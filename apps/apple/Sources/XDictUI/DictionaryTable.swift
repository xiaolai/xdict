import AppKit
import SwiftUI

/// **Apple's dictionary table** (parity P39): an `NSTableView` in a bordered scroll view — no header, alternating rows
/// 20 pt tall, a checkbox, the name in the 12 pt system font and the languages in secondary text — that reorders by
/// drag. To Accessibility it is an AXTable named "Dictionaries" with an AXCheckBox in every row, as Apple's is.
/// Since ADR-0012 d.2 it also takes files and folders dropped from elsewhere (a drag from the table reorders, any other
/// imports, never both) and the Library window's keys: Delete removes, ⌥⌘↑/⌥⌘↓ move, Space toggles.
struct DictionaryTable: NSViewRepresentable {
    /// What a drop onto the table does.
    enum Drop: Equatable {
        case reorder([String])
        case importFiles([URL])
        case refuse
    }

    /// A key the table acts on.
    enum KeyAction: Equatable {
        case remove, moveUp, moveDown, toggle
    }

    /// A drag whose source is this table reorders (its rows, by id) and never imports; any other imports its file URLs.
    static func classify(fromTable: Bool, rows: [String], urls: [URL]) -> Drop {
        if fromTable { return rows.isEmpty ? .refuse : .reorder(rows) }
        let files = urls.filter(\.isFileURL)
        return files.isEmpty ? .refuse : .importFiles(files)
    }

    /// Where the drop is drawn: a reorder in the gap above the proposed row; an import on the whole table.
    static func dropRow(for drop: Drop, proposed: Int) -> (row: Int, operation: NSTableView.DropOperation) {
        if case .reorder = drop { return (proposed, .above) }
        return (-1, .on)
    }

    static func keyAction(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> KeyAction? {
        let flags = flags.intersection([.command, .option, .control, .shift])
        switch (keyCode, flags) {
        case (51, []), (117, []): return .remove
        case (126, [.command, .option]): return .moveUp
        case (125, [.command, .option]): return .moveDown
        case (49, []): return .toggle
        default: return nil
        }
    }

    struct Row: Equatable {
        let id: UUID
        let name: String
        let language: String
        let enabled: Bool
        let usable: Bool
    }

    let rows: [Row]
    @Binding var selection: UUID?
    let name: String
    let checkboxName: String
    let setEnabled: (UUID, Bool) -> Void
    let move: ([String], Int) -> Void
    /// Files and folders dropped from elsewhere; nil while the library takes none (unreadable).
    let importFiles: (([URL]) -> Void)?
    let key: (KeyAction, UUID) -> Void

    static let dragType = NSPasteboard.PasteboardType("ai.xdict.app.dictionary-row")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyedTableView()
        table.onKey = { [weak coordinator = context.coordinator] event in coordinator?.key(event) ?? false }
        table.headerView = nil
        table.rowHeight = SettingsDictionaries.rowHeight
        table.rowSizeStyle = .custom
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 4, height: 0)
        table.style = .plain
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, width) in [("check", 26.0), ("name", 340.0), ("language", 180.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            if id == "check" { column.minWidth = width; column.maxWidth = width }
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([Self.dragType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel(name)
        table.setAccessibilityIdentifier("settings.dictionaries")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.borderType = .lineBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.rows != rows
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        if changed { table.reloadData() }
        let wanted = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        if table.selectedRow != (wanted ?? -1) {
            if let wanted { table.selectRowIndexes([wanted], byExtendingSelection: false) } else { table.deselectAll(nil) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: DictionaryTable
        weak var table: NSTableView?

        init(_ parent: DictionaryTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row), let column else { return nil }
            let item = parent.rows[row]
            switch column.identifier.rawValue {
            case "check":
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
                box.state = item.enabled ? .on : .off
                box.isEnabled = item.usable
                box.tag = row
                box.setAccessibilityLabel(parent.checkboxName)
                box.toolTip = parent.checkboxName
                return centred(box)
            case "name":
                return label(item.name, color: .labelColor)
            default:
                return label(item.language, color: .secondaryLabelColor)
            }
        }

        private func label(_ text: String, color: NSColor) -> NSView {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = color
            field.lineBreakMode = .byTruncatingTail
            return centred(field)
        }

        /// A cell view with its control centred on the row's height.
        private func centred(_ control: NSView) -> NSView {
            let cell = NSTableCellView()
            control.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                control.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        @objc private func toggled(_ sender: NSButton) {
            guard parent.rows.indices.contains(sender.tag) else { return }
            parent.setEnabled(parent.rows[sender.tag].id, sender.state == .on)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let row = table.selectedRow
            let id = parent.rows.indices.contains(row) ? parent.rows[row].id : nil
            if parent.selection != id { parent.selection = id }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard parent.rows.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(parent.rows[row].id.uuidString, forType: DictionaryTable.dragType)
            return item
        }

        private func drop(_ info: any NSDraggingInfo, on tableView: NSTableView) -> Drop {
            let pasteboard = info.draggingPasteboard
            let rows = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: DictionaryTable.dragType) }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL] ?? []
            let drop = DictionaryTable.classify(fromTable: info.draggingSource as? NSTableView === tableView, rows: rows,
                                                urls: urls)
            if case .importFiles = drop, parent.importFiles == nil { return .refuse }
            return drop
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            let drop = drop(info, on: tableView)
            let target = DictionaryTable.dropRow(for: drop, proposed: row)
            switch drop {
            case .refuse: return []
            case .reorder:
                tableView.setDropRow(target.row, dropOperation: target.operation)
                return .move
            case .importFiles:
                tableView.setDropRow(target.row, dropOperation: target.operation)
                return .copy
            }
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            switch drop(info, on: tableView) {
            case .refuse: return false
            case .reorder(let dragged): parent.move(dragged, row)
            case .importFiles(let urls): parent.importFiles?(urls)
            }
            return true
        }

        /// A key on the table, for the selected row; false lets AppKit have it (arrows select, and so on).
        func key(_ event: NSEvent) -> Bool {
            guard let action = DictionaryTable.keyAction(keyCode: event.keyCode, flags: event.modifierFlags),
                  let id = parent.selection else { return false }
            parent.key(action, id)
            return true
        }
    }
}

/// An `NSTableView` that offers its keys to the coordinator first.
final class KeyedTableView: NSTableView {
    var onKey: (@MainActor (NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
