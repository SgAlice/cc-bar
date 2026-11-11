import XCTest
@testable import CCBar

/// 顶部用量胶囊：数字格式、今日汇总口径（与统计页同源）、窗口定位。
final class UsageIslandTests: XCTestCase {
    // MARK: - 格式

    func testCostFormatting() {
        XCTAssertEqual(UsageIslandFormat.cost(0), "$0.00")
        XCTAssertEqual(UsageIslandFormat.cost(Decimal(string: "12.345")!), "$12.35")
        XCTAssertEqual(UsageIslandFormat.cost(Decimal(string: "0.004")!), "<$0.01")
        XCTAssertEqual(UsageIslandFormat.cost(Decimal(string: "0.004")!, signed: true), "+<$0.01")
        XCTAssertEqual(UsageIslandFormat.cost(Decimal(string: "0.23")!, signed: true), "+$0.23")
        XCTAssertEqual(UsageIslandFormat.cost(Decimal(string: "1234.5")!), "$1,235")
    }

    func testTokenFormattingUsesMillions() {
        XCTAssertEqual(UsageIslandFormat.tokens(0), "0M")
        XCTAssertEqual(UsageIslandFormat.tokens(1_200), "<0.01M")
        XCTAssertEqual(UsageIslandFormat.tokens(150_000, signed: true), "+0.15M")
        XCTAssertEqual(UsageIslandFormat.tokens(8_560_000), "8.56M")
        XCTAssertEqual(UsageIslandFormat.tokens(123_460_000), "123.5M")
        XCTAssertEqual(UsageIslandFormat.tokens(1_234_000_000), "1,234M")
    }

    func testHitRateKeepsOneDecimalWithoutRoundingUpToFull() {
        XCTAssertEqual(UsageIslandFormat.hitRate(0), "0.0%")
        XCTAssertEqual(UsageIslandFormat.hitRate(0.9963), "99.6%")
        XCTAssertEqual(UsageIslandFormat.hitRate(0.99996), "99.9%", "没到 100% 不进位成 100%")
        XCTAssertEqual(UsageIslandFormat.hitRate(1), "100%")
        XCTAssertEqual(UsageIslandFormat.hitRate(0.0004), "<0.1%")
        XCTAssertEqual(UsageIslandFormat.hitRate(0.5), "50.0%")
    }

    // MARK: - 今日汇总

    func testTodaySummaryUsesVisibleAppsAndTodayOnly() {
        let today = UsageDay.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let buckets = [
            bucket(.codex, day: today, input: 100, output: 10, cacheRead: 1000, cacheWrite: 5, cost: 1),
            bucket(.codex, day: today, input: 50, output: 5, cacheRead: 0, cacheWrite: 0, cost: 0.5, model: "gpt-5.6"),
            bucket(.claude, day: today, input: 200, output: 20, cacheRead: 0, cacheWrite: 30, cost: 2),
            bucket(.claude, day: yesterday, input: 9_999, output: 9_999, cacheRead: 0, cacheWrite: 0, cost: 99),
            // 不可见服务不计入。
            bucket(.pi, day: today, input: 7_777, output: 0, cacheRead: 0, cacheWrite: 0, cost: 77),
        ]
        let summary = UsageIslandTodaySummary.make(buckets: buckets, visibleApps: [.codex, .claude, .opencode], day: today)

        XCTAssertEqual(summary.total.costUSD, Decimal(string: "3.5"))
        // 总 tokens = 输入 + 输出 + 缓存读 + 缓存写。
        XCTAssertEqual(summary.total.totalTokens, 150 + 15 + 1000 + 5 + 200 + 20 + 30)
        XCTAssertEqual(summary.rows.map(\.app), [.codex, .claude], "没有用量的其他服务不列出")
        XCTAssertEqual(summary.rows.first?.totals.cacheReadTokens, 1000)
        XCTAssertEqual(summary.scope, [.codex, .claude, .opencode])
        XCTAssertFalse(summary.costIncomplete)
    }

    func testTodaySummaryFlagsUnpricedUsage() {
        let today = UsageDay.startOfDay(for: Date())
        var unpriced = bucket(.codex, day: today, input: 100, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0)
        unpriced.hasUnpricedUsage = true
        let summary = UsageIslandTodaySummary.make(buckets: [unpriced], visibleApps: [.codex], day: today)
        XCTAssertTrue(summary.costIncomplete)
    }

    // MARK: - 定位

    func testNotchScreenWrapsNotchAndIgnoresOffset() {
        // 14 英寸 MacBook Pro：刘海两侧是菜单栏区域，刘海高 32pt。
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let left = CGRect(x: 0, y: 950, width: 661, height: 32)
        let right = CGRect(x: 851, y: 950, width: 661, height: 32)
        let geometry = UsageIslandLayout.geometry(
            screenFrame: screen, visibleFrame: visible, safeAreaTop: 32, auxiliaryLeft: left, auxiliaryRight: right
        )
        XCTAssertEqual(geometry.notchWidth, 190)
        XCTAssertEqual(geometry.barHeight, 32)
        XCTAssertTrue(geometry.hasNotch)

        let center = UsageIslandLayout.centerX(
            screenFrame: screen, auxiliaryLeft: left, auxiliaryRight: right, geometry: geometry, offset: 0.3
        )
        XCTAssertEqual(center, 756, "有刘海时对准刘海中心，不受偏移影响")
        let frame = UsageIslandLayout.frame(contentSize: CGSize(width: 400, height: 32), screenFrame: screen, centerX: center)
        XCTAssertEqual(frame.maxY, screen.maxY, "贴住屏幕上沿")
        XCTAssertEqual(frame.midX, 756)
    }

    func testScreenWithoutNotchUsesMenuBarHeightAndOffset() {
        let screen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 1512, y: 0, width: 1920, height: 1050)
        let geometry = UsageIslandLayout.geometry(
            screenFrame: screen, visibleFrame: visible, safeAreaTop: 0, auxiliaryLeft: nil, auxiliaryRight: nil
        )
        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.barHeight, 30)

        // 菜单栏自动隐藏：读不到高度时用兜底值。
        let hidden = UsageIslandLayout.geometry(
            screenFrame: screen, visibleFrame: screen, safeAreaTop: 0, auxiliaryLeft: nil, auxiliaryRight: nil
        )
        XCTAssertEqual(hidden.barHeight, UsageIslandLayout.fallbackBarHeight)

        let center = UsageIslandLayout.centerX(
            screenFrame: screen, auxiliaryLeft: nil, auxiliaryRight: nil, geometry: geometry, offset: 0.2
        )
        let frame = UsageIslandLayout.frame(contentSize: CGSize(width: 180, height: 30), screenFrame: screen, centerX: center)
        XCTAssertEqual(frame.maxY, screen.maxY)
        XCTAssertEqual(UsageIslandLayout.offset(forCenterX: frame.midX, screenFrame: screen), 0.2, accuracy: 0.001)

        // 偏到最右也留在屏幕内。
        let farRight = UsageIslandLayout.frame(
            contentSize: CGSize(width: 340, height: 300), screenFrame: screen,
            centerX: UsageIslandLayout.centerX(screenFrame: screen, auxiliaryLeft: nil, auxiliaryRight: nil,
                                               geometry: geometry, offset: 0.5)
        )
        XCTAssertEqual(farRight.maxX, screen.maxX - UsageIslandLayout.sideMargin)
    }

    func testFullScreenDetectionMatchesWholeScreenOnly() {
        // 主显示器 1512×982 在左，外接 1920×1080 在右，顶边对齐。
        let primaryHeight: CGFloat = 982
        let external = UsageIslandLayout.cgBounds(
            of: CGRect(x: 1512, y: -98, width: 1920, height: 1080), primaryHeight: primaryHeight
        )
        XCTAssertEqual(external, CGRect(x: 1512, y: 0, width: 1920, height: 1080))

        let fullScreenVideo = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let maximized = CGRect(x: 1512, y: 30, width: 1920, height: 1050)
        let onOtherScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertTrue(UsageIslandLayout.isFullScreen(windowBounds: [maximized, fullScreenVideo], screenBounds: external))
        XCTAssertFalse(UsageIslandLayout.isFullScreen(windowBounds: [maximized], screenBounds: external),
                       "最大化窗口不盖住菜单栏，不算全屏")
        XCTAssertFalse(UsageIslandLayout.isFullScreen(windowBounds: [onOtherScreen], screenBounds: external),
                       "别的屏幕全屏不影响")
    }

    // MARK: - Helpers

    private func bucket(
        _ app: UsageApp, day: Date, input: Int, output: Int, cacheRead: Int, cacheWrite: Int,
        cost: Decimal, model: String = "gpt-5.5"
    ) -> UsageBucket {
        UsageBucket(
            app: app, model: model, speed: .standard, day: day,
            inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheCreationTokens: cacheWrite,
            costUSD: cost, requestCount: 1, hasUnpricedUsage: false
        )
    }
}
