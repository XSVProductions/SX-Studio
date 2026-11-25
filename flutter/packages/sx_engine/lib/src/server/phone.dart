import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/text_files.dart';

// PHONE / iPAD: a phone on the same Wi-Fi opens the laptop's network port
// (47322) and gets the same app. It is let in once with a 6-digit code shown
// on the laptop (good for 10 minutes, for any number of phones), then it
// keeps the key. Every phone has the same key, kept in `phone.json` in the
// settings folder. "Unpair all phones" makes a new key.
//
// Port of the PHONE / iPAD block, `Set-PhoneCookie`, `Get-PhoneCookieKey`
// and the `/api/phone/...` routes in `df_aim_gui.ps1`.

/// How long a pairing code stays good.
const pinLife = Duration(minutes: 10);

/// Wrong codes allowed before the code is dropped.
const pinTries = 5;

/// How long pairing stays shut after too many wrong codes.
const pinLockout = Duration(seconds: 60);

/// The cookie a paired phone keeps its key in.
const phoneCookie = 'sxh_k';

/// The mark in the web page's `index.html` that the phone's key replaces.
/// The old page's `__PHONEKEY__`.
const phoneKeyMark = '__PHONEKEY__';

/// Paths a phone may use without the key. The old `$phoneOpen`. The web
/// app's own files are served before any key is checked, as `/` was.
const phoneOpenPaths = {'/', '/icon.png', '/brand.png', '/logo.png', '/mark.png', '/api/phone/pair', '/fonts/saira.woff2', '/fonts/orbitron.woff2'};

/// Compares two strings in time that depends only on their length.
bool sameSecret(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  if (x.length != y.length) return false;
  var d = 0;
  for (var i = 0; i < x.length; i++) {
    d |= x[i] ^ y[i];
  }
  return d == 0;
}

/// Phone access: on or off, the one key every paired phone holds, the
/// pairing code and the last phone seen.
class PhoneAccess {
  PhoneAccess(this.dir, {DateTime Function()? now, Random? random}) : now = now ?? DateTime.now, _rnd = random ?? Random.secure() {
    _load();
    if (key.isEmpty) key = newPhoneKey(_rnd);
  }

  /// The settings folder.
  final String dir;
  final DateTime Function() now;
  final Random _rnd;

  /// `phone.json`, next to `settings.json`.
  String get file => p.join(dir, 'phone.json');

  /// Phone access is turned on. The network listener runs while this is true.
  bool on = false;

  /// The key every paired phone holds. Made at start when there is none,
  /// and kept in [file] with the next save.
  String key = '';

  String _pin = '';
  var _pinUntil = DateTime(0);
  var _fails = 0;
  var _lockUntil = DateTime(0);

  /// The last call from a phone: when and from where. The relay's
  /// `LastSeen` and `LastIp`.
  DateTime? lastSeen;
  String lastIp = '';

  void _load() {
    if (!File(file).existsSync()) return;
    try {
      final j = jsonDecode(readText(file));
      if (j is! Map) return;
      on = psTruthy(j['on']);
      final k = j['key'];
      key = k == null ? '' : '$k';
    } on Object {
      // a broken file reads as phone access off; a new key is made
      on = false;
      key = '';
    }
  }

  /// `Save-Phone`: `{"on":...,"key":"..."}`, no byte order mark.
  void _save() {
    Directory(dir).createSync(recursive: true);
    writeTextSafely(file, jsonEncode({'on': on, 'key': key}), bom: false);
  }

  /// Turns phone access on or off and saves it. Off also drops the code,
  /// and the last phone seen goes with the stopped listener.
  void setOn(bool value) {
    on = value;
    _save();
    if (!on) {
      _pin = '';
      lastSeen = null;
      lastIp = '';
    }
  }

  /// The code showing on the laptop, or '' when none is.
  String get pin => _pin.isNotEmpty && now().isBefore(_pinUntil) ? _pin : '';

  /// Seconds the code has left.
  int get pinLeft => pin.isEmpty ? 0 : psRound(_pinUntil.difference(now()).inMicroseconds / 1e6);

  /// Shows a new 6-digit code for [pinLife]. Any number of phones can pair
  /// with it in that time. A lockout after wrong codes still runs out.
  void newPin() {
    _pin = _rnd.nextInt(1000000).toString().padLeft(6, '0');
    _pinUntil = now().add(pinLife);
    _fails = 0;
  }

  /// Pairs a phone that typed [code]. Answers the key. Throws `PairRefused`
  /// with the reason the phone sees.
  String pair(String code) {
    final t = now();
    if (t.isBefore(_lockUntil)) throw PairRefused('Too many wrong codes. On the laptop, press "Pair a phone" again for a new code.');
    if (_pin.isEmpty || t.isAfter(_pinUntil)) {
      throw PairRefused('No code is showing on the laptop. In SX Studio on the laptop, press the cogwheel (top right) and press "Pair a phone".');
    }
    if (code.trim() == _pin) {
      _fails = 0;
      _save();
      return key;
    }
    if (++_fails >= pinTries) {
      _pin = '';
      _lockUntil = t.add(pinLockout);
    }
    throw PairRefused('That code is not right. Check the 6 digits on the laptop.', wrongCode: true);
  }

  /// True when [k] is the key. `-ceq`: case counts.
  bool check(String k) => k.isNotEmpty && key.isNotEmpty && sameSecret(k, key);

  /// "Unpair all phones": a new key, so every phone has to pair again.
  /// Drops the code too.
  void unpair() {
    key = newPhoneKey(_rnd);
    _save();
    _pin = '';
  }

  /// Notes a call from a phone at [ip].
  void saw(String ip) {
    lastSeen = now();
    lastIp = ip;
  }

  /// The key from the phone's cookie, when it is the current one, else ''.
  /// `Get-PhoneCookieKey`.
  String cookieKey(Request req) {
    final c = requestCookie(req, phoneCookie);
    return check(c) ? c : '';
  }

  /// Why a call from a phone is refused, or null to let it through. The old
  /// server's checks, in its order: phone access off, a laptop-only path,
  /// then the key (in `?t=`, the cookie, or the header the app sends).
  String? refuse(Request req, {required String path, required bool laptopOnly}) {
    if (!on) return 'Phone access is turned off in SX Studio.';
    if (laptopOnly) return 'Only on the computer.';
    if (phoneOpenPaths.contains(path)) return null;
    final t = req.url.queryParameters['t'] ?? '';
    if (check(t) || cookieKey(req).isNotEmpty || check(req.headers['x-sx-token'] ?? '')) return null;
    return 'Pair this phone again.';
  }

  /// The key a phone's page gets back when it loads: from its cookie, or
  /// from `?k=` in the address, when that is the current key. '' otherwise.
  String pageKey(Request req) {
    final ck = cookieKey(req);
    if (ck.isNotEmpty) return ck;
    final uk = req.url.queryParameters['k'] ?? '';
    return check(uk) ? uk : '';
  }

  /// `Set-PhoneCookie`: the key, kept by the phone for ten years.
  Map<String, String> get cookieHeader => {'set-cookie': '$phoneCookie=$key; Max-Age=315360000; Path=/; HttpOnly; SameSite=Lax'};
}

/// `New-PhoneKey`: two new GUIDs, 64 lowercase hex digits.
String newPhoneKey(Random rnd) {
  String guid() {
    final b = [for (var i = 0; i < 16; i++) rnd.nextInt(256)];
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  }

  return guid() + guid();
}

/// One cookie's value from a request, or ''.
String requestCookie(Request req, String name) {
  for (final part in (req.headers['cookie'] ?? '').split(';')) {
    final i = part.indexOf('=');
    if (i > 0 && part.substring(0, i).trim() == name) return part.substring(i + 1).trim();
  }
  return '';
}

/// The phone's page: the web app's `index.html` with the key filled in when
/// the phone showed the current one, and the cookie set again. The old `/`
/// branch for a phone.
Response phonePage(String webDir, PhoneAccess phones, Request req) {
  final key = phones.pageKey(req);
  final html = File(p.join(webDir, 'index.html')).readAsStringSync().replaceAll(phoneKeyMark, key);
  return Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', if (key.isNotEmpty) ...phones.cookieHeader});
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
/// `Get-LocalName`: on a Mac, `scutil --get LocalHostName` first.
Future<String> localName() async {
  var n = '';
  if (Platform.isMacOS) {
    try {
      final r = await Process.run('scutil', ['--get', 'LocalHostName']);
      n = scutilName('${r.stdout}');
    } on ProcessException {
      n = '';
    }
  }
  return localNameFrom(n, Platform.localHostname);
}

/// What `"$(& scutil --get LocalHostName 2>$null)".Trim()` gives: the
/// output's lines joined with spaces, trimmed. A failed run prints its error
/// on stderr, so it gives ''.
String scutilName(String stdout) {
  final lines = stdout.split(RegExp(r'\r?\n'));
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines.join(' ').trim();
}

/// The `.local` name from the Mac's LocalHostName [mac] (or '') and the
/// computer's host name. '' when it isn't a plain name.
String localNameFrom(String mac, String hostName) {
  final n = mac.isNotEmpty ? mac : hostName.replaceAll(RegExp(r'\.local$', caseSensitive: false), '');
  return RegExp(r'^[A-Za-z0-9-]{1,63}$').hasMatch(n) ? '$n.local' : '';
}
