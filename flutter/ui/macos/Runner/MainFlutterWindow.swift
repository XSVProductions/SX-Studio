import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  /// "sx/window": tells Dart the window was closed or opened again (main.dart).
  var channel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    channel = FlutterMethodChannel(name: "sx/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.delegate = self

    super.awakeFromNib()
  }

  /// Closing the window only hides it, as closing the old app's browser window
  /// left its server running: the lights, the player, the Auto Show and the
  /// phones carry on, and the app quits by itself later (lifetime.dart).
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    orderOut(nil)
    channel?.invokeMethod("closed", arguments: nil)
    return false
  }

  /// Opened again from the Dock or Finder: show the window.
  func reopen() {
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    channel?.invokeMethod("opened", arguments: nil)
  }
}
