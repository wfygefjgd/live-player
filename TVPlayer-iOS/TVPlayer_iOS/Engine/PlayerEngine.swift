import AVKit
import Combine

class PlayerEngine: ObservableObject {
    let player = AVPlayer()
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    @Published var isReady = false
    @Published var isPlaying = false
    @Published var error: Error? = nil

    var onError: (() -> Void)?
    var onReady: (() -> Void)?

    init() {
        player.actionAtItemEnd = .pause
        observeStatus()
    }

    func play(url: URL) {
        pause()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        isReady = false
        error = nil

        // 1.5s mark ready
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                if self?.player.currentItem?.status == .readyToPlay || self?.player.rate ?? 0 > 0 {
                    self?.isReady = true
                    self?.onReady?()
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

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
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
}
