/// Falling-sand GPU CA 的 MSL 源（项目惯例：kernel 写成 Swift `static let
/// source` 字面量，运行时 `makeLibrary(source:)` 编译，不用 .metal 文件）。
///
/// preamble（cell accessors / species 常量 / 位置哈希 / fs_at 越界=wall /
/// fs_move_target 候选 helper）必须与 CPU 端逐位一致：
/// - cell 字节布局对齐 `FallingSandCell.swift`
/// - 移动候选对齐 `FallingSandRules.gravityCandidates/flowCandidates`
/// - claim 与 commit 共用 `fs_move_target` → 两阶段对同一 cell 判断一致
///
/// 并行模型：双缓冲 + atomic 认领。每个移动 sub-pass = clear → claim → commit
/// 三 dispatch。claim 只认领空目标（最小源 index 赢），commit 按 empty/occupied
/// 二分提交（守恒、无复制）。RNG 用位置哈希（并行安全），仅相变 + 雪概率门用。
enum FallingSandKernels {
    static let source: String = """
#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------
// species 常量（对齐 FallingSandSpecies.rawValue）
// ---------------------------------------------------------------
constant uint FS_EMPTY = 0u;
constant uint FS_WALL  = 1u;
constant uint FS_SNOW  = 2u;
constant uint FS_WATER = 3u;
constant uint FS_ICE   = 4u;
constant uint FS_STEAM = 5u;

constant uint FS_SENTINEL = 0xFFFFFFFFu;

// ---------------------------------------------------------------
// uniforms（镜像 Swift FallingSandUniforms，字段顺序 + 4 字节标量布局一致）
// ---------------------------------------------------------------
struct FallingSandUniforms {
    uint  grid_width;
    uint  grid_height;
    uint  frame_index;
    uint  left_first;
    uint  pass_kind;          // 0 = gravity, 1 = flow
    uint  force_snow_fall;
    float dt;
    float snow_fall_probability;
    float melt_threshold;
    float freeze_threshold;
    float evaporate_threshold;
    float condense_threshold;
    float melt_rate_per_sec;
    float freeze_rate_per_sec;
    float evaporate_rate_per_sec;
    float condense_rate_per_sec;
    float steam_dissipate_per_sec;
    uint  steam_lifetime_frames;
    float snow_sublimate_per_sec;
    float wind_x;
    float snow_depth_sublimate_coeff;
    uint  rect_count;
    // pet 第二 occluder（镜像 Swift 尾部追加字段）。
    int   pet_origin_x;
    int   pet_origin_y;
    uint  pet_mask_w;
    uint  pet_mask_h;
    uint  pet_enabled;
};

// 窗口遮挡矩形（cell 坐标，y=0 底）。cell 在任意矩形内 → 遮挡（雪不可进）。
struct FSRect { float x; float y; float w; float h; };

// ---------------------------------------------------------------
// cell accessors（逐位对齐 FallingSandCell.swift）
//   byte0 species | byte1 ra | byte2 rb | byte3 clock
// ---------------------------------------------------------------
inline uint fs_species(uint p) { return p & 0xFFu; }
inline uint fs_ra(uint p)      { return (p >> 8) & 0xFFu; }
inline uint fs_rb(uint p)      { return (p >> 16) & 0xFFu; }
inline uint fs_clock(uint p)   { return (p >> 24) & 0xFFu; }
inline uint fs_make(uint s, uint ra, uint rb, uint clk) {
    return (s & 0xFFu) | ((ra & 0xFFu) << 8) | ((rb & 0xFFu) << 16) | ((clk & 0xFFu) << 24);
}
inline bool fs_is_empty(uint p) { return (p & 0xFFu) == 0u; }
inline uint fs_with_clock(uint p, uint c) { return (p & 0x00FFFFFFu) | ((c & 0xFFu) << 24); }
inline uint fs_with_rb(uint p, uint v)    { return (p & 0xFF00FFFFu) | ((v & 0xFFu) << 16); }

// 越界读 = wall（对齐 FallingSandGrid.at）
inline uint fs_at(const device uint* cells, uint w, uint h, int x, int y) {
    if (x < 0 || y < 0 || x >= int(w) || y >= int(h)) return fs_make(FS_WALL, 0u, 0u, 0u);
    return cells[uint(y) * w + uint(x)];
}

// 位置哈希 → [0,1)（SplitMix64 式，并行安全；仅相变 + 雪概率门用）
inline float fs_hash_unit(uint x, uint y, uint frame, uint salt) {
    ulong s = ((ulong)x * 0x9E3779B1ul) ^ ((ulong)y << 21)
            ^ ((ulong)frame * 0x85EBCA6Bul) ^ ((ulong)salt * 0xC2B2AE35ul);
    s = s + 0x9E3779B97F4A7C15ul;
    ulong z = s;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ul;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBul;
    z = z ^ (z >> 31);
    return (float)(uint)(z >> 40) * (1.0 / 16777216.0);
}

// ---------------------------------------------------------------
// 局部风速（空间+时间噪声，研究方向 3b）。strength=0 → 返回 0（确定性，对拍用）。
// 廉价 value-noise：多频 sin 叠加（xy 空间 + t 时间）模拟阵风扫过。
inline float fs_wind_at(uint x, uint y, uint frame, float strength) {
    if (strength == 0.0) return 0.0;
    float t = float(frame) / 60.0;
    float fx = float(x), fy = float(y);
    // 只用随位置变化的 spatial 扰动 → 每片雪独立轻微飘舞。**不要**空间一致的慢速
    // gust（周期 ~12s）：它让全场同向漂 ~6s，视觉上是「集体右滑」。两处风算法保持一致
    // （此处与 FallingSandParticleKernels.fsp_wind_at 同步）。
    float spatial = sin(fx * 0.011 + t * 0.7) * 0.6
                  + sin(fy * 0.023 - t * 0.4 + 1.7) * 0.4
                  + sin((fx + fy) * 0.006 + t * 0.25) * 0.5;
    return strength * spatial * 0.5;
}

// fs_move_target：cell (x,y) 想去哪个线性 index（含雪概率门），无目标=SENTINEL。
// claim 与 commit 共用，保证两阶段一致。对齐 CPU applyPass 的候选优先级 +
// 首个空目标选择。
// ---------------------------------------------------------------
inline uint fs_move_target(const device uint* cells, const device uchar* occlusion,
                           constant FallingSandUniforms& u, uint x, uint y) {
    uint w = u.grid_width, h = u.grid_height;
    uint p = cells[y * w + x];
    uint sp = fs_species(p);
    if (sp == FS_EMPTY || sp == FS_WALL || sp == FS_ICE) return FS_SENTINEL;

    // 雪概率门（gravity pass，非 forced）
    if (u.pass_kind == 0u && sp == FS_SNOW && u.force_snow_fall == 0u) {
        if (fs_hash_unit(x, y, u.frame_index, 0x5A5Au) > u.snow_fall_probability) return FS_SENTINEL;
    }

    bool leftFirst = (u.left_first != 0u);
    int cand[4][2];
    int ncand = 0;
    if (u.pass_kind == 0u) {
        if (sp == FS_SNOW) {
            // 风（strength=0 时 w=0 → 退化为现有顺序 → 对拍不破）：下风向对角优先 +
            // 概率性横向 drift（被风吹偏）。w 是局部风（空间+时间噪声）。
            float w = fs_wind_at(x, y, u.frame_index, u.wind_x);
            int n = 0;
            bool rightFirst = (w != 0.0) ? (w > 0.0) : (!leftFirst);
            if (w != 0.0
                && fs_hash_unit(x, y, u.frame_index, 0x7117u) < fabs(w) * 0.5) {
                cand[n][0] = (w > 0.0) ? 1 : -1; cand[n][1] = 0; n++;  // 横向下风
            }
            cand[n][0] = 0; cand[n][1] = -1; n++;
            if (rightFirst) { cand[n][0]=1;  cand[n][1]=-1; n++; cand[n][0]=-1; cand[n][1]=-1; n++; }
            else            { cand[n][0]=-1; cand[n][1]=-1; n++; cand[n][0]=1;  cand[n][1]=-1; n++; }
            ncand = n;
        } else if (sp == FS_WATER) {
            cand[0][0] = 0;  cand[0][1] = -1;
            if (leftFirst) { cand[1][0] = -1; cand[1][1] = -1; cand[2][0] = 1;  cand[2][1] = -1; }
            else           { cand[1][0] = 1;  cand[1][1] = -1; cand[2][0] = -1; cand[2][1] = -1; }
            ncand = 3;
        } else if (sp == FS_STEAM) {
            cand[0][0] = 0;  cand[0][1] = 1;
            if (leftFirst) { cand[1][0] = -1; cand[1][1] = 1; cand[2][0] = 1;  cand[2][1] = 1; }
            else           { cand[1][0] = 1;  cand[1][1] = 1; cand[2][0] = -1; cand[2][1] = 1; }
            ncand = 3;
        }
    } else {
        if (sp == FS_WATER) {
            if (leftFirst) { cand[0][0] = -1; cand[0][1] = 0; cand[1][0] = 1;  cand[1][1] = 0; }
            else           { cand[0][0] = 1;  cand[0][1] = 0; cand[1][0] = -1; cand[1][1] = 0; }
            ncand = 2;
        }
    }
    for (int i = 0; i < ncand; i++) {
        int tx = int(x) + cand[i][0];
        int ty = int(y) + cand[i][1];
        if (tx < 0 || ty < 0 || tx >= int(w) || ty >= int(h)) continue;
        if (occlusion[uint(ty) * w + uint(tx)] != 0u) continue;   // 窗口内部（遮挡）不可进入
        uint tp = cells[uint(ty) * w + uint(tx)];
        if (fs_is_empty(tp)) return uint(ty) * w + uint(tx);
    }
    return FS_SENTINEL;
}

// ---------------------------------------------------------------
// kernel: 栅格化窗口遮挡 mask —— 每 cell 检查是否落在任意窗口矩形内（2D 遮挡）。
// 比 1D 列 floor 更物理：悬浮窗只挡自己矩形内部，下方开阔地照常积雪。
// 每帧 step 开头跑（窗口移动/切桌面立刻重算）。
// ---------------------------------------------------------------
kernel void fs_rasterize_occlusion(
    device uchar* occlusion                [[buffer(0)]],
    const device FSRect* rects             [[buffer(1)]],
    constant FallingSandUniforms& u        [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.grid_width || gid.y >= u.grid_height) return;
    float fx = float(gid.x) + 0.5, fy = float(gid.y) + 0.5;
    uchar occ = 0u;
    for (uint i = 0u; i < u.rect_count; i++) {
        FSRect r = rects[i];
        if (fx >= r.x && fx < r.x + r.w && fy >= r.y && fy < r.y + r.h) { occ = 1u; break; }
    }
    occlusion[gid.y * u.grid_width + gid.x] = occ;
}

// ---------------------------------------------------------------
// kernel: 栅格化 pet alpha 轮廓进 occlusion buffer（pet 第二 occluder）。
// pet 当前帧 alpha mask（uchar 0..255，mask 局部坐标）OR 进窗口遮挡 → 雪堆在 pet
// 轮廓顶上（比包围盒准，堆出猫头/肩形）。线程 = mask cell（cellSize=1 时 1 mask
// cell = 1 world cell，无缩放）。在 fs_rasterize_occlusion 之后、fs_clear_occluded
// 之前 dispatch（OR 进已写好的窗口遮挡）。
//
// **Y 翻转在此处（唯一一处）**：mask row 0 = sprite 顶部（CGImage top-left 行序，
// renderer 不翻转），而 occlusion grid 是 y=0 底（y-up）。pet_origin_y = pet 占位
// 底行 cell → mask row my（顶=0）映射到 world y = origin_y + (mask_h-1-my)。
// ---------------------------------------------------------------
kernel void fs_rasterize_pet(
    device uchar* occlusion                [[buffer(0)]],
    const device uchar* pet_mask           [[buffer(1)]],
    constant FallingSandUniforms& u        [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (u.pet_enabled == 0u) return;
    if (gid.x >= u.pet_mask_w || gid.y >= u.pet_mask_h) return;
    uchar a = pet_mask[gid.y * u.pet_mask_w + gid.x];
    if (a < 128u) return;                                  // alpha 半透以下不算遮挡
    int wx = u.pet_origin_x + int(gid.x);
    int wy = u.pet_origin_y + int(u.pet_mask_h - 1u - gid.y);   // Y 翻转（mask 顶→世界高 y）
    if (wx < 0 || wy < 0 || wx >= int(u.grid_width) || wy >= int(u.grid_height)) return;
    occlusion[uint(wy) * u.grid_width + uint(wx)] = 1u;
}

// ---------------------------------------------------------------
// kernel: 清除被遮挡的雪 —— 落在窗口矩形内（occlusion=1）的 cell 清空。
// 窗口出现/移动/切桌面时盖住已沉积的雪，这些雪现在「在窗口内」，物理上不该存在 →
// 每帧清掉（Noita 标准 #2 遮挡变化重评估支撑 + Snowfall 窗口内融化）。每帧 step 开头跑。
// ---------------------------------------------------------------
kernel void fs_clear_occluded(
    device uint* cells                     [[buffer(0)]],
    const device uchar* occlusion          [[buffer(1)]],
    constant FallingSandUniforms& u        [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.grid_width || gid.y >= u.grid_height) return;
    uint i = gid.y * u.grid_width + gid.x;
    if (occlusion[i] != 0u) {                       // 在窗口内部
        if ((cells[i] & 0xFFu) != 0u) { cells[i] = 0u; }   // 清掉任何元素
    }
}

// ---------------------------------------------------------------
// kernel: 清 reservation 为 SENTINEL
// ---------------------------------------------------------------
kernel void fs_clear_reservation(
    device atomic_uint* reservation       [[buffer(0)]],
    constant FallingSandUniforms& u        [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.grid_width || gid.y >= u.grid_height) return;
    uint i = gid.y * u.grid_width + gid.x;
    atomic_store_explicit(&reservation[i], FS_SENTINEL, memory_order_relaxed);
}

// ---------------------------------------------------------------
// kernel: 认领 —— 每个可移动 cell 对目标做最小源 index 认领
// ---------------------------------------------------------------
kernel void fs_claim_move(
    const device uint* cells_in            [[buffer(0)]],
    device atomic_uint* reservation        [[buffer(1)]],
    constant FallingSandUniforms& u        [[buffer(2)]],
    const device uchar* occlusion          [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.grid_width || gid.y >= u.grid_height) return;
    uint src = gid.y * u.grid_width + gid.x;
    uint tgt = fs_move_target(cells_in, occlusion, u, gid.x, gid.y);
    if (tgt == FS_SENTINEL) return;
    atomic_fetch_min_explicit(&reservation[tgt], src, memory_order_relaxed);
}

// ---------------------------------------------------------------
// kernel: 提交 —— 双缓冲写 cells_out。empty/occupied 二分：
//   有源认领我（reservation[i]!=SENTINEL）→ 搬源 payload 进来（clock 翻转）
//   否则我若移走（reservation[myTgt]==i）→ 清空，否则原样
// ---------------------------------------------------------------
kernel void fs_commit_move(
    const device uint* cells_in            [[buffer(0)]],
    device uint* cells_out                 [[buffer(1)]],
    const device uint* reservation         [[buffer(2)]],
    constant FallingSandUniforms& u        [[buffer(3)]],
    const device uchar* occlusion          [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.grid_width || gid.y >= u.grid_height) return;
    uint w = u.grid_width;
    uint i = gid.y * w + gid.x;
    uint winner = reservation[i];
    if (winner != FS_SENTINEL) {
        uint src_p = cells_in[winner];
        uint flipped = fs_clock(src_p) ^ 1u;
        cells_out[i] = fs_with_clock(src_p, flipped);
        return;
    }
    uint myTgt = fs_move_target(cells_in, occlusion, u, gid.x, gid.y);
    if (myTgt != FS_SENTINEL && reservation[myTgt] == i) {
        cells_out[i] = FS_EMPTY;
    } else {
        cells_out[i] = cells_in[i];
    }
}

// ---------------------------------------------------------------
// kernel: 温度驱动相变（in-place，per-cell 独立，无邻居依赖）。
// 对齐 CPU FallingSandPhase 的概率公式；RNG 用位置哈希（与 CPU 顺序流分歧，
// 故不做逐位对拍，测不变量）。
//   snow/ice > melt → water；water < freeze → ice，water > evap → steam；
//   steam < condense 或 lifetime 到 → water，小概率 dissipate → empty。
// ---------------------------------------------------------------
// 计算每列雪堆深度（该列 snow cell 总数），供 fs_apply_phase 的深度负反馈升华读。
// 一线程一列，自底向上数 snow cell。
kernel void fs_compute_column_depth(
    const device uint* cells               [[buffer(0)]],
    device uint* column_depth              [[buffer(1)]],
    constant FallingSandUniforms& u        [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= u.grid_width) return;
    uint count = 0u;
    for (uint y = 0u; y < u.grid_height; y++) {
        if ((cells[y * u.grid_width + gid] & 0xFFu) == FS_SNOW) { count++; }
    }
    column_depth[gid] = count;
}

kernel void fs_apply_phase(
    device uint* cells                     [[buffer(0)]],
    const device float* temps              [[buffer(1)]],
    constant FallingSandUniforms& u        [[buffer(2)]],
    const device uint* column_depth        [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.grid_width || gid.y >= u.grid_height) return;
    uint i = gid.y * u.grid_width + gid.x;
    uint p = cells[i];
    uint sp = fs_species(p);
    if (sp == FS_EMPTY || sp == FS_WALL) return;
    float t = temps[i];
    uint ra = fs_ra(p);
    float dt = u.dt;

    if (sp == FS_SNOW) {
        if (t > u.melt_threshold) {
            float prob = min((t - u.melt_threshold) * u.melt_rate_per_sec * dt, 1.0);
            if (fs_hash_unit(gid.x, gid.y, u.frame_index, 0x4D11u) < prob) {
                cells[i] = fs_make(FS_WATER, ra, 0u, 0u);
                return;
            }
        }
        // 升华：base + 深度负反馈。每个雪 cell 升华率 = base + k·columnDepth →
        // 每列总移除 ≈ k·h² → 稳态 h*=√(S/k)，spawn 怎么调都自动收敛（积雪平衡）。
        float depth = float(column_depth[gid.x]);
        float subRate = u.snow_sublimate_per_sec + u.snow_depth_sublimate_coeff * depth;
        if (fs_hash_unit(gid.x, gid.y, u.frame_index, 0x53C0u) < subRate * dt) {
            cells[i] = FS_EMPTY;
        }
    } else if (sp == FS_ICE) {
        if (t > u.melt_threshold) {
            float prob = min((t - u.melt_threshold) * u.melt_rate_per_sec * dt, 1.0);
            if (fs_hash_unit(gid.x, gid.y, u.frame_index, 0x4D11u) < prob) {
                cells[i] = fs_make(FS_WATER, ra, 0u, 0u);
            }
        }
    } else if (sp == FS_WATER) {
        if (t > u.evaporate_threshold) {
            float prob = min((t - u.evaporate_threshold) * u.evaporate_rate_per_sec * dt, 1.0);
            if (fs_hash_unit(gid.x, gid.y, u.frame_index, 0xE7A2u) < prob) {
                cells[i] = fs_make(FS_STEAM, ra, 0u, 0u);
            }
        } else if (t < u.freeze_threshold) {
            float prob = min((u.freeze_threshold - t) * u.freeze_rate_per_sec * dt, 1.0);
            if (fs_hash_unit(gid.x, gid.y, u.frame_index, 0xF00Du) < prob) {
                cells[i] = fs_make(FS_ICE, ra, 0u, 0u);
            }
        }
    } else if (sp == FS_STEAM) {
        uint life = fs_rb(p);
        uint nextLife = life < 255u ? life + 1u : 255u;
        uint np = fs_with_rb(p, nextLife);
        bool lifeUp = nextLife >= u.steam_lifetime_frames;
        float condProb = min((u.condense_threshold - t) * u.condense_rate_per_sec * dt
                             + (lifeUp ? 0.05 : 0.0), 1.0);
        if ((t < u.condense_threshold || lifeUp)
            && fs_hash_unit(gid.x, gid.y, u.frame_index, 0xC0DEu) < condProb) {
            cells[i] = fs_make(FS_WATER, ra, 0u, 0u);
        } else if (fs_hash_unit(gid.x, gid.y, u.frame_index, 0xD15Au) < u.steam_dissipate_per_sec * dt) {
            cells[i] = FS_EMPTY;
        } else {
            cells[i] = np;
        }
    }
}
"""
}
