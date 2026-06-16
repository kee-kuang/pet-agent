import Testing
import AppKit
import Foundation
@testable import Rendering

@Suite("Live2DModelPackLoader 发现 + 显示名")
@MainActor
struct Live2DModelPackLoaderTests {

    /// 临时根目录,deinit 清理。
    private let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live2d-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 造一个 `<root>/<slug>/<model3名>` 模型包(空 moc3 + model3.json 占位)。
    @discardableResult
    private func makePack(slug: String, model3: String, nested: Bool = false) throws -> URL {
        var dir = root.appendingPathComponent(slug, isDirectory: true)
        if nested { dir = dir.appendingPathComponent("runtime", isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(model3))
        try Data().write(to: dir.appendingPathComponent("model.moc3"))
        return dir
    }

    @Test("空 / 不存在目录 → 空数组")
    func emptyRoot() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        #expect(Live2DModelPackLoader.collect(liveRoot: missing).isEmpty)
        #expect(Live2DModelPackLoader.collect(liveRoot: root).isEmpty)
    }

    @Test("含 model3.json 的包 → 一条 .live2d 条目,id 带前缀,makeRenderer 回退 nil")
    func discoversPack() throws {
        try makePack(slug: "hiyori", model3: "Hiyori.model3.json")
        let entries = Live2DModelPackLoader.collect(liveRoot: root)
        #expect(entries.count == 1)
        let e = try #require(entries.first)
        #expect(e.identity.id == "live2d:hiyori")
        #expect(e.identity.category == .live2d)
        #expect(e.identity.displayName == "Hiyori")   // 取 model3 stem
        #expect(e.thumbnail == nil)
        #expect(e.makeRenderer() == nil)              // 渲染器未接入时占位
    }

    @Test("无 model3.json 的目录 → 跳过")
    func skipsNonModelDir() throws {
        let dir = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        #expect(Live2DModelPackLoader.collect(liveRoot: root).isEmpty)
    }

    @Test("model3 在 runtime/ 子目录(深度 2)也能发现")
    func discoversNested() throws {
        try makePack(slug: "mark", model3: "Mark.model3.json", nested: true)
        let entries = Live2DModelPackLoader.collect(liveRoot: root)
        #expect(entries.count == 1)
        #expect(entries.first?.identity.displayName == "Mark")
    }

    @Test("多包按 slug 字典序稳定输出")
    func stableOrder() throws {
        try makePack(slug: "zebra", model3: "Z.model3.json")
        try makePack(slug: "alpha", model3: "A.model3.json")
        let ids = Live2DModelPackLoader.collect(liveRoot: root).map(\.identity.id)
        #expect(ids == ["live2d:alpha", "live2d:zebra"])
    }

    @Test("非标准 model3 命名 → 显示名回退去扩展名")
    func displayNameFallback() {
        let url = URL(fileURLWithPath: "/tmp/weird.json")
        #expect(Live2DModelPackLoader.displayName(model3: url, slug: "myslug") == "weird")
    }
}
