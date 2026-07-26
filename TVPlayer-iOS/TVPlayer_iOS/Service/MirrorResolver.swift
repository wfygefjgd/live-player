import Foundation

/// 国内可达镜像扩展：把 GitHub 系地址展开为一组候选 URL（调用方并发竞速，任一可达即成功）
/// - `*.github.io` Pages：多数地区可直连，原址优先，再补 jsDelivr / ghproxy / raw
/// - `raw.githubusercontent.com`：大陆基本被墙，镜像优先、raw 殿后
/// - 其他地址：原样返回，不做展开
enum MirrorResolver {
    /// jsDelivr 公共 CDN（大陆一般可直连；@分支 缓存约 12 小时）
    private static let jsDelivrHosts = [
        "https://fastly.jsdelivr.net/gh/",
        "https://cdn.jsdelivr.net/gh/",
    ]
    /// ghproxy 类网关（时有失效，仅作兜底）
    private static let ghProxyPrefixes = [
        "https://gh-proxy.com/",
    ]

    /// 返回去重后的候选列表；无法识别的地址返回 [原址]
    static func candidates(for urlString: String) -> [String] {
        let url = urlString.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return [] }
        var list: [String] = []

        if let gh = parseRawGitHub(url) {
            list.append(contentsOf: jsDelivrHosts.map {
                "\($0)\(gh.user)/\(gh.repo)@\(gh.branch)/\(gh.path)"
            })
            list.append(contentsOf: ghProxyPrefixes.map { "\($0)\(url)" })
            list.append(url)
        } else if let pages = parseGitHubPages(url) {
            list.append(url)
            // Pages 通常发布自默认分支，按 main 推断补镜像（猜错只是多一个失败候选）
            list.append(contentsOf: jsDelivrHosts.map {
                "\($0)\(pages.user)/\(pages.repo)@main/\(pages.path)"
            })
            let raw = "https://raw.githubusercontent.com/\(pages.user)/\(pages.repo)/main/\(pages.path)"
            list.append(contentsOf: ghProxyPrefixes.map { "\($0)\(raw)" })
            list.append(raw)
        } else {
            list.append(url)
        }

        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    // raw.githubusercontent.com/<user>/<repo>/<branch>/<path>
    private static func parseRawGitHub(_ url: String)
        -> (user: String, repo: String, branch: String, path: String)? {
        guard let u = URL(string: url), u.host == "raw.githubusercontent.com" else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        return (parts[0], parts[1], parts[2], parts.dropFirst(3).joined(separator: "/"))
    }

    // <user>.github.io/<repo>/<path>
    private static func parseGitHubPages(_ url: String)
        -> (user: String, repo: String, path: String)? {
        guard let u = URL(string: url), let host = u.host, host.hasSuffix(".github.io") else { return nil }
        let user = String(host.dropLast(".github.io".count))
        guard !user.isEmpty, !user.contains(".") else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (user, parts[0], parts.dropFirst().joined(separator: "/"))
    }
}
