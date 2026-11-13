import Foundation
import ImageIO
import CoreGraphics

// Read-only alpha inspection. Does not resample or change the generated art.
let args = CommandLine.arguments
guard args.count == 4, let columns = Int(args[2]), let rows = Int(args[3]), columns > 0, rows > 0 else {
    fputs("usage: inspect_atlas <png> <columns> <rows>\n", stderr)
    exit(1)
}
let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let width = image.width, height = image.height
let fw = width / columns, fh = height / rows
var bytes = [UInt8](repeating: 0, count: width * height * 4)
bytes.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}
func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
var cells: [[String: Any]] = []
for index in 0..<(columns * rows) {
    let ox = (index % columns) * fw, oy = (index / columns) * fh
    var minX = fw, minY = fh, maxX = 0, maxY = 0, opaque = 0
    for y in 0..<fh { for x in 0..<fw { if alpha(ox + x, oy + y) > 20 {
        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y); opaque += 1
    } } }
    cells.append(["index": index, "sourceRect": [ox, oy, fw, fh],
                  "boundsAlpha20": [minX, minY, maxX, maxY], "visiblePixels": opaque])
}
var paddingMaxAlpha: UInt8 = 0
for y in 0..<height { for x in 0..<width {
    if x >= columns * fw || y >= rows * fh { paddingMaxAlpha = max(paddingMaxAlpha, alpha(x, y)) }
} }
let report: [String: Any] = ["image": args[1], "size": [width, height], "cell": [fw, fh],
    "columns": columns, "rows": rows, "paddingMaxAlpha": paddingMaxAlpha,
    "cornerAlpha": [alpha(0,0),alpha(width-1,0),alpha(0,height-1),alpha(width-1,height-1)], "frames": cells]
let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(data: output, encoding: .utf8)!)
