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

    /// 正向 ≥ 此值 → 保活（易达标，少误杀）
    static let positiveVoteThreshold = 3
    /// 负向 ≥ 此值 → 才考虑换线（更严，少乱切）
    static let negativeVoteThreshold = 8
    /// 非强失败需连续确认次数（起播）
    static let softFailConfirmCount = 5
    /// 播放中非强失败需连续确认次数
    static let postReadyFailConfirmCount = 6

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

    private var healthMonitor: PlaybackHealthMonitor?

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

    var onError: (() -> Void)?
    var onReady: (() -> Void)?
    var onStartupTimeout: (() -> Void)?
    var onPlaybackStall: (() -> Void)?
    var onSilentAudio: (() -> Void)?
    var onExtendedStall: (() -> Void)?
    var onHealthCritical: ((String) -> Void)?
    /// 网速过低/无网触发换线
    var onLowSpeed: ((String) -> Void)?

    /// 线路超时/卡顿/低速自动检测（设置可关，默认开）
    var lineTimeoutEnabled: Bool = true

    private var consecutiveStallCount = 0
    private var healthCheckTask: Task<Void, Never>?
    private var evidenceTask: Task<Void, Never>?
    private var itemErrorObserver: NSObjectProtocol?
    private var itemEndFailObserver: NSObjectProtocol?
    private var bufferEmptyObserver: NSObjectProtocol?
    private var playStartedAt: Date = .distantPast
    private var lastLoadedRangesCount = 0
    private var lastErrorLogCount = 0
    // 负向分持续累计（多信号融合用）
    private var persistentNegativeScore = 0

    init() {
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        healthMonitor = PlaybackHealthMonitor(player: player)
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

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "Mozilla/5.0 (iPhone; CPU iOS 17_0 like Mac OS X)"]
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
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
        // loadedTimeRanges 是否增长
        let ranges = item.loadedTimeRanges
        let rangesCount = ranges.count
        let rangesGrowing = rangesCount > lastLoadedRangesCount
        lastLoadedRangesCount = rangesCount
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
        lastErrorLogCount = 0
        playStartedAt = Date()

        // 墙钟硬兜底
        scheduleTask(named: "startup", token: token, timeout: Self.startupHardTimeoutNs) { [weak self] in
            guard let self, self.lineTimeoutEnabled, self.playToken == token else { return }
            guard !self.isReady, !self.hasRendered else { return }
            self.failStartup(token: token, reason: "起播超时")
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
                    return
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
        evidenceTask?.cancel()
        evidenceTask = nil
        cancelTask(named: "startup")
        cancelAllTasks()
        onStartupTimeout?()
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
        stopHealthCheck()
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
        stopHealthCheck()
        stopSpeedCheck()
        consecutiveStallCount = 0
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
        isReady = false
        healthMonitor?.reset()
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

                // 🆕 更新健康度监控
                self.healthMonitor?.updateVideoProgress(time: time, hasRendered: self.hasRendered)
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
        cancelTask(named: "confirmReady")
        cancelTask(named: "confirmReady2")
        cancelTask(named: "errorGrace")
        isReady = true
        hasRendered = true
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
            beginStallCheck()
        case .playing:
            cancelTask(named: "stall")
            continuousStall = false
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

    // MARK: - Private — Health Monitoring

    /// 综合健康度检查（ready 后启动；连续确认才切线）
    private func startHealthCheck(token: Int) {
        stopHealthCheck()
        guard lineTimeoutEnabled else { return }
        consecutiveStallCount = 0
        healthCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.readyProtectNs)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self, self.lineTimeoutEnabled, self.playToken == token, !Task.isCancelled else { return }
                guard self.isReady, self.stallWatchEnabled else { continue }
                if self.player.timeControlStatus == .paused {
                    self.consecutiveStallCount = 0
                    continue
                }

                // 有任何数据进来就不因卡顿/健康度换线（高峰拥堵正常）
                let speed = self.sampleObservedSpeedKBps()
                if speed >= Self.deadSpeedKBps {
                    self.consecutiveStallCount = 0
                    self.lowSpeedSince = nil
                    self.zeroSpeedSince = nil
                    continue
                }

                // 无数据时只累计，真正换线交给 startSpeedCheck / 起播超时
                if self.isStalled() {
                    self.consecutiveStallCount += 1
                } else {
                    self.consecutiveStallCount = 0
                }
            }
        }
    }

    private func stopHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
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
        if s.hasRendered && !s.isBufferEmpty && s.speedKBps >= Self.deadSpeedKBps { return .ok }

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

        // 卡顿单独：最多 +1，达不到阈值
        if s.isBufferEmpty && s.isWaiting { neg += 1 }
        // 真正坏：已出画但长时间停画 + 无数据 + 缓冲空
        if s.hasRendered && !s.clockAdvancing {
            neg += 2
            if s.speedKBps < Self.deadSpeedKBps { neg += 3 }
            if s.isBufferEmpty { neg += 2 }
            if !s.loadedRangesGrowing { neg += 1 }
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

    /// 主动检测卡顿：仅在「应在播」却长期不推进时判定；用户暂停不算卡顿
    func isStalled() -> Bool {
        guard player.currentItem != nil else { return true }
        if player.timeControlStatus == .paused {
            return false
        }
        // 正在播且有速率 → 一定不是卡顿
        if player.timeControlStatus == .playing && player.rate > 0.01 {
            if hasRendered, lastTimeProgressAt != .distantPast,
               Date().timeIntervalSince(lastTimeProgressAt) <= Self.progressStallThreshold {
                return false
            }
        }
        // 持续 waiting 且 rate=0
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate && player.rate == 0 {
            if lastTimeProgressAt == .distantPast {
                return hasRendered
            }
            return Date().timeIntervalSince(lastTimeProgressAt) > Self.progressStallThreshold
        }
        if player.timeControlStatus == .playing && player.rate == 0 {
            return true
        }
        if hasRendered, lastTimeProgressAt != .distantPast,
           Date().timeIntervalSince(lastTimeProgressAt) > Self.progressStallThreshold {
            return true
        }
        return false
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
    let errorLogNewErrors: Int
    let errorLogHasFatal: Bool
    let elapsed: TimeInterval

    init(itemStatus: AVPlayerItem.Status, hasRendered: Bool,
         hasVideoDimensions: Bool = false, clockAdvancing: Bool = false,
         speedKBps: Double = 0, isBufferEmpty: Bool = false,
         isLikelyToKeepUp: Bool = false, isWaiting: Bool = false,
         loadedRangesCount: Int = 0, loadedRangesGrowing: Bool = false,
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
