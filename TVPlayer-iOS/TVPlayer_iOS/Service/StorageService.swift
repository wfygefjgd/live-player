import Foundation

class StorageService {
    private let defaults = UserDefaults.standard

    private let kChannels = "channels_cache"
    private let kSourceUrls = "source_urls"
    private let kSelectedSource = "selected_source_url"
    private let kCustomSource = "custom_source_url"
    private let kHiddenLines = "hidden_lines"
    private let kFavorites = "favorites"

    func saveChannels(_ channels: [Channel]) {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        defaults.set(data, forKey: kChannels)
    }

    func loadChannels() -> [Channel] {
        guard let data = defaults.data(forKey: kChannels),
              let channels = try? JSONDecoder().decode([Channel].self, from: data) else {
            return []
        }
        return channels
    }

    func saveSourceUrls(_ urls: [String]) {
        defaults.set(urls, forKey: kSourceUrls)
    }

    func loadSourceUrls() -> [String] {
        defaults.stringArray(forKey: kSourceUrls) ?? []
    }

    func saveSelectedSourceUrl(_ url: String) {
        defaults.set(url, forKey: kSelectedSource)
    }

    func loadSelectedSourceUrl() -> String {
        defaults.string(forKey: kSelectedSource) ?? ""
    }

    func saveCustomSourceUrl(_ url: String) {
        defaults.set(url, forKey: kCustomSource)
    }

    func loadCustomSourceUrl() -> String {
        defaults.string(forKey: kCustomSource) ?? ""
    }

    func loadHiddenLines() -> Set<String> {
        Set(defaults.stringArray(forKey: kHiddenLines) ?? [])
    }

    func hideLine(_ url: String) {
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var lines = loadHiddenLines()
        lines.insert(url.trimmingCharacters(in: .whitespaces))
        defaults.set(Array(lines), forKey: kHiddenLines)
    }

    func isLineHidden(_ url: String) -> Bool {
        loadHiddenLines().contains(url.trimmingCharacters(in: .whitespaces))
    }

    func loadFavorites() -> Set<String> {
        Set(defaults.stringArray(forKey: kFavorites) ?? [])
    }

    func toggleFavorite(_ key: String) -> Bool {
        var fav = loadFavorites()
        if fav.contains(key) {
            fav.remove(key)
            defaults.set(Array(fav), forKey: kFavorites)
            return false
        }
        fav.insert(key)
        defaults.set(Array(fav), forKey: kFavorites)
        return true
    }

    func isFavorite(_ key: String) -> Bool {
        loadFavorites().contains(key)
    }
}
