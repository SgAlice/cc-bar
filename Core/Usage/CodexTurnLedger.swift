import Foundation

// MARK: - 回合账本
//
// 顶部用量胶囊的「本轮增量」只来自这里，不读 `usage-history` 快照，也不拿两次扫描的差值。
// 数据源是 Codex 本机日志里的逐调用记录 `token_usage_record`：每条带 `response_id`、
// `thread_id`、`turn_id`、`root_turn_id`、`session_id`（根对话），以及该线程本回合的累计
// `turn_token_usage`。生命周期取 `event_msg` 的 `task_started` / `task_complete`
// （兼容 `turn_complete`）/ `turn_aborted`，三者都带 `turn_id`。
//
// 归属规则（与执行文档 §4.2 对应）：
// - 主键是根回合 `(threadID, turnID)`；子代理调用按 `root_turn_id` + `session_id` 并入根回合，
//   各线程分段（`thread#turn`）单独核对，避免父子重复计费。
// - 去重键是 `response_id`；缺失时用确定性兼容键（线程、回合、本回合累计签名、时间戳）。
// - 结束事件只表示「不会再有新调用」，账本还要核对每个分段：调用条数不少于非重复 `token_count`，
//   且记录合计等于最后一条 `turn_token_usage`；子代理分段都已结束。全部满足才算计量完整。
// - 日志没有逐调用记录（旧版本 Codex）时标为无法精确归属，不用时间猜测填数。

/// 一个回合（或其中一个线程分段）已计入的用量。token 口径与 `UsageEntry` 一致：
/// `inputTokens` 已扣除缓存读写，总量 = 输入 + 输出 + 缓存读取 + 缓存写入。
nonisolated struct CodexTurnUsage: Codable, Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var costUSD: Decimal = 0
    var requestCount = 0
    /// 有调用找不到价格；`costUSD` 只是已知部分，界面必须标「费用不完整」。
    var hasUnpricedUsage = false

    static let zero = CodexTurnUsage()

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    mutating func add(_ other: CodexTurnUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
        costUSD += other.costUSD
        requestCount += other.requestCount
        hasUnpricedUsage = hasUnpricedUsage || other.hasUnpricedUsage
    }
}

/// Codex 日志里的原始计数：`input_tokens` 含缓存读取与缓存写入。只用于和 `turn_token_usage` 对账。
nonisolated struct CodexRawTokenCounts: Codable, Equatable, Sendable {
    var input = 0
    var cachedInput = 0
    var cacheWrite = 0
    var output = 0

    init(input: Int = 0, cachedInput: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
    }

    /// 字段名同 `CodexJSONLScanner`：缓存写入两种写法都认，缺失按 0。
    init(json: [String: Any]) {
        input = (json["input_tokens"] as? Int) ?? 0
        cachedInput = (json["cached_input_tokens"] as? Int) ?? 0
        cacheWrite = (json["cache_write_input_tokens"] as? Int) ?? (json["cache_write_tokens"] as? Int) ?? 0
        output = (json["output_tokens"] as? Int) ?? 0
    }

    var isZero: Bool { input == 0 && cachedInput == 0 && cacheWrite == 0 && output == 0 }

    /// 转成 CCBar 统计口径（输入扣掉缓存读写），与 `CodexJSONLScanner` 的换算一致。
    var billableInput: Int { max(0, input - cachedInput - cacheWrite) }

    mutating func add(_ other: CodexRawTokenCounts) {
        input += other.input
        cachedInput += other.cachedInput
        cacheWrite += other.cacheWrite
        output += other.output
    }

    var signature: String { "\(input):\(cachedInput):\(cacheWrite):\(output)" }
}

nonisolated enum CodexTurnStatus: String, Codable, Sendable {
    /// 已开始，还没有结束事件。
    case running
    /// 结束事件已到，仍在等子代理结束或用量对账。
    case settling
    case complete
    /// 被中断或失败；已知用量照常保留。
    case interrupted
    /// 日志里有调用但没有逐调用归属记录，无法精确到本轮。
    case unattributed
}

nonisolated enum CodexTurnNotificationState: String, Codable, Sendable {
    /// 还没决定是否提示。
    case pending
    /// 已弹出过完成提示；之后的补记、重新计价都只改账本。
    case shown
    /// 历史回合（本次启动前已结束、fork 重放等），永不提示。
    case suppressed
}

/// 一个线程在某回合里的分段：根回合自己的线程是一段，每个子代理线程各是一段。
nonisolated struct CodexTurnSegment: Codable, Equatable, Sendable {
    var threadID: String
    var turnID: String
    var isRoot: Bool
    var usage = CodexTurnUsage.zero
    /// 已计入记录的原始合计。
    var raw = CodexRawTokenCounts()
    /// 最近一条记录携带的本回合累计（`turn_token_usage`）；旧日志没有时为 nil。
    var reported: CodexRawTokenCounts?
    var recordCount = 0
    /// 本段内非重复、非零的 `token_count`（按累计签名记键），即 CCBar 统计实际计入的调用。
    /// 记键而不是计数：文件被截断后从头重读时不会重复累加。
    var legacyUsageKeys: [String] = []
    var legacyUsageEventCount: Int { legacyUsageKeys.count }
    var ended = false

    static func key(threadID: String, turnID: String) -> String { "\(threadID)#\(turnID)" }

    /// 记录条数与累计值都能对上，说明本段没有漏读或多算。
    var isConsistent: Bool {
        guard legacyUsageEventCount <= recordCount else { return false }
        if let reported { return reported == raw }
        return true
    }
}

/// 一个根回合的账本记录。
nonisolated struct CodexTurnRecord: Codable, Equatable, Sendable, Identifiable {
    var threadID: String
    var turnID: String
    var startedAt: Date?
    var completedAt: Date?
    var status: CodexTurnStatus = .running
    var interrupted = false
    var usage = CodexTurnUsage.zero
    /// 账本最近一次计价时的价格指纹（同 `Pricing.fingerprint`）。
    var pricingFingerprint: String?
    /// 计量完整：所有分段已结束且对账一致。与价格是否齐全（`usage.hasUnpricedUsage`）分开判断。
    var measurementComplete = false
    var segments: [String: CodexTurnSegment] = [:]
    /// 已计入的调用去重键（`response_id` 或兼容键）。
    var eventIDs: [String] = []
    var notificationState: CodexTurnNotificationState = .pending
    /// 提示弹出后又补记了用量（子代理迟到等）。
    var revisedAfterNotice = false
    /// 结束事件到达时刻（本机时钟），用于等待超时；日志里的 `completed_at` 只有秒级且可能被重放。
    var settlingSince: Date?
    var title: String?

    var id: String { CodexTurnSegment.key(threadID: threadID, turnID: turnID) }

    var hasSubagents: Bool { segments.values.contains { !$0.isRoot } }

    var isEnded: Bool { status != .running }

    /// 只有归属与计量都完整时才能称为「本轮用量」。
    var isExact: Bool {
        measurementComplete && (status == .complete || status == .interrupted)
    }
}

// MARK: - 事件

nonisolated struct CodexUsageRecordEvent: Equatable, Sendable {
    var responseID: String?
    var threadID: String
    var turnID: String
    var rootTurnID: String
    /// 根回合所在线程（`session_id`）；缺失时同 `threadID`。
    var rootThreadID: String
    var raw: CodexRawTokenCounts
    var reportedTurnTotals: CodexRawTokenCounts?
    var model: String
    var speed: UsageSpeed
    var timestamp: Date

    /// `response_id` 缺失时的确定性兼容键：同一线程同一回合内累计值单调递增，重放同一行得到同一个键。
    var dedupeKey: String {
        if let responseID, !responseID.isEmpty { return responseID }
        let cumulative = reportedTurnTotals?.signature ?? raw.signature
        let ms = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
        return "compat:\(threadID)#\(turnID)#\(cumulative)@\(ms)"
    }
}

nonisolated enum CodexTurnEvent: Equatable, Sendable {
    case started(threadID: String, turnID: String, rootTurnID: String, at: Date)
    case ended(threadID: String, turnID: String, rootTurnID: String, at: Date, interrupted: Bool)
    case usage(CodexUsageRecordEvent)
    /// 一次被 CCBar 统计计入的 `token_count`（已按累计签名去重），用于核对是否漏了逐调用记录。
    /// `key` 是该条的累计用量签名（缺失时用时间戳兜底）。
    case legacyUsage(threadID: String, turnID: String, rootTurnID: String, key: String)
}

// MARK: - 账本

/// 计价函数：输入原始计数、模型、速度档与时间，返回费用拆分；找不到价格时返回 nil。
/// 生产环境走 `Pricing.costBreakdown`，与统计页同一价格目录与 Fast 倍率。
typealias CodexTurnPricer = @Sendable (
    _ model: String, _ speed: UsageSpeed, _ raw: CodexRawTokenCounts, _ at: Date
) -> CostBreakdown?

nonisolated struct CodexTurnLedger: Codable, Equatable, Sendable {
    /// 以根回合 `turn_id` 为索引（UUIDv7，全局唯一）；记录里同时保存线程，构成主键。
    var turns: [String: CodexTurnRecord] = [:]

    /// 结束后等待子代理与对账的最长时间；超时后先提示「待汇总」，账本继续补记。
    static let settleTimeout: TimeInterval = 20
    /// 账本保留时长与条数上限。
    static let retention: TimeInterval = 3 * 86_400
    static let maxTurns = 400

    static let productionPricer: CodexTurnPricer = { model, speed, raw, date in
        Pricing.costBreakdown(
            app: .codex,
            model: model,
            speed: speed,
            input: raw.billableInput,
            output: raw.output,
            cacheRead: raw.cachedInput,
            cacheCreation: raw.cacheWrite,
            at: date,
            inputTotal: raw.input
        )
    }

    /// 应用一条事件。`now` 是本机处理时刻，只用于等待超时。
    mutating func apply(_ event: CodexTurnEvent, now: Date, pricer: CodexTurnPricer) {
        switch event {
        case let .started(threadID, turnID, rootTurnID, at):
            if turnID == rootTurnID {
                guard var turn = rootTurn(turnID, threadID: threadID, createIfMissing: true) else { return }
                if turn.startedAt == nil { turn.startedAt = at }
                turn.segments[CodexTurnSegment.key(threadID: threadID, turnID: turnID), default:
                    CodexTurnSegment(threadID: threadID, turnID: turnID, isRoot: true)].isRoot = true
                turns[turnID] = turn
            } else {
                // 子代理回合：根回合不在账本里（启动前的历史）就不追踪。
                guard var turn = turns[rootTurnID] else { return }
                let key = CodexTurnSegment.key(threadID: threadID, turnID: turnID)
                if turn.segments[key] == nil {
                    turn.segments[key] = CodexTurnSegment(threadID: threadID, turnID: turnID, isRoot: false)
                }
                turns[rootTurnID] = turn
            }

        case let .ended(threadID, turnID, rootTurnID, at, interrupted):
            if turnID == rootTurnID {
                guard var turn = rootTurn(turnID, threadID: threadID, createIfMissing: true) else { return }
                let key = CodexTurnSegment.key(threadID: threadID, turnID: turnID)
                turn.segments[key, default: CodexTurnSegment(threadID: threadID, turnID: turnID, isRoot: true)].ended = true
                if turn.status == .running {
                    turn.completedAt = at
                    turn.interrupted = interrupted
                    turn.status = .settling
                    turn.settlingSince = now
                }
                turns[turnID] = turn
            } else {
                guard var turn = turns[rootTurnID] else { return }
                let key = CodexTurnSegment.key(threadID: threadID, turnID: turnID)
                turn.segments[key, default: CodexTurnSegment(threadID: threadID, turnID: turnID, isRoot: false)].ended = true
                turns[rootTurnID] = turn
            }

        case let .usage(record):
            guard var turn = rootTurn(record.rootTurnID, threadID: record.rootThreadID, createIfMissing: true) else { return }
            let dedupeKey = record.dedupeKey
            guard !turn.eventIDs.contains(dedupeKey) else { return }
            turn.eventIDs.append(dedupeKey)

            var usage = CodexTurnUsage(
                inputTokens: record.raw.billableInput,
                outputTokens: record.raw.output,
                cacheReadTokens: record.raw.cachedInput,
                cacheCreationTokens: record.raw.cacheWrite,
                requestCount: 1
            )
            if let cost = pricer(record.model, record.speed, record.raw, record.timestamp) {
                usage.costUSD = cost.total
            } else {
                usage.hasUnpricedUsage = true
            }

            let isRoot = record.threadID == record.rootThreadID && record.turnID == record.rootTurnID
            let key = CodexTurnSegment.key(threadID: record.threadID, turnID: record.turnID)
            var segment = turn.segments[key] ?? CodexTurnSegment(
                threadID: record.threadID, turnID: record.turnID, isRoot: isRoot
            )
            segment.usage.add(usage)
            segment.raw.add(record.raw)
            segment.recordCount += 1
            if let reported = record.reportedTurnTotals { segment.reported = reported }
            turn.segments[key] = segment
            turn.usage.add(usage)
            if turn.notificationState == .shown { turn.revisedAfterNotice = true }
            turns[record.rootTurnID] = turn

        case let .legacyUsage(threadID, turnID, rootTurnID, usageKey):
            guard var turn = turns[rootTurnID] else { return }
            let isRoot = turnID == rootTurnID
            let key = CodexTurnSegment.key(threadID: threadID, turnID: turnID)
            var segment = turn.segments[key] ?? CodexTurnSegment(threadID: threadID, turnID: turnID, isRoot: isRoot)
            guard !segment.legacyUsageKeys.contains(usageKey) else { return }
            segment.legacyUsageKeys.append(usageKey)
            turn.segments[key] = segment
            turns[rootTurnID] = turn
        }
    }

    /// 取根回合；同一 `turn_id` 已属于别的线程时（fork 重放）返回 nil，不串账。
    private mutating func rootTurn(_ turnID: String, threadID: String, createIfMissing: Bool) -> CodexTurnRecord? {
        if let existing = turns[turnID] {
            return existing.threadID == threadID ? existing : nil
        }
        guard createIfMissing else { return nil }
        return CodexTurnRecord(threadID: threadID, turnID: turnID)
    }

    /// 结算等待中的回合，返回本次需要弹出提示的回合（按结束顺序）。
    /// - Parameters:
    ///   - trackingStartedAt: 本次启动开始追踪的时刻；更早结束的回合只记账、不提示（含 fork 重放的旧回合）。
    ///   - notificationsEnabled: 关闭提示时同样结算，只是把待提示的回合标为不提示。
    mutating func settle(
        now: Date,
        trackingStartedAt: Date,
        notificationsEnabled: Bool = true,
        pricingFingerprint: String? = nil
    ) -> [CodexTurnRecord] {
        var notices: [CodexTurnRecord] = []
        for key in turns.keys {
            guard var turn = turns[key], turn.status != .running else { continue }
            if let pricingFingerprint { turn.pricingFingerprint = pricingFingerprint }

            let segments = Array(turn.segments.values)
            let allEnded = segments.allSatisfy(\.ended)
            let consistent = segments.allSatisfy(\.isConsistent)
            let missingAttribution = segments.contains { $0.recordCount == 0 && $0.legacyUsageEventCount > 0 }

            if missingAttribution {
                turn.status = .unattributed
                turn.measurementComplete = false
            } else if allEnded && consistent {
                turn.status = turn.interrupted ? .interrupted : .complete
                turn.measurementComplete = true
            } else {
                turn.status = .settling
                turn.measurementComplete = false
            }

            if turn.notificationState == .pending {
                let timedOut = turn.settlingSince.map { now.timeIntervalSince($0) >= Self.settleTimeout } ?? true
                let decided = turn.status != .settling || timedOut
                if decided {
                    // 日志里的 completed_at 是整秒，留 2 秒容差。
                    let endedAfterLaunch = (turn.completedAt ?? .distantPast) >= trackingStartedAt.addingTimeInterval(-2)
                    if endedAfterLaunch && turn.startedAt != nil && notificationsEnabled {
                        turn.notificationState = .shown
                        notices.append(turn)
                    } else {
                        turn.notificationState = .suppressed
                    }
                }
            }
            turns[key] = turn
        }
        return notices.sorted { ($0.completedAt ?? .distantPast, $0.turnID) < ($1.completedAt ?? .distantPast, $1.turnID) }
    }

    /// 是否还有等待结算的回合（决定是否需要定时再结算一次）。
    var hasSettlingTurns: Bool {
        turns.values.contains { $0.status == .settling }
    }

    /// 清理过期记录：保留仍在进行的回合，其余按结束时间只留最近 `maxTurns` 条、`retention` 以内。
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        turns = turns.filter { _, turn in
            if turn.status == .running {
                // 长时间没有结束事件的回合（Codex 崩溃等）也不能永远留着。
                return (turn.startedAt ?? now) >= cutoff
            }
            return (turn.completedAt ?? turn.startedAt ?? now) >= cutoff
        }
        guard turns.count > Self.maxTurns else { return }
        let ordered = turns.values.sorted {
            ($0.completedAt ?? $0.startedAt ?? .distantFuture) > ($1.completedAt ?? $1.startedAt ?? .distantFuture)
        }
        turns = Dictionary(uniqueKeysWithValues: ordered.prefix(Self.maxTurns).map { ($0.turnID, $0) })
    }

    /// 最近结束的回合，供展开面板显示。
    func recentEndedTurns(limit: Int) -> [CodexTurnRecord] {
        turns.values
            .filter { $0.isEnded && $0.notificationState == .shown }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - 日志解析

/// 单个 Codex 日志文件的读取进度与解析上下文。按字节 offset 增量续读，残行不推进。
nonisolated struct CodexTurnFileCursor: Codable, Equatable, Sendable {
    var offset: UInt64 = 0
    var mtime: TimeInterval = 0
    /// 本文件自己的线程 ID：文件名里的全部 UUID、首条 `session_meta.id`，
    /// 分页历史分段再加上 `history_base.thread_id`。
    var ownThreadIDs: [String] = []
    /// 生命周期事件归属的线程：首条 `session_meta.id`（分页分段即原对话）；还没读到时取文件名里的第一个 UUID。
    var canonicalThreadID: String?
    /// 已读过本文件首条 `session_meta`。fork 文件后面重放的父对话 session_meta 不能改写归属。
    var sawOwnMeta = false
    var model: String?
    var speed: UsageSpeed = .standard
    var lastTotalUsageSignature: String?
    /// 本文件当前进行中的回合，供 `token_count` 归属。
    var currentTurnID: String?
    var currentRootTurnID: String?
}

nonisolated enum CodexTurnLogParser {
    /// 只解析可能相关的行。`response_item` 占日志大头且体积大，按行首类型直接跳过。
    static func isCandidate(_ line: String) -> Bool {
        let head = line.prefix(120)
        if head.contains("\"type\":\"response_item\"") { return false }
        if head.contains("\"type\":\"world_state\"") { return false }
        return true
    }

    /// 文件名末尾的会话 UUID（同 `CodexJSONLScanner.conversationID(from:)`），用于排序与游标。
    static func threadID(fromFileURL url: URL) -> String? {
        threadIDs(fromFileURL: url).last
    }

    /// 文件名里的全部 UUID。分段日志命名为 `rollout-<时间>-<线程 UUID>_<分段 UUID>.jsonl`，
    /// 逐调用记录的 `thread_id` 是前一个。
    static func threadIDs(fromFileURL url: URL) -> [String] {
        let plainURL = JSONLDirectoryEnumerator.isZstd(url) ? url.deletingPathExtension() : url
        let name = plainURL.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(name.startIndex..., in: name)
        return regex.matches(in: name, range: range).compactMap { Range($0.range, in: name).map { String(name[$0]) } }
    }

    /// 新文件的初始游标。
    static func initialCursor(for url: URL) -> CodexTurnFileCursor? {
        let ids = threadIDs(fromFileURL: url)
        guard let first = ids.first else { return nil }
        return CodexTurnFileCursor(ownThreadIDs: ids, canonicalThreadID: first)
    }

    /// 解析一批完整行，更新游标并返回事件。
    static func parse(lines: some Sequence<String>, cursor: inout CodexTurnFileCursor) -> [CodexTurnEvent] {
        var events: [CodexTurnEvent] = []
        for line in lines where isCandidate(line) {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            parse(root: root, cursor: &cursor, into: &events)
        }
        return events
    }

    private static func parse(root: [String: Any], cursor: inout CodexTurnFileCursor, into events: inout [CodexTurnEvent]) {
        let type = root["type"] as? String
        let payload = root["payload"] as? [String: Any]

        switch type {
        case "session_meta":
            guard let payload, !cursor.sawOwnMeta else { return }
            // 首条 session_meta 是本文件自己的（分页分段则指回原对话）；fork 后面重放的父对话 meta 不算。
            cursor.sawOwnMeta = true
            if let metaID = nonEmpty((payload["id"] as? String) ?? (payload["session_id"] as? String)) {
                if !cursor.ownThreadIDs.contains(metaID) { cursor.ownThreadIDs.append(metaID) }
                cursor.canonicalThreadID = metaID
            }
            return
        case "turn_context":
            if let model = payload?["model"] as? String { cursor.model = model }
            return
        case "token_usage_record":
            guard let payload else { return }
            parseUsageRecord(payload, root: root, cursor: cursor, into: &events)
            return
        case "event_msg":
            break
        default:
            return
        }

        if let settings = CodexJSONLScanner.threadSettings(from: root) {
            if let model = settings.model { cursor.model = model }
            cursor.speed = settings.speed
            return
        }
        guard let payload, let kind = payload["type"] as? String,
              let thread = cursor.canonicalThreadID ?? cursor.ownThreadIDs.first else { return }

        switch kind {
        case "task_started", "turn_started":
            guard let turnID = nonEmpty(payload["turn_id"] as? String) else { return }
            let attribution = payload["turn_attribution"] as? [String: Any]
            let rootTurnID = nonEmpty(payload["root_turn_id"] as? String)
                ?? nonEmpty(attribution?["root_turn_id"] as? String)
                ?? turnID
            cursor.currentTurnID = turnID
            cursor.currentRootTurnID = rootTurnID
            let at = epochDate(payload["started_at"]) ?? timestamp(root) ?? Date()
            events.append(.started(threadID: thread, turnID: turnID, rootTurnID: rootTurnID, at: at))

        case "task_complete", "turn_complete", "turn_aborted":
            guard let turnID = nonEmpty(payload["turn_id"] as? String) else { return }
            let rootTurnID = nonEmpty(payload["root_turn_id"] as? String)
                ?? (cursor.currentTurnID == turnID ? cursor.currentRootTurnID : nil)
                ?? turnID
            if cursor.currentTurnID == turnID {
                cursor.currentTurnID = nil
                cursor.currentRootTurnID = nil
            }
            let at = epochDate(payload["completed_at"]) ?? timestamp(root) ?? Date()
            events.append(.ended(
                threadID: thread, turnID: turnID, rootTurnID: rootTurnID, at: at,
                interrupted: kind == "turn_aborted"
            ))

        case "token_count":
            // 与 CodexJSONLScanner 相同的去重：累计签名不变的回显不算新调用，全零不算调用。
            guard let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return }
            let signature = CodexJSONLScanner.totalUsageSignature(info["total_token_usage"] as? [String: Any])
            if signature == cursor.lastTotalUsageSignature, signature != nil { return }
            if CodexRawTokenCounts(json: last).isZero { return }
            if let signature { cursor.lastTotalUsageSignature = signature }
            if let turnID = cursor.currentTurnID {
                let key = signature ?? "ts:\((root["timestamp"] as? String) ?? "")"
                events.append(.legacyUsage(
                    threadID: thread, turnID: turnID, rootTurnID: cursor.currentRootTurnID ?? turnID, key: key
                ))
            }

        default:
            return
        }
    }

    private static func parseUsageRecord(
        _ payload: [String: Any],
        root: [String: Any],
        cursor: CodexTurnFileCursor,
        into events: inout [CodexTurnEvent]
    ) {
        guard let threadID = nonEmpty(payload["thread_id"] as? String),
              let turnID = nonEmpty(payload["turn_id"] as? String),
              let usage = payload["usage"] as? [String: Any] else { return }
        // fork 会把父对话的历史逐行重放进新文件；那些记录的 thread_id 是父对话，原文件里已计过。
        guard cursor.ownThreadIDs.contains(threadID) else { return }
        let raw = CodexRawTokenCounts(json: usage)
        guard !raw.isZero else { return }
        let record = CodexUsageRecordEvent(
            responseID: nonEmpty(payload["response_id"] as? String),
            threadID: threadID,
            turnID: turnID,
            rootTurnID: nonEmpty(payload["root_turn_id"] as? String) ?? turnID,
            rootThreadID: nonEmpty(payload["session_id"] as? String) ?? threadID,
            raw: raw,
            reportedTurnTotals: (payload["turn_token_usage"] as? [String: Any]).map(CodexRawTokenCounts.init(json:)),
            model: cursor.model ?? "unknown",
            speed: cursor.speed,
            timestamp: timestamp(root) ?? Date()
        )
        events.append(.usage(record))
    }

    private static func timestamp(_ root: [String: Any]) -> Date? {
        (root["timestamp"] as? String).flatMap { JSONLTimestamp.parse($0) }
    }

    /// `started_at` / `completed_at` 是 Unix 秒；fork 重放会改写外层 timestamp，但保留这两个字段。
    private static func epochDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let seconds = number.doubleValue
        // 兼容毫秒写法。
        return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
