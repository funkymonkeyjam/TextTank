// SPDX-License-Identifier: GPL-3.0-or-later
// Deliberately strict renderer for the selected original Carbon Caret SVG.
// The source uses only solid rects and absolute M/H/V/Z paths. Unsupported
// constructs fail instead of silently changing the production artwork.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconError: LocalizedError { let message: String; var errorDescription: String? { message } }
struct Shape { let rect: CGRect?; let path: CGPath?; let color: CGColor }
final class Source: NSObject, XMLParserDelegate {
    var shapes: [Shape] = []; var error: Error?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        do {
            switch name {
            case "svg":
                guard attributes["viewBox"] == "0 0 128 128" else { throw IconError(message:"Expected selected 128-square SVG viewBox") }
            case "g": guard attributes["transform"] == nil else { throw IconError(message:"Transformed groups unsupported") }
            case "title": break
            case "rect":
                guard attributes["rx"] == nil, attributes["ry"] == nil, let w = Double(attributes["width"] ?? ""), let h = Double(attributes["height"] ?? "") else { throw IconError(message:"Unsupported rect") }
                shapes.append(Shape(rect:CGRect(x:Double(attributes["x"] ?? "0")!,y:Double(attributes["y"] ?? "0")!,width:w,height:h),path:nil,color:try color(attributes["fill"])))
            case "path": shapes.append(Shape(rect:nil,path:try path(attributes["d"] ?? ""),color:try color(attributes["fill"])))
            default: throw IconError(message:"Unsupported SVG element: \(name)")
            }
        } catch { self.error = error; parser.abortParsing() }
    }
    func color(_ value: String?) throws -> CGColor {
        guard let value, value.count == 7, value.first == "#", let rgb = UInt32(value.dropFirst(),radix:16) else { throw IconError(message:"Only explicit RGB fills supported") }
        return CGColor(red:CGFloat((rgb >> 16)&255)/255,green:CGFloat((rgb >> 8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
    }
    func path(_ data: String) throws -> CGPath {
        let pattern = try NSRegularExpression(pattern:"[MHVZ]|-?[0-9]+(?:\\.[0-9]+)?")
        let matches = pattern.matches(in:data,range:NSRange(data.startIndex...,in:data))
        let tokens = matches.map { String(data[Range($0.range,in:data)!]) }
        let stripped = pattern.stringByReplacingMatches(in:data,range:NSRange(data.startIndex...,in:data),withTemplate:"").replacingOccurrences(of:" ",with:"").replacingOccurrences(of:",",with:"")
        guard stripped.isEmpty else { throw IconError(message:"Unsupported SVG path syntax") }
        let result = CGMutablePath(); var i=0; var point=CGPoint.zero
        func number() throws -> CGFloat { guard i < tokens.count, let n=Double(tokens[i]) else { throw IconError(message:"Missing path coordinate") }; i += 1; return CGFloat(n) }
        while i < tokens.count {
            let command=tokens[i]; i += 1
            switch command {
            case "M": point=CGPoint(x:try number(),y:try number());result.move(to:point)
            case "H": point.x=try number();result.addLine(to:point)
            case "V": point.y=try number();result.addLine(to:point)
            case "Z": result.closeSubpath()
            default: throw IconError(message:"Unsupported path command \(command)")
            }
        }
        return result
    }
}
let args=CommandLine.arguments
guard args.count == 4 else { throw IconError(message:"Usage: build-icon SOURCE.svg OUTPUT.iconset OUTPUT.icns") }
let source=Source();let parser=XMLParser(data:try Data(contentsOf:URL(fileURLWithPath:args[1])));parser.delegate=source
guard parser.parse(),source.error == nil,source.shapes.count == 3 else { throw source.error ?? IconError(message:"Invalid selected icon source") }
let iconset=URL(fileURLWithPath:args[2],isDirectory:true)
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let colorSpace=CGColorSpace(name:CGColorSpace.sRGB)!
        guard let context=CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:pixels*4,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw IconError(message:"Cannot create raster context") }
        // SVG has top-left origin; CoreGraphics bitmap uses bottom-left.
        context.translateBy(x:0,y:CGFloat(pixels));context.scaleBy(x:CGFloat(pixels)/128,y:-CGFloat(pixels)/128)
        for shape in source.shapes {
            context.setFillColor(shape.color)
            if let rect=shape.rect { context.fill(rect) }
            if let path=shape.path { context.addPath(path);context.fillPath() }
        }
        let bitmap=NSBitmapImageRep(cgImage:context.makeImage()!)
        bitmap.size = NSSize(width: size, height: size)
        guard let png=bitmap.representation(using:.png,properties:[:]) else { throw IconError(message:"PNG encoding failed") }
        let name="icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to:iconset.appendingPathComponent(name),options:.atomic)
    }
}
let destinationURL = URL(fileURLWithPath: args[3])
guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.icns.identifier as CFString, 10, nil) else { throw IconError(message:"Cannot create ICNS destination") }
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let imageSource = CGImageSourceCreateWithURL(iconset.appendingPathComponent(name) as CFURL,nil)!
        let properties: [CFString:Any] = [kCGImagePropertyDPIWidth:72 * scale,kCGImagePropertyDPIHeight:72 * scale]
        CGImageDestinationAddImage(destination,CGImageSourceCreateImageAtIndex(imageSource,0,nil)!,properties as CFDictionary)
    }
}
guard CGImageDestinationFinalize(destination) else { throw IconError(message:"ImageIO ICNS encoding failed") }
print("Built conventional ICNS from the selected SVG source at 16–1024 pixels.")
