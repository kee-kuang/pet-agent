import Foundation

/// 把一只 RemotePet 下载安装进 `<parentDir>/<slug>/`(pet.json + spritesheet)。
/// 安全:① 资产 URL 过 `TrustedAssetHosts` allowlist(防 SSRF)② Referer 防盗链
/// ③ 429/5xx 退避重试 ④ 非 2xx 绝不落盘(防把错误页当 sheet 写)⑤ slug + sheet 文件名
/// 净化(防路径遍历写出 dir)。蓝本参考上游开源项目 agentpet (https://github.com/ntd4996/agentpet) 的 PetInstaller。
public struct PetPackInstaller: Sendable {
    let fetcher: AssetFetcher
    public init(fetcher: AssetFetcher = URLSessionAssetFetcher()) { self.fetcher = fetcher }

    private struct PackMeta: Decodable { let spritesheetPath: String? }

    /// 安装并返回包目录 URL(`<parentDir>/<slug>/`)。
    @discardableResult
    public func install(_ pet: RemotePet, into parentDir: URL) async throws -> URL {
        guard let petJsonURL = URL(string: pet.petJsonUrl),
              let sheetURL = URL(string: pet.spritesheetUrl) else { throw PetCatalogError.badURL }
        guard TrustedAssetHosts.isTrusted(petJsonURL) else {
            throw PetCatalogError.untrustedHost(petJsonURL.host ?? pet.petJsonUrl)
        }
        guard TrustedAssetHosts.isTrusted(sheetURL) else {
            throw PetCatalogError.untrustedHost(sheetURL.host ?? pet.spritesheetUrl)
        }

        let petJSON = try await fetchWithBackoff(petJsonURL)
        let meta = try? JSONDecoder().decode(PackMeta.self, from: petJSON)
        let sheetName = Self.safeSheetName(meta?.spritesheetPath, fallbackURL: sheetURL)
        let sheetData = try await fetchWithBackoff(sheetURL)

        let dir = parentDir.appendingPathComponent(Self.sanitizeSlug(pet.slug), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try petJSON.write(to: dir.appendingPathComponent("pet.json"))
        try sheetData.write(to: dir.appendingPathComponent(sheetName))
        return dir
    }

    /// 资产抓取 + 429/5xx 退避(最多 3 次)。非 2xx 抛 badStatus,不返回错误页字节。
    private func fetchWithBackoff(_ url: URL) async throws -> Data {
        var last = 0
        for attempt in 0..<3 {
            let (data, code) = try await fetcher.fetch(url, referer: PetCatalogClient.assetReferer)
            if (200..<300).contains(code) { return data }
            last = code
            guard code == 429 || code >= 500, attempt < 2 else { break }
            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 900_000_000)
        }
        throw PetCatalogError.badStatus(last)
    }

    // MARK: - 净化(路径遍历防护)

    /// spritesheet 文件名:取 pet.json spritesheetPath 的**末段**(剥目录),仅允许
    /// `.png`/`.webp` 简单名;非法则回退 `spritesheet.<URL 扩展名|png>`。绝不含 `/`/`..`。
    static func safeSheetName(_ raw: String?, fallbackURL: URL) -> String {
        if let raw {
            let base = (raw as NSString).lastPathComponent
            let ext = (base as NSString).pathExtension.lowercased()
            if !base.isEmpty, base != "..", !base.contains("/"), ext == "png" || ext == "webp" {
                return base
            }
        }
        let urlExt = fallbackURL.pathExtension.lowercased()
        return "spritesheet." + (urlExt == "webp" || urlExt == "png" ? urlExt : "png")
    }

    /// slug 净化(ASCII、无 `/`/`..`)→ 不会越出 parentDir。petdex slug 通常已干净,防御性再过。
    static func sanitizeSlug(_ raw: String) -> String {
        var out = ""
        var lastDash = false
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "codex-pet" : trimmed
    }
}
