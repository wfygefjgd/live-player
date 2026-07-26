import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import Combine

// MARK: - Window full-bleed (cold start same as resume)

/// Video host on keyWindow, always full **screen** bounds (ignore safe area / Home Indicator).
/// Cold start previously got squeezed by safe-area layout; resume re-installed full frame and looked correct.
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

    private init() {
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        // 不用 autoresizing 跟 safe-area 子视图走；每次 install 钉死全屏
        host.autoresizingMask = []
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
        // 关键：忽略窗口 safeArea，用物理屏幕矩形，冷启动与回前台一致
        let full = Self.fullScreenRect(for: window)

        if let root = window.rootViewController?.view {
            root.backgroundColor = .clear
            root.isOpaque = false
            root.clipsToBounds = false
        }

        host.layer.zPosition = 0
        if host.superview !== window {
            host.removeFromSuperview()
            window.insertSubview(host, at: 0)
        } else {
            window.sendSubviewToBack(host)
        }

        // 尺寸未变且非关键时机则跳过重排，减少与 safe area 动画抢布局
        let sizeChanged = abs(lastAppliedSize.width - full.width) > 0.5
            || abs(lastAppliedSize.height - full.height) > 0.5
        let force = reason.contains("active")
            || reason.contains("foreground")
            || reason.contains("appear")
            || reason.contains("safeArea")
            || reason.contains("orientation")
            || reason.contains("setPlayer")
            || reason.contains("anchor")
            || host.frame.width < full.width - 1
            || host.frame.height < full.height - 1

        if sizeChanged || force || host.frame != full {
            host.frame = full
            host.bounds = CGRect(origin: .zero, size: full.size)
            host.center = CGPoint(x: full.midX, y: full.midY)
            host.clipsToBounds = false
            host.isUserInteractionEnabled = false
            lastAppliedSize = full.size

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = CGRect(origin: .zero, size: full.size)
            playerLayer.videoGravity = .resize
            playerLayer.isHidden = false
            playerLayer.opacity = 1
            if playerLayer.player == nil {
                playerLayer.player = boundPlayer
            }
            CATransaction.commit()
        } else if playerLayer.player == nil {
            playerLayer.player = boundPlayer
        }

        WindowPanelSurface.shared.ensureOnTop()

        window.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        window.rootViewController?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()

        // 冷启动：短窗口内多拍几次全屏，等 Home Indicator / 旋转 inset 落定
        if reason == "host-appear" || reason == "anchor-window" || reason == "app-active"
            || reason == "foreground" || reason == "setPlayer" {
            schedulePasses()
            startBriefDisplayLink()
        }
    }

    /// 前 ~2s 轻量校正（不再狂刷 6s）
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
        install(reason: "displayLink")
        // ~2 秒 @30fps
        if displayLinkTicks >= 60 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    func schedulePasses() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        // 覆盖冷启动 inset 变化窗口即可，不必拖到 10s
        for t in [0.0, 0.05, 0.12, 0.25, 0.5, 1.0, 1.5, 2.0] {
            let item = DispatchWorkItem { [weak self] in self?.install(reason: "delay-\(t)") }
            delayItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
        }
    }

    /// 钉死全屏矩形：优先 window.bounds；冷启动 window 未铺满时用当前方向的 screen 尺寸
    private static func fullScreenRect(for window: UIWindow) -> CGRect {
        let wb = window.bounds
        let sb = window.screen.bounds
        let orient = window.windowScene?.interfaceOrientation
        let landscape = orient?.isLandscape ?? (wb.width > wb.height)
        let screenFull: CGRect = {
            if landscape {
                return CGRect(x: 0, y: 0, width: max(sb.width, sb.height), height: min(sb.width, sb.height))
            }
            return CGRect(x: 0, y: 0, width: min(sb.width, sb.height), height: max(sb.width, sb.height))
        }()
        // window 已接近全屏 → 用 window（与坐标系一致）
        if wb.width >= screenFull.width - 2 && wb.height >= screenFull.height - 2 {
            return CGRect(origin: .zero, size: wb.size)
        }
        // 冷启动常见：window 高度被 Home Indicator / safe area 吃掉 → 用 screen 全屏
        if wb.width >= screenFull.width - 2 && wb.height < screenFull.height - 2 {
            return screenFull
        }
        return screenFull.width > 1 ? screenFull : CGRect(origin: .zero, size: wb.size)
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

/// 正确处理 Home Indicator：声明 auto-hidden，画面层钉死全屏。
/// 不再用「扩 frame / 负 safeArea / 0.05s 狂刷」——那些会在冷启动把布局挤乱。
final class RootHostingController<Content: View>: UIHostingController<Content> {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
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
        if #available(iOS 11.0, *) {
            view.insetsLayoutMarginsFromSafeArea = false
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        // 冷启动关键：appear 后立即 + 短延迟全屏钉死（等同你回前台时的正确路径）
        WindowVideoSurface.shared.install(reason: "host-appear")
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
        for t in [0.05, 0.2, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                WindowVideoSurface.shared.install(reason: "host-appear-delay")
            }
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // inset 变化时不要改 root frame，只重钉画面层全屏
        WindowVideoSurface.shared.install(reason: "safeArea")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 仅当 window 尺寸变化时校正画面（install 内部有去重）
        WindowVideoSurface.shared.install(reason: "host-layout")
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
