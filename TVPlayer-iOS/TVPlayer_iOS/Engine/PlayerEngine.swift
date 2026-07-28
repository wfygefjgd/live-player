import AVKit
import Combine

/// 起播/卡顿检测/静音检测引擎 — 结构化并发优化版
@MainActor
final class PlayerEngine: ObservableObject {
    // MARK: - 配置（事件驱动：硬失败立刻切；软问题多事件+长确认才切）
    /// 起播硬上限：慢 HLS 也要给足时间，避免「没几个能看」
    static let startupHardTimeoutNs: UInt64 = 12_000_000_000
    /// 评估周期
    static let evalPollNs: UInt64 = 500_000_000
    /// 出画后保护：此期间禁止因软问题换线
    static let readyProtectNs: UInt64 = 4_000_000_000
    static let errorGraceNs: UInt64 = 300_000_000
    /// 默认不做无声自动换线（纯视频台太多）；保留检测接口
    static let silentAudioCheckNs: UInt64 = 15_000_000_000
    static let silentAudioPollIntervalNs: UInt64 = 2_000_000_000
    static let progressStallThreshold: TimeInterval = 8.0

    static let minUsefulSpeedKBps: Double = 5
    static let deadSpeedKBps: Double = 0.8
    static let bufferGrowthEpsilon: TimeInterval = 0.15
    static let recentBufferProgressWindow: TimeInterval = 3

    /// 正向 ≥ 此值 → 保活（易达标，少误杀）
    static let positiveVoteThreshold = 3
    /// 负向 ≥ 此值 → 才考虑换线（更严，少乱切）
    static let negativeVoteThreshold = 8
    /// 非强失败需连续确认次数（起播）
    static let softFailConfirmCount = 5
    /// 播放中非强失败需连续确认次数
    static let postReadyFailConfirmCount = 6

    /// 起播保持短缓冲，先拿到第一帧；出画后再切换到稳定缓冲。
    static let initialBufferSeconds: TimeInterval = 4

    static let startupExtensionNs: UInt64 = 6_000_000_000
    static let maxStartupExtensions = 2

    static var steadyBufferSeconds: TimeInterval {
        NetworkMonitor.shared.isCellular ? 16 : 12
    }

    static var stallTimeoutNs: UInt64 {
        NetworkMonitor.shared.isWiFi ? 10_000_000_000 : 12_000_000_000
    }

    static var startupTimeoutNs: UInt64 { startupHardTimeoutNs }

    let player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?

    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var playToken = 0

    private var stallWatchEnabled = false
    private var continuousStall = false
    private var hasRendered = false
    private var lastItemTime: CMTime = .zero
    private var lastTimeProgressAt: Date = .distantPast

    private var hasAudioTrackReported = false
    private var silenceCheckScheduled = false

    // 网速采样
    private var lastAccessBytes: Int64 = 0
    private var lastAccessSampleAt: Date = .distantPast
    private var lastObservedKBps: Double = 0
    private var lowSpeedSince: Date?
    private var zeroSpeedSince: Date?
    private var speedCheckTask: Task<Void, Never>?

    @Published var isReady = false
    @Published var isPlaying = false
    /// 最近采样网速 KB/s（供 UI/调试）
    @Published var observedSpeedKBps: Double = 0
    @Published private(set) var diagnostics = PlaybackDiagnostics()

    var diagnosticsSummary: String {
        let observed = diagnostics.observedBitrate > 0 ? String(format: "%.2f Mbps", diagnostics.observedBitrate / 1_000_000) : "未知"
        let indicated = diagnostics.indicatedBitrate > 0 ? String(format: "%.2f Mbps", diagnostics.indicatedBitrate / 1_000_000) : "未知"
        return "TVPlayer iOS 播放诊断\n线路: \(currentURLString.isEmpty ? "未知" : currentURLString)\n实际码率: \(observed)\n标称码率: \(indicated)\n缓冲: \(String(format: "%.1f", diagnostics.bufferSeconds)) 秒\n卡顿: \(diagnostics.stallCount) 次\n码率限制: \(diagnostics.peakBitRateLimit > 0 ? String(format: "%.2f Mbps", diagnostics.peakBitRateLimit / 1_000_000) : "自动")\n最近状态: \(diagnostics.reason.isEmpty ? "未知" : diagnostics.reason)"
    }

    var onError: (() -> Void)?
    var onReady: (() -> Void)?
    var onStartupTimeout: (() -> Void)?
    var onSilentAudio: (() -> Void)?
    /// 网速过低/无网触发换线
    var onLowSpeed: ((String) -> Void)?

    /// 线路超时/卡顿/低速自动检测（设置可关，默认开）
    var lineTimeoutEnabled: Bool = true

    private var evidenceTask: Task<Void, Never>?
    private var itemErrorObserver: NSObjectProtocol?
    private var itemEndFailObserver: NSObjectProtocol?
    private var bufferEmptyObserver: NSObjectProtocol?
    private var playStartedAt: Date = .distantPast
    private var lastLoadedRangesCount = 0
    private var lastBufferedEnd: TimeInterval = 0
    private var lastBufferProgressAt: Date = .distantPast
    private var lastErrorLogCount = 0
    // 负向分持续累计（多信号融合用）
    private var persistentNegativeScore = 0
    private var currentURLString = ""
    private var recentStalls: [Date] = []
    private var lastStallAt: Date = .distantPast
    private var lastQualitySampleAt: Date = .distantPast
    private var activePeakBitRate: Double = 0
    private var failureRecorded = false
    private var startupExtensionCount = 0

    init() {
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        observeTimeControl()
        setupCacheCleanup()
        NotificationCenter.default.publisher(for: Notification.Name("tvPlayerVideoRendered"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let renderedPlayer = note.object as? AVPlayer,
                      renderedPlayer === self.player else { return }
                // 出画 = 最强正向证据：立刻 OK，取消一切起播兜底
                self.hasRendered = true
                if self.lastTimeProgressAt == .distantPast {
                    self.lastTimeProgressAt = Date()
                }
                if self.player.currentItem?.status == .readyToPlay || self.hasVideoFrameEvidence() {
                    self.markTrulyReady(token: self.playToken)
                }
            }
            .store(in: &cancellables)
    }

    private var memoryWarningObserver: NSObjectProtocol?

    // 内存紧张时仅清 URL 缓存；切勿在后台清空 currentItem（会中断后台音频）
    private func setupCacheCleanup() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            URLCache.shared.removeAllCachedResponses()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        statusObserver?.invalidate()
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
        }
        cancellables.removeAll()
    }

    // MARK: - Public API

    func play(url: URL) {
        // 彻底清理之前的播放状态
        pause()
        player.replaceCurrentItem(with: nil)

        playToken += 1
        let token = playToken
        statusObserver?.invalidate()
        statusObserver = nil

        resetState(for: token)
        currentURLString = url.absoluteString
        playStartedAt = Date()

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "Mozilla/5.0 (iPhone; CPU iOS 17_0 like Mac OS X)"]
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Self.initialBufferSeconds
        item.preferredPeakBitRate = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        player.automaticallyWaitsToMinimizeStalling = true

        // 强制刷新播放器状态，防止画面冻结
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.playToken == token else { return }
            self.player.replaceCurrentItem(with: item)
            self.isReady = false
            self.isPlaying = true

            self.setupItemObserver(item, token: token)
            self.setupTimeObserver(token: token)

            if self.lineTimeoutEnabled {
                self.armEvidenceDrivenWatch(token: token)
            }

            self.player.play()
            self.player.rate = 1.0
        }
    }

    // MARK: - 多信号融合评估器（统一采集 + 加权投票）

    /// 采集当前所有信号
    private func collectSignals() -> PlaybackSignals {
        guard let item = player.currentItem else {
            return PlaybackSignals(itemStatus: .unknown, hasRendered: false)
        }
        let accessLog = item.accessLog()
        let errorLog = item.errorLog()
        let speed = sampleObservedSpeedKBps()
        let clockAdvancing = hasRendered
            && lastTimeProgressAt != .distantPast
            && Date().timeIntervalSince(lastTimeProgressAt) <= Self.progressStallThreshold
        // AVPlayer 通常只维护一个 loadedTimeRange，比较区间终点才能识别真实下载进度。
        let ranges = item.loadedTimeRanges
        let rangesCount = ranges.count
        let bufferedEnd = ranges.compactMap { value -> TimeInterval? in
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(value.timeRangeValue))
            return end.isFinite ? end : nil
        }.max() ?? 0
        let rangesGrowing = bufferedEnd > lastBufferedEnd + Self.bufferGrowthEpsilon
        if rangesGrowing { lastBufferProgressAt = Date() }
        lastBufferedEnd = max(lastBufferedEnd, bufferedEnd)
        lastLoadedRangesCount = rangesCount
        let currentSeconds = CMTimeGetSeconds(item.currentTime())
        let bufferedSeconds = max(0, bufferedEnd - (currentSeconds.isFinite ? currentSeconds : 0))
        let bufferProgressRecent = lastBufferProgressAt != .distantPast
            && Date().timeIntervalSince(lastBufferProgressAt) <= Self.recentBufferProgressWindow
        let event = accessLog?.events.last
        let observedBitrate = event?.observedBitrate ?? 0
        let indicatedBitrate = event?.indicatedBitrate ?? 0
        let throughputRatio = indicatedBitrate > 0 ? observedBitrate / indicatedBitrate : 0
        // errorLog 条数
        let errorCount = errorLog?.events.count ?? 0
        let newErrors = errorCount - lastErrorLogCount
        lastErrorLogCount = errorCount

        return PlaybackSignals(
            itemStatus: item.status,
            hasRendered: hasRendered,
            hasVideoDimensions: item.presentationSize.width > 1 && item.presentationSize.height > 1,
            clockAdvancing: clockAdvancing,
            speedKBps: speed,
            isBufferEmpty: item.isPlaybackBufferEmpty,
            isLikelyToKeepUp: item.isPlaybackLikelyToKeepUp,
            isWaiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            loadedRangesCount: rangesCount,
            loadedRangesGrowing: rangesGrowing,
            bufferProgressRecent: bufferProgressRecent,
            bufferedSeconds: bufferedSeconds,
            throughputRatio: throughputRatio,
            errorLogNewErrors: newErrors,
            errorLogHasFatal: hasFatalError(log: errorLog),
            elapsed: playStartedAt == .distantPast ? 0 : Date().timeIntervalSince(playStartedAt)
        )
    }

    private func hasFatalError(log: AVPlayerItemErrorLog?) -> Bool {
        guard let log = log else { return false }
        for e in log.events.suffix(4) {
            let code = e.errorStatusCode
            if code == 404 || code == 403 || code == 410 || code == 502 || code == 503 { return true }
            if code < 0, let msg = e.errorComment?.lowercased() {
                if msg.contains("404") || msg.contains("forbidden")
                    || msg.contains("not found") || msg.contains("unauthorized") {
                    return true
                }
            }
        }
        return false
    }

    /// 起播投票：强事件立刻切；软问题要多信号 + 长时间才切
    private func fuseVote(_ s: PlaybackSignals) -> FusionVerdict {
        // 出画 / 有尺寸且 ready → OK
        if s.hasRendered { return .ok }
        if s.itemStatus == .readyToPlay && s.hasVideoDimensions { return .ok }

        // 仅硬事件立刻失败
        if s.itemStatus == .failed { return .fail(reason: "线路失败", strong: true) }
        if s.errorLogHasFatal { return .fail(reason: "源不可用", strong: true) }

        var pos = 0
        var neg = 0

        // 正向：任何进展都加分，避免过早判死
        if s.itemStatus == .readyToPlay { pos += 2 }
        if s.hasVideoDimensions { pos += 3 }
        if s.speedKBps >= Self.minUsefulSpeedKBps { pos += 2 }
        else if s.speedKBps >= Self.deadSpeedKBps { pos += 1 }
        if s.isLikelyToKeepUp { pos += 2 }
        if !s.isBufferEmpty { pos += 1 }
        if s.loadedRangesGrowing { pos += 2 }
        if s.loadedRangesCount > 0 { pos += 1 }

        // 负向：单项弱；只有「完全没动静」才叠高分
        // 注意：起播阶段 clockAdvancing 几乎总是 false，不能当负向
        if s.elapsed > 6, !s.hasVideoDimensions, s.itemStatus != .readyToPlay,
           s.speedKBps < Self.deadSpeedKBps, s.isBufferEmpty, !s.loadedRangesGrowing {
            neg += 4  // 6s 后仍完全死寂
        } else if s.elapsed > 4, !s.hasVideoDimensions, s.speedKBps < Self.deadSpeedKBps, s.isBufferEmpty {
            neg += 2
        }
        if s.errorLogNewErrors > 0 { neg += 1 }

        if pos >= Self.positiveVoteThreshold { return .ok }
        if neg >= Self.negativeVoteThreshold { return .fail(reason: "起播无响应", strong: false) }
        return .undetermined(pos: pos, neg: neg)
    }

    /// 启动多信号融合评估（替代多个独立循环）
    private func armEvidenceDrivenWatch(token: Int) {
        evidenceTask?.cancel()
        persistentNegativeScore = 0
        lastLoadedRangesCount = 0
        lastBufferedEnd = 0
        lastBufferProgressAt = .distantPast
        lastErrorLogCount = 0
        playStartedAt = Date()

        // 墙钟硬兜底
        scheduleTask(named: "startup", token: token, timeout: Self.startupHardTimeoutNs) { [weak self] in
            guard let self, self.lineTimeoutEnabled, self.playToken == token else { return }
            guard !self.isReady, !self.hasRendered else { return }
            self.handleStartupDeadline(token: token)
        }

        evidenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.evalPollNs)
                guard let self, !Task.isCancelled, self.playToken == token else { return }
                guard self.lineTimeoutEnabled else { return }
                if self.isReady || self.hasRendered { return }

                let signals = self.collectSignals()
                let verdict = self.fuseVote(signals)

                switch verdict {
                case .ok:
                    self.markTrulyReady(token: token)
                    // READY/缓冲增长是正向信号，但没有解码帧时不能退出监控。
                    if self.isReady { return }
                    self.persistentNegativeScore = max(0, self.persistentNegativeScore - 2)
                case .fail(let reason, let strong):
                    if strong {
                        self.failStartup(token: token, reason: reason)
                        return
                    }
                    // 软失败：需连续多周期确认（约 softFailConfirmCount * 0.5s）
                    self.persistentNegativeScore += 1
                    if self.persistentNegativeScore >= Self.softFailConfirmCount {
                        self.failStartup(token: token, reason: reason)
                        return
                    }
                case .undetermined(let pos, let neg):
                    if pos > neg {
                        self.persistentNegativeScore = max(0, self.persistentNegativeScore - 2)
                    } else if neg > pos + 2 {
                        self.persistentNegativeScore += 1
                    }
                }
            }
        }
    }

    private func failStartup(token: Int, reason: String) {
        guard playToken == token, !isReady, !hasRendered else { return }
        recordFailureOnce()
        updateDiagnostics(reason: reason)
        evidenceTask?.cancel()
        evidenceTask = nil
        cancelTask(named: "startup")
        cancelAllTasks()
        onStartupTimeout?()
    }

    private func handleStartupDeadline(token: Int) {
        guard playToken == token, !isReady, !hasRendered else { return }
        let signals = collectSignals()

        if signals.itemStatus == .failed || signals.errorLogHasFatal {
            failStartup(token: token, reason: "线路明确失败")
            return
        }

        let hasNetworkProgress = signals.hasVideoDimensions
            || signals.bufferProgressRecent
            || (signals.isLikelyToKeepUp && signals.bufferedSeconds > 0)

        if hasNetworkProgress, startupExtensionCount < Self.maxStartupExtensions {
            startupExtensionCount += 1
            persistentNegativeScore = max(0, persistentNegativeScore - 2)
            updateDiagnostics(
                reason: "线路有数据，延长起播观察 \(startupExtensionCount)/\(Self.maxStartupExtensions)"
            )
            let taskName = "startupExtension\(startupExtensionCount)"
            scheduleTask(named: taskName, token: token, timeout: Self.startupExtensionNs) { [weak self] in
                guard let self, self.lineTimeoutEnabled, self.playToken == token else { return }
                guard !self.isReady, !self.hasRendered else { return }
                self.handleStartupDeadline(token: token)
            }
            return
        }

        let reason = startupExtensionCount >= Self.maxStartupExtensions
            ? "起播超过 24 秒仍未出画"
            : "起播无数据"
        failStartup(token: token, reason: reason)
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func resume() {
        guard player.currentItem != nil else { return }
        player.play()
        player.rate = 1.0
        isPlaying = true
        WindowVideoSurface.shared.rebindPlayer()
    }

    /// Re-arm line monitoring when the setting changes during playback.
    func setLineTimeoutEnabled(_ enabled: Bool) {
        lineTimeoutEnabled = enabled
        guard enabled else {
            evidenceTask?.cancel()
            evidenceTask = nil
            stopSpeedCheck()
            cancelAllTasks()
            activePeakBitRate = 0
            player.currentItem?.preferredPeakBitRate = 0
            player.currentItem?.preferredForwardBufferDuration = Self.steadyBufferSeconds
            return
        }

        guard player.currentItem != nil else { return }
        if isReady {
            if !stallWatchEnabled {
                let token = playToken
                scheduleTask(named: "readyProtect", token: token, timeout: Self.readyProtectNs) { [weak self] in
                    guard let self, self.playToken == token else { return }
                    self.stallWatchEnabled = true
                }
            }
            startSpeedCheck(token: playToken)
        } else {
            armEvidenceDrivenWatch(token: playToken)
        }
    }

    func stop() {
        playToken += 1
        statusObserver?.invalidate()
        statusObserver = nil
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        cancelAllTasks()
        evidenceTask?.cancel()
        evidenceTask = nil
        clearItemNotificationObservers()
        stopSpeedCheck()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isReady = false
        stallWatchEnabled = false
        continuousStall = false
        hasRendered = false
        hasAudioTrackReported = false
        silenceCheckScheduled = false
        lastItemTime = .zero
        lastTimeProgressAt = .distantPast
        lastAccessBytes = 0
        lastAccessSampleAt = .distantPast
        lastObservedKBps = 0
        observedSpeedKBps = 0
        lowSpeedSince = nil
        zeroSpeedSince = nil
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    /// 当前播放地址是否有可用的声音轨
    var hasActiveAudioTrack: Bool {
        guard let item = player.currentItem else { return false }
        let tracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
        return tracks.contains { $0.isEnabled }
    }

    // MARK: - Private — State Management

    private func resetState(for token: Int) {
        cancelAllTasks()
        evidenceTask?.cancel()
        evidenceTask = nil
        clearItemNotificationObservers()
        stopSpeedCheck()
        persistentNegativeScore = 0
        stallWatchEnabled = false
        continuousStall = false
        hasRendered = false
        hasAudioTrackReported = false
        silenceCheckScheduled = false
        lastItemTime = .zero
        lastTimeProgressAt = .distantPast
        lastAccessBytes = 0
        lastAccessSampleAt = .distantPast
        lastObservedKBps = 0
        observedSpeedKBps = 0
        lowSpeedSince = nil
        zeroSpeedSince = nil
        recentStalls.removeAll()
        lastStallAt = .distantPast
        lastQualitySampleAt = .distantPast
        activePeakBitRate = 0
        failureRecorded = false
        startupExtensionCount = 0
        diagnostics = PlaybackDiagnostics(bufferSeconds: Self.initialBufferSeconds)
        isReady = false
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
    }

    private func cancelAllTasks() {
        for (_, task) in watchTasks {
            task.cancel()
        }
        watchTasks.removeAll()
    }

    @discardableResult
    private func scheduleTask(named name: String, token: Int, timeout: UInt64, action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        if let existing = watchTasks[name] {
            existing.cancel()
        }
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.playToken == token else { return }
            action()
            self.watchTasks[name] = nil
        }
        watchTasks[name] = task
        return task
    }

    // MARK: - Private — Observers

    private func setupItemObserver(_ item: AVPlayerItem, token: Int) {
        clearItemNotificationObservers()

        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                Task { @MainActor [weak self] in
                    guard let self, self.playToken == token else { return }
                    self.handleReady(token: token)
                }
            } else if item.status == .failed {
                Task { @MainActor [weak self] in
                    guard let self, self.playToken == token else { return }
                    // 负向证据：几乎立刻失败
                    self.handleItemFailed(token: token, immediate: true)
                }
            }
        }

        // 播放中途致命错误 → 立刻换线信号
        itemErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playToken == token else { return }
                if !self.isReady {
                    if let item = self.player.currentItem, item.status == .failed {
                        self.failStartup(token: token, reason: item.error?.localizedDescription ?? "线路失败")
                    }
                }
            }
        }

        itemEndFailObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playToken == token else { return }
                if self.isReady {
                    self.onError?()
                } else {
                    self.handleItemFailed(token: token, immediate: true)
                }
            }
        }
    }

    private func clearItemNotificationObservers() {
        if let itemErrorObserver {
            NotificationCenter.default.removeObserver(itemErrorObserver)
            self.itemErrorObserver = nil
        }
        if let itemEndFailObserver {
            NotificationCenter.default.removeObserver(itemEndFailObserver)
            self.itemEndFailObserver = nil
        }
        if let bufferEmptyObserver {
            NotificationCenter.default.removeObserver(bufferEmptyObserver)
            self.bufferEmptyObserver = nil
        }
    }

    private func setupTimeObserver(token: Int) {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.playToken == token else { return }

                // 检测进度是否推进
                if time != self.lastItemTime {
                    if self.lastTimeProgressAt == .distantPast {
                        self.lastTimeProgressAt = Date()
                    } else if time > self.lastItemTime {
                        self.lastTimeProgressAt = Date()
                    }
                    self.lastItemTime = time
                }

                if !self.hasRendered && time > .zero && self.hasVideoFrameEvidence() {
                    self.hasRendered = true
                }

            }
        }
    }

    private func observeTimeControl() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPlaying = status == .playing
                    self.handleTimeControl(status)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Private — Event Handlers

    private func handleReady(token: Int) {
        guard playToken == token else { return }
        cancelTask(named: "errorGrace")
        // 不在此取消 startup：AVPlayer READY ≠ 已出画；无进度时仍由 startup 超时兜底
        player.play()
        isPlaying = true
        stallWatchEnabled = false

        scheduleTask(named: "confirmReady", token: token, timeout: 800_000_000) { [weak self] in
            guard let self, self.playToken == token else { return }
            if self.hasVideoFrameEvidence() {
                self.markTrulyReady(token: token)
                return
            }
            self.scheduleTask(named: "confirmReady2", token: token, timeout: 1_500_000_000) { [weak self] in
                guard let self, self.playToken == token else { return }
                if self.hasVideoFrameEvidence() {
                    self.markTrulyReady(token: token)
                }
                // 仍无进度：保留 startup 超时触发换线，避免假 READY 卡住
            }
        }
    }

    private func markTrulyReady(token: Int) {
        guard playToken == token else { return }
        guard hasVideoFrameEvidence() || hasRendered else { return }
        if isReady { return }
        evidenceTask?.cancel()
        evidenceTask = nil
        persistentNegativeScore = 0
        cancelTask(named: "startup")
        cancelTask(named: "startupFast")
        cancelTask(named: "startupSoft")
        cancelTask(named: "startupExtension1")
        cancelTask(named: "startupExtension2")
        cancelTask(named: "confirmReady")
        cancelTask(named: "confirmReady2")
        cancelTask(named: "errorGrace")
        isReady = true
        hasRendered = true
        player.currentItem?.preferredForwardBufferDuration = Self.steadyBufferSeconds
        let startupSeconds = playStartedAt == .distantPast
            ? 0 : Date().timeIntervalSince(playStartedAt)
        LineQualityStore.shared.recordStart(
            url: currentURLString,
            startupSeconds: startupSeconds
        )
        updateDiagnostics(reason: "播放稳定")
        player.play()
        player.rate = 1.0
        isPlaying = true
        onReady?()
        WindowVideoSurface.shared.rebindPlayer()

        stallWatchEnabled = false
        scheduleTask(named: "readyProtect", token: token, timeout: Self.readyProtectNs) { [weak self] in
            guard let self, self.playToken == token else { return }
            self.stallWatchEnabled = true
        }
        // 默认不做无声自动换线（很多台本身无音轨，会疯狂跳）
        // scheduleSilentAudioCheck(token: token)
        if lineTimeoutEnabled {
            startSpeedCheck(token: token)
        }
    }

    private func handleItemFailed(token: Int, immediate: Bool = false) {
        guard playToken == token else { return }
        recordFailureOnce()
        if hasRendered || isReady {
            // 已出画后的失败：走 error 换线
            onError?()
            return
        }
        let delay: UInt64 = immediate ? 0 : Self.errorGraceNs
        scheduleTask(named: "errorGrace", token: token, timeout: delay) { [weak self] in
            guard let self, self.playToken == token else { return }
            if self.hasRendered || self.isReady { return }
            self.evidenceTask?.cancel()
            self.evidenceTask = nil
            self.cancelAllTasks()
            self.onError?()
        }
    }

    private func handleTimeControl(_ status: AVPlayer.TimeControlStatus) {
        guard stallWatchEnabled, isReady else {
            if status == .playing {
                cancelTask(named: "stall")
                continuousStall = false
            }
            return
        }
        switch status {
        case .waitingToPlayAtSpecifiedRate:
            if !continuousStall {
                registerStall()
            }
            beginStallCheck()
        case .playing:
            cancelTask(named: "stall")
            continuousStall = false
            scheduleBitrateRecoveryIfNeeded()
        case .paused:
            cancelTask(named: "stall")
            continuousStall = false
        @unknown default:
            break
        }
    }

    private func beginStallCheck() {
        // 卡顿事件本身不换线；由 startSpeedCheck 多信号融合统一判定
        // 这里只做状态复位，避免 continuousStall 卡死
        guard lineTimeoutEnabled else { return }
        continuousStall = true
        let token = playToken
        scheduleTask(named: "stall", token: token, timeout: Self.stallTimeoutNs) { [weak self] in
            guard let self, self.playToken == token else { return }
            self.continuousStall = false
        }
    }

    // MARK: - Adaptive Buffering

    private func registerStall() {
        guard isReady, let item = player.currentItem else { return }
        let now = Date()
        lastStallAt = now
        recentStalls = recentStalls.filter { now.timeIntervalSince($0) <= 45 }
        recentStalls.append(now)
        LineQualityStore.shared.recordStall(url: currentURLString)

        // 第一次卡顿先扩大缓冲；连续卡顿才降码率，避免轻微网络抖动损失画质。
        item.preferredForwardBufferDuration = min(Self.steadyBufferSeconds + 4, 22)
        if recentStalls.count >= 2 {
            applyTemporaryBitrateLimit(to: item)
        }
        updateDiagnostics(reason: recentStalls.count >= 2 ? "连续卡顿，已自适应" : "正在扩大缓冲")
    }

    private func applyTemporaryBitrateLimit(to item: AVPlayerItem) {
        guard let event = item.accessLog()?.events.last else { return }
        let streamBitrate = event.indicatedBitrate
        let observedBitrate = event.observedBitrate
        let basis: Double
        if streamBitrate > 0, observedBitrate > 0 {
            basis = min(streamBitrate, observedBitrate)
        } else {
            basis = max(streamBitrate, observedBitrate)
        }
        guard basis > 0 else { return }

        let proposed = max(700_000, min(basis * 0.75, 4_500_000))
        if activePeakBitRate == 0 || proposed < activePeakBitRate {
            activePeakBitRate = proposed
            item.preferredPeakBitRate = proposed
        }
    }

    private func scheduleBitrateRecoveryIfNeeded() {
        guard activePeakBitRate > 0 else { return }
        let token = playToken
        scheduleTask(named: "bitrateRecovery", token: token, timeout: 90_000_000_000) { [weak self] in
            guard let self, self.playToken == token else { return }
            guard Date().timeIntervalSince(self.lastStallAt) >= 85 else { return }
            self.activePeakBitRate = 0
            self.player.currentItem?.preferredPeakBitRate = 0
            self.player.currentItem?.preferredForwardBufferDuration = Self.steadyBufferSeconds
            self.recentStalls.removeAll()
            self.updateDiagnostics(reason: "网络稳定，已恢复自动画质")
        }
    }

    private func recordFailureOnce() {
        guard !failureRecorded else { return }
        failureRecorded = true
        LineQualityStore.shared.recordFailure(url: currentURLString)
    }

    private func updateDiagnostics(reason: String) {
        let event = player.currentItem?.accessLog()?.events.last
        diagnostics = PlaybackDiagnostics(
            observedBitrate: event?.observedBitrate ?? 0,
            indicatedBitrate: event?.indicatedBitrate ?? 0,
            stallCount: recentStalls.count,
            bufferSeconds: currentBufferedSeconds(),
            peakBitRateLimit: activePeakBitRate,
            reason: reason
        )
    }

    // MARK: - Private — Silent Audio Detection

    private func scheduleSilentAudioCheck(token: Int) {
        guard !silenceCheckScheduled else { return }
        silenceCheckScheduled = true

        scheduleTask(named: "silentCheck", token: token, timeout: Self.silentAudioCheckNs) { [weak self] in
            guard let self, self.playToken == token, self.isReady else { return }
            self.pollAudioTrack(token: token)
        }
    }

    private func pollAudioTrack(token: Int) {
        guard playToken == token, isReady, !hasAudioTrackReported else { return }

        // 有音轨则结束；无音轨再等一轮，避免起播瞬间 tracks 为空
        if hasAudioTrackPresent() {
            hasAudioTrackReported = true
            return
        }

        scheduleTask(named: "silentRecheck", token: token, timeout: Self.silentAudioPollIntervalNs) { [weak self] in
            guard let self, self.playToken == token, self.isReady else { return }
            if self.hasAudioTrackPresent() {
                self.hasAudioTrackReported = true
                return
            }
            // 第三次再确认
            self.scheduleTask(named: "silentRecheck2", token: token, timeout: Self.silentAudioPollIntervalNs) { [weak self] in
                guard let self, self.playToken == token, self.isReady else { return }
                self.hasAudioTrackReported = true
                if !self.hasAudioTrackPresent() {
                    self.onSilentAudio?()
                }
            }
        }
    }

    private func hasAudioTrackPresent() -> Bool {
        guard let item = player.currentItem else { return false }
        let audioTracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
        if !audioTracks.isEmpty { return audioTracks.contains { $0.isEnabled } }
        // asset 级兜底（tracks 尚未挂上时）
        let assetAudios = item.asset.tracks(withMediaType: .audio)
        return !assetAudios.isEmpty
    }

    private func hasVideoTrackPresent() -> Bool {
        guard let item = player.currentItem else { return false }
        if item.presentationSize.width > 1, item.presentationSize.height > 1 {
            return true
        }
        if item.tracks.contains(where: { $0.assetTrack?.mediaType == .video }) {
            return true
        }
        return !item.asset.tracks(withMediaType: .video).isEmpty
    }

    /// Evidence that decoded video exists, rather than only an advancing
    /// audio/live clock. presentationSize becomes valid once AVFoundation has
    /// received a video sample; isReadyForDisplay is reported separately by
    /// WindowVideoSurface and sets hasRendered immediately when available.
    private func hasVideoFrameEvidence() -> Bool {
        if hasRendered { return true }
        guard let item = player.currentItem,
              item.presentationSize.width > 1,
              item.presentationSize.height > 1,
              lastTimeProgressAt != .distantPast else {
            return false
        }
        return hasVideoTrackPresent()
    }

    // MARK: - 多信号融合「播放中」健康评估（统一采集 + 加权投票）

    /// 播放中健康评估：采集全部信号 → 融合投票 → 多信号一致才换线
    private func startSpeedCheck(token: Int) {
        stopSpeedCheck()
        guard lineTimeoutEnabled else { return }
        speedCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.lineTimeoutEnabled, self.playToken == token, !Task.isCancelled else { return }
                if self.player.timeControlStatus == .paused { continue }
                guard self.isReady, self.stallWatchEnabled else { continue }

                let signals = self.collectSignals()
                let now = Date()
                if signals.clockAdvancing,
                   now.timeIntervalSince(self.lastQualitySampleAt) >= 15 {
                    let event = self.player.currentItem?.accessLog()?.events.last
                    LineQualityStore.shared.recordStablePlayback(
                        url: self.currentURLString,
                        seconds: 15,
                        observedBitrate: event?.observedBitrate ?? 0
                    )
                    self.lastQualitySampleAt = now
                    self.updateDiagnostics(reason: "播放稳定")
                }
                let verdict = self.fusePostReadyVote(signals)

                switch verdict {
                case .ok:
                    self.zeroSpeedSince = nil
                    self.lowSpeedSince = nil
                    self.persistentNegativeScore = max(0, self.persistentNegativeScore - 1)
                case .fail(let reason, let strong):
                    if strong {
                        self.onLowSpeed?(reason)
                        return
                    }
                    self.persistentNegativeScore += 1
                    if self.persistentNegativeScore >= Self.postReadyFailConfirmCount {
                        self.onLowSpeed?(reason)
                        return
                    }
                case .undetermined:
                    self.persistentNegativeScore = max(0, self.persistentNegativeScore - 1)
                }
            }
        }
    }

    /// 播放中：只有硬失败立刻切；卡顿/缓冲单独不切；需「停画+无数据」等多事件
    private func fusePostReadyVote(_ s: PlaybackSignals) -> FusionVerdict {
        // 有画面推进 → 绝不换
        if s.hasRendered && s.clockAdvancing { return .ok }
        if s.hasRendered && s.isLikelyToKeepUp { return .ok }
        if s.hasRendered && s.bufferedSeconds >= 2 && (s.bufferProgressRecent || s.throughputRatio >= 0.9) { return .ok }

        // 仅硬事件
        if s.itemStatus == .failed { return .fail(reason: "线路中断", strong: true) }
        if s.errorLogHasFatal { return .fail(reason: "源错误", strong: true) }

        var pos = 0
        var neg = 0

        if s.clockAdvancing { pos += 4 }
        if s.speedKBps >= Self.minUsefulSpeedKBps { pos += 2 }
        else if s.speedKBps >= Self.deadSpeedKBps { pos += 1 }
        if s.isLikelyToKeepUp { pos += 2 }
        if !s.isBufferEmpty { pos += 1 }
        if s.loadedRangesGrowing { pos += 1 }
        if s.throughputRatio >= 1.15 { pos += 2 }
        else if s.throughputRatio >= 0.9 { pos += 1 }

        // 卡顿单独：最多 +1，达不到阈值
        if s.isBufferEmpty && s.isWaiting { neg += 1 }
        // 真正坏：已出画但长时间停画 + 无数据 + 缓冲空
        if s.hasRendered && !s.clockAdvancing {
            neg += 2
            if s.speedKBps < Self.deadSpeedKBps { neg += 3 }
            if s.isBufferEmpty { neg += 2 }
            if !s.bufferProgressRecent { neg += 1 }
            if s.throughputRatio > 0 && s.throughputRatio < 0.65 && s.bufferedSeconds < 1.5 { neg += 2 }
        }
        if s.errorLogNewErrors > 0 { neg += 1 }

        if pos >= Self.positiveVoteThreshold { return .ok }
        if neg >= Self.negativeVoteThreshold { return .fail(reason: "画面中断无数据", strong: false) }
        return .undetermined(pos: pos, neg: neg)
    }

    private func stopSpeedCheck() {
        speedCheckTask?.cancel()
        speedCheckTask = nil
    }

    private func currentBufferedSeconds() -> TimeInterval {
        guard let item = player.currentItem else { return 0 }
        let current = CMTimeGetSeconds(item.currentTime())
        guard current.isFinite else { return 0 }
        return item.loadedTimeRanges.reduce(0) { best, value in
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            guard start.isFinite, end.isFinite, current >= start - 0.1, current <= end else { return best }
            return max(best, end - current)
        }
    }

    /// 从 AVPlayerItemAccessLog 估算 KB/s
    @discardableResult
    func sampleObservedSpeedKBps() -> Double {
        guard let item = player.currentItem,
              let log = item.accessLog(),
              let last = log.events.last else {
            observedSpeedKBps = lastObservedKBps
            return lastObservedKBps
        }

        let bytes = last.numberOfBytesTransferred
        let now = Date()

        // 优先用 observedBitrate（bits/s）
        let bitrate = last.observedBitrate
        if bitrate > 0 {
            let kbps = bitrate / 8.0 / 1024.0
            lastObservedKBps = kbps
            observedSpeedKBps = kbps
            lastAccessBytes = bytes
            lastAccessSampleAt = now
            return kbps
        }

        // 差分 bytes / 时间
        if lastAccessSampleAt != .distantPast, lastAccessBytes > 0, bytes >= lastAccessBytes {
            let dt = now.timeIntervalSince(lastAccessSampleAt)
            if dt > 0.2 {
                let delta = Double(bytes - lastAccessBytes)
                let kbps = (delta / dt) / 1024.0
                lastObservedKBps = kbps
                observedSpeedKBps = kbps
                lastAccessBytes = bytes
                lastAccessSampleAt = now
                return kbps
            }
        } else {
            lastAccessBytes = bytes
            lastAccessSampleAt = now
        }

        // 缓冲中但尚无 log：用 buffer 是否在涨作弱信号
        if item.isPlaybackLikelyToKeepUp {
            lastObservedKBps = max(lastObservedKBps, Self.minUsefulSpeedKBps)
        } else if item.isPlaybackBufferEmpty {
            lastObservedKBps = min(lastObservedKBps, Self.deadSpeedKBps)
        }
        observedSpeedKBps = lastObservedKBps
        return lastObservedKBps
    }

    // MARK: - Private — Task Helpers

    private func cancelTask(named name: String) {
        watchTasks[name]?.cancel()
        watchTasks[name] = nil
    }

}

// MARK: - 多信号融合数据结构

struct PlaybackSignals {
    let itemStatus: AVPlayerItem.Status
    let hasRendered: Bool
    let hasVideoDimensions: Bool
    let clockAdvancing: Bool
    let speedKBps: Double
    let isBufferEmpty: Bool
    let isLikelyToKeepUp: Bool
    let isWaiting: Bool
    let loadedRangesCount: Int
    let loadedRangesGrowing: Bool
    let bufferProgressRecent: Bool
    let bufferedSeconds: TimeInterval
    let throughputRatio: Double
    let errorLogNewErrors: Int
    let errorLogHasFatal: Bool
    let elapsed: TimeInterval

    init(itemStatus: AVPlayerItem.Status, hasRendered: Bool,
         hasVideoDimensions: Bool = false, clockAdvancing: Bool = false,
         speedKBps: Double = 0, isBufferEmpty: Bool = false,
         isLikelyToKeepUp: Bool = false, isWaiting: Bool = false,
         loadedRangesCount: Int = 0, loadedRangesGrowing: Bool = false,
         bufferProgressRecent: Bool = false, bufferedSeconds: TimeInterval = 0,
         throughputRatio: Double = 0,
         errorLogNewErrors: Int = 0, errorLogHasFatal: Bool = false,
         elapsed: TimeInterval = 0) {
        self.itemStatus = itemStatus
        self.hasRendered = hasRendered
        self.hasVideoDimensions = hasVideoDimensions
        self.clockAdvancing = clockAdvancing
        self.speedKBps = speedKBps
        self.isBufferEmpty = isBufferEmpty
        self.isLikelyToKeepUp = isLikelyToKeepUp
        self.isWaiting = isWaiting
        self.loadedRangesCount = loadedRangesCount
        self.loadedRangesGrowing = loadedRangesGrowing
        self.bufferProgressRecent = bufferProgressRecent
        self.bufferedSeconds = bufferedSeconds
        self.throughputRatio = throughputRatio
        self.errorLogNewErrors = errorLogNewErrors
        self.errorLogHasFatal = errorLogHasFatal
        self.elapsed = elapsed
    }
}

enum FusionVerdict {
    case ok
    case fail(reason: String, strong: Bool)
    case undetermined(pos: Int, neg: Int)
}

struct PlaybackDiagnostics: Equatable {
    var observedBitrate: Double
    var indicatedBitrate: Double
    var stallCount: Int
    var bufferSeconds: TimeInterval
    var peakBitRateLimit: Double
    var reason: String

    init(
        observedBitrate: Double = 0,
        indicatedBitrate: Double = 0,
        stallCount: Int = 0,
        bufferSeconds: TimeInterval = 0,
        peakBitRateLimit: Double = 0,
        reason: String = ""
    ) {
        self.observedBitrate = observedBitrate
        self.indicatedBitrate = indicatedBitrate
        self.stallCount = stallCount
        self.bufferSeconds = bufferSeconds
        self.peakBitRateLimit = peakBitRateLimit
        self.reason = reason
    }
}
