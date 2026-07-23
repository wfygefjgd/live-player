import Foundation
import Network

/// 监听网络可用状态，首次授权/断网恢复时通知
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tvplayer.network.monitor")
    private(set) var isSatisfied = false
    var onSatisfied: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let was = self.isSatisfied
                self.isSatisfied = ok
                if ok && !was {
                    self.onSatisfied?()
                }
            }
        }
        monitor.start(queue: queue)
    }
}
