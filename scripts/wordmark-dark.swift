// Derives the dark-background wordmark from the light one: the graphite lettering becomes off-white and the deep
// blue emblem is lightened so it reads on dark backgrounds (GitHub's dark theme). Window dots and edges keep their
// colour and alpha.
//
//   xcrun swift scripts/wordmark-dark.swift assets/branding/macmcp-wordmark-light.png assets/branding/macmcp-wordmark-dark.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: wordmark-dark.swift LIGHT.png DARK.png"); exit(2)
}
let w = image.width, h = image.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

let text: (Double, Double, Double) = (232, 234, 238)   // off-white lettering
let lighten = 0.35                                     // share of white mixed into the blue
for i in stride(from: 0, to: px.count, by: 4) {
    let a = Double(px[i + 3])
    guard a > 0 else { continue }
    // Unpremultiply, recolour, premultiply again.
    var (r, g, b) = (Double(px[i]) * 255 / a, Double(px[i + 1]) * 255 / a, Double(px[i + 2]) * 255 / a)
    let hi = max(r, g, b), lo = min(r, g, b)
    if hi - lo < 50 && hi < 140 {
        (r, g, b) = text
    } else if b > r + 60 && b > g + 60 {
        (r, g, b) = (r + (255 - r) * lighten, g + (255 - g) * lighten, b + (255 - b) * lighten)
    } else {
        continue
    }
    px[i] = UInt8(min(255, (r * a / 255).rounded()))
    px[i + 1] = UInt8(min(255, (g * a / 255).rounded()))
    px[i + 2] = UInt8(min(255, (b * a / 255).rounded()))
}

let out = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)!
guard let result = out.makeImage(),
      let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
    print("encoding failed"); exit(1)
}
try png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) (\(w)x\(h))")
