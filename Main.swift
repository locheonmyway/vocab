import Cocoa
import SwiftUI
import Carbon
import ApplicationServices

final class QuickPanel:NSPanel {
    override var canBecomeKey:Bool { true }
    override var canBecomeMain:Bool { false }
}

@MainActor final class VocabController:NSObject,NSApplicationDelegate,NSWindowDelegate,NSMenuDelegate {
    var model:VocabModel!
    var statusItem:NSStatusItem!
    var panel:QuickPanel?
    var library:NSWindow?
    var hotkey:EventHotKeyRef?
    var eventHandler:EventHandlerRef?
    var mouseMonitor:Any?
    var keyMonitor:Any?
    var localKey:Any?
    var timer:Timer?
    var terminateSignal:DispatchSourceSignal?
    var wakeObserver:Any?
    var shownAt = Date()
    var preview = CommandLine.arguments.contains("--preview")
    var previewRoot:URL?
    var hotkeyStatus:OSStatus = -1
    static var shared:VocabController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared=self; NSApp.setActivationPolicy(.accessory)
        do {
            let root:URL
            if preview {
                root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-ui-preview-\(UUID().uuidString)",isDirectory:true)
                previewRoot=root
            } else { root=Paths.support }
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            if !preview {
                let backup=root.appendingPathComponent("Legacy-Vocabulary-original.md")
                if FileManager.default.fileExists(atPath:Paths.legacy.path) && !FileManager.default.fileExists(atPath:backup.path) {
                    try FileManager.default.copyItem(at:Paths.legacy,to:backup)
                }
            }
            model=VocabModel(store:try Store(url:root.appendingPathComponent("vocab.sqlite3")),catalog:KnowledgeCatalog.load(),reloadCatalog:!preview,workspaceURL:root.appendingPathComponent("workspace-state.json"))
        } catch {
            let alert=NSAlert(); alert.messageText="无法打开 Vocab 数据"; alert.informativeText=error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return
        }
        model.onShowQuick = { [weak self] in self?.showQuick() }
        model.onHideQuick = { [weak self] in self?.hideQuick() }
        model.onResizeQuick = { [weak self] in self?.resizeQuick() }
        model.onFocusQuick = { [weak self] in self?.panel?.makeKey() }
        model.onShowLibrary = { [weak self] in self?.showLibrary() }
        setupMenu()
        if !preview {
            model.prepareDictionaries()
            wakeObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in
                Task { @MainActor [weak self] in self?.model.prepareDictionaries() }
            }
            signal(SIGTERM,SIG_IGN)
            let source=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
            source.setEventHandler { NSApp.terminate(nil) };source.resume();terminateSignal=source
            registerHotkey()
            if !AXIsProcessTrusted() {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
            }
        }
        mouseMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let p=self.panel, p.isVisible,
                      !p.frame.contains(NSEvent.mouseLocation) else{return}
                if !self.model.asking && !self.model.editing { self.model.dismissQuick() }
            }
        }
        keyMonitor=NSEvent.addGlobalMonitorForEvents(matching:.keyDown){[weak self] e in
            if e.keyCode==53 {DispatchQueue.main.async { if self?.panel?.isVisible==true {self?.model.dismissQuick()} }}
        }
        localKey=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] e in
            if e.keyCode==53,self?.panel?.isKeyWindow==true {self?.model.dismissQuick();return nil}
            return e
        }
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in
            DispatchQueue.main.async {
                guard let self,self.panel?.isVisible==true else{return}
                if self.model.hover || self.model.editing || self.model.expanded || self.model.asking || self.model.resultBusy || self.model.bookBusy {
                    self.shownAt=Date();return
                }
                if Date().timeIntervalSince(self.shownAt)>18 {self.model.dismissQuick()}
            }
        }
        if preview {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
                if CommandLine.arguments.contains("--library") { self.showLibrary() }
                else { self.model.manual(prefill:"ambivalent",status:"预览 · 输入单词、搭配或句子");self.model.submitInput() }
            }
        }
    }
    func setupMenu() {
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem.button?.title=preview ? "Aa²" : "Aa"
        statusItem.button?.font=NSFont.systemFont(ofSize:13,weight:.semibold)
        let m=NSMenu();m.delegate=self;statusItem.menu=m;populateMenu(m)
    }
    func menuNeedsUpdate(_ menu:NSMenu){populateMenu(menu)}
    private func populateMenu(_ m:NSMenu){
        m.removeAllItems()
        let heading=NSMenuItem(title:"Vocab · 我的语言",action:nil,keyEquivalent:"");heading.isEnabled=false;m.addItem(heading)
        m.addItem(.separator())
        func add(_ title:String,_ action:Selector,_ key:String=""){let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=self;m.addItem(item)}
        add("手动查词",#selector(manual))
        if !preview,hotkeyStatus != noErr{add("快捷键未注册 · 重试",#selector(retryHotkey))}
        add("打开学习空间",#selector(practice))
        if model.practicing{add("继续当前练习",#selector(resumePractice))}
        m.addItem(.separator())
        add("知识地图",#selector(showMap))
        add("我的表达",#selector(showExpressions))
        add("查词记录",#selector(showHistory))
        add("练习记录",#selector(showPracticeRecords))
        m.addItem(.separator())
        add("打开完整语言助手",#selector(openAssistant))
        add("设置与权限",#selector(settings))
        m.addItem(.separator())
        add("退出 Vocab",#selector(quit),"q")
    }
    func registerHotkey() {
        if let hotkey{UnregisterEventHotKey(hotkey);self.hotkey=nil}
        if let eventHandler{RemoveEventHandler(eventHandler);self.eventHandler=nil}
        var t=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,_,_ in
            DispatchQueue.main.async { VocabController.shared?.trigger() }
            return noErr
        },1,&t,nil,&eventHandler)
        let status=RegisterEventHotKey(UInt32(kVK_ANSI_V),UInt32(controlKey|optionKey),
            EventHotKeyID(signature:OSType(0x564f4332),id:1),GetApplicationEventTarget(),0,&hotkey)
        hotkeyStatus=status
        statusItem.button?.title=status==noErr ? "Aa":"Aa!"
        NSLog("VocabV2 hotkey register status=%d; AX trusted=%d",status,AXIsProcessTrusted() ? 1 : 0)
        if status != noErr {
            model.message="快捷键未注册（\(status)）；请确认旧 Vocab 未同时运行。"
        }
    }
    @objc func retryHotkey(){registerHotkey()}
    func trigger() {
        guard model != nil else{return}
        NSLog("VocabV2 hotkey received; AX trusted=%d; screen=%d",AXIsProcessTrusted() ? 1 : 0,CGPreflightScreenCaptureAccess() ? 1 : 0)
        if panel?.isVisible==true {model.dismissQuick();return}
        model.startCapture(SourceSnapshot.front())
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        if model != nil {showLibrary()}
        return true
    }
    @objc func manual(){model.manual()}
    @objc func showHistory(){guard !model.voice.recording,!model.voice.busy else{return};model.navigation.recordTab = .lookup;model.navigate(.history);showLibrary()}
    @objc func showPracticeRecords(){guard !model.voice.recording,!model.voice.busy else{return};model.navigation.recordTab = .practice;model.navigate(.history);showLibrary()}
    @objc func showMap(){model.navigate(.map);showLibrary()}
    @objc func showExpressions(){model.navigate(.expressions);showLibrary()}
    @objc func practice(){model.navigate(.practice);showLibrary()}
    @objc func resumePractice(){model.resumeActivity();showLibrary()}
    @objc func settings(){model.tab = .settings;showLibrary()}
    @objc func openAssistant(){if model.assistant.thread.isEmpty{settings()}else{model.assistant.open()}}
    @objc func quit(){if model.voice.recording || model.voice.busy{model.message="请先结束录音并等待转写。";showLibrary();return};model.saveWorkspace();NSApp.terminate(nil)}
    func showLibrary() {
        if model.voice.owner=="lookup" && (model.voice.recording || model.voice.busy){model.quickStatus="请先完成录音和转写。";model.askStatus=model.quickStatus;return}
        model.refresh()
        if model.tab == .practice || model.tab == .map {model.checkKnowledgeUpdates()}
        if library==nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),
                           styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            w.title="Vocab · 我的语言";w.isReleasedWhenClosed=false;w.minSize=NSSize(width:780,height:560)
            w.contentView=NSHostingView(rootView:LibraryView(model:model));w.center();w.delegate=self
            library=w
        }
        hideQuick()
        NSApp.activate(ignoringOtherApps:true);library?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{
        if sender === library && model.voice.owner?.hasPrefix("practice:")==true && (model.voice.recording || model.voice.busy){model.pStatus="请先结束录音并等待转写。";return false}
        return true
    }
    func windowWillClose(_ notification:Notification) {
        if notification.object as? NSWindow === library {
            if model.practicing{model.pausePractice()}else{model.saveWorkspace()}
        }
    }
    func showQuick() {
        if panel==nil {
            let p=QuickPanel(contentRect:NSRect(x:0,y:0,width:442,height:300),
                             styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            p.isOpaque=false;p.backgroundColor = .clear;p.hasShadow=true
            p.level = .floating;p.hidesOnDeactivate=false;p.isReleasedWhenClosed=false
            p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            p.contentView=NSHostingView(rootView:QuickView(model:model))
            panel=p
        }
        shownAt=Date();model.hover=false
        resizeQuick()
        panel?.orderFrontRegardless()
        if model.editing || model.asking {panel?.makeKey()}
    }
    func resizeQuick() {
        guard let p=panel else{return}
        let mouse=NSEvent.mouseLocation
        let screen=NSScreen.screens.first(where:{$0.frame.contains(mouse)}) ?? NSScreen.main
        let frame=screen?.visibleFrame ?? NSRect(x:0,y:0,width:1024,height:768)
        let width:CGFloat = model.expanded ? 510 : 442
        let w=min(width,frame.width-24)
        let availableHeight=frame.height-24
        let height:CGFloat = model.editing ? 166 : model.asking ? 620 : model.expanded ? 580 :
            QuickPanelLayout.compactHeight(model:model,width:w,availableHeight:availableHeight,appearance:p.effectiveAppearance)
        let h=min(height,availableHeight)
        let proposedX = p.isVisible ? p.frame.minX : mouse.x-w/2
        let x=min(max(proposedX,frame.minX+12),frame.maxX-w-12)
        var y=p.isVisible ? p.frame.maxY-h : mouse.y-h-18
        if y<frame.minY+12 {y=min(mouse.y+20,frame.maxY-h-12)}
        y=min(max(y,frame.minY+12),frame.maxY-h-12)
        p.setFrame(NSRect(x:x,y:y,width:w,height:h),display:true)
    }
    func hideQuick(){panel?.orderOut(nil)}
    func applicationWillTerminate(_ notification:Notification) {
        timer?.invalidate()
        if let wakeObserver{NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)}
        model?.cancelDictionaryRecovery()
        if let hotkey {UnregisterEventHotKey(hotkey)}
        if let eventHandler {RemoveEventHandler(eventHandler)}
        for monitor in [mouseMonitor,keyMonitor,localKey] {if let monitor {NSEvent.removeMonitor(monitor)}}
        model?.voice.cancel()
        model?.assistant.cancelAll()
        model?.saveWorkspace()
    }
}

@main struct VocabApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") { exit(SelfTests.run()) }
        if CommandLine.arguments.contains("--distribution-test") { exit(SelfTests.distribution()) }
        if CommandLine.arguments.contains("--live-distribution-test") { exit(SelfTests.liveDistribution()) }
        if CommandLine.arguments.contains("--stability-test") { exit(SelfTests.stabilityOnly()) }
        if let index=CommandLine.arguments.firstIndex(of:"--dictionary-audit") {
            exit(SelfTests.dictionaryAudit(Array(CommandLine.arguments.dropFirst(index+1))))
        }
        if CommandLine.arguments.contains("--live-studio-test") { exit(SelfTests.liveStudio()) }
        if CommandLine.arguments.contains("--live-knowledge-test") { exit(SelfTests.liveKnowledge()) }
        if CommandLine.arguments.contains("--live-stable-flow-test") { exit(SelfTests.liveStableFlow()) }
        if let i=CommandLine.arguments.firstIndex(of:"--snapshot-studio"),CommandLine.arguments.count>i+2 {
            let a=CommandLine.arguments;exit(SelfTests.studioSnapshot(screen:a[i+1],path:a[i+2],light:a.contains("--light")))
        }
        if let i=CommandLine.arguments.firstIndex(of:"--snapshot-dictionary"),CommandLine.arguments.count>i+4 {
            let a=CommandLine.arguments
            if let page=DictionaryPage(rawValue:a[i+2]) {
                exit(SelfTests.snapshot(term:a[i+1],page:page,expanded:a[i+3]=="expanded",path:a[i+4],light:a.contains("--light")))
            }
            exit(2)
        }
        if let i=CommandLine.arguments.firstIndex(of:"--ocr-file"),CommandLine.arguments.count>i+3 {
            let args=CommandLine.arguments
            if let image=NSImage(contentsOfFile:args[i+1]), let x=Double(args[i+2]),let y=Double(args[i+3]) {
                var r=NSRect(origin:.zero,size:image.size)
                if let cg=image.cgImage(forProposedRect:&r,context:nil,hints:nil),
                   let candidate=try? LocalOCR.recognize(cg,pointer:CGPoint(x:x,y:y),preferSelection:true) {
                    print("text=\(candidate.text); highlighted=\(candidate.highlighted); exact=\(candidate.exact); confidence=\(candidate.confidence)")
                    exit(0)
                }
            }
            exit(1)
        }
        let app=NSApplication.shared
        let controller=VocabController()
        app.delegate=controller
        app.run()
        _=controller
    }
}
