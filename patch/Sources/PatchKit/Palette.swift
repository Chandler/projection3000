import AppKit
import PatchCore

final class PaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let panel: NSPanel
    let search = NSSearchField()
    let table = NSTableView()
    var results = CatalogNode.all
    let choose: (CatalogNode) -> Void
    init(choose: @escaping (CatalogNode) -> Void) {
        self.choose = choose
        panel = NSPanel(contentRect:.init(x:0,y:0,width:420,height:390),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        super.init()
        panel.title = "Add Node"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.isFloatingPanel = true; panel.level = .floating; panel.appearance = NSAppearance(named:.darkAqua)
        panel.isReleasedWhenClosed = false; panel.backgroundColor = .patchPanel
        let content = NSView(); panel.contentView = content
        search.placeholderString = "Search nodes…"; search.font = .systemFont(ofSize:EditorTypography.title); search.focusRingType = .none; search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(search)
        let column = NSTableColumn(identifier:.init("node")); column.width = 390; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 34; table.backgroundColor = .patchPanel; table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(acceptClickedRow); table.selectionHighlightStyle = .regular
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(scroll)
        let hint = NSTextField(labelWithString:"↑↓ Select     Click / ↵ Add     Esc Close"); hint.textColor = .patchMuted; hint.font = .systemFont(ofSize:EditorTypography.caption); hint.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(hint)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo:content.topAnchor,constant:28), search.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),search.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),search.heightAnchor.constraint(equalToConstant:34),
            scroll.topAnchor.constraint(equalTo:search.bottomAnchor,constant:12),scroll.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:10),scroll.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-10),scroll.bottomAnchor.constraint(equalTo:hint.topAnchor,constant:-8),
            hint.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:18),hint.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-12)
        ])
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
    }
    func show(over window: NSWindow) {
        let frame = window.frame
        panel.setFrameOrigin(.init(x:frame.midX-210,y:frame.midY-150)); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let node = results[row]
        let cell = NSTableCellView(); let label = NSTextField(labelWithString:node.title)
        label.font = .systemFont(ofSize:EditorTypography.body,weight:.medium); label.textColor = .labelColor; label.frame = .init(x:12,y:7,width:230,height:20); cell.addSubview(label)
        let type = NSTextField(labelWithString:node.category); type.font = .systemFont(ofSize:EditorTypography.caption,weight:.medium); type.textColor = .node(node.kind); type.frame = .init(x:287,y:9,width:85,height:16); type.alignment = .right; cell.addSubview(type)
        return cell
    }
    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue.lowercased().trimmingCharacters(in:.whitespaces)
        // Rank 0: name match. 1: kind, category or a control's name. 2: letters in order.
        func rank(_ kind: CatalogNode) -> Int? {
            let title = kind.title.lowercased()
            if query.isEmpty || title.contains(query) { return 0 }
            if "\(kind.kind.rawValue) \(kind.category)".lowercased().contains(query) || kind.parameterSpecs.contains(where:{ $0.title.lowercased().contains(query) }) { return 1 }
            var remaining = Array(query.filter { !$0.isWhitespace })
            for character in title where remaining.first == character { remaining.removeFirst(); if remaining.isEmpty { return 2 } }
            return nil
        }
        let ranked = CatalogNode.all.enumerated().compactMap { index,kind in rank(kind).map { ($0,index,kind) } }
        results = ranked.sorted { ($0.0,$0.1) < ($1.0,$1.1) }.map(\.2)
        table.reloadData(); if !results.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) { move(1); return true }
        if selector == #selector(NSResponder.moveUp(_:)) { move(-1); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { accept(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { panel.close(); return true }
        return false
    }
    func move(_ delta: Int) { guard !results.isEmpty else { return }; let index = min(results.count-1,max(0,table.selectedRow+delta)); table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false); table.scrollRowToVisible(index) }
    @objc private func acceptClickedRow() { accept(row:table.clickedRow) }
    @objc func accept() { accept(row:table.selectedRow) }
    private func accept(row: Int) {
        guard panel.isVisible,results.indices.contains(row) else { return }
        let node = results[row]; panel.close(); choose(node)
    }
}
