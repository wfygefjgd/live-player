import AVKit
import Combine

/// 起播给足时间；只有真正长时间无画面/卡死才回调切换
final class PlayerEngine: ObservableObject {
    /// 起播超时（比 1.1.2 快 2s+，仍给一般频道加载时间）
    static let startupTimeoutNs: UInt64 = 15_000_000_000
    /// 播放中连续卡顿才切
    static let stallTimeoutNs: UInt64 = 10_000_000_000
    /// ready 后保护期
    static let readyProtectNs: UInt64 = 5_000_000_000
    /// error 至少等这么久再报失败
    static let errorGraceNs: UInt64 = 6_000_000_000

    let player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    private var statusObserver: NSKeyValueObservation?
    private var playToken = 0
    private var startupTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var protectTask: Task<Void, Never>?
    private var errorGraceTask: Task<Void, Never>?
    private var stallWatchEnabled = false
    private var continuousStall = false
    private var playStartedAt: Date?
    private var hasRendered = false

    @Published var isReady = false
    @Published var isPlaying = false

    var onError: (() -> Void)?
    var onReady: (() -> Void)?
    var onStartupTimeout: (() -> Void)?
    var onPlaybackStall: (() -> Void)?

    init() {
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        observeTimeControl()
    }

    func play(url: URL) {
        pause()
        playToken += 1
        let token = playToken
        cancelAllWatchers()
        statusObserver?.invalidate()
        stallWatchEnabled = false
        continuousStall = false
        hasRendered = false
        playStartedAt = Date()

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let item = AVPlayerItem(asset: asset)
        // 给直播多一点缓冲，减少刚出画就卡死
        item.preferredForwardBufferDuration = 6
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: item)
        isReady = false
        isPlaying = true

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                DispatchQueue.main.async {
                    guard self.playToken == token else { return }
                    self.handleReady(token: token)
                }
            } else if item.status == .failed {
                DispatchQueue.main.async {
                    guard self.playToken == token else { return }
                    self.scheduleErrorAfterGrace(token: token)
                }
            }
        }

        scheduleStartupTimeout(token: token)
        player.play()
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
        cancelAllWatchers()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isReady = false
        stallWatchEnabled = false
        continuousStall = false
        hasRendered = false
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    // MARK: - Ready / startup

    private func handleReady(token: Int) {
        guard playToken == token else { return }
        cancelStartup()
        errorGraceTask?.cancel()
        errorGraceTask = nil
        isReady = true
        hasRendered = true
        player.play()
        isPlaying = true
        onReady?()
        // 刚出画面：长时间保护，避免「画面刚出来就切走」
        stallWatchEnabled = false
        protectTask?.cancel()
        protectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.readyProtectNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.playToken == token else { return }
                self.stallWatchEnabled = true
            }
        }
    }

    private func scheduleErrorAfterGrace(token: Int) {
        errorGraceTask?.cancel()
        let elapsed = playStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let remain = max(0, Double(Self.errorGraceNs) / 1e9 - elapsed)
        errorGraceTask = Task { [weak self] in
            if remain > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remain * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.playToken == token else { return }
                // 已经出过画面则交给卡顿逻辑，不因瞬时 error 秒切
                if self.hasRendered || self.isReady { return }
                self.cancelAllWatchers()
                self.onError?()
            }
        }
    }

    private func scheduleStartupTimeout(token: Int) {
        cancelStartup()
        startupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.startupTimeoutNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.playToken == token else { return }
                // 已 ready / 已出画：不因超时切
                if self.isReady || self.hasRendered { return }
                self.cancelAllWatchers()
                self.onStartupTimeout?()
            }
        }
    }

    // MARK: - Stall

    private func observeTimeControl() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status == .playing
                self.handleTimeControl(status)
            }
            .store(in: &cancellables)
    }

    private func handleTimeControl(_ status: AVPlayer.TimeControlStatus) {
        guard stallWatchEnabled, isReady else {
            if status == .playing {
                stopStallTimer()
            }
            return
        }
        switch status {
        case .waitingToPlayAtSpecifiedRate:
            beginStallTimerIfNeeded()
        case .playing:
            stopStallTimer()
        case .paused:
            // 用户暂停不算卡顿
            stopStallTimer()
        @unknown default:
            break
        }
    }

    private func beginStallTimerIfNeeded() {
        guard !continuousStall else { return }
        continuousStall = true
        let token = playToken
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.stallTimeoutNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.playToken == token, self.stallWatchEnabled else { return }
                let waiting = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                let rateZero = self.player.rate == 0
                // 必须仍在 waiting 且 rate=0，避免「能播但缓冲中」误切
                guard waiting, rateZero else {
                    self.continuousStall = false
                    return
                }
                self.continuousStall = false
                self.stallTask = nil
                self.onPlaybackStall?()
            }
        }
    }

    private func stopStallTimer() {
        continuousStall = false
        stallTask?.cancel()
        stallTask = nil
    }

    private func cancelStartup() {
        startupTask?.cancel()
        startupTask = nil
    }

    private func cancelAllWatchers() {
        cancelStartup()
        stopStallTimer()
        protectTask?.cancel()
        protectTask = nil
        errorGraceTask?.cancel()
        errorGraceTask = nil
    }
}
