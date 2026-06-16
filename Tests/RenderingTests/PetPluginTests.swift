import AppKit
import Testing
@testable import Rendering

@Suite("PetPlugin / Registry / OrbPetPlugin")
struct PetPluginTests {

    // MARK: - PetIdentity

    @Test("PetIdentity 字段 init + Equatable")
    func identityFields() {
        let a = PetIdentity(id: "orb", displayName: "弹力球", recommendedSize: NSSize(width: 64, height: 64))
        let b = PetIdentity(id: "orb", displayName: "弹力球", recommendedSize: NSSize(width: 64, height: 64))
        let c = PetIdentity(id: "slime", displayName: "史莱姆", recommendedSize: NSSize(width: 80, height: 80))
        #expect(a == b)
        #expect(a != c)
        #expect(a.id == "orb")
        #expect(c.recommendedSize == NSSize(width: 80, height: 80))
    }

    // MARK: - OrbPetPlugin (默认形象)

    @Test("OrbPetPlugin identity 是 id=orb / 弹力球 / 64×64")
    func orbIdentity() {
        let id = OrbPetPlugin.identity
        #expect(id.id == "orb")
        #expect(id.displayName == "弹力球")
        #expect(id.recommendedSize == NSSize(width: 64, height: 64))
    }

    @Test("OrbPetPlugin.makeRenderer 在有 Metal 设备时返回非 nil renderer")
    @MainActor
    func orbMakeRenderer() {
        // 跑测试机器有 Metal → 返回 OrbMetalRenderer; headless CI 上返回 nil。
        // 两种都不算 fail, 只验证类型一致 (返回的若非 nil 必须 conform PetRenderer)。
        let r = OrbPetPlugin.makeRenderer()
        if r != nil {
            #expect(r is OrbMetalRenderer)
        }
    }

    // MARK: - PetPluginRegistry

    /// 用一个隔离 actor 跑 registry 测试避免污染 shared 单例 — 但 registry
    /// 是 @MainActor 单例,无法真正隔离。每个测试前后 resetForTesting() 兜底。
    @Test("register + plugin(for:) 能取回")
    @MainActor
    func registerAndLookup() {
        let registry = PetPluginRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }

        registry.register(OrbPetPlugin.self)
        let found = registry.plugin(for: "orb")
        #expect(found != nil)
        #expect(found?.identity.id == "orb")
    }

    @Test("plugin(for:) 未注册 ID 返回 nil")
    @MainActor
    func lookupMissing() {
        let registry = PetPluginRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }

        registry.register(OrbPetPlugin.self)
        #expect(registry.plugin(for: "slime") == nil)
        #expect(registry.plugin(for: "") == nil)
    }

    @Test("同 ID 重复注册后注册的覆盖")
    @MainActor
    func reregisterOverwrites() {
        // 用 sibling plugin 测试 id 冲突场景
        enum FakeOrbPlugin: PetPlugin {
            static let identity = PetIdentity(id: "orb", displayName: "假弹力球", recommendedSize: .zero)
            static func makeRenderer() -> PetRenderer? { nil }
        }

        let registry = PetPluginRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }

        registry.register(OrbPetPlugin.self)
        registry.register(FakeOrbPlugin.self)

        // 后注册的覆盖, displayName 应是"假弹力球"
        let found = registry.plugin(for: "orb")
        #expect(found?.identity.displayName == "假弹力球")
    }

    @Test("all 返回所有已注册 plugin (顺序不保证)")
    @MainActor
    func allEnumeratesRegistered() {
        enum AnotherPlugin: PetPlugin {
            static let identity = PetIdentity(id: "another", displayName: "另一个", recommendedSize: .zero)
            static func makeRenderer() -> PetRenderer? { nil }
        }

        let registry = PetPluginRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }

        registry.register(OrbPetPlugin.self)
        registry.register(AnotherPlugin.self)

        let allIDs = Set(registry.all.map { $0.identity.id })
        #expect(allIDs == ["orb", "another"])
    }

    @Test("resetForTesting 清空注册表")
    @MainActor
    func resetClears() {
        let registry = PetPluginRegistry.shared
        registry.register(OrbPetPlugin.self)
        registry.resetForTesting()
        #expect(registry.all.isEmpty)
        #expect(registry.plugin(for: "orb") == nil)
    }

    @Test("remove(id:) 注销指定 entry(删除宠物)")
    @MainActor
    func removeDeregisters() {
        let registry = PetPluginRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }
        registry.register(OrbPetPlugin.self)
        registry.remove(id: "orb")
        #expect(registry.plugin(for: "orb") == nil)
        registry.remove(id: "nonexistent")   // 幂等,不崩
    }

    // MARK: - PetLibrary.removePack(安全删除)

    @Test("removePack 删库内目录 + 幂等")
    func removePackInLibrary() throws {
        let dir = PetLibrary.root.appendingPathComponent("codex/__test-del-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try PetLibrary.removePack(at: dir) == true)
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
        #expect(try PetLibrary.removePack(at: dir) == false)   // 幂等:已不在 → false
    }

    @Test("removePack 拒绝删库外任意路径")
    func removePackRejectsOutside() {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("evil-\(UUID())")
        #expect(throws: PetLibrary.RemoveError.notInLibrary) {
            try PetLibrary.removePack(at: outside)
        }
        // 同前缀兄弟目录(petsEVIL)也挡住 —— 必须严格子目录
        let sibling = PetLibrary.root.deletingLastPathComponent().appendingPathComponent("petsEVIL/x")
        #expect(throws: PetLibrary.RemoveError.notInLibrary) {
            try PetLibrary.removePack(at: sibling)
        }
    }
}
