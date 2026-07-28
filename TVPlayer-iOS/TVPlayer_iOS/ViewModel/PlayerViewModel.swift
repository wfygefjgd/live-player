import SwiftUI
import AVKit
import UIKit
import MediaPlayer

// 官方最新线路（软件与数据分离）：只改 GitHub 上这个文件即可更新 App 频道，无需发版。
// 拉取时 MirrorResolver 自动展开 jsDelivr / Pages / ghproxy / raw 镜像竞速
let DEFAULT_SOURCE_URL = "https://cdn.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u"
/// 与 DEFAULT 同内容；「加载最新」优先走 Pages/raw（更新更快，少受 jsDelivr 缓存影响）
let LATEST_LINEUP_URLS: [String] = [
    "https://wfygefjgd.github.io/live-player/iptv-mirrors/validated-channels.m3u",
    "https://raw.githubusercontent.com/wfygefjgd/live-player/main/iptv-mirrors/validated-channels.m3u",
    "https://cdn.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u",
    "https://fastly.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u",
]

private let CHANNEL_OSD_MS: UInt64 = 2_500_000_000
private let INDICATOR_MS: UInt64 = 1_200_000_000
/// 自动换线冷却：防止连续失败瞬间连跳
private let AUTO_SWITCH_COOLDOWN_NS: UInt64 = 1_200_000_000
/// 无声判定冷却（秒级防抖）
private let SILENT_AUDIO_GRACE_NS: UInt64 = 10_000_000_000
/// 连续自动 hop 频道上限（线都试完才 hop）
private let AUTO_RECOVER_MAX_CHANNELS = 15
private let BLACKLIST_REFRESH_NS: UInt64 = 60_000_000_000

// 精选列表 JSON（Bundle 快速启动 / 旁路刷新），勿当 m3u 源重复塞进 PRESET
let VALIDATED_CHANNELS_MIRROR =
    "https://wfygefjgd.github.io/live-player/iptv-mirrors/validated-channels.json"
let VALIDATED_M3U_MIRROR =
    "https://wfygefjgd.github.io/live-player/iptv-mirrors/validated-channels.m3u"
let VALIDATED_M3U_CDN_MIRROR =
    "https://cdn.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u"
let VALIDATED_M3U_FASTLY_MIRROR =
    "https://fastly.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u"
let VALIDATED_M3U_RAW =
    "https://raw.githubusercontent.com/wfygefjgd/live-player/main/iptv-mirrors/validated-channels.m3u"

// M3U 预置源（GitHub 系地址拉取时自动扩镜像，见 MirrorResolver）
let PRESET_SOURCES: [(name: String, url: String)] = [
    ("精选默认源 jsDelivr", VALIDATED_M3U_CDN_MIRROR),
    ("精选默认源 Fastly", VALIDATED_M3U_FASTLY_MIRROR),
    ("精选默认源 Pages", VALIDATED_M3U_MIRROR),
    ("精选默认源 raw", VALIDATED_M3U_RAW),
    ("Guovin 自动筛选源", "https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u"),
    ("vbskycn 双栈源", "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u"),
    ("fanmingming IPv6 源", "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"),
    ("BurningC4 中国源", "https://wfygefjgd.github.io/live-player/iptv-mirrors/burningc4-chinese-iptv.m3u"),
    ("zbefine 2026 维护源", "https://wfygefjgd.github.io/live-player/iptv-mirrors/zbefine-iptv.m3u"),
    ("suxuang IPv6 源", "https://wfygefjgd.github.io/live-player/iptv-mirrors/suxuang-myiptv.m3u"),
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
    /// 正在从 GitHub 拉取官方最新线路
    @Published var isRefreshingLatest = false

    /// 线路超时自动换线（默认开）
    @Published var lineTimeoutEnabled: Bool = true
    /// 失败线路自动加入黑名单（默认关）
    @Published var autoBlacklistEnabled: Bool = false
    /// 当前频道没有可用线路后是否继续自动切台（默认开启，保持历史行为）
    @Published var autoAdvanceOnExhaustion: Bool = true
    private let fusionEngine = SmartFusionEngine.shared

    let player = PlayerEngine()
    private let storage = StorageService()
    private var rawChannels: [Channel] = []
    var sourceUrls: [String] = []
    var activeSourceUrl = DEFAULT_SOURCE_URL
    private var autoSwitchState: AutoSwitchState = .idle
    private var pendingAutoSwitchReminder: String?
    private var started = false
    private var triedLineIndices = Set<Int>()

    // 统一任务管理
    private var osdTask: Task<Void, Never>?
    private var indTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var blacklistRefreshTask: Task<Void, Never>?

    private var lastVolumeTranslation: CGFloat = 0
    private var lastSilentSwitchAt: Date = .distantPast
    private var lastChannelSwitchAt: Date = .distantPast
    private let channelSwitchDebounceInterval: TimeInterval = 0.3  // 300ms 防抖
    private var autoRecoverChannelHops = 0
    private var playbackStable = false
    private var recoverGeneration = 0
    private var loadGeneration = 0
    /// 起播/切台代次：取消过期 playCurrent Task，防竞态覆盖
    private var playGeneration = 0
    /// 用户主动暂停：回前台/中断结束不得强制 resume
    private(set) var userPaused = false
    private var wasPlayingBeforeInterruption = false

    func startup() {
        guard !started else { return }
        started = true
        favorites = storage.loadFavorites()
        UIApplication.shared.isIdleTimerDisabled = true

        restoreLineTimeoutEnabled()
        restoreAutoBlacklistEnabled()
        restoreAutoAdvanceOnExhaustion()

        player.onReady = { [weak self] in self?.onPlayerReady() }
        player.onError = { [weak self] in self?.onPlayerError() }
        player.onStartupTimeout = { [weak self] in self?.onStartupTimeout() }
        player.onSilentAudio = { [weak self] in self?.onSilentAudio() }
        player.onLowSpeed = { [weak self] reason in self?.onLowSpeed(reason) }

        NetworkMonitor.shared.onSatisfied = { [weak self] in self?.onNetworkBecameAvailable() }
        NetworkMonitor.shared.onConnectionTypeChanged = { [weak self] type in
            self?.onConnectionTypeChanged(type)
        }

        restoreSources()

        // ① 缓存 / Bundle 立刻出画
        // ② 后台按当前活动源刷新（默认 DEFAULT_SOURCE_URL，不再走 JSON 旁路）
        if applyQuickStartChannels() {
            loadChannels(force: true, silent: true, preferActiveOnly: true)
        } else {
            beginBootstrapLoad()
        }
    }

    /// 快速启动：用户缓存 → Bundle 预筛列表
    @discardableResult
    private func applyQuickStartChannels() -> Bool {
        let cached = storage.loadChannels()
        if !cached.isEmpty {
            rawChannels = cached
            channels = applyRules(cached)
            if !channels.isEmpty {
                restoreLastChannelPosition()
                isBootstrapping = false
                playCurrent(showOSD: false, resetTried: true)
                return true
            }
        }
        if let bundleChannels = loadChannelsFromBundle(), !bundleChannels.isEmpty {
            rawChannels = bundleChannels
            channels = applyRules(bundleChannels)
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

        restoreLineTimeoutEnabled()
        restoreAutoAdvanceOnExhaustion()
        restoreSources()

        // 只加载频道，不启动播放器
        let cached = applyRules(storage.loadChannels())
        if !cached.isEmpty {
            channels = cached
        } else {
            loadChannels(force: true, silent: true, preferActiveOnly: true)
        }
    }

    // MARK: - 加载逻辑

    private func beginBootstrapLoad() {
        isBootstrapping = true
        indicatorText = ""
        bootstrapMessage = NetworkMonitor.shared.isSatisfied
            ? "正在加载频道列表..."
            : "等待网络权限（请点「允许」）..."
        // 始终优先当前活动源（默认源），不融合多源
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
                self.loadChannels(force: true, silent: false, preferActiveOnly: true)
            }
            while !Task.isCancelled {
                if !self.channels.isEmpty {
                    self.isBootstrapping = false
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self.bootstrapMessage = "仍无频道，继续刷新..."
                self.loadChannels(force: true, silent: false, preferActiveOnly: true)
            }
        }
    }

    func onNetworkBecameAvailable() {
        // 只恢复频道加载，不重载画面（避免闪屏）
        if channels.isEmpty {
            bootstrapMessage = "网络已连接，加载频道..."
            isBootstrapping = true
            loadChannels(force: true, silent: false, preferActiveOnly: true)
        }
    }

    /// 网络类型变化（WiFi ↔ 蜂窝）
    func onConnectionTypeChanged(_ type: NetworkMonitor.ConnectionType) {
        switch type {
        case .cellular:
            showIndicator("当前使用蜂窝网络")
        case .wifi, .wired, .unknown:
            break
        }
    }

    func onAppBecameActive() {
        UIApplication.shared.isIdleTimerDisabled = true
        WindowVideoSurface.shared.rebindPlayer()
        if channels.isEmpty {
            retryLoadSources()
            return
        }
        if userPaused { return }
        if player.player.currentItem == nil {
            playCurrent(showOSD: false, resetTried: false)
            return
        }
        if !player.isPlaying {
            player.resume()
        }
        bumpPlayerLayout()
        updateNowPlaying()
    }

    func retryLoadSources() {
        isBootstrapping = true
        bootstrapMessage = "正在加载频道列表..."
        indicatorText = ""
        loadChannels(force: true, silent: false, preferActiveOnly: true)
        scheduleRetryLoads()
    }

    /// 从 GitHub 官方源加载最新线路（忽略本地缓存；数据更新与 App 发版分离）
    func refreshLatestLineup() {
        guard !isRefreshingLatest else { return }
        isRefreshingLatest = true
        showIndicator("正在加载最新线路...")
        // 固定回到官方源，避免停在过期自定义源上
        activeSourceUrl = DEFAULT_SOURCE_URL
        if !sourceUrls.contains(DEFAULT_SOURCE_URL) {
            sourceUrls.insert(DEFAULT_SOURCE_URL, at: 0)
        }
        persistSources()
        storage.clearBlacklist()
        NetworkService.shared.clearCache()
        URLCache.shared.removeAllCachedResponses()

        loadGeneration += 1
        let gen = loadGeneration
        fusionEngine.invalidateSession()
        fusionEngine.onProgress = { [weak self] message in
            guard let self, self.loadGeneration == gen else { return }
            self.bootstrapMessage = message
            self.indicatorText = message
        }

        // Pages/raw 优先 + 防缓存参数；再竞速 jsDelivr
        let bust = "t=\(Int(Date().timeIntervalSince1970))"
        var urls: [String] = []
        for base in LATEST_LINEUP_URLS {
            if base.contains("jsdelivr.net") {
                urls.append(base)
            } else if base.contains("?") {
                urls.append("\(base)&\(bust)")
            } else {
                urls.append("\(base)?\(bust)")
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let (loaded, errMsg) = await self.fusionEngine.loadChannels(sourceUrls: urls)
            // 如果期间切源/重载导致结果过期，也必须释放刷新锁，否则按钮会永久禁用。
            self.isRefreshingLatest = false
            guard self.loadGeneration == gen else { return }
            if loaded.isEmpty {
                self.showIndicator(self.chineseLoadError(errMsg))
                return
            }
            // 最新线路：允许打断当前列表，整表替换
            self.onChannelsLoaded(loaded, errorMessage: nil, silent: false)
            let lines = loaded.reduce(0) { $0 + $1.sourceCount }
            self.showIndicator("最新线路 · \(loaded.count) 台 / \(lines) 线")
        }
    }

    private func bumpPlayerLayout() {
        playerLayoutEpoch &+= 1
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
    }

    func bumpLayoutForRemount() {
        bumpPlayerLayout()
        WindowVideoSurface.shared.rebindPlayer()
    }

    // MARK: - 源管理

    /// 历史失效预置（勿再自动加回）
    private static let deadPresetUrls: Set<String> = [
        "https://ghfast.top/raw.githubusercontent.com/dongyubin/IPTV/main/IPTV.m3u",
        "https://ghfast.top/raw.githubusercontent.com/gaotianliuyun/youshandefeiyang/main/live.m3u",
        "https://ghfast.top/raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u",
        "https://ghfast.top/raw.githubusercontent.com/kongkongyo/m3u8/main/iptv.m3u",
    ]

    func restoreSources() {
        var urls = OrderedDictionary<String, Bool>()
        for p in PRESET_SOURCES { urls[p.url] = true }
        for u in storage.loadSourceUrls() {
            let clean = u.trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { continue }
            if Self.deadPresetUrls.contains(clean) { continue }
            urls[clean] = true
        }
        sourceUrls = urls.keys
        let selected = storage.loadSelectedSourceUrl().trimmingCharacters(in: .whitespaces)
        let legacyValidatedPages = "https://wfygefjgd.github.io/live-player/iptv-mirrors/validated-channels.m3u"
        let legacyRawDefault = "https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u"
        if !selected.isEmpty,
           selected != legacyValidatedPages,
           selected != legacyRawDefault,
           !Self.deadPresetUrls.contains(selected) {
            activeSourceUrl = selected
            if !sourceUrls.contains(selected) { sourceUrls.append(selected) }
        } else {
            activeSourceUrl = DEFAULT_SOURCE_URL
        }
        if !sourceUrls.contains(activeSourceUrl) {
            sourceUrls.insert(activeSourceUrl, at: 0)
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
        // 换源时清空黑名单
        storage.clearBlacklist()
        reloadActiveSource()
    }

    func reloadActiveSource() {
        playGeneration &+= 1
        playTask?.cancel()
        recoverGeneration &+= 1
        pendingAutoSwitchReminder = nil
        autoRecoverChannelHops = 0
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
        fusionEngine.invalidateSession()

        Task { [weak self] in
            guard let self else { return }
            self.fusionEngine.onProgress = { [weak self] message in
                guard let self, self.loadGeneration == gen else { return }
                self.bootstrapMessage = message
            }

            let (loaded, errMsg) = await self.fusionEngine.loadChannels(sourceUrls: urls)

            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == gen else { return }
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

    // MARK: - 从远程刷新「已筛选」频道列表（GitHub Pages 镜像）
    /// - Returns: 是否成功应用列表
    @discardableResult
    func refreshChannelsFromRemote(silent: Bool = false) async -> Bool {
        // Pages 原址 + jsDelivr/ghproxy/raw 镜像并发竞速（被墙域名会挂到超时，串行太慢）
        let candidates = MirrorResolver.candidates(for: VALIDATED_CHANNELS_MIRROR)

        let fetched: [Channel]? = await withTaskGroup(of: [Channel]?.self) { group in
            for mirror in candidates {
                group.addTask {
                    guard let url = URL(string: mirror) else { return nil }
                    let req = URLRequest(
                        url: url,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 12
                    )
                    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
                    if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { return nil }
                    guard let json = try? JSONDecoder().decode(ValidatedChannelsResponse.self, from: data) else {
                        return nil
                    }
                    let channels = json.channels.map { ch in
                        Channel(name: ch.name, group: ch.group, key: ch.name, urls: ch.urls)
                    }
                    return channels.isEmpty ? nil : channels
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }

        guard let newChannels = fetched else {
            if !silent { showIndicator("镜像列表暂不可用") }
            return false
        }

        let prevKey = currentChannel?.key
        rawChannels = newChannels
        channels = applyRules(newChannels)
        storage.saveChannels(newChannels)
        isBootstrapping = false
        if let prevKey, let idx = channels.firstIndex(where: { $0.key == prevKey }) {
            currentIndex = idx
        } else {
            restoreLastChannelPosition()
        }
        if !silent {
            showIndicator("已加载 \(channels.count) 个已筛频道")
        }
        if !playbackStable || !player.isReady {
            playCurrent(showOSD: false, resetTried: true)
        }
        return true
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
        // 默认第一台永远 CCTV1（语言无关）；有上次记录则恢复
        let key = storage.loadLastChannelKey()
        if !key.isEmpty, let idx = channels.firstIndex(where: { $0.key == key }) {
            currentIndex = idx
            let si = storage.loadLastSourceIndex()
            currentSourceIndex = min(max(0, si), max(0, channels[idx].sourceCount - 1))
            return
        }
        currentIndex = indexOfPreferredDefaultChannel()
        currentSourceIndex = 0
    }

    /// 默认台：CCTV1（语言无关：CCTV-1 / 中央一台 / 央视综合…）
    private func indexOfPreferredDefaultChannel() -> Int {
        if let i = channels.firstIndex(where: { Self.isCCTV1Channel($0) }) {
            return i
        }
        if let i = channels.firstIndex(where: {
            $0.key.lowercased().hasPrefix("cctv") || $0.name.uppercased().contains("CCTV") || $0.name.contains("央视")
        }) {
            return i
        }
        return 0
    }

    /// 识别 CCTV1，忽略语言/空格/横线；排除 CCTV10–17
    private static func isCCTV1Channel(_ ch: Channel) -> Bool {
        if M3UParserService.cctvNumber(from: ch.key) == 1 { return true }
        if M3UParserService.cctvNumber(from: ch.name) == 1 { return true }
        let n = ch.name.replacingOccurrences(of: " ", with: "")
        if n.contains("中央一台") || n.contains("央视一台") || n.contains("中央一") { return true }
        if (n.contains("综合") || n.contains("綜合"))
            && (n.contains("央视") || n.contains("中央") || n.uppercased().contains("CCTV")) {
            // 综合台通常即 CCTV-1
            let num = M3UParserService.cctvNumber(from: ch.key)
            if num == Int.max || num == 1 { return true }
        }
        return false
    }

    /// 与侧栏一致的浏览顺序（收藏→央视→…），上下滑/超时切台都按此序，避免「乱跳」
    func browseOrderedChannels() -> [Channel] {
        ensureCCTV1FirstInBrowseOrder(sections(search: "").flatMap(\.channels))
    }

    private func advanceChannel(delta: Int, userInitiated: Bool) {
        if panelVisible { return }
        let ordered = browseOrderedChannels()
        guard !ordered.isEmpty else { return }
        if userInitiated {
            // A user action must cancel a queued automatic channel hop.
            recoverGeneration &+= 1
            pendingAutoSwitchReminder = nil
            let now = Date()
            if now.timeIntervalSince(lastChannelSwitchAt) < channelSwitchDebounceInterval { return }
            lastChannelSwitchAt = now
            autoRecoverChannelHops = 0
        }
        playbackStable = false
        cooldownTask?.cancel()
        autoSwitchState = .idle

        let curKey = currentChannel?.key
        let pos: Int = {
            if let curKey, let i = ordered.firstIndex(where: { $0.key == curKey }) { return i }
            return 0
        }()
        let next = ordered[(pos + delta + ordered.count) % ordered.count]
        guard let idx = channels.firstIndex(where: { $0.key == next.key }) else { return }
        currentIndex = idx
        currentSourceIndex = 0
        if userInitiated {
            pendingAutoSwitchReminder = nil
            panelVisible = false
        }
        triedLineIndices.removeAll()
        playCurrent(resetTried: true)
    }

    private func persistLastChannel() {
        guard let ch = currentChannel else { return }
        storage.saveLastChannel(key: ch.key, sourceIndex: currentSourceIndex)
    }

    // MARK: - 数据规则

    func applyRules(_ input: [Channel]) -> [Channel] {
        let hiddenLines = storage.loadHiddenLines()
        let blacklistedLines = autoBlacklistEnabled ? storage.loadBlacklistedLines() : []
        input.compactMap { src in
            var filtered = Channel(name: src.name, group: src.group, key: src.key)
            for url in src.urls {
                // 跳过手动隐藏的线路
                if hiddenLines.contains(url.trimmingCharacters(in: .whitespaces)) { continue }
                // 跳过黑名单中的线路
                if blacklistedLines.contains(url.trimmingCharacters(in: .whitespaces)) { continue }
                filtered.addUrl(url)
            }
            return filtered.sourceCount > 0 ? filtered : nil
        }
    }

    /// Rebuilds the filtered list while keeping the selected channel and URL when possible.
    private func reapplyChannelRules(restartIfCurrentLineRemoved: Bool) {
        let oldKey = currentChannel?.key
        let oldURL = currentUrl
        let oldIndex = currentIndex
        let oldSourceIndex = currentSourceIndex

        channels = applyRules(rawChannels)
        guard !channels.isEmpty else {
            currentIndex = 0
            currentSourceIndex = 0
            return
        }

        if let oldKey, let index = channels.firstIndex(where: { $0.key == oldKey }) {
            currentIndex = index
            if let oldURL, let sourceIndex = channels[index].urls.firstIndex(of: oldURL) {
                currentSourceIndex = sourceIndex
            } else {
                currentSourceIndex = min(oldSourceIndex, max(0, channels[index].sourceCount - 1))
            }
        } else {
            currentIndex = min(oldIndex, channels.count - 1)
            currentSourceIndex = min(oldSourceIndex, max(0, channels[currentIndex].sourceCount - 1))
        }

        let currentLineChanged = oldKey != currentChannel?.key ||
            (oldURL != nil && oldURL != currentUrl)
        if restartIfCurrentLineRemoved && currentLineChanged {
            playbackStable = false
            triedLineIndices.removeAll()
            playCurrent(showOSD: false, resetTried: true)
        }
    }

    private func startBlacklistRefreshTask() {
        blacklistRefreshTask?.cancel()
        guard autoBlacklistEnabled else { return }
        blacklistRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BLACKLIST_REFRESH_NS)
                guard let self, !Task.isCancelled, self.autoBlacklistEnabled else { return }
                self.reapplyChannelRules(restartIfCurrentLineRemoved: true)
            }
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
                let a1 = Self.isCCTV1Channel(a)
                let b1 = Self.isCCTV1Channel(b)
                if a1 != b1 { return a1 && !b1 }
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
        guard let ch = currentChannel else {
            showIndicator("当前频道地址无效")
            return
        }

        if resetTried {
            triedLineIndices.removeAll()
            cooldownTask?.cancel()
            autoSwitchState = .idle
            playbackStable = false
            currentSourceIndex = 0
        }

        playGeneration &+= 1
        let gen = playGeneration
        playTask?.cancel()
        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.playLineLoop(channel: ch, generation: gen, showOSD: showOSD)
        }
    }

    /// 统一起播：仅 hardFail 预检跳过；unknown/ok 都交给 AVPlayer
    private func playLineLoop(channel ch: Channel, generation gen: Int, showOSD: Bool) async {
        var guardLoops = 0
        while guardLoops < ch.sourceCount {
            guard !Task.isCancelled, playGeneration == gen else { return }
            guard currentChannel?.key == ch.key else { return }
            guardLoops += 1

            if currentSourceIndex < 0 || currentSourceIndex >= ch.urls.count {
                currentSourceIndex = 0
            }
            let idx = currentSourceIndex
            let raw = ch.urls[idx]

            // 黑名单跳过
            if autoBlacklistEnabled, storage.isLineBlacklisted(raw) {
                triedLineIndices.insert(idx)
                currentSourceIndex = (idx + 1) % max(ch.sourceCount, 1)
                continue
            }
            if storage.isLineHidden(raw) {
                triedLineIndices.insert(idx)
                currentSourceIndex = (idx + 1) % max(ch.sourceCount, 1)
                continue
            }

            guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "rtmp" || scheme == "rtsp" else {
                if lineTimeoutEnabled {
                    triedLineIndices.insert(idx)
                    currentSourceIndex = (idx + 1) % max(ch.sourceCount, 1)
                    continue
                }
                autoSwitchState = .idle
                showIndicator("当前线路地址无效，请手动切换")
                return
            }

            // 预检：只有 hardFail 才跳；超时/慢线 unknown 仍播放
            if lineTimeoutEnabled && (scheme == "http" || scheme == "https") {
                let result = await LineSpeedTester.shared.quickPreflight(raw, timeout: 2.5)
                guard !Task.isCancelled, playGeneration == gen else { return }
                guard currentChannel?.key == ch.key else { return }
                if lineTimeoutEnabled && result == .hardFail {
                    triedLineIndices.insert(idx)
                    if autoBlacklistEnabled { storage.blacklistLine(raw) }
                    currentSourceIndex = (idx + 1) % max(ch.sourceCount, 1)
                    if guardLoops < ch.sourceCount {
                        showIndicator("死链已跳过…")
                    }
                    continue
                }
            }

            triedLineIndices.insert(idx)
            if autoSwitchState == .cooldown { autoSwitchState = .idle }
            if autoSwitchState == .switching { autoSwitchState = .idle }
            player.play(url: u)
            persistLastChannel()
            if showOSD { showChannelOSD() }
            updateNowPlaying()
            return
        }
        guard playGeneration == gen else { return }
        // 当前事务已经尝试完所有线路，允许 autoSwitchLine 决定是否切下一台。
        autoSwitchState = .idle
        showIndicator("当前频道无可用线路")
        autoSwitchLine(hint: "当前频道无可用线路", reason: .hardFail)
    }

    private func onPlayerReady() {
        autoSwitchState = .idle
        playbackStable = true
        autoRecoverChannelHops = 0
        isBootstrapping = false
        userPaused = false
        if let reminder = pendingAutoSwitchReminder {
            pendingAutoSwitchReminder = nil
            if !indicatorText.contains("可在设置中关闭") {
                showIndicator(reminder)
            }
        } else if !indicatorText.isEmpty {
            showIndicator("")
        }
        bumpPlayerLayout()
        WindowVideoSurface.shared.rebindPlayer()
        updateNowPlaying()
        UIApplication.shared.isIdleTimerDisabled = true
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
        // 必要条件①：播放器硬失败（item failed），且用户未暂停、侧栏未开
        guard lineTimeoutEnabled, !userPaused, !panelVisible else { return }
        autoSwitchLine(hint: "线路失败", reason: .hardFail)
    }
    private func onStartupTimeout() {
        // 证据驱动失败 / 硬兜底：仍无画面
        guard lineTimeoutEnabled, !userPaused, !panelVisible else { return }
        if player.isReady || playbackStable { return }
        autoSwitchLine(hint: "线路不可用", reason: .noData)
    }
    private func onLowSpeed(_ reason: String) {
        // 仅引擎多信号确认后的无数据；画面仍在播则忽略
        guard lineTimeoutEnabled, !userPaused, !panelVisible else { return }
        if playbackStable, player.isReady, player.isPlaying {
            return
        }
        autoSwitchLine(hint: reason, reason: .noData)
    }

    // MARK: - 静音检测

    private func onSilentAudio() {
        // 默认关闭无声自动换线（引擎侧已不 schedule）；保留接口防回调
        return
    }

    /// 自动换线必要条件（仅下列确认坏线才切）
    /// 1. hardFail  播放器错误
    /// 2. noData    起播无画面 / 无网 / 长时间无数据且画面不动
    /// 3. noAudio   已出画且确认无音轨（可被冷却挡住）
    /// 明确不切：单纯卡顿、缓冲、健康度 warning、用户暂停、侧栏打开
    private enum FailReason {
        case hardFail
        case noData
        case noAudio

        var isConfirmedBad: Bool { true }
    }

    /// 自动切线：只响应确认坏线事件；下一条统一走 playLineLoop（预检+黑名单）
    private func autoSwitchLine(hint: String, reason: FailReason) {
        guard lineTimeoutEnabled else { return }
        if panelVisible { return }
        guard let ch = currentChannel else {
            showIndicator(hint)
            return
        }
        if reason == .noAudio { return }
        if autoSwitchState == .cooldown, !autoAdvanceOnExhaustion { return }

        if autoSwitchState == .cooldown {
            switch reason {
            case .hardFail, .noData:
                cooldownTask?.cancel()
                autoSwitchState = .idle
            case .noAudio:
                return
            }
        }
        // AVPlayer may report status, error-log and end-time failures for one item.
        // Keep one automatic switch transaction in flight until its preflight ends.
        if autoSwitchState == .switching { return }

        autoSwitchState = .switching
        playbackStable = false

        if autoBlacklistEnabled, currentSourceIndex >= 0, currentSourceIndex < ch.urls.count {
            storage.blacklistLine(ch.urls[currentSourceIndex])
        }
        triedLineIndices.insert(currentSourceIndex)

        // 找下一条：跳过已试 / 隐藏 / 黑名单
        if ch.sourceCount > 1 {
            for nxt in 0..<ch.sourceCount {
                if triedLineIndices.contains(nxt) { continue }
                let cand = ch.urls[nxt]
                if storage.isLineHidden(cand) { continue }
                if autoBlacklistEnabled, storage.isLineBlacklisted(cand) { continue }
                guard let u = URL(string: cand),
                      let scheme = u.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" || scheme == "rtmp" || scheme == "rtsp" else {
                    triedLineIndices.insert(nxt)
                    continue
                }
                _ = u
                currentSourceIndex = nxt
                let reminder = "已自动切换线路 \(nxt + 1)/\(ch.sourceCount)，可在设置中关闭"
                pendingAutoSwitchReminder = reminder
                showIndicator(reminder)
                // 统一走 playCurrent 路径（含 generation + 预检），不直接 player.play
                playGeneration &+= 1
                let gen = playGeneration
                playTask?.cancel()
                playTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.playLineLoop(channel: ch, generation: gen, showOSD: true)
                }
                return
            }
        }

        autoSwitchState = .idle
        guard autoAdvanceOnExhaustion else {
            pendingAutoSwitchReminder = nil
            showIndicator("本台线路不可用，请手动换台")
            beginCooldown()
            return
        }
        if autoRecoverChannelHops >= AUTO_RECOVER_MAX_CHANNELS {
            pendingAutoSwitchReminder = nil
            showIndicator("连续多台无可用线路，请手动换台或换源")
            beginCooldown()
            return
        }
        autoRecoverChannelHops += 1
        let reminder = "已自动切换频道，可在设置中关闭"
        pendingAutoSwitchReminder = reminder
        showIndicator(reminder)
        recoverGeneration += 1
        let gen = recoverGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, self.recoverGeneration == gen else { return }
            self.autoAdvanceChannel()
        }
    }

    /// 自动恢复切台：按侧栏浏览序下一台（非 raw 数组下标）
    private func autoAdvanceChannel() {
        guard !panelVisible else { return }
        advanceChannel(delta: 1, userInitiated: false)
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
        advanceChannel(delta: 1, userInitiated: true)
    }

    func prevChannel() {
        advanceChannel(delta: -1, userInitiated: true)
    }

    func selectChannel(_ ch: Channel) {
        guard let idx = channels.firstIndex(where: { $0.key == ch.key }) else { return }
        pendingAutoSwitchReminder = nil
        // 取消进行中的自动恢复，避免选台后又被 hop 拉走
        recoverGeneration += 1
        autoRecoverChannelHops = 0
        playbackStable = false
        currentIndex = idx
        currentSourceIndex = 0
        panelVisible = false
        autoSwitchState = .idle
        playCurrent(resetTried: true)
    }

    /// 侧栏「第一个」展示位：始终把 CCTV1 顶到列表最前（不影响分组结构，仅浏览序）
    func ensureCCTV1FirstInBrowseOrder(_ list: [Channel]) -> [Channel] {
        guard let cctv1 = list.first(where: { Self.isCCTV1Channel($0) }) else { return list }
        var rest = list.filter { $0.key != cctv1.key }
        rest.insert(cctv1, at: 0)
        return rest
    }

    func switchSource(direction: Int) {
        if panelVisible { return }
        guard let ch = currentChannel, ch.sourceCount > 1 else {
            if let ch = currentChannel, ch.sourceCount <= 1 {
                showIndicator("当前频道只有一个来源")
                showChannelOSD()
            }
            return
        }
        recoverGeneration += 1
        pendingAutoSwitchReminder = nil
        autoSwitchState = .idle
        autoRecoverChannelHops = 0
        playbackStable = false
        currentSourceIndex = (currentSourceIndex + direction + ch.sourceCount) % ch.sourceCount
        triedLineIndices = [currentSourceIndex]
        showIndicator("切换线路 \(currentSourceIndex + 1)/\(ch.sourceCount)")
        // 勿 resetTried：保留手动选的线路索引
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
        if !panelVisible {
            recoverGeneration &+= 1
        }
        panelVisible.toggle()
    }

    func pause() {
        recoverGeneration &+= 1
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

    deinit {
        osdTask?.cancel()
        indTask?.cancel()
        cooldownTask?.cancel()
        retryTask?.cancel()
        playTask?.cancel()
        blacklistRefreshTask?.cancel()
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// 线路超时开关
    func setLineTimeoutEnabled(_ enabled: Bool) {
        lineTimeoutEnabled = enabled
        if !enabled {
            recoverGeneration &+= 1
            pendingAutoSwitchReminder = nil
            cooldownTask?.cancel()
            autoSwitchState = .idle
        }
        player.setLineTimeoutEnabled(enabled)
        storage.saveLineTimeoutEnabled(enabled)
        showIndicator(enabled ? "已开启自动切换线路" : "已关闭自动切换线路")
    }

    func restoreLineTimeoutEnabled() {
        lineTimeoutEnabled = storage.loadLineTimeoutEnabled()
        player.setLineTimeoutEnabled(lineTimeoutEnabled)
    }

    /// 失败线路黑名单开关
    func setAutoBlacklistEnabled(_ enabled: Bool) {
        autoBlacklistEnabled = enabled
        storage.saveAutoBlacklistEnabled(enabled)
        reapplyChannelRules(restartIfCurrentLineRemoved: enabled)
        startBlacklistRefreshTask()
        showIndicator(enabled ? "已开启失败线路黑名单" : "已关闭失败线路黑名单")
    }

    func restoreAutoBlacklistEnabled() {
        autoBlacklistEnabled = storage.loadAutoBlacklistEnabled()
        startBlacklistRefreshTask()
    }

    func setAutoAdvanceOnExhaustion(_ enabled: Bool) {
        autoAdvanceOnExhaustion = enabled
        if !enabled {
            recoverGeneration &+= 1
            pendingAutoSwitchReminder = nil
        }
        storage.saveAutoAdvanceOnExhaustion(enabled)
        showIndicator(enabled ? "已开启自动切换频道" : "已关闭自动切换频道")
    }

    func restoreAutoAdvanceOnExhaustion() {
        autoAdvanceOnExhaustion = storage.loadAutoAdvanceOnExhaustion()
    }

    /// 手动清空黑名单
    func clearBlacklist() {
        storage.clearBlacklist()
        reapplyChannelRules(restartIfCurrentLineRemoved: false)
        showIndicator("黑名单已清空")
    }
}
