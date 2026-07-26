import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import Combine

// MARK: - 霸道全屏画面层
//
// 策略：锁定物理横屏尺寸，不给 Home Indicator / safeArea 让位。
// 小白条只能浮在画面上，不能挤走/缩短画面。
// 不做网络/频繁 remount（会闪屏）。

final class WindowVideoSurface {
    static let shared = WindowVideoSurface()

    private let host = TouchThroughView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private weak var boundPlayer: AVPlayer?

    /// 锁定后 frame 不再随 safeArea 收缩
    private var locked = false
    private var lockedSize: CGSize = .zero
    private var isApplying = false

    private init() {
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        host.autoresizingMask = []
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
        // 仅方向/回前台时重新钉锁定尺寸，不 hardRemount
        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIDevice.orientationDidChangeNotification,
            UIWindow.didBecomeKeyNotification,
            .tvPlayerNeedsRelayout
        ]
        for name in names {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.pinLocked(reason: name.rawValue)
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
            pinLocked(reason: "interruptionEnded")
        @unknown default:
            break
        }
    }

    // MARK: - Player

    func setPlayer(_ player: AVPlayer?) {
        boundPlayer = player
        playerLayer.player = player
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        lockToPhysicalScreenIfNeeded()
        pinLocked(reason: "setPlayer")
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

    /// 兼容旧调用：等同 pinLocked（不再做会闪屏的 hard remount）
    func hardRemount(reason: String = "") {
        lockToPhysicalScreenIfNeeded()
        pinLocked(reason: reason)
        rebindPlayer()
    }

    func forceFullBleed(reason: String = "") {
        lockToPhysicalScreenIfNeeded()
        pinLocked(reason: reason)
    }

    func install(reason: String = "") {
        lockToPhysicalScreenIfNeeded()
        pinLocked(reason: reason)
    }

    // MARK: - 锁定物理全屏

    /// 只在未锁定或尺寸明显变化（真旋转）时更新锁定尺寸
    private func lockToPhysicalScreenIfNeeded(force: Bool = false) {
        let size = Self.physicalLandscapeSize(for: Self.mainWindow())
        guard size.width > 1, size.height > 1 else { return }
        if force || !locked || lockedSize == .zero {
            lockedSize = size
            locked = true
            return
        }
        // 仅当长短边对调（真旋转）才改锁定，safeArea 变化绝不改
        let wasLandscape = lockedSize.width >= lockedSize.height
        let nowLandscape = size.width >= size.height
        if wasLandscape != nowLandscape {
            lockedSize = size
        } else {
            // 同方向：取更大值，永不缩小（霸道）
            lockedSize = CGSize(
                width: max(lockedSize.width, size.width),
                height: max(lockedSize.height, size.height)
            )
        }
        locked = true
    }

    private func pinLocked(reason: String = "") {
        if isApplying { return }
        isApplying = true
        defer { isApplying = false }

        guard let window = Self.mainWindow() else { return }
        lockToPhysicalScreenIfNeeded()
        guard lockedSize.width > 1, lockedSize.height > 1 else { return }

        window.backgroundColor = .black
        window.clipsToBounds = false

        if let root = window.rootViewController {
            root.view.backgroundColor = .clear
            root.view.isOpaque = false
            root.view.clipsToBounds = false
            root.view.insetsLayoutMarginsFromSafeArea = false
            // 不改 additionalSafeArea，不 layoutIfNeeded
            root.setNeedsUpdateOfHomeIndicatorAutoHidden()
            root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            root.setNeedsStatusBarAppearanceUpdate()
        }

        // 挂到主 window 最底层
        host.layer.zPosition = -1_000
        if host.superview !== window {
            host.removeFromSuperview()
            window.insertSubview(host, at: 0)
        } else {
            window.sendSubviewToBack(host)
        }

        // 霸道：frame = 锁定物理尺寸，相对 window 居中；可溢出 window 盖住小白条区域
        let ox = (window.bounds.width - lockedSize.width) / 2
        let oy = (window.bounds.height - lockedSize.height) / 2
        let frame = CGRect(x: ox, y: oy, width: lockedSize.width, height: lockedSize.height)

        host.isHidden = false
        host.alpha = 1
        host.backgroundColor = .black
        host.clipsToBounds = false
        host.isUserInteractionEnabled = false
        host.frame = frame
        host.bounds = CGRect(origin: .zero, size: lockedSize)

        applyLayerFrame()
        if playerLayer.player == nil {
            playerLayer.player = boundPlayer
        }
    }

    private func applyLayerFrame() {
        guard host.bounds.width > 1, host.bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()
    }

    /// 物理横屏尺寸（nativeBounds），无视 safeArea / Home Indicator
    private static func physicalLandscapeSize(for window: UIWindow?) -> CGSize {
        let screen = window?.windowScene?.screen ?? window?.screen ?? UIScreen.main
        let native = screen.nativeBounds
        let scale = max(screen.scale, 1)
        var w = native.width / scale
        var h = native.height / scale
        if w < 1 || h < 1 {
            let b = screen.bounds
            w = b.width
            h = b.height
        }
        // 强制横屏：宽 = 长边
        if w < h { swap(&w, &h) }
        // 与 window 取大，永不小于当前窗
        if let window {
            let ww = max(window.bounds.width, window.bounds.height)
            let wh = min(window.bounds.width, window.bounds.height)
            w = max(w, ww)
            h = max(h, wh)
        }
        return CGSize(width: w, height: h)
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

private final class TouchThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    // 不在 layoutSubviews 里动 playerLayer，避免被系统 layout 带跑
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

// MARK: - 根容器

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
        // safeArea 变了也不让位：仍钉锁定尺寸
        refreshSystemChrome()
        WindowVideoSurface.shared.forceFullBleed(reason: "safeArea-ignore")
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
