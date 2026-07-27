import Foundation

/// 频道加载引擎：固定使用多源合并 + 信誉排序，不再暴露融合模式开关
@MainActor
final class SmartFusionEngine {
    static let shared = SmartFusionEngine()

    private let speedTester = LineSpeedTester.shared
    /// 每次加载递增；旧请求完成后若 session 已变则丢弃结果
    private(set) var session: Int = 0

    /// 进度回调
    var onProgress: ((String) -> Void)?

    init() {}

    /// 新加载开始时作废进行中的旧请求
    func invalidateSession() {
        session &+= 1
    }

    // MARK: - 公开接口

    /// 固定策略：优先加载多源并合并频道，再按历史信誉与轻量测速排序
    /// - 调用前请 `invalidateSession()`；本方法使用当前 `session` 作为 request id
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
        onProgress?("正在按线路信誉排序...")
        let optimized = await optimizeChannels(merged)
        guard requestSession == session else { return ([], nil) }

        let totalLines = optimized.reduce(0) { $0 + $1.sourceCount }
        onProgress?("完成！\(optimized.count) 台 / \(totalLines) 线")
        return (optimized, nil)
    }

    // MARK: - 核心功能

    /// 加载所有源（并发，失败源跳过）
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

    /// 合并同名频道
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

        // 合并结果先套信誉：黑名单后置、偏好前置
        return LineReputationStore.shared.applyToChannels(Array(map.values))
    }

    /// 优化频道：以历史起播信誉为主，HEAD 测速仅作弱信号且只抽样前几条
    private func optimizeChannels(_ channels: [Channel]) async -> [Channel] {
        let rep = LineReputationStore.shared
        let base = rep.applyToChannels(channels)

        var optimized: [Channel] = []
        for ch in base {
            let ordered = rep.orderedURLs(ch.urls, channelKey: ch.key)
            let playable = rep.filterPlayable(ordered)
            if playable.count <= 2 {
                var nc = Channel(name: ch.name, group: ch.group, key: ch.key)
                nc.addUrls(playable.isEmpty ? ordered : playable)
                optimized.append(nc)
                continue
            }

            let sample = Array(playable.prefix(3))
            let qualities = await speedTester.testLines(sample, maxConcurrent: 3)
            // HEAD 仅作弱信号：不可用的往后排，但不拉黑；真实播放失败再拉黑
            let weakBad = Set(qualities.filter { !$0.isAvailable }.map(\.url))
            let good = playable.filter { !weakBad.contains($0) }
            let bad = playable.filter { weakBad.contains($0) }
            let black = ordered.filter { rep.isBlacklisted($0) }

            var nc = Channel(name: ch.name, group: ch.group, key: ch.key)
            nc.addUrls(good + bad + black)
            optimized.append(nc)
        }
        return rep.applyToChannels(optimized)
    }
}
