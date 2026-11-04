import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let size = base * multiplier
        let scale = CGFloat(size) / 1024
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.addPath(CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864),
                               cornerWidth: 195, cornerHeight: 195, transform: nil))
        context.clip()
        let colors = [CGColor(red: 0.07, green: 0.12, blue: 0.23, alpha: 1),
                      CGColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 950), end: CGPoint(x: 900, y: 50), options: [])
        let points = [CGPoint(x: 225, y: 480), CGPoint(x: 350, y: 480), CGPoint(x: 420, y: 690),
                      CGPoint(x: 520, y: 315), CGPoint(x: 600, y: 565), CGPoint(x: 650, y: 480), CGPoint(x: 800, y: 480)]
        context.setLineCap(.round); context.setLineJoin(.round)
        context.setStrokeColor(CGColor(red: 0.12, green: 0.56, blue: 1, alpha: 1))
        context.setLineWidth(54); context.addLines(between: points); context.strokePath()
        let image = context.makeImage()!
        let name = "icon_\(base)x\(base)\(multiplier == 2 ? "@2x" : "").png"
        let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
    }
}
