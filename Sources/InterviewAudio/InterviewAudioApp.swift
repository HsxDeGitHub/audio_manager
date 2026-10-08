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
        WindowGroup("面试音频", id: "library") {
            LibraryView(model: model)
                .frame(minWidth: 1050, minHeight: 650)
                .onAppear { delegate.model = model; delegate.reopenWindow = { openWindow(id: "library") } }
                .task { await model.prepare() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入音频…") { model.pickFiles() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) {
                Button("模型设置…") { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("播放") {
                Button("播放 / 暂停") { model.player.toggle() }.keyboardShortcut(.space, modifiers: [.command])
                Button("后退 10 秒") { model.player.seek(model.player.position - 10) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("前进 10 秒") { model.player.seek(model.player.position + 10) }.keyboardShortcut(.rightArrow, modifiers: [.command])
            }
        }
    }
}
