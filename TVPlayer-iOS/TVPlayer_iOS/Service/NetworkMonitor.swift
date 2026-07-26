import Foundation
import Network

/// 网络状态监听 — 跟踪网络可用性及类型（WiFi/蜂窝）
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tvplayer.network.monitor")

    /// 当前网络是否可用
    private(set) var isSatisfied = false

    /// 当前网络类型
    private(set) var connectionType: ConnectionType = .unknown

    /// 是否使用蜂窝网络（可能需要节省流量）
    var isCellular: Bool { connectionType == .cellular }

    /// 是否 WiFi
    var isWiFi: Bool { connectionType == .wifi }

    enum ConnectionType {
        case wifi
        case cellular
        case wired
        case unknown
    }

    /// 网络从无到有时回调
    var onSatisfied: (() -> Void)? {
        didSet {
            if isSatisfied {
                DispatchQueue.main.async { [weak self] in
                    self?.onSatisfied?()
                }
            }
        }
    }

    /// 网络类型变化时回调
    var onConnectionTypeChanged: ((ConnectionType) -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path: path)
        }
        monitor.start(queue: queue)

        // 初始状态
        update(path: monitor.currentPath)
    }

    private func update(path: NWPath) {
        let satisfied = path.status == .satisfied
        let previousType = connectionType

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let wasSatisfied = self.isSatisfied
            self.isSatisfied = satisfied

            // 推断网络类型
            if path.usesInterfaceType(.wifi) {
                self.connectionType = .wifi
            } else if path.usesInterfaceType(.cellular) {
                self.connectionType = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                self.connectionType = .wired
            } else {
                self.connectionType = satisfied ? .unknown : .unknown
            }

            // 网络恢复通知（无 → 有）
            if satisfied && !wasSatisfied {
                self.onSatisfied?()
            }

            // 网络类型变化通知（含首次判定到 wifi/蜂窝，便于授权后重载画面）
            if self.connectionType != previousType {
                self.onConnectionTypeChanged?(self.connectionType)
            }
        }
    }

    // 🆕 停止监听（供清理使用）
    func stop() {
        monitor.cancel()
        onSatisfied = nil
        onConnectionTypeChanged = nil
    }
}
