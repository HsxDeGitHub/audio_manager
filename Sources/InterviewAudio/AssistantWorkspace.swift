import SwiftUI
import AppKit

extension Notification.Name { static let assistantPanelWidthChanged = Notification.Name("assistant.panelWidthChanged") }

struct AssistantWorkspace<Main: View, Assistant: View>: NSViewControllerRepresentable {
    let visible: Bool
    @AppStorage("assistant.expanded") private var expanded = false
    @ViewBuilder var main: () -> Main
    @ViewBuilder var assistant: () -> Assistant
    func makeNSViewController(context: Context) -> AssistantSplitController {
        let controller = AssistantSplitController()
        controller.expanded = expanded
        controller.install(main: AnyView(main()), assistant: AnyView(assistant()), visible: visible)
        return controller
    }
    func updateNSViewController(_ controller: AssistantSplitController, context: Context) {
        controller.expanded = expanded
        controller.update(main: AnyView(main()), assistant: AnyView(assistant()), visible: visible)
    }
}

/// 使用原生分隔线处理拖动；明确分配阅读区与助手宽度，不让内容固有宽度反复改变分栏。
final class AssistantSplitController: NSViewController, NSSplitViewDelegate {
    let splitView = NSSplitView()
    private let mainHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let assistantHost = NSHostingController(rootView: AnyView(EmptyView()))
    private var mainContent = AnyView(EmptyView())
    private var assistantContent = AnyView(EmptyView())
    var expanded = false { didSet { if expanded != oldValue { arrange() } } }
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
        mainContent = main; assistantContent = assistant
        visibility = visible
        if visible { splitView.addArrangedSubview(assistantHost.view) }
        widthObserver = NotificationCenter.default.addObserver(forName: .assistantPanelWidthChanged, object: nil, queue: .main) { [weak self] event in
            if let width = event.object as? Double { self?.setPreferredWidth(width) }
        }
        arrange()
    }
    func update(main: AnyView, assistant: AnyView, visible: Bool) {
        mainContent = main; assistantContent = assistant
        if visibility != visible {
            visibility = visible
            if visible { splitView.addArrangedSubview(assistantHost.view) }
            else { assistantHost.view.removeFromSuperview() }
            arrange()
        }
        arrange()
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        if lastSize != splitView.bounds.size { arrange() }
    }
    private func arrange() {
        guard !applying else { return }; applying = true; defer { applying = false }
        let size = splitView.bounds.size; lastSize = size
        let minimumMain: CGFloat = expanded ? 520 : 740
        let maximumSide: CGFloat = expanded ? 900 : 560
        let desired: CGFloat = expanded ? 760 : preferredWidth
        let side = visibility ? min(max(320, desired), min(maximumSide, max(320, size.width - minimumMain - splitView.dividerThickness))) : 0
        let main = max(0, size.width - side - (visibility ? splitView.dividerThickness : 0))
        mainHost.view.frame = NSRect(x: 0, y: 0, width: main, height: size.height)
        // 显式给 SwiftUI 根视图新的提议尺寸，避免移除左栏后仍沿用上一次固有宽度。
        mainHost.rootView = AnyView(mainContent.frame(width: main, height: size.height).clipped())
        if visibility {
            assistantHost.view.frame = NSRect(x: main + splitView.dividerThickness, y: 0, width: side, height: size.height)
            assistantHost.rootView = AnyView(assistantContent.frame(width: side, height: size.height).clipped())
        }
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
        max(expanded ? 520 : 740, splitView.bounds.width - splitView.dividerThickness - (expanded ? 900 : 560))
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(expanded ? 520 : 740, splitView.bounds.width - splitView.dividerThickness - 320)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard visibility, !applying, let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) else { return }
        let width = assistantHost.view.frame.width
        if (320...560).contains(width) { preferredWidth = width; UserDefaults.standard.set(Double(width), forKey: "assistant.width") }
    }
    deinit { if let widthObserver { NotificationCenter.default.removeObserver(widthObserver) } }
}
