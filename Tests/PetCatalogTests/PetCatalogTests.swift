import Testing
import Foundation
@testable import PetCatalog

@Suite("PetCatalog —— manifest 解码 + allowlist + 安装器(路径遍历 / 退避)")
struct PetCatalogTests {

    /// 可编程 mock fetcher:按 URL 返回 (data, status);可记录调用 + Referer。
    final class MockFetcher: AssetFetcher, @unchecked Sendable {
        var responses: [String: (Data, Int)] = [:]
        var seenReferers: [String: String?] = [:]
        func fetch(_ url: URL, referer: String?) async throws -> (Data, Int) {
            seenReferers[url.absoluteString] = referer
            return responses[url.absoluteString] ?? (Data(), 404)
        }
    }

    private func trustedURL(_ path: String) -> String {
        "https://petdex-assets.raillyhugo.workers.dev/\(path)"
    }

    // MARK: - manifest

    @Test("manifest lenient 解码:跳过坏元素,保留好的")
    func manifestLenientDecode() async throws {
        let json = """
        {"generatedAt":"x","total":2,"pets":[
          {"slug":"ferris","displayName":"Ferris","kind":"creature","submittedBy":"a","spritesheetUrl":"\(trustedURL("f.webp"))","petJsonUrl":"\(trustedURL("f.json"))"},
          {"slug":"broken"},
          {"slug":"boba","displayName":"Boba","kind":"character","submittedBy":"b","spritesheetUrl":"\(trustedURL("b.webp"))","petJsonUrl":"\(trustedURL("b.json"))"}
        ]}
        """
        let mock = MockFetcher()
        mock.responses[PetCatalogClient.manifestURL.absoluteString] = (Data(json.utf8), 200)
        let pets = try await PetCatalogClient(fetcher: mock).fetchManifest()
        #expect(pets.map(\.slug) == ["ferris", "boba"])   // broken(缺必填)被跳过
        #expect(pets[0].author == "a")
    }

    @Test("manifest 非 2xx → badStatus")
    func manifestBadStatus() async {
        let mock = MockFetcher()
        mock.responses[PetCatalogClient.manifestURL.absoluteString] = (Data(), 503)
        await #expect(throws: PetCatalogError.badStatus(503)) {
            try await PetCatalogClient(fetcher: mock).fetchManifest()
        }
    }

    // MARK: - allowlist

    @Test("TrustedAssetHosts:白名单 host + https 才信任")
    func allowlist() {
        #expect(TrustedAssetHosts.isTrusted(URL(string: trustedURL("x.png"))!))
        #expect(!TrustedAssetHosts.isTrusted(URL(string: "https://evil.example.com/x.png")!))   // 非白名单
        #expect(!TrustedAssetHosts.isTrusted(URL(string: "http://petdex-assets.raillyhugo.workers.dev/x.png")!)) // http
    }

    @Test("安装器拒绝非白名单资产 host(防 SSRF)")
    func installRejectsUntrustedHost() async {
        let pet = RemotePet(slug: "x", displayName: "X", kind: nil, submittedBy: nil,
                            spritesheetUrl: "https://evil.example.com/s.webp",
                            petJsonUrl: "https://evil.example.com/p.json")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID())", isDirectory: true)
        await #expect(throws: PetCatalogError.untrustedHost("evil.example.com")) {
            try await PetPackInstaller(fetcher: MockFetcher()).install(pet, into: tmp)
        }
    }

    // MARK: - 安装(写盘)

    @Test("安装:写 pet.json + spritesheet 到 <dir>/<slug>/,Referer 头注入")
    func installWritesFiles() async throws {
        let mock = MockFetcher()
        let petJSON = #"{"slug":"ferris","displayName":"Ferris","spritesheetPath":"spritesheet.webp"}"#
        mock.responses[trustedURL("f.json")] = (Data(petJSON.utf8), 200)
        mock.responses[trustedURL("f.webp")] = (Data("PNGBYTES".utf8), 200)
        let pet = RemotePet(slug: "ferris", displayName: "Ferris", kind: "creature", submittedBy: "a",
                            spritesheetUrl: trustedURL("f.webp"), petJsonUrl: trustedURL("f.json"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dir = try await PetPackInstaller(fetcher: mock).install(pet, into: tmp)
        #expect(dir.lastPathComponent == "ferris")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pet.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("spritesheet.webp").path))
        // 资产请求带 petdex Referer(防盗链)。
        #expect(mock.seenReferers[trustedURL("f.webp")] == PetCatalogClient.assetReferer)
    }

    @Test("路径遍历防护:spritesheetPath 含 ../ → 落到安全文件名,不写出 dir")
    func installPathTraversalGuard() async throws {
        let mock = MockFetcher()
        let petJSON = #"{"spritesheetPath":"../../../../tmp/evil.webp"}"#
        mock.responses[trustedURL("p.json")] = (Data(petJSON.utf8), 200)
        mock.responses[trustedURL("s.webp")] = (Data("X".utf8), 200)
        let pet = RemotePet(slug: "x", displayName: "X", kind: nil, submittedBy: nil,
                            spritesheetUrl: trustedURL("s.webp"), petJsonUrl: trustedURL("p.json"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dir = try await PetPackInstaller(fetcher: mock).install(pet, into: tmp)
        // 末段净化 → "evil.webp" 写在 dir 内,绝不写出。
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil.webp").path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.allSatisfy { !$0.contains("..") && !$0.contains("/") })
    }

    @Test("safeSheetName:非法/缺失回退,合法保留")
    func safeSheetName() {
        let f = URL(string: trustedURL("a.webp"))!
        #expect(PetPackInstaller.safeSheetName("spritesheet.png", fallbackURL: f) == "spritesheet.png")
        #expect(PetPackInstaller.safeSheetName("../../x.webp", fallbackURL: f) == "x.webp")    // 剥目录
        #expect(PetPackInstaller.safeSheetName("evil.sh", fallbackURL: f) == "spritesheet.webp") // 非图片→回退(URL .webp)
        #expect(PetPackInstaller.safeSheetName(nil, fallbackURL: f) == "spritesheet.webp")
    }

    @Test("非 2xx 资产不落盘(throws,不写错误页)")
    func installBadAssetStatusThrows() async {
        let mock = MockFetcher()
        mock.responses[trustedURL("p.json")] = (Data(), 404)
        let pet = RemotePet(slug: "x", displayName: "X", kind: nil, submittedBy: nil,
                            spritesheetUrl: trustedURL("s.webp"), petJsonUrl: trustedURL("p.json"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID())", isDirectory: true)
        await #expect(throws: PetCatalogError.badStatus(404)) {
            try await PetPackInstaller(fetcher: mock).install(pet, into: tmp)
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("x").path))
    }
}
