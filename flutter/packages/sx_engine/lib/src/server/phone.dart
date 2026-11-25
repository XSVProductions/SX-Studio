import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../show/text_files.dart';

// PHONE / iPAD: a phone on the same Wi-Fi opens the laptop's network port
// (47322) and gets the same app. It is let in once with a 6-digit code shown
// on the laptop, and then keeps a long random key of its own. The laptop
// keeps only a hash of each key, in `phones.json` in the settings folder.
//
// Port of the PHONE / iPAD block and the `/api/phone/...` routes in
// `df_aim_gui.ps1`. The old app gave every phone the same key and sent it in
// the address. Here each phone has its own key, sent in a header only.

/// How long a pairing code stays good.
const pinLife = Duration(minutes: 10);

/// Wrong codes allowed before the code is dropped.
const pinTries = 5;

/// How long pairing stays shut after too many wrong codes.
const pinLockout = Duration(seconds: 60);

class _Phone {
  _Phone(this.id, this.name, this.hash, this.paired);

  final String id;
  final String name;

  /// SHA-256 of the key, as bytes.
  final List<int> hash;
  final String paired;

  Json toJson() => {'id': id, 'name': name, 'hash': _hex(hash), 'paired': paired};
}

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

List<int> _unhex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

List<int> _hash(String key) => sha256.convert(utf8.encode(key)).bytes;

/// Compares two byte lists in time that depends only on their length.
bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

/// Compares two strings in time that depends only on their length.
bool sameSecret(String a, String b) => _sameBytes(utf8.encode(a), utf8.encode(b));

/// `yyyy-MM-ddTHH:mm:ss`, PowerShell's `ToString('s')`.
String sortableTime(DateTime t) => t.toIso8601String().substring(0, 19);

/// A short name for a phone from its browser's User-Agent.
String phoneName(String userAgent) {
  for (final (rx, name) in [
    (RegExp('iPad'), 'iPad'),
    (RegExp('iPhone'), 'iPhone'),
    (RegExp('Android.*Mobile'), 'Android phone'),
    (RegExp('Android'), 'Android tablet'),
    (RegExp('Macintosh'), 'Mac'),
    (RegExp('Windows'), 'Windows computer'),
  ]) {
    if (rx.hasMatch(userAgent)) return name;
  }
  return 'Phone';
}

/// Phone access: on or off, the pairing code, and the paired phones.
class PhoneAccess {
  PhoneAccess(this.dir, {DateTime Function()? now, Random? random}) : now = now ?? DateTime.now, _rnd = random ?? Random.secure() {
    _load();
  }

  /// The settings folder.
  final String dir;
  final DateTime Function() now;
  final Random _rnd;

  String get file => p.join(dir, 'phones.json');

  /// Phone access is turned on. The network listener runs while this is true.
  bool on = false;

  final _phones = <_Phone>[];
  final _seen = <String, (DateTime, String)>{};

  String _pin = '';
  var _pinUntil = DateTime(0);
  var _fails = 0;
  var _lockUntil = DateTime(0);

  void _load() {
    final f = File(file);
    if (f.existsSync()) {
      try {
        final j = (jsonDecode(readText(file)) as Map).cast<String, Object?>();
        on = j.boolean('on');
        for (final ph in j.list('phones', (x) => x)) {
          final hash = _unhex(ph.str('hash'));
          if (hash.length == 32) _phones.add(_Phone(ph.str('id'), ph.str('name'), hash, ph.str('paired')));
        }
      } on Object {
        // a broken file means no phones are paired; they pair again
      }
      return;
    }
    // The old app's phone.json: one key shared by every phone. Phones paired
    // with it keep working until they are unpaired here.
    final old = File(p.join(dir, 'phone.json'));
    if (!old.existsSync()) return;
    try {
      final j = (jsonDecode(readText(old.path)) as Map).cast<String, Object?>();
      on = j.boolean('on');
      final key = j.str('key');
      if (on && key.isNotEmpty) _phones.add(_Phone(_newId(), 'Paired before the update', _hash(key), ''));
    } on Object {
      return;
    }
  }

  void _save() {
    Directory(dir).createSync(recursive: true);
    writeTextSafely(
      file,
      const JsonEncoder.withIndent('  ').convert({
        'on': on,
        'phones': [for (final ph in _phones) ph.toJson()],
      }),
      bom: false,
    );
  }

  String _newId() => [for (var i = 0; i < 4; i++) _rnd.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  /// Turns phone access on or off and saves it. Off also drops the code.
  void setOn(bool value) {
    on = value;
    if (!on) _pin = '';
    _save();
  }

  /// The code showing on the laptop, or '' when none is.
  String get pin => _pin.isNotEmpty && now().isBefore(_pinUntil) ? _pin : '';

  /// Seconds the code has left.
  int get pinLeft => pin.isEmpty ? 0 : _pinUntil.difference(now()).inSeconds;

  /// Shows a new 6-digit code for [pinLife]. One phone can pair with it.
  void newPin() {
    _pin = _rnd.nextInt(1000000).toString().padLeft(6, '0');
    _pinUntil = now().add(pinLife);
    _fails = 0;
    _lockUntil = DateTime(0);
  }

  /// Pairs a phone that typed [code]. Answers its new key, which is shown
  /// to that phone once and never kept here. Throws `PairRefused` with the
  /// reason the phone sees.
  String pair(String code, {String name = 'Phone'}) {
    final t = now();
    if (t.isBefore(_lockUntil)) throw PairRefused('Too many wrong codes. On the laptop, press "Pair a phone" again for a new code.');
    if (pin.isEmpty) {
      throw PairRefused('No code is showing on the laptop. In SX Studio on the laptop, press the cogwheel (top right) and press "Pair a phone".');
    }
    if (!sameSecret(code.trim(), _pin)) {
      if (++_fails >= pinTries) {
        _pin = '';
        _lockUntil = t.add(pinLockout);
      }
      throw PairRefused('That code is not right. Check the 6 digits on the laptop.', wrongCode: true);
    }
    _pin = '';
    _fails = 0;
    final key = base64Url.encode([for (var i = 0; i < 32; i++) _rnd.nextInt(256)]).replaceAll('=', '');
    _phones.add(_Phone(_newId(), name, _hash(key), sortableTime(t)));
    _save();
    return key;
  }

  /// The id of the paired phone that holds [key], or null. Notes when and
  /// from where it was seen.
  String? check(String key, {String ip = ''}) {
    if (key.isEmpty) return null;
    final h = _hash(key);
    String? found;
    // every phone is compared, so the time taken says nothing about the key
    for (final ph in _phones) {
      if (_sameBytes(ph.hash, h)) found = ph.id;
    }
    if (found != null) _seen[found] = (now(), ip);
    return found;
  }

  /// Unpairs one phone by id, or every phone with `*`. Drops the code too.
  void unpair(String id) {
    if (id == '*') {
      _phones.clear();
    } else {
      _phones.removeWhere((ph) => ph.id == id);
    }
    _pin = '';
    _save();
  }

  /// The paired phones, for the laptop's list.
  List<PairedPhone> get phones => [
    for (final ph in _phones)
      PairedPhone(
        id: ph.id,
        name: ph.name,
        paired: ph.paired,
        lastSeen: _seen[ph.id] == null ? '' : sortableTime(_seen[ph.id]!.$1),
        lastIp: _seen[ph.id]?.$2 ?? '',
      ),
  ];

  /// The most recent call from any phone: when and from where.
  (DateTime, String)? get lastSeen => _seen.values.fold<(DateTime, String)?>(null, (a, b) => a == null || b.$1.isAfter(a.$1) ? b : a);
}

/// Pairing said no. [message] is what the phone shows.
class PairRefused implements Exception {
  PairRefused(this.message, {this.wrongCode = false});

  final String message;

  /// The code was wrong (the answer waits a little, to slow guessing).
  final bool wrongCode;
}

/// This computer's network addresses a phone can use, Wi-Fi first. Port of
/// `Get-LanAddrs`.
Future<List<LanAddress>> lanAddresses() async {
  final skip = RegExp(
    'vEthernet|VMware|VirtualBox|Hyper-V|Loopback|utun|awdl|llw|bridge|docker|WSL|Tailscale|ZeroTier|^veth|^br-|^virbr',
    caseSensitive: false,
  );
  final wifi = RegExp(r'Wi-?Fi|WLAN|Wireless|^en0$|^wl', caseSensitive: false);
  final out = <LanAddress>[];
  try {
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (skip.hasMatch(ni.name)) continue;
      for (final a in ni.addresses) {
        if (a.isLoopback || a.isLinkLocal || a.address.startsWith('127.') || a.address.startsWith('169.254.')) continue;
        out.add(LanAddress(ip: a.address, name: ni.name, wifi: wifi.hasMatch(ni.name)));
      }
    }
  } on SocketException {
    return out;
  }
  out.sort((a, b) => a.wifi != b.wifi ? (a.wifi ? -1 : 1) : a.ip.compareTo(b.ip));
  return out;
}

/// The Bonjour name (`laptop.local`), the same at every venue. Port of
/// `Get-LocalName`.
String localName() {
  final n = Platform.localHostname.replaceAll(RegExp(r'\.local$'), '');
  return RegExp(r'^[A-Za-z0-9-]{1,63}$').hasMatch(n) ? '$n.local' : '';
}
