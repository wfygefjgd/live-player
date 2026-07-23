import SwiftUI
import AVKit
import UIKit
import Combine

/// 画面在 SwiftUI 内可见；layer 对齐 window 全屏；不裁切（resizeAspect）。
/// 修 1.3.5/1.3.6：window 底层被盖住 / contain 叠在小容器上导致四边假黑边。
final class FullScreenPlayerViewController: UIViewController {
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = true
        view.clipsToBounds = false
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(playerLayer)

        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        if #available(iOS 11.0, *) {
            additionalSafeAreaInsets = .zero
        }

        for name: Notification.Name in [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIDevice.orientationDidChangeNotification,
            .tvPlayerNeedsRelayout
        ] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.forceRelayout()
                    self?.scheduleRelayoutPasses()
                }
                .store(in: &cancellables)
        }
    }

    deinit { delayItems.forEach { $0.cancel() } }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        forceRelayout()
        scheduleRelayoutPasses()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if #available(iOS 11.0, *) {
            let s = view.safeAreaInsets
            additionalSafeAreaInsets = UIEdgeInsets(
                top: -s.top, left: -s.left, bottom: -s.bottom, right: -s.right
            )
        }
        layoutPlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayer()
    }

    func bind(player: AVPlayer?) {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        forceRelayout()
    }

    func onPlaybackReady() {
        forceRelayout()
        scheduleRelayoutPasses()
    }

    func forceRelayout() {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        layoutPlayer()
        DispatchQueue.main.async { [weak self] in self?.layoutPlayer() }
    }

    private func scheduleRelayoutPasses() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        for t in [0.05, 0.15, 0.35, 0.7, 1.2] {
            let item = DispatchWorkItem { [weak self] in self?.layoutPlayer() }
            delayItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
        }
    }

    private func layoutPlayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playerLayer.superlayer == nil {
            view.layer.addSublayer(playerLayer)
        }

        // 1) 优先：整个 window 物理全屏（含 Home 条区域）
        if let window = view.window {
            playerLayer.frame = view.convert(window.bounds, from: nil)
        } else if view.bounds.width > 2, view.bounds.height > 2 {
            playerLayer.frame = view.bounds
        } else {
            let b = UIScreen.main.bounds
            playerLayer.frame = CGRect(
                origin: .zero,
                size: CGSize(width: max(b.width, b.height), height: min(b.width, b.height))
            )
        }

        // 2) 不能比本 view 更小（防中间小窗 + 四边假黑边）
        let vb = view.bounds
        if vb.width > 2, vb.height > 2 {
            if playerLayer.frame.width < vb.width - 1 || playerLayer.frame.height < vb.height - 1 {
                playerLayer.frame = vb
            }
        }

        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()
    }
}

struct VideoPlayerView: UIViewControllerRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIViewController(context: Context) -> FullScreenPlayerViewController {
        let vc = FullScreenPlayerViewController()
        vc.bind(player: vm.player.player)
        return vc
    }

    func updateUIViewController(_ vc: FullScreenPlayerViewController, context: Context) {
        vc.bind(player: vm.player.player)
        _ = vm.playerLayoutEpoch
        if vm.player.isReady {
            vc.onPlaybackReady()
        } else {
            vc.forceRelayout()
        }
    }
}

extension Notification.Name {
    static let tvPlayerNeedsRelayout = Notification.Name("tvPlayerNeedsRelayout")
}
