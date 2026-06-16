import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SandboxPhysics

/// 把网格渲染成 RGBA PNG 落到 /tmp，供人/Claude `Read` 做视觉自评。
/// y=0 在底 → 写图时翻转到图像底部。每 cell 放大 `scale` 像素方块。
enum FallingSandPNG {
    /// 把一块 RGBA8 像素（如离屏渲染 readback）写成 PNG。row 0 在顶（纹理约定）。
    static func writeRGBA(_ px: [UInt8], width: Int, height: Int, to path: String) {
        var data = px
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let url = URL(fileURLWithPath: path)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    static func dump(_ g: FallingSandGrid, to path: String, scale: Int = 6) {
        let w = g.width * scale, h = g.height * scale
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for gy in 0..<g.height {
            for gx in 0..<g.width {
                let s = FallingSandCell.species(g.at(gx, gy))
                let ra = FallingSandCell.ra(g.at(gx, gy))
                let c = FallingSandPalette.shaded(s, ra: ra)
                let imgY = (g.height - 1 - gy)   // 翻转：y=0 到图底
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let x = gx * scale + dx
                        let y = imgY * scale + dy
                        let o = (y * w + x) * 4
                        px[o]     = UInt8(max(0, min(255, c.x * 255)))
                        px[o + 1] = UInt8(max(0, min(255, c.y * 255)))
                        px[o + 2] = UInt8(max(0, min(255, c.z * 255)))
                        px[o + 3] = UInt8(max(0, min(255, c.w * 255)))
                    }
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let url = URL(fileURLWithPath: path)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
