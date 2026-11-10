// Foldlet — iOS-style app folders for the macOS Dock.
// https://github.com/wmtaff/foldlet  ·  MIT License
//
// Every group is its own tiny app bundle (~/Applications/Foldlet/<Name>.app),
// so it can live anywhere in the app section of the Dock. The Dock icon is a
// live 3×3 grid of the member apps' icons; clicking it pops up a grid panel.

import AppKit
import UniformTypeIdentifiers

// MARK: - Helpers

@discardableResult
func sh(_ exe: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func makeError(_ msg: String) -> NSError {
    NSError(domain: "Foldlet", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
}

func displayName(_ url: URL) -> String {
    let n = FileManager.default.displayName(atPath: url.path)
    return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
}

enum Env {
    static let fm = FileManager.default
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.wmtaff.foldlet.unknown" }
    static func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }
    static var name: String { info("CFBundleDisplayName") ?? info("CFBundleName") ?? "Group" }
    static let supportDir: URL = {
        let u = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Foldlet", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var dataURL: URL { supportDir.appendingPathComponent(bundleID + ".json") }
    static var groupsDir: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
    static var selfPath: String { Bundle.main.bundleURL.standardizedFileURL.path }
}

// MARK: - Model

struct Member: Codable, Equatable {
    var bundleID: String?
    var path: String
}

final class Store {
    private(set) var members: [Member] = []
    var onChange: (() -> Void)?

    init() { load() }

    private func load() {
        guard let d = try? Data(contentsOf: Env.dataURL),
              let m = try? JSONDecoder().decode([Member].self, from: d) else { return }
        members = m
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(members) { try? d.write(to: Env.dataURL, options: .atomic) }
        onChange?()
    }

    /// Prefer the bundle ID so groups survive apps moving or updating.
    func url(for m: Member) -> URL? {
        if let id = m.bundleID, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        return Env.fm.fileExists(atPath: m.path) ? URL(fileURLWithPath: m.path) : nil
    }

    var resolved: [(index: Int, url: URL)] {
        members.enumerated().compactMap { (i, m) in
            guard let u = url(for: m) else { return nil }
            return (index: i, url: u)
        }
    }

    func contains(path: String, bundleID: String?) -> Bool {
        members.contains { $0.path == path || ($0.bundleID != nil && $0.bundleID == bundleID) }
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for raw in urls {
            let u = ((try? URL(resolvingAliasFileAt: raw)) ?? raw).standardizedFileURL
            guard u.pathExtension.lowercased() == "app", u.path != Env.selfPath else { continue }
            let bid = Bundle(url: u)?.bundleIdentifier
            if contains(path: u.path, bundleID: bid) { continue }
            members.append(Member(bundleID: bid, path: u.path))
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    func remove(at i: Int) {
        guard members.indices.contains(i) else { return }
        members.remove(at: i)
        save()
    }

    func move(from: Int, to: Int) {
        guard from != to, members.indices.contains(from) else { return }
        let m = members.remove(at: from)
        members.insert(m, at: min(max(to, 0), members.count))
        save()
    }
}

// MARK: - Dock preferences (com.apple.dock persistent-apps)

enum DockPrefs {
    static let domain = "com.apple.dock" as CFString
    static let key = "persistent-apps" as CFString

    static func tiles() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue(key, domain) as? [[String: Any]]) ?? []
    }

    static func save(_ t: [[String: Any]]) {
        CFPreferencesSetAppValue(key, t as NSArray, domain)
        CFPreferencesAppSynchronize(domain)
    }

    static func tileData(_ t: [String: Any]) -> [String: Any] { (t["tile-data"] as? [String: Any]) ?? [:] }

    static func path(_ t: [String: Any]) -> String? {
        guard let fd = tileData(t)["file-data"] as? [String: Any], let s = fd["_CFURLString"] as? String else { return nil }
        if let u = URL(string: s), u.isFileURL { return u.standardizedFileURL.path }
        return URL(fileURLWithPath: s).standardizedFileURL.path
    }

    static func bundleID(_ t: [String: Any]) -> String? { tileData(t)["bundle-identifier"] as? String }
    static func label(_ t: [String: Any]) -> String? { tileData(t)["file-label"] as? String }

    static func fileData(_ url: URL) -> [String: Any] {
        ["_CFURLString": url.absoluteString, "_CFURLStringType": 15] as [String: Any]
    }

    static func newTile(_ url: URL) -> [String: Any] {
        ["tile-type": "file-tile", "tile-data": ["file-data": fileData(url)] as [String: Any]] as [String: Any]
    }

    static func insert(_ url: URL, after: URL?) {
        var t = tiles()
        let afterPath = after?.standardizedFileURL.path
        let idx = t.firstIndex(where: { path($0) == afterPath }).map { $0 + 1 } ?? t.count
        t.insert(newTile(url), at: idx)
        save(t)
    }

    @discardableResult
    static func remove(where pred: ([String: Any]) -> Bool) -> Bool {
        var t = tiles()
        let n = t.count
        t.removeAll(where: pred)
        guard t.count != n else { return false }
        save(t)
        return true
    }

    static func replace(_ old: URL, with new: URL, label: String) {
        var t = tiles()
        let op = old.standardizedFileURL.path
        for i in t.indices where path(t[i]) == op {
            var td = tileData(t[i])
            td["file-data"] = fileData(new)
            td["file-label"] = label
            t[i]["tile-data"] = td
        }
        save(t)
    }

    static func restart() { sh("/usr/bin/killall", ["Dock"]) }
}

// MARK: - Icon rendering

enum IconRenderer {
    /// iOS-folder-style icon: rounded tile with a 3×3 grid of mini app icons.
    static func render(_ urls: [URL], size: CGFloat = 1024) -> NSImage {
        let icons = urls.prefix(9).map { NSWorkspace.shared.icon(forFile: $0.path) }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Standard macOS icon body: 824/1024 centred.
            let inset = size * 100 / 1024
            let body = rect.insetBy(dx: inset, dy: inset)
            let radius = body.width * 0.225
            let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = size * 0.022
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.010)
            shadow.set()
            NSColor(calibratedWhite: 0.88, alpha: 0.92).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGradient(starting: NSColor(calibratedWhite: 1.0, alpha: 0.55),
                       ending: NSColor(calibratedWhite: 0.78, alpha: 0.45))?.draw(in: shape, angle: -90)
            NSColor(calibratedWhite: 1.0, alpha: 0.6).setStroke()
            shape.lineWidth = size * 0.004
            shape.stroke()

            let n = 3
            let pad = body.width * 0.085
            let gap = body.width * 0.02
            let cell = (body.width - 2 * pad - CGFloat(n - 1) * gap) / CGFloat(n)
            for (i, icon) in icons.enumerated() {
                let r = i / n, c = i % n
                let x = body.minX + pad + CGFloat(c) * (cell + gap)
                let y = body.maxY - pad - CGFloat(r + 1) * cell - CGFloat(r) * gap
                icon.draw(in: NSRect(x: x, y: y, width: cell, height: cell),
                          from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: - Group bundle management

enum Groups {
    static func sanitize(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return t.isEmpty ? nil : t
    }

    /// Custom icons live in "Icon\r" at the bundle root, which codesign refuses; strip before signing.
    static func clearCustomIcon(_ url: URL) {
        NSWorkspace.shared.setIcon(nil, forFile: url.path, options: [])
        try? FileManager.default.removeItem(at: url.appendingPathComponent("Icon\r"))
        sh("/usr/bin/xattr", ["-cr", url.path])
    }

    static func setInfo(_ url: URL, name: String, bundleID: String?) throws {
        let p = url.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: p)
        guard var d = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw makeError("Couldn't read the group's Info.plist.")
        }
        d["CFBundleName"] = name
        d["CFBundleDisplayName"] = name
        if let b = bundleID { d["CFBundleIdentifier"] = b }
        let out = try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
        try out.write(to: p, options: .atomic)
    }

    static func sign(_ url: URL) { sh("/usr/bin/codesign", ["--force", "--sign", "-", url.path]) }

    static func newBundleID() -> String { "io.github.wmtaff.foldlet.group." + UUID().uuidString.prefix(8).lowercased() }

    static func create(named name: String) throws {
        let dest = Env.groupsDir.appendingPathComponent(name + ".app")
        if FileManager.default.fileExists(atPath: dest.path) {
            throw makeError("A group named “\(name)” already exists.")
        }
        try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: dest)
        clearCustomIcon(dest)
        try setInfo(dest, name: name, bundleID: newBundleID())
        sign(dest)
        DockPrefs.insert(dest, after: Bundle.main.bundleURL)
        DockPrefs.restart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSWorkspace.shared.openApplication(at: dest, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    struct DockApp { let url: URL; let name: String; let bundleID: String? }

    /// Apps pinned in the Dock, excluding Foldlet groups themselves.
    static func dockApps() -> [DockApp] {
        DockPrefs.tiles().compactMap { t in
            let bid = DockPrefs.bundleID(t)
            if let b = bid, b.hasPrefix("io.github.wmtaff.foldlet.") { return nil }   // another group
            guard let p = DockPrefs.path(t), p.hasSuffix(".app"), p != Env.selfPath else { return nil }
            var u = URL(fileURLWithPath: p)
            if !FileManager.default.fileExists(atPath: p) {
                // Stale Dock path (e.g. a renamed group or a moved app): resolve by bundle ID or skip it.
                guard let b = bid, let alt = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
                u = alt
            }
            if let b = Bundle(url: u), (b.object(forInfoDictionaryKey: "FoldletGroup") as? Bool) == true { return nil }
            return DockApp(url: u, name: DockPrefs.label(t) ?? displayName(u), bundleID: bid)
        }
    }
}

// MARK: - Views

final class GroupPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class TileView: NSView, NSDraggingSource {
    enum Kind { case app(index: Int, url: URL), add }
    static let size = NSSize(width: 88, height: 96)

    let kind: Kind
    weak var controller: Controller?
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var downEvent: NSEvent?
    private var didDrag = false

    init(kind: Kind, controller: Controller) {
        self.kind = kind
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 12

        imageView.frame = NSRect(x: (Self.size.width - 64) / 2, y: 26, width: 64, height: 64)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        label.frame = NSRect(x: 4, y: 6, width: Self.size.width - 8, height: 16)
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor

        switch kind {
        case .app(_, let url):
            imageView.image = NSWorkspace.shared.icon(forFile: url.path)
            label.stringValue = displayName(url)
            toolTip = label.stringValue
        case .add:
            let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            imageView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")?.withSymbolConfiguration(cfg)
            imageView.imageScaling = .scaleNone
            imageView.contentTintColor = .secondaryLabelColor
            label.stringValue = "Add"
            label.textColor = .secondaryLabelColor
            toolTip = "Add apps (or drop apps anywhere on this panel)"
        }
        addSubview(imageView)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func draw(_ dirtyRect: NSRect) {
        guard case .add = kind else { return }
        let r = imageView.frame.insetBy(dx: 5, dy: 5)
        let p = NSBezierPath(roundedRect: r, xRadius: 13, yRadius: 13)
        p.lineWidth = 1.5
        p.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
        p.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        didDrag = false
        imageView.alphaValue = 0.6
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let d = downEvent, case .app(_, let url) = kind else { return }
        let dx = event.locationInWindow.x - d.locationInWindow.x
        let dy = event.locationInWindow.y - d.locationInWindow.y
        guard hypot(dx, dy) > 4 else { return }
        didDrag = true
        imageView.alphaValue = 1
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageView.frame, contents: imageView.image)
        beginDraggingSession(with: [item], event: d, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        imageView.alphaValue = 1
        if !didDrag, bounds.contains(convert(event.locationInWindow, from: nil)) { controller?.activate(self) }
        downEvent = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.contextMenu(for: self) }

    // Inside the panel: reorder. Outside: offer a link only (never copy/move the real app).
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .link
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.tileDragEnded(self, at: screenPoint, operation: operation)
    }
}

final class DropView: NSView {
    weak var controller: Controller?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 22
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func appURLs(_ s: NSDraggingInfo) -> [URL] {
        let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { (try? URL(resolvingAliasFileAt: $0)) ?? $0 }
            .filter { $0.pathExtension.lowercased() == "app" }
    }

    private func setHighlight(_ on: Bool) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = on ? 3 : 0
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource is TileView { return .move }
        let ok = !appURLs(sender).isEmpty
        setHighlight(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setHighlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlight(false)
        if let tile = sender.draggingSource as? TileView {
            guard case .app(let from, _) = tile.kind, let c = controller else { return false }
            c.store.move(from: from, to: c.memberIndex(at: convert(sender.draggingLocation, from: nil)))
            return true
        }
        let urls = appURLs(sender)
        guard !urls.isEmpty else { return false }
        controller?.store.add(urls)
        return true
    }
}

// MARK: - Controller

final class Controller: NSObject, NSApplicationDelegate {
    let store = Store()
    var panel: GroupPanel!
    var dropView: DropView!
    var titleLabel: NSTextField!
    var tiles: [TileView] = []
    var columns = 3
    var gridX0: CGFloat = 0
    var anchor = NSEvent.mouseLocation
    let pad: CGFloat = 14, header: CGFloat = 40, radius: CGFloat = 22

    // Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildPanel()
        store.onChange = { [weak self] in self?.storeChanged() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshIcon()
        if CommandLine.arguments.contains("--no-panel") { return }
        showPanel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return false
    }

    func applicationDidResignActive(_ notification: Notification) { hidePanel() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Apps dropped onto the group's Dock icon arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        store.add(urls)
        showPanel()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        for r in store.resolved { m.addItem(item(displayName(r.url), #selector(openMember(_:)), r.url)) }
        if !store.members.isEmpty { m.addItem(.separator()) }
        m.addItem(item("Add Apps…", #selector(chooseApps)))
        m.addItem(item("Add Apps from Dock…", #selector(addFromDock)))
        m.addItem(.separator())
        m.addItem(item("New Group…", #selector(newGroup)))
        m.addItem(item("Rename Group…", #selector(renameGroup)))
        m.addItem(item("Delete Group…", #selector(deleteGroup)))
        return m
    }

    // Building UI

    func item(_ title: String, _ action: Selector, _ obj: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.representedObject = obj
        return i
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(item("Add Apps…", #selector(chooseApps)))
        appMenu.addItem(item("Add Apps from Dock…", #selector(addFromDock)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("New Group…", #selector(newGroup)))
        appMenu.addItem(item("Rename Group…", #selector(renameGroup)))
        appMenu.addItem(item("Delete Group…", #selector(deleteGroup)))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(Env.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func buildPanel() {
        panel = GroupPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar            // above the Dock, below menus
        panel.hidesOnDeactivate = false     // we hide manually so it doesn't pop back on reactivation
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.hidePanel() }

        dropView = DropView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        dropView.controller = self
        dropView.autoresizingMask = [.width, .height]
        installBackdrop()

        titleLabel = NSTextField(labelWithString: Env.name)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        dropView.addSubview(titleLabel)
    }

    /// Panel background. On macOS 26+ use the system Liquid Glass material, the same one
    /// the Dock uses for folder stacks (e.g. Downloads). Earlier systems get a popover-style blur.
    func installBackdrop() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: dropView.frame)
            glass.cornerRadius = radius
            glass.contentView = dropView
            panel.contentView = glass
            return
        }
        #endif
        let effect = NSVisualEffectView(frame: dropView.frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = IconRenderer.roundedMask(radius: radius)
        effect.addSubview(dropView)
        panel.contentView = effect
    }

    func reload() {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = store.resolved.map { TileView(kind: .app(index: $0.index, url: $0.url), controller: self) }
        tiles.append(TileView(kind: .add, controller: self))

        let n = tiles.count
        let ideal = max(3, Int(ceil(Double(n).squareRoot())))
        columns = max(1, min(n, min(5, ideal)))
        let rows = (n + columns - 1) / columns
        let ts = TileView.size
        let gridW = CGFloat(columns) * ts.width
        let w = max(pad * 2 + gridW, 220)
        let h = header + pad + CGFloat(rows) * ts.height
        gridX0 = (w - gridW) / 2

        panel.setContentSize(NSSize(width: w, height: h))
        dropView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        titleLabel.stringValue = Env.name
        titleLabel.frame = NSRect(x: pad, y: h - header + 8, width: w - pad * 2, height: 22)
        for (i, t) in tiles.enumerated() {
            let r = i / columns, c = i % columns
            t.frame = NSRect(x: gridX0 + CGFloat(c) * ts.width,
                             y: h - header - CGFloat(r + 1) * ts.height,
                             width: ts.width, height: ts.height)
            dropView.addSubview(t)
        }
        panel.invalidateShadow()
    }

    /// Member index for a drop point in dropView coordinates (for reordering).
    func memberIndex(at p: NSPoint) -> Int {
        let ts = TileView.size
        let c = min(max(Int((p.x - gridX0) / ts.width), 0), columns - 1)
        let r = max(Int((dropView.bounds.height - header - p.y) / ts.height), 0)
        let ti = r * columns + c
        let appIdx = tiles.compactMap { t -> Int? in
            if case .app(let i, _) = t.kind { return i }
            return nil
        }
        return ti < appIdx.count ? appIdx[ti] : max(store.members.count - 1, 0)
    }

    func position() {
        let size = panel.frame.size
        let m = anchor
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let orient = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        var o: NSPoint
        switch orient {
        case "left":  o = NSPoint(x: max(vis.minX + 8, m.x + 48), y: m.y - size.height / 2)
        case "right": o = NSPoint(x: min(vis.maxX - 8, m.x - 48) - size.width, y: m.y - size.height / 2)
        default:      o = NSPoint(x: m.x - size.width / 2, y: max(vis.minY + 8, m.y + 48))
        }
        o.x = min(max(o.x, vis.minX + 8), vis.maxX - size.width - 8)
        o.y = min(max(o.y, vis.minY + 8), vis.maxY - size.height - 8)
        panel.setFrameOrigin(o)
    }

    // Panel show / hide

    func showPanel(reanchor: Bool = true) {
        if reanchor { anchor = NSEvent.mouseLocation }
        reload()
        position()
        NSApp.activate(ignoringOtherApps: true)
        let wasVisible = panel.isVisible
        if !wasVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self.panel.animator().alphaValue = 1
            }
        }
    }

    func hidePanel() { panel.orderOut(nil) }

    func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }

    func storeChanged() {
        refreshIcon()
        if panel.isVisible { reload(); position() }
    }

    func refreshIcon() {
        let img = IconRenderer.render(store.resolved.map { $0.url })
        NSApp.applicationIconImage = img
        // Also stamp it on the bundle so the Dock shows it when the group isn't running.
        NSWorkspace.shared.setIcon(img, forFile: Bundle.main.bundlePath, options: [])
    }

    // Tile actions

    func activate(_ tile: TileView) {
        switch tile.kind {
        case .app(_, let url):
            hidePanel()
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        case .add:
            addMenu().popUp(positioning: nil, at: NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), in: tile)
        }
    }

    func addMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Choose Apps…", #selector(chooseApps)))
        m.addItem(item("Add Apps from Dock…", #selector(addFromDock)))
        return m
    }

    func contextMenu(for tile: TileView) -> NSMenu? {
        guard case .app(let idx, let url) = tile.kind else { return addMenu() }
        let m = NSMenu()
        m.addItem(item("Open", #selector(openMember(_:)), url))
        m.addItem(item("Show in Finder", #selector(revealMember(_:)), url))
        m.addItem(.separator())
        m.addItem(item("Move to Dock", #selector(moveToDock(_:)), idx))
        m.addItem(item("Remove from Group", #selector(removeMember(_:)), idx))
        return m
    }

    /// Dragging an app out of the panel removes it from the group (like iOS).
    func tileDragEnded(_ tile: TileView, at p: NSPoint, operation: NSDragOperation) {
        guard case .app(let idx, _) = tile.kind else { return }
        if panel.isVisible && panel.frame.contains(p) { return }
        store.remove(at: idx)
    }

    @objc func openMember(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        hidePanel()
        NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc func revealMember(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        hidePanel()
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    @objc func removeMember(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        store.remove(at: i)
    }

    @objc func moveToDock(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int, store.members.indices.contains(i),
              let u = store.url(for: store.members[i]) else { return }
        store.remove(at: i)
        DockPrefs.insert(u, after: Bundle.main.bundleURL)
        DockPrefs.restart()
    }

    // Adding apps

    @objc func chooseApps() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        let op = NSOpenPanel()
        op.title = "Add Apps to \(Env.name)"
        op.prompt = "Add"
        op.allowsMultipleSelection = true
        op.canChooseDirectories = false
        op.allowedContentTypes = [.application]
        op.directoryURL = URL(fileURLWithPath: "/Applications")
        if op.runModal() == .OK { store.add(op.urls) }
        showPanel(reanchor: false)
    }

    @objc func addFromDock() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        let apps = Groups.dockApps().filter { !store.contains(path: $0.url.standardizedFileURL.path, bundleID: $0.bundleID) }
        guard !apps.isEmpty else {
            message("Nothing to add", "Every app pinned in your Dock is already in “\(Env.name)”.")
            showPanel(reanchor: false)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Add apps from the Dock to “\(Env.name)”"
        alert.informativeText = "Tick the apps to move into this group."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let rowH: CGFloat = 26, width: CGFloat = 320
        let list = FlippedView(frame: NSRect(x: 0, y: 0, width: width - 20, height: CGFloat(apps.count) * rowH))
        var boxes: [NSButton] = []
        for (i, a) in apps.enumerated() {
            let b = NSButton(checkboxWithTitle: a.name, target: nil, action: nil)
            let icon = NSWorkspace.shared.icon(forFile: a.url.path)
            let att = NSTextAttachment()
            att.image = icon
            att.bounds = NSRect(x: 0, y: -5, width: 18, height: 18)
            let title = NSMutableAttributedString(attachment: att)
            title.append(NSAttributedString(string: "  " + a.name))
            b.attributedTitle = title
            b.frame = NSRect(x: 4, y: CGFloat(i) * rowH + 2, width: width - 28, height: rowH - 4)
            list.addSubview(b)
            boxes.append(b)
        }
        let scrollH = min(CGFloat(apps.count) * rowH, 300)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 30, width: width, height: scrollH))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = list
        let removeBox = NSButton(checkboxWithTitle: "Also remove them from the Dock", target: nil, action: nil)
        removeBox.state = .on
        removeBox.frame = NSRect(x: 0, y: 2, width: width, height: 22)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: scrollH + 32))
        container.addSubview(scroll)
        container.addSubview(removeBox)
        alert.accessoryView = container

        if alert.runModal() == .alertFirstButtonReturn {
            let chosen = zip(apps, boxes).filter { $0.1.state == .on }.map { $0.0 }
            if !chosen.isEmpty {
                store.add(chosen.map { $0.url })
                if removeBox.state == .on {
                    let paths = Set(chosen.map { $0.url.standardizedFileURL.path })
                    let ids = Set(chosen.compactMap { $0.bundleID })
                    let removed = DockPrefs.remove { t in
                        if let p = DockPrefs.path(t), paths.contains(p) { return true }
                        if let b = DockPrefs.bundleID(t), ids.contains(b) { return true }
                        return false
                    }
                    if removed { DockPrefs.restart() }
                }
            }
        }
        showPanel(reanchor: false)
    }

    // Group management

    @objc func newGroup() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        guard let name = prompt("New Foldlet Group", "Name the new group:", "New Group", "Create") else { return }
        do { try Groups.create(named: name) } catch { NSAlert(error: error).runModal() }
    }

    @objc func renameGroup() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        guard let name = prompt("Rename Group", "New name for “\(Env.name)”:", Env.name, "Rename"),
              name != Env.name else { return }
        let old = Bundle.main.bundleURL
        let new = old.deletingLastPathComponent().appendingPathComponent(name + ".app")
        if FileManager.default.fileExists(atPath: new.path) {
            message("Name in use", "A group named “\(name)” already exists.")
            return
        }
        do {
            Groups.clearCustomIcon(old)
            try Groups.setInfo(old, name: name, bundleID: nil)
            Groups.sign(old)
            try FileManager.default.moveItem(at: old, to: new)
            DockPrefs.replace(old, with: new, label: name)
            DockPrefs.restart()
            relaunch(new)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func deleteGroup() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Delete “\(Env.name)”?"
        a.informativeText = "This removes the group and its Dock icon. The apps inside aren't touched."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let me = Env.selfPath
        if DockPrefs.remove(where: { DockPrefs.path($0) == me }) { DockPrefs.restart() }
        try? FileManager.default.removeItem(at: Env.dataURL)
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func relaunch(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", url.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    func prompt(_ title: String, _ text: String, _ def: String, _ button: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = def
        a.accessoryView = f
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return Groups.sanitize(f.stringValue)
    }

    func message(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

// MARK: - Entry point

// Used by uninstall.sh: unpin every Foldlet group from the Dock, then exit.
if CommandLine.arguments.contains("--remove-all-from-dock") {
    let removed = DockPrefs.remove { t in
        guard let p = DockPrefs.path(t), let b = Bundle(path: p) else { return false }
        return (b.object(forInfoDictionaryKey: "FoldletGroup") as? Bool) == true
    }
    if removed { DockPrefs.restart() }
    exit(0)
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
