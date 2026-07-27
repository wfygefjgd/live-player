import SwiftUI
import AVKit
import UIKit
import MediaPlayer

// =============================================================================
// v1.5.57：画面脱离 SwiftUI 布局
//
// 现象 1+4：中间小框四周黑 + 小白条顶起
// 根因：VideoPlayerView 在 SwiftUI/Hosting 安全区内，被缩成中间卡片
//
// 做法：
// - PlayerSurfaceView 钉在 FullScreenRootController.view 底层四边
// - Hosting / ContentView 全透明，只叠手势与 OSD
// - 视频不读 safe area，小白条只能浮在上面
// - resizeAspect：完整画面，只允许两边比例黑边
// =============================================================================

// MARK: - 根容器：系统 safe area 不参与布局

final class SinkContainerView: UIView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

// MARK: - AVPlayer 画面层

final class PlayerSurfaceView: UIView {
    private var boundPlayer: AVPlayer?

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        isUserInteractionEnabled = false
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
        WindowVideoSurface.shared.publishDebugSnapshot()
    }

    func debugSnapshot() -> String {
        let b = bounds.integral
        let vr = playerLayer.videoRect.integral
        return "surface \(Int(b.width))x\(Int(b.height)) videoRect \(Int(vr.width))x\(Int(vr.height)) @(\(Int(vr.minX)),\(Int(vr.minY)))"
    }
}

// MARK: - 全局画面宿主（钉在 root 底层，不进 SwiftUI）

final class WindowVideoSurface {
    static let shared = WindowVideoSurface()
    static let debugDidChange = Notification.Name("WindowVideoSurface.debugDidChange")

    private(set) var surface: PlayerSurfaceView?
    private weak var container: UIView?
    private var boundPlayer: AVPlayer?
    private(set) var debugText: String = ""

    private init() {}

    private func layoutSurface(in container: UIView) {
        guard let surface else { return }
        let target = ScreenGeometry.physicalLandscapeBounds(for: container.window?.windowScene)
        let size: CGSize
        if target.width > 1, target.height > 1 {
            size = target.size
        } else {
            size = container.bounds.size
        }
        surface.frame = CGRect(
            x: (container.bounds.width - size.width) / 2,
            y: (container.bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        publishDebugSnapshot()
    }

    /// 安装到 root 容器底层，直接按物理横屏尺寸铺开，避免被上层布局压成中间小框
    func install(in container: UIView) {
        self.container = container
        let surface: PlayerSurfaceView
        if let existing = self.surface {
            surface = existing
        } else {
            surface = PlayerSurfaceView(frame: container.bounds)
            self.surface = surface
        }

        if surface.superview !== container {
            surface.removeFromSuperview()
            surface.translatesAutoresizingMaskIntoConstraints = true
            surface.autoresizingMask = []
            container.insertSubview(surface, at: 0)
        } else {
            container.sendSubviewToBack(surface)
        }

        layoutSurface(in: container)

        if let p = boundPlayer {
            surface.setPlayer(p)
        }
    }

    func setPlayer(_ player: AVPlayer?) {
        boundPlayer = player
        if let surface {
            surface.setPlayer(player)
        } else if let container {
            install(in: container)
            surface?.setPlayer(player)
        }
    }

    func rebindPlayer() {
        if let container, surface?.superview !== container {
            install(in: container)
        }
        if let container {
            layoutSurface(in: container)
        }
        if let p = boundPlayer {
            surface?.setPlayer(p)
        } else {
            surface?.rebind()
        }
        // 确保在最底
        if let surface, let container = surface.superview {
            container.sendSubviewToBack(surface)
        }
    }

    func forceFullBleed(reason: String = "") { rebindPlayer() }
    func hardRemount(reason: String = "") { rebindPlayer() }
    func install(reason: String = "") {
        if let container { install(in: container) }
    }
    func refreshLayout() {
        if let container {
            layoutSurface(in: container)
        }
    }

    func publishDebugSnapshot() {
        let containerText: String
        if let container {
            let cb = container.bounds.integral
            let wb = container.window?.bounds.integral ?? .zero
            containerText = "window \(Int(wb.width))x\(Int(wb.height)) root \(Int(cb.width))x\(Int(cb.height))"
        } else {
            containerText = "window ?x? root ?x?"
        }
        let surfaceText = surface?.debugSnapshot() ?? "surface nil"
        debugText = "\(containerText)\n\(surfaceText)"
        NotificationCenter.default.post(name: Self.debugDidChange, object: debugText)
    }
}

// MARK: - SwiftUI：仅绑定 player，不承载画面尺寸

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        WindowVideoSurface.shared.setPlayer(vm.player.player)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        WindowVideoSurface.shared.setPlayer(vm.player.player)
        _ = vm.playerLayoutEpoch
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
        // 透明：让底层视频露出来；视频层自己是黑底
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true

        // 1) 视频钉 root 底层
        WindowVideoSurface.shared.install(in: view)

        // 2) SwiftUI 叠在上面（透明）
        addChild(hosted)
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        hosted.view.backgroundColor = .clear
        hosted.view.isOpaque = false
        hosted.view.clipsToBounds = false
        view.addSubview(hosted.view)
        NSLayoutConstraint.activate([
            hosted.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosted.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosted.didMove(toParent: self)

        if let surface = WindowVideoSurface.shared.surface {
            view.sendSubviewToBack(surface)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        WindowVideoSurface.shared.refreshLayout()
        if let surface = WindowVideoSurface.shared.surface {
            view.sendSubviewToBack(surface)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        WindowVideoSurface.shared.rebindPlayer()
        refreshSystemChrome()
    }

    func forcePhysicalFullScreen() {
        WindowVideoSurface.shared.rebindPlayer()
        refreshSystemChrome()
    }

    func refreshSystemChrome() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
    }
}

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

// MARK: - UIHostingController（透明叠层）

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
        view.backgroundColor = .clear
        view.isOpaque = false
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
