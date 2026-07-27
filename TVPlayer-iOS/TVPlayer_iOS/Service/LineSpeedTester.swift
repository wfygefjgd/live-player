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

    /// 起播前快速预检：1.5s 内拉到首包才值得交给 AVPlayer（死链可跳过等待）
    func quickPreflight(_ url: String, timeout: TimeInterval = 1.5) async -> Bool {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        // 短缓存：同一死链短时间不重复打
        if let cached = cache[url], Date().timeIntervalSince(cached.lastChecked) < 60 {
            return cached.isAvailable
        }
        let start = Date()
        if let q = await probe(url: u, method: "GET", start: start, range: true, timeout: timeout) {
            cache[url] = q
            return q.isAvailable
        }
        // GET 失败再试一次不带 Range（部分源拒 Range）
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200...399).contains(code) && data.count > 0
            cache[url] = LineQuality(
                url: url,
                responseTime: Int(Date().timeIntervalSince(start) * 1000),
                isAvailable: ok,
                lastChecked: Date()
            )
            return ok
        } catch {
            cache[url] = LineQuality(
                url: url, responseTime: Int.max, isAvailable: false, lastChecked: Date()
            )
            return false
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
