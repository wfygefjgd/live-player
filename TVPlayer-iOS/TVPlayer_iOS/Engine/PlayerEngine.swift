import AVKit
import Combine

/// 起播/卡顿检测/静音检测引擎 — 结构化并发优化版
@MainActor
final class PlayerEngine: ObservableObject {
    // MARK: - 配置常量（证据驱动：事件判定为主，超时仅兜底）
    /// 起播墙钟上限（仅兜底，正常靠 failed/出画事件结束）
    static let startupHardTimeoutNs: UInt64 = 7_000_000_000
    /// 证据轮询间隔
    static let evidencePollNs: UInt64 = 350_000_000
    /// 连续 N 次「无任何正向证据」→ 判死线（约 3.5s）
    static let deadEvidenceStrikes = 10
    /// 有弱希望但一直无画面：再给若干轮（合计约 6～7s 到 hard）
    static let softEvidenceStrikes = 16
    /// 出画后保护
    static let readyProtectNs: UInt64 = 2_000_000_000
    /// 硬失败后极短确认（防瞬时 glitch）；有负向证据可直接 0
    static let errorGraceNs: UInt64 = 200_000_000
    static let silentAudioCheckNs: UInt64 = 8_000_000_000
    static let silentAudioPollIntervalNs: UInt64 = 1_500_000_000
    static let progressStallThreshold: TimeInterval = 6.0

    static let minUsefulSpeedKBps: Double = 8
    static let deadSpeedKBps: Double = 1.5
    static let lowSpeedSwitchSeconds: TimeInterval = 10.0
    static let zeroSpeedSwitchSeconds: TimeInterval = 4.0
    static let zeroSpeedSwitchSecondsAfterRender: TimeInterval = 6.0

    static var stallTimeoutNs: UInt64 {
        NetworkMonitor.shared.isWiFi ? 6_000_000_000 : 8_000_000_000
    }

    static var startupTimeoutNs: UInt64 { startupHardTimeoutNs }
    /// 兼容旧分级名
    static var startupFastFailNs: UInt64 { UInt64(deadEvidenceStrikes) * evidencePollNs }
    static var startupSoftTimeoutNs: UInt64 { UInt64(softEvidenceStrikes) * evidencePollNs }

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
    private var deadStrikes = 0
    private var playStartedAt: Date = .distantPast

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

    // MARK: - 证据驱动起播判定（替代纯 sleep 超时）

    /// 正向证据 → 立刻 OK；负向证据 → 立刻失败；否则累计 strikes，到点才兜底
    private func armEvidenceDrivenWatch(token: Int) {
        evidenceTask?.cancel()
        deadStrikes = 0
        playStartedAt = Date()

        // 墙钟硬兜底（防止逻辑漏判一直黑屏）
        scheduleTask(named: "startup", token: token, timeout: Self.startupHardTimeoutNs) { [weak self] in
            guard let self, self.lineTimeoutEnabled, self.playToken == token else { return }
            guard !self.isReady, !self.hasRendered else { return }
            self.failStartup(token: token, reason: "起播超时")
        }

        evidenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.evidencePollNs)
                guard let self, !Task.isCancelled, self.playToken == token else { return }
                guard self.lineTimeoutEnabled else { return }
                if self.isReady || self.hasRendered { return }

                // ① 负向证据：立刻失败（不等待）
                if let neg = self.negativeEvidence() {
                    self.failStartup(token: token, reason: neg)
                    return
                }

                // ② 正向证据：立刻成功
                if self.positiveEvidence() {
                    self.markTrulyReady(token: token)
                    return
                }

                // ③ 尚无结论：按「有无希望」累计
                if self.startupHasStrongHope() {
                    self.deadStrikes = 0
                    continue
                }
                if self.startupHasHope() {
                    self.deadStrikes += 1
                    if self.deadStrikes >= Self.softEvidenceStrikes {
                        self.failStartup(token: token, reason: "起播无画面")
                        return
                    }
                } else {
                    self.deadStrikes += 1
                    if self.deadStrikes >= Self.deadEvidenceStrikes {
                        self.failStartup(token: token, reason: "线路无响应")
                        return
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
        cancelTask(named: "startupFast")
        cancelTask(named: "startupSoft")
        cancelAllTasks()
        _ = reason
        onStartupTimeout?()
    }

    /// 正向：已出画 / 有视频尺寸且时钟在走 / 有视频轨且 likelyToKeepUp
    private func positiveEvidence() -> Bool {
        if hasRendered { return true }
        if hasVideoFrameEvidence() { return true }
        guard let item = player.currentItem else { return false }
        if item.status == .readyToPlay,
           item.presentationSize.width > 1,
           lastTimeProgressAt != .distantPast {
            return true
        }
        return false
    }

    /// 负向：item failed、致命 errorLog、明确无法播放
    private func negativeEvidence() -> String? {
        guard let item = player.currentItem else { return "无播放项" }
        if item.status == .failed {
            return item.error?.localizedDescription ?? "线路失败"
        }
        if let log = item.errorLog() {
            for e in log.events.suffix(3) {
                let code = e.errorStatusCode
                // 常见致命：4xx/5xx、I/O、-1102 等
                if code == 404 || code == 403 || code == 410 || code == 502 || code == 503 {
                    return "源返回 \(code)"
                }
                if code < 0, let msg = e.errorComment, !msg.isEmpty {
                    let lower = msg.lowercased()
                    if lower.contains("404") || lower.contains("forbidden")
                        || lower.contains("not found") || lower.contains("unauthorized") {
                        return "源拒绝访问"
                    }
                }
            }
        }
        return nil
    }

    private func startupHasHope() -> Bool {
        guard let item = player.currentItem else { return false }
        if item.status == .readyToPlay { return true }
        if item.presentationSize.width > 1 { return true }
        if !item.isPlaybackBufferEmpty { return true }
        if item.loadedTimeRanges.isEmpty == false { return true }
        let speed = sampleObservedSpeedKBps()
        if speed >= Self.deadSpeedKBps { return true }
        if let log = item.accessLog(), let e = log.events.last, e.numberOfBytesTransferred > 1024 {
            return true
        }
        return false
    }

    private func startupHasStrongHope() -> Bool {
        guard let item = player.currentItem else { return false }
        if item.status == .readyToPlay, item.presentationSize.width > 1 { return true }
        if hasVideoFrameEvidence() { return true }
        let speed = sampleObservedSpeedKBps()
        if speed >= Self.minUsefulSpeedKBps { return true }
        if item.isPlaybackLikelyToKeepUp, !item.loadedTimeRanges.isEmpty { return true }
        return false
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
        deadStrikes = 0
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
                if let neg = self.negativeEvidence(), !self.isReady {
                    self.failStartup(token: token, reason: neg)
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
        deadStrikes = 0
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
        scheduleSilentAudioCheck(token: token)
        if lineTimeoutEnabled {
            startHealthCheck(token: token)
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
        guard lineTimeoutEnabled else { return }
        guard !continuousStall else { return }
        continuousStall = true
        let token = playToken
        scheduleTask(named: "stall", token: token, timeout: Self.stallTimeoutNs) { [weak self] in
            guard let self, self.lineTimeoutEnabled, self.playToken == token, self.stallWatchEnabled else { return }
            // 高峰卡顿很常见：只要还有数据进来就不因 stall 换线
            let speed = self.sampleObservedSpeedKBps()
            if speed >= Self.deadSpeedKBps {
                self.continuousStall = false
                return
            }
            // 完全无数据 + 卡死才上报（交给无数据策略）
            let waiting = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let noProgress = self.hasRendered
                && self.lastTimeProgressAt != .distantPast
                && Date().timeIntervalSince(self.lastTimeProgressAt) > Self.progressStallThreshold
            let frozenPlaying = self.player.timeControlStatus == .playing
                && self.player.rate > 0.01
                && noProgress
            guard waiting || frozenPlaying || self.isStalled() else {
                self.continuousStall = false
                return
            }
            self.continuousStall = false
            // 映射为无数据，而不是「卡顿换线」
            self.onLowSpeed?("无数据")
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

    // MARK: - 网速驱动换线

    /// 起播后即采样 accessLog；无网/无速快切，有速暂缓，低速持续再切
    private func startSpeedCheck(token: Int) {
        stopSpeedCheck()
        guard lineTimeoutEnabled else { return }
        speedCheckTask = Task { [weak self] in
            // 起播阶段也采样（不必等 ready）
            try? await Task.sleep(nanoseconds: 600_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.lineTimeoutEnabled, self.playToken == token, !Task.isCancelled else { return }
                if self.player.timeControlStatus == .paused { continue }

                let speed = self.sampleObservedSpeedKBps()
                let netOK = NetworkMonitor.shared.isSatisfied
                // 画面仍在推进 = 有播，不因 accessLog 抖动误切
                let progressOK = self.hasRendered
                    && self.lastTimeProgressAt != .distantPast
                    && Date().timeIntervalSince(self.lastTimeProgressAt) <= Self.progressStallThreshold

                if progressOK {
                    self.zeroSpeedSince = nil
                    self.lowSpeedSince = nil
                    continue
                }

                // (a) 系统无网，或速度接近 0 且画面也不动
                if !netOK || speed < Self.deadSpeedKBps {
                    if self.zeroSpeedSince == nil { self.zeroSpeedSince = Date() }
                    self.lowSpeedSince = nil
                    let elapsed = Date().timeIntervalSince(self.zeroSpeedSince ?? Date())
                    let need: TimeInterval
                    if !netOK {
                        need = Self.zeroSpeedSwitchSeconds
                    } else if self.hasRendered || self.isReady {
                        need = Self.zeroSpeedSwitchSecondsAfterRender
                    } else {
                        // 未出画：交给 startup 超时为主，这里只作慢兜底
                        need = max(Self.zeroSpeedSwitchSecondsAfterRender, 8.0)
                    }
                    if elapsed >= need {
                        self.zeroSpeedSince = nil
                        let hint = !netOK ? "网络未连接" : "无数据"
                        self.onLowSpeed?(hint)
                        return
                    }
                    continue
                }

                self.zeroSpeedSince = nil

                // (b) 有有效速度 → 不切（高峰卡顿正常）
                if speed >= Self.minUsefulSpeedKBps {
                    self.lowSpeedSince = nil
                    continue
                }

                // (c) 极低速 + 画面也不动：持续确认后换
                if self.lowSpeedSince == nil { self.lowSpeedSince = Date() }
                let lowElapsed = Date().timeIntervalSince(self.lowSpeedSince ?? Date())
                if lowElapsed >= Self.lowSpeedSwitchSeconds {
                    self.lowSpeedSince = nil
                    self.onLowSpeed?("几乎无数据")
                    return
                }
            }
        }
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
