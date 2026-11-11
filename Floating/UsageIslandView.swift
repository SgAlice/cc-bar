import SwiftUI

// MARK: - UsageIslandRootView
//
// 见 docs/界面布局.md §2a。三种形态共用同一个窗口，窗口尺寸跟随内容：
// - 收起：窄胶囊「今日 $… · …M」；
// - 回合提示：胶囊换成「对话名  +$… · +…M」，约 4 秒后收回；
// - 展开（悬停）：今日明细 + 最近回合。
// 材质与悬浮窗 HUD 一致（窗背景 0.55 + `.popover` material + hairline）。不使用常驻动画。

struct UsageIslandRootView: View {
    @Environment(AppState.self) private var appState
    let model: UsageIslandModel
    let settings: SettingsStore
    let tracker: CodexTurnTracker
    let actions: UsageIslandActions

    var body: some View {
        content
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: UsageIslandSizeKey.self, value: proxy.size)
                }
            }
            .onPreferenceChange(UsageIslandSizeKey.self) { size in
                actions.sizeChanged(size)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .expanded:
            UsageIslandExpandedView(
                summary: summary,
                updatedAt: appState.usageService.lastScanAt,
                recentTurns: tracker.recentTurns,
                showsTurns: settings.usageIslandTurnNotices,
                message: model.message,
                actions: actions
            )
        case .collapsed:
            if let notice = model.currentNotice {
                UsageIslandNoticeView(
                    turn: latest(notice),
                    remaining: model.queue.count - 1 + model.skippedNotices,
                    actions: actions
                )
            } else {
                UsageIslandCapsuleView(summary: summary, message: model.message, actions: actions)
            }
        }
    }

    /// 提示弹出后账本还可能补记，显示时取最新值。
    private func latest(_ turn: CodexTurnRecord) -> CodexTurnRecord {
        tracker.recentTurns.first { $0.id == turn.id } ?? turn
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

// MARK: - 背景

private struct UsageIslandBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor).opacity(0.55)
                    VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

private extension View {
    func islandBackground(cornerRadius: CGFloat) -> some View {
        modifier(UsageIslandBackground(cornerRadius: cornerRadius))
    }

    /// 胶囊可横向拖动；没拖动时按点击处理。拖动用 4pt 阈值，避免点击误触拖动。
    func islandDragAndTap(actions: UsageIslandActions, onTap: @escaping () -> Void) -> some View {
        gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in actions.dragChanged() }
                .onEnded { _ in actions.dragEnded() }
                .exclusively(before: TapGesture().onEnded { onTap() })
        )
    }
}

// MARK: - 收起

private struct UsageIslandCapsuleView: View {
    let summary: UsageIslandTodaySummary
    let message: String?
    let actions: UsageIslandActions

    static let height: CGFloat = 26

    var body: some View {
        HStack(spacing: 6) {
            if let message {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
            } else {
                Text(tr("Today", "今日"))
                    .foregroundStyle(.secondary)
                Text(costText)
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(UsageIslandFormat.tokens(summary.total.totalTokens))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(minWidth: 120)
        .islandBackground(cornerRadius: Self.height / 2)
        .contentShape(Capsule())
        .islandDragAndTap(actions: actions, onTap: actions.openStatistics)
        .help(tr("Click to open Statistics. Drag to move.", "点击打开统计，拖动可左右移动"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// 有未定价用量时金额只是已知部分，加「+」提示不完整，展开面板里有明确说明。
    private var costText: String {
        UsageIslandFormat.cost(summary.total.costUSD) + (summary.costIncomplete ? "+" : "")
    }
}

// MARK: - 回合提示

private struct UsageIslandNoticeView: View {
    let turn: CodexTurnRecord
    let remaining: Int
    let actions: UsageIslandActions

    var body: some View {
        HStack(spacing: 8) {
            ServiceTile(
                logoName: UsageApp.codex.logoName,
                fallback: "C",
                tint: UsageApp.codex.tintColor,
                size: 16,
                logoSize: 10,
                cornerRadius: 4
            )
            Text(UsageIslandTurnText.title(turn))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 220, alignment: .leading)
            UsageIslandTurnAmount(turn: turn)
            if remaining > 0 {
                Button(action: actions.expand) {
                    Text(tr("+\(remaining) more", "另有 \(remaining) 轮"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("Show all", "展开查看"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .islandBackground(cornerRadius: 15)
        .contentShape(Capsule())
        .islandDragAndTap(actions: actions) { actions.openTurn(turn) }
        .help(tr("Open this conversation in Codex", "在 Codex 中打开对话"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .fixedSize()
        .help(UsageIslandTurnText.detail(turn))
    }
}

@MainActor
enum UsageIslandTurnText {
    static func title(_ turn: CodexTurnRecord) -> String {
        PrivacyDisplay.conversation(key: "codex:\(turn.threadID)", title: turn.title)
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

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
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
                Divider().padding(.horizontal, 14)
                turns
            }

            Divider().padding(.horizontal, 14)
            footer
        }
        .frame(width: Self.width, alignment: .leading)
        .islandBackground(cornerRadius: 14)
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
            Text(tr("Recent Codex turns", "最近的 Codex 回合"))
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
                            Text(UsageIslandTurnText.title(turn))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            UsageIslandTurnAmount(turn: turn)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
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
            .padding(.vertical, 8)
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
