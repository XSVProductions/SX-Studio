import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Held for as long as the app runs. Without it macOS naps the app about a
  // minute after its window is hidden or covered, for example with ShowXpress
  // in front: the engine then runs at background priority (five times slower,
  // measured) and its timers fire late, so phones, the Auto Show and the
  // lights lag. The old app's server was a plain background program, which
  // macOS never naps. The Mac may still go to sleep when nobody uses it.
  let awake = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
    reason: "The lights, the Auto Show and phones keep running while the window is hidden")

  // The app outlives its window, as the old server did (MainFlutterWindow).
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Opening the app again (it is one copy only on the Mac) shows its window.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window = mainFlutterWindow as? MainFlutterWindow {
      window.reopen()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
