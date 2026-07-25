import AVKit
import Combine

/// 起播/卡顿检测/静音检测引擎 — 结构化并发优化版
@MainActor
final class PlayerEngine: ObservableObject {
    // MARK: - 配置常量
    static let startupTimeoutNs: UInt64 = 3_000_000_000      // 3s 起播超时（改为3秒）
    static let readyProtectNs: UInt64 = 1_000_000_000         // 1s 出画保护（改为1秒）
    static let errorGraceNs: UInt64 = 1_000_000_000           // 1s 错误宽容（改为1秒）
    static let silentAudioCheckNs: UInt64 = 3_000_000_000     // 3s 后检测静音
    static let silentAudioPollIntervalNs: UInt64 = 500_000_000 // 500ms 轮询间隔

    // 根据网络类型动态调整卡顿阈值 - 更激进的超时
    static var stallTimeoutNs: UInt64 {
        NetworkMonitor.shared.isWiFi ? 1_500_000_000 : 2_500_000_000  // WiFi: 1.5s, 蜂窝: 2.5s
    }

    let player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?

    // 统一 Task 管理
    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var playToken = 0

    // 播放状态
    private var stallWatchEnabled = false
    private var continuousStall = false
    private var hasRendered = false
    private var lastItemTime: CMTime = .zero
    private var lastTimeProgressAt: Date = .distantPast

    // 静音检测
    private var hasAudioTrackReported = false
    private var silenceCheckScheduled = false

    @Published var isReady = false
    @Published var isPlaying = false

    // 回调
    var onError: (() -> Void)?
    var onReady: (() -> Void)?
    var onStartupTimeout: (() -> Void)?
    var onPlaybackStall: (() -> Void)?
    var onSilentAudio: (() -> Void)?
    var onExtendedStall: (() -> Void)?

    private var stallPollTask: Task<Void, Never>?
    private var consecutiveStallCount = 0

    init() {
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        observeTimeControl()
        setupCacheCleanup()  // 🆕 设置AVPlayer缓存清理
    }

    // 🆕 设置AVPlayer缓存清理
    private func setupCacheCleanup() {
        // App进入后台时清理播放器缓存
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearPlayerCache()
            }
        }
    }

    // 🆕 清理AVPlayer缓存
    private func clearPlayerCache() {
        // 清理AVAssetCache
        if let item = player.currentItem,
           let asset = item.asset as? AVURLAsset {
            asset.resourceLoader.setDelegate(nil, queue: nil)
        }

        // 清理旧的播放项
        player.replaceCurrentItem(with: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        startStallPolling(token: token)

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

            self.scheduleTask(named: "startup", token: token, timeout: Self.startupTimeoutNs) { [weak self] in
                guard let self, !self.isReady, !self.hasRendered else { return }
                self.cancelAllTasks()
                self.onStartupTimeout?()
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
        stopStallPolling()
        cancellables.removeAll()  // 🆕 清理Combine订阅
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
        stallWatchEnabled = false
        continuousStall = false
        hasRendered = false
        hasAudioTrackReported = false
        silenceCheckScheduled = false
        lastItemTime = .zero
        lastTimeProgressAt = .distantPast
    }

    private func cancelAllTasks() {
        for (_, task) in watchTasks {
            task.cancel()
        }
        watchTasks.removeAll()
    }

    @discardableResult
    private func scheduleTask(named name: String, token: Int, timeout: UInt64, action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        // 同名任务取消
        if let existing = watchTasks[name] {
            existing.cancel()
        }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.playToken == token else { return }
                action()
            } catch {
                // Cancelled
            }
            self?.watchTasks[name] = nil
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
        cancelTask(named: "startup")
        cancelTask(named: "errorGrace")
        isReady = true
        hasRendered = true
        player.play()
        isPlaying = true
        onReady?()

        // 保护期内不检测卡顿
        stallWatchEnabled = false
        scheduleTask(named: "readyProtect", token: token, timeout: Self.readyProtectNs) { [weak self] in
            guard let self, self.playToken == token else { return }
            self.stallWatchEnabled = true
        }

        // 延迟后检测静音
        scheduleSilentAudioCheck(token: token)
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
        guard !continuousStall else { return }
        continuousStall = true
        let token = playToken
        scheduleTask(named: "stall", token: token, timeout: Self.stallTimeoutNs) { [weak self] in
            guard let self, self.playToken == token, self.stallWatchEnabled else { return }
            let waiting = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let rateZero = self.player.rate == 0
            guard waiting, rateZero else {
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

        if !hasAudioTrackPresent() {
            hasAudioTrackReported = true
            onSilentAudio?()
            return
        }

        // 再轮询一次确认
        scheduleTask(named: "silentRecheck", token: token, timeout: Self.silentAudioPollIntervalNs) { [weak self] in
            guard let self, self.playToken == token, self.isReady else { return }
            if !self.hasAudioTrackPresent() {
                self.hasAudioTrackReported = true
                self.onSilentAudio?()
            }
        }
    }

    private func hasAudioTrackPresent() -> Bool {
        guard let item = player.currentItem else { return false }
        let audioTracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
        return !audioTracks.isEmpty
    }

    // MARK: - Private — Stall Polling

    private func startStallPolling(token: Int) {
        stopStallPolling()
        consecutiveStallCount = 0
        stallPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.playToken == token, !Task.isCancelled else { return }
                guard self.isReady else { continue }
                if self.isStalled() {
                    self.consecutiveStallCount += 1
                    if self.consecutiveStallCount >= 2 {
                        self.consecutiveStallCount = 0
                        self.onExtendedStall?()
                    }
                } else {
                    self.consecutiveStallCount = 0
                }
            }
        }
    }

    private func stopStallPolling() {
        stallPollTask?.cancel()
        stallPollTask = nil
        consecutiveStallCount = 0
    }

    // MARK: - Private — Task Helpers

    private func cancelTask(named name: String) {
        watchTasks[name]?.cancel()
        watchTasks[name] = nil
    }

    /// 主动检测卡顿（供外部轮询，线程安全）
    func isStalled() -> Bool {
        guard player.currentItem != nil else { return true }
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            return true
        }
        if player.timeControlStatus == .playing && player.rate == 0 {
            return true
        }
        let progressAt = lastTimeProgressAt
        let rendered = hasRendered
        // 更激进的黑屏检测：2秒无进度即认为卡顿
        if rendered && progressAt != .distantPast,
           Date().timeIntervalSince(progressAt) > 2.0 {
            return true
        }
        if rendered && progressAt == .distantPast {
            return true
        }
        return false
    }
}
