import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';

import 'desktop_window.dart';

/// The laptop UI's port, the old window server's (`-Port 47321`).
const appPort = 47321;

SendPort? _engine;
File? _info;

/// Starts the engine on its own isolate, so a slow file tool never holds up
/// the window, and connects to it over the loopback address.
///
/// One copy only, as the old app: the engine takes port 47321 and writes the
/// old info file (`showxpress_helper_gui.json` in the temp folder) with its
/// address, process id and version. When the port is taken, a copy of the
/// same version brings up its window and this one quits; an older or newer
/// version still running (right after an update) is stopped and replaced.
///
/// `SX_SHOW` points the engine at a show folder (development). `SX_PORT`
/// picks another port, with its own info file, as the old `-Port`. `SX_WEB`
/// is the web build phones load, otherwise the `web` folder next to the app.
Future<SxClient> boot() async {
  final rnd = Random.secure();
  final token = [for (var i = 0; i < 24; i++) rnd.nextInt(16).toRadixString(16)].join();
  final port = int.tryParse(Platform.environment['SX_PORT'] ?? '') ?? appPort;
  final config = EngineConfig(
    port: port,
    token: token,
    showPath: Platform.environment['SX_SHOW'],
    webDir: Platform.environment['SX_WEB'] ?? bundledWeb(Platform.resolvedExecutable),
    settingsDir: settingsDir,
    appExe: Platform.resolvedExecutable,
  );
  final info = infoFile(port);
  var started = await _startEngine(config);
  if (started == null) {
    var other = readInfo(info);
    // A copy started a moment ago (the installer and the old app's updater
    // both open the app) has the port but may not have written the file yet.
    for (var n = 0; n < 20 && (other == null || processName(other.pid) == null); n++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      other = readInfo(info);
    }
    if (other != null && other.ver != sxStudioVersion && isAppProcess(processName(other.pid))) {
      Process.killPid(other.pid, ProcessSignal.sigkill);
      for (var n = 0; n < 20 && started == null; n++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        started = await _startEngine(config);
      }
    }
    if (started == null) {
      if (other != null) {
        await showOtherCopy(other.pid);
        exit(0);
      }
      throw BootFailure('Port $port is busy and no running SX Studio was found.');
    }
  }
  _engine = started.stop;
  _info = info;
  writeInfo(info, url: 'http://localhost:$port/?t=$token', pid: pid, ver: sxStudioVersion);
  unawaited(started.quit.then(_quit));
  return SxClient(Uri.parse('http://127.0.0.1:${started.port}'), token: token, client: LiveWatch(http.Client()));
}

/// The engine asked to quit: five minutes idle with the window closed, or an
/// update is ready. Stops it (the installer starts then) and ends the app.
Future<void> _quit(QuitReason why) async {
  // the window shows "Installing the update..." for a moment first
  if (why == QuitReason.update) await Future<void>.delayed(const Duration(seconds: 1));
  await shutdown();
  exit(0);
}

/// The web build shipped with the app: `web` next to the program on Windows
/// and Linux, `Contents/Resources/web` in the Mac app. The usual place when
/// neither is there, so the engine knows the phone page is missing.
String bundledWeb(String exe) {
  final dir = File(exe).parent.path;
  final places = ['$dir${Platform.pathSeparator}web', '$dir/../Resources/web'];
  return places.firstWhere((d) => File('$d/index.html').existsSync(), orElse: () => Platform.isMacOS ? places[1] : places[0]);
}

/// The old app's info file for [port]: another port keeps its own, so a test
/// copy never shows the real one's window.
File infoFile(int port) =>
    File('${Directory.systemTemp.path}${Platform.pathSeparator}${port == appPort ? 'showxpress_helper_gui.json' : 'showxpress_helper_gui_$port.json'}');

/// What the info file says about the running copy, or null when there is no
/// readable one.
({String url, int pid, String ver})? readInfo(File f) {
  try {
    final j = jsonDecode(f.readAsStringSync());
    if (j is! Map) return null;
    final p = j['pid'];
    return (url: '${j['url'] ?? ''}', pid: p is int ? p : int.tryParse('${p ?? ''}') ?? 0, ver: '${j['ver'] ?? ''}');
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Writes the info file as the old app did (`url`, `pid`, `ver`).
void writeInfo(File f, {required String url, required int pid, required String ver}) {
  try {
    f.writeAsStringSync(jsonEncode({'url': url, 'pid': pid, 'ver': ver}));
  } on FileSystemException {
    // a second start then can't find this copy, as with the old app
  }
}

/// True for a process this app may stop to replace: the old PowerShell app
/// (`pwsh`, `powershell`) or this one (`sx_studio`).
bool isAppProcess(String? name) => name != null && RegExp(r'^(pwsh|powershell|sx_studio)(\.exe)?$', caseSensitive: false).hasMatch(name);

/// The program name of process [id], or null when it isn't running.
String? processName(int id) {
  if (id <= 0) return null;
  try {
    if (Platform.isWindows) {
      final r = Process.runSync('tasklist', ['/FI', 'PID eq $id', '/FO', 'CSV', '/NH']);
      final m = RegExp(r'^"([^"]+)","(\d+)"').firstMatch('${r.stdout}'.trim());
      return m != null && m[2] == '$id' ? m[1] : null;
    }
    final r = Process.runSync('ps', ['-p', '$id', '-o', 'comm=']);
    final name = '${r.stdout}'.trim();
    return name.isEmpty ? null : name.split('/').last;
  } on ProcessException {
    return null;
  }
}

/// Stops the engine and waits for it: lights out, the player and the Auto
/// Show stopped, the phone listener closed. A downloaded update's installer
/// starts then. Removes the info file when it is this copy's.
Future<void> shutdown() async {
  final engine = _engine;
  if (engine == null) return;
  _engine = null;
  final done = ReceivePort();
  engine.send(done.sendPort);
  await done.first.timeout(const Duration(seconds: 10), onTimeout: () => null);
  done.close();
  if (_info case final f?) {
    if (readInfo(f)?.pid == pid) {
      try {
        f.deleteSync();
      } on FileSystemException {
        // gone already
      }
    }
  }
}

typedef _Started = ({int port, SendPort stop, Future<QuitReason> quit});

/// Starts an engine isolate. Null when the port is taken.
Future<_Started?> _startEngine(EngineConfig config) async {
  final events = ReceivePort();
  await Isolate.spawn(_engineMain, (events.sendPort, config));
  final quit = Completer<QuitReason>();
  final first = Completer<Object?>();
  events.listen((m) {
    if (!first.isCompleted) {
      first.complete(m);
    } else if (m is int) {
      quit.complete(QuitReason.values[m]);
      events.close();
    }
  });
  final m = await first.future;
  if (m is (int, SendPort)) return (port: m.$1, stop: m.$2, quit: quit.future);
  events.close();
  if (m == 'busy') return null;
  throw BootFailure('$m');
}

Future<void> _engineMain((SendPort, EngineConfig) args) async {
  final (events, config) = args;
  final engine = Engine(config);
  try {
    await engine.start();
  } on SocketException {
    await engine.stop();
    events.send('busy');
    return;
  } on Object catch (e) {
    await engine.stop();
    events.send("SX Studio didn't start: $e");
    return;
  }
  final stop = ReceivePort();
  events.send((engine.port, stop.sendPort));
  unawaited(engine.lifetime.quitting.then((why) => events.send(why.index)));
  final done = await stop.first as SendPort;
  await engine.stop();
  await engine.find<UpdateInstaller>()?.launch();
  done.send(null);
}
