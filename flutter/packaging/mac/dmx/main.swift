// sxh_dmx - the Helper's DMX output for LIVE AIM on the Mac. Same job and stdin protocol as src/dmx_out.ps1 (Windows):
//   first line printed: "OK <interface name>" or "ERR <why>"; then one line per change from stdin:
//   z (all 0) | b:ch:v (raw byte) | p:c:f:v (16-bit, glides) | s:c:f:v (16-bit, jumps) | k (keep-alive) | q (quit)
//   No command for 30 s or stdin closed -> all channels 0, interface closed, exit.
// A frame goes out as soon as a line arrives (at most 50 a second), so SX Studio's own 40 frames a second reach the
// lights as they were made. With nothing new the frame is sent again every 40 ms, or every 25 ms while a glide runs.
// It uses ShowXpress's own Mac driver (efk_hardware.dylib next to TheLightingController.app). That driver has to be
// loaded and used on a program's main thread, which PowerShell can't do - hence this small tool. The driver is Intel
// or Apple Silicon depending on the ShowXpress download, so this tool is built for both and SX Studio runs the kind
// that matches (helper_dmx.dart).
//   sxh_dmx --dir <ShowXpress folder> [--probe]     --probe = report what it finds and exit
import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
func say(_ s: String) { print(s); fflush(stdout) }

var dir = ""
var probe = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    if a == "--dir", let d = args.next() { dir = d } else if a == "--probe" { probe = true }
}

typealias FnI = @convention(c) () -> Int
typealias FnP = @convention(c) () -> UnsafeRawPointer?
typealias FnS = @convention(c) (UnsafeMutablePointer<UInt8>) -> Int

func loadedEFK() -> String {
    var r: [String] = []
    for i in 0..<_dyld_image_count() {
        if let c = _dyld_get_image_name(i) { let s = String(cString: c); if s.lowercased().contains("efk") { r.append(s) } }
    }
    return r.joined(separator: " ; ")
}

let hwPath = (dir as NSString).appendingPathComponent("efk_hardware.dylib")
if !FileManager.default.fileExists(atPath: hwPath) {
    say("ERR ShowXpress's interface driver (efk_hardware.dylib) was not found next to ShowXpress (\(dir)).")
    exit(0)
}
// No Dock icon or menu bar for this helper. This has to come before the driver loads: the driver starts an
// NSApplication as it loads, and from inside SX Studio.app that never returned (macOS 26, seen with both drivers' chips).
NSApplication.shared.setActivationPolicy(.prohibited)
_ = FileManager.default.changeCurrentDirectoryPath(dir)   // the driver opens efk_usb.dylib by its bare name
_ = dlopen((dir as NSString).appendingPathComponent("efk_usb.dylib"), RTLD_NOW | RTLD_GLOBAL)
guard let lib = dlopen(hwPath, RTLD_NOW | RTLD_GLOBAL) else {
    let e = dlerror().map { String(cString: $0) } ?? ""
    say("ERR ShowXpress's interface driver didn't load: \(e)")
    exit(0)
}

func sym<T>(_ n: String, _ t: T.Type) -> T {
    guard let p = dlsym(lib, n) else { say("ERR ShowXpress's interface driver has no \(n)."); exit(0) }
    return unsafeBitCast(p, to: t)
}
let efkCheck = sym("EFK_check_hardware", FnI.self)
let efkOpen = sym("EFK_open", FnI.self)
let efkClose = sym("EFK_close", FnI.self)
let efkStream = sym("EFK_stream_mode", FnI.self)
let efkNames = sym("EFK_get_name_of_interfaces", FnP.self)
let efkSend = sym("EFK_send_dmx", FnS.self)

// the driver's text: UTF-16 (PureBasic) - or a plain C string, just in case
func driverText(_ p: UnsafeRawPointer?) -> String {
    guard let p = p else { return "" }
    let b = p.assumingMemoryBound(to: UInt8.self)
    if b[0] != 0 && b[1] == 0 {
        let u = p.assumingMemoryBound(to: UInt16.self)
        var n = 0
        while n < 4096 && u[n] != 0 { n += 1 }
        return String(decoding: UnsafeBufferPointer(start: u, count: n), as: UTF16.self)
    }
    return String(cString: b)
}

_ = efkCheck()
let names = driverText(efkNames())
let iface = names.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
if iface.isEmpty || names.hasPrefix("err") {
    say("ERR none")
    if probe { say("loaded: \(loadedEFK())") }
    exit(0)
}
if probe { say("OK \(iface.uppercased())"); say("loaded: \(loadedEFK())"); exit(0) }
_ = efkOpen()
_ = efkStream()
say("OK \(iface.uppercased())")

// ---- the frame, glides, commands (same as dmx_out.ps1)
let N = 512 * 16
final class Pair { var c = 0; var f = 0; var cur = 0.0; var tgt = 0.0 }
var frame = [UInt8](repeating: 0, count: N)
var pairs: [Int: Pair] = [:]
let lock = NSLock()
var running = true
var lastCmd = Date()

// ---- waiting. macOS may add 10 ms to an ordinary wait (usleep, a semaphore, a condition): a 25 ms sleep here took
// 33 ms, and 160 ms once the program ran at background priority, which is 6 frames a second. A kqueue timer marked
// critical is on time in both cases (25.02 ms measured). The same queue wakes the main loop when a line arrives.
let kq = kqueue()
let lineEvent: UInt = 1
let timerEvent: UInt = 2
func change(_ ident: UInt, _ filter: Int32, _ flags: Int32, _ fflags: Int32 = 0, _ data: Int = 0) {
    var e = kevent(ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: UInt32(fflags), data: data, udata: nil)
    _ = kevent(kq, &e, 1, nil, 0, nil)
}
change(lineEvent, EVFILT_USER, EV_ADD | EV_CLEAR)

// called by the reader for every line: the main loop sends the new frame at once
func lineArrived() { change(lineEvent, EVFILT_USER, 0, NOTE_TRIGGER) }

// Waits `us` microseconds. With `orLine` it returns early, and true, when a line arrives.
func wait(us: Int, orLine: Bool) -> Bool {
    change(timerEvent, EVFILT_TIMER, EV_ADD | EV_ONESHOT, NOTE_USECONDS | NOTE_CRITICAL, max(us, 1))
    var got = kevent()
    while true {
        if kevent(kq, nil, 0, &got, 1, nil) != 1 { continue }
        if got.filter == Int16(EVFILT_TIMER) { return false }
        if orLine { change(timerEvent, EVFILT_TIMER, EV_DELETE); return true }
    }
}

func num(_ s: Substring, _ mx: Int) -> Int? {
    guard let v = Int(s), v >= 0, v <= mx else { return nil }
    return v
}

func apply(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    lastCmd = Date()
    for t in line.split(separator: " ") {
        if t == "z" { for i in 0..<N { frame[i] = 0 }; pairs.removeAll(); continue }
        if t == "k" { continue }
        if t == "q" { running = false; continue }
        let a = t.split(separator: ":", omittingEmptySubsequences: false)
        if a[0] == "b", a.count == 3, let ch = num(a[1], N), let v = num(a[2], 255), ch >= 1 { frame[ch - 1] = UInt8(v); continue }
        if a[0] == "p" || a[0] == "s", a.count == 4, let c1 = num(a[1], N), let f1 = num(a[2], N), let v = num(a[3], 65535), c1 >= 1, f1 >= 1 {
            let c = c1 - 1
            let p: Pair
            if let e = pairs[c] { p = e } else { p = Pair(); p.c = c; p.cur = Double(v); pairs[c] = p }
            p.f = f1 - 1
            p.tgt = Double(v)
            if a[0] == "s" { p.cur = Double(v) }
        }
    }
}

let reader = Thread {
    while let line = readLine() {
        apply(line)
        lineArrived()
        lock.lock(); let r = running; lock.unlock()
        if !r { break }
    }
    lock.lock(); running = false; lock.unlock()
    lineArrived()
}
reader.start()

func sendFrame(_ b: [UInt8]) {
    var o = b
    o.withUnsafeMutableBufferPointer { _ = efkSend($0.baseAddress!) }
}

while true {
    lock.lock()
    if !running { lock.unlock(); break }
    for p in pairs.values {
        let d = p.tgt - p.cur
        if abs(d) < 3 { p.cur = p.tgt } else { p.cur += d * 0.45 }
        let v = Int(p.cur.rounded())
        frame[p.c] = UInt8((v >> 8) & 255)
        frame[p.f] = UInt8(v & 255)
    }
    let out = frame
    let gliding = pairs.values.contains { $0.cur != $0.tgt }
    if Date().timeIntervalSince(lastCmd) > 30 { running = false }
    lock.unlock()
    sendFrame(out)
    let sent = DispatchTime.now().uptimeNanoseconds
    // keep the main run loop turning (the driver may rely on it)
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, false)
    // the next frame: when a line arrives, but not within 20 ms of this one. Lines that came together make one frame.
    if wait(us: gliding ? 25000 : 40000, orLine: true) {
        let since = Int((DispatchTime.now().uptimeNanoseconds - sent) / 1000)
        if since < 20000 { _ = wait(us: 20000 - since, orLine: false) }
    }
}

// lights out, then let ShowXpress have the interface again
let zero = [UInt8](repeating: 0, count: N)
for _ in 0..<3 { sendFrame(zero); _ = wait(us: 30000, orLine: false) }
_ = efkClose()
exit(0)
