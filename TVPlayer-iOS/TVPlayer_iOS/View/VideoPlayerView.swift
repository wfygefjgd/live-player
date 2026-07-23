import SwiftUI
import AVKit
import UIKit
import Combine

// MARK: - Window 级全屏播放（iPhone Air 等：首次也铺满，不依赖回前台 relayout）

/// 把 AVPlayerLayer 直接钉在 keyWindow 上，约束到 window 四边（不用 safeAreaLayoutGuide）
final class WindowVideoSurface {
    static let shared = WindowVideoSurface()

    private let hostView = PassthroughView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    private var edgeConstraints: [NSLayoutConstraint] = []
    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []
    private weak var player: AVPlayer?

    private init() {
        hostView.backgroundColor = .black
        hostView.isUserInteractionEnabled = false
        hostView.translatesAutoresizingMaskIntoConstraints = false
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.black.cgColor
        hostView.layer.addSublayer(playerLayer)

        let events: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIDevice.orientationDidChangeNotification,
            .tvPlayerNeedsRelayout
        ]
        for name in events {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.installAndLayout() }
                .store(in: &cancellables)
        }
    }

    func setPlayer(_ player: AVPlayer?) {
        self.player = player
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        installAndLayout()
        scheduleExtraLayouts()
    }

    func installAndLayout() {
        guard let window = Self.resolveKeyWindow() else { return }

        window.backgroundColor = .black
        // SwiftUI 根视图必须透明，否则会盖住 window 底层视频
        if let root = window.rootViewController?.view {
            root.backgroundColor = .clear
            root.isOpaque = false
        }

        if hostView.superview !== window {
            edgeConstraints.forEach { $0.isActive = false }
            edgeConstraints.removeAll()
            hostView.removeFromSuperview()
            window.insertSubview(hostView, at: 0)
            let c = [
                hostView.topAnchor.constraint(equalTo: window.topAnchor),
                hostView.bottomAnchor.constraint(equalTo: window.bottomAnchor),
                hostView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: window.trailingAnchor)
            ]
            NSLayoutConstraint.activate(c)
            edgeConstraints = c
        } else {
            window.sendSubviewToBack(hostView)
        }

        hostView.layoutIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = hostView.bounds
        // bounds 若仍为 0，直接用 window.bounds
        if playerLayer.frame.width < 2 || playerLayer.frame.height < 2 {
            playerLayer.frame = window.bounds
            hostView.frame = window.bounds
        }
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()
    }

    private func scheduleExtraLayouts() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        for t in [0.0, 0.05, 0.1, 0.2, 0.4, 0.8, 1.5] {
            let w = DispatchWorkItem { [weak self] in self?.installAndLayout() }
            delayItems.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
        }
    }

    private static func resolveKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let w = scene.windows.first(where: \.isKeyWindow) { return w }
            if let w = scene.windows.first { return w }
        }
        for scene in scenes {
            if let w = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
                return w
            }
        }
        return nil
    }
}

/// 不拦截触摸，保证手势落在上层 SwiftUI
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 同步 layer
        if let sub = layer.sublayers?.first as? AVPlayerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sub.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - SwiftUI 透明占位（真正画面在 Window 层）

final class PlayerAnchorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        WindowVideoSurface.shared.installAndLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        WindowVideoSurface.shared.installAndLayout()
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
        if vm.player.isReady {
            NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
            WindowVideoSurface.shared.installAndLayout()
        }
    }
}

extension Notification.Name {
    static let tvPlayerNeedsRelayout = Notification.Name("tvPlayerNeedsRelayout")
}
