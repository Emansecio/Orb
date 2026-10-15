// Finishes a snapshot for the README: crops it, rounds its corners, draws a hairline and a soft shadow around it and,
// with --backdrop, sets it on the indigo glow of the welcome screen. Used by scripts/readme-shots.sh.
//
//   swift scripts/readme-frame.swift in.png out.png [--crop x,y,w,h] [--width 1600] [--backdrop]
//
// Pixel values are in the snapshot's own pixels (snapshots are drawn at 2x).
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("uso: readme-frame.swift in.png out.png [--crop x,y,w,h] [--width N] [--backdrop]\n".utf8))
    exit(1)
}
func value(_ flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}
let backdrop = arguments.contains("--backdrop")
let maxWidth = value("--width").flatMap(Double.init) ?? 1600

guard let source = NSImage(contentsOfFile: arguments[0])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("não li \(arguments[0])\n".utf8))
    exit(1)
}
var image = source
if let crop = value("--crop")?.split(separator: ",").compactMap({ Double($0) }), crop.count == 4,
   let cropped = source.cropping(to: CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])) {
    image = cropped
}

// Everything below is in output pixels: the picture is scaled down to fit `maxWidth` with its frame.
let margin: CGFloat = backdrop ? 96 : 56
let fit = min(1, (maxWidth - 2 * margin) / CGFloat(image.width))
let picture = CGSize(width: (CGFloat(image.width) * fit).rounded(), height: (CGFloat(image.height) * fit).rounded())
let canvas = CGSize(width: picture.width + 2 * margin, height: picture.height + 2 * margin)
let radius: CGFloat = 22

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                              bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.interpolationQuality = .high

if backdrop {
    // The welcome screen's stage light: indigo glowing from the top, deep night at the bottom, with rounded corners.
    let bounds = CGRect(origin: .zero, size: canvas)
    context.addPath(CGPath(roundedRect: bounds, cornerWidth: 36, cornerHeight: 36, transform: nil))
    context.clip()
    let linear = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.05, green: 0.04, blue: 0.14, alpha: 1),
                                                         CGColor(srgbRed: 0.16, green: 0.12, blue: 0.42, alpha: 1)] as CFArray,
                            locations: [0, 1])!
    context.drawLinearGradient(linear, start: .zero, end: CGPoint(x: 0, y: canvas.height), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.43, green: 0.36, blue: 1, alpha: 0.55),
                                                       CGColor(srgbRed: 0.43, green: 0.36, blue: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    let top = CGPoint(x: canvas.width / 2, y: canvas.height)
    context.drawRadialGradient(glow, startCenter: top, startRadius: 0, endCenter: top, endRadius: canvas.width * 0.6, options: [])
    context.resetClip()
}

let frame = CGRect(origin: CGPoint(x: margin, y: margin), size: picture)
let rounded = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

// The shadow, cast by the rounded shape alone.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: backdrop ? 60 : 44,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: backdrop ? 0.6 : 0.45))
context.addPath(rounded)
context.setFillColor(CGColor(srgbRed: 0.03, green: 0.03, blue: 0.03, alpha: 1))
context.fillPath()
context.restoreGState()

// The picture, clipped to the rounded shape.
context.saveGState()
context.addPath(rounded)
context.clip()
context.draw(image, in: frame)
context.restoreGState()

// A hairline, as macOS draws around a dark window.
context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
context.setLineWidth(1)
context.strokePath()

guard let output = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[1]))
