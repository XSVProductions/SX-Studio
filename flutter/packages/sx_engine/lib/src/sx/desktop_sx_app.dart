import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../show/text_files.dart';
import 'sx_app.dart';
import 'sx_process.dart';
import 'windows_desk.dart';

/// What differs between Windows and macOS: finding, opening and closing ShowXpress.
abstract interface class SxOs {
  /// ShowXpress's running processes, asked fresh.
  List<SxProc> processes();

  /// Opens ShowXpress. Returns null, or why it couldn't.
  Future<String?> launch();

  /// Asks ShowXpress to close, letting it ask the user about saving.
  Future<void> askToClose(List<SxProc> procs);
}

/// ShowXpress on this computer, for Windows and macOS.
///
/// [running] is asked on every status poll and by every tool before it
/// writes, so the process list is cached for a second.
///
/// Port of `Get-SxProcess`, `Start-Sx` and `/api/sx/close` in `df_aim_gui.ps1`.
class DesktopSxApp implements SxApp {
  DesktopSxApp(this.os);

  final SxOs os;
  List<SxProc> _procs = const [];
  DateTime? _at;

  List<SxProc> _fresh() {
    _at = DateTime.now();
    return _procs = os.processes();
  }

  List<SxProc> get _cached {
    final at = _at;
    if (at == null || DateTime.now().difference(at) > const Duration(seconds: 1)) return _fresh();
    return _procs;
  }

  @override
  bool get running => _cached.isNotEmpty;

  @override
  Future<ToolResult> launch() async {
    if (_fresh().isNotEmpty) return const ToolResult(ok: true, out: '  ShowXpress is already open', extra: {'already': true});
    final error = await os.launch();
    _at = null;
    if (error != null) return ToolResult.failed(error);
    return const ToolResult(ok: true, out: '  ShowXpress is starting');
  }

  @override
  Future<ToolResult> close({bool force = false}) async {
    final ps = _fresh();
    if (ps.isEmpty) return const ToolResult(ok: true, out: "  ShowXpress isn't open", extra: {'none': true});
    if (force) {
      // stuck (no window, or it never finished closing): stop it, anything not saved is lost
      for (final x in ps) {
        Process.killPid(x.pid, ProcessSignal.sigkill);
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
      // the old app sends the error text along even when it worked
      return ToolResult(ok: _fresh().isEmpty, out: '  ShowXpress was force closed', error: 'ShowXpress could not be stopped - restart the computer.');
    }
    await os.askToClose(ps);
    return const ToolResult(ok: true, out: '  ShowXpress was asked to close');
  }
}

/// ShowXpress on Windows: `Program Files\ShowXpress\TheLightingController.exe`.
class WindowsSx implements SxOs {
  @override
  List<SxProc> processes() => [
    for (final x in windowsProcesses())
      if (isSxProcessName(processNameOf(x.exeFile))) (pid: x.pid, exe: x.exeFile),
  ];

  /// Port of `Get-SxExe`.
  String? exe() {
    final env = Platform.environment;
    for (final dir in [env['ProgramW6432'], env['ProgramFiles'], env['ProgramFiles(x86)']]) {
      if (dir == null || dir.isEmpty) continue;
      final f = p.join(dir, 'ShowXpress', 'TheLightingController.exe');
      if (File(f).existsSync()) return f;
    }
    return null;
  }

  @override
  Future<String?> launch() async {
    final x = exe();
    if (x == null) return r'ShowXpress was not found in Program Files\ShowXpress.';
    await Process.start(x, const [], workingDirectory: p.dirname(x), mode: ProcessStartMode.detached);
    return null;
  }

  /// Closes the main window of each, then for two minutes answers
  /// "Do you really want to quit?" with Yes. "Do you want to save?" stays
  /// with the user. Port of the Windows half of `/api/sx/close` and `sx_quit.ps1`.
  @override
  Future<void> askToClose(List<SxProc> procs) async {
    for (final x in procs) {
      closeMainWindow(x.pid);
    }
    final quit = quitTexts(_languageLines());
    final pids = [for (final x in procs) x.pid];
    final end = DateTime.now().add(const Duration(seconds: 120));
    Timer.periodic(const Duration(milliseconds: 250), (t) {
      final alive = {for (final x in windowsProcesses()) x.pid};
      final ids = pids.where(alive.contains).toList();
      if (ids.isEmpty || DateTime.now().isAfter(end) || answerQuitDialog(ids, quit).isNotEmpty) t.cancel();
    });
  }

  /// Every line of ShowXpress's language files, where `Txt_quit=` is.
  Iterable<String> _languageLines() sync* {
    final dir = Directory(p.join(Platform.environment['ProgramFiles'] ?? r'C:\Program Files', 'ShowXpress', 'TheLightingController', 'language'));
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.ini'))) {
      try {
        yield* readLines(f.path);
      } on FileSystemException {
        continue;
      }
    }
  }
}

/// ShowXpress on a Mac: `TheLightingController.app`.
class MacSx implements SxOs {
  @override
  List<SxProc> processes() {
    try {
      final r = Process.runSync('ps', ['-axo', 'pid=,stat=,comm=']);
      return parseMacPs('${r.stdout}');
    } on ProcessException {
      return const [];
    }
  }

  /// ShowXpress's app: in Applications, or in a ShowXpress folder there (the
  /// download's layout, with the interface driver next to the app), else
  /// wherever Spotlight finds it. Port of `Find-SxMacApp`.
  String? findApp() {
    final home = Platform.environment['HOME'] ?? '';
    final c = <String>[];
    List<Directory> dirs(String path) {
      try {
        return Directory(path).listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
      } on FileSystemException {
        return const [];
      }
    }

    bool isApp(Directory d) => d.path.toLowerCase().endsWith('.app') && looksLikeSx(p.basename(d.path));
    for (final r in ['/Applications', p.join(home, 'Applications')]) {
      if (!Directory(r).existsSync()) continue;
      c.addAll(dirs(r).where(isApp).map((d) => d.path));
      for (final d in dirs(r).where((d) => looksLikeSx(p.basename(d.path)) && !d.path.toLowerCase().endsWith('.app'))) {
        c.addAll(dirs(d.path).where(isApp).map((x) => x.path));
      }
    }
    if (c.isEmpty) {
      try {
        final r = Process.runSync('mdfind', ["kMDItemFSName == 'TheLightingController.app'"]);
        c.addAll('${r.stdout}'.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('/Volumes/') && Directory(l).existsSync()));
      } on ProcessException {
        // no Spotlight
      }
    }
    return pickMacApp(c, (app) => File(p.join(p.dirname(app), 'efk_hardware.dylib')).existsSync());
  }

  @override
  Future<String?> launch() async {
    final a = findApp();
    if (a == null) return 'ShowXpress was not found in Applications.';
    await Process.run('open', [a]);
    return null;
  }

  /// Tells each ShowXpress app to quit. osascript is not waited for: it can
  /// sit for minutes while ShowXpress asks the user about saving.
  @override
  Future<void> askToClose(List<SxProc> procs) async {
    var apps = {for (final x in procs) ?macAppOf(x.exe)};
    if (apps.isEmpty) apps = {?findApp()};
    for (final ap in apps) {
      await Process.start('osascript', ['-e', 'tell application "$ap" to quit'], mode: ProcessStartMode.detached);
    }
  }
}
