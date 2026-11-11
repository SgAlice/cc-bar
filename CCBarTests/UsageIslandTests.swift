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

    func testLayoutStaysBelowMenuBarAndNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let frame = UsageIslandLayout.frame(
            contentSize: CGSize(width: 180, height: 26),
            screenFrame: screen, visibleFrame: visible, safeAreaTop: 32, offset: 0
        )
        XCTAssertEqual(frame.maxY, 945 - UsageIslandLayout.topGap)
        XCTAssertEqual(frame.midX, 756)

        // 菜单栏自动隐藏：visibleFrame 顶到屏幕边，仍要避开刘海。
        let autoHidden = UsageIslandLayout.frame(
            contentSize: CGSize(width: 180, height: 26),
            screenFrame: screen, visibleFrame: screen, safeAreaTop: 32, offset: 0
        )
        XCTAssertEqual(autoHidden.maxY, 982 - 32 - UsageIslandLayout.topGap)
    }

    func testLayoutClampsOffsetInsideScreenAndRoundTrips() {
        let screen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
        let size = CGSize(width: 320, height: 200)
        let farRight = UsageIslandLayout.frame(contentSize: size, screenFrame: screen, visibleFrame: visible,
                                               safeAreaTop: 0, offset: 0.5)
        XCTAssertEqual(farRight.maxX, screen.maxX - UsageIslandLayout.sideMargin)

        let shifted = UsageIslandLayout.frame(contentSize: CGSize(width: 180, height: 26), screenFrame: screen,
                                              visibleFrame: visible, safeAreaTop: 0, offset: 0.2)
        XCTAssertEqual(UsageIslandLayout.offset(forCenterX: shifted.midX, screenFrame: screen), 0.2, accuracy: 0.001)
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
