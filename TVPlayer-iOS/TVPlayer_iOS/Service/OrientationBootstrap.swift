import UIKit

/// 固定横屏；不再风暴式 hardRemount（1.5.42 闪退诱因）
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
        // 只钉一次画面，不循环 refreshChromeAndVideo
        DispatchQueue.main.async {
            WindowVideoSurface.shared.forceFullBleed(reason: "landscape-lock")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            WindowVideoSurface.shared.hardRemount(reason: "landscape-lock-delay")
        }
    }

    static func simulateForegroundRecovery(reason: String) {
        WindowVideoSurface.shared.hardRemount(reason: "sim-fg-\(reason)")
    }
}
