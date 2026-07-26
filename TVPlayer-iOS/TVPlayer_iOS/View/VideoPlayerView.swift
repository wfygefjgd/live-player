import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import Combine

// MARK: - 独立底层 Video Window
//
// 小白条是系统层，App 内 zPosition 无法压过它；但可以把画面放到
// 「比主 UI 更低的独立 UIWindow」里，铺满物理屏，与主窗 safeArea 完全脱钩。
// 主窗透明只负责手势/UI；画面在另一层，不会被小白条「挤布局」。

final class WindowVideoSurface {
    static let shared = WindowVideoSurface()

    /// 专用画面窗：level 低于主窗，永不 makeKey
    private var videoWindow: UIWindow?
    private let host = TouchThroughView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private weak var boundPlayer: AVPlayer?
    private var isApplying = false

    private init() {
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.clipsToBounds = false

        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.isOpaque = true
        playerLayer.masksToBounds = false
        host.layer.addSublayer(playerLayer)

        setupNotifications()
        setupAudioSession()
    }

    private func setupNotifications() {
        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIDevice.orientationDidChangeNotification,
            UIWindow.didBecomeKeyNotification,
            UIScene.didActivateNotification,
            .tvPlayerNeedsRelayout
        ]
        for name in names {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.ensureVideoWindow(reason: name.rawValue) }
                .store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleInterruption(note) }
            .store(in: &cancellables)
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            NotificationCenter.default.post(name: .tvPlayerInterruptionBegan, object: nil)
        case .ended:
            let should = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            if should {
                NotificationCenter.default.post(name: .tvPlayerInterruptionEnded, object: nil)
            }
            rebindPlayer()
            ensureVideoWindow(reason: "interruptionEnded")
        @unknown default:
            break
        }
    }

    // MARK: - Public API（兼容旧调用名）

    func setPlayer(_ player: AVPlayer?) {
        boundPlayer = player
        playerLayer.player = player
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        ensureVideoWindow(reason: "setPlayer")
    }

    func rebindPlayer() {
        guard let p = boundPlayer else { return }
        if playerLayer.player !== p {
            playerLayer.player = p
        }
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        playerLayer.videoGravity = .resize
        applyLayerFrame()
    }

    func forceFullBleed(reason: String = "") {
        ensureVideoWindow(reason: reason)
    }

    func hardRemount(reason: String = "") {
        ensureVideoWindow(reason: reason)
        rebindPlayer()
    }

    func install(reason: String = "") {
        ensureVideoWindow(reason: reason)
    }

    // MARK: - 独立 Video Window

    private func ensureVideoWindow(reason: String = "") {
        if isApplying { return }
        isApplying = true
        defer { isApplying = false }

        guard let scene = Self.activeScene() else { return }
        let screen = scene.screen
        let full = Self.physicalLandscapeFrame(screen: screen, scene: scene)

        let win: UIWindow
        if let existing = videoWindow, existing.windowScene === scene {
            win = existing
        } else {
            let created = UIWindow(windowScene: scene)
            // 比主窗低一层：主窗 UI/手势在上，画面在下
            created.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
            created.backgroundColor = .black
            created.isUserInteractionEnabled = false
            created.clipsToBounds = false
            // 空 root，不参与 safeArea 布局链
            let root = VideoWindowRootController()
            root.view.backgroundColor = .black
            created.rootViewController = root
            videoWindow = created
            win = created
        }

        // 永远铺满物理横屏，不读 safeArea
        win.frame = full
        win.bounds = CGRect(origin: .zero, size: full.size)
        win.isHidden = false
        // 绝不 makeKey — 主窗保持 key，小白条策略仍由主 root 控制

        if let rootView = win.rootViewController?.view {
            rootView.frame = win.bounds
            rootView.backgroundColor = .black
            if host.superview !== rootView {
                host.removeFromSuperview()
                rootView.addSubview(host)
            }
        } else if host.superview !== win {
            host.removeFromSuperview()
            win.addSubview(host)
        }

        host.frame = win.bounds
        host.bounds = CGRect(origin: .zero, size: win.bounds.size)
        host.isHidden = false
        host.alpha = 1
        host.backgroundColor = .black

        applyLayerFrame()
        if playerLayer.player == nil {
            playerLayer.player = boundPlayer
        }

        // 主窗保持透明，露出底层 video window
        if let app = UIApplication.shared.delegate as? AppDelegate {
            app.window?.backgroundColor = .clear
            app.window?.isOpaque = false
            app.window?.rootViewController?.view.backgroundColor = .clear
            app.window?.rootViewController?.view.isOpaque = false
            // 确保主窗仍在 video 之上且为 key
            if let main = app.window, !main.isKeyWindow {
                main.makeKeyAndVisible()
            }
            // 主窗 level 正常
            app.window?.windowLevel = .normal
        }
    }

    private func applyLayerFrame() {
        let bounds = host.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()
    }

    /// 物理横屏全屏矩形（scene/screen），不吃 safeArea
    private static func physicalLandscapeFrame(screen: UIScreen, scene: UIWindowScene) -> CGRect {
        let native = screen.nativeBounds
        let scale = max(screen.scale, 1)
        var w = native.width / scale
        var h = native.height / scale
        if w < 1 || h < 1 {
            let b = screen.bounds
            w = b.width
            h = b.height
        }
        if w < h { swap(&w, &h) }
        // 与 scene 坐标对齐：取横屏
        let coord = scene.coordinateSpace.bounds
        let cw = max(coord.width, coord.height)
        let ch = min(coord.width, coord.height)
        w = max(w, cw)
        h = max(h, ch)
        return CGRect(x: 0, y: 0, width: w, height: h)
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// Video window 的 root：不声明复杂策略，只铺黑底
private final class VideoWindowRootController: UIViewController {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        additionalSafeAreaInsets = .zero
        view.insetsLayoutMarginsFromSafeArea = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 不在这里动 player，避免递归；由 ensureVideoWindow 统一钉
    }
}

private final class TouchThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

final class PlayerAnchorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        WindowVideoSurface.shared.forceFullBleed(reason: "anchor-window")
    }
}

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> PlayerAnchorView {
        let v = PlayerAnchorView()
        // 锚点只负责触发；真实画面在独立 video window
        WindowVideoSurface.shared.setPlayer(vm.player.player)
        return v
    }

    func updateUIView(_ uiView: PlayerAnchorView, context: Context) {
        WindowVideoSurface.shared.setPlayer(vm.player.player)
        _ = vm.playerLayoutEpoch
    }
}

// MARK: - 主 UI 根容器（透明，露出底层 video window）

final class FullScreenRootController: UIViewController {
    private let hosted: UIViewController

    init(hosting: UIViewController) {
        self.hosted = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        // 主窗必须透明，否则挡住底层 video window
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        additionalSafeAreaInsets = .zero
        view.insetsLayoutMarginsFromSafeArea = false

        addChild(hosted)
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        hosted.view.backgroundColor = .clear
        hosted.view.isOpaque = false
        view.addSubview(hosted.view)
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
        WindowVideoSurface.shared.forceFullBleed(reason: "root-appear")
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            WindowVideoSurface.shared.forceFullBleed(reason: "transition")
        }, completion: { _ in
            WindowVideoSurface.shared.forceFullBleed(reason: "transition-end")
        })
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // 主窗 safeArea 变化与 video window 无关；仍刷新 chrome + 钉 video 窗
        refreshSystemChrome()
        WindowVideoSurface.shared.forceFullBleed(reason: "safeArea")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        WindowVideoSurface.shared.forceFullBleed(reason: "root-layout")
    }

    func refreshSystemChrome() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
    }
}

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
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        additionalSafeAreaInsets = .zero
        view.insetsLayoutMarginsFromSafeArea = false
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
        WindowVideoSurface.shared.forceFullBleed(reason: "host-appear")
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
    static let tvPlayerHardRemount = Notification.Name("tvPlayerHardRemount")
}
