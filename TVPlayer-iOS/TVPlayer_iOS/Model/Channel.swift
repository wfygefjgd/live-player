import Foundation

class Channel: Codable, Identifiable, Equatable {
    let id = UUID()
    let name: String
    let group: String
    let key: String
    private(set) var urls: [String]

    init(name: String, group: String = "未分组", key: String? = nil, urls: [String]? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        self.name = trimmedName.isEmpty ? "未知" : trimmedName
        let trimmedGroup = group.trimmingCharacters(in: .whitespaces)
        self.group = trimmedGroup.isEmpty ? "未分组" : trimmedGroup
        self.key = (key?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? M3UParserService.normalizeName(trimmedName)
        self.urls = []
        if let urls = urls {
            for u in urls {
                addUrl(u)
            }
        }
    }

    func addUrl(_ url: String) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !urls.contains(clean) else { return }
        urls.append(clean)
    }

    var sourceCount: Int { urls.count }

    var primaryUrl: String { urls.first ?? "" }

    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.key == rhs.key
    }
}
