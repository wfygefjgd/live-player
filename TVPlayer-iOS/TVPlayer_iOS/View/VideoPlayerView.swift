import SwiftUI
import AVKit

/// 使用系统 AVPlayerViewController，强制铺满窗口；
/// videoGravity = resizeAspect：高度优先顶满，左右可黑边，不裁切。
struct VideoPlayerView: UIViewControllerRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = vm.player.player
        c.showsPlaybackControls = false
        c.videoGravity = .resizeAspect
        c.allowsPictureInPicturePlayback = false
        c.updatesNowPlayingInfoCenter = false
        c.view.backgroundColor = .black
        c.view.isUserInteractionEnabled = false
        return c
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== vm.player.player {
            uiViewController.player = vm.player.player
        }
        uiViewController.videoGravity = .resizeAspect
        uiViewController.view.backgroundColor = .black
    }
}
