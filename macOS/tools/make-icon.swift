// Convert the original ICO artwork at build time. Keep the hand-sized small images.
import AppKit
import ImageIO

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
    fatalError("Cannot open " + input.path)
}

var frames: [Int: CGImage] = [:]
for index in 0..<CGImageSourceGetCount(source) {
    if let frame = CGImageSourceCreateImageAtIndex(source, index, nil), frame.width == frame.height {
        frames[frame.width] = frame
    }
}
guard let largest = frames.keys.max() else { fatalError("No square images in ICO") }
let resources = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)

func bitmap(_ pixels: Int) -> CGContext {
    CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
              bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ frame: CGImage, pixels: Int, artworkPixels: Int, verticalOffset: Int = 0, to file: URL) {
    let context = bitmap(pixels)
    let origin = CGFloat(pixels - artworkPixels) / 2
    context.interpolationQuality = .high
    context.draw(frame, in: CGRect(x: origin, y: origin + CGFloat(verticalOffset), width: CGFloat(artworkPixels), height: CGFloat(artworkPixels)))
    guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("Cannot create " + file.path) }
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write " + file.path) }
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        // Center the legacy ICNS tile on a transparent macOS icon canvas.
        let inset = Int((CGFloat(pixels) * 100 / 1024).rounded())
        let tile = pixels - 2 * inset
        let size = frames.keys.filter { $0 >= tile }.min() ?? largest
        let suffix = scale == 2 ? "@2x" : ""
        let file = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        writePNG(frames[size]!, pixels: pixels, artworkPixels: tile, to: file)
    }
}

// The ICO uses a green plate (#74DD7C) and a dark violet bolt. Recover the
// bolt's coverage from the premultiplied green channel, including its soft edge.
let mask = bitmap(largest)
mask.draw(frames[largest]!, in: CGRect(x: 0, y: 0, width: largest, height: largest))
let rgba = mask.data!.assumingMemoryBound(to: UInt8.self)
for pixel in stride(from: 0, to: largest * largest * 4, by: 4) {
    let alpha = Int(rgba[pixel + 3])
    let contrast = 221 * alpha - 255 * Int(rgba[pixel + 1])
    rgba[pixel + 3] = UInt8(clamping: min(alpha, max(0, contrast / (221 - 60))))
    rgba[pixel] = 0
    rgba[pixel + 1] = 0
    rgba[pixel + 2] = 0
}
for scale in [1, 2] {
    let suffix = scale == 2 ? "@2x" : ""
    let file = resources.appendingPathComponent("MenuBarTemplate\(suffix).png")
    // The wide upper stroke puts the ink center one point above the canvas center.
    writePNG(mask.makeImage()!, pixels: 18 * scale, artworkPixels: 16 * scale, verticalOffset: -scale, to: file)
}
