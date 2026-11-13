// SPDX-License-Identifier: GPL-3.0-only
// Native ISO BMFF CENC adapter. No FFmpeg process or Android runtime on iOS.
import Foundation
import CommonCrypto

enum CENCMedia {
    struct Box { let type:String; let start:Int; let body:Int; let end:Int }
    private static func invalid() -> ManjuError { .message("此分集的媒体封装暂不支持，请重试或选择其他作品。") }
    private static func uint(_ b:[UInt8],_ p:Int,_ n:Int) throws -> UInt64 {
        guard p>=0,n>0,p<=b.count-n else { throw invalid() }
        return b[p..<p+n].reduce(UInt64(0)) { ($0<<8)|UInt64($1) }
    }
    private static func number(_ b:[UInt8],_ p:Int,_ n:Int=4) throws -> Int {
        let value=try uint(b,p,n); guard value<=UInt64(Int.max) else { throw invalid() }; return Int(value)
    }
    static func boxes(_ b:[UInt8],_ start:Int,_ end:Int) throws -> [Box] {
        guard start>=0,end<=b.count,start<=end else { throw invalid() }
        var result=[Box](),p=start
        while p<end {
            guard p<=end-8 else { throw invalid() }
            var size=try number(b,p); var header=8
            let type=String(bytes:b[p+4..<p+8],encoding:.ascii) ?? ""
            if size==1 { size=try number(b,p+8,8); header=16 }
            if size==0 { size=end-p }
            guard size>=header,size<=end-p else { throw invalid() }
            result.append(Box(type:type,start:p,body:p+header,end:p+size)); p+=size
        }; return result
    }
    private static func child(_ b:[UInt8],_ box:Box,_ name:String) throws -> Box {
        let found=try boxes(b,box.body,box.end).filter{$0.type==name}; guard found.count==1 else { throw invalid() }; return found[0]
    }
    private static func setType(_ b:inout [UInt8],_ start:Int,_ value:String) { b.replaceSubrange(start+4..<start+8,with:value.utf8) }
    /// 一个加密采样在文件里的位置和解密参数。
    struct Sample { let offset:Int; let size:Int; let iv:Data; let spans:[(clear:Int,encrypted:Int)] }
    /// 边下边播用：文件开头（到 moov 结束）已去掉加密标记的字节 + 全部采样的解密表（按文件偏移排序）。
    struct StreamPlan { let header:[UInt8]; let samples:[Sample] }

    static func decrypt(_ input:Data,key:Data) throws -> Data {
        guard key.count==16,input.count<=200*1024*1024 else { throw invalid() }
        var b=Array(input); let root=try boxes(b,0,b.count)
        guard let moov=root.first(where:{$0.type=="moov"}),!root.contains(where:{$0.type=="moof"}) else { throw invalid() }
        let mdats=root.filter{$0.type=="mdat"}; guard !mdats.isEmpty else { throw invalid() }
        let total=b.count
        let samples=try walk(&b,moov:moov) { offset,size in offset<=total-size && mdats.contains(where:{offset >= $0.body && offset+size <= $0.end}) }
        for (index,sample) in samples.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            try decryptSample(&b,offset:sample.offset,size:sample.size,key:key,iv:sample.iv,spans:sample.spans)
        }
        return Data(b)
    }
    /// 只凭文件开头就建立解密表。`head` 必须包含完整的 moov，且 moov 在 mdat 之前（否则无法边下边播，抛错后走整集准备）。
    static func plan(head:[UInt8],fileSize:Int) throws -> StreamPlan {
        guard fileSize>0,fileSize<=200*1024*1024 else { throw invalid() }
        var b=head,p=0,moov:Box?
        while p<=b.count-8 {
            var size=try number(b,p),header=8
            let type=String(bytes:b[p+4..<p+8],encoding:.ascii) ?? ""
            if size==1 { guard p<=b.count-16 else { break };size=try number(b,p+8,8);header=16 }
            guard size>=header,type != "moof",type != "mdat" else { throw invalid() }
            guard size<=b.count-p else { throw invalid() }
            if type=="moov" { moov=Box(type:type,start:p,body:p+header,end:p+size);break }
            p+=size
        }
        guard let moov else { throw invalid() }
        let samples=try walk(&b,moov:moov) { offset,size in offset>=moov.end && offset<=fileSize-size }
        return StreamPlan(header:Array(b[0..<moov.end]),samples:samples.sorted{$0.offset<$1.offset})
    }
    /// moov 是否已经完整落在 `head` 里：true 可以建表；false 这个文件不是「索引在前」；nil 还要更多字节。
    static func headReady(_ head:[UInt8]) -> Bool? {
        var p=0
        while p<=head.count-8 {
            guard var size=try? number(head,p) else { return false }
            let type=String(bytes:head[p+4..<p+8],encoding:.ascii) ?? ""
            if size==1 { guard p<=head.count-16,let large=try? number(head,p+8,8) else { return nil };size=large }
            if type=="mdat" || type=="moof" || size<8 { return false }
            if type=="moov" { return size<=head.count-p ? true : (size<=8*1024*1024 ? nil : false) }
            guard size<=8*1024*1024 else { return false }
            p+=size
        }
        return nil
    }
    /// 遍历 moov 里的加密轨道：校验、收集每个采样的解密参数，并把加密标记原地改掉（不改变任何偏移）。
    private static func walk(_ b:inout [UInt8],moov:Box,valid:(Int,Int)->Bool) throws -> [Sample] {
        var samples=[Sample]()
        var encryptedTracks=0
        for track in try boxes(b,moov.body,moov.end).filter({$0.type=="trak"}) {
            try Task.checkCancellation()
            let mdia=try child(b,track,"mdia"), minf=try child(b,mdia,"minf"), stbl=try child(b,minf,"stbl")
            let tables=try boxes(b,stbl.body,stbl.end), stsd=try child(b,stbl,"stsd")
            guard try number(b,stsd.body+4)==1 else { throw invalid() }
            let entries=try boxes(b,stsd.body+8,stsd.end); guard let entry=entries.first else { throw invalid() }
            guard ["encv","enca"].contains(entry.type) else { continue }
            let children=try boxes(b,entry.start+(entry.type=="encv" ? 86 : 36),entry.end)
            guard let sinf=children.first(where:{$0.type=="sinf"}) else { throw invalid() }
            let frma=try child(b,sinf,"frma"),schm=try child(b,sinf,"schm"), schi=try child(b,sinf,"schi"),tenc=try child(b,schi,"tenc")
            guard schm.end-schm.body>=8,frma.end-frma.body>=4,
                  String(bytes:b[schm.body+4..<schm.body+8],encoding:.ascii)=="cenc",tenc.end-tenc.body>=24,
                  b[tenc.body]==0,b[tenc.body+6]==1,[8,16].contains(b[tenc.body+7]) else { throw invalid() }
            let ivSize=Int(b[tenc.body+7])
            guard let original=String(bytes:b[frma.body..<frma.body+4],encoding:.ascii),["avc1","hvc1","hev1","mp4a"].contains(original) else { throw invalid() }
            let stsz=try child(b,stbl,"stsz"), stsc=try child(b,stbl,"stsc"),senc=try child(b,stbl,"senc")
            let sampleCount=try number(b,stsz.body+8),constant=try number(b,stsz.body+4)
            guard sampleCount>0,sampleCount<1_000_000,try number(b,senc.body+4)==sampleCount else { throw invalid() }
            var sizes=[Int](); sizes.reserveCapacity(sampleCount)
            for i in 0..<sampleCount { sizes.append(try constant>0 ? constant : number(b,stsz.body+12+i*4)) }
            guard let offsets=tables.first(where:{$0.type=="stco" || $0.type=="co64"}) else { throw invalid() }
            let chunkCount=try number(b,offsets.body+4),width=offsets.type=="co64" ? 8 : 4
            guard chunkCount>0,chunkCount<=sampleCount else { throw invalid() }
            let mapCount=try number(b,stsc.body+4); guard mapCount>0,mapCount<=chunkCount else { throw invalid() }
            var maps=[(first:Int,count:Int)]()
            for i in 0..<mapCount {
                let p=stsc.body+8+i*12,first=try number(b,p),count=try number(b,p+4),description=try number(b,p+8)
                guard count>0,description==1,first>=1,first<=chunkCount,(maps.last?.first ?? 0)<first else { throw invalid() }; maps.append((first,count))
            }
            guard maps[0].first==1 else { throw invalid() }
            let flags=try number(b,senc.body+1,3); guard flags & ~2 == 0 else { throw invalid() }
            var encryption=senc.body+8,sample=0,mapIndex=0
            for chunk in 1...chunkCount {
                if chunk % 64 == 0 { try Task.checkCancellation() }
                if mapIndex+1<maps.count,maps[mapIndex+1].first==chunk { mapIndex+=1 }
                var offset=try number(b,offsets.body+8+(chunk-1)*width,width)
                for _ in 0..<maps[mapIndex].count {
                    guard sample<sampleCount else { throw invalid() }; let size=sizes[sample]
                    guard size>0,offset>=0,valid(offset,size),encryption<=senc.end-ivSize else { throw invalid() }
                    var iv=Data(b[encryption..<encryption+ivSize]); encryption+=ivSize
                    if ivSize==8 { iv+=Data(repeating:0,count:8) }
                    var spans=[(clear:Int,encrypted:Int)]()
                    if flags & 2 != 0 {
                        let count=try number(b,encryption,2); encryption+=2; guard count<=10000 else { throw invalid() }
                        for _ in 0..<count { let clear=try number(b,encryption,2),encrypted=try number(b,encryption+2);encryption+=6;spans.append((clear,encrypted)) }
                    } else { spans=[(0,size)] }
                    guard encryption<=senc.end,spans.reduce(0,{$0+$1.clear+$1.encrypted})==size else { throw invalid() }
                    samples.append(Sample(offset:offset,size:size,iv:iv,spans:spans))
                    offset+=size; sample+=1
                }
            }
            guard sample==sampleCount,encryption==senc.end else { throw invalid() }
            setType(&b,entry.start,original); setType(&b,sinf.start,"free")
            for table in tables where ["senc","saio","saiz"].contains(table.type) { setType(&b,table.start,"free") }
            encryptedTracks+=1
        }
        guard encryptedTracks>0 else { throw invalid() }; return samples
    }
    /// 解密文件里任意一段字节（`bytes` 对应文件偏移 `fileOffset` 起的内容）。AES-CTR 可以从任意位置开始算，
    /// 所以一段数据到了就能解，不必等整集下完。`samples` 必须按偏移排序。
    static func decrypt(range bytes:inout [UInt8],at fileOffset:Int,samples:[Sample],key:Data) throws {
        guard key.count==16 else { throw invalid() }
        let end=fileOffset+bytes.count
        var low=0,high=samples.count
        while low<high { let mid=(low+high)/2;if samples[mid].offset+samples[mid].size<=fileOffset { low=mid+1 } else { high=mid } }
        var index=low
        while index<samples.count,samples[index].offset<end {
            let sample=samples[index];index+=1
            var p=sample.offset,stream=0,cryptor:CCCryptorRef?
            defer { if let cryptor { CCCryptorRelease(cryptor) } }
            for span in sample.spans {
                p+=span.clear
                let from=max(p,fileOffset),to=min(p+span.encrypted,end)
                if from<to {
                    if cryptor==nil {
                        // 从这个采样的密文流中途开始：计数器加上已跳过的整块数，再空转掉块内偏移。
                        let position=stream+(from-p)
                        var counter=[UInt8](sample.iv),carry=position/16,i=15
                        while carry>0,i>=0 { let sum=Int(counter[i])+(carry & 0xff);counter[i]=UInt8(sum & 0xff);carry=(carry>>8)+(sum>>8);i-=1 }
                        let status=key.withUnsafeBytes { k in
                            CCCryptorCreateWithMode(CCOperation(kCCDecrypt),CCMode(kCCModeCTR),CCAlgorithm(kCCAlgorithmAES),CCPadding(ccNoPadding),
                                counter,k.baseAddress,key.count,nil,0,0,CCModeOptions(kCCModeOptionCTR_BE),&cryptor)
                        }
                        guard status==kCCSuccess,let cryptor else { throw invalid() }
                        let skip=position%16
                        if skip>0 {
                            let zeros=[UInt8](repeating:0,count:skip);var sink=[UInt8](repeating:0,count:skip),written=0
                            guard CCCryptorUpdate(cryptor,zeros,skip,&sink,skip,&written)==kCCSuccess else { throw invalid() }
                        }
                    }
                    let count=to-from,local=from-fileOffset
                    var output=[UInt8](repeating:0,count:count),written=0
                    let result=bytes.withUnsafeBufferPointer { CCCryptorUpdate(cryptor,$0.baseAddress!+local,count,&output,count,&written) }
                    guard result==kCCSuccess,written==count else { throw invalid() }
                    bytes.replaceSubrange(local..<local+count,with:output)
                }
                p+=span.encrypted;stream+=span.encrypted
            }
        }
    }
    private static func decryptSample(_ bytes:inout [UInt8],offset:Int,size:Int,key:Data,iv:Data,spans:[(clear:Int,encrypted:Int)]) throws {
        var cryptor: CCCryptorRef?
        let status=key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCryptorCreateWithMode(CCOperation(kCCDecrypt),CCMode(kCCModeCTR),CCAlgorithm(kCCAlgorithmAES),CCPadding(ccNoPadding),
                v.baseAddress,k.baseAddress,key.count,nil,0,0,CCModeOptions(kCCModeOptionCTR_BE),&cryptor)
        } }
        guard status==kCCSuccess,let cryptor else { throw invalid() }; defer { CCCryptorRelease(cryptor) }
        var p=offset
        for span in spans {
            p+=span.clear
            if span.encrypted>0 {
                let input=Data(bytes[p..<p+span.encrypted]); var output=[UInt8](repeating:0,count:span.encrypted);var written=0
                let result=input.withUnsafeBytes { CCCryptorUpdate(cryptor,$0.baseAddress,input.count,&output,output.count,&written) }
                guard result==kCCSuccess,written==span.encrypted else { throw invalid() }
                bytes.replaceSubrange(p..<p+span.encrypted,with:output);p+=span.encrypted
            }
        }
    }
}
