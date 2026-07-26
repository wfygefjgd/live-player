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
        // 保持原比例，不裁切、不拉伸
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
        // layerClass=AVPlayerLayer：layer 即 self.layer，尺寸随 view.bounds，勿改 layer.frame
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

// MARK: - SwiftUI：.ignoresSafeArea() 贴满物理屏

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let v = PlayerSurfaceView()
        // 允许在 SwiftUI 布局中横向/纵向完全拉伸铺满
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

    // 不声明固定 intrinsic size，交给父级 .frame(maxWidth/maxHeight: .infinity)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlayerSurfaceView, context: Context) -> CGSize? {
        let w = proposal.width ?? UIScreen.main.bounds.width
        let h = proposal.height ?? UIScreen.main.bounds.height
        return CGSize(width: w, height: h)
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
        view.clipsToBounds = false
        // 解除系统圆角/限高限宽对子树的裁剪影响
        additionalSafeAreaInsets = .zero

        // 内容延伸到系统栏后面（不要用 safeAreaLayoutGuide 包播放器）
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true

        addChild(hosted)
        // 用 frame 布局，避免 Auto Layout 被 safe area 约束带偏
        hosted.view.translatesAutoresizingMaskIntoConstraints = true
        hosted.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosted.view.backgroundColor = .black
        hosted.view.clipsToBounds = false
        view.addSubview(hosted.view)
        hosted.view.frame = view.bounds
        hosted.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        forcePhysicalFullScreen()
        refreshSystemChrome()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        forcePhysicalFullScreen()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // 拒绝系统 inset 把根容器挤成中间小框
        additionalSafeAreaInsets = .zero
        forcePhysicalFullScreen()
    }

    /// 横屏下强制 window / root / host 等于物理全屏尺寸
    func forcePhysicalFullScreen() {
        let target = ScreenGeometry.physicalLandscapeBounds(for: view.window?.windowScene)
        if let window = view.window, window.bounds.size != target.size || window.frame.origin != .zero {
            window.frame = target
        }
        if view.bounds.size != target.size {
            view.frame = CGRect(origin: .zero, size: target.size)
            view.bounds = CGRect(origin: .zero, size: target.size)
        }
        hosted.view.frame = view.bounds
        hosted.view.bounds = CGRect(origin: .zero, size: view.bounds.size)
        additionalSafeAreaInsets = .zero
        if let hosting = hosted as? UIHostingController<AnyView> {
            hosting.additionalSafeAreaInsets = .zero
        }
        hosted.additionalSafeAreaInsets = .zero
    }

    func refreshSystemChrome() {
        forcePhysicalFullScreen()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
    }
}

/// 物理横屏全屏几何：解除 portrait bounds / scene 未旋转导致的中间小框
enum ScreenGeometry {
    static func physicalLandscapeBounds(for scene: UIWindowScene?) -> CGRect {
        if let scene {
            let b = scene.coordinateSpace.bounds
            // scene bounds 已是当前方向；保证宽>=高（横屏）
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
        view.clipsToBounds = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        additionalSafeAreaInsets = .zero
        // iOS 16.4+：不让 Hosting 把 safe area 强加给 SwiftUI 内容
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 根 Hosting 强行等于父视图物理全屏，解除中间圆角限宽框
        if let superview = view.superview {
            let target = superview.bounds
            if view.frame != target {
                view.frame = target
            }
        } else {
            let target = ScreenGeometry.physicalLandscapeBounds(for: view.window?.windowScene)
            view.frame = target
        }
        additionalSafeAreaInsets = .zero
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        additionalSafeAreaInsets = .zero
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        additionalSafeAreaInsets = .zero
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
