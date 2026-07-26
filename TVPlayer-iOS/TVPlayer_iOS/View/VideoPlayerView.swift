import SwiftUI
import AVKit
import UIKit
import MediaPlayer

// =============================================================================
// Edge-to-Edge 全屏播放（标准写法）
//
// 目标：
// - 播放器视图贴紧物理屏幕，不限制在 Safe Area 内
// - Home Indicator 半透明浮在视频上方，不把画面挤上去
// - 自动隐藏 / 淡化状态栏与 Home Indicator
//
// UIKit 要点：
//   edgesForExtendedLayout = .all
//   prefersHomeIndicatorAutoHidden = true
//   prefersStatusBarHidden = true
//   preferredScreenEdgesDeferringSystemGestures = .all
//   约束钉 view 四边，不要用 safeAreaLayoutGuide
//
// SwiftUI 要点：
//   视频层 .ignoresSafeArea(.all) / .ignoresSafeArea()
//   .statusBarHidden(true)
//   .persistentSystemOverlays(.hidden)
//   .defersSystemGestures(on: .all)
//   仅浮动控制栏可用 safeAreaInsets 抬高，视频本身不要
// =============================================================================

// MARK: - UIKit：铺满 bounds 的 AVPlayer 层（不读 Safe Area）

final class PlayerSurfaceView: UIView {
    private var boundPlayer: AVPlayer?

    /// UIKit 标准：view.layer 直接是 AVPlayerLayer，layout 时自然铺满 bounds
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPlayer(_ player: AVPlayer?) {
        boundPlayer = player
        playerLayer.player = player
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        playerLayer.videoGravity = .resize
        setNeedsLayout()
    }

    func rebind() {
        guard let p = boundPlayer else { return }
        if playerLayer.player !== p { playerLayer.player = p }
        playerLayer.videoGravity = .resize
        // layer 随 bounds 自动布局；无需按 safeArea 缩 frame
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.videoGravity = .resize
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

// MARK: - SwiftUI：.ignoresSafeArea() 贴满物理屏

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

// MARK: - UIKit 根控制器（标准 Edge-to-Edge）

final class FullScreenRootController: UIViewController {
    private let hosted: UIViewController

    init(hosting: UIViewController) {
        self.hosted = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // —— 隐藏 / 自动淡化 Home Indicator（小白条）——
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // 延迟边缘手势，减少与小白条冲突
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    // —— 隐藏状态栏 ——
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // 自身决定策略，不转发给子 VC
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = true

        // 内容延伸到系统栏后面（不要用 safeAreaLayoutGuide 包播放器）
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true

        addChild(hosted)
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        hosted.view.backgroundColor = .black
        view.addSubview(hosted.view)

        // 钉死物理四边 = Edge-to-Edge（禁止 safeAreaLayoutGuide）
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 保证子树仍铺满，不被系统临时 inset 带偏
        hosted.view.frame = view.bounds
    }

    func refreshSystemChrome() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
    }
}

// MARK: - UIHostingController（SwiftUI 宿主同样声明全屏策略）

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
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        // iOS 16.4+：不让 Hosting 把 safe area 强加给 SwiftUI 内容
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
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
