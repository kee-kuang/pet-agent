/// reservation 认领移动。CPU 版按方向 pass 顺序跑（天然 race-free），
/// 模拟 GPU 并行 + atomic 认领的最终态。
///
/// 算法（每个 pass）：
///   Phase 1 认领：每个可移动 cell 按候选优先级找第一个空目标，对该目标
///     做「最小源 index 认领」（reservation[target] = min）。
///   Phase 1.5 判定：源是否赢得它认领的目标。
///   Phase 2 提交：赢家目标 ← 源 payload（clock 翻转）；赢家源 ← 空；
///     其余不变。每次成功移动清空一个源、填一个目标 → 守恒、无复制。
public enum FallingSandMovement {

    /// 重力 pass（含对角）。`snowFallForced` 为 true 时跳过雪的概率门（测试用确定性）。
    public static func gravityPass(
        _ g: inout FallingSandGrid,
        leftFirst: Bool,
        rng: inout FallingSandRandom,
        snowFallForced: Bool = false
    ) {
        applyPass(&g, leftFirst: leftFirst, rng: &rng, horizontal: false, snowFallForced: snowFallForced)
    }

    /// 水平漫流 pass（仅液体）。
    public static func flowPass(
        _ g: inout FallingSandGrid,
        leftFirst: Bool,
        rng: inout FallingSandRandom
    ) {
        applyPass(&g, leftFirst: leftFirst, rng: &rng, horizontal: true, snowFallForced: true)
    }

    // MARK: - 内部

    private static func applyPass(
        _ g: inout FallingSandGrid,
        leftFirst: Bool,
        rng: inout FallingSandRandom,
        horizontal: Bool,
        snowFallForced: Bool
    ) {
        let n = g.cells.count
        var reservation = [Int](repeating: -1, count: n)   // target index → 赢家源 index
        var sourceTarget = [Int](repeating: -1, count: n)  // 源 index → 它认领的 target index

        // Phase 1: 认领
        for y in 0..<g.height {
            for x in 0..<g.width {
                let p = g.at(x, y)
                let s = FallingSandCell.species(p)
                if s == .empty || s == .wall { continue }

                // 雪的概率下落门（非 horizontal pass）
                if !horizontal && s == .snow && !snowFallForced {
                    if rng.unit() > FallingSandRules.snowFallProbability { continue }
                }

                let candidates = horizontal
                    ? FallingSandRules.flowCandidates(s, leftFirst: leftFirst)
                    : FallingSandRules.gravityCandidates(s, leftFirst: leftFirst)
                if candidates.isEmpty { continue }

                let src = g.index(x, y)
                for off in candidates {
                    let tx = x + off.dx, ty = y + off.dy
                    guard g.inBounds(tx, ty) else { continue }
                    guard FallingSandCell.isEmpty(g.at(tx, ty)) else { continue }
                    guard !g.belowFloor(tx, ty) else { continue }   // 窗口内部不可进入
                    let tgt = g.index(tx, ty)
                    // 最小源 index 认领（确定性赢家）
                    if reservation[tgt] == -1 || src < reservation[tgt] {
                        reservation[tgt] = src
                    }
                    sourceTarget[src] = tgt
                    break
                }
            }
        }

        // Phase 1.5 + Phase 2: 提交到新 buffer
        var next = g.cells
        for src in 0..<n {
            let tgt = sourceTarget[src]
            guard tgt != -1, reservation[tgt] == src else { continue }   // 没认领或没赢
            let clock = FallingSandCell.clock(g.cells[src]) ^ 1
            next[tgt] = FallingSandCell.withClock(g.cells[src], clock)
            next[src] = FallingSandCell.empty
        }
        g.cells = next
    }
}
