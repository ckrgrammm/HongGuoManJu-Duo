import Foundation
import Combine

@MainActor final class CatalogModel: ObservableObject {
    @Published var items=[Drama]()
    @Published var loading=false
    @Published var error:String?
    @Published var hasMore=false
    @Published var query=""
    @Published var sort=CatalogSort.hot
    private(set) var page=0
    private var generation=UUID()
    private var task:Task<Void,Never>?
    private let provider:ContentProvider
    private let recommendations:Bool
    private let recentKey="recentRecommendationIDs"
    private var recentAtReload=Set<String>()
    private var recentOrder=[String]()
    private var backlog=[Drama]()
    private let nextStartKey="nextRecommendationStartPage"
    private var recommendationStart=1
    private var nextRecommendationPage=1
    /// 上次没看完的推荐列表：下次打开先用它，不等官网列表（约 0.6 秒），新的一页随后接在后面。
    private let queueKey="recommendationQueue"

    init(provider:ContentProvider,recommendations:Bool=false) {
        self.provider=provider
        self.recommendations=recommendations
    }

    func recordRecommendation(_ id:String) {
        guard recommendations else { return }
        var recent=UserDefaults.standard.stringArray(forKey:recentKey) ?? []
        recent.removeAll { $0==id }
        recent.insert(id,at:0)
        UserDefaults.standard.set(Array(recent.prefix(3000)),forKey:recentKey)
    }
    func reload() {
        task?.cancel();generation=UUID();page=0;items=[];hasMore=false;error=nil
        if recommendations {
            recentOrder=UserDefaults.standard.stringArray(forKey:recentKey) ?? []
            recentAtReload=Set(recentOrder);backlog=[]
            recommendationStart=max(1,UserDefaults.standard.integer(forKey:nextStartKey))
            nextRecommendationPage=recommendationStart
            if let data=UserDefaults.standard.data(forKey:queueKey),let saved=try? JSONDecoder().decode([Drama].self,from:data) {
                var seen=Set<String>()
                items=saved.filter { WebsiteParser.validID($0.id) && !recentAtReload.contains($0.id) && seen.insert($0.id).inserted }
            }
        }
        fetch(reset:true)
    }
    func more() { guard !loading,hasMore else { return };fetch(reset:false) }
    private func fetch(reset:Bool) {
        let token=generation,q=query.trimmingCharacters(in:.whitespacesAndNewlines),s=sort
        loading=true;error=nil
        task=Task {
            do {
                var first=reset,rounds=0,added=0
                repeat {
                    let next=recommendations ? nextRecommendationPage : (first ? 1 : page+1)
                    var result:CatalogPage
                    do {
                        result=try await (q.isEmpty ? provider.catalog(sort:s,page:next) : provider.search(query:q,page:next))
                    } catch {
                        try Task.checkCancellation()
                        guard recommendations,first,next>1 else { throw error }
                        result=try await provider.catalog(sort:s,page:1)
                    }
                    if recommendations,first,next>1,result.page != 1,result.items.isEmpty {
                        result=try await provider.catalog(sort:s,page:1)
                    }
                    try Task.checkCancellation();guard token==generation else { return }
                    var known=Set(items.map(\.id)).union(backlog.map(\.id))
                    let candidates=result.items.filter { known.insert($0.id).inserted }
                    if recommendations {
                        // 推荐只放没看过的；看过的先压在后面，整个片单都翻完了才拿出来。
                        let fresh=candidates.filter { !recentAtReload.contains($0.id) }.shuffled()
                        backlog+=candidates.filter { recentAtReload.contains($0.id) }
                        items+=fresh;added+=fresh.count
                    } else {
                        items+=candidates
                    }
                    page=result.page
                    if recommendations {
                        if first {
                            recommendationStart=result.page
                            UserDefaults.standard.set(result.hasMore ? result.page+1 : 1,forKey:nextStartKey)
                        }
                        nextRecommendationPage=result.hasMore ? result.page+1 : 1
                        hasMore=(result.hasMore || recommendationStart>1) && nextRecommendationPage != recommendationStart
                    } else {
                        hasMore=result.hasMore
                    }
                    first=false;rounds+=1
                    // 这一页全是看过的：接着翻下一页，直到凑出几部新的。
                } while recommendations && added<4 && hasMore && rounds<8
                if recommendations {
                    if !hasMore,!backlog.isEmpty {
                        // 片单翻完了：把看过的接上，最久没看的排前面。
                        let rank=Dictionary(recentOrder.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:{ a,_ in a })
                        items+=backlog.sorted { (rank[$0.id] ?? .max)>(rank[$1.id] ?? .max) };backlog=[]
                    }
                    if let data=try? JSONEncoder().encode(items.prefix(60).map(\.summary)) { UserDefaults.standard.set(data,forKey:queueKey) }
                }
                loading=false
            } catch is CancellationError { if token==generation { loading=false } }
            catch { if token==generation { self.error=error.localizedDescription;loading=false } }
        }
    }
}
