// Recognising ShowXpress among the running programs, finding its app on a
// Mac, and recognising its "Do you really want to quit?" box on Windows.
// Pure functions, so they are tested on any machine. The platform code that
// feeds them lives in `desktop_sx_app.dart` and `windows_desk.dart`.

/// One ShowXpress process: its id and, on a Mac, its program's full path.
typedef SxProc = ({int pid, String exe});

final _winName = RegExp('^(TheLightingContr|ShowXpress)', caseSensitive: false);
final _notSx = RegExp('Helper|sxh|setup|unins|updat', caseSensitive: false);

/// True for ShowXpress's own program on Windows, given the process name
/// without `.exe` (`TheLightingController`). Its installer, updater and
/// helpers don't count. Port of the Windows half of `Get-SxProcess`.
bool isSxProcessName(String name) => _winName.hasMatch(name) && !_notSx.hasMatch(name);

/// A Windows program file name (`TheLightingController.exe`) as .NET's
/// `ProcessName` gives it: without the extension.
String processNameOf(String exeFile) => exeFile.toLowerCase().endsWith('.exe') ? exeFile.substring(0, exeFile.length - 4) : exeFile;

final _macExe = RegExp(r'\.app/Contents/MacOS/(TheLightingController|ShowXpress)[^/]*$', caseSensitive: false);
final _macNot = RegExp('Helper|sxh', caseSensitive: false);

/// True for ShowXpress's main program on a Mac, given the full path of a
/// running program.
///
/// Only the main program inside the .app counts. A leftover part of
/// ShowXpress once made SX Studio say "open" after it had closed, and SX
/// Studio's own old Mac app ("SXHelper") must never match. Port of the Mac
/// half of `Get-SxProcess`, which read these paths from `ps`.
bool isMacSxExe(String exe) => _macExe.hasMatch(exe.trim()) && !_macNot.hasMatch(exe.trim());

/// The `.app` folder a Mac program runs from, or null.
String? macAppOf(String exe) => RegExp(r'^(.+?\.app)/').firstMatch(exe)?[1];

final _macAppName = RegExp('ShowXpress|LightingController', caseSensitive: false);

/// True for a folder name that looks like ShowXpress (an app or the folder the download unpacks to).
bool looksLikeSx(String name) => _macAppName.hasMatch(name);

/// Picks the ShowXpress app to open from [candidates] (full paths of
/// `.app` folders). One with ShowXpress's interface driver
/// (`efk_hardware.dylib`) next to it wins, otherwise the first.
/// Port of the end of `Find-SxMacApp`.
String? pickMacApp(List<String> candidates, bool Function(String app) hasDriver) {
  final withDriver = candidates.where(hasDriver);
  return withDriver.firstOrNull ?? candidates.firstOrNull;
}

/// ShowXpress's quit question in every language it has: the default
/// English one plus each `Txt_quit=` line of its language files.
/// Port of the start of `sx_quit.ps1`.
Set<String> quitTexts(Iterable<String> languageFileLines) {
  final rx = RegExp(r'^Txt_quit=(.+)$', caseSensitive: false);
  return {
    normDialogText('Do you really want to quit?'),
    for (final l in languageFileLines)
      if (rx.firstMatch(l) case final m?)
        if (m[1]!.trim().isNotEmpty) normDialogText(m[1]!.trim()),
  };
}

/// Dialog text as compared: no `&` (keyboard marks), single spaces, lower case.
String normDialogText(String s) => s.replaceAll('&', '').split(RegExp(r'[ \r\n\t]')).where((w) => w.isNotEmpty).join(' ').toLowerCase();

/// One control in a Windows message box.
typedef DialogControl = ({String cls, String text, int id});

/// Which control of a message box to "click" so ShowXpress quits, or null
/// to leave the box alone.
///
/// Only a box whose one line of text is exactly ShowXpress's quit question
/// (nothing about saving) with a Yes (or OK) button is answered. "Do you want
/// to save ...?" and every other question stay with the user.
/// Port of `SxQuit.Answer` in `sx_quit.ps1`.
int? quitDialogYes(List<DialogControl> controls, Set<String> quit) {
  final texts = <String>[];
  int? yes;
  var buttons = 0;
  for (final (i, c) in controls.indexed) {
    if (c.cls == 'Static' && c.text.trim().isNotEmpty) texts.add(c.text);
    if (c.cls == 'Button') {
      buttons++;
      final n = normDialogText(c.text);
      if (c.id == 6 || (c.id == 1 && (n == 'ok' || n == 'yes'))) yes = i;
    }
  }
  final all = normDialogText(texts.join(' '));
  if (texts.length == 1 && quit.contains(all) && !all.contains('save') && yes != null && buttons <= 3) return yes;
  return null;
}
