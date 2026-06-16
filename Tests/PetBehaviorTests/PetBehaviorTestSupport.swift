import Foundation
import PetBehavior

/// 确定性 SplitMix64 RNG,供加权随机分布测试可复现。
/// (与 RuntimeBridge.PetMotionRandom 同算法,此处独立一份避免跨 target 依赖。)
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 字典桩条件求值器:`results[condition] ?? defaultValue`。测试用它精确控制哪些条件成立。
struct StubConditionEvaluator: ConditionEvaluator {
    var results: [String: Bool] = [:]
    var defaultValue: Bool = true
    func isSatisfied(_ condition: String) -> Bool { results[condition] ?? defaultValue }
}

/// 把 XML 字符串转 Data(UTF-8)。
func xmlData(_ string: String) -> Data { Data(string.utf8) }
