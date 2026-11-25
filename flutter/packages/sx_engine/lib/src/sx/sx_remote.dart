import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:sx_api/sx_api.dart';
import 'package:xml/xml.dart';

import '../ps_compat.dart';
import '../show/show_env.dart';
import 'remote_setup.dart';

// SHOWXPRESS REMOTE: presses Live buttons in a running ShowXpress through its
// "External App" network control (TCP 7348, protocol in ShowXpress's
// External_Application/Protocol.pdf). Lines end in CRLF:
//   -> HELLO|ShowXpressHelper|<password>     <- HELLO  (or ERROR...)
//   -> BUTTON_LIST                            <- BUTTON_LIST|<buttons><page name=..><button pressed="1">TITLE</button>..
//   -> BUTTON_PRESS|<title>  /  BUTTON_RELEASE|<title>
// Buttons are found by TITLE. When two share a title ShowXpress only reaches
// the first. Connections are short (connect, press, close): a connected app
// gets beat messages, and SX Studio doesn't want to sit on that during a show.
//
// Port of `sx_remote.ps1` (connection, State, Press, Release, Off).

/// One button as whoever plays it (ShowXpress or the SX Player) sees it.
class ButtonOnAir {
  ButtonOnAir(this.title, this.page, this.pressed);

  final String title;
  final String page;
  bool pressed;
}

/// An open connection to whatever plays the buttons.
abstract interface class ButtonSession {
  /// Every button, as last read.
  List<ButtonOnAir> get list;

  /// Sends `BUTTON_PRESS|<title>` and `BUTTON_RELEASE|<title>` lines, then
  /// updates [list].
  Future<void> send(List<String> cmds);

  Future<void> close();
}

/// A connection attempt: a session, or the reason there is none.
typedef Connection = ({ButtonSession? session, String error});

/// The first button for each title, ignoring case. Port of `Get-ByTitle`.
Map<String, ButtonOnAir> byTitle(List<ButtonOnAir> list) {
  final h = psMap<ButtonOnAir>();
  for (final b in list) {
    h.putIfAbsent(b.title, () => b);
  }
  return h;
}

/// True for ShowXpress's SETUP page, whose buttons never count as "the show playing".
bool isSetupPage(String page) => RegExp(r'^\s*setup\s*$', caseSensitive: false).hasMatch(page);

/// Reads CRLF lines from a socket.
class _Lines {
  _Lines(this._socket) {
    _sub = _socket.listen(
      (data) {
        _bytes.addAll(data);
        var k = -1;
        for (var i = _bytes.length - 2; i >= 0; i--) {
          if (_bytes[i] == 13 && _bytes[i + 1] == 10) {
            k = i;
            break;
          }
        }
        if (k >= 0) {
          _queue.addAll(utf8.decode(_bytes.sublist(0, k), allowMalformed: true).split('\r\n'));
          _bytes.removeRange(0, k + 2);
        }
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      onError: (Object _) {
        _closed = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  late final StreamSubscription<List<int>> _sub;
  final _bytes = <int>[];
  final _queue = <String>[];
  var _closed = false;
  Completer<void>? _waiting;

  void _wake() {
    _waiting?.complete();
    _waiting = null;
  }

  /// Lines up to and including the first one [done] accepts, or everything
  /// read when [ms] pass or the connection closes. Port of `Read-Sx`.
  Future<List<String>> readUntil(bool Function(String) done, int ms) async {
    final out = <String>[];
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (true) {
      while (_queue.isNotEmpty) {
        final l = _queue.removeAt(0);
        out.add(l);
        if (done(l)) return out;
      }
      final left = end.difference(DateTime.now());
      if (_closed || left <= Duration.zero) return out;
      final w = _waiting = Completer<void>();
      await w.future.timeout(left, onTimeout: () {});
    }
  }

  void send(String line) => _socket.add(utf8.encode('$line\r\n'));

  Future<void> close() async {
    await _sub.cancel();
    _socket.destroy();
  }
}

/// A connection to ShowXpress's remote.
class SxTcpSession implements ButtonSession {
  SxTcpSession._(this._lines);

  final _Lines _lines;

  @override
  List<ButtonOnAir> list = [];

  /// Connects and says hello. Null when ShowXpress doesn't answer.
  /// Throws [ToolError] when it refuses the password. Port of `Open-Sx`.
  static Future<SxTcpSession?> open(int port, String password, {String host = '127.0.0.1'}) async {
    final Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 1500));
    } on Object {
      return null;
    }
    final s = SxTcpSession._(_Lines(socket));
    s._lines.send('HELLO|ShowXpressHelper|$password');
    final r = await s._lines.readUntil((l) => l == 'HELLO' || psLike(l, 'ERROR'), 2500);
    final h = r.where((l) => l == 'HELLO' || psLike(l, 'ERROR')).firstOrNull;
    if (h != 'HELLO') {
      await s.close();
      if (h != null) throw ToolError('ShowXpress refused SX Studio ($h). Turn the remote on again from SX Studio.');
      return null;
    }
    return s;
  }

  /// Asks for every button. Null when ShowXpress didn't send the list.
  /// Port of `Get-SxList`.
  Future<List<ButtonOnAir>?> readList() async {
    _lines.send('BUTTON_LIST');
    final r = await _lines.readUntil((l) => l.startsWith('BUTTON_LIST|'), 4000);
    final x = r.where((l) => l.startsWith('BUTTON_LIST|')).lastOrNull;
    if (x == null) return null;
    return parseButtonList(x.substring(12));
  }

  @override
  Future<void> send(List<String> cmds) async {
    if (cmds.isEmpty) return;
    cmds.forEach(_lines.send);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final l2 = await readList();
    if (l2 != null && l2.isNotEmpty) list = l2;
  }

  @override
  Future<void> close() => _lines.close();
}

/// PowerShell's `-like 'X*'`: starts with [prefix], ignoring case.
bool psLike(String s, String prefix) => s.toLowerCase().startsWith(prefix.toLowerCase());

/// The buttons in ShowXpress's `BUTTON_LIST` XML.
///
/// PowerShell's XML adapter turns an element with no attributes and only
/// text into a plain string, so such a button has no title. Kept as found.
List<ButtonOnAir> parseButtonList(String xml) {
  final XmlDocument d;
  try {
    d = XmlDocument.parse(xml);
  } on XmlException {
    throw ToolError("ShowXpress sent a button list SX Studio can't read.");
  }
  bool plain(XmlElement e) => e.attributes.isEmpty && e.childElements.isEmpty;
  Iterable<XmlElement> kids(XmlElement e, String name) => e.childElements.where((c) => psEq(c.name.local, name));
  final root = d.rootElement;
  if (!psEq(root.name.local, 'buttons')) return [];
  return [
    for (final pg in kids(root, 'page'))
      if (!plain(pg) || pg.innerText.isNotEmpty)
        for (final b in kids(pg, 'button'))
          if (!plain(b) || b.innerText.isNotEmpty)
            ButtonOnAir(plain(b) ? '' : b.innerText.trim(), plain(pg) ? '' : pg.getAttribute('name') ?? '', !plain(b) && b.getAttribute('pressed') == '1'),
  ];
}

/// Connects to ShowXpress and reads its buttons. Port of `Connect-Sx`.
Future<Connection> connectShowXpress(RemoteConfig setup, {required bool open}) async {
  if (!setup.ready) return (session: null, error: 'The ShowXpress remote is off.');
  if (!open) return (session: null, error: 'ShowXpress is closed.');
  final cn = await SxTcpSession.open(setup.port, setup.password);
  if (cn == null) {
    return (
      session: null,
      error: "ShowXpress isn't answering yet (still starting, or it was opened before the remote was turned on - close and open it again).",
    );
  }
  try {
    final list = await cn.readList();
    if (list == null || list.isEmpty) {
      await cn.close();
      return (session: null, error: "ShowXpress hasn't loaded the show yet.");
    }
    cn.list = list;
    return (session: cn, error: '');
  } catch (_) {
    await cn.close();
    rethrow;
  }
}

/// What a remote call does.
enum RemoteAction { state, press, release, off }

/// Distinct in first-seen order, case sensitive, like `Select-Object -Unique`.
List<String> _unique(Iterable<String> xs) => [...LinkedHashSet<String>.of(xs)];

/// `-notin` / `-in`: list membership ignoring case.
bool psIn(String x, Iterable<String> xs) => xs.any((y) => psEq(x, y));

/// Reads what ShowXpress plays, or presses and releases buttons.
///
/// [titles] are the buttons to press (or release). [solo] releases everything
/// else that plays first. [idle] presses nothing when something outside the
/// SETUP page plays, so a running show is never cut. [release] are extra
/// buttons to turn off (the Auto Show tab's "Try").
///
/// Port of the State / Press / Release / Off part of `sx_remote.ps1`.
Future<RemoteState> remoteAction(
  ShowEnv env,
  RemoteAction action, {
  List<String> titles = const [],
  List<String> release = const [],
  bool solo = false,
  bool idle = false,
  String? paramPath,
}) async {
  final want = [for (final t in titles) t.trim()].where((t) => t.isNotEmpty).toList();
  final setup = RemoteConfig.read(env, paramPath: paramPath);
  final open = env.sxRunning();
  final x = await connectShowXpress(setup, open: open);
  final cn = x.session;
  if (cn == null) return RemoteState(ready: setup.ready, open: open, error: x.error, setup: setup.toWire());
  try {
    final list = cn.list, by = byTitle(list);
    final cmds = <String>[], released = <String>[], pressedNow = <String>[];
    var missing = <String>[], playing = <String>[], skipped = false;
    if (action == RemoteAction.press) {
      missing = [
        for (final t in want)
          if (!by.containsKey(t)) t,
      ];
      final other = [
        for (final b in list)
          if (b.pressed && !psIn(b.title, want)) b,
      ];
      if (idle) {
        playing = _unique([
          for (final b in other)
            if (!isSetupPage(b.page)) b.title,
        ]);
        skipped = playing.isNotEmpty;
      }
      if (!skipped) {
        if (solo) {
          for (final b in other) {
            cmds.add('BUTTON_RELEASE|${b.title}');
            released.add(b.title);
          }
        } else {
          for (final t in _unique([for (final r in release) r.trim()].where((t) => t.isNotEmpty && !psIn(t, want)))) {
            if (by[t]?.pressed ?? false) {
              cmds.add('BUTTON_RELEASE|$t');
              released.add(t);
            }
          }
        }
        for (final t in want) {
          if (by[t] case final b? when !b.pressed) {
            cmds.add('BUTTON_PRESS|$t');
            pressedNow.add(t);
          }
        }
      }
    } else if (action == RemoteAction.release) {
      for (final t in want) {
        if (by[t]?.pressed ?? false) {
          cmds.add('BUTTON_RELEASE|$t');
          released.add(t);
        }
      }
    } else if (action == RemoteAction.off) {
      for (final b in list.where((b) => b.pressed)) {
        cmds.add('BUTTON_RELEASE|${b.title}');
        released.add(b.title);
      }
    }
    await cn.send(cmds);
    return RemoteState(
      ready: setup.ready,
      open: open,
      connected: true,
      pressed: [
        for (final b in cn.list)
          if (b.pressed) PressedButton(title: b.title, page: b.page),
      ],
      titles: _unique(cn.list.map((b) => b.title)),
      setup: setup.toWire(),
      pressedNow: pressedNow,
      released: released,
      missing: missing,
      skipped: skipped,
      playing: playing,
    );
  } finally {
    await cn.close();
  }
}
