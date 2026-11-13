import Foundation
import Combine

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var favorites=[Drama]()
    @Published private(set) var history=[WatchRecord]()
    /// 点过赞的作品（仅保存在本机，来源没有可用的点赞接口）
    @Published private(set) var liked=Set<String>()
    @Published var storageError:String?
    @Published var autoNext:Bool { didSet { UserDefaults.standard.set(autoNext,forKey:"autoNext") } }
    @Published var prefetch:Bool { didSet { UserDefaults.standard.set(prefetch,forKey:"prefetch") } }
    @Published var speed:Double { didSet { UserDefaults.standard.set(speed,forKey:"speed") } }
    private let file:URL
    private struct Saved:Codable { var favorites:[Drama];var history:[WatchRecord];var liked:[String]? }
    init(directory:URL?=nil) {
        let defaults=UserDefaults.standard
        autoNext=defaults.object(forKey:"autoNext") as? Bool ?? true
        prefetch=defaults.object(forKey:"prefetch") as? Bool ?? true
        let rate=defaults.double(forKey:"speed");speed=[0.75,1,1.25,1.5,2].contains(rate) ? rate : 1
        let root=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ManjuDuo",isDirectory:true)
        file=root.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:file.path) {
                let saved=try JSONDecoder().decode(Saved.self,from:Data(contentsOf:file))
                favorites=saved.favorites;history=saved.history;liked=Set(saved.liked ?? [])
            }
        } catch { storageError="本机记录无法读取，原文件已保留。请检查存储空间后重新打开。" }
    }
    func record(for id:String) -> WatchRecord? { history.first{$0.id==id} }
    func isFavorite(_ id:String) -> Bool { favorites.contains{$0.id==id} }
    func isLiked(_ id:String) -> Bool { liked.contains(id) }
    func toggleLike(_ drama:Drama) { if liked.contains(drama.id) { liked.remove(drama.id) } else { liked.insert(drama.id) };persist() }
    /// 记下「下一次从这一集开头看」（推荐流看完一集后进入剧内续播用）。
    func queue(drama:Drama,episode:Episode,duration:Double) { save(drama:drama,episode:episode,time:0,duration:max(1,duration)) }
    func toggle(_ drama:Drama) {
        if isFavorite(drama.id) { favorites.removeAll{$0.id==drama.id} } else { favorites.insert(drama.summary,at:0) }; persist()
    }
    func save(drama:Drama,episode:Episode,time:Double,duration:Double) {
        guard time.isFinite,duration.isFinite,duration>0,time>=0 else { return }
        let entry=WatchRecord(drama:drama.summary,episodeID:episode.id,order:episode.order,time:min(time,duration),duration:duration,updated:Date())
        history.removeAll{$0.id==drama.id};history.insert(entry,at:0);if history.count>200 { history=Array(history.prefix(200)) };persist()
    }
    func clearHistory() { history.removeAll();persist() }
    private func persist() {
        // A corrupt input must never be silently overwritten by an empty library.
        guard storageError==nil else { return }
        do { try JSONEncoder().encode(Saved(favorites:favorites,history:history,liked:liked.sorted())).write(to:file,options:.atomic) }
        catch { storageError="本机记录保存失败，请检查剩余空间。" }
    }
}

