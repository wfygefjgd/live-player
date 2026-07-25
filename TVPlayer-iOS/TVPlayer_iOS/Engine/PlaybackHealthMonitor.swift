import AVKit
import AVFoundation

/// 播放健康度监控器 - 多维度综合检测
@MainActor
final class PlaybackHealthMonitor {
    // MARK: - 健康度指标

    struct HealthMetrics {
        var videoHealth: VideoHealth = .unknown
        var audioHealth: AudioHealth = .unknown
        var networkHealth: NetworkHealth = .unknown
        var overallHealth: OverallHealth = .unknown
    }

    enum VideoHealth {
        case unknown
        case healthy           // 画面正常渲染和更新
        case frozen            // 画面冻结（有渲染但无更新）
        case blackScreen       // 黑屏（未渲染）
    }

    enum AudioHealth {
        case unknown
        case healthy           // 音频正常输出
        case silent            // 有音频轨道但无输出
        case noTrack           // 无音频轨道
    }

    enum NetworkHealth {
        case unknown
        case healthy           // 缓冲充足，无卡顿
        case buffering         // 正在缓冲
        case stalled           // 频繁卡顿
    }

    enum OverallHealth {
        case unknown
        case healthy           // 一切正常
        case warning           // 单一问题
        case critical          // 多重问题，需要切换
    }

    // MARK: - 私有状态

    private weak var player: AVPlayer?
    private var hasRendered = false
    private var lastTimeProgressAt: Date = .distantPast
    private var lastItemTime: CMTime = .zero
    private var bufferEmptyCount = 0
    private var stallCount = 0

    private var audioSession: AVAudioSession { AVAudioSession.sharedInstance() }

    // 配置阈值
    private let videoFreezeThreshold: TimeInterval = 2.0
    private let bufferEmptyThreshold = 3
    private let stallThreshold = 2

    // MARK: - 初始化

    init(player: AVPlayer) {
        self.player = player
    }

    // MARK: - 公共方法

    /// 更新画面进度（从 TimeObserver 调用）
    func updateVideoProgress(time: CMTime, hasRendered: Bool) {
        self.hasRendered = hasRendered

        if time != lastItemTime {
            if lastTimeProgressAt == .distantPast {
                lastTimeProgressAt = Date()
            } else if time > lastItemTime {
                lastTimeProgressAt = Date()
            }
            lastItemTime = time
        }
    }

    /// 记录缓冲空事件
    func recordBufferEmpty() {
        bufferEmptyCount += 1
    }

    /// 记录卡顿事件
    func recordStall() {
        stallCount += 1
    }

    /// 重置统计
    func reset() {
        hasRendered = false
        lastTimeProgressAt = .distantPast
        lastItemTime = .zero
        bufferEmptyCount = 0
        stallCount = 0
    }

    /// 获取当前健康度指标
    func getCurrentMetrics() -> HealthMetrics {
        var metrics = HealthMetrics()

        metrics.videoHealth = evaluateVideoHealth()
        metrics.audioHealth = evaluateAudioHealth()
        metrics.networkHealth = evaluateNetworkHealth()
        metrics.overallHealth = evaluateOverallHealth(metrics)

        return metrics
    }

    /// 判断是否需要立即切换
    func shouldSwitchImmediately() -> (should: Bool, reason: String) {
        let metrics = getCurrentMetrics()

        // 严重问题：黑屏 + 无声音
        if metrics.videoHealth == .blackScreen && metrics.audioHealth == .noTrack {
            return (true, "黑屏无声音")
        }

        // 严重问题：画面冻结 + 无声音 + 网络卡顿
        if metrics.videoHealth == .frozen &&
           metrics.audioHealth != .healthy &&
           metrics.networkHealth == .stalled {
            return (true, "画面冻结且网络卡顿")
        }

        // 综合健康度为危急
        if metrics.overallHealth == .critical {
            return (true, "综合健康度危急")
        }

        return (false, "")
    }

    /// 判断是否应该尝试切换线路
    func shouldSwitchLine() -> (should: Bool, reason: String) {
        let metrics = getCurrentMetrics()

        // 视频问题但有声音
        if metrics.videoHealth == .frozen && metrics.audioHealth == .healthy {
            return (true, "视频流问题")
        }

        // 音频问题但有画面
        if metrics.audioHealth == .silent && metrics.videoHealth == .healthy {
            return (true, "音频流问题")
        }

        // 网络频繁卡顿
        if metrics.networkHealth == .stalled {
            return (true, "网络卡顿")
        }

        return (false, "")
    }

    // MARK: - 私有评估方法

    private func evaluateVideoHealth() -> VideoHealth {
        guard let player = player, player.currentItem != nil else {
            return .unknown
        }

        // 未渲染过 = 黑屏
        if !hasRendered {
            return .blackScreen
        }

        // 渲染过但进度长时间未更新 = 冻结
        if lastTimeProgressAt != .distantPast {
            let elapsed = Date().timeIntervalSince(lastTimeProgressAt)
            if elapsed > videoFreezeThreshold {
                return .frozen
            }
        }

        return .healthy
    }

    private func evaluateAudioHealth() -> AudioHealth {
        guard let player = player, let item = player.currentItem else {
            return .unknown
        }

        // 检查音频轨道
        let audioTracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
        if audioTracks.isEmpty {
            return .noTrack
        }

        // 检查是否有启用的音频轨道
        let hasEnabledTrack = audioTracks.contains { $0.isEnabled }
        if !hasEnabledTrack {
            return .silent
        }

        // 检查播放器音量
        if player.volume < 0.01 {
            return .silent
        }

        return .healthy
    }

    private func evaluateNetworkHealth() -> NetworkHealth {
        guard let player = player, let item = player.currentItem else {
            return .unknown
        }

        // 检查缓冲状态
        if item.isPlaybackBufferEmpty {
            return .buffering
        }

        // 检查历史卡顿次数
        if stallCount >= stallThreshold || bufferEmptyCount >= bufferEmptyThreshold {
            return .stalled
        }

        return .healthy
    }

    private func evaluateOverallHealth(_ metrics: HealthMetrics) -> OverallHealth {
        var issueCount = 0

        if metrics.videoHealth != .healthy && metrics.videoHealth != .unknown {
            issueCount += 1
        }
        if metrics.audioHealth != .healthy && metrics.audioHealth != .unknown {
            issueCount += 1
        }
        if metrics.networkHealth != .healthy && metrics.networkHealth != .unknown {
            issueCount += 1
        }

        if issueCount == 0 {
            return .healthy
        } else if issueCount == 1 {
            return .warning
        } else {
            return .critical
        }
    }
}
