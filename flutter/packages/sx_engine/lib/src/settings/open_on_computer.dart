import 'dart:io';

/// Opens a folder, file or web page on the laptop, the way a double click
/// would. Tests put their own in with `Engine.provide<Opener>`.
abstract class Opener {
  Future<void> open(String target);
}

/// The real one: Explorer, Finder, or the default browser.
class LaptopOpener implements Opener {
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
}
