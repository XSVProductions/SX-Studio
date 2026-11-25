import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One button in the fake ShowXpress.
class FakeButton {
  FakeButton(this.page, this.title, {this.pressed = false});

  final String page;
  final String title;
  bool pressed;
}

/// A stand-in for ShowXpress's "External App" remote on a local port.
///
/// Answers HELLO (checking the password), BUTTON_LIST, BUTTON_PRESS and
/// BUTTON_RELEASE like ShowXpress does, and keeps every line it receives in
/// [log], so tests can compare what two clients sent.
class FakeSxRemote {
  FakeSxRemote._(this._server, this.password);

  static Future<FakeSxRemote> start({required String password}) async =>
      FakeSxRemote._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), password).._listen();

  final ServerSocket _server;
  final String password;
  int get port => _server.port;

  var buttons = <FakeButton>[];

  /// Lines received, in order, over every connection.
  final log = <String>[];

  /// Sent after HELLO, as ShowXpress sends beats to a connected app.
  var noise = false;

  /// Answer HELLO with ERROR instead.
  var refuse = false;

  final _sockets = <Socket>[];

  void _listen() => _server.listen((s) {
    _sockets.add(s);
    var buf = '';
    s.listen((data) {
      buf += utf8.decode(data);
      while (buf.contains('\r\n')) {
        final k = buf.indexOf('\r\n');
        final line = buf.substring(0, k);
        buf = buf.substring(k + 2);
        log.add(line);
        _answer(s, line);
      }
    }, onError: (Object _) {});
  });

  void _answer(Socket s, String line) {
    void send(String l) => s.add(utf8.encode('$l\r\n'));
    if (line.startsWith('HELLO|')) {
      if (refuse || line.split('|').last != password) return send('ERROR|BAD_PASSWORD');
      send('HELLO');
      if (noise) send('BEAT_ON');
    } else if (line == 'BUTTON_LIST') {
      if (noise) send('BEAT_ON');
      send('BUTTON_LIST|${listXml()}');
    } else if (line.startsWith('BUTTON_PRESS|') || line.startsWith('BUTTON_RELEASE|')) {
      final t = line.substring(line.indexOf('|') + 1);
      final b = buttons.where((b) => b.title == t).firstOrNull;
      if (b != null) b.pressed = line.startsWith('BUTTON_PRESS|');
    }
  }

  String listXml() {
    String esc(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s).replaceAll('"', '&quot;');
    final pages = <String, List<FakeButton>>{};
    for (final b in buttons) {
      pages.putIfAbsent(b.page, () => []).add(b);
    }
    final sb = StringBuffer('<buttons>');
    for (final e in pages.entries) {
      sb.write('<page name="${esc(e.key)}">');
      for (final (i, b) in e.value.indexed) {
        sb.write('<button index="$i" flash="0" pressed="${b.pressed ? 1 : 0}">${esc(b.title)}</button>');
      }
      sb.write('</page>');
    }
    sb.write('</buttons>');
    return sb.toString();
  }

  /// Titles pressed now.
  List<String> get pressed => [
    for (final b in buttons)
      if (b.pressed) b.title,
  ];

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }
}
