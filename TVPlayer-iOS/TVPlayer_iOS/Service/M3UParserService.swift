import Foundation

class M3UParserService {
    private static let groupPattern = try! NSRegularExpression(pattern: "group-title=\"([^\"]*)\"")
    private static let namePattern = try! NSRegularExpression(pattern: ",(.+?)$")
    private static let cctvPattern = try! NSRegularExpression(pattern: "cctv\\s*[-_ ]*0*([1-9]\\d*)(k|\\+)?", options: .caseInsensitive)
    private static let trailingPattern = try! NSRegularExpression(
        pattern: "(fhd|uhd|hd|sd|4k|8k|1080p|720p|576p|50fps|60fps|h264|h265|hevc|hdr|"
            + "高清|超清|标清|蓝光|流畅|高码|高帧|测试|备用\\d*|线路\\d+|源\\d+|"
            + "直播|在线|综合|频道|央视|卫视|中文|台)$",
        options: .caseInsensitive
    )

    static func parse(_ text: String) -> [Channel] {
        guard !text.isEmpty else { return [] }
        var channels = OrderedDictionary<String, Channel>()
        var pendingName: String? = nil
        var pendingGroup = "未分组"

        let lines = text.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                if let g = groupPattern.firstMatch(in: line) {
                    pendingGroup = g
                }
                if let n = namePattern.firstMatch(in: line) {
                    pendingName = n
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), let name = pendingName {
                let display = normalizeDisplayName(name)
                let key = normalizeName(display)
                if let existing = channels[key] {
                    existing.addUrl(line)
                } else {
                    let ch = Channel(name: display, group: pendingGroup, key: key)
                    ch.addUrl(line)
                    channels[key] = ch
                }
                pendingName = nil
                pendingGroup = "未分组"
            }
        }
        return Array(channels.values)
    }

    static func normalizeName(_ name: String) -> String {
        var w = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let m = cctvPattern.firstMatch(in: w) {
            let suffix = m.count > 2 ? m[2].uppercased() : ""
            return "cctv\(Int(m[1])!)\(suffix)"
        }
        w = w.replacingOccurrences(of: "[\\s\\-—_\u{00B7}\u{002E}\u{FF0C}\u{3001}\u{3002}/\\\\|()（）\\[\\]【】:+]+", with: "", options: .regularExpression)
        for (a, b) in [("中央", "cctv"), ("央视", "cctv"), ("高清", ""), ("超清", ""), ("蓝光", ""), ("流畅", ""), ("频道", ""), ("直播", ""), ("在线", "")] {
            w = w.replacingOccurrences(of: a, with: b)
        }
        w = w.replacingOccurrences(of: "(测试|试看|备份|备用|线路|源)+", with: "", options: .regularExpression)
        w = w.replacingOccurrences(of: "(?:第)?0*([1-9]\\d*)台$", with: "$1", options: .regularExpression)
        w = stripTrailingNoise(w)
        return w
    }

    static func normalizeDisplayName(_ rawName: String) -> String {
        var clean = rawName.trimmingCharacters(in: .whitespaces)
        if let m = cctvPattern.firstMatch(in: clean) {
            let suffix = m.count > 2 ? m[2].uppercased() : ""
            return "CCTV-\(Int(m[1])!)\(suffix)"
        }
        clean = clean.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "(?i)(高清|超清|蓝光|流畅|频道|直播|在线|测试|备用\\d*|线路\\d+|源\\d+)$", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "未知" : clean
    }

    private static func stripTrailingNoise(_ value: String) -> String {
        var w = value
        while true {
            if let m = trailingPattern.firstMatch(in: w) {
                w = String(w[..<m.startIndex])
            } else {
                break
            }
        }
        return w
    }
}

// MARK: - Regex helpers
private extension NSRegularExpression {
    func firstMatch(in string: String) -> [String]? {
        let range = NSRange(location: 0, length: string.utf16.count)
        guard let m = firstMatch(in: string, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            (string as NSString).substring(with: m.range(at: i))
        }
    }
}


