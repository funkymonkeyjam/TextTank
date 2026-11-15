// SPDX-License-Identifier: GPL-3.0-or-later
// Strict offline renderer for the original Carbon Caret SVG; no application launch.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct Shape {
    let rect: CGRect?
    let path: CGPath?
    let rgb: UInt32
    var color: CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
final class Source: NSObject, XMLParserDelegate {
    var shapes: [Shape] = []
    var error: Error?
    private let allowed: [String: Set<String>] = [
        "svg": ["xmlns", "width", "height", "viewBox", "role", "aria-labelledby", "style"],
        "title": ["id"], "g": ["id", "data-part"],
        "rect": ["x", "y", "width", "height", "fill"], "path": ["fill", "d"]
    ]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        do {
            guard let accepted = allowed[name], Set(attributes.keys).isSubset(of: accepted) else {
                throw IconError(message: "Unsupported SVG element or attribute: \(name)")
            }
            switch name {
            case "svg":
                guard attributes["viewBox"] == "0 0 128 128",
                      attributes["style"] == nil || attributes["style"] == "color:#15201F" else {
                    throw IconError(message: "Expected selected 128-square SVG viewBox and supported root style")
                }
            case "g", "title": break
            case "rect":
                guard let x = Double(attributes["x"] ?? "0"), x.isFinite,
                      let y = Double(attributes["y"] ?? "0"), y.isFinite,
                      let width = Double(attributes["width"] ?? ""), width.isFinite, width >= 0,
                      let height = Double(attributes["height"] ?? ""), height.isFinite, height >= 0 else {
                    throw IconError(message: "Invalid rectangle coordinates")
                }
                shapes.append(Shape(rect: CGRect(x: x, y: y, width: width, height: height),
                                    path: nil, rgb: try color(attributes["fill"])))
            case "path":
                shapes.append(Shape(rect: nil, path: try path(attributes["d"] ?? ""),
                                    rgb: try color(attributes["fill"])))
            default: throw IconError(message: "Unsupported SVG element: \(name)")
            }
        } catch {
            self.error = error
            parser.abortParsing()
        }
    }
    func color(_ value: String?) throws -> UInt32 {
        guard let value, value.utf8.count == 7, value.first == "#",
              value.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let rgb = UInt32(value.dropFirst(), radix: 16) else {
            throw IconError(message: "Only explicit six-digit RGB fills are supported")
        }
        return rgb
    }
    func path(_ data: String) throws -> CGPath {
        let pattern = try NSRegularExpression(pattern: "[MHVZ]|-?[0-9]+(?:\\.[0-9]+)?")
        let matches = pattern.matches(in: data, range: NSRange(data.startIndex..., in: data))
        let tokens = try matches.map { match -> String in
            guard let range = Range(match.range, in: data) else { throw IconError(message: "Invalid path range") }
            return String(data[range])
        }
        let stripped = pattern.stringByReplacingMatches(in: data, range: NSRange(data.startIndex..., in: data), withTemplate: "")
        guard stripped.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "," }) else {
            throw IconError(message: "Unsupported SVG path syntax")
        }
        let result = CGMutablePath()
        var index = 0
        var point = CGPoint.zero
        var start: CGPoint?
        func number() throws -> CGFloat {
            guard index < tokens.count, let value = Double(tokens[index]), value.isFinite else {
                throw IconError(message: "Missing or invalid path coordinate")
            }
            index += 1
            return CGFloat(value)
        }
        while index < tokens.count {
            let command = tokens[index]
            index += 1
            switch command {
            case "M":
                point = CGPoint(x: try number(), y: try number())
                start = point
                result.move(to: point)
            case "H":
                guard start != nil else { throw IconError(message: "Path must begin with M") }
                point.x = try number()
                result.addLine(to: point)
            case "V":
                guard start != nil else { throw IconError(message: "Path must begin with M") }
                point.y = try number()
                result.addLine(to: point)
            case "Z":
                guard let start else { throw IconError(message: "Path must begin with M") }
                result.closeSubpath()
                point = start
            default: throw IconError(message: "Unsupported path command \(command)")
            }
        }
        guard !result.isEmpty else { throw IconError(message: "Empty icon path") }
        return result
    }
}

func render(_ arguments: [String]) throws {
    let source = Source()
    let parser = XMLParser(data: try Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    parser.delegate = source
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), source.error == nil, !source.shapes.isEmpty else {
        throw source.error ?? parser.parserError ?? IconError(message: "Empty icon source")
    }
    let iconset = URL(fileURLWithPath: arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw IconError(message: "No sRGB color space") }
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                          bytesPerRow: pixels * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw IconError(message: "Cannot create raster context")
            }
            context.translateBy(x: 0, y: CGFloat(pixels))
            context.scaleBy(x: CGFloat(pixels) / 128, y: -CGFloat(pixels) / 128)
            for shape in source.shapes {
                context.setFillColor(shape.color)
                if let rect = shape.rect { context.fill(rect) }
                if let path = shape.path { context.addPath(path); context.fillPath() }
            }
            // Opaque interior pixels avoid antialiasing. Compare with parsed RGB, not CGColor conversion.
            guard let data = context.data else { throw IconError(message: "No bitmap bytes") }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            let samples: [(Int, Int)] = [(4, 4), (40, 72), (88, 72)]
            guard source.shapes.count == samples.count else { throw IconError(message: "Selected icon must have three shapes") }
            for (shape, sample) in zip(source.shapes, samples) {
                let offset = Int(Double(sample.1) * Double(pixels) / 128) * context.bytesPerRow
                    + Int(Double(sample.0) * Double(pixels) / 128) * 4
                let actual = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
                guard actual == shape.rgb else { throw IconError(message: "Icon pixel color differs from SVG RGB at \(pixels) pixels") }
            }
            guard let image = context.makeImage() else { throw IconError(message: "Cannot make raster image") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            bitmap.size = NSSize(width: size, height: size)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw IconError(message: "PNG encoding failed") }
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try png.write(to: iconset.appendingPathComponent(name), options: .atomic)
        }
    }
    let destinationURL = URL(fileURLWithPath: arguments[3])
    guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.icns.identifier as CFString, 10, nil) else {
        throw IconError(message: "Cannot create ICNS destination")
    }
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            guard let imageSource = CGImageSourceCreateWithURL(iconset.appendingPathComponent(name) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw IconError(message: "Cannot decode generated raster")
            }
            let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
    }
    guard CGImageDestinationFinalize(destination) else { throw IconError(message: "ImageIO ICNS encoding failed") }
    print("Built conventional ICNS with exact SVG RGB at 16–1024 pixels.")
}

let arguments = CommandLine.arguments
if arguments.count != 4 {
    FileHandle.standardError.write(Data("Usage: build-icon SOURCE.svg OUTPUT.iconset OUTPUT.icns\n".utf8))
    exit(64)
}
do {
    try render(arguments)
} catch {
    FileHandle.standardError.write(Data("Icon generation stopped: \(error.localizedDescription)\n".utf8))
    exit(1)
}
