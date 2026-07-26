import Foundation

/// 线路信誉：融合排序 + 自动换线共用，避免两边各记一套、互相打架。
/// - 播放成功：加分、记偏好、清黑名单
/// - 播放失败：减分、短时拉黑（默认 24h）
/// - 融合/换线都读同一份记忆，跨天有效
@MainActor
final class LineReputationStore {
    static let shared = LineReputationStore()

    struct Entry: Codable {
        var url: String
        var successCount: Int = 0
        var failCount: Int = 0
        var lastSuccessAt: Date?
        var lastFailAt: Date?
        var blacklistedUntil: Date?
    }

    private let defaults = UserDefaults.standard
    private let kEntries = "line_reputation_v1"
    private let kPreferred = "line_preferred_by_channel_v1"

    /// 硬失败后默认拉黑时长
    var blacklistDuration: TimeInterval = 24 * 3600
    /// 成功一次可抵消的失败权重
    private let successWeight = 3

    private var entries: [String: Entry] = [:]
    private var preferredURLByChannelKey: [String: String] = [:]
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        load()
    }

    // MARK: - Query

    func isBlacklisted(_ url: String) -> Bool {
        guard let e = entries[normalize(url)] else { return false }
        guard let until = e.blacklistedUntil else { return false }
        if until > Date() { return true }
        // 过期自动解禁（保留历史计数）
        return false
    }

    func preferredURL(forChannelKey key: String) -> String? {
        preferredURLByChannelKey[key]
    }

    /// 分数越小越好（类似测速 score）
    func score(for url: String) -> Int {
        let key = normalize(url)
        if isBlacklisted(key) { return Int.max - 1 }
        guard let e = entries[key] else { return 500_000 } // 未知居中
        if e.successCount == 0 && e.failCount == 0 { return 500_000 }
        // 成功多、失败少 → 低分
        let base = e.failCount * 10_000 - e.successCount * successWeight * 1_000
        // 最近成功加权
        var bonus = 0
        if let s = e.lastSuccessAt, Date().timeIntervalSince(s) < 7 * 86400 {
            bonus -= 2_000
        }
        if let f = e.lastFailAt, Date().timeIntervalSince(f) < 86400 {
            bonus += 5_000
        }
        return max(0, base + bonus)
    }

    // MARK: - Record

    func markSuccess(url: String, channelKey: String?) {
        let u = normalize(url)
        guard !u.isEmpty else { return }
        var e = entries[u] ?? Entry(url: u)
        e.successCount += 1
        e.lastSuccessAt = Date()
        e.blacklistedUntil = nil
        entries[u] = e
        if let channelKey, !channelKey.isEmpty {
            preferredURLByChannelKey[channelKey] = u
        }
        save()
    }

    func markFailure(url: String, channelKey: String?, hard: Bool = true) {
        let u = normalize(url)
        guard !u.isEmpty else { return }
        var e = entries[u] ?? Entry(url: u)
        e.failCount += 1
        e.lastFailAt = Date()
        if hard {
            e.blacklistedUntil = Date().addingTimeInterval(blacklistDuration)
        }
        entries[u] = e
        // 失败则清掉该频道对该 URL 的偏好
        if let channelKey,
           preferredURLByChannelKey[channelKey] == u {
            preferredURLByChannelKey.removeValue(forKey: channelKey)
        }
        save()
    }

    // MARK: - Sort / Filter for fusion & playback

    /// 按信誉重排线路：偏好 → 未拉黑高分 → 未知 → 拉黑垫底
    func orderedURLs(_ urls: [String], channelKey: String?) -> [String] {
        guard !urls.isEmpty else { return [] }
        let pref = channelKey.flatMap { preferredURLByChannelKey[$0] }

        var seen = Set<String>()
        var unique: [String] = []
        for u in urls {
            let n = normalize(u)
            guard !n.isEmpty, !seen.contains(n) else { continue }
            seen.insert(n)
            unique.append(n)
        }

        return unique.sorted { a, b in
            if let pref {
                if a == pref && b != pref { return true }
                if b == pref && a != pref { return false }
            }
            let ba = isBlacklisted(a)
            let bb = isBlacklisted(b)
            if ba != bb { return !ba && bb }
            return score(for: a) < score(for: b)
        }
    }

    /// 过滤掉仍在黑名单内的线；若全被拉黑则保留全部（最后手段）
    func filterPlayable(_ urls: [String]) -> [String] {
        let alive = urls.filter { !isBlacklisted($0) }
        return alive.isEmpty ? urls : alive
    }

    /// 给频道列表统一套信誉排序（融合输出后调用）
    func applyToChannels(_ channels: [Channel]) -> [Channel] {
        channels.map { ch in
            let ordered = orderedURLs(ch.urls, channelKey: ch.key)
            var nc = Channel(name: ch.name, group: ch.group, key: ch.key)
            nc.addUrls(ordered)
            return nc
        }
    }

    /// 清理过期黑名单与过旧条目（可选维护）
    func prune(maxAge: TimeInterval = 30 * 86400) {
        let now = Date()
        entries = entries.filter { _, e in
            let last = max(e.lastSuccessAt ?? .distantPast, e.lastFailAt ?? .distantPast)
            return now.timeIntervalSince(last) < maxAge || (e.blacklistedUntil ?? .distantPast) > now
        }
        save()
    }

    // MARK: - Persistence

    private func normalize(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        if let data = defaults.data(forKey: kEntries),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
        if let pref = defaults.dictionary(forKey: kPreferred) as? [String: String] {
            preferredURLByChannelKey = pref
        }
        // 解禁过期
        let now = Date()
        for (k, var e) in entries {
            if let until = e.blacklistedUntil, until <= now {
                e.blacklistedUntil = nil
                entries[k] = e
            }
        }
    }

    private func save() {
        // 防抖落盘，避免换线连点时频繁写 UserDefaults
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(self.entries) {
                self.defaults.set(data, forKey: self.kEntries)
            }
            self.defaults.set(self.preferredURLByChannelKey, forKey: self.kPreferred)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// 进程退出前可调用，立刻刷盘
    func flush() {
        saveWorkItem?.cancel()
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: kEntries)
        }
        defaults.set(preferredURLByChannelKey, forKey: kPreferred)
    }
}
