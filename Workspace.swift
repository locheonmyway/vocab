import Foundation

// Browsing has a different lifetime from the work being performed.
enum LibraryTab:String,Codable,CaseIterable,Identifiable {
    case practice="学习空间",map="知识地图",expressions="我的表达",history="记录",settings="设置",workbench="当前练习"
    var id:String{rawValue}
    var symbol:String {
        switch self{case .practice:return "house";case .map:return "square.grid.3x3";case .expressions:return "star";case .history:return "clock";case .settings:return "gearshape";case .workbench:return "play.circle"}
    }
}
enum RecordTab:String,Codable,CaseIterable,Identifiable {
    case lookup="查词",practice="练习"
    var id:String{rawValue}
}
enum KnowledgeFilter:String,Codable,CaseIterable,Identifiable {
    case all="全部状态",untouched="未开始",inProgress="练习中",covered="已覆盖"
    var id:String{rawValue}
    init(from decoder:Decoder)throws{self=Self(rawValue:try decoder.singleValueContainer().decode(String.self)) ?? .all}
    func includes(_ state:KnowledgeCoverageState)->Bool{
        self == .all || rawValue==state.rawValue
    }
}
struct WorkspaceNavigation:Codable {
    var tab:LibraryTab = .practice
    var lookupSearch="", expressionSearch="", practiceSearch="", mapSearch=""
    var selectedHistory:String?, selectedLegacy:String?, selectedExpression:String?, selectedAttempt:String?
    var mapDomain:KnowledgeDomain?, mapSelected:String?
    var mapFilter:KnowledgeFilter = .all
    var recordTab:RecordTab = .lookup
    var customDraft=""
    var customMode:StudioMode = .thought
    var customExpanded=false
    var scrollAnchors:[String:String]=[:]
    // Return to just the origin, without discarding browsing done elsewhere.
    mutating func restore(_ origin:Self) {
        tab=origin.tab == .workbench ? .practice : origin.tab
        switch tab {
        case .history:
            lookupSearch=origin.lookupSearch;practiceSearch=origin.practiceSearch
            selectedHistory=origin.selectedHistory;selectedLegacy=origin.selectedLegacy;selectedAttempt=origin.selectedAttempt;recordTab=origin.recordTab
        case .expressions:expressionSearch=origin.expressionSearch;selectedExpression=origin.selectedExpression
        case .map:mapSearch=origin.mapSearch;mapDomain=origin.mapDomain;mapSelected=origin.mapSelected;mapFilter=origin.mapFilter
        default:break
        }
        for key in ["lookup","practice-records","expressions","map"] where key == anchorKey {scrollAnchors[key]=origin.scrollAnchors[key]}
    }
    var anchorKey:String {
        switch tab{case .history:return recordTab == .lookup ? "lookup":"practice-records";case .expressions:return "expressions";case .map:return "map";default:return tab.rawValue}
    }
}

enum ActivityKind:String,Codable {case mixed,knowledge,review,expression,reading,custom,record,discussion}
enum ActivityPhase:String,Codable {
    case ready,preparing,replying,evaluating,review,unavailable
    var submitted:Bool{self == .evaluating || self == .review}
    var waiting:Bool{self == .replying || self == .evaluating}
}
// The scene holds only the recoverable working state. A submitted attempt in
// SQLite remains authoritative; viewing a scene never writes a new attempt.
struct ActivityScene:Codable,Identifiable {
    var task:StudioTask
    var target:Expression?
    var attempt:Practice?
    var previous:Practice?
    var feedback:StudioFeedback?
    var answer=""
    var dialogue:[StudioDialogueTurn]=[]
    var hint=false
    var phase:ActivityPhase = .ready
    var status=""
    var materialVisible=true
    var savedSuggestion=false
    var historical=false
    var presented=false
    var prepare=false
    var freshRequired=false
    var skipped=false
    var id:String{task.id}
    var hasDraft:Bool{!phase.submitted && !cleanText(answer).isEmpty && (attempt?.answer != answer || task.isDialogue)}
    var label:String{(task.retryOf == nil ? "":"重练 · ")+(task.knowledgeContext?.description ?? task.method?.title ?? task.sourceLabel ?? task.mode.title)}
    var stateLabel:String{
        if phase == .evaluating{return "已答 · 等反馈"}
        if phase == .replying{return "等待伙伴回应"}
        if phase == .unavailable{return "新情境未生成"}
        if hasDraft{return "草稿"}
        if task.isDialogue,!phase.submitted,attempt != nil{return "交流中"}
        if let attempt{return attempt.feedback.isEmpty ? "已答 · 待反馈":"有反馈"}
        if skipped{return "已跳过"}
        return "未尝试"
    }
    mutating func interrupt() {
        switch phase {
        case .preparing:
            if freshRequired {phase = .unavailable;status="新情境尚未完成，可以重试。"}
            else {task=StudioSelector.safeFallback(task);hint = hint || task.referenceVisible || (task.method == .cloze && !task.contextPrepared);phase = .ready;status="使用本地素材 · 可继续练习"}
        case .replying:phase = .ready;status="原答已保留，可以继续交流或结束回顾。"
        case .evaluating:phase = .review;status="原答已保存，可补取反馈。"
        default:break
        }
    }
}
struct LearningActivity:Codable {
    var id=UUID().uuidString
    var kind:ActivityKind
    var origin:WorkspaceNavigation
    var focusID:String? = nil
    var topic:String? = nil
    var scenes:[ActivityScene]=[]
    var index=0
    var recap=false
    var seen:Set<String>=[]
    var submittedIDs:Set<String>=[]
    var preferredMode:StudioMode?
    var focusOffered:Int?
    var steps=0
    var current:ActivityScene? {
        get {scenes.indices.contains(index) ? scenes[index]:nil}
        set {if let newValue,scenes.indices.contains(index){scenes[index]=newValue}}
    }
    var draftCount:Int{scenes.filter(\.hasDraft).count}
    var attemptedCount:Int{scenes.filter{$0.attempt != nil}.count}
    var skippedCount:Int{scenes.filter{$0.skipped && $0.attempt==nil}.count}
    var finite:Bool{kind != .mixed}
    mutating func insert(_ scene:ActivityScene) {
        let position=min(index+1,scenes.count);scenes.insert(scene,at:position);index=position
        recap=false
    }
    mutating func select(_ i:Int){guard scenes.indices.contains(i) else{return};index=i;recap=false}
}
struct WorkspaceSnapshot:Codable {
    var schemaVersion=1
    var navigation:WorkspaceNavigation
    var activity:LearningActivity?
    static func load(_ url:URL?) -> Self? {
        guard let url,let data=try? Data(contentsOf:url),
              let value=try? JSONDecoder().decode(Self.self,from:data),value.schemaVersion==1 else{return nil}
        return value
    }
    func save(_ url:URL)throws{try JSONEncoder().encode(self).write(to:url,options:.atomic)}
}

// Three mutually exclusive completion states; evidence is kept separately in
// KnowledgeProgress, not used as user-facing completion levels.
struct KnowledgeCoverage {
    var total=0,inProgress=0,covered=0
    var attempted:Int{inProgress+covered}
    var untouched:Int{max(0,total-attempted)}
    init(_ units:[KnowledgeUnit],progress:[String:KnowledgeProgress]) {
        total=units.count
        for u in units {
            switch u.coverage(progress[u.id] ?? .init()) {case .untouched:break;case .inProgress:inProgress+=1;case .covered:covered+=1}
        }
    }
}
