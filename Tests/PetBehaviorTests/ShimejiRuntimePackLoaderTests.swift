import Foundation
import Testing
import PetBehavior

/// 运行时包加载器:完整包(conf/actions+behaviors + img)→ RuntimePack;缺任一 → nil;诊断校验。
@MainActor
@Suite("ShimejiRuntimePackLoader")
struct ShimejiRuntimePackLoaderTests {
    static let actionsXML = """
    <Mascot xmlns="http://www.group-finity.com/Mascot">
        <ActionList>
            <Action Name="Stand" Type="Stay" BorderType="Floor">
                <Animation><Pose Image="/shime1.png" ImageAnchor="64,128" Velocity="0,0" Duration="10" /></Animation>
            </Action>
            <Action Name="Falling" Type="Embedded" Class="com.group_finity.mascot.action.Fall">
                <Animation><Pose Image="/shime4.png" ImageAnchor="64,128" Velocity="0,0" Duration="4" /></Animation>
            </Action>
            <Action Name="Fall" Type="Sequence"><ActionReference Name="Falling"/></Action>
        </ActionList>
    </Mascot>
    """

    static let behaviorsXML = """
    <Mascot xmlns="http://www.group-finity.com/Mascot">
        <BehaviorList>
            <Behavior Name="Fall" Frequency="0" Hidden="true" />
            <Condition Condition="#{mascot.environment.floor.isOn(mascot.anchor)}">
                <Behavior Name="Stand" Frequency="100" />
            </Condition>
        </BehaviorList>
    </Mascot>
    """

    private func makePack(
        actions: String? = actionsXML,
        behaviors: String? = behaviorsXML,
        withImages: Bool = true
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petpack-\(UUID().uuidString)", isDirectory: true)
        let conf = root.appendingPathComponent("conf")
        try FileManager.default.createDirectory(at: conf, withIntermediateDirectories: true)
        if let actions { try Data(actions.utf8).write(to: conf.appendingPathComponent("actions.xml")) }
        if let behaviors { try Data(behaviors.utf8).write(to: conf.appendingPathComponent("behaviors.xml")) }
        if withImages {
            let img = root.appendingPathComponent("img")
            try FileManager.default.createDirectory(at: img, withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: img.appendingPathComponent("shime1.png"))
        }
        return root
    }

    @Test("完整包 → RuntimePack(图+库+img 目录,引用闭合)")
    func loadsCompletePack() throws {
        let dir = try makePack()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pack = try #require(ShimejiRuntimePackLoader.load(packDir: dir))
        #expect(pack.graph.behaviors["Stand"] != nil)
        #expect(pack.library.action(named: "Fall") != nil)
        #expect(pack.imageDirectory.lastPathComponent == "img")
        #expect(pack.validationIssues.isEmpty)
    }

    @Test("缺 behaviors.xml → nil(退化 spritesheet-only)")
    func missingBehaviorsReturnsNil() throws {
        let dir = try makePack(behaviors: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ShimejiRuntimePackLoader.load(packDir: dir) == nil)
    }

    @Test("缺 img/ → nil")
    func missingImagesReturnsNil() throws {
        let dir = try makePack(withImages: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ShimejiRuntimePackLoader.load(packDir: dir) == nil)
    }

    @Test("行为→动作缺失记入诊断但仍加载")
    func danglingActionRecordedNotBlocking() throws {
        let behaviors = """
        <Mascot xmlns="http://www.group-finity.com/Mascot"><BehaviorList>
            <Behavior Name="Ghost" Frequency="100" Action="NoSuchAction" />
        </BehaviorList></Mascot>
        """
        let dir = try makePack(behaviors: behaviors)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pack = try #require(ShimejiRuntimePackLoader.load(packDir: dir))
        #expect(pack.validationIssues.contains { $0.contains("NoSuchAction") })
    }

    @Test("加载的真实包可直接驱动引擎(端到端:落地)")
    func loadedPackDrivesEngine() throws {
        let dir = try makePack()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pack = try #require(ShimejiRuntimePackLoader.load(packDir: dir))
        let env = BehaviorEnvironment(
            workArea: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1040),
            activeWindow: .invisible,
            screen: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1080)
        )
        let engine = ShimejiMascotEngine(
            graph: pack.graph, library: pack.library,
            anchor: BehaviorPoint(x: 500, y: 400), environment: env, seed: 3
        )
        var landed = false
        for _ in 0..<200 {
            let frame = engine.tick(environment: env)
            if Int(frame.anchor.y.rounded()) == 1040 { landed = true; break }
        }
        #expect(landed)
    }
}
