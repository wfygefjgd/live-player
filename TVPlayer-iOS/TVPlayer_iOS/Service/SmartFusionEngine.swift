import Foundation

/// 融合模式
enum FusionMode: String, Codable {
    case off        // 关闭融合：仅使用单一源
    case fast       // 快速模式：只用最快的源
    case balanced   // 平衡模式：融合前3个源
    case complete   // 完整模式：融合所有源
    case smart      // 智能模式：渐进式融合 + 后台测速（推荐）
}

/// 智能融合引擎
@MainActor
final class SmartFusionEngine {
    static let shared = SmartFusionEngine()

    private let speedTester = LineSpeedTester.shared
    private var fusionMode: FusionMode = .smart
    /// 每次 smartFusion 递增；后台 Task 完成后若 session 已变则丢弃结果
    private(set) var session: Int = 0

    /// 进度回调
    var onProgress: ((String) -> Void)?

    init() {}

    /// 新加载开始时作废进行中的后台融合
    func invalidateSession() {
        session &+= 1
    }

    // MARK: - 公开接口

    /// 智能融合：加载所有源 + 测速 + 排序
    /// - 调用前请 `invalidateSession()`；本方法使用当前 `session` 作为 request id
    func smartFusion(sourceUrls: [String], mode: FusionMode? = nil) async -> ([Channel], String?) {
        let requestSession = session
        let actualMode = mode ?? fusionMode

        switch actualMode {
        case .off:
            return await offMode(sourceUrls: sourceUrls)
        case .fast:
            return await fastMode(sourceUrls: sourceUrls)
        case .balanced:
            return await balancedMode(sourceUrls: sourceUrls)
        case .complete:
            return await completeMode(sourceUrls: sourceUrls)
        case .smart:
            return await smartMode(sourceUrls: sourceUrls, requestSession: requestSession)
        }
    }

    // MARK: - 不同模式实现

    /// 关闭模式：仅使用第一个源
    private func offMode(sourceUrls: [String]) async -> ([Channel], String?) {
        onProgress?("关闭融合：加载单一源...")

        guard let firstUrl = sourceUrls.first else {
            return ([], "没有可用的源")
        }

        return await NetworkService.shared.fetchWithCandidates(urls: [firstUrl])
    }

    /// 快速模式：只用最快的源（竞速）
    private func fastMode(sourceUrls: [String]) async -> ([Channel], String?) {
        onProgress?("快速模式：竞速加载...")

        // 使用现有的竞速逻辑
        return await NetworkService.shared.fetchWithCandidates(urls: sourceUrls)
    }

    /// 平衡模式：融合前 5 个源（更激进）
    private func balancedMode(sourceUrls: [String]) async -> ([Channel], String?) {
        onProgress?("平衡模式：加载前5个源...")

        let limitedUrls = Array(sourceUrls.prefix(5))
        let allChannels = await loadAllSources(limitedUrls)

        if allChannels.isEmpty {
            return ([], "所有源均加载失败")
        }

        onProgress?("正在合并频道...")
        let merged = mergeChannels(allChannels)

        onProgress?("完成！共 \(merged.count) 个频道")
        return (merged, nil)
    }

    /// 完整模式：融合所有源 + 完整测速
    private func completeMode(sourceUrls: [String]) async -> ([Channel], String?) {
        onProgress?("完整模式：加载所有源...")

        // 第一步：并发加载所有源
        let allChannels = await loadAllSources(sourceUrls)

        if allChannels.isEmpty {
            return ([], "所有源均加载失败")
        }

        onProgress?("正在合并频道...")
        let merged = mergeChannels(allChannels)

        onProgress?("正在按播放信誉优化线路...")
        let optimized = await optimizeChannels(merged)

        let totalLines = optimized.reduce(0) { $0 + $1.sourceCount }
        onProgress?("完成！\(optimized.count) 个频道，\(totalLines) 条线路")

        return (optimized, nil)
    }

    /// 智能模式：前 2 源竞速出画 → 后台全量融合（更激进 + 可重复启动）
    private func smartMode(sourceUrls: [String], requestSession: Int) async -> ([Channel], String?) {
        onProgress?("智能模式：快速启动...")

        var firstBatch: [Channel] = []
        // 前 2 个源竞速，谁先出结果用谁（更快）
        let raceUrls = Array(sourceUrls.prefix(2))
        if !raceUrls.isEmpty {
            let (firstChannels, _) = await NetworkService.shared.fetchWithCandidates(urls: raceUrls)
            guard requestSession == session else { return ([], nil) }
            if !firstChannels.isEmpty {
                firstBatch = mergeChannels(firstChannels)
                onProgress?("已加载 \(firstBatch.count) 个频道，后台继续融合...")
            }
        }

        let urls = sourceUrls
        // 独立 Task：不阻塞首批返回；session 变化则丢弃（支持反复切换融合模式）
        Task { @MainActor [urls, requestSession] in
            let allChannels = await self.loadAllSources(urls)
            guard requestSession == self.session else { return }
            guard !allChannels.isEmpty else { return }
            self.onProgress?("正在合并所有频道...")
            let merged = self.mergeChannels(allChannels)
            let optimized = LineReputationStore.shared.applyToChannels(merged)
            guard requestSession == self.session else { return }
            let totalLines = optimized.reduce(0) { $0 + $1.sourceCount }
            self.onProgress?("融合完成！\(optimized.count) 台 / \(totalLines) 线")
            NotificationCenter.default.post(
                name: .channelsOptimized,
                object: optimized,
                userInfo: ["session": requestSession]
            )
        }

        guard requestSession == session else { return ([], nil) }

        if !firstBatch.isEmpty {
            return (firstBatch, nil)
        }

        let allChannels = await loadAllSources(sourceUrls)
        guard requestSession == session else { return ([], nil) }
        if allChannels.isEmpty {
            return ([], "所有源均加载失败")
        }
        let merged = mergeChannels(allChannels)
        return (merged, nil)
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

        // 融合结果先套信誉：黑名单后置、偏好前置（与自动换线同一记忆）
        return LineReputationStore.shared.applyToChannels(Array(map.values))
    }

    /// 优化频道：以历史起播信誉为主；HEAD 测速仅作弱信号且只抽样前几条
    private func optimizeChannels(_ channels: [Channel]) async -> [Channel] {
        let rep = LineReputationStore.shared
        // 默认：只按信誉排序，最快
        var base = rep.applyToChannels(channels)

        // complete 模式才做极轻量抽样探测（每台最多 3 条，且跳过黑名单）
        // 探测结果不覆盖「真实起播失败」的黑名单，只微调未知线顺序
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
            // HEAD 只作弱信号：不可用的往后排，但不拉黑（拉黑只由真实播放决定）
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

// MARK: - 通知名称

extension Notification.Name {
    static let channelsOptimized = Notification.Name("channelsOptimized")
    /// 首源批次就绪（智能模式快速出画）
    static let channelsFirstBatch = Notification.Name("channelsFirstBatch")
}
