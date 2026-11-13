import SwiftUI

enum Studio {
    static let background=Color(red:0.055,green:0.059,blue:0.075)
    static let surface=Color(red:0.10,green:0.106,blue:0.13)
    static let accent=Color(red:1,green:0.40,blue:0.24)
    static let muted=Color.white.opacity(0.5)
}
extension View {
    /// 液态玻璃胶囊底：iOS 26+ 用 glassEffect，低版本回退 ultraThinMaterial（与 DouDuo 右侧栏一致）。
    /// 把操作列放进 Duo 右侧系统控制条（安全区之外），靠下。
    /// 用一层铺满全屏的容器来摆放，而不是 offset 出安全区——offset 出去的按钮看得见但点不到。
    /// 系统时钟 / 状态环的竖轴距屏幕右缘约 49pt（DouDuo 真机实测），操作列（宽 66）与它对齐。
    func stripColumn<Rail:View>(bottom:CGFloat,@ViewBuilder _ rail:()->Rail) -> some View {
        overlay {
            rail().padding(.trailing,49-33).padding(.bottom,bottom)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomTrailing)
                .ignoresSafeArea()
        }
    }
    /// 控制条顶部、系统时钟和状态环正下方的一颗按钮（宽 44，同样对齐 49pt 竖轴）。
    func stripTop<Item:View>(top:CGFloat,@ViewBuilder _ item:()->Item) -> some View {
        overlay {
            item().padding(.trailing,49-22).padding(.top,top)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing)
                .ignoresSafeArea()
        }
    }
    @ViewBuilder func studioGlassCircle() -> some View {
        if #available(iOS 26.0, *) { self.glassEffect(.regular.interactive(), in: .circle) }
        else { self.background(.ultraThinMaterial, in: Circle()) }
    }
    @ViewBuilder func studioGlassCapsule() -> some View {
        if #available(iOS 26.0, *) { self.glassEffect(.regular.interactive(), in: .capsule) }
        else { self.background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.08))) }
    }
}
/// 右侧操作栏里的一颗按钮（导航和播放操作共用）。compact：矮屏只留图标。
struct RailButton:View {
    let title:String
    let icon:String
    var selected=false
    var compact=false
    var tint=Studio.accent
    let action:()->Void
    var body:some View {
        Button(action:action) {
            VStack(spacing:4) {
                Image(systemName:icon).font(.system(size:19,weight:.semibold))
                if !compact { Text(title).font(.caption2.weight(.semibold)).lineLimit(1) }
            }
            .frame(width:54,height:compact ? 40 : 52)
            .background(selected ? tint.opacity(0.16) : .clear,in:Capsule())
            .foregroundStyle(selected ? tint : Color.white)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct Cover:View {
    let drama:Drama
    var body:some View {
        AsyncImage(url:drama.coverURL) { image in image.resizable().scaledToFill() } placeholder:{
            ZStack { Studio.surface;Image(systemName:"play.rectangle.on.rectangle.fill").font(.largeTitle).foregroundStyle(Studio.muted) }
        }
        .aspectRatio(0.72,contentMode:.fit).clipped().clipShape(RoundedRectangle(cornerRadius:14))
    }
}
struct DramaCard:View {
    let drama:Drama
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            Cover(drama:drama).overlay(alignment:.bottomTrailing) {
                Text("\(drama.total) 集").font(.caption2.weight(.semibold)).padding(.horizontal,7).padding(.vertical,4)
                    .background(.black.opacity(0.65),in:Capsule()).padding(8)
            }
            Text(drama.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(height:40,alignment:.topLeading)
            Text(drama.tags.prefix(2).joined(separator:" · ")).font(.caption).foregroundStyle(Studio.muted).lineLimit(1)
        }.foregroundStyle(.white).accessibilityElement(children:.combine)
    }
}
func clockText(_ value:Double) -> String {
    guard value.isFinite,value>=0 else { return "0:00" };let n=Int(value);return String(format:"%d:%02d",n/60,n%60)
}
struct InlineError:View {
    let message:String
    let retry:()->Void
    var body:some View { VStack(spacing:12) {
        Image(systemName:"wifi.exclamationmark").font(.title2).foregroundStyle(Studio.accent)
        Text(message).font(.subheadline).foregroundStyle(Studio.muted).multilineTextAlignment(.center)
        Button("重试",action:retry).buttonStyle(.bordered).tint(Studio.accent)
    }.padding(24).frame(maxWidth:.infinity) }
}
