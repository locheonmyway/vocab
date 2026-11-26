import Foundation
import SQLite3

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vocab/V2", isDirectory: true)
    static let legacy = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Learning/Vocabulary.md")
    static func resource(_ name: String) -> URL {
        if let u = Bundle.main.url(forResource: name, withExtension: "py") { return u }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(name + ".py")
    }
}

enum SupportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

func cleanText(_ s: String) -> String {
    s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
func keyFor(_ s: String) -> String {
    cleanText(s).replacingOccurrences(of: "’", with: "'").lowercased()
}
func queryText(_ s: String) -> String {
    // Preserve the complete phrase/sentence and original in history.
    // Remove surrounding quotation marks and punctuation on isolated words.
    var clean = cleanText(s)
    // Only strip a script speaker prefix when the selection has the known
    // transcript end marker; the original selection remains in history.
    if clean.range(of:"\\s*\\^u[0-9a-fA-F]{4}$",options:.regularExpression) != nil {
        clean=clean.replacingOccurrences(of:"\\s*\\^u[0-9a-fA-F]{4}$",with:"",options:.regularExpression)
        clean=clean.replacingOccurrences(of:"^[A-Za-z][A-Za-z .'-]{0,24}[:：]\\s*",with:"",options:.regularExpression)
    }
    let unquoted = clean.trimmingCharacters(in:CharacterSet(charactersIn:"“”\"‘’«»"))
    if unquoted.split(separator:" ").count == 1 {
        return unquoted.trimmingCharacters(in:CharacterSet(charactersIn:",.;:!?()[]{}"))
    }
    return unquoted.trimmingCharacters(in:CharacterSet(charactersIn:",;"))
}
func shortText(_ s: String, _ n: Int = 180) -> String {
    s.count <= n ? s : String(s.prefix(n)) + "…"
}

enum ExpressionKind: String, Codable, CaseIterable, Identifiable {
    case word = "单词", collocation = "搭配", phrase = "固定表达", pattern = "句式", sentence = "整句"
    var id: String { rawValue }
    static func infer(_ text: String) -> Self {
        let words = cleanText(text).split(separator: " ")
        if words.count <= 1 { return .word }
        if text.contains("…") || text.contains(" X ") || text.contains(" Y") || text.contains("[") { return .pattern }
        if words.count > 6 || text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") { return .sentence }
        return .phrase
    }
}

struct BookContext: Codable, Equatable {
    var assetID: String?
    var title: String
    var author: String
    var evidence: String
    var progress: Double?
    var context: String?
    var chapter: String?
    var location: String?
    var highlightID: String?
    var recordKind: String?
    var label: String { evidence == "windowTitle" ? title : "可能正在读：\(title)" }
    var contextLabel: String {
        recordKind == "existingHighlight" ? "曾高亮的匹配原文（非当前页证明）" : "书中唯一文字匹配（非当前页证明）"
    }
}

struct DictionaryMeaning: Codable, Equatable {
    var definition: String
    var qualifiers: [String]
    var examples: [String]
    var synonymGroups: [String]
    var antonyms: [String]
    var subordinate: Bool
}
struct DictionarySense: Codable, Equatable {
    var number: Int
    var meanings: [DictionaryMeaning]
}
struct DictionaryGrammar: Codable, Equatable {
    var partOfSpeech: String
    var senses: [DictionarySense]
}
struct DictionaryNoteItem: Codable, Equatable {
    var heading: String
    var text: String
}
struct DictionaryNote: Codable, Equatable {
    var title: String
    var items: [DictionaryNoteItem]
}
struct DictionaryContent: Codable, Equatable {
    var groups: [DictionaryGrammar]
    var sections: [DictionaryNote]
}
struct DictionaryPronunciation: Codable, Equatable {
    var ipa: String
    var term: String
    var dialect: String
    var source: String
    var derived: Bool? = nil
}

struct DictionarySupplement: Codable, Equatable {
    var source: String
    var detail: String
    var content: DictionaryContent? = nil
}

struct Definition: Codable, Equatable {
    var term: String
    var matched: String
    var body: String
    var detail: String
    var phonetic: String = ""
    var example: String? = nil
    var source: String
    var match: String  // exact, inflected, partial, none
    var supplement: DictionarySupplement? = nil
    var content: DictionaryContent? = nil
    var chinese: DictionarySupplement? = nil
    var pronunciations: [DictionaryPronunciation]? = nil
    var fetched: Double = Date().timeIntervalSince1970
    var valid: Bool { match != "none" }
    var complete: Bool { match == "exact" || match == "inflected" }
    var preferredPronunciations: [DictionaryPronunciation] {
        let items = pronunciations ?? []
        let actual = items.filter { keyFor($0.term)==keyFor(term) && $0.derived != true }
        let derived = items.filter { keyFor($0.term)==keyFor(term) && $0.derived == true }
        let base = items.filter { keyFor($0.term)==keyFor(matched) && $0.derived != true }
        let candidates = !actual.isEmpty ? actual : !derived.isEmpty ? derived : base
        // The lookup source order is ODE, bilingual Oxford, then Writer's.
        // Don't mix variants from conflicting sources or mislabel a stem.
        if let first = candidates.first {
            let sameSource = candidates.filter {$0.source==first.source}
            let british = sameSource.filter {$0.dialect != "AmE"}
            var seen=Set<String>()
            return Array((british.isEmpty ? sameSource : british).filter {seen.insert($0.ipa).inserted}.prefix(2))
        }
        let legacy=phonetic.trimmingCharacters(in:CharacterSet(charactersIn:"/ "))
        guard !legacy.isEmpty, pronunciations == nil else {return []}
        return [DictionaryPronunciation(ipa:legacy,term:match=="inflected" ? matched : term,dialect:"",source:source)]
    }
}
struct LookupRecord: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var time = Date().timeIntervalSince1970
    var original: String
    var query: String
    var application: String
    var appID: String
    var capture: String
    var definition: Definition?
    var book: BookContext?
    var visibleContext: String? = nil
    var state: String = "pending"
    var savedExplanations: [SavedExplanation]? = nil
    var related: [RelatedDictionaryEntry]? = nil
    var bookIssue:String? = nil
}
struct RelatedDictionaryEntry:Codable,Equatable,Identifiable {
    var head:String
    var label:String
    var text:String
    var source:String
    var id:String{source+"|"+head+"|"+label}
}
enum DictionaryOutcome:String,Codable {case found,noMatch,unavailable,unreadable}
struct DictionaryLookup:Codable {
    var definition:Definition?
    var related:[RelatedDictionaryEntry]
    var time=Date().timeIntervalSince1970
    var failure:String? = nil
    // Optional only for decoding positive caches from older app versions.
    var outcome:DictionaryOutcome? = nil
    var status:DictionaryOutcome {outcome ?? (failure != nil ? .unreadable : definition?.complete == true ? .found:.noMatch)}
    var needsRecovery:Bool {status == .unavailable || status == .unreadable}
    var cacheable:Bool {
        guard status == .found, let d=definition,d.complete,
              ["Oxford Dictionary of English","Oxford Chinese Dictionary","Oxford American Writer’s Thesaurus"].contains(d.source) else{return false}
        return !(d.content?.groups.isEmpty ?? true) && !cleanText(d.body).isEmpty
    }
    var message:String {
        switch status {
        case .found: return "已查到"
        case .noMatch:return related.isEmpty ? "本机 Oxford 未返回完整词条；可问 AI 或重试":"未精确命中 · 下方是 Oxford 相关搭配"
        case .unavailable:return definition == nil ? "本机 Oxford 资源尚未就绪；可重试":"部分 Oxford 资源尚未就绪 · 已显示可用释义；可重试"
        case .unreadable:return failure ?? (definition == nil ? "本机词典内容暂未能读取；可重试":"部分词典内容暂未能读取 · 已显示可用释义；可重试")
        }
    }
}
struct SavedExplanation: Codable, Equatable {
    var question: String
    var answer: String
    var time: Double
    var turn: String?
    var source: String? = nil
}
struct LegacyRow: Codable, Identifiable {
    var id: String
    var term: String
    var phonetic: String
    var definition: String
    var synonyms: String
    var count: Int
    var date: String
    var source: String
    var originalLine: String
}
enum LearningState: String, Codable {
    case pending = "待练习", learning = "正在练习", independent = "练习中独立使用", paused = "已暂停"
}
struct Expression: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var original: String
    var target: String
    var kind: ExpressionKind
    var intent: String
    var definition: String
    var source: String
    var book: BookContext?
    var lookupIDs: [String] = []
    var created = Date().timeIntervalSince1970
    var modified = Date().timeIntervalSince1970
    var learning: LearningState = .pending
    var stage = 0
    var due: Double? = nil
    var successes = 0
    var previousQuestion: String? = nil
    var notes = ""
    var example: String? = nil
    var studyMeaning:String? = nil
    var studyMeaningSource:String? = nil
    var intervalDays:Double? = nil
    var knowledgeID:String? = nil
    var identity: String { keyFor(target) + "|" + keyFor(intent) }
}
enum PracticeRating: String, Codable, CaseIterable, Identifiable {
    case missed = "没想起来", assisted = "借助提示", needsWork = "想起但需要修正"
    case independent = "独立使用", alternative = "自然替代表达", skipped = "跳过"
    case completed = "已表达", unassessed = "已记录，未评估"
    var id: String { rawValue }
}
struct Practice: Codable, Identifiable {
    var id = UUID().uuidString
    var expressionID: String?
    var time = Date().timeIntervalSince1970
    var mode: String
    var stage: Int
    var question: String
    var answer: String
    var hint: Bool
    var feedback: String
    var assistantTurn: String?
    var rating: PracticeRating
    var next: Double?
    var feedbackSource: String? = nil
    var taskID: String? = nil
    var taskKey: String? = nil
    var material: String? = nil
    var dialogue: [StudioDialogueTurn]? = nil
    var retryOf: String? = nil
    var clue: PracticeClue? = nil
    var focusKey: String? = nil
    var focus: PracticeClue? = nil
    var contextPrepared: Bool? = nil
    var focusImproved: Bool? = nil
    var focusQuote: String? = nil
    var targetQuote: String? = nil
    var targetText: String? = nil
    var targetIntent: String? = nil
    var targetKind: ExpressionKind? = nil
    var learningVersion:Int? = nil
    var method:PracticeMethod? = nil
    var reference:String? = nil
    var sourceLabel:String? = nil
    var functional:FunctionalFocus? = nil
    var lookupID:String? = nil
    var referenceVisible:Bool? = nil
    var knowledge:KnowledgeTarget? = nil
    var knowledgeContext:KnowledgeContext? = nil
    var knowledgeSession:String? = nil
    var knowledgeObservation:KnowledgeObservation? = nil
    var interaction:InteractionContract? = nil
    var completedAt:Double? = nil
    var answerRaw:String? = nil
    var dialogueRaw:[StudioDialogueTurn]? = nil
    var answerRevision:Int? = nil
    var correctedAt:Double? = nil
    var scheduleReceipt:ScheduleReceipt? = nil
    var scheduleBlocked:Bool? = nil
    var feedbackDiscussion:[FeedbackExchange]? = nil
    var reviewingCovered:Bool? = nil
    var revision:Int{answerRevision ?? 0}
    var isDialogue:Bool{(interaction ?? (mode == StudioMode.respond.rawValue ? .dialogue:.expression)) == .dialogue}
    var completed:Bool{
        guard !cleanText(answer).isEmpty else{return false}
        if completedAt != nil{return true}
        guard (learningVersion ?? 0)<4 else{return false}
        if !isDialogue{return true}
        return !feedback.isEmpty && (dialogue?.contains{$0.speaker != "你"} ?? false)
    }
    mutating func invalidateEvaluation(){
        feedback="";feedbackSource=nil;assistantTurn=nil;rating = .unassessed;next=nil
        targetQuote=nil;clue=nil;knowledgeObservation=nil;focusImproved=nil;focusQuote=nil
    }
}

struct FeedbackExchange:Codable,Identifiable,Equatable {
    var id=UUID().uuidString
    var revision:Int
    var question:String
    var answer:String
    var source:String?
}

// A receipt records only the fields actually changed by scheduling. It can be
// undone iff the same collection identity and exact resulting state still hold.
struct ScheduleState:Codable,Equatable {
    var stage:Int,successes:Int
    var due:Double?,intervalDays:Double?,modified:Double
    var learning:LearningState
    var previousQuestion:String?,knowledgeID:String?
    init(_ e:Expression){stage=e.stage;successes=e.successes;due=e.due;intervalDays=e.intervalDays;modified=e.modified;learning=e.learning;previousQuestion=e.previousQuestion;knowledgeID=e.knowledgeID}
    func matchesSchedule(_ e:Expression)->Bool{var value=ScheduleState(e);value.modified=modified;return value==self}
    func restore(_ e:Expression)->Expression{var e=e;e.stage=stage;e.successes=successes;e.due=due;e.intervalDays=intervalDays;e.modified=modified;e.learning=learning;e.previousQuestion=previousQuestion;e.knowledgeID=knowledgeID;return e}
}
struct ScheduleReceipt:Codable,Equatable {
    var revision:Int
    var identity:String
    var before:ScheduleState
    var after:ScheduleState
}

enum Scheduler {
    /// Persist only observed performance; a natural alternative is not a failed communication.
    static func apply(_ rating: PracticeRating, hinted: Bool, to old: Expression,
                      now: Double = Date().timeIntervalSince1970) -> Expression {
        var e = old
        let day: Double = 86400
        if [.skipped,.completed,.unassessed].contains(rating) { return e }
        e.modified = now
        let previous=e.intervalDays ?? max(1,((e.due ?? now+day)-old.modified)/day)
        func schedule(_ days:Double){e.intervalDays=days;e.due=now+days*day}
        if rating == .alternative {schedule(3);return e}
        switch rating {
        case .missed:
            e.stage=max(0,e.stage-1);e.learning = .learning;schedule(max(1,min(7,previous*0.3)))
        case .needsWork:
            e.stage=min(e.stage,1);e.learning = .learning;schedule(max(1,min(7,previous*0.5)))
        case .assisted:
            if e.stage==0 {e.stage=1;e.learning = .learning;schedule(1)}
            else if e.stage==1 {e.learning = .learning;schedule(max(1,min(3,previous)))}
            // A supported repeat is useful, but must not erase stronger past evidence.
            else if (e.due ?? 0)<=now {schedule(max(3,min(14,previous)))}
        case .alternative: break
        case .independent:
            if hinted || e.stage == 0 {
                if e.stage==0 {e.stage=1;e.learning = .learning;schedule(1)}
                else if e.stage==1 {e.learning = .learning;schedule(1)}
            } else {
                e.stage = 2
                e.successes += 1
                schedule(e.successes==1 ? 3 : min(180,max(3,previous*2)))
                e.learning = .independent
            }
        case .skipped, .completed, .unassessed: break
        }
        return e
    }
    static func queue(_ items: [Expression], now: Double = Date().timeIntervalSince1970) -> [Expression] {
        let ready = items.filter { $0.learning != .paused && ($0.due ?? 0) <= now }
        let review = ready.filter { $0.learning != .pending }.sorted { ($0.due ?? 0) < ($1.due ?? 0) }
        let fresh = ready.filter { $0.learning == .pending }.sorted { $0.created < $1.created }
        var result: [Expression] = []
        var i = 0, j = 0
        while i < review.count || j < fresh.count {
            for _ in 0..<2 where i < review.count { result.append(review[i]); i += 1 }
            if j < fresh.count { result.append(fresh[j]); j += 1 }
        }
        return result
    }
}

final class Store {
    private let db: OpaquePointer
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { throw SupportError.message("无法打开词汇数据库") }
        db = handle
        sqlite3_busy_timeout(db, 3000)
        try sql("PRAGMA journal_mode=WAL")
        try sql("CREATE TABLE IF NOT EXISTS history(id TEXT PRIMARY KEY, term TEXT, ts REAL, payload TEXT NOT NULL)")
        try sql("CREATE INDEX IF NOT EXISTS history_term ON history(term, ts)")
        try sql("CREATE TABLE IF NOT EXISTS legacy(id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        try sql("CREATE TABLE IF NOT EXISTS expressions(id TEXT PRIMARY KEY, identity TEXT UNIQUE, updated REAL, payload TEXT NOT NULL)")
        try sql("CREATE TABLE IF NOT EXISTS practice(id TEXT PRIMARY KEY, expr TEXT, ts REAL, payload TEXT NOT NULL)")
        try sql("CREATE INDEX IF NOT EXISTS practice_ts ON practice(ts)")
        try sql("CREATE TABLE IF NOT EXISTS practice_exposure(id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        try sql("CREATE TABLE IF NOT EXISTS dictionary_cache(id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        try sql("CREATE TABLE IF NOT EXISTS assistant_links(id TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }
    deinit { sqlite3_close(db) }

    private func error() -> SupportError {
        SupportError.message(String(cString: sqlite3_errmsg(db)))
    }
    private func statement(_ text: String, _ params: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, text, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        for (i, p) in params.enumerated() {
            if sqlite3_bind_text(stmt, Int32(i + 1), p, -1, transient) != SQLITE_OK {
                sqlite3_finalize(stmt); throw error()
            }
        }
        return stmt
    }
    private func sql(_ text: String, _ params: [String] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement(text, params); defer { sqlite3_finalize(s) }
        let code = sqlite3_step(s)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error() }
    }
    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func fetch<T: Decodable>(_ text: String, _ params: [String] = [], _ type: T.Type) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement(text, params); defer { sqlite3_finalize(s) }
        var values: [T] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error() }
            if let ptr = sqlite3_column_text(s, 0) {
                let data = Data(String(cString: ptr).utf8)
                values.append(try decoder.decode(type, from: data))
            }
        }
        return values
    }
    func importLegacy(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        lock.lock(); defer { lock.unlock() }
        try sql("BEGIN IMMEDIATE")
        do {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                guard line.hasPrefix("|") else { continue }
                let parts = line.components(separatedBy: "|").dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 7, let count = Int(parts[4]), !parts[0].isEmpty else { continue }
                let row = LegacyRow(id: keyFor(parts[0]), term: parts[0], phonetic: parts[1],
                                    definition: parts[2], synonyms: parts[3], count: count,
                                    date: parts[5], source: parts[6], originalLine: line)
                try sql("INSERT OR REPLACE INTO legacy(id,payload) VALUES(?,?)", [row.id, try json(row)])
            }
            try sql("COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
    }
    func legacyRows() throws -> [LegacyRow] {
        try fetch("SELECT payload FROM legacy ORDER BY id", [], LegacyRow.self)
    }
    func put(_ r: LookupRecord) throws {
        try sql("INSERT OR REPLACE INTO history(id,term,ts,payload) VALUES(?,?,?,?)",
                [r.id, keyFor(r.query), String(r.time), try json(r)])
    }
    func history() throws -> [LookupRecord] {
        try fetch("SELECT payload FROM history ORDER BY ts DESC", [], LookupRecord.self)
    }
    func record(_ id:String)throws->LookupRecord? {
        try fetch("SELECT payload FROM history WHERE id=?",[id],LookupRecord.self).first
    }
    func cachedDictionary(_ term:String)throws->DictionaryLookup? {
        // A miss, even when healthy, is never persistent evidence of absence.
        // Only reuse a valid positive entry with the selected Oxford source.
        for version in ["v5:","v4:","v3:"] {
            if let result=try? fetch("SELECT payload FROM dictionary_cache WHERE id=?",[version+keyFor(term)],DictionaryLookup.self).first,
               result.cacheable,Date().timeIntervalSince1970-result.time < 14*86400{return result}
        }
        return nil
    }
    func putDictionary(_ term:String,_ result:DictionaryLookup)throws {
        guard result.cacheable else{return}
        try sql("INSERT OR REPLACE INTO dictionary_cache(id,payload) VALUES(?,?)",["v5:"+keyFor(term),try json(result)])
    }
    func encounters(for term: String) throws -> ([LookupRecord], LegacyRow?) {
        let k = keyFor(term)
        let h = try fetch("SELECT payload FROM history WHERE term=? ORDER BY ts DESC", [k], LookupRecord.self)
        let l = try fetch("SELECT payload FROM legacy WHERE id=?", [k], LegacyRow.self).first
        return (h,l)
    }
    func removeHistory(_ id: String) throws { try sql("DELETE FROM history WHERE id=?", [id]) }
    func allExpressions() throws -> [Expression] {
        try fetch("SELECT payload FROM expressions ORDER BY updated DESC", [], Expression.self)
    }
    @discardableResult
    func saveExpression(_ new: Expression) throws -> Expression {
        lock.lock(); defer { lock.unlock() }
        let existing = try fetch("SELECT payload FROM expressions WHERE identity=?",
                                 [new.identity], Expression.self).first
        var value = new
        if var e = existing, e.id != new.id {
            if !(try fetch("SELECT payload FROM expressions WHERE id=?", [new.id], Expression.self)).isEmpty {
                throw SupportError.message("已有相同的学习表达与意图，请保留或调整其中一个。")
            }
            for id in new.lookupIDs where !e.lookupIDs.contains(id) { e.lookupIDs.append(id) }
            e.modified = Date().timeIntervalSince1970
            if e.book == nil { e.book = new.book }
            value = e
        }
        try sql("INSERT INTO expressions(id,identity,updated,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET identity=excluded.identity,updated=excluded.updated,payload=excluded.payload",
                [value.id, value.identity, String(value.modified), try json(value)])
        return value
    }
    func removeExpression(_ id: String) throws { try sql("DELETE FROM expressions WHERE id=?", [id]) }
    func putPractice(_ p: Practice, expression: Expression? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try sql("BEGIN IMMEDIATE")
        do {
            try sql("INSERT INTO practice(id,expr,ts,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,expr=excluded.expr,ts=excluded.ts", [p.id, p.expressionID ?? "", String(p.time), try json(p)])
            if let expression {try saveExpression(expression)}
            try sql("COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
    }
    func practices(_ id: String? = nil) throws -> [Practice] {
        if let id { return try fetch("SELECT payload FROM practice WHERE expr=? ORDER BY ts DESC",[id],Practice.self) }
        return try fetch("SELECT payload FROM practice ORDER BY ts DESC", [], Practice.self)
    }
    func recentPractices(limit:Int=60) throws -> [Practice] {
        try fetch("SELECT payload FROM practice WHERE length(trim(coalesce(json_extract(payload,'$.answer'),'')))>0 ORDER BY ts DESC LIMIT ?",[String(limit)],Practice.self)
    }
    func practice(_ id:String)throws->Practice?{
        try fetch("SELECT payload FROM practice WHERE id=?",[id],Practice.self).first
    }
    func knowledgePractices()throws->[Practice] {
        try fetch("SELECT payload FROM practice WHERE json_extract(payload,'$.knowledge.id') IS NOT NULL AND json_extract(payload,'$.learningVersion')>=3 ORDER BY ts DESC",[],Practice.self)
    }
    func completedTaskCounts()throws->(all:Int,target:Int) {
        // Pre-redesign trial history remains available, but does not establish
        // future practice balance or personal skill assumptions.
        struct Counts:Decodable{var all:Int;var target:Int}
        let sqlText="""
        SELECT json_object('all',count(DISTINCT coalesce(json_extract(payload,'$.taskID'),id)),
        'target',count(DISTINCT CASE WHEN expr!='' AND expr IS NOT NULL AND coalesce(json_extract(payload,'$.method'),'')!='cloze' THEN coalesce(json_extract(payload,'$.taskID'),id) END))
        FROM practice WHERE json_extract(payload,'$.learningVersion')>=2 AND length(trim(coalesce(json_extract(payload,'$.answer'),'')))>0 AND json_extract(payload,'$.retryOf') IS NULL
        AND coalesce(json_extract(payload,'$.taskKey'),'') NOT LIKE 'discussion:%'
        AND (json_extract(payload,'$.learningVersion')<4 OR json_extract(payload,'$.completedAt') IS NOT NULL)
        """
        let result=try fetch(sqlText,[],Counts.self).first;return (result?.all ?? 0,result?.target ?? 0)
    }
    func exposures() throws -> [String:PracticeExposure] {
        let values=try fetch("SELECT payload FROM practice_exposure",[],PracticeExposure.self)
        return Dictionary(uniqueKeysWithValues:values.map{($0.key,$0)})
    }
    @discardableResult func recordExposure(_ key:String, now:Double=Date().timeIntervalSince1970) throws -> PracticeExposure {
        lock.lock(); defer{lock.unlock()}
        let prior=try fetch("SELECT payload FROM practice_exposure WHERE id=?",[key],PracticeExposure.self).first
        let next=PracticeExposure(key:key,time:now,count:(prior?.count ?? 0)+1)
        try sql("INSERT OR REPLACE INTO practice_exposure(id,payload) VALUES(?,?)",[key,try json(next)])
        return next
    }
    func link(_ request: String, _ value: String) throws {
        try sql("INSERT OR REPLACE INTO assistant_links(id,value) VALUES(?,?)",[request,value])
    }
    func exportJSON() throws -> Data {
        struct Export: Codable { var format = "Vocab V2"; var history: [LookupRecord]; var legacy: [LegacyRow]; var expressions: [Expression]; var practice: [Practice];var practiceExposures:[PracticeExposure] }
        let out = Export(history: try history(), legacy: try legacyRows(), expressions: try allExpressions(), practice: try practices(),practiceExposures:try exposures().values.sorted{$0.key<$1.key})
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try enc.encode(out)
    }
    func exportMarkdown() throws -> String {
        func esc(_ s: String) -> String { cleanText(s).replacingOccurrences(of: "|", with: "｜") }
        var out = "# Vocab · 个人表达与查词历史\n\n## 我的表达\n\n| 表达 | 类型 | 目标/使用意图 | 状态 | 来源 |\n|---|---|---|---|---|\n"
        for e in try allExpressions() {
            out += "| \(esc(e.target)) | \(e.kind.rawValue) | \(esc(e.intent.isEmpty ? e.definition : e.intent)) | \(e.learning.rawValue) | \(esc(e.source)) |\n"
        }
        out += "\n## 查询历史\n\n| 查询 | 释义 | 来源 | 日期 |\n|---|---|---|---|\n"
        for h in try history() { out += "| \(esc(h.original)) | \(esc(h.definition?.body ?? h.state)) | \(esc(h.book?.label ?? h.application)) | \(dateText(h.time)) |\n" }
        out += "\n## 旧表历史（原日期精度与次数）\n\n| 词 | 音标 | 释义 | 同义词 | 次数 | 日期 | 来源 |\n|---|---|---|---|---|---|---|\n"
        for l in try legacyRows() { out += l.originalLine + "\n" }
        return out
    }
    func exportCSV() throws -> String {
        func row(_ v:[String]) -> String { v.map { "\"" + $0.replacingOccurrences(of:"\"",with:"\"\"") + "\"" }.joined(separator:",") + "\n" }
        var csv = row(["类型","表达或查询","释义/意图","状态或次数","时间","来源","原文"])
        for h in try history() { csv += row(["查询",h.query,h.definition?.detail ?? "",h.state,dateText(h.time),h.book?.label ?? h.application,h.original]) }
        for l in try legacyRows() { csv += row(["旧历史",l.term,l.definition,String(l.count),l.date,l.source,l.originalLine]) }
        for e in try allExpressions() { csv += row(["学习表达",e.target,e.intent,e.learning.rawValue,dateText(e.created),e.source,e.original]) }
        return csv
    }
}

func dateText(_ time: Double) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: time))
}

enum LocalProcess {
    enum Outcome {case data(Data),timeout,failed}
    // Spool output to a private temp file: neither a stuck child nor a full
    // stdout pipe may block the UI or an unbounded read to EOF.
    static func run(_ executable:URL,arguments:[String],input:Data?=nil,timeout:Double)->Outcome {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-helper-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]),let output=try? FileHandle(forWritingTo:url) else{return .failed}
        defer{try? output.close();try? FileManager.default.removeItem(at:url)}
        let p=Process();p.executableURL=executable;p.arguments=arguments;p.standardOutput=output;p.standardError=FileHandle.nullDevice
        let stdin=Pipe();p.standardInput=input==nil ? FileHandle.nullDevice as Any:stdin as Any
        let ended=DispatchSemaphore(value:0);p.terminationHandler={_ in ended.signal()}
        do{try p.run();if let input{try stdin.fileHandleForWriting.write(contentsOf:input);try stdin.fileHandleForWriting.close()}}
        catch{if p.isRunning{p.terminate()};return .failed}
        if ended.wait(timeout:.now()+timeout) == .timedOut {
            if p.isRunning{p.terminate()}
            if ended.wait(timeout:.now()+0.5) == .timedOut,p.isRunning{kill(p.processIdentifier,SIGKILL);_ = ended.wait(timeout:.now()+0.5)}
            return .timeout
        }
        if p.terminationStatus==124{return .timeout}
        guard p.terminationStatus==0,let data=try? Data(contentsOf:url) else{return .failed}
        return .data(data)
    }
}

enum DictionaryEngine {
    private enum HelperState:String,Decodable {case ready,unavailable,unreadable}
    private struct SourceState:Decodable {
        var identifier,state,result:String
        var assetPresent:Bool
        var recordCount,parseFailures:Int
    }
    private struct Envelope<T:Decodable>:Decodable {
        var state:HelperState
        var results:[T]
        var sources:[SourceState]?
    }
    private struct OxfordResult: Decodable {
        var source: String
        var identifier: String
        var matched: String
        var match: String
        var body: String
        var detail: String
        var phonetic: String
        var example: String?
        var content: DictionaryContent?
        var pronunciations: [DictionaryPronunciation]?
    }
    private static func exact(_ term:String,script:URL=Paths.resource("oxford_entry"))->DictionaryLookup {
        guard !term.isEmpty,term.count<=180 else{return .init(definition:nil,related:[],outcome:.noMatch)}
        let raw:Data
        switch LocalProcess.run(URL(fileURLWithPath:"/usr/bin/python3"),arguments:[script.path,term],timeout:6){
        case .timeout:return .init(definition:nil,related:[],failure:"本地词典查询超时；可重试",outcome:.unreadable)
        case .failed:return .init(definition:nil,related:[],failure:"本地词典暂时读取失败；可重试",outcome:.unreadable)
        case .data(let data):raw=data
        }
        guard let envelope=try? JSONDecoder().decode(Envelope<OxfordResult>.self,from:raw) else{return .init(definition:nil,related:[],failure:"本地词典返回内容异常；可重试",outcome:.unreadable)}
        let diagnostic=(envelope.sources ?? []).map{"\($0.identifier):\($0.state)/\($0.assetPresent ? "local":"absent")/\($0.recordCount)/\($0.parseFailures)/\($0.result)"}.joined(separator:",")
        NSLog("Vocab dictionary stage=exact chars=%d state=%@ sources=%@",term.count,envelope.state.rawValue,diagnostic)
        let ordered = ["com.apple.dictionary.ODE","com.apple.dictionary.zh_CN-en.OCD","com.apple.dictionary.OAWT"]
            .compactMap { id in envelope.results.first(where:{$0.identifier==id}) }
        let usable = ordered.filter { ["exact","inflected"].contains($0.match) && !cleanText($0.body).isEmpty }
        let state:DictionaryOutcome = envelope.state == .unavailable ? .unavailable : envelope.state == .unreadable ? .unreadable : usable.isEmpty ? .noMatch:.found
        guard let primary=usable.first else {return .init(definition:nil,related:[],outcome:state)}
        let writer = usable.first(where: {$0.identifier == "com.apple.dictionary.OAWT"})
        let chinese = usable.first(where: {$0.identifier == "com.apple.dictionary.zh_CN-en.OCD"})
        var definition = Definition(term:term, matched:primary.matched,
                          body:shortText(primary.body, 380), detail:primary.detail,
                          phonetic: primary.phonetic, example:primary.example, source:primary.source,
                          match:primary.match,
                          supplement:writer.map {DictionarySupplement(source:$0.source, detail:$0.detail,content:$0.content)},
                          content:primary.content,
                          chinese:chinese.map {DictionarySupplement(source:$0.source,detail:$0.detail,content:$0.content)},
                          pronunciations:ordered.flatMap{$0.pronunciations ?? []})
        definition.phonetic = definition.preferredPronunciations.first?.ipa ?? ""
        return .init(definition:definition,related:[],outcome:state)
    }
    static func oxford(_ term:String)->Definition?{exact(term).definition}
    static func local(_ term: String) -> Definition? {
        // Only the explicitly selected local Oxford dictionaries. The
        // user can ask the language assistant when they have no relevant entry.
        oxford(term)
    }
    static func lookup(_ term:String)->DictionaryLookup {lookup(term,script:Paths.resource("oxford_entry"))}
    // The explicit script parameter is also used by isolated end-to-end
    // resource fixtures; the installed app always uses the bundled helper.
    static func lookup(_ term:String,script:URL)->DictionaryLookup {
        let result=exact(term,script:script)
        if result.status != .noMatch{return result}
        guard term.split(separator:" ").count>1,term.count<=1000 else{return result}
        let heads=LanguageEvidence.heads(term)
        guard !heads.isEmpty else{return result}
        let args=[script.path,"--related",term,LanguageEvidence.tokens(term).map{$0.lemma}.joined(separator:" ")]+Array(heads.prefix(3))
        let raw:Data
        switch LocalProcess.run(URL(fileURLWithPath:"/usr/bin/python3"),arguments:args,timeout:6){
        case .timeout:return .init(definition:nil,related:[],failure:"相关词条查询超时；可重试",outcome:.unreadable)
        case .failed:return .init(definition:nil,related:[],failure:"相关词条暂时读取失败；可重试",outcome:.unreadable)
        case .data(let data):raw=data
        }
        guard let envelope=try? JSONDecoder().decode(Envelope<RelatedDictionaryEntry>.self,from:raw) else{return .init(definition:nil,related:[],failure:"相关词条返回内容异常；可重试",outcome:.unreadable)}
        let state:DictionaryOutcome = envelope.state == .unavailable ? .unavailable : envelope.state == .unreadable ? .unreadable:.noMatch
        return .init(definition:nil,related:envelope.results,outcome:state)
    }
}

func expressionFrom(_ r: LookupRecord) -> Expression {
    Expression(original: r.original, target: r.query, kind: .infer(r.query), intent: "",
               definition: r.definition.map { $0.complete ? $0.body : "仅部分匹配（\($0.matched)）；完整表达需进一步确认。" } ?? "", source: r.book?.label ?? r.application,
               book: r.book, lookupIDs: [r.id], example:r.definition?.complete == true ? r.definition?.example : nil)
}
