import Foundation

/// 线路质量数据
struct LineQuality: Codable {
    let url: String
    var responseTime: Int  // 毫秒
    var isAvailable: Bool
    var lastChecked: Date

    var score: Int {
        if !isAvailable { return Int.max }
        return responseTime
    }
}

/// 线路速度检测器
@MainActor
final class LineSpeedTester {
    static let shared = LineSpeedTester()

    private let session: URLSession
    private let timeout: TimeInterval = 5.0
    private var cache: [String: LineQuality] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"
        ]
        self.session = URLSession(configuration: config)
    }

    /// 弱探测：HEAD 仅作参考；最终「可播」以 AVPlayer 起播成败为准
    func testLine(_ url: String) async -> LineQuality {
        let rep = LineReputationStore.shared
        // 真实播放黑名单 → 弱探测直接失败
        if rep.isBlacklisted(url) {
            return LineQuality(url: url, responseTime: Int.max, isAvailable: false, lastChecked: Date())
        }
        // 历史起播成功较多 → 跳过 HEAD
        let score = rep.score(for: url)
        if score < 100_000 {
            if let cached = cache[url], Date().timeIntervalSince(cached.lastChecked) < 600 {
                return cached
            }
            let q = LineQuality(url: url, responseTime: max(50, score / 100), isAvailable: true, lastChecked: Date())
            cache[url] = q
            return q
        }

        if let cached = cache[url],
           Date().timeIntervalSince(cached.lastChecked) < 300 {
            return cached
        }

        guard let u = URL(string: url) else {
            return LineQuality(url: url, responseTime: Int.max, isAvailable: false, lastChecked: Date())
        }

        // 部分 CDN 不支持 HEAD → 再试 Range GET
        let start = Date()
        if let q = await probe(url: u, method: "HEAD", start: start) {
            cache[url] = q
            return q
        }
        if let q = await probe(url: u, method: "GET", start: start, range: true) {
            cache[url] = q
            return q
        }
        return LineQuality(url: url, responseTime: Int.max, isAvailable: false, lastChecked: Date())
    }

    private func probe(url: URL, method: String, start: Date, range: Bool = false) async -> LineQuality? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if range {
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }
        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else { return nil }
            // 2xx / 3xx / 206 都算「源可达」——仍只是弱信号
            guard (200...399).contains(http.statusCode) else { return nil }
            return LineQuality(url: url.absoluteString, responseTime: elapsed, isAvailable: true, lastChecked: Date())
        } catch {
            return nil
        }
    }

    /// 批量测试多条线路（并发）
    func testLines(_ urls: [String], maxConcurrent: Int = 8) async -> [LineQuality] {
        var results: [LineQuality] = []

        // 分批并发测试
        for batch in urls.chunked(into: maxConcurrent) {
            let batchResults = await withTaskGroup(of: LineQuality.self) { group in
                for url in batch {
                    group.addTask {
                        await self.testLine(url)
                    }
                }

                var collected: [LineQuality] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            results.append(contentsOf: batchResults)
        }

        return results
    }

    /// 清除缓存
    func clearCache() {
        cache.removeAll()
    }
}

// MARK: - 辅助扩展

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
