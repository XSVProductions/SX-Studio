import 'dart:io';

/// Opens a folder, file or web page on the laptop, the way a double click
/// would. Tests put their own in with `Engine.provide<Opener>`.
abstract class Opener {
  Future<void> open(String target);
}

/// Shows one file selected in Explorer or Finder. Tests put their own in
/// with `Engine.provide<Revealer>`.
abstract class Revealer {
  Future<void> reveal(String file);
}

/// The last settings file Export settings saved, for "Show the file". Empty
/// until the first export. The old server's `$script:cfgExport`.
class LastExport {
  String path = '';
}

/// The real one: Explorer, Finder, or the default browser.
class LaptopOpener implements Opener, Revealer {
  const LaptopOpener();

  @override
  Future<void> open(String target) async {
    final url = target.startsWith('https://');
    final (exe, args) = Platform.isWindows
        ? url
              ? ('rundll32', ['url.dll,FileProtocolHandler', target])
              : target.toLowerCase().endsWith('.bat')
              ? ('cmd', ['/c', target])
              : ('explorer.exe', [target])
        : Platform.isMacOS
        ? ('open', [target])
        : ('xdg-open', [target]);
    await Process.start(exe, args, mode: ProcessStartMode.detached);
  }

  /// `explorer.exe /select,"<file>"` on Windows, `open -R` on the Mac, and
  /// the folder on Linux, which has no common way to select a file.
  @override
  Future<void> reveal(String file) async {
    final (exe, args) = Platform.isWindows
        ? ('explorer.exe', ['/select,', file])
        : Platform.isMacOS
        ? ('open', ['-R', file])
        : ('xdg-open', [File(file).parent.path]);
    await Process.start(exe, args, mode: ProcessStartMode.detached);
  }
}
