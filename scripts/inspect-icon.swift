// Structural check for a rendered icon: catches the silent failure where an SVG
// rasterizes to blank or all-white. Usage: swift inspect-icon.swift <file.png>
import AppKit

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff)
else {
    print("FAILED to load")
    exit(1)
}

let width = bitmap.pixelsWide
let height = bitmap.pixelsHigh
var opaque = 0
var total = 0
var red = 0.0, green = 0.0, blue = 0.0

for y in stride(from: 0, to: height, by: 4) {
    for x in stride(from: 0, to: width, by: 4) {
        total += 1
        guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
        if colour.alphaComponent > 0.5 {
            opaque += 1
            red += colour.redComponent
            green += colour.greenComponent
            blue += colour.blueComponent
        }
    }
}

let pct = Double(opaque) / Double(total) * 100
print("size:            \(width)x\(height)")
print("sampled:         \(total) px, opaque \(opaque) (\(String(format: "%.1f", pct))%)")
if opaque > 0 {
    print(String(format: "avg opaque RGB:  %.3f %.3f %.3f", red / Double(opaque), green / Double(opaque), blue / Double(opaque)))
}

// Corner should be transparent (rounded square), centre should be opaque.
let corner = bitmap.colorAt(x: 1, y: 1)?.alphaComponent ?? -1
let centre = bitmap.colorAt(x: width / 2, y: height / 2)?.alphaComponent ?? -1
print(String(format: "corner alpha:    %.2f", corner))
print(String(format: "centre alpha:    %.2f", centre))

let looksRendered = pct > 60 && pct < 99 && centre > 0.9 && corner < 0.1
print(looksRendered ? "VERDICT: rendered correctly" : "VERDICT: SUSPICIOUS — check the artwork")
exit(looksRendered ? 0 : 1)
