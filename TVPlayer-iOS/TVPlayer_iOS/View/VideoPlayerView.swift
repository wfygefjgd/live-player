import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import Combine

// MARK: - 窗口级全屏画面
//
// iPhone Air 反馈：仅「退后台再进」画面才正确。
// 根因：AVPlayerLayer 在首次横屏落稳前 frame/绑定是脏的；回前台会 rebind。
// 对策：hardRemount = 卸层 → 按物理横屏尺寸重挂 → player 置 nil 再绑回（等同回前台）。

final class WindowVideoSurface {
    static let shared = WindowVideoSurface()

    private let host = TouchThroughView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []
    private weak var boundPlayer: AVPlayer?
    private var displayLink: CADisplayLink?
    private var displayLinkTicks = 0
    private var lastSize: CGSize = .zero
    private var remountGeneration = 0

    private init() {
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.clipsToBounds = false
        host.layer.zPosition = -1_000

        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.isOpaque = true
        playerLayer.masksToBounds = false
        host.layer.addSublayer(playerLayer)

        setupNotifications()
        setupAudioSession()
    }

    private func setupNotifications() {
        let hardNames: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIScene.didActivateNotification,
            .tvPlayerHardRemount
        ]
        for name in hardNames {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.hardRemount(reason: name.rawValue) }
                .store(in: &cancellables)
        }
        let softNames: [Notification.Name] = [
            UIDevice.orientationDidChangeNotification,
            UIWindow.didBecomeKeyNotification,
            .tvPlayerNeedsRelayout
        ]
        for name in softNames {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.forceFullBleed(reason: name.rawValue) }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleInterruption(note) }
            .store(in: &cancellables)

        // 窗口坐标变化（横竖/分屏/Air 形态）
        NotificationCenter.default.publisher(for: UIScene.geometryDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.hardRemount(reason: "geometry")
            }
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
            hardRemount(reason: "interruptionEnded")
        @unknown default:
            break
        }
    }

    // MARK: - Player

    func setPlayer(_ player: AVPlayer?) {
        let changed = boundPlayer !== player
        boundPlayer = player
        if changed {
            hardRemount(reason: "setPlayer")
        } else {
            forceFullBleed(reason: "setPlayer-same")
            rebindPlayer()
        }
    }

    func rebindPlayer() {
        guard let p = boundPlayer else { return }
        if playerLayer.player !== p {
            playerLayer.player = p
        }
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        playerLayer.videoGravity = .resize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
        CATransaction.commit()
    }

    /// 等同「退后台再进」：卸掉 layer 宿主 → 按物理横屏尺寸重挂 → player 断绑再绑
    func hardRemount(reason: String = "") {
        remountGeneration &+= 1
        let gen = remountGeneration
        guard let window = Self.mainWindow() else {
            forceFullBleed(reason: "hard-no-window")
            return
        }

        // 1) 断开 player，避免脏 frame 粘在 layer 上
        let p = boundPlayer
        playerLayer.player = nil

        // 2) 卸下 host
        host.removeFromSuperview()

        // 3) 目标矩形：优先当前 window（回前台时 window 已正确）；否则物理横屏
        window.backgroundColor = .black
        window.clipsToBounds = false
        window.layoutIfNeeded()

        let target = Self.landscapeScreenRect(for: window)
        // 相对 window 铺满；若 window 仍偏小则用 target 外扩（盖满物理屏）
        let hostFrame: CGRect
        if window.bounds.width >= target.width - 1, window.bounds.height >= target.height - 1 {
            hostFrame = window.bounds
        } else {
            let ox = (window.bounds.width - target.width) / 2
            let oy = (window.bounds.height - target.height) / 2
            hostFrame = CGRect(x: ox, y: oy, width: target.width, height: target.height)
        }

        if let root = window.rootViewController {
            root.view.backgroundColor = .clear
            root.view.isOpaque = false
            root.view.clipsToBounds = false
            root.view.insetsLayoutMarginsFromSafeArea = false
            root.additionalSafeAreaInsets = .zero
            root.setNeedsUpdateOfHomeIndicatorAutoHidden()
            root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            root.setNeedsStatusBarAppearanceUpdate()
            root.view.setNeedsLayout()
            root.view.layoutIfNeeded()
        }

        // 4) 重挂 host 铺满
        host.frame = hostFrame
        host.bounds = CGRect(origin: .zero, size: hostFrame.size)
        host.backgroundColor = .black
        host.isHidden = false
        host.alpha = 1
        host.clipsToBounds = false
        host.layer.zPosition = -1_000
        window.insertSubview(host, at: 0)
        window.sendSubviewToBack(host)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()

        lastSize = host.bounds.size

        // 5) 下一 runloop 再绑 player（关键：模拟回前台时的 rebind 时机）
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remountGeneration == gen else { return }
            self.playerLayer.player = p ?? self.boundPlayer
            self.playerLayer.videoGravity = .resize
            self.playerLayer.frame = self.host.bounds
            self.playerLayer.isHidden = false
            self.playerLayer.opacity = 1
            if self.playerLayer.isReadyForDisplay, let pl = self.playerLayer.player {
                NotificationCenter.default.post(
                    name: Notification.Name("tvPlayerVideoRendered"),
                    object: pl
                )
            }
        }

        // 6) 随后几帧再钉（旋转/Air 动画未结束）
        for t in [0.05, 0.12, 0.28, 0.5, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, self.remountGeneration == gen else { return }
                self.forceFullBleed(reason: "hard-follow-\(t)")
                self.rebindPlayer()
            }
        }
    }

    func cleanup() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTicks = 0
    }

    deinit {
        cleanup()
        cancellables.removeAll()
    }

    func install(reason: String = "") {
        hardRemount(reason: reason)
    }

    func forceFullBleed(reason: String = "") {
        guard let window = Self.mainWindow() else { return }

        let target = Self.landscapeScreenRect(for: window)
        // 尺寸跳变（竖→横或 Air 安全区变化）→ 走 hardRemount
        if lastSize.width > 1, abs(lastSize.width - target.width) > 2 || abs(lastSize.height - target.height) > 2 {
            hardRemount(reason: "size-jump-\(reason)")
            return
        }

        window.backgroundColor = .black
        window.clipsToBounds = false

        if let root = window.rootViewController {
            root.view.backgroundColor = .clear
            root.view.isOpaque = false
            root.view.clipsToBounds = false
            root.view.insetsLayoutMarginsFromSafeArea = false
            root.setNeedsUpdateOfHomeIndicatorAutoHidden()
            root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            root.setNeedsStatusBarAppearanceUpdate()
        }

        host.layer.zPosition = -1_000
        if host.superview !== window {
            host.removeFromSuperview()
            window.insertSubview(host, at: 0)
        } else {
            window.sendSubviewToBack(host)
        }

        let rect = window.bounds
        guard rect.width > 1, rect.height > 1 else { return }

        host.isHidden = false
        host.alpha = 1
        host.backgroundColor = .black
        host.clipsToBounds = false
        host.isUserInteractionEnabled = false
        host.frame = rect
        host.bounds = CGRect(origin: .zero, size: rect.size)
        lastSize = rect.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        if playerLayer.player == nil {
            playerLayer.player = boundPlayer
        }
        CATransaction.commit()

        if playerLayer.isReadyForDisplay, let player = playerLayer.player {
            NotificationCenter.default.post(
                name: Notification.Name("tvPlayerVideoRendered"),
                object: player
            )
        }

        let heavy = reason.contains("active")
            || reason.contains("foreground")
            || reason.contains("appear")
            || reason.contains("setPlayer")
            || reason.contains("ready")
            || reason.contains("scene")
            || reason.contains("recover")
            || reason.contains("sim-fg")
            || reason.contains("hard")
        if heavy {
            schedulePasses()
            startBriefDisplayLink()
        }
    }

    func startBriefDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTicks = 0
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self), selector: #selector(DisplayLinkProxy.tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func onDisplayLinkTick() {
        displayLinkTicks += 1
        forceFullBleed(reason: "displayLink")
        rebindPlayer()
        if displayLinkTicks >= 60 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    func schedulePasses() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        for t in [0.0, 0.05, 0.15, 0.35, 0.7, 1.2] {
            let item = DispatchWorkItem { [weak self] in
                self?.forceFullBleed(reason: "delay-\(t)")
                self?.rebindPlayer()
            }
            delayItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
        }
    }

    /// 物理横屏全尺寸：宽=长边，高=短边（不读 safeArea）
    private static func landscapeScreenRect(for window: UIWindow) -> CGRect {
        let screen = window.windowScene?.screen ?? window.screen
        let b = screen.bounds
        let longSide = max(b.width, b.height)
        let shortSide = min(b.width, b.height)
        // window 已是横屏且与 screen 接近 → 用 window（与回前台一致）
        if window.bounds.width >= window.bounds.height,
           window.bounds.width > 100,
           abs(window.bounds.width - longSide) < 4 {
            return CGRect(origin: .zero, size: window.bounds.size)
        }
        return CGRect(x: 0, y: 0, width: longSide, height: shortSide)
    }

    private static func mainWindow() -> UIWindow? {
        if let app = UIApplication.shared.delegate as? AppDelegate, let w = app.window {
            return w
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            let normals = scene.windows.filter { $0.windowLevel <= .normal && !$0.isHidden }
            if let key = normals.first(where: \.isKeyWindow) { return key }
            if let first = normals.first { return first }
        }
        return scenes.flatMap(\.windows).first { $0.windowLevel <= .normal }
    }
}

private final class DisplayLinkProxy: NSObject {
    weak var owner: WindowVideoSurface?
    init(owner: WindowVideoSurface) { self.owner = owner }
    @objc func tick() { owner?.onDisplayLinkTick() }
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
        WindowVideoSurface.shared.hardRemount(reason: "anchor-window")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        WindowVideoSurface.shared.forceFullBleed(reason: "anchor-layout")
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
        WindowVideoSurface.shared.forceFullBleed(reason: "swiftui-update")
    }
}

// MARK: - 根容器

final class FullScreenRootController: UIViewController {
    private let hosted: UIViewController
    private var lastBounds: CGSize = .zero

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
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        OrientationBootstrap.allowedMask
    }

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
        WindowVideoSurface.shared.hardRemount(reason: "root-appear")
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
        // 出画前也按「回前台」节奏多钉几次
        for t in [0.2, 0.5, 1.0, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.refreshSystemChrome()
                WindowVideoSurface.shared.hardRemount(reason: "root-appear-\(t)")
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            WindowVideoSurface.shared.forceFullBleed(reason: "transition")
        }, completion: { _ in
            // 旋转结束 = 最接近「回前台」的时机
            WindowVideoSurface.shared.hardRemount(reason: "transition-end")
            OrientationBootstrap.simulateForegroundRecovery(reason: "transition-end")
        })
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        refreshSystemChrome()
        WindowVideoSurface.shared.hardRemount(reason: "safeArea")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let s = view.bounds.size
        if abs(s.width - lastBounds.width) > 1 || abs(s.height - lastBounds.height) > 1 {
            lastBounds = s
            WindowVideoSurface.shared.hardRemount(reason: "root-bounds-change")
        } else {
            WindowVideoSurface.shared.forceFullBleed(reason: "root-layout")
        }
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
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        OrientationBootstrap.allowedMask
    }

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
        WindowVideoSurface.shared.hardRemount(reason: "host-appear")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        WindowVideoSurface.shared.forceFullBleed(reason: "host-layout")
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
