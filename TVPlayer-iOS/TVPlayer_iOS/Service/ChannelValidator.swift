import Foundation
import AVFoundation

// MARK: - 频道验证结果
struct ValidationResult: Codable {
    var validChannels: [String: [String]]  // [频道名: [可用URL]]
    var totalTested: Int
    var validCount: Int
    var timestamp: Date
}

// MARK: - 频道验证服务
@MainActor
final class ChannelValidator: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var testedCount: Int = 0
    @Published var totalCount: Int = 0
    @Published var isValidating: Bool = false

    private var validationTask: Task<Void, Never>?

    // 验证超时时间（秒）- 缩短到3秒快速失败
    private let validationTimeout: TimeInterval = 3.0

    // 并发验证数量 - 提高到50并发
    private let concurrentValidations = 50

    func validateAllChannels(_ channels: [Channel]) async -> ValidationResult {
        isValidating = true
        totalCount = channels.reduce(0) { $0 + $1.urls.count }
        testedCount = 0
        progress = 0.0

        var validChannels: [String: [String]] = [:]
        var validCount = 0

        // 并发验证所有频道的所有线路
        await withTaskGroup(of: (String, String, Bool).self) { group in
            var pendingValidations: [(Channel, String)] = []

            // 收集所有待验证的频道-URL对
            for channel in channels {
                for url in channel.urls {
                    pendingValidations.append((channel, url))
                }
            }

            // 分批并发验证
            for (channel, url) in pendingValidations {
                group.addTask {
                    let isValid = await self.validateURL(url)
                    await MainActor.run {
                        self.testedCount += 1
                        self.progress = Double(self.testedCount) / Double(self.totalCount)
                    }
                    return (channel.name, url, isValid)
                }

                // 控制并发数
                if group.isEmpty == false && pendingValidations.count > self.concurrentValidations {
                    if let result = await group.next() {
                        if result.2 {
                            validChannels[result.0, default: []].append(result.1)
                            validCount += 1
                        }
                    }
                }
            }

            // 收集剩余结果
            for await result in group {
                if result.2 {
                    validChannels[result.0, default: []].append(result.1)
                    validCount += 1
                }
            }
        }

        isValidating = false

        return ValidationResult(
            validChannels: validChannels,
            totalTested: totalCount,
            validCount: validCount,
            timestamp: Date()
        )
    }

    // 验证单个 URL 是否可用
    private func validateURL(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }

        // 使用 HEAD 请求快速检测
        var request = URLRequest(url: url, timeoutInterval: validationTimeout)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    func cancel() {
        validationTask?.cancel()
        isValidating = false
    }
}

// MARK: - 验证结果存储
final class ValidationStorage {
    static let shared = ValidationStorage()
    private let key = "channel_validation_result"

    func save(_ result: ValidationResult) {
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func load() -> ValidationResult? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let result = try? JSONDecoder().decode(ValidationResult.self, from: data) else {
            return nil
        }
        return result
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    func hasValidation() -> Bool {
        return load() != nil
    }
}
