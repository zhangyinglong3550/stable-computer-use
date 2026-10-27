import Cocoa
import ApplicationServices
import Foundation

// MARK: - 常量

let ATTRS: [String] = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
    kAXValueAttribute, kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute,
    kAXChildrenAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
]

/// 这些动作只是滚动容器自带的，不作为"可交互"的证据
let NOISE_ACTIONS: Set<String> = [
    "AXScrollLeftByPage", "AXScrollRightByPage", "AXScrollUpByPage", "AXScrollDownByPage",
]

/// 真正能点的角色
let CONTROL_ROLES: Set<String> = [
    "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
    "AXPopUpButton", "AXLink", "AXTab", "AXDisclosureTriangle", "AXToolbarButton",
    "AXIncrementor", "AXSearchField",
]

/// 可编辑角色
let EDITABLE_ROLES: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

/// 纯装饰，直接丢
let DECORATIVE_ROLES: Set<String> = ["AXScrollBar", "AXSplitter", "AXUnknown", "AXMenuBar"]

/// 这些角色几乎不可能带动作，跳过 actionNames 这次 IPC（实测能省掉约 1/4 快照耗时）
let INERT_ROLES: Set<String> = ["AXStaticText", "AXImage", "AXWindow"]

// MARK: - 工具

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

/// 清洗不可见字符。
///
/// 实测真实 app 的窗口标题里塞满了这些（Chrome 的窗口标题前面就是一长串），
/// 不清洗会污染渲染、模糊匹配和 token 计数。
/// 用 Unicode 类别判定而不是列举码点：Cf 覆盖零宽空格、双向控制符、标签字符等，
/// 比手写白名单可靠得多。
func sanitize(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for sc in s.unicodeScalars {
        switch sc.properties.generalCategory {
        case .format, .control, .unassigned:
            // 保留换行和制表，其余控制符换成空格
            if sc == "\n" || sc == "\t" { out.append(sc) } else { out.append(" ") }
        case .nonspacingMark:
            // 变体选择符（FE00–FE0F）是 nonspacingMark，去掉；组合附加符号保留
            if (0xFE00...0xFE0F).contains(sc.value) || (0xE0100...0xE01EF).contains(sc.value) {
                continue
            }
            out.append(sc)
        default:
            out.append(sc)
        }
    }
    var text = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    // 收敛连续空格
    while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
    return text
}

func asText(_ v: Any?) -> String? {
    guard let v else { return nil }
    if let s = v as? String {
        let t = sanitize(s)
        return t.isEmpty ? nil : t
    }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func rect(_ pos: CFTypeRef?, _ size: CFTypeRef?) -> CGRect? {
    var p = CGPoint.zero
    var s = CGSize.zero
    if let pos, CFGetTypeID(pos) == AXValueGetTypeID() {
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
    }
    if let size, CFGetTypeID(size) == AXValueGetTypeID() {
        AXValueGetValue(size as! AXValue, .cgSize, &s)
    }
    guard s.width > 0, s.height > 0 else { return nil }
    return CGRect(origin: p, size: s)
}

func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x1000_0000_01b3
    }
    return h
}

func base36(_ v: UInt64, width: Int = 6) -> String {
    let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    var n = v
    var out = ""
    repeat {
        out.append(digits[Int(n % 36)])
        n /= 36
    } while n > 0
    while out.count < width { out.append("0") }
    return String(out.reversed().prefix(width))
}

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

// MARK: - 节点

struct Node {
    var role: String
    var subrole: String?
    var label: String?
    var value: String?
    var actions: [String]
    var enabled: Bool
    var rect: CGRect?
    var depth: Int
    var parent: Int
    var children: [Int] = []
    var sig: String = ""
    var ref: String = ""
}

/// 一次批量读取一个节点的全部属性（1 次 IPC 而不是 10 次）
func readNode(_ el: AXUIElement) -> (role: String, subrole: String?, label: String?, value: String?,
                                    rect: CGRect?, children: [AXUIElement], enabled: Bool)? {
    var values: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(
        el, ATTRS as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
    guard err == .success, let arr = values as? [Any], arr.count >= ATTRS.count else {
        // 退化为逐个读，保证不丢节点
        let role = asText(attr(el, kAXRoleAttribute)) ?? "AXUnknown"
        let label = asText(attr(el, kAXTitleAttribute)) ?? asText(attr(el, kAXDescriptionAttribute))
        let value = asText(attr(el, kAXValueAttribute))
        let kids = (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        return (role, asText(attr(el, kAXSubroleAttribute)), label, value,
                rect(attr(el, kAXPositionAttribute), attr(el, kAXSizeAttribute)), kids, true)
    }
    func txt(_ i: Int) -> String? { asText(arr[i]) }
    let role = txt(0) ?? "AXUnknown"
    var label = txt(2) ?? txt(3)
    let value = txt(4) ?? txt(5)
    if label == nil, role == "AXStaticText" { label = value }
    var enabled = true
    if let n = arr[9] as? NSNumber { enabled = n.boolValue }
    let kids = (arr[8] as? [AXUIElement]) ?? []
    return (role, txt(1), label, value, rect(arr[6] as CFTypeRef?, arr[7] as CFTypeRef?), kids, enabled)
}

func actionNames(_ el: AXUIElement) -> [String] {
    var an: CFArray?
    guard AXUIElementCopyActionNames(el, &an) == .success, let list = an as? [String] else { return [] }
    return list.filter { !NOISE_ACTIONS.contains($0) }
}

func actionsFor(_ el: AXUIElement, role: String) -> [String] {
    if INERT_ROLES.contains(role) { return [] }
    return actionNames(el)
}

/// 深度优先收集，保持原始 AX 元素，供后续点击
///
/// 必须防环：实测 Finder 在某些视图下会把祖先再当作子节点返回，
/// 不检测就会一直灌到 maxN，ref 和排序全部失去意义。
///
/// 判据用「角色 + 文字 + 矩形」与祖先比较，而不是 CFEqual ——
/// CFEqual 在 AXUIElement 上会误判（实测把同一层的兄弟全判成祖先）。
/// 真实 UI 里容器不可能和祖先同角色、同文字、同位置。
struct Identity: Hashable {
    let role: String
    let text: String
    let rect: String
}

func collect(_ root: AXUIElement, maxN: Int, maxDepth: Int)
    -> (nodes: [Node], elems: [AXUIElement], truncated: Bool, cycles: Int) {

    var nodes: [Node] = []
    var elems: [AXUIElement] = []
    var cycles = 0
    var truncated = false

    func ident(_ info: (role: String, subrole: String?, label: String?, value: String?,
                        rect: CGRect?, children: [AXUIElement], enabled: Bool)) -> Identity {
        let r = info.rect.map { "\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width)),\(Int($0.height))" } ?? ""
        return Identity(role: info.role, text: info.label ?? info.value ?? "", rect: r)
    }

    func walk(_ el: AXUIElement, _ depth: Int, _ parent: Int, _ ancestors: [Identity]) {
        if nodes.count >= maxN { truncated = true; return }

        guard let info = readNode(el) else { return }
        if DECORATIVE_ROLES.contains(info.role) { return }

        // 只看最近 4 层：太远的同构容器是合法的（嵌套 group 很常见）
        let me_ident = ident(info)
        let recent = ancestors.suffix(4)
        if !me_ident.rect.isEmpty && recent.contains(me_ident) {
            cycles += 1
            return
        }

        let acts = actionsFor(el, role: info.role)
        let me = nodes.count
        nodes.append(Node(role: info.role, subrole: info.subrole, label: info.label, value: info.value,
                          actions: acts, enabled: info.enabled, rect: info.rect, depth: depth, parent: parent))
        elems.append(el)
        if parent >= 0 { nodes[parent].children.append(me) }

        if depth < maxDepth {
            let next = ancestors + [me_ident]
            for c in info.children.prefix(2000) {
                walk(c, depth + 1, me, next)
            }
        }
    }
    walk(root, 0, -1, [])
    return (nodes, elems, truncated, cycles)
}

/// 自底向上剪枝：无文字、无动作、无保留子节点的丢掉
func prune(_ nodes: [Node]) -> [Bool] {
    var keep = [Bool](repeating: false, count: nodes.count)
    for i in stride(from: nodes.count - 1, through: 0, by: -1) {
        let n = nodes[i]
        let hasText = (n.label?.isEmpty == false) || (n.value?.isEmpty == false)
        let hasAction = !n.actions.isEmpty
        let isEditable = EDITABLE_ROLES.contains(n.role)
        let hasKeptKid = n.children.contains { keep[$0] }
        keep[i] = hasText || hasAction || isEditable || hasKeptKid
    }
    return keep
}

/// 稳定签名：用祖先的"角色+文字"路径，而不是下标
func assignSignatures(_ nodes: [Node], keep: [Bool], maxLabel: Int = 48) -> [String] {
    var sigs = [String](repeating: "", count: nodes.count)
    var seen: [String: Int] = [:]
    for i in nodes.indices where keep[i] {
        let n = nodes[i]
        let piece = n.role + "|" + String((n.label ?? n.value ?? "").prefix(maxLabel))
        let base = n.parent >= 0 ? sigs[n.parent] + "/" + piece : piece
        let count = (seen[base] ?? 0) + 1
        seen[base] = count
        sigs[i] = count == 1 ? base : base + "#\(count)"
    }
    return sigs
}

func assignRefs(_ nodes: inout [Node], sigs: [String], keep: [Bool]) {
    var used: [String: Int] = [:]
    for i in nodes.indices where keep[i] {
        var r = base36(fnv1a(sigs[i]))
        if let c = used[r] {
            used[r] = c + 1
            r += "-\(c + 1)"
        } else {
            used[r] = 1
        }
        nodes[i].ref = r
        nodes[i].sig = sigs[i]
    }
}

/// 解析到最近的可点祖先（文字节点自己点不动）
func actionableAncestor(_ nodes: [Node], _ i: Int, keep: [Bool]) -> Int {
    if nodes[i].actions.contains("AXPress") || CONTROL_ROLES.contains(nodes[i].role) { return i }
    if nodes[i].rect != nil && !nodes[i].actions.isEmpty { return i }
    var cur = nodes[i].parent
    while cur >= 0 {
        if keep[cur] && (nodes[cur].actions.contains("AXPress") || CONTROL_ROLES.contains(nodes[cur].role)) {
            return cur
        }
        cur = nodes[cur].parent
    }
    return i
}

// MARK: - app / window

struct AppRef {
    let app: NSRunningApplication
    let ax: AXUIElement
}

func resolveApp(_ spec: String) -> AppRef {
    let running = NSWorkspace.shared.runningApplications
    let match = running.first { $0.bundleIdentifier == spec }
        ?? running.first { $0.localizedName == spec }
        ?? running.first { ($0.bundleIdentifier ?? "").lowercased().contains(spec.lowercased()) }
        ?? running.first { ($0.localizedName ?? "").lowercased().contains(spec.lowercased()) }
    guard let app = match else { die("app_not_found: \(spec)", code: 2) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 2.0)
    return AppRef(app: app, ax: ax)
}

/// 真正能当"窗口"的角色。Finder 在只有桌面时会把自己的 Application 元素
/// 和桌面的 ScrollArea 塞进 kAXWindowsAttribute —— 那不是窗口，进去就是深渊。
let WINDOW_ROLES: Set<String> = ["AXWindow", "AXSheet", "AXDialog", "AXSystemDialog"]

func isWindow(_ el: AXUIElement) -> Bool {
    guard let role = asText(attr(el, kAXRoleAttribute)) else { return false }
    return WINDOW_ROLES.contains(role)
}

func targetWindow(_ a: AppRef) -> AXUIElement {
    if let w = attr(a.ax, kAXFocusedWindowAttribute) {
        let el = w as! AXUIElement
        if isWindow(el) { return el }
    }
    if let w = attr(a.ax, kAXMainWindowAttribute) {
        let el = w as! AXUIElement
        if isWindow(el) { return el }
    }
    if let ws = attr(a.ax, kAXWindowsAttribute) as? [AXUIElement] {
        if let f = ws.first(where: { isWindow($0) }) { return f }
    }
    let name = a.app.localizedName ?? "?"
    // 区分"真的没窗口"和"AX 根本读不到"：对 app 自己读一次角色
    var probe: CFTypeRef?
    let probeErr = AXUIElementCopyAttributeValue(a.ax, kAXRoleAttribute as CFString, &probe)
    if probeErr == .cannotComplete {
        die("ax_cannot_complete: AX 返回 -25204，可能是屏幕锁定、显示器休眠或 AX 服务无响应", code: 10)
    }
    die("no_window: \(name) 没有可操作的窗口（可能只有桌面，或被最小化）", code: 3)
}

struct Snapshot {
    var nodes: [Node]
    var elems: [AXUIElement]
    var keep: [Bool]
    var window: AXUIElement
    var app: AppRef
    var title: String
    var truncated: Bool = false
    var cycles: Int = 0
}

func snapshot(_ spec: String, maxN: Int = 4000, maxDepth: Int = 20) -> Snapshot {
    let a = resolveApp(spec)
    let w = targetWindow(a)
    let (nodes, elems, truncated, cycles) = collect(w, maxN: maxN, maxDepth: maxDepth)
    let keep = prune(nodes)
    var out = nodes
    let sigs = assignSignatures(nodes, keep: keep)
    assignRefs(&out, sigs: sigs, keep: keep)
    return Snapshot(nodes: out, elems: elems, keep: keep, window: w,
                    app: a, title: asText(attr(w, kAXTitleAttribute)) ?? "",
                    truncated: truncated, cycles: cycles)
}

// MARK: - 渲染

func render(_ s: Snapshot) -> String {
    var lines: [String] = []
    var renderDepth: [Int: Int] = [:]
    func walk(_ i: Int, _ d: Int) {
        let n = s.nodes[i]
        renderDepth[i] = d
        let pad = String(repeating: "  ", count: d)
        let role = n.role.replacingOccurrences(of: "AX", with: "")
        var line = "\(pad)[\(n.ref)] \(role)"
        if let l = n.label, !l.isEmpty {
            line += ": " + (l.count > 70 ? String(l.prefix(70)) + "…" : l)
        }
        if let v = n.value, !v.isEmpty, v != n.label {
            let t = v.count > 40 ? String(v.prefix(40)) + "…" : v
            line += " (value: \(t))"
        }
        if !n.enabled { line += " [disabled]" }
        if !n.actions.isEmpty {
            line += "  <" + n.actions.sorted().joined(separator: ", ") + ">"
        }
        lines.append(line)
        for c in n.children where s.keep[c] {
            walk(c, d + 1)
        }
    }
    if s.keep.indices.contains(0) && s.keep[0] { walk(0, 0) }
    return lines.joined(separator: "\n")
}

func toJSON(_ s: Snapshot) -> [String: Any] {
    var out: [[String: Any]] = []
    func walk(_ i: Int) {
        let n = s.nodes[i]
        var e: [String: Any] = [
            "ref": n.ref,
            "role": n.role,
            "depth": n.depth,
            "enabled": n.enabled,
        ]
        if let r = n.rect {
            e["rect"] = ["x": r.origin.x, "y": r.origin.y, "w": r.width, "h": r.height]
        }
        if let v = n.value { e["value"] = v }
        if let l = n.label { e["label"] = l }
        if !n.actions.isEmpty { e["actions"] = n.actions }
        let anc = actionableAncestor(s.nodes, i, keep: s.keep)
        if anc != i { e["actionable_ref"] = s.nodes[anc].ref }
        out.append(e)
        for c in n.children where s.keep[c] { walk(c) }
    }
    if s.keep.indices.contains(0) && s.keep[0] { walk(0) }
    var payload: [String: Any] = ["app": s.app.app.localizedName ?? "",
                                  "bundle": s.app.app.bundleIdentifier ?? "",
                                  "window": s.title, "elements": out]
    if s.truncated { payload["truncated"] = true }
    if s.cycles > 0 { payload["cyclesDetected"] = s.cycles }
    return payload
}

// MARK: - 输入合成

func activate(_ a: AppRef) {
    if #available(macOS 14.0, *) {
        a.app.activate()
    } else {
        a.app.activate(options: [.activateIgnoringOtherApps])
    }
    usleep(60_000)
}

func mouseClick(at p: CGPoint, button: CGMouseButton = .left, count: Int = 1, holdMs: Int = 40) {
    let src = CGEventSource(stateID: .hidSystemState)
    let (down, up): (CGEventType, CGEventType) = button == .right
        ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button)?
        .post(tap: .cghidEventTap)
    usleep(30_000)
    for _ in 0..<max(1, count) {
        CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: p, mouseButton: button)?
            .post(tap: .cghidEventTap)
        usleep(useconds_t(holdMs * 1000))
        CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: p, mouseButton: button)?
            .post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

let KEYCODES: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
    "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "kp_0": 82, "kp_1": 83, "kp_2": 84, "kp_3": 85, "kp_4": 86,
    "kp_5": 87, "kp_6": 88, "kp_7": 89, "kp_8": 91, "kp_9": 92,
    "period": 47, "comma": 43, "slash": 44, "minus": 27, "equal": 24,
    "semicolon": 41, "quote": 39, "backslash": 42, "grave": 50,
    "leftbracket": 33, "rightbracket": 30,
]

let MODIFIERS: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand, "super": .maskCommand, "meta": .maskCommand,
    "ctrl": .maskControl, "control": .maskControl,
    "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
    "shift": .maskShift, "fn": .maskSecondaryFn,
]

func parseChord(_ chord: String) -> (CGKeyCode, CGEventFlags) {
    let parts = chord.lowercased()
        .split(separator: "+")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard let keyName = parts.last else { die("invalid_key: \(chord)", code: 4) }
    var flags: CGEventFlags = []
    for m in parts.dropLast() {
        guard let f = MODIFIERS[m] else { die("unknown_modifier: \(m)", code: 4) }
        flags.insert(f)
    }
    guard let code = KEYCODES[keyName] else { die("unknown_key: \(keyName)", code: 4) }
    return (code, flags)
}

func pressKey(_ chord: String) {
    let (code, flags) = parseChord(chord)
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(15_000)
    up?.post(tap: .cghidEventTap)
    usleep(15_000)
}

func typeText(_ text: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for scalar in text {
        var utf16 = Array(String(scalar).utf16)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else { continue }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        guard let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.post(tap: .cghidEventTap)
        usleep(4_000)
    }
}

// MARK: - 参数

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var bools: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if body.contains("=") {
                    let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
                    flags[parts[0]] = parts.count > 1 ? parts[1] : ""
                } else if i + 1 < raw.count && !raw[i + 1].hasPrefix("--") {
                    flags[body] = raw[i + 1]
                    i += 1
                } else {
                    bools.insert(body)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func flag(_ k: String) -> String? { flags[k] }
    func has(_ k: String) -> Bool { bools.contains(k) || flags[k] != nil }
    func int(_ k: String, _ d: Int) -> Int { flags[k].flatMap(Int.init) ?? d }
}

func findNode(_ s: Snapshot, ref: String) -> Int? {
    for i in s.nodes.indices where s.keep[i] && s.nodes[i].ref == ref { return i }
    return nil
}

func centerOf(_ nodes: [Node], _ i: Int, keep: [Bool]) -> CGPoint? {
    var cur = i
    while cur >= 0 {
        if let r = nodes[cur].rect, r.width > 0, r.height > 0 {
            return CGPoint(x: r.midX, y: r.midY)
        }
        cur = nodes[cur].parent
    }
    return nil
}

// MARK: - 命令

let args = Args(Array(CommandLine.arguments.dropFirst()))
guard let cmd = args.positional.first else {
    die("usage: scu-ax <doctor|apps|snapshot|act|verify> [options]", code: 1)
}

// MARK: - 不打扰用户：AX 优先 + 显式接管

/// 用户最近一次操作距现在多久（秒）。用来避免在用户正在用电脑时抢焦点。
func userIdleSeconds() -> Double {
    let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown,
                                .scrollWheel, .flagsChanged]
    return types.map {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
    }.min() ?? 0
}

/// 会抢焦点的动作必须同时满足：显式 --take-over + 用户已经空闲够久。
func requireTakeOver(_ args: Args, why: String) {
    guard args.has("take-over") else {
        emit(["ok": false, "reasonCode": "needs_takeover", "why": why,
              "hint": "这个动作必须把目标窗口切到前台，会打断用户。"
                    + "确认要接管时加 --take-over；否则请改用 AX 路径（--via ax / set / type）"])
        exit(11)
    }
    let need = Double(args.flag("idle-seconds") ?? "2.0") ?? 2.0
    let idle = userIdleSeconds()
    if idle < need {
        emit(["ok": false, "reasonCode": "user_active",
              "idleSeconds": (idle * 10).rounded() / 10, "requiredIdleSeconds": need,
              "hint": "用户刚操作过电脑，现在抢焦点会打断他。等用户空闲后再试，或降低 --idle-seconds"])
        exit(12)
    }
}

/// 屏幕坐标 → AX 元素。不需要移动鼠标。
func elementAtPoint(_ pid: pid_t, _ p: CGPoint) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 1.5)
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(axApp, Float(p.x), Float(p.y), &el) == .success else {
        return nil
    }
    return el
}

/// 从命中的元素往上找第一个能"按"的祖先（图标命中的往往是 AXImage，本身没动作）
func pressable(_ el: AXUIElement, maxHops: Int = 10) -> (element: AXUIElement, action: String)? {
    // 只接受"按压类"动作。
    // AXShowMenu 会弹出右键菜单 —— 实测在企微会话列表上把祖先回退到它，
    // 结果弹了一个上下文菜单，属于明显的误操作。宁可失败也不要乱弹。
    let preferred = ["AXPress", "AXOpen", "AXConfirm", "AXPick"]
    var cur: AXUIElement? = el
    var hops = 0
    while let c = cur, hops < maxHops {
        var acts: CFArray?
        if AXUIElementCopyActionNames(c, &acts) == .success, let list = acts as? [String] {
            for want in preferred where list.contains(want) {
                return (c, want)
            }
        }
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &parentRef) == .success,
           let p = parentRef as! AXUIElement? {
            cur = p
        } else {
            cur = nil
        }
        hops += 1
    }
    return nil
}

func elementSnapshot(_ el: AXUIElement) -> [String: Any] {
    var out: [String: Any] = [:]
    if let r = asText(attr(el, kAXRoleAttribute)) { out["role"] = r }
    if let t = asText(attr(el, kAXTitleAttribute)) { out["label"] = t }
    else if let d = asText(attr(el, kAXDescriptionAttribute)) { out["label"] = d }
    return out
}

// ---- 菜单栏快捷方式：不需要焦点就能触发 ----

/// 解析 "super+shift+s" → (字符, 修饰键位掩码)
/// AXMenuItemCmdModifiers 的位：1=shift, 2=option, 4=control；0 表示只带 Command。
func chordToMenuItem(_ chord: String) -> (key: String, mods: Int)? {
    let parts = chord.lowercased().split(separator: "+").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    guard let key = parts.last, key.count == 1 else { return nil }
    var mods = 0
    var hasCommand = false
    for m in parts.dropLast() {
        switch m {
        case "super", "cmd", "command", "meta": hasCommand = true
        case "shift": mods |= 1
        case "alt", "option", "opt": mods |= 2
        case "ctrl", "control": mods |= 4
        default: return nil
        }
    }
    // 没有 Command 的组合不是菜单快捷键
    guard hasCommand else { return nil }
    return (key, mods)
}

func findAndPressMenuItem(_ appAx: AXUIElement, key: String, mods: Int) -> Bool {
    guard let menuBar = attr(appAx, kAXMenuBarAttribute) else { return false }
    var pressed = false

    func walk(_ el: AXUIElement, _ depth: Int) {
        if pressed || depth > 6 { return }
        let role = asText(attr(el, kAXRoleAttribute)) ?? ""
        if role == "AXMenuItem" {
            let cmdChar = (asText(attr(el, "AXMenuItemCmdChar")) ?? "").lowercased()
            let cmdMods = (attr(el, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? -1
            if cmdChar == key && cmdMods == mods {
                if AXUIElementPerformAction(el, "AXPress" as CFString) == .success {
                    pressed = true
                    return
                }
            }
        }
        if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for k in kids { walk(k, depth + 1) }
        }
    }
    walk(menuBar as! AXUIElement, 0)
    return pressed
}

/// 往元素里写字，不需要焦点。
func writeText(into el: AXUIElement, _ text: String) -> Bool {
    // 可编辑控件：优先在光标处插入，其次整体赋值
    if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
        return true
    }
    if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
        return true
    }
    return false
}

switch cmd {

case "doctor":
    let trusted = AXIsProcessTrusted()
    let screen = CGPreflightScreenCaptureAccess()

    // AXIsProcessTrusted() == true **不代表真的能读**，必须做一次真实探针。
    //
    // 注意：不要用 AXUIElementCreateSystemWide() + kAXFocusedApplicationAttribute
    // 做探针 —— 实测在正常工作时它也会稳定返回 -25204，是假阴性。
    // 正确做法是对**某个具体 app** 读一次属性。
    var axUsable = false
    var probeErr: AXError = .cannotComplete
    var probeTarget = "-"
    if let front = NSWorkspace.shared.frontmostApplication {
        probeTarget = front.bundleIdentifier ?? front.localizedName ?? "?"
        let ax = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1.5)
        var probe: CFTypeRef?
        probeErr = AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &probe)
        axUsable = (probeErr == .success && probe != nil)
    }

    // 第二项：能不能真的拿到窗口。
    // 实测存在一种状态 —— AXRole 读得到，但 kAXWindowsAttribute 返回的全是 app 代理
    // （CFEqual(app, w) == true，没有位置/尺寸）。此时所有 snapshot 都会 no_window。
    // 常见于显示器休眠 / 长时间无操作。光看第一项会误报"可用"。
    var windowUsable = false
    var windowProbeApp = "-"
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.8)
        guard let ws = attr(ax, kAXWindowsAttribute) as? [AXUIElement] else { continue }
        if ws.contains(where: { isWindow($0) }) {
            windowUsable = true
            windowProbeApp = app.localizedName ?? app.bundleIdentifier ?? "?"
            break
        }
    }

    var payload: [String: Any] = [
        "accessibility": trusted,
        "accessibilityUsable": axUsable,
        "axProbeCode": Int(probeErr.rawValue),
        "axProbeTarget": probeTarget,
        "windowUsable": windowUsable,
        "windowProbeApp": windowProbeApp,
        "screen_recording": screen,
        "macos": ProcessInfo.processInfo.operatingSystemVersionString,
        "ok": trusted && axUsable && windowUsable,
    ]
    if !axUsable {
        payload["reasonCode"] = probeErr == .cannotComplete ? "ax_cannot_complete" : "ax_unusable"
        payload["hint"] = probeErr == .cannotComplete
            ? "AX 返回 -25204（cannotComplete）：通常是屏幕已锁定、或当前不是活动 GUI 会话。解锁后重试。"
            : "辅助功能权限虽显示已授权，但 AX 调用失败。到 系统设置 → 隐私与安全性 → 辅助功能 把终端关掉再打开。"
    } else if !windowUsable {
        payload["reasonCode"] = "no_accessible_windows"
        payload["hint"] = "AX 能读，但没有任何 app 暴露真实窗口（拿回来的都是 app 代理，没有位置和尺寸）。"
                         + "常见于显示器休眠 / 长时间无操作。唤醒屏幕、把目标窗口调出来再试。"
    }
    emit(payload)

case "apps":
    var list: [[String: Any]] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.6)
        let ws = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let titles = ws.compactMap { asText(attr($0, kAXTitleAttribute)) }
        list.append(["name": app.localizedName ?? "", "bundle": app.bundleIdentifier ?? "",
                     "pid": app.processIdentifier, "windows": ws.count,
                     "titles": Array(titles.prefix(3))])
    }
    emit(["apps": list, "count": list.count])

case "snapshot":
    guard let appSpec = args.flag("app") else { die("missing --app", code: 4) }
    let s = snapshot(appSpec, maxN: args.int("max", 4000))
    if args.has("json") {
        emit(toJSON(s))
    } else {
        print("APP \(s.app.app.localizedName ?? "?") [\(s.app.app.bundleIdentifier ?? "")]  WINDOW: \(s.title)")
        print(render(s))
        let kept = s.keep.filter { $0 }.count
        var tail = "# nodes \(kept)/\(s.nodes.count)"
        if s.truncated { tail += "  TRUNCATED at --max" }
        if s.cycles > 0 { tail += "  cycles=\(s.cycles)" }
        print(tail)
    }

case "act":
    guard let appSpec = args.flag("app") else { die("missing --app", code: 4) }
    guard let op = args.flag("op") else { die("missing --op", code: 4) }
    let wantMouse = args.flag("via") == "mouse"

    // ---------- click ----------
    if op == "click" {
        let app = resolveApp(appSpec)

        // 坐标点击
        if let xs = args.flag("x"), let ys = args.flag("y"),
           let px = Double(xs), let py = Double(ys) {
            let pt = CGPoint(x: px, y: py)
            if wantMouse {
                requireTakeOver(args, why: "坐标鼠标点击会移动指针")
                activate(app)
                mouseClick(at: pt, button: (args.flag("button") == "right") ? .right : .left,
                           count: args.int("count", 1))
                emit(["ok": true, "op": "click", "via": "mouse", "x": px, "y": py])
                break
            }
            // 默认：命中测试 → 往上找可按祖先 → AXPress。全程不动鼠标、不抢焦点。
            guard let hit = elementAtPoint(app.app.processIdentifier, pt) else {
                emit(["ok": false, "reasonCode": "no_element_at_point", "x": px, "y": py,
                      "hint": "该坐标没有可访问元素（可能是 Electron 自绘区域）。"
                            + "需要真的点像素时用 --via mouse --take-over"])
                exit(13)
            }
            guard let t = pressable(hit) else {
                emit(["ok": false, "reasonCode": "no_ax_action_at_point", "x": px, "y": py,
                      "element": elementSnapshot(hit),
                      "hint": "命中了元素但没有可执行动作。需要真的点像素时用 --via mouse --take-over"])
                exit(13)
            }
            let err = AXUIElementPerformAction(t.element, t.action as CFString)
            var r: [String: Any] = ["ok": err == .success, "op": "click", "via": "ax-hit-test",
                                    "x": px, "y": py, "action": t.action,
                                    "element": elementSnapshot(t.element)]
            if err != .success { r["reasonCode"] = "ax_action_failed" }
            emit(r)
            if err != .success { exit(14) }
            break
        }

        // 元素点击
        let s = snapshot(appSpec)
        var target = -1
        if let ref = args.flag("ref") {
            guard let i = findNode(s, ref: ref) else {
                emit(["ok": false, "reasonCode": "stale_ref", "ref": ref,
                      "hint": "ref 不在最新快照里，重新 snapshot 后重试"])
                exit(5)
            }
            target = i
        } else if let text = args.flag("text") {
            let want = text.lowercased()
            target = s.nodes.indices.first { i in
                s.keep[i] && ((s.nodes[i].label ?? "").lowercased().contains(want)
                              || (s.nodes[i].value ?? "").lowercased().contains(want))
            } ?? -1
            if target < 0 { emit(["ok": false, "reasonCode": "text_not_found", "text": text]); exit(6) }
        } else {
            die("bad_args: click 需要 --ref / --text / --x --y", code: 4)
        }

        let n = s.nodes[target]
        if !n.enabled {
            emit(["ok": false, "reasonCode": "disabled", "ref": n.ref]); exit(7)
        }

        // 默认永远先试 AX；只有显式 --via mouse 才动鼠标
        if !wantMouse {
            // 注意：这里刻意不含 AXShowMenu
            for act in ["AXPress", "AXOpen", "AXConfirm", "AXPick"] where n.actions.contains(act) {
                if AXUIElementPerformAction(s.elems[target], act as CFString) == .success {
                    emit(["ok": true, "op": "click", "ref": n.ref, "via": "ax", "action": act])
                    exit(0)
                }
            }
            // 自己也按不动，试试祖先
            if let t = pressable(s.elems[target]) {
                if AXUIElementPerformAction(t.element, t.action as CFString) == .success {
                    emit(["ok": true, "op": "click", "ref": n.ref, "via": "ax-ancestor",
                          "action": t.action])
                    exit(0)
                }
            }
            emit(["ok": false, "reasonCode": "no_ax_action", "ref": n.ref, "role": n.role,
                  "hint": "这个元素没有可执行的无障碍动作。需要真点像素时用 --via mouse --take-over"])
            exit(13)
        }

        requireTakeOver(args, why: "鼠标点击会移动指针")
        guard let p = centerOf(s.nodes, target, keep: s.keep) else {
            emit(["ok": false, "reasonCode": "no_geometry", "ref": n.ref]); exit(8)
        }
        activate(s.app)
        mouseClick(at: p, button: (args.flag("button") == "right") ? .right : .left,
                   count: args.int("count", 1))
        emit(["ok": true, "op": "click", "ref": n.ref, "via": "mouse", "x": p.x, "y": p.y])
        break
    }

    // ---------- set ----------
    if op == "set" {
        let s = snapshot(appSpec)
        guard let ref = args.flag("ref"), let i = findNode(s, ref: ref) else {
            emit(["ok": false, "reasonCode": "stale_ref"]); exit(5)
        }
        guard let v = args.flag("value") else { die("missing --value", code: 4) }
        let ok = writeText(into: s.elems[i], v)
        emit(["ok": ok, "op": "set", "ref": ref, "via": "ax",
              "reasonCode": ok ? "" : "set_failed"])
        if !ok { exit(14) }
        break
    }

    // ---------- type ----------
    if op == "type" {
        guard let t = args.flag("text") else { die("missing --text", code: 4) }
        let app = resolveApp(appSpec)
        // 目标：指定 ref 的元素，或该 app 当前的焦点元素。都不需要 app 在前台。
        var targetEl: AXUIElement?
        if let ref = args.flag("ref") {
            let s = snapshot(appSpec)
            if let i = findNode(s, ref: ref) { targetEl = s.elems[i] }
        } else {
            var f: CFTypeRef?
            if AXUIElementCopyAttributeValue(app.ax, kAXFocusedUIElementAttribute as CFString, &f) == .success {
                targetEl = (f as! AXUIElement)
            }
        }
        if let el = targetEl, writeText(into: el, t) {
            emit(["ok": true, "op": "type", "via": "ax", "chars": t.count])
            break
        }
        // AX 写不进去 —— 需要真键盘，必须接管
        requireTakeOver(args, why: "键盘输入需要目标窗口获得焦点")
        activate(app)
        typeText(t)
        emit(["ok": true, "op": "type", "via": "keyboard", "chars": t.count])
        break
    }

    // ---------- key ----------
    if op == "key" {
        guard let k = args.flag("key") else { die("missing --key", code: 4) }
        let app = resolveApp(appSpec)
        if !wantMouse {
            // 先试菜单栏：命中就能在后台触发，不碰焦点
            if let (key, mods) = chordToMenuItem(k), findAndPressMenuItem(app.ax, key: key, mods: mods) {
                emit(["ok": true, "op": "key", "key": k, "via": "menu-item"])
                break
            }
            emit(["ok": false, "reasonCode": "needs_takeover", "key": k,
                  "hint": "这个组合键不是菜单项，只能靠真键盘发送，需要目标窗口聚焦。"
                        + "确认要接管时加 --take-over"])
            exit(11)
        }
        requireTakeOver(args, why: "发送组合键需要目标窗口聚焦")
        activate(app)
        pressKey(k)
        emit(["ok": true, "op": "key", "key": k, "via": "keyboard"])
        break
    }

    // ---------- scroll ----------
    if op == "scroll" {
        let s = snapshot(appSpec)
        guard let ref = args.flag("ref"), let i = findNode(s, ref: ref) else {
            emit(["ok": false, "reasonCode": "stale_ref"]); exit(5)
        }
        let dir = args.flag("direction") ?? "down"
        let pages = Double(args.flag("pages") ?? "1") ?? 1
        // 滚动走 AX 动作，同样不需要焦点
        let axAction: String
        switch dir {
        case "up": axAction = "AXScrollUpByPage"
        case "down": axAction = "AXScrollDownByPage"
        case "left": axAction = "AXScrollLeftByPage"
        default: axAction = "AXScrollRightByPage"
        }
        var cur: AXUIElement? = s.elems[i]
        var hops = 0
        while let c = cur, hops < 10 {
            var acts: CFArray?
            if AXUIElementCopyActionNames(c, &acts) == .success,
               let list = acts as? [String], list.contains(axAction) {
                for _ in 0..<max(1, Int(pages.rounded())) {
                    _ = AXUIElementPerformAction(c, axAction as CFString)
                }
                emit(["ok": true, "op": "scroll", "direction": dir, "via": "ax", "action": axAction])
                exit(0)
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &parentRef) == .success,
               let p = parentRef as! AXUIElement? { cur = p } else { cur = nil }
            hops += 1
        }
        requireTakeOver(args, why: "这个容器没有 AX 滚动动作，只能合成滚轮事件")
        if let p = centerOf(s.nodes, i, keep: s.keep) {
            activate(s.app)
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            let dy: Int32 = (dir == "up" ? 1 : -1) * Int32(10 * pages)
            CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                    wheel1: dy, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        }
        emit(["ok": true, "op": "scroll", "direction": dir, "via": "wheel"])
        break
    }

    die("unknown --op \(op)", code: 4)

case "verify":
    guard let appSpec = args.flag("app"), let ref = args.flag("ref") else {
        die("missing --app/--ref", code: 4)
    }
    let s = snapshot(appSpec)
    guard let i = findNode(s, ref: ref) else {
        emit(["ok": false, "reasonCode": "stale_ref", "ref": ref]); exit(5)
    }
    let n = s.nodes[i]
    var out: [String: Any] = ["ok": true, "ref": ref, "role": n.role, "enabled": n.enabled]
    out["actions"] = n.actions
    if let r = n.rect { out["rect"] = ["x": r.origin.x, "y": r.origin.y, "w": r.width, "h": r.height] }
    if let l = n.label { out["label"] = l }
    emit(out)

default:
    die("unknown command \(cmd)", code: 1)
}
