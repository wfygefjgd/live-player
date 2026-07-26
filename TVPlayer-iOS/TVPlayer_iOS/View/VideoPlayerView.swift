import SwiftUI
import AVKit
import UIKit
import MediaPlayer

// =============================================================================
// Edge-to-Edge 全屏播放（最小稳妥方案）
//
// - 容器 safeAreaInsets 强制 0：小白条不挤高度
// - 子视图钉 superview 四边（不用 safeAreaLayoutGuide）
// - 不每帧改 window.frame（避免中间小框 / 四周黑边）
// - Home Indicator 仅 auto-hide 浮在画面上
// - 视频 resizeAspect：完整画面，只允许两边比例黑边
// =============================================================================

// MARK: - 根容器：系统 safe area 不参与布局

final class SinkContainerView: UIView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

// MARK: - UIKit：铺满 bounds 的 AVPlayer 层

final class PlayerSurfaceView: UIView {
    private var boundPlayer: AVPlayer?

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPlayer(_ player: AVPlayer?) {
        boundPlayer = player
        playerLayer.player = player
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        playerLayer.videoGravity = .resizeAspect
        setNeedsLayout()
    }

    func rebind() {
        guard let p = boundPlayer else { return }
        if playerLayer.player !== p { playerLayer.player = p }
        playerLayer.videoGravity = .resizeAspect
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.videoGravity = .resizeAspect
    }
}

/// 兼容旧调用
final class WindowVideoSurface {
    static let shared = WindowVideoSurface()
    weak var surface: PlayerSurfaceView?

    func setPlayer(_ player: AVPlayer?) { surface?.setPlayer(player) }
    func rebindPlayer() { surface?.rebind() }
    func forceFullBleed(reason: String = "") { surface?.rebind() }
    func hardRemount(reason: String = "") { surface?.rebind() }
    func install(reason: String = "") { surface?.rebind() }
}

// MARK: - SwiftUI 包装

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let v = PlayerSurfaceView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        WindowVideoSurface.shared.surface = v
        v.setPlayer(vm.player.player)
        return v
    }

    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        WindowVideoSurface.shared.surface = uiView
        uiView.setPlayer(vm.player.player)
        _ = vm.playerLayoutEpoch
    }

    /// 跟随父级 proposal，不写死 UIScreen 尺寸（避免方向错误锁死小框）
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlayerSurfaceView, context: Context) -> CGSize? {
        guard let w = proposal.width, let h = proposal.height,
              w.isFinite, h.isFinite, w > 0, h > 0 else {
            return nil
        }
        return CGSize(width: w, height: h)
    }
}

// MARK: - UIKit 根控制器

final class FullScreenRootController: UIViewController {
    private let hosted: UIViewController

    init(hosting: UIViewController) {
        self.hosted = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = SinkContainerView(frame: .zero)
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = true
        view.clipsToBounds = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true

        addChild(hosted)
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        hosted.view.backgroundColor = .black
        hosted.view.clipsToBounds = false
        view.addSubview(hosted.view)
        // 钉 view 四边，不用 safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hosted.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosted.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosted.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshSystemChrome()
    }

    /// 兼容旧调用：只刷新系统栏策略，不改 window.frame
    func forcePhysicalFullScreen() {
        refreshSystemChrome()
    }

    func refreshSystemChrome() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
    }
}

/// 兼容旧几何工具（仅只读，不再用于强写 window）
enum ScreenGeometry {
    static func physicalLandscapeBounds(for scene: UIWindowScene?) -> CGRect {
        if let scene {
            let b = scene.coordinateSpace.bounds
            if b.width >= b.height {
                return CGRect(x: 0, y: 0, width: b.width, height: b.height)
            }
            return CGRect(x: 0, y: 0, width: b.height, height: b.width)
        }
        let s = UIScreen.main.bounds
        let w = max(s.width, s.height)
        let h = min(s.width, s.height)
        return CGRect(x: 0, y: 0, width: w, height: h)
    }
}

// MARK: - UIHostingController

final class RootHostingController<Content: View>: UIHostingController<Content> {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = true
        view.clipsToBounds = false
        view.layer.cornerRadius = 0
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
        view.insetsLayoutMarginsFromSafeArea = false
        view.preservesSuperviewLayoutMargins = false
        view.layoutMargins = .zero
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
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
