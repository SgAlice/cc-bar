import XCTest
@testable import CCBar

/// 顶部用量胶囊的回合账本：归属、去重、对账、子代理、中断、重放与重启。
/// fixture 按本机 Codex 日志的真实结构脱敏构造（字段名与顺序一致，内容为占位）。
final class CodexTurnLedgerTests: XCTestCase {
    private let threadA = "01a1c8f8-0966-7b00-93d1-000000000001"
    private let threadB = "01a1c8f8-0966-7b00-93d1-000000000002"
    private let subThread = "01a1c912-44a2-7560-bad5-000000000003"
    private let launch = Date(timeIntervalSince1970: 1_794_370_000)

    /// 每次调用固定 $1，便于核对条数；`unpriced-*` 模型返回 nil。
    private nonisolated static let fakePricer: CodexTurnPricer = { @Sendable model, _, _, _ in
        model.hasPrefix("unpriced") ? nil : CostBreakdown(input: 1, output: 0, cacheRead: 0, cacheCreation: 0)
    }

    // MARK: - 账本单元

    func testSingleTurnWithSeveralCallsIsExactAndSumsTokenClasses() {
        var log = Fixture(thread: threadA)
        log.started("t1", at: launch + 10)
        log.call("t1", input: 1000, cached: 400, write: 100, output: 50)
        log.call("t1", input: 2000, cached: 1500, write: 0, output: 80)
        log.completed("t1", at: launch + 20)

        var ledger = CodexTurnLedger()
        let notices = apply(log, to: &ledger, now: launch + 21)

        XCTAssertEqual(notices.count, 1)
        let turn = try! XCTUnwrap(notices.first)
        XCTAssertEqual(turn.status, .complete)
        XCTAssertTrue(turn.isExact)
        XCTAssertEqual(turn.usage.requestCount, 2)
        // 输入已扣缓存读写：(1000-400-100) + (2000-1500-0)
        XCTAssertEqual(turn.usage.inputTokens, 1000)
        XCTAssertEqual(turn.usage.cacheReadTokens, 1900)
        XCTAssertEqual(turn.usage.cacheCreationTokens, 100)
        XCTAssertEqual(turn.usage.outputTokens, 130)
        // 总量 = 输入 + 输出 + 缓存读 + 缓存写，不重复扣减。
        XCTAssertEqual(turn.usage.totalTokens, 3130)
        XCTAssertEqual(turn.usage.costUSD, 2)
    }

    func testConsecutiveTurnsInSameThreadStaySeparate() {
        var log = Fixture(thread: threadA)
        log.started("t1", at: launch + 10)
        log.call("t1", input: 100, output: 10)
        log.completed("t1", at: launch + 11)
        log.started("t2", at: launch + 12)
        log.call("t2", input: 200, output: 20)
        log.call("t2", input: 300, output: 30)
        log.completed("t2", at: launch + 13)

        var ledger = CodexTurnLedger()
        let notices = apply(log, to: &ledger, now: launch + 14)

        XCTAssertEqual(notices.map(\.turnID), ["t1", "t2"])
        XCTAssertEqual(notices[0].usage.requestCount, 1)
        XCTAssertEqual(notices[0].usage.totalTokens, 110)
        XCTAssertEqual(notices[1].usage.requestCount, 2)
        XCTAssertEqual(notices[1].usage.totalTokens, 550)
    }

    func testParallelChatsDoNotMixAndQueueInCompletionOrder() {
        var a = Fixture(thread: threadA)
        var b = Fixture(thread: threadB)
        a.started("ta", at: launch + 10)
        b.started("tb", at: launch + 10)
        b.call("tb", input: 500, output: 5)
        a.call("ta", input: 100, output: 1)
        b.completed("tb", at: launch + 15)
        a.completed("ta", at: launch + 16)

        var ledger = CodexTurnLedger()
        // 两个文件分别读取；完成提示按结束时间排队，与读取顺序无关。
        for event in parse(a) + parse(b) { ledger.apply(event, now: launch + 17, pricer: Self.fakePricer) }
        let notices = ledger.settle(now: launch + 17, trackingStartedAt: launch)

        XCTAssertEqual(notices.map(\.threadID), [threadB, threadA])
        XCTAssertEqual(notices[0].usage.totalTokens, 505)
        XCTAssertEqual(notices[1].usage.totalTokens, 101)
    }

    func testSubagentUsageMergesIntoRootAndWaitsForChildToEnd() {
        var parent = Fixture(thread: threadA)
        parent.started("root", at: launch + 10)
        parent.call("root", input: 100, output: 10)

        var child = Fixture(thread: subThread, rootThread: threadA)
        child.started("child", root: "root", at: launch + 11)
        child.call("child", root: "root", input: 1000, output: 100)

        parent.completed("root", at: launch + 20)

        var ledger = CodexTurnLedger()
        for event in parse(parent) + parse(child) { ledger.apply(event, now: launch + 20, pricer: Self.fakePricer) }

        // 子代理还没结束：不宣称准确，也不立刻提示。
        var notices = ledger.settle(now: launch + 21, trackingStartedAt: launch)
        XCTAssertTrue(notices.isEmpty)
        XCTAssertEqual(ledger.turns["root"]?.status, .settling)

        child.completed("child", root: "root", at: launch + 22)
        for event in parse(child).suffix(1) { ledger.apply(event, now: launch + 22, pricer: Self.fakePricer) }
        notices = ledger.settle(now: launch + 22, trackingStartedAt: launch)

        let turn = try! XCTUnwrap(notices.first)
        XCTAssertTrue(turn.isExact)
        XCTAssertTrue(turn.hasSubagents)
        XCTAssertEqual(turn.usage.requestCount, 2)
        XCTAssertEqual(turn.usage.totalTokens, 1210)
        XCTAssertEqual(turn.segments.count, 2)
        // 子代理自己的回合不单独提示。
        XCTAssertNil(ledger.turns["child"])
    }

    func testSubagentStillRunningAfterTimeoutNotifiesPendingThenBackfills() {
        var parent = Fixture(thread: threadA)
        parent.started("root", at: launch + 10)
        parent.call("root", input: 100, output: 10)
        var child = Fixture(thread: subThread, rootThread: threadA)
        child.started("child", root: "root", at: launch + 11)
        parent.completed("root", at: launch + 20)

        var ledger = CodexTurnLedger()
        let processedAt = launch + 20
        for event in parse(parent) + parse(child) { ledger.apply(event, now: processedAt, pricer: Self.fakePricer) }

        let late = processedAt + CodexTurnLedger.settleTimeout + 1
        let notices = ledger.settle(now: late, trackingStartedAt: launch)
        let pending = try! XCTUnwrap(notices.first)
        XCTAssertEqual(pending.status, .settling)
        XCTAssertFalse(pending.isExact)

        // 迟到的子代理用量只补记账本，不再弹第二次提示。
        child.call("child", root: "root", input: 1000, output: 100)
        child.completed("child", root: "root", at: launch + 60)
        for event in parse(child).suffix(3) { ledger.apply(event, now: late, pricer: Self.fakePricer) }
        XCTAssertTrue(ledger.settle(now: late + 1, trackingStartedAt: launch).isEmpty)
        let final = try! XCTUnwrap(ledger.turns["root"])
        XCTAssertEqual(final.status, .complete)
        XCTAssertTrue(final.revisedAfterNotice)
        XCTAssertEqual(final.usage.totalTokens, 1210)
    }

    func testInterruptedTurnKeepsKnownUsage() {
        var log = Fixture(thread: threadA)
        log.started("t1", at: launch + 10)
        log.call("t1", input: 100, output: 10)
        log.aborted("t1", at: launch + 12)

        var ledger = CodexTurnLedger()
        let turn = try! XCTUnwrap(apply(log, to: &ledger, now: launch + 13).first)
        XCTAssertEqual(turn.status, .interrupted)
        XCTAssertTrue(turn.measurementComplete)
        XCTAssertEqual(turn.usage.totalTokens, 110)
    }

    func testUnpricedModelIsFlaggedNotZero() {
        var log = Fixture(thread: threadA, model: "unpriced-model")
        log.started("t1", at: launch + 10)
        log.call("t1", input: 100, output: 10)
        log.completed("t1", at: launch + 11)

        var ledger = CodexTurnLedger()
        let turn = try! XCTUnwrap(apply(log, to: &ledger, now: launch + 12).first)
        XCTAssertTrue(turn.usage.hasUnpricedUsage)
        XCTAssertTrue(turn.measurementComplete, "计量完整与价格完整分开判断")
    }

    func testLogWithoutPerCallRecordsIsUnattributed() {
        var log = Fixture(thread: threadA)
        log.started("t1", at: launch + 10)
        log.tokenCountOnly(input: 100, output: 10)
        log.completed("t1", at: launch + 11)

        var ledger = CodexTurnLedger()
        let turn = try! XCTUnwrap(apply(log, to: &ledger, now: launch + 12).first)
        XCTAssertEqual(turn.status, .unattributed)
        XCTAssertFalse(turn.isExact)
    }

    func testMissingRecordDetectedByCumulativeTotals() {
        var log = Fixture(thread: threadA)
        log.started("t1", at: launch + 10)
        log.call("t1", input: 100, output: 10)
        log.call("t1", input: 200, output: 20)
        log.completed("t1", at: launch + 11)
        // 去掉第一条逐调用记录，模拟漏读：最后一条的 turn_token_usage 对不上。
        let index = log.lines.firstIndex { $0.contains("token_usage_record") }!
        log.lines.remove(at: index)

        var ledger = CodexTurnLedger()
        for event in parse(log) { ledger.apply(event, now: launch + 12, pricer: Self.fakePricer) }
        XCTAssertTrue(ledger.settle(now: launch + 12, trackingStartedAt: launch).isEmpty)
        let late = launch + 12 + CodexTurnLedger.settleTimeout + 1
        let turn = try! XCTUnwrap(ledger.settle(now: late, trackingStartedAt: launch).first)
        XCTAssertFalse(turn.isExact)
    }

    func testTurnsEndedBeforeLaunchAreNeverNotified() {
        var log = Fixture(thread: threadA)
        log.started("old", at: launch - 100)
        log.call("old", input: 100, output: 10)
        log.completed("old", at: launch - 90)

        var ledger = CodexTurnLedger()
        XCTAssertTrue(apply(log, to: &ledger, now: launch + 1).isEmpty)
        XCTAssertEqual(ledger.turns["old"]?.notificationState, .suppressed)
        XCTAssertEqual(ledger.turns["old"]?.usage.totalTokens, 110, "历史回合照常记账")
    }

    func testDuplicateRecordsAndReplayDoNotDoubleCount() {
        var log = Fixture(thread: threadA)
        log.started("t1", at: launch + 10)
        log.call("t1", input: 100, output: 10)
        log.completed("t1", at: launch + 11)

        var ledger = CodexTurnLedger()
        let events = parse(log)
        for event in events + events { ledger.apply(event, now: launch + 12, pricer: Self.fakePricer) }
        let notices = ledger.settle(now: launch + 12, trackingStartedAt: launch)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].usage.requestCount, 1)
        XCTAssertTrue(ledger.settle(now: launch + 13, trackingStartedAt: launch).isEmpty)
    }

    func testMissingResponseIDUsesDeterministicCompatKey() {
        var log = Fixture(thread: threadA, omitResponseID: true)
        log.started("t1", at: launch + 10)
        log.call("t1", input: 100, output: 10)
        log.call("t1", input: 100, output: 10)
        log.completed("t1", at: launch + 11)

        var ledger = CodexTurnLedger()
        let events = parse(log)
        for event in events + events { ledger.apply(event, now: launch + 12, pricer: Self.fakePricer) }
        let turn = try! XCTUnwrap(ledger.settle(now: launch + 12, trackingStartedAt: launch).first)
        // 两次调用数值相同，但累计值不同，兼容键不同；整段重放不重复计入。
        XCTAssertEqual(turn.usage.requestCount, 2)
        XCTAssertTrue(turn.isExact)
    }

    func testForkReplayRecordsWithForeignThreadAreIgnored() {
        var original = Fixture(thread: threadA)
        original.started("t1", at: launch + 10)
        original.call("t1", input: 100, output: 10)
        original.completed("t1", at: launch + 11)

        // fork 文件：首行是 fork 自己的 session_meta，随后父对话的行（含父对话 session_meta）原样重放，
        // 记录里的 thread_id 仍是父对话；最后才是 fork 自己的新回合。
        var fork = Fixture(thread: threadB)
        fork.lines = [fork.lines[0]] + original.lines
        fork.started("t2", at: launch + 20)
        fork.call("t2", input: 300, output: 30)
        fork.completed("t2", at: launch + 21)

        var ledger = CodexTurnLedger()
        for event in parse(original) + parse(fork) { ledger.apply(event, now: launch + 22, pricer: Self.fakePricer) }
        let notices = ledger.settle(now: launch + 22, trackingStartedAt: launch)

        XCTAssertEqual(notices.map(\.turnID), ["t1", "t2"])
        XCTAssertEqual(ledger.turns["t1"]?.threadID, threadA)
        XCTAssertEqual(ledger.turns["t1"]?.usage.requestCount, 1)
        XCTAssertEqual(ledger.turns["t2"]?.usage.totalTokens, 330)
    }

    func testTurnAcrossMidnightKeepsFullIncrement() {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: launch).addingTimeInterval(86_400)
        var log = Fixture(thread: threadA)
        log.started("t1", at: midnight - 30)
        log.call("t1", input: 100, output: 10, at: midnight - 20)
        log.call("t1", input: 200, output: 20, at: midnight + 20)
        log.completed("t1", at: midnight + 30)

        var ledger = CodexTurnLedger()
        let turn = try! XCTUnwrap(apply(log, to: &ledger, now: midnight + 31).first)
        XCTAssertEqual(turn.usage.totalTokens, 330)
    }

    func testPruneKeepsRunningAndRecentTurns() {
        var ledger = CodexTurnLedger()
        var old = Fixture(thread: threadA)
        old.started("old", at: launch - 5 * 86_400)
        old.completed("old", at: launch - 5 * 86_400 + 10)
        var running = Fixture(thread: threadB)
        running.started("run", at: launch - 60)
        for event in parse(old) + parse(running) { ledger.apply(event, now: launch, pricer: Self.fakePricer) }
        _ = ledger.settle(now: launch, trackingStartedAt: launch)
        ledger.prune(now: launch)
        XCTAssertNil(ledger.turns["old"])
        XCTAssertEqual(ledger.turns["run"]?.status, .running)
    }

    func testCandidateFilterSkipsResponseItemsByLinePrefix() {
        let item = #"{"timestamp":"2026-11-11T04:57:44.338Z","ordinal":9,"type":"response_item","payload":{"type":"message"}}"#
        let record = #"{"timestamp":"2026-11-11T04:57:44.338Z","ordinal":95,"type":"token_usage_record","payload":{}}"#
        XCTAssertFalse(CodexTurnLogParser.isCandidate(item))
        XCTAssertTrue(CodexTurnLogParser.isCandidate(record))
    }

    func testSegmentedFileNameUsesThreadFromSessionMeta() throws {
        // 分段日志：文件名是「线程 UUID_分段 UUID」，记录与 session_meta 都用线程 UUID。
        var log = Fixture(thread: threadA)
        log.started("t1", at: launch + 10)
        log.call("t1", input: 100, output: 10)
        log.completed("t1", at: launch + 11)
        let url = URL(fileURLWithPath: "/tmp/rollout-2026-11-10T16-07-27-\(threadA)_\(threadB).jsonl")
        var cursor = try XCTUnwrap(CodexTurnLogParser.initialCursor(for: url))
        XCTAssertEqual(CodexTurnLogParser.threadID(fromFileURL: url), threadB)
        var ledger = CodexTurnLedger()
        for event in CodexTurnLogParser.parse(lines: log.lines, cursor: &cursor) {
            ledger.apply(event, now: launch + 12, pricer: Self.fakePricer)
        }
        let turn = try XCTUnwrap(ledger.settle(now: launch + 12, trackingStartedAt: launch).first)
        XCTAssertEqual(turn.threadID, threadA)
        XCTAssertTrue(turn.isExact)
        XCTAssertEqual(turn.usage.requestCount, 1)
    }

    // MARK: - 引擎（真实文件、增量读取、重启）

    func testEngineReadsIncrementallyIgnoresPartialTailAndSurvivesRestart() async throws {
        let root = try makeTempRoot()
        let stateURL = root.deletingLastPathComponent().appendingPathComponent("state-\(UUID().uuidString).json")
        let fileURL = root.appendingPathComponent("2026/11/11/rollout-2026-11-11T12-57-40-\(threadA).jsonl")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var log = Fixture(thread: threadA)
        let start = Date()
        log.started("t1", at: start)
        log.call("t1", input: 100, output: 10)
        try write(log.lines, to: fileURL)

        let engine = CodexTurnEngine(sessionsRoot: root, stateURL: stateURL, pricer: Self.fakePricer, titleLookup: { [:] })
        var result = await engine.bootstrap(now: start)
        XCTAssertTrue(result.notices.isEmpty)

        // 尾行未写完：不推进 offset，也不提示。
        log.call("t1", input: 200, output: 20)
        log.completed("t1", at: Date())
        let full = log.lines.joined(separator: "\n") + "\n"
        let partial = String(full.dropLast(40))
        try partial.write(to: fileURL, atomically: false, encoding: .utf8)
        result = await engine.process(paths: [fileURL.path], now: Date())
        XCTAssertTrue(result.notices.isEmpty)

        try full.write(to: fileURL, atomically: false, encoding: .utf8)
        result = await engine.process(paths: [fileURL.path], now: Date())
        let turn = try XCTUnwrap(result.notices.first)
        XCTAssertTrue(turn.isExact)
        XCTAssertEqual(turn.usage.requestCount, 2)
        XCTAssertTrue(result.sawTurnEnd)
        await engine.save(now: Date())

        // 重启：载入账本，不重播已提示的回合；新回合照常提示。
        let restarted = CodexTurnEngine(sessionsRoot: root, stateURL: stateURL, pricer: Self.fakePricer, titleLookup: { [:] })
        result = await restarted.bootstrap(now: Date())
        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertEqual(result.recent.first?.turnID, "t1")

        log.started("t2", at: Date())
        log.call("t2", input: 50, output: 5)
        log.completed("t2", at: Date().addingTimeInterval(1))
        try write(log.lines, to: fileURL)
        result = await restarted.process(paths: [fileURL.path], now: Date())
        XCTAssertEqual(result.notices.map(\.turnID), ["t2"])
        let ledger = await restarted.ledgerForTesting()
        XCTAssertEqual(ledger.turns["t1"]?.usage.requestCount, 2, "重读不会重复计入")
    }

    /// 回合账本与 CCBar 现有 Codex 扫描对同一份日志逐条对账：调用数、token 分类与费用一致。
    func testLedgerMatchesCodexScannerOnSameLog() async throws {
        let root = try makeTempRoot()
        let fileURL = root.appendingPathComponent("2026/11/11/rollout-2026-11-11T12-57-40-\(threadA).jsonl")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var log = Fixture(thread: threadA, model: "gpt-5.5")
        log.started("t1", at: launch + 10)
        log.call("t1", input: 12_000, cached: 8_000, output: 300)
        log.echoTokenCount()
        log.call("t1", input: 20_000, cached: 15_000, output: 500)
        log.completed("t1", at: launch + 20)
        try write(log.lines, to: fileURL)

        let scan = await CodexJSONLScanner.scan(previous: [:], roots: [root], indexedTitles: [:])
        var ledger = CodexTurnLedger()
        for event in parse(log) { ledger.apply(event, now: launch + 21, pricer: CodexTurnLedger.productionPricer) }
        let turn = try XCTUnwrap(ledger.settle(now: launch + 21, trackingStartedAt: launch).first)

        XCTAssertTrue(turn.isExact)
        XCTAssertEqual(turn.usage.requestCount, scan.entries.count)
        XCTAssertEqual(turn.usage.inputTokens, scan.entries.reduce(0) { $0 + $1.inputTokens })
        XCTAssertEqual(turn.usage.outputTokens, scan.entries.reduce(0) { $0 + $1.outputTokens })
        XCTAssertEqual(turn.usage.cacheReadTokens, scan.entries.reduce(0) { $0 + $1.cacheReadTokens })
        XCTAssertEqual(turn.usage.costUSD, scan.entries.reduce(Decimal(0)) { $0 + ($1.costUSD ?? 0) })
        XCTAssertGreaterThan(turn.usage.costUSD, 0)
    }

    // MARK: - Claude Code

    func testClaudeTurnSumsCallsAndEndsOnFinalText() throws {
        var log = ClaudeFixture(session: threadA)
        log.prompt("p1", at: launch + 10)
        // 第一次调用：thinking + tool_use 两个内容块，每行都带同一个 message.id 与最终用量。
        log.assistant("msg_1", blocks: ["thinking", "tool_use"], stop: "tool_use",
                      input: 10, output: 200, cacheRead: 5_000, cacheWrite: 1_000)
        log.toolResult(promptID: "p1")
        // 最终回答：thinking 行还不算结束，文本块写入后才结束。
        log.assistant("msg_2", blocks: ["thinking"], stop: "end_turn",
                      input: 5, output: 300, cacheRead: 6_000, cacheWrite: 0)
        var ledger = CodexTurnLedger()
        var cursor = CodexTurnFileCursor()
        for event in ClaudeTurnLogParser.parse(lines: log.lines, cursor: &cursor) {
            ledger.apply(event, now: launch + 30, pricer: Self.fakePricer, app: .claude)
        }
        XCTAssertEqual(ledger.turns["p1"]?.status, .running, "最后一块是 thinking，回答还没写完")

        log.assistant("msg_2", blocks: ["text"], stop: "end_turn",
                      input: 5, output: 300, cacheRead: 6_000, cacheWrite: 0)
        for event in ClaudeTurnLogParser.parse(lines: log.lines.suffix(1), cursor: &cursor) {
            ledger.apply(event, now: launch + 31, pricer: Self.fakePricer, app: .claude)
        }
        let turn = try XCTUnwrap(ledger.settle(now: launch + 31, trackingStartedAt: launch).first)
        XCTAssertEqual(turn.app, .claude)
        XCTAssertEqual(turn.threadID, threadA)
        XCTAssertEqual(turn.conversationKey, "claude:\(threadA)")
        XCTAssertTrue(turn.isExact)
        XCTAssertEqual(turn.usage.requestCount, 2, "同一 message.id 的多行只计一次")
        XCTAssertEqual(turn.usage.inputTokens, 15)
        XCTAssertEqual(turn.usage.outputTokens, 500)
        XCTAssertEqual(turn.usage.cacheReadTokens, 11_000)
        XCTAssertEqual(turn.usage.cacheCreationTokens, 1_000)
        XCTAssertEqual(cursor.fallbackTitle, "Prompt p1")
    }

    func testClaudeInterruptionAndSupersededTurns() throws {
        var log = ClaudeFixture(session: threadA)
        log.prompt("p1", at: launch + 10)
        log.assistant("msg_1", blocks: ["tool_use"], stop: "tool_use", input: 10, output: 20, cacheRead: 0, cacheWrite: 0)
        log.interrupt(promptID: "p1")
        log.prompt("p2", at: launch + 20)
        log.assistant("msg_2", blocks: ["tool_use"], stop: "tool_use", input: 10, output: 20, cacheRead: 0, cacheWrite: 0)
        // 没有最终回答就开始了下一回合：上一回合按结束处理。
        log.prompt("p3", at: launch + 30)
        log.assistant("msg_3", blocks: ["text"], stop: "end_turn", input: 1, output: 2, cacheRead: 0, cacheWrite: 0)

        var ledger = CodexTurnLedger()
        var cursor = CodexTurnFileCursor()
        for event in ClaudeTurnLogParser.parse(lines: log.lines, cursor: &cursor) {
            ledger.apply(event, now: launch + 40, pricer: Self.fakePricer, app: .claude)
        }
        let notices = ledger.settle(now: launch + 40, trackingStartedAt: launch)
        XCTAssertEqual(notices.map(\.turnID), ["p1", "p2", "p3"])
        XCTAssertEqual(notices[0].status, .interrupted)
        XCTAssertEqual(notices[0].usage.totalTokens, 30)
        XCTAssertEqual(notices[1].status, .complete)
        XCTAssertEqual(notices[2].usage.totalTokens, 3)
    }

    /// 与 CCBar 现有 Claude 扫描对同一份日志对账：调用数、各类 token 与费用一致。
    func testClaudeLedgerMatchesClaudeScanner() async throws {
        let root = try makeTempRoot()
        let fileURL = root.appendingPathComponent("-Users-test-project/\(threadB).jsonl")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var log = ClaudeFixture(session: threadB, model: "claude-fable-5-2")
        log.prompt("p1", at: launch + 10)
        log.assistant("msg_1", blocks: ["thinking", "tool_use"], stop: "tool_use",
                      input: 12, output: 400, cacheRead: 30_000, cacheWrite: 2_000)
        log.toolResult(promptID: "p1")
        log.assistant("msg_2", blocks: ["text"], stop: "end_turn",
                      input: 3, output: 250, cacheRead: 32_000, cacheWrite: 500)
        try write(log.lines, to: fileURL)

        let scan = ClaudeJSONLScanner.scan(
            previous: [:], seenMessageIds: [], root: root,
            conversationIndex: ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
        )
        let engine = CodexTurnEngine(
            sessionsRoot: root.appendingPathComponent("codex-none"), claudeRoot: root,
            stateURL: nil, titleLookup: { [:] }
        )
        _ = await engine.bootstrap(now: launch)
        let ledger = await engine.ledgerForTesting()
        let turn = try XCTUnwrap(ledger.turns["p1"])

        XCTAssertTrue(turn.isExact)
        XCTAssertEqual(turn.usage.requestCount, scan.entries.reduce(0) { $0 + $1.requestCount })
        XCTAssertEqual(turn.usage.inputTokens, scan.entries.reduce(0) { $0 + $1.inputTokens })
        XCTAssertEqual(turn.usage.outputTokens, scan.entries.reduce(0) { $0 + $1.outputTokens })
        XCTAssertEqual(turn.usage.cacheReadTokens, scan.entries.reduce(0) { $0 + $1.cacheReadTokens })
        XCTAssertEqual(turn.usage.cacheCreationTokens, scan.entries.reduce(0) { $0 + $1.cacheCreationTokens })
        XCTAssertEqual(turn.usage.costUSD, scan.entries.reduce(Decimal(0)) { $0 + ($1.costUSD ?? 0) })
        XCTAssertGreaterThan(turn.usage.costUSD, 0)
    }

    func testClaudeCandidateFilterSkipsMetadataLines() {
        XCTAssertFalse(ClaudeTurnLogParser.isCandidate(#"{"type":"api-request","id":"x"}"#))
        XCTAssertFalse(ClaudeTurnLogParser.isCandidate(#"{"type":"queue-operation","operation":"enqueue"}"#))
        XCTAssertTrue(ClaudeTurnLogParser.isCandidate(#"{"parentUuid":null,"isSidechain":false,"type":"user"}"#))
        XCTAssertTrue(ClaudeTurnLogParser.isCandidate(#"{"type":"assistant","message":{}}"#))
    }

    // MARK: - Helpers

    private func apply(_ log: Fixture, to ledger: inout CodexTurnLedger, now: Date) -> [CodexTurnRecord] {
        for event in parse(log) { ledger.apply(event, now: now, pricer: Self.fakePricer) }
        return ledger.settle(now: now, trackingStartedAt: launch)
    }

    private func parse(_ log: Fixture) -> [CodexTurnEvent] {
        var cursor = CodexTurnLogParser.initialCursor(
            for: URL(fileURLWithPath: "/tmp/rollout-2026-11-11T12-57-40-\(log.thread).jsonl")
        )!
        return CodexTurnLogParser.parse(lines: log.lines, cursor: &cursor)
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbar-turn-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
    }
}

/// 按真实 Codex 日志结构生成脱敏 JSONL。
private struct Fixture {
    let thread: String
    var rootThread: String?
    var model = "gpt-5.5"
    var omitResponseID = false
    var lines: [String] = []
    private var turnTotals: [String: CodexRawTokenCounts] = [:]
    private var threadTotal = CodexRawTokenCounts()
    private var responseSeq = 0
    private var clock = Date(timeIntervalSince1970: 1_794_370_000)

    init(thread: String, rootThread: String? = nil, model: String = "gpt-5.5", omitResponseID: Bool = false) {
        self.thread = thread
        self.rootThread = rootThread
        self.model = model
        self.omitResponseID = omitResponseID
        var meta: [String: Any] = ["id": thread, "cwd": "/tmp/project", "cli_version": "0.167.0"]
        if let rootThread {
            meta["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": rootThread, "depth": 1]]]
        }
        add(["type": "session_meta", "payload": meta])
        add(["type": "event_msg", "payload": [
            "type": "thread_settings_applied", "thread_id": thread,
            "thread_settings": ["model": model, "service_tier": "default"]
        ]])
    }

    mutating func started(_ turn: String, root: String? = nil, at date: Date) {
        clock = date
        let rootTurn = root ?? turn
        add(["type": "event_msg", "payload": [
            "type": "task_started", "turn_id": turn, "root_turn_id": rootTurn,
            "started_at": Int(date.timeIntervalSince1970),
            "turn_attribution": ["turn_id": turn, "root_turn_id": rootTurn]
        ]])
        add(["type": "turn_context", "payload": ["turn_id": turn, "root_turn_id": rootTurn, "model": model]])
    }

    mutating func call(_ turn: String, root: String? = nil, input: Int, cached: Int = 0, write: Int = 0,
                       output: Int, at date: Date? = nil) {
        if let date { clock = date } else { clock = clock.addingTimeInterval(1) }
        responseSeq += 1
        let usage = CodexRawTokenCounts(input: input, cachedInput: cached, cacheWrite: write, output: output)
        turnTotals[turn, default: CodexRawTokenCounts()].add(usage)
        threadTotal.add(usage)
        var payload: [String: Any] = [
            "thread_id": thread, "turn_id": turn, "root_turn_id": root ?? turn,
            "session_id": rootThread ?? thread,
            "usage": json(usage), "turn_token_usage": json(turnTotals[turn]!), "thread_token_usage": json(threadTotal)
        ]
        if !omitResponseID { payload["response_id"] = "resp_\(thread.suffix(4))_\(responseSeq)" }
        add(["type": "token_usage_record", "payload": payload])
        tokenCount(last: usage)
    }

    /// 旧版本 Codex：只有 token_count，没有逐调用记录。
    mutating func tokenCountOnly(input: Int, output: Int) {
        let usage = CodexRawTokenCounts(input: input, output: output)
        threadTotal.add(usage)
        tokenCount(last: usage)
    }

    /// 切换设置时 Codex 会原样回显上一条 token_count，CCBar 与账本都不能把它当成新调用。
    mutating func echoTokenCount() {
        guard let last = lines.last(where: { $0.contains("\"token_count\"") }) else { return }
        lines.append(last)
    }

    mutating func completed(_ turn: String, root: String? = nil, at date: Date) {
        clock = date
        add(["type": "event_msg", "payload": [
            "type": "task_complete", "turn_id": turn, "root_turn_id": root ?? turn,
            "completed_at": Int(date.timeIntervalSince1970), "duration_ms": 1000
        ]])
    }

    mutating func aborted(_ turn: String, at date: Date) {
        clock = date
        add(["type": "event_msg", "payload": [
            "type": "turn_aborted", "turn_id": turn, "root_turn_id": turn, "reason": "interrupted",
            "completed_at": Int(date.timeIntervalSince1970)
        ]])
    }

    private mutating func tokenCount(last usage: CodexRawTokenCounts) {
        add(["type": "event_msg", "payload": [
            "type": "token_count",
            "info": ["last_token_usage": json(usage), "total_token_usage": json(threadTotal)]
        ]])
    }

    private func json(_ counts: CodexRawTokenCounts) -> [String: Any] {
        [
            "input_tokens": counts.input,
            "cached_input_tokens": counts.cachedInput,
            "cache_write_input_tokens": counts.cacheWrite,
            "output_tokens": counts.output,
            "reasoning_output_tokens": 0,
            "total_tokens": counts.input + counts.output
        ]
    }

    private mutating func add(_ object: [String: Any]) {
        var root = object
        root["timestamp"] = ISO8601DateFormatter.fractional.string(from: clock)
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        lines.append(String(decoding: data, as: UTF8.self))
    }
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// 按真实 Claude Code 日志结构生成脱敏 JSONL（字段与本机 Claude Code 桌面版一致，内容为占位）。
private struct ClaudeFixture {
    let session: String
    var model = "claude-fable-5-2"
    var lines: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_794_370_000)

    init(session: String, model: String = "claude-fable-5-2") {
        self.session = session
        self.model = model
    }

    mutating func prompt(_ promptID: String, at date: Date) {
        clock = date
        add([
            "type": "user", "isSidechain": false, "promptId": promptID,
            "turnOrigin": "human", "turnPosition": ["promptIndex": 1, "turnIndex": 1],
            "message": ["role": "user", "content": "Prompt \(promptID)"]
        ])
    }

    mutating func toolResult(promptID: String) {
        add([
            "type": "user", "isSidechain": false, "promptId": promptID,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "ok"]]]
        ])
    }

    mutating func interrupt(promptID: String) {
        add([
            "type": "user", "isSidechain": false, "promptId": promptID,
            "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]
        ])
    }

    /// 每个内容块一行；各行带同一 message.id 与最终用量。
    mutating func assistant(_ id: String, blocks: [String], stop: String,
                            input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
        for block in blocks {
            add([
                "type": "assistant", "isSidechain": false, "requestId": "req_\(id)",
                "message": [
                    "id": id, "model": model, "role": "assistant", "stop_reason": stop,
                    "content": [["type": block]],
                    "usage": [
                        "input_tokens": input, "output_tokens": output,
                        "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite,
                        "cache_creation": ["ephemeral_5m_input_tokens": cacheWrite, "ephemeral_1h_input_tokens": 0],
                        "speed": "standard"
                    ]
                ]
            ])
        }
    }

    private mutating func add(_ object: [String: Any]) {
        clock = clock.addingTimeInterval(1)
        var root = object
        root["sessionId"] = session
        root["uuid"] = UUID().uuidString
        root["timestamp"] = ISO8601DateFormatter.fractional.string(from: clock)
        root["cwd"] = "/tmp/project"
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        lines.append(String(decoding: data, as: UTF8.self))
    }
}
