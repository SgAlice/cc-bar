import Foundation

/// Claude Code 日志（`~/.claude/projects/**/*.jsonl`）的回合解析，产出与 Codex 相同的 `CodexTurnEvent`。
///
/// 本机日志实测（Claude Code 桌面版 / CLI，2026-11）：
/// - 每条用户行（含工具结果）都带 `promptId`；开启新回合的那条另带 `turnPosition`
///   （`turnOrigin` 为 `human` / `sdk` / `task_notification`）。回合主键 = `sessionId` + `promptId`。
/// - 助手行没有 `promptId`，按文件内顺序归给当前回合。同一次调用按内容块拆成多行，
///   每行都带同一个 `message.id` 和最终用量；口径同 `ClaudeJSONLScanner`：只认带 `stop_reason` 的行，
///   按 `message.id` 去重，计价含 5m / 1h 缓存写入与 advisor 推理。
/// - 没有专门的结束事件：主线助手消息 `stop_reason` 不是 `tool_use` / `pause_turn`、且最后一个内容块
///   是文本时视为回合结束；`[Request interrupted by user` 视为中断；新回合开始时上一回合若还没结束，按结束处理。
/// - 子代理的调用并入所在回合（同一 `sessionId` 线程），不单独等待；结束后迟到的用量只补记账本。
nonisolated enum ClaudeTurnLogParser {
    /// Claude Code 的「回合还要继续」的停止原因。
    private static let continuingStopReasons: Set<String> = ["tool_use", "pause_turn"]

    /// 跳过明显无关的行。用户 / 助手行的 `type` 字段可能在几万字符之后，不能按前缀判断它们；
    /// 但 api-request、queue-operation 等元数据行的 `type` 固定写在行首，见到就跳过。
    static func isCandidate(_ line: String) -> Bool {
        guard line.hasPrefix("{\"type\":\"") else { return true }
        return line.hasPrefix("{\"type\":\"user\"") || line.hasPrefix("{\"type\":\"assistant\"")
    }

    static func parse(lines: some Sequence<String>, cursor: inout CodexTurnFileCursor) -> [CodexTurnEvent] {
        var events: [CodexTurnEvent] = []
        for line in lines where isCandidate(line) {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch root["type"] as? String {
            case "user": parseUser(root, cursor: &cursor, into: &events)
            case "assistant": parseAssistant(root, cursor: &cursor, into: &events)
            default: continue
            }
        }
        return events
    }

    private static func parseUser(_ root: [String: Any], cursor: inout CodexTurnFileCursor, into events: inout [CodexTurnEvent]) {
        guard let sessionID = nonEmpty(root["sessionId"] as? String) else { return }
        let promptID = nonEmpty(root["promptId"] as? String)
        let message = root["message"] as? [String: Any]
        let content = message?["content"]
        let isToolResult = (content as? [[String: Any]])?.contains { ($0["type"] as? String) == "tool_result" } ?? false
        let isMeta = (root["isMeta"] as? Bool) == true
        let isSidechain = (root["isSidechain"] as? Bool) == true
        let at = timestamp(root) ?? Date()

        if root["turnPosition"] != nil, let promptID, !isToolResult, !isMeta, !isSidechain {
            // 新回合开始。上一回合没有收到最终回答（例如排队消息接续）时按结束处理，不判为中断。
            if let previous = cursor.currentTurnID, previous != promptID, !cursor.claudeTurnEnded {
                events.append(.ended(threadID: sessionID, turnID: previous, rootTurnID: previous, at: at, interrupted: false))
            }
            cursor.currentTurnID = promptID
            cursor.currentRootTurnID = promptID
            cursor.canonicalThreadID = sessionID
            cursor.claudeTurnEnded = false
            if cursor.fallbackTitle == nil {
                cursor.fallbackTitle = ConversationTitleIndex.userMessage(from: content)
            }
            events.append(.started(threadID: sessionID, turnID: promptID, rootTurnID: promptID, at: at))
            return
        }

        if !isSidechain, Self.isInterruption(content), let current = cursor.currentTurnID, !cursor.claudeTurnEnded {
            cursor.claudeTurnEnded = true
            events.append(.ended(threadID: sessionID, turnID: current, rootTurnID: current, at: at, interrupted: true))
            return
        }

        // 从回合中途开始读（重启后续读）时，用工具结果行上的 promptId 接上当前回合。
        if cursor.currentTurnID == nil, let promptID, !isSidechain {
            cursor.currentTurnID = promptID
            cursor.currentRootTurnID = promptID
            cursor.canonicalThreadID = sessionID
            cursor.claudeTurnEnded = false
        }
    }

    private static func parseAssistant(_ root: [String: Any], cursor: inout CodexTurnFileCursor, into events: inout [CodexTurnEvent]) {
        guard let turnID = cursor.currentTurnID,
              let sessionID = nonEmpty(root["sessionId"] as? String) ?? cursor.canonicalThreadID,
              let message = root["message"] as? [String: Any] else { return }
        let stopReason = message["stop_reason"] as? String

        if let parsed = ClaudeJSONLScanner.parseAssistant(root), ClaudeJSONLScanner.isComplete(parsed) {
            events.append(.usage(usageEvent(parsed, sessionID: sessionID, turnID: turnID)))
        }

        // 主线上的最终回答（最后一块是文本）表示本回合结束；收在 thinking 等块时等后续行。
        let isSidechain = (root["isSidechain"] as? Bool) == true
        guard !isSidechain, !cursor.claudeTurnEnded, let stopReason,
              !continuingStopReasons.contains(stopReason) else { return }
        let lastBlock = (message["content"] as? [[String: Any]])?.last?["type"] as? String
        guard lastBlock == nil || lastBlock == "text" else { return }
        cursor.claudeTurnEnded = true
        events.append(.ended(
            threadID: sessionID, turnID: turnID, rootTurnID: turnID,
            at: timestamp(root) ?? Date(), interrupted: false
        ))
    }

    /// 与 `ClaudeJSONLScanner` 同口径的一次调用：输入不含缓存，总量 = 输入 + 输出 + 缓存读 + 缓存写；
    /// advisor 推理并入同一次调用的 token 与费用。
    static func usageEvent(_ parsed: ClaudeJSONLScanner.ParsedAssistant, sessionID: String, turnID: String) -> CodexUsageRecordEvent {
        var input = parsed.inputTokens
        var output = parsed.outputTokens
        var cacheRead = parsed.cacheReadTokens
        var cacheWrite = parsed.cacheCreationTokens
        var cost = Pricing.costBreakdown(
            app: .claude,
            model: parsed.model,
            speed: parsed.speed,
            input: parsed.inputTokens,
            output: parsed.outputTokens,
            cacheRead: parsed.cacheReadTokens,
            cacheCreation: parsed.cacheCreation5mTokens,
            cacheCreation1h: parsed.cacheCreation1hTokens,
            at: parsed.timestamp
        )?.total
        for advisor in parsed.advisorUsages {
            input += advisor.inputTokens
            output += advisor.outputTokens
            cacheRead += advisor.cacheReadTokens
            cacheWrite += advisor.cacheCreation.totalTokens
            let advisorCost = Pricing.costBreakdown(
                app: .claude,
                model: advisor.model,
                speed: .standard,
                input: advisor.inputTokens,
                output: advisor.outputTokens,
                cacheRead: advisor.cacheReadTokens,
                cacheCreation: advisor.cacheCreation.fiveMinuteTokens,
                cacheCreation1h: advisor.cacheCreation.oneHourTokens,
                at: parsed.timestamp
            )?.total
            cost = cost.flatMap { base in advisorCost.map { base + $0 } }
        }
        // 账本的原始计数以「输入含缓存」表示（与 Codex 一致），换算回统计口径时再扣掉缓存读写。
        let raw = CodexRawTokenCounts(
            input: input + cacheRead + cacheWrite,
            cachedInput: cacheRead,
            cacheWrite: cacheWrite,
            output: output
        )
        return CodexUsageRecordEvent(
            responseID: parsed.messageId,
            threadID: sessionID,
            turnID: turnID,
            rootTurnID: turnID,
            rootThreadID: sessionID,
            raw: raw,
            reportedTurnTotals: nil,
            model: parsed.model,
            speed: parsed.speed,
            timestamp: parsed.timestamp,
            precomputedCost: .init(costUSD: cost)
        )
    }

    /// Claude Code 在用户中断时写入的占位消息。
    private static func isInterruption(_ content: Any?) -> Bool {
        if let text = content as? String { return text.hasPrefix("[Request interrupted by user") }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { (($0["text"] as? String) ?? "").hasPrefix("[Request interrupted by user") }
    }

    private static func timestamp(_ root: [String: Any]) -> Date? {
        (root["timestamp"] as? String).flatMap { JSONLTimestamp.parse($0) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
