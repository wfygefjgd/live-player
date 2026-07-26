import AVKit
import Combine

/// 起播/卡顿检测/静音检测引擎 — 结构化并发优化版
@MainActor
final class PlayerEngine: ObservableObject {
    // MARK: - 配置常量
    static let startupTimeoutNs: UInt64 = 3_500_000_000      // 3.5s 起播超时
    static let readyProtectNs: UInt64 = 1_200_000_000         // 1.2s 出画保护
    static let errorGraceNs: UInt64 = 800_000_000             // 0.8s 错误宽容
    static let silentAudioCheckNs: UInt64 = 6_000_000_000
    static let silentAudioPollIntervalNs: UInt64 = 1_000_000_000
    static let progressStallThreshold: TimeInterval = 1.8

    /// 网速阈值（KB/s）：≥ 此值暂缓换线；持续低于则快切
    static let minUsefulSpeedKBps: Double = 50
    /// 判定「几乎无速度」
    static let deadSpeedKBps: Double = 5
    /// 低速持续多久才换线（秒）
    static let lowSpeedSwitchSeconds: TimeInterval = 2.0
    /// 无网/无速度多久立刻换（秒）
    static let zeroSpeedSwitchSeconds: TimeInterval = 1.2

    static var stallTimeoutNs: UInt64 {
        NetworkMonitor.shared.isWiFi ? 2_000_000_000 : 3_000_000_000
    }

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

    init() {
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        healthMonitor = PlaybackHealthMonitor(player: player)  // 🆕 初始化健康度监控
        observeTimeControl()
        setupCacheCleanup()  // 🆕 设置AVPlayer缓存清理
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
        item.preferredForwardBufferDuration = 2
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        player.automaticallyWaitsToMinimizeStalling = false

        // 强制刷新播放器状态，防止画面冻结
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.playToken == token else { return }
            self.player.replaceCurrentItem(with: item)
            self.isReady = false
            self.isPlaying = true

            self.setupItemObserver(item, token: token)
            self.setupTimeObserver(token: token)

            if self.lineTimeoutEnabled {
                self.scheduleTask(named: "startup", token: token, timeout: Self.startupTimeoutNs) { [weak self] in
                    guard let self, self.lineTimeoutEnabled, !self.isReady, !self.hasRendered else { return }
                    self.cancelAllTasks()
                    self.onStartupTimeout?()
                }
            }

            // 强制播放，确保不会卡住
            self.player.play()
            self.player.rate = 1.0
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func resume() {
        guard player.currentItem != nil else { return }
        player.play()
        isPlaying = true
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
        stopHealthCheck()
        stopSpeedCheck()
        cancellables.removeAll()
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
        stopHealthCheck()
        stopSpeedCheck()
        consecutiveStallCount = 0
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
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                Task { @MainActor [weak self] in
                    guard let self, self.playToken == token else { return }
                    self.handleReady(token: token)
                }
            } else if item.status == .failed {
                Task { @MainActor [weak self] in
                    guard let self, self.playToken == token else { return }
                    self.handleItemFailed(token: token)
                }
            }
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

                if !self.hasRendered && time > .zero {
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
            if self.hasRendered || self.lastTimeProgressAt != .distantPast {
                self.markTrulyReady(token: token)
                return
            }
            self.scheduleTask(named: "confirmReady2", token: token, timeout: 1_500_000_000) { [weak self] in
                guard let self, self.playToken == token else { return }
                if self.hasRendered || self.lastTimeProgressAt != .distantPast {
                    self.markTrulyReady(token: token)
                }
                // 仍无进度：保留 startup 超时触发换线，避免假 READY 卡住
            }
        }
    }

    private func markTrulyReady(token: Int) {
        guard playToken == token else { return }
        cancelTask(named: "startup")
        cancelTask(named: "confirmReady")
        cancelTask(named: "confirmReady2")
        isReady = true
        hasRendered = true
        player.play()
        player.rate = 1.0
        isPlaying = true
        onReady?()
        // 出画后强制重绑画面层，消除「有声无画 / 被小白条裁切」
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
        WindowVideoSurface.shared.rebindPlayer()
        WindowVideoSurface.shared.forceFullBleed(reason: "player-ready")

        stallWatchEnabled = false
        scheduleTask(named: "readyProtect", token: token, timeout: Self.readyProtectNs) { [weak self] in
            guard let self, self.playToken == token else { return }
            self.stallWatchEnabled = true
            WindowVideoSurface.shared.forceFullBleed(reason: "ready-protect")
        }
        scheduleSilentAudioCheck(token: token)
        if lineTimeoutEnabled {
            startHealthCheck(token: token)
            startSpeedCheck(token: token)
        }
    }

    private func handleItemFailed(token: Int) {
        guard playToken == token else { return }
        let elapsed = lastTimeProgressAt == .distantPast ? 0 : Date().timeIntervalSince(lastTimeProgressAt)
        let graceRemain = max(0, Double(Self.errorGraceNs) / 1e9 - elapsed)

        scheduleTask(named: "errorGrace", token: token, timeout: UInt64(graceRemain * 1_000_000_000)) { [weak self] in
            guard let self, self.playToken == token else { return }
            if self.hasRendered || self.isReady { return }
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
            // 有够用网速时暂缓换线（正在缓冲加载）
            let speed = self.sampleObservedSpeedKBps()
            if speed >= Self.minUsefulSpeedKBps {
                self.continuousStall = false
                return
            }
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
            self.onPlaybackStall?()
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
        if !audioTracks.isEmpty { return true }
        // asset 级兜底（tracks 尚未挂上时）
        let assetAudios = item.asset.tracks(withMediaType: .audio)
        return !assetAudios.isEmpty
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

                // 有够用的网速时：不因短暂 waiting 误切（用户要求：有速度先等）
                let speed = self.sampleObservedSpeedKBps()
                if speed >= Self.minUsefulSpeedKBps {
                    self.consecutiveStallCount = 0
                    self.lowSpeedSince = nil
                    self.zeroSpeedSince = nil
                    continue
                }

                if let monitor = self.healthMonitor {
                    let immediate = monitor.shouldSwitchImmediately()
                    if immediate.should {
                        self.onHealthCritical?(immediate.reason)
                        return
                    }
                }

                if let item = self.player.currentItem, item.isPlaybackBufferEmpty {
                    self.healthMonitor?.recordBufferEmpty()
                }

                if self.isStalled() {
                    self.healthMonitor?.recordStall()
                    self.consecutiveStallCount += 1
                    if self.consecutiveStallCount >= 2 {
                        self.consecutiveStallCount = 0
                        self.onExtendedStall?()
                        return
                    }
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

                // (a) 网络未就绪 或 几乎无速度 → 累计后立刻换
                if !netOK || speed < Self.deadSpeedKBps {
                    if self.zeroSpeedSince == nil { self.zeroSpeedSince = Date() }
                    self.lowSpeedSince = nil
                    let elapsed = Date().timeIntervalSince(self.zeroSpeedSince ?? Date())
                    // 已出画且仍无速：更快；未出画用起播超时兜底，这里略放宽
                    let need = self.hasRendered || self.isReady
                        ? Self.zeroSpeedSwitchSeconds
                        : max(Self.zeroSpeedSwitchSeconds, 2.0)
                    if elapsed >= need {
                        self.zeroSpeedSince = nil
                        let hint = !netOK ? "网络未连接" : "无网速"
                        self.onLowSpeed?(hint)
                        return
                    }
                    continue
                }

                self.zeroSpeedSince = nil

                // (b) 有够用速度 → 暂缓，不切
                if speed >= Self.minUsefulSpeedKBps {
                    self.lowSpeedSince = nil
                    continue
                }

                // (c) 50KB 以下：持续一段时间再切
                if self.lowSpeedSince == nil { self.lowSpeedSince = Date() }
                let lowElapsed = Date().timeIntervalSince(self.lowSpeedSince ?? Date())
                if lowElapsed >= Self.lowSpeedSwitchSeconds {
                    self.lowSpeedSince = nil
                    self.onLowSpeed?(String(format: "网速偏低 %.0fKB/s", speed))
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
