import AppKit
import Darwin
import UniformTypeIdentifiers

/// A read-only index of loose Desktop items. Only display metadata and session-local
/// identifiers cross into the village artwork. No thumbnails or contents are loaded.
@MainActor final class VillagePostOffice: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
        let born: Int
        let nanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            born = info.st_birthtimespec.tv_sec
            nanoseconds = info.st_birthtimespec.tv_nsec
        }
    }
    private enum Kind: String {
        case image, document, package, alias, other
        var title: String {
            switch self {
            case .image: return "Picture"
            case .document: return "Document"
            case .package: return "Package"
            case .alias: return "Shortcut"
            case .other: return "File"
            }
        }
        var symbol: String {
            switch self {
            case .image: return "photo"
            case .document: return "doc.text"
            case .package: return "shippingbox"
            case .alias: return "arrow.turn.up.right"
            case .other: return "doc"
            }
        }
        var opensInApp: Bool { self == .image || self == .document }
    }
    private struct Item: Equatable {
        var id: String
        let url: URL
        let identity: Identity
        let kind: Kind
    }
    private let desktop: URL
    private var entries: [Item] = []
    private var unavailable = false
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var desk: NSPanel?
    private lazy var table = NSTableView()
    private lazy var status = NSTextField(labelWithString: "")
    private var actionButton: NSButton?
    private var finderButton: NSButton?
    var onChange: (() -> Void)?
    var deskIsVisible: Bool { desk?.isVisible == true }

    /// Injectable so the file routing can be exercised without launching personal files.
    var openDocument: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    init(desktop: URL? = nil) {
        self.desktop = desktop ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        super.init()
    }

    var items: [[String: String]] {
        entries.map { ["id": $0.id, "name": $0.url.lastPathComponent, "kind": $0.kind.rawValue] }
    }

    func start() {
        guard watcher == nil else { refresh(); return }
        let descriptor = Darwin.open(desktop.path, O_EVTONLY)
        if descriptor != -1 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke, .attrib], queue: .main)
            source.setCancelHandler { Darwin.close(descriptor) }
            source.setEventHandler { [weak self] in
                guard let self, let flags = self.watcher?.data else { return }
                self.pending?.cancel()
                let lost = !flags.intersection([.delete, .rename, .revoke]).isEmpty
                if lost { self.watcher?.cancel(); self.watcher = nil }
                let work = DispatchWorkItem { [weak self] in
                    if lost { self?.start() } else { self?.refresh() }
                }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
            }
            watcher = source
            source.resume()
        }
        refresh()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        watcher?.cancel()
        watcher = nil
        desk?.orderOut(nil)
        entries = []
        unavailable = false
    }

    private func readEntry(_ url: URL, keys: Set<URLResourceKey>) -> Item? {
        var statInfo = stat()
        guard Darwin.lstat(url.path, &statInfo) == 0 else { return nil }
        let fileMode = statInfo.st_mode & S_IFMT
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isHidden != true else { return nil }
        let kind: Kind
        if fileMode == S_IFLNK || values?.isAliasFile == true {
            kind = .alias
        } else if values?.isPackage == true {
            kind = .package
        } else if fileMode == S_IFDIR {
            return nil  // Real directories are the houses.
        } else if fileMode == S_IFREG, statInfo.st_mode & 0o111 == 0,
                  let type = UTType(filenameExtension: url.pathExtension),
                  !type.conforms(to: .executable), !type.conforms(to: .script) {
            if type.conforms(to: .image) { kind = .image }
            else if type.conforms(to: .content) { kind = .document }
            else { kind = .other }
        } else {
            kind = .other
        }
        return Item(id: "", url: url, identity: Identity(statInfo), kind: kind)
    }

    func refresh() {
        let keys: Set<URLResourceKey> = [.isHiddenKey, .isAliasFileKey, .isPackageKey]
        let previous = entries
        let previousUnavailable = unavailable
        let selected = desk == nil ? nil : selectedItem?.id
        do {
            let children = try FileManager.default.contentsOfDirectory(at: desktop,
                includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            var found = children.compactMap { readEntry($0, keys: keys) }.sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            // Match unchanged directory entries first so two hard links have distinct
            // hit targets. An unambiguous rename keeps its existing artwork identity.
            var prior = Dictionary(grouping: previous, by: \.identity)
            for index in found.indices {
                let file = found[index]
                if let match = prior[file.identity]?.firstIndex(where: { $0.url == file.url }) {
                    found[index].id = prior[file.identity]!.remove(at: match).id
                }
            }
            let remaining = Dictionary(grouping: found.indices.filter { found[$0].id.isEmpty },
                                       by: { found[$0].identity })
            for (key, indices) in remaining {
                if indices.count == 1, let candidates = prior[key], candidates.count == 1 {
                    found[indices[0]].id = candidates[0].id
                } else {
                    for index in indices { found[index].id = UUID().uuidString }
                }
            }
            entries = found
            unavailable = false
        } catch {
            entries = []
            unavailable = true
        }
        guard previous != entries || previousUnavailable != unavailable else { return }
        if desk != nil { reloadDesk(selectedID: selected) }
        onChange?()
    }

    /// Resolve again against today's directory entries. Stale clicks on deleted or
    /// replaced files can never intentionally open the new occupant of that path.
    func openItem(id: String) {
        refresh()
        guard let file = entries.first(where: { $0.id == id }) else { return }
        if !file.kind.opensInApp || !openDocument(file.url) { reveal(file.url) }
    }

    func revealItem(id: String) {
        refresh()
        if let file = entries.first(where: { $0.id == id }) { reveal(file.url) }
    }

    func showDesk(selectedID: String? = nil) {
        start()
        if desk == nil { makeDesk() }
        reloadDesk(selectedID: selectedID ?? selectedItem?.id)
        guard let desk else { return }
        if !desk.isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let frame = screen.visibleFrame
            desk.setFrameOrigin(NSPoint(x: frame.midX - desk.frame.width / 2,
                                        y: frame.midY - desk.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        desk.makeKeyAndOrderFront(nil)
        desk.makeFirstResponder(table)
    }

    private var selectedItem: Item? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private func makeDesk() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 345),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let paper = NSColor(srgbRed: 0.985, green: 0.966, blue: 0.909, alpha: 1)
        let pineInk = NSColor(srgbRed: 0.16, green: 0.25, blue: 0.21, alpha: 1)
        panel.title = "Village Post Office"
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = paper
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 360, height: 235)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace]
        desk = panel

        let heading = NSTextField(labelWithString: "The sorting desk")
        heading.font = NSFont(descriptor: NSFont.systemFont(ofSize: 24, weight: .medium).fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: 24).fontDescriptor, size: 24)
        heading.textColor = pineInk
        let mark = NSImageView(image: NSImage(systemSymbolName: "envelope", accessibilityDescription: nil) ?? NSImage())
        mark.contentTintColor = NSColor(srgbRed: 0.66, green: 0.31, blue: 0.24, alpha: 1)
        let titleRow = NSStackView(views: [mark, heading])
        titleRow.spacing = 10
        titleRow.alignment = .centerY

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("post"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = paper
        table.rowHeight = 31
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Files on the Desktop")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let finder = NSButton(title: "Show in Finder", target: self, action: #selector(revealSelected))
        let choose = NSButton(title: "Open", target: self, action: #selector(openSelected))
        choose.keyEquivalent = "\r"
        finderButton = finder
        actionButton = choose
        let actions = NSStackView(views: [finder, choose])
        actions.spacing = 8
        let layout = NSStackView(views: [titleRow, status, scroll, actions])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 9
        layout.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        layout.translatesAutoresizingMaskIntoConstraints = false
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = paper.cgColor
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            layout.topAnchor.constraint(equalTo: content.topAnchor),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -32),
            status.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func reloadDesk(selectedID: String?) {
        table.reloadData()
        if let selectedID, let index = entries.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else { table.deselectAll(nil) }
        if unavailable { status.stringValue = "Your Desktop is unavailable. Check Desktop Folder access in System Settings." }
        else if entries.isEmpty { status.stringValue = "Letters will appear here when you add files to your Desktop." }
        else { status.stringValue = entries.count == 1 ? "1 item from your Desktop" : "\(entries.count) items from your Desktop" }
        updateActions()
    }

    private func updateActions() {
        let canOpen = selectedItem?.kind.opensInApp ?? false
        actionButton?.isEnabled = canOpen
        finderButton?.isEnabled = selectedItem != nil
        finderButton?.keyEquivalent = canOpen ? "" : "\r"
        actionButton?.keyEquivalent = canOpen ? "\r" : ""
    }
    @objc private func openSelected() {
        if let id = selectedItem?.id { openItem(id: id) }
    }
    @objc private func revealSelected() {
        if let id = selectedItem?.id { revealItem(id: id) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let cellID = NSUserInterfaceItemIdentifier("postmark")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = cellID
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            let image = NSImageView()
            image.contentTintColor = .secondaryLabelColor
            for view in [label, image] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            cell.textField = label
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: 19),
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        let file = entries[row]
        cell.textField?.stringValue = file.url.lastPathComponent
        cell.imageView?.image = NSImage(systemSymbolName: file.kind.symbol, accessibilityDescription: file.kind.title)
        cell.toolTip = file.url.lastPathComponent
        return cell
    }
}
