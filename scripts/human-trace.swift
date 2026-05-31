#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

// Local-only prototype: converts human computer activity into Raindrop Workshop events/traces.
// Default capture is metadata only. Screenshots are opt-in via HUMAN_TRACE_SCREENSHOTS=1.
// It deliberately never captures typed text or clipboard contents.

let endpoint = (ProcessInfo.processInfo.environment["RAINDROP_LOCAL_DEBUGGER"] ?? "http://localhost:5899/v1/")
    .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
let userId = NSUserName()
let eventName = ProcessInfo.processInfo.environment["HUMAN_TRACE_EVENT"] ?? "human_computer_use"
let screenshotsEnabled = !isFalsey(ProcessInfo.processInfo.environment["HUMAN_TRACE_SCREENSHOTS"])
let segmentIdleSeconds = Double(ProcessInfo.processInfo.environment["HUMAN_TRACE_SEGMENT_IDLE_SECONDS"] ?? "30") ?? 30

final class HumanTracer {
    static let shared = HumanTracer()

    private let session = URLSession(configuration: .ephemeral)
    private var currentApp = "unknown"
    private var currentBundle = "unknown"
    private var currentWindow = ""
    private var lastContextKey = ""
    private var keyCount = 0
    private var mouseMoveCount = 0
    private var lastMouseMoveFlush = Date()
    private var scrollCount = 0
    private var scrollDeltaX = 0
    private var scrollDeltaY = 0
    private var scrollStartedAt: Date?
    private var scrollLastAt: Date?
    private var clickCount = 0
    private var clickButtons: [String: Int] = [:]
    private var firstClick: CGPoint?
    private var lastClick: CGPoint?
    private var clickStartedAt: Date?
    private var clickLastAt: Date?
    private var lastActivityAt = Date()
    private var segment = TraceSegment.new()

    func start() {
        startSegment(reason: "recorder_start")
    }

    func finish() {
        flushClickAggregate(reason: "recorder_stop")
        flushScrollAggregate(reason: "recorder_stop")
        flushKeyAggregate(reason: "recorder_stop")
        finishSegment(output: "Human computer usage trace stopped")
        Thread.sleep(forTimeInterval: 0.25)
    }

    private func startSegment(reason: String) {
        segment = TraceSegment.new()
        lastContextKey = ""
        postEvent(isPending: true, output: nil, attachments: [], properties: ["segment.reason": reason])
        let t = nowUnixNano()
        postTraceSpan(
            spanId: segment.rootSpanId,
            parentSpanId: nil,
            name: "human activity burst",
            startUnixNano: t,
            endUnixNano: t,
            attributes: [
                attr("ai.telemetry.metadata.raindrop.eventId", segment.eventId),
                attr("ai.operationId", "human.session"),
                attr("user", userId),
                attr("source", "macos_accessibility_prototype"),
                attr("segment.reason", reason),
                attr("privacy.screenshots_enabled", screenshotsEnabled ? "true" : "false")
            ]
        )
        refreshContext(force: true)
    }

    private func finishSegment(output: String) {
        postEvent(isPending: false, output: output, attachments: [], properties: [
            "segment.duration_ms": Int(Date().timeIntervalSince(segment.startedAt) * 1000)
        ])
    }

    private func markActivity(kind: String) {
        let now = Date()
        if now.timeIntervalSince(lastActivityAt) >= segmentIdleSeconds {
            flushClickAggregate(reason: "idle_boundary")
            flushScrollAggregate(reason: "idle_boundary")
            flushKeyAggregate(reason: "idle_boundary")
            finishSegment(output: "Activity burst ended after idle gap")
            startSegment(reason: "activity_after_idle_\(kind)")
        }
        lastActivityAt = now
    }

    func refreshContext(force: Bool = false) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appName = app.localizedName ?? "unknown"
        let bundle = app.bundleIdentifier ?? "unknown"
        let window = focusedWindowTitle(pid: app.processIdentifier) ?? ""
        let contextKey = "\(bundle)|\(window)"

        currentApp = appName
        currentBundle = bundle
        currentWindow = window

        if force || contextKey != lastContextKey {
            flushClickAggregate(reason: "focus_change")
            flushScrollAggregate(reason: "focus_change")
            flushKeyAggregate(reason: "focus_change")
            let spanId = randomHex(bytes: 8)
            segment.contextSpanId = spanId
            lastContextKey = contextKey
            let t = nowUnixNano()
            postTraceSpan(
                spanId: spanId,
                parentSpanId: segment.rootSpanId,
                name: "focus: \(appName)",
                startUnixNano: t,
                endUnixNano: t,
                attributes: baseAttributes(operation: "human.focus") + [
                    attr("app.name", appName),
                    attr("app.bundle", bundle),
                    attr("window.title", window)
                ]
            )
        }
    }

    func recordClick(button: String, x: Double, y: Double) {
        markActivity(kind: "click")
        refreshContext()
        if clickCount == 0 {
            clickStartedAt = Date()
            firstClick = CGPoint(x: x, y: y)
        }
        clickLastAt = Date()
        lastClick = CGPoint(x: x, y: y)
        clickCount += 1
        clickButtons[button, default: 0] += 1
        if clickCount >= 8 { flushClickAggregate(reason: "count_threshold") }
    }

    func flushClickAggregate(reason: String = "timer") {
        guard clickCount > 0 else { return }
        let now = Date()
        if reason == "timer", let last = clickLastAt, now.timeIntervalSince(last) < 0.30 { return }
        let count = clickCount
        let buttons = clickButtons.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
        let first = firstClick ?? .zero
        let last = lastClick ?? first
        let durationMs = max(1, Int((clickLastAt ?? now).timeIntervalSince(clickStartedAt ?? now) * 1000))
        clickCount = 0
        clickButtons = [:]
        firstClick = nil
        lastClick = nil
        clickStartedAt = nil
        clickLastAt = nil
        let screenshot = screenshotAttachment(reason: "click_burst", detail: "\(count) clicks; buttons=\(buttons)")
        let t = nowUnixNano()
        postTraceSpan(
            spanId: randomHex(bytes: 8),
            parentSpanId: segment.contextSpanId,
            name: count == 1 ? "click" : "click burst",
            startUnixNano: t,
            endUnixNano: t,
            attributes: baseAttributes(operation: "human.click_burst") + [
                attr("click.event_count", count),
                attr("click.buttons", buttons),
                attr("click.first_x", Int(first.x)),
                attr("click.first_y", Int(first.y)),
                attr("click.last_x", Int(last.x)),
                attr("click.last_y", Int(last.y)),
                attr("click.duration_ms", durationMs),
                attr("click.flush_reason", reason),
                attr("screenshot.attached", screenshot == nil ? "false" : "true")
            ]
        )
        if let screenshot {
            postEvent(isPending: true, output: nil, attachments: [screenshot], properties: ["latest_action": count == 1 ? "click" : "click_burst"])
        }
    }

    func recordScroll(deltaX: Int64, deltaY: Int64) {
        markActivity(kind: "scroll")
        refreshContext()
        if scrollCount == 0 { scrollStartedAt = Date() }
        scrollLastAt = Date()
        scrollCount += 1
        scrollDeltaX += Int(deltaX)
        scrollDeltaY += Int(deltaY)
        if scrollCount >= 40 {
            flushScrollAggregate(reason: "count_threshold")
        }
    }

    func flushScrollAggregate(reason: String = "timer") {
        guard scrollCount > 0 else { return }
        let now = Date()
        if reason == "timer", let last = scrollLastAt, now.timeIntervalSince(last) < 0.45 { return }
        let count = scrollCount
        let dx = scrollDeltaX
        let dy = scrollDeltaY
        let started = scrollStartedAt ?? now
        let durationMs = max(1, Int((scrollLastAt ?? now).timeIntervalSince(started) * 1000))
        scrollCount = 0
        scrollDeltaX = 0
        scrollDeltaY = 0
        scrollStartedAt = nil
        scrollLastAt = nil
        let t = nowUnixNano()
        postTraceSpan(
            spanId: randomHex(bytes: 8),
            parentSpanId: segment.contextSpanId,
            name: "scroll burst",
            startUnixNano: t,
            endUnixNano: t,
            attributes: baseAttributes(operation: "human.scroll_burst") + [
                attr("scroll.event_count", count),
                attr("scroll.total_delta_x", dx),
                attr("scroll.total_delta_y", dy),
                attr("scroll.duration_ms", durationMs),
                attr("scroll.flush_reason", reason)
            ]
        )
    }

    func recordKeyDown() {
        markActivity(kind: "keyboard")
        refreshContext()
        keyCount += 1
        if keyCount >= 20 {
            flushKeyAggregate(reason: "key_count_threshold")
        }
    }

    func recordMouseMove() {
        mouseMoveCount += 1
        let elapsed = Date().timeIntervalSince(lastMouseMoveFlush)
        if elapsed >= 5, mouseMoveCount > 0 {
            let count = mouseMoveCount
            mouseMoveCount = 0
            lastMouseMoveFlush = Date()
            refreshContext()
            let t = nowUnixNano()
            postTraceSpan(
                spanId: randomHex(bytes: 8),
                parentSpanId: segment.contextSpanId,
                name: "mouse movement",
                startUnixNano: t,
                endUnixNano: t,
                attributes: baseAttributes(operation: "human.mouse_move") + [
                    attr("mouse.move_count", count),
                    attr("duration_ms", Int(elapsed * 1000))
                ]
            )
        }
    }

    func flushKeyAggregate(reason: String = "timer") {
        guard keyCount > 0 else { return }
        let count = keyCount
        keyCount = 0
        let screenshot = count >= 5 ? screenshotAttachment(reason: "keyboard_activity", detail: "\(count) keydowns") : nil
        let t = nowUnixNano()
        postTraceSpan(
            spanId: randomHex(bytes: 8),
            parentSpanId: segment.contextSpanId,
            name: "keyboard activity",
            startUnixNano: t,
            endUnixNano: t,
            attributes: baseAttributes(operation: "human.keyboard") + [
                attr("keyboard.keydown_count", count),
                attr("keyboard.flush_reason", reason),
                attr("screenshot.attached", screenshot == nil ? "false" : "true"),
                attr("privacy.note", "key contents intentionally not captured")
            ]
        )
        if let screenshot {
            postEvent(isPending: true, output: nil, attachments: [screenshot], properties: ["latest_action": "keyboard_activity"])
        }
    }

    private func baseAttributes(operation: String) -> [[String: Any]] {
        [
            attr("ai.telemetry.metadata.raindrop.eventId", segment.eventId),
            attr("ai.operationId", operation),
            attr("app.name", currentApp),
            attr("app.bundle", currentBundle),
            attr("window.title", currentWindow)
        ]
    }

    private func screenshotAttachment(reason: String, detail: String) -> [String: Any]? {
        guard screenshotsEnabled else { return nil }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("human-trace-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png", tempURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let png = try? Data(contentsOf: tempURL),
              !png.isEmpty else { return nil }

        return [
            "type": "image",
            "role": "input",
            "name": "\(reason)-\(Int(Date().timeIntervalSince1970)).png",
            "value": "data:image/png;base64,\(png.base64EncodedString())",
            "properties": [
                "reason": reason,
                "detail": detail,
                "app": currentApp,
                "window": currentWindow
            ]
        ]
    }

    private func postEvent(isPending: Bool, output: String?, attachments: [[String: Any]], properties extraProperties: [String: Any]) {
        var aiData: [String: Any] = [
            "input": "Human computer usage trace from macOS Accessibility/Event Tap prototype",
            "model": "human/macos",
            "convo_id": segment.eventId
        ]
        if let output { aiData["output"] = output }

        var properties: [String: Any] = [
            "source": "macos_accessibility_prototype",
            "privacy": screenshotsEnabled ? "screenshots_opted_in_no_key_text_no_clipboard" : "no_key_text_no_screenshots_no_clipboard",
            "endpoint": endpoint,
            "segment.id": segment.eventId,
            "segment.idle_threshold_seconds": segmentIdleSeconds
        ]
        for (key, value) in extraProperties { properties[key] = value }

        var body: [String: Any] = [
            "event_id": segment.eventId,
            "user_id": userId,
            "event": eventName,
            "timestamp": isoNow(),
            "ai_data": aiData,
            "properties": properties,
            "is_pending": isPending
        ]
        if !attachments.isEmpty { body["attachments"] = attachments }
        postJSON(path: "events/track_partial", body: body)
    }

    private func postTraceSpan(spanId: String, parentSpanId: String?, name: String, startUnixNano: String, endUnixNano: String, attributes: [[String: Any]]) {
        var span: [String: Any] = [
            "traceId": segment.traceId,
            "spanId": spanId,
            "name": name,
            "startTimeUnixNano": startUnixNano,
            "endTimeUnixNano": endUnixNano,
            "attributes": attributes
        ]
        if let parentSpanId { span["parentSpanId"] = parentSpanId }

        let body: [String: Any] = [
            "resourceSpans": [[
                "resource": ["attributes": [attr("service.name", "human-computer-tracer")]],
                "scopeSpans": [[
                    "scope": ["name": "human-computer-tracer", "version": "0.2.0"],
                    "spans": [span]
                ]]
            ]]
        ]
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
        return TraceSegment(
            eventId: randomHex(bytes: 8),
            traceId: randomHex(bytes: 16),
            rootSpanId: root,
            contextSpanId: root,
            startedAt: Date()
        )
    }
}

func focusedWindowTitle(pid: pid_t) -> String? {
    let appElement = AXUIElementCreateApplication(pid)
    var focusedWindow: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
          let window = focusedWindow else { return nil }
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
    return title as? String
}

func attr(_ key: String, _ value: String) -> [String: Any] {
    ["key": key, "value": ["stringValue": value]]
}

func attr(_ key: String, _ value: Int) -> [String: Any] {
    ["key": key, "value": ["intValue": String(value)]]
}

func attr(_ key: String, _ value: Double) -> [String: Any] {
    ["key": key, "value": ["doubleValue": value]]
}

func nowUnixNano() -> String {
    String(Int64(Date().timeIntervalSince1970 * 1_000_000_000))
}

func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func randomHex(bytes: Int) -> String {
    var data = Data(count: bytes)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
    return data.map { String(format: "%02x", $0) }.joined()
}

func isFalsey(_ value: String?) -> Bool {
    guard let value else { return false }
    return ["0", "false", "no", "off"].contains(value.lowercased())
}

func requestAccessibilityPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    if !trusted {
        print("Accessibility permission is not granted yet. macOS should show a permission prompt.")
        print("After granting it, re-run: make human-trace")
    }
}

func installEventTap() -> CFMachPort? {
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
        callback: { _, type, event, _ in
            switch type {
            case .leftMouseDown:
                let p = event.location
                HumanTracer.shared.recordClick(button: "left", x: p.x, y: p.y)
            case .rightMouseDown:
                let p = event.location
                HumanTracer.shared.recordClick(button: "right", x: p.x, y: p.y)
            case .otherMouseDown:
                let p = event.location
                HumanTracer.shared.recordClick(button: "other", x: p.x, y: p.y)
            case .scrollWheel:
                let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
                HumanTracer.shared.recordScroll(deltaX: dx, deltaY: dy)
            case .keyDown:
                HumanTracer.shared.recordKeyDown()
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
                HumanTracer.shared.recordMouseMove()
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    )
}

requestAccessibilityPermission()
HumanTracer.shared.start()

Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    HumanTracer.shared.refreshContext()
}
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    HumanTracer.shared.flushClickAggregate()
    HumanTracer.shared.flushScrollAggregate()
    HumanTracer.shared.flushKeyAggregate()
}

signal(SIGINT) { _ in
    HumanTracer.shared.finish()
    exit(0)
}
signal(SIGTERM) { _ in
    HumanTracer.shared.finish()
    exit(0)
}

if let eventTap = installEventTap() {
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    print("Human trace started → \(endpoint)")
    print("Sidebar unit: one activity burst; new burst after \(Int(segmentIdleSeconds))s idle.")
    print("Capturing: active app/window, clicks, scrolls, key counts, mouse movement counts.")
    print("Screenshots: \(screenshotsEnabled ? "ENABLED" : "disabled") by default. Disable with HUMAN_TRACE_SCREENSHOTS=0.")
    print("Never capturing: key text or clipboard contents.")
    print("Press Ctrl-C to stop and finish the current Workshop run.")
    RunLoop.current.run()
} else {
    print("Could not create event tap. Grant Accessibility/Input Monitoring permissions, then re-run.")
    HumanTracer.shared.finish()
    exit(1)
}
