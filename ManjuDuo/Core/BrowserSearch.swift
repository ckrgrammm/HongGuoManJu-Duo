import Foundation
import WebKit
import SwiftUI

// Same architecture as DouDuo: the official page owns browser verification;
// all presentation and playback remain native. No account cookies are exported.
@MainActor final class BrowserSearch: NSObject, WKNavigationDelegate, WKScriptMessageHandler, ObservableObject {
    static let shared=BrowserSearch()
    let web: WKWebView
    private var tail: Task<Void,Never>?
    private var operation: UUID?
    private var continuation: CheckedContinuation<Data,Error>?
    private var timeout: Task<Void,Never>?
    private var target: URL?
    private override init() {
        let config=WKWebViewConfiguration(); config.websiteDataStore = .default()
        web=WKWebView(frame:.zero,configuration:config)
        super.init(); web.navigationDelegate=self
        config.userContentController.add(self,name:"manjuSearch")
        web.customUserAgent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"
        let script="""
        (()=>{
          function deliver(url,text){try{const u=new URL(url,location.href);if(u.origin===location.origin&&u.pathname==='/api/search/result')window.webkit.messageHandlers.manjuSearch.postMessage({url:u.href,body:text});}catch(e){}}
          const original=window.fetch;window.fetch=async function(...args){const response=await original.apply(this,args);const copy=response.clone();copy.text().then(t=>deliver(response.url,t)).catch(()=>{});return response;};
          const send=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.send=function(...args){this.addEventListener('load',()=>{if(this.responseType===''||this.responseType==='text')deliver(this.responseURL,this.responseText);});return send.apply(this,args);};
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,forMainFrameOnly:true))
    }
    func search(query: String, page: Int) async throws -> CatalogPage {
        let predecessor=tail
        let task=Task<Data,Error> { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            return try await self.load(query:query,page:page)
        }
        tail=Task { _ = try? await task.value }
        let data=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
        try Task.checkCancellation(); return try WebsiteParser.search(data,page:page)
    }
    private func load(query: String,page: Int) async throws -> Data {
        let id=UUID(); operation=id
        var parts=URLComponents(string:"https://hongguoduanju.com/api/search/result")!
        parts.queryItems=[URLQueryItem(name:"query",value:query),URLQueryItem(name:"page",value:String(page))]; target=parts.url
        let path=query.addingPercentEncoding(withAllowedCharacters:CharacterSet.alphanumerics) ?? ""
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Data,Error>) in
                continuation=c
                if Task.isCancelled { finish(.failure(CancellationError()),id:id); return }
                web.load(URLRequest(url:URL(string:"https://hongguoduanju.com/search/\(path)?page=\(page)")!))
                timeout=Task { try? await Task.sleep(for:.seconds(30)); if !Task.isCancelled { self.finish(.failure(ManjuError.message("官网搜索暂不可用或需要验证，请稍后重试。")),id:id) } }
            }
        },onCancel:{Task { @MainActor in self.finish(.failure(CancellationError()),id:id) }})
    }
    private func finish(_ result: Result<Data,Error>,id: UUID) {
        guard operation==id, let c=continuation else { return }
        continuation=nil; operation=nil; target=nil; timeout?.cancel(); timeout=nil; web.stopLoading(); c.resume(with:result)
    }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host=="hongguoduanju.com",
              let id=operation, let target, let value=message.body as? [String:Any],
              let address=value["url"] as? String, let url=URLComponents(string:address), url.host==target.host, url.path==target.path,
              let expected=URLComponents(url:target,resolvingAgainstBaseURL:false),
              url.queryItems?.first(where:{$0.name=="query"})?.value==expected.queryItems?.first(where:{$0.name=="query"})?.value,
              (url.queryItems?.first(where:{$0.name=="page"})?.value ?? "1")==expected.queryItems?.first(where:{$0.name=="page"})?.value,
              let text=value["body"] as? String else { return }
        guard text.utf8.count<=8*1024*1024 else { finish(.failure(ManjuError.message("搜索响应过大。")),id:id); return }
        finish(.success(Data(text.utf8)),id:id)
    }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) {
        guard let target, let id=operation else { return }
        let literal=String(data:(try? JSONSerialization.data(withJSONObject:target.absoluteString,options:.fragmentsAllowed)) ?? Data(),encoding:.utf8) ?? "null"
        // Reuse the loaded site's own fetch and security environment if SSR omitted a request.
        webView.evaluateJavaScript("fetch(\(literal),{credentials:'same-origin'}).catch(()=>{})") { [weak self] _,error in
            if error != nil { self?.finish(.failure(ManjuError.message("官网搜索初始化失败。")),id:id) }
        }
    }
    func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: Error) {
        if let id=operation { finish(.failure(ManjuError.message("官网搜索连接失败。")),id:id) }
    }
    func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        guard let url=action.request.url, url.scheme=="https",url.host=="hongguoduanju.com" else { decisionHandler(.cancel); return }; decisionHandler(.allow)
    }
}
struct SearchBrowserHost: UIViewRepresentable {
    func makeUIView(context:Context) -> WKWebView { BrowserSearch.shared.web }
    func updateUIView(_ uiView:WKWebView,context:Context) {}
}
