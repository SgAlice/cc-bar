import AppKit
import SwiftUI
import Foundation
import Observation

// MARK: - 格式化

/// 顶部用量胶囊的数字格式。金额是 API 等值估算（Decimal 汇总完再格式化），
/// token 固定以 `M = 1,000,000` 显示，不跟随统计页的 Token 单位设置，胶囊宽度因此稳定。
nonisolated enum UsageIslandFormat {
    static func cost(_ value: Decimal, signed: Bool = false) -> String {
        let sign = signed ? "+" : ""
        if value == 0 { return "\(sign)$0.00" }
        // 小额非零费用不能显示成 $0.00。
        if value > 0 && value < Decimal(string: "0.01")! { return "\(sign)<$0.01" }
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.roundingMode = .halfUp
        let fractionDigits = value >= 1000 ? 0 : 2
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        let body = formatter.string(from: number) ?? "\(value)"
        return "\(sign)$\(body)"
    }

    static func tokens(_ count: Int, signed: Bool = false) -> String {
        let sign = signed ? "+" : ""
        if count <= 0 { return "\(sign)0M" }
        // 不足 0.01M 的非零用量同样不能显示成 0。
        if count < 5_000 { return "\(sign)<0.01M" }
        let millions = Double(count) / 1_000_000
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.roundingMode = .halfUp
        let digits = millions < 100 ? 2 : (millions < 1000 ? 1 : 0)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return "\(sign)\(formatter.string(from: NSNumber(value: millions)) ?? "\(millions)")M"
    }
}

// MARK: - 今日汇总

/// 胶囊与展开面板的今日数据。与统计页同一份 `UsageAggregator` 桶、同一可见服务筛选和价格，
/// 只是按本地日历的今天截取，不另写计价。
nonisolated struct UsageIslandTodaySummary: Equatable, Sendable {
    nonisolated struct AppRow: Equatable, Sendable, Identifiable {
        var app: UsageApp
        var totals: UsageTotals
        var id: UsageApp { app }
    }

    var total = UsageTotals.zero
    var rows: [AppRow] = []
    /// 统计范围：当前计入的服务（即统计页可见的服务）。
    var scope: [UsageApp] = []

    var costIncomplete: Bool { total.hasUnpricedUsage }

    /// - Parameters:
    ///   - day: 本地时区今天 0 点（`UsageDay.startOfDay`）。
    ///   - visibleApps: `SettingsStore.visibleUsageApps`，与统计页一致。
    static func make(buckets: [UsageBucket], visibleApps: [UsageApp], day: Date) -> UsageIslandTodaySummary {
        let visible = Set(visibleApps)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        var byApp: [UsageApp: UsageTotals] = [:]
        var total = UsageTotals.zero
        for bucket in buckets where visible.contains(bucket.app) && bucket.day >= day && bucket.day < nextDay {
            byApp[bucket.app, default: .zero].add(bucket)
            total.add(bucket)
        }
        // Codex / Claude Code 是主要分项，可见时总列出；其他服务今天有用量才列出。
        let rows = visibleApps.compactMap { app -> AppRow? in
            let totals = byApp[app] ?? .zero
            guard app == .codex || app == .claude || totals.totalTokens > 0 || totals.requestCount > 0 else {
                return nil
            }
            return AppRow(app: app, totals: totals)
        }
        return UsageIslandTodaySummary(total: total, rows: rows, scope: visibleApps)
    }
}

// MARK: - 位置

/// 灵动岛所在屏幕的顶部几何。
nonisolated struct UsageIslandGeometry: Equatable, Sendable {
    /// 刘海宽度；无刘海为 0。
    var notchWidth: CGFloat = 0
    /// 顶栏行高度：有刘海取刘海高度，否则取菜单栏高度。
    var barHeight: CGFloat = 24
    /// 有刘海时岛形固定包住刘海，不能拖动。
    var hasNotch: Bool { notchWidth > 0 }
}

/// 灵动岛窗口的位置计算（纯函数，便于测试）。
nonisolated enum UsageIslandLayout {
    /// 与屏幕左右边缘的最小间距。
    static let sideMargin: CGFloat = 8
    /// 菜单栏自动隐藏时读不到高度，按系统菜单栏常见高度兜底。
    static let fallbackBarHeight: CGFloat = 24

    /// 顶栏几何。
    /// - Parameters:
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top`，有刘海时即刘海高度。
    ///   - auxiliaryLeft / auxiliaryRight: `NSScreen.auxiliaryTopLeftArea / RightArea`，刘海两侧的菜单栏区域。
    static func geometry(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryLeft: CGRect?,
        auxiliaryRight: CGRect?
    ) -> UsageIslandGeometry {
        if safeAreaTop > 0, let left = auxiliaryLeft, let right = auxiliaryRight, right.minX > left.maxX {
            return UsageIslandGeometry(notchWidth: right.minX - left.maxX, barHeight: safeAreaTop)
        }
        let menuBar = screenFrame.maxY - visibleFrame.maxY
        return UsageIslandGeometry(notchWidth: 0, barHeight: menuBar > 0 ? menuBar : fallbackBarHeight)
    }

    /// 岛形中心：有刘海时对准刘海中心；否则屏幕中心加用户偏移（占屏幕宽度的比例）。
    static func centerX(
        screenFrame: CGRect,
        auxiliaryLeft: CGRect?,
        auxiliaryRight: CGRect?,
        geometry: UsageIslandGeometry,
        offset: Double
    ) -> CGFloat {
        if geometry.hasNotch, let left = auxiliaryLeft, let right = auxiliaryRight {
            return (left.maxX + right.minX) / 2
        }
        let clampedOffset = min(0.5, max(-0.5, offset))
        return screenFrame.midX + CGFloat(clampedOffset) * screenFrame.width
    }

    /// 窗口顶边贴住屏幕上沿，水平以 `centerX` 为中心并留在屏幕内。
    static func frame(contentSize: CGSize, screenFrame: CGRect, centerX: CGFloat) -> CGRect {
        var x = centerX - contentSize.width / 2
        let minX = screenFrame.minX + sideMargin
        let maxX = screenFrame.maxX - sideMargin - contentSize.width
        x = maxX < minX ? screenFrame.midX - contentSize.width / 2 : min(max(x, minX), maxX)
        return CGRect(
            x: x.rounded(),
            y: screenFrame.maxY - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    /// 拖动结束后，把窗口中心换算回比例偏移。
    static func offset(forCenterX centerX: CGFloat, screenFrame: CGRect) -> Double {
        guard screenFrame.width > 0 else { return 0 }
        return min(0.5, max(-0.5, Double((centerX - screenFrame.midX) / screenFrame.width)))
    }
}

// MARK: - 动效

/// 岛形尺寸变化的弹簧曲线：变大略带回弹，变小不回弹。悬停展开 / 收起与回合提示弹出 / 收回共用。
enum UsageIslandMotion {
    static let grow = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let shrink = Animation.spring(response: 0.3, dampingFraction: 0.95)
    /// 覆盖两种弹簧的稳定时间。
    static let settleDuration: Duration = .milliseconds(700)
}

// MARK: - 界面状态

@MainActor
@Observable
final class UsageIslandModel {
    enum Mode: Equatable {
        case collapsed
        case expanded
    }

    var mode: Mode = .collapsed
    /// 等待展示的回合提示，队首正在显示。
    var queue: [CodexTurnRecord] = []
    /// 长队列合并时跳过、未单独弹出的回合数（仍可在展开面板里看到）。
    var skippedNotices = 0
    /// 打开 Codex 对话失败等临时提示。
    var message: String?
    /// 跨午夜时递增，让今日汇总按新的一天重算。
    var dayToken = 0
    /// 当前屏幕的顶部几何（刘海宽度、菜单栏高度）。
    var geometry = UsageIslandGeometry()
    /// 窗口画布尺寸：平时等于岛形尺寸；展开 / 收起过渡中取前后两者的并集。岛形在画布里顶部居中。
    var canvasSize: CGSize = .zero

    var currentNotice: CodexTurnRecord? { queue.first }

    @ObservationIgnored var summaryCache: (key: String, value: UsageIslandTodaySummary)?
}
