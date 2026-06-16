import Foundation

public enum PetCatalogError: Error, Equatable {
    case badStatus(Int)        // 非 2xx(含 429 退避耗尽)
    case decodeFailed          // manifest / pet.json 解析失败
    case untrustedHost(String) // 资产 URL 不在 allowlist
    case badURL                // pet.json / spritesheet URL 非法
}

/// 资产抓取抽象 —— 生产用 URLSession,测试注入 mock(免真网)。返回 (data, httpStatus)。
public protocol AssetFetcher: Sendable {
    func fetch(_ url: URL, referer: String?) async throws -> (Data, Int)
}

public struct URLSessionAssetFetcher: AssetFetcher {
    private let session: URLSession
    public init() {
        // 独立配置:30s 请求超时(弱网下避免单次安装长挂分钟级,URLSession.shared 默认 60s)。
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }
    public func fetch(_ url: URL, referer: String?) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 200)
    }
}

/// petdex 资产 host allowlist(参照上游开源项目 petdex (https://github.com/crafter-station/petdex) 的 install.ts TRUSTED_ASSET_HOSTS 重新实现的域名约定,未拷贝源码):
/// 即便 manifest 被改 / 脏数据列了非白名单域名,也拒绝从这些域名下字节(防 SSRF/供应链投毒)。
public enum TrustedAssetHosts {
    public static let hosts: Set<String> = [
        "petdex-assets.raillyhugo.workers.dev",
        "pub-94495283df974cfea5e98d6a9e3fa462.r2.dev",
        "yu2vz9gndp.ufs.sh",
    ]
    /// 仅 https + host 在白名单。
    public static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        return hosts.contains(host)
    }
}

/// 拉 catalog manifest → `[RemotePet]`。
public struct PetCatalogClient: Sendable {
    public static let manifestURL = URL(string: "https://petdex.crafter.run/api/manifest")!
    public static let assetReferer = "https://petdex.crafter.run/"

    let fetcher: AssetFetcher
    public init(fetcher: AssetFetcher = URLSessionAssetFetcher()) { self.fetcher = fetcher }

    /// 一次性拉 manifest(失败抛 badStatus / decodeFailed)。manifest 本体不需 Referer。
    public func fetchManifest() async throws -> [RemotePet] {
        let (data, status) = try await fetcher.fetch(Self.manifestURL, referer: nil)
        guard (200..<300).contains(status) else { throw PetCatalogError.badStatus(status) }
        guard let manifest = try? JSONDecoder().decode(PetManifest.self, from: data) else {
            throw PetCatalogError.decodeFailed
        }
        return manifest.pets
    }
}
