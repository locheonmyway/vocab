import SwiftUI

enum DictionaryPage: String, CaseIterable, Identifiable {
    case english = "英英", chinese = "中文", writer = "用词"
    var id: String { rawValue }
    static func preferred(_ source:String?) -> Self {
        if source == "Oxford Chinese Dictionary" {return .chinese}
        if source?.contains("Writer") == true {return .writer}
        return .english
    }
}

// The compact and expanded dictionary share one content model, not one
// truncated text block. Native semantic colours adapt to light/dark mode.
struct DictionaryPages: View {
    @Binding var page: DictionaryPage
    var expanded: Bool
    var includeWriter:Bool = false
    var body: some View {
        Picker("词典内容", selection: $page) {
            ForEach(expanded || includeWriter ? DictionaryPage.allCases : [.english, .chinese]) {
                Text($0.rawValue).tag($0)
            }
        }
        .labelsHidden().pickerStyle(.segmented).controlSize(.regular)
        .frame(maxWidth:.infinity,alignment:.leading)
        .accessibilityLabel("词典内容")
    }
}

struct PronunciationLine: View {
    let definition:Definition
    var body: some View {
        let values=definition.preferredPronunciations
        if let first=values.first {
            HStack(alignment:.firstTextBaseline,spacing:6) {
                if keyFor(first.term) != keyFor(definition.term) {
                    Text("原形音标").font(.caption2).foregroundStyle(.secondary)
                } else if first.dialect == "AmE" {
                    Text("美").font(.caption2).foregroundStyle(.secondary)
                }
                Text(values.map{"/"+$0.ipa+"/"}.joined(separator:"  "))
                    .font(.system(size:14,weight:.medium)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2)
                if first.derived == true {
                    Text("词形推导").font(.caption2).foregroundStyle(.secondary)
                }
            }.help(first.derived == true ? "根据 Oxford 原形音标与规则词尾推导；非词典原文" : first.term+" · "+first.source)
        } else if !definition.term.contains(" ") {
            Text("词典未收录音标").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct DictionaryReading: View {
    let definition: Definition
    let page: DictionaryPage
    let compact: Bool
    var selectSense: ((String, DictionaryMeaning)->Void)? = nil
    var savedIntents: Set<String> = []
    @State private var fullSenseGroups: Set<Int> = []

    private var content: DictionaryContent? {
        switch page {
        case .english:
            return DictionaryPage.preferred(definition.source) == .english ? definition.content : nil
        case .chinese: return definition.chinese?.content
        case .writer: return definition.supplement?.content
        }
    }
    private var source: String? {
        switch page {
        case .english: return DictionaryPage.preferred(definition.source) == .english ? definition.source : nil
        case .chinese: return definition.chinese?.source
        case .writer: return definition.supplement?.source
        }
    }
    private var fallback: String? {
        switch page {
        case .english: return source == nil ? nil : (compact ? definition.body : definition.detail)
        case .chinese: return definition.chinese?.detail
        case .writer: return definition.supplement?.detail
        }
    }
    private var quickGroups: [DictionaryGrammar] {
        guard let content else { return [] }
        let groups = Array(content.groups.prefix(3))
        var budget = 4
        var result: [DictionaryGrammar] = []
        for group in groups {
            guard budget > 0 else { break }
            let limit = max(1, budget - max(0, groups.count - result.count - 1))
            var meanings = [DictionarySense]()
            let first = group.senses.first
            // The dictionary's first sense is its core entry. Additional
            // brief senses are useful for compact entries; never guess rarity.
            let senses = group.senses.count <= 2 ? group.senses : Array(group.senses.prefix(1))
            var remaining = limit
            for sense in senses {
                guard remaining > 0 else { break }
                let count = senses.count > 1 ? 1 : min(2,remaining)
                let kept = Array(sense.meanings.prefix(count))
                if !kept.isEmpty {
                    meanings.append(DictionarySense(number:sense.number,meanings:kept))
                    remaining -= kept.count
                }
            }
            if meanings.isEmpty, let first { meanings = [first] }
            if !meanings.isEmpty {
                result.append(DictionaryGrammar(partOfSpeech:group.partOfSpeech,senses:meanings))
                budget -= meanings.reduce(0) { $0 + $1.meanings.count }
            }
        }
        return result
    }
    var body: some View {
        VStack(alignment:.leading, spacing: compact ? 9 : 20) {
            if let content, !content.groups.isEmpty {
                let list = compact ? quickGroups : content.groups
                ForEach(Array(list.enumerated()),id:\.offset) { i, group in
                    if !compact && i > 0 { Divider() }
                    grammar(group,index:i)
                }
                if !compact {
                    ForEach(Array(content.sections.enumerated()),id:\.offset) { _, note in
                        DictionaryNoteView(note:note)
                    }
                }
            } else if let fallback, !fallback.isEmpty {
                Text("词典原始文本 · 暂无结构化词条").font(.caption2).foregroundStyle(.secondary)
                Text(fallback).font(.system(size:14)).lineSpacing(4)
                    .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            } else {
                VStack(alignment:.leading,spacing:6) {
                    Text(page == .chinese ? "没有完整的本地中文词条" : page == .writer ? "没有对应的用词词条" : "没有完整的英英词条")
                        .font(.subheadline.weight(.medium))
                    Text("可以切换到其他词典，或者问 AI。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical,8)
            }
            if let source, !compact {
                Text(source).font(.caption2).foregroundStyle(.secondary)
                    .padding(.top,compact ? 0 : 5)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private func grammar(_ group: DictionaryGrammar,index:Int) -> some View {
        VStack(alignment:.leading,spacing:compact ? 3 : 10) {
            if !group.partOfSpeech.isEmpty {
                Text(group.partOfSpeech).font(.system(size:compact ? 12 : 13,weight:.semibold))
                    .foregroundStyle(accent).italic()
            }
            let shortList = !compact && group.senses.count > 3
            let shown = shortList ? Array(group.senses.prefix(2)) : group.senses
            ForEach(Array(shown.enumerated()),id:\.offset) { _, sense in
                senseRow(sense,group:group)
            }
            if shortList {
                DisclosureGroup(isExpanded:Binding(get:{fullSenseGroups.contains(index)},set:{
                    if $0 {fullSenseGroups.insert(index)} else {fullSenseGroups.remove(index)}
                })) {
                    VStack(alignment:.leading,spacing:10) {
                        ForEach(Array(group.senses.dropFirst(2).enumerated()),id:\.offset) { _, sense in
                            senseRow(sense,group:group)
                        }
                    }.padding(.top,8)
                } label:{
                    Text("其余 \(group.senses.count-2) 个义项").font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    @ViewBuilder private func senseRow(_ sense:DictionarySense,group:DictionaryGrammar)->some View {
        HStack(alignment:.firstTextBaseline,spacing:7) {
            if !compact && group.senses.count > 1 {
                Text(String(sense.number)).font(.system(size:12,weight:.semibold))
                    .foregroundStyle(.secondary).frame(width:17,alignment:.trailing)
            }
            VStack(alignment:.leading,spacing:compact ? 3 : 7) {
                ForEach(Array(sense.meanings.enumerated()),id:\.offset) { _, m in
                    meaning(m, partOfSpeech:group.partOfSpeech)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    @ViewBuilder private func meaning(_ m: DictionaryMeaning,partOfSpeech:String) -> some View {
        VStack(alignment:.leading, spacing:compact ? 3 : 5) {
            if !compact && !m.qualifiers.isEmpty {
                Text(m.qualifiers.joined(separator:" · ")).font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !m.definition.isEmpty {
                HStack(alignment:.firstTextBaseline,spacing:6) {
                    if !compact && m.subordinate {
                        Text("•").foregroundStyle(.secondary).font(.caption)
                    }
                    Text(m.definition).font(.system(size:compact ? 14 : 15))
                        .lineSpacing(compact ? 2 : 4).textSelection(.enabled)
                        .fixedSize(horizontal:false,vertical:true)
                    if !compact, let selectSense {
                        Spacer(minLength:2)
                        let intent=[partOfSpeech,m.definition].filter{!$0.isEmpty}.joined(separator:" · ")
                        let saved=savedIntents.contains(intent)
                        Button { selectSense(partOfSpeech,m) } label: {
                            Image(systemName:saved ? "star.fill" : "star").font(.caption)
                        }.buttonStyle(.borderless).foregroundStyle(saved ? accent : .secondary)
                        .help(saved ? "已收藏这个义项" : "收藏这个义项")
                        .accessibilityLabel(saved ? "已收藏这个义项" : "收藏这个义项")
                    }
                }
            }
            if compact, m.definition.isEmpty,let synonyms=m.synonymGroups.first {
                Text(synonyms).font(.system(size:14)).lineLimit(2).lineSpacing(2)
                    .textSelection(.enabled)
            }
            if !compact {
                ForEach(Array(m.examples.enumerated()),id:\.offset) { _, example in
                    Text(example).font(.system(size:13)).italic().foregroundStyle(.secondary)
                        .lineSpacing(3).padding(.leading, m.subordinate ? 14 : 5)
                        .textSelection(.enabled)
                }
                ForEach(Array(m.synonymGroups.enumerated()),id:\.offset) { i, synonyms in
                    VStack(alignment:.leading,spacing:4) {
                        if i > 0 { Divider().opacity(0.6) }
                        Text(synonyms).font(.system(size:14)).lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
                if !m.antonyms.isEmpty {
                    Text("反义词 · " + m.antonyms.joined(separator:", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.leading, m.subordinate && !compact ? 8 : 0)
    }
}

private struct DictionaryNoteView: View {
    let note: DictionaryNote
    @State private var open = false
    var body: some View {
        let title = note.title.lowercased()
        let prominent = title.contains("usage") || title.contains("choose") || title.contains("confused")
        VStack(alignment:.leading,spacing:9) {
            Divider()
            if prominent {
                Text(note.title.capitalized).font(.subheadline.weight(.semibold))
                contents
            } else {
                DisclosureGroup(isExpanded:$open) {
                    contents.padding(.top,8)
                } label: {
                    HStack {
                        Text(note.title.capitalized).font(.subheadline.weight(.semibold))
                        if note.items.count > 1 {
                            Text(String(note.items.count)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
    private var contents: some View {
        VStack(alignment:.leading,spacing:12) {
            ForEach(Array(note.items.enumerated()),id:\.offset) { _, item in
                VStack(alignment:.leading,spacing:4) {
                    if !item.heading.isEmpty {
                        Text(item.heading).font(.system(size:14,weight:.semibold))
                    }
                    Text(item.text).font(.system(size:13)).lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
