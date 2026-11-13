import SwiftUI
import UIKit

/// 红果扫码登录：显示官网二维码，用手机红果 App 扫码并确认。
struct LoginView:View {
    @ObservedObject private var account=AccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var image:UIImage?
    @State private var remaining=0
    @State private var status="正在获取二维码…"
    @State private var error:String?
    @State private var round=0

    var body:some View {
        NavigationStack {
            VStack(spacing:18) {
                Spacer(minLength:0)
                ZStack {
                    RoundedRectangle(cornerRadius:18).fill(.white)
                    if let image { Image(uiImage:image).interpolation(.none).resizable().scaledToFit().padding(14).opacity(error==nil ? 1 : 0.15) }
                    else if error==nil { ProgressView().tint(.gray) }
                    if error != nil { Button("重新获取") { round+=1 }.buttonStyle(.borderedProminent) }
                }
                .frame(width:240,height:240)
                .accessibilityIdentifier("login-qr")
                Text(error ?? status).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(error==nil ? Color.white : .orange)
                if error==nil,remaining>0 { Text("\(remaining) 秒后过期").font(.caption.monospacedDigit()).foregroundStyle(Studio.muted) }
                Text("打开手机上的红果免费短剧 App，用扫一扫扫描并确认登录。登录态只保存在这台设备的钥匙串里。")
                    .font(.footnote).foregroundStyle(Studio.muted).multilineTextAlignment(.center).padding(.horizontal,28)
                Spacer(minLength:0);Spacer(minLength:0)
            }
            .frame(maxWidth:.infinity).background(Studio.background.ignoresSafeArea())
            .navigationTitle("红果账号").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarLeading) { Button("取消") { dismiss() } } }
        }
        .preferredColorScheme(.dark).tint(Studio.accent)
        .task(id:round) { await run() }
    }

    private func run() async {
        image=nil;error=nil;status="正在获取二维码…";remaining=0
        do {
            // 官网二维码一分钟左右就过期：过期自动换一张，最多换 5 次，再久就停下等用户点「重新获取」。
            for _ in 0..<5 {
                let login=WebLogin()
                let qr=try await login.qr()
                guard let picture=UIImage(data:qr.image) else { throw ManjuError.message("二维码图片无法显示。") }
                image=picture;status="等待扫码"
                let deadline=Date().addingTimeInterval(Double(max(30,qr.expiresIn)))
                while Date()<deadline {
                    remaining=max(0,Int(deadline.timeIntervalSinceNow))
                    try await Task.sleep(for:.seconds(2))
                    let done:Bool
                    do { done=try await login.poll() }
                    catch let failure as ManjuError where failure.localizedDescription.contains("过期") { break }
                    if done {
                        status="已确认，正在核对账号…"
                        try account.save(try await login.credentials())
                        dismiss();return
                    }
                }
                status="二维码已更新，等待扫码"
            }
            throw ManjuError.message("二维码已过期，请重新获取。")
        } catch is CancellationError { }
        catch { self.error=error.localizedDescription;remaining=0 }
    }
}
