import Foundation

class NetworkService {
    static let shared = NetworkService()

    private let ua = "Mozilla/5.0 (Linux; Android 10)"
    private let timeout: TimeInterval = 12

    func fetch(url: String) async throws -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return text
    }

    func fetchWithCandidates(urls: [String]) async -> [Channel] {
        for url in urls {
            do {
                let body = try await fetch(url: url)
                if !body.isEmpty {
                    let parsed = M3UParserService.parse(body)
                    if !parsed.isEmpty {
                        return parsed
                    }
                }
            } catch {
                continue
            }
        }
        return []
    }
}
