import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import Combine

// MARK: - 强力全屏画面层（覆盖 Home Indicator / 小白条）

/// 画面钉在 keyWindow 最底层，frame 强制为物理屏幕尺寸（可溢出 window，盖住小白条）。
/// 手势仍由上层 SwiftUI 接收；侧边栏 WindowPanelSurface 保持更高 zPosition。
final class WindowVideoSurface {
    static let shared = WindowVideoSurface()

    private let host = TouchThroughView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []
    private weak var boundPlayer: AVPlayer?
    private var displayLink: CADisplayLink?
    private var displayLinkTicks = 0
    private var lastAppliedSize: CGSize = .zero
    private var keepAliveTimer: Timer?

    private init() {
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        host.autoresizingMask = []
        host.clipsToBounds = false
        host.layer.zPosition = -1_000
        // 强制拉伸铺满整屏（允许变形，无黑边、不按比例裁切）
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.isOpaque = true
        playerLayer.masksToBounds = false
        host.layer.addSublayer(playerLayer)

        setupNotifications()
        setupAudioSession()
        startKeepAlive()
    }

    private func setupNotifications() {
        let notes: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didFinishLaunchingNotification,
            UIDevice.orientationDidChangeNotification,
            UIWindow.didBecomeKeyNotification,
            UIScene.didActivateNotification,
            .tvPlayerNeedsRelayout
        ]
        for name in notes {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.forceFullBleed(reason: name.rawValue)
                }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.forceFullBleed(reason: "routeChange") }
            .store(in: &cancellables)

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
            forceFullBleed(reason: "interruptionEnded")
            rebindPlayer()
        @unknown default:
            break
        }
    }

    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.forceFullBleed(reason: "keepalive")
        }
        if let t = keepAliveTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    // MARK: - Player

    func setPlayer(_ player: AVPlayer?) {
        boundPlayer = player
        playerLayer.player = player
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        forceFullBleed(reason: "setPlayer")
        schedulePasses()
        startBriefDisplayLink()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.rebindPlayer()
            self?.forceFullBleed(reason: "setPlayer-rebind")
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
        playerLayer.setNeedsDisplay()
        host.setNeedsLayout()
        host.layoutIfNeeded()
        // 画面高度 = host 高度 - 底部外扩黑边（盖小白条），禁止居中偏移
        let bottomPad: CGFloat = 34
        let videoH = max(host.bounds.height - bottomPad, lastAppliedSize.height > 1 ? lastAppliedSize.height - bottomPad : host.bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = CGRect(x: 0, y: 0, width: host.bounds.width, height: videoH)
        playerLayer.videoGravity = .resize
        CATransaction.commit()
    }

    func cleanup() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTicks = 0
    }

    deinit {
        keepAliveTimer?.invalidate()
        cleanup()
        cancellables.removeAll()
    }

    func install(reason: String = "") {
        forceFullBleed(reason: reason)
    }

    // MARK: - 强力全屏

    func forceFullBleed(reason: String = "") {
        guard let window = Self.keyWindow() else { return }

        window.backgroundColor = .black
        window.clipsToBounds = false

        if let root = window.rootViewController {
            root.view.backgroundColor = .clear
            root.view.isOpaque = false
            root.view.clipsToBounds = false
            if #available(iOS 11.0, *) {
                root.view.insetsLayoutMarginsFromSafeArea = false
            }
            // 禁止负向 additionalSafeArea 震荡；画面走物理屏，不依赖 UIKit safe area
            if root.additionalSafeAreaInsets != .zero {
                root.additionalSafeAreaInsets = .zero
            }
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

        // 物理屏 + 底部外扩，确保盖住 Home Indicator 区域（条若短暂出现也压在画面下）
        var bleed = Self.physicalScreenRect(for: window)
        let bottomPad: CGFloat = 34
        bleed.size.height += bottomPad
        guard bleed.width > 1, bleed.height > 1 else { return }
        let ox = (window.bounds.width - bleed.width) / 2
        // 顶部对齐，底部多伸出盖小白条
        let oy = (window.bounds.height - (bleed.height - bottomPad)) / 2

        host.isHidden = false
        host.alpha = 1
        host.backgroundColor = .black
        host.clipsToBounds = false
        host.isUserInteractionEnabled = false
        host.frame = CGRect(x: ox, y: oy, width: bleed.width, height: bleed.height)
        host.bounds = CGRect(origin: .zero, size: bleed.size)

        lastAppliedSize = bleed.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 画面仍铺满「逻辑全屏」高度（不含 bottomPad 的可视区），黑底外扩盖白条
        let videoH = max(bleed.height - bottomPad, window.bounds.height)
        playerLayer.frame = CGRect(x: 0, y: 0, width: bleed.width, height: videoH)
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
            || reason.contains("orientation")
            || reason.contains("launch")
            || reason.contains("ready")
            || reason.contains("recover")
        if heavy {
            schedulePasses()
            startBriefDisplayLink()
            rebindPlayer()
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
        if displayLinkTicks >= 90 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    func schedulePasses() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        for t in [0.0, 0.02, 0.05, 0.1, 0.2, 0.35, 0.5, 0.8, 1.2, 1.8, 2.5, 3.5] {
            let item = DispatchWorkItem { [weak self] in
                self?.forceFullBleed(reason: "delay-\(t)")
                self?.rebindPlayer()
            }
            delayItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
        }
    }

    /// 物理屏幕横屏全尺寸（nativeBounds 换算），无视 safeArea
    private static func physicalScreenRect(for window: UIWindow) -> CGRect {
        let screen = window.windowScene?.screen ?? window.screen
        let sb = screen.bounds
        let native = screen.nativeBounds
        let scale = max(screen.scale, 1)
        var w = native.width / scale
        var h = native.height / scale
        if w < 1 || h < 1 {
            w = sb.width
            h = sb.height
        }
        // 与当前 window 方向对齐（横屏：宽>高）
        let landscape = window.bounds.width >= window.bounds.height
        if landscape && w < h { swap(&w, &h) }
        if !landscape && h < w { swap(&w, &h) }
        let finalW = max(w, window.bounds.width, sb.width)
        let finalH = max(h, window.bounds.height, sb.height)
        return CGRect(x: 0, y: 0, width: finalW, height: finalH)
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let w = scene.windows.first(where: \.isKeyWindow) { return w }
            if let w = scene.windows.first { return w }
        }
        return scenes.flatMap(\.windows).first
    }
}

private final class DisplayLinkProxy: NSObject {
    weak var owner: WindowVideoSurface?
    init(owner: WindowVideoSurface) { self.owner = owner }
    @objc func tick() { owner?.onDisplayLinkTick() }
}

private final class TouchThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    // 不在 layout 里把 AVPlayerLayer 撑满 bounds（会破坏「只拉伸不外扩裁切」）
    override func layoutSubviews() {
        super.layoutSubviews()
    }
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

/// 纯 UIKit 根容器：Home Indicator / 状态栏策略由它说了算。
/// UIHostingController 作子 VC 时，系统常去问 hosting 内部子节点，导致小白条不隐藏。
final class FullScreenRootController: UIViewController {
    private let hosted: UIViewController
    private var indicatorPulse: Timer?

    init(hosting: UIViewController) {
        self.hosted = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var shouldAutorotate: Bool { false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // 关键：不要把策略下发给 hosting 子 VC
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
        if #available(iOS 11.0, *) {
            view.insetsLayoutMarginsFromSafeArea = false
        }

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
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
        startIndicatorPulse()
        for t in [0.05, 0.15, 0.3, 0.6, 1.0, 2.0, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.refreshSystemChrome()
                WindowVideoSurface.shared.forceFullBleed(reason: "root-appear-delay")
                WindowVideoSurface.shared.rebindPlayer()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        indicatorPulse?.invalidate()
        indicatorPulse = nil
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        additionalSafeAreaInsets = .zero
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

    /// 定期提醒系统刷新小白条策略（回前台/手势后系统常会把条拉回来）
    private func startIndicatorPulse() {
        indicatorPulse?.invalidate()
        indicatorPulse = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshSystemChrome()
        }
        if let t = indicatorPulse {
            RunLoop.main.add(t, forMode: .common)
        }
    }
}

/// Hosting 本身也声明隐藏；真正生效靠外层 FullScreenRootController
final class RootHostingController<Content: View>: UIHostingController<Content> {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var shouldAutorotate: Bool { false }
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
        if #available(iOS 11.0, *) {
            view.insetsLayoutMarginsFromSafeArea = false
        }
        // 阻止 SwiftUI safe area 把内容往上顶
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

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        additionalSafeAreaInsets = .zero
        WindowVideoSurface.shared.forceFullBleed(reason: "host-safeArea")
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
}
