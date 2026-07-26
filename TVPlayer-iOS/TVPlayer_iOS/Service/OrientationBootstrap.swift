import UIKit

/// 固定横屏
enum OrientationBootstrap {
    private(set) static var allowedMask: UIInterfaceOrientationMask = .landscape

    static var isLandscapeLocked: Bool { true }

    static func resetForColdLaunch() {
        allowedMask = .landscape
    }

    static func schedulePortraitToLandscapeShock(after delay: TimeInterval = 0) {
        lockLandscapeAndRefresh()
    }

    static func lockLandscapeAndRefresh() {
        allowedMask = .landscape
        DispatchQueue.main.async {
            WindowVideoSurface.shared.forceFullBleed(reason: "landscape-lock")
        }
    }

    static func simulateForegroundRecovery(reason: String) {
        WindowVideoSurface.shared.forceFullBleed(reason: "sim-fg-\(reason)")
        WindowVideoSurface.shared.rebindPlayer()
    }
}
