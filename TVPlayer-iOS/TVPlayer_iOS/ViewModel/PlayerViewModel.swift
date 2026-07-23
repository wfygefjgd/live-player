import SwiftUI
import AVKit

let DEFAULT_SOURCE_URL = "https://ghproxy.net/https://raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8"

private let CHANNEL_OSD_MS: UInt64 = 2_500_000_000
private let FLOAT_HIDE_MS: UInt64 = 2_500_000_000
private let INDICATOR_MS: UInt64 = 1_200_000_000
private let AUTO_SWITCH_COOLDOWN_NS: UInt64 = 4_000_000_000

let PRESET_SOURCES: [(name: String, url: String)] = [
    ("默认源", DEFAULT_SOURCE_URL),
    ("best-fan 全量", "https://ghproxy.net/https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8"),
    ("TVBox", "https://ghfast.top/raw.githubusercontent.com/Supprise0901/TVBox_live/main/live.txt"),
    ("vbskycn", "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/tv.m3u"),
    ("fanmingming", "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"),
]

private enum AutoSwitchState {
    case idle
    case switching
    case cooldown
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var currentIndex = 0
    @Published var currentSourceIndex = 0
    @Published var panelVisible = false
    @Published var locked = false
    @Published var showSourceSheet = false
    @Published var showDeleteAlert = false
    @Published var channelOSD: String = ""
    @Published var indicatorText: String = ""
    @Published var showFloatOverlay = false
    @Published var favorites: Set<String> = []
    @Published var isBootstrapping = false
    @Published var bootstrapMessage = "正在连接网络..."

    let player = PlayerEngine()
    private let storage = StorageService()
    private var rawChannels: [Channel] = []
    var sourceUrls: [String] = []
    var activeSourceUrl = DEFAULT_SOURCE_URL
    private var autoSwitchState: AutoSwitchState = .idle
    private var started = false
    private var triedLineIndices = Set<Int>()
    private var osdTask: Task<Void, Never>?
    private var indTask: Task<Void, Never>?
    private var floatTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var lastVolumeTranslation: CGFloat = 0
    private var loadGeneration = 0

    func startup() {
        guard !started else { return }
        started = true
        favorites = storage.loadFavorites()

        player.onReady = { [weak self] in
            Task { @MainActor in self?.onPlayerReady() }
        }
        player.onError = { [weak self] in
            Task { @MainActor in self?.onPlayerError() }
        }
        player.onStartupTimeout = { [weak self] in
            Task { @MainActor in self?.onStartupTimeout() }
        }
        player.onPlaybackStall = { [weak self] in
            Task { @MainActor in self?.onPlaybackStall() }
        }

        // 网络从无到有 / 首次点「允许」后自动再拉源
        NetworkMonitor.shared.onSatisfied = { [weak self] in
            Task { @MainActor in
                self?.onNetworkBecameAvailable()
            }
        }

        restoreSources()
        let cached = applyRules(storage.loadChannels())
        if !cached.isEmpty {
            channels = cached
            restoreLastChannelPosition()
            isBootstrapping = false
            playCurrent(showOSD: false, resetTried: true)
            loadChannels(force: true, silent: true, preferActiveOnly: false)
        } else {
            isBootstrapping = true
            bootstrapMessage = "正在加载频道列表..."
            showIndicator("加载中...")
            // 先等网络可用再拉，避免未授权就报错卡住
            beginBootstrapLoad()
        }
    }

    /// 首次无缓存：等待网络 → 拉源 → 失败自动重试
    private func beginBootstrapLoad() {
        retryTask?.cancel()
        if NetworkMonitor.shared.isSatisfied {
            loadChannels(force: true, silent: false, preferActiveOnly: true)
            return
        }
        bootstrapMessage = "等待网络连接（请允许访问网络）..."
        showIndicator("等待网络...")
        // 同时尝试拉一次（部分机型 path 报告滞后）
        loadChannels(force: true, silent: false, preferActiveOnly: true)
        scheduleRetryLoads()
    }

    private func scheduleRetryLoads() {
        // 已有重试任务在跑则不叠加
        if let t = retryTask, !t.isCancelled { return }
        retryTask = Task { @MainActor in
            // 授权后 1s / 3s / 6s 再试，之后每 5s 直到有频道
            for sec in [1, 3, 6] as [UInt64] {
                try? await Task.sleep(nanoseconds: sec * 1_000_000_000)
                guard !Task.isCancelled else { return }
                if !channels.isEmpty {
                    isBootstrapping = false
                    return
                }
                bootstrapMessage = "正在重新加载频道..."
                loadChannels(force: true, silent: false, preferActiveOnly: false)
            }
            while !Task.isCancelled {
                if !channels.isEmpty {
                    isBootstrapping = false
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                bootstrapMessage = "仍无频道，继续刷新..."
                loadChannels(force: true, silent: false, preferActiveOnly: false)
            }
        }
    }

    func onNetworkBecameAvailable() {
        if channels.isEmpty {
            bootstrapMessage = "网络已连接，加载频道..."
            isBootstrapping = true
            loadChannels(force: true, silent: false, preferActiveOnly: false)
        }
    }

    func onAppBecameActive() {
        if channels.isEmpty {
            retryLoadSources()
        }
    }

    /// 无频道时用户点「重新加载」或自动触发
    func retryLoadSources() {
        isBootstrapping = true
        bootstrapMessage = "正在加载频道列表..."
        showIndicator("加载中...")
        loadChannels(force: true, silent: false, preferActiveOnly: false)
        scheduleRetryLoads()
    }

    func restoreSources() {
        var urls = OrderedDictionary<String, Bool>()
        for p in PRESET_SOURCES { urls[p.url] = true }
        for u in storage.loadSourceUrls() {
            let clean = u.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { urls[clean] = true }
        }
        sourceUrls = urls.keys
        let selected = storage.loadSelectedSourceUrl().trimmingCharacters(in: .whitespaces)
        if !selected.isEmpty {
            activeSourceUrl = selected
            if !sourceUrls.contains(selected) { sourceUrls.append(selected) }
        } else {
            activeSourceUrl = DEFAULT_SOURCE_URL
        }
        persistSources()
    }

    func persistSources() {
        storage.saveSourceUrls(sourceUrls)
        storage.saveSelectedSourceUrl(activeSourceUrl)
        storage.saveCustomSourceUrl(activeSourceUrl)
    }

    func selectSource(_ url: String) {
        let clean = url.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != activeSourceUrl else { return }
        activeSourceUrl = clean
        if !sourceUrls.contains(clean) { sourceUrls.append(clean) }
        persistSources()
        reloadActiveSource()
    }

    func reloadActiveSource() {
        channels = []
        rawChannels = []
        currentIndex = 0
        currentSourceIndex = 0
        triedLineIndices.removeAll()
        autoSwitchState = .idle
        player.stop()
        showIndicator("正在切换源...")
        showFloat()
        loadChannels(force: true, silent: false)
    }

    func deleteSourceUrl(_ url: String) {
        guard url != DEFAULT_SOURCE_URL else { return }
        sourceUrls.removeAll { $0 == url }
        storage.removeSourceUrl(url)
        if activeSourceUrl == url {
            activeSourceUrl = DEFAULT_SOURCE_URL
            if !sourceUrls.contains(DEFAULT_SOURCE_URL) {
                sourceUrls.append(DEFAULT_SOURCE_URL)
            }
            persistSources()
            reloadActiveSource()
        } else {
            persistSources()
        }
    }

    func loadChannels(force: Bool = true, silent: Bool = false, preferActiveOnly: Bool = false) {
        if !force && !channels.isEmpty { return }
        if !silent { indicatorText = "加载中..." }
        let urls = preferActiveOnly ? [activeSourceUrl] : buildCandidates()
        Task {
            var result = await NetworkService.shared.fetchWithCandidates(urls: urls)
            // 仅当前源失败时再扩到全部候选
            if result.channels.isEmpty, preferActiveOnly {
                result = await NetworkService.shared.fetchWithCandidates(urls: buildCandidates())
            }
            await MainActor.run {
                onChannelsLoaded(result.channels, errorMessage: result.errorMessage, silent: silent)
            }
        }
    }

    private func onChannelsLoaded(_ loaded: [Channel], errorMessage: String?, silent: Bool) {
        guard !loaded.isEmpty else {
            if channels.isEmpty {
                isBootstrapping = true
                bootstrapMessage = (errorMessage ?? "加载失败") + "，正在重试..."
                if !silent {
                    showIndicator(bootstrapMessage)
                }
                scheduleRetryLoads()
            } else if !silent {
                showIndicator(errorMessage ?? "刷新失败")
            }
            return
        }
        let prevKey = currentChannel?.key
        rawChannels = loaded.map { Channel(name: $0.name, group: $0.group, key: $0.key, urls: $0.urls) }
        channels = applyRules(rawChannels)
        guard !channels.isEmpty else {
            if !silent { showIndicator("加载失败") }
            if channels.isEmpty { scheduleRetryLoads() }
            return
        }
        storage.saveChannels(loaded)
        isBootstrapping = false
        retryTask?.cancel()
        retryTask = nil

        if let prevKey, let idx = channels.firstIndex(where: { $0.key == prevKey }) {
            currentIndex = idx
            currentSourceIndex = min(currentSourceIndex, max(0, channels[idx].sourceCount - 1))
        } else {
            restoreLastChannelPosition()
        }

        if silent {
            if !player.isReady {
                playCurrent(showOSD: false, resetTried: true)
            }
        } else {
            showIndicator("已加载 \(channels.count) 个频道")
            playCurrent(showOSD: false, resetTried: true)
        }
    }

    func buildCandidates() -> [String] {
        var candidates = [activeSourceUrl]
        for url in sourceUrls where url != activeSourceUrl {
            candidates.append(url)
        }
        return candidates
    }

    private func restoreLastChannelPosition() {
        let key = storage.loadLastChannelKey()
        if !key.isEmpty, let idx = channels.firstIndex(where: { $0.key == key }) {
            currentIndex = idx
            let si = storage.loadLastSourceIndex()
            currentSourceIndex = min(max(0, si), max(0, channels[idx].sourceCount - 1))
        } else {
            currentIndex = 0
            currentSourceIndex = 0
        }
    }

    private func persistLastChannel() {
        guard let ch = currentChannel else { return }
        storage.saveLastChannel(key: ch.key, sourceIndex: currentSourceIndex)
    }

    func applyRules(_ input: [Channel]) -> [Channel] {
        input.compactMap { src in
            let filtered = Channel(name: src.name, group: src.group, key: src.key)
            for (i, url) in src.urls.enumerated() {
                if storage.isLineHidden(url) { continue }
                if shouldSkipLine(key: src.key, index: i) { continue }
                filtered.addUrl(url)
            }
            return filtered.sourceCount > 0 ? filtered : nil
        }
    }

    private func shouldSkipLine(key: String, index: Int) -> Bool {
        switch key {
        case "cctv10", "cctv14", "北京": return index == 0
        case "cctv13": return (0...2).contains(index)
        case "湖南": return (0...1).contains(index)
        default: return false
        }
    }

    struct ChannelSection: Identifiable {
        let id: String
        let title: String
        let channels: [Channel]
    }

    func sections(search: String) -> [ChannelSection] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list: [Channel] = q.isEmpty
            ? channels
            : channels.filter { $0.name.lowercased().contains(q) || $0.group.lowercased().contains(q) }
        var result: [ChannelSection] = []
        let favs = list.filter { favorites.contains($0.key) }
        if !favs.isEmpty {
            result.append(ChannelSection(id: "__fav__", title: "收藏", channels: favs))
        }
        var order: [String] = []
        var map: [String: [Channel]] = [:]
        for ch in list {
            if map[ch.group] == nil {
                order.append(ch.group)
                map[ch.group] = []
            }
            map[ch.group]?.append(ch)
        }
        for g in order {
            if let arr = map[g], !arr.isEmpty {
                result.append(ChannelSection(id: g, title: g, channels: arr))
            }
        }
        return result
    }

    func toggleFavorite(for ch: Channel) {
        let on = storage.toggleFavorite(ch.key)
        favorites = storage.loadFavorites()
        showIndicator(on ? "已收藏 \(ch.name)" : "已取消收藏")
    }

    func isFavorite(_ ch: Channel) -> Bool {
        favorites.contains(ch.key)
    }

    var currentChannel: Channel? {
        guard !channels.isEmpty, channels.indices.contains(currentIndex) else { return nil }
        return channels[currentIndex]
    }

    var currentUrl: String? {
        guard let ch = currentChannel, ch.urls.indices.contains(currentSourceIndex) else { return nil }
        return ch.urls[currentSourceIndex]
    }

    func playCurrent(showOSD: Bool = true, resetTried: Bool = false) {
        guard currentChannel != nil, let url = currentUrl, let u = URL(string: url) else {
            showIndicator("当前频道地址无效")
            return
        }
        if resetTried {
            triedLineIndices.removeAll()
            cooldownTask?.cancel()
            autoSwitchState = .idle
        }
        triedLineIndices.insert(currentSourceIndex)
        // 切换播放时允许后续失败继续试下一条（不要卡在 cooldown）
        if autoSwitchState == .cooldown {
            autoSwitchState = .idle
        }
        player.play(url: u)
        persistLastChannel()
        if showOSD { showChannelOSD() }
        showFloat()
    }

    private func onPlayerReady() {
        autoSwitchState = .idle
        scheduleHideFloat()
        if !indicatorText.isEmpty { showIndicator("") }
    }

    private func onPlayerError() { autoSwitchLine(hint: "线路失败，切换下一线路") }
    private func onStartupTimeout() { autoSwitchLine(hint: "线路超时，切换下一线路") }
    private func onPlaybackStall() { autoSwitchLine(hint: "网络卡顿，切换下一线路") }

    /// 自动切线：同频道内连续试完所有线路；仅整轮失败后才进入冷却
    private func autoSwitchLine(hint: String) {
        guard !locked else { return }
        // switching 中忽略重复回调；cooldown 仅用于整轮试完之后
        if autoSwitchState == .switching { return }
        if autoSwitchState == .cooldown { return }

        guard let ch = currentChannel else {
            showIndicator(hint)
            return
        }
        guard ch.sourceCount > 1 else {
            showIndicator("当前频道只有一条线路")
            return
        }

        var nxt = (currentSourceIndex + 1) % ch.sourceCount
        var scanned = 0
        while triedLineIndices.contains(nxt), scanned < ch.sourceCount {
            nxt = (nxt + 1) % ch.sourceCount
            scanned += 1
        }
        // 所有线路都试过
        if triedLineIndices.count >= ch.sourceCount || scanned >= ch.sourceCount {
            autoSwitchState = .idle
            showIndicator("当前频道线路均不可用")
            beginCooldown()
            return
        }

        guard let u = URL(string: ch.urls[nxt]) else {
            triedLineIndices.insert(nxt)
            autoSwitchState = .idle
            autoSwitchLine(hint: hint)
            return
        }
        autoSwitchState = .switching
        currentSourceIndex = nxt
        triedLineIndices.insert(nxt)
        showIndicator("\(hint) (\(nxt + 1)/\(ch.sourceCount))")
        // 不在这里 beginCooldown，保证下一条失败还能继续切
        player.play(url: u)
        persistLastChannel()
        showChannelOSD()
        // 短暂标记后恢复 idle，便于下一次失败继续
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if autoSwitchState == .switching {
                autoSwitchState = .idle
            }
        }
    }

    private func beginCooldown() {
        autoSwitchState = .cooldown
        cooldownTask?.cancel()
        cooldownTask = Task {
            try? await Task.sleep(nanoseconds: AUTO_SWITCH_COOLDOWN_NS)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if autoSwitchState == .cooldown { autoSwitchState = .idle }
            }
        }
    }

    func nextChannel() {
        guard !locked, !channels.isEmpty else { return }
        currentIndex = (currentIndex + 1) % channels.count
        currentSourceIndex = 0
        panelVisible = false
        autoSwitchState = .idle
        playCurrent(resetTried: true)
    }

    func prevChannel() {
        guard !locked, !channels.isEmpty else { return }
        currentIndex = (currentIndex - 1 + channels.count) % channels.count
        currentSourceIndex = 0
        panelVisible = false
        autoSwitchState = .idle
        playCurrent(resetTried: true)
    }

    func selectChannel(_ ch: Channel) {
        guard let idx = channels.firstIndex(where: { $0.key == ch.key }) else { return }
        currentIndex = idx
        currentSourceIndex = 0
        panelVisible = false
        autoSwitchState = .idle
        playCurrent(resetTried: true)
    }

    func switchSource(direction: Int) {
        guard !locked, let ch = currentChannel, ch.sourceCount > 1 else {
            if let ch = currentChannel, ch.sourceCount <= 1 {
                showIndicator("当前频道只有一个来源")
                showChannelOSD()
            }
            return
        }
        autoSwitchState = .idle
        currentSourceIndex = (currentSourceIndex + direction + ch.sourceCount) % ch.sourceCount
        playCurrent(resetTried: true)
    }

    func switchNextLine(hint: String) { autoSwitchLine(hint: hint) }

    func showChannelOSD() {
        guard let ch = currentChannel else { return }
        var text = "\(currentIndex + 1)/\(channels.count) \(ch.name)"
        if ch.sourceCount > 1 {
            text += "  线路 \(currentSourceIndex + 1)/\(ch.sourceCount)"
        }
        channelOSD = text
        osdTask?.cancel()
        osdTask = Task {
            try? await Task.sleep(nanoseconds: CHANNEL_OSD_MS)
            guard !Task.isCancelled else { return }
            await MainActor.run { channelOSD = "" }
        }
    }

    func showIndicator(_ text: String) {
        indicatorText = text
        indTask?.cancel()
        guard !text.isEmpty else { return }
        indTask = Task {
            try? await Task.sleep(nanoseconds: INDICATOR_MS)
            guard !Task.isCancelled else { return }
            await MainActor.run { indicatorText = "" }
        }
    }

    func showFloat() {
        showFloatOverlay = true
        cancelHideFloat()
        scheduleHideFloat()
    }

    func scheduleHideFloat() {
        cancelHideFloat()
        guard player.isReady else { return }
        floatTask = Task {
            try? await Task.sleep(nanoseconds: FLOAT_HIDE_MS)
            guard !Task.isCancelled else { return }
            await MainActor.run { hideFloat() }
        }
    }

    func cancelHideFloat() {
        floatTask?.cancel()
        floatTask = nil
    }

    func hideFloat() { showFloatOverlay = false }

    func togglePanel() {
        guard !locked else { return }
        panelVisible.toggle()
        showFloat()
    }

    func toggleLock() {
        locked.toggle()
        if locked {
            panelVisible = false
            hideFloat()
        } else {
            showFloat()
        }
    }

    func pause() { player.pause() }
    func resume() { player.resume() }

    func handleVolumeDrag(translationHeight: CGFloat, ended: Bool) {
        if ended {
            lastVolumeTranslation = 0
            return
        }
        let deltaY = translationHeight - lastVolumeTranslation
        lastVolumeTranslation = translationHeight
        VolumeHelper.adjust(by: Float(-deltaY) / 200)
        showIndicator("音量 \(Int(VolumeHelper.current * 100))%")
        showFloat()
    }

    func confirmDeleteLine() {
        guard currentUrl != nil else { return }
        showDeleteAlert = true
    }

    func doDeleteLine() {
        guard let url = currentUrl, let ch = currentChannel else { return }
        storage.hideLine(url)
        let targetKey = ch.key
        let nextIdx = ch.sourceCount <= 1 ? -1 : currentSourceIndex
        let oldIdx = currentIndex
        let source = rawChannels.isEmpty ? channels : rawChannels
        channels = applyRules(source)
        guard !channels.isEmpty else {
            player.stop()
            currentIndex = 0
            currentSourceIndex = 0
            showIndicator("线路已删除")
            return
        }
        if let found = channels.firstIndex(where: { $0.key == targetKey }) {
            currentIndex = found
            let updated = channels[found]
            if updated.sourceCount <= 0 {
                nextChannel()
                return
            }
            currentSourceIndex = nextIdx >= 0 && nextIdx < updated.sourceCount ? nextIdx : 0
        } else {
            currentIndex = min(oldIdx, channels.count - 1)
            currentSourceIndex = 0
        }
        showIndicator("已删除当前线路")
        playCurrent(resetTried: true)
    }
}
