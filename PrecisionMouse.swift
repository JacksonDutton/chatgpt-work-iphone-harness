// PrecisionMouse — a continuous hold/drag controller for macOS.
// Build: swiftc PrecisionMouse.swift -o PrecisionMouse
// Check: ./PrecisionMouse status
// Test event sequence without input: ./PrecisionMouse drag X Y X2 Y2 HOLD_MS MOVE_MS SETTLE_MS --dry-run
// Execute the same command without --dry-run. Coordinates are global screen POINTS,
// measured from the top-left of the primary display, not screenshot pixels.
// Holds the button continuously through mouseDown, pause, dragged events, pause,
// and mouseUp. Move duration is sampled at ~60 Hz. Ctrl-C releases the button.
// Requires existing macOS Accessibility permission. Never requests it silently.
import AppKit
import ApplicationServices
import Darwin

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}
func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
let args = Array(CommandLine.arguments.dropFirst())
final class MousePanel: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var fields: [NSTextField] = []
    var result: NSTextField!
    var bridgeTimer: Timer?
    var bridgeBusy = false
    var lastRequest = ""
    var bridgeRoot: URL { Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("mouse-bridge", isDirectory: true) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 570, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Precision Mouse"
        let view = window.contentView!
        func label(_ text: String, _ y: Double) {
            let item = NSTextField(wrappingLabelWithString: text)
            item.frame = NSRect(x: 24, y: y, width: 520, height: 44)
            view.addSubview(item)
        }
        label("Continuous press → hold → drag → release. Coordinates are global screen points, not screenshot pixels.", 396)
        let names = ["Start X", "Start Y", "End X", "End Y", "Hold ms", "Move ms", "Settle ms"]
        let defaults = ["0", "0", "0", "0", "400", "100", "500"]
        for i in 0..<7 {
            let row = i / 4, col = i % 4
            let x = 24 + col * 132, y = 334 - row * 75
            let name = NSTextField(labelWithString: names[i])
            name.frame = NSRect(x: x, y: y, width: 120, height: 20)
            view.addSubview(name)
            let field = NSTextField(string: defaults[i])
            field.frame = NSRect(x: x, y: y - 30, width: 110, height: 26)
            view.addSubview(field); fields.append(field)
        }
        let grant = NSButton(title: "Request Accessibility Access", target: self, action: #selector(requestAccess))
        grant.frame = NSRect(x: 24, y: 170, width: 250, height: 34)
        view.addSubview(grant)
        let run = NSButton(title: "Run Held Drag", target: self, action: #selector(runDrag))
        run.frame = NSRect(x: 294, y: 170, width: 240, height: 34)
        view.addSubview(run)
        let locate = NSButton(title: "Read Mirroring Window", target: self, action: #selector(readWindow))
        locate.frame = NSRect(x: 24, y: 128, width: 250, height: 32)
        view.addSubview(locate)
        result = NSTextField(wrappingLabelWithString: "No input sent. Grant Accessibility access to Precision Mouse, then reopen it. Run Held Drag focuses iPhone Mirroring and starts after one second.")
        result.frame = NSRect(x: 24, y: 12, width: 520, height: 108)
        view.addSubview(result)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Precision Mouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? FileManager.default.createDirectory(at: bridgeRoot, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: bridgeRoot.appendingPathComponent("request.json")),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { lastRequest = old["id"] as? String ?? "" }
        bridgeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollBridge() }
    }
    func reply(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: bridgeRoot.appendingPathComponent("response.json"), options: .atomic)
            result.stringValue = String(data: data, encoding: .utf8) ?? ""
        }
    }
    func mirrorGeometry() -> (NSRunningApplication, CGRect)? {
        guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.ScreenContinuity" }) else { return nil }
        var value: CFTypeRef?
        let element = AXUIElementCreateApplication(target.processIdentifier)
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement],
              let win = list.first(where: { window in
                  var identifier: CFTypeRef?
                  AXUIElementCopyAttributeValue(window, kAXIdentifierAttribute as CFString, &identifier)
                  return identifier as? String == "iphone-mirroring-main"
              }) else { return nil }
        var pv: CFTypeRef?, sv: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pv)
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sv)
        guard let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; var s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
        guard s.width > 0, s.height > 0 else { return nil }
        return (target, CGRect(origin: p, size: s))
    }
    func pollBridge() {
        guard !bridgeBusy,
              let data = try? Data(contentsOf: bridgeRoot.appendingPathComponent("request.json")),
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = req["id"] as? String, id != lastRequest else { return }
        lastRequest = id
        guard let timestamp = req["created"] as? Double, abs(Date().timeIntervalSince1970 - timestamp) < 60 else {
            reply(["id": id, "state": "error", "error": "Expired request"]); return
        }
        let trusted = AXIsProcessTrusted(), posting = CGPreflightPostEventAccess()
        guard let (target, frame) = mirrorGeometry() else {
            reply(["id": id, "state": "error", "error": "Cannot read Mirroring window", "trusted": trusted, "posting": posting]); return
        }
        let action = req["action"] as? String ?? ""
        if action == "status" {
            let point = CGEvent(source: nil)?.location ?? .zero
            reply(["id": id, "state": "done", "trusted": trusted, "posting": posting,
                   "frame": [frame.minX,frame.minY,frame.width,frame.height], "pointer": [point.x,point.y],
                   "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""]); return
        }
        guard trusted && posting else { reply(["id": id,"state":"error","error":"Permission required"]); return }
        guard ["click", "drag"].contains(action) else { reply(["id":id,"state":"error","error":"Unsupported action"]); return }
        func position(_ key: String) -> CGPoint? {
            guard let xy = req[key] as? [Double], xy.count == 2,
                  xy.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return nil }
            return CGPoint(x: frame.minX + xy[0] * frame.width, y: frame.minY + xy[1] * frame.height)
        }
        guard let start = position("from"), let end = action == "drag" ? position("to") : start else {
            reply(["id":id,"state":"error","error":"Expected window-relative fractions in [0,1]"]); return
        }
        let hold = req["hold"] as? Double ?? (action == "drag" ? 1000 : 100)
        let move = req["move"] as? Double ?? 1200
        let settle = req["settle"] as? Double ?? 700
        let requestedSteps = req["steps"] as? Int ?? 0
        guard hold.isFinite && move.isFinite && settle.isFinite,
              (0...5000).contains(hold), (100...5000).contains(move), (0...3000).contains(settle),
              (0...300).contains(requestedSteps) else {
            reply(["id":id,"state":"error","error":"Invalid timing or drag steps"]); return
        }
        bridgeBusy = true
        reply(["id":id,"state":"running"])
        NSApp.hide(nil)
        target.activate(options: [])
        let root = bridgeRoot
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                self.bridgeBusy = false; self.reply(["id":id,"state":"error","error":"Mirroring did not become frontmost"]); return
            }
            DispatchQueue.global().async {
                let source = CGEventSource(stateID: .combinedSessionState)
                source?.localEventsSuppressionInterval = 0
                var previous = start
                var cancelled = false
                func send(_ type: CGEventType, _ point: CGPoint) {
                    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
                    event.setIntegerValueField(.mouseEventClickState, value: 1)
                    event.flags = .maskNonCoalesced
                    if type == .leftMouseDragged {
                        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x.rounded() - previous.x.rounded()))
                        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y.rounded() - previous.y.rounded()))
                    }
                    event.post(tap: .cgSessionEventTap)
                    previous = point
                }
                func pause(_ milliseconds: Double) {
                    let until = Date().addingTimeInterval(milliseconds / 1000)
                    while Date() < until {
                        if FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel").path)
                            || NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                            cancelled = true; return
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
                CGWarpMouseCursorPosition(start)
                send(.mouseMoved, start); pause(150)
                do {
                    if !cancelled { send(.leftMouseDown, start); pause(hold) }
                    if action == "drag" && !cancelled {
                        let steps = requestedSteps > 0 ? requestedSteps : max(2, Int(move / 16.667))
                        for i in 1...steps {
                            if cancelled { break }
                            let t = Double(i) / Double(steps)
                            send(.leftMouseDragged, CGPoint(x:start.x+(end.x-start.x)*t, y:start.y+(end.y-start.y)*t))
                            pause(move / Double(steps))
                        }
                        pause(settle)
                    }
                    send(.leftMouseUp, previous)
                }
                let cursor = CGEvent(source: nil)?.location ?? .zero
                let finalCancelled = cancelled
                DispatchQueue.main.async {
                    self.bridgeBusy = false
                    self.reply(["id":id,"state":finalCancelled ? "cancelled" : "done", "action":action,
                                "start":[start.x,start.y],"end":[end.x,end.y],"pointerAfter":[cursor.x,cursor.y]])
                }
            }
        }
    }
    @objc func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        result.stringValue = AXIsProcessTrustedWithOptions(options)
            ? "Accessibility is enabled. Ready to test."
            : "Enable Precision Mouse in System Settings → Privacy & Security → Accessibility, then reopen this app."
    }
    @objc func readWindow() {
        guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.ScreenContinuity" }) else {
            result.stringValue = "Open iPhone Mirroring first."; return
        }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement], let window = list.first else {
            result.stringValue = "Cannot read Mirroring window. Accessibility trusted: \(AXIsProcessTrusted()). Reopen after granting access."; return
        }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        guard let positionValue, let sizeValue else { result.stringValue = "No window geometry"; return }
        var point = CGPoint.zero; var size = CGSize.zero
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return }
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        result.stringValue = "Mirroring window in screen points: x=\(point.x), y=\(point.y), width=\(size.width), height=\(size.height). Accessibility=\(AXIsProcessTrusted()), event posting=\(CGPreflightPostEventAccess())."
    }
    @objc func runDrag() {
        guard !bridgeBusy else { result.stringValue = "A gesture is already running."; return }
        guard let (_, frame) = mirrorGeometry() else {
            result.stringValue = "Open the main iPhone Mirroring window first."; return
        }
        let values = fields.compactMap { Double($0.stringValue) }
        guard values.count == 7, values.allSatisfy({ $0.isFinite }) else {
            result.stringValue = "Enter seven finite numbers."; return
        }
        let request: [String: Any] = [
            "id": UUID().uuidString, "created": Date().timeIntervalSince1970,
            "action": "drag",
            "from": [(values[0] - frame.minX) / frame.width, (values[1] - frame.minY) / frame.height],
            "to": [(values[2] - frame.minX) / frame.width, (values[3] - frame.minY) / frame.height],
            "hold": values[4], "move": values[5], "settle": values[6], "steps": 1
        ]
        do {
            try? FileManager.default.removeItem(at: bridgeRoot.appendingPathComponent("cancel"))
            let data = try JSONSerialization.data(withJSONObject: request)
            try data.write(to: bridgeRoot.appendingPathComponent("request.json"), options: .atomic)
            result.stringValue = "Gesture queued for iPhone Mirroring."
        } catch { result.stringValue = error.localizedDescription }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
if args.isEmpty {
    let app = NSApplication.shared
    let delegate = MousePanel()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
    exit(0)
}
let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else {
        fail("Cannot allocate mouse event")
    }
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}
func releaseOnSignal(_ number: Int32) {
    let location = CGEvent(source: nil)?.location ?? .zero
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
    Darwin.exit(128 + number)
}
guard let command = args.first else {
    fail("Usage: PrecisionMouse status | drag X Y X2 Y2 HOLD_MS MOVE_MS SETTLE_MS [--dry-run]")
}
if command == "status" {
    let location = CGEvent(source: nil)?.location ?? .zero
    emit(["accessibilityTrusted": AXIsProcessTrusted(),
          "canPostEvents": CGPreflightPostEventAccess(),
          "pointer": [location.x, location.y]])
    exit(0)
}
guard command == "drag", args.count == 8 || (args.count == 9 && args[8] == "--dry-run") else {
    fail("Expected: drag X Y X2 Y2 HOLD_MS MOVE_MS SETTLE_MS [--dry-run]")
}
let numbers = args[1...7].compactMap(Double.init)
guard numbers.count == 7, numbers.allSatisfy({ $0.isFinite }) else { fail("Expected finite numbers") }
let start = CGPoint(x: numbers[0], y: numbers[1])
let end = CGPoint(x: numbers[2], y: numbers[3])
let hold = numbers[4], duration = numbers[5], settle = numbers[6]
guard (0...5000).contains(hold), (100...5000).contains(duration), (0...3000).contains(settle) else {
    fail("Hold must be 0–5000 ms, move 100–5000 ms, settle 0–3000 ms")
}
var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &displays, &count)
func onDisplay(_ point: CGPoint) -> Bool { displays.contains { CGDisplayBounds($0).contains(point) } }
let steps = max(2, Int(ceil(duration / 16.667)))
let points = (1...steps).map { i -> CGPoint in
    let t = Double(i) / Double(steps)
    let eased = t * t * (3 - 2 * t)
    return CGPoint(x: start.x + (end.x - start.x) * eased,
                   y: start.y + (end.y - start.y) * eased)
}
let dryRun = args.last == "--dry-run"
let pathOnDisplay = onDisplay(start) && points.allSatisfy(onDisplay)
emit(["dryRun": dryRun, "start": [start.x,start.y], "end": [end.x,end.y],
      "holdMs": hold, "moveMs": duration, "settleMs": settle,
      "pathOnActiveDisplay": pathOnDisplay,
      "dragEvents": steps, "sequence": ["mouseDown", "hold", "leftMouseDragged", "settle", "mouseUp"]])
if dryRun { exit(0) }
guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
    fail("Accessibility/event-posting permission is not available. No input sent.")
}
guard pathOnDisplay else { fail("Drag path is outside active displays. No input sent.") }
signal(SIGINT, releaseOnSignal)
signal(SIGTERM, releaseOnSignal)
post(.mouseMoved, start)
Thread.sleep(forTimeInterval: 0.15)
post(.leftMouseDown, start)
Thread.sleep(forTimeInterval: hold / 1000)
for point in points {
    post(.leftMouseDragged, point)
    Thread.sleep(forTimeInterval: duration / 1000 / Double(steps))
}
Thread.sleep(forTimeInterval: settle / 1000)
post(.leftMouseUp, end)
emit(["inputSent": true])
