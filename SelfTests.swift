import Cocoa
import Foundation
import SwiftUI

final class StudioTestAssistant: LanguageAssistant {
    private var callbacks: [String:(AssistantEvent)->Void] = [:]
    private var order:[String]=[]
    private var cancelledCallbacks:[String:(AssistantEvent)->Void]=[:]
    private(set) var prompts:[String]=[]
    override func ask(_ prompt:String,request:String,route:String,callback:@escaping(AssistantEvent)->Void) {
        prompts.append(prompt);callbacks[request]=callback;order.append(request)
    }
    override func cancel(_ id:String) {cancelledCallbacks[id]=callbacks.removeValue(forKey:id);order.removeAll{$0==id}}
    func lateResult(_ text:String){
        guard let (id,callback)=cancelledCallbacks.first else{return};cancelledCallbacks[id]=nil
        callback(.init(type:"result",request:id,text:text,model:"DeepSeek-Flash",effort:"high",provider:"qoder-cn"))
    }
    func respond(_ text:String) {
        guard let id=order.last,let callback=callbacks.removeValue(forKey:id) else{return}
        order.removeAll{$0==id};callback(.init(type:"result",request:id,text:text,model:"DeepSeek-Flash",effort:"high",provider:"qoder-cn"))
    }
    func fail() {
        guard let id=order.last,let callback=callbacks.removeValue(forKey:id) else{return}
        order.removeAll{$0==id};callback(.init(type:"error",request:id,text:"fixture unavailable"))
    }
}

enum SelfTests {
    @MainActor static func liveDistribution()->Int32 {
        var result:Int32?
        Task {
            do {
                let base=KnowledgeCatalog.bundled()
                var older=base;older.releaseSequence=0
                let version=Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.0"
                guard let pack=try await KnowledgeUpdate.fetch(current:older,appVersion:version) else{throw SupportError.message("No current release")}
                let root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-live-distribution-"+UUID().uuidString)
                defer{try? FileManager.default.removeItem(at:root)}
                for name in ["existing","fresh"] {
                    let support=root.appendingPathComponent(name)
                    let installed=try KnowledgeUpdate.install(pack,support:support,base:older,appVersion:version)
                    try assert(installed==pack.catalog,"verified public knowledge asset for "+name)
                    let again=try await KnowledgeUpdate.fetch(current:installed,appVersion:version)
                    try assert(again==nil,"public channel recognises current revision for "+name)
                }
                result=0
            }catch{print(error.localizedDescription);result=1}
        }
        let deadline=Date().addingTimeInterval(75)
        while result==nil,Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
        return result ?? 1
    }
    static func distribution()->Int32 {
        do {
            let base=KnowledgeCatalog.bundled()
            try assert(base.valid && base.units.count>=112 && base.releaseSequence != nil,"bundled official knowledge catalog")
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-distribution-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            var next=base
            next.releaseSequence=(base.releaseSequence ?? 0)+1
            next.releaseVersion="99.0.0"
            var newUnit=base.units[0];newUnit.id="l.distribution-fixture"
            next.units.append(newUnit)
            let data=try JSONEncoder().encode(next)
            let manifest=KnowledgeRelease(sequence:next.releaseSequence!,version:next.releaseVersion!,schemaVersion:1,minAppVersion:"2.2.0",sha256:KnowledgeUpdate.digest(data),unitCount:next.units.count,scenarioCount:next.units.reduce(0,{$0+$1.scenarios.count}))
            let pack=try KnowledgeUpdate.validate(data,manifest:manifest,current:base,appVersion:"2.2.0")
            let a=root.appendingPathComponent("existing"),b=root.appendingPathComponent("fresh")
            try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true)
            let marker=a.appendingPathComponent("private-test.txt")
            try Data("private test".utf8).write(to:marker)
            try assert(try KnowledgeUpdate.install(pack,support:a,base:base,appVersion:"2.2.0")==next,"existing install advances knowledge without replacing data")
            try assert(KnowledgeCatalog.load(support:b,base:base)==base,"another local user remains independent")
            try assert(try KnowledgeUpdate.install(pack,support:b,base:base,appVersion:"2.2.0")==next,"fresh user independently installs same revision")
            try assert(try Data(contentsOf:marker)==Data("private test".utf8),"private file unchanged")
            try assert((try? KnowledgeUpdate.validate(data,manifest:manifest,current:next,appVersion:"2.2.0"))==nil,"reject replay")
            try assert((try? KnowledgeUpdate.validate(data,manifest:manifest,current:base,appVersion:"2.1.2"))==nil,"reject incompatible app version")
            try assert((try? KnowledgeUpdate.validate(data+Data([0]),manifest:manifest,current:base,appVersion:"2.2.0"))==nil,"reject altered bytes")
            var removed=next;removed.units.removeFirst()
            try assert(!KnowledgeCatalog.extends(removed,base),"reject deletion of existing identity")
            try Data("broken".utf8).write(to:a.appendingPathComponent("KnowledgeCatalog.json"),options:.atomic)
            try assert(KnowledgeCatalog.load(support:a,base:base)==next,"recover last-good catalog after damaged local file")
            return 0
        }catch{print(error.localizedDescription);return 1}
    }
    static func assert(_ yes:@autoclosure () throws ->Bool,_ explanation:String) throws {
        if try !yes() { throw SupportError.message("FAIL: "+explanation) }
        print("PASS "+explanation)
    }
    @MainActor static func run()->Int32 {
        do {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-selftest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer {try? FileManager.default.removeItem(at:root)}
            let store=try Store(url:root.appendingPathComponent("data.sqlite"))
            let fixture=root.appendingPathComponent("Vocabulary.md")
            let data="# Vocabulary\n\n| 词 | 音标 | 释义 | 同义词 | 次数 | 日期 | 来源 |\n|---|---|---|---|---|---|---|\n| ambivalent | ipa | 矛盾 | | 2 | 11-19 | 图书 |\n| reticent | | 寡言 | | 1 | 11-20 | Obsidian |\n"
            try data.write(to:fixture,atomically:true,encoding:.utf8)
            try store.importLegacy(fixture);try store.importLegacy(fixture)
            let rows=try store.legacyRows()
            try assert(rows.count==2 && rows.reduce(0){$0+$1.count}==3,"旧表聚合导入幂等、原次数保留")
            try assert((try? String(contentsOf:fixture,encoding:.utf8))==data,"迁移不改原文件")
            try assert((try store.allExpressions()).isEmpty,"旧查询不自动收藏")
            let phrase="in the teeth of"
            let r=LookupRecord(original:phrase,query:queryText(phrase),application:"Fixture",appID:"fixture",capture:"手动")
            try store.put(r);try store.put(r)
            try assert((try store.history()).count==1 && r.query==phrase,"完整短语保留、同事件更新不重复")
            var e=expressionFrom(r);e.kind = .collocation
            let a=try store.saveExpression(e)
            let b=try store.saveExpression(expressionFrom(r))
            try assert(a.id==b.id && (try store.allExpressions()).count==1,"同表达收藏幂等")
            var another=expressionFrom(r);another.intent="另一个具体表达意图";try store.saveExpression(another)
            try assert((try store.allExpressions()).count==2,"不同表达意图独立")
            let now=Date().timeIntervalSince1970
            let assisted=Scheduler.apply(.independent,hinted:true,to:a,now:now)
            try assert(assisted.stage==1 && assisted.learning == .learning,"看见目标不算独立掌握")
            let alternative=Scheduler.apply(.alternative,hinted:false,to:assisted,now:now)
            try assert(alternative.successes==0 && alternative.learning == .learning,"自然替代表达不错误提升掌握")
            let independent=Scheduler.apply(.independent,hinted:false,to:assisted,now:now)
            try assert(independent.stage==2 && independent.learning == .independent && independent.due! > now,"真实独立输出调整练习间隔")
            let p=Practice(expressionID:a.id,mode:"One Thought",stage:0,question:"example",answer:"example",hint:true,feedback:"self",rating:.assisted,next:assisted.due)
            try store.putPractice(p,expression:assisted)
            try assert((try store.practices(a.id)).count==1,"反馈与调度事务持久化")
            let validPractice = StudioPrompts.Generated(prompt:"A colleague raises a sensitive issue. What would you advise?",material:nil)
            try assert(StudioPrompts.validTarget(validPractice,target:"tread lightly",mode:.thought),"允许不泄露目标词的主动提取情境")
            try assert(!StudioPrompts.validTarget(.init(prompt:"Use TREAD-lightly in this situation.",material:nil),target:"tread lightly",mode:.thought),"拒绝用标点或大小写变化泄露目标词")
            try assert(!StudioPrompts.validTarget(validPractice,target:"tread lightly",mode:.retell),"拒绝没有阅读材料的复述任务")
            try studioTests(root:root)
            try knowledgeTests(root:root)
            try workspaceTests(root:root)
            try stabilityTests(root:root)
            let export=try store.exportJSON()
            try assert(!export.isEmpty && (try store.exportMarkdown()).contains(phrase) && (try store.exportCSV()).contains(phrase),"JSON/Markdown/CSV 导出")
            let ordinary=DictionaryEngine.lookup("imperative")
            try assert(ordinary.status == .found && ordinary.definition?.source=="Oxford Dictionary of English" &&
                       ordinary.definition?.chinese != nil && ordinary.definition?.supplement != nil,"常见词三本指定 Oxford 精确命中")
            let place=DictionaryEngine.lookup("Granite State")
            try assert(place.status == .found && place.definition?.matched=="Granite State" &&
                       place.definition?.body.contains("New Hampshire")==true,"无常规 df 的 Oxford 交叉引用词条仍可读")
            let definitelyMissing=DictionaryEngine.lookup("zznotavocabwordzz")
            try assert(definitelyMissing.status == .noMatch && definitelyMissing.definition==nil,"三本健康词典真正未返回词条的独立状态")
            let ostensibly=DictionaryEngine.local("ostensibly")
            try assert(ostensibly?.complete==true && ostensibly?.detail.isEmpty==false,"本机词典单词命中")
            let fullPhrase=DictionaryEngine.local("put up with")
            try assert(fullPhrase?.term=="put up with" && fullPhrase?.matched=="put up with" && fullPhrase?.complete==true,"完整短语精确匹配")
            if let d=DictionaryEngine.oxford("padlock") {
                try assert(d.source=="Oxford Dictionary of English" && d.body.contains("detachable lock")
                           && d.detail.contains("ORIGIN") && d.supplement?.source.contains("Writer") == true
                           && d.supplement?.detail.contains("lock, lock up") == true,
                           "Oxford 主释义、词源与写作词库分离")
                let phrase=DictionaryEngine.oxford("put up with")
                try assert(phrase?.complete == true && phrase?.matched=="put up with"
                           && phrase?.body.contains("tolerate or endure") == true
                           && phrase?.detail.contains("PHRASAL VERBS") == false,
                           "Oxford 短语精确定位，不返回整个母词")
                let usage=DictionaryEngine.oxford("affect")
                try assert(usage?.detail.contains("USAGE") == true && usage?.supplement != nil,
                           "Oxford 用法及写作内容保留")
                let granted=DictionaryEngine.oxford("take for granted")
                try assert(granted?.body.contains("assume that something is true") == true,
                           "多义短语的核心义项保留")
                let hazard=DictionaryEngine.oxford("hazard")
                try assert(hazard?.content?.groups.map(\.partOfSpeech) == ["noun","verb"]
                           && hazard?.content?.groups.first?.senses.count == 5
                           && hazard?.content?.groups.first?.senses.first?.meanings.count == 3,
                           "名词、动词、编号义项和从属义项独立保留")
                try assert(hazard?.chinese?.content?.groups.first?.senses.first?.meanings.first?.definition.contains("危险") == true
                           && hazard?.chinese?.content?.groups.first?.senses.first?.meanings.first?.examples.first?.contains("火灾隐患") == true,
                           "本机英汉准确分离释义及对应例句")
                try assert(hazard?.supplement?.content?.groups.first?.senses.first?.meanings.first?.synonymGroups.count == 3
                           && hazard?.supplement?.content?.sections.contains(where:{$0.title.contains("CHOOSE THE RIGHT WORD")}) == true,
                           "Writer 语义同义词分组保留，不连成长段")
                try assert(phrase?.chinese?.content?.groups.first?.senses.first?.meanings.first?.definition.contains("容忍") == true,
                           "中文短语精确定位")
            } else { throw SupportError.message("指定 Oxford 词源不可用，不能通过发布回归") }
            // Actual user queries that formerly fell through to the online API.
            for (form,lemma) in [("eluded","elude"),("surmises","surmise"),("suppositions","supposition"),
                                 ("vertebrae","vertebra"),("misgivings","misgiving"),
                                 ("children","child"),("bought","buy"),("cities","city"),
                                 ("stopped","stop"),("went","go"),("ran","run")] {
                let d=DictionaryEngine.local(form)
                try assert(d?.source=="Oxford Dictionary of English" && d?.term==form &&
                           d?.matched==lemma && d?.match=="inflected" &&
                           !(d?.content?.groups.isEmpty ?? true),"Oxford 词形匹配：\(form) → \(lemma)")
            }
            let surmises=DictionaryEngine.local("surmises")
            try assert(surmises?.content?.groups.map(\.partOfSpeech)==["verb","noun"] && surmises?.supplement != nil,
                       "保留复数／动词第三人称的两种词性及 Writer 结果")
            let saw=DictionaryEngine.local("saw")
            try assert(saw?.matched=="saw" && saw?.match=="exact" &&
                       saw?.content?.groups.contains(where:{$0.partOfSpeech=="verb · see"})==true,
                       "同形词优先精确词头，仍区分另一原形")
            let eluded=DictionaryEngine.local("eluded")
            try assert(eluded?.preferredPronunciations.first?.ipa=="ɪˈluːdɪd" &&
                       eluded?.preferredPronunciations.first?.term=="eluded" &&
                       eluded?.preferredPronunciations.first?.derived==true,
                       "规则过去式音标明确标注为推导，不冒充词典原文")
            let vertebrae=DictionaryEngine.local("vertebrae")
            try assert(vertebrae?.preferredPronunciations.count==2 &&
                       vertebrae?.preferredPronunciations.allSatisfy{$0.term=="vertebrae" && $0.derived != true}==true,
                       "不规则复数优先使用词典真实变体音标")
            let misgivings=DictionaryEngine.local("misgivings")
            try assert(misgivings?.preferredPronunciations.first?.source=="Oxford Chinese Dictionary" &&
                       misgivings?.preferredPronunciations.first?.term=="misgivings" &&
                       misgivings?.preferredPronunciations.first?.derived != true,
                       "实际选区的现有 Oxford 音标优于推导音标")
            let read=DictionaryEngine.local("read")
            try assert(Set(read?.preferredPronunciations.map(\.ipa) ?? [])==Set(["riːd","rɛd"]),
                       "同形异音保留两种真实音标")
            try assert(DictionaryEngine.local("barefaced questions")==nil &&
                       DictionaryEngine.local("zznotavocabwordzz")==nil,
                       "完整表达未命中即停止，不截首词或转向在线词典")
            try assert(DictionaryEngine.local("ingenious")?.preferredPronunciations.first?.ipa=="ɪnˈdʒiːniəs",
                       "常规单词保留实际 Oxford 音标")
            let model=VocabModel(store:store)
            let before=try store.allExpressions().count
            model.record=r
            model.replies=[ChatReply(question:"意思？",answer:"解释测试",turn:nil)]
            model.keepExplanation()
            try assert(try store.allExpressions().count==before && store.history().first(where:{$0.id==r.id})?.savedExplanations?.count==1,
                       "保留 AI 解释不自动转入主动表达库")
            if let hazard=DictionaryEngine.oxford("hazard"),
               let meaning=hazard.content?.groups.first?.senses.first?.meanings.first {
                var lookup=LookupRecord(original:"hazard",query:"hazard",application:"Fixture",appID:"fixture",capture:"手动")
                lookup.definition=hazard;try store.put(lookup);model.record=lookup
                model.preciseSave(partOfSpeech:"noun",meaning:meaning)
                let after=try store.allExpressions()
                try assert(after.count==before+1 && after.contains(where:{$0.target=="hazard" && $0.intent.contains("a danger or risk") && $0.example==meaning.examples.first})
                           && model.editingExpression==nil,"直接收藏指定义项与所属例句，不离开浮窗")
                model.preciseSave(partOfSpeech:"noun",meaning:meaning)
                try assert(try store.allExpressions().count==before+1,"重复收藏同义项不重复创建")
            }
            // Regression for real short entries whose 224-point popup used
            // to have no visible definition. Exercise the same native layout
            // measurement used by the production window (both language pages).
            _ = NSApplication.shared
            let appearance=NSAppearance(named:.darkAqua)
            var measured:[String:CGFloat]=[:]
            for term in ["camcorder","bounder","germane","philanthropy","inertia","surmises","vertebrae","latch"] {
                guard let definition=DictionaryEngine.local(term) else {throw SupportError.message("布局测试词条缺失：\(term)")}
                var lookup=LookupRecord(original:term,query:term,application:"Fixture",appID:"fixture",capture:"手动")
                lookup.definition=definition;model.record=lookup;model.toast="";model.expanded=false
                let en=QuickPanelLayout.naturalHeight(model:model,width:442,page:.english,appearance:appearance)
                let cn=QuickPanelLayout.naturalHeight(model:model,width:442,page:.chinese,appearance:appearance)
                let h=QuickPanelLayout.compactHeight(model:model,width:442,availableHeight:700,appearance:appearance)
                let required=max(en,cn)
                try assert(required>224 && h>224 && h>=min(ceil(required+12),QuickPanelLayout.compactLimit),
                           "实际收起布局可容纳双语核心释义：\(term)（\(Int(h)) pt）")
                measured[term]=h
            }
            try assert((measured["camcorder"] ?? 440)<(measured["latch"] ?? 0),"短义项紧凑，多义项按实际排版增高")
            let narrow=QuickPanelLayout.compactHeight(model:model,width:320,availableHeight:300,appearance:appearance)
            try assert(narrow==300,"窄屏及有限高度只限制内容区滚动，不越出可用屏幕")
            let beforeToast=QuickPanelLayout.naturalHeight(model:model,width:442,page:.english,appearance:appearance)
            model.toast="已收藏 · 日后主动练习"
            let afterToast=QuickPanelLayout.naturalHeight(model:model,width:442,page:.english,appearance:appearance)
            try assert(afterToast>beforeToast,"新增收藏提示等实际界面内容计入高度")
            model.toast=""
            let image=NSImage(size:NSSize(width:640,height:180))
            image.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect:NSRect(x:0,y:0,width:640,height:180)).fill()
            ("ambivalent" as NSString).draw(at:NSPoint(x:190,y:72),withAttributes:[.font:NSFont.systemFont(ofSize:32),.foregroundColor:NSColor.black])
            image.unlockFocus()
            var rect=NSRect(x:0,y:0,width:640,height:180)
            if let cg=image.cgImage(forProposedRect:&rect,context:nil,hints:nil) {
                let recognized=try LocalOCR.recognize(cg,pointer:CGPoint(x:0.44,y:0.5))
                try assert(recognized?.text.lowercased()=="ambivalent","Vision 本机 OCR 合成图像选词")
            } else {throw SupportError.message("无法创建 OCR 测试图片")}
            // Simulate Books dark mode: selected words have a gray rectangular
            // background, while the pointer is elsewhere in the same line.
            let dark=NSImage(size:NSSize(width:820,height:210))
            let font=NSFont.systemFont(ofSize:34)
            let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:NSColor.white]
            let prefix="There was a " as NSString,selected="padlock and a chain" as NSString
            dark.lockFocus()
            NSColor.black.setFill();NSBezierPath(rect:NSRect(x:0,y:0,width:820,height:210)).fill()
            let dx:CGFloat=30,dy:CGFloat=90
            let start=dx+prefix.size(withAttributes:attrs).width
            let width=selected.size(withAttributes:attrs).width
            NSColor(calibratedWhite:0.25,alpha:1).setFill()
            NSBezierPath(rect:NSRect(x:start-1,y:dy-4,width:width+2,height:43)).fill()
            ("There was a padlock and a chain upon the gate." as NSString).draw(at:NSPoint(x:dx,y:dy),withAttributes:attrs)
            dark.unlockFocus()
            var darkRect=NSRect(x:0,y:0,width:820,height:210)
            if let cg=dark.cgImage(forProposedRect:&darkRect,context:nil,hints:nil) {
                let recognized=try LocalOCR.recognize(cg,pointer:CGPoint(x:0.10,y:0.5),preferSelection:true)
                print("selection fixture:",recognized?.text ?? "none")
                try assert(recognized?.text.lowercased()=="padlock and a chain" && recognized?.highlighted==true,
                           "Books 灰色多词选区优先于鼠标指针")
            } else {throw SupportError.message("无法创建选区测试图片")}
            print("Vocab self-test OK")
            return 0
        } catch {fputs("\(error.localizedDescription)\n",stderr);return 1}
    }

    @MainActor static func stabilityTests(root:URL)throws {
        let base=KnowledgeCatalog.bundled()
        guard let take=base.unit("l.take-need"),let get=base.unit("l.get-understand"),let clarify=base.unit("i.clarify-specific") else{throw SupportError.message("Missing core fixtures")}
        try assert(base.units.count==112 && base.units.allSatisfy{$0.coreScenarioIDs != nil && (1...3).contains($0.coreScenarios.count) && $0.scenarios.allSatisfy{$0.interaction != nil}},"正式 112 项均有明确核心与互动合同")
        let store=try Store(url:root.appendingPathComponent("stability.sqlite")),ai=StudioTestAssistant(),url=root.appendingPathComponent("stable-state.json")
        let e=try store.saveExpression(Expression(original:"encumbered",target:"encumbered",kind:.word,intent:"阻碍",definition:"burdened",source:"fixture"))
        let m=VocabModel(store:store,assistant:ai,workspaceURL:url)
        m.startPractice(expression:e);ai.respond(#"{"prompt":"Describe a burden on an organisation.","material":null}"#)
        m.pAnswer="The business was encumbered by unnecessary rules.";m.submitPractice();m.saveWorkspace()
        let pending=try store.practices(e.id).first!
        try assert(pending.feedback.isEmpty && pending.completed,"单次表达立即完成，反馈尚在等待")
        let ai2=StudioTestAssistant(),r=VocabModel(store:store,assistant:ai2,workspaceURL:url)
        r.requestFeedback();ai2.respond(#"{"summary":"自然。","targetUse":"used","targetQuote":"encumbered","clue":{"category":"措辞","focus":"描述实际负担","evidence":"unnecessary rules"}}"#)
        let first=try store.practice(pending.id)!,scheduled=try store.allExpressions().first{$0.id==e.id}!
        try assert(first.scheduleReceipt != nil && scheduled.stage==1 && scheduled.due != e.due,"重启后补评恢复调度并保存单次应用凭据")
        r.requestFeedback();try assert(ai2.prompts.count==1,"同答案版本不会重复评价或调度")
        r.discussFeedback(first,question:"Is burdened an equally natural alternative?")
        ai2.respond("In this context, yes — with a slightly different register.")
        let discussed=try store.practice(first.id)!
        try assert(discussed.feedbackDiscussion?.count==1 && discussed.rating==first.rating && (try store.practices()).count==1 && (try store.allExpressions()).first{$0.id==e.id}==scheduled,"反馈追问保留同一原答且不改变评级/调度/尝试数")
        var staleEditor=e;staleEditor.notes="保留我的备注";r.saveEdited(staleEditor)
        let afterEditor=try store.allExpressions().first{$0.id==e.id}!
        try assert(first.scheduleReceipt?.after.matchesSchedule(afterEditor)==true && afterEditor.notes==staleEditor.notes,"打开编辑器时后台反馈推进调度，保存备注不覆盖新调度")
        try assert(r.correctPractice(discussed,text:"The business is encumbered by unnecessary rules."),"可以修正同一答案")
        let revised=try store.practice(first.id)!,restored=try store.allExpressions().first{$0.id==e.id}!
        try assert(revised.id==first.id && revised.revision==1 && revised.answerRaw==first.answer && revised.feedback.isEmpty && revised.clue==nil && revised.scheduleReceipt==nil && restored.stage==e.stage && restored.due==e.due && restored.notes==staleEditor.notes,"修正转写保留原答，旧评价线索失效并回滚最新调度")
        r.requestFeedback();try assert(r.correctPractice(revised,text:"The business remains encumbered by unnecessary rules."),"等待时可以修正转写")
        ai2.lateResult(#"{"summary":"过时结果","targetUse":"used","targetQuote":"encumbered"}"#)
        try assert((try store.practice(first.id))?.feedback.isEmpty==true && (try store.practice(first.id))?.revision==2,"迟到旧版本评价不能覆盖修正后的答案")
        r.requestFeedback();ai2.respond(#"{"summary":"自然。","targetUse":"used","targetQuote":"encumbered"}"#)
        let reevaluated=try store.practice(first.id)!,newSchedule=try store.allExpressions().first{$0.id==e.id}!
        try assert(reevaluated.scheduleReceipt?.revision==2 && newSchedule.stage==1 && (try store.practices()).count==1,"修正后显式重评只更新一次，不新增练习")
        let later=Practice(expressionID:e.id,time:reevaluated.time+60,mode:"One Thought",stage:1,question:"later",answer:"Later answer",hint:false,feedback:"later",rating:.completed,next:nil)
        try store.putPractice(later);r.refresh()
        try assert(r.correctPractice(reevaluated,text:"The organisation remains encumbered by rules.") && (try store.practice(first.id))?.scheduleBlocked==true && (try store.allExpressions()).first{$0.id==e.id}==newSchedule,"修正较旧尝试不覆盖后来学习调度")
        r.stopPractice()
        let mapStore=try Store(url:root.appendingPathComponent("core-coverage.sqlite")), mapAI=StudioTestAssistant()
        let map=VocabModel(store:mapStore,assistant:mapAI,catalog:.init(schemaVersion:1,units:[take,get,clarify]))
        map.startKnowledge(take,scenarioID:take.extraScenarios[0].id);let extraActivity=map.activity?.id
        map.backToActivityOrigin();map.startKnowledge(take)
        try assert(map.activity?.id != extraActivity && map.currentScenes.count==take.coreScenarios.count,"从额外复练返回地图，主要按钮真正开启核心组")
        map.startKnowledge(take)
        try assert(map.currentScenes.count==take.coreScenarios.count && map.currentScenes.count<take.scenarios.count,"地图仅安排核心组，保留额外情境供复练")
        map.pAnswer="It took us three hours to check the figures.";map.submitPractice()
        try assert(take.coverage(map.progress(for:take)) == .inProgress && map.pFeedbackWaiting,"真实提交第一核心即进行中，无需等待模型")
        map.nextPractice();map.pAnswer="Such a career change takes sustained effort.";map.submitPractice()
        try assert(take.coverage(map.progress(for:take)) == .covered,"完成全部核心任务即覆盖，不需证明独立")
        map.stopPractice();map.startKnowledge(take,scenarioID:take.extraScenarios[0].id)
        try assert(map.currentScenes.count==1 && take.coverage(map.progress(for:take)) == .covered,"额外复练不改变已覆盖状态、不重复安排核心")
        map.stopPractice();map.startKnowledge(get,scenarioID:"plan-briefing")
        map.pAnswer="Yes, I get what you mean.";map.submitPractice()
        try assert(map.pSubmitted && map.pDialogue.isEmpty && map.currentPracticeRecord?.completed==true,"单次情境回应立即进入反馈，不额外聊天")
        map.stopPractice();map.startKnowledge(clarify,scenarioID:"figures-friday")
        map.pAnswer="Do you mean submission or feedback?";map.submitPractice()
        try assert(map.pTask?.isDialogue==true && map.currentPracticeRecord?.completed==false,"定向澄清首轮未完成不计核心覆盖")
        mapAI.respond("It is the submission deadline. Feedback comes next week.")
        map.pAnswer="Right, we submit on Friday.";map.submitPractice();mapAI.respond("Exactly, that's the arrangement.")
        map.pAnswer="Thanks for clarifying.";map.submitPractice();mapAI.respond("You're welcome.")
        try assert(!map.pSubmitted && map.currentPracticeRecord?.completed==false,"真实多轮不因第三条回复强制结束")
        map.finishConversation();try assert(map.pSubmitted && map.currentPracticeRecord?.completed==true,"有实际伙伴回合并结束才完成对话训练")
        mapAI.respond(#"{"summary":"澄清有效。","knowledgeUse":"used","knowledgeQuote":"Right, we submit on Friday.","knowledgePartnerQuote":"It is the submission deadline.","knowledgeReason":"确认提交日期。"}"#)
        map.stopPractice();let coverageBefore=map.coverage().covered;let countBefore=try mapStore.completedTaskCounts().all
        map.startDiscussion();map.pAnswer="I think a change of mind can be valuable.";map.submitPractice();mapAI.respond("What made you think that?")
        map.finishConversation();mapAI.respond(#"{"summary":"观点清晰。"}"#)
        try assert(map.coverage().covered==coverageBefore && (try mapStore.completedTaskCounts()).all==countBefore && map.currentPracticeRecord?.taskKey?.hasPrefix("discussion:")==true,"综合表达不冒充地图覆盖或定向推荐配额")
        map.stopPractice()
        let mixStore=try Store(url:root.appendingPathComponent("core-mixed.sqlite")),mixAI=StudioTestAssistant(),mix=VocabModel(store:mixStore,assistant:mixAI,catalog:.init(schemaVersion:1,units:[take]))
        mix.startPractice();let firstCore=mix.pTask?.knowledgeContext?.id
        mix.pAnswer="It took us three hours.";mix.submitPractice();mix.nextPractice()
        try assert(mix.pTask?.knowledge?.id==take.id && mix.pTask?.knowledgeContext?.id != firstCore,"随便练习先完成同一知识组再换点")
        try assert(DiscussionTopic.bank.count>=12 && DiscussionTopic.bank.allSatisfy{$0.knowledge.allSatisfy{base.unit($0) != nil}},"主题池链接真实知识身份，不是随机模板")
        // A committed SQLite row may be newer than a debounced workspace.
        let crashStore=try Store(url:root.appendingPathComponent("stability-crash.sqlite")),crashAI=StudioTestAssistant(),crashURL=root.appendingPathComponent("stability-crash.json")
        let cm=VocabModel(store:crashStore,assistant:crashAI,workspaceURL:crashURL)
        cm.startPractice(mode:.thought);cm.pAnswer="Committed answer.";cm.saveWorkspace()
        let task=cm.pTask!
        let committed=Practice(expressionID:nil,mode:task.mode.rawValue,stage:0,question:task.prompt,answer:cm.pAnswer,hint:false,feedback:"",rating:.unassessed,next:nil,taskID:task.id,taskKey:task.key,learningVersion:4,interaction:.expression,completedAt:Date().timeIntervalSince1970)
        try crashStore.putPractice(committed)
        let recoveredAI=StudioTestAssistant(),recovered=VocabModel(store:crashStore,assistant:recoveredAI,workspaceURL:crashURL)
        try assert(recovered.pSubmitted && recovered.currentPracticeRecord?.id==committed.id,"数据库已提交而现场尚未写回时按任务 ID 恢复，不重复答题")
        recovered.requestFeedback();recoveredAI.respond(#"{"summary":"Old detail."}"#);recovered.saveWorkspace()
        var changed=try crashStore.practice(committed.id)!;changed.answerRaw=changed.answer;changed.answer="Corrected answer.";changed.answerRevision=1;changed.invalidateEvaluation();try crashStore.putPractice(changed)
        let afterCrash=VocabModel(store:crashStore,assistant:StudioTestAssistant(),workspaceURL:crashURL)
        try assert(afterCrash.savedPracticeAnswer==changed.answer && afterCrash.pFeedbackDetail==nil && afterCrash.pFeedback.isEmpty,"数据库转写修正领先工作现场时，旧结构化反馈与建议不得恢复")
        let reviewStore=try Store(url:root.appendingPathComponent("review-interleave.sqlite"));let five=Array(base.units.prefix(5));let past=Date().timeIntervalSince1970-86400
        for (i,u) in five.prefix(3).enumerated(){for s in u.coreScenarios{
            try reviewStore.putPractice(Practice(expressionID:nil,time:past+Double(i*10),mode:s.studioMode.rawValue,stage:0,question:s.prompt,answer:"A real prior answer",hint:true,feedback:"feedback",rating:.completed,next:nil,taskKey:"knowledge:"+u.id,learningVersion:4,knowledge:u.target,knowledgeContext:.init(id:s.id,description:s.context,transferEligible:true),knowledgeSession:"completed-group-\(i)",interaction:s.contract,completedAt:past))
        }}
        let interleave=VocabModel(store:reviewStore,assistant:StudioTestAssistant(),catalog:.init(schemaVersion:1,units:five))
        interleave.startPractice();try assert(interleave.pTask?.reviewingCovered==true,"两个真实新知识组之后可穿插已覆盖知识的复练")
        interleave.skipScene()
        try assert(interleave.pTask?.reviewingCovered != true && interleave.currentKnowledgeUnit.map{$0.coverage(interleave.progress(for:$0)) == .untouched}==true,"复练机会消费后继续未覆盖知识，不连续耗尽旧点")
        let oldClue=PracticeClue(category:"语法",focus:"interested 后接 in",evidence:"interested on",functional:.preposition,correction:"I am interested in it.",blank:"in")
        let newClue=PracticeClue(category:"清晰度",focus:"回应 when 时给出时机",evidence:"A little patience can help.")
        let now=Date().timeIntervalSince1970
        let olderClue=Practice(expressionID:nil,time:now-86400,mode:"One Thought",stage:0,question:"previous",answer:"I am interested on it.",hint:false,feedback:"feedback",rating:.completed,next:nil,clue:oldClue,learningVersion:4,completedAt:now-86400)
        let newerClue=Practice(expressionID:nil,time:now-10,mode:"One Thought",stage:0,question:"newer",answer:"A little patience can help.",hint:false,feedback:"feedback",rating:.completed,next:nil,clue:newClue,learningVersion:4,completedAt:now-10)
        try assert(StudioSelector.nextClue([newerClue,olderClue],exposures:[oldClue.key:.init(key:oldClue.key,time:now-86400,count:1)],avoiding:[])?.key==oldClue.key,"到期的旧线索不会被每次新反馈永久插队")
        let empty=DictionaryLookup(definition:nil,related:[],outcome:.noMatch)
        try store.putDictionary("fixture-empty",empty);try store.putDictionary("fixture-failure",.init(definition:nil,related:[],failure:"timeout"))
        try assert((try store.cachedDictionary("fixture-empty")) == nil && (try store.cachedDictionary("fixture-failure"))==nil,"任何空结果和读取失败均不进入持久缓存")
        try dictionaryFlowTests(root:root)
        try dictionaryHelperRecoveryTests(root:root)
        if case .timeout=LocalProcess.run(URL(fileURLWithPath:"/bin/sleep"),arguments:["2"],timeout:0.05){print("PASS 本地辅助进程超时有限退出")}
        else{throw SupportError.message("FAIL: external helper timeout")}
        if case .failed=LocalProcess.run(URL(fileURLWithPath:"/bin/sh"),arguments:["-c","exit 7"],timeout:1){print("PASS 非零退出不当作无匹配")}
        else{throw SupportError.message("FAIL: external helper failure")}
    }

    // Exercise the actual model, persistence and retry entry point using
    // isolated deterministic provider outcomes, not by purging Apple assets.
    @MainActor static func dictionaryFlowTests(root:URL)throws {
        let url=root.appendingPathComponent("dictionary-flow.sqlite")
        let store=try Store(url:url)
        let unavailable=DictionaryLookup(definition:nil,related:[],outcome:.unavailable)
        let miss=DictionaryLookup(definition:nil,related:[],outcome:.noMatch)
        func hit(_ term:String,_ text:String)->DictionaryLookup{
            let sense=DictionaryMeaning(definition:text,qualifiers:[],examples:[],synonymGroups:[],antonyms:[],subordinate:false)
            let content=DictionaryContent(groups:[.init(partOfSpeech:"adjective",senses:[.init(number:1,meanings:[sense])])],sections:[])
            return .init(definition:Definition(term:term,matched:term,body:text,detail:text,source:"Oxford Dictionary of English",match:"exact",content:content),related:[],outcome:.found)
        }
        final class Fixture {
            let lock=NSLock()
            var choices:[String:[DictionaryLookup]]
            var counts:[String:Int]=[:]
            init(_ choices:[String:[DictionaryLookup]]){self.choices=choices}
            func query(_ term:String)->DictionaryLookup{
                lock.lock();defer{lock.unlock()}
                counts[term,default:0]+=1
                guard var remaining=choices[term],let result=remaining.first else{return .init(definition:nil,related:[],outcome:.noMatch)}
                if remaining.count>1{remaining.removeFirst();choices[term]=remaining}
                return result
            }
            func calls(_ term:String)->Int{lock.lock();defer{lock.unlock()};return counts[term,default:0]}
        }
        let fixture=Fixture(["imperative":[unavailable,hit("imperative","essential"),hit("imperative","refreshed")],
                             "offline":[unavailable],
                             "unknownfixture":[miss,hit("unknownfixture","later result")],
                             "abandoned":[unavailable],
                             "replacement":[hit("replacement","new lookup")]])
        // Reproduce the *actual* old v4 negative cache without touching the
        // production database. It must not prevent the first fresh attempt.
        let sql="INSERT INTO dictionary_cache(id,payload) VALUES('v4:imperative','{\"related\":[],\"time\":\(Date().timeIntervalSince1970)}')"
        guard case .data=LocalProcess.run(URL(fileURLWithPath:"/usr/bin/sqlite3"),arguments:[url.path,sql],timeout:2) else{throw SupportError.message("Cannot create legacy cache fixture")}
        try assert(try store.cachedDictionary("imperative")==nil,"旧版一小时空缓存失效，不屏蔽首次查询")
        let m=VocabModel(store:store,assistant:StudioTestAssistant(),dictionaryLookup:fixture.query,dictionaryRetryDelays:[0.12,0.12])
        func wait(_ condition:()->Bool)throws{
            let end=Date().addingTimeInterval(3)
            while !condition(),Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
            guard condition() else{throw SupportError.message("Dictionary flow fixture timed out")}
        }
        func lookup(_ term:String){m.manual(prefill:term);m.submitInput()}
        lookup("imperative")
        let originalID=m.record?.id
        try wait{m.resultBusy && m.quickStatus.contains("资源正在恢复")}
        try assert(m.record?.definition==nil && fixture.calls("imperative")==1,"冷启动资源未就绪显示恢复中，不显示缺词")
        try wait{!m.resultBusy}
        try assert(m.record?.id==originalID && m.record?.definition?.body=="essential" &&
                   (try store.history()).count==1 && fixture.calls("imperative")==2 &&
                   (try store.cachedDictionary("imperative"))?.definition?.body=="essential","同一次查询资源恢复后自动更新原记录并缓存真实结果")
        m.retryDictionary()
        try wait{!m.resultBusy}
        try assert(m.record?.id==originalID && m.record?.definition?.body=="refreshed" &&
                   fixture.calls("imperative")==3 && (try store.history()).count==1,"手动重试绕过正负缓存并更新同一记录")
        lookup("offline")
        try wait{!m.resultBusy}
        try assert(m.record?.definition==nil && m.quickStatus.contains("尚未就绪") &&
                   (try store.cachedDictionary("offline"))==nil && fixture.calls("offline")==3,"持续缺少资源有限重查后明确可重试，不伪装成缺词")
        lookup("unknownfixture")
        try wait{!m.resultBusy}
        try assert(m.quickStatus.contains("未返回完整词条") && (try store.cachedDictionary("unknownfixture"))==nil,"健康无匹配仍不缓存空结果")
        let unknownID=m.record?.id
        m.retryDictionary()
        try wait{!m.resultBusy}
        try assert(m.record?.id==unknownID && m.record?.definition?.body=="later result","健康未命中后可以重新查到，不被旧空结果拦截")
        lookup("abandoned")
        try wait{m.resultBusy && m.quickStatus.contains("资源正在恢复")}
        let oldID=m.record?.id
        lookup("replacement")
        try wait{!m.resultBusy}
        try wait{(try? store.record(oldID ?? ""))?.state.contains("可重试")==true}
        try assert(m.record?.query=="replacement" && m.record?.definition?.body=="new lookup" &&
                   fixture.calls("abandoned")==1,"取消旧恢复不会覆盖新选词，旧历史保留资源状态")
    }

    static func dictionaryAudit(_ terms:[String])->Int32 {
        for term in terms {
            let r=DictionaryEngine.lookup(term)
            let fields=[term,r.status.rawValue,r.definition?.source ?? "",r.definition?.matched ?? "",
                        r.definition?.match ?? "",String(r.related.count)]
            print(fields.joined(separator:"\t"))
        }
        return 0
    }

    @MainActor static func dictionaryHelperRecoveryTests(root:URL)throws {
        let dir=root.appendingPathComponent("dictionary-helper-fixture")
        let resources=dir.appendingPathComponent("Resources"),helpers=dir.appendingPathComponent("Helpers")
        let fm=FileManager.default
        try fm.createDirectory(at:resources,withIntermediateDirectories:true)
        try fm.createDirectory(at:helpers,withIntermediateDirectories:true)
        let original=Paths.resource("oxford_entry"),script=resources.appendingPathComponent("oxford_entry.py")
        try fm.copyItem(at:original,to:script)
        let realHelper=original.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/DictionaryBridge")
        try fm.createSymbolicLink(at:helpers.appendingPathComponent("RealDictionaryBridge"),withDestinationURL:realHelper)
        // Replace only the bridge *inside this temporary fixture*, never
        // Apple resources or the installed app. The Python parser, Swift
        // subprocess transport, model, store and later native query are real.
        let wrapper=helpers.appendingPathComponent("DictionaryBridge")
        let fixtureScript="""
        #!/usr/bin/python3
        import json, os, pathlib, sys
        root = pathlib.Path(__file__).parent.resolve()
        term = sys.argv[1]
        ids = ["com.apple.dictionary.ODE", "com.apple.dictionary.zh_CN-en.OCD", "com.apple.dictionary.OAWT"]
        names = ["Oxford Dictionary of English", "Oxford Chinese Dictionary", "Oxford American Writer’s Thesaurus"]
        def payload(state):
            return [{"identifier":k,"source":n,"state":state,"assetPresent":state=="ready","recordCount":0,"readFailures":0,"plain":"","entries":[]} for k,n in zip(ids,names)]
        if term == "imperative":
            counter = root / "attempts"
            n = int(counter.read_text()) if counter.exists() else 0
            counter.write_text(str(n+1))
            if n < 2:
                print(json.dumps(payload("unavailable"))); sys.exit(0)
        if term in ("fixtureplain","fixturebad","put up with"):
            raw = payload("ready")
            raw[0]["entries"] = [{"head":term,"rawHead":term,"html":"<invalid"}]
            raw[0]["recordCount"] = 1
            if term == "fixtureplain": raw[0]["plain"] = "fixtureplain adjective a genuine same-source fixture description"
            if term == "put up with": raw[0]["plain"] = "put | pʊt | verb move to a place"
            print(json.dumps(raw)); sys.exit(0)
        actual = str(root / "RealDictionaryBridge")
        os.execv(actual,[actual,term])
        """
        try fixtureScript.write(to:wrapper,atomically:true,encoding:.utf8)
        try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let store=try Store(url:dir.appendingPathComponent("data.sqlite"))
        let m=VocabModel(store:store,assistant:StudioTestAssistant(),dictionaryLookup:{DictionaryEngine.lookup($0,script:script)},dictionaryRetryDelays:[0.2,0.2,0.2])
        func wait(_ condition:()->Bool)throws{
            let end=Date().addingTimeInterval(12)
            while !condition(),Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
            guard condition() else{throw SupportError.message("Dictionary helper recovery fixture timed out")}
        }
        m.manual(prefill:"imperative");m.submitInput()
        let id=m.record?.id
        try wait{m.resultBusy && m.quickStatus.contains("资源正在恢复")}
        try assert(m.record?.definition==nil && (try store.cachedDictionary("imperative"))==nil,"真实助手未就绪包经过 Python 和 Swift 后仍为恢复状态")
        try wait{!m.resultBusy}
        let n=try String(contentsOf:helpers.appendingPathComponent("attempts"),encoding:.utf8)
        try assert(n=="3" && m.record?.id==id && m.record?.definition?.complete==true &&
                   m.record?.definition?.source=="Oxford Dictionary of English" && m.record?.definition?.chinese != nil &&
                   m.record?.definition?.supplement != nil && (try store.history()).count==1,
                   "完整链路两次资源未就绪后自动切回真实三本 Oxford，同一查询成功")
        m.manual(prefill:"fixtureplain");m.submitInput()
        try wait{!m.resultBusy}
        try assert(m.record?.definition?.complete==true && m.record?.definition?.source=="Oxford Dictionary of English" &&
                   m.record?.definition?.content?.groups.isEmpty==true && (try store.cachedDictionary("fixtureplain"))==nil,
                   "实际助手解析异常时展示可验证的同源原始文本，不把它缓存成结构化结果")
        m.manual(prefill:"fixturebad");m.submitInput()
        try wait{!m.resultBusy}
        try assert(m.record?.definition==nil && m.quickStatus.contains("暂未能读取") &&
                   (try store.cachedDictionary("fixturebad"))==nil,"解析失败经过全链路仍为可重试，不冒充词典缺词")
        let parent=DictionaryEngine.lookup("put up with",script:script)
        try assert(parent.status == .unreadable && parent.definition==nil,"完整链路拒绝以公开接口返回的母词冒充精确短语")
    }
    @MainActor static func stabilityOnly()->Int32 {
        do {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-stability-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
            try stabilityTests(root:root);print("Stability test OK");return 0
        }catch{fputs("\(error.localizedDescription)\n",stderr);return 1}
    }

    @MainActor static func studioTests(root:URL)throws {
        let store=try Store(url:root.appendingPathComponent("studio.sqlite"))
        let ai=StudioTestAssistant(),model=VocabModel(store:store,assistant:ai)
        model.startPractice()
        try assert(model.practicing && model.pTask?.mode == .thought && !model.pWaiting && ai.prompts.isEmpty && model.expressions.isEmpty,"无收藏也能立刻开始开放表达（不等待 AI）")
        let first=model.pTask?.key;model.stopPractice();model.startPractice()
        try assert(first != model.pTask?.key,"重开练习按已呈现记录轮换题目")
        model.pAnswer="I understand his reasons but I don't agree with what he did."
        model.submitPractice()
        try assert((try store.recentPractices()).first?.answer == model.pAnswer && (try store.recentPractices()).first?.rating == .unassessed,"提交后立即保存原话，无需反馈或自评")
        model.pausePractice()
        try assert(model.pSubmitted && model.practicing && (try store.recentPractices()).count==1,"关闭窗口保留已提交内容并可继续反馈")
        model.requestFeedback()
        ai.respond(#"{"summary":"意思清楚，区分了动机与行为。","improvement":"用更精确的语气表达保留意见。","example":"I understand his motives without condoning his actions.","suggestion":{"expression":"condone","meaning":"宽恕或容许不当行为","example":"I do not condone his actions."},"clue":{"category":"措辞","focus":"区分理解动机与认同行为","evidence":"I understand his reasons"},"targetUse":null}"#)
        try assert(model.pFeedbackDetail?.clue?.focus=="区分理解动机与认同行为" && model.expressions.isEmpty && (try store.recentPractices()).first?.rating == .completed,"反馈形成可验证线索，不自动收藏")
        model.savePracticeSuggestion()
        try assert(model.expressions.count==1 && model.expressions.first?.source=="练习 · AI 建议","本人主动收藏才进入表达库")
        let originalID=(try store.recentPractices()).first!.id
        model.practiceClue()
        try assert(model.pTask?.mode == .rephrase && model.pTask?.retryOf == originalID && model.pPrevious?.answer.contains("understand")==true,"练习线索直接连接下一次改说，并保留原答")
        model.pAnswer="I understand his motives without condoning his actions.";model.submitPractice()
        ai.respond(#"{"summary":"这次更精确。","focusImproved":true,"focusQuote":"without condoning his actions"}"#)
        let attempts=try store.recentPractices()
        try assert(attempts.count==2 && attempts.first?.retryOf==originalID && attempts.first?.focusImproved==true,"再表达另存真实尝试，不覆盖第一次回答")
        model.stopPractice();model.startPractice(mode:.respond)
        model.pAnswer="I think certainty makes it hard to have a conversation.";model.submitPractice()
        try assert(ai.prompts.last?.contains("不批改") == true && model.pFeedbackDetail==nil,"Respond 首轮要求自然回应而不是逐句批改")
        ai.respond("What makes you change your mind, then?")
        try assert(model.pDialogue.count==2 && !model.pSubmitted,"对话伙伴回应后可以继续交流")
        model.pAnswer="A convincing example usually helps me.";model.submitPractice();model.finishConversation()
        ai.respond(#"{"summary":"你回应了对方的问题，整个交流自然。"}"#)
        try assert(model.pSubmitted && model.pFeedbackDetail != nil && (try store.recentPractices()).first?.dialogue?.filter{$0.speaker=="你"}.count==2,"短对话集中回顾，完整保留两轮原答")
        model.stopPractice();model.startPractice(mode:.retell)
        try assert(model.pTask?.material?.isEmpty==false && model.pTask?.mode == .retell,"Retell 有真实可复述材料")
        model.pAnswer="They changed the way they thought about the problem.";model.submitPractice();ai.fail();model.stopPractice()
        try assert((try store.recentPractices()).first?.answer.contains("changed")==true,"AI 反馈失败仍保留实际输出")
        let unassessed=(try store.recentPractices()).first!,countBefore=(try store.recentPractices()).count
        model.resumeRecordFeedback(unassessed);ai.respond(#"{"summary":"保留了主要意思，可以补充具体原因。"}"#)
        try assert((try store.recentPractices()).count==countBefore && (try store.recentPractices()).first?.id==unassessed.id && model.pFeedbackDetail != nil,"历史中补取原答反馈更新同一条记录，不重复计入练习")
        let now=Date().timeIntervalSince1970
        var many=(0..<200).map{i in Expression(original:"item\(i)",target:"item\(i)",kind:.word,intent:"meaning",definition:"meaning",source:"fixture",created:now+Double(i))}
        many[199].target="encumbered"
        let firstTarget=StudioSelector.nextExpression(many,exposures:[:],avoiding:[],step:0,now:now)!
        try assert(firstTarget.id==many[0].id,"两百个新收藏不会始终优先最新表达")
        let exposure=PracticeExposure(key:"target:"+firstTarget.id,time:now,count:1)
        try assert(StudioSelector.nextExpression(many,exposures:[exposure.key:exposure],avoiding:[],step:0,now:now)?.id==many[1].id,"跳过/已呈现跨会话冷却，不需要逐项重跳")
        var due=many[0];due.learning = .learning;due.stage=1;due.due=now-100
        try assert(StudioSelector.nextExpression([due,many[1]],exposures:[:],avoiding:[],step:0,now:now)?.id==due.id && StudioSelector.nextExpression([due,many[1]],exposures:[:],avoiding:[],step:2,now:now)?.id==many[1].id,"到期和新收藏按真实目标呈现次数轮换")
        let e=try store.saveExpression(Expression(original:"encumbered",target:"encumbered",kind:.word,intent:"受负担阻碍",definition:"burdened",source:"fixture"))
        model.startPractice(expression:e);ai.respond(#"{"prompt":"Describe how outdated regulations might hold back a business.","material":null}"#)
        try assert(model.pHint && model.pCurrent?.id==e.id,"表达库单项进入同一工作台，目标可见计为提示")
        model.pAnswer="The business was encumbered by outdated regulations.";model.submitPractice()
        ai.respond(#"{"summary":"使用自然。","targetUse":"used","targetQuote":"encumbered"}"#)
        try assert((try store.practices(e.id)).first?.rating == .assisted,"可见目标使用不能算独立提取")
        let falseFeedback=StudioFeedback.parse(#"{"summary":"不错","targetUse":"used","targetQuote":"encumbered","clue":{"category":"语气","focus":"需要练委婉拒绝","evidence":"fabricated"}}"#,answer:"I found it difficult.",target:e)
        try assert(falseFeedback?.rating(answer:"I found it difficult.",target:e,hinted:false) == .unassessed && falseFeedback?.clue==nil,"模型虚构目标证据或线索无法进入调度")
        let contradictory=StudioFeedback.parse(#"{"summary":"没有使用目标","targetUse":"missed"}"#,answer:"The business was encumbered by rules.",target:e)
        try assert(contradictory?.rating(answer:"The business was encumbered by rules.",target:e,hinted:false) == .unassessed,"AI 对目标使用的矛盾判断不能降级收藏")
        let old=Scheduler.apply(.independent,hinted:false,to:Scheduler.apply(.assisted,hinted:true,to:e,now:now),now:now)
        let alternate=Scheduler.apply(.alternative,hinted:false,to:old,now:now)
        try assert(alternate.stage==old.stage && alternate.successes==old.successes && alternate.learning==old.learning,"自然替代不覆盖已有独立使用证据")
        _ = try store.saveExpression(old)
        let earlier=Practice(expressionID:e.id,time:now-3600,mode:"One Thought",stage:1,question:"Describe a burden",answer:"The company was struggling.",hint:false,feedback:"",rating:.unassessed,next:nil,contextPrepared:true,targetText:e.target,targetIntent:e.intent,targetKind:e.kind)
        try store.putPractice(earlier);model.resumeRecordFeedback(earlier);ai.respond(#"{"summary":"较早的表达没有调用目标。","targetUse":"missed"}"#)
        try assert((try store.allExpressions()).first{$0.id==e.id}?.due==old.due && (try store.allExpressions()).first{$0.id==e.id}?.stage==old.stage,"历史补评仅更新原答，不覆盖更新的收藏调度证据")
        try assert(!StudioPrompts.validTarget(.init(prompt:"Use encumbered here",material:nil),target:"encumbered",mode:.thought),"目标生成题必须隐藏目标词")
        let clue=PracticeClue(category:"语气",focus:"表达异议时保留尊重",evidence:"I don't agree.")
        let fallback=StudioSelector.clueFallback(.init(key:clue.key,mode:.respond,prompt:"Unrelated",clue:clue))
        try assert(fallback.material==clue.evidence && fallback.prompt.contains(clue.focus) && !fallback.contextPrepared,"线索本地回退以实际原话为素材，不能伪装成独立迁移")
        let mixStore=try Store(url:root.appendingPathComponent("mix.sqlite"));_ = try mixStore.saveExpression(e)
        let mixAI=StudioTestAssistant(),mix=VocabModel(store:mixStore,assistant:mixAI)
        for _ in 0..<2 {mix.startPractice();mix.stopPractice()}
        mix.startPractice()
        try assert(mix.pTask?.targetID==nil && (try mixStore.completedTaskCounts()).all==0,"只看题或跳过不会推进真实混合调度")
        mix.pAnswer="I prefer a quieter environment.";mix.submitPractice()
        mixAI.respond(#"{"summary":"观点直接清晰。"}"#)
        mix.stopPractice();mix.startPractice()
        try assert(mix.pTask?.targetID==e.id,"跨会话实际完成一题后混合调度引入收藏")
        mix.stopPractice()
        try assert(StudioSelector.targetEvidence(quote:"He ran out of time.",target:"run out of") &&
                   StudioSelector.targetEvidence(quote:"She took a long hard look at it.",target:"take a look at") &&
                   StudioSelector.targetEvidence(quote:"The plan backfired.",target:"backfire") &&
                   !StudioSelector.targetEvidence(quote:"They ran. Out of time.",target:"run out of") &&
                   !StudioSelector.targetEvidence(quote:"I'm a runner.",target:"run"),"不规则词形和自然插入修饰匹配；拒绝跨句/派生词")
        try assert(LanguageEvidence.containsQuote("I said, “That’s enough.”","That's enough"),"标点和引号差异不丢失真实证据")
        try assert(Scheduler.apply(.missed,hinted:false,to:e,now:now).stage==0 &&
                   Scheduler.apply(.missed,hinted:false,to:old,now:now).successes==old.successes,"未掌握不会误晋级，偶尔失败保留已有独立证据")
        let blank=try mixStore.saveExpression(Expression(original:"He acted on my advice.",target:"act on my advice",kind:.phrase,intent:"",definition:"",source:"fixture"))
        mix.startPractice(expression:blank)
        try assert(mix.pWaiting && mix.pTask?.reference==blank.target && mix.pTask?.material==nil,"无释义的收藏可首次准备重建提示")
        mixAI.respond(#"{"cue":"根据我的建议采取行动。"}"#)
        try assert(mix.pTask?.material=="根据我的建议采取行动。" && mix.pTask?.referenceVisible==false &&
                   (try mixStore.allExpressions()).first{$0.id==blank.id}?.studyMeaning != nil,"中文释义保存在已有表达中，隐藏原文")
        mix.pAnswer="He acted on my advice.";mix.submitPractice()
        mixAI.respond(#"{"summary":"用法自然。","targetUse":"used","targetQuote":"acted on my advice"}"#)
        var ready=try mixStore.allExpressions().first{$0.id==blank.id}!
        try assert(ready.stage==1 && ready.due!>now && mix.practiceRating == .assisted,"首轮有提示的真实输出推进到下次提取")
        mix.stopPractice();ready.due=now-10;_ = try mixStore.saveExpression(ready)
        _ = try mixStore.recordExposure("target:"+blank.id,now:now-86400)
        var other=try mixStore.allExpressions().first{$0.id==e.id}!;other.learning = .paused;_ = try mixStore.saveExpression(other)
        mix.startPractice(review:true)
        try assert(mix.pTask?.targetID==blank.id && !mix.pWaiting && !mix.pHint && mix.pTask?.referenceVisible==false,"到期后自动回到已保存的释义，独立提取不泄露目标")
        mix.pAnswer="He acted on my advice.";mix.submitPractice()
        mixAI.respond(#"{"summary":"准确自然。","targetUse":"used","targetQuote":"acted on my advice"}"#)
        try assert((try mixStore.allExpressions()).first{$0.id==blank.id}?.stage==2 && mix.practiceRating == .independent,"实际独立提取持久化并延长间隔")
        mix.stopPractice()
        let reading=LookupRecord(original:"She acted on my advice because she trusted me.",query:"She acted on my advice because she trusted me.",application:"Books",appID:"fixture",capture:"AX")
        try mixStore.put(reading);mix.refresh()
        try assert(mix.readingCandidates.contains{$0.id==reading.id},"练习首页确实可发现查询中的阅读材料")
        mix.startReadingPractice(reading)
        mixAI.respond(#"{"cue":"因为她信任我，所以她照我的建议做了。"}"#)
        try assert(mix.pTask?.lookupID==reading.id && mix.pTask?.referenceVisible==false,"阅读原文和重建提示保持来源，不要求逐字复述")
        mix.pAnswer="She followed my advice because she trusted me.";mix.submitPractice()
        mixAI.respond(#"{"summary":"自然表达，原意保留。","clue":{"category":"语法","focus":"act on 表示依据行动","evidence":"followed my advice","functional":"preposition","correction":"She acted on my advice.","blank":"on"}}"#)
        let savedClue=mix.pFeedbackDetail!.clue!
        mix.practiceClue()
        try assert(mix.pTask?.method == .cloze && mix.pTask?.functional == .preposition && mix.pTask?.material?.contains("____")==true && mix.pTask?.referenceVisible==false,"反馈线索直接转为同段原文虚词练习")
        mix.pAnswer="on";mix.submitPractice()
        mixAI.respond(#"{"summary":"正确，act on 表示依据……行动。","focusImproved":true,"focusQuote":"on","clue":{"category":"语法","focus":"介词 on 的使用","evidence":"on","functional":"preposition","correction":"She acted on my advice.","blank":"on"}}"#)
        try assert((try mixStore.recentPractices()).first?.method == .cloze && (try mixStore.recentPractices()).first?.focusImproved==true,"虚词输出与反馈沿用同一练习记录和线索")
        try assert((try mixStore.recentPractices()).first?.clue==nil,"正确的单词填空不再制造第二条空泛线索")
        mix.stopPractice()
        let unrelated=PracticeClue(category:"语法",focus:"arrive at 接小地点",evidence:"arrive to",functional:.preposition,correction:"arrive at the station",blank:"at")
        try assert(savedClue.key != unrelated.key,"不同介词规则不共用一个训练线索")
        _ = try mixStore.recordExposure(savedClue.key,now:now-86400)
        mix.startPractice(mode:.thought);mix.pAnswer="Sometimes it helps to wait.";mix.submitPractice()
        mixAI.respond(#"{"summary":"表达清楚。"}"#);mix.stopPractice()
        mix.startPractice()
        try assert(mix.pTask?.clue?.key==savedClue.key && mix.pWaiting,"跨会话的新机会回到具体练习线索")
        mixAI.respond(#"{"prompt":"依据建议采取行动","material":"The team decided to act on the recommendation.","blank":"on"}"#)
        try assert(mix.pTask?.method == .cloze && mix.pTask?.material=="The team decided to act ____ the recommendation." && mix.pTask?.sourceLabel=="AI 生成 · 新语境","虚词迁移使用新的相关情境而不是任意介词")
        try assert(mix.pTask?.clozeWord=="on" && !mix.pHint && mix.pTask?.referenceVisible==false,"新语境空缺具有真实参考答案且未提示")
        mix.pAnswer="on";mix.submitPractice()
        mixAI.respond(#"{"summary":"正确。","focusImproved":true,"focusQuote":"on"}"#)
        try assert(StudioSelector.nextClue(try mixStore.recentPractices(),exposures:[:],avoiding:[])==nil,"无提示的新语境有效证据闭合线索")
        mix.stopPractice()
        let stale=try mixStore.allExpressions().first{$0.id==blank.id}!
        var edited=stale;edited.target="rely on my advice";mix.saveEdited(edited)
        let updated=try mixStore.allExpressions().first{$0.id==blank.id}!
        try assert(updated.stage==0 && updated.studyMeaning==nil && updated.due==nil,"修改学习目标准确重置旧含义和调度，而非继承掌握")
        let invalid=StudioSelector.reading(reference:"act on my advice",source:"fixture",meaning:"仅部分匹配（act）；完整表达需进一步确认。",key:"test")
        let fallbackReading=StudioSelector.safeFallback(invalid)
        try assert(fallbackReading.referenceVisible && fallbackReading.material==fallbackReading.reference,"错误释义不能伪装成无提示重建")
        model.stopPractice()
    }

    // Authored test units isolated from the production catalog and personal DB.
    static func knowledgeFixtures()->[KnowledgeUnit] {
        func unit(_ id:String,_ domain:KnowledgeDomain,_ area:String,_ title:String,_ objective:String,_ explanation:String,
                  _ kind:KnowledgeEvidenceKind,_ forms:[String],_ wordClass:String,_ rule:String,_ negative:[String],
                  _ examples:[String],_ scenarios:[KnowledgeScenario])->KnowledgeUnit {
            .init(id:id,domain:domain,area:area,title:title,objective:objective,explanation:explanation,
                  examples:examples.map{.init(text:$0,meaning:"独立测试样例")},notes:[],intents:[objective],
                  evidence:.init(kind:kind,forms:forms,wordClass:wordClass,rule:rule,criterion:objective,negative:negative),
                  scenarios:scenarios,sources:[.init(title:"自写验收材料",locator:"fixture",url:"",rights:"own")])
        }
        func s(_ id:String,_ context:String,_ mode:String,_ prompt:String,_ material:String="",_ ref:String="")->KnowledgeScenario{
            .init(id:id,context:context,mode:mode,prompt:prompt,material:material,reference:ref)
        }
        return [
            unit("p.act-on-basis",.P,"phrasal","依据建议采取行动","自然使用 act on/upon 表示依据警告、信息或建议行动","不是仅收到建议。",
                 .lexical,["act on","act upon"],"verb","",["The act on Broadway was famous.","I followed the advice."],
                 ["We acted on the warning and left early.","She acted upon his advice."],
                 [s("warning","旅行中根据天气警告提前离开","rebuild","用英语重建这句意思。","我们根据那条警告提前离开。","We acted on the warning and left early."),
                  s("recommendation","项目组按照顾问建议调整方案","thought","A team received a recommendation which changed its plan. Explain what the team did.")]),
            unit("g.past-deduction",.G,"modality","对过去的强推断","用 must have + 过去分词表达过去的推断，不是义务或先决条件","区分推断和要求。",
                 .construction,["must have"],"","past-deduction",["You must have patience.","The applicant must have completed the course."],
                 ["Someone must have moved the chair.","She must have heard us."],
                 [s("window","窗户及湿地板迹象","thought","The window was closed before you left. Now it is open. What is your most likely explanation?"),
                  s("package","包裹踪迹的推断","thought","The parcel was here ten minutes ago. It is gone, and the door is unlocked. What likely happened?")]),
            unit("d.cause-vs-sequence",.D,"relations","先后与因果","根据材料区分先后和未经证实的因果；不凭连接词判断","连续发生不自动意味着因果。",
                 .function,[],"","",["The price change caused the fall in sales."],
                 ["Sales fell afterwards; we do not know why.","The two events happened close together, but the cause is unclear."],
                 [s("sales","价格变化后销量下滑，原因未知","retell","Explain what happened without assuming a cause.","Prices increased on Monday. Sales fell on Tuesday. No investigation of the cause has been made."),
                  s("network","软件升级后服务掉线，原因未查","retell","Explain the known facts and uncertainty.","The software was updated before lunch. The service went down at three. Engineers have not identified the cause.")]),
            unit("i.clarify-deadline",.I,"clarification","有针对性地澄清","询问具体含糊信息，并在伙伴答复后确认真实含义","真正解决歧义，不只请求重复。",
                 .function,[],"","",["Could you repeat that?"],
                 ["Do you mean the deadline or the date we hear back?","Right, so we send it on Friday."],
                 [s("deadline","Friday 指反馈还是提交","respond","We need to have that sorted out by Friday. Does that work for you?"),
                  s("room","next room 指办公室还是会议室","respond","Let's meet in the next room after the call, shall we?")]),
            unit("l.effective-efficient",.L,"choice","有成效与有效率","实际区分效果与资源时间成本","可以有效但不高效。",
                 .lexical,["effective","efficient"],"adjective","contrast",["It was effective."],
                 ["It was effective but not efficient.","The efficient method was not as effective."],
                 [s("project","做法奏效但耗时过长","thought","A method produces the desired result, but requires twice the time of the alternative. Evaluate it precisely."),
                  s("process","节约资源却未达到目标","thought","A fast process uses very little energy but fails to meet the original goal. Evaluate it.")])
        ]
    }
    @MainActor static func knowledgeTests(root:URL)throws {
        let fixtures=knowledgeFixtures()
        let corpus=KnowledgeCatalog(schemaVersion:1,revision:"fixture",units:fixtures)
        try assert(corpus.valid && Set(corpus.units.map(\.domain)).count==5,"知识目录真实五域及独立情境结构")
        let shipped=KnowledgeCatalog.bundled()
        if Bundle.main.url(forResource:"KnowledgeCatalog",withExtension:"json") != nil {
            try assert(shipped.valid && Set(shipped.units.map(\.domain)).count==5,"正式目录完整解码并覆盖五域")
            if shipped.revision == "LanguageMap-v1" {
                let areas=Set(shipped.units.map{$0.domain.rawValue+":"+$0.area})
                try assert((80...120).contains(shipped.units.count) && areas.count==30,"首版覆盖五域、30子域")
            }
            var issues:[String]=[]
            for u in shipped.units {
                let eligible=u.scenarios.filter{$0.method != .cloze && (!u.target.interactive || $0.studioMode == .respond) &&
                    !KnowledgeAssessment.leaks(u.target,visible:$0.prompt+" "+$0.material)}
                if eligible.count<2 {issues.append("\(u.id) unhinted=\(eligible.count)")}
                for s in u.scenarios where s.method == .rebuild && u.evidence.kind != .function {
                    if !KnowledgeAssessment.formCheck(s.reference,u.evidence) {issues.append("\(u.id) reference: \(s.reference)")}
                }
            }
            print("CATALOG AUDIT: \(shipped.units.count) units, issues=\(issues.count)")
            for issue in issues {print("CATALOG REVIEW: "+issue)}
            try assert(issues.isEmpty,"目录各知识点至少具备两种可独立验证的情境且重建参照通过形式检查")
        }
        let p=fixtures[0],g=fixtures[1],d=fixtures[2],i=fixtures[3],l=fixtures[4]
        try assert(KnowledgeAssessment.formCheck("They acted on the advice.",p.evidence) &&
                   !KnowledgeAssessment.formCheck("The act on Broadway was famous.",p.evidence),"词类门拒绝同形名词误报")
        try assert(KnowledgeAssessment.formCheck("It must have been open.",g.evidence) &&
                   !KnowledgeAssessment.formCheck("You must have patience.",g.evidence),"开放构式检查拒绝 must have + 名词")
        try assert(!KnowledgeAssessment.formCheck("It was effective.",l.evidence) &&
                   KnowledgeAssessment.formCheck("It was effective but not efficient.",l.evidence),"真实对比必须出现两项形式")
        if let rise=shipped.unit("l.raise-rise") {
            try assert(KnowledgeAssessment.formCheck("Prices rose and managers raised fees.",rise.evidence) &&
                       !KnowledgeAssessment.formCheck("We raised a rose.",rise.evidence),"不规则动词词形与同形名词分开")
        }
        try assert(!KnowledgeAssessment.leaks(g.target,visible:"The window was open.") &&
                   KnowledgeAssessment.formCheck("They must've already left.",g.evidence),"自然收缩式与无关词不阻断开放构式")
        try assert(!KnowledgePrompts.valid(.init(prompt:p.scenarios[1].prompt,material:nil,context:"不同ID"),task:p.task(p.scenarios[1]),previous:[]) &&
                   !KnowledgePrompts.valid(.init(prompt:"Say how they acted on the advice.",material:nil,context:"新情境"),task:p.task(p.scenarios[1]),previous:[]),"生成任务不接受重复或泄露词形")
        var falseFeedback=StudioFeedback(summary:"错",knowledgeUse:"used",knowledgeQuote:"The applicant must have completed the course.",knowledgeReason:"只是结构命中")
        try assert(KnowledgeAssessment.assess(falseFeedback,task:g.task(g.scenarios[0]),answer:"The applicant must have completed the course.",hinted:false,dialogue:[])==nil,"资格要求中的过去形式不能冒充过去推断")
        falseFeedback.knowledgeQuote="The learner must have forgotten."
        try assert(KnowledgeAssessment.assess(falseFeedback,task:g.task(g.scenarios[0]),answer:"I don't know.",hinted:false,dialogue:[])==nil,"AI 虚构原答不得点亮")
        let store=try Store(url:root.appendingPathComponent("knowledge.sqlite")),ai=StudioTestAssistant()
        let model=VocabModel(store:store,assistant:ai,catalog:.init(schemaVersion:1,units:[p]))
        model.startPractice()
        try assert(model.pTask?.knowledge?.id==p.id && !model.pHint && !model.pWaiting,"无收藏时仍立即得到核心知识任务")
        model.pAnswer="We acted on the warning and left early.";model.submitPractice()
        try assert((try store.knowledgePractices()).first?.answer==model.pAnswer && model.progress(for:p).status == .unobserved,"原答先保存，不凭提交点亮")
        ai.respond(#"{"summary":"自然表达。","knowledgeUse":"used","knowledgeQuote":"We acted on the warning and left early.","knowledgeReason":"用 act on 表明行动依据。"}"#)
        try assert(model.progress(for:p).status == .independent && model.expressions.isEmpty,"无影子收藏的知识证据真实持久化")
        var prior=try store.knowledgePractices().first!
        let original=prior;prior.time-=86400;try store.putPractice(prior)
        _ = try store.recordExposure("knowledge:"+p.id,now:prior.time)
        model.stopPractice();model.startPractice()
        try assert(model.pTask?.knowledgeContext?.id=="recommendation","下次自动进入实质不同的校验情境")
        model.pAnswer="The team acted on the recommendation.";model.submitPractice()
        ai.respond(#"{"summary":"表达正确。","knowledgeUse":"used","knowledgeQuote":"acted on the recommendation","knowledgeReason":"在新项目场景以建议为依据采取行动。"}"#)
        let actual=try store.knowledgePractices()
        try assert(model.progress(for:p).status == .transferred && actual.count==2,"模拟跨日独立新情境形成可追溯的迁移证据")
        var duplicate=actual.first!;duplicate.knowledgeContext=original.knowledgeContext
        try assert(KnowledgeProgress.derive([prior,duplicate])[p.id]?.status == .independent,"不同会话的同一情境绝不假装迁移")
        duplicate.knowledgeContext=actual.first!.knowledgeContext;duplicate.knowledgeSession=prior.knowledgeSession
        try assert(KnowledgeProgress.derive([prior,duplicate])[p.id]?.status == .independent,"同会话换材料不冒充跨会话迁移")
        model.stopPractice();model.startKnowledge(p);model.pAnswer="We acted on the warning and left early.";model.submitPractice()
        ai.respond(#"{"summary":"好。","knowledgeUse":"used","knowledgeQuote":"We acted on the warning and left early.","knowledgeReason":"正确运用搭配。"}"#)
        try assert(model.currentKnowledgeObservation?.independent==false,"主动看知识说明后只能记录辅助证据")
        let other=try Store(url:root.appendingPathComponent("knowledge-function.sqlite")),a2=StudioTestAssistant()
        let discourse=VocabModel(store:other,assistant:a2,catalog:.init(schemaVersion:1,units:[d]))
        discourse.startPractice();discourse.pAnswer="Sales fell after the price change, but we don't know what caused the fall.";discourse.submitPractice()
        a2.respond(#"{"summary":"忠实区分先后与因果。","knowledgeUse":"used","knowledgeQuote":"we don't know what caused the fall","knowledgeReason":"没有把事件时间顺序当因果关系。"}"#)
        try assert(discourse.progress(for:d).status == .independent,"语篇关系不依赖固定词形也可获得真实证据")
        let dialogueStore=try Store(url:root.appendingPathComponent("knowledge-dialogue.sqlite")),a3=StudioTestAssistant()
        let dialogue=VocabModel(store:dialogueStore,assistant:a3,catalog:.init(schemaVersion:1,units:[i]))
        dialogue.startPractice();dialogue.pAnswer="Do you mean we submit it on Friday or hear back on Friday?";dialogue.submitPractice()
        a3.respond("We need to submit it on Friday; we'll hear back next week.")
        dialogue.pAnswer="Right, so we submit it on Friday.";dialogue.submitPractice();dialogue.finishConversation()
        a3.respond(#"{"summary":"有效澄清。","knowledgeUse":"used","knowledgeQuote":"Right, so we submit it on Friday.","knowledgePartnerQuote":"We need to submit it on Friday","knowledgeReason":"具体区分提交和反馈，得到回复后确认。"}"#)
        try assert(dialogue.progress(for:i).status == .independent,"真实多轮互动及对方回合证据闭环")
        let bad=StudioFeedback(summary:"很好",knowledgeUse:"used",knowledgeQuote:"Could you repeat that?",knowledgeReason:"错误推断",knowledgePartnerQuote:"Good")
        try assert(KnowledgeAssessment.assess(bad,task:i.task(i.scenarios[0]),answer:"Could you repeat that?",hinted:false,dialogue:[])==nil,"没有实际伙伴回合不能点亮有效互动")
        let firstOnly=StudioFeedback(summary:"很好",knowledgeUse:"used",knowledgeQuote:"Do you mean we submit it on Friday?",knowledgeReason:"有问题",knowledgePartnerQuote:"We need to submit it on Friday")
        let turns=[StudioDialogueTurn(speaker:"你",text:"Do you mean we submit it on Friday?"),.init(speaker:"伙伴",text:"We need to submit it on Friday."),.init(speaker:"你",text:"It's raining today.")]
        try assert(KnowledgeAssessment.assess(firstOnly,task:i.task(i.scenarios[0]),answer:"Do you mean we submit it on Friday?\nIt's raining today.",hinted:false,dialogue:turns)==nil,"只问未确认、随后无关表达不证明完整澄清")
        let deflected=[turns[0],StudioDialogueTurn(speaker:"伙伴",text:"Sure — which date are you thinking of?"),StudioDialogueTurn(speaker:"你",text:"Right, Friday is the deadline.")]
        let falseClosure=StudioFeedback(summary:"很好",knowledgeUse:"used",knowledgeQuote:"Friday is the deadline",knowledgeReason:"虚假确认",knowledgePartnerQuote:"which date are you thinking of")
        try assert(KnowledgeAssessment.assess(falseClosure,task:i.task(i.scenarios[0]),answer:deflected[0].text+"\n"+deflected[2].text,hinted:false,dialogue:deflected)==nil,"伙伴只反问而未实际解答不形成有效澄清")
        let actualClarification=[turns[0],StudioDialogueTurn(speaker:"伙伴",text:"Friday is the submission deadline. Feedback will come next week. Does that help?"),StudioDialogueTurn(speaker:"你",text:"Right, Friday is the deadline, and feedback comes later.")]
        let multiSentence=StudioFeedback(summary:"完整澄清",knowledgeUse:"used",knowledgeQuote:"Friday is the deadline, and feedback comes later.",knowledgeReason:"实际区别两个日期",knowledgePartnerQuote:"Friday is the submission deadline. Feedback will come next week.")
        try assert(KnowledgeAssessment.assess(multiSentence,task:i.task(i.scenarios[0]),answer:actualClarification[0].text+"\n"+actualClarification[2].text,hinted:false,dialogue:actualClarification)?.independent==true,"真实伙伴跨连续陈述句的完整答复可核验；不要求证据仅一个句子")
        let crossQuestion=[actualClarification[0],StudioDialogueTurn(speaker:"伙伴",text:"Friday is the submission deadline. Does that help? Feedback will come next week."),actualClarification[2]]
        var invalidSpan=multiSentence;invalidSpan.knowledgePartnerQuote=crossQuestion[1].text
        try assert(KnowledgeAssessment.assess(invalidSpan,task:i.task(i.scenarios[0]),answer:crossQuestion[0].text+"\n"+crossQuestion[2].text,hinted:false,dialogue:crossQuestion)==nil,"引文跨过伙伴问句不得冒充连续事实答复")
        model.stopPractice();discourse.stopPractice();dialogue.stopPractice()
    }

    @MainActor static func workspaceTests(root:URL)throws {
        let store=try Store(url:root.appendingPathComponent("workspace.sqlite"))
        let url=root.appendingPathComponent("workspace-state.json")
        var catalog=KnowledgeCatalog.bundled()
        // Explicit three-scene fixture preserves the full navigation test;
        // the real curated group is tested separately.
        if let i=catalog.units.firstIndex(where:{$0.id=="l.take-need"}){catalog.units[i].coreScenarioIDs=nil}
        guard let unit=catalog.unit("l.take-need"),unit.scenarios.count>=3,
              let other=catalog.units.first(where:{$0.domain != unit.domain}) else{throw SupportError.message("知识工作空间测试缺少正式目录")}
        let ai=StudioTestAssistant(),m=VocabModel(store:store,assistant:ai,catalog:catalog,workspaceURL:url)
        m.openKnowledge(unit.id);m.navigation.mapSearch="take"
        m.startKnowledge(unit)
        let original=m.activity!.id,first=m.pTask!.id
        try assert(m.tab == .workbench && m.currentScenes.count==unit.scenarios.count && m.pHint,"定向知识活动有真实有限情境，所有显式目标提示可见")
        m.pAnswer="It took us about"
        m.navigate(.practice);m.openKnowledge(other.id);m.resumeActivity()
        try assert(m.activity?.id==original && m.pTask?.id==first && m.pAnswer=="It took us about","浏览主页和其他知识不改变活动或草稿")
        m.backToActivityOrigin()
        try assert(m.tab == .map && m.navigation.mapSelected==unit.id && m.navigation.mapSearch=="take","返回恢复原知识浏览位置和筛选")
        m.resumeActivity()
        m.pAnswer="It took us three hours to check the figures."
        m.submitPractice()
        let attempt=try store.practices().first!
        try assert(m.pFeedbackWaiting && m.coverage().attempted==1 && m.coverage().covered==0 && m.progress(for:unit).status == .unobserved,"实际提交而非浏览计入覆盖，等待反馈不冒充独立使用")
        m.nextPractice();let second=m.pTask!.id;m.pAnswer="Changing careers requires patience."
        ai.respond(#"{"summary":"原答清楚。","knowledgeUse":"used","knowledgeQuote":"It took us three hours to check the figures.","knowledgeReason":"表达耗费时间。"}"#)
        try assert(m.pTask?.id==second && m.pAnswer=="Changing careers requires patience." && m.pFeedbackDetail==nil && (try store.practice(attempt.id))?.feedback.isEmpty==false,"迟到反馈绑定原答而非当前情境")
        let priorExposure=try store.exposures()["knowledge:"+unit.id]?.count
        m.selectScene(0)
        try assert(m.pTask?.id==first && m.pSubmitted && m.pFeedbackDetail != nil && (try store.practices()).count==1 && (try store.exposures()["knowledge:"+unit.id]?.count)==priorExposure,"回看题面、原答及反馈，不重复登记练习或呈现")
        m.selectScene(1)
        try assert(m.pAnswer=="Changing careers requires patience.","回到下一情境时恢复其草稿")
        m.saveWorkspace()
        let reloadAI=StudioTestAssistant(),r=VocabModel(store:store,assistant:reloadAI,catalog:catalog,workspaceURL:url)
        try assert(r.activity?.id==original && r.pTask?.id==second && r.pAnswer==m.pAnswer && reloadAI.prompts.isEmpty,"重启恢复同一活动、任务、草稿，不重发 AI 或伪造新会话")
        r.startKnowledge(other)
        try assert(r.activityConfirmation != nil && r.activity?.id==original,"更换活动保护未提交草稿")
        r.confirmActivityReplacement(false)
        r.pAnswer="It takes time to learn new skills.";r.submitPractice();reloadAI.fail()
        let older=try store.practices().first!
        r.nextPractice();r.pAnswer="It took a great deal of persistence."
        r.resumeRecordFeedback(older,inPlace:true)
        reloadAI.respond(#"{"summary":"这次表达耗费精力。","knowledgeUse":"used","knowledgeQuote":"It takes time to learn new skills.","knowledgeReason":"符合耗费义。"}"#)
        try assert(r.pAnswer=="It took a great deal of persistence." && (try store.practice(older.id))?.feedback.isEmpty==false,"在历史中补评不抢占当前练习现场")
        r.pAnswer="";r.skipScene()
        try assert(r.activityRecap && r.currentSceneIndex==2 && r.activity?.attemptedCount==2 && r.activity?.skippedCount==1,"三个情境结束后自然回顾，不循环第一题；已答与跳过分开")
        let exposureBeforeExtra=try store.exposures()["knowledge:"+unit.id]?.count
        r.addKnowledgeContext();reloadAI.fail()
        try assert(r.generationUnavailable && (try store.exposures()["knowledge:"+unit.id]?.count)==exposureBeforeExtra,"生成新情境失败不悄悄重复旧题或登记新呈现")
        r.selectScene(0);r.stopPractice()
        try assert(!r.practicing && r.tab == .map && r.navigation.mapSelected==unit.id && r.coverage().attempted==1,"结束回原知识点；本轮完成不提升知识覆盖")
        let keys=Array(catalog.units.prefix(4))
        var progress:[String:KnowledgeProgress]=[:]
        progress[keys[0].id]=KnowledgeProgress(status:.independent,attempts:3,visitedContexts:Set(keys[0].coreScenarios.map(\.id)),completedContexts:Set(keys[0].coreScenarios.map(\.id)))
        progress[keys[1].id]=KnowledgeProgress(status:.transferred,attempts:5,visitedContexts:Set(keys[1].coreScenarios.map(\.id)),completedContexts:Set(keys[1].coreScenarios.map(\.id)))
        progress[keys[2].id]=KnowledgeProgress(status:.assisted,attempts:2,needsPractice:true,visitedContexts:[keys[2].coreScenarios[0].id])
        let coverage=KnowledgeCoverage(keys,progress:progress)
        try assert(coverage.total==4 && coverage.attempted==3 && coverage.covered==2 && coverage.inProgress==1 && coverage.untouched==1,"覆盖按核心情境完成，不以独立证据或题数当掌握率")
        // Separate navigation and lookup identity, even when a practice is active.
        r.startKnowledge(unit);r.pAnswer="Keep my draft";let active=r.activity?.id
        let lookup=LookupRecord(original:"take",query:"take",application:"fixture",appID:"fixture",capture:"manual")
        try store.put(lookup);r.refresh();r.openLookup(lookup.id)
        try assert(r.navigation.selectedHistory==lookup.id && r.activity?.id==active && r.pAnswer=="Keep my draft","查询记录交接与当前活动相互独立")
        r.pAnswer="";r.stopPractice()
        let guardStore=try Store(url:root.appendingPathComponent("workspace-guard.sqlite")),guardAI=StudioTestAssistant()
        let guardModel=VocabModel(store:guardStore,assistant:guardAI,catalog:.init(schemaVersion:1,units:[unit]))
        guardModel.startPractice()
        try assert(!guardModel.pHint,"混合活动开始时没有泄露目标")
        guardModel.openKnowledge(unit.id);guardModel.noteKnowledgeViewed(unit.id);guardModel.resumeActivity()
        try assert(guardModel.pHint && guardModel.coverage().attempted==0,"实际查看同一知识详情将未作答任务标辅助，不增加覆盖")
        guardModel.pAnswer="It took us three hours.";guardModel.submitPractice()
        guardAI.respond(#"{"summary":"自然。","knowledgeUse":"used","knowledgeQuote":"It took us three hours.","knowledgeReason":"表达耗费时间。"}"#)
        let firstAttempt=guardModel.activity!.current!.attempt!.id,oldTask=guardModel.pTask!.id,sceneCount=guardModel.currentScenes.count
        guardModel.retryPractice()
        try assert(guardModel.currentScenes.count==sceneCount+1 && guardModel.currentScenes[0].task.id==oldTask && guardModel.pTask?.retryOf==firstAttempt && guardModel.activity?.attemptedCount==1,"明确重练保留上一原题和原答，新的重练不冒充已提交")
        guardModel.selectScene(0)
        try assert(guardModel.pSubmitted && guardModel.activity?.current?.attempt?.id==firstAttempt && guardModel.pFeedbackDetail != nil,"重练前的原答和反馈仍可直接回看")
        guardModel.stopPractice()
        guardModel.startPractice(mode:.respond,topic:"A conversation about the weekend.")
        guardModel.pAnswer="I plan to visit a friend.";guardModel.submitPractice();guardAI.respond("That's nice. When are you going?")
        guardModel.pAnswer="I'm thinking about"
        guardModel.finishConversation()
        let incomplete=guardModel.activity!.current!.attempt!
        guardModel.resumeRecordFeedback(incomplete,inPlace:true)
        try assert(!guardModel.pSubmitted && guardModel.pAnswer=="I'm thinking about" && !guardModel.waitingForFeedback(incomplete.id),"草稿未提交时结束对话和历史补评均不能吞掉当前回应")
        guardModel.pAnswer="";guardModel.finishConversation();guardAI.respond(#"{"summary":"清楚自然。"}"#);guardModel.stopPractice()
        let e=try guardStore.saveExpression(Expression(original:"encumbered",target:"encumbered",kind:.word,intent:"受阻",definition:"burdened",source:"test"))
        guardModel.refresh();guardModel.startPractice(expression:e)
        guardAI.respond(#"{"prompt":"Describe how outdated rules might hold back a business.","material":null}"#)
        guardModel.pAnswer="The business was encumbered by outdated rules.";guardModel.submitPractice();guardAI.fail()
        let dueBefore=(try guardStore.allExpressions()).first{$0.id==e.id}?.due
        guardModel.requestFeedback();guardAI.respond(#"{"summary":"适当。","targetUse":"used","targetQuote":"encumbered"}"#)
        try assert((try guardStore.allExpressions()).first{$0.id==e.id}?.due != dueBefore && guardModel.currentPracticeRecord?.scheduleReceipt != nil && guardModel.pFeedbackDetail != nil,"首次反馈失败后补评原记录，正确推进一次收藏调度")
        guardModel.stopPractice()
    }

    @MainActor static func snapshot(term:String,page:DictionaryPage,expanded:Bool,path:String,light:Bool)->Int32 {
        do {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-snapshot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:root) }
            _ = NSApplication.shared
            let model=VocabModel(store:try Store(url:root.appendingPathComponent("data.sqlite")))
            guard let definition=DictionaryEngine.local(term) else { throw SupportError.message("未命中测试词条") }
            var record=LookupRecord(original:term,query:term,application:"Books",appID:"fixture",capture:"AX")
            record.definition=definition; record.state="已查到"
            model.record=record;model.expanded=expanded;model.encounterText="曾查 1 次"
            let appearance=NSAppearance(named:light ? .aqua : .darkAqua)
            let width:CGFloat=expanded ? 510 : 442
            let height:CGFloat=expanded ? 580 : QuickPanelLayout.compactHeight(model:model,width:width,availableHeight:700,appearance:appearance)
            let frame=NSRect(x:0,y:0,width:width,height:height)
            let hosted=NSHostingView(rootView:QuickView(model:model,initialPage:page)
                .frame(width:width,height:height).environment(\.colorScheme,light ? .light : .dark))
            let window=NSWindow(contentRect:frame,styleMask:[.borderless],backing:.buffered,defer:false)
            window.appearance=appearance
            window.contentView=hosted; hosted.frame=frame
            hosted.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.15))
            hosted.layoutSubtreeIfNeeded()
            guard let bitmap=hosted.bitmapImageRepForCachingDisplay(in:hosted.bounds)
            else {throw SupportError.message("无法渲染预览")}
            hosted.cacheDisplay(in:hosted.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else {throw SupportError.message("无法输出预览")}
            try png.write(to:URL(fileURLWithPath:path))
            print("Rendered \(term) · \(page.rawValue) · \(expanded ? "expanded" : "compact")")
            return 0
        } catch {fputs("\(error.localizedDescription)\n",stderr);return 1}
    }

    @MainActor static func studioSnapshot(screen requested:String,path:String,light:Bool)->Int32 {
        do {
            let narrow=requested.hasSuffix("-narrow")
            let screen=narrow ? String(requested.dropLast(7)):requested
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-studio-preview-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
            _ = NSApplication.shared
            let store=try Store(url:root.appendingPathComponent("data.sqlite")),ai=StudioTestAssistant()
            let reading=LookupRecord(original:"She acted on my advice because she trusted me.",query:"She acted on my advice because she trusted me.",application:"Books",appID:"fixture",capture:"AX")
            try store.put(reading)
            let expression=try store.saveExpression(Expression(original:"act on my advice",target:"act on my advice",kind:.phrase,intent:"根据建议行动",definition:"",source:"Books",lookupIDs:[reading.id]))
            let loaded=KnowledgeCatalog.bundled()
            let demo=loaded.valid ? loaded : .init(schemaVersion:1,units:knowledgeFixtures())
            if screen=="map-progress" || screen=="map-detail" {
                for (index,unit) in [demo.unit("l.take-need"),demo.unit("p.act-on"),demo.unit("d.cause-vs-sequence")].compactMap({$0}).enumerated(){
                    let group=index==1 ? unit.coreScenarios:Array(unit.coreScenarios.prefix(1))
                    for s in group {
                        let task=unit.task(s),independent=index==1
                        var p=Practice(mode:task.mode.rawValue,stage:0,question:task.prompt,answer:unit.examples[0].text,hint:!independent,feedback:"示例：表达有真实使用机会。",rating:independent ? .independent:.assisted,next:nil,learningVersion:4,knowledge:unit.target,knowledgeContext:task.knowledgeContext,knowledgeSession:"snapshot",interaction:s.contract,completedAt:Date().timeIntervalSince1970)
                        p.knowledgeObservation = .init(use:index==2 ? .needs_work:.used,quote:p.answer,reason:"仅视觉渲染的临时样例",independent:independent,validation:"示例")
                        try store.putPractice(p)
                    }
                }
            }
            let model=VocabModel(store:store,assistant:ai,catalog:demo);model.refresh();model.tab = .practice
            if screen=="map" || screen=="map-progress"{model.navigate(.map)}
            else if screen=="map-detail",let unit=demo.unit("l.take-need"){model.openKnowledge(unit.id)}
            else if screen=="focused" || screen=="recap",let unit=demo.unit("l.take-need"){
                model.openKnowledge(unit.id);model.startKnowledge(unit)
                if screen=="recap"{
                    model.pAnswer="It took us three hours.";model.submitPractice()
                    ai.respond(#"{"summary":"表达了耗时。","knowledgeUse":"used","knowledgeQuote":"It took us three hours.","knowledgeReason":"表示花费时间。"}"#)
                    model.nextPractice()
                    while !model.activityRecap{model.skipScene()}
                }
            }else if screen=="history"{model.openLookup(reading.id)}
            else if screen=="expressions"{model.openExpression(expression.id)}
            else if screen=="discussion"{
                model.startDiscussion(topic:"When is changing your mind a sign of strength?")
                model.pAnswer="It takes confidence to admit you were wrong.";model.submitPractice();ai.respond("I agree that admitting a mistake can show confidence. But sometimes people change their position for convenience rather than evidence. How would you tell the difference?")
            }
            else if screen=="feedback" || screen=="records" {
                model.startPractice(mode:.thought,topic:"Can you understand someone's choices without approving of them?")
                model.pAnswer="I understand his reasons but I don't agree with what he did.";model.submitPractice()
                ai.respond(#"{"summary":"意思清楚，能区分动机与行为。","improvement":"用 condone 精确表达对行为本身的态度。","example":"I sympathise with his motives without condoning his actions.","suggestion":{"expression":"condone","meaning":"容许或认同不当行为"},"clue":{"category":"措辞","focus":"区分理解动机与认同行为","evidence":"I understand his reasons"}}"#)
                if screen=="feedback",let p=model.currentPracticeRecord{model.discussFeedback(p,question:"Is condone too formal for a casual conversation?");ai.respond("It is natural in discussion but somewhat formal. In casual conversation, ‘I understand him, but I don't think what he did was okay’ is perfectly idiomatic.")}
                if screen=="records",let p=model.practiceHistory.first{model.openPracticeRecord(p.id)}
            } else if screen=="respond" {
                model.startPractice(mode:.respond);model.pAnswer="I agree to some extent, but it depends on the situation.";model.submitPractice();ai.respond("What kind of situation would change your view?")
            } else if screen=="retell" {model.startPractice(mode:.retell)}
            else if screen=="thought" {model.startPractice()}
            else if screen=="knowledge" {model.startPractice()}
            else if screen=="rebuild" || screen=="cloze" {
                model.startReadingPractice(reading,functional:.preposition,useCloze:screen=="cloze")
                if screen=="rebuild"{ai.respond(#"{"cue":"因为她信任我，所以她照我的建议做了。"}"#)}
            }
            else if screen=="target" {
                let e=try store.saveExpression(Expression(original:"encumbered",target:"encumbered",kind:.word,intent:"负担所阻碍",definition:"burdened",source:"Books"));model.startPractice(expression:e)
                ai.respond(#"{"prompt":"Describe how outdated regulations might hold back a business.","material":null}"#)
            }
            let width:CGFloat=narrow ? 780:900,height:CGFloat=narrow ? 560:720,frame=NSRect(x:0,y:0,width:width,height:height)
            let appearance=NSAppearance(named:light ? .aqua : .darkAqua)
            let content=AnyView(LibraryView(model:model))
            let hosted=NSHostingView(rootView:content.frame(width:width,height:height).environment(\.colorScheme,light ? .light : .dark).background(Color(nsColor:light ? .white : NSColor(calibratedWhite:0.115,alpha:1))))
            let window=NSWindow(contentRect:frame,styleMask:[.borderless],backing:.buffered,defer:false);window.appearance=appearance;window.contentView=hosted;hosted.frame=frame
            hosted.layoutSubtreeIfNeeded();window.displayIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.2));hosted.layoutSubtreeIfNeeded()
            guard let bitmap=hosted.bitmapImageRepForCachingDisplay(in:hosted.bounds) else{throw SupportError.message("无法渲染练习预览")}
            hosted.cacheDisplay(in:hosted.bounds,to:bitmap);guard let png=bitmap.representation(using:.png,properties:[:]) else{throw SupportError.message("无法输出练习预览")}
            try png.write(to:URL(fileURLWithPath:path));print("Rendered practice \(screen)");return 0
        }catch{fputs("\(error.localizedDescription)\n",stderr);return 1}
    }

    @MainActor static func liveKnowledge()->Int32 {
        do {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-knowledge-live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
            let production=KnowledgeCatalog.bundled()
            let p=production.unit("p.act-on") ?? knowledgeFixtures()[0],d=production.unit("d.cause-vs-sequence") ?? knowledgeFixtures()[2],i=production.unit("i.clarify-specific") ?? knowledgeFixtures()[3]
            func wait(_ model:VocabModel,_ condition:()->Bool)throws {
                let deadline=Date().addingTimeInterval(130)
                while !condition(),Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
                if !condition(){throw SupportError.message("Live knowledge timeout: "+model.pStatus)}
            }
            if !CommandLine.arguments.contains("--interaction-only") {
            let m=VocabModel(store:try Store(url:root.appendingPathComponent("lexical.sqlite")),catalog:.init(schemaVersion:1,units:[p]))
            m.startPractice();try assert(m.pTask?.knowledge?.id==p.id && !m.pHint,"真实入口无收藏即有知识目标")
            m.pAnswer=production.valid ? "The company acted on the inspection findings and closed the store." : "We acted on the warning and left early.";m.submitPractice();try wait(m){!m.pFeedbackWaiting}
            try assert(m.progress(for:p).status == .independent,"真实 Pi 核验固定表达的意义及形式，不需收藏")
            var prior=try m.store.knowledgePractices().first!;prior.time-=86400;try m.store.putPractice(prior)
            _ = try m.store.recordExposure("knowledge:"+p.id,now:prior.time)
            m.stopPractice();m.startPractice()
            try assert(m.pTask?.knowledgeContext?.id != prior.knowledgeContext?.id && !m.pHint,"模拟跨日再次进入不同真实情境")
            if m.pTask?.mode == .respond {
                m.pAnswer="Yes, we acted on the safety report and arranged the repairs yesterday.";m.submitPractice();try wait(m){!m.pFeedbackWaiting};m.finishConversation();try wait(m){!m.pFeedbackWaiting}
            } else {m.pAnswer="The team acted on the recommendation and changed its plan.";m.submitPractice();try wait(m){!m.pFeedbackWaiting}}
            try assert(m.progress(for:p).status == .transferred,"真实 Pi 跨会话新情境证据闭环")
            let md=VocabModel(store:try Store(url:root.appendingPathComponent("discourse.sqlite")),catalog:.init(schemaVersion:1,units:[d]))
            md.startPractice();md.pAnswer=production.valid ? "Prices rose in March, and sales fell in April. Opening hours also changed that month, so we don't know whether the price rise caused the drop." : "Sales fell after the price change, but no one has established the cause.";md.submitPractice();try wait(md){!md.pFeedbackWaiting}
            try assert(md.progress(for:d).status == .independent,"真实 Pi 语篇逻辑证据，不靠关键词")
            var dp=try md.store.knowledgePractices().first!;dp.time-=86400;try md.store.putPractice(dp)
            _ = try md.store.recordExposure("knowledge:"+d.id,now:dp.time);md.stopPractice();md.startPractice()
            try assert(md.pTask?.knowledgeContext?.id != dp.knowledgeContext?.id,"语篇第二独立情境")
            if md.pTask?.mode == .respond {
                md.pAnswer="Not necessarily. Sales dropped after our price change, but we haven't established the cause. Something else could explain it.";md.submitPractice();try wait(md){!md.pFeedbackWaiting};md.finishConversation();try wait(md){!md.pFeedbackWaiting}
            } else {md.pAnswer="The service went down after the software update, but engineers haven't identified what caused the outage.";md.submitPractice();try wait(md){!md.pFeedbackWaiting}}
            try assert(md.progress(for:d).status == .transferred,"真实 Pi 语篇跨会话不同情境闭环")
            m.stopPractice();md.stopPractice()
            }
            let mi=VocabModel(store:try Store(url:root.appendingPathComponent("interaction.sqlite")),catalog:.init(schemaVersion:1,units:[i]))
            mi.startPractice();mi.pAnswer="When you say Friday, do you mean we have to submit it by then, or that's when we'll hear back?";mi.submitPractice();try wait(mi){!mi.pFeedbackWaiting}
            let partner=mi.pDialogue.last?.text ?? ""
            print("Live interaction partner fixture:",partner)
            mi.pAnswer="Understood. We need to have it sorted by Friday, and their feedback comes later. I'll aim for noon."
            mi.submitPractice();mi.finishConversation();try wait(mi){!mi.pFeedbackWaiting}
            print("Live interaction feedback:",mi.pFeedbackDetail?.summary ?? "none",mi.currentKnowledgeObservation?.reason ?? "no evidence")
            if let f=mi.pFeedbackDetail{print("Live interaction evidence:",f.knowledgeUse ?? "nil",f.knowledgeQuote ?? "nil",f.knowledgePartnerQuote ?? "nil",f.knowledgeReason ?? "nil")}
            try assert(mi.progress(for:i).status == .independent && mi.pDialogue.count>=3,"真实 Pi 对实际互动回合提供可核验独立使用证据")
            mi.stopPractice()
            print("Live Knowledge OK");return 0
        } catch {fputs("\(error.localizedDescription)\n",stderr);return 1}
    }

    @MainActor static func liveStableFlow()->Int32 {
        do {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-live-stable-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
            let store=try Store(url:root.appendingPathComponent("data.sqlite")),m=VocabModel(store:store,catalog:KnowledgeCatalog.bundled())
            func wait(_ condition:()->Bool)throws{
                let deadline=Date().addingTimeInterval(130)
                while !condition(),Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
                if !condition(){throw SupportError.message("Live stable flow timeout: "+m.pStatus)}
            }
            m.startDiscussion(topic:"Is changing your mind a sign of strength or weakness?")
            m.pAnswer="I think it takes confidence to admit that the evidence has changed your view.";m.submitPractice();try wait{!m.pFeedbackWaiting}
            try assert(m.pDialogue.count==2 && !m.pSubmitted,"真实 High 主题交流有伙伴实际回应")
            print("Live topic partner:",m.pDialogue.last?.text ?? "none")
            m.pAnswer="For me the important distinction is whether the new position is supported by better evidence, or merely convenient.";m.submitPractice();try wait{!m.pFeedbackWaiting}
            try assert(m.pDialogue.count==4,"真实 High 根据上一个观点延续交流")
            print("Live topic continuation:",m.pDialogue.last?.text ?? "none")
            m.finishConversation();try wait{!m.pFeedbackWaiting}
            guard let p=m.currentPracticeRecord,!p.feedback.isEmpty else{throw SupportError.message("Missing live feedback")}
            try assert(p.completed && p.feedbackSource?.contains("HIGH")==true && m.coverage().attempted==0,"主题交流完成、真实 High 反馈且不计地图覆盖")
            m.discussFeedback(p,question:"Would 'merely convenient' sound too judgmental in casual conversation?");try wait{!m.discussingFeedback(p.id)}
            guard let discussed=try store.practice(p.id),let turn=discussed.feedbackDiscussion?.last else{throw SupportError.message("Missing live follow-up")}
            print("Live feedback discussion:",turn.answer)
            try assert(discussed.rating==p.rating && (try store.practices()).count==1 && turn.source?.contains("HIGH")==true,"真实反馈讨论不改变原答或评级")
            guard let userTurn=p.dialogue?.first(where:{$0.speaker=="你"}) else{throw SupportError.message("No original turn")}
            try assert(m.correctPractice(discussed,text:"I think it takes confidence to admit that new evidence has changed your view.",turnID:userTurn.id),"真实多轮答案可修正同一回合")
            try assert((try store.practice(p.id))?.feedback.isEmpty==true && (try store.practice(p.id))?.revision==1,"修正清空旧评价但保留原始回合")
            m.requestFeedback();try wait{!m.pFeedbackWaiting}
            try assert((try store.practice(p.id))?.feedback.isEmpty==false && (try store.practices()).count==1,"真实 High 对同一修订答案重新评价，不新增尝试")
            print("Live Stable Flow OK");return 0
        }catch{fputs("\(error.localizedDescription)\n",stderr);return 1}
    }

    @MainActor static func liveStudio()->Int32 {
        do {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-studio-live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
            let model=VocabModel(store:try Store(url:root.appendingPathComponent("data.sqlite")))
            func wait(_ condition:()->Bool)throws {
                let end=Date().addingTimeInterval(130)
                while !condition(),Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.10))}
                if !condition() {throw SupportError.message("Live practice timed out: \(model.pStatus)")}
            }
            if !CommandLine.arguments.contains("--transfer-only") {
            for (mode,topic,answer) in [(StudioMode.thought,"Can you understand a character without approving of their actions?","I understand his reasons but I don't agree with what he did."),(.rephrase,"I don't really like the idea, but I get why you proposed it.","I see your reasoning, but I have reservations about the idea."),(.retell,"Maya changed her mind after reading a colleague's message again. She realised it concerned a deadline, not her abilities. She asked about the delay and they worked together.","Maya realised that her colleague was commenting on a deadline rather than criticising her personally, so she asked about the delay and they found a solution.")] {
                model.startPractice(mode:mode,topic:topic);model.pAnswer=answer;model.submitPractice();try wait{!model.pFeedbackWaiting}
                try assert(model.pFeedbackDetail != nil,"真实 Pi 反馈 · \(mode.rawValue) · \(model.pStatus)")
                model.stopPractice()
            }
            model.startPractice(mode:.respond,topic:"Is changing your mind a sign of strength?");model.pAnswer="I think it takes confidence to admit you were wrong.";model.submitPractice();try wait{!model.pFeedbackWaiting}
            try assert(model.pDialogue.count==2 && !model.pSubmitted,"真实 Pi 对话先回应而非批改")
            model.finishConversation();try wait{!model.pFeedbackWaiting};try assert(model.pFeedbackDetail != nil,"真实 Pi 对话结束后集中反馈");model.stopPractice()
            let e=try model.store.saveExpression(Expression(original:"encumbered",target:"encumbered",kind:.word,intent:"受到不必要负担阻碍",definition:"burdened or impeded",source:"fixture"));model.startPractice(expression:e)
            try wait{!model.pWaiting};try assert(model.pHint && model.pCurrent?.id==e.id && !StudioSelector.targetEvidence(quote:model.pTask?.prompt ?? "",target:e.target),"真实 Pi 收藏目标任务，题面不泄露")
            model.pAnswer="The business was encumbered by unnecessary regulations.";model.submitPractice();try wait{!model.pFeedbackWaiting}
            try assert(model.pFeedbackDetail != nil && model.practiceRating != .independent,"真实 Pi 目标反馈不冒充独立提取")
            model.stopPractice()
            let phrase=try model.store.saveExpression(Expression(original:"act on my advice",target:"act on my advice",kind:.phrase,intent:"",definition:"",source:"fixture"))
            model.startPractice(expression:phrase);try wait{!model.pWaiting}
            try assert(model.pTask?.contextPrepared==true && model.pTask?.referenceVisible==false && model.pTask?.material?.range(of:"\\p{Han}",options:.regularExpression) != nil,"真实 Pi 为无释义收藏准备中文重建提示")
            model.pAnswer="He acted on my advice.";model.submitPractice();try wait{!model.pFeedbackWaiting}
            var saved=try model.store.allExpressions().first{$0.id==phrase.id}!
            try assert(saved.stage==1 && model.practiceRating == .assisted,"真实 Pi 初次辅助使用进入调度")
            model.stopPractice();saved.due=Date().timeIntervalSince1970-10;_ = try model.store.saveExpression(saved)
            _ = try model.store.recordExposure("target:"+phrase.id,now:Date().timeIntervalSince1970-86400)
            model.startPractice(review:true)
            try assert(model.pTask?.targetID==phrase.id && !model.pWaiting && !model.pHint,"模拟到期后复用释义、目标隐藏")
            model.pAnswer="He acted on my advice.";model.submitPractice();try wait{!model.pFeedbackWaiting}
            try assert(model.practiceRating == .independent && (try model.store.allExpressions()).first{$0.id==phrase.id}?.stage==2,"真实 Pi 独立提取推进收藏状态")
            model.stopPractice()
            let reading=LookupRecord(original:"She acted on my advice because she trusted me.",query:"She acted on my advice because she trusted me.",application:"Books",appID:"fixture",capture:"AX")
            try model.store.put(reading);model.startReadingPractice(reading);try wait{!model.pWaiting}
            try assert(model.pTask?.referenceVisible==false && model.pTask?.contextPrepared==true,"真实阅读重建获得提示并隐藏原文")
            model.pAnswer="She followed my advice because she trusted me.";model.submitPractice();try wait{!model.pFeedbackWaiting}
            try assert(model.pFeedbackDetail != nil,"真实 Pi 对自然替代重建提供反馈")
            model.practiceFunctional(.preposition)
            try assert(model.pTask?.method == .cloze && model.pTask?.material?.contains("____")==true,"同段材料继续虚词训练")
            model.pAnswer="on";model.submitPractice();try wait{!model.pFeedbackWaiting}
            try assert(model.pFeedbackDetail != nil && (try model.store.recentPractices()).first?.reference==reading.query,"真实 Pi 虚词反馈与原文记录完成")
            model.stopPractice()
            }
            let transfer=VocabModel(store:try Store(url:root.appendingPathComponent("transfer.sqlite")))
            transfer.startPractice(mode:.thought,topic:"Tell me what you think about the proposal.")
            transfer.pAnswer="I am interested on the proposal.";transfer.submitPractice();try wait{!transfer.pFeedbackWaiting}
            guard let clue=transfer.pFeedbackDetail?.clue,clue.functional == .preposition else {throw SupportError.message("真实 Pi 未给出介词线索")}
            try assert(clue.valid(in:"I am interested on the proposal.") && clue.correction?.contains("interested in")==true,"真实 Pi 从真实错误提取具体规则及纠正示例")
            transfer.practiceClue()
            try assert(transfer.pTask?.method == .cloze && transfer.pTask?.clozeWord=="in","实际反馈直接转入纠正练习")
            transfer.pAnswer="in";transfer.submitPractice();try wait{!transfer.pFeedbackWaiting};transfer.stopPractice()
            _ = try transfer.store.recordExposure(clue.key,now:Date().timeIntervalSince1970-86400)
            transfer.startPractice(mode:.thought);transfer.pAnswer="A little patience can help.";transfer.submitPractice();try wait{!transfer.pFeedbackWaiting};transfer.stopPractice()
            transfer.startPractice();try wait{!transfer.pWaiting}
            print("Live transfer selection:",transfer.pTask?.key ?? "none",transfer.pTask?.clue?.key ?? "none",transfer.pStatus,"counts",try transfer.store.completedTaskCounts().all,"eligible",StudioSelector.nextClue(try transfer.store.recentPractices(),exposures:try transfer.store.exposures(),avoiding:[])?.key ?? "none")
            print("Live transfer fixture:",clue.focus,"expected",clue.blank ?? "(none)","generated",transfer.pTask?.material ?? "(none)","blank",transfer.pTask?.clozeWord ?? "(none)")
            try assert(transfer.pTask?.clue?.key==clue.key && transfer.pTask?.method == .cloze && transfer.pTask?.clozeWord=="in" &&
                       transfer.pTask?.sourceLabel=="AI 生成 · 新语境" && !transfer.pHint,"真实 Pi 使用新语境复练同一介词规则")
            transfer.pAnswer="in";transfer.submitPractice();try wait{!transfer.pFeedbackWaiting}
            try assert((try transfer.store.recentPractices()).first?.focusImproved==true && StudioSelector.nextClue(try transfer.store.recentPractices(),exposures:[:],avoiding:[])?.key != clue.key,"真实 Pi 无提示迁移证据闭合该规则")
            transfer.stopPractice();print("Live Studio OK");return 0
        }catch{fputs("\(error.localizedDescription)\n",stderr);return 1}
    }
}
