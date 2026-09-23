// Renders an SVG to PNG at a given size, preserving alpha.
// Usage: swift svg2png.swift <in.svg> <size> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let size = Int(args[2]) else {
    print("usage: swift svg2png.swift <in.svg> <size> <out.png>")
    exit(2)
}

let source = URL(fileURLWithPath: args[1])
guard let image = NSImage(contentsOf: source) else {
    print("FAILED: NSImage could not read \(args[1])")
    exit(1)
}
print("loaded SVG: \(image.size.width)x\(image.size.height) points, reps=\(image.representations.count)")

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    print("FAILED: could not allocate \(size)x\(size) bitmap")
    exit(1)
}
rep.size = NSSize(width: size, height: size)

guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    print("FAILED: could not make a graphics context")
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill(using: .copy)
image.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    from: NSRect(origin: .zero, size: image.size),
    operation: .sourceOver,
    fraction: 1.0
)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    print("FAILED: could not encode PNG")
    exit(1)
}
try png.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3]) (\(png.count) bytes, \(size)x\(size))")
