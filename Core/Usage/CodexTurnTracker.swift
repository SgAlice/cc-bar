import CoreServices
import Foundation
import Observation
import os

// MARK: - 后台引擎

/// 读日志、改账本、落盘都在这个 actor 里串行执行，不占主线程。
///
/// 只读 `~/.codex/sessions` 下有变化的文件，按字节 offset 续读；不枚举全部历史，
/// 也不经过 `UsageService` 的周期扫描与 15 分钟写盘节流。
actor CodexTurnEngine {
    struct Result: Sendable {
        var notices: [CodexTurnRecord]
        var recent: [CodexTurnRecord]
        var hasSettlingTurns: Bool
        /// 本次处理中有根回合结束（用于触发一次今日用量刷新）。
        var sawTurnEnd: Bool
    }

    nonisolated struct PersistedState: Codable, Sendable {
        var version = 1
        var savedAt: Date
        var ledger: CodexTurnLedger
        var cursors: [String: CodexTurnFileCursor]
    }

    private let sessionsRoot: URL
    private let stateURL: URL?
    private let pricer: CodexTurnPricer
    private let titleLookup: @Sendable () -> [String: String]
    private var ledger = CodexTurnLedger()
    private var cursors: [String: CodexTurnFileCursor] = [:]
    private var trackingStartedAt = Date()
    private var dirty = false
    private var notificationsEnabled = true

    /// 首次启动（或状态文件失效）时回读多久以内改过的日志，用来恢复正在进行的回合。
    static let bootstrapWindow: TimeInterval = 24 * 3600
    /// 根回合结束后补扫多久以内改过的文件，兜住还没通过 FSEvents 送达的子代理日志。
    static let endSweepWindow: TimeInterval = 15 * 60
    static let recentLimit = 8

    init(
        sessionsRoot: URL,
        stateURL: URL?,
        pricer: @escaping CodexTurnPricer = CodexTurnLedger.productionPricer,
        titleLookup: @escaping @Sendable () -> [String: String] = { ConversationTitleIndex.codexTitles() }
    ) {
        self.sessionsRoot = sessionsRoot
        self.stateURL = stateURL
        self.pricer = pricer
        self.titleLookup = titleLookup
    }

    static func defaultStateURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("CCBar/usage-island", isDirectory: true)
            .appendingPathComponent("codex-turns.json", isDirectory: false)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
    }

    /// 载入账本并补读最近改过的日志。启动前已经结束的回合只记账、不提示（执行文档 §4.2 规则 8）。
    func bootstrap(now: Date) -> Result {
        trackingStartedAt = now
        if let stateURL, let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data), state.version == 1 {
            ledger = state.ledger
            cursors = state.cursors
        }
        // 有游标的文件从原处续读；没有游标的只回读近期改过的，恢复进行中的回合。
        let since = now.addingTimeInterval(-Self.bootstrapWindow)
        let files = JSONLDirectoryEnumerator.enumerate(at: sessionsRoot, minimumMtime: since).files
        readFiles(files.map(\.url))
        return finish(now: now, sawTurnEnd: false)
    }

    /// 处理一批变化的路径。`paths == nil` 表示事件被合并或丢失，按近期改过的文件补读。
    func process(paths: [String]?, now: Date) -> Result {
        let urls: [URL]
        if let paths {
            // FSEvents 上报的是解析过符号链接的真实路径，两种写法都认，读取时换回监听根下的路径。
            let roots = Array(Set([sessionsRoot.path, sessionsRoot.resolvingSymlinksInPath().path]))
            urls = paths.compactMap { path -> URL? in
                guard path.hasSuffix(".jsonl"),
                      let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return nil }
                return sessionsRoot.appendingPathComponent(String(path.dropFirst(root.count + 1)))
            }
        } else {
            urls = JSONLDirectoryEnumerator.enumerate(
                at: sessionsRoot, minimumMtime: now.addingTimeInterval(-Self.endSweepWindow)
            ).files.map(\.url)
        }
        let endedBefore = endedRootTurnIDs()
        readFiles(urls)
        let sawTurnEnd = endedRootTurnIDs() != endedBefore
        if sawTurnEnd {
            // 子代理日志与父对话是不同文件，结束事件到达时先把近期改过的文件都读到末尾再结算。
            let sweep = JSONLDirectoryEnumerator.enumerate(
                at: sessionsRoot, minimumMtime: now.addingTimeInterval(-Self.endSweepWindow)
            ).files.map(\.url)
            readFiles(sweep)
        }
        return finish(now: now, sawTurnEnd: sawTurnEnd)
    }

    /// 只重新结算（等待超时用），不读文件。
    func resettle(now: Date) -> Result {
        finish(now: now, sawTurnEnd: false)
    }

    func save(now: Date) {
        guard dirty, let stateURL else { return }
        // 游标只留最近一周内改过的文件；更旧的对话恢复写入时从头读一次即可。
        let cutoff = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        cursors = cursors.filter { $0.value.mtime >= cutoff }
        let state = PersistedState(savedAt: now, ledger: ledger, cursors: cursors)
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: [.atomic])
            dirty = false
        } catch {
            AppLog.warn(.usage, "turn ledger save failed: \(error.localizedDescription)")
        }
    }

    // MARK: Internals

    private func endedRootTurnIDs() -> Set<String> {
        Set(ledger.turns.values.filter(\.isEnded).map(\.turnID))
    }

    private func finish(now: Date, sawTurnEnd: Bool) -> Result {
        let fingerprint = ledger.hasSettlingTurns
            ? Pricing.fingerprint(knownUsage: [])
            : nil
        var notices = ledger.settle(
            now: now,
            trackingStartedAt: trackingStartedAt,
            notificationsEnabled: notificationsEnabled,
            pricingFingerprint: fingerprint
        )
        if !notices.isEmpty {
            let titles = titleLookup()
            for index in notices.indices {
                let title = titles[notices[index].threadID]
                notices[index].title = title
                ledger.turns[notices[index].turnID]?.title = title
            }
            dirty = true
        }
        ledger.prune(now: now)
        return Result(
            notices: notices,
            recent: ledger.recentEndedTurns(limit: Self.recentLimit),
            hasSettlingTurns: ledger.hasSettlingTurns,
            sawTurnEnd: sawTurnEnd
        )
    }

    /// 按会话 UUID 升序读：UUIDv7 前缀就是创建时间，父对话先于 fork / 子代理，`turn_id` 先由原线程占位。
    private func readFiles(_ urls: [URL]) {
        let unique = Array(Set(urls.map(\.standardizedFileURL)))
        let sorted = unique.sorted {
            let l = CodexTurnLogParser.threadID(fromFileURL: $0) ?? $0.path
            let r = CodexTurnLogParser.threadID(fromFileURL: $1) ?? $1.path
            return l == r ? $0.path < $1.path : l < r
        }
        for url in sorted { readFile(url) }
    }

    private func readFile(_ url: URL) {
        let path = url.path
        guard let initial = CodexTurnLogParser.initialCursor(for: url) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = (attributes?[.size] as? NSNumber)?.uint64Value else {
            // 文件被移走（归档）时保留游标，不当成错误。
            return
        }
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var cursor = cursors[path] ?? initial
        if cursor.offset == size, cursor.mtime == mtime { return }
        if cursor.offset > size {
            // 文件被截断或替换：从头读，账本按去重键防止重复计入。
            cursor = initial
        }
        var events: [CodexTurnEvent] = []
        let outcome = JSONLLineReader.streamLines(url: url, fromOffset: cursor.offset) { batch in
            events += CodexTurnLogParser.parse(lines: batch, cursor: &cursor)
        }
        guard case let .success(newOffset) = outcome else { return }
        let now = Date()
        for event in events {
            ledger.apply(event, now: now, pricer: pricer)
        }
        cursor.offset = newOffset
        cursor.mtime = mtime
        cursors[path] = cursor
        dirty = true
    }

    // MARK: Testing

    func ledgerForTesting() -> CodexTurnLedger { ledger }
}

// MARK: - FSEvents 接收盒

/// FSEvents 回调在后台队列，用锁盒子收集路径，再由主 actor 取走处理。
nonisolated private final class CodexTurnEventSink: Sendable {
    private struct Pending {
        var paths: Set<String> = []
        var uncertain = false
    }

    private let state = OSAllocatedUnfairLock(initialState: Pending())
    let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let uncertainMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
        )
        let relevant = state.withLock { pending -> Bool in
            var relevant = false
            for (index, path) in paths.enumerated() {
                let flag = index < flags.count ? flags[index] : uncertainMask
                if flag & uncertainMask != 0 {
                    pending.uncertain = true
                    relevant = true
                } else if path.hasSuffix(".jsonl") {
                    pending.paths.insert(path)
                    relevant = true
                }
            }
            return relevant
        }
        if relevant { onChange() }
    }

    func markUncertain() {
        state.withLock { $0.uncertain = true }
        onChange()
    }

    /// 取走并清空；返回 nil 路径表示需要按时间补扫。
    func drain() -> (paths: [String]?, hasWork: Bool) {
        state.withLock { pending in
            defer { pending = Pending() }
            if pending.uncertain { return (nil, true) }
            return (Array(pending.paths), !pending.paths.isEmpty)
        }
    }
}

// MARK: - 主 actor 门面

/// Codex 逐回合追踪。只在顶部用量胶囊开启了「回合完成提示」时运行。
@MainActor
@Observable
final class CodexTurnTracker {
    static let shared = CodexTurnTracker()

    /// 最近结束、已提示过的回合（新的在前），供展开面板显示。
    private(set) var recentTurns: [CodexTurnRecord] = []
    private(set) var isRunning = false

    /// 新完成的回合（按结束顺序）。
    @ObservationIgnored var onNotices: (([CodexTurnRecord]) -> Void)?
    /// 有根回合结束；用于请求一次今日用量刷新。
    @ObservationIgnored var onTurnEnded: (() -> Void)?

    @ObservationIgnored private var engine: CodexTurnEngine?
    @ObservationIgnored private var sink: CodexTurnEventSink?
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var isProcessing = false
    @ObservationIgnored private var resettleTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.ccbar.codex-turn-tracker", qos: .utility)

    /// 事件合并窗口：回合结束要尽快提示，但不必逐次写入都处理。
    private static let latency: CFTimeInterval = 0.5
    /// 账本落盘的最小间隔：Codex 连续写日志时也最多每 30 秒写一次。
    private static let saveDelay: Duration = .seconds(30)

    static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private init() {}

    func start(notificationsEnabled: Bool) {
        guard !AppRuntime.isRunningUnitTests else { return }
        if isRunning {
            setNotificationsEnabled(notificationsEnabled)
            return
        }
        isRunning = true
        let engine = CodexTurnEngine(sessionsRoot: Self.sessionsRoot, stateURL: CodexTurnEngine.defaultStateURL())
        self.engine = engine
        let sink = CodexTurnEventSink {
            Task { @MainActor in CodexTurnTracker.shared.pump() }
        }
        self.sink = sink
        startStream(sink: sink)
        isProcessing = true
        Task { [weak self] in
            await engine.setNotificationsEnabled(notificationsEnabled)
            let result = await engine.bootstrap(now: Date())
            guard let self, self.engine === engine else { return }
            self.apply(result)
            self.isProcessing = false
            self.pump()
        }
        AppLog.info(.usage, "codex turn tracker started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopStream()
        resettleTask?.cancel()
        saveTask?.cancel()
        if let engine {
            Task { await engine.save(now: Date()) }
        }
        engine = nil
        sink = nil
        recentTurns = []
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard let engine else { return }
        Task { await engine.setNotificationsEnabled(enabled) }
    }

    /// 退出前落盘。
    func persistForTermination() async {
        guard let engine else { return }
        await engine.save(now: Date())
    }

    /// 睡眠唤醒等场景：事件可能丢失，按时间补扫一次。
    func requestSweep() {
        sink?.markUncertain()
    }

    private func pump() {
        guard !isProcessing, let engine, let sink else { return }
        let work = sink.drain()
        guard work.hasWork else { return }
        isProcessing = true
        Task { [weak self] in
            let result = await engine.process(paths: work.paths, now: Date())
            guard let self, self.engine === engine else { return }
            self.apply(result)
            self.isProcessing = false
            self.pump()
        }
    }

    private func apply(_ result: CodexTurnEngine.Result) {
        if recentTurns != result.recent { recentTurns = result.recent }
        if !result.notices.isEmpty { onNotices?(result.notices) }
        if result.sawTurnEnd { onTurnEnded?() }
        scheduleResettle(result.hasSettlingTurns)
        scheduleSave()
    }

    /// 有回合在等子代理或对账时，隔 2 秒再结算一次；没有就不留定时器。
    private func scheduleResettle(_ needed: Bool) {
        resettleTask?.cancel()
        guard needed, let engine else { return }
        resettleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let result = await engine.resettle(now: Date())
            guard let self, self.engine === engine, !Task.isCancelled else { return }
            self.apply(result)
        }
    }

    private func scheduleSave() {
        guard saveTask == nil, let engine else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            await engine.save(now: Date())
            self?.saveTask = nil
        }
    }

    // MARK: FSEvents

    private func startStream(sink: CodexTurnEventSink) {
        let root = Self.sessionsRoot
        // sessions 还不存在（从没用过 Codex）时监听上一级，目录出现后照样能收到。
        let watched = FileManager.default.fileExists(atPath: root.path)
            ? root.path
            : root.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: watched) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let sink = Unmanaged<CodexTurnEventSink>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
                sink.markUncertain()
                return
            }
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            sink.handle(paths: paths, flags: flags)
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [watched] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            UInt32(
                kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            AppLog.warn(.usage, "codex turn tracker: FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            AppLog.warn(.usage, "codex turn tracker: FSEventStreamStart failed")
            return
        }
        stream = created
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
