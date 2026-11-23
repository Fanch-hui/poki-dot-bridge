import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: RenderDotAppIcon.swift <output.png>")
}

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Unable to create app icon")
}

context.setFillColor(CGColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setFillColor(CGColor(srgbRed: 186 / 255, green: 193 / 255, blue: 211 / 255, alpha: 1))
let diameter: CGFloat = 568
let center = CGFloat(size) / 2
let hole = diameter * (31.6797 / 80.0781)
context.addEllipse(in: CGRect(x: center - diameter / 2, y: center - diameter / 2, width: diameter, height: diameter))
context.addEllipse(in: CGRect(x: center - hole / 2, y: center - hole / 2, width: hole, height: hole))
context.drawPath(using: .eoFill)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil
      ) else {
    fatalError("Unable to write app icon")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to finish app icon")
}
