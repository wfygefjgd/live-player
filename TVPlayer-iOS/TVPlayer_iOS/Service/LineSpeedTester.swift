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

/// 预检结果：只有 hardFail 才跳过；unknown 仍交给 AVPlayer
enum PreflightResult {
    case ok
    case hardFail   // 明确死链：404/403/连接失败
    case unknown    // 超时/慢/拒 HEAD：不判死，继续播
}

/// 线路速度检测器
@MainActor
final class LineSpeedTester {
    static let shared = LineSpeedTester()

    private let session: URLSession
    private let timeout: TimeInterval = 5.0
    private var cache: [String: LineQuality] = [:]
    /// hardFail 才缓存为不可用；unknown 不缓存，避免误杀
    private var hardFailCache: [String: Date] = [:]

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
        if let cached = cache[url],
           Date().timeIntervalSince(cached.lastChecked) < 300 {
            return cached
        }

        guard let u = URL(string: url) else {
            return LineQuality(url: url, responseTime: Int.max, isAvailable: false, lastChecked: Date())
        }

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

    /// 起播前预检：仅 hardFail 跳过；超时/慢线返回 unknown，交给播放器
    func quickPreflight(_ url: String, timeout: TimeInterval = 2.5) async -> PreflightResult {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .hardFail
        }
        if let t = hardFailCache[url], Date().timeIntervalSince(t) < 120 {
            return .hardFail
        }
        if let cached = cache[url], cached.isAvailable,
           Date().timeIntervalSince(cached.lastChecked) < 120 {
            return .ok
        }

        let start = Date()
        // 单次 Range 请求使用完整预检预算；拿到响应头后立即结束，不下载直播响应体。
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        do {
            let (_, resp) = try await session.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 || code == 403 || code == 410 || code == 451 {
                hardFailCache[url] = Date()
                cache[url] = LineQuality(url: url, responseTime: Int.max, isAvailable: false, lastChecked: Date())
                return .hardFail
            }
            if (200...399).contains(code) {
                cache[url] = LineQuality(
                    url: url,
                    responseTime: Int(Date().timeIntervalSince(start) * 1000),
                    isAvailable: true,
                    lastChecked: Date()
                )
                return .ok
            }
            // 其它状态或超时：未知，仍尝试播放，不叠加第二轮探测。
            return .unknown
        } catch let err as URLError {
            switch err.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet:
                // 超时/连不上：多数是慢或临时网络，不当 hardFail（否则可播率崩）
                // 仅「明确无法解析的非法 host」才 hard——这里统一 unknown，让 AVPlayer 再试
                if err.code == .cannotFindHost || err.code == .dnsLookupFailed {
                    hardFailCache[url] = Date()
                    return .hardFail
                }
                return .unknown
            default:
                return .unknown
            }
        } catch {
            return .unknown
        }
    }

    private func probe(url: URL, method: String, start: Date, range: Bool = false, timeout: TimeInterval? = nil) async -> LineQuality? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? self.timeout
        if range {
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }
        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 || http.statusCode == 403 || http.statusCode == 410 {
                return nil
            }
            guard (200...399).contains(http.statusCode) else { return nil }
            return LineQuality(url: url.absoluteString, responseTime: elapsed, isAvailable: true, lastChecked: Date())
        } catch {
            return nil
        }
    }

    /// 批量测试多条线路（并发）
    func testLines(_ urls: [String], maxConcurrent: Int = 8) async -> [LineQuality] {
        var results: [LineQuality] = []
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

    func clearCache() {
        cache.removeAll()
        hardFailCache.removeAll()
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
