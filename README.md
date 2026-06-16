# Vivarium — PetAgent 桌宠运行时引擎

> **一句话**：Vivarium 是 PetAgent 的**桌宠运行时引擎**（desktop-pet runtime engine）——驱动一只桌面生物「活起来」的全部引擎逻辑：运动物理、行为状态机、资产解析、渲染编排。业务层（AI 助理 / chat / 主动协助 / 设置 UI）在它**之上**依赖它。
>
> 名字取自 *vivarium*（饲养活体生物的容器 / 栖息地）——正是「让桌宠在你屏幕上栖居」的运行时。它是**形象无关**的：Live2D、Codex/petdex sprite、Shimeji 不是各自独立的引擎，而是 Vivarium 下挂的可插拔 **backend / importer**。

## 为什么是独立引擎层

把「引擎」从「业务」切开，换来高内聚、低耦合、可独立演进/开源：

- **引擎**（Vivarium）= 形象无关的运行时：tick、行为、运动、渲染编排、桌面环境抽象。可无头单测（不起窗口）。
- **业务**（PetAgent app：`Orchestrator`/`Shell`/`App`）= AI 对话、主动协助、桌面感知、设置 UI、窗口/事件路由。依赖 Vivarium。

蓝本是 [Shijima-Qt](https://github.com/pixelomer/Shijima-Qt)（Shimeji 引擎的 C++ 无 Java 干净重构）的「独立引擎库 `libshijima` + 薄平台外壳」两段式：引擎只产出纯数据（这一帧画哪张图 + 世界坐标 anchor + 放什么音），渲染/装窗由 host 负责。

## 分层（依赖严格单向向下，禁回指）

```
VivariumCore      纯值类型 + 协议契约(Foundation-only,可无头单测)
  ↑               PetEmotionState / PetMotionPhase·Input·Frame / PetAlphaMask /
  │               SignatureAction / DesktopSnapshot / RenderState·PresentationMapper /
  │               PetRenderer 协议(AppKit-free,只暴露 contentLayer: CALayer) / SpritePackFormat /
  │               Environment(屏幕/floor/ceiling/workArea/activeWindow 边界 + cursor)
  │
VivariumAssets    petdex / Shimeji / Live2D 包解析 + 加载(IO 经协议注入)
  ↑               Shimeji actions.xml/behaviors.xml 解析、CodexSpritePackLoader、
  │               Live2DModelPackLoader、PetCatalog 在线安装、PetLibrary
  │
VivariumMotion    PetMotionController + RuntimeClient 物理 step(运动仲裁 / 漫步 / 爬墙 / perch)
  │
VivariumBehavior  数据驱动行为状态机(加权随机 + 条件门控 + NextBehavior)+ behaviors.xml
  │
VivariumRender    PetRenderer 后端实现(Orb Metal / Sprite CALayer / Slime);Live2D 后端因 Cubism
                  专有 SDK(Vendor/，gitignored)留在宿主侧条件编译,经 PetRenderer 协议接入

SandboxPhysics    旁路独立子系统(deps[]，不在上面单向链里):GPU 物理沙盒 ——
（形象无关，可独立抽出）  FallingSand 统一元胞自动机:雪/雨/水/冰/汽 同一套引擎(雪=kind0、
                  雨=kind1 water 粒子,同源)。Rendering 的 overlay 渲染器消费它;
                  其 occluder 输入是通用可选项,引擎不知「桌宠」。
```

**平台 API 隔离**：AppKit / Accessibility / ScreenCaptureKit / CoreGraphics 一律留在引擎**外**的 host 层（Shell/App），经值类型契约 + 闭包/协议注入喂入（`DesktopSnapshot` 值类型、`RuntimeClient` 协议 + `NoOpRuntimeClient`、`rendererFactory` 注入钩子即范式）。引擎 Core/Assets/Motion/Behavior 保持 Foundation-only。

## Backend / importer（形象插件，非独立引擎）

| 形象 | 类型 | 说明 |
|---|---|---|
| **Orb** | Metal 程序化 | SDF + Fresnel 流光胶质球(内置默认) |
| **Sprite (Codex/petdex)** | CALayer 切帧 | 8×9/8×10 spritesheet,直接吃 codex-pets.net 社区库 |
| **Shimeji** | 导入格式 | `actions.xml` 帧序解析 → 转成 sprite 包(自定义命名帧也能动);多角色包全转 N 个独立包 |
| **Live2D** | Cubism Metal | `.model3.json` 模型;SDK 专有不入库,宿主侧条件编译 |

新形象只需实现 `PetRenderer` 协议(暴露 `contentLayer: CALayer`)+ 经 `PetPluginRegistry` 注册,引擎不 import 具体 backend。

## 机制：独立公开仓库 + 宿主 submodule

Vivarium 作为**独立开源仓库**发布，由 PetAgent 宿主仓以 **git submodule** 挂在 `Packages/Vivarium` 路径下。宿主仍通过 `.package(path: "Packages/Vivarium")` 本地引用其 library product——拿到强制 public product 边界 + 清晰所有权 + 可独立演进/被他人复用，同时本地 `swift build` 仍是全图增量。

引擎对外只暴露 library product（`Context` / `RuntimeBridge` / `SandboxPhysics` / `Rendering` / `ShimejiImport` / `PetCatalog` / `PetBehavior`），平台 API 全部隔离在宿主侧（见下「平台 API 隔离」）。其中 `SandboxPhysics`（GPU 物理沙盒）deps `[]`，是最易被外部项目单独复用的一块。

## 模块

| Target | 职责 |
|---|---|
| `Context` | 桌面环境抽象 + Accessibility/AX 前台窗口桥（值类型契约喂入引擎） |
| `RuntimeBridge` | `PetMotionController` + `RuntimeClient` 物理 step（运动仲裁 / 漫步 / 爬墙 / perch）+ `PresentationMapper`/`RenderState` |
| `SandboxPhysics` | **形象无关的 GPU 物理沙盒**：falling-sand 统一元胞自动机 —— 雪/雨/水/冰/汽 同一套引擎(雪=kind0 粒子、雨=kind1 water 粒子,落地漫流成水洼,同源)，含堆积 + 相变 + 升华深度负反馈 + 温度耦合。deps `[]`，只 Metal/simd/Foundation，可被任意 macOS+Metal 项目复用。**用法文档 → [Sources/SandboxPhysics/README.md](Sources/SandboxPhysics/README.md)** |
| `Rendering` | `PetRenderer` 后端（Orb Metal / Sprite CALayer / Slime / Live2D）+ 托管 sim 的 overlay 渲染器（`MetalSnowOverlayView`） |
| `ShimejiImport` | Shimeji `actions.xml`/`behaviors.xml` 解析 → sprite 包转换 |
| `PetCatalog` | petdex 在线目录浏览 + 一键安装（反 SSRF host 白名单） |
| `PetBehavior` | 数据驱动 Shimeji 行为状态机（加权随机 + 条件门控 + NextBehavior 转移图，JavaScriptCore 条件求值器） |

> **三套物理互不冲突**：桌宠离散刚体（重力/拖拽/爬墙）走 `RuntimeBridge`；Shimeji 脚本积分（Fall/Jump/Dragged）在 `PetBehavior`；GPU 沙盒（雪/雨/水/冰/汽 统一 falling-sand CA）在 `SandboxPhysics`。`SandboxPhysics` 零 Vivarium 依赖、可独立抽出复用；其 occluder（挡雪轮廓）是通用可选输入（nil 即禁用），宿主喂入桌宠轮廓而引擎不知「桌宠」。

## 构建 / 测试

```bash
swift build --package-path Packages/Vivarium     # 或在包根直接 swift build
swift test  --package-path Packages/Vivarium     # 374 测试
```

可选：smoke 测试 `realConfSmoke` 需一个真实 Shimeji 包目录（含 `actions.xml`/`behaviors.xml`），通过环境变量提供；未设则自动跳过：

```bash
export VIVARIUM_TEST_MASCOT_DIR=/path/to/shimeji/DefaultMascot
```

## 许可证

[Apache License 2.0](LICENSE)。Vivarium 是 clean-room 的 Swift 实现，吸收的开源思路与归属见 [NOTICE](NOTICE)。

## 致谢 / Acknowledgements

Vivarium 的设计思路、算法、公式与数据约定吸收自下列开源项目，由我们在 Swift 中**重新实现（逻辑/规范级，未拷贝上游源码）**。完整清单与各自借鉴点见 [NOTICE](NOTICE)。

- **Shimeji 生态** — [Shijima-Qt](https://github.com/pixelomer/Shijima-Qt)（两段式引擎/外壳分层 + subtick 插值蓝本）、[Shimeji-Desktop](https://github.com/DalekCraft2/Shimeji-Desktop)（行为加权抽样 + action 物理公式）、[ShimejiEE-cross-platform](https://github.com/LavenderSnek/ShimejiEE-cross-platform)（actions.xml 两遍式解析）、[VShimeji](https://github.com/Valkryst/VShimeji)（行为频率权重）
- **Sprite / Codex 宠物** — [petdex](https://github.com/crafter-station/petdex)（spritesheet 状态表约定 + 跨工具包格式）
- **生命感 / 交互** — [HermesPet](https://github.com/basionwang-bot/HermesPet)（LifeSigns 呼吸/眨眼 + Markdown 渲染）、[AccountyCat](https://github.com/strjonas/AccountyCat)（主动气泡设计）、[agentpet](https://github.com/ntd4996/agentpet)（应用内浏览/安装 + hook→情绪映射）、[GodotDesktopPet](https://github.com/MeiTozawa/GodotDesktopPet)（mood-weighted 动作选择）
- **物理 / 渲染** — [Snowfall](https://github.com/BarredEwe/Snowfall)（飞行粒子雪）、[plasmasnow](https://github.com/markcapella/plasmasnow)（逐列堆积算法）、[godot](https://github.com/godotengine/godot)（GPU compute pipeline）
