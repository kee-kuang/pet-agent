import Foundation

/// Falling-sand 雪物理的**实时可调参数单一真相源**。
///
/// 把散落在 `FallingSandRules`（相变阈值/升华）、`FallingSandParticles`（重力/风/
/// 大小/上限）、`FallingSandDriver`（密度）里的字面量收拢成一份，供 设置 → 调试 面板
/// 拖滑块实时调（无需 edit→build→install→截图）。默认值 = 当前生产值。
///
/// 数据流：调试面板拖滑块 → `SettingsViewModel.fallingSandTuning` → app → driver.tuning
/// → 每帧 apply 到 particles / engine uniforms。Codable 持久化到 UserDefaults。
public struct FallingSandTuning: Equatable, Sendable, Codable {
    // MARK: - 降雪
    /// 每帧发射飞行雪粒子数（降雪密度 + 积雪速度的主因子；全屏 ~1512 列需够大）。
    public var snowEmitPerFrame: Int = 40
    /// 每帧发射雨粒子数。
    public var rainEmitPerFrame: Int = 90   // 雨比雪密（大雨，落得快每颗在屏短）；面板可微调
    /// 风力（kernel 在此基础上叠空间+时间噪声出阵风）。
    public var windStrength: Float = 1.5
    /// 重力（飞行粒子下落加速度，cell/s²）。
    public var gravity: Float = 90
    /// 雪花最小 / 最大尺寸（平方分布偏小）。
    public var sizeMin: Float = 0.6
    public var sizeMax: Float = 3
    /// 雪下落概率（1.0 = 每帧确定性下落）。
    public var snowFallProbability: Float = FallingSandRules.snowFallProbability

    // MARK: - 雨视觉（splash 水花 / 随风斜 / 湿亮 sheen）
    /// 雨滴落地溅起 splash 水花的概率（0..1）。落地雨先沉积 water cell，再按此概率
    /// 把自己转成一颗弹道水花（横飞+轻微上抛、弧线消亡、不二次沉积），余下直接消失。
    /// 默认 0.3：暴雨 emit 大，太高会糊成连续水花带、削弱单颗瞬时层次（Noita 风=稀疏精准）；
    /// 想看暴雨全员溅可面板拉满。
    public var splashProbability: Float = 0.3
    /// 雨的有向风 lean（带符号 cell/s）。正=向右斜、负=向左斜、0=直落。雪不受此影响
    /// （雪用 spatial 净零微飘，不集体滑）；渲染把蓝色 streak 沿 velocity 定向 → 雨随风斜。
    public var rainWindLean: Float = 9
    /// 不下雨时积水洼的湿亮 sheen 基线（0..1）。下雨时 driver 把 wetness lerp 到 1，
    /// 停雨后回落到此基线 —— 让融雪/残留水洼也保持一点"真实是湿的"反光，而非假玻璃水痕。
    public var wetnessBaseline: Float = 0.25

    // MARK: - 积雪
    /// 每列积雪硬上限（cell；防 runaway 的物理封顶）。
    public var maxColumnDepth: Int = 24
    /// 升华基础概率/秒（与深度无关；孤立雪缓慢消除）。
    public var snowSublimatePerSec: Float = FallingSandRules.snowSublimatePerSec
    /// 升华深度系数 k（稳态 h*=√(S/k)；调大→更浅，调小→更厚）。
    public var snowDepthSublimateCoeff: Float = FallingSandRules.snowDepthSublimateCoeff

    // MARK: - 相变温度阈值（归一化 0..1）
    public var meltThreshold: Float = FallingSandRules.meltThreshold
    public var freezeThreshold: Float = FallingSandRules.freezeThreshold
    public var evaporateThreshold: Float = FallingSandRules.evaporateThreshold
    public var condenseThreshold: Float = FallingSandRules.condenseThreshold

    // MARK: - 相变速率
    public var meltRatePerSec: Float = FallingSandRules.meltRatePerSec
    public var freezeRatePerSec: Float = FallingSandRules.freezeRatePerSec
    public var evaporateRatePerSec: Float = FallingSandRules.evaporateRatePerSec
    public var condenseRatePerSec: Float = FallingSandRules.condenseRatePerSec
    public var steamDissipatePerSec: Float = FallingSandRules.steamDissipatePerSec

    // MARK: - 调试温度覆盖
    /// 调试用环境温度覆盖（0..1 归一化）；`< 0` = 关闭（用天气/温度模式的值）。
    /// 方便不改天气就直接拖到「全融 0.9」/「冰冻 0.1」看相变。
    public var ambientOverride: Float = -1

    public init() {}

    /// 把当前值导出成可直接粘进代码的 Swift 片段（「导出当前值」按钮用）。
    public func swiftCodeSnippet() -> String {
        func f(_ v: Float) -> String { String(format: "%g", v) }
        return """
        // FallingSandTuning 当前调试值（粘进 FallingSandRules / FallingSandParticles / FallingSandDriver 作新默认）
        snowEmitPerFrame = \(snowEmitPerFrame)   rainEmitPerFrame = \(rainEmitPerFrame)
        windStrength = \(f(windStrength))   gravity = \(f(gravity))   size = \(f(sizeMin))…\(f(sizeMax))   snowFallProbability = \(f(snowFallProbability))
        splashProbability = \(f(splashProbability))   rainWindLean = \(f(rainWindLean))   wetnessBaseline = \(f(wetnessBaseline))
        maxColumnDepth = \(maxColumnDepth)   snowSublimatePerSec = \(f(snowSublimatePerSec))   snowDepthSublimateCoeff = \(f(snowDepthSublimateCoeff))
        meltThreshold = \(f(meltThreshold))   freezeThreshold = \(f(freezeThreshold))   evaporateThreshold = \(f(evaporateThreshold))   condenseThreshold = \(f(condenseThreshold))
        meltRatePerSec = \(f(meltRatePerSec))   freezeRatePerSec = \(f(freezeRatePerSec))   evaporateRatePerSec = \(f(evaporateRatePerSec))   condenseRatePerSec = \(f(condenseRatePerSec))   steamDissipatePerSec = \(f(steamDissipatePerSec))
        """
    }
}
