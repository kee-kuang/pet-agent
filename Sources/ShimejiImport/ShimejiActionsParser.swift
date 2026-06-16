import Foundation

/// 解析 Shimeji-ee `actions.xml` → 动作名 → 有序帧序列。
///
/// **为何需要**:社区包(尤其自定义角色)的动画帧用**自定义命名**(`dance01.png`/`bounce01.png`),
/// 播放顺序/时长/位移全在 actions.xml 的 `<Pose>` 里 —— 图片本身无时序。仅按 `shime1-46.png`
/// 编号读帧的路径对这类包全瞎(只抓到散帧、无法拼成动作 → 桌宠静止不动)。本解析器读 actions.xml
/// 拿到「每个动作真正引用哪些帧」,让任意命名的包都能正确动起来。
///
/// **范围**:只取**叶子动作**(`Type=Stay/Move/Animate`)的 `<Pose>` 帧序 —— 它们是纯帧序列,1:1
/// 对应我们的 sprite 行。`Sequence`/`Select`(行为编排)、`Embedded`(引擎专属 Java 类:Fall/Dragged/
/// Breed/Hug)不解析 —— 无单个 sprite 行可落,且其效果多已被本仓原生 PetMotion 实现。
///
/// 参考 LavenderSnek/ShimejiEE-cross-platform 的 `ActionBuilder` 结构(抄思路、不抄 Java 代码)。
public enum ShimejiActionsParser {

    /// 一帧:引用的图片文件名 + 时长(Shimeji tick)+ x 位移(符号→朝向)。
    public struct Pose: Equatable, Sendable {
        public let image: String        // 帧文件名,已去前导 "/"(相对角色 img 目录)
        public let durationTicks: Int   // Shimeji tick(~40ms);缺省 0
        public let velocityX: Double    // 每 tick x 位移;非字面量(含 ${} 表达式)→ 0
        public init(image: String, durationTicks: Int, velocityX: Double) {
            self.image = image
            self.durationTicks = durationTicks
            self.velocityX = velocityX
        }
    }

    /// 叶子动作 Type 白名单(纯 Pose 序列)。空 Type 容错按叶子处理。
    private static let leafTypes: Set<String> = ["Stay", "Move", "Animate", ""]

    /// `actions.xml` 数据 → `[动作名: [Pose]]`。
    /// - 只收叶子动作(Stay/Move/Animate);Sequence/Select/Embedded 跳过。
    /// - 多 `<Animation Condition=...>` 分支取**第一个**(默认/无条件优先;条件分支运行时才知,导入降级取首)。
    /// - 解析失败 / 无 Pose 的动作 → 不入表。命名空间(`xmlns=…/Mascot`)用 localName 匹配,不受影响。
    public static func parse(_ data: Data) -> [String: [Pose]] {
        guard let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement() else { return [:] }
        var out: [String: [Pose]] = [:]
        for actionList in root.childElements(localName: "ActionList") {
            for action in actionList.childElements(localName: "Action") {
                guard let name = action.attr("Name") else { continue }
                let type = action.attr("Type") ?? ""
                guard leafTypes.contains(type) else { continue }
                guard let anim = action.childElements(localName: "Animation").first else { continue }
                let poses = anim.childElements(localName: "Pose").compactMap(pose(from:))
                if !poses.isEmpty { out[name] = poses }
            }
        }
        return out
    }

    private static func pose(from el: XMLElement) -> Pose? {
        guard let raw = el.attr("Image") else { return nil }
        return Pose(
            image: normalizeImage(raw),
            durationTicks: Int(el.attr("Duration") ?? "") ?? 0,
            velocityX: velocityX(el.attr("Velocity"))
        )
    }

    /// `"/shime1.png"` → `"shime1.png"`。Shimeji `Image` 是相对角色 img 根、以 `/` 开头的路径。
    static func normalizeImage(_ s: String) -> String {
        s.hasPrefix("/") ? String(s.dropFirst()) : s
    }

    /// `"-2,0"` → -2.0。含 `${}`/`#{}` 表达式或非法 → 0(只需朝向符号,表达式求值不在导入期做)。
    static func velocityX(_ s: String?) -> Double {
        guard let s, let comma = s.firstIndex(of: ",") else { return 0 }
        return Double(s[..<comma].trimmingCharacters(in: .whitespaces)) ?? 0
    }
}

// MARK: - XMLElement 便捷(localName 匹配,绕开默认命名空间)

private extension XMLElement {
    /// 直接子元素里 localName 匹配的(忽略命名空间前缀)。
    func childElements(localName: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == localName }
    }
    func attr(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }
}
