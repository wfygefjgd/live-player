import SwiftUI
import AVKit

let DEFAULT_SOURCE_URL = "https://ghproxy.net/https://raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8"

private let CHANNEL_OSD_MS: UInt64 = 2_500_000_000
private let FLOAT_HIDE_MS: UInt64 = 2_500_000_000
private let INDICATOR_MS: UInt64 = 1_200_000_000
private let AUTO_SWITCH_COOLDOWN_NS: UInt64 = 4_000_000_000
private let SILENT_AUDIO_GRACE_NS: UInt64 = 5_000_000_000  // 5s 静音切换冷却

let PRESET_SOURCES: [(name: String, url: String)] = [
    ("BurningC4 CDN", "https://iptv.burningc4.com/TV-IPV4.m3u"),
    ("dongyubin 体育", "https://ghfast.top/raw.githubusercontent.com/dongyubin/IPTV/main/IPTV.m3u"),
    ("肥羊 4K", "https://ghfast.top/raw.githubusercontent.com/gaotianliuyun/youshandefeiyang/main/live.m3u"),
    ("hujingguang", "https://ghfast.top/raw.githubusercontent.com/hujingguang/ChinaIPTV/main/grouped.m3u8"),
    ("fanmingming IPv6", "https://ghfast.top/raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"),
    ("best-fan 全量", "https://gh-proxy.com/https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8"),
    ("kongkongyo CCTV", "https://ghfast.top/raw.githubusercontent.com/kongkongyo/m3u8/main/iptv.m3u"),
    ("iptv-org 中国", "https://ghfast.top/raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u"),
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
    @Published var playerLayoutEpoch: Int = 0
    @Published var needsValidation = false  // 🆕 手动触发验证标志

    // 🆕 智能融合相关
    @Published var fusionMode: FusionMode = .smart
    private let fusionEngine = SmartFusionEngine.shared

    let player = PlayerEngine()
    private let storage = StorageService()
    private var rawChannels: [Channel] = []
    var sourceUrls: [String] = []
    var activeSourceUrl = DEFAULT_SOURCE_URL
    private var autoSwitchState: AutoSwitchState = .idle
    private var started = false
    private var triedLineIndices = Set<Int>()

    // 统一任务管理
    private var osdTask: Task<Void, Never>?
    private var indTask: Task<Void, Never>?
    private var floatTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var silentAudioTask: Task<Void, Never>?

    // 🆕 NotificationCenter观察者引用
    private var fusionObserver: NSObjectProtocol?

    private var lastVolumeTranslation: CGFloat = 0
    private var lastSilentSwitchAt: Date = .distantPast

    func startup() {
        guard !started else { return }
        started = true
        favorites = storage.loadFavorites()

        // 🆕 设置融合引擎的观察者
        setupFusionObserver()

        // 🆕 恢复融合模式设置
        restoreFusionMode()

        // PlayerViewModel 已是 @MainActor，闭包回调无需再切主线程
        player.onReady = { [weak self] in self?.onPlayerReady() }
        player.onError = { [weak self] in self?.onPlayerError() }
        player.onStartupTimeout = { [weak self] in self?.onStartupTimeout() }
        player.onPlaybackStall = { [weak self] in self?.onPlaybackStall() }
        player.onSilentAudio = { [weak self] in self?.onSilentAudio() }
        player.onExtendedStall = { [weak self] in self?.onExtendedStall() }

        NetworkMonitor.shared.onSatisfied = { [weak self] in self?.onNetworkBecameAvailable() }
        NetworkMonitor.shared.onConnectionTypeChanged = { [weak self] type in
            self?.onConnectionTypeChanged(type)
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
            indicatorText = ""
            beginBootstrapLoad()
        }
    }

    // MARK: - 加载逻辑

    private func beginBootstrapLoad() {
        isBootstrapping = true
        indicatorText = ""
        if NetworkMonitor.shared.isSatisfied {
            bootstrapMessage = "正在加载频道列表..."
            loadChannels(force: true, silent: false, preferActiveOnly: false)
            scheduleRetryLoads()
            return
        }
        bootstrapMessage = "等待网络权限（请点「允许」）..."
        loadChannels(force: true, silent: false, preferActiveOnly: true)
        scheduleRetryLoads()
    }

    private func scheduleRetryLoads() {
        if let t = retryTask, !t.isCancelled { return }
        retryTask = Task { [weak self] @MainActor in
            guard let self else { return }
            for sec in [1, 3, 6] as [UInt64] {
                try? await Task.sleep(nanoseconds: sec * 1_000_000_000)
                guard !Task.isCancelled else { return }
                if !self.channels.isEmpty {
                    self.isBootstrapping = false
                    return
                }
                self.bootstrapMessage = "正在重新加载频道..."
                self.loadChannels(force: true, silent: false, preferActiveOnly: false)
            }
            while !Task.isCancelled {
                if !self.channels.isEmpty {
                    self.isBootstrapping = false
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self.bootstrapMessage = "仍无频道，继续刷新..."
                self.loadChannels(force: true, silent: false, preferActiveOnly: false)
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

    /// 网络类型变化（WiFi ↔ 蜂窝）
    func onConnectionTypeChanged(_ type: NetworkMonitor.ConnectionType) {
        switch type {
        case .cellular:
            showIndicator("当前使用蜂窝网络")
        case .wifi:
            break // WiFi 不打扰用户
        case .wired, .unknown:
            break
        }
    }

    func onAppBecameActive() {
        bumpPlayerLayout()
        if channels.isEmpty {
            retryLoadSources()
        }
    }

    func retryLoadSources() {
        isBootstrapping = true
        bootstrapMessage = "正在加载频道列表..."
        indicatorText = ""
        loadChannels(force: true, silent: false, preferActiveOnly: false)
        scheduleRetryLoads()
    }

    private func bumpPlayerLayout() {
        playerLayoutEpoch &+= 1
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
    }

    // MARK: - 源管理

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

    // MARK: - 加载频道

    func loadChannels(force: Bool = true, silent: Bool = false, preferActiveOnly: Bool = false) {
        if !force && !channels.isEmpty { return }
        if !silent && !isBootstrapping {
            indicatorText = "加载中..."
        }
        let urls = preferActiveOnly ? [activeSourceUrl] : buildCandidates()

        Task { [weak self] in
            guard let self else { return }
            // 🆕 使用智能融合引擎
            fusionEngine.onProgress = { [weak self] message in
                self?.bootstrapMessage = message
            }

            let (loaded, errMsg) = await fusionEngine.smartFusion(
                sourceUrls: urls,
                mode: fusionMode
            )

            await MainActor.run { [weak self] in
                self?.onChannelsLoaded(loaded, errorMessage: errMsg, silent: silent)
            }
        }
    }

    private func onChannelsLoaded(_ loaded: [Channel], errorMessage: String?, silent: Bool) {
        guard !loaded.isEmpty else {
            if channels.isEmpty {
                isBootstrapping = true
                let msg = chineseLoadError(errorMessage)
                bootstrapMessage = msg + "，正在重试..."
                indicatorText = ""
                scheduleRetryLoads()
            } else if !silent {
                showIndicator(chineseLoadError(errorMessage))
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
            // 🆕 显示融合结果
            let totalLines = channels.reduce(0) { $0 + $1.sourceCount }
            if totalLines > 1000 {
                showIndicator("✨ \(channels.count) 个频道，\(totalLines) 条线路")
            }
            playCurrent(showOSD: false, resetTried: true)
        }
    }

    // MARK: - 应用频道验证结果
    func applyValidationResult(_ result: ValidationResult) {
        var filteredChannels: [Channel] = []

        for channel in rawChannels {
            if let validURLs = result.validChannels[channel.name], !validURLs.isEmpty {
                // 只保留验证通过的URL
                let filtered = Channel(
                    name: channel.name,
                    group: channel.group,
                    key: channel.key,
                    urls: validURLs
                )
                filteredChannels.append(filtered)
            }
        }

        channels = filteredChannels

        if !channels.isEmpty {
            currentIndex = 0
            currentSourceIndex = 0
        }
    }

    // MARK: - 手动触发重新验证
    func triggerManualValidation() {
        // 清除验证记录
        ValidationStorage.shared.clear()
        // 设置标志，让RootView重新显示验证界面
        needsValidation = true
    }

    func buildCandidates() -> [String] {
        var candidates = [activeSourceUrl]
        for url in sourceUrls where url != activeSourceUrl {
            candidates.append(url)
        }
        return candidates
    }

    private func chineseLoadError(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "加载失败" }
        let lower = raw.lowercased()
        if lower.contains("network") || lower.contains("internet") || lower.contains("offline")
            || lower.contains("timed out") || lower.contains("timeout") {
            return "网络不可用"
        }
        if lower.contains("parse") { return "解析失败" }
        if lower.contains("invalid") || lower.contains("url") { return "地址无效" }
        if lower.contains("server") || lower.contains("http") { return "服务器异常" }
        if raw.range(of: "\\p{Han}", options: .regularExpression) != nil {
            return String(raw.prefix(40))
        }
        return "加载失败"
    }

    private func restoreLastChannelPosition() {
        // 优先默认选择CCTV，除非用户有明确的上次观看记录
        let key = storage.loadLastChannelKey()
        if !key.isEmpty, let idx = channels.firstIndex(where: { $0.key == key }) {
            // 用户有观看历史，恢复到上次的频道
            currentIndex = idx
            let si = storage.loadLastSourceIndex()
            currentSourceIndex = min(max(0, si), max(0, channels[idx].sourceCount - 1))
        } else {
            // 没有观看历史，默认选择 CCTV-1 或第一个 CCTV 频道
            if let cctvIdx = channels.firstIndex(where: {
                $0.name.contains("CCTV") || $0.name.contains("央视") || $0.name.contains("cctv")
            }) {
                currentIndex = cctvIdx
            } else if let cctv1Idx = channels.firstIndex(where: {
                $0.name.contains("CCTV1") || $0.name.contains("CCTV-1") || $0.name.contains("综合")
            }) {
                currentIndex = cctv1Idx
            } else {
                // 实在找不到 CCTV，才选择第一个频道
                currentIndex = 0
            }
            currentSourceIndex = 0
        }
    }

    private func persistLastChannel() {
        guard let ch = currentChannel else { return }
        storage.saveLastChannel(key: ch.key, sourceIndex: currentSourceIndex)
    }

    // MARK: - 数据规则

    func applyRules(_ input: [Channel]) -> [Channel] {
        input.compactMap { src in
            var filtered = Channel(name: src.name, group: src.group, key: src.key)
            for url in src.urls {
                if storage.isLineHidden(url) { continue }
                filtered.addUrl(url)
            }
            return filtered.sourceCount > 0 ? filtered : nil
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

        func groupName(for ch: Channel) -> String {
            if M3UParserService.isCCTVKey(ch.key) || ch.name.uppercased().contains("CCTV") {
                return "央视"
            }
            let g = ch.group.trimmingCharacters(in: .whitespaces)
            if g.isEmpty || g == "未分组" {
                return "未分组"
            }
            if g.contains("央视") || g.uppercased().contains("CCTV") {
                return "央视"
            }
            return g
        }

        func sortChannels(_ arr: [Channel]) -> [Channel] {
            arr.sorted { a, b in
                let na = M3UParserService.cctvNumber(from: a.key)
                let nb = M3UParserService.cctvNumber(from: b.key)
                if na != Int.max || nb != Int.max {
                    if na != nb { return na < nb }
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        var result: [ChannelSection] = []
        let favs = sortChannels(list.filter { favorites.contains($0.key) })
        if !favs.isEmpty {
            result.append(ChannelSection(id: "__fav__", title: "收藏", channels: favs))
        }

        var order: [String] = []
        var map: [String: [Channel]] = [:]
        for ch in list {
            let g = groupName(for: ch)
            if map[g] == nil {
                order.append(g)
                map[g] = []
            }
            map[g]?.append(ch)
        }
        order.sort { a, b in
            if a == "央视" { return true }
            if b == "央视" { return false }
            if a == "未分组" { return false }
            if b == "未分组" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        for g in order {
            if let arr = map[g], !arr.isEmpty {
                result.append(ChannelSection(id: g, title: g, channels: sortChannels(arr)))
            }
        }
        return result
    }

    // MARK: - 收藏

    func toggleFavorite(for ch: Channel) {
        let on = storage.toggleFavorite(ch.key)
        favorites = storage.loadFavorites()
        showIndicator(on ? "已收藏 \(ch.name)" : "已取消收藏")
    }

    func isFavorite(_ ch: Channel) -> Bool {
        favorites.contains(ch.key)
    }

    // MARK: - 播放控制

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
        bumpPlayerLayout()
    }

    private func onPlayerError() { autoSwitchLine(hint: "线路失败，切换下一线路") }
    private func onStartupTimeout() { autoSwitchLine(hint: "线路超时，切换下一线路") }
    private func onPlaybackStall() { autoSwitchLine(hint: "网络卡顿，切换下一线路") }
    private func onExtendedStall() { autoSwitchLine(hint: "画面冻结，切换下一线路") }

    // MARK: - 静音检测

    private func onSilentAudio() {
        let now = Date()
        if now.timeIntervalSince(lastSilentSwitchAt) < Double(SILENT_AUDIO_GRACE_NS) / 1e9 {
            return
        }
        guard let ch = currentChannel, ch.sourceCount > 1 else { return }
        lastSilentSwitchAt = now
        autoSwitchLine(hint: "当前线路无声音，切换下一线路")
    }

    /// 自动切线：同频道内连续试完所有线路，如果都失败则切下一频道
    private func autoSwitchLine(hint: String) {
        guard !locked else { return }
        if autoSwitchState == .switching { return }
        if autoSwitchState == .cooldown { return }

        guard let ch = currentChannel else {
            showIndicator(hint)
            return
        }

        // 如果只有一条线路，直接切下一个频道
        if ch.sourceCount <= 1 {
            showIndicator("当前频道只有一条线路，切换下一频道")
            beginCooldown()
            Task { [weak self] @MainActor in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 800_000_000)  // 0.8秒后切换
                guard !Task.isCancelled else { return }
                self.nextChannel()
            }
            return
        }

        var nxt = (currentSourceIndex + 1) % ch.sourceCount
        var scanned = 0
        while triedLineIndices.contains(nxt), scanned < ch.sourceCount {
            nxt = (nxt + 1) % ch.sourceCount
            scanned += 1
        }

        // 所有线路都试过了，切下一个频道
        if triedLineIndices.count >= ch.sourceCount || scanned >= ch.sourceCount {
            autoSwitchState = .idle
            showIndicator("当前频道所有线路不可用，切换下一频道")
            beginCooldown()
            Task { [weak self] @MainActor in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 800_000_000)  // 0.8秒后切换
                guard !Task.isCancelled else { return }
                self.nextChannel()
            }
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
        player.play(url: u)
        persistLastChannel()
        showChannelOSD()
        Task { [weak self] @MainActor in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if self.autoSwitchState == .switching {
                self.autoSwitchState = .idle
            }
        }
    }

    private func beginCooldown() {
        autoSwitchState = .cooldown
        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AUTO_SWITCH_COOLDOWN_NS)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.autoSwitchState == .cooldown { self.autoSwitchState = .idle }
            }
        }
    }

    func nextChannel() {
        guard !locked, !channels.isEmpty else { return }
        cooldownTask?.cancel()
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

    // MARK: - UI 辅助

    func showChannelOSD() {
        guard let ch = currentChannel else { return }
        var text = "\(currentIndex + 1)/\(channels.count) \(ch.name)"
        if ch.sourceCount > 1 {
            text += "  线路 \(currentSourceIndex + 1)/\(ch.sourceCount)"
        }
        channelOSD = text
        osdTask?.cancel()
        osdTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: CHANNEL_OSD_MS)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.channelOSD = ""
            }
        }
    }

    func showIndicator(_ text: String) {
        indicatorText = text
        indTask?.cancel()
        guard !text.isEmpty else { return }
        indTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: INDICATOR_MS)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.indicatorText = ""
            }
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
        floatTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: FLOAT_HIDE_MS)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.hideFloat()
            }
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
    func resume() {
        player.resume()
        bumpPlayerLayout()
    }

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

    // MARK: - 智能融合相关

    /// 监听后台优化完成的通知
    private func setupFusionObserver() {
        fusionObserver = NotificationCenter.default.addObserver(
            forName: .channelsOptimized,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let optimized = notification.object as? [Channel] {
                self.channels = self.applyRules(optimized)
                let totalLines = optimized.reduce(0) { $0 + $1.sourceCount }
                self.showIndicator("✨ 线路优化完成！\(optimized.count) 个频道，\(totalLines) 条线路")
            }
        }
    }

    deinit {
        // 🆕 移除NotificationCenter观察者
        if let observer = fusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // 取消所有任务
        osdTask?.cancel()
        indTask?.cancel()
        floatTask?.cancel()
        cooldownTask?.cancel()
        retryTask?.cancel()
        silentAudioTask?.cancel()
    }

    /// 切换融合模式
    func switchFusionMode(_ mode: FusionMode) {
        fusionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "fusionMode")

        let modeName: String
        switch mode {
        case .fast: modeName = "快速"
        case .balanced: modeName = "平衡"
        case .complete: modeName = "完整"
        case .smart: modeName = "智能"
        }

        showIndicator("已切换到\(modeName)模式")

        // 重新加载频道
        loadChannels(force: true, silent: false, preferActiveOnly: false)
    }

    /// 从 UserDefaults 恢复融合模式设置
    func restoreFusionMode() {
        if let saved = UserDefaults.standard.string(forKey: "fusionMode"),
           let mode = FusionMode(rawValue: saved) {
            fusionMode = mode
        }
    }
}
