// SX Helper for Mac: a real app (Dock icon, own window, Cmd+Q) around the Helper's local server.
// launch.sh starts the PowerShell server; this window shows its page. The server writes its address to
// $TMPDIR/showxpress_helper_gui.json ({url, pid, ver}); only a server of this same version is used.
import Cocoa
import WebKit

let tmpDir = NSTemporaryDirectory()
let infoPath = (tmpDir as NSString).appendingPathComponent("showxpress_helper_gui.json")
let updatingFlag = (tmpDir as NSString).appendingPathComponent("sxh_updating")
let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("AwaazTools/showxpress_helper_app.log")

func logLine(_ s: String) {
    let line = "\(Date()) \(s)\n"
    guard let d = line.data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(d); h.closeFile() }
    else { try? d.write(to: URL(fileURLWithPath: logPath)) }
}

final class Flag: @unchecked Sendable { var on = false }

func apiURL(_ base: URL, _ path: String) -> URL? {
    guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
    c.path = path
    c.fragment = nil
    return c.url
}

// does the server at this address answer with our token?
func pingOK(_ base: URL) -> Bool {
    guard let u = apiURL(base, "/api/sx") else { return false }
    let f = Flag()
    let sem = DispatchSemaphore(value: 0)
    let req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        f.on = (resp as? HTTPURLResponse)?.statusCode == 200
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 5)
    return f.on
}

// the running server of this version, if there is one
func findServer() -> (url: URL, pid: pid_t)? {
    guard let d = FileManager.default.contents(atPath: infoPath),
          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let s = j["url"] as? String, let url = URL(string: s),
          (j["ver"] as? String) == appVersion else { return nil }
    let pid = (j["pid"] as? NSNumber)?.int32Value ?? 0
    return pingOK(url) ? (url: url, pid: pid) : nil
}

func runLauncher() -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [(Bundle.main.resourcePath ?? "") + "/launch.sh"]
    var env = ProcessInfo.processInfo.environment
    env["TMPDIR"] = tmpDir   // the server must write its address where this app looks
    p.environment = env
    do { try p.run() } catch { return 1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// set by the server just before it stops for an update (the installer then opens the new version)
func updating() -> Bool {
    guard let a = try? FileManager.default.attributesOfItem(atPath: updatingFlag),
          let d = a[.modificationDate] as? Date else { return false }
    return Date().timeIntervalSince(d) < 900
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var serverURL: URL?
    var serverPid: pid_t = 0
    var starting = false
    var timer: Timer?
    var ticks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 880), configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        web.uiDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "SX Helper"
        window.minSize = NSSize(width: 640, height: 480)
        window.backgroundColor = NSColor(red: 0.055, green: 0.063, blue: 0.078, alpha: 1)
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("ShowXpressHelperWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        showMessage("Starting SX Helper…")
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { return true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func showMessage(_ text: String) {
        let safe = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        web.loadHTMLString("<html><body style=\"margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#0e1014;color:#c7cdd8;font:15px -apple-system,sans-serif;text-align:center;white-space:pre-line;padding:0 40px\">\(safe)</body></html>", baseURL: nil)
    }

    func startServer() {
        if starting { return }
        starting = true
        timer?.invalidate()
        timer = nil
        DispatchQueue.global(qos: .userInitiated).async {
            if findServer() == nil {
                let code = runLauncher()
                if code != 0 {
                    logLine("launch.sh exit \(code)")
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return
                }
            }
            let end = Date().addingTimeInterval(120)
            while Date() < end {
                if let s = findServer() {
                    DispatchQueue.main.async { self.loaded(s.url, s.pid) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.4)
            }
            logLine("server did not answer")
            DispatchQueue.main.async {
                self.starting = false
                self.showMessage("SX Helper didn't start.\nDetails: ~/AwaazTools/showxpress_helper_error.log\n\nClose this window and open SX Helper again.")
            }
        }
    }

    func loaded(_ url: URL, _ pid: pid_t) {
        starting = false
        serverURL = url
        serverPid = pid
        logLine("loaded \(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? 0) pid \(pid) version \(appVersion)")
        web.load(URLRequest(url: url))
        ticks = 0
        timer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    // every 2 s: did the server stop? (update -> quit, the installer opens the new version; otherwise start it again)
    @objc func tick() {
        ticks += 1
        if serverPid > 0 && kill(serverPid, 0) != 0 && errno == ESRCH {
            timer?.invalidate()
            timer = nil
            if updating() { logLine("server stopped for an update - quitting"); NSApp.terminate(nil); return }
            logLine("server stopped - starting it again")
            showMessage("Starting SX Helper again…")
            startServer()
            return
        }
        // keep the server from quitting for being idle while this window is open (the page may be throttled)
        if ticks % 30 == 0, let b = serverURL, let u = apiURL(b, "/api/sx") { URLSession.shared.dataTask(with: u).resume() }
    }

    // links to other sites open in the normal browser
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, let s = u.scheme, s == "http" || s == "https",
           u.host != "localhost" && u.host != "127.0.0.1" {
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { NSWorkspace.shared.open(u) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "SX Helper"
        a.informativeText = message
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = "SX Helper"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    @objc func reloadPage(_ sender: Any?) { web.reload() }

    func buildMenu() {
        let bar = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            bar.addItem(item)
            let m = NSMenu(title: title)
            item.submenu = m
            return m
        }
        let appMenu = sub("SX Helper")
        appMenu.addItem(withTitle: "About SX Helper", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide SX Helper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit SX Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = sub("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = sub("View")
        let reload = view.addItem(withTitle: "Reload", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        reload.target = self

        let win = sub("Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = bar
        NSApp.windowsMenu = win
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
