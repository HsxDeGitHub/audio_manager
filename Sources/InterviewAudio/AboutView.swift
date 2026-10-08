import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 60)).foregroundStyle(accent)
            Text("听阅").font(.largeTitle.weight(.semibold))
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · 构建 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")").font(.caption).foregroundStyle(.secondary)
            Text("在本机转写、查找与回听音频。\n录音保留在原位置，校对与修改历史保存在本机。").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            Text("快捷键：⌘F 搜索 · ⌘G 下一个结果 · ⇧⌘G 上一个结果\n⌥⌘Z 撤销校对 · ⇧⌥⌘Z 重做校对").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(32).frame(width: 510)
    }
}
