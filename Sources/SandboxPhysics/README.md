# SandboxPhysics

> 形象无关的 **GPU 物理沙盒** —— 基于 **falling-sand 元胞自动机**的统一天气/材质模拟器,零业务依赖(只 `import Metal / simd / Foundation`),可被任意 macOS + Metal 项目单独复用。

**一套引擎,多种材质**:雪 / 雨 / 水 / 冰 / 汽 全是同一个 falling-sand 引擎里的 **species**,共享重力、堆积、漫流、相变、升华、温度耦合 —— 不是「雪引擎 + 雨引擎」两套,而是一套 CA 跑全部降水/材质:

- **雪** = `kind 0` 飞行浮点粒子 → 落地沉积 snow cell → 堆积成坡、升华平衡
- **雨** = `kind 1` 飞行 water 粒子 → 落地沉积 water cell → 漫流成水洼、温度耦合(冷天冻 ice / 热天蒸发 steam)、落地按概率溅 `kind 2` splash 水花

实现完全同源(同一个 `FallingSandParticles.emitTop(kind:)` + 同一个 CA 网格),靠 `kind` 区分。

## 要求

- macOS 13+ · Swift 5.9+
- 一个可用的 `MTLDevice`（headless / 无 GPU 环境下各 `init?` / `make` 返回 `nil`,调用方据此优雅降级）

## 安装

```swift
// Package.swift
.package(url: "https://github.com/iuin8/pet-agent-vivarium", from: "0.3.0")

// target 依赖（只取物理库这一块）
.product(name: "SandboxPhysics", package: "pet-agent-vivarium")
```

```swift
import SandboxPhysics
```

---

## FallingSand —— 雪/水/冰/汽 元胞自动机

两层 API:`FallingSandDriver`（高层,推荐;混合飞行粒子 + CA,一帧全编排）与 `FallingSandGPUEngine`（低层 CA 内核,要自己管粒子时用）。

### 快速上手（高层 `FallingSandDriver`）

`FallingSandDriver` 是 `@MainActor`。宿主负责创建 `MTLDevice` / `MTLCommandQueue` / drawable,并每帧喂入天气状态 + 遮挡,再把一个 command buffer + render pass 交给 `tick`：

```swift
import Metal
import SandboxPhysics

// 宿主创建 GPU 资源
let device = MTLCreateSystemDefaultDevice()!
let queue  = device.makeCommandQueue()!

// 创建驱动器(自动建 engine + 粒子 + 两条渲染管线)。失败返回 nil。
guard let driver = FallingSandDriver(
    device: device, queue: queue,
    gridWidth: 640, gridHeight: 360,        // cell 网格尺寸(= 像素 / cellSize)
    pixelFormat: .bgra8Unorm
) else { return }

// 每帧:① 写状态 ② tick(交付 command buffer + render pass)
func renderFrame(into commandBuffer: MTLCommandBuffer,
                 renderPass: MTLRenderPassDescriptor,
                 dt: Float) {
    driver.spawnSnow = true                  // 开降雪(kind 0 粒子)
    driver.spawnRain = false                 // 开降雨(kind 1 = water 粒子,落地漫流成水洼)
    driver.ambientTemperature = 0.3          // 环境温度 0..1(冷→雪留存 / 暖→融成水)
    driver.tuning.windStrength = 2.0         // 物理参数热调
    driver.pendingRects = [                   // 窗口/障碍遮挡矩形(cell 坐标, y=0 在底)
        FSRect(x: 80, y: 0, w: 120, h: 40)
    ]

    driver.tick(commandBuffer: commandBuffer, renderPassDescriptor: renderPass, dt: dt)
    // 宿主随后 commandBuffer.present(drawable) + commit()
}

// 切天气 / 收场
driver.clear()   // 清空网格 + 飞行粒子 + 停 spawn
```

`tick` 内部一帧完整编排:上传遮挡 → 发射粒子 → 积分 → 落地沉积到 CA → CA step（重力 / 漫流 / 相变 / 升华平衡）→ 渲染（连续雪面 + 飞行粒子 同一 render pass）。全程 GPU 开销实测 < 3 ms（1px 分辨率）。

### 遮挡输入（通用,可选）

雪可以被任意形状挡住 / 堆积其上。有两种遮挡输入,都是**可选**的（不设即无遮挡）:

- **矩形遮挡** `driver.pendingRects: [FSRect]?` —— axis-aligned 矩形（窗口、平台等），引擎每帧栅格化成逐 cell mask。
- **alpha 轮廓遮挡** `driver.pendingPetOccluder: PetOccluderFrame?` —— 精确轮廓（行主序 `[UInt8]` alpha,row 0 = 顶部），雪会堆在它轮廓顶、内部每帧清除。`nil` 即禁用。

```swift
driver.pendingPetOccluder = FallingSandDriver.PetOccluderFrame(
    mask: alphaBytes,            // [UInt8](w*h),行主序,row0=顶
    width: 128, height: 128,
    originCellX: 200, originCellY: 60   // 轮廓左下角在 cell 坐标系的原点
)
```

> 命名里的 `Pet` 是这套引擎最初的来源场景（桌宠轮廓挡雪）。对引擎而言它只是「一张任意 alpha 轮廓」—— 你喂什么形状,雪就堆在什么形状上,引擎不关心它是不是桌宠。

### 物理调参 `FallingSandTuning`

`Equatable & Sendable & Codable`（可直接持久化到 `UserDefaults`），`driver.tuning` 每帧 apply。关键参数:

| 参数 | 类型 | 作用 |
|---|---|---|
| `snowEmitPerFrame` | `Int` | 每帧发射飞行雪粒子数（降雪密度 + 积雪速度主因子） |
| `gravity` | `Float` | 重力加速度（cell/s²） |
| `windStrength` | `Float` | 风力基础值（kernel 叠空间 + 时间噪声出阵风） |
| `meltThreshold` / `freezeThreshold` | `Float` | 融化 / 冻结温度阈值（归一化 0..1） |
| `meltRatePerSec` / `evaporateRatePerSec` | `Float` | 融化（雪→水）/ 蒸发（水→汽）速率 |
| `snowSublimatePerSec` | `Float` | 升华基础概率/秒（孤立雪缓慢消失） |
| `snowDepthSublimateCoeff` | `Float` | 升华深度系数 k —— 稳态雪深 h\* = √(S/k),调大→浅、调小→厚 |
| `maxColumnDepth` | `Int` | 每列积雪硬上限（cell,防 runaway） |
| `splashProbability` | `Float` | 雨滴落地溅水花概率 |
| `wetnessBaseline` | `Float` | 不下雨时积水洼湿亮基线 |
| `ambientOverride` | `Float` | 调试用环境温度覆盖（< 0 = 关闭,用传入值） |

### 元素 `FallingSandSpecies`

`enum: UInt8` —— `empty` / `wall` / `snow` / `water` / `ice` / `steam`。雪下落+升华、水下落+漫流+融蒸、冰静止参与融冻、汽反重力上升。

### 低层 / CPU 参考

- **`FallingSandGPUEngine`** —— 纯 CA 内核（自己管粒子时用）:`init?(device:queue:width:height:)` → `uploadTemperatures(_:)` / `fillTemperature(_:)` / `spawnTopRow(_:fillRatio:)` / `uploadRects(_:)` / `uploadPetMask(_:originCellX:originCellY:w:h:)` / `step(dt:)`,渲染读 `cellBufferForRender: MTLBuffer`。
- **`FallingSandSimulation`** —— 纯 CPU 参考实现（`init(width:height:seed:)` / `step(dt:temperatures:)` / `stepMovementOnly()`），与 GPU 逐格对拍,可做确定性单测,也可当无 GPU 环境的 fallback。

---

## 责任边界（宿主 vs 引擎）

| 宿主（AppKit / MTKView / 你的 app） | SandboxPhysics |
|---|---|
| 创建 `MTLDevice` / `MTLCommandQueue` / drawable / `MTKView` | CA / 粒子的全部 GPU compute + render 编码 |
| 每帧喂天气状态（spawn flags / 温度 / 风） | 重力 / 漫流 / 相变 / 升华 / 溅射 物理 |
| 每帧喂遮挡（窗口矩形 / alpha 轮廓） | 栅格化遮挡 + 落地碰撞 + 列深封顶 |
| `commandBuffer.present(drawable)` + `commit()` | 单 render pass 出图（连续面 + 粒子实例） |

引擎只产 GPU 命令与可读 buffer,不碰窗口 / 不知「桌宠」/ 不知「天气从哪来」—— 平台与业务全在宿主侧。

## 许可

[Apache License 2.0](../../LICENSE)。clean-room Swift 实现;falling-sand 思路致谢见 [NOTICE](../../NOTICE)（sandspiel / Snowfall / plasmasnow 等）。
