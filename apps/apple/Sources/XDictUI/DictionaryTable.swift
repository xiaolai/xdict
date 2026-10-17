import AppKit
import SwiftUI

/// **Apple's dictionary table** (parity P39): an `NSTableView` in a bordered scroll view — no header, alternating rows
/// 20 pt tall, a checkbox, the name in the 12 pt system font and the languages in secondary text — that reorders by
/// drag. To Accessibility it is an AXTable named "Dictionaries" with an AXCheckBox in every row, as Apple's is.
struct DictionaryTable: NSViewRepresentable {
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

    static let dragType = NSPasteboard.PasteboardType("ai.xdict.app.dictionary-row")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
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
        table.registerForDraggedTypes([Self.dragType])
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

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource as? NSTableView === tableView else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let dragged = (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
                $0.string(forType: DictionaryTable.dragType)
            }
            guard !dragged.isEmpty else { return false }
            parent.move(dragged, row)
            return true
        }
    }
}
