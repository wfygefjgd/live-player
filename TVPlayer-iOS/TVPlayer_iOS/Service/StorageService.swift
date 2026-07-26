import Foundation

final class StorageService {
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "StorageService", qos: .utility, attributes: .concurrent)

    // Keys
    private let kChannels = "channels_cache"
    private let kChannelsMeta = "channels_meta"       // 元数据（版本、数量、更新时间）
    private let kSourceUrls = "source_urls"
    private let kSelectedSource = "selected_source_url"
    private let kCustomSource = "custom_source_url"
    private let kHiddenLines = "hidden_lines"
    private let kFavorites = "favorites"
    private let kLastChannelKey = "last_channel_key"
    private let kLastSourceIndex = "last_source_index"
    private let kDataVersion = "data_version"

    private let currentDataVersion = 1

    // 元数据结构
    private struct ChannelsMeta: Codable {
        let version: Int
        let count: Int
        let updatedAt: Date
    }

    // MARK: - 频道缓存（异步 + 分批）

    func saveChannels(_ channels: [Channel]) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let data = try? JSONEncoder().encode(channels)
            self.defaults.set(data, forKey: self.kChannels)

            // 保存元数据
            let meta = ChannelsMeta(version: self.currentDataVersion,
                                    count: channels.count,
                                    updatedAt: Date())
            if let metaData = try? JSONEncoder().encode(meta) {
                self.defaults.set(metaData, forKey: self.kChannelsMeta)
            }
            self.defaults.set(self.currentDataVersion, forKey: self.kDataVersion)
        }
    }

    func loadChannels() -> [Channel] {
        queue.sync {
            // 检查数据版本，必要时迁移
            let savedVersion = defaults.integer(forKey: kDataVersion)
            if savedVersion < currentDataVersion {
                migrateData(from: savedVersion)
            }

            guard let data = defaults.data(forKey: kChannels),
                  let channels = try? JSONDecoder().decode([Channel].self, from: data) else {
                return []
            }
            return channels
        }
    }

    /// 快速检查是否有缓存（不加载全部数据）
    func hasCachedChannels() -> Bool {
        queue.sync {
            guard defaults.data(forKey: kChannels) != nil else { return false }
            if let metaData = defaults.data(forKey: kChannelsMeta),
               let meta = try? JSONDecoder().decode(ChannelsMeta.self, from: metaData) {
                return meta.count > 0
            }
            return true
        }
    }

    /// 缓存是否过期（超过 24h 返回 true）
    func isCacheStale(maxAge: TimeInterval = 86400) -> Bool {
        queue.sync {
            if let metaData = defaults.data(forKey: kChannelsMeta),
               let meta = try? JSONDecoder().decode(ChannelsMeta.self, from: metaData) {
                return Date().timeIntervalSince(meta.updatedAt) > maxAge
            }
            return true
        }
    }

    // MARK: - 数据迁移

    private func migrateData(from oldVersion: Int) {
        // v0 → v1: 无旧数据结构，直接清理
        if oldVersion < 1 {
            // 未来版本可以在这里做结构迁移
        }
        defaults.set(currentDataVersion, forKey: kDataVersion)
    }

    // MARK: - 源地址管理

    func saveSourceUrls(_ urls: [String]) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(urls, forKey: self.kSourceUrls)
        }
    }

    func loadSourceUrls() -> [String] {
        queue.sync {
            defaults.stringArray(forKey: kSourceUrls) ?? []
        }
    }

    func saveSelectedSourceUrl(_ url: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(url, forKey: self.kSelectedSource)
        }
    }

    func loadSelectedSourceUrl() -> String {
        queue.sync {
            defaults.string(forKey: kSelectedSource) ?? ""
        }
    }

    func saveCustomSourceUrl(_ url: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(url, forKey: self.kCustomSource)
        }
    }

    func loadCustomSourceUrl() -> String {
        queue.sync {
            defaults.string(forKey: kCustomSource) ?? ""
        }
    }

    // MARK: - 隐藏线路

    func loadHiddenLines() -> Set<String> {
        queue.sync {
            Set(defaults.stringArray(forKey: kHiddenLines) ?? [])
        }
    }

    /// 同步写入，保证随后 isLineHidden / applyRules 立刻可见
    func hideLine(_ url: String) {
        let clean = url.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        queue.sync(flags: .barrier) {
            var lines = Set(defaults.stringArray(forKey: kHiddenLines) ?? [])
            lines.insert(clean)
            defaults.set(Array(lines), forKey: kHiddenLines)
        }
    }

    func isLineHidden(_ url: String) -> Bool {
        queue.sync {
            let lines = Set(defaults.stringArray(forKey: kHiddenLines) ?? [])
            return lines.contains(url.trimmingCharacters(in: .whitespaces))
        }
    }

    func unhideAllLines() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.removeObject(forKey: self.kHiddenLines)
        }
    }

    func removeSourceUrl(_ url: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            var urls = self.defaults.stringArray(forKey: self.kSourceUrls) ?? []
            urls.removeAll { $0 == url }
            self.defaults.set(urls, forKey: self.kSourceUrls)
        }
    }

    // MARK: - 收藏

    func loadFavorites() -> Set<String> {
        queue.sync {
            Set(defaults.stringArray(forKey: kFavorites) ?? [])
        }
    }

    func toggleFavorite(_ key: String) -> Bool {
        queue.sync {
            var fav = Set(defaults.stringArray(forKey: kFavorites) ?? [])
            if fav.contains(key) {
                fav.remove(key)
                defaults.set(Array(fav), forKey: kFavorites)
                return false
            }
            fav.insert(key)
            defaults.set(Array(fav), forKey: kFavorites)
            return true
        }
    }

    func isFavorite(_ key: String) -> Bool {
        queue.sync {
            let fav = Set(defaults.stringArray(forKey: kFavorites) ?? [])
            return fav.contains(key)
        }
    }

    // MARK: - 上次播放位置

    func saveLastChannel(key: String, sourceIndex: Int) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(key, forKey: self.kLastChannelKey)
            self.defaults.set(sourceIndex, forKey: self.kLastSourceIndex)
        }
    }

    func loadLastChannelKey() -> String {
        queue.sync {
            defaults.string(forKey: kLastChannelKey) ?? ""
        }
    }

    func loadLastSourceIndex() -> Int {
        queue.sync {
            defaults.integer(forKey: kLastSourceIndex)
        }
    }

    // MARK: - 全量清理（用于恢复出厂）

    func clearAll() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            for key in [self.kChannels, self.kChannelsMeta, self.kSourceUrls,
                        self.kSelectedSource, self.kCustomSource, self.kHiddenLines,
                        self.kFavorites, self.kLastChannelKey, self.kLastSourceIndex,
                        self.kDataVersion] {
                self.defaults.removeObject(forKey: key)
            }
        }
    }
}
