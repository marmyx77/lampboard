import AppKit
import LampBoardCore

/// The project beside a live session (D136): its folder as a tree, the file
/// the agent is on, a preview, and ⌘L to cite the file or the selected lines
/// in the session's prompt, as a paste and never with an Enter.
///
/// Read-only on purpose: the session is the one that edits. The preview reads
/// the file again when it changes on disk, so what it shows is what the agent
/// just wrote.
@MainActor
final class LiveFilesView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate {

    /// One entry of the tree; a folder reads its entries the first time it opens.
    final class Node: NSObject {
        let path: String
        let isFolder: Bool
        private(set) var loaded: [Node]?
        init(path: String, isFolder: Bool) { self.path = path; self.isFolder = isFolder }
        var name: String { (path as NSString).lastPathComponent }

        /// At most this many entries a folder: a `dist/` of a hundred thousand
        /// files must not hold the window.
        static let most = 2_000

        var children: [Node] {
            if let loaded { return loaded }
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            let entries = urls.map { url in
                (name: url.lastPathComponent, isFolder: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }
            let nodes = ProjectFiles.sorted(entries).prefix(Self.most)
                .map { Node(path: (path as NSString).appendingPathComponent($0.name), isFolder: $0.isFolder) }
            loaded = nodes
            return nodes
        }

        func forget() { loaded = nil }
    }

    /// Where a citation goes: the session's prompt.
    var cite: (String) -> Void = { _ in }

    private var root: Node?
    private let outline = NSOutlineView()
    private let preview = CitingTextView()
    private let follow = NSButton(title: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let citeButton = NSButton(title: "Cite ⌘L", target: nil, action: nil)
    private var shown: (path: String, modified: Date?)?
    private var following: String?
    /// The folder, kept while the panel is closed: nothing is listed, read or
    /// looked at until somebody opens it.
    private var folder: String?
    /// Whether the panel is open.
    var isActive = false { didSet { if isActive { update(folder: folder, following: following) } } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .small
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(picked)
        column.resizingMask = .autoresizingMask
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let tree = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        outline.frame = tree.contentView.bounds
        outline.autoresizingMask = [.width, .height]
        tree.documentView = outline
        tree.hasVerticalScroller = true
        tree.drawsBackground = false
        tree.autohidesScrollers = true

        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.drawsBackground = false
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textContainerInset = NSSize(width: 6, height: 6)
        preview.delegate = self
        preview.onCite = { [weak self] in self?.citeSelection() }
        let text = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        preview.frame = text.contentView.bounds
        text.documentView = preview
        text.autohidesScrollers = true
        text.hasVerticalScroller = true
        text.drawsBackground = false
        preview.minSize = .zero
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]

        follow.bezelStyle = .inline
        follow.controlSize = .small
        follow.target = self
        follow.action = #selector(followPressed)
        follow.isHidden = true
        follow.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingMiddle
        citeButton.bezelStyle = .rounded
        citeButton.controlSize = .small
        citeButton.target = self
        citeButton.action = #selector(citePressed)
        citeButton.isEnabled = false

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(tree)
        split.addArrangedSubview(text)
        for view in [follow, split, status, citeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            follow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            follow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            follow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            split.topAnchor.constraint(equalTo: follow.bottomAnchor, constant: 6),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: citeButton.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            status.centerYAnchor.constraint(equalTo: citeButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: citeButton.leadingAnchor, constant: -6),
            citeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            citeButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            tree.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            text.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        status.stringValue = "Pick a file to read it here."
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The theme's card, as the terminal sits on one.
    /// Drawn, not a layer: a layer here turned the terminal beside it white in
    /// the window's picture.
    func apply(textColor: NSColor, card: NSColor, edge: NSColor) {
        fill = card
        self.edge = edge
        preview.textColor = textColor
        status.textColor = textColor.withAlphaComponent(0.6)
        needsDisplay = true
    }

    private var fill = NSColor.clear
    private var edge = NSColor.clear

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        fill.setFill()
        path.fill()
        edge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The session's folder and the file its agent is on; called every second.
    func update(folder: String?, following: String?) {
        self.folder = folder
        guard isActive else { self.following = following; return }
        if folder != root?.path {
            root = folder.map { Node(path: $0, isFolder: true) }
            outline.reloadData()
            // A file of another folder is not cited against this one.
            if let shown, let folder, ProjectFiles.relative(shown.path, to: folder) == nil { clearPreview() }
        }
        if following != self.following || follow.isHidden != (following == nil) {
            self.following = following
            follow.isHidden = following == nil
            if let following, let folder {
                follow.title = "● Claude is on \(ProjectFiles.relative(following, to: folder) ?? following)"
            }
        }
        refreshPreviewIfChanged()
    }

    /// The file the preview shows, if any.
    var showingPath: String? { shown?.path }

    /// Opens `path` in the tree and the preview.
    func open(_ path: String) {
        reveal(path)
        show(path)
    }

    // MARK: - The tree

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? Node) ?? root)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node) ?? root)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.isFolder == true }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.name)
        label.font = .systemFont(ofSize: 12, weight: node.path == following ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: node.path))
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = label
        return cell
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        // A folder closed is read again when it opens, and told so: the
        // outline keeps no children of the old reading.
        guard let node = notification.userInfo?["NSObject"] as? Node else { return }
        node.forget()
        outline.reloadItem(node, reloadChildren: true)
    }

    @objc private func picked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node, !node.isFolder else { return }
        show(node.path)
    }

    @objc private func followPressed() {
        guard let following else { return }
        reveal(following)
        show(following)
    }

    /// Opens the folders down to `path` and selects it.
    private func reveal(_ path: String) {
        guard let root, let relative = ProjectFiles.relative(path, to: root.path) else { return }
        var node = root
        for part in relative.split(separator: "/").map(String.init) {
            guard let next = node.children.first(where: { $0.name == part }) else { return }
            if next.isFolder { outline.expandItem(next) }
            node = next
        }
        let row = outline.row(forItem: node)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
    }

    // MARK: - The preview

    private func clearPreview() {
        preview.string = ""
        shown = nil
        citeButton.isEnabled = false
        status.stringValue = "Pick a file to read it here."
    }

    /// At most a megabyte of a regular file, never a FIFO nor a device that
    /// would block, and never more read than shown.
    private func read(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= ProjectFiles.previewLimit,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: ProjectFiles.previewLimit + 1)) ?? Data()
        return ProjectFiles.previewText(data)
    }

    private func show(_ path: String) {
        guard let text = read(path) else {
            preview.string = ""
            shown = (path, modified(path))
            status.stringValue = "\((path as NSString).lastPathComponent): not shown (not text, or over a megabyte). ⌘L still cites it."
            citeButton.isEnabled = true
            return
        }
        preview.string = text
        shown = (path, modified(path))
        citeButton.isEnabled = true
        describeSelection()
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The agent wrote the file: the preview reads it again where it was
    /// scrolled. The selection goes: kept by its offsets it could cover other
    /// lines now, and ⌘L would cite lines nobody chose.
    private func refreshPreviewIfChanged() {
        guard isActive, let shown, let now = modified(shown.path), now != shown.modified else { return }
        let scrolled = preview.enclosingScrollView?.contentView.bounds.origin
        show(shown.path)
        preview.setSelectedRange(NSRange(location: 0, length: 0))
        if let scrolled { preview.enclosingScrollView?.contentView.scroll(to: scrolled) }
        status.stringValue = "Changed on disk, read again · " + status.stringValue
    }

    func textViewDidChangeSelection(_ notification: Notification) { describeSelection() }

    private func selectedLines() -> ClosedRange<Int>? {
        let range = preview.selectedRange()
        guard range.length > 0 else { return nil }
        return ProjectFiles.lines(in: preview.string, selection: range.location..<(range.location + range.length))
    }

    private func describeSelection() {
        guard let shown else { return }
        let name = (shown.path as NSString).lastPathComponent
        if let lines = selectedLines() {
            status.stringValue = lines.count == 1 ? "\(name), line \(lines.lowerBound)" : "\(name), lines \(lines.lowerBound)–\(lines.upperBound)"
        } else {
            status.stringValue = name
        }
    }

    @objc private func citePressed() { citeSelection() }

    private func citeSelection() {
        guard let shown, let root else { NSSound.beep(); return }
        cite(ProjectFiles.citation(path: shown.path, root: root.path, lines: selectedLines()))
    }
}

/// The preview's text: ⌘L cites, as in an editor's chat.
private final class CitingTextView: NSTextView {
    var onCite: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "l" {
            onCite()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
