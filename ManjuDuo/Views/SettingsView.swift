import SwiftUI

struct SettingsView:View {
    @EnvironmentObject private var library:LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var stats:CacheStats?
    @State private var clearing=false
    @State private var confirm=false
    @State private var error:String?
    @ObservedObject private var account=AccountStore.shared
    @State private var login=false
    @State private var confirmSignOut=false
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    if let name=account.name {
                        LabeledContent("已登录",value:name)
                        Button("退出登录",role:.destructive) { confirmSignOut=true }
                    } else {
                        Button { login=true } label:{ Label("扫码登录红果账号",systemImage:"qrcode") }.accessibilityIdentifier("settings-login")
                    }
                } header:{Text("红果账号")} footer:{Text("用手机红果 App 扫码登录。目前只保存登录状态，收藏和进度仍只在本机。")}
                Section("播放") {
                    Toggle("自动播放下一集",isOn:$library.autoNext)
                    Toggle("预取下一集",isOn:$library.prefetch)
                    Picker("默认倍速",selection:$library.speed) { ForEach([0.75,1,1.25,1.5,2],id:\.self) { speed in Text("\(speed.formatted())×").tag(speed) } }
                }
                Section {
                    LabeledContent("已缓存",value:stats.map{"\($0.files) 集 · \(ByteCountFormatter.string(fromByteCount:Int64($0.bytes),countStyle:.file))"} ?? "正在读取")
                    Button(clearing ? "正在清理…" : "清理视频缓存",role:.destructive) { Task { await clearCache() } }.disabled(clearing)
                } header:{Text("本机缓存")} footer:{Text("只预取下一集，最多保留约 1 GB；系统空间不足时也可能清理缓存。收藏和观看进度单独保存。")}
                Section("足迹") { Button("清除观看历史",role:.destructive) { confirm=true } }
                Section("关于") {
                    LabeledContent("漫剧 Duo",value:"0.1.0")
                    Text("沿用 DouDuo 的原生播放与自适应布局思路。内容来自红果；这是独立第三方客户端，播放范围取决于来源实际返回的资源。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("收藏与进度仅保存在当前设备，不同步红果账号。切到后台自动暂停。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }.navigationTitle("设置").toolbar { ToolbarItem(placement:.topBarTrailing) { Button("完成") { dismiss() } } }
            .task { stats=try? await MediaCache.shared.stats() }
            .confirmationDialog("清除这台设备的观看历史？",isPresented:$confirm,titleVisibility:.visible) { Button("清除历史",role:.destructive) { library.clearHistory() } }
            .sheet(isPresented:$login) { LoginView() }
            .confirmationDialog("退出这台设备上的红果账号？",isPresented:$confirmSignOut,titleVisibility:.visible) { Button("退出登录",role:.destructive) { account.signOut() } }
        }.preferredColorScheme(.dark).tint(Studio.accent)
    }
    private func clearCache() async {
        clearing=true;error=nil
        do { try await MediaCache.shared.clear();stats=try await MediaCache.shared.stats() } catch { self.error=error.localizedDescription }
        clearing=false
    }
}
