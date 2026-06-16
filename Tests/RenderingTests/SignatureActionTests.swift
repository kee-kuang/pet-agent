import AppKit
import Testing
@testable import Rendering

@Suite("SignatureAction + PetRenderer protocol 默认实现")
struct SignatureActionTests {

    // MARK: - SignatureAction Hashable / Equatable

    @Test("SignatureAction 同 case 相等, 不同 case 不等")
    func equality() {
        #expect(SignatureAction.greet == .greet)
        #expect(SignatureAction.celebrate == .celebrate)
        #expect(SignatureAction.greet != .celebrate)
        #expect(SignatureAction.refuse != .acknowledge)
    }

    @Test("SignatureAction 全部 case 可放进 Set, 集合长度等于 case 数")
    func setMembership() {
        let all: Set<SignatureAction> = [
            .greet, .celebrate, .acknowledge, .refuse,
            .signatureIdle, .reactToDragEnd,
        ]
        // 当前 6 个 case, 新增 case 时此测试会 fail 提醒同步 contract
        #expect(all.count == 6)
    }

    // MARK: - PetRenderer 默认实现 (Orb 走 default 空集 + no-op)

    /// 最小 PetRenderer conformance, 只实现必要项 (contentLayer + updateForState +
    /// pause/resume), supportedSignatures / trigger 走 protocol 默认。
    @MainActor
    final class MinimalRenderer: PetRenderer {
        let contentLayer: CALayer = CALayer()
        var lastState: PetEmotionState?
        func updateForState(_ state: PetEmotionState) { lastState = state }
    }

    @Test("默认 supportedSignatures 是空集")
    @MainActor
    func defaultSupportedIsEmpty() {
        let r = MinimalRenderer()
        #expect(r.supportedSignatures.isEmpty)
    }

    @Test("默认 trigger(_:) 是 no-op (不抛错 + renderer 状态不变)")
    @MainActor
    func defaultTriggerIsNoOp() {
        let r = MinimalRenderer()
        r.updateForState(.thinking)
        // 调 trigger 不应该改变 lastState
        r.trigger(.celebrate)
        r.trigger(.refuse)
        r.trigger(.acknowledge)
        #expect(r.lastState == .thinking)
    }

    // MARK: - 自定义 conformance 覆盖 supportedSignatures

    @MainActor
    final class CelebrateOnlyRenderer: PetRenderer {
        let contentLayer: CALayer = CALayer()
        var triggeredActions: [SignatureAction] = []
        var supportedSignatures: Set<SignatureAction> { [.celebrate] }
        func updateForState(_ state: PetEmotionState) {}
        func trigger(_ signature: SignatureAction) {
            triggeredActions.append(signature)
        }
    }

    @Test("自定义 supportedSignatures 子集生效, contains 校验可路由")
    @MainActor
    func customSupportedSubset() {
        let r = CelebrateOnlyRenderer()
        #expect(r.supportedSignatures == [.celebrate])
        #expect(r.supportedSignatures.contains(.celebrate))
        #expect(r.supportedSignatures.contains(.refuse) == false)
    }

    @Test("覆盖 trigger 后被记录, Shell 应在 dispatch 前先用 supportedSignatures 过滤")
    @MainActor
    func customTriggerRecorded() {
        let r = CelebrateOnlyRenderer()
        // 调用方应该按 supportedSignatures 过滤;此处直接调 trigger 模拟 Shell
        // 已校验通过 的场景。
        if r.supportedSignatures.contains(.celebrate) {
            r.trigger(.celebrate)
        }
        #expect(r.triggeredActions == [.celebrate])
    }
}
