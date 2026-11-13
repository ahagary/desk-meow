import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 7,
      let x = Int(CommandLine.arguments[3]), let y = Int(CommandLine.arguments[4]),
      let width = Int(CommandLine.arguments[5]), let height = Int(CommandLine.arguments[6]) else {
    fputs("usage: extract_png input.png output.png x y width height\n", stderr)
    exit(2)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      x >= 0, y >= 0, width > 0, height > 0,
      x + width <= image.width, y + height <= image.height,
      let crop = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)),
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.png.identifier as CFString, 1, nil
      ) else {
    fputs("could not crop PNG\n", stderr)
    exit(3)
}
CGImageDestinationAddImage(destination, crop, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("could not write PNG\n", stderr)
    exit(4)
}
