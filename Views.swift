import Cocoa
import SwiftUI
import ApplicationServices
import CoreGraphics

let accent = Color(nsColor:NSColor(name:nil) { appearance in
    appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
        ? NSColor.systemTeal : NSColor(srgbRed:0.04,green:0.37,blue:0.40,alpha:1)
})

// One sizing implementation for the real panel and its offscreen regression
// snapshots. Measure a non-scrolling copy of the actual compact view at the
// panel's available width, including title, IPA, tabs, source, actions and toast.
@MainActor enum QuickPanelLayout {
    static let compactLimit:CGFloat=440

    static func naturalHeight(model:VocabModel,width:CGFloat,page:DictionaryPage,appearance:NSAppearance? = nil)->CGFloat {
        let content=QuickView(model:model,initialPage:page,measuring:true).frame(width:width)
        let hosted=NSHostingView(rootView:content)
        if let appearance { hosted.appearance=appearance }
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize.height
    }

    static func compactHeight(model:VocabModel,width:CGFloat,availableHeight:CGFloat,appearance:NSAppearance? = nil)->CGFloat {
        let pages:[DictionaryPage] = DictionaryPage.preferred(model.record?.definition?.source) == .writer
            ? [.english,.chinese,.writer] : (model.record?.definition == nil ? [.english] : [.english,.chinese])
        let measured=pages.map {naturalHeight(model:model,width:width,page:$0,appearance:appearance)}
            .filter{$0.isFinite && $0>0}.max() ?? 320
        // A small reserve covers native scrolling indicators / pixel rounding.
        // On unusually long entries the same body becomes scrollable, but the
        // header, first meaning and actions keep useful room.
        let desired=max(250,ceil(measured+12))
        return min(desired,min(compactLimit,availableHeight))
    }
}

struct TagLabel: View {
    let text:String
    var color:Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal,7).padding(.vertical,4)
            .foregroundStyle(color).background(color.opacity(0.12),in:Capsule())
    }
}

struct VoiceButton: View {
    @ObservedObject var voice:VoiceInput
    var english:Bool
    var owner:String="lookup"
    let insert:(String)->Void
    var body: some View {
        Button {
            voice.toggle(english:english,owner:owner,onText:insert)
        } label: {
            Label(voice.owner==owner && voice.recording ? "停止录音" : (voice.owner==owner && voice.busy ? "识别中…" : "说话"),
                  systemImage:voice.owner==owner && voice.recording ? "stop.circle.fill" : "mic")
        }
        .disabled(voice.busy || (voice.owner != nil && voice.owner != owner))
        .help(voice.message.isEmpty ? "本机语音转文字" : voice.message)
    }
}

struct QuickView: View {
    @ObservedObject var model:VocabModel
    @ObservedObject private var voice:VoiceInput
    @FocusState private var editingFocus:Bool
    @FocusState private var questionFocus:Bool
    @State private var page:DictionaryPage
    private let measuring:Bool
    init(model:VocabModel,initialPage:DictionaryPage = .english,measuring:Bool = false) {
        self.model=model;self.voice=model.voice
        _page=State(initialValue:initialPage)
        self.measuring=measuring
    }

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Image(systemName:"text.book.closed").foregroundStyle(accent)
                Text("Vocab").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.resultBusy || model.bookBusy { ProgressView().controlSize(.small).scaleEffect(0.68) }
                Button { model.dismissQuick() } label: { Image(systemName:"xmark").font(.caption.weight(.semibold)).padding(4) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭")
            }
            if model.editing {
                VStack(alignment:.leading,spacing:8) {
                    Text(model.quickStatus).font(.caption).foregroundStyle(.secondary)
                    TextField("输入单词、搭配或句子",text:$model.input)
                        .textFieldStyle(.roundedBorder).font(.system(size:15)).focused($editingFocus)
                        .onSubmit { model.submitInput() }
                    HStack {
                        VoiceButton(voice:model.voice,english:false) { model.input = $0 }
                        Spacer()
                        Button("查询") {model.submitInput()}.keyboardShortcut(.defaultAction)
                            .disabled(cleanText(model.input).isEmpty || model.voice.recording || model.voice.busy)
                    }
                    if !model.voice.message.isEmpty { Text(model.voice.message).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength:0)
            } else if let record=model.record {
                // The query and controls should never disappear when reading a
                // long entry or scrolling a conversation.
                HStack(alignment:.top,spacing:8) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(record.query).font(.system(size:24,weight:.semibold))
                            .textSelection(.enabled).lineLimit(2)
                        if let d=record.definition {
                            PronunciationLine(definition:d)
                            if !d.complete { TagLabel(text:"部分匹配：\(d.matched)",color:.orange) }
                            else if d.match == "inflected" { Text("原形 · "+d.matched).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Spacer(minLength:4)
                    Button { model.speak(record.query) } label: { Image(systemName:"speaker.wave.2") }
                        .buttonStyle(.borderless).help("本机英式发音").accessibilityLabel("发音")
                    Button { model.editQuery() } label: { Image(systemName:"pencil") }
                        .buttonStyle(.borderless).disabled(model.voice.recording || model.voice.busy).help("编辑查询").accessibilityLabel("编辑查询")
                }
                if model.asking {
                    assistantPane(record)
                } else {
                    if record.definition != nil {
                        DictionaryPages(page:$page,expanded:model.expanded,
                                        includeWriter:DictionaryPage.preferred(record.definition?.source) == .writer)
                    }
                    if measuring {
                        // Measure exactly the same content without a flexible
                        // ScrollView swallowing its intrinsic height.
                        dictionaryPane(record).fixedSize(horizontal:false,vertical:true)
                    } else {
                        ScrollView {
                            dictionaryPane(record)
                        }.scrollIndicators(.automatic).id(page)
                    }
                    HStack(alignment:.firstTextBaseline,spacing:7) {
                        if !model.encounterText.isEmpty { Text(model.encounterText).font(.caption2).foregroundStyle(accent).lineLimit(1) }
                        else { Text(record.book?.label ?? record.application).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength:0)
                        if let d=record.definition {
                            let source=page == .chinese ? d.chinese?.source : page == .writer ? d.supplement?.source : d.source
                            if let source { Text(source).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(source) }
                        }
                    }
                }
                Divider()
                HStack(spacing:8) {
                    Button(model.asking ? "返回词典" : model.expanded ? "收起" : "展开") {
                        if model.asking { model.closeAsk() }
                        else { model.toggleExpanded() }
                    }
                    if model.savedID == nil || model.undoableID != nil {
                        Button {model.toggleSave()} label:{Label(model.savedID==nil ? "收藏表达":"撤销收藏",systemImage:model.savedID==nil ? "star":"star.fill")}
                            .foregroundStyle(model.savedID==nil ? .primary:accent)
                    } else {TagLabel(text:"已收藏",color:accent)}
                    if !model.asking { Button {
                        model.openAsk()
                        if record.definition == nil {model.beginAsk("解释完整表达在这里的意思和自然用法。")}
                    } label: { Label(record.definition == nil ? "理解表达" : "问 AI",systemImage:"sparkles") } }
                    Spacer(minLength:0)
                    Button {model.justShowLookup()} label:{Image(systemName:"arrow.up.right.square")}.buttonStyle(.borderless).help("查看本次记录").accessibilityLabel("查看本次记录")
                }.controlSize(.small)
                if !model.toast.isEmpty { Text(model.toast).font(.caption2).foregroundStyle(accent) }
            } else {
                Text(model.quickStatus.isEmpty ? "正在读取…" : model.quickStatus).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(15)
        .frame(maxWidth:.infinity,maxHeight:measuring ? nil : .infinity,alignment:.topLeading)
        .fixedSize(horizontal:false,vertical:measuring)
        .background(Color(nsColor:.windowBackgroundColor),in:RoundedRectangle(cornerRadius:14))
        .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(Color.primary.opacity(0.12),lineWidth:0.8))
        .onHover { if !measuring {model.hover=$0} }
        .onAppear {if !measuring {if model.editing{editingFocus=true};if let r=model.record{model.noteLookupViewed(r)}}}
        .onChange(of:model.editing) { _,value in if !measuring && value { editingFocus=true } }
        .onChange(of:model.asking) { _,value in if !measuring && value { questionFocus=true } }
        .onChange(of:model.record?.id) { _,_ in if !measuring {page = .english;if let r=model.record{model.noteLookupViewed(r)}} }
        .onChange(of:model.replies.last?.answer){_,answer in if !measuring,let answer,model.asking{model.noteLanguageTextViewed(answer)}}
        .onChange(of:model.expanded) { _,value in if !measuring && !value && page == .writer && DictionaryPage.preferred(model.record?.definition?.source) != .writer { page = .english } }
        .onChange(of:model.record?.definition?.source) { _,value in
            if !measuring && value != nil { page=DictionaryPage.preferred(value) }
        }
        .onChange(of:model.toast) { _,_ in
            if !measuring && !model.expanded && !model.editing && !model.asking {
                DispatchQueue.main.async { model.onResizeQuick?() }
            }
        }
    }

    @ViewBuilder private func dictionaryPane(_ record:LookupRecord)->some View {
        VStack(alignment:.leading,spacing:12) {
            if let d=record.definition {
                DictionaryReading(definition:d,page:page,compact:!model.expanded,
                                  selectSense:{ pos,sense in model.preciseSave(partOfSpeech:pos,meaning:sense) },
                                  savedIntents:Set(model.expressions.filter{keyFor($0.target)==keyFor(record.query)}.map(\.intent)))
                    .id(page)
                if !d.complete || model.resultBusy || record.state.contains("可重试") {
                    Text(model.quickStatus).font(.caption).foregroundStyle(.secondary)
                    if !model.resultBusy,record.state.contains("可重试"){Button("重试本地词典"){model.retryDictionary()}.buttonStyle(.borderless).foregroundStyle(accent)}
                }
            } else {
                Text(model.quickStatus).font(.system(size:14)).foregroundStyle(.secondary)
                if !model.resultBusy,(record.state.contains("可重试") || record.state.contains("或重试") || record.state.contains("未精确命中")){Button("重试本地词典"){model.retryDictionary()}.buttonStyle(.borderless).foregroundStyle(accent)}
                RelatedDictionaryView(entries:record.related ?? [],compact:!model.expanded)
            }
            if model.expanded {
                contextPane(record)
                HStack {
                    Button("调整收藏目标或选择句式") { model.preciseSave() }
                    if record.query.split(separator:" ").count>=2 || record.book?.context?.isEmpty==false {
                        Button("练这段"){model.startReadingPractice(record,fromLookup:true)}
                    }
                }.buttonStyle(.borderless).foregroundStyle(accent)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    @ViewBuilder private func contextPane(_ record:LookupRecord)->some View {
        if record.query.count > 100 {
            Text("完整查询").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(record.query).font(.system(size:13)).lineSpacing(4).textSelection(.enabled)
        }
        if let book=record.book {
            Divider()
            Text(book.label).font(.subheadline.weight(.semibold))
            if let context=book.context {
                Text(book.contextLabel).font(.caption2).foregroundStyle(.secondary)
                if let chapter=book.chapter,!chapter.isEmpty {Text(chapter).font(.caption.weight(.semibold))}
                Text(context).font(.system(size:13)).lineSpacing(4).textSelection(.enabled)
            }
        }
        if let issue=record.bookIssue{Text(issue+" · 不影响查词").font(.caption2).foregroundStyle(.secondary)}
        if let line=record.visibleContext,!line.isEmpty {
            Text("屏幕识别语境（可能有误差）").font(.caption2).foregroundStyle(.secondary)
            Text(line).font(.system(size:13)).lineSpacing(4).textSelection(.enabled)
        }
    }
    @ViewBuilder private func assistantPane(_ record:LookupRecord)->some View {
        HStack {
            Label("语言助手",systemImage:"sparkles").font(.subheadline.weight(.semibold))
            Spacer()
            Button(model.handoffBusy ? "正在转入…" : "在 Codex 继续聊") { model.continueLookupInCodex() }.buttonStyle(.borderless)
                .disabled(model.handoffBusy || model.activeAsk != nil)
        }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:15) {
                    if model.replies.isEmpty {
                        if let d = record.definition {
                            Text(d.body).font(.system(size:13)).lineSpacing(3).foregroundStyle(.secondary)
                        }
                        Text("关于这个表达，你还想知道什么？").font(.headline)
                    }
                    ForEach(model.replies) { reply in
                        VStack(alignment:.leading,spacing:9) {
                            Text(reply.question).font(.subheadline.weight(.semibold))
                                .foregroundStyle(accent).textSelection(.enabled)
                            if !reply.answer.isEmpty {
                                ReadableAnswer(text:reply.answer)
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                        Divider()
                    }
                    Color.clear.frame(height:1).id("conversation-end")
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8)
            }
            .onChange(of:model.replies.count) { _,_ in proxy.scrollTo("conversation-end",anchor:.bottom) }
            .onChange(of:model.replies.last?.answer) { _,_ in proxy.scrollTo("conversation-end",anchor:.bottom) }
        }
        if !model.askStatus.isEmpty { Text(model.askStatus).font(.caption).foregroundStyle(.secondary) }
        HStack(spacing:6) {
            Button("在这里的意思") { model.question = "请解释此处的完整表达及意思。"; questionFocus=true }
            Button("比较用法") { model.question = "它的实际用法、近义表达和语气有什么区别？"; questionFocus=true }
        }.controlSize(.small).disabled(model.activeAsk != nil)
        HStack {
            TextField("想进一步问什么？",text:$model.question).textFieldStyle(.roundedBorder)
                .focused($questionFocus).onSubmit { model.beginAsk() }
            Button("发送") { model.beginAsk() }.buttonStyle(.borderedProminent).tint(accent)
                .disabled(model.activeAsk != nil || cleanText(model.question).isEmpty || model.voice.recording || model.voice.busy)
        }
        HStack {
            VoiceButton(voice:model.voice,english:false) { model.question = $0 }
            if model.activeAsk != nil { Button("停止等待") { model.closeAskWait() } }
            if model.pendingAsk != nil { Button("重试") { model.recheckAsk() } }
            Spacer()
            if model.replies.last?.answer.isEmpty == false {
                Button("保留到历史") { model.keepExplanation() }.buttonStyle(.borderless)
            }
        }.controlSize(.small)
        if !model.voice.message.isEmpty { Text(model.voice.message).font(.caption2).foregroundStyle(.secondary) }
    }
}

struct ReadableAnswer: View {
    let text:String
    var body:some View {
        let rich = (try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        Text(rich).font(.system(size:14)).lineSpacing(5).textSelection(.enabled)
            .fixedSize(horizontal:false,vertical:true)
    }
}

struct LibraryView: View {
    @ObservedObject var model:VocabModel
    var body: some View {
        HStack(spacing:0){
            VStack(alignment:.leading,spacing:7){
                Text("Vocab").font(.system(size:24,weight:.semibold)).padding(.horizontal,10).padding(.bottom,18)
                ForEach([LibraryTab.practice,.map,.expressions,.history]){item in navRow(item)}
                if model.practicing {
                    Divider().padding(.vertical,9)
                    navRow(.workbench)
                    Text(model.activityTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal,10)
                }
                Spacer()
                navRow(.settings)
            }.padding(12).frame(width:158).frame(maxHeight:.infinity,alignment:.topLeading)
                .background(Color(nsColor:.controlBackgroundColor))
            Divider()
            VStack(spacing:0){
                Group {
                    switch model.tab {
                    case .history: RecordsView(model:model)
                    case .expressions: ExpressionsView(model:model)
                    case .practice: PracticeView(model:model)
                    case .map: KnowledgeMapView(model:model,onBack:{model.navigate(.practice)})
                    case .workbench: PracticeView(model:model,showWorkbench:true)
                    case .settings: SettingsView(model:model)
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                if !model.message.isEmpty {
                    Divider()
                    HStack {Text(model.message).font(.caption);Spacer();Button("关闭"){model.message=""}.buttonStyle(.borderless)}
                        .padding(9).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(minWidth:780,minHeight:560)
            .sheet(item:$model.editingExpression) { e in ExpressionEditor(model:model,initial:e) }
            .onAppear { model.refresh() }
            .alert("保留当前练习？",isPresented:Binding(get:{model.activityConfirmation != nil},set:{if !$0{model.confirmActivityReplacement(false)}})){
                Button("继续当前练习",role:.cancel){model.confirmActivityReplacement(false);model.resumeActivity()}
                Button(model.activityConfirmAction,role:.destructive){model.confirmActivityReplacement(true)}
            } message:{Text(model.activityConfirmation ?? "")}
    }
    private func navRow(_ item:LibraryTab)->some View{
        Button {model.navigate(item)} label:{
            HStack(spacing:9){
                Image(systemName:item.symbol).font(.system(size:14,weight:.medium)).frame(width:18)
                Text(item == .workbench ? "当前练习":item.rawValue).font(.subheadline.weight(model.tab==item ? .semibold:.regular))
                Spacer(minLength:0)
            }.padding(.horizontal,10).padding(.vertical,9).frame(maxWidth:.infinity,alignment:.leading)
                .foregroundStyle(model.tab==item ? accent:Color.primary)
                .background(model.tab==item ? accent.opacity(0.14):Color.clear,in:RoundedRectangle(cornerRadius:6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(model.tab==item ? .isSelected:[])
    }
}

struct RelatedDictionaryView:View {
    let entries:[RelatedDictionaryEntry]
    var compact=false
    var body:some View {
        if !entries.isEmpty {
            VStack(alignment:.leading,spacing:9) {
                Text("Oxford 相关搭配 · 非完整词条").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(entries.prefix(compact ? 2 : 4)){entry in
                    VStack(alignment:.leading,spacing:4) {
                        Text(entry.label).font(.subheadline.weight(.semibold))
                        Text(compact ? shortText(entry.text,180) : entry.text).font(.system(size:13)).lineSpacing(3).textSelection(.enabled)
                        Text(entry.source+" · "+entry.head).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct RecordsView:View{
    @ObservedObject var model:VocabModel
    var body:some View{
        VStack(alignment:.leading,spacing:0){
            HStack{
                VStack(alignment:.leading,spacing:4){
                    Text("记录").font(.largeTitle.bold())
                    Text("遇见过的语言，与自己实际表达过的语言。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("记录类型",selection:Binding(get:{model.navigation.recordTab},set:{if !model.voice.recording && !model.voice.busy{model.navigation.recordTab=$0}})){
                    ForEach(RecordTab.allCases){Text($0.rawValue).tag($0)}
                }.labelsHidden().pickerStyle(.segmented).frame(width:150)
            }.padding(20)
            Divider()
            if model.navigation.recordTab == .lookup{HistoryView(model:model)}
            else{PracticeRecordsView(model:model)}
        }
    }
}
// A single browsing pattern for all three libraries, adapting the actual
// available content width (not the screen). The selection remains the route.
struct WorkspaceSplit<Index:View,Detail:View>:View{
    var selected:Bool
    var indexWidth:CGFloat=220
    var back:()->Void
    @ViewBuilder var index:()->Index
    @ViewBuilder var detail:()->Detail
    var body:some View{
        GeometryReader{g in
            if g.size.width<660{
                if selected{
                    VStack(spacing:0){
                        HStack{Button(action:back){Label("返回列表",systemImage:"chevron.left")}.buttonStyle(.borderless);Spacer()}
                            .padding(.horizontal,18).padding(.vertical,9)
                        Divider()
                        detail().frame(maxWidth:.infinity,maxHeight:.infinity)
                    }
                }else{index().frame(maxWidth:.infinity,maxHeight:.infinity)}
            }else{
                HStack(spacing:0){index().frame(width:indexWidth);Divider();detail().frame(maxWidth:.infinity,maxHeight:.infinity)}
            }
        }
    }
}
struct PracticeRecordsView:View{
    @ObservedObject var model:VocabModel
    var items:[Practice]{
        let q=keyFor(model.navigation.practiceSearch)
        return model.practiceHistory.filter{q.isEmpty || keyFor($0.answer+" "+$0.question+" "+($0.knowledge?.title ?? "")+" "+($0.targetText ?? "")+" "+$0.feedback).contains(q)}
    }
    var body:some View{
        WorkspaceSplit(selected:items.contains{$0.id==model.navigation.selectedAttempt},back:{if !model.voice.recording && !model.voice.busy{model.navigation.selectedAttempt=nil}}){
            VStack(alignment:.leading,spacing:8){
                TextField("搜索原答、知识点、反馈",text:$model.navigation.practiceSearch).textFieldStyle(.roundedBorder)
                Text("\(items.count) 次实际表达").font(.caption).foregroundStyle(.secondary)
                ScrollView{
                    LazyVStack(alignment:.leading,spacing:4){
                        ForEach(items){r in
                            Button {if !model.voice.recording && !model.voice.busy{model.navigation.selectedAttempt=r.id}} label:{
                                VStack(alignment:.leading,spacing:5){
                                    Text(r.knowledge?.title ?? r.targetText ?? r.method?.title ?? StudioMode(rawValue:r.mode)?.title ?? r.mode).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text(shortText(r.answer,95)).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                                    Text(dateText(r.time)+" · "+(model.waitingForFeedback(r.id) ? "等反馈":r.feedback.isEmpty ? "待反馈":"已反馈")).font(.caption2).foregroundStyle(.secondary)
                                }.padding(9).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(model.navigation.selectedAttempt==r.id ? accent.opacity(0.14):Color.clear,in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(r.id)
                        }
                    }.scrollTargetLayout()
                }.scrollPosition(id:model.scrollAnchor("practice-records"))
            }.padding(13)
        } detail:{
            if let r=items.first(where:{$0.id==model.navigation.selectedAttempt}){
                VStack(spacing:0){
                    ScrollViewReader{proxy in ScrollView{PracticeRecordDetail(model:model,record:r).padding(22);Color.clear.frame(height:1).id("feedback-bottom")}.onChange(of:r.feedbackDiscussion?.count ?? 0){_,_ in proxy.scrollTo("feedback-bottom",anchor:.bottom)}}
                    if !r.feedback.isEmpty{Divider();FeedbackComposer(model:model,record:r).padding(12)}
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).id(r.id)
            }else{EmptyState(icon:"text.bubble",title:items.isEmpty ? "没有相关练习":"选择一次表达",detail:"回看原答、原材料和反馈，不会增加一次学习记录。").padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)}
        }
    }
}
struct PracticeRecordDetail:View{
    @ObservedObject var model:VocabModel
    let record:Practice
    var body:some View{
        VStack(alignment:.leading,spacing:15){
            Text(record.knowledge?.title ?? record.targetText ?? record.method?.title ?? StudioMode(rawValue:record.mode)?.title ?? record.mode).font(.title2.bold()).textSelection(.enabled)
            Text(dateText(record.time)+" · "+(record.feedback.isEmpty ? "待反馈":"已反馈")).font(.caption).foregroundStyle(.secondary)
            HStack{
                Button("再练一次"){model.repeatRecord(record)}.buttonStyle(.borderedProminent).tint(accent)
                if record.feedback.isEmpty,!model.waitingForFeedback(record.id){Button("补取原答反馈"){model.resumeRecordFeedback(record,inPlace:true)}}
            }
            Text(record.question).font(.headline).textSelection(.enabled)
            if let material=record.material{Text(material).font(.subheadline).padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:6)).textSelection(.enabled)}
            if let original=record.reference {DisclosureGroup("原表达 · "+(record.sourceLabel ?? "参考")){Text(original).textSelection(.enabled)}.font(.subheadline)}
            Divider()
            PracticeAnswerBlock(model:model,record:record)
            if !record.feedback.isEmpty{Divider();Text("反馈").font(.headline);ReadableAnswer(text:record.feedback)}
            else if model.waitingForFeedback(record.id){HStack{ProgressView().controlSize(.small);Text("正在整理原答反馈…").font(.caption)}}
            else{Text("原答已保存，反馈尚未完成。").font(.subheadline).foregroundStyle(.secondary)}
            if let e=record.knowledgeObservation{
                if let reason=e.reason{Text(reason).font(.subheadline).foregroundStyle(.secondary)}
            }
            FeedbackDiscussionPanel(model:model,record:record)
            VStack(alignment:.leading,spacing:8){
                if let k=record.knowledge,model.knowledgeCatalog.unit(k.id) != nil{Button("查看知识点"){model.openKnowledge(k.id)}.buttonStyle(.borderless)}
                if let e=record.expressionID,model.expressions.contains(where:{$0.id==e}){Button("查看我的表达"){model.openExpression(e)}.buttonStyle(.borderless)}
                if let id=record.lookupID,model.history.contains(where:{$0.id==id}){Button("查看原查询"){model.openLookup(id)}.buttonStyle(.borderless)}
                if let id=record.retryOf{Button("查看上次原答"){model.openPracticeRecord(id)}.buttonStyle(.borderless)}
            }
        }.frame(maxWidth:.infinity,alignment:.leading).onAppear{model.noteRecordViewed(record)}
    }
}

// Same review surface in workbench and history. Editing a displayed answer is
// transcription correction; the existing retry action creates a new attempt.
struct PracticeAnswerBlock:View {
    @ObservedObject var model:VocabModel
    let record:Practice
    @State private var editing:String?=nil
    @State private var draft=""
    var body:some View{
        VStack(alignment:.leading,spacing:8){
            HStack{Text("你的原话").font(.headline);if record.answerRevision != nil{Text("已修正转写").font(.caption).foregroundStyle(.secondary)};Spacer()}
            if let turns=record.dialogue,!turns.isEmpty{
                ForEach(turns){turn in
                    VStack(alignment:.leading,spacing:5){
                        HStack{Text(turn.speaker).font(.caption.weight(.semibold)).foregroundStyle(turn.speaker=="你" ? accent:.secondary);Spacer()
                            if turn.speaker=="你"{editButton(turn.id,turn.text)}
                            else{Button{model.speak(turn.text)}label:{Image(systemName:"speaker.wave.2")}.buttonStyle(.borderless)}
                        }
                        if editing==turn.id{editor(turnID:turn.id)}else{Text(turn.text.isEmpty ? "（无可用转写）":turn.text).textSelection(.enabled)}
                    }.padding(9).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:6))
                }
            }else{
                HStack(alignment:.top){if editing==record.id{editor(turnID:nil)}else{Text(record.answer.isEmpty ? "（无可用转写）":record.answer).font(.system(size:15)).textSelection(.enabled);Spacer();editButton(record.id,record.answer)}}
            }
            if let raw=record.answerRaw{DisclosureGroup("原始转写"){Text(raw).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}.font(.caption)}
        }.onChange(of:record.id){_,_ in editing=nil}
    }
    private func editButton(_ id:String,_ text:String)->some View{
        Button{editing=id;draft=text}label:{Image(systemName:"pencil")}.buttonStyle(.borderless).disabled(!model.canCorrect(record)).help("修正语音转写（不新增练习）").accessibilityLabel("修正转写")
    }
    private func editor(turnID:String?)->some View{
        VStack(alignment:.leading,spacing:6){
            TextEditor(text:$draft).font(.system(size:15)).frame(minHeight:76,maxHeight:140).padding(3).overlay(RoundedRectangle(cornerRadius:5).stroke(Color.secondary.opacity(0.25)))
            Text("仅修正识别错误。旧反馈会失效；留空表示没有可用转写。若想改进表达，请使用再说一次。").font(.caption).foregroundStyle(.secondary)
            HStack{Button("取消"){editing=nil}.buttonStyle(.borderless);Spacer();Button("保存修正"){if model.correctPractice(record,text:draft,turnID:turnID){editing=nil}}.buttonStyle(.borderedProminent).tint(accent)}
        }
    }
}
struct FeedbackDiscussionPanel:View {
    @ObservedObject var model:VocabModel
    let record:Practice
    var current:[FeedbackExchange]{(record.feedbackDiscussion ?? []).filter{$0.revision==record.revision}}
    var old:[FeedbackExchange]{(record.feedbackDiscussion ?? []).filter{$0.revision != record.revision}}
    var body:some View{
        VStack(alignment:.leading,spacing:10){
            if !old.isEmpty{DisclosureGroup("修正转写前的讨论"){ForEach(old){exchange($0)}}.font(.caption).foregroundStyle(.secondary)}
            if !record.feedback.isEmpty{ForEach(current){exchange($0)}}
        }
    }
    private func exchange(_ turn:FeedbackExchange)->some View{
        VStack(alignment:.leading,spacing:5){Text(turn.question).font(.subheadline.weight(.medium)).foregroundStyle(accent);ReadableAnswer(text:turn.answer);if let source=turn.source{Text(source).font(.caption2).foregroundStyle(.secondary)}}.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:6))
    }
}
struct FeedbackComposer:View{
    @ObservedObject var model:VocabModel
    @ObservedObject private var voice:VoiceInput
    let record:Practice
    @State private var question=""
    init(model:VocabModel,record:Practice){self.model=model;self.record=record;self.voice=model.voice}
    var body:some View{
        VStack(alignment:.leading,spacing:4){
            HStack(alignment:.center,spacing:7){
                TextField("问问这次反馈…",text:$question,axis:.vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                VoiceButton(voice:voice,english:false,owner:"practice:discussion:"+record.id){question=$0}.disabled(model.discussingFeedback(record.id))
                Button{model.discussFeedback(record,question:question)}label:{Image(systemName:"arrow.up.circle.fill").font(.title2)}.buttonStyle(.borderless).foregroundStyle(accent).disabled(cleanText(question).isEmpty || model.discussingFeedback(record.id) || voice.recording || voice.busy).help("发送问题")
            }
            if model.discussingFeedback(record.id){HStack{ProgressView().controlSize(.small);Text("正在讨论…").font(.caption).foregroundStyle(.secondary)}}
            if let error=model.discussionErrors[record.id]{Text(error).font(.caption).foregroundStyle(.secondary)}
        }.onChange(of:record.feedbackDiscussion?.count ?? 0){_,_ in question=""}.onChange(of:record.revision){_,_ in question=""}
    }
}

struct HistoryView: View {
    @ObservedObject var model:VocabModel
    @State private var deleting:LookupRecord?
    @State private var dictionaryPage:DictionaryPage = .english
    private var histories:[LookupRecord] {
        let q=keyFor(model.search)
        return q.isEmpty ? model.history : model.history.filter{keyFor($0.query+" "+($0.definition?.detail ?? "")+" "+($0.definition?.chinese?.detail ?? "")+" "+($0.book?.title ?? "")).contains(q)}
    }
    private var old:[LegacyRow] {
        let q=keyFor(model.search)
        return q.isEmpty ? model.legacy : model.legacy.filter{keyFor($0.term+" "+$0.definition+" "+$0.source).contains(q)}
    }
    // A history row is a word/expression to revisit; the individual
    // encounters remain available with their own date and source.
    private var groupedHistory:[[LookupRecord]] {
        let grouped=Dictionary(grouping:histories,by:{keyFor($0.query)})
        return grouped.values.sorted{($0.first?.time ?? 0)>($1.first?.time ?? 0)}
    }
    var body:some View {
        WorkspaceSplit(selected:histories.contains{$0.id==model.selectedHistory} || old.contains{$0.id==model.selectedLegacy},back:{model.selectedHistory=nil;model.selectedLegacy=nil}){
            VStack(alignment:.leading,spacing:8) {
                TextField("搜索词、含义、书名",text:$model.search).textFieldStyle(.roundedBorder)
                Text("查询只记录接触 · 不自动加入学习").font(.caption2).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:5) {
                        if histories.isEmpty && old.isEmpty { Text("还没有相关记录").foregroundStyle(.secondary).padding(8) }
                        if !histories.isEmpty {
                            Text("近期 · \(groupedHistory.count) 个表达").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top,5)
                            ForEach(groupedHistory, id:\.[0].id) { group in
                                let r=group[0]
                                Button { model.selectedHistory=r.id; model.selectedLegacy=nil } label: {
                                    VStack(alignment:.leading,spacing:3) {
                                        HStack {
                                            Text(r.query).font(.subheadline.weight(.medium)).lineLimit(2)
                                            Spacer(minLength:0)
                                            if group.count > 1 {
                                                Text("×\(group.count)").font(.caption2.weight(.medium)).foregroundStyle(accent)
                                            }
                                        }
                                        Text((r.book?.label ?? r.application)+" · "+dateText(r.time)).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                                    }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                                        .background(group.contains(where:{$0.id==model.selectedHistory}) ? accent.opacity(0.15) : Color.clear,in:RoundedRectangle(cornerRadius:7))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id("lookup:"+keyFor(r.query))
                            }
                        }
                        if !old.isEmpty {
                            Text("原词表 · \(old.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top,8)
                            ForEach(old) { l in
                                Button { model.selectedLegacy=l.id;model.selectedHistory=nil } label: {
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(l.term).font(.subheadline.weight(.medium))
                                        Text("×\(l.count) · \(l.date) · \(l.source)").font(.caption2).foregroundStyle(.secondary)
                                    }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                                        .background(model.selectedLegacy==l.id ? accent.opacity(0.15) : Color.clear,in:RoundedRectangle(cornerRadius:7))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id("legacy:"+l.id)
                            }
                        }
                    }.scrollTargetLayout()
                }.scrollPosition(id:model.scrollAnchor("lookup"))
            }.padding(13)
        } detail:{
            ScrollView {
                VStack(alignment:.leading,spacing:13) {
                    if let r=histories.first(where:{$0.id==model.selectedHistory}) {
                        Text(r.query).font(.title2.bold()).textSelection(.enabled).id(r.id).onAppear{model.noteLookupViewed(r)}
                        Text("\(r.book?.label ?? r.application) · \(dateText(r.time))").font(.caption).foregroundStyle(.secondary)
                        let repeats=model.history.filter{keyFor($0.query)==keyFor(r.query)}
                        if repeats.count > 1 {
                            DisclosureGroup("\(repeats.count) 次接触 · 查看其他来源") {
                                VStack(alignment:.leading,spacing:8) {
                                    ForEach(repeats) { item in
                                        Button { model.selectedHistory=item.id } label:{
                                            HStack {
                                                if item.id==r.id { Image(systemName:"checkmark").foregroundStyle(accent) }
                                                Text(item.book?.label ?? item.application)
                                                Spacer()
                                                Text(dateText(item.time)).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.top,6)
                            }.font(.subheadline)
                        }
                        HStack {
                            if let e=model.expressions.first(where:{$0.lookupIDs.contains(r.id)}) {
                                Button("查看收藏"){model.openExpression(e.id)}.buttonStyle(.borderedProminent).tint(accent)
                            }else{Button("收藏表达") {model.saveOne(r)}.buttonStyle(.borderedProminent).tint(accent)}
                            Button("再次查询") { model.manual(prefill:r.query) }
                            if r.query.split(separator:" ").count>=2 || r.book?.context?.isEmpty==false {Button("练这段"){model.startReadingPractice(r)}}
                            Spacer(); Button("移除记录",role:.destructive){deleting=r}
                        }
                        if let d=r.definition {
                            PronunciationLine(definition:d)
                            if d.match == "inflected" { Text("原形 · "+d.matched).font(.caption).foregroundStyle(.secondary) }
                            DictionaryPages(page:$dictionaryPage,expanded:true)
                            DictionaryReading(definition:d,page:dictionaryPage,compact:false)
                                .id(dictionaryPage)
                        } else {
                            Text("这次查询没有词典结果。").font(.subheadline).foregroundStyle(.secondary)
                            RelatedDictionaryView(entries:r.related ?? [])
                        }
                        if let b=r.book,let c=b.context { Text(b.contextLabel).font(.caption).foregroundStyle(accent); Text(c).textSelection(.enabled) }
                        if let line=r.visibleContext {Text("屏幕识别语境（可能有误差）").font(.caption).foregroundStyle(.secondary);Text(line).textSelection(.enabled)}
                        if r.original != r.query { Text("原选区").font(.caption.bold()); Text(r.original).textSelection(.enabled) }
                        if let notes=r.savedExplanations,!notes.isEmpty {
                            Divider()
                            Text("保留的 AI 解释").font(.headline)
                            ForEach(Array(notes.enumerated()),id:\.offset) { _, note in
                                Text(note.question).font(.subheadline.weight(.semibold))
                                ReadableAnswer(text:note.answer)
                                if let source=note.source {Text(source).font(.caption2).foregroundStyle(.secondary)}
                            }
                        }
                    } else if let l=old.first(where:{$0.id==model.selectedLegacy}) {
                        Text(l.term).font(.title2.bold()).textSelection(.enabled).id(l.id).onAppear{model.noteLanguageTextViewed(l.term)}
                        Text(l.phonetic).foregroundStyle(.secondary)
                        Text(l.definition).textSelection(.enabled)
                        if !l.synonyms.isEmpty { Text("同义词：\(l.synonyms)").foregroundStyle(.secondary) }
                        Text("旧表聚合记录：\(l.count) 次 · 日期 \(l.date)（年份未知） · \(l.source)").font(.caption).foregroundStyle(.secondary)
                        HStack { Button("收藏表达") { model.saveLegacy(l) }.buttonStyle(.borderedProminent).tint(accent); Button("再次查询"){model.manual(prefill:l.term)} }
                    } else {
                        EmptyState(icon:"clock.arrow.circlepath",title:"每次遇见，都是一次接触",detail:"选择一条历史查看原查询、释义与来源；喜欢的表达可以补收藏。")
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(24)
            }
        }
        .onChange(of:model.selectedHistory) { _,id in
            let source = model.history.first(where:{$0.id==id})?.definition?.source
            dictionaryPage = DictionaryPage.preferred(source)
        }
        .confirmationDialog("移除查询记录？已有收藏及练习原答仍保留。",isPresented:Binding(get:{deleting != nil},set:{if !$0{deleting=nil}})) {
            if let deleting { Button("移除",role:.destructive){model.deleteHistory(deleting);self.deleting=nil} }
            Button("取消",role:.cancel){deleting=nil}
        }
    }
}

struct ExpressionsView: View {
    @ObservedObject var model:VocabModel
    @State private var deleting:Expression?
    private var items:[Expression] {
        let q=keyFor(model.search)
        return q.isEmpty ? model.expressions : model.expressions.filter { keyFor($0.target+" "+$0.intent+" "+$0.definition).contains(q) }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0){
            VStack(alignment:.leading,spacing:4){Text("我的表达").font(.largeTitle.bold());Text("主动选择想真正用起来的语言。").font(.caption).foregroundStyle(.secondary)}.padding(20)
            Divider()
            WorkspaceSplit(selected:items.contains{$0.id==model.selectedExpression},back:{model.selectedExpression=nil}){
            VStack(alignment:.leading,spacing:8) {
                TextField("搜索收藏表达",text:$model.search).textFieldStyle(.roundedBorder)
                Text("\(model.expressions.count) 个主动表达 · \(model.readyCount) 可练习").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing:5) {
                        ForEach(items) { e in
                            Button {model.selectedExpression=e.id} label: {
                                VStack(alignment:.leading,spacing:6) {
                                    Text(e.target).font(.subheadline.weight(.medium)).lineLimit(2)
                                    HStack { TagLabel(text:e.kind.rawValue); Text(e.learning.rawValue).font(.caption2).foregroundStyle(.secondary) }
                                }.padding(9).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(model.selectedExpression==e.id ? accent.opacity(0.15) : Color.clear,in:RoundedRectangle(cornerRadius:7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(e.id)
                        }
                    }.scrollTargetLayout()
                }.scrollPosition(id:model.scrollAnchor("expressions"))
            }.padding(13)
        } detail:{
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    if let e=items.first(where:{$0.id==model.selectedExpression}) {
                        Text(e.target).font(.title2.bold()).textSelection(.enabled).id(e.id).onAppear{model.noteExpressionViewed(e)}
                        HStack { TagLabel(text:e.kind.rawValue,color:accent); TagLabel(text:e.learning.rawValue) }
                        Button("练这个表达"){model.startPractice(expression:e)}.buttonStyle(.borderedProminent).tint(accent)
                        if !e.intent.isEmpty { Text("我想学的表达意图").font(.caption.bold()); Text(e.intent).textSelection(.enabled) }
                        if let cue=e.studyMeaning,!cue.isEmpty {
                            Text("练习提示 · "+(e.studyMeaningSource ?? "学习素材")).font(.caption.bold()).foregroundStyle(.secondary)
                            Text(cue).textSelection(.enabled)
                        }
                        if !e.definition.isEmpty && e.definition != e.intent {
                            if e.definition.count > 420 {
                                DisclosureGroup("原收藏释义") {
                                    Text(e.definition).font(.system(size:14)).lineSpacing(4).textSelection(.enabled)
                                }
                            } else {
                                Text("释义及用法").font(.caption.bold())
                                Text(e.definition).font(.system(size:14)).lineSpacing(4).textSelection(.enabled)
                            }
                        }
                        Text("原始选区").font(.caption.bold()); Text(e.original).textSelection(.enabled)
                        Text(e.source).font(.caption).foregroundStyle(.secondary)
                        if let id=e.lookupIDs.first,model.history.contains(where:{$0.id==id}){Button("查看原查询"){model.openLookup(id)}.buttonStyle(.borderless)}
                        if let id=e.knowledgeID,model.knowledgeCatalog.unit(id) != nil{Button("查看相关知识点"){model.openKnowledge(id)}.buttonStyle(.borderless)}
                        if let b=e.book,let c=b.context { Text(b.contextLabel).font(.caption).foregroundStyle(.secondary); Text(c).textSelection(.enabled) }
                        if !e.notes.isEmpty { Text("我的笔记／AI 解释").font(.caption.bold());Text(e.notes).textSelection(.enabled) }
                        if let due=e.due { Text("下次练习建议：\(dateText(due))").font(.caption).foregroundStyle(.secondary) }
                        let reviews=model.selectedPracticeRecords
                        if !reviews.isEmpty {
                            Text("实际练习 · \(reviews.count) 次").font(.subheadline.bold())
                            ForEach(reviews.prefix(6)) { p in
                                VStack(alignment:.leading,spacing:4) {
                                    Text(dateText(p.time)+" · "+p.rating.rawValue).font(.caption).foregroundStyle(.secondary)
                                    Text(p.answer).font(.subheadline).textSelection(.enabled)
                                    Button("查看原答和反馈"){model.openPracticeRecord(p.id)}.buttonStyle(.borderless).font(.caption)
                                }.padding(9).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:7))
                            }
                        }
                        HStack {
                            Button("编辑学习目标") {model.edit(e)}
                            Button(e.learning == .paused ? "继续学习" : "暂停") {model.togglePause(e)}
                            Spacer(); Button("取消收藏",role:.destructive){deleting=e}
                        }
                    } else {
                        EmptyState(icon:"star",title:"收藏的是想用的语言",detail:"在浮窗一键收藏单词、搭配、句式或整句。在这里调整表达目标并查看真实练习记录。")
                    }
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
        }.confirmationDialog("取消收藏？查询及已提交的练习记录仍保留。",isPresented:Binding(get:{deleting != nil},set:{if !$0{deleting=nil}})) {
            if let deleting { Button("取消收藏",role:.destructive){model.deleteExpression(deleting);self.deleting=nil} }
            Button("返回",role:.cancel){deleting=nil}
        }
    }
}

struct ExpressionEditor:View {
    @ObservedObject var model:VocabModel
    @State var value:Expression
    init(model:VocabModel,initial:Expression){self.model=model;_value=State(initialValue:initial)}
    var body:some View {
        VStack(alignment:.leading,spacing:15) {
            Text("确认学习表达").font(.title2.bold())
            Text("原文完整保留；可以把整句中真正想学的结构作为目标。").foregroundStyle(.secondary).font(.caption)
            Text("原始选区").font(.caption.bold())
            ScrollView {Text(value.original).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:70)
            TextField("学习目标",text:$value.target).textFieldStyle(.roundedBorder)
            Picker("类型",selection:$value.kind){ForEach(ExpressionKind.allCases){Text($0.rawValue).tag($0)}}
            TextField("想表达的含义、语气或特定义项（可选）",text:$value.intent).textFieldStyle(.roundedBorder)
            Text("我的笔记 / 真实使用记录").font(.caption.bold())
            TextEditor(text:$value.notes).font(.body).frame(height:100).border(Color.secondary.opacity(0.2))
            HStack { Spacer();Button("取消"){model.editingExpression=nil};Button("保存"){model.saveEdited(value)}.buttonStyle(.borderedProminent).tint(accent).disabled(cleanText(value.target).isEmpty) }
        }.padding(25).frame(width:510)
    }
}

struct PracticeView:View {
    @ObservedObject var model:VocabModel
    @ObservedObject private var voice:VoiceInput
    var showWorkbench:Bool
    init(model:VocabModel,showWorkbench:Bool=false){self.model=model;self.voice=model.voice;self.showWorkbench=showWorkbench}
    var body:some View{
        if showWorkbench && model.practicing{
            VStack(spacing:0){
                activityHeader.padding(.horizontal,22).padding(.vertical,13)
                Divider()
                ScrollViewReader{proxy in
                    ScrollView{
                        VStack(alignment:.leading,spacing:18){
                            if model.activityRecap{recap}
                            else if let task=model.pTask{workbench(task)}
                            Color.clear.frame(height:1).id("workbench-bottom")
                        }.padding(24).frame(maxWidth:850,alignment:.leading).frame(maxWidth:.infinity,alignment:.center)
                    }.id(model.activityRecap ? "recap":model.pTask?.id ?? "")
                        .onChange(of:model.pDialogue.count){_,_ in if model.pTask?.isDialogue==true && !model.pSubmitted{proxy.scrollTo("workbench-bottom",anchor:.bottom)}}
                        .onChange(of:model.currentPracticeRecord?.feedbackDiscussion?.count ?? 0){_,_ in proxy.scrollTo("workbench-bottom",anchor:.bottom)}
                }
                if !model.activityRecap{
                    Divider()
                    VStack(spacing:8){
                        if let task=model.pTask,task.isDialogue,!model.pSubmitted,!model.pWaiting,!model.generationUnavailable{dialogueComposer}
                        if model.pSubmitted,let record=model.currentPracticeRecord,!record.feedback.isEmpty{FeedbackComposer(model:model,record:record).id(record.id)}
                        activityFooter
                    }.padding(.horizontal,22).padding(.vertical,11)
                }
            }
        }else{ScrollView{landing.padding(26).frame(maxWidth:780,alignment:.leading).frame(maxWidth:.infinity,alignment:.center)}}
    }
    private var landing:some View{
        VStack(alignment:.leading,spacing:18){
            VStack(alignment:.leading,spacing:5){
                Text("学习空间").font(.largeTitle.bold())
                Text("用英语想事情、聊事情，把读到的语言变成自己的表达。").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment:.top,spacing:18){
                VStack(alignment:.leading,spacing:9){
                    Text(model.practicing ? "继续当前练习":"随便练一下").font(.title2.weight(.semibold))
                    Text(model.practicing ? "\(model.activityTitle) · "+(model.activityRecap ? "本轮回顾":model.activity?.current?.stateLabel ?? "可继续"):"循知识地图练习，在真实情境中调用英语。").font(.subheadline).foregroundStyle(.secondary)
                    HStack{Button{if model.practicing{model.resumeActivity()}else{model.startPractice()}}label:{Label(model.practicing ? "继续练习":"开始练习",systemImage:"play.fill")}.buttonStyle(.borderedProminent).tint(accent)
                        if model.practicing{Button("新练习"){model.startPractice()}.buttonStyle(.borderless)}}
                }.frame(maxWidth:.infinity,alignment:.leading)
                Divider()
                VStack(alignment:.leading,spacing:9){
                    Text("聊几句").font(.title2.weight(.semibold))
                    Text("围绕有内容的话题交流，综合运用自己的英语。").font(.subheadline).foregroundStyle(.secondary)
                    Button{model.startDiscussion()}label:{Label("开始交流",systemImage:"bubble.left.and.bubble.right")}.buttonStyle(.borderedProminent).tint(accent)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(accent.opacity(0.09),in:RoundedRectangle(cornerRadius:10))
            Divider()
            HStack(alignment:.center){
                VStack(alignment:.leading,spacing:5){
                    Text("巩固我的表达").font(.headline)
                    Text(model.readyCount>0 ? "\(model.readyCount) 个新表达或到期表达。":"没有到期表达，仍可以从表达库选一个。").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("开始复习"){model.startPractice(review:true)}.disabled(model.readyCount==0)
                Button("表达库"){model.navigate(.expressions)}.buttonStyle(.borderless)
            }
            if !model.knowledgeCatalog.units.isEmpty{
                Divider()
                HStack{Text("知识地图").font(.headline);Spacer();Button("探索地图"){model.navigate(.map)}.buttonStyle(.borderless)}
                CoverageSummary(coverage:model.coverage(),compact:true)
            }
            DisclosureGroup("用自己的话题或材料",isExpanded:$model.navigation.customExpanded){
                VStack(alignment:.leading,spacing:9){
                    Picker("表达方式",selection:$model.navigation.customMode){ForEach(StudioMode.allCases){Text($0.title).tag($0)}}.pickerStyle(.segmented)
                    Text("贴一段材料或写下想说的话。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text:$model.navigation.customDraft).font(.system(size:14)).frame(height:80).padding(3).overlay(RoundedRectangle(cornerRadius:6).stroke(Color.secondary.opacity(0.25)))
                    HStack{if model.navigation.customDraft.count>2500{Text("请缩短材料到 2500 字符以内").font(.caption).foregroundStyle(.orange)};Spacer();Button("就练这个"){model.startPractice(mode:model.navigation.customMode,topic:model.navigation.customDraft)}.buttonStyle(.borderedProminent).tint(accent).disabled(cleanText(model.navigation.customDraft).isEmpty || model.navigation.customDraft.count>2500)}
                }.padding(.top,8)
            }.font(.subheadline)
            if !model.readingCandidates.isEmpty{
                Divider();Text("最近读到的表达").font(.headline)
                Text("从真实原文出发，用自己的英语重建。").font(.caption).foregroundStyle(.secondary)
                ForEach(model.readingCandidates.prefix(3)){r in
                    HStack{
                        Button{model.openLookup(r.id)}label:{
                            VStack(alignment:.leading,spacing:4){Text(shortText(r.query,115)).font(.subheadline.weight(.medium)).lineLimit(2);Text(r.book?.label ?? r.application).font(.caption2).foregroundStyle(.secondary)}
                                .frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button("练这段"){model.startReadingPractice(r)}
                        Menu("虚词"){ForEach(FunctionalFocus.allCases){focus in Button(focus.title){model.startReadingPractice(r,functional:focus,useCloze:true)}}}.fixedSize()
                    }.padding(.vertical,6)
                }
            }
            if !model.practicing && !model.pStatus.isEmpty{Text(model.pStatus).font(.caption).foregroundStyle(.secondary)}
            if !model.pRecent.isEmpty{
                Divider()
                HStack{Text("最近的表达").font(.headline);Spacer();Button("全部练习记录"){model.navigation.recordTab = .practice;model.navigate(.history)}.buttonStyle(.borderless)}
                ForEach(model.pRecent.prefix(3)){r in
                    Button{model.openPracticeRecord(r.id)}label:{
                        HStack{
                            VStack(alignment:.leading,spacing:4){Text(shortText(r.answer,135)).font(.subheadline).lineLimit(2);Text(dateText(r.time)+" · "+r.rating.rawValue).font(.caption).foregroundStyle(.secondary)}
                            Spacer();Image(systemName:"chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private var activityHeader:some View{
        VStack(alignment:.leading,spacing:9){
            HStack{
                Button{model.backToActivityOrigin()}label:{Label(model.activityOriginTitle,systemImage:"chevron.left")}.buttonStyle(.borderless)
                if model.activityOriginTitle != "学习空间"{Button("学习主页"){model.navigate(.practice)}.buttonStyle(.borderless).foregroundStyle(.secondary)}
                Spacer()
                if model.activity?.kind == .discussion,model.currentPracticeRecord==nil{Button("换个话题"){model.startDiscussion()}.buttonStyle(.borderless)}
                if !model.activityRecap{Button("结束本轮"){model.stopPractice()}.buttonStyle(.borderless)}
            }.font(.subheadline)
            HStack(alignment:.firstTextBaseline){
                Text(model.activityTitle).font(.title2.bold()).lineLimit(2)
                Spacer()
                if !model.activityProgressLabel.isEmpty{Text(model.activityProgressLabel).font(.caption).foregroundStyle(.secondary)}
            }
            if model.activityFinite && model.currentScenes.count>1{
                ScrollView(.horizontal,showsIndicators:false){
                    HStack(spacing:7){
                        ForEach(Array(model.currentScenes.enumerated()),id:\.element.id){index,s in
                            Button{model.selectScene(index)}label:{
                                VStack(alignment:.leading,spacing:4){
                                    Text("\(index+1). "+shortText(s.label,20)).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(s.stateLabel).font(.caption2).foregroundStyle(.secondary)
                                }.padding(7).frame(minWidth:114,alignment:.leading)
                                 .background(!model.activityRecap && model.currentSceneIndex==index ? accent.opacity(0.14):Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(s.label)
                        }
                    }
                }
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private var dialogueComposer:some View{
        ZStack(alignment:.topLeading){
            if model.pAnswer.isEmpty{Text("你的回应 · 说一段或键入…").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal,8).padding(.top,10)}
            TextEditor(text:$model.pAnswer).font(.system(size:15)).scrollContentBackground(.hidden).frame(minHeight:54,maxHeight:82).padding(3)
        }.background(.background,in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).stroke(Color.secondary.opacity(0.25)))
    }
    private var activityFooter:some View{
        HStack(spacing:10){
            Button{model.selectScene(model.currentSceneIndex-1)}label:{Label("上一个",systemImage:"chevron.left")}.disabled(model.currentSceneIndex==0)
            if model.activity?.current?.attempt==nil{Button("跳过"){model.skipScene()}.buttonStyle(.borderless)}
            Spacer()
            if let task=model.pTask{
                if task.reference != nil {Menu("练这段材料"){
                    if task.reference != nil{ForEach(FunctionalFocus.allCases){focus in Button("练这段的"+focus.title){model.practiceFunctional(focus)}}}
                    if task.method == .cloze{Button("重建这段表达"){model.practiceRebuild()}}
                }.menuStyle(.borderlessButton).fixedSize()}
                if !model.pSubmitted && !model.pWaiting && !model.generationUnavailable{
                    VoiceButton(voice:model.voice,english:true,owner:"practice:"+task.id){if model.pTask?.id==task.id{model.pAnswer=$0}}.disabled(model.pFeedbackWaiting)
                    if task.isDialogue && !model.pDialogue.isEmpty{
                        Button("结束并回顾"){model.finishConversation()}.buttonStyle(.borderless)
                            .disabled(!cleanText(model.pAnswer).isEmpty || voice.recording || voice.busy).help("先提交或清空当前回应，再回顾对话")
                    }
                    Button(task.isDialogue || task.isReply ? "回应":"提交表达"){model.submitPractice()}
                        .buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.return,modifiers:.command)
                        .disabled(cleanText(model.pAnswer).isEmpty || model.pFeedbackWaiting || voice.recording || voice.busy)
                }
            }
            if model.pSubmitted || model.pWaiting || model.generationUnavailable{
                Button(nextLabel){model.nextPractice()}.buttonStyle(.borderedProminent).tint(accent)
            }
        }
    }
    private var nextLabel:String{model.activityFinite && model.currentSceneIndex==model.currentScenes.count-1 && model.activity?.kind != .review ? "本轮回顾":model.activityFinite ? "下一情境":"下一题"}
    private var recap:some View{
        VStack(alignment:.leading,spacing:15){
            Text("本轮到达末尾").font(.largeTitle.bold())
            if let a=model.activity{
                let tried=a.attemptedCount,skipped=a.skippedCount
                Text("已提交 \(tried) 项 · 跳过 \(skipped) 项 · 未尝试 \(max(0,a.scenes.count-tried-skipped)) 项").font(.title3)
                let evaluated=a.scenes.filter{$0.attempt.map{!$0.feedback.isEmpty}==true}.count
                Text("已有反馈 \(evaluated) 项 · 待反馈 \(max(0,tried-evaluated)) 项").font(.subheadline).foregroundStyle(.secondary)
                if let u=model.knowledgeCatalog.unit(a.focusID){
                    let p=model.progress(for:u)
                    Text("核心训练：\(u.coreScenarios.filter{p.completedContexts.contains($0.id)}.count) / \(u.coreScenarios.count) · \(u.coverage(p).rawValue)").font(.subheadline)
                }
                Text("已经完成的核心训练会记入知识地图；仍可继续复练。").font(.subheadline).foregroundStyle(.secondary)
            }
            if model.isFocusedActivity{
                if let next=model.followingKnowledgeUnit{
                    Button("下一个知识点"){model.nextKnowledgeUnit()}.buttonStyle(.borderedProminent).tint(accent)
                    Text(next.title).font(.caption).foregroundStyle(.secondary)
                }else{Button("回地图选知识点"){model.backToActivityOrigin()}.buttonStyle(.borderedProminent).tint(accent)}
                if model.canAddKnowledgeContext {Button("再练一个新情境"){model.addKnowledgeContext()}}
            }
            if model.activity?.kind == .discussion{Button("换个话题"){model.startDiscussion()}.buttonStyle(.borderedProminent).tint(accent)}
            Button("结束本轮并返回"){model.stopPractice()}.buttonStyle(.borderless)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private func workbench(_ task:StudioTask)->some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:8) {
                TagLabel(text:task.method?.title ?? (task.isReply ? "情境回应":task.mode.title),color:accent)
                if let k=task.knowledge {TagLabel(text:k.domain.title)}
                if task.clue != nil {TagLabel(text:"练习线索")}
                Spacer()
                Text("已记录 \(model.pCompleted) 次表达").font(.caption).foregroundStyle(.secondary)
            }
            if model.generationUnavailable {
                VStack(alignment:.leading,spacing:10){
                    Text("没有生成新的情境").font(.headline)
                    Text(model.pStatus).font(.subheadline).foregroundStyle(.secondary)
                    Button("重试新情境"){model.retryNewContext()}.buttonStyle(.borderedProminent).tint(accent)
                }.frame(maxWidth:.infinity,alignment:.leading)
            } else if model.pWaiting {
                HStack(spacing:12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment:.leading,spacing:4) {
                        Text(model.pStatus.isEmpty ? "正在准备适合你的情境":model.pStatus).font(.headline)
                        Text(model.activity?.current?.freshRequired==true ? "检查新情境是否符合这个知识目标。":"也可以立即开始，不必等待 AI。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer();if model.activity?.current?.freshRequired != true{Button("直接开始"){model.useLocal()}.buttonStyle(.borderedProminent).tint(accent)}
                }.padding(18).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
            } else {
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Text(task.isDialogue ? "对话开始" : task.isReply ? "情境回应":"表达任务").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if task.mode == .retell && task.material != nil {Button(model.pMaterialVisible ? "隐藏原文" : "显示原文"){model.togglePracticeMaterial()}.buttonStyle(.borderless).font(.caption)}
                        if task.method == nil {Button {model.speak(task.prompt)} label: {Image(systemName:"speaker.wave.2")}.buttonStyle(.borderless).help("朗读题目")}
                    }
                    Text(task.prompt).font(.system(size:19,weight:.medium)).textSelection(.enabled)
                    if let source=task.sourceLabel {Text(source).font(.caption).foregroundStyle(.secondary)}
                    if let material=task.material,model.pMaterialVisible {
                        Text(task.method == .cloze ? "带空缺的原文" : task.method == .rebuild ? (task.referenceVisible ? "原表达" : "意思提示") : task.mode == .retell ? "阅读材料" : task.mode == .rephrase ? "原表达" : "话题").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(material).font(.system(size:15)).lineSpacing(4).textSelection(.enabled)
                            .padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:7))
                    }
                    if let original=task.reference,task.method != nil {
                        if model.pSubmitted || task.referenceVisible {
                            if task.material != original {
                                Text("原表达 · 对照参考").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                HStack(alignment:.top){Text(original).textSelection(.enabled);Spacer(minLength:0);Button{model.speak(original)}label:{Image(systemName:"speaker.wave.2")}.buttonStyle(.borderless)}
                            }
                        } else {Button("看原文（提示）"){model.revealReference()}.buttonStyle(.borderless).font(.caption)}
                    }
                    if let e=model.pCurrent,task.method == nil {
                        if model.pHint {
                            HStack {Text(e.target).font(.title3.weight(.semibold)).foregroundStyle(accent);Button{model.speak(e.target)}label:{Image(systemName:"speaker.wave.2")}.buttonStyle(.borderless)}
                            if !e.intent.isEmpty {Text(e.intent).font(.caption).foregroundStyle(.secondary)}
                        } else if !model.pSubmitted {Button("给我提示"){model.revealPracticeHint()}.buttonStyle(.borderless)}
                    }
                    if let clue=task.clue {
                        if task.method != .cloze || model.pSubmitted || model.pHint {
                            Text("本轮可以尝试：\(clue.focus)").font(.caption).foregroundStyle(accent)
                        } else {
                            Text("在新语境中练习之前的\(task.functional?.title ?? "虚词")用法").font(.caption).foregroundStyle(accent)
                        }
                    }
                    if let unit=model.currentKnowledgeUnit {
                        if model.pHint && !model.pSubmitted {
                            if model.isFocusedActivity{DisclosureGroup("查看知识说明和例句"){KnowledgeExplanation(unit:unit,compact:true).padding(.top,8)}.font(.subheadline)}
                            else{KnowledgeExplanation(unit:unit,compact:true)}
                        } else if model.pSubmitted {
                            DisclosureGroup("本轮知识点 · "+unit.title){KnowledgeExplanation(unit:unit,compact:false).padding(.top,8)}
                        } else {
                            Button("先了解这个知识点（提示）"){model.revealPracticeHint()}.buttonStyle(.borderless).foregroundStyle(accent)
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
                if let prior=model.pPrevious {
                    DisclosureGroup("上一次表达与反馈") {
                        VStack(alignment:.leading,spacing:8) {Text(prior.answer).textSelection(.enabled);if !prior.feedback.isEmpty {ReadableAnswer(text:prior.feedback)}}.padding(.top,8)
                    }.font(.subheadline)
                }
                if !model.pSubmitted && !model.pDialogue.isEmpty {
                    VStack(alignment:.leading,spacing:10) {
                        ForEach(model.pDialogue) {turn in
                            VStack(alignment:.leading,spacing:4) {
                                HStack {Text(turn.speaker).font(.caption.weight(.semibold)).foregroundStyle(turn.speaker=="你" ? accent : .secondary)
                                    if turn.speaker != "你" {Button {model.speak(turn.text)} label:{Image(systemName:"speaker.wave.2")}.buttonStyle(.borderless)} }
                                Text(turn.text).font(.system(size:15)).textSelection(.enabled)
                            }.padding(11).frame(maxWidth:.infinity,alignment:.leading).background(turn.speaker=="你" ? accent.opacity(0.08):Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                }
                if !model.pSubmitted {
                    if !task.isDialogue {
                        Text(task.isReply ? "你的回应" : "你的英语表达").font(.headline)
                        ZStack(alignment:.topLeading) {
                            if model.pAnswer.isEmpty {Text("说一段，或直接输入英语…").foregroundStyle(.secondary).padding(.horizontal,8).padding(.top,9)}
                            TextEditor(text:$model.pAnswer).font(.system(size:15)).scrollContentBackground(.hidden).frame(minHeight:100,maxHeight:140).padding(3)
                        }.background(.background,in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).stroke(Color.secondary.opacity(0.25)))
                    }
                    if task.isDialogue,!model.pDialogue.isEmpty,!cleanText(model.pAnswer).isEmpty{Text("提交或清空当前回应后，可回顾对话。").font(.caption).foregroundStyle(.secondary)}
                    if !model.voice.message.isEmpty {Text(model.voice.message).font(.caption).foregroundStyle(.secondary)}
                } else if let record=model.currentPracticeRecord {
                    PracticeAnswerBlock(model:model,record:record)
                }
                if model.pFeedbackWaiting {
                    HStack {ProgressView().controlSize(.small);Text(model.pStatus).font(.caption).foregroundStyle(.secondary);Spacer()}
                } else if model.pSubmitted {
                    feedbackPanel
                } else if !model.pStatus.isEmpty {Text(model.pStatus).font(.caption).foregroundStyle(.secondary)}
                if !model.pFeedbackWaiting {
                    HStack {Spacer();Button("在 Codex 继续聊"){model.continuePracticeInCodex()}.buttonStyle(.borderless).font(.caption).disabled(model.handoffBusy)}
                }
            }
        }
    }
    private var feedbackPanel:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text("这次表达").font(.headline);Spacer();if let source=model.pFeedbackSource {Text(source).font(.caption2).foregroundStyle(.secondary)}}
            if let f=model.pFeedbackDetail {
                Text(f.summary).font(.subheadline.weight(.medium)).textSelection(.enabled)
                if model.pTask?.knowledge != nil {
                    if let evidence=model.currentKnowledgeObservation {
                        VStack(alignment:.leading,spacing:5) {
                            if let reason=evidence.reason {Text(reason).font(.subheadline).textSelection(.enabled)}
                            if let quote=evidence.quote {Text(quote).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                        }
                    } else {Text("本轮尚无可验证的知识证据，保留原答与反馈。").font(.caption).foregroundStyle(.secondary)}
                }
                if !model.pStatus.isEmpty {Text(model.pStatus).font(.caption).foregroundStyle(.secondary)}
                if let quote=model.practiceTargetQuote{Text(quote).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                if let improvement=f.improvement,!cleanText(improvement).isEmpty {Text("可以更好").font(.caption.weight(.semibold)).foregroundStyle(.secondary);Text(improvement).textSelection(.enabled)}
                if let example=f.example,!cleanText(example).isEmpty {HStack(alignment:.top){Text(example).font(.system(size:15)).textSelection(.enabled);Spacer(minLength:0);Button{model.speak(example)}label:{Image(systemName:"speaker.wave.2")}.buttonStyle(.borderless)}}
                if let suggestion=f.suggestion {
                    HStack {VStack(alignment:.leading,spacing:3){Text(suggestion.expression).font(.subheadline.weight(.semibold));Text(suggestion.meaning).font(.caption).foregroundStyle(.secondary)};Spacer();Button(model.pSavedSuggestion ? "已收藏" : "收藏表达"){model.savePracticeSuggestion()}.disabled(model.pSavedSuggestion)}
                        .padding(10).background(.background,in:RoundedRectangle(cornerRadius:7))
                }
                if let clue=f.clue {Text("练习线索：\(clue.focus)").font(.caption).foregroundStyle(accent)}
            } else {
                if !model.pFeedback.isEmpty{ReadableAnswer(text:model.pFeedback)}
                else{Text(model.pStatus.isEmpty ? "原答已保存。" : model.pStatus).font(.subheadline).foregroundStyle(.secondary)}
            }
            HStack {
                if model.pFeedback.isEmpty {Button("重新获取反馈"){model.requestFeedback()}.disabled(cleanText(model.savedPracticeAnswer).isEmpty)}
                Button("再说一次"){model.retryPractice()}
                if model.pFeedbackDetail?.clue != nil {Button("练一下这个"){model.practiceClue()}.buttonStyle(.borderedProminent).tint(accent)}
                Spacer()
                if let id=model.activity?.current?.attempt?.id{Button("查看原答记录"){model.openPracticeRecord(id)}.buttonStyle(.borderless)}
            }
            if let record=model.currentPracticeRecord{FeedbackDiscussionPanel(model:model,record:record)}
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(accent.opacity(0.07),in:RoundedRectangle(cornerRadius:11))
    }
}

struct KnowledgeExplanation:View {
    let unit:KnowledgeUnit
    var compact=false
    var showTitle=true
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if showTitle{Text(unit.title).font(.headline).foregroundStyle(accent)}
            Text(unit.explanation).font(.subheadline).textSelection(.enabled)
            ForEach(Array(unit.examples.prefix(compact ? 2 : 4))){example in
                VStack(alignment:.leading,spacing:4){
                    Text(example.text).font(.system(size:15,weight:.medium)).textSelection(.enabled)
                    Text(example.meaning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(9).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:6))
            }
            if !unit.notes.isEmpty {ForEach(unit.notes,id:\.self){Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}}
            if !compact {
                DisclosureGroup("资料来源") {
                    ForEach(unit.sources){s in
                        VStack(alignment:.leading,spacing:3) {
                            if let url=URL(string:s.url),url.scheme=="https" {Link(s.title,destination:url)}
                            else {Text(s.title)}
                            if !s.locator.isEmpty {Text(s.locator).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)}
                        }.padding(.bottom,5)
                    }.padding(.top,5)
                }.font(.caption)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct CoverageBar:View{
    let coverage:KnowledgeCoverage
    var body:some View{
        GeometryReader{g in
            if coverage.total>0{
                HStack(spacing:0){
                    segment(coverage.covered,color:accent,width:g.size.width)
                    segment(coverage.inProgress,color:accent.opacity(0.35),width:g.size.width)
                    segment(coverage.untouched,color:.secondary.opacity(0.15),width:g.size.width)
                }.clipShape(Capsule())
            }else{Capsule().fill(.quaternary)}
        }.frame(height:7).accessibilityLabel("核心训练覆盖进度")
    }
    @ViewBuilder private func segment(_ n:Int,color:Color,width:CGFloat)->some View{
        if n>0{Rectangle().fill(color).frame(width:width*CGFloat(n)/CGFloat(coverage.total))}
    }
}
struct CoverageSummary:View{
    let coverage:KnowledgeCoverage
    var compact=false
    var body:some View{
        VStack(alignment:.leading,spacing:9){
            HStack(alignment:.firstTextBaseline){
                Text("\(coverage.covered) / \(coverage.total)").font(compact ? .title3.weight(.semibold):.title2.weight(.semibold)).monospacedDigit()
                Text("知识点已覆盖").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength:0)
            }
            CoverageBar(coverage:coverage)
            ViewThatFits(in:.horizontal){
                HStack(spacing:13){legend("已覆盖",coverage.covered,accent);legend("练习中",coverage.inProgress,accent.opacity(0.35));legend("未开始",coverage.untouched,.secondary.opacity(0.35))}
                VStack(alignment:.leading,spacing:5){legend("已覆盖",coverage.covered,accent);legend("练习中",coverage.inProgress,accent.opacity(0.35));legend("未开始",coverage.untouched,.secondary.opacity(0.35))}
            }
            if !compact{
                Text("已覆盖表示完成过核心训练，不代表永久掌握；仍可以继续练习。").font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func legend(_ title:String,_ count:Int,_ color:Color)->some View{
        HStack(spacing:5){Circle().fill(color).frame(width:6,height:6);Text(title).font(.caption).foregroundStyle(.secondary);Text("\(count)").font(.caption.weight(.semibold)).monospacedDigit()}
    }
}
struct KnowledgeMapView:View{
    @ObservedObject var model:VocabModel
    let onBack:()->Void
    private var domain:KnowledgeDomain?{model.navigation.mapDomain}
    private var query:String{model.navigation.mapSearch}
    private var filtered:[KnowledgeUnit]{
        let q=keyFor(query)
        return model.knowledgeCatalog.units.filter{u in
            (domain==nil || u.domain==domain) && model.navigation.mapFilter.includes(u.coverage(model.progress(for:u))) && (q.isEmpty || keyFor(([u.title,u.objective,u.explanation]+u.intents+u.evidence.forms).joined(separator:" ")).contains(q))
        }
    }
    private var isOverview:Bool{domain==nil && cleanText(query).isEmpty && model.navigation.mapFilter == .all}
    var body:some View{
        VStack(alignment:.leading,spacing:0){
            VStack(alignment:.leading,spacing:11){
                HStack{Text("知识地图").font(.largeTitle.bold());Spacer();Button("学习空间"){onBack()}.buttonStyle(.borderless)}
                CoverageSummary(coverage:model.coverage(),compact:!isOverview)
                HStack(spacing:10){
                    Picker("领域",selection:$model.navigation.mapDomain){
                        Text("全部领域").tag(KnowledgeDomain?.none)
                        ForEach(KnowledgeDomain.allCases){d in Text(d.title).tag(Optional(d))}
                    }.labelsHidden().frame(maxWidth:195)
                    TextField("搜索知识点、用法或表达意图",text:$model.navigation.mapSearch).textFieldStyle(.roundedBorder)
                    if !query.isEmpty{Button{model.navigation.mapSearch=""}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.borderless).help("清除搜索")}
                    Picker("知识状态",selection:$model.navigation.mapFilter){ForEach(KnowledgeFilter.allCases){f in Text(f.rawValue).tag(f)}}.labelsHidden().frame(width:110)
                }
            }.padding(20)
            Divider()
            if isOverview{
                ScrollView{
                    VStack(alignment:.leading,spacing:12){
                        Text("按领域探索").font(.headline)
                        ForEach(KnowledgeDomain.allCases){d in
                            let c=model.coverage(d)
                            Button{
                                model.navigation.mapDomain=d;model.navigation.mapSelected=nil;model.navigation.scrollAnchors["map"]=nil
                            }label:{
                                HStack(alignment:.center,spacing:14){
                                    VStack(alignment:.leading,spacing:7){
                                        HStack{Text(d.title).font(.headline);Spacer();Text("\(c.covered) / \(c.total) 已覆盖").font(.caption).foregroundStyle(.secondary).monospacedDigit()}
                                        CoverageBar(coverage:c)
                                        Text("练习中 \(c.inProgress) · 未开始 \(c.untouched)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical,9).padding(.horizontal,4).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                        HStack {
                            Text("目录："+(model.knowledgeCatalog.revision ?? "核心知识 1")).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("检查更新"){model.checkKnowledgeUpdates(force:true)}.buttonStyle(.borderless).disabled(model.knowledgeUpdateChecking)
                        }
                        if !model.knowledgeUpdateStatus.isEmpty{Text(model.knowledgeUpdateStatus).font(.caption).foregroundStyle(.secondary)}
                    }.padding(22).frame(maxWidth:780,alignment:.leading).frame(maxWidth:.infinity)
                }
            }else{
                WorkspaceSplit(selected:filtered.contains{$0.id==model.navigation.mapSelected},indexWidth:212,back:{model.navigation.mapSelected=nil}){
                    ScrollView{
                        LazyVStack(alignment:.leading,spacing:4){
                            if let d=domain{
                                let c=model.coverage(d)
                                Text("\(c.covered) / \(c.total) 已覆盖 · 练习中 \(c.inProgress)").font(.caption2).foregroundStyle(.secondary).padding(.bottom,7)
                            }
                            if filtered.isEmpty{Text("没有匹配的知识点").font(.subheadline).foregroundStyle(.secondary).padding(7)}
                            ForEach(KnowledgeDomain.allCases){d in
                                let items=filtered.filter{$0.domain==d}
                                if !items.isEmpty{
                                    if domain==nil{Text(d.title).font(.caption.weight(.semibold)).foregroundStyle(accent).padding(.top,6)}
                                    ForEach(d.areas,id:\.0){area in
                                        let group=items.filter{$0.area==area.0}
                                        if !group.isEmpty{
                                            Text(area.1).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top,9)
                                            ForEach(group){u in
                                                let p=model.progress(for:u)
                                                Button{model.navigation.mapSelected=u.id}label:{
                                                    VStack(alignment:.leading,spacing:4){
                                                        Text(u.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                                        Text(u.coverage(p).rawValue).font(.caption2).foregroundStyle(.secondary)
                                                    }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                                                     .background(model.navigation.mapSelected==u.id ? accent.opacity(0.14):Color.clear,in:RoundedRectangle(cornerRadius:5)).contentShape(Rectangle())
                                                }.buttonStyle(.plain).id(u.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }.padding(12).scrollTargetLayout()
                    }.scrollPosition(id:model.scrollAnchor("map"))
                } detail:{
                    ScrollView{
                        if let unit=filtered.first(where:{$0.id==model.navigation.mapSelected}){detail(unit).padding(22).id(unit.id).onAppear{model.noteKnowledgeViewed(unit.id)}}
                        else{EmptyState(icon:"books.vertical",title:filtered.isEmpty ? "没有找到相符的知识点":"选一个知识点",detail:"从左侧的知识目录查看解释、真实例句和练习记录，或直接开始练习。").padding(20)}
                    }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                }
            }
        }.onChange(of:model.navigation.mapDomain){_,_ in
            if !filtered.contains(where:{$0.id==model.navigation.mapSelected}){model.navigation.mapSelected=nil}
        }
    }
    private func detail(_ unit:KnowledgeUnit)->some View{
        let p=model.progress(for:unit)
        return VStack(alignment:.leading,spacing:14){
            Text(unit.domain.areaTitle(unit.area)).font(.caption).foregroundStyle(.secondary)
            Text(unit.title).font(.title2.bold()).textSelection(.enabled)
            HStack{TagLabel(text:unit.coverage(p).rawValue,color:accent);Text("核心 \(unit.coreScenarios.filter{p.completedContexts.contains($0.id)}.count) / \(unit.coreScenarios.count)").font(.caption).foregroundStyle(.secondary)}
            HStack{
                Button(unit.coverage(p) == .covered ? "复练这个知识点":unit.coverage(p) == .inProgress ? "继续核心训练":"练这个知识点"){model.startKnowledge(unit)}.buttonStyle(.borderedProminent).tint(accent)
                Button(model.knowledgeDeferred.contains(unit.id) ? "恢复推荐":"少推荐"){model.toggleKnowledgeDeferred(unit)}.buttonStyle(.borderless)
            }
            KnowledgeExplanation(unit:unit,showTitle:false)
            Divider()
            Text("核心训练").font(.headline)
            ForEach(unit.coreScenarios){scenario in scenarioRow(unit:unit,scenario:scenario,completed:p.completedContexts.contains(scenario.id))}
            if !unit.extraScenarios.isEmpty{DisclosureGroup("其他复练情境（\(unit.extraScenarios.count)）"){ForEach(unit.extraScenarios){scenario in scenarioRow(unit:unit,scenario:scenario,completed:p.completedContexts.contains(scenario.id))}}.font(.subheadline)}
            let related=(unit.related ?? []).compactMap{model.knowledgeCatalog.unit($0)}
            if !related.isEmpty{Divider();Text("相关知识点").font(.headline);ForEach(related){item in Button(item.title){model.openKnowledge(item.id)}.buttonStyle(.borderless).font(.subheadline)}}
            Divider()
            Text("实际表达记录").font(.headline)
            let rows=model.records(for:unit)
            if rows.isEmpty{Text("还没有实际表达记录。").font(.caption).foregroundStyle(.secondary)}
            else{ForEach(rows){record in
                Button{model.openPracticeRecord(record.id)}label:{
                    HStack{VStack(alignment:.leading,spacing:4){Text(shortText(record.answer,140)).font(.subheadline).lineLimit(2);Text(dateText(record.time)+" · "+(record.feedback.isEmpty ? "待反馈":"已反馈")).font(.caption2).foregroundStyle(.secondary)};Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)}.padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }}
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func scenarioRow(unit:KnowledgeUnit,scenario:KnowledgeScenario,completed:Bool)->some View{
        Button{model.startKnowledge(unit,scenarioID:scenario.id)}label:{
            HStack{VStack(alignment:.leading,spacing:3){Text(scenario.context).font(.subheadline).lineLimit(2);Text(scenario.method?.title ?? (scenario.contract == .reply ? "情境回应":scenario.studioMode.title)).font(.caption2).foregroundStyle(.secondary)}
                Spacer();Image(systemName:completed ? "checkmark.circle.fill":"play.circle").foregroundStyle(accent)
            }.padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct SettingsView:View {
    @ObservedObject var model:VocabModel
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("查词和系统权限").font(.headline)
                HStack {Text("鼠标前侧键 / Ctrl + Option + V");Spacer();TagLabel(text:AXIsProcessTrusted() ? "辅助功能正常" : "辅助功能待开启",color:AXIsProcessTrusted() ? accent : .orange)}
                Button("打开辅助功能授权"){_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)}
                HStack {Text("选区失败使用局部 OCR；不询问逐次确认。");Spacer();TagLabel(text:CGPreflightScreenCaptureAccess() ? "屏幕捕获可用" : "屏幕捕获未启用")}
                Button("开启系统屏幕捕获"){_ = CGRequestScreenCaptureAccess()}
                Divider()
                Text("语言助手").font(.headline)
                Text("语言问答、出题、反馈及交流由本机 Pi 调用你选择的模型。账户在 Pi 登录，本地词典查询不发送给 AI。主动使用 AI 时会发送相应选区、词典解释、阅读/OCR 语境、题面、回答和讨论上下文。").font(.caption).foregroundStyle(.secondary)
                TextField("Pi provider（如 qoder-cn）",text:$model.aiProviderInput).textFieldStyle(.roundedBorder)
                TextField("Pi model（如 DeepSeek-Flash）",text:$model.aiModelInput).textFieldStyle(.roundedBorder)
                Picker("思考档位",selection:$model.aiEffortInput){ForEach(["off","minimal","low","medium","high","max"],id:\.self){Text($0.uppercased()).tag($0)}}.frame(maxWidth:260)
                HStack{Button("保存配置"){_ = model.saveConnections()};Button("测试 AI 连接"){model.testConnections()}}
                TextField("聊天 ID",text:$model.threadInput).textFieldStyle(.roundedBorder)
                HStack {Button("保存连接"){model.saveThread()};Button("打开完整对话"){model.assistant.open()}}
                if !model.connectionStatus.isEmpty{Text(model.connectionStatus).font(.caption).foregroundStyle(.secondary)}
                Divider()
                Text("本机语音").font(.headline)
                Text("与 OMLXVoice 共用已有本机 Whisper 服务。录音仅在你主动点击话筒时开始，转录后可编辑。").foregroundStyle(.secondary).font(.caption)
                TextField("本机语音接口",text:$model.voiceEndpointInput).textFieldStyle(.roundedBorder)
                Button("保存语音地址"){_ = model.saveConnections()}
                Divider()
                Text("数据与导出").font(.headline)
                Text("本地 SQLite · \(model.history.count) 条新查询 · \(model.legacy.count) 条旧记录 · \(model.expressions.count) 个收藏").font(.caption)
                HStack {Button("导出 Markdown"){model.export("md")};Button("导出 CSV"){model.export("csv")};Button("导出学习记录 JSON"){model.export("json")}}
                Text("JSON 包含查询、旧词表、收藏、练习与曝光记录；不含缓存、应用设置或未提交现场，不等于完整应用备份。").font(.caption).foregroundStyle(.secondary)
                Button("打开数据目录"){NSWorkspace.shared.open(Paths.support)}
                Text("旧 Vocabulary.md 不被覆盖。").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth:850,alignment:.leading)
        }
    }
}

struct EmptyState:View {
    let icon:String,title:String,detail:String
    var body:some View {
        VStack(spacing:12) {
            Image(systemName:icon).font(.system(size:39,weight:.light)).foregroundStyle(accent)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth:.infinity,minHeight:290).padding(20)
    }
}
