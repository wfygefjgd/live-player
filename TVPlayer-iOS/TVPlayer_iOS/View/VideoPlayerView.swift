import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import Combine

// MARK: - 方案 A：让路（safe area）
// 画面只铺在安全区内，底边主动留给系统 Home Indicator，不与系统抢层、不改 safeArea。

final class PlayerSurfaceView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var boundPlayer: AVPlayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPlayer(_ player: AVPlayer?) {
        boundPlayer = player
        playerLayer.player = player
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        setNeedsLayout()
    }

    func rebind() {
        guard let p = boundPlayer else { return }
        if playerLayer.player !== p {
            playerLayer.player = p
        }
        playerLayer.frame = bounds
        playerLayer.videoGravity = .resize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        playerLayer.videoGravity = .resize
        CATransaction.commit()
    }
}

/// 兼容旧调用名：内部转到当前 surface
final class WindowVideoSurface {
    static let shared = WindowVideoSurface()
    weak var surface: PlayerSurfaceView?

    func setPlayer(_ player: AVPlayer?) {
        surface?.setPlayer(player)
    }

    func rebindPlayer() {
        surface?.rebind()
    }

    // 以下为空实现：清掉历史 hack 调用点，避免再改布局
    func forceFullBleed(reason: String = "") {
        surface?.rebind()
    }

    func hardRemount(reason: String = "") {
        surface?.rebind()
    }

    func install(reason: String = "") {
        surface?.rebind()
    }
}

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let v = PlayerSurfaceView()
        WindowVideoSurface.shared.surface = v
        v.setPlayer(vm.player.player)
        return v
    }

    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        WindowVideoSurface.shared.surface = uiView
        uiView.setPlayer(vm.player.player)
        _ = vm.playerLayoutEpoch
    }
}

// MARK: - 根控制器（普通横屏，尊重系统 safe area）

final class FullScreenRootController: UIViewController {
    private let hosted: UIViewController

    init(hosting: UIViewController) {
        self.hosted = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    // 方案 A：不强制隐藏 Home Indicator，让系统正常占位
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = true

        addChild(hosted)
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        hosted.view.backgroundColor = .black
        view.addSubview(hosted.view)
        // 钉在 safe area 内 = 给小白条让路
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hosted.view.topAnchor.constraint(equalTo: guide.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            hosted.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
        hosted.didMove(toParent: self)
    }

    func refreshSystemChrome() {
        setNeedsStatusBarAppearanceUpdate()
    }
}

final class RootHostingController<Content: View>: UIHostingController<Content> {
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = true
    }
}

final class NowPlayingController {
    static let shared = NowPlayingController()
    private let infoCenter = MPNowPlayingInfoCenter.default()

    func update(title: String, artist: String, isPlaying: Bool) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        infoCenter.nowPlayingInfo = info
    }

    func updateElapsedTime(_ time: TimeInterval) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        infoCenter.nowPlayingInfo = info
    }

    func updatePlaybackRate(_ rate: Float) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        infoCenter.nowPlayingInfo = info
    }

    func clear() {
        infoCenter.nowPlayingInfo = nil
    }
}

extension Notification.Name {
    static let tvPlayerNeedsRelayout = Notification.Name("tvPlayerNeedsRelayout")
    static let tvPlayerInterruptionBegan = Notification.Name("tvPlayerInterruptionBegan")
    static let tvPlayerInterruptionEnded = Notification.Name("tvPlayerInterruptionEnded")
}
