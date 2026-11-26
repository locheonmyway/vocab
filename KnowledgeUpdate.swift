import Foundation
import CryptoKit

struct KnowledgeRelease:Codable {
    let sequence:Int
    let version:String
    let schemaVersion:Int
    let minAppVersion:String
    let sha256:String
    let unitCount:Int
    let scenarioCount:Int
}

enum KnowledgeUpdate {
    static let repository="locheonmyway/vocab"
    static let latest=URL(string:"https://raw.githubusercontent.com/"+repository+"/main/knowledge/latest.json")!
    static let maxBytes=10_000_000
    struct Package {
        let manifest:KnowledgeRelease
        let data:Data
        let catalog:KnowledgeCatalog
    }
    static func digest(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    static func versionParts(_ value:String)->[Int]? {
        let parts=value.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==3,parts.allSatisfy({!$0.isEmpty && $0.allSatisfy{$0.isASCII && $0.isNumber} && Int($0) != nil}) else{return nil}
        return parts.compactMap{Int($0)}
    }
    static func validate(_ data:Data,manifest m:KnowledgeRelease,current:KnowledgeCatalog,appVersion:String)throws->Package {
        guard let min=versionParts(m.minAppVersion),let actual=versionParts(appVersion),!actual.lexicographicallyPrecedes(min) else{throw SupportError.message("知识包需要较新的 Vocab，请先升级应用。")}
        guard m.schemaVersion==1,versionParts(m.version) != nil,m.sequence > (current.releaseSequence ?? 0),
              data.count<=maxBytes,digest(data)==m.sha256,
              let c=try? JSONDecoder().decode(KnowledgeCatalog.self,from:data),c.valid,
              c.releaseSequence==m.sequence,c.releaseVersion==m.version,
              c.units.count==m.unitCount,c.units.reduce(0,{$0+$1.scenarios.count})==m.scenarioCount,
              KnowledgeCatalog.extends(c,current) else{throw SupportError.message("知识包校验未通过，继续使用现有知识地图。")}
        return Package(manifest:m,data:data,catalog:c)
    }
    private static func get(_ url:URL,limit:Int) async throws->Data {
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:20)
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode==200,data.count<=limit else{throw SupportError.message("知识服务暂不可用，现有目录不受影响。")}
        return data
    }
    static func fetch(current:KnowledgeCatalog,appVersion:String) async throws->Package? {
        let bytes=try await get(latest,limit:32_768)
        let m=try JSONDecoder().decode(KnowledgeRelease.self,from:bytes)
        guard m.sequence > 0,versionParts(m.version) != nil else{throw SupportError.message("知识版本信息无效。")}
        guard m.sequence > (current.releaseSequence ?? 0) else{return nil}
        let url=URL(string:"https://github.com/"+repository+"/releases/download/knowledge-v"+m.version+"/KnowledgeCatalog.json")!
        return try validate(await get(url,limit:maxBytes),manifest:m,current:current,appVersion:appVersion)
    }
    static func install(_ package:Package,support:URL=Paths.support,base:KnowledgeCatalog=KnowledgeCatalog.bundled(),appVersion:String)throws->KnowledgeCatalog {
        let current=KnowledgeCatalog.load(support:support,base:base)
        let checked=try validate(package.data,manifest:package.manifest,current:current,appVersion:appVersion)
        try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true)
        try checked.data.write(to:support.appendingPathComponent("KnowledgeCatalog.json"),options:.atomic)
        return KnowledgeCatalog.load(support:support,base:base)
    }
}
