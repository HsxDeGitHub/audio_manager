import SwiftUI
import AppKit

extension Notification.Name { static let assistantPanelWidthChanged = Notification.Name("assistant.panelWidthChanged") }

struct AssistantWorkspace<Main: View, Assistant: View>: NSViewControllerRepresentable {
    let visible: Bool
    @ViewBuilder var main: () -> Main
    @ViewBuilder var assistant: () -> Assistant
    func makeNSViewController(context: Context) -> AssistantSplitController {
        let controller = AssistantSplitController()
        controller.install(main: AnyView(main()), assistant: AnyView(assistant()), visible: visible)
        return controller
    }
    func updateNSViewController(_ controller: AssistantSplitController, context: Context) {
        controller.update(main: AnyView(main()), assistant: AnyView(assistant()), visible: visible)
    }
}

/// 使用原生分隔线处理拖动；明确分配阅读区与助手宽度，不让内容固有宽度反复改变分栏。
final class AssistantSplitController: NSViewController, NSSplitViewDelegate {
    let splitView = NSSplitView()
    private let mainHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let assistantHost = NSHostingController(rootView: AnyView(EmptyView()))
    private var visibility = false
    private var applying = false
    private var lastSize = NSSize.zero
    private var widthObserver: NSObjectProtocol?
    var preferredWidth = UserDefaults.standard.object(forKey: "assistant.width") as? Double ?? 380
    override func loadView() {
        splitView.isVertical = true; splitView.dividerStyle = .thin; splitView.delegate = self
        view = splitView
    }
    func install(main: AnyView, assistant: AnyView, visible: Bool) {
        loadViewIfNeeded()
        addChild(mainHost); addChild(assistantHost)
        mainHost.view.translatesAutoresizingMaskIntoConstraints = true
        assistantHost.view.translatesAutoresizingMaskIntoConstraints = true
        splitView.addArrangedSubview(mainHost.view)
        mainHost.rootView = main; assistantHost.rootView = assistant
        visibility = visible
        if visible { splitView.addArrangedSubview(assistantHost.view) }
        widthObserver = NotificationCenter.default.addObserver(forName: .assistantPanelWidthChanged, object: nil, queue: .main) { [weak self] event in
            if let width = event.object as? Double { self?.setPreferredWidth(width) }
        }
        arrange()
    }
    func update(main: AnyView, assistant: AnyView, visible: Bool) {
        mainHost.rootView = main; assistantHost.rootView = assistant
        if visibility != visible {
            visibility = visible
            if visible { splitView.addArrangedSubview(assistantHost.view) }
            else { assistantHost.view.removeFromSuperview() }
            arrange()
        }
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        if lastSize != splitView.bounds.size { arrange() }
    }
    private func arrange() {
        guard !applying else { return }; applying = true; defer { applying = false }
        let size = splitView.bounds.size; lastSize = size
        let side = visibility ? min(max(320, preferredWidth), min(560, max(320, size.width - 740 - splitView.dividerThickness))) : 0
        let main = max(0, size.width - side - (visibility ? splitView.dividerThickness : 0))
        mainHost.view.frame = NSRect(x: 0, y: 0, width: main, height: size.height)
        if visibility { assistantHost.view.frame = NSRect(x: main + splitView.dividerThickness, y: 0, width: side, height: size.height) }
        mainHost.view.needsLayout = true; assistantHost.view.needsLayout = true
        mainHost.view.needsDisplay = true; assistantHost.view.needsDisplay = true; splitView.needsDisplay = true
    }
    func setPreferredWidth(_ width: Double) {
        preferredWidth = min(560, max(320, width))
        UserDefaults.standard.set(preferredWidth, forKey: "assistant.width")
        arrange()
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // 拖分隔线时容器大小不变，保留AppKit刚算出的子视图宽度。
        if lastSize != splitView.bounds.size { arrange() }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(740, splitView.bounds.width - splitView.dividerThickness - 560)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(740, splitView.bounds.width - splitView.dividerThickness - 320)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard visibility, !applying, let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) else { return }
        let width = assistantHost.view.frame.width
        if (320...560).contains(width) { preferredWidth = width; UserDefaults.standard.set(Double(width), forKey: "assistant.width") }
    }
    deinit { if let widthObserver { NotificationCenter.default.removeObserver(widthObserver) } }
}
