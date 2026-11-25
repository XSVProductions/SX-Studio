import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// The desktop runner's channel (`windows/runner/flutter_window.cpp`,
/// `macos/Runner/MainFlutterWindow.swift`). The runner calls `closed` when
/// the window is closed (it only hides it) and `opened` when the app is
/// started again. Dart calls `showOther(pid)` to bring up the window of the
/// copy already running. There is no such channel in a browser.
const windowChannel = MethodChannel('sx/window');

/// Asks the runner to show the window of the SX Studio running as [pid].
/// False when there is no such window.
Future<bool> showOtherCopy(int pid) async {
  try {
    return await windowChannel.invokeMethod<bool>('showOther', pid) ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Why the app couldn't start, in the old app's words.
class BootFailure implements Exception {
  const BootFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Watches the laptop window's calls for live output it turned on itself and
/// hasn't turned off, the old page's `LV||CP||SEP||MVP||LKP`. Closing the
/// window stops it then, as the old page's `beforeunload` did.
class LiveWatch extends http.BaseClient {
  LiveWatch(this._inner);

  final http.Client _inner;

  /// True between this window's `/api/live/start` and `/api/live/stop`.
  static var mine = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method == 'POST') {
      switch (request.url.path) {
        case '/api/live/start':
          mine = true;
        case '/api/live/stop':
          mine = false;
      }
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
