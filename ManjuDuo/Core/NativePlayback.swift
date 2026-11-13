// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CommonCrypto

actor NativePlayback {
    private typealias Registration = (device:String,install:String)
    private var registration:(identity:Registration,expires:Date)?
    private var registrationTask:Task<Registration,Error>?
    private var addressTasks:[String:Task<MediaResource,Error>]=[:]

    func resource(episodeID:String) async throws -> MediaResource {
        guard WebsiteParser.validID(episodeID) else { throw ManjuError.message("分集编号无效。") }
        try Task.checkCancellation()
        if let task=addressTasks[episodeID] {
            let resource=try await task.value
            try Task.checkCancellation()
            return resource
        }
        let task=Task { try await lookupResource(episodeID:episodeID) }
        addressTasks[episodeID]=task
        defer { addressTasks[episodeID]=nil }
        let resource=try await task.value
        try Task.checkCancellation()
        return resource
    }

    private func deviceRegistration() async throws -> Registration {
        if let registration,registration.expires>Date() { return registration.identity }
        if let registrationTask { return try await registrationTask.value }

        let task=Task {
            Trace.mark("registering device")
            let identity=try await register()
            Trace.mark("device registered")
            return identity
        }
        registrationTask=task
        defer { registrationTask=nil }
        let identity=try await task.value
        registration=(identity,Date().addingTimeInterval(300))
        return identity
    }

    private func lookupResource(episodeID:String) async throws -> MediaResource {
        var lastError: Error = ManjuError.message("播放资源暂不可用。")
        for _ in 0..<2 {
            try Task.checkCancellation()
            do { return try await registeredResource(episodeID) }
            catch is CancellationError { throw CancellationError() }
            catch {
                lastError=error;Trace.mark("play address attempt failed for \(episodeID): \(error.localizedDescription)")
                // 来源只给了本机解不了的编码（如 bytevc2）：重试结果一样，直接走官网地址。
                if error.localizedDescription==Self.noTrack { break }
            }
        }
        // A web result must be explicitly tied to this requested episode, never reuse a preview.
        do { return try await webResource(episodeID) }
        catch is CancellationError { throw CancellationError() }
        catch { Trace.mark("web play address unavailable (\((error as NSError).code))");throw lastError }
    }
    private func register() async throws -> Registration {
        let seed=Data(hex:"4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")!
        let version="73932"
        let header: [String:Any] = [
            "app_version_minor":"7.3.9.32","git_hash":"3a88f4e","release_build":"b5e187f","not_request_sender":0,
            "carrier":"CHINA MOBILE","mcc_mnc":"46000","rom":"eng.root.20231116.160340","rom_version":"W528JS release-keys",
            "ipv6_list":[],"sim_region":"cn","sim_serial_number":[],"oaid_may_support":false,"req_id":UUID().uuidString.lowercased(),
            "device_platform":"android","custom":["account_region_src":"fallback","host_bit":64,"account_region":"cn","dragon_device_type":"phone"],
            "pre_installed_channel":"","apk_first_install_time":Int64(Date().timeIntervalSince1970*1000),"is_system_app":0,"sdk_flavor":"china",
            "guest_mode":0,"display_name":"红果免费短剧","aid":8662,"package":"com.phoenix.read","sig_hash":"56a962410c494bbaf0b58dba20cae56f",
            "app_version":"7.3.9.32","version_code":version,"manifest_version_code":version,"update_version_code":version,"channel":"update_64",
            "sdk_version":"3.7.0-rc.34-fanqie-xiaoshuo","sdk_target_version":29,"os":"Android","os_version":"16","os_api":36,
            "device_model":"25053RT47C","device_brand":"Redmi","device_manufacturer":"Xiaomi","device_category":"phone","cpu_abi":"arm64-v8a",
            "density_dpi":520,"display_density":"mdpi","resolution":"1280x2772","language":"zh","timezone":8,"access":"wifi","region":"CN",
            "tz_name":"Asia/Shanghai","tz_offset":28800,"openudid":try ProtocolCrypto.random(8).hex,
            "clientudid":UUID().uuidString.lowercased(),"cdid":UUID().uuidString.lowercased()
        ]
        let json=try JSONSerialization.data(withJSONObject:["magic_tag":"ss_app_log","header":header,"_gen_time":Int64(Date().timeIntervalSince1970*1000)],options:.withoutEscapingSlashes)
        let compressed=try ProtocolCrypto.gzip(json), salt=try ProtocolCrypto.random(32)
        let material=ProtocolCrypto.sha512(ProtocolCrypto.sha512(salt)+seed)
        let body=Data([116,99,5,16,0,0])+salt+(try ProtocolCrypto.aesCBC(ProtocolCrypto.sha512(compressed)+compressed,key:Data(material.prefix(16)),iv:Data(material.dropFirst(16).prefix(16)),padding:true))
        let url=URL(string:"https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1")!
        var request=URLRequest(url:url); request.httpMethod="POST"; request.httpBody=body; request.timeoutInterval=20
        let headers=["content-type":"application/octet-stream;tt-data=a","user-agent":"com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C)","log-encode-type":"gzip","x-ss-dp":"8662","x-ss-req-ticket":String(Int64(Date().timeIntervalSince1970*1000)),"x-vc-bdturing-sdk-version":"4.0.3.cn","lc":"101","sdk-version":"2","passport-sdk-version":"5051452","x-neptune":"-8|50:51:59:30:40:47:49:39","x-ss-stub":ProtocolCrypto.md5(body).hex.uppercased()]
        for (key,value) in headers { request.setValue(value,forHTTPHeaderField:key) }
        let data=try await bounded(request,limit:65536)
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let device=value["device_id_str"] as? String, let install=value["install_id_str"] as? String,
              WebsiteParser.validID(device), WebsiteParser.validID(install) else { throw ManjuError.message("播放设备登记失败，请重试。") }
        return (device,install)
    }
    private func registeredResource(_ id: String) async throws -> MediaResource {
        let (device,install)=try await deviceRegistration()
        var components=URLComponents(string:"https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/")!
        let values: [(String,String)] = [("device_id",device),("iid",install),("aid","8662"),("app_name","novelread"),("version_code","73932"),("version_name","7.3.9.32"),("manifest_version_code","73932"),("update_version_code","73932"),("channel","update_64"),("device_platform","android"),("os","android"),("ssmix","a"),("device_type","25053RT47C"),("device_brand","Redmi"),("language","zh"),("os_api","36"),("os_version","16"),("resolution","1280*2772"),("dpi","520"),("ac","wifi"),("video_id",id),("video_id_type","0"),("device_level","1"),("need_all_video_definition","1"),("need_mp4_align","0"),("use_os_player","0"),("video_platform","1024"),("source","0"),("from_video_id",""),("_rticket",String(Int64(Date().timeIntervalSince1970*1000)))]
        // URLSearchParams encoding is part of the signature; sign exactly what will be sent.
        let allowed=CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._")
        let query=values.map { $0.0 + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters:allowed) ?? "").replacingOccurrences(of:"%20",with:"+") }.joined(separator:"&")
        components.percentEncodedQuery=query
        var request=URLRequest(url:components.url!); request.timeoutInterval=25
        for (key,value) in try PlayerSignature.headers(query:query) { request.setValue(value,forHTTPHeaderField:key) }
        request.setValue("com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)",forHTTPHeaderField:"User-Agent")
        request.setValue("application/json; charset=utf-8,application/x-protobuf",forHTTPHeaderField:"Accept")
        request.setValue("8662",forHTTPHeaderField:"x-ss-dp"); request.setValue("50561",forHTTPHeaderField:"passport-sdk-version"); request.setValue("0",forHTTPHeaderField:"x-xs-from-web")
        let data=try await bounded(request,limit:8*1024*1024)
        guard !data.isEmpty, let result=try JSONSerialization.jsonObject(with:data) as? [String:Any], result["code"] as? Int == 0,
              let payload=result["data"] as? [String:Any], let models=payload["video_model_data"] as? [String:Any],
              let target=models[id] as? [String:Any] else { throw ManjuError.message("来源未返回这一集的播放资源，请重试。") }
        var raw=target["video_model"]
        if let text=raw as? String { raw=try JSONSerialization.jsonObject(with:Data(text.utf8)) }
        guard let model=raw as? [String:Any] else { throw ManjuError.message("播放数据格式发生变化。") }
        do { return try Self.parseModel(model,episodeID:id) }
        catch {
            // 全部档位都是 bytevc2（H.266）：照上游 hongguoTV 的做法，向模型里的兼容接口再要一次，通常能拿到 H.265。
            guard error.localizedDescription==Self.noTrack else { throw error }
            do {
                let resource=try await compatibleResource(model,episodeID:id)
                Trace.mark("compatible track found for \(id): \(resource.codec)/\(resource.definition)")
                return resource
            } catch is CancellationError { throw CancellationError() }
            catch let fallback { Trace.mark("compatible model unavailable for \(id): \(fallback.localizedDescription)");throw error }
        }
    }
    /// 兼容模型（协议出自 tsukiyo-zero/hongguoTV ContentRepository，GPL-3.0）：`fallback_api` 加 `codec_type=0&force_codec=h264`。
    /// 参数名不保证返回的编码，所以仍按实际 codec 过滤。
    private func compatibleResource(_ model:[String:Any],episodeID:String) async throws -> MediaResource {
        let raw=model["fallback_api"]
        let address=(raw as? [String:Any])?["fallback_api"] as? String ?? (raw as? [Any])?.first as? String ?? raw as? String ?? ""
        guard var parts=URLComponents(string:address),parts.scheme=="https",parts.user==nil,parts.port==nil,
              let host=parts.host,["snssdk.com","fqnovel.com","bytedance.com"].contains(where:{ host.hasSuffix("."+$0) }) else { throw ManjuError.message("没有兼容播放接口。") }
        var items=(parts.queryItems ?? []).filter { $0.name != "codec_type" && $0.name != "force_codec" }
        items+=[URLQueryItem(name:"codec_type",value:"0"),URLQueryItem(name:"force_codec",value:"h264")]
        parts.queryItems=items
        var request=URLRequest(url:parts.url!);request.timeoutInterval=20
        request.setValue("com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)",forHTTPHeaderField:"User-Agent")
        request.setValue("zh-CN,zh;q=0.9",forHTTPHeaderField:"Accept-Language")
        let data=try await bounded(request,limit:8*1024*1024)
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],let info=(root["video_info"] as? [String:Any])?["data"] as? [String:Any],
              let list=info["video_list"] as? [String:Any] else { throw ManjuError.message("兼容接口没有返回播放资源。") }
        let seed=(info["key_seed"] as? String).flatMap { $0.isEmpty ? nil : Data(base64Encoded:$0) }
        let order=["1080p","720p","540p","480p","360p"]
        func rank(_ row:[String:Any]) -> Int { order.firstIndex(of:(row["definition"] as? String ?? "").lowercased()) ?? 99 }
        let rows=list.values.compactMap { $0 as? [String:Any] }
            .filter { ["h264","avc1","h265","hevc","hvc1","h265_hvc1","bytevc1"].contains(($0["codec_type"] as? String ?? "").lowercased()) && !($0["main_url"] as? String ?? "").isEmpty }
            .sorted { rank($0)<rank($1) }
        Trace.mark("compatible model offered: \(list.values.compactMap { $0 as? [String:Any] }.map { "\($0["codec_type"] ?? "?")/\($0["definition"] ?? "?")" }.sorted().joined(separator:", "))")
        for row in rows {
            var text=(row["main_url"] as? String ?? "").replacingOccurrences(of:"\\/",with:"/")
            if let seed { text=(try? Self.decryptAddress(text,seed:seed)) ?? "" }
            else if !text.hasPrefix("https://") { text=String(data:Data(base64Encoded:text) ?? Data(),encoding:.utf8) ?? "" }
            guard let url=URL(string:text),Self.allowedMedia(url) else { continue }
            let spade=row["spade_a"] as? String ?? ""
            let key:Data?
            if spade.isEmpty {
                // 没给密钥又标了加密的档位用不了。
                if let flag=row["encrypt"],!(flag as? Bool == false || "\(flag)"=="0" || "\(flag)"=="false") { continue }
                key=nil
            } else { guard let decoded=try? ContentKey.decode(spade) else { continue };key=decoded }
            let duration=(info["video_duration"] as? Double) ?? (model["video_duration"] as? Double) ?? 0
            let size=(row["size"] as? NSNumber)?.intValue ?? 0
            guard duration>=0,duration<=1800,size>=0,size<=200*1024*1024 else { continue }
            return MediaResource(episodeID:episodeID,url:url,definition:row["definition"] as? String ?? "兼容",codec:row["codec_type"] as? String ?? "",duration:duration,size:size,contentKey:key)
        }
        throw ManjuError.message("兼容接口也没有本机能解的档位。")
    }
    /// 兼容接口里加密过的地址（同上游 MediaCrypto.decryptUrl）。
    static func decryptAddress(_ value:String,seed:Data) throws -> String {
        guard let raw=Data(base64Encoded:value),raw.count>=20,raw[raw.startIndex]==0xa8,raw[raw.startIndex+2]==1,raw[raw.startIndex+3]==0 else { throw ManjuError.message("播放地址格式异常。") }
        let constants=Data(hex:"4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")!
        let h=ProtocolCrypto.sha512(ProtocolCrypto.sha512(seed)+constants)
        let key=Data(h.prefix(16)),iv=Data(h.dropFirst(16).prefix(16)),body=Data(raw.dropFirst(4).prefix((raw.count-4)/16*16))
        var out=[UInt8](repeating:0,count:body.count+16);var written=0
        let status=key.withUnsafeBytes { k in iv.withUnsafeBytes { v in body.withUnsafeBytes { d in
            CCCrypt(CCOperation(kCCDecrypt),CCAlgorithm(kCCAlgorithmAES),0,k.baseAddress,key.count,v.baseAddress,d.baseAddress,body.count,&out,out.count,&written)
        } } }
        guard status==kCCSuccess,written>0 else { throw ManjuError.message("播放地址解不开。") }
        var end=written
        if let last=out[..<end].last,(1...16).contains(Int(last)),Int(last)<=end { end-=Int(last) }
        while end>0,out[end-1]==0 { end-=1 }
        guard let text=String(bytes:out[..<end],encoding:.utf8) else { throw ManjuError.message("播放地址解不开。") }
        return text
    }
    static let noTrack="来源只提供了 iPhone 解不了的编码，这一集暂时放不了。"
    static func parseModel(_ model: [String:Any], episodeID: String) throws -> MediaResource {
        if let status=model["status"] as? Int, ![0,10].contains(status) { throw ManjuError.message("此分集暂不可播。") }
        let list=(model["video_list"] as? [String:Any]).map { Array($0.values) } ?? (model["video_list"] as? [Any] ?? [])
        let order=["1080p","720p","540p","480p","360p"]
        let tracks=list.compactMap { $0 as? [String:Any] }.map { raw -> [String:Any] in
            guard let meta=raw["video_meta"] as? [String:Any] else { return raw }
            let encryption=raw["encrypt_info"] as? [String:Any] ?? [:]
            return meta.merging(encryption) { _,new in new }.merging(["main_url":raw["main_url"] ?? ""]) { _,new in new }
        }.filter { ["h264","avc1","h265","hevc","hvc1","h265_hvc1","bytevc1"].contains($0["codec_type"] as? String ?? "") }
        .sorted { (order.firstIndex(of:$0["definition"] as? String ?? "") ?? 99) < (order.firstIndex(of:$1["definition"] as? String ?? "") ?? 99) }
        if tracks.isEmpty,!list.isEmpty {
            let offered=list.compactMap { $0 as? [String:Any] }.map { raw -> String in
                let meta=raw["video_meta"] as? [String:Any] ?? raw
                return "\(meta["codec_type"] ?? "?")/\(meta["definition"] ?? "?")"
            }.sorted().joined(separator:", ")
            Trace.mark("no decodable track for \(episodeID); offered: \(offered)")
            throw ManjuError.message(noTrack)
        }
        guard let track=tracks.first, let encoded=track["main_url"] as? String, let encrypted=track["encrypt"] as? Bool,
              let duration=model["video_duration"] as? Double, duration>0, duration<=1800,
              let size=(track["size"] as? NSNumber)?.intValue, size>0, size<=200*1024*1024 else { throw ManjuError.message("没有适合当前设备的完整播放资源。") }
        let address=encoded.hasPrefix("https://") ? encoded : String(data:Data(base64Encoded:encoded) ?? Data(),encoding:.utf8) ?? ""
        guard let url=URL(string:address), Self.allowedMedia(url) else { throw ManjuError.message("媒体来源地址无效。") }
        let key: Data?
        if encrypted {
            guard track["encryption_method"] as? String == "cenc-aes-ctr", let spade=track["spade_a"] as? String else { throw ManjuError.message("暂不支持此分集的媒体格式。") }
            key=try ContentKey.decode(spade)
        } else { key=nil }
        return MediaResource(episodeID:episodeID,url:url,definition:track["definition"] as? String ?? "",codec:track["codec_type"] as? String ?? "",duration:duration,size:size,contentKey:key)
    }
    static func allowedMedia(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host=url.host else { return false }
        return ["qznovelvod.com","bytevod.com","douyinvod.com","fqnovelvod.com","vegslb.com"].contains { host.hasSuffix("."+$0) }
    }
    private func webResource(_ id: String) async throws -> MediaResource {
        var request=URLRequest(url:URL(string:"https://hongguoduanju.com/api/video/protected/fallback-play-info")!)
        request.httpMethod="POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONSerialization.data(withJSONObject:["item_id":id])
        let data=try await bounded(request,limit:65536)
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any], let base=value["base_resp"] as? [String:Any], base["StatusCode"] as? Int == 0,
              let address=value["main_url"] as? String, let url=URL(string:address), Self.allowedMedia(url),
              let expiration=Double(String(describing:value["url_expire"] ?? "")), expiration>Date().timeIntervalSince1970+10 else { throw ManjuError.message("官网尚未向当前访客开放此集播放。") }
        return MediaResource(episodeID:id,url:url,definition:"官网",codec:"h264",duration:0,size:0,contentKey:nil)
    }
}

enum ContentKey {
    static func decode(_ encoded: String) throws -> Data {
        func failure() -> ManjuError { .message("此分集的媒体格式暂不支持。") }
        guard encoded.count<=4096, let data=Data(base64Encoded:encoded), data.count>=5 else { throw failure() }
        let p=Array(data), tagLength=Int(p[0]^p[1]^p[2])-48, count=p.count-tagLength-1
        guard tagLength>=1, tagLength<=p.count-3, count>=3 else { throw failure() }
        let salt=p[p.count-tagLength-2]^p[p.count-tagLength-1]
        let tag=String(bytes:p.suffix(tagLength).map{$0^salt},encoding:.ascii)
        guard tag != "app_v2", tag != "web_v2" else { throw failure() }
        let original=Array(p[1...count]); var decoded=[UInt8]()
        for i in 0..<count { decoded.append(UInt8(truncatingIfNeeded:Int(original[i] ^ (i<2 ? [250,85][i] : original[i-2]))-21-i.nonzeroBitCount)) }
        guard let prefix=Int(String(UnicodeScalar(decoded[0])),radix:16), count-prefix>=1,
              let text=String(bytes:decoded[1..<(count-prefix)],encoding:.ascii), text.count==32, let key=Data(hex:text) else { throw failure() }
        return key
    }
}
