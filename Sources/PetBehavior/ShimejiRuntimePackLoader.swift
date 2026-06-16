import Foundation

/// 已安装 Shimeji 包的运行时数据加载器:`<包目录>/conf/{actions,behaviors}.xml` + `img/` →
/// `(graph, library, imageDirectory)` 喂 `ShimejiMascotEngine`。
///
/// 完整性判定:**actions + behaviors 都可解析 且 img/ 存在**才返回包(包转换器是
/// best-effort 拷贝,缺任一 → nil → host 退化为 spritesheet-only 渲染,不启用行为引擎)。
/// 宽容坏包:悬空引用不阻塞加载(引擎对缺失行为/动作有界兜底),只在 `RuntimePack` 上暴露
/// 校验结果供 host 诊断日志。
public enum ShimejiRuntimePackLoader {
    public struct RuntimePack {
        public let graph: ShimejiBehaviorGraph
        public let library: ShimejiActionLibrary
        /// 原始帧目录(渲染端按帧名加载;含 shimeN 与自定义命名)。
        public let imageDirectory: URL
        /// 诊断:行为图悬空引用 + 动作库悬空引用 + 行为→动作缺失(空 = 全闭合)。
        public let validationIssues: [String]
    }

    public static func load(packDir: URL) -> RuntimePack? {
        let confDir = packDir.appendingPathComponent("conf", isDirectory: true)
        let imageDirectory = packDir.appendingPathComponent("img", isDirectory: true)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: imageDirectory.path, isDirectory: &isDir), isDir.boolValue,
              let actionsData = try? Data(contentsOf: confDir.appendingPathComponent("actions.xml")),
              let behaviorsData = try? Data(contentsOf: confDir.appendingPathComponent("behaviors.xml")),
              let library = ShimejiActionLibraryParser.parse(actionsData),
              let graph = ShimejiBehaviorParser.parse(behaviorsData),
              !graph.behaviors.isEmpty, !library.actions.isEmpty
        else { return nil }

        var issues: [String] = []
        for name in graph.danglingReferences() { issues.append("行为图悬空引用: \(name)") }
        for name in library.danglingReferences() { issues.append("动作库悬空引用: \(name)") }
        for behavior in graph.behaviors.values.sorted(by: { $0.name < $1.name })
        where library.action(named: behavior.actionName) == nil {
            issues.append("行为 \(behavior.name) 的动作缺失: \(behavior.actionName)")
        }

        return RuntimePack(
            graph: graph,
            library: library,
            imageDirectory: imageDirectory,
            validationIssues: issues
        )
    }
}
