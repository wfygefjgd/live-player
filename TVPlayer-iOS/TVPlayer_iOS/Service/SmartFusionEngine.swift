import Foundation

/// 频道加载引擎：多源合并 + 轻量测速排序（无线路信誉 / 黑名单）
@MainActor
final class SmartFusionEngine {
    static let shared = SmartFusionEngine()

    private let speedTester = LineSpeedTester.shared
    private(set) var session: Int = 0

    var onProgress: ((String) -> Void)?

    init() {}

    func invalidateSession() {
        session &+= 1
    }

    /// 多源合并后，对每台抽样前几条线路做弱测速排序
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
        onProgress?("正在整理线路...")
        let optimized = await optimizeChannels(merged)
        guard requestSession == session else { return ([], nil) }

        let totalLines = optimized.reduce(0) { $0 + $1.sourceCount }
        onProgress?("完成！\(optimized.count) 台 / \(totalLines) 线")
        return (optimized, nil)
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
        for ch in channels {
            if var existing = map[ch.key] {
                existing.merge(with: ch)
                map[ch.key] = existing
            } else {
                map[ch.key] = ch
            }
        }
        return Array(map.values)
    }

    /// HEAD 弱测速：不可达的往后排，不拉黑；真实播放失败再由自动换线处理
    private func optimizeChannels(_ channels: [Channel]) async -> [Channel] {
        var optimized: [Channel] = []
        for ch in channels {
            let urls = ch.urls
            if urls.count <= 2 {
                var nc = Channel(name: ch.name, group: ch.group, key: ch.key)
                nc.addUrls(urls)
                optimized.append(nc)
                continue
            }

            let sample = Array(urls.prefix(3))
            let qualities = await speedTester.testLines(sample, maxConcurrent: 3)
            let weakBad = Set(qualities.filter { !$0.isAvailable }.map(\.url))
            let good = urls.filter { !weakBad.contains($0) }
            let bad = urls.filter { weakBad.contains($0) }

            var nc = Channel(name: ch.name, group: ch.group, key: ch.key)
            nc.addUrls(good + bad)
            optimized.append(nc)
        }
        return optimized
    }
}
