import Foundation
import AVFoundation

struct CachedMedia: Codable, Sendable {
    let episodeID: String
    let definition: String
    let duration: Double
    let filename: String
    let bytes: Int
    var touched: Date
}
struct CacheStats: Sendable { let files:Int;let bytes:Int }
private final class MediaDownloadPolicy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {
        completionHandler(request.url.map(NativePlayback.allowedMedia)==true ? request : nil)
    }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {}
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
        if totalBytesWritten>100*1024*1024 || totalBytesExpectedToWrite>100*1024*1024 { downloadTask.cancel() }
    }
}
actor MediaCache {
    static let shared=MediaCache()
    private let root:URL
    private let playback=NativePlayback()
    private let policy=MediaDownloadPolicy()
    private lazy var session=URLSession(configuration:.ephemeral,delegate:policy,delegateQueue:nil)
    private var entries=[String:CachedMedia]()
    private var flights=[String:(UUID,Task<CachedMedia,Error>)]()
    private var loaded=false
    private var generation=0
    private let budget=Int64(1024*1024*1024)
    init(root:URL?=nil) {
        self.root=root ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ManjuMedia",isDirectory:true)
    }
    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var directory=root; var values=URLResourceValues();values.isExcludedFromBackup=true;try? directory.setResourceValues(values)
        if let data=try? Data(contentsOf:root.appendingPathComponent("index.json")),let saved=try? JSONDecoder().decode([CachedMedia].self,from:data) {
            for item in saved where WebsiteParser.validID(item.episodeID) && UUID(uuidString:String(item.filename.dropLast(4))) != nil && item.filename.hasSuffix(".mp4") {
                if FileManager.default.fileExists(atPath:root.appendingPathComponent(item.filename).path) { entries[item.episodeID]=item }
            }
        }
        // Remove files orphaned by interruption without trusting names from remote data.
        let live=Set(entries.values.map(\.filename))
        // 上次没下完的边下边播半成品（.part）也一并清掉。
        for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where (file.pathExtension=="mp4" && !live.contains(file.lastPathComponent)) || file.pathExtension=="part" { try? FileManager.default.removeItem(at:file) }
        loaded=true
    }
    private func persist() throws { try JSONEncoder().encode(Array(entries.values)).write(to:root.appendingPathComponent("index.json"),options:.atomic) }
    func cachedURL(_ id:String) throws -> URL? { try load(); return entries[id].map { root.appendingPathComponent($0.filename) } }
    // MARK: 边下边播

    /// 已经完整缓存的一集（不联网）。
    func cached(_ id:String) throws -> (URL,CachedMedia)? {
        try load()
        guard var entry=entries[id] else { return nil }
        entry.touched=Date();entries[id]=entry
        return (root.appendingPathComponent(entry.filename),entry)
    }
    /// 这一集是否正在后台整集预取（是的话直接等它，比重新取更快）。
    func inFlight(_ id:String) -> Bool { flights[id] != nil }
    /// 向来源要播放地址和密钥（不下载媒体）。
    func resource(_ id:String) async throws -> MediaResource { try await playback.resource(episodeID:id) }
    /// 边下边播用的临时文件位置：放在缓存目录里，下完后可以原地改名转正。
    func streamFile() throws -> URL { try load();return root.appendingPathComponent(UUID().uuidString+".part") }
    /// 边下边播已把整集取完并解密：转入正式缓存，重看不再联网。
    func adopt(_ id:String,part:URL,bytes:Int,definition:String,duration:Double) {
        guard (try? load()) != nil,duration.isFinite,duration>0,bytes>0,entries[id]==nil,flights[id]==nil,
              FileManager.default.fileExists(atPath:part.path) else { try? FileManager.default.removeItem(at:part);return }
        let filename=UUID().uuidString+".mp4",destination=root.appendingPathComponent(filename)
        do {
            try FileManager.default.moveItem(at:part,to:destination)
            entries[id]=CachedMedia(episodeID:id,definition:definition,duration:duration,filename:filename,bytes:bytes,touched:Date())
            try evict(protect:id);try persist()
        } catch { entries[id]=nil;try? FileManager.default.removeItem(at:part);try? FileManager.default.removeItem(at:destination) }
    }

    func prepare(_ id:String) async throws -> (URL,CachedMedia) {
        try load(); try Task.checkCancellation()
        if var entry=entries[id] {
            entry.touched=Date();entries[id]=entry
            return (root.appendingPathComponent(entry.filename),entry)
        }
        let identifier:UUID,task:Task<CachedMedia,Error>
        if let flight=flights[id] { (identifier,task)=flight }
        else {
            identifier=UUID();let stamp=generation
            task=Task { try await self.fetch(id,generation:stamp) }; flights[id]=(identifier,task)
        }
        do {
            let result=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
            if flights[id]?.0==identifier { flights[id]=nil }
            try Task.checkCancellation(); return (root.appendingPathComponent(result.filename),result)
        } catch { if flights[id]?.0==identifier { flights[id]=nil }; throw error }
    }
    private func fetch(_ id:String,generation stamp:Int) async throws -> CachedMedia {
        let resource=try await playback.resource(episodeID:id);try Task.checkCancellation()
        let volume=try? root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let free=volume,free<Int64(max(resource.size,50*1024*1024)*3) { throw ManjuError.message("存储空间不足，请先清理缓存。") }
        var request=URLRequest(url:resource.url);request.timeoutInterval=90
        let (temp,response)=try await session.download(for:request)
        defer { try? FileManager.default.removeItem(at:temp) }
        guard let response=response as? HTTPURLResponse,response.statusCode==200 else { throw ManjuError.message("媒体下载失败，请重试当前集。") }
        try Task.checkCancellation()
        let size=(try FileManager.default.attributesOfItem(atPath:temp.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size>0,size<=100*1024*1024,resource.size==0 || size==resource.size else { throw ManjuError.message("媒体下载不完整或单集过大，请重试。") }
        let filename=UUID().uuidString+".mp4",destination=root.appendingPathComponent(filename)
        let processing=Task.detached(priority:.userInitiated) {
            try Task.checkCancellation()
            if let key=resource.contentKey {
                let data=try CENCMedia.decrypt(Data(contentsOf:temp,options:.mappedIfSafe),key:key)
                try Task.checkCancellation();try data.write(to:destination,options:.atomic)
            } else { try FileManager.default.copyItem(at:temp,to:destination) }
        }
        do {
            try await withTaskCancellationHandler(operation:{try await processing.value},onCancel:{processing.cancel()})
            try Task.checkCancellation();guard stamp==generation else { throw CancellationError() }
            let asset=AVURLAsset(url:destination)
            let playable=try await asset.load(.isPlayable),tracks=try await asset.loadTracks(withMediaType:.video),audio=try await asset.loadTracks(withMediaType:.audio)
            let duration=try await asset.load(.duration).seconds
            guard playable,!tracks.isEmpty,!audio.isEmpty,duration.isFinite,duration>0,
                  resource.duration==0 || abs(duration-resource.duration)<max(2,resource.duration*0.03) else { throw ManjuError.message("当前设备无法完整播放这一集，请重试或选择其他作品。") }
            try Task.checkCancellation();guard stamp==generation else { throw CancellationError() }
            let bytes=(try FileManager.default.attributesOfItem(atPath:destination.path)[.size] as? NSNumber)?.intValue ?? size
            let result=CachedMedia(episodeID:id,definition:resource.definition,duration:duration,filename:filename,bytes:bytes,touched:Date())
            entries[id]=result
            do { try evict(protect:id);try persist() }
            catch { entries[id]=nil;throw error }
            return result
        } catch { try? FileManager.default.removeItem(at:destination);throw error }
    }
    private func evict(protect:String) throws {
        var total=entries.values.reduce(Int64(0)){$0+Int64($1.bytes)}
        for entry in entries.values.sorted(by:{$0.touched<$1.touched}) where total>budget && entry.episodeID != protect {
            try FileManager.default.removeItem(at:root.appendingPathComponent(entry.filename));entries[entry.episodeID]=nil;total-=Int64(entry.bytes)
        }
    }
    func stats() throws -> CacheStats { try load();return CacheStats(files:entries.count,bytes:entries.values.reduce(0){$0+$1.bytes}) }
    func clear() async throws {
        generation+=1
        let pending=flights.values.map(\.1);for task in pending { task.cancel() };flights.removeAll()
        for task in pending { _ = try? await task.value }
        try load()
        for entry in Array(entries.values) { try FileManager.default.removeItem(at:root.appendingPathComponent(entry.filename));entries[entry.episodeID]=nil }
        try persist()
    }
}
