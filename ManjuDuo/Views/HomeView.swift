import SwiftUI

struct HomeView:View {
    let provider:ContentProvider
    @EnvironmentObject private var library:LibraryStore
    @StateObject private var catalog:CatalogModel
    @State private var query=""
    @State private var tab=0
    @State private var imported=""
    @State private var importing=false
    @State private var importSheet=false
    @State private var importError:String?
    @State private var selected:Drama?
    @State private var settings=false
    @State private var storageNoticeDismissed=false
    /// 打开 App 先进推荐流；发现 / 追剧 / 足迹 从右侧导航切过去。
    @State private var showFeed=true
    @State private var feedCurrent:Drama?
    @StateObject private var feedCatalog:CatalogModel
    @AppStorage("fillVideo") private var fill=true
    @Environment(\.scenePhase) private var phase
    init(provider:ContentProvider) {
        self.provider=provider;_catalog=StateObject(wrappedValue:CatalogModel(provider:provider));_feedCatalog=StateObject(wrappedValue:CatalogModel(provider:provider,recommendations:true))
    }
    private let columns=[GridItem(.adaptive(minimum:145,maximum:220),spacing:16,alignment:.top)]
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let wide = size.width >= 700 || (size.width > size.height && size.width >= 600)
            // 布局同 DouDuo：导航在顶部一排（推荐 · 发现 · 追剧 · 足迹），右侧操作区只放当前这部剧的操作。
            // Duo 右侧有系统控制条（时钟所在的安全区）时，操作按钮直接放进这条控制条里，不压画面。
            let strip = geometry.safeAreaInsets.trailing
            let inStrip = strip >= 62
            let compact = size.height < 520
            // 留白同 DouDuo：顶栏离屏幕上缘、左右按钮离两侧都留出一段，不贴边。
            let topGap = max(0, 24 - geometry.safeAreaInsets.top)
            let sideGap: CGFloat = wide ? 36 : 14
            let feedActive = showFeed && selected == nil && !importSheet && !settings && phase == .active
            ZStack {
                TabView(selection: $tab) {
                    page(0, wide: wide).tabItem { Label("发现", systemImage: "square.grid.2x2") }.tag(0)
                    page(1, wide: wide).tabItem { Label("追剧", systemImage: "bookmark") }.tag(1)
                    page(2, wide: wide).tabItem { Label("足迹", systemImage: "clock") }.tag(2)
                }
                .padding(.top, topBarHeight + topGap)
                .background(Studio.background.ignoresSafeArea())
                .opacity(showFeed ? 0 : 1).allowsHitTesting(!showFeed).accessibilityHidden(showFeed)
                FeedView(catalog: feedCatalog, provider: provider, library: library, active: feedActive,
                         insets: geometry.safeAreaInsets, railReserve: inStrip ? strip : 78, current: $feedCurrent) { selected = $0 }
                    .opacity(showFeed ? 1 : 0).allowsHitTesting(showFeed).accessibilityHidden(!showFeed)
            }
            .overlay(alignment: .top) { topBar(topGap: topGap, sideGap: sideGap) }
            // 右侧操作列靠下放（同 DouDuo）：有系统控制条就放进控制条，否则悬浮在画面右下。
            .stripColumn(bottom: geometry.safeAreaInsets.bottom + (compact ? 8 : 26)) { if inStrip { feedActions(compact: compact) } }
            .overlay(alignment: .bottomTrailing) {
                if !inStrip { feedActions(compact: compact).padding(.trailing, 12).padding(.bottom, compact ? 8 : 26) }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Studio.accent)
            .background { SearchBrowserHost().frame(width:1,height:1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true) }
            .sheet(isPresented:$importSheet) { importPanel }
            .sheet(isPresented:$settings) { SettingsView() }
            .fullScreenCover(item:$selected) { drama in DramaScreen(summary:drama,provider:provider).environmentObject(library) }
            .alert("本机存储",isPresented:Binding(get:{library.storageError != nil && !storageNoticeDismissed},set:{if !$0 { storageNoticeDismissed=true }})) { Button("知道了",role:.cancel){} } message:{ Text(library.storageError ?? "") }
            .task { if feedCatalog.items.isEmpty { feedCatalog.reload() };if catalog.items.isEmpty { catalog.reload() } }
    }

    private let topBarHeight: CGFloat = 50
    @FocusState private var searchFocused: Bool

    /// 顶部导航：文字 Tab 居中一排，推荐流里透明压在画面上，其它页是普通顶栏。
    private func topBar(topGap: CGFloat, sideGap: CGFloat) -> some View {
        HStack(spacing: 26) {
            topTab("推荐", selected: showFeed, id: "nav-feed") { showFeed = true }
            topTab("发现", selected: !showFeed && tab == 0, id: "nav-0") { tab = 0; showFeed = false }
            topTab("追剧", selected: !showFeed && tab == 1, id: "nav-1") { tab = 1; showFeed = false }
            topTab("足迹", selected: !showFeed && tab == 2, id: "nav-2") { tab = 2; showFeed = false }
        }
        .frame(maxWidth: .infinity).frame(height: topBarHeight)
        .overlay(alignment: .leading) {
            Button { settings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40).studioGlassCircle() }
                .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel("设置").padding(.leading, sideGap)
        }
        .overlay(alignment: .trailing) {
            Button { tab = 0; showFeed = false; searchFocused = true } label: { Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40).studioGlassCircle() }
                .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel("搜索").accessibilityIdentifier("nav-search").padding(.trailing, sideGap)
        }
        .padding(.top, topGap)
        .background {
            if showFeed { LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false) }
            else { Studio.background.ignoresSafeArea() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("topNavigation")
    }

    private func topTab(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 17, weight: selected ? .bold : .medium))
                Capsule().fill(selected ? Color.white : .clear).frame(width: 18, height: 3)
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.62))
            .shadow(color: .black.opacity(showFeed ? 0.5 : 0), radius: 2, y: 1)
            .padding(.horizontal, 4).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 右侧操作区：推荐流里当前这部剧的操作（追剧 / 选集 / 铺满）。
    @ViewBuilder private func feedActions(compact: Bool) -> some View {
        if showFeed, let drama = feedCurrent {
            VStack(spacing: 4) {
                RailButton(title: library.isFavorite(drama.id) ? "已追" : "追剧", icon: library.isFavorite(drama.id) ? "bookmark.fill" : "bookmark",
                           selected: library.isFavorite(drama.id), compact: compact) { library.toggle(drama) }
                RailButton(title: "选集", icon: "list.bullet", compact: compact) { selected = drama }
                RailButton(title: fill ? "铺满" : "完整", icon: fill ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left", compact: compact) { fill.toggle() }
                    .accessibilityLabel(fill ? "画面铺满，点按切换为完整画面" : "完整画面，点按切换为铺满")
            }
            .padding(6).studioGlassCapsule()
            .accessibilityElement(children: .contain).accessibilityIdentifier("feedActions")
        }
    }

    private func page(_ index: Int, wide: Bool) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    masthead(for: index)
                    if index==0 {
                        searchBar
                        if catalog.query.isEmpty { filters }
                        if !library.history.isEmpty,catalog.query.isEmpty { continueWatching }
                        HStack { Text(catalog.query.isEmpty ? "今日片单" : "搜索结果").font(.title2.bold());Spacer();if catalog.loading { ProgressView().tint(.white) } }
                        LazyVGrid(columns:columns,alignment:.leading,spacing:20) {
                            ForEach(catalog.items) { item in Button { selected=item } label:{DramaCard(drama:item)}.buttonStyle(.plain) }
                        }
                        if let error=catalog.error { InlineError(message:error) { if catalog.items.isEmpty { catalog.reload() } else { catalog.more() } } }
                        else if !catalog.loading,catalog.items.isEmpty { ContentUnavailableView("还没有找到作品",systemImage:"magnifyingglass",description:Text("换个剧名试试，或导入红果分享链接。")) }
                        if catalog.hasMore,!catalog.loading { Button("加载更多") { catalog.more() }.frame(maxWidth:.infinity).buttonStyle(.bordered).tint(Studio.accent).padding(.vertical,8) }
                        if catalog.items.isEmpty,catalog.loading { ProgressView("正在获取漫剧…").frame(maxWidth:.infinity).padding(.vertical,60) }
                    } else if index==1 { favorites }
                    else { history }
                }.padding(.horizontal,20).padding(.top,16).padding(.bottom,32).frame(maxWidth:1100).frame(maxWidth:.infinity)
            }
            .background(Studio.background).scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden,for:.navigationBar)
            .refreshable { if index==0 { catalog.reload() } }
        }
        .toolbar(.hidden, for: .tabBar)
    }
    private func masthead(for tab: Int) -> some View {
        HStack(alignment:.center) {
            VStack(alignment:.leading,spacing:6) {
                HStack(spacing:8) { RoundedRectangle(cornerRadius:3).fill(Studio.accent).frame(width:5,height:24);Text("漫剧 Duo").font(.system(size:30,weight:.bold,design:.rounded)) }
                Text("\(tab==0 ? "好故事，接着看。" : tab==1 ? "把想看的留在这里。" : "每个故事，都记得进度。")").font(.subheadline).foregroundStyle(Studio.muted)
            }
            Spacer()
            Button { importSheet=true } label:{Image(systemName:"link.badge.plus").font(.title3).frame(width:44,height:44).background(Studio.surface,in:Circle())}.accessibilityLabel("导入作品链接")
        }.foregroundStyle(.white)
    }
    private var searchBar:some View {
        HStack(spacing:10) {
            Image(systemName:"magnifyingglass").foregroundStyle(Studio.muted)
            TextField("搜索漫剧名称",text:$query).submitLabel(.search).onSubmit(search).focused($searchFocused).accessibilityIdentifier("searchField")
            if !query.isEmpty { Button { query="";search() } label:{Image(systemName:"xmark.circle.fill").foregroundStyle(Studio.muted)} }
            Button("搜索",action:search).font(.subheadline.weight(.semibold))
        }.padding(14).background(Studio.surface,in:RoundedRectangle(cornerRadius:14))
    }
    private func search() { catalog.query=String(query.prefix(30));catalog.reload() }
    private var filters:some View {
        HStack(spacing:10) { ForEach(CatalogSort.allCases) { sort in
            Button { catalog.sort=sort;catalog.reload() } label:{
                Text(sort.rawValue).font(.subheadline.weight(.medium)).padding(.horizontal,20).padding(.vertical,10)
                    .background(catalog.sort==sort ? Studio.accent : Studio.surface,in:Capsule()).foregroundStyle(.white)
            }.buttonStyle(.plain)
        } }
    }
    private var continueWatching:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("继续观看").font(.headline);Spacer();Button("全部") { tab=2;showFeed=false }.font(.caption).foregroundStyle(Studio.muted) }
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:12) { ForEach(library.history.prefix(8)) { record in
                    Button { selected=record.drama } label:{
                        HStack(spacing:12) {
                            Cover(drama:record.drama).frame(width:60)
                            VStack(alignment:.leading,spacing:8) {
                                Text(record.drama.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("第 \(record.order) 集 · \(clockText(record.time))").font(.caption).foregroundStyle(Studio.muted)
                                ProgressView(value:record.duration>0 ? min(1,record.time/record.duration) : 0).tint(Studio.accent)
                            }.frame(width:155,alignment:.leading)
                            Image(systemName:"play.fill").font(.caption).foregroundStyle(Studio.accent)
                        }.padding(12).background(Studio.surface,in:RoundedRectangle(cornerRadius:16)).foregroundStyle(.white)
                    }.buttonStyle(.plain)
                } }
            }
        }
    }
    private var favorites:some View {
        Group {
            if library.favorites.isEmpty { ContentUnavailableView("还没有追剧",systemImage:"bookmark",description:Text("打开一部作品，点「追剧」就能保存在这里。")) }
            else { LazyVGrid(columns:columns,alignment:.leading,spacing:20) { ForEach(library.favorites) { item in Button { selected=item } label:{DramaCard(drama:item)}.buttonStyle(.plain) } } }
        }
    }
    private var history:some View {
        VStack(spacing:14) {
            if library.history.isEmpty { ContentUnavailableView("从一个故事开始",systemImage:"clock",description:Text("观看进度会自动保存在这台设备。")) }
            ForEach(library.history) { record in
                Button { selected=record.drama } label:{
                    HStack(spacing:16) {
                        Cover(drama:record.drama).frame(width:70)
                        VStack(alignment:.leading,spacing:8) {
                            Text(record.drama.title).font(.headline).lineLimit(2)
                            Text("第 \(record.order) / \(record.drama.total) 集").font(.subheadline).foregroundStyle(Studio.muted)
                            Text("\(clockText(record.time)) / \(clockText(record.duration))").font(.caption).foregroundStyle(Studio.muted)
                        };Spacer();Image(systemName:"play.circle.fill").font(.title).foregroundStyle(Studio.accent)
                    }.padding(12).background(Studio.surface,in:RoundedRectangle(cornerRadius:16)).foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
        }
    }
    private var importPanel:some View {
        NavigationStack {
            VStack(alignment:.leading,spacing:20) {
                Text("把故事带进来").font(.title2.bold())
                Text("粘贴红果官网作品链接，或包含链接的漫剧分享文案。").font(.subheadline).foregroundStyle(Studio.muted)
                TextEditor(text:$imported).frame(height:140).padding(10).scrollContentBackground(.hidden).background(Studio.surface,in:RoundedRectangle(cornerRadius:12)).accessibilityIdentifier("importText")
                if let importError { Text(importError).font(.subheadline).foregroundStyle(.orange) }
                Button {
                    importing=true;importError=nil
                    Task {
                        do { let item=try await provider.importShare(imported);importing=false;importSheet=false;selected=item }
                        catch { importing=false;importError=error.localizedDescription }
                    }
                } label:{ HStack { if importing { ProgressView().tint(.white) };Text(importing ? "正在获取作品…" : "打开作品").fontWeight(.semibold) }.frame(maxWidth:.infinity).padding(14) }
                .buttonStyle(.borderedProminent).disabled(imported.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || importing)
                Spacer()
            }.padding(24).background(Studio.background).toolbar { ToolbarItem(placement:.topBarTrailing) { Button("关闭") { importSheet=false } } }
        }.presentationDetents([.medium,.large]).interactiveDismissDisabled(importing)
    }
}
