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
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let size = frames.keys.filter { $0 >= pixels }.min() ?? largest
        let frame = frames[size]!
        let suffix = scale == 2 ? "@2x" : ""
        let file = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)
        else { fatalError("Cannot create " + file.path) }
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write " + file.path) }
    }
}
