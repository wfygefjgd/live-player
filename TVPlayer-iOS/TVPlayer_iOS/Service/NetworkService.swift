import Foundation
import Network

enum NetworkFetchError: LocalizedError {
    case invalidURL
    case badResponse
    case emptyBody
    case parseEmpty
    case allFailed
    case noNetwork

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "地址无效"
        case .badResponse: return "服务器响应异常"
        case .emptyBody: return "内容为空"
        case .parseEmpty: return "解析不到频道"
        case .allFailed: return "所有源均加载失败"
        case .noNetwork: return "网络不可用"
        }
    }
}

final class NetworkService {
    static let shared = NetworkService()

    private let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
    private let timeout: TimeInterval = 15

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 2
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData  // 🆕 强制不使用缓存
        cfg.urlCache = URLCache(
            memoryCapacity: 2 * 1024 * 1024,    // 🆕 减小内存缓存到2MB
            diskCapacity: 0,                     // 🆕 禁用磁盘缓存
            diskPath: nil
        )
        cfg.httpAdditionalHeaders = ["User-Agent": ua]
        return URLSession(configuration: cfg)
    }()

    // 网络状态监听
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    private var isNetworkAvailable = true
    private var pendingRetry: (() -> Void)?
    private var retryTask: Task<Void, Never>?

    private init() {
        startNetworkMonitor()
        setupCacheCleanup()  // 🆕 设置缓存清理
    }

    // 🆕 定时清理缓存机制
    private func setupCacheCleanup() {
        // App进入后台时清理缓存
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearCache()
        }

        // App收到内存警告时清理缓存
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearCache()
        }
    }

    // 🆕 清理缓存
    func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        monitor.cancel()
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = path.status == .satisfied
            let wasUnavailable = !self.isNetworkAvailable
            self.isNetworkAvailable = available

            if available && wasUnavailable {
                // 网络恢复，触发重试
                DispatchQueue.main.async { [weak self] in
                    self?.pendingRetry?()
                    self?.pendingRetry = nil
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// 注册网络恢复时的重试回调
    func onNetworkAvailable(_ retry: @escaping () -> Void) {
        if isNetworkAvailable {
            retry()
        } else {
            pendingRetry = { [weak self] in
                guard let self, self.isNetworkAvailable else { return }
                retry()
            }
        }
    }

    func fetch(url: String) async throws -> String {
        guard let u = URL(string: url), u.scheme != nil else {
            throw NetworkFetchError.invalidURL
        }

        if !isNetworkAvailable {
            throw NetworkFetchError.noNetwork
        }

        var request = URLRequest(url: u, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NetworkFetchError.badResponse
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            if let text2 = String(data: data, encoding: .isoLatin1), !text2.isEmpty {
                return text2
            }
            throw NetworkFetchError.emptyBody
        }
        return text
    }

    /// 所有候选源竞速：谁先解析出频道用谁
    func fetchWithCandidates(urls: [String]) async -> (channels: [Channel], errorMessage: String?) {
        guard !urls.isEmpty else {
            return ([], NetworkFetchError.allFailed.errorDescription)
        }

        // 全部并发竞速
        if let raced = await raceFetch(urls: urls) {
            return (raced, nil)
        }

        // 全部失败，返回错误
        var lastError: String?
        for url in urls {
            do {
                let body = try await fetch(url: url)
                let parsed = await parseOffMain(body)
                if parsed.isEmpty {
                    lastError = NetworkFetchError.parseEmpty.errorDescription
                    continue
                }
                return (parsed, nil)
            } catch let e as NetworkFetchError {
                lastError = e.errorDescription
            } catch {
                lastError = error.localizedDescription
            }
        }
        return ([], lastError ?? NetworkFetchError.allFailed.errorDescription)
    }

    /// 并发请求所有 URL，取最快返回的频道列表
    private func raceFetch(urls: [String]) async -> [Channel]? {
        await withTaskGroup(of: [Channel]?.self) { group in
            for url in urls {
                group.addTask {
                    do {
                        let body = try await self.fetch(url: url)
                        let parsed = await self.parseOffMain(body)
                        return parsed.isEmpty ? nil : parsed
                    } catch {
                        return nil
                    }
                }
            }
            // 取第一个成功结果
            for await result in group {
                if let channels = result, !channels.isEmpty {
                    group.cancelAll()
                    return channels
                }
            }
            return nil
        }
    }

    private func parseOffMain(_ body: String) async -> [Channel] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: M3UParserService.parse(body))
            }
        }
    }

    /// 带退避的重试加载（用于网络恢复后）
    func retryLoadWithBackoff(
        urls: [String],
        maxRetries: Int = 3,
        onResult: @escaping ([Channel], String?) -> Void
    ) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while attempt < maxRetries, !Task.isCancelled {
                let (channels, _) = await self.fetchWithCandidates(urls: urls)
                if !channels.isEmpty {
                    await MainActor.run { onResult(channels, nil) }
                    return
                }
                attempt += 1
                if attempt < maxRetries {
                    let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
            await MainActor.run {
                onResult([], "加载失败，请检查网络")
            }
        }
    }

    func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }
}
