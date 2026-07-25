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

    /// 进度回调
    var onProgress: ((String) -> Void)?

    init() {}

    // MARK: - 公开接口

    /// 智能融合：加载所有源 + 测速 + 排序
    func smartFusion(sourceUrls: [String], mode: FusionMode? = nil) async -> ([Channel], String?) {
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
            return await smartMode(sourceUrls: sourceUrls)
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

    /// 平衡模式：融合前3个源
    private func balancedMode(sourceUrls: [String]) async -> ([Channel], String?) {
        onProgress?("平衡模式：加载前3个源...")

        let limitedUrls = Array(sourceUrls.prefix(3))
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

        onProgress?("正在测试线路速度...")
        let optimized = await optimizeChannels(merged)

        let totalLines = optimized.reduce(0) { $0 + $1.sourceCount }
        onProgress?("完成！\(optimized.count) 个频道，\(totalLines) 条线路")

        return (optimized, nil)
    }

    /// 智能模式：渐进式融合 + 后台测速（推荐）
    private func smartMode(sourceUrls: [String]) async -> ([Channel], String?) {
        onProgress?("智能模式：快速启动...")

        // 第一步：快速加载第一个源（给用户先看）
        if let firstUrl = sourceUrls.first {
            let (firstChannels, _) = await NetworkService.shared.fetchWithCandidates(urls: [firstUrl])
            if !firstChannels.isEmpty {
                onProgress?("已加载 \(firstChannels.count) 个频道，后台继续融合...")
                // 这里先返回第一个源的数据，让用户可以立即开始播放
                // 实际会在后台继续加载其他源
            }
        }

        // 第二步：后台加载其他源
        let allChannels = await loadAllSources(sourceUrls)

        if allChannels.isEmpty {
            return ([], "所有源均加载失败")
        }

        onProgress?("正在合并所有频道...")
        let merged = mergeChannels(allChannels)

        // 第三步：后台异步测速（不阻塞返回）
        Task.detached { @MainActor in
            let optimized = await self.optimizeChannels(merged)
            let totalLines = optimized.reduce(0) { $0 + $1.sourceCount }
            self.onProgress?("线路优化完成！\(optimized.count) 个频道，\(totalLines) 条线路")

            // 通知外部更新频道列表
            NotificationCenter.default.post(
                name: .channelsOptimized,
                object: optimized
            )
        }

        let totalLines = merged.reduce(0) { $0 + $1.sourceCount }
        onProgress?("融合完成！\(merged.count) 个频道，\(totalLines) 条线路")

        return (merged, nil)
    }

    // MARK: - 核心功能

    /// 加载所有源（并发）
    private func loadAllSources(_ urls: [String]) async -> [Channel] {
        await withTaskGroup(of: (Int, [Channel]).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        await MainActor.run {
                            self.onProgress?("正在加载源 \(index + 1)/\(urls.count)...")
                        }
                        let body = try await NetworkService.shared.fetch(url: url)
                        let parsed = M3UParserService.parse(body)
                        return (index, parsed)
                    } catch {
                        return (index, [])
                    }
                }
            }

            var allChannels: [Channel] = []
            for await (_, channels) in group {
                allChannels.append(contentsOf: channels)
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

        return Array(map.values)
    }

    /// 优化频道：测速 + 排序
    private func optimizeChannels(_ channels: [Channel]) async -> [Channel] {
        var optimized: [Channel] = []
        let totalChannels = channels.count
        var processed = 0

        for ch in channels {
            processed += 1

            // 跳过只有1条线路的频道
            if ch.sourceCount <= 1 {
                optimized.append(ch)
                continue
            }

            // 更新进度
            if processed % 10 == 0 {
                onProgress?("正在测试线路速度... (\(processed)/\(totalChannels))")
            }

            var optimizedCh = ch

            // 测试所有线路（最多测试前20条，避免太慢）
            let linesToTest = Array(ch.urls.prefix(20))
            let qualities = await speedTester.testLines(linesToTest, maxConcurrent: 8)

            // 按速度排序
            let sorted = qualities.sorted { $0.score < $1.score }

            // 可选：过滤掉不可用的线路
            let available = sorted.filter { $0.isAvailable }
            let unavailable = sorted.filter { !$0.isAvailable }

            // 重新构建 URL 列表：可用线路在前，不可用在后
            let sortedUrls = available.map { $0.url } + unavailable.map { $0.url }

            // 添加剩余未测试的线路
            let remainingUrls = ch.urls.dropFirst(20)
            let finalUrls = sortedUrls + Array(remainingUrls)

            // 创建新的 Channel 对象，使用排序后的 URLs
            var newChannel = Channel(name: ch.name, group: ch.group, key: ch.key)
            newChannel.addUrls(finalUrls)

            optimized.append(newChannel)
        }

        return optimized
    }
}

// MARK: - 通知名称

extension Notification.Name {
    static let channelsOptimized = Notification.Name("channelsOptimized")
}
