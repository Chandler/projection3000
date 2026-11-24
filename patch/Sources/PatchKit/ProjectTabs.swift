import AppKit
import PatchCore

extension AppController {
    func configureTabAPI() {
        guard !embedded else { return }
        api?.tabState = { [weak self] in
            guard let self else { return [] }
            let root=self.tabRoot
            return root.openTabs.map { tab in
                ["id":tab.tabID.uuidString,"name":tab.workspace.projectName,
                 "file":tab.workspace.fileURL?.path as Any? ?? NSNull(),"dirty":tab.workspace.dirty,
                 "running":tab.tabRunning,"selected":root.activeTab === tab,
                 "graphRevision":tab.api?.revision() ?? "", "renderedFrames":tab.renderer.renderedFrames] as [String:Any]
            }
        }
        api?.tabCommand = { [weak self] command in
            guard let self, let op=command["op"] as? String, op.hasPrefix("tab_") else { return nil }
            let root=self.tabRoot
            let target: AppController
            if let id=command["tab"] as? String {
                guard let tab=root.openTabs.first(where:{ $0.tabID.uuidString == id }) else { throw GraphError("Unknown project tab") }
                target=tab
            } else { target=root.activeTab ?? self }
            switch op {
            case "tab_new": target.newProject()
            case "tab_select": root.selectProjectTab(target)
            case "tab_start": target.setTabRunning(true)
            case "tab_stop": target.setTabRunning(false)
            case "tab_close":
                guard !target.workspace.dirty else { throw GraphError("Save this tab before closing it through the API") }
                target.closeProjectTab()
            default: throw GraphError("Unknown tab command")
            }
            return ["ok":true]
        }
        api?.onOpenProject = { [weak self] url in try self?.tabRoot.openProjectTab(url) }
        if tabOwner == nil {
            api?.activeEndpoint = { [weak self] in self?.activeTab?.api }
            api?.forwardRoute = { [weak self] method,path,data in
                guard let self,let tab=self.activeTab,tab !== self,!tab.tabClosed else { return nil }
                return try tab.api?.route(method,path,data)
            }
        }
    }
    func tabSnapshot() throws -> [String:Any] {
        workspace.plugins.synchronize(); workspace.finishPendingGesture()
        return ["tabID":tabID.uuidString,"running":tabRunning,"graphRevision":api?.revision() ?? "",
                "graph":try JSONSerialization.jsonObject(with:JSONEncoder().encode(workspace.graph)),
                "selection":workspace.selected?.uuidString as Any? ?? NSNull(),"selectedNodes":workspace.selectedIDs.map(\.uuidString),
                "playing":workspace.playing,"backdropEnabled":workspace.backdropEnabled,"backdropID":workspace.backdropID?.uuidString as Any? ?? NSNull(),
                "projectName":workspace.projectName,"file":workspace.fileURL?.path as Any? ?? NSNull(),"dirty":workspace.dirty,
                "previewVisible":workspace.previewVisible,"pinnedPreviews":pinnedPreviewState,
                "midi":["followNode":midi?.followNode?.uuidString as Any? ?? NSNull()],
                "editor":["zoom":Double(canvas.zoom),"x":Double(canvas.offset.x),"y":Double(canvas.offset.y)]]
    }
    func sessionWithTabs(base: [String:Any]) throws -> [String:Any] {
        let root=tabRoot
        var result=base
        if let active=root.activeTab, !active.tabClosed { result.merge(try active.tabSnapshot()) { _,new in new } }
        result["tabs"]=try root.openTabs.map { try $0.tabSnapshot() }
        result["activeTab"]=root.activeTab?.tabID.uuidString
        return result
    }
    @discardableResult func createTab(snapshot: [String:Any], select: Bool = true) throws -> AppController {
        let root=tabRoot
        let tab=AppController(apiPort:root.apiPort,tabOwner:root,tabSession:snapshot)
        root.tabChildren.append(tab)
        do { try tab.start() }
        catch { root.tabChildren.removeAll { $0 === tab }; tab.stop(); throw error }
        if select { root.selectProjectTab(tab) } else { tab.window.orderOut(nil) }
        if select { root.persistSession() }
        return tab
    }
    func openProjectTab(_ url: URL) throws {
        let root=tabRoot
        if let tab=root.openTabs.first(where:{ $0.workspace.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            root.selectProjectTab(tab); return
        }
        let graph=try Graph.read(Data(contentsOf:url))
        _ = try root.createTab(snapshot:["graph":try JSONSerialization.jsonObject(with:JSONEncoder().encode(graph)),"file":url.path,"dirty":false,"running":false])
        workspace.remember(url)
    }
    func openInTab(_ url: URL) {
        do { try tabRoot.openProjectTab(url) }
        catch { workspace.message=error.localizedDescription; NSAlert(error:error).runModal() }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // AppKit can deliver launch arguments as file-open events before startup.
        // Explicit session/project arguments are already handled by start().
        let args=CommandLine.arguments
        let explicit=Set(["--session","--project"].compactMap { flag -> String? in
            guard let i=args.firstIndex(of:flag),args.indices.contains(i+1) else { return nil }
            return URL(fileURLWithPath:args[i+1]).standardizedFileURL.path
        })
        let files=filenames.filter { !explicit.contains(URL(fileURLWithPath:$0).standardizedFileURL.path) }
        if !headless {
            if started { for path in files { openInTab(URL(fileURLWithPath:path)) } }
            else { pendingOpenFiles += files }
        }
        sender.reply(toOpenOrPrint:.success)
    }
    func suspendTabMIDI() { midi?.suspend() }
    @objc func toggleTabRunning() { setTabRunning(!tabRunning) }
    func setTabRunning(_ running: Bool) {
        guard !embedded,!changingRunState,tabRunning != running else { return }
        if !running,renderer.hasActiveRecordings {
            changingRunState=true; updateTitle()
            renderer.finishRecordings { [weak self] in
                guard let self else { return }
                self.changingRunState=false; self.setTabRunning(false)
            }
            return
        }
        tabRunning=running
        if running {
            workspace.plugins.setSuspended(false)
            let follow=midi?.followNode
            midiSettings?.close(); midiSettings=nil
            midi=MIDIController(workspace:workspace,apcState:renderer.apcState,enabled:ProcessInfo.processInfo.environment["PATCH_DISABLE_MIDI"] != "1")
            if let follow { try? midi.setFollow(follow,enabled:true) }
            renderer.start(graph:workspace.renderGraph,playing:workspace.playing)
            renderer.update(graph:workspace.renderGraph,playing:workspace.playing,publicationGraph:workspace.graph)
            syncOutputs()
        } else {
            workspace.plugins.synchronize()
            renderer.stop(); workspace.plugins.setSuspended(true); suspendTabMIDI()
            for win in outputWindows.values { win.delegate=nil; win.close() }
            outputWindows.removeAll(); outputDelegates.removeAll()
        }
        updateTitle(); tabRoot.persistSession()
    }
    @objc func closeProjectTab() {
        guard !tabClosed,!changingRunState else { return }
        window.makeFirstResponder(nil); workspace.finishPendingGesture()
        guard workspace.confirmDiscard() else { return }
        if renderer.hasActiveRecordings {
            changingRunState=true
            renderer.finishRecordings { [weak self] in self?.changingRunState=false; self?.closeProjectTab() }
            return
        }
        let root=tabRoot
        tabClosed=true
        root.tabChildren.removeAll { $0 === self }
        if root.activeTab === self { root.activeTab=root.openTabs.first }
        stop(keepAPI:self === root)
        window.delegate=nil; window.close()
        root.persistSession()
        if let tab=root.activeTab { root.selectProjectTab(tab) }
        else { DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { NSApp.terminate(nil) } }
    }
}

extension AppController {
    func makeTabStrip(in root: NSView) {
        let scroll=NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints=false
        scroll.drawsBackground=false; scroll.hasHorizontalScroller=false; scroll.hasVerticalScroller=false
        let stack=NSStackView(); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing=0
        stack.translatesAutoresizingMaskIntoConstraints=false; scroll.documentView=stack; tabStrip=stack
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo:root.topAnchor,constant:28),scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:8),
            scroll.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-8),scroll.heightAnchor.constraint(equalToConstant:38),
            stack.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),stack.topAnchor.constraint(equalTo:scroll.contentView.topAnchor),
            stack.heightAnchor.constraint(equalTo:scroll.heightAnchor)
        ])
    }
    func selectProjectTab(_ tab: AppController) {
        let root=tabRoot
        if headless { root.activeTab=tab; return }
        let previous=root.activeTab
        if let previous,previous !== tab { tab.window.setFrame(previous.window.frame,display:false) }
        root.activeTab=tab
        for other in root.openTabs where other !== tab { other.window.orderOut(nil) }
        tab.window.makeKeyAndOrderFront(nil); tab.window.makeFirstResponder(tab.canvas)
        tab.makeMenus(); refreshTabStrips()
    }
    func refreshTabStrips() {
        let root=tabRoot, tabs=tabRoot.openTabs
        let signature=tabs.map { "\($0.tabID)|\($0.workspace.projectName)|\($0.workspace.dirty)|\($0.tabRunning)|\($0.changingRunState)|\(root.activeTab === $0)" }.joined(separator:";")
        for owner in tabs {
            guard let strip=owner.tabStrip,owner.tabStripSignature != signature else { continue }
            owner.tabStripSignature=signature
            for view in strip.arrangedSubviews { strip.removeArrangedSubview(view); view.removeFromSuperview() }
            for tab in tabs {
                let selected=root.activeTab === tab
                let cell=NSView(); cell.wantsLayer=true; cell.identifier=NSUserInterfaceItemIdentifier(tab.tabID.uuidString)
                cell.layer?.backgroundColor=(selected ? NSColor.white.withAlphaComponent(0.07) : NSColor.clear).cgColor
                let title=NSButton(title:tab.workspace.projectName + (tab.workspace.dirty ? " •" : ""),target:owner,action:#selector(selectTabButton(_:)))
                title.identifier=NSUserInterfaceItemIdentifier(tab.tabID.uuidString); title.isBordered=false
                title.font = .systemFont(ofSize:12,weight:selected ? .semibold:.regular)
                title.contentTintColor=selected ? .labelColor:.secondaryLabelColor; title.cell?.lineBreakMode = .byTruncatingTail
                title.toolTip=tab.workspace.fileURL?.path ?? tab.workspace.projectName
                let status=NSTextField(labelWithString:tab.changingRunState ? "Stopping…" : tab.tabRunning ? "Running" : "Stopped")
                status.font = .systemFont(ofSize:10); status.textColor=tab.tabRunning ? .systemGreen:.secondaryLabelColor
                let run=NSButton(title:tab.tabRunning ? "Stop" : "Start",target:owner,action:#selector(runTabButton(_:)))
                run.identifier=title.identifier; run.isBordered=false; run.font = .systemFont(ofSize:10,weight:.medium)
                run.image=NSImage(systemSymbolName:tab.tabRunning ? "stop.fill":"play.fill",accessibilityDescription:tab.tabRunning ? "Stop tab":"Start tab")
                run.imagePosition = .imageLeading; run.contentTintColor=tab.tabRunning ? .systemGreen:.secondaryLabelColor
                run.toolTip=tab.tabRunning ? "Stop all nodes in this tab":"Start this tab"; run.isEnabled = !tab.changingRunState
                run.setAccessibilityLabel((tab.tabRunning ? "Stop ":"Start ")+tab.workspace.projectName)
                let close=NSButton(image:NSImage(systemSymbolName:"xmark",accessibilityDescription:"Close tab")!,target:owner,action:#selector(closeTabButton(_:)))
                close.identifier=title.identifier; close.isBordered=false; close.contentTintColor = .secondaryLabelColor
                close.toolTip="Close \(tab.workspace.projectName)"; close.setAccessibilityLabel(close.toolTip!)
                let row=NSStackView(views:[title,status,run,close]); row.spacing=7; row.translatesAutoresizingMaskIntoConstraints=false; cell.addSubview(row)
                let line=NSView(); line.translatesAutoresizingMaskIntoConstraints=false; line.wantsLayer=true
                line.layer?.backgroundColor=(selected ? NSColor.patchAccent:NSColor.clear).cgColor; cell.addSubview(line)
                NSLayoutConstraint.activate([cell.heightAnchor.constraint(equalToConstant:36),row.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:10),row.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-10),row.centerYAnchor.constraint(equalTo:cell.centerYAnchor),title.widthAnchor.constraint(lessThanOrEqualToConstant:150),close.widthAnchor.constraint(equalToConstant:16),line.heightAnchor.constraint(equalToConstant:2),line.leadingAnchor.constraint(equalTo:cell.leadingAnchor),line.trailingAnchor.constraint(equalTo:cell.trailingAnchor),line.bottomAnchor.constraint(equalTo:cell.bottomAnchor)])
                strip.addArrangedSubview(cell)
            }
            let add=NSButton(image:NSImage(systemSymbolName:"plus",accessibilityDescription:"New project tab")!,target:owner,action:#selector(newProject));add.isBordered=false;add.toolTip="New project tab · ⌘N";add.widthAnchor.constraint(equalToConstant:32).isActive=true;strip.addArrangedSubview(add)
            strip.layoutSubtreeIfNeeded()
            if let active=root.activeTab,let cell=strip.arrangedSubviews.first(where:{ $0.identifier?.rawValue == active.tabID.uuidString }) { cell.scrollToVisible(cell.bounds) }
        }
    }
    func projectTab(for sender: NSButton) -> AppController? { openTabs.first { $0.tabID.uuidString == sender.identifier?.rawValue } }
    @objc func selectTabButton(_ sender: NSButton) { if let tab=projectTab(for:sender) { selectProjectTab(tab) } }
    @objc func runTabButton(_ sender: NSButton) { projectTab(for:sender)?.toggleTabRunning() }
    @objc func closeTabButton(_ sender: NSButton) { projectTab(for:sender)?.closeProjectTab() }
}
