import Testing
import CoreGraphics
import Foundation
@testable import ShimejiImport

@Suite("ShimejiPackConverter")
struct ShimejiPackConverterTests {

    private func solidFrame(r: UInt8, w: Int = 96, h: Int = 96) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(r) / 255, green: 0.4, blue: 0.6, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// 造一个临时 Shimeji 包：`<tmp>/img/<char>/shime1..count.png`。返回包根。
    private func makePack(char: String, frameCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shimeji-test-\(UUID().uuidString)", isDirectory: true)
        let frameDir = root.appendingPathComponent("img/\(char)", isDirectory: true)
        try FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)
        for n in 1...frameCount {
            let url = frameDir.appendingPathComponent("shime\(n).png")
            #expect(ShimejiPackConverter.writePNG(solidFrame(r: UInt8(n)), to: url))
        }
        return root
    }

    /// 把 packed sheet 渲进 RGBA 缓冲,按「图顶左原点」取像素(与 renderer cropping 同系)。
    private func sampler(for sheet: CGImage) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let w = sheet.width, h = sheet.height, bpr = w * 4
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(sheet, in: CGRect(x: 0, y: 0, width: w, height: h))
        return { [ctx] x, y in
            let p = ctx.data!.bindMemory(to: UInt8.self, capacity: bpr * h)
            let i = y * bpr + x * 4
            return (p[i], p[i + 1], p[i + 2], p[i + 3])
        }
    }

    /// 造**自定义命名**包(模拟火柴人):帧名 stand/walkA-C/climbA + 1 张 shime1(基,但 <4 → 走
    /// actions.xml 路径)+ conf/actions.xml 把它们绑到 Stand/Walk/ClimbWall。返回包根。
    private func makeCustomPack(char: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shimeji-custom-\(UUID().uuidString)", isDirectory: true)
        let frameDir = root.appendingPathComponent("img/\(char)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: frameDir.appendingPathComponent("conf"), withIntermediateDirectories: true)
        for (name, r) in [("shime1", 1), ("stand", 10), ("walkA", 20), ("walkB", 30), ("walkC", 40), ("climbA", 50)] {
            #expect(ShimejiPackConverter.writePNG(solidFrame(r: UInt8(r)),
                                                  to: frameDir.appendingPathComponent("\(name).png")))
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <Mascot xmlns="http://www.group-finity.com/Mascot">
          <ActionList>
            <Action Name="Stand" Type="Stay"><Animation><Pose Image="/stand.png" Duration="250"/></Animation></Action>
            <Action Name="Walk" Type="Move"><Animation>
              <Pose Image="/walkA.png" Velocity="-2,0" Duration="6"/>
              <Pose Image="/walkB.png" Velocity="-2,0" Duration="6"/>
              <Pose Image="/walkC.png" Velocity="-2,0" Duration="6"/>
            </Animation></Action>
            <Action Name="ClimbWall" Type="Move" BorderType="Wall"><Animation><Pose Image="/climbA.png" Duration="6"/></Animation></Action>
          </ActionList>
        </Mascot>
        """
        try Data(xml.utf8).write(to: frameDir.appendingPathComponent("conf/actions.xml"))
        return root
    }

    @Test("actions.xml 路径:自定义命名帧 → 正确装入对应行(walk 行得 3 个不同帧 = 能动,根治静止)")
    func convertsViaActionsXML() throws {
        let pack = try makeCustomPack(char: "Stick")
        defer { try? FileManager.default.removeItem(at: pack) }
        let outParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("axout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outParent) }

        let outDirs = try ShimejiPackConverter.convert(packDir: pack, outputParentDir: outParent)
        let outDir = try #require(outDirs.first)
        let sheet = try #require(ShimejiPackConverter.loadCGImage(outDir.appendingPathComponent("spritesheet.png")))
        let px = sampler(for: sheet)
        let fw = ShimejiPetdexLayout.frameWidth, fh = ShimejiPetdexLayout.frameHeight
        func centerR(_ row: Int, _ col: Int) -> UInt8 { px(col * fw + fw / 2, row * fh + fh / 2).r }

        #expect(centerR(0, 0) == 10)                          // row0 idle ← Stand(stand.png)
        // row1 runningRight ← Walk[walkA,B,C] = 20/30/40:三个不同帧 → 真能动(非全 shime1 静止)
        #expect(centerR(1, 0) == 20)
        #expect(centerR(1, 1) == 30)
        #expect(centerR(1, 2) == 40)
        #expect(centerR(2, 0) == 20)                          // row2 runningLeft ← Walk 镜像(同源帧)
        #expect(sheet.height == 10 * fh)                      // ClimbWall → 含 row9 → 10 行
        #expect(centerR(9, 0) == 50)                          // row9 climbing ← climbA
        let obj = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: outDir.appendingPathComponent("pet.json"))) as? [String: Any])
        #expect(obj["rows"] as? Int == 10)
    }

    @Test("帧号覆盖足够(≥4 shimeN)→ 仍走帧号路径(标准包不受 actions 路径影响)")
    func richNumberedStillUsesNumberedPath() throws {
        // 12 帧标准包 + 一个会「误导」的 actions.xml:若走了 actions 路径,row1 会变 stand 色;
        // 走帧号路径则 row1 = shime1,2,3。验证阈值正确把标准包留在帧号路径。
        let pack = try makePack(char: "Std", frameCount: 12)
        defer { try? FileManager.default.removeItem(at: pack) }
        let frameDir = pack.appendingPathComponent("img/Std/conf", isDirectory: true)
        try FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)
        try Data("""
        <Mascot xmlns="http://www.group-finity.com/Mascot"><ActionList>
        <Action Name="Walk" Type="Move"><Animation><Pose Image="/shime9.png" Duration="6"/></Animation></Action>
        </ActionList></Mascot>
        """.utf8).write(to: frameDir.appendingPathComponent("actions.xml"))
        let outParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("stdout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outParent) }

        let outDir = try #require(try ShimejiPackConverter.convert(packDir: pack, outputParentDir: outParent).first)
        let sheet = try #require(ShimejiPackConverter.loadCGImage(outDir.appendingPathComponent("spritesheet.png")))
        let px = sampler(for: sheet)
        let fw = ShimejiPetdexLayout.frameWidth, fh = ShimejiPetdexLayout.frameHeight
        // 帧号路径:row1 runningRight ← shime[1,2,3]。若误走 actions 路径会是 shime9。
        #expect(px(0 * fw + fw / 2, 1 * fh + fh / 2).r == 1)
        #expect(px(1 * fw + fw / 2, 1 * fh + fh / 2).r == 2)
    }

    @Test("端到端：扫嵌套 img/<角色> → 写 spritesheet.png(含 climb 行=10 行)+ pet.json")
    func convertsNestedPack() throws {
        let pack = try makePack(char: "Neko", frameCount: 30)   // 含 shime12-14 → climb 行
        defer { try? FileManager.default.removeItem(at: pack) }
        let outParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outParent) }

        let outDirs = try ShimejiPackConverter.convert(packDir: pack, outputParentDir: outParent)
        #expect(outDirs.count == 1)   // 单角色包 → 1 个输出
        let outDir = try #require(outDirs.first)
        // slug 由 char 名净化 → "neko"
        #expect(outDir.lastPathComponent == "neko")
        let sheetURL = outDir.appendingPathComponent("spritesheet.png")
        let petURL = outDir.appendingPathComponent("pet.json")
        #expect(FileManager.default.fileExists(atPath: sheetURL.path))
        #expect(FileManager.default.fileExists(atPath: petURL.path))
        // 输出 spritesheet:8 列 × 10 行(含 shime12-14 攀爬专用行)。
        let sheet = try #require(ShimejiPackConverter.loadCGImage(sheetURL))
        #expect(sheet.width == ShimejiPetdexLayout.sheetWidth)
        #expect(sheet.height == 10 * ShimejiPetdexLayout.frameHeight)
        // pet.json 可解析 + source=shimeji + rows 报真实 10。
        let obj = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: petURL)) as? [String: Any])
        #expect(obj["source"] as? String == "shimeji")
        #expect(obj["rows"] as? Int == 10)
    }

    @Test("帧目录发现：含 shimeN.png 的角色目录被收集(单角色 → 1 个)")
    func findsFrameDirectory() throws {
        let pack = try makePack(char: "Cat", frameCount: 10)
        defer { try? FileManager.default.removeItem(at: pack) }
        let found = ShimejiPackConverter.findAllFrameDirectories(pack)
        #expect(found.count == 1)
        #expect(found.first?.lastPathComponent == "Cat")
        #expect(ShimejiPackConverter.loadFrames(in: found[0]).count == 10)
    }

    /// 造多角色包:`<tmp>/img/<char>/shime1..N.png`(N 取 chars 各自帧数)。返回包根。
    private func makeMultiCharPack(_ chars: [(name: String, frames: Int)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shimeji-multi-\(UUID().uuidString)", isDirectory: true)
        for (name, count) in chars {
            let dir = root.appendingPathComponent("img/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in 1...count {
                #expect(ShimejiPackConverter.writePNG(solidFrame(r: UInt8(n)),
                                                      to: dir.appendingPathComponent("shime\(n).png")))
            }
        }
        return root
    }

    @Test("多角色包 → 每角色各转一个独立包(忠于 Shimeji-ee 全加载语义,不丢角色)")
    func convertsAllCharacters() throws {
        // 默认 Shimeji-ee 发行版结构:Shimeji(白) + KuroShimeji(黑),各完整帧。
        let pack = try makeMultiCharPack([("Shimeji", 14), ("KuroShimeji", 14)])
        defer { try? FileManager.default.removeItem(at: pack) }
        let outParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outParent) }

        let outDirs = try ShimejiPackConverter.convert(packDir: pack, outputParentDir: outParent)
        #expect(outDirs.count == 2)                                  // 两角色各一包,不丢
        let slugs = Set(outDirs.map(\.lastPathComponent))
        #expect(slugs == ["shimeji", "kuroshimeji"])                 // slug 由各自目录名推导
        for dir in outDirs {                                         // 每包都真有 sheet + pet.json
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("spritesheet.png").path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pet.json").path))
        }
        #expect(outDirs.map(\.lastPathComponent) == ["kuroshimeji", "shimeji"])  // 按 slug 排序确定性
    }

    @Test("多角色 slug 冲突(全非 ASCII 名都兜底 shimeji)→ 加稳定 hash 后缀去冲突,不互覆")
    func multiCharSlugCollisionGetsSuffix() throws {
        // 两个日文角色名 → sanitizeSlug 都成 "shimeji" → 必须加后缀区分,否则第二个覆盖第一个。
        let pack = try makeMultiCharPack([("ねこ", 12), ("いぬ", 12)])
        defer { try? FileManager.default.removeItem(at: pack) }
        let outParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("collout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outParent) }

        let outDirs = try ShimejiPackConverter.convert(packDir: pack, outputParentDir: outParent)
        #expect(outDirs.count == 2)                                  // 两包都产出,没互覆
        let slugs = Set(outDirs.map(\.lastPathComponent))
        #expect(slugs.count == 2)                                    // slug 互异
        for s in slugs { #expect(s.hasPrefix("shimeji-")) }          // base "shimeji" + hash 后缀
    }

    @Test("stableHash4 确定性:同串恒等,4 位 hex")
    func stableHash4Deterministic() {
        let a = ShimejiPackConverter.stableHash4("ねこ")
        #expect(a == ShimejiPackConverter.stableHash4("ねこ"))       // 同串每次相同(可覆盖更新)
        #expect(a != ShimejiPackConverter.stableHash4("いぬ"))       // 异串大概率不同
        #expect(a.count == 4)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test("无 shimeN.png → 抛 noFramesFound")
    func noFramesThrows() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: ShimejiPackConverter.ConvertError.noFramesFound) {
            _ = try ShimejiPackConverter.convert(packDir: empty,
                                                 outputParentDir: empty.appendingPathComponent("out"))
        }
    }

    @Test("convertZipOrDir: .zip 解压后转换 → 9 行输出(无 climb 源帧,容嵌套)")
    func convertsFromZip() throws {
        let pack = try makePack(char: "Zipped", frameCount: 11)   // 无 shime12-14 → 9 行;<tmp>/img/Zipped/shimeN.png
        defer { try? FileManager.default.removeItem(at: pack) }
        // 打成 .zip(ditto -c -k 归档 pack 内容 → zip 根含 img/Zipped/…)。
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID()).zip")
        let z = Process()
        z.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        z.arguments = ["-c", "-k", pack.path, zipURL.path]
        try z.run(); z.waitUntilExit()
        try #require(z.terminationStatus == 0)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let outParent = FileManager.default.temporaryDirectory.appendingPathComponent("zout-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outParent) }
        let outDirs = try ShimejiPackConverter.convertZipOrDir(at: zipURL, outputParentDir: outParent)
        let outDir = try #require(outDirs.first)
        let sheet = try #require(ShimejiPackConverter.loadCGImage(outDir.appendingPathComponent("spritesheet.png")))
        #expect(sheet.width == ShimejiPetdexLayout.sheetWidth)
        #expect(sheet.height == ShimejiPetdexLayout.sheetHeight)
    }

    /// 用 python3 zipfile 造 zip(可写任意条目名,含 ../ 穿越;CLI `zip` 会净化故不用)。
    private func makeZip(entries: [String], at zipURL: URL) throws {
        let argsScript = "import zipfile,sys\n"
            + "z=zipfile.ZipFile(sys.argv[1],'w')\n"
            + "for n in sys.argv[2:]: z.writestr(n, b'x')\n"
            + "z.close()"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", argsScript, zipURL.path] + entries
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)
    }

    @Test("zip-slip 防护:含 ../ 穿越条目的 .zip → 拒绝;干净 zip 放行")
    func rejectsZipSlip() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("slip-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let evil = work.appendingPathComponent("evil.zip")
        try makeZip(entries: ["img/C/shime1.png", "../../escape.txt"], at: evil)
        #expect(throws: ShimejiPackConverter.ConvertError.unzipFailed) {
            try ShimejiPackConverter.validateZipEntries(evil)
        }
        // 绝对路径条目也拒。
        let abs = work.appendingPathComponent("abs.zip")
        try makeZip(entries: ["/etc/passwd"], at: abs)
        #expect(throws: ShimejiPackConverter.ConvertError.unzipFailed) {
            try ShimejiPackConverter.validateZipEntries(abs)
        }
        // 干净 zip 放行。
        let clean = work.appendingPathComponent("clean.zip")
        try makeZip(entries: ["img/C/shime1.png", "img/C/shime2.png"], at: clean)
        #expect(throws: Never.self) { try ShimejiPackConverter.validateZipEntries(clean) }
    }

    @Test("convertZipOrDir: 目录直通(非 .zip 走 convert)")
    func convertZipOrDirPassesDirectory() throws {
        let pack = try makePack(char: "Dir", frameCount: 8)
        defer { try? FileManager.default.removeItem(at: pack) }
        let outParent = FileManager.default.temporaryDirectory.appendingPathComponent("dout-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outParent) }
        let outDirs = try ShimejiPackConverter.convertZipOrDir(at: pack, outputParentDir: outParent)
        let outDir = try #require(outDirs.first)
        #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("spritesheet.png").path))
    }

    @Test("slug 净化：空格/符号折连字符,去首尾,空→shimeji")
    func sanitizesSlug() {
        #expect(ShimejiPackConverter.sanitizeSlug("My Cat!!") == "my-cat")
        #expect(ShimejiPackConverter.sanitizeSlug("  ねこ ") == "shimeji")  // 非 ASCII 折连字符→去首尾→空→兜底
        #expect(ShimejiPackConverter.sanitizeSlug("---") == "shimeji")
    }

    // MARK: - 运行时数据(conf+img)保留

    @Test("convert 随包保留 conf/{actions,behaviors}.xml + img/ 原始帧")
    func preservesRuntimeData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shimeji-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let frameDir = root.appendingPathComponent("img/Cat", isDirectory: true)
        try FileManager.default.createDirectory(
            at: frameDir.appendingPathComponent("conf"), withIntermediateDirectories: true)
        for n in 1...6 {
            #expect(ShimejiPackConverter.writePNG(solidFrame(r: UInt8(n)),
                                                  to: frameDir.appendingPathComponent("shime\(n).png")))
        }
        try Data("<Mascot><ActionList><Action Name=\"Stand\" Type=\"Stay\"/></ActionList></Mascot>".utf8)
            .write(to: frameDir.appendingPathComponent("conf/actions.xml"))
        try Data("<Mascot><BehaviorList><Behavior Name=\"Stand\" Frequency=\"100\"/></BehaviorList></Mascot>".utf8)
            .write(to: frameDir.appendingPathComponent("conf/behaviors.xml"))

        let outParent = FileManager.default.temporaryDirectory.appendingPathComponent("rtout-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outParent) }
        let outDir = try #require(try ShimejiPackConverter.convert(packDir: root, outputParentDir: outParent).first)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("conf/actions.xml").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("conf/behaviors.xml").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("img/shime1.png").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("img/shime6.png").path))
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("spritesheet.png").path))
    }

    @Test("conf 逐级祖先解析:包根 conf 共享给 img/<角色>")
    func resolvesConfFromPackRootAncestor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shimeji-confroot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let frameDir = root.appendingPathComponent("img/Cat", isDirectory: true)
        try FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)
        for n in 1...6 {
            #expect(ShimejiPackConverter.writePNG(solidFrame(r: UInt8(n)),
                                                  to: frameDir.appendingPathComponent("shime\(n).png")))
        }
        let rootConf = root.appendingPathComponent("conf", isDirectory: true)
        try FileManager.default.createDirectory(at: rootConf, withIntermediateDirectories: true)
        try Data("<Mascot><ActionList/></Mascot>".utf8).write(to: rootConf.appendingPathComponent("actions.xml"))

        let resolved = ShimejiPackConverter.resolveConfFile(named: "actions.xml", frameDir: frameDir, packRoot: root)
        #expect(resolved?.path == rootConf.appendingPathComponent("actions.xml").path)
    }
}
