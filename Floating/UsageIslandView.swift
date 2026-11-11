import SwiftUI

// MARK: - UsageIslandRootView
//
// 见 docs/界面布局.md §2a。灵动岛样式：黑色岛形贴住屏幕上沿，与刘海融为一体。
// - 收起：刘海左侧「今日 $…」，右侧「…M」；无刘海屏幕在菜单栏正中显示同样的黑色岛形，中间用「·」分隔；
// - 回合提示：左侧换成「对话名」，右侧换成「+$… · +…M」，约 4 秒后收回；
// - 展开（悬停）：从岛形向下展开今日明细与最近回合。
// 左右两翼等宽，刘海始终落在正中。始终用深色外观；收起纯黑，展开后明细区域是深色毛玻璃。
// 展开 / 收起用弹簧曲线过渡（控制器里 `withAnimation`），岛形尺寸与底角一起变化；没有常驻动画。

struct UsageIslandRootView: View {
    @Environment(AppState.self) private var appState
    let model: UsageIslandModel
    let settings: SettingsStore
    let tracker: CodexTurnTracker
    let actions: UsageIslandActions

    var body: some View {
        island
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: UsageIslandSizeKey.self, value: proxy.size)
                }
            }
            .onPreferenceChange(UsageIslandSizeKey.self) { size in
                actions.sizeChanged(size)
            }
            // 窗口画布可能比岛形大（过渡中），岛形始终贴顶居中。
            .frame(
                width: model.canvasSize.width > 1 ? model.canvasSize.width : nil,
                height: model.canvasSize.height > 1 ? model.canvasSize.height : nil,
                alignment: .top
            )
            .environment(\.colorScheme, .dark)
    }

    private var geometry: UsageIslandGeometry { model.geometry }
    private var isExpanded: Bool { model.mode == .expanded }

    private var island: some View {
        VStack(spacing: 0) {
            UsageIslandBar(geometry: geometry, left: { left }, right: { right })
                .contentShape(Rectangle())
                .islandDragAndTap(actions: actions, onTap: barTapped)
                .help(barHelp)
            if isExpanded {
                UsageIslandExpandedView(
                    summary: summary,
                    updatedAt: appState.usageService.lastScanAt,
                    recentTurns: tracker.recentTurns,
                    showsTurns: settings.usageIslandTurnNotices,
                    message: model.message,
                    actions: actions
                )
                // 明细从顶栏下方滑出并淡入；收起时只淡出，跟着岛形一起收拢。
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -10)),
                    removal: .opacity
                ))
            }
        }
        .padding(.horizontal, UsageIslandShape.shoulder)
        .padding(.bottom, isExpanded ? 6 : 0)
        .background(islandBackground)
        .clipShape(UsageIslandShape(bottomRadius: bottomRadius))
        .contentShape(UsageIslandShape(bottomRadius: bottomRadius))
        .accessibilityElement(children: .contain)
    }

    private var bottomRadius: CGFloat {
        isExpanded ? 18 : min(12, geometry.barHeight / 2)
    }

    /// 收起时纯黑，与刘海、菜单栏无缝衔接。展开时明细区域换成深色毛玻璃：
    /// 顶栏行保持纯黑，往下约 28pt 渐变到半透明深色，背后的桌面从明细区域透出来。
    /// `.hudWindow` 材质始终是深色；`VisualEffectBackground` 默认 `.active`，App 不在前台时也保持模糊。
    private var islandBackground: some View {
        ZStack(alignment: .top) {
            if isExpanded {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                    .transition(.opacity)
            }
            Color.black.opacity(isExpanded ? 0.42 : 1)
            VStack(spacing: 0) {
                Color.black.frame(height: geometry.barHeight)
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Bar content

    private var notice: CodexTurnRecord? {
        guard !isExpanded, let first = model.currentNotice else { return nil }
        return tracker.recentTurns.first { $0.id == first.id } ?? first
    }

    @ViewBuilder
    private var left: some View {
        if let message = model.message, !isExpanded {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let notice {
            HStack(spacing: 6) {
                UsageIslandTurnText.tile(notice.app, size: 16)
                Text(UsageIslandTurnText.title(notice))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150, alignment: .leading)
            }
            // 换到下一条提示时按新内容淡入淡出，而不是原地改字。
            .id(notice.id)
            .transition(.opacity)
        } else {
            HStack(spacing: 5) {
                Text(tr("Today", "今日")).foregroundStyle(.secondary)
                Text(UsageIslandFormat.cost(summary.total.costUSD) + (summary.costIncomplete ? "+" : ""))
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var right: some View {
        if model.message != nil, !isExpanded {
            EmptyView()
        } else if let notice {
            HStack(spacing: 6) {
                UsageIslandTurnAmount(turn: notice)
                let remaining = model.queue.count - 1 + model.skippedNotices
                if remaining > 0 {
                    Button(action: actions.expand) {
                        Text(tr("+\(remaining)", "另有 \(remaining) 轮"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Show all", "展开查看"))
                }
            }
            .id(notice.id)
            .transition(.opacity)
        } else {
            HStack(spacing: 5) {
                Text(UsageIslandFormat.tokens(summary.total.totalTokens))
                    .monospacedDigit()
                // 菜单栏的额度百分比合并到这里（同一规则与设置），不带服务图标。
                ForEach(quotaItems) { item in
                    Text("·").foregroundStyle(.tertiary)
                    Text(item.text)
                        .monospacedDigit()
                        .foregroundStyle(item.color)
                }
            }
        }
    }

    /// 与菜单栏同一来源：「菜单栏」开关打开的额度服务、「额度周期」设置。
    private var quotaItems: [UsageIslandQuotaItem] {
        let window = settings.menuBarWindow
        return settings.orderedMenuBarProviders
            .filter { settings.effectiveMenuBarVisibility(for: $0.app) }
            .map { provider in
                let snapshot = appState.quotaSnapshot(for: provider.app)
                let remaining = snapshot.flatMap { snapshot in
                    snapshot.isUnlimited == true
                        ? nil
                        : MenuBarQuotaSelection.limits(in: snapshot, choice: window).map(\.window.remainingPercent).min()
                }
                return UsageIslandQuotaItem(
                    id: provider.app,
                    text: MenuBarBadgeImage.pctText(snapshot, window: window),
                    color: Self.quotaColor(remaining)
                )
            }
    }

    /// 黑底上中性的石墨灰看不清，正常档用白色；低于 20% 橙、用完红，与 `statusColor` 的分档一致。
    private static func quotaColor(_ remaining: Double?) -> Color {
        guard let remaining else { return .white }
        if remaining <= 0 { return .red }
        if remaining < 20 { return .orange }
        return .white
    }

    private func barTapped() {
        if let notice {
            actions.openTurn(notice)
        } else {
            actions.openStatistics()
        }
    }

    private var barHelp: String {
        if let notice { return UsageIslandTurnText.openHelp(notice) }
        return geometry.hasNotch
            ? tr("Click to open Statistics", "点击打开统计")
            : tr("Click to open Statistics. Drag to move.", "点击打开统计，拖动可左右移动")
    }

    /// 只在聚合器版本、可见服务或日期变化时重算。
    private var summary: UsageIslandTodaySummary {
        let aggregator = appState.usageService.aggregator
        let visible = settings.visibleUsageApps
        let day = UsageDay.startOfDay(for: Date())
        let key = "\(aggregator.revision)|\(visible.map(\.rawValue).joined(separator: ","))|\(day.timeIntervalSince1970)|\(model.dayToken)"
        if let cached = model.summaryCache, cached.key == key { return cached.value }
        let value = UsageIslandTodaySummary.make(buckets: aggregator.snapshot(), visibleApps: visible, day: day)
        model.summaryCache = (key, value)
        return value
    }
}

private struct UsageIslandQuotaItem: Identifiable {
    var id: QuotaApp
    var text: String
    var color: Color
}

/// 视图回调到控制器的入口。
struct UsageIslandActions {
    var sizeChanged: (CGSize) -> Void
    var openStatistics: () -> Void
    var openTurn: (CodexTurnRecord) -> Void
    var expand: () -> Void
    var dragChanged: () -> Void
    var dragEnded: () -> Void
}

private struct UsageIslandSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - 岛形

/// 顶边平直贴住屏幕上沿，两侧顶角向外弯出「肩」与菜单栏衔接，底边圆角。与刘海的外形一致。
struct UsageIslandShape: Shape {
    /// 顶部外弯的宽度；内容需左右各让出这么多。
    static let shoulder: CGFloat = 6
    var bottomRadius: CGFloat

    /// 展开 / 收起时底角随尺寸一起过渡。
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = Self.shoulder
        let r = min(bottomRadius, (rect.width - 2 * s) / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s),
                          control: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s + r, y: rect.maxY),
                          control: CGPoint(x: rect.minX + s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r),
                          control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - s, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private extension View {
    /// 无刘海时岛形可横向拖动；没拖动时按点击处理。拖动用 4pt 阈值，避免点击误触拖动。
    func islandDragAndTap(actions: UsageIslandActions, onTap: @escaping () -> Void) -> some View {
        gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in actions.dragChanged() }
                .onEnded { _ in actions.dragEnded() }
                .exclusively(before: TapGesture().onEnded { onTap() })
        )
    }
}

// MARK: - 顶栏行

/// 与菜单栏同高的一行：左翼 + 刘海（或「·」）+ 右翼，左右边距相同。
/// 有刘海时两翼按较宽的一侧等宽（刘海才能居中），文字在各自一翼内居中；无刘海时按实际宽度排列，整体居中。
private struct UsageIslandBar<Left: View, Right: View>: View {
    let geometry: UsageIslandGeometry
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right
    @State private var wingWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            left()
                .fixedSize()
                .background(measure)
                .frame(minWidth: geometry.hasNotch ? wingWidth : nil)
                .padding(.leading, 12)
            Group {
                if geometry.hasNotch {
                    Color.clear.frame(width: geometry.notchWidth + 16)
                } else {
                    Text("·").foregroundStyle(.tertiary).padding(.horizontal, 6)
                }
            }
            right()
                .fixedSize()
                .background(measure)
                .frame(minWidth: geometry.hasNotch ? wingWidth : nil)
                .padding(.trailing, 12)
        }
        .font(.system(size: geometry.barHeight > 26 ? 13 : 12, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(height: geometry.barHeight)
        .onPreferenceChange(UsageIslandWingKey.self) { width in
            guard abs(width - wingWidth) > 0.5 else { return }
            // 有刘海时两翼按较宽的一侧等宽；内容变化后跟着弹簧过渡，不在动画中途跳宽。
            if reduceMotion || wingWidth == 0 {
                wingWidth = width
            } else {
                withAnimation(UsageIslandMotion.grow) { wingWidth = width }
            }
        }
    }

    private var measure: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: UsageIslandWingKey.self, value: proxy.size.width)
        }
    }
}

private struct UsageIslandWingKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 回合增量：完整时写本轮金额与 tokens；否则标明状态，不把未完成的数字当成本轮用量。
private struct UsageIslandTurnAmount: View {
    let turn: CodexTurnRecord

    var body: some View {
        HStack(spacing: 5) {
            if turn.status == .unattributed {
                Text(tr("Can't attribute exactly", "无法精确归属"))
                    .foregroundStyle(.secondary)
            } else {
                if turn.usage.hasUnpricedUsage {
                    Text(tr("Cost incomplete", "费用不完整"))
                        .foregroundStyle(.orange)
                } else {
                    Text(UsageIslandFormat.cost(turn.usage.costUSD, signed: true))
                        .monospacedDigit()
                }
                Text("·").foregroundStyle(.tertiary)
                Text(UsageIslandFormat.tokens(turn.usage.totalTokens, signed: true))
                    .monospacedDigit()
                if let badge = UsageIslandTurnText.badge(turn) {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(UsageIslandTurnText.detail(turn))
    }
}

@MainActor
enum UsageIslandTurnText {
    static func title(_ turn: CodexTurnRecord) -> String {
        PrivacyDisplay.conversation(key: turn.conversationKey, title: turn.title)
    }

    static func tile(_ app: UsageApp, size: CGFloat) -> some View {
        ServiceTile(
            logoName: app.logoName,
            fallback: String(app.displayName.prefix(1)),
            tint: app.tintColor,
            size: size,
            logoSize: size * 0.625,
            cornerRadius: size / 4
        )
    }

    /// Codex 有官方深链可以打开对话；Claude Code 没有公开的会话深链，改为在统计页对话视图里定位。
    static func openHelp(_ turn: CodexTurnRecord) -> String {
        turn.app == .codex
            ? tr("Open this conversation in Codex", "在 Codex 中打开对话")
            : tr("Show this conversation in Statistics", "在统计中查看对话")
    }

    /// 非完整状态的短标签。
    static func badge(_ turn: CodexTurnRecord) -> String? {
        switch turn.status {
        case .settling: tr("Pending", "待汇总")
        case .interrupted: tr("Interrupted", "已中断")
        case .complete, .running, .unattributed: nil
        }
    }

    /// 悬停说明：先说结果，再说原因。
    static func detail(_ turn: CodexTurnRecord) -> String {
        switch turn.status {
        case .complete:
            turn.hasSubagents
                ? tr("Usage for this turn, including subagents", "本轮用量，含子代理")
                : tr("Usage for this turn", "本轮用量")
        case .interrupted:
            tr("Turn was interrupted; usage already incurred is kept", "本轮已中断，已产生的用量照常计入")
        case .settling:
            turn.hasSubagents
                ? tr("Subagents are still running; this will update when they finish", "子代理仍在运行，结束后自动补记")
                : tr("Some usage hasn't been recorded yet; this will update shortly", "部分用量还没写入，稍后自动更新")
        case .unattributed:
            tr("This Codex version doesn't log per-turn usage", "当前 Codex 版本的日志没有逐轮用量记录")
        case .running:
            ""
        }
    }
}

// MARK: - 展开

private struct UsageIslandExpandedView: View {
    let summary: UsageIslandTodaySummary
    let updatedAt: Date?
    let recentTurns: [CodexTurnRecord]
    let showsTurns: Bool
    let message: String?
    let actions: UsageIslandActions

    static let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.rows) { row in
                    UsageIslandAppRow(row: row)
                }
                if summary.costIncomplete {
                    Label(
                        tr("Some models have no price; cost is incomplete", "部分模型缺少价格，费用不完整"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showsTurns {
                divider
                turns
            }

            divider
            footer
        }
        .frame(width: Self.width, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }

    private var header: some View {
        Button(action: actions.openStatistics) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tr("Today's local usage", "今日本机用量"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let updatedAt {
                        Text(tr("Updated \(updatedAt.formatted(date: .omitted, time: .shortened))",
                                "更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(UsageIslandFormat.cost(summary.total.costUSD))
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(UsageIslandFormat.tokens(summary.total.totalTokens))
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                UsageIslandMetrics(totals: summary.total, size: 11)
                Text(tr("API-equivalent estimate, not your subscription bill or remaining quota",
                        "按 API 价格估算，不是订阅扣款，也不是剩余额度"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(tr("Open Statistics", "打开统计"))
    }

    @ViewBuilder
    private var turns: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Recent turns", "最近的回合"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if recentTurns.isEmpty {
                Text(tr("Shown here after each turn ends", "每轮结束后显示在这里"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(recentTurns.prefix(5)) { turn in
                    Button { actions.openTurn(turn) } label: {
                        HStack(spacing: 8) {
                            UsageIslandTurnText.tile(turn.app, size: 14)
                            Text(UsageIslandTurnText.title(turn))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            if turn.status != .unattributed, turn.usage.totalTokens > 0 {
                                Text(tr("Hit \(StatsFormatter.percent(turn.usage.cacheHitRate))",
                                        "命中 \(StatsFormatter.percent(turn.usage.cacheHitRate))"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                    .help(tr("Cache hit rate for this turn", "本轮缓存命中率"))
                            }
                            UsageIslandTurnAmount(turn: turn)
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(UsageIslandTurnText.openHelp(turn))
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        Text(tr("Scope: \(summary.scope.map(\.displayName).joined(separator: ", "))",
                "统计范围：\(summary.scope.map(\.displayName).joined(separator: "、"))"))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

/// 缓存命中率与输出速度，口径与统计页相同（`UsageTotals.cacheHitRate`、`StatsFormatter.outputSpeed`，
/// 含 Pi 近似计时时前缀「≈」并给出说明）。没有可计时的请求时速度显示「—」。
private struct UsageIslandMetrics: View {
    let totals: UsageTotals
    let size: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            metric(tr("Hit rate", "命中率"), StatsFormatter.percent(totals.cacheHitRate))
            metric(tr("Output speed", "输出速度"), StatsFormatter.outputSpeed(totals.timing))
                .help(StatsFormatter.outputSpeedHelp(totals.timing))
        }
        .font(.system(size: size))
        .lineLimit(1)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct UsageIslandAppRow: View {
    let row: UsageIslandTodaySummary.AppRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ServiceTile(
                    logoName: row.app.logoName,
                    fallback: String(row.app.displayName.prefix(1)),
                    tint: row.app.tintColor,
                    size: 16,
                    logoSize: 10,
                    cornerRadius: 4
                )
                Text(row.app.displayName)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(UsageIslandFormat.cost(row.totals.costUSD) + (row.totals.hasUnpricedUsage ? "+" : ""))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Text(UsageIslandFormat.tokens(row.totals.totalTokens))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 52, alignment: .trailing)
            }
            HStack(spacing: 10) {
                breakdown(tr("In", "输入"), row.totals.inputTokens)
                breakdown(tr("Out", "输出"), row.totals.outputTokens)
                breakdown(tr("Cache read", "缓存读"), row.totals.cacheReadTokens)
                breakdown(tr("Cache write", "缓存写"), row.totals.cacheCreationTokens)
            }
            .padding(.leading, 24)
            UsageIslandMetrics(totals: row.totals, size: 10)
                .padding(.leading, 24)
        }
    }

    private func breakdown(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(UsageIslandFormat.tokens(value)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 10))
        .lineLimit(1)
    }
}
