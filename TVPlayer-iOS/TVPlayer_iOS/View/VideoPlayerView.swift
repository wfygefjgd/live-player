import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import Combine

// MARK: - 主窗最底层全屏画面（按用户方案）
//
// 1. 容器（window / root / SwiftUI）全部透明 —— 底下没有黑底挡画面
// 2. 画面 host 插在主 window 的 index 0（最低，但不低于容器）
// 3. host / playerLayer 铺满物理屏，不读 safeArea，不给小白条让位
// 4. 小白条是系统层，只能浮在上面；布局上不能再挤短画面

final class WindowVideoSurface {
    static let shared = WindowVideoSurface()

    private let host = TouchThroughView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private weak var boundPlayer: AVPlayer?
    private var isApplying = false

    private init() {
        // host 自身可以是黑的（只作为画面底板），但尺寸必须全屏
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        host.autoresizingMask = []
        host.clipsToBounds = false
        host.layer.zPosition = -10_000

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
                .sink { [weak self] _ in
                    self?.pinToBottomFullScreen(reason: name.rawValue)
                }
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
            pinToBottomFullScreen(reason: "interruptionEnded")
        @unknown default:
            break
        }
    }

    // MARK: - Public

    func setPlayer(_ player: AVPlayer?) {
        boundPlayer = player
        playerLayer.player = player
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        pinToBottomFullScreen(reason: "setPlayer")
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
        pinToBottomFullScreen(reason: reason)
    }

    func hardRemount(reason: String = "") {
        pinToBottomFullScreen(reason: reason)
        rebindPlayer()
    }

    func install(reason: String = "") {
        pinToBottomFullScreen(reason: reason)
    }

    // MARK: - 钉在主窗最底 + 全透明容器

    private func pinToBottomFullScreen(reason: String = "") {
        if isApplying { return }
        isApplying = true
        defer { isApplying = false }

        guard let window = Self.mainWindow() else { return }

        // —— 用户方案：容器全透明，底下不要黑底挡画面 ——
        window.backgroundColor = .clear
        window.isOpaque = false
        window.clipsToBounds = false

        if let root = window.rootViewController {
            makeFullyClear(root.view)
            root.additionalSafeAreaInsets = .zero
            root.view.insetsLayoutMarginsFromSafeArea = false
            // 把 root 子树里常见的黑底也清掉（不递归太深，避免卡）
            clearBlackBackgrounds(in: root.view, depth: 0)
            root.setNeedsUpdateOfHomeIndicatorAutoHidden()
            root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            root.setNeedsStatusBarAppearanceUpdate()
        }

        // —— 画面在容器最底层（index 0），不低于 window ——
        if host.superview !== window {
            host.removeFromSuperview()
            window.insertSubview(host, at: 0)
        } else {
            window.sendSubviewToBack(host)
        }
        host.layer.zPosition = -10_000

        // 物理全屏：不读 safeArea，可比 window.bounds 更大以盖住小白条区域
        let full = Self.physicalFullFrame(for: window)
        host.isHidden = false
        host.alpha = 1
        host.backgroundColor = .black
        host.clipsToBounds = false
        host.isUserInteractionEnabled = false
        host.frame = full
        host.bounds = CGRect(origin: .zero, size: full.size)

        applyLayerFrame()
        if playerLayer.player == nil {
            playerLayer.player = boundPlayer
        }
    }

    private func applyLayerFrame() {
        guard host.bounds.width > 1, host.bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 画面 = host 全大，不给底部留空
        playerLayer.frame = host.bounds
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()
    }

    private func makeFullyClear(_ view: UIView?) {
        guard let view else { return }
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
    }

    private func clearBlackBackgrounds(in view: UIView, depth: Int) {
        guard depth < 6 else { return }
        // 不改 host / 不改侧栏内容；只清主界面容器黑底
        if view === host { return }
        if let bg = view.backgroundColor, bg != .clear {
            // 纯黑/近黑 → 透明
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if bg.getRed(&r, green: &g, blue: &b, alpha: &a), r < 0.08, g < 0.08, b < 0.08, a > 0.5 {
                view.backgroundColor = .clear
                view.isOpaque = false
            }
        }
        for sub in view.subviews where sub !== host {
            clearBlackBackgrounds(in: sub, depth: depth + 1)
        }
    }

    /// 物理全屏 frame（相对 window）：横屏长边×短边，可略大于 window 以盖 Home Indicator
    private static func physicalFullFrame(for window: UIWindow) -> CGRect {
        let screen = window.windowScene?.screen ?? window.screen
        let native = screen.nativeBounds
        let scale = max(screen.scale, 1)
        var w = native.width / scale
        var h = native.height / scale
        if w < 1 || h < 1 {
            w = screen.bounds.width
            h = screen.bounds.height
        }
        // 横屏
        if w < h { swap(&w, &h) }
        let ww = window.bounds.width
        let wh = window.bounds.height
        if ww >= wh {
            w = max(w, ww)
            h = max(h, wh)
        } else {
            // window 仍是竖的瞬间：仍按横屏物理尺寸画，居中
            w = max(w, wh)
            h = max(h, ww)
        }
        let ox = (ww - w) / 2
        let oy = (wh - h) / 2
        return CGRect(x: ox, y: oy, width: w, height: h)
    }

    private static func mainWindow() -> UIWindow? {
        if let app = UIApplication.shared.delegate as? AppDelegate, let w = app.window {
            return w
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            let normals = scene.windows.filter {
                $0.windowLevel <= .normal && !$0.isHidden
            }
            if let key = normals.first(where: \.isKeyWindow) { return key }
            if let first = normals.first { return first }
        }
        return scenes.flatMap(\.windows).first { $0.windowLevel <= .normal }
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
        WindowVideoSurface.shared.setPlayer(vm.player.player)
        return v
    }

    func updateUIView(_ uiView: PlayerAnchorView, context: Context) {
        WindowVideoSurface.shared.setPlayer(vm.player.player)
        _ = vm.playerLayoutEpoch
    }
}

// MARK: - 零 Safe Area 容器 View（用户：被挤的是容器，不是画面）

/// 强制 safeAreaInsets = 0，容器可沉到物理底边，不给 Home Indicator 留位
final class SinkContainerView: UIView {
    override var safeAreaInsets: UIEdgeInsets { .zero }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
        insetsLayoutMarginsFromSafeArea = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 容器下沉：frame 钉死 window.bounds（物理全屏）
private func sinkContainerFrame(_ view: UIView) {
    guard let window = view.window else { return }
    let target = window.bounds
    guard target.width > 1, target.height > 1 else { return }
    if view.frame.size != target.size || abs(view.frame.origin.x) > 0.5 || abs(view.frame.origin.y) > 0.5 {
        view.frame = target
        view.bounds = CGRect(origin: .zero, size: target.size)
    }
    window.backgroundColor = .clear
    window.isOpaque = false
}

// MARK: - 主 UI 根：容器下沉到最底

final class FullScreenRootController: UIViewController {
    private let hosted: UIViewController

    init(hosting: UIViewController) {
        self.hosted = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 用零 safeArea 的容器 view，而不是系统默认 UIView
    override func loadView() {
        view = SinkContainerView(frame: UIScreen.main.bounds)
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
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        view.insetsLayoutMarginsFromSafeArea = false

        addChild(hosted)
        hosted.view.translatesAutoresizingMaskIntoConstraints = true
        hosted.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosted.view.backgroundColor = .clear
        hosted.view.isOpaque = false
        hosted.view.frame = view.bounds
        view.addSubview(hosted.view)
        hosted.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sinkSelf()
        refreshSystemChrome()
        WindowVideoSurface.shared.forceFullBleed(reason: "root-appear")
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.sinkSelf()
            WindowVideoSurface.shared.forceFullBleed(reason: "transition")
        }, completion: { _ in
            self.sinkSelf()
            WindowVideoSurface.shared.forceFullBleed(reason: "transition-end")
        })
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // 系统 inset 变化：容器再下沉（SinkContainerView 已强制 insets=0）
        sinkSelf()
        refreshSystemChrome()
        WindowVideoSurface.shared.forceFullBleed(reason: "safeArea")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sinkSelf()
        hosted.view.frame = view.bounds
        WindowVideoSurface.shared.forceFullBleed(reason: "root-layout")
    }

    private func sinkSelf() {
        // 容器下沉到 window 最底铺满（不依赖负 additionalSafeArea，避免震荡）
        additionalSafeAreaInsets = .zero
        sinkContainerFrame(view)
        if let window = view.window, window.rootViewController === self {
            view.frame = window.bounds
            view.bounds = CGRect(origin: .zero, size: window.bounds.size)
        }
        hosted.view.frame = view.bounds
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
        if let superview = view.superview {
            view.frame = superview.bounds
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
        WindowVideoSurface.shared.forceFullBleed(reason: "host-appear")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let superview = view.superview {
            view.frame = superview.bounds
        }
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
