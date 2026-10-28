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

func collect(_ root: AXUIElement, maxN: Int, maxDepth: Int, visibleRect: CGRect? = nil,
             withActions: Bool = true)
    -> (nodes: [Node], elems: [AXUIElement], truncated: Bool, cycles: Int) {

    var nodes: [Node] = []
    var elems: [AXUIElement] = []
    var cycles = 0
    var truncated = false
    var skipped = 0

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

        // 可见区过滤：滚出屏幕的行（虚拟列表里常有上千个）没必要读
        if let vr = visibleRect, let r = info.rect, !vr.intersects(r) {
            skipped += 1
            return
        }
        let acts = withActions ? actionsFor(el, role: info.role) : []
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
    if skipped > 0 { FileHandle.standardError.write(Data("skipped-offscreen: \(skipped)\n".utf8)) }
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

/// 实时在跑的 app 列表。
///
/// `NSWorkspace.shared.runningApplications` 靠 workspace 通知维护，
/// 而 daemon 没有 NSApplication runloop，收不到通知 —— 它会一直返回启动那一刻的快照。
/// 后果：daemon 跑起来之后新开的 app 永远 `app_not_found`。
/// 直接问内核要进程表，再用 `NSRunningApplication(processIdentifier:)` 包装，不依赖 runloop。
func liveProcessIDs() -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
    let capacity = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
    guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
    let count = size / MemoryLayout<kinfo_proc>.stride
    return (0..<count).map { procs[$0].kp_proc.p_pid }
}

func liveApps() -> [NSRunningApplication] {
    liveProcessIDs().compactMap { NSRunningApplication(processIdentifier: $0) }
}

/// 按 bundle id / 名字 / 模糊匹配找一个在跑的 app。
/// 先查 workspace 缓存（快，绝大多数命中），再查内核进程表（慢一点，但能发现新 app）。
func findRunningApp(_ spec: String) -> NSRunningApplication? {
    // bundle id 精确查询走 LaunchServices，最便宜
    if spec.contains(".") {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: spec)
            .first(where: { !$0.isTerminated }) {
            return app
        }
    }
    if let app = matchApp(NSWorkspace.shared.runningApplications, spec) { return app }
    return matchApp(liveApps(), spec)
}

func matchApp(_ running: [NSRunningApplication], _ spec: String) -> NSRunningApplication? {
    let live = running.filter { !$0.isTerminated }
    return live.first { $0.bundleIdentifier == spec }
        ?? live.first { $0.localizedName == spec }
        ?? live.first { ($0.bundleIdentifier ?? "").lowercased().contains(spec.lowercased()) }
        ?? live.first { ($0.localizedName ?? "").lowercased().contains(spec.lowercased()) }
}

func resolveApp(_ spec: String) -> AppRef {
    guard let app = findRunningApp(spec) else { die("app_not_found: \(spec)", code: 2) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 2.0)
    tryEnableManualAX(app.processIdentifier, ax)
    return AppRef(app: app, ax: ax)
}

/// 真正能当"窗口"的角色。Finder 在只有桌面时会把自己的 Application 元素
/// 和桌面的 ScrollArea 塞进 kAXWindowsAttribute —— 那不是窗口，进去就是深渊。
let WINDOW_ROLES: Set<String> = ["AXWindow", "AXSheet", "AXDialog", "AXSystemDialog"]

func isWindow(_ el: AXUIElement) -> Bool {
    guard let role = asText(attr(el, kAXRoleAttribute)) else { return false }
    return WINDOW_ROLES.contains(role)
}

/// 已经尝试过强制开启无障碍树的 app（按 pid）
var manualAxTried = Set<pid_t>()

/// Chromium/Electron 系应用有个开关：设 AXManualAccessibility=true 会强制它构建无障碍树。
/// VS Code 这类有效；Notion 这类把内容画在 canvas 里的无效（实测 64→64 节点）。
/// 无害，所以每个 app 试一次，能开就赚。
func tryEnableManualAX(_ pid: pid_t, _ ax: AXUIElement) {
    if manualAxTried.contains(pid) { return }
    manualAxTried.insert(pid)
    _ = AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
}

/// 不 exit 的版本 —— daemon 里绝不能用会退出的解析，否则一个坏请求就把服务打死。
func resolveAppSafe(_ spec: String) -> AppRef? {
    guard let app = findRunningApp(spec) else { return nil }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 2.0)
    tryEnableManualAX(app.processIdentifier, ax)
    return AppRef(app: app, ax: ax)
}

func targetWindow(_ a: AppRef) -> AXUIElement? {
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
    return nil
}

struct Snapshot {
    var nodes: [Node]
    var elems: [AXUIElement]
    var keep: [Bool]
    var window: AXUIElement
    var app: AppRef
    var title: String
    var rect: CGRect? = nil
    var truncated: Bool = false
    var cycles: Int = 0
}

/// 找这个 app 的窗口在 CGWindowList 里的 ID。
/// 用 optionAll：窗口在别的 Space、或者被完全盖住时，OnScreenOnly 根本看不到它。
func cgWindowId(pid: pid_t, like bounds: CGRect?) -> CGWindowID? {
    let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    var best: (CGWindowID, CGFloat) = (0, .greatestFiniteMagnitude)
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let num = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let ww = b["Width"] as? CGFloat, let hh = b["Height"] as? CGFloat,
              ww > 100, hh > 100 else { continue }
        if let target = bounds {
            let dx = abs(ww - target.width) + abs(hh - target.height)
            if dx < best.1 { best = (num, dx) }
        } else if best.0 == 0 {
            best = (num, 0)
        }
    }
    return best.0 == 0 ? nil : best.0
}

func windowRect(_ w: AXUIElement) -> CGRect? {
    var p = CGPoint.zero, sz = CGSize.zero
    if let pv = attr(w, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = attr(w, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }
    guard sz.width > 0, sz.height > 0 else { return nil }
    return CGRect(origin: p, size: sz)
}

func snapshot(_ spec: String, maxN: Int = 4000, maxDepth: Int = 20,
              visibleOnly: Bool = true, withActions: Bool = true) -> Snapshot? {
    guard let a = resolveAppSafe(spec), let w = targetWindow(a) else { return nil }
    let wr = windowRect(w)
    // 窗口矩形 ∩ 它所在屏幕的可用区域 = 真正看得见的部分
    var visible: CGRect? = nil
    if visibleOnly, let wr {
        for scr in NSScreen.screens where scr.frame.intersects(wr) {
            visible = wr.intersection(scr.visibleFrame)
            break
        }
    }
    let (nodes, elems, truncated, cycles) = collect(w, maxN: maxN, maxDepth: maxDepth,
                                                    visibleRect: visible, withActions: withActions)
    let keep = prune(nodes)
    var out = nodes
    let sigs = assignSignatures(nodes, keep: keep)
    assignRefs(&out, sigs: sigs, keep: keep)
    return Snapshot(nodes: out, elems: elems, keep: keep, window: w,
                    app: a, title: asText(attr(w, kAXTitleAttribute)) ?? "",
                    rect: wr, truncated: truncated, cycles: cycles)
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
    var payload: [String: Any] = ["ok": true,
                                  "pid": Int(s.app.app.processIdentifier),
                                  "app": s.app.app.localizedName ?? "",
                                  "bundle": s.app.app.bundleIdentifier ?? "",
                                  "window": s.title, "elements": out,
                                  "coordinateSpace": "screen"]
    if let r = s.rect {
        payload["windowRect"] = ["x": r.origin.x, "y": r.origin.y,
                                 "w": r.width, "h": r.height]
        payload["windowOrigin"] = ["x": r.origin.x, "y": r.origin.y]
    }
    if s.truncated { payload["truncated"] = true }
    if s.cycles > 0 { payload["cyclesDetected"] = s.cycles }
    return payload
}

// MARK: - 输入合成

/// 等待倍率：1.0 = 稳（默认），0.25 = 快。环境变量 SCU_WAIT_SCALE 可覆盖。
func waitScale() -> Double {
    if let v = ProcessInfo.processInfo.environment["SCU_WAIT_SCALE"], let d = Double(v), d > 0 {
        return d
    }
    return 1.0
}

func nap(_ ms: Double) {
    let scaled = ms * waitScale()
    if scaled >= 1 { usleep(useconds_t(scaled * 1000)) }
}

func activate(_ a: AppRef) {
    if #available(macOS 14.0, *) {
        a.app.activate()
    } else {
        a.app.activate(options: [.activateIgnoringOtherApps])
    }
    nap(35)
}

/// 事件往哪送。
///
/// `global` 塞进系统事件流：谁在前台就归谁。目标不在前台时，事件会落到
/// 用户正在用的窗口上 —— 这是"静默串窗"的根因。
/// `pid` 直接投递给目标进程的事件队列：不移动真实光标、不抢焦点，
/// 代价是目标 app 可能因为窗口不是 key window 而丢弃它（所以结果标 unverified）。
enum EventRoute {
    case global
    case pid(pid_t)

    var isPid: Bool { if case .pid = self { return true }; return false }
    var label: String { isPid ? "pid" : "global" }
}

func send(_ ev: CGEvent?, _ route: EventRoute) {
    guard let ev else { return }
    switch route {
    case .global: ev.post(tap: .cghidEventTap)
    case .pid(let p): ev.postToPid(p)
    }
}

func mouseClick(at p: CGPoint, button: CGMouseButton = .left, count: Int = 1, holdMs: Int = 12,
                route: EventRoute = .global) {
    let src = CGEventSource(stateID: .hidSystemState)
    let (down, up): (CGEventType, CGEventType) = button == .right
        ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    // 只保留事件顺序所需的最小间隔。
    // 实测/Codex 的做法一致：输入立刻发，等待放在「取状态」那一侧自适应做。
    send(CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button),
         route)
    nap(2)
    for _ in 0..<max(1, count) {
        send(CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: p, mouseButton: button),
             route)
        nap(Double(holdMs))
        send(CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: p, mouseButton: button),
             route)
        nap(2)
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

func scrollWheel(at p: CGPoint, dy: Int32, route: EventRoute = .global) {
    let src = CGEventSource(stateID: .hidSystemState)
    send(CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                 mouseCursorPosition: p, mouseButton: .left), route)
    send(CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                 wheel1: dy, wheel2: 0, wheel3: 0), route)
}

/// 解析组合键。返回 nil 表示不认识 —— daemon 里不能 die，否则一个坏请求就把服务打死。
func parseKey(_ chord: String) -> (CGKeyCode, CGEventFlags)? {
    let parts = chord.lowercased()
        .split(separator: "+")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard let keyName = parts.last else { return nil }
    var flags: CGEventFlags = []
    for m in parts.dropLast() {
        guard let f = MODIFIERS[m] else { return nil }
        flags.insert(f)
    }
    guard let code = KEYCODES[keyName] else { return nil }
    return (code, flags)
}

func parseChord(_ chord: String) -> (CGKeyCode, CGEventFlags) {
    guard let r = parseKey(chord) else { die("invalid_key: \(chord)", code: 4) }
    return r
}

func pressKey(_ chord: String, route: EventRoute = .global) {
    guard let (code, flags) = parseKey(chord) else { return }
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    send(down, route)
    usleep(15_000)
    send(up, route)
    usleep(15_000)
}

/// 长文本走剪贴板粘贴：逐字合成是 4ms/字，26 个字就 100ms+。
/// 粘贴是一次 ⌘V，而且不会因为输入法状态丢字。
func pasteText(_ text: String, route: EventRoute = .global) -> Bool {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)
    usleep(20_000)
    let src = CGEventSource(stateID: .hidSystemState)
    let vKey = CGKeyCode(9)   // v
    let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    send(down, route)
    usleep(15_000)
    send(up, route)
    usleep(60_000)
    // 还原用户原来的剪贴板
    if let s = saved {
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
    return true
}

func typeText(_ text: String, route: EventRoute = .global) {
    let src = CGEventSource(stateID: .hidSystemState)
    for scalar in text {
        var utf16 = Array(String(scalar).utf16)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else { continue }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        send(down, route)
        guard let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        send(up, route)
        nap(1.5)
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

/// 元素中心点（屏幕坐标）。daemon 里没有节点数组，直接读属性。
func elementCenter(_ el: AXUIElement) -> CGPoint? {
    var p = CGPoint.zero, sz = CGSize.zero
    if let pv = attr(el, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = attr(el, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }
    guard sz.width > 0, sz.height > 0 else { return nil }
    return CGPoint(x: p.x + sz.width / 2, y: p.y + sz.height / 2)
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

/// 整体赋值（`set` 语义）。先试 AXValue，再退回插入。
func setValue(into el: AXUIElement, _ text: String) -> Bool {
    if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
        return true
    }
    return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
}

/// 在光标处插入（`type` 语义），不需要焦点。
func insertText(into el: AXUIElement, _ text: String) -> Bool {
    if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
        return true
    }
    return AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success
}

// MARK: - 结果契约：动作到底生效了没有
//
// `ok: true` 只说明"无障碍调用返回了 success"，不说明界面上真的发生了什么。
// 每个动作都带 verification：
//   verified   —— 读回值匹配。这是唯一能证明"输入真的落地"的形态。
//   unverified —— 合成输入投出去就管不着了，或者 AX 调用本身无法断言。
// 调用方不许把 unverified 当成功上报。

func verified(_ source: String) -> [String: Any] { ["state": "verified", "source": source] }
func unverified(_ reason: String) -> [String: Any] { ["state": "unverified", "reason": reason] }

/// 读回元素当前文本，用来验证写入。
func readBack(_ el: AXUIElement) -> String? {
    if let v = attr(el, kAXValueAttribute), let s = asText(v) { return s }
    if let v = attr(el, kAXSelectedTextAttribute), let s = asText(v) { return s }
    return nil
}

/// 写入后的读回判定。
/// 只有"值变了且包含预期文本"才算 verified —— 单纯 contains 在"字段里本来就有这串字"时会误判。
func verifyWrite(_ el: AXUIElement, before: String?, expected: String) -> [String: Any] {
    guard let after = readBack(el) else { return unverified("provider_unavailable") }
    let changed = before == nil || after != before
    if changed && (after == expected || after.hasSuffix(expected) || after.contains(expected)) {
        return verified("value_readback")
    }
    var out = unverified(changed ? "value_mismatch" : "value_unchanged")
    out["actualPreview"] = String(after.prefix(80))
    return out
}

// MARK: - 坐标空间
//
// 动作坐标默认是**屏幕点**（AX 的 position / CGEvent 的 location 都是这个空间）。
// `--space window` 让调用方直接传窗口内坐标（原点 = 窗口左上角），
// 由这里换算 —— 多屏和负坐标下调用方不用自己减窗口原点。

func windowOrigin(_ spec: String) -> CGPoint? {
    guard let a = resolveAppSafe(spec), let w = targetWindow(a), let r = windowRect(w) else {
        return nil
    }
    return r.origin
}

func toScreenPoint(_ p: CGPoint, appSpec: String, space: String) -> CGPoint? {
    guard space == "window" else { return p }
    guard let o = windowOrigin(appSpec) else { return nil }
    return CGPoint(x: p.x + o.x, y: p.y + o.y)
}

/// 坐标相关的输出统一带上空间和换算结果，别再让调用方猜。
func pointPayload(_ screen: CGPoint, space: String) -> [String: Any] {
    ["coordinateSpace": space, "screen": ["x": screen.x, "y": screen.y]]
}


// MARK: - 浮动状态条
//
// 只做展示：无边框 NSPanel、不抢焦点、鼠标穿透。
// 它跑在 daemon 进程里，不是独立 .app —— 不需要任何额外 TCC 权限，
// 换来的是一条看得见的状态：正在做什么、结果是 verified 还是 unverified。
//
// SCU_HUD=0 关闭（CI / 无 WindowServer）；SCU_HUD_POS=bottom 贴屏幕底部。

final class StatusHUD {
    static let shared = StatusHUD()

    private var panel: NSPanel?
    private var dot: NSView?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var hideTask: DispatchWorkItem?

    private let width: CGFloat = 320
    private let height: CGFloat = 52

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["SCU_HUD"] != "0"
    }

    /// 动作开始：先亮出来，避免"黑箱操作"。
    func begin(cmd: String, app: String) {
        show(title: "scu · \(cmd)", detail: app, color: .systemBlue, autoHide: false)
    }

    /// 动作结束：状态色 + verification 原因。
    func finish(cmd: String, payload: [String: Any]) {
        let ok = (payload["ok"] as? Bool) ?? false
        let verification = payload["verification"] as? [String: Any]
        let state = verification?["state"] as? String
        let reason = (verification?["reason"] as? String) ?? (payload["reasonCode"] as? String)
        let via = payload["via"] as? String

        var color = NSColor.systemGreen
        var detail = "ok"
        if !ok {
            color = .systemRed
            detail = reason ?? "failed"
        } else if state == "verified" {
            detail = "verified"
        } else if state == "unverified" {
            color = .systemOrange
            detail = "unverified" + (reason.map { " · \($0)" } ?? "")
        }
        if let via, !via.isEmpty { detail += " · via \(via)" }
        show(title: "scu · \(cmd)", detail: detail, color: color, autoHide: true)
    }

    private func show(title: String, detail: String, color: NSColor, autoHide: Bool) {
        guard enabled else { return }
        DispatchQueue.main.async {
            let p = self.ensurePanel()
            self.titleLabel?.stringValue = title
            self.detailLabel?.stringValue = detail
            self.dot?.layer?.backgroundColor = color.cgColor
            self.resize(p, title: title, detail: detail)
            self.position(p)
            self.hideTask?.cancel()
            self.hideTask = nil
            p.alphaValue = 1
            p.orderFrontRegardless()
            if autoHide { self.scheduleHide() }
        }
    }

    /// 宽度跟着内容走：一句 "ok" 和一句 "unverified · value_mismatch · via pid"
    /// 不该占同样大的块。
    private func resize(_ p: NSPanel, title: String, detail: String) {
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 11)
        let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
        let detailWidth = (detail as NSString).size(withAttributes: [.font: detailFont]).width
        let width = min(460, max(180, max(titleWidth, detailWidth) + 58))
        if abs(p.frame.width - width) > 0.5 {
            p.setContentSize(NSSize(width: width, height: height))
        }
    }

    private func scheduleHide() {
        let task = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: task)
    }

    private func fadeOut() {
        guard let p = panel, p.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    private func position(_ p: NSPanel) {
        // NSScreen.main 是"当前活动屏"，daemon 没有 key window 时可能指向副屏，
        // 算出来的 Y 会跑到屏幕外。主屏固定是 screens 的第一个（菜单栏所在）。
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        let x = f.midX - p.frame.width / 2
        let y = ProcessInfo.processInfo.environment["SCU_HUD_POS"] == "bottom"
            ? f.minY + 28
            : f.maxY - p.frame.height - 12
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.alphaValue = 0

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        // 视觉材质在浅色页面上会发灰，压一层深色保证对比稳定
        let tint = NSView(frame: effect.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.46).cgColor
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)

        let dotView = NSView(frame: NSRect(x: 16, y: height / 2 - 4, width: 8, height: 8))
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4
        dotView.layer?.backgroundColor = NSColor.systemGreen.cgColor
        effect.addSubview(dotView)
        dot = dotView

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 34, y: height / 2 + 1, width: width - 48, height: 16)
        title.autoresizingMask = [.width]
        effect.addSubview(title)
        titleLabel = title

        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor(white: 1, alpha: 0.72)
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 34, y: height / 2 - 16, width: width - 48, height: 15)
        detail.autoresizingMask = [.width]
        effect.addSubview(detail)
        detailLabel = detail

        p.contentView = effect
        panel = p
        return p
    }
}

/// 当前请求里正在执行的写动作，供 writeLine 收尾时更新 HUD。
/// handleClient 是串行执行的，所以不需要锁。
var hudCommand: String? = nil

// MARK: - 常驻 daemon：消除「每步重走全树」
//
// 慢的根因：每次动作都要 spawn 进程 + 重新遍历整棵 AX 树 + 序列化 JSON。
// 大 app（企微 3774 节点）光快照就 780ms，点一下要 1 秒。
//
// daemon 的思路和 Codex 一致：**walk 一次，把 AXUIElement 活着留着**。
// 之后的动作直接用缓存里的元素对象，不再走树 —— 这是微秒级和秒级的区别。

var cache: [String: AXUIElement] = [:]      // ref -> 活元素
var cacheMeta: [String: [String: Any]] = [:] // ref -> 元信息
var cacheOwner: [String: String] = [:]       // ref -> 最近的可点祖先 ref
var cacheApp = ""
var cacheWindow = ""

func cacheStore(_ snap: Snapshot) {
    cache.removeAll(keepingCapacity: true)
    cacheMeta.removeAll(keepingCapacity: true)
    cacheApp = snap.app.app.bundleIdentifier ?? ""
    cacheWindow = snap.title
    cacheOwner.removeAll(keepingCapacity: true)
    for i in snap.nodes.indices where snap.keep[i] {
        let ref = snap.nodes[i].ref
        cache[ref] = snap.elems[i]
        // 文字节点自己点不动 —— 记住它归属的可点祖先，动作时直接跳过去
        let anc = actionableAncestor(snap.nodes, i, keep: snap.keep)
        if anc != i { cacheOwner[ref] = snap.nodes[anc].ref }
        var m: [String: Any] = ["role": snap.nodes[i].role, "enabled": snap.nodes[i].enabled]
        if let l = snap.nodes[i].label { m["label"] = l }
        if let v = snap.nodes[i].value { m["value"] = v }
        if !snap.nodes[i].actions.isEmpty { m["actions"] = snap.nodes[i].actions }
        cacheMeta[ref] = m
    }
}

/// 缓存里的 AXUIElement 可能指向已经销毁/重建的控件。
/// 按下之前确认它还是缓存时那个：角色没变、窗口标题没变。
/// 读不到窗口属性就当通过（菜单项之类的元素本来就没有窗口）。
func cacheStale(_ ref: String) -> [String: Any]? {
    guard let el = cache[ref], let meta = cacheMeta[ref] else { return nil }
    let role = asText(attr(el, kAXRoleAttribute)) ?? ""
    if let want = meta["role"] as? String, !want.isEmpty, role != want {
        return ["ok": false, "reasonCode": "stale_ref", "ref": ref, "why": "role_changed",
                "expected": want, "actual": role]
    }
    if !cacheWindow.isEmpty, let wv = attr(el, kAXWindowAttribute) {
        let w = wv as! AXUIElement
        if let t = asText(attr(w, kAXTitleAttribute)), t != cacheWindow {
            return ["ok": false, "reasonCode": "stale_ref", "ref": ref, "why": "window_changed",
                    "expectedWindow": cacheWindow, "actualWindow": t]
        }
    }
    return nil
}

/// 在缓存元素上直接执行"按压类"动作。不重走树。
func cachedPress(_ ref: String) -> [String: Any] {
    // 先试自己，再试归属的可点祖先 —— 都从缓存拿，不重走树
    var chain = [ref]
    if let owner = cacheOwner[ref], owner != ref { chain.append(owner) }

    for candidate in chain {
        guard let el = cache[candidate] else { continue }
        if let stale = cacheStale(candidate) {
            // 目标自己失效就直接报错；祖先失效就换下一个候选
            if candidate == ref { return stale }
            continue
        }
        var acts: CFArray?
        AXUIElementCopyActionNames(el, &acts)
        let list = (acts as? [String]) ?? []
        for want in ["AXPress", "AXOpen", "AXConfirm", "AXPick"] where list.contains(want) {
            if AXUIElementPerformAction(el, want as CFString) == .success {
                var r: [String: Any] = ["ok": true, "op": "click", "ref": ref,
                                        "action": want, "via": "daemon-cache",
                                        "verification": unverified("axpress_unasserted")]
                if candidate != ref { r["pressedAncestor"] = candidate }
                return r
            }
        }
    }
    if cache[ref] == nil { return ["ok": false, "reasonCode": "cache_miss", "ref": ref] }
    return ["ok": false, "reasonCode": "no_ax_action", "ref": ref]
}

func writeLine(_ fd: Int32, _ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { buf in
            _ = Darwin.write(fd, buf.baseAddress, buf.count)
        }
    }
    // 响应已经发走，再做 UI —— 展示不能拖慢调用方
    if let cmd = hudCommand, obj["ok"] != nil {
        StatusHUD.shared.finish(cmd: cmd, payload: obj)
        hudCommand = nil
    }
}

/// 界面指纹：只看留下来的节点的 ref/文字/值/可用性。
/// 用来判断"动作之后界面到底变没变"，从而避免截图。
func signature(_ s: Snapshot) -> String {
    // 只用「角色 + 文字 + 值 + 可用性」，**不依赖 keep 和 ref**。
    // keep 取决于要不要读动作，ref 取决于 keep —— 用它俩会让"带动作"和"不带动作"
    // 算出的签名不可比（踩过这个坑：轻量快照下变化检测永远返回没变）。
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for n in s.nodes {
        let part = n.role + "|" + (n.label ?? "") + "|" + (n.value ?? "") + "|" + (n.enabled ? "1" : "0")
        for ch in part.utf8 {
            h ^= UInt64(ch)
            h = h &* 0x1000_0000_01b3
        }
    }
    return base36(h, width: 12)
}

/// 执行一个动作，然后轮询直到界面变化（或超时）。
/// 这是替代"动作后截图给模型看"的关键原语：一次遍历 30–120ms，比一次视觉判断快一个数量级。
func actAndWait(_ req: [String: Any], appSpec: String, timeoutMs: Int) -> [String: Any] {
    // 轮询只需要"变没变"，不需要动作列表 —— 省掉一半 IPC
    guard let before = snapshot(appSpec, withActions: false) else {
        return ["ok": false, "reasonCode": "no_window", "app": appSpec]
    }
    // 注意：这里**不** cacheStore —— 轻量快照没有动作列表，覆盖缓存会让后续点击失效
    let sigBefore = signature(before)
    let space = (req["space"] as? String) ?? "screen"
    let wantActivate = (req["activate"] as? Bool) == true
    let route: EventRoute = resolveAppSafe(appSpec)
        .map { .pid($0.app.processIdentifier) } ?? .global

    // ---- 执行 ----
    let tActStart = Date()
    var actResult: [String: Any] = ["ok": true]
    if let ref = req["ref"] as? String {
        actResult = cachedPress(ref)
        if (actResult["reasonCode"] as? String) == "cache_miss" {
            if let fresh = snapshot(appSpec) { cacheStore(fresh) }
            actResult = cachedPress(ref)
        }
        if (actResult["reasonCode"] as? String) == "cache_miss" {
            actResult = ["ok": false, "reasonCode": "stale_ref", "ref": ref]
        }
        // 动作本身失败了就别再等界面变化
        if (actResult["ok"] as? Bool) != true { return actResult }
    } else if let x = req["x"] as? Double, let y = req["y"] as? Double {
        guard let app = resolveAppSafe(appSpec) else {
            return ["ok": false, "reasonCode": "app_not_found"]
        }
        guard let screen = toScreenPoint(CGPoint(x: x, y: y), appSpec: appSpec, space: space) else {
            return ["ok": false, "reasonCode": "window_not_found"]
        }
        let mouseButton: CGMouseButton = (req["button"] as? String) == "right" ? .right : .left
        let count = (req["count"] as? Int) ?? 1
        if (req["mouse"] as? Bool) == true || (req["via"] as? String) == "mouse" {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.app.processIdentifier {
                activate(app)
            }
            mouseClick(at: screen, button: mouseButton, count: count)
            actResult = ["ok": true, "via": "mouse", "verification": unverified("synthetic_input")]
        } else if (req["via"] as? String) == "pid" {
            mouseClick(at: screen, button: mouseButton, count: count,
                       route: .pid(app.app.processIdentifier))
            actResult = ["ok": true, "via": "pid-mouse", "verification": unverified("synthetic_input")]
        } else {
            guard let hit = elementAtPoint(app.app.processIdentifier, screen),
                  let t = pressable(hit) else {
                return ["ok": false, "reasonCode": "no_ax_action_at_point"]
            }
            let err = AXUIElementPerformAction(t.element, t.action as CFString)
            actResult = ["ok": err == .success, "via": "hit-test", "action": t.action,
                         "verification": unverified("axpress_unasserted")]
            if err != .success { actResult["reasonCode"] = "ax_action_failed" }
        }
        actResult.merge(pointPayload(screen, space: space)) { _, new in new }
    } else if let text = req["text"] as? String {
        guard let app = resolveAppSafe(appSpec) else {
            return ["ok": false, "reasonCode": "app_not_found"]
        }
        var targetEl: AXUIElement?
        if let ref = req["ref"] as? String {
            if cache[ref] == nil, let fresh = snapshot(appSpec) { cacheStore(fresh) }
            if let stale = cacheStale(ref) { return stale }
            guard cache[ref] != nil else { return ["ok": false, "reasonCode": "stale_ref", "ref": ref] }
            targetEl = cache[ref]
        } else {
            var f: CFTypeRef?
            if AXUIElementCopyAttributeValue(app.ax, kAXFocusedUIElementAttribute as CFString, &f) == .success {
                targetEl = (f as! AXUIElement)
            }
        }
        var wrote = false
        if let el = targetEl {
            let previous = readBack(el)
            if insertText(into: el, text) {
                wrote = true
                actResult = ["ok": true, "via": "ax",
                             "verification": verifyWrite(el, before: previous, expected: text)]
            }
        }
        if !wrote {
            // AX 写不进去（webview / 自绘控件）：定向投递键盘，不抢焦点。
            typeText(text, route: route)
            actResult = ["ok": true, "via": route.label == "pid" ? "pid" : "keyboard",
                         "verification": unverified("synthetic_input")]
        }
    } else if let k = req["key"] as? String {
        guard parseKey(k) != nil else {
            return ["ok": false, "reasonCode": "invalid_key", "key": k]
        }
        guard let app = resolveAppSafe(appSpec) else {
            return ["ok": false, "reasonCode": "app_not_found"]
        }
        if wantActivate,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != app.app.processIdentifier {
            activate(app)
        }
        if wantActivate {
            pressKey(k)
            actResult = ["ok": true, "via": "keyboard", "verification": unverified("synthetic_input")]
        } else {
            pressKey(k, route: .pid(app.app.processIdentifier))
            actResult = ["ok": true, "via": "pid", "verification": unverified("synthetic_input")]
        }
    } else {
        return ["ok": false, "reasonCode": "bad_args"]
    }

    // ---- 等变化 ----
    let actMs = Int(Date().timeIntervalSince(tActStart) * 1000)
    let started = Date()
    var changed = false
    var waited = 0
    while waited < timeoutMs {
        usleep(45_000)
        waited = Int(Date().timeIntervalSince(started) * 1000)
        guard let now = snapshot(appSpec, withActions: false) else { continue }
        if signature(now) != sigBefore {
            changed = true
            break
        }
    }

    var out = actResult
    out["changed"] = changed
    out["actMs"] = actMs
    out["waitedMs"] = waited
    out["before"] = sigBefore
    // AX 动作可能返回失败但已经生效（典型：AXOpen 打开视图后把被点的行销毁了）。
    // 界面确实变了就是更强的证据：ok 转 true，原始错误留在 providerError 里。
    if changed, (out["ok"] as? Bool) != true {
        out["providerError"] = out["reasonCode"] ?? "ax_action_failed"
        out["reasonCode"] = ""
        out["ok"] = true
    }
    out["verification"] = combineVerification(out["verification"] as? [String: Any], changed: changed)
    if !changed { out["note"] = "界面没有变化：动作可能没生效，或者这个动作本来就不改界面" }
    return out
}

/// 合成输入的 unverified 不能因为"界面变了"就升级成 verified ——
/// 变了不等于这串字落到了你以为的那个输入框。
func combineVerification(_ base: [String: Any]?, changed: Bool) -> [String: Any] {
    if let base, (base["state"] as? String) == "verified" { return base }
    if let base, let reason = base["reason"] as? String,
       reason != "axpress_unasserted" {
        return base
    }
    return changed ? verified("ui_changed") : (base ?? unverified("ui_unchanged"))
}

func handleClient(_ fd: Int32) {
    var buf = [UInt8]()
    var tmp = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = Darwin.read(fd, &tmp, tmp.count)
        if n <= 0 { break }
        buf.append(contentsOf: tmp[0..<n])
        if buf.contains(0x0A) { break }
    }
    guard let text = String(bytes: buf, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        writeLine(fd, ["ok": false, "reasonCode": "empty_request"]); return
    }
    guard let req = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
        writeLine(fd, ["ok": false, "reasonCode": "bad_json"]); return
    }
    let cmd = req["cmd"] as? String ?? ""
    let appSpec = req["app"] as? String ?? ""

    // 只有写动作上 HUD；snapshot/ping 之类不弹，否则屏幕会一直闪。
    let hudWorthy = ["click", "set", "type", "key", "scroll", "actAndWait"].contains(cmd)
    hudCommand = hudWorthy ? cmd : nil
    if hudWorthy {
        StatusHUD.shared.begin(cmd: cmd, app: appSpec)
    }

    switch cmd {
    case "ping":
        writeLine(fd, ["ok": true, "pid": getpid(), "cached": cache.count, "app": cacheApp])

    case "snapshot":
        let maxN = req["max"] as? Int ?? 4000
        let t0 = Date()
        guard resolveAppSafe(appSpec) != nil else {
            writeLine(fd, ["ok": false, "reasonCode": "app_not_found", "app": appSpec,
                           "running": liveApps().compactMap { $0.bundleIdentifier }.sorted().prefix(40).map { $0 }])
            return
        }
        let wantActions = (req["actions"] as? Bool) ?? true
        guard let snap = snapshot(appSpec, maxN: maxN, withActions: wantActions) else {
            writeLine(fd, ["ok": false, "reasonCode": "no_window", "app": appSpec]); return
        }
        let tWalk = Date()
        cacheStore(snap)
        var out = toJSON(snap)
        let tJson = Date()
        out["cached"] = cache.count
        out["walkMs"] = Int(tWalk.timeIntervalSince(t0) * 1000)
        out["jsonMs"] = Int(tJson.timeIntervalSince(tWalk) * 1000)
        out["nodes"] = snap.nodes.count
        writeLine(fd, out)

    case "click":
        if let ref = req["ref"] as? String {
            var r = cachedPress(ref)
            if r["ok"] as? Bool != true {
                // 缓存失效 → 重取一次再试
                guard let snap = snapshot(appSpec) else {
                    writeLine(fd, ["ok": false, "reasonCode": "no_window", "app": appSpec]); return
                }
                cacheStore(snap)
                r = cachedPress(ref)
            }
            // 重取后还是没有这个 ref：是过期引用，不是未知错误
            if (r["reasonCode"] as? String) == "cache_miss" {
                r = ["ok": false, "reasonCode": "stale_ref", "ref": ref]
            }
            writeLine(fd, r)
        } else if let x = req["x"] as? Double, let y = req["y"] as? Double,
                  ((req["mouse"] as? Bool) == true || (req["via"] as? String) == "pid"
                   || (req["via"] as? String) == "mouse") {
            // 坐标点击。默认 pid：定向投递，不移动光标、不抢焦点。
            // mouse = 真鼠标：会移动指针，必须显式要求。
            let space = (req["space"] as? String) ?? "screen"
            guard let screen = toScreenPoint(CGPoint(x: x, y: y), appSpec: appSpec, space: space) else {
                writeLine(fd, ["ok": false, "reasonCode": "window_not_found",
                               "hint": "--space window 需要目标 app 有可读窗口"]); return
            }
            guard let app = resolveAppSafe(appSpec) else {
                writeLine(fd, ["ok": false, "reasonCode": "app_not_found", "app": appSpec]); return
            }
            let mouseButton: CGMouseButton = (req["button"] as? String) == "right" ? .right : .left
            let count = (req["count"] as? Int) ?? 1
            if (req["via"] as? String) == "pid" {
                mouseClick(at: screen, button: mouseButton, count: count,
                           route: .pid(app.app.processIdentifier))
                var out: [String: Any] = ["ok": true, "op": "click", "via": "pid-mouse",
                                          "verification": unverified("synthetic_input")]
                out.merge(pointPayload(screen, space: space)) { _, new in new }
                writeLine(fd, out)
            } else {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.app.processIdentifier {
                    activate(app)
                }
                mouseClick(at: screen, button: mouseButton, count: count)
                var out: [String: Any] = ["ok": true, "op": "click", "via": "daemon-mouse",
                                          "verification": unverified("synthetic_input")]
                out.merge(pointPayload(screen, space: space)) { _, new in new }
                writeLine(fd, out)
            }
        } else if let x = req["x"] as? Double, let y = req["y"] as? Double {
            let space = (req["space"] as? String) ?? "screen"
            guard let screen = toScreenPoint(CGPoint(x: x, y: y), appSpec: appSpec, space: space) else {
                writeLine(fd, ["ok": false, "reasonCode": "window_not_found"]); return
            }
            guard let app = resolveAppSafe(appSpec) else {
                writeLine(fd, ["ok": false, "reasonCode": "app_not_found", "app": appSpec]); return
            }
            guard let hit = elementAtPoint(app.app.processIdentifier, screen),
                  let t = pressable(hit) else {
                writeLine(fd, ["ok": false, "reasonCode": "no_ax_action_at_point"])
                return
            }
            let err = AXUIElementPerformAction(t.element, t.action as CFString)
            var out: [String: Any] = ["ok": err == .success, "action": t.action,
                                      "via": "daemon-hit-test",
                                      "verification": unverified("axpress_unasserted")]
            out.merge(pointPayload(screen, space: space)) { _, new in new }
            writeLine(fd, out)
        } else {
            writeLine(fd, ["ok": false, "reasonCode": "bad_args"])
        }

    case "set":
        guard let ref = req["ref"] as? String, let v = req["value"] as? String else {
            writeLine(fd, ["ok": false, "reasonCode": "bad_args"]); return
        }
        // daemon 刚重启 / 缓存被清空时，先补一次快照再动作
        if cache[ref] == nil, let snap = snapshot(appSpec) { cacheStore(snap) }
        guard let el = cache[ref] else {
            writeLine(fd, ["ok": false, "reasonCode": "cache_miss"]); return
        }
        if let stale = cacheStale(ref) { writeLine(fd, stale); return }
        let before = readBack(el)
        let ok = setValue(into: el, v)
        writeLine(fd, ["ok": ok, "ref": ref, "via": "ax",
                       "verification": ok ? verifyWrite(el, before: before, expected: v)
                                          : unverified("set_failed")])

    case "type":
        guard let t = req["text"] as? String else {
            writeLine(fd, ["ok": false, "reasonCode": "bad_args"]); return
        }
        guard let app = resolveAppSafe(appSpec) else {
            writeLine(fd, ["ok": false, "reasonCode": "app_not_found", "app": appSpec]); return
        }
        var targetEl: AXUIElement?
        if let ref = req["ref"] as? String {
            if cache[ref] == nil, let snap = snapshot(appSpec) { cacheStore(snap) }
            if let stale = cacheStale(ref) { writeLine(fd, stale); return }
            targetEl = cache[ref]
        } else {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(app.ax, kAXFocusedUIElementAttribute as CFString, &focused) == .success {
                targetEl = (focused as! AXUIElement)
            }
        }
        if let el = targetEl {
            let before = readBack(el)
            if insertText(into: el, t) {
                writeLine(fd, ["ok": true, "chars": t.count, "via": "ax",
                               "verification": verifyWrite(el, before: before, expected: t)])
                return
            }
        }
        // AX 写不进去：定向投递键盘事件。不激活 app，所以不会打断正在用电脑的人；
        // 代价是目标窗口不是 key window 时事件可能被丢弃 —— 结果标 unverified。
        typeText(t, route: .pid(app.app.processIdentifier))
        writeLine(fd, ["ok": true, "chars": t.count, "via": "pid",
                       "verification": unverified("synthetic_input")])

    case "actAndWait":
        let timeout = (req["timeoutMs"] as? Int) ?? 1500
        writeLine(fd, actAndWait(req, appSpec: appSpec, timeoutMs: timeout))

    case "signature":
        guard let snap = snapshot(appSpec) else {
            writeLine(fd, ["ok": false, "reasonCode": "no_window"]); return
        }
        writeLine(fd, ["ok": true, "signature": signature(snap)])

    case "activate":
        guard let app = resolveAppSafe(appSpec) else {
            writeLine(fd, ["ok": false, "reasonCode": "app_not_found", "app": appSpec]); return
        }
        activate(app)
        writeLine(fd, ["ok": true, "op": "activate", "app": appSpec])

    case "key":
        guard let k = req["key"] as? String else {
            writeLine(fd, ["ok": false, "reasonCode": "bad_args"]); return
        }
        guard parseKey(k) != nil else {
            writeLine(fd, ["ok": false, "reasonCode": "invalid_key", "key": k]); return
        }
        guard let app = resolveAppSafe(appSpec) else {
            writeLine(fd, ["ok": false, "reasonCode": "app_not_found", "app": appSpec]); return
        }
        // 默认：先查菜单栏（后台就能触发，最可靠），再定向投递。
        // 需要真键盘（焦点已在目标窗口）时传 activate=true。
        if (req["activate"] as? Bool) == true {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.app.processIdentifier {
                activate(app)
            }
            pressKey(k)
            writeLine(fd, ["ok": true, "op": "key", "key": k, "via": "keyboard",
                           "verification": unverified("synthetic_input")])
        } else {
            if let (key, mods) = chordToMenuItem(k),
               findAndPressMenuItem(app.ax, key: key, mods: mods) {
                writeLine(fd, ["ok": true, "op": "key", "key": k, "via": "menu-item",
                               "verification": unverified("axpress_unasserted")])
                return
            }
            pressKey(k, route: .pid(app.app.processIdentifier))
            writeLine(fd, ["ok": true, "op": "key", "key": k, "via": "pid",
                           "verification": unverified("synthetic_input")])
        }

    case "scroll":
        guard let ref = req["ref"] as? String else {
            writeLine(fd, ["ok": false, "reasonCode": "bad_args"]); return
        }
        if cache[ref] == nil, let snap = snapshot(appSpec) { cacheStore(snap) }
        guard let el = cache[ref] else {
            writeLine(fd, ["ok": false, "reasonCode": "cache_miss"]); return
        }
        if let stale = cacheStale(ref) { writeLine(fd, stale); return }
        let dir = (req["direction"] as? String) ?? "down"
        let pages = (req["pages"] as? NSNumber)?.doubleValue ?? 1
        let axAction: String
        switch dir {
        case "up": axAction = "AXScrollUpByPage"
        case "down": axAction = "AXScrollDownByPage"
        case "left": axAction = "AXScrollLeftByPage"
        default: axAction = "AXScrollRightByPage"
        }
        var cursor: AXUIElement? = el
        var hops = 0
        while let c = cursor, hops < 10 {
            var acts: CFArray?
            if AXUIElementCopyActionNames(c, &acts) == .success,
               let list = acts as? [String], list.contains(axAction) {
                for _ in 0..<max(1, Int(pages.rounded())) {
                    _ = AXUIElementPerformAction(c, axAction as CFString)
                }
                writeLine(fd, ["ok": true, "op": "scroll", "direction": dir, "via": "ax",
                               "action": axAction, "verification": unverified("axpress_unasserted")])
                return
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &parentRef) == .success,
               let p = parentRef as! AXUIElement? { cursor = p } else { cursor = nil }
            hops += 1
        }
        // 容器没有 AX 滚动动作：定向滚轮，不动光标、不抢焦点
        guard let app = resolveAppSafe(appSpec), let center = elementCenter(el) else {
            writeLine(fd, ["ok": false, "reasonCode": "no_geometry"]); return
        }
        let dy: Int32 = (dir == "up" ? 1 : -1) * Int32(10 * pages)
        scrollWheel(at: center, dy: dy, route: .pid(app.app.processIdentifier))
        var scrollOut: [String: Any] = ["ok": true, "op": "scroll", "direction": dir,
                                        "via": "pid-wheel",
                                        "verification": unverified("synthetic_input")]
        scrollOut.merge(pointPayload(center, space: "screen")) { _, new in new }
        writeLine(fd, scrollOut)

    case "invalidate":
        cache.removeAll(); cacheMeta.removeAll(); cacheApp = ""
        writeLine(fd, ["ok": true])

    case "shutdown":
        writeLine(fd, ["ok": true])
        exit(0)

    default:
        writeLine(fd, ["ok": false, "reasonCode": "unknown_cmd", "cmd": cmd])
    }
}

/// socket 主循环。跑在后台队列：主线程要留给 NSApplication 的 runloop（HUD）。
func socketLoop(path: String) -> Never {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { die("socket() failed", code: 20) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8.prefix(103))
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { die("bind failed: \(String(cString: strerror(errno)))", code: 20) }
    guard listen(fd, 64) == 0 else { die("listen failed", code: 20) }
    print("READY \(path)")
    fflush(stdout)
    while true {
        let c = accept(fd, nil, nil)
        if c < 0 { continue }
        handleClient(c)
        close(c)
    }
}

func serveDaemon(path: String) -> Never {
    // SCU_HUD=0（CI / 无 WindowServer）时保持纯后台，不起 AppKit。
    guard ProcessInfo.processInfo.environment["SCU_HUD"] != "0" else {
        socketLoop(path: path)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // 不占 Dock、不抢焦点
    DispatchQueue.global(qos: .userInitiated).async {
        socketLoop(path: path)
    }
    app.run()
    exit(0)
}

switch cmd {

case "serve":
    let sock = args.flag("socket") ?? (NSTemporaryDirectory() + "scu-ax.sock")
    serveDaemon(path: sock)

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
    for app in liveApps() where app.activationPolicy == .regular {
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
    for app in liveApps() where app.activationPolicy == .regular {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.6)
        // 只数真窗口：Finder 只有桌面时也会在 AXWindows 里塞代理元素
        let ws = ((attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter { isWindow($0) }
        let titles = ws.compactMap { asText(attr($0, kAXTitleAttribute)) }
        list.append(["name": app.localizedName ?? "", "bundle": app.bundleIdentifier ?? "",
                     "pid": app.processIdentifier, "windows": ws.count,
                     "titles": Array(titles.prefix(3))])
    }
    emit(["apps": list, "count": list.count])

case "snapshot":
    guard let appSpec = args.flag("app") else { die("missing --app", code: 4) }
    guard let s = snapshot(appSpec, maxN: args.int("max", 4000)) else {
        let app = resolveAppSafe(appSpec)
        let name = app?.app.localizedName ?? appSpec
        die("no_window: \(name) 没有可操作的窗口（可能只有桌面、被最小化，或显示器休眠）", code: 3)
    }
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
    let via = args.flag("via") ?? "ax"
    let wantMouse = via == "mouse"
    let wantPid = via == "pid"
    let space = args.flag("space") ?? "screen"

    // ---------- click ----------
    if op == "click" {
        let app = resolveApp(appSpec)

        // 坐标点击
        if let xs = args.flag("x"), let ys = args.flag("y"),
           let px = Double(xs), let py = Double(ys) {
            guard let pt = toScreenPoint(CGPoint(x: px, y: py), appSpec: appSpec, space: space) else {
                emit(["ok": false, "reasonCode": "window_not_found",
                      "hint": "--space window 需要目标 app 有可读窗口"]); exit(3)
            }
            let pointOut = pointPayload(pt, space: space)
            if wantPid {
                // 定向投递：不移动真实光标、不抢焦点。
                mouseClick(at: pt, button: (args.flag("button") == "right") ? .right : .left,
                           count: args.int("count", 1), route: .pid(app.app.processIdentifier))
                var r: [String: Any] = ["ok": true, "op": "click", "via": "pid-mouse",
                                        "verification": unverified("synthetic_input")]
                r.merge(pointOut) { _, new in new }
                emit(r)
                break
            }
            if wantMouse {
                requireTakeOver(args, why: "坐标鼠标点击会移动指针")
                activate(app)
                mouseClick(at: pt, button: (args.flag("button") == "right") ? .right : .left,
                           count: args.int("count", 1))
                var r: [String: Any] = ["ok": true, "op": "click", "via": "mouse",
                                        "verification": unverified("synthetic_input")]
                r.merge(pointOut) { _, new in new }
                emit(r)
                break
            }
            // 默认：命中测试 → 往上找可按祖先 → AXPress。全程不动鼠标、不抢焦点。
            guard let hit = elementAtPoint(app.app.processIdentifier, pt) else {
                var r: [String: Any] = ["ok": false, "reasonCode": "no_element_at_point",
                                        "hint": "该坐标没有可访问元素（可能是 Electron 自绘区域）。"
                                              + "需要真的点像素时用 --via pid（定向投递）"
                                              + "或 --via mouse --take-over（移动光标）"]
                r.merge(pointOut) { _, new in new }
                emit(r)
                exit(13)
            }
            guard let t = pressable(hit) else {
                var r: [String: Any] = ["ok": false, "reasonCode": "no_ax_action_at_point",
                                        "element": elementSnapshot(hit),
                                        "hint": "命中了元素但没有可执行动作。需要真的点像素时用 --via pid 或 --via mouse --take-over"]
                r.merge(pointOut) { _, new in new }
                emit(r)
                exit(13)
            }
            let err = AXUIElementPerformAction(t.element, t.action as CFString)
            var r: [String: Any] = ["ok": err == .success, "op": "click", "via": "ax-hit-test",
                                    "action": t.action,
                                    "verification": unverified("axpress_unasserted"),
                                    "element": elementSnapshot(t.element)]
            r.merge(pointOut) { _, new in new }
            if err != .success { r["reasonCode"] = "ax_action_failed" }
            emit(r)
            if err != .success { exit(14) }
            break
        }

        // 元素点击
        guard let s = snapshot(appSpec) else {
        die("no_window: \(appSpec) 没有可操作的窗口", code: 3)
    }
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

        // --via pid：定向投递坐标点击，不激活窗口、不移动真实光标
        if wantPid {
            guard let p = centerOf(s.nodes, target, keep: s.keep) else {
                emit(["ok": false, "reasonCode": "no_geometry", "ref": n.ref]); exit(8)
            }
            mouseClick(at: p, button: (args.flag("button") == "right") ? .right : .left,
                       count: args.int("count", 1), route: .pid(s.app.app.processIdentifier))
            var r: [String: Any] = ["ok": true, "op": "click", "ref": n.ref, "via": "pid-mouse",
                                    "verification": unverified("synthetic_input")]
            r.merge(pointPayload(p, space: "screen")) { _, new in new }
            emit(r)
            break
        }

        // 默认永远先试 AX；只有显式 --via mouse 才动鼠标
        if !wantMouse {
            // 注意：这里刻意不含 AXShowMenu
            for act in ["AXPress", "AXOpen", "AXConfirm", "AXPick"] where n.actions.contains(act) {
                if AXUIElementPerformAction(s.elems[target], act as CFString) == .success {
                    emit(["ok": true, "op": "click", "ref": n.ref, "via": "ax", "action": act,
                          "verification": unverified("axpress_unasserted")])
                    exit(0)
                }
            }
            // 自己也按不动，试试祖先
            if let t = pressable(s.elems[target]) {
                if AXUIElementPerformAction(t.element, t.action as CFString) == .success {
                    emit(["ok": true, "op": "click", "ref": n.ref, "via": "ax-ancestor",
                          "action": t.action, "verification": unverified("axpress_unasserted")])
                    exit(0)
                }
            }
            emit(["ok": false, "reasonCode": "no_ax_action", "ref": n.ref, "role": n.role,
                  "hint": "这个元素没有可执行的无障碍动作。需要真点像素时用 --via pid（定向投递）"
                        + "或 --via mouse --take-over（移动光标）"])
            exit(13)
        }

        requireTakeOver(args, why: "鼠标点击会移动指针")
        guard let p = centerOf(s.nodes, target, keep: s.keep) else {
            emit(["ok": false, "reasonCode": "no_geometry", "ref": n.ref]); exit(8)
        }
        activate(s.app)
        mouseClick(at: p, button: (args.flag("button") == "right") ? .right : .left,
                   count: args.int("count", 1))
        var r: [String: Any] = ["ok": true, "op": "click", "ref": n.ref, "via": "mouse",
                                "verification": unverified("synthetic_input")]
        r.merge(pointPayload(p, space: "screen")) { _, new in new }
        emit(r)
        break
    }

    // ---------- set ----------
    if op == "set" {
        guard let s = snapshot(appSpec) else {
        die("no_window: \(appSpec) 没有可操作的窗口", code: 3)
    }
        guard let ref = args.flag("ref"), let i = findNode(s, ref: ref) else {
            emit(["ok": false, "reasonCode": "stale_ref"]); exit(5)
        }
        guard let v = args.flag("value") else { die("missing --value", code: 4) }
        let el = s.elems[i]
        let before = readBack(el)
        let ok = setValue(into: el, v)
        emit(["ok": ok, "op": "set", "ref": ref, "via": "ax",
              "verification": ok ? verifyWrite(el, before: before, expected: v)
                                 : unverified("set_failed"),
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
            guard let s = snapshot(appSpec) else {
        die("no_window: \(appSpec) 没有可操作的窗口", code: 3)
    }
            if let i = findNode(s, ref: ref) { targetEl = s.elems[i] }
        } else {
            var f: CFTypeRef?
            if AXUIElementCopyAttributeValue(app.ax, kAXFocusedUIElementAttribute as CFString, &f) == .success {
                targetEl = (f as! AXUIElement)
            }
        }
        if let el = targetEl {
            let before = readBack(el)
            if insertText(into: el, t) {
                emit(["ok": true, "op": "type", "via": "ax", "chars": t.count,
                      "verification": verifyWrite(el, before: before, expected: t)])
                break
            }
        }
        // AX 写不进去（webview / 自绘控件）：默认定向投递，不抢焦点。
        // 目标窗口不是 key window 时事件可能被丢弃 —— 用 --wait 或 --take-over 兜。
        if !wantMouse && !args.has("take-over") {
            typeText(t, route: .pid(app.app.processIdentifier))
            emit(["ok": true, "op": "type", "via": "pid", "chars": t.count,
                  "verification": unverified("synthetic_input")])
            break
        }
        requireTakeOver(args, why: "键盘输入需要目标窗口获得焦点")
        activate(app)
        if t.count > 8 && !args.has("no-paste") {
            _ = pasteText(t)
            emit(["ok": true, "op": "type", "via": "paste", "chars": t.count,
                  "verification": unverified("clipboard_paste")])
        } else {
            typeText(t)
            emit(["ok": true, "op": "type", "via": "keyboard", "chars": t.count,
                  "verification": unverified("synthetic_input")])
        }
        break
    }

    // ---------- key ----------
    if op == "key" {
        guard let k = args.flag("key") else { die("missing --key", code: 4) }
        let app = resolveApp(appSpec)
        if !wantMouse && !args.has("take-over") {
            // 先试菜单栏：命中就能在后台触发，不碰焦点
            if let (key, mods) = chordToMenuItem(k), findAndPressMenuItem(app.ax, key: key, mods: mods) {
                emit(["ok": true, "op": "key", "key": k, "via": "menu-item",
                      "verification": unverified("axpress_unasserted")])
                break
            }
            // 不是菜单项：定向投递，不抢焦点
            guard parseKey(k) != nil else {
                emit(["ok": false, "reasonCode": "invalid_key", "key": k]); exit(4)
            }
            pressKey(k, route: .pid(app.app.processIdentifier))
            emit(["ok": true, "op": "key", "key": k, "via": "pid",
                  "verification": unverified("synthetic_input")])
            break
        }
        requireTakeOver(args, why: "发送组合键需要目标窗口聚焦")
        activate(app)
        pressKey(k)
        emit(["ok": true, "op": "key", "key": k, "via": "keyboard",
              "verification": unverified("synthetic_input")])
        break
    }

    // ---------- scroll ----------
    if op == "scroll" {
        guard let s = snapshot(appSpec) else {
        die("no_window: \(appSpec) 没有可操作的窗口", code: 3)
    }
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
                emit(["ok": true, "op": "scroll", "direction": dir, "via": "ax",
                      "action": axAction, "verification": unverified("axpress_unasserted")])
                exit(0)
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &parentRef) == .success,
               let p = parentRef as! AXUIElement? { cur = p } else { cur = nil }
            hops += 1
        }
        guard let p = centerOf(s.nodes, i, keep: s.keep) else {
            emit(["ok": false, "reasonCode": "no_geometry"]); exit(8)
        }
        let dy: Int32 = (dir == "up" ? 1 : -1) * Int32(10 * pages)
        // 没有 AX 滚动动作。默认定向投递滚轮，不抢焦点；--via mouse 才移动光标。
        if !wantMouse && !args.has("take-over") {
            scrollWheel(at: p, dy: dy, route: .pid(s.app.app.processIdentifier))
            var r: [String: Any] = ["ok": true, "op": "scroll", "direction": dir, "via": "pid-wheel",
                                    "verification": unverified("synthetic_input")]
            r.merge(pointPayload(p, space: "screen")) { _, new in new }
            emit(r)
            break
        }
        requireTakeOver(args, why: "这个容器没有 AX 滚动动作，只能合成滚轮事件")
        activate(s.app)
        scrollWheel(at: p, dy: dy)
        var r: [String: Any] = ["ok": true, "op": "scroll", "direction": dir, "via": "wheel",
                                "verification": unverified("synthetic_input")]
        r.merge(pointPayload(p, space: "screen")) { _, new in new }
        emit(r)
        break
    }

    die("unknown --op \(op)", code: 4)

case "winid":
    guard let appSpec = args.flag("app") else { die("missing --app", code: 4) }
    guard let app = resolveAppSafe(appSpec) else {
        emit(["ok": false, "reasonCode": "app_not_found", "app": appSpec]); exit(2)
    }
    let bounds = targetWindow(app).flatMap { windowRect($0) }
    guard let id = cgWindowId(pid: app.app.processIdentifier, like: bounds) else {
        emit(["ok": false, "reasonCode": "no_cg_window", "app": appSpec]); exit(3)
    }
    var out: [String: Any] = ["ok": true, "id": id, "pid": Int(app.app.processIdentifier)]
    if let b = bounds { out["bounds"] = ["x": b.origin.x, "y": b.origin.y, "w": b.width, "h": b.height] }
    emit(out)

case "verify":
    guard let appSpec = args.flag("app"), let ref = args.flag("ref") else {
        die("missing --app/--ref", code: 4)
    }
    guard let s = snapshot(appSpec) else {
        die("no_window: \(appSpec) 没有可操作的窗口", code: 3)
    }
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
