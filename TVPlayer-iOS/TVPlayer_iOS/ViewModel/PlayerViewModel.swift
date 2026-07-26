import SwiftUI
import AVKit
import UIKit
import MediaPlayer

let DEFAULT_SOURCE_URL = "https://ghfast.top/raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u"

private let CHANNEL_OSD_MS: UInt64 = 2_500_000_000
private let INDICATOR_MS: UInt64 = 1_200_000_000
private let AUTO_SWITCH_COOLDOWN_NS: UInt64 = 1_200_000_000
private let SILENT_AUDIO_GRACE_NS: UInt64 = 8_000_000_000  // 8s 静音切换冷却，避免好线误切
private let AUTO_RECOVER_MAX_CHANNELS = 25                 // 连续自动切台上限，防止死循环
private let PREFERRED_LINE_STABLE_NS: UInt64 = 6_000_000_000 // 稳定播放 6s 后记住好线路

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
    @Published var showSourceSheet = false
    @Published var channelOSD: String = ""
    @Published var indicatorText: String = ""
    @Published var favorites: Set<String> = []
    @Published var isBootstrapping = false
    @Published var bootstrapMessage = "正在连接网络..."
    @Published var playerLayoutEpoch: Int = 0

    // 智能融合相关（默认智能：首源先出画 + 后台全量融合）
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
    private var cooldownTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    // NotificationCenter 观察者
    private var fusionObserver: NSObjectProtocol?
    private var firstBatchObserver: NSObjectProtocol?

    private var lastVolumeTranslation: CGFloat = 0
    private var lastSilentSwitchAt: Date = .distantPast
    private var lastChannelSwitchAt: Date = .distantPast
    private let channelSwitchDebounceInterval: TimeInterval = 0.3  // 300ms 防抖
    private var autoRecoverChannelHops = 0
    private var playbackStable = false
    private var recoverGeneration = 0
    private var preferStableTask: Task<Void, Never>?
    private let reputation = LineReputationStore.shared
    private var loadGeneration = 0
    /// 用户主动暂停：回前台/中断结束不得强制 resume
    private(set) var userPaused = false
    private var wasPlayingBeforeInterruption = false

    func startup() {
        guard !started else { return }
        started = true
        favorites = storage.loadFavorites()
        UIApplication.shared.isIdleTimerDisabled = true

        setupFusionObserver()
        restoreFusionMode()

        player.onReady = { [weak self] in self?.onPlayerReady() }
        player.onError = { [weak self] in self?.onPlayerError() }
        player.onStartupTimeout = { [weak self] in self?.onStartupTimeout() }
        // 移除快速卡顿检测，只保留扩展卡顿和健康度检测
        // player.onPlaybackStall = { [weak self] in self?.onPlaybackStall() }
        player.onSilentAudio = { [weak self] in self?.onSilentAudio() }
        player.onExtendedStall = { [weak self] in self?.onExtendedStall() }
        player.onHealthCritical = { [weak self] reason in self?.onHealthCritical(reason) }  // 🆕 健康度危急回调

        NetworkMonitor.shared.onSatisfied = { [weak self] in self?.onNetworkBecameAvailable() }
        NetworkMonitor.shared.onConnectionTypeChanged = { [weak self] type in
            self?.onConnectionTypeChanged(type)
        }

        restoreSources()
        reputation.prune()

        // ① 缓存 / Bundle 立刻出画（信誉排序跳过已知坏线）
        // ② 后台静默刷新融合，不打断已稳定播放
        if applyQuickStartChannels() {
            loadChannels(force: true, silent: true, preferActiveOnly: false)
        } else {
            isBootstrapping = true
            bootstrapMessage = "正在加载频道列表..."
            indicatorText = ""
            beginBootstrapLoad()
        }
    }

    /// 快速启动：用户缓存优先于 Bundle 内置，避免覆盖融合结果
    @discardableResult
    private func applyQuickStartChannels() -> Bool {
        let cached = storage.loadChannels()
        if !cached.isEmpty {
            let applied = reputation.applyToChannels(cached)
            rawChannels = applied
            channels = applyRules(applied)
            if !channels.isEmpty {
                restoreLastChannelPosition()
                isBootstrapping = false
                playCurrent(showOSD: false, resetTried: true)
                return true
            }
        }
        if let bundleChannels = loadChannelsFromBundle(), !bundleChannels.isEmpty {
            let applied = reputation.applyToChannels(bundleChannels)
            rawChannels = applied
            channels = applyRules(applied)
            if !channels.isEmpty {
                restoreLastChannelPosition()
                isBootstrapping = false
                playCurrent(showOSD: false, resetTried: true)
                return true
            }
        }
        return false
    }

    // 🆕 只加载频道数据，不启动播放器（用于验证界面）
    func loadChannelsOnly() {
        guard !started else { return }
        started = true
        favorites = storage.loadFavorites()

        setupFusionObserver()
        restoreFusionMode()
        restoreSources()

        // 只加载频道，不启动播放器
        let cached = applyRules(storage.loadChannels())
        if !cached.isEmpty {
            channels = cached
        } else {
            // 直接加载频道，不显示引导界面
            loadChannels(force: true, silent: true, preferActiveOnly: false)
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
        retryTask = Task { @MainActor [weak self] in
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
        loadChannels(force: true, silent: false, preferActiveOnly: true)
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
        loadGeneration += 1
        let gen = loadGeneration
        let mode = fusionMode
        // 作废上一轮后台融合通知，并绑定本轮 session
        fusionEngine.invalidateSession()
        let fusionSession = fusionEngine.session

        Task { [weak self] in
            guard let self else { return }
            self.fusionEngine.onProgress = { [weak self] message in
                guard let self, self.loadGeneration == gen else { return }
                self.bootstrapMessage = message
            }

            let (loaded, errMsg) = await self.fusionEngine.smartFusion(
                sourceUrls: urls,
                mode: mode
            )

            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == gen else { return }
                guard self.fusionEngine.session == fusionSession else { return }
                self.onChannelsLoaded(loaded, errorMessage: errMsg, silent: silent)
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
        // 融合结果再套信誉记忆：坏线后置、好线前置（与自动换线不冲突）
        let reputationApplied = reputation.applyToChannels(loaded)
        rawChannels = reputationApplied.map { Channel(name: $0.name, group: $0.group, key: $0.key, urls: $0.urls) }
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
            // 后台刷新：仅未出画时才自动开播，避免打断正在看的台
            if !player.isReady && !playbackStable {
                playCurrent(showOSD: false, resetTried: true)
            }
        } else {
            showIndicator("已加载 \(channels.count) 个频道")
            let totalLines = channels.reduce(0) { $0 + $1.sourceCount }
            if totalLines > 1000 {
                showIndicator("\(channels.count) 台 · \(totalLines) 线")
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
    // MARK: - 从 Bundle 加载预验证频道
    private func loadChannelsFromBundle() -> [Channel]? {
        guard let url = Bundle.main.url(forResource: "validated-channels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(ValidatedChannelsResponse.self, from: data) else {
            return nil
        }

        return json.channels.map { ch in
            Channel(name: ch.name, group: ch.group, key: ch.name, urls: ch.urls)
        }
    }

    // MARK: - 从远程刷新频道
    func refreshChannelsFromRemote() async {
        let mirrorUrl = "https://ghfast.top/raw.githubusercontent.com/wfygefjgd/live-player/main/TVPlayer-iOS/scripts/validated-channels.json"

        guard let url = URL(string: mirrorUrl) else {
            await MainActor.run {
                showIndicator("刷新失败：URL 无效")
            }
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONDecoder().decode(ValidatedChannelsResponse.self, from: data)

            let newChannels = json.channels.map { ch in
                Channel(name: ch.name, group: ch.group, key: ch.name, urls: ch.urls)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rawChannels = newChannels
                self.channels = self.applyRules(newChannels)
                self.storage.saveChannels(newChannels)
                self.restoreLastChannelPosition()
                self.showIndicator("✓ 已刷新 \(self.channels.count) 个频道")
                self.playCurrent(showOSD: false, resetTried: true)
            }
        } catch {
            await MainActor.run {
                showIndicator("刷新失败：\(error.localizedDescription)")
            }
        }
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
            if favorites.contains(ch.key) { return "收藏" }
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

        // 每个频道只出现一次：收藏优先单独成组，避免 List 重复 id
        var result: [ChannelSection] = []
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
            if a == "收藏" { return true }
            if b == "收藏" { return false }
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
        guard let ch = currentChannel else { return nil }
        guard currentSourceIndex >= 0 && currentSourceIndex < ch.urls.count else { return nil }
        return ch.urls[currentSourceIndex]
    }

    func playCurrent(showOSD: Bool = true, resetTried: Bool = false) {
        guard var ch = currentChannel else {
            showIndicator("当前频道地址无效")
            return
        }
        // 用共享信誉重排本台线路（融合与换线同一记忆）
        let ordered = reputation.orderedURLs(ch.urls, channelKey: ch.key)
        if ordered != ch.urls {
            var nc = Channel(name: ch.name, group: ch.group, key: ch.key)
            nc.addUrls(ordered)
            if let idx = channels.firstIndex(where: { $0.key == ch.key }) {
                channels[idx] = nc
            }
            ch = nc
        }

        if resetTried {
            triedLineIndices.removeAll()
            cooldownTask?.cancel()
            autoSwitchState = .idle
            playbackStable = false
            preferStableTask?.cancel()
            // 偏好 URL 或第一条未拉黑线
            if let pref = reputation.preferredURL(forChannelKey: ch.key),
               let i = ch.urls.firstIndex(of: pref) {
                currentSourceIndex = i
            } else if let i = ch.urls.firstIndex(where: { !reputation.isBlacklisted($0) }) {
                currentSourceIndex = i
            } else {
                currentSourceIndex = 0
            }
        }

        var guardLoops = 0
        while guardLoops < ch.sourceCount {
            guardLoops += 1
            if currentSourceIndex < 0 || currentSourceIndex >= ch.urls.count {
                currentSourceIndex = 0
            }
            // 自动路径跳过黑名单（手动点台 resetTried 后仍会先试偏好）
            let raw = ch.urls[currentSourceIndex]
            if reputation.isBlacklisted(raw), triedLineIndices.count < ch.sourceCount - 1 {
                triedLineIndices.insert(currentSourceIndex)
                currentSourceIndex = (currentSourceIndex + 1) % max(ch.sourceCount, 1)
                continue
            }
            if let u = URL(string: raw), let scheme = u.scheme?.lowercased(),
               scheme == "http" || scheme == "https" || scheme == "rtmp" || scheme == "rtsp" {
                triedLineIndices.insert(currentSourceIndex)
                if autoSwitchState == .cooldown { autoSwitchState = .idle }
                if autoSwitchState == .switching { autoSwitchState = .idle }
                player.play(url: u)
                persistLastChannel()
                if showOSD { showChannelOSD() }
                updateNowPlaying()
                return
            }
            triedLineIndices.insert(currentSourceIndex)
            currentSourceIndex = (currentSourceIndex + 1) % max(ch.sourceCount, 1)
        }
        showIndicator("当前频道地址无效")
        autoSwitchLine(hint: "当前频道地址无效", reason: .hardFail)
    }

    private func onPlayerReady() {
        autoSwitchState = .idle
        playbackStable = true
        autoRecoverChannelHops = 0
        isBootstrapping = false
        userPaused = false
        if !indicatorText.isEmpty { showIndicator("") }
        bumpPlayerLayout()
        updateNowPlaying()
        UIApplication.shared.isIdleTimerDisabled = true
        // 真实起播成功才写信誉（延迟确认，避免假 READY）
        preferStableTask?.cancel()
        let key = currentChannel?.key
        let url = currentUrl
        let gen = recoverGeneration
        preferStableTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: PREFERRED_LINE_STABLE_NS)
            guard let self, !Task.isCancelled else { return }
            guard self.recoverGeneration == gen, self.playbackStable, self.player.isReady else { return }
            guard let url else { return }
            guard self.currentUrl == url else { return }
            self.reputation.markSuccess(url: url, channelKey: key)
        }
    }

    func updateNowPlaying() {
        guard let ch = currentChannel else {
            NowPlayingController.shared.clear()
            return
        }
        var title = ch.name
        if ch.sourceCount > 1 {
            title += " · 线\(currentSourceIndex + 1)/\(ch.sourceCount)"
        }
        NowPlayingController.shared.update(
            title: title,
            artist: "TVPlayer",
            isPlaying: player.isPlaying
        )
    }

    private func onPlayerError() {
        guard !userPaused else { return }
        autoSwitchLine(hint: "线路失败", reason: .hardFail)
    }
    private func onStartupTimeout() {
        guard !userPaused else { return }
        autoSwitchLine(hint: "线路超时无画面", reason: .startupTimeout)
    }
    private func onExtendedStall() {
        guard !userPaused else { return }
        autoSwitchLine(hint: "画面持续卡顿", reason: .stall)
    }

    private func onHealthCritical(_ reason: String) {
        guard !userPaused else { return }
        autoSwitchLine(hint: reason, reason: .healthCritical)
    }

    // MARK: - 静音检测

    private func onSilentAudio() {
        // 仅多线路 + 已稳定 + 仍无音轨时才切；HLS 起播慢选轨不误杀
        guard let ch = currentChannel, ch.sourceCount > 1 else { return }
        guard playbackStable, player.isReady else { return }
        guard player.hasActiveAudioTrack == false else { return }
        let now = Date()
        if now.timeIntervalSince(lastSilentSwitchAt) < Double(SILENT_AUDIO_GRACE_NS) / 1e9 {
            return
        }
        lastSilentSwitchAt = now
        autoSwitchLine(hint: "当前线路无声音", reason: .silentAudio)
    }

    private enum FailReason {
        case hardFail
        case startupTimeout
        case stall
        case healthCritical
        case silentAudio

        var isConfirmedBad: Bool {
            switch self {
            case .hardFail, .startupTimeout, .stall, .healthCritical, .silentAudio:
                return true
            }
        }
    }

    /// 自动切线：仅确认坏线才切；同频道试完所有线路后切下一频道，直到出画
    private func autoSwitchLine(hint: String, reason: FailReason) {
        guard let ch = currentChannel else {
            showIndicator(hint)
            return
        }
        guard reason.isConfirmedBad else {
            showIndicator(hint)
            return
        }
        // 冷却期只抑制“软问题”重复触发；硬失败/超时必须放行
        if autoSwitchState == .cooldown {
            switch reason {
            case .hardFail, .startupTimeout:
                cooldownTask?.cancel()
                autoSwitchState = .idle
            default:
                return
            }
        }
        // 不再用 switching 窗口吞掉失败回调（此前 400ms 内失败会卡死）

        playbackStable = false
        preferStableTask?.cancel()
        triedLineIndices.insert(currentSourceIndex)
        // 写入共享信誉：失败线 24h 内优先跳过（融合与下次启动共用）
        if let failURL = currentUrl {
            let hard = (reason == .hardFail || reason == .startupTimeout || reason == .stall || reason == .healthCritical)
            reputation.markFailure(url: failURL, channelKey: ch.key, hard: hard)
        }

        // 多线路：按信誉顺序找下一条未试过的合法线
        if ch.sourceCount > 1 {
            let candidates = reputation.orderedURLs(ch.urls, channelKey: ch.key)
            for cand in candidates {
                guard let nxt = ch.urls.firstIndex(of: cand) else { continue }
                if triedLineIndices.contains(nxt) { continue }
                if reputation.isBlacklisted(cand), triedLineIndices.count + 1 < ch.sourceCount {
                    triedLineIndices.insert(nxt)
                    continue
                }
                guard let u = URL(string: cand),
                      let scheme = u.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" || scheme == "rtmp" || scheme == "rtsp" else {
                    triedLineIndices.insert(nxt)
                    continue
                }
                currentSourceIndex = nxt
                triedLineIndices.insert(nxt)
                autoSwitchState = .idle
                showIndicator("\(hint) · 线路 \(nxt + 1)/\(ch.sourceCount)")
                player.play(url: u)
                persistLastChannel()
                showChannelOSD()
                return
            }
        }

        // 本频道线路已耗尽 → 自动下一频道
        autoSwitchState = .idle
        if autoRecoverChannelHops >= AUTO_RECOVER_MAX_CHANNELS {
            showIndicator("连续多台无可用线路，请手动换台或换源")
            beginCooldown()
            return
        }
        autoRecoverChannelHops += 1
        showIndicator("\(hint) · 本台线路不可用，切下一台")
        // 短延迟避免同帧重入；不进入长冷却，保证恢复链路畅通
        recoverGeneration += 1
        let gen = recoverGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, self.recoverGeneration == gen else { return }
            self.autoAdvanceChannel()
        }
    }

    /// 自动恢复用的切台（不受用户防抖影响）
    private func autoAdvanceChannel() {
        guard !channels.isEmpty else { return }
        cooldownTask?.cancel()
        autoSwitchState = .idle
        currentIndex = (currentIndex + 1) % channels.count
        currentSourceIndex = 0
        panelVisible = false
        triedLineIndices.removeAll()
        playCurrent(resetTried: true)
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
        guard !channels.isEmpty else { return }
        let now = Date()
        if now.timeIntervalSince(lastChannelSwitchAt) < channelSwitchDebounceInterval {
            return
        }
        lastChannelSwitchAt = now
        autoRecoverChannelHops = 0
        playbackStable = false
        cooldownTask?.cancel()
        currentIndex = (currentIndex + 1) % channels.count
        currentSourceIndex = 0
        panelVisible = false
        autoSwitchState = .idle
        playCurrent(resetTried: true)
    }

    func prevChannel() {
        guard !channels.isEmpty else { return }
        let now = Date()
        if now.timeIntervalSince(lastChannelSwitchAt) < channelSwitchDebounceInterval {
            return
        }
        lastChannelSwitchAt = now
        autoRecoverChannelHops = 0
        playbackStable = false
        currentIndex = (currentIndex - 1 + channels.count) % channels.count
        currentSourceIndex = 0
        panelVisible = false
        autoSwitchState = .idle
        playCurrent(resetTried: true)
    }

    func selectChannel(_ ch: Channel) {
        guard let idx = channels.firstIndex(where: { $0.key == ch.key }) else { return }
        autoRecoverChannelHops = 0
        playbackStable = false
        currentIndex = idx
        currentSourceIndex = 0
        panelVisible = false
        autoSwitchState = .idle
        playCurrent(resetTried: true)
    }

    func switchSource(direction: Int) {
        guard let ch = currentChannel, ch.sourceCount > 1 else {
            if let ch = currentChannel, ch.sourceCount <= 1 {
                showIndicator("当前频道只有一个来源")
                showChannelOSD()
            }
            return
        }
        autoSwitchState = .idle
        autoRecoverChannelHops = 0
        playbackStable = false
        preferStableTask?.cancel()
        currentSourceIndex = (currentSourceIndex + direction + ch.sourceCount) % ch.sourceCount
        triedLineIndices = [currentSourceIndex]
        showIndicator("切换线路 \(currentSourceIndex + 1)/\(ch.sourceCount)")
        // 勿 resetTried：会把手动选的线路索引重置回偏好线
        playCurrent(showOSD: true, resetTried: false)
    }

    func switchNextLine(hint: String) { autoSwitchLine(hint: hint, reason: .hardFail) }

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

    func togglePanel() {
        panelVisible.toggle()
    }

    func pause() {
        userPaused = true
        player.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        updateNowPlaying()
    }
    func resume() {
        userPaused = false
        player.resume()
        UIApplication.shared.isIdleTimerDisabled = true
        bumpPlayerLayout()
        updateNowPlaying()
    }

    /// 回前台：仅在非用户暂停时续播
    func resumeIfAppropriate() {
        guard !userPaused, player.isReady, !player.isPlaying else { return }
        player.resume()
        UIApplication.shared.isIdleTimerDisabled = true
        bumpPlayerLayout()
        updateNowPlaying()
    }

    func noteInterruptionBegan() {
        wasPlayingBeforeInterruption = player.isPlaying && !userPaused
    }

    func noteInterruptionEnded(shouldResume: Bool) {
        guard shouldResume, wasPlayingBeforeInterruption, !userPaused else { return }
        resume()
    }

    private var lastBrightnessTranslation: CGFloat = 0

    func handleVolumeDrag(translationHeight: CGFloat, ended: Bool) {
        if ended {
            lastVolumeTranslation = 0
            return
        }
        let deltaY = translationHeight - lastVolumeTranslation
        lastVolumeTranslation = translationHeight
        VolumeHelper.adjust(by: Float(-deltaY) / 200)
        showIndicator("音量 \(Int(VolumeHelper.current * 100))%")
    }

    /// 亮度交给系统，手势不再改屏亮
    func handleBrightnessDrag(translationHeight: CGFloat, ended: Bool) {
        if ended { lastBrightnessTranslation = 0 }
    }

    // MARK: - 智能融合相关

    /// 监听首源批次 + 后台全量优化：软合并，不打断稳定播放
    private func setupFusionObserver() {
        if let observer = fusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = firstBatchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        fusionObserver = NotificationCenter.default.addObserver(
            forName: .channelsOptimized,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let s = notification.userInfo?["session"] as? Int, s != self.fusionEngine.session {
                return
            }
            guard let optimized = notification.object as? [Channel] else { return }
            self.mergeOptimizedChannels(optimized)
        }
        // channelsFirstBatch 已停用双投递；保留 observer 槽位以免旧通知误伤
        firstBatchObserver = nil
    }

    /// 融合后台优化结果软合并：保留当前台/当前线，只更新列表与排序
    private func mergeOptimizedChannels(_ optimized: [Channel]) {
        let prevKey = currentChannel?.key
        let prevURL = currentUrl
        let applied = reputation.applyToChannels(optimized)
        rawChannels = applied
        channels = applyRules(applied)
        guard !channels.isEmpty else { return }
        storage.saveChannels(applied)

        if let prevKey, let idx = channels.firstIndex(where: { $0.key == prevKey }) {
            currentIndex = idx
            if let prevURL, let li = channels[idx].urls.firstIndex(of: prevURL) {
                currentSourceIndex = li
            } else {
                currentSourceIndex = min(currentSourceIndex, max(0, channels[idx].sourceCount - 1))
            }
            if !player.isReady && !playbackStable && !userPaused {
                playCurrent(showOSD: false, resetTried: true)
            }
        } else if !player.isReady && !userPaused {
            restoreLastChannelPosition()
            playCurrent(showOSD: false, resetTried: true)
        }

        let totalLines = channels.reduce(0) { $0 + $1.sourceCount }
        showIndicator("线路优化完成 · \(channels.count) 台 / \(totalLines) 线")
    }

    deinit {
        let obs1 = fusionObserver
        let obs2 = firstBatchObserver
        osdTask?.cancel()
        indTask?.cancel()
        cooldownTask?.cancel()
        retryTask?.cancel()
        preferStableTask?.cancel()
        DispatchQueue.main.async {
            if let obs1 { NotificationCenter.default.removeObserver(obs1) }
            if let obs2 { NotificationCenter.default.removeObserver(obs2) }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// 切换融合模式
    func switchFusionMode(_ mode: FusionMode) {
        fusionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "fusionMode")

        let modeName: String
        switch mode {
        case .off: modeName = "关闭融合"
        case .fast: modeName = "快速"
        case .balanced: modeName = "平衡"
        case .complete: modeName = "完整"
        case .smart: modeName = "智能"
        }

        showIndicator("已切换到\(modeName)模式")

        // 重新加载频道
        loadChannels(force: true, silent: false, preferActiveOnly: false)
    }

    /// 从 UserDefaults 恢复融合模式设置（无记录时保持 .smart）
    func restoreFusionMode() {
        if let saved = UserDefaults.standard.string(forKey: "fusionMode"),
           let mode = FusionMode(rawValue: saved) {
            fusionMode = mode
        } else {
            fusionMode = .smart
        }
    }
}
