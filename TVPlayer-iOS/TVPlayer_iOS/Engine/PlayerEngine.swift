import AVKit
import Combine

final class PlayerEngine: ObservableObject {
    let player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    private var statusObserver: NSKeyValueObservation?
    private var bufferObserver: NSKeyValueObservation?
    private var playToken = 0
    private var bufferTask: Task<Void, Never>?

    @Published var isReady = false
    @Published var isPlaying = false

    var onError: (() -> Void)?
    var onReady: (() -> Void)?
    var onSlowNetwork: (() -> Void)?

    init() {
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        observeStatus()
    }

    func play(url: URL) {
        pause()
        playToken += 1
        let token = playToken
        statusObserver?.invalidate()
        bufferObserver?.invalidate()
        cancelBufferTask()

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                DispatchQueue.main.async {
                    guard self.playToken == token else { return }
                    self.isReady = true
                    self.player.play()
                    self.isPlaying = true
                    self.onReady?()
                }
            } else if item.status == .failed {
                DispatchQueue.main.async {
                    guard self.playToken == token else { return }
                    self.onError?()
                }
            }
        }

        bufferObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if !item.isPlaybackLikelyToKeepUp {
                    self?.startBufferTask()
                } else {
                    self?.cancelBufferTask()
                }
            }
        }

        player.play()
        isPlaying = true
        isReady = false
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
        statusObserver?.invalidate()
        statusObserver = nil
        bufferObserver?.invalidate()
        bufferObserver = nil
        cancelBufferTask()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isReady = false
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    var isBufferingSlow: Bool {
        guard let item = player.currentItem else { return true }
        return !item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferEmpty
    }

    private func observeStatus() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = status == .playing
            }
            .store(in: &cancellables)
    }

    /// 卡顿 4s 后复查，仍慢再等 4s 确认后回调
    private func startBufferTask() {
        guard bufferTask == nil else { return }
        bufferTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let stillSlow = await MainActor.run { self.isBufferingSlow }
            guard stillSlow, !Task.isCancelled else {
                await MainActor.run { self.cancelBufferTask() }
                return
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                defer { self.cancelBufferTask() }
                guard self.isBufferingSlow else { return }
                self.onSlowNetwork?()
            }
        }
    }

    private func cancelBufferTask() {
        bufferTask?.cancel()
        bufferTask = nil
    }
}
