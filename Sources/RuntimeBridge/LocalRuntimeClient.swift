import Context
import Foundation

/// 纯 Swift pet 运动 runtime —— 退役 Rust `weather_motion_runtime` 后的替代实现。
///
/// 唯一 live 逻辑(参照早期 Rust `physics.rs` 的运动逻辑重新实现,逐参数对齐行为保真,未拷贝源码):
/// 1. pet 以 `petTrackingSpeed` 恒速朝光标移动(对应原 `advance_position`);
/// 2. 统计光标命中的窗口数 `contactCount`(对应原 `cursor_inside`)。
///
/// 原 Rust runtime 的雪粒子子系统在 GPU falling-sand 重写(2026-06-02)后已死
/// (`wantsParticles` 恒为 false),随 Rust 一并退役 → 不再产出粒子。
public actor LocalRuntimeClient: RuntimeClient {
    /// px/s,参照早期 Rust `PET_TRACKING_SPEED` 常量重新设定(数值约定,未拷贝源码)。
    static let petTrackingSpeed = 160.0

    public init() {}

    public func capabilities() async throws -> RuntimeCapabilities {
        RuntimeCapabilities(version: "swift-local", supportsWeather: false)
    }

    public func step(_ input: RuntimeInput) async throws -> RuntimeOutput {
        let cursor = input.desktopSnapshot.cursorPosition
        let next = Self.advance(
            from: input.currentPetPose.position,
            toward: cursor,
            deltaTime: input.deltaTime
        )
        let contacts = input.collisionGeometry.reduce(into: 0) { count, rect in
            if Self.contains(rect: rect.bounds, point: cursor) { count += 1 }
        }
        return RuntimeOutput(
            petPose: PetPose(position: next, rotation: 0),
            contactCount: contacts,
            isSnowEnabled: input.isSnowEnabled
        )
    }

    /// pet 朝目标点恒速移动,逐帧 clamp 到 `maxStep`;够近则吸附到目标(消抖)。
    static func advance(from: Point, toward target: Point, deltaTime: Double) -> Point {
        let dx = target.x - from.x
        let dy = target.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let maxStep = petTrackingSpeed * deltaTime
        if distance <= maxStep || distance == 0 { return target }
        let scale = maxStep / distance
        return Point(x: from.x + dx * scale, y: from.y + dy * scale)
    }

    static func contains(rect: Rect, point: Point) -> Bool {
        point.x >= rect.origin.x
            && point.x <= rect.origin.x + rect.width
            && point.y >= rect.origin.y
            && point.y <= rect.origin.y + rect.height
    }
}
