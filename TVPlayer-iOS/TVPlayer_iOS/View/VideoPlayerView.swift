import SwiftUI
import AVKit
import UIKit

/// 用 UIViewController 承载播放层，强制扩展到安全区外（顶/底 Home 条区域一并画上）。
final class FullScreenPlayerViewController: UIViewController {
    private let playerLayer = AVPlayerLayer()
    private weak var boundPlayer: AVPlayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(playerLayer)
        // 允许内容延伸到系统条之下
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        if #available(iOS 11.0, *) {
            additionalSafeAreaInsets = .zero
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // 抵消系统 safe area，让 self.view 布局区域等于物理全屏
        if #available(iOS 11.0, *) {
            let s = view.safeAreaInsets
            additionalSafeAreaInsets = UIEdgeInsets(
                top: -s.top,
                left: -s.left,
                bottom: -s.bottom,
                right: -s.right
            )
        }
        layoutPlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayer()
    }

    func bind(player: AVPlayer?) {
        boundPlayer = player
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layoutPlayer()
    }

    private func layoutPlayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 优先盖住整个 window
        if let window = view.window {
            let full = window.bounds
            let frameInView = view.convert(full, from: window)
            playerLayer.frame = frameInView
        } else {
            let b = UIScreen.main.bounds
            playerLayer.frame = CGRect(origin: .zero, size: CGSize(
                width: max(b.width, b.height),
                height: min(b.width, b.height)
            ))
            // 若 view 已有尺寸，直接铺满 view
            if view.bounds.width > 1, view.bounds.height > 1 {
                playerLayer.frame = view.bounds
            }
        }
        // 最终兜底：至少等于 view.bounds
        if playerLayer.frame.width < view.bounds.width || playerLayer.frame.height < view.bounds.height {
            playerLayer.frame = view.bounds
        }
        playerLayer.videoGravity = .resizeAspectFill
        CATransaction.commit()
    }
}

/// SwiftUI 包装：全屏 UIViewController + 铺满画面（轻微裁切，尽量无黑边）
struct VideoPlayerView: UIViewControllerRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIViewController(context: Context) -> FullScreenPlayerViewController {
        let vc = FullScreenPlayerViewController()
        vc.bind(player: vm.player.player)
        return vc
    }

    func updateUIViewController(_ uiViewController: FullScreenPlayerViewController, context: Context) {
        uiViewController.bind(player: vm.player.player)
    }
}
