import Foundation

final class PageRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url=request.url, WebsiteParser.allowedPage(url) else { completionHandler(nil); return }; completionHandler(request)
    }
}
actor ContentProvider {
    private let policy=PageRedirectPolicy()
    private lazy var session: URLSession = {
        let config=URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest=25; config.timeoutIntervalForResource=45
        return URLSession(configuration:config,delegate:policy,delegateQueue:nil)
    }()
    private var detailRequests:[String:Task<Drama,Error>]=[:]
    private var detailCache: [String:(Date,Drama)] = [:]
    func page(_ url: URL) async throws -> String {
        guard WebsiteParser.allowedPage(url) else { throw ManjuError.message("不支持这个来源的链接。") }
        var request=URLRequest(url:url); request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15",forHTTPHeaderField:"User-Agent")
        let data=try await bounded(request,session:session,limit:8*1024*1024)
        guard let html=String(data:data,encoding:.utf8) else { throw ManjuError.message("官网页面无法读取。") }; return html
    }
    func catalog(sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let url=URL(string:"https://hongguoduanju.com/category/comic-drama\(sort.path)?page=\(page)")!
        return try WebsiteParser.catalog(await self.page(url),page:page)
    }
    func detail(id: String) async throws -> Drama {
        guard WebsiteParser.validID(id) else { throw ManjuError.message("作品编号无效。") }
        if let (date,item)=detailCache[id], Date().timeIntervalSince(date)<300 { return item }
        if let request=detailRequests[id] { return try await request.value }
        let request=Task { try await fetchDetail(id:id) }
        detailRequests[id]=request
        defer { detailRequests[id]=nil }
        return try await request.value
    }

    private func fetchDetail(id:String) async throws -> Drama {
        let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ManjuDuo/Series",isDirectory:true)
        let saved=directory.appendingPathComponent(id+".json")
        // 选集表很少变：6 小时内存过的直接用本机这份，省掉一次联网（约 0.6 秒）。
        if let age=(try? saved.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate,Date().timeIntervalSince(age)<6*3600,
           let item=Self.stored(saved,id:id) { detailCache[id]=(Date(),item);return item }
        do {
            let item=try WebsiteParser.detail(await page(URL(string:"https://hongguoduanju.com/detail?series_id=\(id)")!),expectedID:id)
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try? JSONEncoder().encode(item).write(to:saved,options:.atomic)
            detailCache[id]=(Date(),item); if detailCache.count>50 { detailCache.removeValue(forKey:detailCache.keys.first!) }; return item
        } catch is CancellationError { throw CancellationError() }
        catch {
            // Metadata only: cached media URLs, identities and keys are never persisted here.
            if let item=Self.stored(saved,id:id) { return item }
            throw error
        }
    }
    private static func stored(_ saved:URL,id:String) -> Drama? {
        guard let data=try? Data(contentsOf:saved),let item=try? JSONDecoder().decode(Drama.self,from:data),
              item.id==id,!item.episodes.isEmpty,item.episodes.count==item.total,
              Set(item.episodes.map(\.id)).count==item.total,
              item.episodes.enumerated().allSatisfy({WebsiteParser.validID($0.element.id) && $0.element.order==$0.offset+1}) else { return nil }
        return item
    }
    func importShare(_ input: String) async throws -> Drama {
        let url=try WebsiteParser.importedURL(input)
        let html=try await page(url)
        let id=try WebsiteParser.importID(url,html:html)
        let item=try await detail(id:id)
        if let loader=try? WebsiteParser.router(html), let model=loader["video-animation-share_page"] as? [String:Any],
           let data=model["pageData"] as? [String:Any], let ids=data["chapter_ids"] as? [String] {
            guard ids==item.episodes.map(\.id) else { throw ManjuError.message("分享页面与官网选集不一致，请重新获取链接。") }
        }
        return item
    }
    func search(query: String, page: Int) async throws -> CatalogPage {
        var parts=URLComponents(string:"https://hongguoduanju.com/api/search/result")!
        parts.queryItems=[URLQueryItem(name:"query",value:query),URLQueryItem(name:"page",value:String(page))]
        do { return try WebsiteParser.search(await bounded(URLRequest(url:parts.url!),session:session,limit:8*1024*1024),page:page) }
        catch is CancellationError { throw CancellationError() }
        catch { return try await BrowserSearch.shared.search(query:query,page:page) }
    }
}

func bounded(_ request: URLRequest, session: URLSession = .shared, limit: Int) async throws -> Data {
    let (bytes,response)=try await session.bytes(for:request)
    guard let http=response as? HTTPURLResponse else { throw ManjuError.message("服务器没有返回有效响应。") }
    guard http.statusCode == 200 else { throw ManjuError.message(http.statusCode==403 ? "来源暂时拒绝访问，请稍后重试。" : "来源暂不可用（\(http.statusCode)）。") }
    guard response.expectedContentLength<=Int64(limit) else { throw ManjuError.message("来源响应超过大小限制。") }
    var data=Data(); data.reserveCapacity(min(limit,max(0,Int(response.expectedContentLength))))
    for try await byte in bytes {
        data.append(byte); if data.count>limit { throw ManjuError.message("来源响应超过大小限制。") }
        if data.count % 65536 == 0 { try Task.checkCancellation() }
    }
    try Task.checkCancellation(); return data
}
