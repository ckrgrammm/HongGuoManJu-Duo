// SPDX-License-Identifier: GPL-3.0-only
// 551 wire protocol adapted from hongguo-manju-desktop f0ba90d; see THIRD_PARTY.md.
import Foundation
import CommonCrypto
import Security
import zlib

enum CryptoFailure: Error { case invalidInput, operationFailed }
extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        self.init(bytes)
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
enum ProtocolCrypto {
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw CryptoFailure.operationFailed }
        return Data(bytes)
    }
    static func md5(_ data: Data) -> Data {
        var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &out) }
        return Data(out)
    }
    static func sha512(_ data: Data) -> Data {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA512($0.baseAddress, CC_LONG(data.count), &out) }
        return Data(out)
    }
    static func aesCBC(_ data: Data, key: Data, iv: Data, padding: Bool) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw CryptoFailure.invalidInput }
        var out = [UInt8](repeating: 0, count: data.count + 16); var written = 0
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in data.withUnsafeBytes { d in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), padding ? CCOptions(kCCOptionPKCS7Padding) : 0,
                    k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count, &out, out.count, &written)
        } } }
        guard status == kCCSuccess else { throw CryptoFailure.operationFailed }
        return Data(out.prefix(written))
    }
    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CryptoFailure.operationFailed }
        defer { deflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))))
        let status = data.withUnsafeBytes { input in out.withUnsafeMutableBytes { output in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(output.count)
            return deflate(&stream, Z_FINISH)
        } }
        guard status == Z_STREAM_END else { throw CryptoFailure.operationFailed }
        return Data(out.prefix(Int(stream.total_out)))
    }
    static func sm3(_ input: Data) -> Data {
        func rol(_ x: UInt32, _ n: Int) -> UInt32 { let n = n & 31; return n == 0 ? x : (x << n) | (x >> (32 - n)) }
        func p0(_ x: UInt32) -> UInt32 { x ^ rol(x, 9) ^ rol(x, 17) }
        func p1(_ x: UInt32) -> UInt32 { x ^ rol(x, 15) ^ rol(x, 23) }
        var bytes = Array(input); let bits = UInt64(bytes.count) * 8
        bytes.append(0x80); while bytes.count % 64 != 56 { bytes.append(0) }
        for n in (0..<8).reversed() { bytes.append(UInt8(truncatingIfNeeded: bits >> (n * 8))) }
        var h: [UInt32] = [0x7380166f,0x4914b2b9,0x172442d7,0xda8a0600,0xa96f30bc,0x163138aa,0xe38dee4d,0xb0fb0e4e]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 68)
            for i in 0..<16 { for j in 0..<4 { w[i] = (w[i] << 8) | UInt32(bytes[offset + i * 4 + j]) } }
            for j in 16..<68 { w[j] = p1(w[j-16] ^ w[j-9] ^ rol(w[j-3],15)) ^ rol(w[j-13],7) ^ w[j-6] }
            var a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], hh=h[7]
            for j in 0..<64 {
                let t: UInt32 = j < 16 ? 0x79cc4519 : 0x7a879d8a
                let ss1 = rol(rol(a,12) &+ e &+ rol(t,j),7), ss2 = ss1 ^ rol(a,12)
                let ff = j < 16 ? a ^ b ^ c : (a & b) | (a & c) | (b & c)
                let gg = j < 16 ? e ^ f ^ g : (e & f) | (~e & g)
                let tt1 = ff &+ d &+ ss2 &+ (w[j] ^ w[j+4]), tt2 = gg &+ hh &+ ss1 &+ w[j]
                d=c; c=rol(b,9); b=a; a=tt1; hh=g; g=rol(f,19); f=e; e=p0(tt2)
            }
            let values = [a,b,c,d,e,f,g,hh]; for i in 0..<8 { h[i] ^= values[i] }
        }
        return Data(h.flatMap { x in [24,16,8,0].map { UInt8(truncatingIfNeeded: x >> $0) } })
    }
}

enum PlayerSignature {
    private static let license: UInt64 = 1611921764
    private static func rol(_ v: UInt64, _ n: Int) -> UInt64 { (v << n) | (v >> (64-n)) }
    private static func ror(_ v: UInt64, _ n: Int) -> UInt64 { (v >> n) | (v << (64-n)) }
    private static func le(_ v: UInt64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded: v >> ($0*8)) }) }
    private static func word(_ data: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[data.startIndex + offset + $1]) << ($1*8) }
    }
    private static func pad(_ data: Data) -> Data { data + Data(repeating: UInt8(16-data.count%16), count: 16-data.count%16) }
    private static func varint(_ n: UInt64) -> Data {
        var n = n & 0xffffffff; var bytes = [UInt8]()
        while n >= 128 { bytes.append(UInt8(n & 127) | 128); n >>= 7 }; bytes.append(UInt8(n)); return Data(bytes)
    }
    private struct Proto {
        var data = Data()
        mutating func int(_ tag: UInt64, _ value: UInt64) { data += varint(tag << 3) + varint(value) }
        mutating func bytes(_ tag: UInt64, _ value: Data) { data += varint((tag << 3) | 2) + varint(UInt64(value.count)) + value }
        mutating func text(_ tag: UInt64, _ value: String) { bytes(tag, Data(value.utf8)) }
    }
    static func headers(query: String, body: Data? = nil, ts: UInt64 = UInt64(Date().timeIntervalSince1970),
                        randField: Int32? = nil, ladonRandom: Data? = nil) throws -> [String:String] {
        let pairs = URLComponents(string: "https://example.invalid/?"+query)?.queryItems ?? []
        func value(_ key: String) -> String { pairs.first { $0.name == key }?.value ?? "" }
        let aid = UInt64(value("aid")) ?? 1967
        let random = try ladonRandom ?? ProtocolCrypto.random(4)
        guard random.count == 4 else { throw CryptoFailure.invalidInput }
        let field: Int32
        if let randField { field = randField } else { field = Int32(truncatingIfNeeded: word(try ProtocolCrypto.random(4) + Data(repeating: 0,count: 4),0)) }
        var pb = Proto()
        pb.int(1,1077940818); pb.int(2,2); pb.int(3,UInt64(UInt32(bitPattern: field)))
        pb.text(4,String(aid == 0 ? 1967 : aid)); pb.text(5,value("device_id")); pb.text(6,String(license))
        pb.text(7,value("version_name")); pb.text(8,"v04.04.05-ov-android"); pb.int(9,134744640)
        pb.bytes(10,Data(repeating:0,count:8)); pb.int(11,0); pb.int(12,ts << 1)
        let stub = body.flatMap { $0.isEmpty ? nil : ProtocolCrypto.md5($0) }
        pb.bytes(13,Data(ProtocolCrypto.sm3(stub ?? Data(repeating:0,count:16)).prefix(6)))
        pb.bytes(14,Data(ProtocolCrypto.sm3(query.isEmpty ? Data(repeating:0,count:16) : Data(query.utf8)).prefix(6)))
        var sub = Proto(); sub.int(1,1); sub.int(2,1); sub.int(3,1); sub.int(7,0xc792eccc); pb.bytes(15,sub.data)
        pb.text(16,""); pb.text(20,"none"); pb.int(21,738)
        sub = Proto(); sub.text(1,"NX551J"); sub.int(2,8196); sub.int(4,0x80e0d800); pb.bytes(23,sub.data); pb.int(25,2)
        let signKey = Data(hex:"fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304")!
        var keys = (0..<4).map { word(signKey,$0*8) }
        for i in 4..<72 {
            var tmp = ror(keys[i-1],3) ^ keys[i-3]; tmp ^= ror(tmp,1)
            let bit = (UInt64(0x3dc94c3a046d678b) >> ((i-4)%62)) & 1
            keys.append(~keys[i-4] ^ tmp ^ bit ^ 3)
        }
        let padded = pad(pb.data); var encrypted = Data()
        for offset in stride(from:0,to:padded.count,by:16) {
            var x=word(padded,offset), y=word(padded,offset+8)
            for key in keys { let previous=y; y=x ^ (rol(y,1) & rol(y,8)) ^ rol(y,2) ^ key; x=previous }
            encrypted += le(x) + le(y)
        }
        let magic = Data(hex:"f2f7fcfff2f7fcff")!
        var frame = Array(magic + encrypted + Data(hex:"eafb2cfe8568519154")!)
        for i in 8..<frame.count { frame[i] ^= magic[i%8] }
        let argus = Data(hex:"f281")! + (try ProtocolCrypto.aesCBC(pad(Data(frame.reversed()) + Data("ao".utf8)),
            key:Data(hex:"d31e3718288a1027baab59f146a09a9c")!,iv:Data(hex:"ea180a0336ed352fcd24e4d50018ae54")!,padding:false))
        let digest = Data(ProtocolCrypto.md5(random + Data(String(aid).utf8)).hex.utf8)
        let words = (0..<4).map { word(digest,$0*8) }
        var table = [words[0]], queue = Array(words.suffix(2)); var b0=words[0], b8=words[1]
        for i in 0..<34 {
            var x8 = (ror(b8,8) &+ b0) ^ UInt64(i); queue.append(x8); x8 ^= rol(b0,3)
            table.append(x8); b0=x8; b8=queue.removeFirst()
        }
        let input = pad(Data("\(ts)-\(license)-\(aid)".utf8)); var ladon = random
        for offset in stride(from:0,to:input.count,by:16) {
            var a=word(input,offset), b=word(input,offset+8)
            for i in 0..<34 { b=table[i] ^ (a &+ ror(b,8)); a=b ^ rol(a,3) }; ladon += le(a) + le(b)
        }
        var out = ["x-ss-req-ticket":String(ts*1000),"x-khronos":String(ts),"x-ladon":ladon.base64EncodedString(),"x-argus":argus.base64EncodedString()]
        if let stub { out["x-ss-stub"] = stub.hex }; return out
    }
}
