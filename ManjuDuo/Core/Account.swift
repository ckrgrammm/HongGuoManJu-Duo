// SPDX-License-Identifier: GPL-3.0-only
// 红果官网扫码登录。流程移植自 tsukiyo-zero/hongguoTV
// kotlin-tv/core/src/main/kotlin/com/hongguotv/core/WebLogin.kt（GPL-3.0-only，提交 77a99f5）。
import Foundation
import Security
import Combine

/// 一次官网登录会话：CSRF 等 Cookie 只留在这个对象里，在取码 / 轮询 / 确认之间沿用。
actor WebLogin {
    struct QR:Sendable { let image:Data;let expiresIn:Int }
    struct Credentials:Sendable { let cookie:String;let name:String }

    private static let base="https://hongguoduanju.com"
    private static let agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    private final class NoRedirect:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
        func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
    }
    private let session:URLSession
    /// 只收官网域下的 Cookie：名字 → (值, 过期时间)
    private var cookies=[String:(value:String,expires:Date?)]()
    private var token=""

    init() {
        let config=URLSessionConfiguration.ephemeral
        config.httpCookieStorage=nil;config.httpShouldSetCookies=false;config.urlCache=nil
        config.timeoutIntervalForRequest=20
        session=URLSession(configuration:config,delegate:NoRedirect(),delegateQueue:nil)
    }

    private func live() -> [String:String] {
        let now=Date()
        return cookies.filter { $0.value.expires.map { $0>now } ?? true }.mapValues(\.value)
    }

    private func execute(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        guard let url=request.url,url.scheme=="https",url.host=="hongguoduanju.com" else { throw ManjuError.message("登录请求指向了不支持的站点。") }
        var scoped=request
        let jar=live()
        if !jar.isEmpty { scoped.setValue(jar.map { "\($0.key)=\($0.value)" }.joined(separator:"; "),forHTTPHeaderField:"Cookie") }
        let (data,response)=try await session.data(for:scoped)
        guard let http=response as? HTTPURLResponse else { throw ManjuError.message("官网没有返回有效响应。") }
        guard data.count<=2*1024*1024 else { throw ManjuError.message("官网登录响应过大。") }
        let headers=(http.allHeaderFields as? [String:String]) ?? [:]
        for cookie in HTTPCookie.cookies(withResponseHeaderFields:headers,for:url) {
            let domain=cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            guard domain=="hongguoduanju.com" || "hongguoduanju.com".hasSuffix("."+domain) || domain.isEmpty else { continue }
            if let expires=cookie.expiresDate,expires<=Date() { cookies[cookie.name]=nil }
            else { cookies[cookie.name]=(cookie.value,cookie.expiresDate) }
        }
        return (data,http)
    }

    private func call(_ path:String,params:[String:String]=[:]) async throws -> [String:Any] {
        var parts=URLComponents(string:Self.base+path)!
        let fixed=[("aid","513755"),("passport_jssdk_version","3.4.10"),("passport_jssdk_type","normal"),("account_sdk_source","web"),("is_from_ttaccountsdk","1"),("language","zh")]
        parts.queryItems=fixed.map { URLQueryItem(name:$0.0,value:$0.1) }+params.sorted { $0.key<$1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
        var request=URLRequest(url:parts.url!)
        request.setValue(Self.agent,forHTTPHeaderField:"User-Agent")
        request.setValue(Self.base+"/",forHTTPHeaderField:"Referer")
        request.setValue(Self.base,forHTTPHeaderField:"Origin")
        request.setValue("application/json, text/javascript",forHTTPHeaderField:"Accept")
        if let csrf=live()["passport_csrf_token"] { request.setValue(csrf,forHTTPHeaderField:"x-tt-passport-csrf-token") }
        let (data,http)=try await execute(request)
        guard (200..<300).contains(http.statusCode) else { throw ManjuError.message("账号请求失败（HTTP \(http.statusCode)）。") }
        guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw ManjuError.message("官网登录返回格式异常。") }
        return json
    }

    private func checked(_ reply:[String:Any]) throws -> [String:Any] {
        guard let data=reply["data"] as? [String:Any] else { throw ManjuError.message("官网登录返回格式异常。") }
        guard reply["message"] as? String=="success" else {
            let code=(data["error_code"] as? NSNumber)?.intValue ?? -1
            let text=data["verify_center_decision_conf"] != nil ? "红果要求完成滑块验证，请稍后再试" : (data["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "官网登录失败"
            throw ManjuError.message("\(text)（错误码 \(code)）")
        }
        return data
    }

    /// 取一张登录二维码（PNG）。
    func qr() async throws -> QR {
        let data=try checked(try await call("/passport/web/get_qrcode/",params:["next":Self.base+"/"]))
        guard let value=data["token"] as? String,!value.isEmpty,let picture=data["qrcode"] as? String,
              let image=Data(base64Encoded:String(picture[(picture.range(of:"base64,")?.upperBound ?? picture.startIndex)...])),!image.isEmpty else { throw ManjuError.message("官网没有返回二维码。") }
        token=value
        let expiry=(data["expire_time"] as? NSNumber)?.doubleValue ?? 180
        let seconds=expiry>1_000_000_000 ? expiry-Date().timeIntervalSince1970 : expiry
        return QR(image:image,expiresIn:Int(max(0,min(600,seconds))))
    }

    /// 还在等扫码 / 确认时返回 false；二维码过期抛错。
    func poll() async throws -> Bool {
        guard !token.isEmpty else { throw ManjuError.message("请先获取二维码。") }
        let data=try checked(try await call("/passport/web/check_qrconnect/",params:["next":Self.base+"/","token":token]))
        let status=(data["status"] as? String) ?? (data["status"] as? NSNumber)?.stringValue ?? ""
        if ["5","expired"].contains(status) { throw ManjuError.message("二维码已过期，请重新获取。") }
        if ["3","confirmed"].contains(status),let redirect=data["redirect_url"] as? String,!redirect.isEmpty { try await finishRedirect(redirect) }
        return hasSession
    }
    /// 手机上的状态，给界面显示用：new / scanned / confirmed。
    private var hasSession:Bool { let jar=live();return jar["sessionid"] != nil || jar["sessionid_ss"] != nil }

    /// 只跟官网自己的确认跳转，把登录态 Cookie 收下来。
    private func finishRedirect(_ value:String) async throws {
        guard var url=URL(string:value,relativeTo:URL(string:Self.base)!)?.absoluteURL else { throw ManjuError.message("登录确认地址无效。") }
        for _ in 0..<5 {
            guard url.scheme=="https",url.host=="hongguoduanju.com" else { throw ManjuError.message("登录确认跳转到不支持的站点。") }
            var request=URLRequest(url:url)
            request.setValue(Self.agent,forHTTPHeaderField:"User-Agent");request.setValue(Self.base+"/",forHTTPHeaderField:"Referer")
            let (_,http)=try await execute(request)
            if (300..<400).contains(http.statusCode),let location=http.value(forHTTPHeaderField:"Location"),let next=URL(string:location,relativeTo:url)?.absoluteURL { url=next;continue }
            guard (200..<300).contains(http.statusCode) else { throw ManjuError.message("登录确认失败（HTTP \(http.statusCode)）。") }
            return
        }
        throw ManjuError.message("登录确认跳转次数过多。")
    }

    /// 登录态下发后，向官网核对一次账号资料再交出去。
    func credentials() async throws -> Credentials {
        guard hasSession else { throw ManjuError.message("官网尚未下发登录态，请先在手机确认登录。") }
        let data=try checked(try await call("/passport/account/info/v2/"))
        let name=["screen_name","name","user_name"].compactMap { data[$0] as? String }.first { !$0.isEmpty } ?? "红果用户"
        return Credentials(cookie:live().sorted { $0.key<$1.key }.map { "\($0.key)=\($0.value)" }.joined(separator:"; "),name:name)
    }
}

/// 当前登录的红果账号。登录态（Cookie）只存在钥匙串里，不进备份文件、不写日志。
@MainActor final class AccountStore:ObservableObject {
    static let shared=AccountStore()
    @Published private(set) var name:String?
    var signedIn:Bool { name != nil }
    private let service="com.manjuduo.account",nameKey="accountName"

    private init() {
        if cookie() != nil { name=UserDefaults.standard.string(forKey:nameKey) ?? "红果用户" }
    }
    private func query() -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"session"] }

    /// 账号接口要带的 Cookie；没登录是 nil。
    func cookie() -> String? {
        var request=query();request[kSecReturnData as String]=true;request[kSecMatchLimit as String]=kSecMatchLimitOne
        var item:CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary,&item)==errSecSuccess,let data=item as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    func save(_ credentials:WebLogin.Credentials) throws {
        SecItemDelete(query() as CFDictionary)
        var item=query()
        item[kSecValueData as String]=Data(credentials.cookie.utf8)
        item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else { throw ManjuError.message("登录态无法保存到钥匙串。") }
        UserDefaults.standard.set(credentials.name,forKey:nameKey)
        name=credentials.name
    }
    func signOut() {
        SecItemDelete(query() as CFDictionary)
        UserDefaults.standard.removeObject(forKey:nameKey)
        name=nil
    }
}
