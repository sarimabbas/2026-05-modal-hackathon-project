#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

func usage() -> Never {
    fputs("""
    Usage:
      swift scripts/ReplayTool.swift click <x> <y> [left|right]
      swift scripts/ReplayTool.swift move <x> <y>
      swift scripts/ReplayTool.swift scroll <dx> <dy> [x y]
      swift scripts/ReplayTool.swift drag <x1> <y1> <x2> <y2> [durationMs]
      swift scripts/ReplayTool.swift type <text>
      swift scripts/ReplayTool.swift paste <text>
      swift scripts/ReplayTool.swift key <keyCode> [cmd,shift,option,control]
      swift scripts/ReplayTool.swift inspect [x y]
      swift scripts/ReplayTool.swift screenshot <path>
      swift scripts/ReplayTool.swift wait <ms>

    """, stderr)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "click":
    guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else { usage() }
    let button = args.count >= 4 ? args[3] : "left"
    postClick(x: x, y: y, button: button)
    printJSON(["ok": true, "action": "click", "x": x, "y": y, "button": button])
case "move":
    guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else { usage() }
    postMouseMove(x: x, y: y)
    printJSON(["ok": true, "action": "move", "x": x, "y": y])
case "scroll":
    guard args.count >= 3, let dx = Int32(args[1]), let dy = Int32(args[2]) else { usage() }
    if args.count >= 5, let x = Double(args[3]), let y = Double(args[4]) {
        postMouseMove(x: x, y: y)
    }
    postScroll(dx: dx, dy: dy)
    printJSON(["ok": true, "action": "scroll", "dx": dx, "dy": dy])
case "drag":
    guard args.count >= 5,
          let x1 = Double(args[1]), let y1 = Double(args[2]),
          let x2 = Double(args[3]), let y2 = Double(args[4]) else { usage() }
    let durationMs = args.count >= 6 ? max(20, Int(args[5]) ?? 250) : 250
    postDrag(x1: x1, y1: y1, x2: x2, y2: y2, durationMs: durationMs)
    printJSON(["ok": true, "action": "drag", "from": [x1, y1], "to": [x2, y2], "durationMs": durationMs])
case "type":
    guard args.count >= 2 else { usage() }
    let text = args.dropFirst().joined(separator: " ")
    runAppleScript("tell application \"System Events\" to keystroke \(appleScriptString(text))")
    printJSON(["ok": true, "action": "type", "characters": text.count])
case "paste":
    guard args.count >= 2 else { usage() }
    let text = args.dropFirst().joined(separator: " ")
    pasteText(text)
    printJSON(["ok": true, "action": "paste", "characters": text.count])
case "key":
    guard args.count >= 2, let code = CGKeyCode(args[1]) else { usage() }
    let flags = args.count >= 3 ? eventFlags(args[2]) : []
    postKey(code: code, flags: flags)
    printJSON(["ok": true, "action": "key", "keyCode": Int(code), "modifiers": args.count >= 3 ? args[2] : ""])
case "inspect":
    let point: CGPoint
    if args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) {
        point = CGPoint(x: x, y: y)
    } else {
        point = NSEvent.mouseLocation
    }
    var payload: [String: Any] = ["ok": true, "x": Int(point.x), "y": Int(point.y), "frontmost": frontmostInfo()]
    if let info = uiElementInfoAt(x: point.x, y: point.y) {
        payload["element"] = info.dictionary()
    }
    printJSON(payload)
case "screenshot":
    guard args.count >= 2 else { usage() }
    let path = NSString(string: args[1]).expandingTildeInPath
    captureScreenshot(path: path)
    printJSON(["ok": true, "action": "screenshot", "path": path])
case "wait":
    guard args.count >= 2, let ms = Double(args[1]) else { usage() }
    Thread.sleep(forTimeInterval: ms / 1000)
    printJSON(["ok": true, "action": "wait", "ms": ms])
default:
    usage()
}

func postMouseMove(x: Double, y: Double) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
}

func postClick(x: Double, y: Double, button: String) {
    let point = CGPoint(x: x, y: y)
    let cgButton: CGMouseButton = button == "right" ? .right : .left
    let downType: CGEventType = button == "right" ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = button == "right" ? .rightMouseUp : .leftMouseUp
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: cgButton)?.post(tap: .cghidEventTap)
    usleep(15_000)
    CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton)?.post(tap: .cghidEventTap)
    usleep(35_000)
    CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton)?.post(tap: .cghidEventTap)
}

func postScroll(dx: Int32, dy: Int32) {
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
}

func postDrag(x1: Double, y1: Double, x2: Double, y2: Double, durationMs: Int) {
    let start = CGPoint(x: x1, y: y1)
    let end = CGPoint(x: x2, y: y2)
    let steps = max(6, min(80, durationMs / 12))
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(20_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        let point = CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(useconds_t(max(1, durationMs / steps) * 1000))
    }
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func postKey(code: CGKeyCode, flags: CGEventFlags) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(20_000)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
}

func pasteText(_ text: String) {
    let pasteboard = NSPasteboard.general
    let old = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    postKey(code: 9, flags: .maskCommand)
    usleep(50_000)
    if let old {
        pasteboard.clearContents()
        pasteboard.setString(old, forType: .string)
    }
}

func captureScreenshot(path: String) {
    try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-t", "png", path]
    try? process.run()
    process.waitUntilExit()
}

func runAppleScript(_ script: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
    process.waitUntilExit()
}

func eventFlags(_ value: String) -> CGEventFlags {
    var flags = CGEventFlags()
    for part in value.split(separator: ",") {
        switch part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option", "alt": flags.insert(.maskAlternate)
        case "control", "ctrl": flags.insert(.maskControl)
        default: break
        }
    }
    return flags
}

func frontmostInfo() -> [String: Any] {
    guard let app = NSWorkspace.shared.frontmostApplication else { return [:] }
    var result: [String: Any] = [
        "app": app.localizedName ?? "",
        "bundle": app.bundleIdentifier ?? "",
        "pid": app.processIdentifier
    ]
    if let title = focusedWindowTitle(pid: app.processIdentifier) { result["windowTitle"] = title }
    if let frame = focusedWindowFrame(pid: app.processIdentifier) { result["windowFrame"] = rectDictionary(frame) }
    return result
}

struct UIElementInfo {
    var role = ""
    var subrole = ""
    var title = ""
    var value = ""
    var description = ""
    var help = ""
    var identifier = ""
    var enabled = ""
    var focused = ""
    var frame = CGRect.zero
    var ancestry = ""

    func dictionary() -> [String: Any] {
        var result: [String: Any] = [
            "role": role,
            "subrole": subrole,
            "title": title,
            "value": value,
            "description": description,
            "help": help,
            "identifier": identifier,
            "enabled": enabled,
            "focused": focused,
            "ancestry": ancestry
        ]
        if frame != .zero { result["frame"] = rectDictionary(frame) }
        return result
    }
}

func uiElementInfoAt(x: Double, y: Double) -> UIElementInfo? {
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &element) == .success, let element else { return nil }
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

func rectDictionary(_ rect: CGRect) -> [String: Int] {
    ["x": Int(rect.origin.x), "y": Int(rect.origin.y), "width": Int(rect.width), "height": Int(rect.height)]
}

func printJSON(_ value: Any) {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        print("{}")
        return
    }
    print(string)
}

func appleScriptString(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
}
