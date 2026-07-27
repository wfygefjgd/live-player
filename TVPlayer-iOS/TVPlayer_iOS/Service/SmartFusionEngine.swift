import Foundation

/// 频道加载：多源合并。线路顺序保持源站顺序，不按「强弱线」重排。
/// 高峰拥堵不是某条线弱，有数据就继续播；没数据再由播放器侧换线。
@MainActor
final class SmartFusionEngine {
    static let shared = SmartFusionEngine()

    private(set) var session: Int = 0
    var onProgress: ((String) -> Void)?

    init() {}

    func invalidateSession() {
        session &+= 1
    }

    func loadChannels(sourceUrls: [String]) async -> ([Channel], String?) {
        let requestSession = session
        guard !sourceUrls.isEmpty else {
            return ([], "没有可用的源")
        }

        onProgress?("正在加载频道源...")
        let allChannels = await loadAllSources(sourceUrls)
        guard requestSession == session else { return ([], nil) }
        if allChannels.isEmpty {
            return ([], "所有源均加载失败")
        }

        onProgress?("正在合并频道...")
        let merged = mergeChannels(allChannels)
        guard requestSession == session else { return ([], nil) }

        let totalLines = merged.reduce(0) { $0 + $1.sourceCount }
        onProgress?("完成！\(merged.count) 台 / \(totalLines) 线")
        return (merged, nil)
    }

    private func loadAllSources(_ urls: [String]) async -> [Channel] {
        guard !urls.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, [Channel]).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let body = try await NetworkService.shared.fetchTextWithMirrors(url: url)
                        let parsed = M3UParserService.parse(body)
                        return (index, parsed)
                    } catch {
                        return (index, [])
                    }
                }
            }

            var allChannels: [Channel] = []
            var done = 0
            for await (_, channels) in group {
                done += 1
                if !channels.isEmpty {
                    allChannels.append(contentsOf: channels)
                }
                let progress = done
                let total = urls.count
                await MainActor.run {
                    self.onProgress?("正在加载源 \(progress)/\(total)...")
                }
            }
            return allChannels
        }
    }

    private func mergeChannels(_ channels: [Channel]) -> [Channel] {
        var map: [String: Channel] = [:]
        var order: [String] = []
        for ch in channels {
            if var existing = map[ch.key] {
                existing.merge(with: ch)
                map[ch.key] = existing
            } else {
                map[ch.key] = ch
                order.append(ch.key)
            }
        }
        return order.compactMap { map[$0] }
    }
}
