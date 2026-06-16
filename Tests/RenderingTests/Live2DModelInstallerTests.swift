import Testing
import Foundation
@testable import Rendering

@Suite("Live2DModelInstaller 安装 + 路由探测 + slug")
struct Live2DModelInstallerTests {

    private let tmp: URL
    init() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("live2d-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    /// 造一个 Live2D 包目录(model3.json + moc3 + 一张贴图),返回包根。
    @discardableResult
    private func makePack(named name: String, model3: String = "Model.model3.json") throws -> URL {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(model3))
        try Data().write(to: dir.appendingPathComponent("model.moc3"))
        try Data().write(to: dir.appendingPathComponent("texture_00.png"))
        return dir
    }

    @Test("从目录安装 → 整包拷进 <dest>/<slug>/,model3 + 贴图都在")
    func installFromFolder() throws {
        let pack = try makePack(named: "src", model3: "Hiyori.model3.json")
        let dest = tmp.appendingPathComponent("dest", isDirectory: true)
        let out = try Live2DModelInstaller.install(from: pack, into: dest)
        #expect(out.lastPathComponent == "hiyori")   // slug = model3 stem 净化
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: out.appendingPathComponent("Hiyori.model3.json").path))
        #expect(fm.fileExists(atPath: out.appendingPathComponent("model.moc3").path))
        #expect(fm.fileExists(atPath: out.appendingPathComponent("texture_00.png").path))
    }

    @Test("无 model3.json 的目录 → noModelFound")
    func noModel() throws {
        let dir = tmp.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        #expect(throws: Live2DModelInstaller.InstallError.noModelFound) {
            try Live2DModelInstaller.install(from: dir, into: tmp.appendingPathComponent("d"))
        }
    }

    @Test("覆盖重装:同 slug 第二次安装替换内容")
    func reinstallOverwrites() throws {
        let pack = try makePack(named: "src1", model3: "Cat.model3.json")
        let dest = tmp.appendingPathComponent("dest2", isDirectory: true)
        let out1 = try Live2DModelInstaller.install(from: pack, into: dest)
        try Data("v2".utf8).write(to: out1.appendingPathComponent("marker.txt"))
        // 第二次:同名 model3 → 同 slug → 覆盖(marker.txt 应被清掉)
        let pack2 = try makePack(named: "src2", model3: "Cat.model3.json")
        let out2 = try Live2DModelInstaller.install(from: pack2, into: dest)
        #expect(out1.path == out2.path)
        #expect(!FileManager.default.fileExists(atPath: out2.appendingPathComponent("marker.txt").path))
    }

    @Test("containsModel3:含 model3 的目录 true,不含 false")
    func detectFolder() throws {
        let pack = try makePack(named: "p")
        #expect(Live2DModelInstaller.containsModel3(at: pack))
        let plain = tmp.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(!Live2DModelInstaller.containsModel3(at: plain))
    }

    @Test("从 .zip 安装 + containsModel3 探测 zip")
    func installFromZip() throws {
        let pack = try makePack(named: "zsrc", model3: "Zip.model3.json")
        let zip = tmp.appendingPathComponent("model.zip")
        // ditto -c -k 打成 PKZip(pack 内容在 zip 根下)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", pack.path, zip.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)

        #expect(Live2DModelInstaller.containsModel3(at: zip))
        let dest = tmp.appendingPathComponent("zdest", isDirectory: true)
        let out = try Live2DModelInstaller.install(from: zip, into: dest)
        #expect(out.lastPathComponent == "zip")
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Zip.model3.json").path))
    }

    @Test("slug 净化:非 ASCII / 路径符折连字符,空回退默认")
    func sanitize() {
        #expect(Live2DModelInstaller.sanitizeSlug("Hiyori Pro!") == "hiyori-pro")
        #expect(Live2DModelInstaller.sanitizeSlug("../../etc") == "etc")
        #expect(Live2DModelInstaller.sanitizeSlug("日本語") == "live2d-model")
    }
}
