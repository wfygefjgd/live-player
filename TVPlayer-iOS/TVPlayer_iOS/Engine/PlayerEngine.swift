import AVKit
import Combine

class PlayerEngine: ObservableObject {
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
        player.actionAtItemEnd = .pause
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
            if item.status == .failed {
                DispatchQueue.main.async { self?.onError?() }
            }
        }
        bufferObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            if !item.isPlaybackLikelyToKeepUp {
                DispatchQueue.main.async { self?.startBufferTask() }
            } else {
                DispatchQueue.main.async { self?.cancelBufferTask() }
            }
        }
        player.play()
        isPlaying = true
        isReady = false

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                guard let self, self.playToken == token else { return }
                if self.player.currentItem?.status == .readyToPlay || self.player.rate > 0 {
                    self.isReady = true
                    self.onReady?()
                }
            }
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

    private func observeStatus() {
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                self?.isPlaying = status == .playing
            }
            .store(in: &cancellables)
    }

    private func startBufferTask() {
        cancelBufferTask()
        bufferTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { onSlowNetwork?() }
        }
    }

    private func cancelBufferTask() {
        bufferTask?.cancel()
        bufferTask = nil
    }
}
</parameter>
<｜DSML｜parameter name="filePath" string="true">C:\\Users\\96335\\Desktop\\TVPlayer\\TVPlayer-iOS\\TVPlayer_iOS\\Engine\\PlayerEngine.swift