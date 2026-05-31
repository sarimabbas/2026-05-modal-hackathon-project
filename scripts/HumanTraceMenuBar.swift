#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

let endpoint = (ProcessInfo.processInfo.environment["RAINDROP_LOCAL_DEBUGGER"] ?? "http://localhost:5899/v1/")
    .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
let userId = NSUserName()
let eventName = "human_computer_use"
let bridgeDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".raindrop", isDirectory: true)
let controlFile = bridgeDirectory.appendingPathComponent("human-trace-control.json")
let statusFile = bridgeDirectory.appendingPathComponent("human-trace-status.json")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = HumanTraceRecorder()
    private var browserControlTimer: Timer?
    private var lastBrowserControlNonce = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityPermission()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "HT"
        statusItem.button?.toolTip = "Human Trace Recorder"
        rebuildMenu()
        publishStatus()
        browserControlTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.handleBrowserControl()
            self?.publishStatus()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let recordToggleItem = NSMenuItem(title: recorder.isRecording ? "Stop Recording" : "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        recordToggleItem.target = self
        menu.addItem(recordToggleItem)

        let open = NSMenuItem(title: "Open Workshop", action: #selector(openWorkshop), keyEquivalent: "w")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let screenshotItem = NSMenuItem(title: recorder.screenshotsEnabled ? "Screenshots: On" : "Screenshots: Off", action: #selector(toggleScreenshots), keyEquivalent: "")
        screenshotItem.target = self
        screenshotItem.state = recorder.screenshotsEnabled ? .on : .off
        menu.addItem(screenshotItem)

        let typedTextItem = NSMenuItem(title: recorder.typedTextEnabled ? "Capture Typed Text: On" : "Capture Typed Text: Off", action: #selector(toggleTypedText), keyEquivalent: "")
        typedTextItem.target = self
        typedTextItem.state = recorder.typedTextEnabled ? .on : .off
        menu.addItem(typedTextItem)

        for seconds in [10, 30, 60] {
            let item = NSMenuItem(title: "Segment after \(seconds)s idle", action: #selector(setIdleThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = Int(recorder.segmentIdleSeconds) == seconds ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let privacy = NSMenuItem(title: "Privacy: no key text, no clipboard", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        let typed = recorder.typedTextEnabled ? " T" : ""
        statusItem.button?.title = recorder.isRecording ? "● HT\(typed)" : "HT\(typed)"
    }

    @objc private func toggleRecording() {
        setRecording(!recorder.isRecording, notifyUser: true)
    }

    @objc private func toggleScreenshots() {
        recorder.screenshotsEnabled.toggle()
        updateStatusTitle()
        notify(title: recorder.screenshotsEnabled ? "Screenshots enabled" : "Screenshots disabled", message: recorder.screenshotsEnabled ? "Click and typing bursts will attach screenshots." : "Future spans will not attach screenshots.")
        rebuildMenu()
        publishStatus()
    }

    @objc private func toggleTypedText() {
        recorder.typedTextEnabled.toggle()
        updateStatusTitle()
        notify(
            title: recorder.typedTextEnabled ? "Typed text capture enabled" : "Typed text capture disabled",
            message: recorder.typedTextEnabled ? "Typing spans will include text until you turn this off. Menu bar shows HT T." : "Typing spans will only include counts."
        )
        rebuildMenu()
        publishStatus()
    }

    @objc private func setIdleThreshold(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Int {
            recorder.segmentIdleSeconds = Double(seconds)
        }
        rebuildMenu()
        publishStatus()
    }

    @objc private func openWorkshop() {
        NSWorkspace.shared.open(URL(string: "http://localhost:5899/runs")!)
    }

    @objc private func quit() {
        recorder.stop()
        publishStatus()
        NSApp.terminate(nil)
    }

    private func setRecording(_ shouldRecord: Bool, notifyUser: Bool) {
        if shouldRecord {
            recorder.start()
            if notifyUser { notify(title: "Human Trace recording", message: "Capturing activity to local Workshop.") }
        } else {
            recorder.stop()
            if notifyUser { notify(title: "Human Trace stopped", message: "Finished the current Workshop run.") }
        }
        rebuildMenu()
        publishStatus()
    }

    private func handleBrowserControl() {
        guard let data = try? Data(contentsOf: controlFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let nonce = json["nonce"] as? String ?? ""
        guard !nonce.isEmpty, nonce != lastBrowserControlNonce else { return }
        lastBrowserControlNonce = nonce
        defer { try? FileManager.default.removeItem(at: controlFile) }

        let createdAt = json["createdAt"] as? Double ?? 0
        if createdAt > 0, Date().timeIntervalSince1970 * 1000 - createdAt > 30_000 { return }

        switch json["command"] as? String {
        case "start":
            setRecording(true, notifyUser: false)
        case "stop":
            setRecording(false, notifyUser: false)
        default:
            break
        }
    }

    private func publishStatus() {
        try? FileManager.default.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "recording": recorder.isRecording,
            "screenshotsEnabled": recorder.screenshotsEnabled,
            "typedTextEnabled": recorder.typedTextEnabled,
            "segmentIdleSeconds": recorder.segmentIdleSeconds,
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: statusFile, options: .atomic)
        }
    }
}

func notify(title: String, message: String) {
    let script = "display notification \(shellAppleScriptString(message)) with title \(shellAppleScriptString(title))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
}

func shellAppleScriptString(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

final class HumanTraceRecorder {
    var isRecording = false
    var screenshotsEnabled = true
    var typedTextEnabled = false
    var segmentIdleSeconds: Double = 30

    private let session = URLSession(configuration: .ephemeral)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timers: [Timer] = []

    private var currentApp = "unknown"
    private var currentBundle = "unknown"
    private var currentWindow = ""
    private var lastContextKey = ""
    private var eventSequence = 0
    private var keyCount = 0
    private var typedBuffer = ""
    private var keyCodes: [String: Int] = [:]
    private var keyModifiers: [String: Int] = [:]
    private var keyStartedAt: Date?
    private var keyLastAt: Date?
    private var mouseMoveCount = 0
    private var lastMouseMoveFlush = Date()
    private var mouseFirstPoint: CGPoint?
    private var mouseLastPoint: CGPoint?
    private var scrollCount = 0
    private var scrollDeltaX = 0
    private var scrollDeltaY = 0
    private var scrollStartedAt: Date?
    private var scrollLastAt: Date?
    private var scrollFirstPoint: CGPoint?
    private var scrollLastPoint: CGPoint?
    private var scrollStartUI: UIElementInfo?
    private var scrollLastUI: UIElementInfo?
    private var clickCount = 0
    private var clickButtons: [String: Int] = [:]
    private var firstClick: CGPoint?
    private var lastClick: CGPoint?
    private var firstClickUI: UIElementInfo?
    private var lastClickUI: UIElementInfo?
    private var clickStartedAt: Date?
    private var clickLastAt: Date?
    private var dragCount = 0
    private var dragButton = "left"
    private var dragStartedAt: Date?
    private var dragLastAt: Date?
    private var dragStartPoint: CGPoint?
    private var dragLastPoint: CGPoint?
    private var dragStartUI: UIElementInfo?
    private var dragLastUI: UIElementInfo?
    private var dragDistance = 0.0
    private var lastActivityAt = Date()
    private var segment = TraceSegment.new()

    func start() {
        guard !isRecording else { return }
        requestAccessibilityPermission()
        guard let tap = installEventTap() else {
            NSSound.beep()
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRecording = true
        startSegment(reason: "menu_bar_start")
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshContext() },
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.flushClickAggregate()
                self?.flushScrollAggregate()
                self?.flushKeyAggregate()
                self?.flushDragAggregate()
            }
        ]
    }

    func stop() {
        guard isRecording else { return }
        flushClickAggregate(reason: "menu_bar_stop")
        flushScrollAggregate(reason: "menu_bar_stop")
        flushKeyAggregate(reason: "menu_bar_stop")
        flushDragAggregate(reason: "menu_bar_stop")
        finishSegment(output: "Human computer usage trace stopped")
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        isRecording = false
        Thread.sleep(forTimeInterval: 0.15)
    }

    private func installEventTap() -> CFMachPort? {
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let recorder = Unmanaged<HumanTraceRecorder>.fromOpaque(refcon!).takeUnretainedValue()
                recorder.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            let p = event.location
            recordClick(button: "left", x: p.x, y: p.y)
        case .rightMouseDown:
            let p = event.location
            recordClick(button: "right", x: p.x, y: p.y)
        case .otherMouseDown:
            let p = event.location
            recordClick(button: "other", x: p.x, y: p.y)
        case .scrollWheel:
            recordScroll(
                deltaX: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                deltaY: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                x: event.location.x,
                y: event.location.y
            )
        case .keyDown:
            recordKeyDown(event: event)
        case .mouseMoved:
            recordMouseMove(x: event.location.x, y: event.location.y)
        case .leftMouseDragged:
            let p = event.location
            recordDrag(button: "left", x: p.x, y: p.y)
        case .rightMouseDragged:
            let p = event.location
            recordDrag(button: "right", x: p.x, y: p.y)
        default:
            break
        }
    }

    private func startSegment(reason: String) {
        segment = TraceSegment.new()
        lastContextKey = ""
        eventSequence = 0
        postEvent(isPending: true, output: nil, attachments: [], properties: ["segment.reason": reason])
        let t = nowUnixNano()
        postTraceSpan(spanId: segment.rootSpanId, parentSpanId: nil, name: "human activity burst", startUnixNano: t, endUnixNano: t, attributes: [
            attr("ai.telemetry.metadata.raindrop.eventId", segment.eventId),
            attr("ai.operationId", "human.session"),
            attr("user", userId),
            attr("source", "macos_menubar_accessibility_prototype"),
            attr("trace.schema_version", "2026-05-30.replay.v1"),
            attr("privacy.screenshots_enabled", screenshotsEnabled ? "true" : "false"),
            attr("privacy.typed_text_enabled", typedTextEnabled ? "true" : "false")
        ])
        refreshContext(force: true)
    }

    private func finishSegment(output: String) {
        postEvent(isPending: false, output: output, attachments: [], properties: ["segment.duration_ms": Int(Date().timeIntervalSince(segment.startedAt) * 1000)])
    }

    private func markActivity(kind: String) {
        let now = Date()
        if now.timeIntervalSince(lastActivityAt) >= segmentIdleSeconds {
            flushClickAggregate(reason: "idle_boundary")
            flushScrollAggregate(reason: "idle_boundary")
            flushKeyAggregate(reason: "idle_boundary")
            flushDragAggregate(reason: "idle_boundary")
            finishSegment(output: "Activity burst ended after idle gap")
            startSegment(reason: "activity_after_idle_\(kind)")
        }
        lastActivityAt = now
    }

    private func refreshContext(force: Bool = false) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appName = app.localizedName ?? "unknown"
        let bundle = app.bundleIdentifier ?? "unknown"
        let window = focusedWindowTitle(pid: app.processIdentifier) ?? ""
        let key = "\(bundle)|\(window)"
        currentApp = appName
        currentBundle = bundle
        currentWindow = window
        if force || key != lastContextKey {
            flushClickAggregate(reason: "focus_change")
            flushScrollAggregate(reason: "focus_change")
            flushKeyAggregate(reason: "focus_change")
            flushDragAggregate(reason: "focus_change")
            let spanId = randomHex(bytes: 8)
            segment.contextSpanId = spanId
            lastContextKey = key
            let t = nowUnixNano()
            postTraceSpan(spanId: spanId, parentSpanId: segment.rootSpanId, name: "focus: \(appName)", startUnixNano: t, endUnixNano: t, attributes: baseAttributes(operation: "human.focus", actionKind: "focus") + focusedWindowAttributes(pid: app.processIdentifier))
        }
    }

    private func recordClick(button: String, x: Double, y: Double) {
        markActivity(kind: "click")
        refreshContext()
        if clickCount == 0 {
            clickStartedAt = Date()
            firstClick = CGPoint(x: x, y: y)
            firstClickUI = uiElementInfoAt(x: x, y: y)
        }
        clickLastAt = Date()
        lastClick = CGPoint(x: x, y: y)
        lastClickUI = uiElementInfoAt(x: x, y: y)
        clickCount += 1
        clickButtons[button, default: 0] += 1
        if clickCount >= 8 { flushClickAggregate(reason: "count_threshold") }
    }

    private func flushClickAggregate(reason: String = "timer") {
        guard clickCount > 0 else { return }
        let now = Date()
        if reason == "timer", let last = clickLastAt, now.timeIntervalSince(last) < 0.30 { return }
        let count = clickCount
        let buttons = clickButtons.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
        let first = firstClick ?? .zero
        let last = lastClick ?? first
        let firstUI = firstClickUI
        let lastUI = lastClickUI
        let durationMs = max(1, Int((clickLastAt ?? now).timeIntervalSince(clickStartedAt ?? now) * 1000))
        clickCount = 0
        clickButtons = [:]
        firstClick = nil
        lastClick = nil
        firstClickUI = nil
        lastClickUI = nil
        clickStartedAt = nil
        clickLastAt = nil
        let shot = screenshotAttachment(reason: "click_burst", detail: "\(count) clicks; buttons=\(buttons)")
        let shotName = attachmentName(shot)
        let shotPath = attachmentPath(shot)
        let screen = NSScreen.main?.frame ?? .zero
        let spanName = count == 1 ? "click @ \(Int(last.x)),\(Int(last.y))" : "click burst ×\(count) @ \(Int(first.x)),\(Int(first.y))→\(Int(last.x)),\(Int(last.y))"
        let t = nowUnixNano()
        var attrs = baseAttributes(operation: "human.click_burst", actionKind: "click") + screenAttributes(prefix: "click.screen") + [
            attr("ai.toolCall.name", "human.click"),
            attr("ai.toolCall.args", jsonString(["count": count, "buttons": buttons, "first": [Int(first.x), Int(first.y)], "last": [Int(last.x), Int(last.y)], "target": lastUI?.replayTarget() ?? [:]])),
            attr("ai.toolCall.result", jsonString(["screenshot": shotPath, "ui": lastUI?.summary() ?? ""])),
            attr("replay.action", "click"),
            attr("replay.primary_x", Int(last.x)),
            attr("replay.primary_y", Int(last.y)),
            attr("replay.target", lastUI?.replayTargetJSONString() ?? ""),
            attr("click.event_count", count), attr("click.buttons", buttons), attr("click.first_x", Int(first.x)), attr("click.first_y", Int(first.y)), attr("click.last_x", Int(last.x)), attr("click.last_y", Int(last.y)), attr("click.first_x_norm", normalized(first.x, screen.width)), attr("click.first_y_norm", normalized(first.y, screen.height)), attr("click.last_x_norm", normalized(last.x, screen.width)), attr("click.last_y_norm", normalized(last.y, screen.height)), attr("click.duration_ms", durationMs), attr("click.flush_reason", reason), attr("screenshot.attached", shot == nil ? "false" : "true"), attr("screenshot.capture", shot == nil ? "" : "focused_window"), attr("screenshot.name", shotName), attr("screenshot.path", shotPath)
        ]
        if let firstUI { attrs.append(contentsOf: firstUI.attributes(prefix: "ui.first")) }
        if let lastUI { attrs.append(contentsOf: lastUI.attributes(prefix: "ui.last")) }
        postTraceSpan(spanId: randomHex(bytes: 8), parentSpanId: segment.contextSpanId, name: spanName, startUnixNano: t, endUnixNano: t, attributes: attrs)
        if let shot { postEvent(isPending: true, output: nil, attachments: [shot], properties: ["latest_action": count == 1 ? "click" : "click_burst"]) }
    }

    private func recordScroll(deltaX: Int64, deltaY: Int64, x: Double, y: Double) {
        markActivity(kind: "scroll")
        refreshContext()
        if scrollCount == 0 {
            scrollStartedAt = Date()
            scrollFirstPoint = CGPoint(x: x, y: y)
            scrollStartUI = uiElementInfoAt(x: x, y: y)
        }
        scrollLastAt = Date()
        scrollLastPoint = CGPoint(x: x, y: y)
        scrollLastUI = uiElementInfoAt(x: x, y: y)
        scrollCount += 1
        scrollDeltaX += Int(deltaX)
        scrollDeltaY += Int(deltaY)
        if scrollCount >= 40 { flushScrollAggregate(reason: "count_threshold") }
    }

    private func flushScrollAggregate(reason: String = "timer") {
        guard scrollCount > 0 else { return }
        let now = Date()
        if reason == "timer", let last = scrollLastAt, now.timeIntervalSince(last) < 0.45 { return }
        let count = scrollCount
        let dx = scrollDeltaX
        let dy = scrollDeltaY
        let started = scrollStartedAt ?? now
        let first = scrollFirstPoint ?? .zero
        let last = scrollLastPoint ?? first
        let firstUI = scrollStartUI
        let lastUI = scrollLastUI
        let durationMs = max(1, Int((scrollLastAt ?? now).timeIntervalSince(started) * 1000))
        scrollCount = 0
        scrollDeltaX = 0
        scrollDeltaY = 0
        scrollStartedAt = nil
        scrollLastAt = nil
        scrollFirstPoint = nil
        scrollLastPoint = nil
        scrollStartUI = nil
        scrollLastUI = nil
        let screen = NSScreen.main?.frame ?? .zero
        let spanName = "scroll burst Δy=\(dy) ×\(count) @ \(Int(last.x)),\(Int(last.y))"
        let t = nowUnixNano()
        var attrs = baseAttributes(operation: "human.scroll_burst", actionKind: "scroll") + screenAttributes(prefix: "scroll.screen") + [
            attr("ai.toolCall.name", "human.scroll"),
            attr("ai.toolCall.args", jsonString(["count": count, "deltaX": dx, "deltaY": dy, "last": [Int(last.x), Int(last.y)], "target": lastUI?.replayTarget() ?? [:]])),
            attr("ai.toolCall.result", "scrolled total dy=\(dy), dx=\(dx) over \(count) events"),
            attr("replay.action", "scroll"),
            attr("replay.primary_x", Int(last.x)),
            attr("replay.primary_y", Int(last.y)),
            attr("replay.target", lastUI?.replayTargetJSONString() ?? ""),
            attr("scroll.event_count", count), attr("scroll.total_delta_x", dx), attr("scroll.total_delta_y", dy), attr("scroll.first_x", Int(first.x)), attr("scroll.first_y", Int(first.y)), attr("scroll.last_x", Int(last.x)), attr("scroll.last_y", Int(last.y)), attr("scroll.last_x_norm", normalized(last.x, screen.width)), attr("scroll.last_y_norm", normalized(last.y, screen.height)), attr("scroll.duration_ms", durationMs), attr("scroll.flush_reason", reason)
        ]
        if let firstUI { attrs.append(contentsOf: firstUI.attributes(prefix: "ui.first")) }
        if let lastUI { attrs.append(contentsOf: lastUI.attributes(prefix: "ui.last")) }
        postTraceSpan(spanId: randomHex(bytes: 8), parentSpanId: segment.contextSpanId, name: spanName, startUnixNano: t, endUnixNano: t, attributes: attrs)
    }

    private func recordKeyDown(event: CGEvent) {
        markActivity(kind: "keyboard")
        refreshContext()
        if keyCount == 0 { keyStartedAt = Date() }
        keyLastAt = Date()
        keyCount += 1
        keyCodes[String(event.getIntegerValueField(.keyboardEventKeycode)), default: 0] += 1
        keyModifiers[modifierSummary(event.flags), default: 0] += 1
        if typedTextEnabled { applyKeyToTypedBuffer(event) }
        if keyCount >= 40 || typedBuffer.count >= 160 { flushKeyAggregate(reason: "key_count_threshold") }
    }

    private func recordMouseMove(x: Double, y: Double) {
        mouseMoveCount += 1
        let point = CGPoint(x: x, y: y)
        if mouseFirstPoint == nil { mouseFirstPoint = point }
        mouseLastPoint = point
        let elapsed = Date().timeIntervalSince(lastMouseMoveFlush)
        if elapsed >= 5, mouseMoveCount > 0 {
            let count = mouseMoveCount
            let first = mouseFirstPoint ?? point
            let last = mouseLastPoint ?? first
            mouseMoveCount = 0
            mouseFirstPoint = nil
            mouseLastPoint = nil
            lastMouseMoveFlush = Date()
            refreshContext()
            let t = nowUnixNano()
            postTraceSpan(spanId: randomHex(bytes: 8), parentSpanId: segment.contextSpanId, name: "mouse movement", startUnixNano: t, endUnixNano: t, attributes: baseAttributes(operation: "human.mouse_move", actionKind: "point") + [
                attr("replay.action", "move"), attr("replay.primary_x", Int(last.x)), attr("replay.primary_y", Int(last.y)), attr("mouse.move_count", count), attr("mouse.first_x", Int(first.x)), attr("mouse.first_y", Int(first.y)), attr("mouse.last_x", Int(last.x)), attr("mouse.last_y", Int(last.y)), attr("duration_ms", Int(elapsed * 1000))
            ])
        }
    }

    private func recordDrag(button: String, x: Double, y: Double) {
        markActivity(kind: "drag")
        refreshContext()
        let point = CGPoint(x: x, y: y)
        if dragCount == 0 {
            dragStartedAt = Date()
            dragButton = button
            dragStartPoint = point
            dragStartUI = uiElementInfoAt(x: x, y: y)
        } else if let last = dragLastPoint {
            dragDistance += hypot(point.x - last.x, point.y - last.y)
        }
        dragCount += 1
        dragLastAt = Date()
        dragLastPoint = point
        dragLastUI = uiElementInfoAt(x: x, y: y)
        if dragCount >= 80 { flushDragAggregate(reason: "count_threshold") }
    }

    private func flushDragAggregate(reason: String = "timer") {
        guard dragCount > 0 else { return }
        let now = Date()
        if reason == "timer", let last = dragLastAt, now.timeIntervalSince(last) < 0.40 { return }
        let count = dragCount
        let button = dragButton
        let started = dragStartedAt ?? now
        let first = dragStartPoint ?? .zero
        let last = dragLastPoint ?? first
        let firstUI = dragStartUI
        let lastUI = dragLastUI
        let distance = dragDistance
        let durationMs = max(1, Int((dragLastAt ?? now).timeIntervalSince(started) * 1000))
        dragCount = 0
        dragStartedAt = nil
        dragLastAt = nil
        dragStartPoint = nil
        dragLastPoint = nil
        dragStartUI = nil
        dragLastUI = nil
        dragDistance = 0
        let shot = screenshotAttachment(reason: "drag_burst", detail: "\(count) drag events; button=\(button)")
        let shotName = attachmentName(shot)
        let shotPath = attachmentPath(shot)
        let t = nowUnixNano()
        var attrs = baseAttributes(operation: "human.drag_burst", actionKind: "drag") + screenAttributes(prefix: "drag.screen") + [
            attr("ai.toolCall.name", "human.drag"),
            attr("ai.toolCall.args", jsonString(["button": button, "from": [Int(first.x), Int(first.y)], "to": [Int(last.x), Int(last.y)], "durationMs": durationMs, "target": lastUI?.replayTarget() ?? [:]])),
            attr("ai.toolCall.result", jsonString(["screenshot": shotPath, "ui": lastUI?.summary() ?? ""])),
            attr("replay.action", "drag"),
            attr("replay.primary_x", Int(last.x)),
            attr("replay.primary_y", Int(last.y)),
            attr("replay.target", lastUI?.replayTargetJSONString() ?? ""),
            attr("drag.event_count", count), attr("drag.button", button), attr("drag.first_x", Int(first.x)), attr("drag.first_y", Int(first.y)), attr("drag.last_x", Int(last.x)), attr("drag.last_y", Int(last.y)), attr("drag.distance_px", distance), attr("drag.duration_ms", durationMs), attr("drag.flush_reason", reason),
            attr("screenshot.attached", shot == nil ? "false" : "true"), attr("screenshot.capture", shot == nil ? "" : "focused_window"), attr("screenshot.name", shotName), attr("screenshot.path", shotPath)
        ]
        if let firstUI { attrs.append(contentsOf: firstUI.attributes(prefix: "ui.first")) }
        if let lastUI { attrs.append(contentsOf: lastUI.attributes(prefix: "ui.last")) }
        postTraceSpan(spanId: randomHex(bytes: 8), parentSpanId: segment.contextSpanId, name: "drag \(button) @ \(Int(first.x)),\(Int(first.y))→\(Int(last.x)),\(Int(last.y))", startUnixNano: t, endUnixNano: t, attributes: attrs)
        if let shot { postEvent(isPending: true, output: nil, attachments: [shot], properties: ["latest_action": "drag_burst"]) }
    }

    private func flushKeyAggregate(reason: String = "timer") {
        guard keyCount > 0 else { return }
        let now = Date()
        if reason == "timer", let last = keyLastAt, now.timeIntervalSince(last) < 0.90 { return }
        let count = keyCount
        let text = typedBuffer
        let codes = keyCodes.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
        let modifiers = keyModifiers.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
        let durationMs = max(1, Int((keyLastAt ?? now).timeIntervalSince(keyStartedAt ?? now) * 1000))
        keyCount = 0
        typedBuffer = ""
        keyCodes = [:]
        keyModifiers = [:]
        keyStartedAt = nil
        keyLastAt = nil
        let shot = count >= 5 ? screenshotAttachment(reason: "typing_burst", detail: "\(count) keydowns") : nil
        let shotName = attachmentName(shot)
        let shotPath = attachmentPath(shot)
        let spanName = typedTextEnabled && !text.isEmpty ? "typing burst: \(truncateForName(text))" : "typing burst ×\(count)"
        var attrs = baseAttributes(operation: "human.typing_burst", actionKind: "type") + [
            attr("ai.toolCall.name", "human.typing"),
            attr("ai.toolCall.args", jsonString(["keydownCount": count, "textCaptured": typedTextEnabled, "keyCodes": codes, "modifiers": modifiers])),
            attr("ai.toolCall.result", typedTextEnabled ? text : "typed text not captured"),
            attr("replay.action", typedTextEnabled && !text.isEmpty ? "type" : "key"),
            attr("keyboard.keydown_count", count),
            attr("keyboard.key_codes", codes),
            attr("keyboard.modifiers", modifiers),
            attr("keyboard.duration_ms", durationMs), attr("keyboard.flush_reason", reason), attr("keyboard.typed_text_captured", typedTextEnabled ? "true" : "false"), attr("screenshot.attached", shot == nil ? "false" : "true"), attr("screenshot.capture", shot == nil ? "" : "focused_window"), attr("screenshot.name", shotName), attr("screenshot.path", shotPath)
        ]
        if typedTextEnabled {
            attrs.append(attr("keyboard.typed_text", text))
        } else {
            attrs.append(attr("privacy.note", "typed text intentionally not captured; enable Capture Typed Text to include it"))
        }
        let t = nowUnixNano()
        postTraceSpan(spanId: randomHex(bytes: 8), parentSpanId: segment.contextSpanId, name: spanName, startUnixNano: t, endUnixNano: t, attributes: attrs)
        if let shot { postEvent(isPending: true, output: nil, attachments: [shot], properties: ["latest_action": "typing_burst"]) }
    }

    private func applyKeyToTypedBuffer(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 51 || keyCode == 117 { // delete / forward delete
            if !typedBuffer.isEmpty { typedBuffer.removeLast() }
            return
        }
        if keyCode == 36 || keyCode == 76 { typedBuffer.append("\n"); return }
        if keyCode == 48 { typedBuffer.append("\t"); return }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        chars.withUnsafeMutableBufferPointer { buffer in
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: buffer.baseAddress)
        }
        guard length > 0 else { return }
        let text = String(utf16CodeUnits: chars, count: length)
        guard text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0.value == 10 || $0.value == 9 }) else { return }
        typedBuffer.append(text)
    }

    private func baseAttributes(operation: String, actionKind: String) -> [[String: Any]] {
        eventSequence += 1
        return [
            attr("ai.telemetry.metadata.raindrop.eventId", segment.eventId),
            attr("ai.operationId", operation),
            attr("app.name", currentApp),
            attr("app.bundle", currentBundle),
            attr("window.title", currentWindow),
            attr("trace.schema_version", "2026-05-30.replay.v1"),
            attr("trace.sequence", eventSequence),
            attr("trace.observed_at_ms", Int(Date().timeIntervalSince1970 * 1000)),
            attr("replay.kind", actionKind)
        ]
    }

    private func screenshotAttachment(reason: String, detail: String) -> [String: Any]? {
        guard screenshotsEnabled else { return nil }
        guard !isRewindViewerContext() else { return nil }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".raindrop", isDirectory: true)
            .appendingPathComponent("human-trace-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(reason)-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let fileURL = directory.appendingPathComponent(name)
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let frame = focusedWindowFrame(pid: pid),
              frame.width > 20,
              frame.height > 20 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png", "-R", "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))", fileURL.path]
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0, let png = try? Data(contentsOf: fileURL), !png.isEmpty else { return nil }
        return ["type": "image", "role": "input", "name": name, "value": "data:image/png;base64,\(png.base64EncodedString())", "properties": ["reason": reason, "detail": detail, "app": currentApp, "window": currentWindow, "capture": "focused_window", "path": fileURL.path]]
    }

    private func isRewindViewerContext() -> Bool {
        let window = currentWindow.lowercased()
        return window.contains("mochi rewind") || window.contains("127.0.0.1:5173") || window.contains("localhost:5173")
    }

    private func postEvent(isPending: Bool, output: String?, attachments: [[String: Any]], properties extra: [String: Any]) {
        var aiData: [String: Any] = ["input": "Human computer usage trace from macOS menu bar recorder", "model": "human/macos", "convo_id": segment.eventId]
        if let output { aiData["output"] = output }
        var properties: [String: Any] = ["source": "macos_menubar_accessibility_prototype", "privacy": screenshotsEnabled ? "screenshots_on_no_key_text_no_clipboard" : "screenshots_off_no_key_text_no_clipboard", "segment.id": segment.eventId, "segment.idle_threshold_seconds": segmentIdleSeconds]
        extra.forEach { properties[$0.key] = $0.value }
        var body: [String: Any] = ["event_id": segment.eventId, "user_id": userId, "event": eventName, "timestamp": isoNow(), "ai_data": aiData, "properties": properties, "is_pending": isPending]
        if !attachments.isEmpty { body["attachments"] = attachments }
        postJSON(path: "events/track_partial", body: body)
    }

    private func postTraceSpan(spanId: String, parentSpanId: String?, name: String, startUnixNano: String, endUnixNano: String, attributes: [[String: Any]]) {
        var span: [String: Any] = ["traceId": segment.traceId, "spanId": spanId, "name": name, "startTimeUnixNano": startUnixNano, "endTimeUnixNano": endUnixNano, "attributes": attributes]
        if let parentSpanId { span["parentSpanId"] = parentSpanId }
        let body: [String: Any] = ["resourceSpans": [["resource": ["attributes": [attr("service.name", "human-computer-tracer")]], "scopeSpans": [["scope": ["name": "human-computer-tracer", "version": "0.3.0"], "spans": [span]]]]]]
        postJSON(path: "traces", body: body)
    }

    private func postJSON(path: String, body: [String: Any]) {
        guard let url = URL(string: endpoint + path), JSONSerialization.isValidJSONObject(body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: request).resume()
    }
}

struct TraceSegment {
    let eventId: String
    let traceId: String
    let rootSpanId: String
    var contextSpanId: String
    let startedAt: Date
    static func new() -> TraceSegment {
        let root = randomHex(bytes: 8)
        return TraceSegment(eventId: randomHex(bytes: 8), traceId: randomHex(bytes: 16), rootSpanId: root, contextSpanId: root, startedAt: Date())
    }
}

struct UIElementInfo {
    var role: String = ""
    var subrole: String = ""
    var title: String = ""
    var value: String = ""
    var description: String = ""
    var help: String = ""
    var identifier: String = ""
    var enabled: String = ""
    var focused: String = ""
    var frame: CGRect = .zero
    var ancestry: String = ""

    func summary() -> String {
        [role, title.isEmpty ? value : title, identifier].filter { !$0.isEmpty }.joined(separator: " | ")
    }

    func attributes(prefix: String) -> [[String: Any]] {
        var attrs: [[String: Any]] = []
        func add(_ suffix: String, _ value: String) {
            if !value.isEmpty { attrs.append(attr("\(prefix).\(suffix)", value)) }
        }
        add("role", role)
        add("subrole", subrole)
        add("title", title)
        add("value", value)
        add("description", description)
        add("help", help)
        add("identifier", identifier)
        add("enabled", enabled)
        add("focused", focused)
        add("ancestry", ancestry)
        if frame != .zero {
            attrs.append(attr("\(prefix).frame_x", Int(frame.origin.x)))
            attrs.append(attr("\(prefix).frame_y", Int(frame.origin.y)))
            attrs.append(attr("\(prefix).frame_width", Int(frame.width)))
            attrs.append(attr("\(prefix).frame_height", Int(frame.height)))
        }
        return attrs
    }

    func replayTarget() -> [String: Any] {
        var target: [String: Any] = [:]
        if !role.isEmpty { target["role"] = role }
        if !title.isEmpty { target["title"] = title }
        if !value.isEmpty { target["value"] = value }
        if !description.isEmpty { target["description"] = description }
        if !identifier.isEmpty { target["identifier"] = identifier }
        if frame != .zero {
            target["frame"] = [
                "x": Int(frame.origin.x),
                "y": Int(frame.origin.y),
                "width": Int(frame.width),
                "height": Int(frame.height)
            ]
            target["center"] = [Int(frame.midX), Int(frame.midY)]
        }
        return target
    }

    func replayTargetJSONString() -> String {
        let target = replayTarget()
        return target.isEmpty ? "" : jsonString(target)
    }
}

func uiElementInfoAt(x: Double, y: Double) -> UIElementInfo? {
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &element)
    guard err == .success, let element else { return nil }
    return uiElementInfo(element)
}

func uiElementInfo(_ element: AXUIElement) -> UIElementInfo {
    UIElementInfo(
        role: axString(element, kAXRoleAttribute),
        subrole: axString(element, kAXSubroleAttribute),
        title: axString(element, kAXTitleAttribute),
        value: axString(element, kAXValueAttribute),
        description: axString(element, kAXDescriptionAttribute),
        help: axString(element, kAXHelpAttribute),
        identifier: axString(element, kAXIdentifierAttribute),
        enabled: axBoolString(element, kAXEnabledAttribute),
        focused: axBoolString(element, kAXFocusedAttribute),
        frame: axFrame(element),
        ancestry: axAncestry(element)
    )
}

func axString(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return String(describing: value)
}

func axBoolString(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return "" }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    if let number = value as? NSNumber { return number.boolValue ? "true" : "false" }
    return ""
}

func axFrame(_ element: AXUIElement) -> CGRect {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    var point = CGPoint.zero
    var size = CGSize.zero
    if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
       let positionRef,
       AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
       AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
       let sizeRef,
       AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) {
        return CGRect(origin: point, size: size)
    }
    return .zero
}

func axAncestry(_ element: AXUIElement, maxDepth: Int = 6) -> String {
    var parts: [String] = []
    var current: AXUIElement? = element
    for _ in 0..<maxDepth {
        guard let el = current else { break }
        let role = axString(el, kAXRoleAttribute)
        let title = axString(el, kAXTitleAttribute)
        let desc = axString(el, kAXDescriptionAttribute)
        let label = [role, title.isEmpty ? desc : title].filter { !$0.isEmpty }.joined(separator: ":")
        if !label.isEmpty { parts.append(label) }
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success, let parentRef {
            current = (parentRef as! AXUIElement)
        } else {
            break
        }
    }
    return parts.joined(separator: " <- ")
}

func requestAccessibilityPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

func focusedWindowTitle(pid: pid_t) -> String? {
    let appElement = AXUIElementCreateApplication(pid)
    var focusedWindow: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success, let window = focusedWindow else { return nil }
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
    return title as? String
}

func focusedWindowFrame(pid: pid_t) -> CGRect? {
    let appElement = AXUIElementCreateApplication(pid)
    var focusedWindow: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
          let window = focusedWindow else { return nil }
    let frame = axFrame(window as! AXUIElement)
    return frame == .zero ? nil : frame
}

func focusedWindowAttributes(pid: pid_t) -> [[String: Any]] {
    var attrs: [[String: Any]] = []
    if let frame = focusedWindowFrame(pid: pid) {
        attrs.append(attr("window.frame_x", Int(frame.origin.x)))
        attrs.append(attr("window.frame_y", Int(frame.origin.y)))
        attrs.append(attr("window.frame_width", Int(frame.width)))
        attrs.append(attr("window.frame_height", Int(frame.height)))
    }
    attrs.append(contentsOf: screenAttributes(prefix: "screen"))
    return attrs
}

func screenAttributes(prefix: String) -> [[String: Any]] {
    guard let screen = NSScreen.main else { return [] }
    let frame = screen.frame
    let visible = screen.visibleFrame
    return [
        attr("\(prefix).x", Int(frame.origin.x)),
        attr("\(prefix).y", Int(frame.origin.y)),
        attr("\(prefix).width", Int(frame.width)),
        attr("\(prefix).height", Int(frame.height)),
        attr("\(prefix).visible_x", Int(visible.origin.x)),
        attr("\(prefix).visible_y", Int(visible.origin.y)),
        attr("\(prefix).visible_width", Int(visible.width)),
        attr("\(prefix).visible_height", Int(visible.height)),
        attr("\(prefix).scale", Double(screen.backingScaleFactor))
    ]
}

func modifierSummary(_ flags: CGEventFlags) -> String {
    var parts: [String] = []
    if flags.contains(.maskCommand) { parts.append("cmd") }
    if flags.contains(.maskShift) { parts.append("shift") }
    if flags.contains(.maskAlternate) { parts.append("option") }
    if flags.contains(.maskControl) { parts.append("control") }
    if flags.contains(.maskSecondaryFn) { parts.append("fn") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

func attr(_ key: String, _ value: String) -> [String: Any] { ["key": key, "value": ["stringValue": value]] }
func attr(_ key: String, _ value: Int) -> [String: Any] { ["key": key, "value": ["intValue": String(value)]] }
func attr(_ key: String, _ value: Double) -> [String: Any] { ["key": key, "value": ["doubleValue": value]] }
func attachmentName(_ attachment: [String: Any]?) -> String { attachment?["name"] as? String ?? "" }
func attachmentPath(_ attachment: [String: Any]?) -> String {
    (attachment?["properties"] as? [String: Any])?["path"] as? String ?? ""
}
func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let string = String(data: data, encoding: .utf8) else { return String(describing: value) }
    return string
}
func normalized(_ value: Double, _ maxValue: Double) -> Double { maxValue > 0 ? value / maxValue : 0 }
func truncateForName(_ value: String) -> String {
    let cleaned = value.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\t", with: "⇥")
    return cleaned.count > 48 ? String(cleaned.prefix(48)) + "…" : cleaned
}
func nowUnixNano() -> String { String(Int64(Date().timeIntervalSince1970 * 1_000_000_000)) }
func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }
func randomHex(bytes: Int) -> String {
    var data = Data(count: bytes)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
    return data.map { String(format: "%02x", $0) }.joined()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
