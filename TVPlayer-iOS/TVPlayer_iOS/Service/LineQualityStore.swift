import Foundation

/// 本地线路质量记忆。只用于同频道线路排序，不把慢线永久判死。
final class LineQualityStore {
    static let shared = LineQualityStore()

    struct Record: Codable {
        var successfulStarts = 0
        var failures = 0
        var stalls = 0
        var stableSeconds: TimeInterval = 0
        var observedBitrate: Double = 0
        var lastUpdated = Date()

        var score: Double {
            Double(successfulStarts) * 24
                - Double(failures) * 55
                - Double(stalls) * 12
                + min(stableSeconds / 15, 80)
                + min(observedBitrate / 1_000_000, 8)
        }

        var hasEvidence: Bool {
            successfulStarts > 0 || failures > 0 || stalls > 0 || stableSeconds >= 10
        }
    }

    private let key = "line_quality_records_v1"
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "tvplayer.line-quality", qos: .utility)
    private var records: [String: Record]

    private init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
        prune()
    }

    func preferredIndex(in urls: [String]) -> Int? {
        queue.sync {
            var best: (index: Int, score: Double)?
            for (index, raw) in urls.enumerated() {
                let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let record = records[url], record.hasEvidence else { continue }
                if best == nil || record.score > best!.score {
                    best = (index, record.score)
                }
            }
            guard let best, best.score > 0 else { return nil }
            return best.index
        }
    }

    func recordStart(url: String, startupSeconds: TimeInterval) {
        update(url: url) { record in
            record.successfulStarts += 1
            // 快速起播略加稳定信用，慢起播不作为失败。
            if startupSeconds <= 4 { record.stableSeconds += 3 }
        }
    }

    func recordFailure(url: String) {
        update(url: url) { $0.failures += 1 }
    }

    func recordStall(url: String) {
        update(url: url) { $0.stalls += 1 }
    }

    func recordStablePlayback(url: String, seconds: TimeInterval, observedBitrate: Double) {
        guard seconds > 0 else { return }
        update(url: url) { record in
            record.stableSeconds += min(seconds, 30)
            if observedBitrate > 0 {
                record.observedBitrate = record.observedBitrate == 0
                    ? observedBitrate
                    : record.observedBitrate * 0.7 + observedBitrate * 0.3
            }
        }
    }

    private func update(url raw: String, mutate: @escaping (inout Record) -> Void) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var record = self.records[url] ?? Record()
            mutate(&record)
            record.lastUpdated = Date()
            self.records[url] = record
            self.prune()
            self.persist()
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        records = records.filter { $0.value.lastUpdated >= cutoff }
        if records.count > 500 {
            let keep = records.sorted { $0.value.lastUpdated > $1.value.lastUpdated }.prefix(500)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}
