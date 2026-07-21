import SwiftUI
import AVKit

class PlayerContainerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        if let layer = layer.sublayers?.first as? AVPlayerLayer {
            layer.frame = bounds
        }
    }
}

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> UIView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        let layer = AVPlayerLayer(player: vm.player.player)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let view = uiView as? PlayerContainerView,
           let layer = view.layer.sublayers?.first as? AVPlayerLayer {
            layer.player = vm.player.player
        }
    }
}
