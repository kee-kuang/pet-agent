/// 精简 falling-sand GPU uniforms。**全部 4 字节标量**（UInt32/Float），
/// 避免 SIMD 对齐坑；温度是独立 per-cell buffer，不进 uniforms。
/// Swift 端与 `FallingSandKernels.source` 里的 MSL `FallingSandUniforms`
/// 必须字段顺序 + 字节布局逐一对应（stride 测试做闸）。
public struct FallingSandUniforms: Equatable, Sendable {
    public var gridWidth: UInt32
    public var gridHeight: UInt32
    public var frameIndex: UInt32
    public var leftFirst: UInt32          // 1 = 左优先，0 = 右优先（每帧翻转消方向偏置）
    public var passKind: UInt32           // 0 = gravity（含对角/上升），1 = flow（液体横移）
    public var forceSnowFall: UInt32      // 1 = 跳过雪概率门（确定性对拍用）
    public var dt: Float
    public var snowFallProbability: Float
    public var meltThreshold: Float
    public var freezeThreshold: Float
    public var evaporateThreshold: Float
    public var condenseThreshold: Float
    public var meltRatePerSec: Float
    public var freezeRatePerSec: Float
    public var evaporateRatePerSec: Float
    public var condenseRatePerSec: Float
    public var steamDissipatePerSec: Float
    public var steamLifetimeFrames: UInt32
    public var snowSublimatePerSec: Float
    public var windX: Float   // 自然风（带符号，~-1..1）；0 = 无风（确定性，对拍用）
    public var snowDepthSublimateCoeff: Float   // 深度负反馈系数 k（积雪自平衡）
    public var rectCount: UInt32                // 窗口遮挡矩形数（栅格化 kernel 用）
    // pet 第二 occluder（雪堆 pet 身上）。pet 当前帧 alpha 轮廓栅格化进
    // 同一 occlusion buffer，雪精确堆在 pet 轮廓顶上。petEnabled=0 时 fs_rasterize_pet
    // 整个跳过（无雪/无 sprite 形象时零开销）。origin 为带符号 cell 坐标（pet 可部分出屏 → 负）。
    public var petOriginX: Int32                // pet 占位左下角 cell X（世界底原点 y-up）
    public var petOriginY: Int32                // pet 占位左下角 cell Y
    public var petMaskW: UInt32                 // pet mask 宽（cell）
    public var petMaskH: UInt32                 // pet mask 高（cell）
    public var petEnabled: UInt32               // 1 = 栅格化 pet occluder，0 = 跳过

    public init(
        gridWidth: UInt32,
        gridHeight: UInt32,
        frameIndex: UInt32 = 0,
        leftFirst: UInt32 = 1,
        passKind: UInt32 = 0,
        forceSnowFall: UInt32 = 0,
        dt: Float = 1.0 / 30.0,
        snowFallProbability: Float = FallingSandRules.snowFallProbability,
        meltThreshold: Float = FallingSandRules.meltThreshold,
        freezeThreshold: Float = FallingSandRules.freezeThreshold,
        evaporateThreshold: Float = FallingSandRules.evaporateThreshold,
        condenseThreshold: Float = FallingSandRules.condenseThreshold,
        meltRatePerSec: Float = FallingSandRules.meltRatePerSec,
        freezeRatePerSec: Float = FallingSandRules.freezeRatePerSec,
        evaporateRatePerSec: Float = FallingSandRules.evaporateRatePerSec,
        condenseRatePerSec: Float = FallingSandRules.condenseRatePerSec,
        steamDissipatePerSec: Float = FallingSandRules.steamDissipatePerSec,
        steamLifetimeFrames: UInt32 = UInt32(FallingSandRules.steamLifetimeFrames),
        snowSublimatePerSec: Float = FallingSandRules.snowSublimatePerSec,
        windX: Float = 0,
        snowDepthSublimateCoeff: Float = FallingSandRules.snowDepthSublimateCoeff,
        rectCount: UInt32 = 0,
        petOriginX: Int32 = 0,
        petOriginY: Int32 = 0,
        petMaskW: UInt32 = 0,
        petMaskH: UInt32 = 0,
        petEnabled: UInt32 = 0
    ) {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.frameIndex = frameIndex
        self.leftFirst = leftFirst
        self.passKind = passKind
        self.forceSnowFall = forceSnowFall
        self.dt = dt
        self.snowFallProbability = snowFallProbability
        self.meltThreshold = meltThreshold
        self.freezeThreshold = freezeThreshold
        self.evaporateThreshold = evaporateThreshold
        self.condenseThreshold = condenseThreshold
        self.meltRatePerSec = meltRatePerSec
        self.freezeRatePerSec = freezeRatePerSec
        self.evaporateRatePerSec = evaporateRatePerSec
        self.condenseRatePerSec = condenseRatePerSec
        self.steamDissipatePerSec = steamDissipatePerSec
        self.steamLifetimeFrames = steamLifetimeFrames
        self.snowSublimatePerSec = snowSublimatePerSec
        self.windX = windX
        self.snowDepthSublimateCoeff = snowDepthSublimateCoeff
        self.rectCount = rectCount
        self.petOriginX = petOriginX
        self.petOriginY = petOriginY
        self.petMaskW = petMaskW
        self.petMaskH = petMaskH
        self.petEnabled = petEnabled
    }
}
