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

    // 🆕 最强硬方法：直接设置 view.frame 覆盖整个屏幕
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()

        // 强制 view 占据整个屏幕，忽略安全区域
        if let window = view.window {
            let screenBounds = window.screen.bounds
            if view.frame != screenBounds {
                view.frame = screenBounds
            }
        }
    }

    private var hideIndicatorTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false

        // 🆕 禁用安全区域布局
        if #available(iOS 11.0, *) {
            view.insetsLayoutMarginsFromSafeArea = false
        }

        // 立即强制隐藏
        forceHideHomeIndicator()

        // 启动持续隐藏定时器（每 0.5 秒强制一次）
        hideIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        forceHideHomeIndicator()
        WindowVideoSurface.shared.install(reason: "host-appear")
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
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

        // 三重延迟确保生效
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            self?.setNeedsStatusBarAppearanceUpdate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            self?.setNeedsStatusBarAppearanceUpdate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            self?.setNeedsStatusBarAppearanceUpdate()
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
