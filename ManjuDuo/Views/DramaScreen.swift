import SwiftUI
import AVFoundation
import UIKit

struct DramaScreen:View {
    let summary:Drama
    let provider:ContentProvider
    @EnvironmentObject private var library:LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var drama:Drama?
    @State private var error:String?
    @State private var revision=0
    var body:some View {
        Group {
            if let drama { DramaPlayerView(drama:drama,library:library) }
            else {
                VStack(spacing:24) {
                    HStack { Button { dismiss() } label:{Image(systemName:"chevron.down").font(.title2)};Spacer() }.padding()
                    Spacer()
                    Cover(drama:summary).frame(width:160)
                    Text(summary.title).font(.title2.bold()).multilineTextAlignment(.center).padding(.horizontal)
                    if let error { InlineError(message:error) { self.error=nil;revision+=1 } }
                    else { ProgressView("正在获取选集…").tint(.white) }
                    Spacer();Spacer()
                }.background(Studio.background)
            }
        }.preferredColorScheme(.dark).tint(Studio.accent)
        .task(id:revision) {
            do { drama=try await provider.detail(id:summary.id) }
            catch is CancellationError { }
            catch { self.error=error.localizedDescription }
        }
    }
}
struct DramaPlayerView:View {
    @StateObject private var model:PlayerModel
    @ObservedObject private var library:LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var panel=true
    @State private var panelDecided=false
    /// 全屏观看时点一下画面：标题、进度条、右侧按钮一起收起 / 显示。
    @State private var chrome=true
    /// 上下滑切集时画面的竖向位移：跟手 → 滑出 → 新一集从另一边滑进来。
    @State private var slide:CGFloat=0
    @State private var scrubValue=0.0
    @State private var gestureStart=0.0
    @State private var segment=0
    @AppStorage("fillVideo") private var fill=true
    init(drama:Drama,library:LibraryStore) {
        self.library=library;_model=StateObject(wrappedValue:PlayerModel(drama:drama,library:library))
    }
    var body:some View {
        GeometryReader { geometry in
            let wide=geometry.size.width>=700 || (geometry.size.width>geometry.size.height && geometry.size.width>=600)
            // Duo 右侧系统控制条：有就把操作按钮放进去
            let strip=geometry.safeAreaInsets.trailing
            let inStrip=strip>=62
            Group {
                if panel {
                    VStack(spacing:0) {
                        header(solid:true,actions:!inStrip)
                        if wide {
                            HStack(spacing:0) {
                                videoBox.frame(maxWidth:.infinity,maxHeight:.infinity)
                                episodes.frame(width:min(380,geometry.size.width*0.38)).background(Studio.background)
                            }
                        } else {
                            VStack(spacing:0) {
                                videoBox.frame(maxWidth:.infinity,maxHeight:.infinity)
                                episodes.frame(height:min(310,geometry.size.height*0.40)).background(Studio.background)
                            }
                        }
                    }
                } else {
                    // 全屏观看：画面铺满整块屏幕（含控制条下方和圆角），标题和进度条压在画面上，不留黑边。
                    ZStack {
                        videoLayer(fill:model.shouldFill(fill,container:geometry.size)).ignoresSafeArea()
                        if chrome { VStack(spacing:0) { header(solid:false,actions:!inStrip);Spacer(minLength:0);controls }.transition(.opacity) }
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .stripColumn(bottom:geometry.safeAreaInsets.bottom+(geometry.size.height<600 ? 8 : 26)) { if inStrip,panel || chrome { stripActions(compact:geometry.size.height<600).transition(.opacity) } }
            // 返回按钮放在控制条里、时钟和状态环正下方（内屏横向约 126pt，外屏竖向有前摄，再往下一点）。
            .stripTop(top:geometry.size.height>geometry.size.width ? 166 : 126) {
                if inStrip,panel || chrome {
                    Button { dismiss() } label:{ Image(systemName:"chevron.down").font(.system(size:17,weight:.semibold)).frame(width:44,height:44).studioGlassCircle() }
                        .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel("返回片单").accessibilityIdentifier("drama-back")
                }
            }
            // 宽屏（Duo 内屏）进来直接全屏看，选集收在右侧按钮里；窄屏保持上视频下选集。
            .onAppear { if !panelDecided { panel = !wide;panelDecided=true } }
        }
        .preferredColorScheme(.dark).tint(Studio.accent)
        // 全屏观看收起按钮时，系统的时间 / Wi-Fi 那一块也一起收起；再点一下画面都回来。
        .statusBarHidden(!panel && !chrome)
        .persistentSystemOverlays(!panel && !chrome ? .hidden : .automatic)
        .onAppear { model.start();segment=max(0,((library.record(for:model.drama.id)?.order ?? 1)-1)/100) }
        .onDisappear { model.stop() }
        .onChange(of:phase) { _,new in if new != .active { model.pause() } }
        .onChange(of:library.prefetch) { _,_ in model.prefetchNext() }
        .onChange(of:model.episode?.id) { _,_ in if let order=model.episode?.order { segment=(order-1)/100 } }
    }
    private var favorite:Bool { library.isFavorite(model.drama.id) }
    private var liked:Bool { library.isLiked(model.drama.id) }
    private var shareText:String { "\(model.drama.title) \(model.drama.webURL.absoluteString)" }
    private func togglePanel() { withAnimation(.easeInOut(duration:0.22)) { panel.toggle();chrome=true } }
    private func header(solid:Bool,actions:Bool) -> some View {
        HStack(spacing:10) {
            // 有控制条时返回按钮在控制条里（时钟下方），顶栏只留标题。
            if actions { Button { dismiss() } label:{Image(systemName:"chevron.down").frame(width:34,height:40)}.accessibilityLabel("返回片单") }
            VStack(alignment:.leading,spacing:3) {
                Text(model.drama.title).font(.subheadline.bold()).lineLimit(1)
                Text(model.episode?.title ?? "正在准备").font(.caption).foregroundStyle(solid ? Studio.muted : .white.opacity(0.8))
            }
            Spacer(minLength:8)
            if actions {
                Button { library.toggle(model.drama) } label:{Image(systemName:favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.yellow : .white).frame(width:34,height:40)}.accessibilityLabel(favorite ? "取消收藏" : "收藏")
                Button { library.toggleLike(model.drama) } label:{Image(systemName:liked ? "heart.fill" : "heart").foregroundStyle(liked ? Color.pink : .white).frame(width:34,height:40)}.accessibilityLabel(liked ? "取消点赞" : "点赞")
                ShareLink(item:shareText) { Image(systemName:"arrowshape.turn.up.right").frame(width:34,height:40) }.accessibilityLabel("分享")
                if !panel { Button { fill.toggle() } label:{Image(systemName:fill ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left").frame(width:34,height:40)}.accessibilityLabel(fill ? "切换为完整画面" : "切换为铺满") }
                Button { togglePanel() } label:{Image(systemName:panel ? "arrow.up.left.and.arrow.down.right.square" : "list.bullet").frame(width:34,height:40)}.accessibilityLabel(panel ? "全屏观看" : "展开选集")
            }
        // 没有返回按钮时（Duo 内屏）标题直接贴着左上圆角，多留一段不被圆角裁掉。
        }.foregroundStyle(.white).padding(.leading,actions ? 16 : 36).padding(.trailing,16).padding(.top,actions ? 6 : 20).padding(.bottom,6)
        .background { if solid { Studio.background } else { LinearGradient(colors:[.black.opacity(0.7),.clear],startPoint:.top,endPoint:.bottom).ignoresSafeArea() } }
    }
    /// Duo 右侧控制条里的操作列（同红果剧内）：收藏 / 点赞 / 分享，再加 选集⇄全屏、铺满⇄完整。
    private func stripActions(compact:Bool) -> some View {
        VStack(spacing:4) {
            RailButton(title:favorite ? "已收藏" : "收藏",icon:favorite ? "star.fill" : "star",selected:favorite,compact:compact,tint:.yellow) { library.toggle(model.drama) }
                .accessibilityIdentifier("drama-favorite")
            RailButton(title:liked ? "已赞" : "点赞",icon:liked ? "heart.fill" : "heart",selected:liked,compact:compact,tint:.pink) { library.toggleLike(model.drama) }
                .accessibilityIdentifier("drama-like")
            ShareLink(item:shareText) {
                VStack(spacing:4) { Image(systemName:"arrowshape.turn.up.right.fill").font(.system(size:19,weight:.semibold));if !compact { Text("分享").font(.caption2.weight(.semibold)) } }
                    .frame(width:54,height:compact ? 40 : 52).foregroundStyle(.white).contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityLabel("分享")
            RailButton(title:panel ? "全屏" : "选集",icon:panel ? "arrow.up.left.and.arrow.down.right.square" : "list.bullet",compact:compact) { togglePanel() }
                .accessibilityLabel(panel ? "全屏观看" : "展开选集").accessibilityIdentifier("drama-panel")
            if !panel {
                RailButton(title:fill ? "铺满" : "完整",icon:fill ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",compact:compact) { fill.toggle() }
                    .accessibilityLabel(fill ? "画面铺满，点按切换为完整画面" : "完整画面，点按切换为铺满")
            }
        }.padding(6).studioGlassCapsule()
    }
    private var videoBox:some View {
        ZStack { videoLayer(fill:false);VStack { Spacer();controls } }.clipped().accessibilityIdentifier("videoSurface")
    }
    private func videoLayer(fill:Bool) -> some View {
        ZStack {
            Color.black
            PlayerSurface(player:model.player,fill:fill).offset(y:slide)
            PlayerGestureView(onSingleTap:{ if panel { model.toggle() } else { withAnimation(.easeInOut(duration:0.2)) { chrome.toggle() } } },onDoubleTap:{x,width in model.seek(model.position+(x<width/2 ? -10 : 10))},onLongPress:{model.longPress($0)},
                onSeekBegan:{gestureStart=model.position;model.scrubbing=true},
                onSeekChanged:{delta,width in guard width>0 else { return };scrubValue=min(max(gestureStart+Double(delta/width)*max(30,model.duration),0),model.duration)},
                onSeekEnded:{model.scrubbing=false;model.seek(scrubValue)},
                onSwipeUp:{ switchEpisode(model.next,direction:-1) },
                onSwipeDown:{ switchEpisode(model.previous,direction:1) },
                // 没有上一集 / 下一集时只给一点阻尼位移，松手弹回。
                onVerticalDrag:{ y in slide=(y<0 ? model.next : model.previous)==nil ? y*0.25 : y },
                onVerticalCancel:{ withAnimation(.spring(response:0.3,dampingFraction:0.85)) { slide=0 } })
            Group {
            if model.loading {
                VStack(spacing:14) { ProgressView().scaleEffect(1.25).tint(.white);Text("正在准备 \(model.episode?.title ?? "")").font(.subheadline);Text("首次播放需下载并准备媒体").font(.caption).foregroundStyle(Studio.muted) }
                    .padding(24).background(.black.opacity(0.75),in:RoundedRectangle(cornerRadius:18)).allowsHitTesting(false)
            } else if let failure=model.failure {
                VStack(spacing:14) { Image(systemName:"exclamationmark.circle").font(.largeTitle).foregroundStyle(Studio.accent);Text(failure).font(.subheadline).multilineTextAlignment(.center);Button("重试当前集") { model.retry() }.buttonStyle(.borderedProminent) }
                    .padding(24).frame(maxWidth:320).background(Studio.surface,in:RoundedRectangle(cornerRadius:18))
            } else if model.finished {
                VStack(spacing:14) {
                    Text(model.next==nil ? "本剧已看完" : "本集播放结束").font(.title3.bold())
                    if let next=model.next { Button("播放下一集") { model.play(next) }.buttonStyle(.borderedProminent) }
                    Button("重新播放") { model.seek(0);model.toggle() }.buttonStyle(.bordered)
                }.padding(24).background(.black.opacity(0.8),in:RoundedRectangle(cornerRadius:16))
            }
            }.offset(y:slide)
        }.clipped()
    }
    /// 切集动画（同推荐流翻页的手感）：当前画面顺着手势滑出去，新一集从另一边滑进来。direction：-1 上滑，1 下滑。
    private func switchEpisode(_ target:Episode?,direction:CGFloat) {
        guard let target else { withAnimation(.spring(response:0.3,dampingFraction:0.85)) { slide=0 };return }
        let distance=UIScreen.main.bounds.height
        withAnimation(.easeIn(duration:0.16)) { slide=direction*distance }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.16) {
            model.play(target)
            var jump=Transaction();jump.disablesAnimations=true
            withTransaction(jump) { slide = -direction*distance }
            DispatchQueue.main.async { withAnimation(.spring(response:0.36,dampingFraction:0.88)) { slide=0 } }
        }
    }
    private var controls:some View {
        VStack(spacing:6) {
            Slider(value:Binding(get:{model.scrubbing ? scrubValue : min(model.position,max(model.duration,1))},set:{scrubValue=$0}),in:0...max(model.duration,1),onEditingChanged:{editing in
                if editing { scrubValue=model.position;model.scrubbing=true } else { model.scrubbing=false;model.seek(scrubValue) }
            }).disabled(model.loading || model.duration<=0).accessibilityLabel("播放进度")
            HStack(spacing:16) {
                Button { model.toggle() } label:{Image(systemName:model.playing ? "pause.fill" : "play.fill").frame(width:28,height:32)}.accessibilityLabel(model.playing ? "暂停" : "播放")
                Text("\(clockText(model.scrubbing ? scrubValue : model.position)) / \(clockText(model.duration))").font(.caption.monospacedDigit())
                Spacer(minLength:0)
                if !model.definition.isEmpty { Text(model.definition).font(.caption2).foregroundStyle(Studio.muted) }
                Menu { ForEach([0.75,1,1.25,1.5,2],id:\.self) { speed in Button("\(speed.formatted())×") { model.setSpeed(speed) } } } label:{Text("\(library.speed.formatted())×").font(.caption.bold()).frame(minWidth:30,minHeight:32)}.accessibilityLabel("播放倍速")
                Button { if let next=model.next { model.play(next) } } label:{Image(systemName:"forward.end.fill").frame(width:28,height:32)}.disabled(model.next==nil).accessibilityLabel("下一集")
            }.foregroundStyle(.white)
        }.padding(.horizontal,16).padding(.top,24).padding(.bottom,12).background(LinearGradient(colors:[.clear,.black.opacity(0.9)],startPoint:.top,endPoint:.bottom))
    }
    private var episodes:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("选集").font(.headline);Text("全 \(model.drama.total) 集").font(.caption).foregroundStyle(Studio.muted);Spacer()
                Menu { Toggle("自动下一集",isOn:$library.autoNext);Toggle("预取下一集",isOn:$library.prefetch) } label:{Image(systemName:"ellipsis").frame(width:36,height:36)}.accessibilityLabel("连播与缓存设置")
            }.padding(.horizontal,18).padding(.top,8)
            if model.drama.episodes.count>100 {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack { ForEach(0..<Int(ceil(Double(model.drama.episodes.count)/100)),id:\.self) { group in
                        Button("\(group*100+1)–\(min((group+1)*100,model.drama.total))") { segment=group }
                            .font(.caption.weight(.medium)).padding(.horizontal,10).padding(.vertical,7).background(segment==group ? Studio.accent.opacity(0.18) : Studio.surface,in:Capsule()).foregroundStyle(segment==group ? Studio.accent : Studio.muted)
                    } }.padding(.horizontal,18)
                }.padding(.vertical,8)
            }
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:48),spacing:8)],spacing:8) {
                    ForEach(model.drama.episodes.filter { ($0.order-1)/100==segment }) { episode in
                        Button { model.play(episode) } label:{
                            Text(String(episode.order)).font(.subheadline.weight(.medium)).frame(maxWidth:.infinity).frame(height:40)
                                .background(model.episode?.id==episode.id ? Studio.accent : Studio.surface,in:RoundedRectangle(cornerRadius:10))
                                .foregroundStyle(.white)
                        }.accessibilityLabel("播放第 \(episode.order) 集").accessibilityIdentifier("episode-\(episode.order)")
                    }
                }.padding(.horizontal,18).padding(.bottom,18)
                if !model.drama.intro.isEmpty { Text(model.drama.intro).font(.caption).foregroundStyle(Studio.muted).lineSpacing(4).padding(.horizontal,18).padding(.bottom,20).frame(maxWidth:.infinity,alignment:.leading) }
            }
        }
    }
}
struct PlayerSurface:UIViewRepresentable {
    let player:AVPlayer
    /// true：等比放大铺满容器（裁掉多出的边）；false：完整画面
    var fill=false
    func makeUIView(context:Context) -> PlayerLayerView { let view=PlayerLayerView();view.layerView.player=player;view.layerView.videoGravity=fill ? .resizeAspectFill : .resizeAspect;return view }
    func updateUIView(_ uiView:PlayerLayerView,context:Context) {
        uiView.layerView.player=player
        let gravity:AVLayerVideoGravity=fill ? .resizeAspectFill : .resizeAspect
        if uiView.layerView.videoGravity != gravity { uiView.layerView.videoGravity=gravity }
    }
    static func dismantleUIView(_ uiView:PlayerLayerView,coordinator:()) { uiView.layerView.player=nil }
}
final class PlayerLayerView:UIView {
    override class var layerClass:AnyClass { AVPlayerLayer.self }
    var layerView:AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame:CGRect) { super.init(frame:frame);backgroundColor = .clear;layerView.videoGravity = .resizeAspect }
    required init?(coder:NSCoder) { fatalError("init(coder:) not supported") }
}
