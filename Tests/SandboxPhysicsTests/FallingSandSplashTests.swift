import Testing
import Metal
import simd
@testable import SandboxPhysics

/// splash 水花：主雨落地先沉积 water cell，再按 `splashProbability` 把自己转成一颗
/// 弹道水花（kind=2，横飞+上抛，弧线消亡，不二次沉积）。雪不溅。
@Suite("FallingSand splash 水花")
struct FallingSandSplashTests {
    /// 在底行附近手摆一颗粒子 → land 一帧 → 返回 (沉积的 cell species, 粒子落地后状态)。
    private func landOne(
        kind: UInt32,
        velocity: SIMD2<Float>,
        splashProbability: Float
    ) throws -> (species: UInt32, particle: SnowParticle) {
        let device = try #require(SharedMetal.device)
        let queue = try #require(SharedMetal.commandQueue)
        let gw = 64, gh = 48
        let p = try #require(FallingSandParticles(device: device, queue: queue, gridWidth: gw, gridHeight: gh, capacity: 64))
        p.splashProbability = splashProbability
        let cellBuf = try #require(device.makeBuffer(length: gw * gh * MemoryLayout<UInt32>.stride, options: [.storageModeShared]))
        cellBuf.contents().initializeMemory(as: UInt32.self, repeating: 0, count: gw * gh)
        let occBuf = try #require(device.makeBuffer(length: gw * gh * MemoryLayout<UInt8>.stride, options: [.storageModeShared]))
        occBuf.contents().initializeMemory(as: UInt8.self, repeating: 0, count: gw * gh)
        let depthBuf = try #require(device.makeBuffer(length: gw * MemoryLayout<UInt32>.stride, options: [.storageModeShared]))
        depthBuf.contents().initializeMemory(as: UInt32.self, repeating: 0, count: gw)

        let pptr = p.buffer.contents().bindMemory(to: SnowParticle.self, capacity: 64)
        pptr[0] = SnowParticle(position: SIMD2<Float>(30, 0.4), velocity: velocity, size: 3, seed: 12345, alive: 1, kind: kind)

        p.land(cellBuffer: cellBuf, occlusionBuffer: occBuf, columnDepthBuffer: depthBuf, dt: 1.0 / 60.0)

        let cells = cellBuf.contents().bindMemory(to: UInt32.self, capacity: gw * gh)
        let after = p.buffer.contents().bindMemory(to: SnowParticle.self, capacity: 64)
        return (cells[0 * gw + 30] & 0xFF, after[0])
    }

    @Test("主雨 splashProbability=1：先沉积水，再转成上抛的 splash 水花（kind=2 存活）")
    func mainRainSpawnsSplash() throws {
        let (species, particle) = try landOne(kind: 1, velocity: SIMD2<Float>(0, -5), splashProbability: 1)
        #expect(species == 3)                 // water 已沉积
        #expect(particle.alive == 1)          // 没死 —— 转成了水花
        #expect(particle.kind == 2)           // splash 水花
        #expect(particle.velocity.y > 0)      // 向上抛
    }

    @Test("主雨 splashProbability=0：沉积水后直接死亡（不溅）")
    func mainRainNoSplashWhenZero() throws {
        let (species, particle) = try landOne(kind: 1, velocity: SIMD2<Float>(0, -5), splashProbability: 0)
        #expect(species == 3)                 // water 已沉积
        #expect(particle.alive == 0)          // 死亡
        #expect(particle.kind == 1)           // 仍是主雨（没转）
    }

    @Test("splash 水花下落触地：消亡且不沉积（纯视觉）")
    func fallingSplashDiesWithoutDeposit() throws {
        let (species, particle) = try landOne(kind: 2, velocity: SIMD2<Float>(0, -5), splashProbability: 1)
        #expect(species == 0)                 // 没沉积任何 cell
        #expect(particle.alive == 0)          // 触地消亡
    }

    @Test("splash 水花上升中：无视落地（避免落回刚溅起的水）")
    func risingSplashSurvivesLanding() throws {
        let (species, particle) = try landOne(kind: 2, velocity: SIMD2<Float>(0, 10), splashProbability: 1)
        #expect(species == 0)                 // 不沉积
        #expect(particle.alive == 1)          // 上升中存活，继续弧线
    }

    @Test("雪落地不溅（splashProbability=1 也只沉积 snow 后死亡）")
    func snowNeverSplashes() throws {
        let (species, particle) = try landOne(kind: 0, velocity: SIMD2<Float>(0, -5), splashProbability: 1)
        #expect(species == 2)                 // snow
        #expect(particle.alive == 0)
        #expect(particle.kind == 0)
    }
}
