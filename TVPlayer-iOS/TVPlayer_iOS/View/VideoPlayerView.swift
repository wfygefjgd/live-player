import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import Combine

// MARK: - Window full-bleed (cold start same as resume)

/// Video host on keyWindow, pinned to **window.bounds** (not safe area).
/// Cold start must match "return from background" layout.
final class WindowVideoSurface {
    static let shared = WindowVideoSurface()

    private let host = TouchThroughView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []
    private weak var boundPlayer: AVPlayer?
    private var displayLink: CADisplayLink?
    private var displayLinkTicks = 0

    private init() {
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = UIColor.black.cgColor
        host.layer.addSublayer(playerLayer)

        setupNotifications()
        setupAudioSession()
    }

    private func setupNotifications() {
        let notes: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didFinishLaunchingNotification,
            UIDevice.orientationDidChangeNotification,
            UIWindow.didBecomeKeyNotification,
            .tvPlayerNeedsRelayout
        ]
        for name in notes {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.install(reason: name.rawValue)
                }
                .store(in: &cancellables)
        }

        // 音频路由变更（耳机拔插等）
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleRouteChange()
            }
            .store(in: &cancellables)

        // 音频中断通知（来电等）
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleInterruption(note)
            }
            .store(in: &cancellables)
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
    }

    private func handleRouteChange() {
        install(reason: "routeChange")
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // 中断开始（来电等），暂停播放由 PlayerEngine 处理
            break
        case .ended:
            // 中断结束，恢复播放
            if let raw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: raw)
                if options.contains(.shouldResume) {
                    install(reason: "interruptionEnded")
                }
            }
        @unknown default:
            break
        }
    }

    // MARK: - Player

    func setPlayer(_ player: AVPlayer?) {
        if player == nil {
            cleanup()
        }
        boundPlayer = player
        playerLayer.player = player
        playerLayer.videoGravity = .resize
        install(reason: "setPlayer")
        schedulePasses()
        startBriefDisplayLink()
    }

    // 🆕 清理资源
    func cleanup() {
        cancellables.removeAll()
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTicks = 0
    }

    deinit {
        cleanup()
    }

    func install(reason: String = "") {
        guard let window = Self.keyWindow() else { return }

        window.backgroundColor = .black
        window.clipsToBounds = false
        if let root = window.rootViewController?.view {
            root.backgroundColor = .clear
            root.isOpaque = false
            root.clipsToBounds = false
        }

        if host.superview !== window {
            host.removeFromSuperview()
            window.insertSubview(host, at: 0)
        } else {
            window.sendSubviewToBack(host)
        }

        let full = window.bounds
        host.frame = full
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.clipsToBounds = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
        if playerLayer.frame.width < 2 || playerLayer.frame.height < 2 {
            playerLayer.frame = full
        }
        if playerLayer.frame.width < full.width - 0.5
            || playerLayer.frame.height < full.height - 0.5 {
            host.frame = full
            playerLayer.frame = CGRect(origin: .zero, size: full.size)
        }
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        if playerLayer.player == nil {
            playerLayer.player = boundPlayer
        }
        CATransaction.commit()

        window.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        window.rootViewController?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()

        if reason == "host-appear" || reason == "anchor-window" {
            schedulePasses()
            startBriefDisplayLink()
        }
    }

    /// First ~6s: layout every frame (Home Indicator inset settles after first frames)
    func startBriefDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil  // 🆕 清空引用
        displayLinkTicks = 0
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func onDisplayLinkTick() {
        displayLinkTicks += 1
        install(reason: "displayLink")
        if displayLinkTicks >= 360 {
            displayLink?.invalidate()
            displayLink = nil  // 🆕 清空引用
        }
    }

    func schedulePasses() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        for t in [0.0, 0.03, 0.08, 0.15, 0.3, 0.5, 0.8, 1.2, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0] {
            let item = DispatchWorkItem { [weak self] in self?.install(reason: "delay-\(t)") }
            delayItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
        }
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

/// CADisplayLink cannot retain WindowVideoSurface strongly via target; use proxy
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
        WindowVideoSurface.shared.install(reason: "anchor-window")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        WindowVideoSurface.shared.install(reason: "anchor-layout")
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
        WindowVideoSurface.shared.install(reason: "swiftui-update")
    }
}

final class RootHostingController<Content: View>: UIHostingController<Content> {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var shouldAutorotate: Bool { false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }

    // 🔥 暴力方法1：强制扩展视图到屏幕之外 + 黑色遮罩
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()

        if let window = view.window {
            let screen = window.screen.bounds
            let bottomInset = view.safeAreaInsets.bottom

            // 方法1: 设置超大负边距，彻底突破安全区域
            additionalSafeAreaInsets = UIEdgeInsets(
                top: -50,
                left: -50,
                bottom: -(bottomInset + 50),
                right: -50
            )

            // 方法2: 强制 frame 扩展到屏幕外
            let extendedFrame = CGRect(
                x: -50,
                y: -50,
                width: screen.width + 100,
                height: screen.height + 100
            )
            if view.frame != extendedFrame {
                view.frame = extendedFrame
            }

            // 方法3: 修改 view 的 bounds 和 center
            view.bounds = CGRect(origin: .zero, size: CGSize(width: screen.width + 100, height: screen.height + 100))
            view.center = CGPoint(x: screen.midX, y: screen.midY)

            // 🔥 方法4: 添加黑色遮罩视图覆盖底部区域
            addBlackMaskIfNeeded(screenBounds: screen, bottomInset: bottomInset)
        }
    }

    private var blackMask: UIView?

    private func addBlackMaskIfNeeded(screenBounds: CGRect, bottomInset: CGFloat) {
        if blackMask == nil {
            let mask = UIView()
            mask.backgroundColor = .black
            mask.isUserInteractionEnabled = false
            mask.tag = 9999
            view.addSubview(mask)
            blackMask = mask
        }

        // 遮罩覆盖底部 Home Indicator 区域
        blackMask?.frame = CGRect(
            x: 0,
            y: screenBounds.height - bottomInset - 10,
            width: screenBounds.width,
            height: bottomInset + 60  // 超出屏幕范围
        )
        view.bringSubviewToFront(blackMask!)
    }

    private var hideIndicatorTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false  // 🔥 关键：允许子视图超出边界

        // 禁用安全区域布局
        if #available(iOS 11.0, *) {
            view.insetsLayoutMarginsFromSafeArea = false
        }

        // 🔥 暴力方法2：尝试修改私有属性（可能被拒）
        if let window = view.window {
            // 强制禁用 Home Indicator
            if responds(to: Selector(("setHomeIndicatorAutoHidden:")))) {
                perform(Selector(("setHomeIndicatorAutoHidden:")), with: true)
            }
        }

        // 立即强制隐藏
        forceHideHomeIndicator()

        // 启动持续隐藏定时器（每 0.1 秒强制一次，更频繁）
        hideIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.forceHideHomeIndicator()
        }
    }

    deinit {
        hideIndicatorTimer?.invalidate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        forceHideHomeIndicator()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hideIndicatorTimer?.invalidate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        forceHideHomeIndicator()
        WindowVideoSurface.shared.install(reason: "host-appear")
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)

        // 🔥 暴力方法3：延迟多次强制
        for delay in [0.0, 0.05, 0.1, 0.2, 0.3, 0.5, 0.8, 1.0, 1.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.forceHideHomeIndicator()
            }
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        forceHideHomeIndicator()
        WindowVideoSurface.shared.install(reason: "safeArea")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        forceHideHomeIndicator()
        WindowVideoSurface.shared.install(reason: "host-layout")
    }

    private func forceHideHomeIndicator() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()

        // 🔥 暴力方法4：多次连续调用，确保生效
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }
}

// MARK: - Now Playing Info (锁屏控件)

final class NowPlayingController {
    static let shared = NowPlayingController()
    private let infoCenter = MPNowPlayingInfoCenter.default()

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
}
