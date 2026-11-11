import AppKit
import SwiftUI

/// 灵动岛窗口。贴住屏幕上沿、层级在菜单栏之上（与刘海融为一体）；不抢焦点、跨 Space 与全屏可见。
/// 不允许按背景拖动：无刘海时只能横向调整，由岛形自己的拖动手势处理。
final class UsageIslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // 菜单栏窗口在 `.mainMenu`；岛形要盖在菜单栏上才能贴住刘海，取 `.statusBar`。
        // 菜单栏展开的下拉菜单层级更高，仍会显示在岛形之上。
        level = .statusBar
        hidesOnDeactivate = false
        // 黑色岛形与刘海相接，系统阴影会在屏幕上沿画出一道边，关闭。
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        worksWhenModal = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 系统默认会把窗口挤出菜单栏区域；岛形必须贴住屏幕上沿，不做约束。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 灵动岛专用 hosting view。
///
/// 与 HUD 的 `DraggableHostingView` 相反：不接管 hitTest / mouseDown，SwiftUI 的点击与拖动手势照常工作，
/// 拖动、点击、按钮由视图自己划分区域。这里只补三件事：
/// 1. `acceptsFirstMouse`：App 不在前台时第一下点击也能生效；
/// 2. `.activeAlways` 的跟踪区：App 不在前台时也能收到悬停进出；
/// 3. 右键菜单。
/// 刻意不做成泛型，原因同 `DraggableHostingView`（Release 下编译器崩溃）。
final class UsageIslandHostingView: NSHostingView<AnyView> {
    var onHoverChange: ((Bool) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }
}

/// 顶部用量胶囊：今日累计常驻、悬停展开明细、Codex 回合完成提示排队显示。
@MainActor
final class UsageIslandController: NSObject {
    static let shared = UsageIslandController()

    let model = UsageIslandModel()
    private var panel: UsageIslandPanel?
    private var hostingView: UsageIslandHostingView?
    private weak var appState: AppState?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// 打开统计页 / 设置页；`openWindow` 只在 SwiftUI 环境里可用，由 App 层注入。
    var openStatisticsHandler: (() -> Void)?
    var openSettingsHandler: (() -> Void)?

    /// 岛形内容的实际尺寸（SwiftUI 回报）。
    private var contentSize: CGSize = .zero
    /// 展开 / 收起过渡中：窗口画布保持前后两者的并集，动画结束再收回，收起动画不会被窗口裁掉。
    private var isTransitioning = false
    private var transitionTask: Task<Void, Never>?
    private var isHovering = false
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastUsageRefreshAt: Date?
    private var drag: (mouseX: CGFloat, frameX: CGFloat)?
    private var lastDragEndedAt: Date?

    /// 悬停多久后展开、离开多久后收回。
    private static let expandDelay: Duration = .milliseconds(350)
    private static let collapseDelay: Duration = .milliseconds(400)
    /// 每条回合提示的停留时间；悬停时暂停。
    private static let noticeDuration: Duration = .seconds(4)
    /// 排队超过这个数时不再逐条播放，合并成一条「另有 N 轮」，避免长时间遮挡。
    private static let maxQueuedNotices = 3
    /// 回合结束后请求一次今日用量刷新的最小间隔。
    private static let usageRefreshInterval: TimeInterval = 60

    func attach(appState: AppState) {
        self.appState = appState
        let tracker = CodexTurnTracker.shared
        tracker.onNotices = { [weak self] notices in self?.enqueue(notices) }
        tracker.onTurnEnded = { [weak self] in self?.requestUsageRefresh() }
    }

    /// 按设置显示 / 隐藏，并启停回合追踪。
    func sync() {
        let settings = SettingsStore.shared
        guard settings.usageIslandEnabled, appState != nil else {
            CodexTurnTracker.shared.stop()
            model.queue.removeAll()
            model.mode = .collapsed
            panel?.orderOut(nil)
            unregisterObservers()
            return
        }
        if settings.usageIslandTurnNotices {
            CodexTurnTracker.shared.start(notificationsEnabled: true)
        } else {
            CodexTurnTracker.shared.stop()
            model.queue.removeAll()
        }
        if panel == nil { buildPanel() }
        registerObservers()
        updateVisibility()
        layout()
    }

    /// 退出前保存回合账本。
    func prepareForTermination() async {
        await CodexTurnTracker.shared.persistForTermination()
    }

    // MARK: Panel

    private func buildPanel() {
        guard let appState else { return }
        let settings = SettingsStore.shared
        let actions = UsageIslandActions(
            sizeChanged: { [weak self] size in self?.contentSizeChanged(size) },
            openStatistics: { [weak self] in self?.openStatistics() },
            openTurn: { [weak self] turn in self?.openTurn(turn) },
            expand: { [weak self] in self?.expand() },
            dragChanged: { [weak self] in self?.dragChanged() },
            dragEnded: { [weak self] in self?.dragEnded() }
        )
        let content = AnyView(
            UsageIslandRootView(
                model: model,
                settings: settings,
                tracker: CodexTurnTracker.shared,
                actions: actions
            )
            .environment(appState)
        )
        let hosting = UsageIslandHostingView(rootView: content)
        hosting.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        hosting.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.sizingOptions = []

        let initial = CGRect(x: 0, y: 0, width: 160, height: 26)
        let panel = UsageIslandPanel(contentRect: initial)
        panel.contentView = hosting
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        self.panel = panel
        self.hostingView = hosting
        hosting.layoutSubtreeIfNeeded()
        contentSize = hosting.fittingSize
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != contentSize else { return }
        contentSize = size
        let current = model.canvasSize
        setCanvas(isTransitioning
            ? CGSize(width: max(current.width, size.width), height: max(current.height, size.height))
            : size)
    }

    private func setCanvas(_ size: CGSize) {
        if model.canvasSize != size {
            // 画布跟着窗口一起瞬时变化，不能被卷进展开 / 收起的动画事务，否则岛形会相对窗口漂移。
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.canvasSize = size }
        }
        layout()
    }

    /// 变大用略带回弹的弹簧，变小用不回弹的快速弹簧；系统开启「减弱动态效果」时直接切换。
    private static let expandAnimation = UsageIslandMotion.grow
    private static let collapseAnimation = UsageIslandMotion.shrink
    private static let transitionDuration = UsageIslandMotion.settleDuration

    private func setMode(_ mode: UsageIslandModel.Mode) {
        guard model.mode != mode else { return }
        animate(growing: mode == .expanded) { model.mode = mode }
    }

    /// 岛形内容的所有变化（悬停展开 / 收起、回合提示弹出 / 切换 / 收回、临时提示）都走这里：
    /// 变大用略带回弹的弹簧，变小用不回弹的弹簧；过渡期间窗口画布保持前后尺寸的并集。
    private func animate(growing: Bool, _ change: () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            change()
            return
        }
        isTransitioning = true
        transitionTask?.cancel()
        withAnimation(growing ? Self.expandAnimation : Self.collapseAnimation) {
            change()
        }
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: Self.transitionDuration)
            guard !Task.isCancelled, let self else { return }
            self.isTransitioning = false
            self.setCanvas(self.contentSize)
        }
    }

    /// 选中的屏幕；断开后回落到主显示器。
    private func targetScreen() -> NSScreen? {
        let id = SettingsStore.shared.usageIslandDisplayID
        if !id.isEmpty, let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == id }) {
            return screen
        }
        return NSScreen.screens.first
    }

    static func displayID(of screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "\($0.uint32Value)" } ?? ""
    }

    private func layout() {
        guard let panel, drag == nil, let screen = targetScreen() else { return }
        let auxLeft = screen.auxiliaryTopLeftArea
        let auxRight = screen.auxiliaryTopRightArea
        let geometry = UsageIslandLayout.geometry(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeft: auxLeft,
            auxiliaryRight: auxRight
        )
        // 几何变化会让内容重新布局，尺寸回报后再进来一次定位。
        if model.geometry != geometry { model.geometry = geometry }
        let canvas = model.canvasSize.width > 1 ? model.canvasSize : contentSize
        let size = canvas.width > 1 ? canvas : CGSize(width: 160, height: geometry.barHeight)
        let centerX = UsageIslandLayout.centerX(
            screenFrame: screen.frame,
            auxiliaryLeft: auxLeft,
            auxiliaryRight: auxRight,
            geometry: geometry,
            offset: SettingsStore.shared.usageIslandOffset
        )
        let frame = UsageIslandLayout.frame(contentSize: size, screenFrame: screen.frame, centerX: centerX)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private var shouldShowPanel: Bool {
        guard SettingsStore.shared.usageIslandEnabled else { return false }
        // 关掉回合提示后没有东西会让它出现，「平时隐藏」不生效。
        if !SettingsStore.shared.usageIslandAutoHide || !SettingsStore.shared.usageIslandTurnNotices { return true }
        return !model.queue.isEmpty || model.mode == .expanded || isHovering || model.message != nil
    }

    private func updateVisibility() {
        guard let panel else { return }
        if shouldShowPanel {
            if !panel.isVisible {
                layout()
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: Hover

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            collapseTask?.cancel()
            guard drag == nil else { return }
            if model.currentNotice != nil {
                // 悬停在提示上：暂停收回，方便点击。
                dismissTask?.cancel()
                return
            }
            guard model.mode == .collapsed else { return }
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: Self.expandDelay)
                guard !Task.isCancelled, let self, self.isHovering, self.drag == nil else { return }
                self.expand()
            }
        } else {
            hoverTask?.cancel()
            collapseTask?.cancel()
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: Self.collapseDelay)
                guard !Task.isCancelled, let self, !self.isHovering else { return }
                self.collapse()
            }
        }
    }

    private func expand() {
        hoverTask?.cancel()
        dismissTask?.cancel()
        // 展开后排队的提示都在「最近的回合」里，不再逐条弹出。
        animate(growing: true) {
            model.queue.removeAll()
            model.skippedNotices = 0
            model.mode = .expanded
        }
        updateVisibility()
    }

    private func collapse() {
        if model.mode == .expanded {
            setMode(.collapsed)
        }
        if model.currentNotice != nil {
            scheduleDismiss(after: .seconds(1.5))
        }
        updateVisibility()
    }

    // MARK: Notices

    private func enqueue(_ notices: [CodexTurnRecord]) {
        guard SettingsStore.shared.usageIslandEnabled, SettingsStore.shared.usageIslandTurnNotices else { return }
        if model.mode == .expanded {
            // 展开面板的列表会直接显示新回合。
            return
        }
        let wasEmpty = model.queue.isEmpty
        animate(growing: true) { model.queue.append(contentsOf: notices) }
        updateVisibility()
        if wasEmpty { scheduleDismiss(after: Self.noticeDuration) }
    }

    private func scheduleDismiss(after delay: Duration) {
        dismissTask?.cancel()
        guard !isHovering else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            self.advanceQueue()
        }
    }

    private func advanceQueue() {
        guard !model.queue.isEmpty else { return }
        // 最后一条收回时岛形变小；切到下一条时宽度可能变大也可能变小，按变大处理（略带回弹）。
        animate(growing: model.queue.count > 1) {
            if model.queue.count > Self.maxQueuedNotices {
                // 长队列：直接跳到最新一条，并带上「另有 N 轮」，其余在展开面板里看。
                model.skippedNotices += model.queue.count - 2
                model.queue = [model.queue[model.queue.count - 1]]
            } else {
                model.queue.removeFirst()
            }
            if model.queue.isEmpty { model.skippedNotices = 0 }
        }
        updateVisibility()
        if !model.queue.isEmpty { scheduleDismiss(after: Self.noticeDuration) }
    }

    // MARK: Drag

    private func dragChanged() {
        // 有刘海时岛形固定包住刘海。
        guard let panel, !model.geometry.hasNotch else { return }
        hoverTask?.cancel()
        dismissTask?.cancel()
        let mouseX = NSEvent.mouseLocation.x
        if drag == nil {
            drag = (mouseX, panel.frame.origin.x)
        }
        guard let drag, let screen = targetScreen() else { return }
        let minX = screen.frame.minX + UsageIslandLayout.sideMargin
        let maxX = screen.frame.maxX - UsageIslandLayout.sideMargin - panel.frame.width
        let x = min(max(drag.frameX + (mouseX - drag.mouseX), minX), max(minX, maxX))
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: panel.frame.origin.y))
    }

    private func dragEnded() {
        guard let panel, drag != nil else { return }
        drag = nil
        lastDragEndedAt = Date()
        if let screen = targetScreen() {
            SettingsStore.shared.usageIslandOffset = UsageIslandLayout.offset(
                forCenterX: panel.frame.midX, screenFrame: screen.frame
            )
        }
        layout()
        if model.currentNotice != nil { scheduleDismiss(after: .seconds(2)) }
    }

    /// 刚拖完松手时不当成点击。
    private var justDragged: Bool {
        lastDragEndedAt.map { Date().timeIntervalSince($0) < 0.3 } ?? false
    }

    // MARK: Actions

    private func openStatistics() {
        guard !justDragged else { return }
        if let appState {
            appState.mainWindowSession.range = .today
            appState.mainWindowSession.serviceFilter = .all
            appState.mainWindowSession.viewMode = .overview
        }
        openStatisticsHandler?()
    }

    /// Codex：用官方深链 `codex://threads/<id>` 打开对话；只保证打开该对话，不保证定位到具体回合或已有窗口。
    /// Claude Code：没有公开的会话深链，打开统计页对话视图并选中该对话（同弹出面板「最近对话」）。
    private func openTurn(_ turn: CodexTurnRecord) {
        guard !justDragged else { return }
        if model.currentNotice?.id == turn.id {
            advanceQueue()
        }
        guard turn.app == .codex else {
            appState?.pendingStatsConversation = PendingStatsConversation(key: turn.conversationKey, app: turn.app)
            openStatisticsHandler?()
            return
        }
        guard let url = URL(string: "codex://threads/\(turn.threadID)") else { return }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            showMessage(tr("Couldn't open conversation. Install or update Codex.", "无法打开对话，请安装或更新 Codex"))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            guard error != nil else { return }
            Task { @MainActor in
                UsageIslandController.shared.showMessage(tr("Couldn't open conversation in Codex", "无法在 Codex 中打开对话"))
            }
        }
    }

    private func showMessage(_ text: String) {
        animate(growing: true) { model.message = text }
        updateVisibility()
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.animate(growing: false) { self.model.message = nil }
            self.updateVisibility()
        }
    }

    /// 回合结束后尽快刷新今日累计。走 `UsageService` 现有的增量扫描（与手动刷新同一入口），
    /// 最多每分钟一次，不改写盘节流。
    private func requestUsageRefresh() {
        guard SettingsStore.shared.usageIslandEnabled, let appState, refreshTask == nil else { return }
        if let last = lastUsageRefreshAt, Date().timeIntervalSince(last) < Self.usageRefreshInterval { return }
        lastUsageRefreshAt = Date()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await appState.usageService.scanNow()
            self?.refreshTask = nil
        }
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let reset = NSMenuItem(title: tr("Reset Position", "恢复居中"), action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let hide = NSMenuItem(title: tr("Hide Usage Island", "隐藏顶部用量胶囊"), action: #selector(hideFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: tr("Settings", "设置"), action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func resetPosition() {
        SettingsStore.shared.usageIslandOffset = 0
        layout()
    }

    @objc private func hideFromMenu() {
        SettingsStore.shared.usageIslandEnabled = false
        sync()
    }

    @objc private func openSettingsFromMenu() {
        openSettingsHandler?()
    }

    /// 设置页修改位置 / 显示器后调用。
    func relayout() {
        layout()
    }

    // MARK: System events

    private func registerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        // 显示器接入 / 断开、分辨率与排列变化：重新按安全区域定位。
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.layout() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.layout() }
        // 唤醒：FSEvents 可能在睡眠期间合并，补扫一次；屏幕排列也可能变了。
        observe(workspace, NSWorkspace.didWakeNotification) { controller in
            controller.layout()
            CodexTurnTracker.shared.requestSweep()
        }
        // 跨午夜：今日累计归零。
        observe(center, .NSCalendarDayChanged) { $0.model.dayToken += 1 }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ handler: @escaping @MainActor (UsageIslandController) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private func unregisterObservers() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
    }
}
