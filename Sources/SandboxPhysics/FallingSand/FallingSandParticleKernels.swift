/// 飞行雪粒子 MSL（参考上游开源项目 Snowfall (https://github.com/BarredEwe/Snowfall) 的浮点粒子做法重新实现）。浮点位置 + 速度 → `pos += vel*dt`
/// 全程亚像素，根治 cell-CA「一卡一卡」整格跳；per-particle size → 随机大小雪花。
///
/// 坐标系对齐 CA：y=0 底、+y 上；下落 = velocity.y 为负。
/// `fsp_wind_at` 与 FallingSandKernels.fs_wind_at 同算法（独立 source string 不能
/// 共享符号，故复制一份；改风算法时两处同步）。
enum FallingSandParticleKernels {
    static let source: String = """
#include <metal_stdlib>
using namespace metal;

struct SnowParticle {
    float2 position;
    float2 velocity;
    float size;
    uint seed;
    uint alive;
    uint kind;   // 0 = 雪, 1 = 主雨, 2 = splash 水花
};

struct FSParticleUniforms {
    uint  particle_count;
    uint  grid_width;
    uint  grid_height;
    uint  frame_index;
    float dt;
    float gravity;
    float wind_x;          // 雨的有向风 lean（带符号）；雪不用
    float wind_strength;   // 雪 spatial 微飘强度
    uint  max_column_depth;
    float splash_probability;   // 雨落地溅起 splash 水花概率 0..1
    // pet 扬雪（粒子在 pet AABB 内 + pet 横移 → 横扫上扬，镜像 Swift 尾部追加）。
    uint  pet_sweep_enabled;    // 1 = 启用扬雪，0 = 跳过
    float pet_min_x;            // pet AABB（cell 坐标，y=0 底）
    float pet_min_y;
    float pet_max_x;
    float pet_max_y;
    float pet_vel_x;            // pet 横向速度（cell/s，带符号）
};

// 局部风（空间+时间噪声）— 复制自 FallingSandKernels.fs_wind_at，保持一致。
inline float fsp_wind_at(float fx, float fy, uint frame, float strength) {
    if (strength == 0.0) return 0.0;
    float t = float(frame) / 60.0;
    // 只用随位置变化的 spatial 扰动 → 每片雪独立轻微飘舞（有的偏左有的偏右）。
    // **不要**空间一致的慢速 gust（周期 ~12s）：它让全场雪花同向漂 ~6s，视觉上
    // 就是「屏幕雪集体往右滑」（用户反馈）。spatial 在任一时刻对全体均值≈0 → 无集体漂。
    float spatial = sin(fx * 0.011 + t * 0.7) * 0.6
                  + sin(fy * 0.023 - t * 0.4 + 1.7) * 0.4
                  + sin((fx + fy) * 0.006 + t * 0.25) * 0.5;
    return strength * spatial * 0.5;
}

// SplitMix 式 hash → [0,1)，回收时重置 x 用。
inline float fsp_hash_unit(uint a, uint b) {
    uint z = (a * 0x9E3779B1u) ^ (b * 0x85EBCA6Bu);
    z = (z ^ (z >> 15)) * 0x2C1B3C6Du;
    z = (z ^ (z >> 12)) * 0x297A2D39u;
    z = z ^ (z >> 15);
    return float(z & 0x00FFFFFFu) / float(0x01000000u);
}

// 积分一帧：重力 + 风（按 size，大雪花受风更大）+ pos += vel*dt（亚像素）。
// 落到底（y<0）暂回收到顶（H3 接 CA 落地前的临时行为）。
kernel void fs_integrate_particles(
    device SnowParticle* particles         [[buffer(0)]],
    constant FSParticleUniforms& u         [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particle_count) return;
    SnowParticle p = particles[id];
    if (p.alive == 0u) return;

    p.velocity.y -= u.gravity * u.dt;            // 重力向下（-y）对所有粒子生效
    if (p.kind == 0u) {
        // 雪：spatial 净零微飘（每片独立飘舞，对全体均值≈0 → 不集体滑）。
        // 强度取 wind_strength（与旧行为一致：strength² 系数，因旧 wind_x==wind_strength）。
        float w = fsp_wind_at(p.position.x, p.position.y, u.frame_index, u.wind_strength);
        p.velocity.x += w * u.wind_strength * (0.4 + p.size * 0.12) * u.dt;  // 大雪花受风更大
        p.velocity.x *= 0.98;                                                // 横向阻尼
    } else if (p.kind == 1u) {
        // 主雨：朝有向风 lean 速度收敛（雨随风斜飘；雪保持净零不滑）。
        p.velocity.x += (u.wind_x - p.velocity.x) * 3.0 * u.dt;
    } else {
        // splash 水花（kind==2）：纯弹道，无风；轻微横向阻尼让水花软着陆。
        p.velocity.x *= 0.99;
    }
    // pet 扬雪：雪粒子在 pet AABB 内且 pet 有明显横移 → 沿运动方向横扫 +
    // 轻微上扬（踩雪喷散幻觉，代偿 sprite 无脚印）。阈值滤静止/微动（站立呼吸不扬雪）。
    if (u.pet_sweep_enabled != 0u && p.kind == 0u
        && p.position.x >= u.pet_min_x && p.position.x < u.pet_max_x
        && p.position.y >= u.pet_min_y && p.position.y < u.pet_max_y
        && fabs(u.pet_vel_x) > 15.0) {              // 阈值 15 cell/s：滤静止/呼吸微动
        p.velocity.x += u.pet_vel_x * 8.0 * u.dt;   // 横向冲量 ∝ pet 速度，正向跟随
        p.velocity.y += 40.0 * u.dt;                // 轻微上扬，雪被踢起
    }
    p.position += p.velocity * u.dt;             // 亚像素积分

    // 落到底（未被 land 捕获的安全网）→ 死亡（不回收，避免顶部聚集）。
    if (p.position.y < 0.0) {
        p.alive = 0u;
        particles[id] = p;
        return;
    }
    // 横向环绕
    if (p.position.x < 0.0) { p.position.x += float(u.grid_width); }
    if (p.position.x >= float(u.grid_width)) { p.position.x -= float(u.grid_width); }

    particles[id] = p;
}

// 落地→CA 沉积：碰到窗口 floor 或下方有占用 → 往 CA 网格写一个 snow cell（携带
// 粒子 size 作 rb 尺寸种子）+ 粒子回收到顶。让 CA 接管堆积/相变/平衡（H1）。
// FS_SNOW=2 与 FallingSandKernels 一致。
kernel void fs_particle_land(
    device SnowParticle* particles         [[buffer(0)]],
    device uint* cells                     [[buffer(1)]],
    const device uchar* occlusion          [[buffer(2)]],
    constant FSParticleUniforms& u         [[buffer(3)]],
    const device uint* column_depth        [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particle_count) return;
    SnowParticle p = particles[id];
    if (p.alive == 0u) return;

    int w = int(u.grid_width), h = int(u.grid_height);
    int cx = int(p.position.x), cy = int(p.position.y);
    if (cx < 0) { cx = 0; } if (cx >= w) { cx = w - 1; }
    if (cy < 0) { cy = 0; } if (cy >= h) { cy = h - 1; }

    bool isSplash   = (p.kind == 2u);
    bool isMainRain = (p.kind == 1u);

    // 落地：到屏幕底 / 下方是窗口（遮挡）/ 下方有雪/水。2D 遮挡：悬浮窗下方开阔地照常落地。
    bool landed = false;
    if (cy <= 0) { landed = true; }                                  // 屏幕底
    else if (occlusion[(cy - 1) * w + cx] != 0u) { landed = true; }  // 下方是窗口顶
    else if ((cells[(cy - 1) * w + cx] & 0xFFu) != 0u) { landed = true; }  // 下方有雪/水

    // splash 水花：上升中无视落地（否则会立刻落回刚溅起的水里）；下落触地 → 消亡，
    // 不沉积、不二次溅（纯视觉水花，真正的水洼扩散交给已沉积 water cell 的漫流）。
    if (isSplash) {
        if (landed && p.velocity.y <= 0.0) { p.alive = 0u; particles[id] = p; }
        return;
    }

    if (!landed) { return; }

    // 硬上限：列深达上限 → 拒绝沉积（只对雪封顶；水会漫流不堆积，不封）。
    bool capped = (!isMainRain) && (column_depth[cx] >= u.max_column_depth);
    // 沉积。只写空 cell + 未封顶 + 当前 cell 不在窗口内（occlusion=0）。
    if (!capped && occlusion[cy * w + cx] == 0u && (cells[cy * w + cx] & 0xFFu) == 0u) {
        uint ra = (p.seed >> 3) & 0xFFu;
        if (isMainRain) {
            cells[cy * w + cx] = 3u | (ra << 8);                     // FS_WATER → 漫流成水洼
        } else {
            uint rb = uint(clamp(p.size * 28.0, 0.0, 255.0));        // size→尺寸种子
            cells[cy * w + cx] = 2u | (ra << 8) | (rb << 16);        // FS_SNOW
        }
    }

    // 主雨落地：先沉积水（上面已做），再按概率把自己转成一颗 splash 水花
    // —— 横飞 + 轻微上抛、弧线消亡、不再沉积；余下直接死亡。
    if (isMainRain) {
        float roll = fsp_hash_unit(p.seed, u.frame_index ^ 0x9E3779B1u);
        if (roll < u.splash_probability) {
            float rx = fsp_hash_unit(p.seed * 2654435761u, u.frame_index);        // 横向方向/速度
            float ry = fsp_hash_unit(p.seed ^ 0x85EBCA6Bu, u.frame_index + 1u);   // 上抛速度
            p.kind = 2u;                                  // → splash 水花
            p.position.x = float(cx) + 0.5;
            p.position.y = float(cy) + 1.2;               // 略高于落点，避免本帧再判落地
            p.velocity.x = (rx - 0.5) * 44.0;             // ±22 cell/s 横向扩散
            p.velocity.y = 9.0 + ry * 13.0;              // 9..22 cell/s 轻微上抛（贴地水花，非弹跳）
            p.size = max(p.size * 0.75, 0.45);            // 水花更小
            particles[id] = p;
            return;
        }
    }

    // 落地 → 粒子死亡（混合架构关键：不回收到顶，否则飞行粒子涨到容量上限 +
    // 列满后回收堆在顶部 = 顶部越堆越密。死亡后由 emit 按速率补充，存活数自然平衡）。
    p.alive = 0u;
    particles[id] = p;
}
"""
}
