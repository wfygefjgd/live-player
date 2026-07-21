import SwiftUI
import AVKit

struct VideoPlayerView: UIViewControllerRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = vm.player.player
        c.showsPlaybackControls = false
        c.videoGravity = .resizeAspectFill
        c.allowsPictureInPicturePlayback = false
        c.updatesNowPlayingInfoCenter = false
        c.view.backgroundColor = .black
        c.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        c.view.clipsToBounds = true
        return c
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = vm.player.player
    }
}
