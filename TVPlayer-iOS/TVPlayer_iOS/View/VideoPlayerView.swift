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
        // 等比铺满，避免 .resize 拉伸变形
        playerLayer.videoGravity = .resizeAspectFill
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
        playerLayer.videoGravity = .resizeAspectFill
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
        playerLayer.setNeedsDisplay()
        host.setNeedsLayout()
        host.layoutIfNeeded()
        // 再钉一次 frame，防止 layer 卡在旧 bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
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

        let full = Self.physicalScreenRect(for: window)

        window.backgroundColor = .black
        window.clipsToBounds = false

        if let root = window.rootViewController {
            root.view.backgroundColor = .clear
            root.view.isOpaque = false
            root.view.clipsToBounds = false
            if #available(iOS 11.0, *) {
                root.view.insetsLayoutMarginsFromSafeArea = false
            }
            // 负向 additionalSafeArea：把系统 inset 顶掉，布局可延伸进小白条
            let si = root.view.safeAreaInsets
            let neg = UIEdgeInsets(top: -si.top, left: -si.left, bottom: -si.bottom, right: -si.right)
            if root.additionalSafeAreaInsets != neg {
                root.additionalSafeAreaInsets = neg
            }
            root.setNeedsUpdateOfHomeIndicatorAutoHidden()
            root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            root.setNeedsStatusBarAppearanceUpdate()
        }

        // 挂到 keyWindow 最底层；zPosition 低于 panel
        host.layer.zPosition = -1_000
        if host.superview !== window {
            host.removeFromSuperview()
            window.insertSubview(host, at: 0)
        } else {
            window.sendSubviewToBack(host)
        }

        // 强制物理全屏：可大于 window.bounds，盖住 Home Indicator 区域
        host.isHidden = false
        host.alpha = 1
        host.backgroundColor = .black
        host.clipsToBounds = false
        host.isUserInteractionEnabled = false
        host.frame = full
        host.bounds = CGRect(origin: .zero, size: full.size)
        // 若 window 原点与 screen 不一致，仍对齐到 (0,0) 物理坐标
        if window.bounds != full {
            // 把 host 中心对齐到屏幕中心在 window 坐标系下的位置
            let screen = window.windowScene?.screen ?? window.screen
            let screenOriginInWindow = window.convert(CGPoint.zero, from: screen.coordinateSpace)
            // convert from screen may fail on older API — fallback center
            if full.width > window.bounds.width + 1 || full.height > window.bounds.height + 1 {
                host.center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
                host.bounds = CGRect(origin: .zero, size: full.size)
            } else {
                host.frame = CGRect(origin: .zero, size: full.size)
            }
            _ = screenOriginInWindow
        }

        lastAppliedSize = full.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        if playerLayer.player == nil {
            playerLayer.player = boundPlayer
        }
        CATransaction.commit()

        WindowPanelSurface.shared.ensureOnTop()

        let heavy = reason.contains("active")
            || reason.contains("foreground")
            || reason.contains("appear")
            || reason.contains("setPlayer")
            || reason.contains("orientation")
            || reason.contains("launch")
            || reason.contains("ready")
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
        // 仅横屏：长边为宽
        let lw = max(w, h)
        let lh = min(w, h)
        // 至少不小于 window
        let finalW = max(lw, window.bounds.width)
        let finalH = max(lh, window.bounds.height)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        if let layer = layer.sublayers?.compactMap({ $0 as? AVPlayerLayer }).first {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = bounds
            CATransaction.commit()
        }
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

/// 主界面 Hosting：强制隐藏 Home Indicator，负向 safeArea 吃掉小白条
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
        if #available(iOS 11.0, *) {
            view.insetsLayoutMarginsFromSafeArea = false
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
        applyZeroSafeArea()
        WindowVideoSurface.shared.forceFullBleed(reason: "host-appear")
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
        for t in [0.05, 0.15, 0.3, 0.6, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.applyZeroSafeArea()
                WindowVideoSurface.shared.forceFullBleed(reason: "host-appear-delay")
                WindowVideoSurface.shared.rebindPlayer()
            }
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyZeroSafeArea()
        WindowVideoSurface.shared.forceFullBleed(reason: "safeArea")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyZeroSafeArea()
        WindowVideoSurface.shared.forceFullBleed(reason: "host-layout")
    }

    private func applyZeroSafeArea() {
        let inset = view.safeAreaInsets
        let target = UIEdgeInsets(
            top: -inset.top,
            left: -inset.left,
            bottom: -inset.bottom,
            right: -inset.right
        )
        if additionalSafeAreaInsets != target {
            additionalSafeAreaInsets = target
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
}
