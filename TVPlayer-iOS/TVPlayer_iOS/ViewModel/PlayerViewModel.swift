import SwiftUI
import AVKit
import MediaPlayer

let DEFAULT_SOURCE_URL = "https://raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8"

let DEFAULT_MIRRORS = [
    DEFAULT_SOURCE_URL,
    "https://ghfast.top/raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8",
    "https://raw.gitmirror.com/best-fan/iptv-sources/master/cn_all_status.m3u8",
    "https://raw.kkgithub.com/best-fan/iptv-sources/master/cn_all_status.m3u8",
]

let CHANNEL_OSD_MS: UInt64 = 2_500_000_000
let STALL_TIMEOUT_MS: UInt64 = 7_000_000_000
let FLOAT_HIDE_MS: UInt64 = 2_500_000_000

let PRESET_SOURCES: [(name: String, url: String)] = [
    ("默认源", DEFAULT_SOURCE_URL),
    ("best-fan 全量", "https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8"),
    ("TVBox", "https://ghfast.top/raw.githubusercontent.com/Supprise0901/TVBox_live/main/live.txt"),
    ("vbskycn", "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/tv.m3u"),
    ("fanmingming", "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"),
]

@MainActor
class PlayerViewModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var currentIndex = 0
    @Published var currentSourceIndex = 0
    @Published var panelVisible = false
    @Published var locked = false
    @Published var showSourceSheet = false
    @Published var showDeleteAlert = false
    @Published var channelOSD: String = ""
    @Published var indicatorText: String = ""

    let player = PlayerEngine()
    private let storage = StorageService()
    private var rawChannels: [Channel] = []
    var sourceUrls: [String] = []
    var activeSourceUrl = DEFAULT_SOURCE_URL
    private var waitingForReady = false
    private var autoSwitching = false
    private var playbackToken = 0
    private var osdTask: Task<Void, Never>?
    private var indTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var floatTask: Task<Void, Never>?

    func startup() {
        player.onReady = { [weak self] in
            Task { @MainActor in
                self?.onPlayerReady()
            }
        }
        player.onError = { [weak self] in
            Task { @MainActor in
                self?.onPlayerError()
            }
        }
        restoreSources()
        // load cache first, then async refresh
        let cached = applyRules(storage.loadChannels())
        if !cached.isEmpty {
            channels = cached
            currentIndex = 0
            currentSourceIndex = 0
            playCurrent(showOSD: false, timeoutMs: STALL_TIMEOUT_MS)
        }
        loadChannels(force: cached.isEmpty)
    }

    // MARK: - Sources
    func restoreSources() {
        var urls = OrderedDictionary<String, Bool>()
        for p in PRESET_SOURCES { urls[p.url] = true }
        for u in storage.loadSourceUrls() {
            let clean = u.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { urls[clean] = true }
        }
        sourceUrls = Array(urls.values)
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
        player.stop()
        indicatorText = "正在切换源..."
        showFloat()
        loadChannels(force: true)
    }

    // MARK: - Load
    func loadChannels(force: Bool = true) {
        guard !player.isReady || force else { return }
        indicatorText = "加载中..."
        let urls = buildCandidates()
        Task {
            let loaded = await NetworkService.shared.fetchWithCandidates(urls: urls)
            await MainActor.run { onChannelsLoaded(loaded) }
        }
    }

    private func onChannelsLoaded(_ loaded: [Channel]) {
        guard !loaded.isEmpty else {
            if channels.isEmpty {
                indicatorText = "加载失败"
            } else {
                indicatorText = "刷新失败"
            }
            return
        }
        rawChannels = loaded.map { Channel(name: $0.name, group: $0.group, key: $0.key, urls: $0.urls) }
        channels = applyRules(rawChannels)
        guard !channels.isEmpty else {
            indicatorText = "加载失败"
            return
        }
        storage.saveChannels(loaded)
        indicatorText = "已加载 \(channels.count) 个频道"
        currentIndex = 0
        currentSourceIndex = 0
        playCurrent(showOSD: false, timeoutMs: STALL_TIMEOUT_MS)
    }

    func buildCandidates() -> [String] {
        var urls = [activeSourceUrl]
        if activeSourceUrl == DEFAULT_SOURCE_URL {
            for m in DEFAULT_MIRRORS where !urls.contains(m) { urls.append(m) }
        } else if activeSourceUrl.contains("raw.githubusercontent.com") {
            for prefix in ["https://ghfast.top/raw.githubusercontent.com/",
                           "https://raw.gitmirror.com/",
                           "https://raw.kkgithub.com/"] {
                let mirrored = activeSourceUrl.replacingOccurrences(of: "https://raw.githubusercontent.com/", with: prefix)
                if !urls.contains(mirrored) { urls.append(mirrored) }
            }
        }
        return urls
    }

    // MARK: - Rules
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

    // MARK: - Current
    var currentChannel: Channel? {
        guard !channels.isEmpty, (0..<channels.count).contains(currentIndex) else { return nil }
        return channels[currentIndex]
    }

    var currentUrl: String? {
        guard let ch = currentChannel,
              (0..<ch.sourceCount).contains(currentSourceIndex) else { return nil }
        return ch.urls[currentSourceIndex]
    }

    // MARK: - Play
    func playCurrent(showOSD: Bool = true, timeoutMs: UInt64 = STALL_TIMEOUT_MS) {
        guard let ch = currentChannel, let url = currentUrl, let u = URL(string: url) else {
            indicatorText = "当前频道地址无效"
            return
        }
        playbackToken += 1
        waitingForReady = true
        autoSwitching = false
        cancelStall()
        scheduleStall(timeoutMs: timeoutMs)

        player.play(url: u)
        if showOSD { showChannelOSD() }
        showFloat()
    }

    private func onPlayerReady() {
        waitingForReady = false
        autoSwitching = false
        cancelStall()
        scheduleHideFloat()
    }

    private func onPlayerError() {
        waitingForReady = false
        cancelStall()
        switchNextLine(hint: "播放失败，切换下一线路")
    }

    // MARK: - Navigation
    func nextChannel() {
        guard !locked, !channels.isEmpty else { return }
        currentIndex = (currentIndex + 1) % channels.count
        currentSourceIndex = 0
        playCurrent()
    }

    func prevChannel() {
        guard !locked, !channels.isEmpty else { return }
        currentIndex = (currentIndex - 1 + channels.count) % channels.count
        currentSourceIndex = 0
        playCurrent()
    }

    func switchSource(direction: Int) {
        guard !locked, let ch = currentChannel, ch.sourceCount > 1 else {
            if let ch = currentChannel, ch.sourceCount <= 1 {
                indicatorText = "当前频道只有一个来源"
                showChannelOSD()
            }
            return
        }
        currentSourceIndex = (currentSourceIndex + direction + ch.sourceCount) % ch.sourceCount
        playCurrent(timeoutMs: STALL_TIMEOUT_MS)
    }

    func switchNextLine(hint: String) {
        guard let ch = currentChannel, ch.sourceCount > 1, !autoSwitching else {
            autoSwitching = false
            indicatorText = hint
            return
        }
        autoSwitching = true
        let nxt = (currentSourceIndex + 1) % ch.sourceCount
        guard nxt != currentSourceIndex else {
            autoSwitching = false
            indicatorText = hint
            return
        }
        currentSourceIndex = nxt
        indicatorText = hint
        playCurrent(timeoutMs: STALL_TIMEOUT_MS)
    }

    // MARK: - Stall
    private func scheduleStall(timeoutMs: UInt64) {
        cancelStall()
        let token = playbackToken
        stallTask = Task {
            try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            guard !Task.isCancelled, token == playbackToken, waitingForReady else { return }
            await MainActor.run {
                waitingForReady = false
                switchNextLine(hint: "线路超时，切换下一线路")
            }
        }
    }

    private func cancelStall() { stallTask?.cancel(); stallTask = nil }

    // MARK: - OSD / Indicator
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
        indTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { indicatorText = "" }
        }
    }

    // MARK: - Float buttons
    func showFloat() {
        cancelHideFloat()
        objectWillChange.send()
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

    func cancelHideFloat() { floatTask?.cancel(); floatTask = nil }
    func hideFloat() { }
    // float visibility is controlled by onChanged via schedule

    // MARK: - Actions
    func onTap() {
        showFloat()
        guard !locked else { return }
        player.toggle()
    }

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

    func adjustBrightness(delta: Float) {
        let current = UIScreen.main.brightness
        UIScreen.main.brightness = max(0.05, min(1.0, current + CGFloat(delta)))
        showIndicator("亮度 \(Int(UIScreen.main.brightness * 100))%")
    }

    func adjustVolume(delta: Float) {
        // Use MPVolumeView
        showIndicator("音量 \(delta)")
    }

    // MARK: - Delete line
    func confirmDeleteLine() {
        guard let ch = currentChannel, currentUrl != nil else { return }
        showDeleteAlert = true
    }

    func doDeleteLine() {
        guard let url = currentUrl, let ch = currentChannel else { return }
        storage.hideLine(url)
        let targetKey = ch.key
        let nextIdx = ch.sourceCount <= 1 ? -1 : currentSourceIndex
        let oldIdx = currentIndex

        let source = rawChannels.isEmpty ? channels : rawChannels
        let rebuilt = applyRules(source)
        channels = rebuilt

        guard !channels.isEmpty else {
            player.stop()
            currentIndex = 0
            currentSourceIndex = 0
            indicatorText = "线路已删除"
            return
        }

        if let found = channels.firstIndex(where: { $0.key == targetKey }) {
            currentIndex = found
            let updated = channels[found]
            if updated.sourceCount <= 0 { nextChannel(); return }
            currentSourceIndex = nextIdx >= 0 && nextIdx < updated.sourceCount ? nextIdx : 0
        } else {
            currentIndex = min(oldIdx, channels.count - 1)
            currentSourceIndex = 0
        }
        indicatorText = "已删除当前线路"
        playCurrent(timeoutMs: STALL_TIMEOUT_MS)
    }
}

// MARK: - Ordered Dictionary helper
struct OrderedDictionary<Key: Hashable, Value> {
    private var keys: [Key] = []
    private var dict: [Key: Value] = [:]
    var values: [Value] { keys.compactMap { dict[$0] } }
    mutating subscript(key: Key) -> Value? {
        get { dict[key] }
        set {
            if newValue == nil { dict.removeValue(forKey: key); keys.removeAll { $0 == key } }
            else if dict[key] == nil { keys.append(key); dict[key] = newValue }
            else { dict[key] = newValue }
        }
    }
}
