import Foundation

@main struct CoreChecks {
    static var checks=0
    static func check(_ truth:Bool,_ message:String) { precondition(truth,message);checks+=1 }
    static func rejects(_ name:String,_ operation:() throws -> Void) { do { try operation();preconditionFailure("should reject \(name)") } catch { checks+=1 } }
    static func u32(_ n:Int) -> Data { Data([UInt8(truncatingIfNeeded:n>>24),UInt8(truncatingIfNeeded:n>>16),UInt8(truncatingIfNeeded:n>>8),UInt8(truncatingIfNeeded:n)]) }
    static func box(_ name:String,_ data:Data) -> Data { u32(data.count+8)+Data(name.utf8)+data }
    @MainActor static func main() throws {
        let id="1000000000000001",episodes=["1000000000000002","1000000000000003"]
        let raw:[String:Any] = ["series_id":id,"series_name":"合成测试作品","episode_cnt":2,"vid_list":episodes,"tags":["玄幻"]]
        func html(_ loader:[String:Any]) throws -> String { "<script>window._ROUTER_DATA = " + String(data:try JSONSerialization.data(withJSONObject:["loaderData":loader]),encoding:.utf8)! + ";</script>" }
        let detailHTML=try html(["detail_page":["isSuccess":true,"seriesDetail":raw]])
        let item=try WebsiteParser.detail(detailHTML,expectedID:id)
        check(item.episodes.map(\.id)==episodes,"64-bit IDs must remain exact strings")
        check(item.episodes.map(\.order)==[1,2],"episode order")
        rejects("wrong work") { _ = try WebsiteParser.detail(detailHTML,expectedID:"1000000000000009") }
        var incomplete=raw;incomplete["episode_cnt"]=3
        let incompleteHTML=try html(["detail_page":["isSuccess":true,"seriesDetail":incomplete]])
        rejects("incomplete series") { _ = try WebsiteParser.detail(incompleteHTML,expectedID:id) }
        var duplicate=raw;duplicate["vid_list"]=[episodes[0],episodes[0]]
        rejects("duplicate IDs") { _ = try WebsiteParser.drama(duplicate) }
        rejects("numeric ID precision") { _ = try WebsiteParser.drama(["series_id":1000000000000001,"series_name":"bad","episode_cnt":1]) }
        rejects("external import") { _ = try WebsiteParser.importedURL("https://example.com/?series_id=\(id)") }
        rejects("credential URL") { _ = try WebsiteParser.importedURL("https://user@hongguoduanju.com/detail?series_id=\(id)") }
        rejects("insecure URL") { _ = try WebsiteParser.importedURL("http://hongguoduanju.com/detail?series_id=\(id)") }
        let imported=try WebsiteParser.importedURL("来看 https://hongguoduanju.com/detail?series_id=\(id)")
        check(try WebsiteParser.importID(imported,html:"")==id,"direct import")
        let catalogHTML=try html(["category_$":["isSuccess":true,"recommendList":[raw,raw],"pagination":["pageNum":1,"totalPages":2]]])
        let catalog=try WebsiteParser.catalog(catalogHTML,page:1)
        check(catalog.items.count==1 && catalog.hasMore,"dedup and pagination")
        rejects("wrong page") { _ = try WebsiteParser.catalog(catalogHTML,page:2) }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library=LibraryStore(directory:root);library.toggle(item)
        library.save(drama:item,episode:item.episodes[1],time:12,duration:60)
        let restored=LibraryStore(directory:root)
        check(restored.isFavorite(id) && restored.record(for:id)?.time==12 && restored.record(for:id)?.order==2,"persistent favorites and progress")
        library.save(drama:item,episode:item.episodes[0],time:.nan,duration:60)
        check(library.record(for:id)?.order==2,"invalid time must not overwrite progress")
        try Data("broken".utf8).write(to:root.appendingPathComponent("library.json"))
        let corrupt=LibraryStore(directory:root);corrupt.toggle(item)
        let preserved=try String(contentsOf:root.appendingPathComponent("library.json"),encoding:.utf8)
        check(corrupt.storageError != nil && preserved=="broken","corrupt input preserved")
        // NIST SP 800-38A F.5 AES-CTR known block in a synthetic CENC sample.
        let key=Data(hex:"2b7e151628aed2a6abf7158809cf4f3c")!,iv=Data(hex:"f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")!
        let cipher=Data(hex:"874d6191b620e3261bef6864990db6ce")!,plain=Data(hex:"6bc1bee22e409f96e93d7e117393172a")!
        var tenc=Data(repeating:0,count:24);tenc[6]=1;tenc[7]=16
        let sinf=box("sinf",box("frma",Data("avc1".utf8))+box("schm",Data(repeating:0,count:4)+Data("cenc".utf8)+u32(65536))+box("schi",box("tenc",tenc)))
        let entry=box("encv",Data(repeating:0,count:78)+sinf)
        let stsd=box("stsd",u32(0)+u32(1)+entry),stsz=box("stsz",u32(0)+u32(16)+u32(1))
        let stsc=box("stsc",u32(0)+u32(1)+u32(1)+u32(1)+u32(1)),senc=box("senc",u32(0)+u32(1)+iv)
        func movie(_ offset:Int) -> Data { box("moov",box("trak",box("mdia",box("minf",box("stbl",stsd+stsz+stsc+senc+box("stco",u32(0)+u32(1)+u32(offset))))))) }
        let header=movie(0),offset=header.count+8,input=movie(offset)+box("mdat",cipher)
        let output=try CENCMedia.decrypt(input,key:key)
        check(output.suffix(16)==plain,"CENC must decode NIST sample")
        check(output.count==input.count,"patching metadata must preserve chunk offsets")
        rejects("truncated media") { _ = try CENCMedia.decrypt(Data(input.dropLast()),key:key) }
        rejects("invalid key") { _ = try CENCMedia.decrypt(input,key:Data()) }
        for length in 0..<min(input.count,100) { rejects("truncation \(length)") { _ = try CENCMedia.decrypt(Data(input.prefix(length)),key:key) } }
        // 边下边播：多采样 + 子采样的合成文件，按各种分段大小流式解密，结果必须与整集解密逐字节一致。
        do {
            var generator=SystemRandomNumberGenerator()
            let sizes=[37,16,5,64,33],clearLead=[3,0,2,7,1]
            var body=Data(),sencBody=u32(2)+u32(sizes.count)
            for (i,size) in sizes.enumerated() {
                body+=Data((0..<size).map{_ in UInt8.random(in:0...255,using:&generator)})
                sencBody+=Data((0..<16).map{_ in UInt8.random(in:0...255,using:&generator)})
                let a=clearLead[i],e1=(size-a)/2,c2=1,e2=size-a-e1-c2
                sencBody+=Data([0,2])+Data([0,UInt8(a)])+u32(e1)+Data([0,UInt8(c2)])+u32(e2)
            }
            let stsz2=box("stsz",u32(0)+u32(0)+u32(sizes.count)+sizes.reduce(Data()){$0+u32($1)})
            let stsc2=box("stsc",u32(0)+u32(1)+u32(1)+u32(sizes.count)+u32(1)),senc2=box("senc",sencBody)
            func movie2(_ offset:Int) -> Data { box("ftyp",Data("isom".utf8)+u32(0))+box("moov",box("trak",box("mdia",box("minf",box("stbl",stsd+stsz2+stsc2+senc2+box("stco",u32(0)+u32(1)+u32(offset))))))) }
            let head2=movie2(0),file=movie2(head2.count+8)+box("mdat",body)
            let whole=try CENCMedia.decrypt(file,key:key)
            check(CENCMedia.headReady(Array(file.prefix(head2.count-1)))==nil,"partial head needs more bytes")
            check(CENCMedia.headReady(Array(file.prefix(head2.count)))==true,"complete head is ready")
            check(CENCMedia.headReady(Array(box("mdat",body)+head2))==false,"index-last files are not streamable")
            let plan=try CENCMedia.plan(head:Array(file.prefix(head2.count+3)),fileSize:file.count)
            check(plan.header==Array(whole.prefix(head2.count)),"stream header must match full decrypt")
            for step in [1,7,16,17,50,1000] {
                var out=plan.header,position=plan.header.count
                while position<file.count {
                    let end=min(file.count,position+step);var piece=Array(file[position..<end])
                    try CENCMedia.decrypt(range:&piece,at:position,samples:plan.samples,key:key);out+=piece;position=end
                }
                check(Data(out)==whole,"streamed decrypt in \(step)-byte pieces must equal full decrypt")
            }
            rejects("stream plan without moov") { _ = try CENCMedia.plan(head:Array(file.prefix(40)),fileSize:file.count) }
            rejects("stream plan with samples past the file") { _ = try CENCMedia.plan(head:Array(file.prefix(head2.count)),fileSize:file.count-1) }
        }
        print("PASS: \(checks) parser, identity, import, persistence and native CENC checks")
    }
}
