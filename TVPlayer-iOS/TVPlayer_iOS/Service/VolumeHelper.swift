import AVFoundation
import MediaPlayer
import UIKit

/// Persistent hidden MPVolumeView for system volume
enum VolumeHelper {
    private static var volumeView: MPVolumeView?
    private static var slider: UISlider?

    static var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    private static func ensureInstalled() {
        if volumeView != nil, slider != nil { return }
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        v.alpha = 0.0001
        v.isUserInteractionEnabled = false
        volumeView = v
        slider = v.subviews.compactMap { $0 as? UISlider }.first

        if let window = keyWindow() {
            window.addSubview(v)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let w = keyWindow(), let vv = volumeView, vv.superview == nil {
                    w.addSubview(vv)
                }
                if slider == nil {
                    slider = volumeView?.subviews.compactMap { $0 as? UISlider }.first
                }
            }
        }
        if slider == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                slider = volumeView?.subviews.compactMap { $0 as? UISlider }.first
            }
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    static func setVolume(_ value: Float) {
        ensureInstalled()
        let v = max(0, min(1, value))
        if let slider {
            slider.value = v
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                if slider == nil {
                    slider = volumeView?.subviews.compactMap { $0 as? UISlider }.first
                }
                slider?.value = v
            }
        }
    }

    static func adjust(by delta: Float) {
        setVolume(current + delta)
    }
}
