/// 温度驱动相变。读 per-cell 归一化温度（0..1），按概率翻转 species：
///   snow > meltThreshold → water
///   water < freezeThreshold → ice ；water > evaporateThreshold → steam
///   ice > meltThreshold → water
///   steam < condenseThreshold（或 lifetime 到）→ water ；小概率消散 → empty
/// 概率 = (温差) · rate · dt，clamp 到 [0,1]。
public enum FallingSandPhase {
    public static func apply(
        _ g: inout FallingSandGrid,
        temperatures: [Float],
        dt: Float,
        rng: inout FallingSandRandom
    ) {
        precondition(temperatures.count == g.cells.count, "温度场尺寸需与网格一致")
        let R = FallingSandRules.self
        // 每列雪深（深度负反馈升华读）—— 镜像 GPU fs_compute_column_depth。
        var columnDepth = [Int](repeating: 0, count: g.width)
        for idx in 0..<g.cells.count where FallingSandCell.species(g.cells[idx]) == .snow {
            columnDepth[idx % g.width] += 1
        }
        for i in 0..<g.cells.count {
            let p = g.cells[i]
            let s = FallingSandCell.species(p)
            if s == .empty || s == .wall { continue }
            let t = temperatures[i]
            let ra = FallingSandCell.ra(p)

            switch s {
            case .snow:
                if t > R.meltThreshold,
                   rng.unit() < min((t - R.meltThreshold) * R.meltRatePerSec * dt, 1) {
                    g.cells[i] = FallingSandCell.make(.water, ra: ra)
                } else {
                    // 升华：base + 深度负反馈 k·columnDepth → 每列总移除 ≈ k·h² →
                    // 稳态 h*=√(S/k)，spawn 怎么调都自动收敛（镜像 GPU）。
                    let depth = Float(columnDepth[i % g.width])
                    let subRate = R.snowSublimatePerSec + R.snowDepthSublimateCoeff * depth
                    if rng.unit() < subRate * dt { g.cells[i] = FallingSandCell.empty }
                }
            case .ice:
                if t > R.meltThreshold,
                   rng.unit() < min((t - R.meltThreshold) * R.meltRatePerSec * dt, 1) {
                    g.cells[i] = FallingSandCell.make(.water, ra: ra)
                }
            case .water:
                if t > R.evaporateThreshold,
                   rng.unit() < min((t - R.evaporateThreshold) * R.evaporateRatePerSec * dt, 1) {
                    g.cells[i] = FallingSandCell.make(.steam, ra: ra)
                } else if t < R.freezeThreshold,
                          rng.unit() < min((R.freezeThreshold - t) * R.freezeRatePerSec * dt, 1) {
                    g.cells[i] = FallingSandCell.make(.ice, ra: ra)
                }
            case .steam:
                // lifetime 累加进 rb
                let life = FallingSandCell.rb(p)
                let nextLife = life < 255 ? life + 1 : 255
                let np = FallingSandCell.withRb(p, nextLife)
                let lifeUp = nextLife >= R.steamLifetimeFrames
                if t < R.condenseThreshold || lifeUp,
                   rng.unit() < min((R.condenseThreshold - t) * R.condenseRatePerSec * dt + (lifeUp ? 0.05 : 0), 1) {
                    g.cells[i] = FallingSandCell.make(.water, ra: ra)
                } else if rng.unit() < R.steamDissipatePerSec * dt {
                    g.cells[i] = FallingSandCell.empty
                } else {
                    g.cells[i] = np
                }
            default:
                break
            }
        }
    }
}
