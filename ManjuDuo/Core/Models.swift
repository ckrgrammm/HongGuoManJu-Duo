import Foundation

enum ManjuError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct Episode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let order: Int
    var title: String { "第 \(order) 集" }
}
struct Drama: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let cover: String
    let intro: String
    let total: Int
    let tags: [String]
    var episodes: [Episode] = []
    var webAccessible: Int = 0
    var coverURL: URL? { URL(string: cover.replacingOccurrences(of:"http://",with:"https://")) }
    var webURL: URL { URL(string:"https://hongguoduanju.com/detail?series_id=\(id)")! }
    var summary: Drama { var d=self; d.episodes=[]; return d }
}
struct CatalogPage: Sendable { let items: [Drama]; let hasMore: Bool; let page: Int }
struct WatchRecord: Identifiable, Codable, Sendable {
    var id: String { drama.id }
    var drama: Drama
    var episodeID: String
    var order: Int
    var time: Double
    var duration: Double
    var updated: Date
}
struct MediaResource: Sendable {
    let episodeID: String
    let url: URL
    let definition: String
    let codec: String
    let duration: Double
    let size: Int
    let contentKey: Data?
}
enum CatalogSort: String, CaseIterable, Identifiable {
    case hot = "全部", fantasy = "玄幻", apocalypse = "末世"
    var id: String { rawValue }
    var path: String { switch self { case .hot: ""; case .fantasy: "/fantasy"; case .apocalypse: "/apocalypse" } }
}
enum WebsiteParser {
    static func validID(_ value: String) -> Bool { value.range(of:"^[1-9][0-9]{7,23}$",options:.regularExpression) != nil }
    static func router(_ html: String) throws -> [String:Any] {
        guard let range=html.range(of:"_ROUTER_DATA\\s*=\\s*",options:.regularExpression) else { throw ManjuError.message("官网数据未准备好，请稍后重试。") }
        let tail=html[range.upperBound...]; var depth=0, quoted=false, escaped=false
        guard tail.first == "{" else { throw ManjuError.message("官网数据格式发生变化。") }
        for i in tail.indices {
            let c=tail[i]
            if quoted { if escaped { escaped=false } else if c == "\\" { escaped=true } else if c == "\"" { quoted=false } }
            else if c == "\"" { quoted=true }
            else if c == "{" || c == "[" { depth += 1 }
            else if c == "}" || c == "]" {
                depth -= 1
                if depth == 0 {
                    guard let json=try JSONSerialization.jsonObject(with:Data(tail[...i].utf8)) as? [String:Any], let loader=json["loaderData"] as? [String:Any] else { break }
                    return loader
                }
            }
        }
        throw ManjuError.message("官网返回的数据不完整。")
    }
    static func drama(_ value: [String:Any]) throws -> Drama {
        guard let id=value["series_id"] as? String, validID(id), let title=(value["series_name"] ?? value["series_title"]) as? String, !title.isEmpty else { throw ManjuError.message("作品数据缺少有效编号或标题。") }
        let ids=value["vid_list"] as? [String] ?? []
        guard ids.count <= 10000, ids.allSatisfy(validID), Set(ids).count == ids.count else { throw ManjuError.message("选集列表包含无效或重复的分集。") }
        let total=(value["episode_cnt"] as? NSNumber)?.intValue ?? ids.count
        guard total > 0 else { throw ManjuError.message("此作品暂无分集。") }
        let tags=value["tags"] as? [String] ?? (value["category_list"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }
        return Drama(id:id,title:title,cover:value["series_cover"] as? String ?? "",intro:value["series_intro"] as? String ?? "",total:total,tags:tags,
                     episodes:ids.enumerated().map { Episode(id:$0.element,order:$0.offset+1) },webAccessible:(value["accessible_episode_cnt"] as? NSNumber)?.intValue ?? 0)
    }
    static func catalog(_ html: String, page: Int) throws -> CatalogPage {
        let loader=try router(html)
        guard let model=loader["category_$"] as? [String:Any], model["isSuccess"] as? Bool == true,
              let list=model["recommendList"] as? [[String:Any]], let pagination=model["pagination"] as? [String:Any],
              let returned=pagination["pageNum"] as? Int, returned == page, let pages=pagination["totalPages"] as? Int else { throw ManjuError.message("漫剧列表暂时不可用。") }
        var seen=Set<String>()
        let items=try list.map(drama).filter { seen.insert($0.id).inserted }
        return CatalogPage(items:items,hasMore:page<pages,page:page)
    }
    static func detail(_ html: String, expectedID: String) throws -> Drama {
        let loader=try router(html)
        guard let model=loader["detail_page"] as? [String:Any], model["isSuccess"] as? Bool == true,
              let raw=model["seriesDetail"] as? [String:Any] else { throw ManjuError.message("作品详情暂不可用。") }
        let item=try drama(raw)
        guard item.id == expectedID, item.episodes.count == item.total else { throw ManjuError.message("官网选集尚不完整，请稍后重试。") }
        return item
    }
    static func search(_ data: Data, page: Int) throws -> CatalogPage {
        guard let model=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let list=model["searchList"] as? [[String:Any]], let returned=model["pageNum"] as? Int, returned==page,
              let more=model["hasMore"] as? Bool else { throw ManjuError.message("搜索暂不可用，请稍后重试。") }
        var seen=Set<String>(); var results=[Drama]()
        for entry in list {
            guard var video=entry["video_data"] as? [String:Any] else { continue }
            if video["series_id"] == nil { video["series_id"]=entry["keyword"] }
            if let name=entry["name"] as? String { video["series_name"]=name }
            if let item=try? drama(video), seen.insert(item.id).inserted { results.append(item) }
        }
        return CatalogPage(items:results,hasMore:more,page:page)
    }
    static func importedURL(_ input: String) throws -> URL {
        guard input.count<=16384, let detector=try? NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue),
              let url=detector.firstMatch(in:input,range:NSRange(input.startIndex...,in:input))?.url, allowedPage(url) else {
            throw ManjuError.message("请粘贴红果官网作品链接或红果漫剧分享链接。")
        }; return url
    }
    static func allowedPage(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
        ["hongguoduanju.com","www.hongguoduanju.com","kylin.hainanyuyue.com","hainanyuyue.com"].contains(url.host ?? "")
    }
    static func importID(_ url: URL, html: String) throws -> String {
        if url.host == "hongguoduanju.com" || url.host == "www.hongguoduanju.com", let id=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="series_id"})?.value, validID(id) { return id }
        let loader=try router(html)
        guard let model=loader["video-animation-share_page"] as? [String:Any] else { throw ManjuError.message("该分享链接没有漫剧作品信息。") }
        let params=model["params"] as? [String:Any]
        let link=model["linkParams"] as? [String:Any], scheme=link?["schemeParams"] as? [String:Any]
        guard let id=(scheme?["video_id"] ?? params?["series_id"]) as? String, validID(id) else { throw ManjuError.message("分享链接缺少有效作品编号。") }
        return id
    }
}

/// 临时计时：定位「换集慢」慢在哪一步。
enum Trace {
    nonisolated(unsafe) static var origin=Date()
    static func reset(_ label:String) { origin=Date();print("TRACE ---- \(label)") }
    static func mark(_ label:String) { print(String(format:"TRACE %6.0f ms  %@",Date().timeIntervalSince(origin)*1000,label)) }
}
