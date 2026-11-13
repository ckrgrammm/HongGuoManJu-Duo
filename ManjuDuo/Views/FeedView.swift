import SwiftUI
import AVFoundation

/// 推荐流：打开 App 直接进入，整页上下滑切剧（沿用 DouDuo 的分页流 + 右侧操作栏布局）。
/// 本视图铺满全屏（含 Duo 右侧系统控制条下方），真实安全区由外层通过 `insets` 传入。
struct FeedView:View {
    @ObservedObject var catalog:CatalogModel
    let provider:ContentProvider
    @ObservedObject var library:LibraryStore
    let active:Bool
    let insets:EdgeInsets
    /// 右侧给操作栏让出的宽度（文字不压到按钮下面）
    let railReserve:CGFloat
    @Binding var current:Drama?
    let onOpen:(Drama)->Void
    @AppStorage("fillVideo") private var fill=true
    @State private var position:String?
    @State private var playingID:String?
    @State private var scrollIdle=true
    @GestureState private var dragging=false
    @State private var scheduledCurrentID:String?
    @StateObject private var streamPreparation=StreamPreparation()

    var body:some View {
        GeometryReader { geo in
            let full=geo.size
            ZStack {
                Color.black
                if catalog.items.isEmpty { placeholder }
                else {
                    ScrollViewReader { proxy in
                    observePaging(ScrollView(.vertical) {
                        LazyVStack(spacing:0) {
                            ForEach(catalog.items) { item in
                                FeedPage(summary:item,provider:provider,library:library,streamPreparation:streamPreparation,playing:active && item.id==playingID,
                                         fill:fill,container:full,insets:insets,railReserve:railReserve,onOpen:onOpen,onFinished:{ advance(from:item.id) })
                                    .frame(width:full.width,height:full.height)
                                    .id(item.id)
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id:$position)
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea())
                    // 折叠 / 展开 / 旋转后每页高度变了，滚动偏移不会自己跟着变，重新对齐到当前这一页。
                    .onChange(of:full) { _,_ in
                        guard let id=playingID ?? position else { return }
                        DispatchQueue.main.async { proxy.scrollTo(id,anchor:.top) }
                    }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of:catalog.items.first?.id,initial:true) { _,first in
            if first==nil { playingID=nil }
            if position==nil || !catalog.items.contains(where:{$0.id==position}) { position=first }
        }
        .onChange(of:playingID,initial:true) { _,id in moved(to:id) }
        .onChange(of:active) { _,_ in prepareNext() }
        .onChange(of:catalog.items.count) { _,_ in prepareNext() }
        .onChange(of:library.prefetch) { _,_ in prepareNext() }
        .onDisappear { streamPreparation.keep([]) }
    }

    @ViewBuilder
    private func observePaging<Content:View>(_ scroll:Content) -> some View {
        if #available(iOS 18, *) {
            scroll
                .onScrollPhaseChange { _,phase in
                    scrollIdle=phase == .idle
                    if scrollIdle { playingID=position }
                }
                .onChange(of:position,initial:true) { _,id in
                    if scrollIdle { playingID=id }
                }
        } else {
            // iOS 17 does not expose scroll phases. Hold playback during the drag,
            // then wait for the page ID to stabilize before switching.
            scroll
                .simultaneousGesture(DragGesture().updating($dragging) { _,state,_ in state=true })
                .task(id:dragging ? nil : position) {
                    guard !dragging,let id=position else { return }
                    if playingID != nil {
                        do { try await Task.sleep(for:.milliseconds(250)) }
                        catch { return }
                    }
                    guard !Task.isCancelled,!dragging,position==id else { return }
                    playingID=id
                }
        }
    }

    private var placeholder:some View {
        VStack(spacing:16) {
            if let error=catalog.error { InlineError(message:error) { catalog.reload() } }
            else { ProgressView("正在获取漫剧…").tint(.white).foregroundStyle(.white) }
        }.padding(.trailing,railReserve)
    }

    /// 一集播完：自动滑到下一部推荐。已经是最后一部（后面还没加载出来）时返回 false，由当前页重播。
    private func advance(from id:String) -> Bool {
        let items=catalog.items
        guard active,playingID==id,let index=items.firstIndex(where:{$0.id==id}),index+1<items.count else { return false }
        withAnimation(.easeInOut(duration:0.35)) { position=items[index+1].id }
        return true
    }

    private func moved(to id:String?) {
        let items=catalog.items
        guard let index=items.firstIndex(where:{$0.id==id}) else { current=nil;return }
        current=items[index]
        catalog.recordRecommendation(items[index].id)
        if index>=items.count-3 { catalog.more() }
        prepareNext()
    }

    private func prepareNext() {
        let items=catalog.items
        guard active,library.prefetch,let id=playingID,
              let index=items.firstIndex(where:{$0.id==id}) else {
            streamPreparation.keep([])
            scheduledCurrentID=nil
            return
        }
        // 当前这部 + 后面两部提前备好（地址、索引、开头约 1 MB），滑过去直接从本机数据开播。
        let window=items.dropFirst(index).prefix(3)
        streamPreparation.keep(Set(window.map(\.id)))
        let previousID=scheduledCurrentID
        scheduledCurrentID=id
        for next in window where next.id != id || previousID==nil {
            streamPreparation.prepare(next.id) {
                let detail=try await provider.detail(id:next.id)
                let record=library.record(for:detail.id)
                guard let episode=detail.episodes.first(where:{$0.id==record?.episodeID}) ?? detail.episodes.first else {
                    throw ManjuError.message("没有可播放的分集。")
                }
                // 上次看到一半：把续播位置附近的数据也提前取好（往前留 6 秒给关键帧）。
                let resume=record?.episodeID==episode.id ? record : nil
                return (episode.id,resume.map { $0.duration>0 && $0.time>1 ? max(0,($0.time-6)/$0.duration) : 0 } ?? 0)
            }
        }
    }
}

private struct FeedPage:View {
    let summary:Drama
    let provider:ContentProvider
    @ObservedObject var library:LibraryStore
    let streamPreparation:StreamPreparation
    let playing:Bool
    let fill:Bool
    let container:CGSize
    let insets:EdgeInsets
    let railReserve:CGFloat
    let onOpen:(Drama)->Void
    let onFinished:()->Bool
    @State private var drama:Drama?
    @State private var error:String?
    @State private var revision=0

    var body:some View {
        ZStack {
            poster
            if playing {
                if let drama { FeedPlayer(drama:drama,library:library,streamPreparation:streamPreparation,fill:fill,container:container,bottomInset:insets.bottom,onFinished:onFinished).id(drama.id) }
                else if let error { InlineError(message:error) { self.error=nil;revision+=1 }.frame(maxWidth:320).background(Studio.surface,in:RoundedRectangle(cornerRadius:18)) }
                else { ProgressView().scaleEffect(1.25).tint(.white) }
            }
            info
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .clipped()
        .task(id:"\(playing)-\(revision)") {
            guard playing,drama==nil else { return }
            Trace.reset("feed page \(summary.title): fetching episode list")
            do { drama=try await provider.detail(id:summary.id);Trace.mark("episode list fetched (shown above the next 'play' line)") }
            catch is CancellationError { }
            catch { self.error=error.localizedDescription }
        }
    }

    /// 还没开播 / 画面没铺满时的底：封面虚化铺底 + 完整封面居中。
    private var poster:some View {
        Color.black
            .overlay { AsyncImage(url:summary.coverURL) { image in image.resizable().scaledToFill() } placeholder:{ Color.clear }.blur(radius:40).opacity(0.55) }
            .clipped()
            .overlay { if !playing || drama==nil { Cover(drama:summary).frame(maxWidth:220).padding(.trailing,railReserve).padding(.vertical,90) } }
    }

    /// 内容到屏幕边缘的留白（同 DouDuo：宽屏约 28pt，窄屏 16pt）
    private var margin:CGFloat { container.width>=700 ? 28 : 16 }
    private var info:some View {
        let order=library.record(for:summary.id)?.order ?? 1
        return VStack(alignment:.leading,spacing:8) {
            Spacer(minLength:0)
            Text(summary.title).font(.headline).lineLimit(1)
            if !summary.tags.isEmpty {
                HStack(spacing:6) { ForEach(summary.tags.prefix(4),id:\.self) { tag in
                    Text(tag).font(.caption2.weight(.medium)).padding(.horizontal,7).padding(.vertical,3).background(.white.opacity(0.16),in:RoundedRectangle(cornerRadius:5))
                } }
            }
            // 简介只在窄屏（画面上下有留白）显示；宽屏铺满时画面自带字幕，文字块尽量小、不压字幕。
            if container.width<700,!summary.intro.isEmpty { Text(summary.intro).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2) }
            Button { onOpen(summary) } label:{
                HStack(spacing:6) {
                    Image(systemName:"play.rectangle.fill")
                    Text("第 \(order) 集 · 选集 · 全 \(summary.total) 集").lineLimit(1)
                    Image(systemName:"chevron.right").font(.caption2.weight(.bold))
                }.font(.caption.weight(.semibold)).padding(.horizontal,12).padding(.vertical,8).background(.black.opacity(0.45),in:Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("feed-open")
        }
        .foregroundStyle(.white)
        .shadow(color:.black.opacity(0.6),radius:3,y:1)
        .frame(maxWidth:container.width>=700 ? 300 : 520,alignment:.leading)
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomLeading)
        .padding(.leading,insets.leading+margin).padding(.trailing,railReserve+margin)
        .padding(.top,insets.top+90).padding(.bottom,insets.bottom+(container.width>=700 ? 30 : 22))
    }
}

/// 当前页的播放层：只在这一页是当前页且推荐流在前台时存在，离开即保存进度并释放播放器。
private struct FeedPlayer:View {
    @StateObject private var model:PlayerModel
    let fill:Bool
    let container:CGSize
    let bottomInset:CGFloat
    let onFinished:()->Bool
    @State private var scrubValue=0.0
    @State private var gestureStart=0.0
    init(drama:Drama,library:LibraryStore,streamPreparation:StreamPreparation,fill:Bool,container:CGSize,bottomInset:CGFloat,onFinished:@escaping ()->Bool) {
        let model=PlayerModel(drama:drama,library:library,streamPreparation:streamPreparation);model.continuous=false
        _model=StateObject(wrappedValue:model);self.fill=fill;self.container=container;self.bottomInset=bottomInset;self.onFinished=onFinished
    }
    var body:some View {
        ZStack {
            PlayerSurface(player:model.player,fill:model.shouldFill(fill,container:container)).opacity(model.loading ? 0 : 1)
            PlayerGestureView(onSingleTap:{model.toggle()},onDoubleTap:{x,width in model.seek(model.position+(x<width/2 ? -10 : 10))},onLongPress:{model.longPress($0)},
                onSeekBegan:{gestureStart=model.position;scrubValue=model.position;model.scrubbing=true},
                onSeekChanged:{delta,width in guard width>0 else { return };scrubValue=min(max(gestureStart+Double(delta/width)*max(30,model.duration),0),model.duration)},
                onSeekEnded:{model.scrubbing=false;model.seek(scrubValue)},verticalFirst:true)
            if model.loading {
                VStack(spacing:10) { ProgressView().scaleEffect(1.2).tint(.white);Text("正在准备 \(model.episode?.title ?? "")").font(.caption) }
                    .padding(18).background(.black.opacity(0.6),in:RoundedRectangle(cornerRadius:16)).allowsHitTesting(false)
            } else if let failure=model.failure {
                VStack(spacing:12) { Text(failure).font(.subheadline).multilineTextAlignment(.center);Button("重试") { model.retry() }.buttonStyle(.borderedProminent) }
                    .padding(20).frame(maxWidth:300).background(Studio.surface,in:RoundedRectangle(cornerRadius:16))
            } else if model.finished {
                Button("重新播放") { model.seek(0);model.toggle() }.buttonStyle(.borderedProminent)
            } else if model.scrubbing {
                Text("\(clockText(scrubValue)) / \(clockText(model.duration))").font(.title3.monospacedDigit().weight(.semibold))
                    .padding(.horizontal,16).padding(.vertical,10).background(.black.opacity(0.6),in:Capsule()).allowsHitTesting(false)
            } else if !model.playing {
                Image(systemName:"play.fill").font(.system(size:54)).foregroundStyle(.white.opacity(0.7)).allowsHitTesting(false)
            }
            GeometryReader { geo in
                let progress=model.duration>0 ? min(1,max(0,(model.scrubbing ? scrubValue : model.position)/model.duration)) : 0
                ZStack(alignment:.leading) {
                    Rectangle().fill(.white.opacity(0.22))
                    Rectangle().fill(Studio.accent).frame(width:geo.size.width*progress)
                }.frame(height:model.scrubbing ? 4 : 2).frame(maxHeight:.infinity,alignment:.bottom).padding(.bottom,max(6,bottomInset*0.4))
            }.allowsHitTesting(false)
        }
        .foregroundStyle(.white)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // 推荐流只放一集：看完自动换下一部推荐。这部剧记到下一集开头，之后从选集 / 足迹进去能接着看。
        .onChange(of:model.finished) { _,done in
            guard done else { return }
            if let next=model.next { model.library.queue(drama:model.drama,episode:next,duration:model.duration) }
            if !onFinished(),let episode=model.episode { model.play(episode) }
        }
    }
}
