import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor final class PlayerModel:ObservableObject {
    let drama:Drama
    let player=AVPlayer()
    let library:LibraryStore
    @Published private(set) var episode:Episode?
    @Published private(set) var position=0.0
    @Published private(set) var duration=0.0
    @Published private(set) var definition=""
    /// 画面宽 / 高；0 = 还不知道
    @Published private(set) var aspect=0.0
    @Published private(set) var loading=false
    @Published private(set) var playing=false
    @Published private(set) var failure:String?
    @Published private(set) var finished=false
    @Published var scrubbing=false
    /// false：播完当前集就停在「已结束」，由外层决定下一步（推荐流：看完一集后进入剧内）。
    var continuous=true
    private var operation=UUID()
    private var loadTask:Task<Void,Never>?
    private let streamPreparation:StreamPreparation
    private let audioOwner=UUID()
    private var periodic:Any?
    private var endObserver:NSObjectProtocol?
    private var itemStatus:NSKeyValueObservation?
    private var rateStatus:NSKeyValueObservation?
    private var lastSaved=Date.distantPast
    private var ready=false
    private var wantsPlayback=true
    private var transientSpeed:Double?
    /// 当前这一集的边下边播会话（已缓存的集没有）。
    private var stream:StreamSession?
    init(drama:Drama,library:LibraryStore,streamPreparation:StreamPreparation?=nil) {
        self.drama=drama;self.library=library
        self.streamPreparation=streamPreparation ?? StreamPreparation()
        player.automaticallyWaitsToMinimizeStalling=true
        periodic=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.5,preferredTimescale:600),queue:.main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        rateStatus=player.observe(\.timeControlStatus,options:[.new]) { [weak self] _,_ in Task { @MainActor in
            guard let self else { return };self.playing=self.player.timeControlStatus == .playing
            if self.playing { Trace.mark("PLAYING") }
            else if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                Trace.mark("player waiting: \(self.player.reasonForWaitingToPlay?.rawValue ?? "unknown")")
            }
        } }
    }
    func start() {
        guard episode==nil,!drama.episodes.isEmpty else { return }
        let record=library.record(for:drama.id)
        let target=drama.episodes.first{$0.id==record?.episodeID} ?? drama.episodes[0]
        play(target,resume:record?.episodeID==target.id ? record?.time ?? 0 : 0)
    }
    /// `retried`：这一次已经是自动重试（拿新地址重新来一遍），再失败才提示用户。
    func play(_ target:Episode,resume:Double=0,retried:Bool=false) {
        checkpoint();loadTask?.cancel()
        player.pause();player.replaceCurrentItem(with:nil);clearItemObservers()
        stream?.cancel();stream=nil
        operation=UUID();let token=operation
        Trace.reset("play \(target.title)")
        episode=target;position=0;duration=0;definition="";aspect=0;loading=true;failure=nil;finished=false;ready=false;wantsPlayback=true
        loadTask=Task {
            do {
                let item=try await source(for:target,token:token,direct:retried)
                try Task.checkCancellation();guard token==operation else { return }
                itemStatus=item.observe(\.status,options:[.initial,.new]) { [weak self,weak item] _,_ in
                    Task { @MainActor in
                        guard let self,let item,token==self.operation else { return }
                        if item.status == .readyToPlay,!self.ready {
                            self.ready=true
                            Trace.mark("player item ready")
                            if self.duration<=0,item.duration.seconds.isFinite { self.duration=item.duration.seconds }
                            let size=item.presentationSize;if size.width>0,size.height>0 { self.aspect=Double(size.width/size.height) }
                            let start=max(0,min(resume,max(0,self.duration-0.5)))
                            if start==0 {
                                self.loading=false
                                if self.wantsPlayback {
                                    Trace.mark("playImmediately requested")
                                    self.player.playImmediately(atRate:Float(self.library.speed))
                                }
                                self.checkpoint();self.prefetchNext()
                                return
                            }
                            Trace.mark("resume seek started at \(start)s")
                            let tolerance=CMTime(seconds:0.5,preferredTimescale:600)
                            self.player.seek(to:CMTime(seconds:start,preferredTimescale:600),toleranceBefore:tolerance,toleranceAfter:tolerance) { [weak self] success in
                                Task { @MainActor in
                                    guard let self,token==self.operation else { return }
                                    Trace.mark("resume seek finished: \(success)")
                                    let actual=self.player.currentTime().seconds
                                    self.position=actual.isFinite ? actual : start;self.loading=false
                                    if self.wantsPlayback {
                                    Trace.mark("playImmediately requested")
                                    self.player.playImmediately(atRate:Float(self.library.speed))
                                }
                                    self.checkpoint();self.prefetchNext()
                                }
                            }
                        } else if item.status == .failed {
                            Trace.mark("player item failed: \(item.error?.localizedDescription ?? "unknown error")")
                            if !retried { Trace.mark("retrying automatically with a fresh address");self.play(target,resume:resume,retried:true);return }
                            self.loading=false;self.failure="播放器无法打开这一集，请重试。";self.ready=false
                        }
                    }
                }
                endObserver=NotificationCenter.default.addObserver(forName:AVPlayerItem.didPlayToEndTimeNotification,object:item,queue:.main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self,token==self.operation else { return }
                        self.position=self.duration;self.checkpoint()
                        if self.continuous,self.library.autoNext,let next=self.next { self.play(next) }
                        else { self.finished=true;self.player.pause() }
                    }
                }
                // 续播：先告诉播放器要从哪里开始，它就不会先去读片头再跳。
                if resume>1 {
                    let tolerance=CMTime(seconds:0.5,preferredTimescale:600)
                    item.seek(to:CMTime(seconds:resume,preferredTimescale:600),toleranceBefore:tolerance,toleranceAfter:tolerance,completionHandler:nil)
                }
                player.replaceCurrentItem(with:item)
                PlaybackAudio.activate(audioOwner)
            } catch is CancellationError { }
            catch {
                guard token==operation else { return }
                Trace.mark("playback failed: \(error.localizedDescription)")
                // 编码解不了的集重试也一样，不白等。
                if !retried,error.localizedDescription != NativePlayback.noTrack { Trace.mark("retrying automatically with a fresh address");play(target,resume:resume,retried:true);return }
                loading=false;failure=error.localizedDescription
            }
        }
    }
    /// 铺满（裁边放大）只在画面方向和容器方向一致时才用，否则会裁掉大半画面。
    func shouldFill(_ preferred:Bool,container:CGSize) -> Bool {
        guard preferred,aspect>0,container.width>0,container.height>0 else { return false }
        return (aspect>1) == (container.width>container.height)
    }
    /// `direct`：自动重试时，不加密的来源直接交给播放器（不走边下边播），作为保底。
    private func source(for target:Episode,token:UUID,direct:Bool) async throws -> AVPlayerItem {
        if let (url,media)=try await MediaCache.shared.cached(target.id) {
            duration=media.duration;definition=media.definition
            return AVPlayerItem(url:url)
        }

        let warmed=await streamPreparation.take(drama.id,episodeID:target.id)
        if Task.isCancelled || token != operation {
            warmed?.cancel()
            throw CancellationError()
        }
        if let warmed,await warmed.resumePlayback() {
            guard !Task.isCancelled,token==operation else { warmed.cancel();throw CancellationError() }
            stream=warmed
            Trace.mark("reusing prepared stream")
            return streamItem(warmed)
        }

        warmed?.cancel()
        try Task.checkCancellation()
        Trace.mark("requesting play address")
        let resource=try await MediaCache.shared.resource(target.id)
        Trace.mark("got play address \(resource.definition) \(resource.size/1024) KB")
        try Task.checkCancellation()
        guard token==operation else { throw CancellationError() }
        if resource.contentKey==nil,direct {
            duration=resource.duration;definition=resource.definition
            return AVPlayerItem(url:resource.url)
        }

        let session=StreamSession(resource:resource,file:try await MediaCache.shared.streamFile())
        try Task.checkCancellation()
        guard token==operation else { throw CancellationError() }
        stream=session
        do { try await session.start() }
        catch { session.cancel();if stream===session { stream=nil };throw error }
        guard token==operation else { session.cancel();throw CancellationError() }
        Trace.mark("stream index ready")
        return streamItem(session)
    }

    private func streamItem(_ session:StreamSession) -> AVPlayerItem {
        duration=session.resource.duration;definition=session.resource.definition
        let asset=AVURLAsset(url:session.assetURL)
        asset.resourceLoader.setDelegate(session,queue:session.queue)
        return AVPlayerItem(asset:asset)
    }
    var next:Episode? { guard let episode,let index=drama.episodes.firstIndex(of:episode),index+1<drama.episodes.count else { return nil };return drama.episodes[index+1] }
    var previous:Episode? { guard let episode,let index=drama.episodes.firstIndex(of:episode),index>0 else { return nil };return drama.episodes[index-1] }
    func retry() { guard let episode else { return };let resume=position>0 ? position : (library.record(for:drama.id)?.episodeID==episode.id ? library.record(for:drama.id)?.time ?? 0 : 0);play(episode,resume:resume) }
    func toggle() {
        guard ready else { return }
        if player.timeControlStatus == .playing { wantsPlayback=false;player.pause() }
        else { if finished { seek(0);finished=false };wantsPlayback=true;player.playImmediately(atRate:Float(library.speed)) }
    }
    func pause() { wantsPlayback=false;player.pause();checkpoint() }
    func seek(_ seconds:Double) {
        guard ready,seconds.isFinite else { return }
        position=min(max(0,seconds),duration);finished=false
        player.seek(to:CMTime(seconds:position,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
        checkpoint()
    }
    func setSpeed(_ speed:Double) { library.speed=speed;if player.timeControlStatus == .playing { player.rate=Float(speed) } }
    func longPress(_ active:Bool) {
        if active { transientSpeed=Double(player.rate);if playing { player.rate=2 } }
        else if let rate=transientSpeed { if playing { player.rate=Float(rate) };transientSpeed=nil }
    }
    private func tick(_ seconds:Double) {
        guard ready,seconds.isFinite,seconds>=0,!scrubbing else { return };position=seconds
        if Date().timeIntervalSince(lastSaved)>5 { checkpoint() }
    }
    func checkpoint() {
        guard ready,let episode else { return };library.save(drama:drama,episode:episode,time:position,duration:duration);lastSaved=Date()
    }
    func prefetchNext() {
        guard continuous else { return }
        guard library.prefetch,let next else { streamPreparation.keep([]);return }
        streamPreparation.prepare(drama.id) { (next.id,0) }
    }
    func stop() {
        checkpoint();operation=UUID();loadTask?.cancel();player.pause();player.replaceCurrentItem(with:nil)
        if continuous { streamPreparation.keep([]) }
        stream?.cancel();stream=nil
        clearItemObservers();ready=false
        if let periodic { player.removeTimeObserver(periodic);self.periodic=nil };rateStatus=nil
        PlaybackAudio.deactivate(audioOwner)
    }
    private func clearItemObservers() {
        itemStatus=nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver);self.endObserver=nil }
    }
}


@MainActor final class StreamPreparation:ObservableObject {
    private var pending=[String:Task<StreamSession?,Never>]()

    /// `target` 返回要备的分集和续播位置（占全长的比例，0 = 从头）。
    func prepare(_ dramaID:String,target:@escaping @MainActor () async throws -> (String,Double)) {
        guard pending[dramaID]==nil else { return }
        pending[dramaID]=Task {
            var session:StreamSession?
            do {
                let (id,fraction)=try await target()
                try Task.checkCancellation()
                guard try await MediaCache.shared.cached(id)==nil else { return nil }
                let resource=try await MediaCache.shared.resource(id)
                try Task.checkCancellation()
                let prepared=StreamSession(resource:resource,file:try await MediaCache.shared.streamFile())
                session=prepared
                try await prepared.start(warming:true,resumeFraction:fraction)
                try Task.checkCancellation()
                return prepared
            } catch {
                session?.cancel()
                return nil
            }
        }
    }

    func take(_ dramaID:String,episodeID:String) async -> StreamSession? {
        guard let task=pending.removeValue(forKey:dramaID) else { return nil }
        let session=await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard let session else { return nil }
        guard session.resource.episodeID==episodeID else { session.cancel();return nil }
        return session
    }

    func keep(_ dramaIDs:Set<String>) {
        for id in Set(pending.keys).subtracting(dramaIDs) {
            guard let task=pending.removeValue(forKey:id) else { continue }
            task.cancel()
            Task { let session=await task.value;session?.cancel() }
        }
    }
}

private enum PlaybackAudio {
    private static let queue=DispatchQueue(label:"manju.playback.audio",qos:.userInitiated)
    nonisolated(unsafe) private static var owner:UUID?

    static func activate(_ id:UUID) {
        queue.async {
            if owner==nil {
                let audio=AVAudioSession.sharedInstance()
                try? audio.setCategory(.playback,mode:.moviePlayback)
                try? audio.setActive(true)
            }
            owner=id
        }
    }

    static func deactivate(_ id:UUID) {
        queue.async {
            guard owner==id else { return }
            owner=nil
            try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
        }
    }
}
