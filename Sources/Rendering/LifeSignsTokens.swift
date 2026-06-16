import Foundation

/// Orb「生命感」动画 token —— 体积呼吸 / 眨眼 / 完成跳跃的振幅、周期、间隔等常量。
///
/// 设计动机:让 Orb 静止状态(`.idle` / `.watching` / `.thinking` / ...)也有连续生命迹象,
/// 不再像一颗死球。参考上游开源项目 HermesPet (https://github.com/basionwang-bot/HermesPet)
/// 的 LifeSignsModifier 呼吸 / 眨眼 /
/// 跳跃三套节奏,适配 PetAgent 的 Metal SDF orb(HermesPet 原版是 SwiftUI ViewModifier,
/// 直接 `.scaleEffect` / `.opacity`;我们在 fragment shader 内用 uniform 调制 SDF 半径与
/// Fresnel)。
///
/// 跟 `AnimTok`(Shell 层 UI 动画)的区别:这里是 shader uniform 的振幅与频率,
/// 物理含义不同(振幅是 SDF radius 倍率,不是 TimeInterval),所以单独成 namespace。
public enum LifeSignsTokens {

    // MARK: - 体积呼吸

    /// 呼吸周期(秒)—— Orb SDF 半径以此周期做正弦振荡。与 HermesPet `AnimTok.breathe`
    /// 1.4s 一致;跟 PetChatAnimator idle 1.8s 位置呼吸(layer transform.translation.y)
    /// 周期不同,叠加出 beat 效果反而更生动。
    public static let breathPeriod: TimeInterval = 1.4

    /// 呼吸振幅(SDF radius 相对倍率)—— 1.0 ± breathAmplitude。
    /// 0.03 = ±3%,保守振幅,在 64 px 视口下肉眼可感不浮夸。
    public static let breathAmplitude: Float = 0.03

    // MARK: - 完成跳跃

    /// 完成跳跃:上跳偏移(逻辑像素)—— talking → idle 时表达「我说完了」的弹起信号。
    /// 4 pt 跟 PetChatAnimator idle 呼吸 ±4 pt 同量级,跳完不抢戏。
    public static let jumpOffset: Float = 4.0

    /// 完成跳跃:总时长(秒)—— 上跳 + 落回的完整 keyframe 时长。
    public static let jumpDuration: TimeInterval = 0.4
}
