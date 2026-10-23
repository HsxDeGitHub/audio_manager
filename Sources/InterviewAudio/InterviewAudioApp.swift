import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var reopenWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenWindow?() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdown()
        return .terminateNow
    }
}

@main
struct InterviewAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("听阅", id: "library") {
            LibraryView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { delegate.model = model; delegate.reopenWindow = { openWindow(id: "library") } }
                .task { await model.prepare() }
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于听阅") { model.showAbout = true }
            }
            CommandGroup(after: .undoRedo) {
                Divider()
                Button(model.undoLabel.map { "撤销校对：" + $0 } ?? "撤销校对修改") { model.undoEdit() }.disabled(model.undoLabel == nil).keyboardShortcut("z", modifiers: [.command, .option])
                Button(model.redoLabel.map { "重做校对：" + $0 } ?? "重做校对修改") { model.undoEdit(redo: true) }.disabled(model.redoLabel == nil).keyboardShortcut("z", modifiers: [.command, .option, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("导入音频…") { model.pickFiles() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) {
                Button("模型设置…") { model.showSettings = true }.keyboardShortcut(",")
                Button("大模型配置…") { model.showAISettings = true }
                Divider()
                Button("长期记忆…") { model.showMemories = true }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("工具与 MCP…") { model.showToolSettings = true }
            }
            CommandMenu("播放") {
                Button("播放 / 暂停") { model.player.toggle() }.keyboardShortcut(.space, modifiers: [.command])
                Button("后退 10 秒") { model.player.seek(model.player.position - 10) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("前进 10 秒") { model.player.seek(model.player.position + 10) }.keyboardShortcut(.rightArrow, modifiers: [.command])
            }
            CommandGroup(after: .sidebar) {
                Button("显示或收起听阅助手") { model.assistant.toggle() }.keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandMenu("阅读") {
                Button("搜索音频文字") { model.searchFocusRequestID = UUID() }.keyboardShortcut("f")
                Button("下一个搜索结果") { model.navigateHit(1) }.keyboardShortcut("g").disabled(model.hits.isEmpty)
                Button("上一个搜索结果") { model.navigateHit(-1) }.keyboardShortcut("g", modifiers: [.command,.shift]).disabled(model.hits.isEmpty)
                Button("返回搜索前的位置") { Task { await model.returnFromSearch() } }.disabled(!model.hasSearchOrigin)
                Divider()
                Button("定位当前句") { model.locateCurrentSentence() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("放大文字") { model.setReaderFontSize(model.readerFontSize + 1) }.keyboardShortcut("+", modifiers: [.command])
                Button("缩小文字") { model.setReaderFontSize(model.readerFontSize - 1) }.keyboardShortcut("-", modifiers: [.command])
            }
        }
    }
}
