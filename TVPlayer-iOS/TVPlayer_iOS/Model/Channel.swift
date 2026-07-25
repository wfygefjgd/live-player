import Foundation

// MARK: - 预验证频道 JSON 响应结构
struct ValidatedChannelsResponse: Codable {
    let channels: [ValidatedChannel]
    let metadata: ValidationMetadata?
}

struct ValidatedChannel: Codable {
    let name: String
    let group: String
    let urls: [String]
}

struct ValidationMetadata: Codable {
    let totalChannels: Int
    let validChannels: Int
    let totalUrlsTested: Int
    let totalValidUrls: Int
    let validatedAt: String
    let maxUrlsPerChannel: Int
    let sources: [String]

    enum CodingKeys: String, CodingKey {
        case totalChannels = "total_channels"
        case validChannels = "valid_channels"
        case totalUrlsTested = "total_urls_tested"
        case totalValidUrls = "total_valid_urls"
        case validatedAt = "validated_at"
        case maxUrlsPerChannel = "max_urls_per_channel"
        case sources
    }
}

/// 频道数据模型 — 值类型，线程安全，Codable
struct Channel: Codable, Identifiable, Equatable, Hashable {
    /// 稳定 id：用 key 避免列表 diff 闪烁
    var id: String { key }

    let name: String
    let group: String
    let key: String
    private(set) var urls: [String]

    enum CodingKeys: String, CodingKey {
        case name, group, key, urls
    }

    init(name: String, group: String = "未分组", key: String? = nil, urls: [String]? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        self.name = trimmedName.isEmpty ? "未知" : trimmedName
        let trimmedGroup = group.trimmingCharacters(in: .whitespaces)
        self.group = trimmedGroup.isEmpty ? "未分组" : trimmedGroup
        self.key = (key?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? M3UParserService.normalizeName(trimmedName)
        self.urls = []
        if let urls {
            for u in urls {
                addUrl(u)
            }
        }
    }

    /// 添加 URL（去重 + 清理）
    mutating func addUrl(_ url: String) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !urls.contains(clean) else { return }
        urls.append(clean)
    }

    /// 批量添加 URL
    mutating func addUrls(_ newUrls: [String]) {
        for u in newUrls {
            addUrl(u)
        }
    }

    /// 删除指定 URL
    mutating func removeUrl(_ url: String) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        urls.removeAll { $0 == clean }
    }

    var sourceCount: Int { urls.count }

    var primaryUrl: String { urls.first ?? "" }

    var isEmpty: Bool { urls.isEmpty }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

    // MARK: - Equatable

    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.key == rhs.key
    }

    /// 合并两个同名频道的 URL
    mutating func merge(with other: Channel) {
        for url in other.urls {
            addUrl(url)
        }
    }
}
