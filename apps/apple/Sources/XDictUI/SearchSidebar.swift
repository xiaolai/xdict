import AppKit
import SwiftUI
import XDictEntryView
import XDictSearch
import XDictTokens

/// **The sidebar, as Apple's Dictionary has it** (parity P9, P11, P13, P43): there only after a search; one flat list of
/// the matching headwords across the dictionaries in scope — an AppKit table VoiceOver reads as "search results", 28 pt
/// rows of 13 pt text, the selected row semibold — under an italic "Did you mean?" when the rows are spelling guesses.
/// Which dictionaries could not search is said in the page (`PageNotices`), not here.
struct SearchSidebar: View {
    @Bindable var state: SearchWindowState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.model.listing?.isGuess == true {
                Text("Did you mean?")
                    .font(Tokens.TextRole.didYouMean.font)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Tokens.Inset.sidebarHeaderLeading)
                    .padding(.vertical, Tokens.Space.s)
                    .accessibilityIdentifier("did-you-mean")
            }
            HeadwordTable(state: state)
            if case .failed = state.service {
                Divider()
                Text(state.service.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(Tokens.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The list itself: rows from the model's listing, the selection its selected headword; a row chosen (click or arrows)
/// is shown.
struct HeadwordTable: NSViewRepresentable {
    let state: SearchWindowState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = HeadwordTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("headword"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = HeadwordTableView.rowHeight
        table.intercellSpacing = .zero
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel(String(localized: "search results"))
        table.setAccessibilityIdentifier("results")
        table.entryKeyView = { [weak entry = state.entry] in entry?.keyViewTarget }
        state.entry.keyViewPredecessor = table
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.state = state
        let rows = state.model.listing?.headwords ?? []
        if rows != coordinator.rows {
            coordinator.rows = rows
            table.reloadData()
        }
        coordinator.select(state.model.selectedHeadword, in: table)
        if coordinator.focus != state.resultsFocus {
            coordinator.focus = state.resultsFocus
            table.window?.makeFirstResponder(table)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var state: SearchWindowState?
        var rows: [String] = []
        var focus = 0
        private var selecting = false
        private var bold: Int?

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: HeadwordCell.identifier, owner: nil) as? HeadwordCell)
                ?? HeadwordCell()
            cell.show(rows.indices.contains(row) ? rows[row] : "", selected: row == tableView.selectedRow)
            return cell
        }

        /// The model's selected headword, selected in the table without choosing it again.
        func select(_ headword: String?, in table: NSTableView) {
            let row = headword.flatMap { rows.firstIndex(of: $0) } ?? -1
            guard row != table.selectedRow else { return restyle(table) }
            selecting = true
            if row >= 0 {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            } else {
                table.deselectAll(nil)
            }
            selecting = false
            restyle(table)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            restyle(table)
            guard !selecting, rows.indices.contains(table.selectedRow) else { return }
            state?.model.choose(headword: rows[table.selectedRow])
        }

        /// The selected row semibold, the rest regular (P43).
        private func restyle(_ table: NSTableView) {
            let now = table.selectedRow >= 0 ? table.selectedRow : nil
            guard now != bold else { return }
            let changed = [bold, now].compactMap { $0 }.filter { $0 < rows.count }
            bold = now
            table.reloadData(forRowIndexes: IndexSet(changed), columnIndexes: IndexSet(integer: 0))
        }
    }
}

/// The sidebar's table: its own class, so the window's instruments know the results list by it.
final class HeadwordTableView: NSTableView {
    static let rowHeight: CGFloat = Tokens.Row.sidebar
    /// Where Tab goes from the list: the entry (`EntryViewController.keyViewTarget`), asked when the key is pressed, so
    /// the All page's frames made later, or a key-view loop the window recalculated, cannot send it to the search field.
    var entryKeyView: (() -> NSView?)?

    override var nextValidKeyView: NSView? {
        if let entry = entryKeyView?(), entry.canBecomeKeyView { return entry }
        return super.nextValidKeyView
    }
}

/// One headword: 13 pt system text, semibold when selected.
final class HeadwordCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("headword.cell")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ headword: String, selected: Bool) {
        label.stringValue = headword
        label.font = (selected ? Tokens.TextRole.sidebarRowSelected : Tokens.TextRole.sidebarRow).nsFont
    }
}
