import Testing
import AppKit
@testable import Rendering

@Suite("CodexSpritePackLoader 元数据 + 缩略图 + 分类")
@MainActor
struct CodexSpritePackLoaderTests {

    /// 写一个 8×9 spritesheet PNG(首帧左上角纯色)到临时目录,返回 URL。
    private func writeSheet(to url: URL, firstFrameRed: UInt8 = 200) throws {
        let w = 8 * 12, h = 9 * 13   // 96×117,≥8×9
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // 首帧(row0/col0)= CGImage 左上角(顶行)。CGContext y-up → 顶 = 高 y。
        ctx.setFillColor(red: CGFloat(firstFrameRed) / 255, green: 0.2, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: h - 13, width: 12, height: 13))   // 左上角一格
        let img = try #require(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: img)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    @Test("readMeta 读 displayName + source(shimeji 标记)")
    func readsMeta() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"displayName":"经典 Shimeji","source":"shimeji"}"#
        try json.write(to: dir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        let meta = CodexSpritePackLoader.readMeta(in: dir)
        #expect(meta.displayName == "经典 Shimeji")
        #expect(meta.source == "shimeji")
        #expect(meta.packId == nil)    // 无包归属字段 → nil(向后兼容)
        #expect(meta.packName == nil)
    }

    @Test("readMeta 读 packId/packName(多角色包同包归属)")
    func readsMetaPack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"displayName":"Blue","source":"shimeji","packId":"alan-pack","packName":"Alan's Stickfigures"}"#
        try json.write(to: dir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        let meta = CodexSpritePackLoader.readMeta(in: dir)
        #expect(meta.packId == "alan-pack")
        #expect(meta.packName == "Alan's Stickfigures")
    }

    @Test("readMeta 缺 pet.json → (nil, nil)")
    func readsMetaMissing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = CodexSpritePackLoader.readMeta(in: dir)
        #expect(meta.displayName == nil)
        #expect(meta.source == nil)
    }

    @Test("firstFrameThumbnail 从 8×9 sheet 裁出 idle 首帧缩略图")
    func cropsThumbnail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-\(UUID()).png")
        try writeSheet(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let thumb = try #require(CodexSpritePackLoader.firstFrameThumbnail(sheetURL: url, maxDim: 44))
        #expect(thumb.size.width > 0 && thumb.size.height > 0)
        #expect(max(thumb.size.width, thumb.size.height) <= 44.5)
    }

    @Test("firstFrameThumbnail 非图片 / 尺寸不足 → nil")
    func thumbnailNilOnBadInput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).png")
        try Data("not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CodexSpritePackLoader.firstFrameThumbnail(sheetURL: url) == nil)
    }

    @Test("PetCategory 分组排序 + 占位图标稳定")
    func categoryMetadata() {
        #expect(PetCategory.allCases.map(\.sortOrder) == [0, 1, 2, 3])
        #expect(PetCategory.builtin.displayName == "内置")
        #expect(PetCategory.shimejiImport.displayName == "Shimeji 导入")
        #expect(!PetCategory.codexCommunity.fallbackSymbol.isEmpty)
    }

    @Test("PetIdentity category 默认 .builtin,可自定义")
    func identityCategory() {
        let a = PetIdentity(id: "orb", displayName: "弹力球", recommendedSize: .zero)
        #expect(a.category == .builtin)
        let b = PetIdentity(id: "codex:x", displayName: "x", recommendedSize: .zero, category: .shimejiImport)
        #expect(b.category == .shimejiImport)
    }

    // MARK: - PetLibrary 目录架构(collect 多目录扫描)

    /// 在 base/<slug>/ 造一个含 spritesheet.png(+ 可选 pet.json source)的包。
    private func makePack(_ base: URL, slug: String, source: String? = nil) throws {
        let dir = base.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSheet(to: dir.appendingPathComponent("spritesheet.png"))
        if let source {
            try #"{"displayName":"\#(slug)","source":"\#(source)"}"#
                .write(to: dir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        }
    }

    @Test("collect:自有 codex/shimeji 子目录类别按位置 + 兼容目录类别按 source")
    func collectCategorizesByLocation() throws {
        let our = FileManager.default.temporaryDirectory.appendingPathComponent("our-\(UUID())", isDirectory: true)
        let compat = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: our); try? FileManager.default.removeItem(at: compat) }
        try makePack(our.appendingPathComponent("codex"), slug: "ferris")       // 自有 codex → .codexCommunity
        try makePack(our.appendingPathComponent("shimeji"), slug: "neko")       // 自有 shimeji → .shimejiImport
        try makePack(compat, slug: "doraemon")                                  // 兼容无 source → .codexCommunity
        try makePack(compat, slug: "kuro", source: "shimeji")                   // 兼容 source=shimeji → .shimejiImport

        let entries = CodexSpritePackLoader.collect(ourRoot: our, compatRoot: compat, loadCompat: true)
        func cat(_ id: String) -> PetCategory? { entries.first { $0.identity.id == "codex:" + id }?.identity.category }
        #expect(cat("ferris") == .codexCommunity)
        #expect(cat("neko") == .shimejiImport)
        #expect(cat("doraemon") == .codexCommunity)
        #expect(cat("kuro") == .shimejiImport)
        #expect(entries.count == 4)
    }

    @Test("collect:关兼容开关 → 兼容目录不加载")
    func collectRespectsCompatToggle() throws {
        let our = FileManager.default.temporaryDirectory.appendingPathComponent("our-\(UUID())", isDirectory: true)
        let compat = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: our); try? FileManager.default.removeItem(at: compat) }
        try makePack(our.appendingPathComponent("codex"), slug: "ferris")
        try makePack(compat, slug: "doraemon")

        let off = CodexSpritePackLoader.collect(ourRoot: our, compatRoot: compat, loadCompat: false)
        #expect(off.map { $0.identity.id } == ["codex:ferris"])   // 兼容 doraemon 不加载
        let on = CodexSpritePackLoader.collect(ourRoot: our, compatRoot: compat, loadCompat: true)
        #expect(on.count == 2)
    }

    @Test("collect:同 slug 自有优先,兼容里同名跳过")
    func collectDedupesPreferringOwn() throws {
        let our = FileManager.default.temporaryDirectory.appendingPathComponent("our-\(UUID())", isDirectory: true)
        let compat = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: our); try? FileManager.default.removeItem(at: compat) }
        try makePack(our.appendingPathComponent("shimeji"), slug: "dup")        // 自有 shimeji
        try makePack(compat, slug: "dup")                                       // 兼容同名(无 source)

        let entries = CodexSpritePackLoader.collect(ourRoot: our, compatRoot: compat, loadCompat: true)
        #expect(entries.filter { $0.identity.id == "codex:dup" }.count == 1)    // 去重
        #expect(entries.first { $0.identity.id == "codex:dup" }?.identity.category == .shimejiImport) // 自有(shimeji)赢
    }

    @Test("PetLibrary:类型子目录路径 + 类别映射")
    func petLibraryPaths() {
        #expect(PetLibrary.installDir(for: .codex).lastPathComponent == "codex")
        #expect(PetLibrary.installDir(for: .shimeji).lastPathComponent == "shimeji")
        #expect(PetLibrary.Kind.shimeji.category == .shimejiImport)
        #expect(PetLibrary.Kind.codex.category == .codexCommunity)
        #expect(PetLibrary.root.lastPathComponent == "pets")
        #expect(PetLibrary.root.deletingLastPathComponent().lastPathComponent == ".petagent")
    }
}
