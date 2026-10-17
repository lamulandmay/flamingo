// Renders Flamingo's icons from the same geometry the app draws (FlamingoMarkPath).
//
//   source scripts/env.sh
//   xcrun swiftc -parse-as-library Resources/Assets/make-icon.swift \
//       Sources/FlamingoDesign/FlamingoMarkPath.swift Sources/FlamingoDesign/Squircle.swift -o /tmp/make-icon
//   /tmp/make-icon Resources/Assets
//
// Writes into the given directory:
//   AppIcon.icns                     16–1024, built with iconutil
//   Assets.car                       AppIcon + AccentColor, built with actool (if present)
//   MenuBarIconTemplate.png, @2x     22pt template image of the mark
// Pass --preview <dir> to also write the 1024 PNG and a light/dark Dock mock for review.
// Plan 08 owns. Rerun after any change to the mark.

import AppKit
import CoreGraphics
import SwiftUI

@main
struct MakeIcon {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var preview: URL?
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
            preview = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...(i + 1))
        }
        let out = URL(fileURLWithPath: args.first ?? "Resources/Assets")
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let work = fm.temporaryDirectory.appendingPathComponent("flamingo-icon-\(getpid())")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. iconset → icns
        let iconset = work.appendingPathComponent("AppIcon.iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for (name, px) in iconsetSizes {
            try write(appIcon(px), to: iconset.appendingPathComponent("\(name).png"))
        }
        try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path])

        // 2. Asset catalog with AppIcon and AccentColor → Assets.car
        if let actool = which("actool") {
            let xc = work.appendingPathComponent("Assets.xcassets")
            try writeCatalog(xc, iconset: iconset)
            let partial = work.appendingPathComponent("partial.plist")
            try run(actool, ["--compile", work.path, "--platform", "macosx", "--minimum-deployment-target", "14.0",
                             "--app-icon", "AppIcon", "--accent-color", "AccentColor",
                             "--output-partial-info-plist", partial.path, "--notices", "--warnings", xc.path])
            try? fm.removeItem(at: out.appendingPathComponent("Assets.car"))
            try fm.copyItem(at: work.appendingPathComponent("Assets.car"), to: out.appendingPathComponent("Assets.car"))
        } else {
            print("actool not found; skipped Assets.car (source scripts/env.sh first)")
        }

        // 3. Menu bar template, 22pt
        try write(menuBarTemplate(22), to: out.appendingPathComponent("MenuBarIconTemplate.png"))
        try write(menuBarTemplate(44), to: out.appendingPathComponent("MenuBarIconTemplate@2x.png"))

        if let preview {
            try fm.createDirectory(at: preview, withIntermediateDirectories: true)
            try write(appIcon(1024), to: preview.appendingPathComponent("AppIcon-1024.png"))
            try write(dockMock(), to: preview.appendingPathComponent("AppIcon-dock.png"))
        }
        print("wrote \(out.path)")
    }

    static let iconsetSizes: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    // MARK: Art

    // Coral, a touch lighter at the top. The only gradient in Flamingo.
    static let top = CGColor(srgbRed: 1.00, green: 0.553, blue: 0.588, alpha: 1)      // #FF8D96
    static let bottom = CGColor(srgbRed: 0.918, green: 0.302, blue: 0.408, alpha: 1)  // #EA4D68
    static let bird = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let beakTip = CGColor(srgbRed: 0.20, green: 0.11, blue: 0.14, alpha: 1)    // #331C24

    /// macOS icon grid: an 824pt continuous-curvature squircle centered on a 1024 canvas,
    /// the same Bézier geometry the app uses for every rounded shape.
    static func appIcon(_ px: Int) -> CGImage {
        draw(px, px) { c in
            let k = CGFloat(px) / 1024
            let plate = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
            let radius = 185.4 * k
            let shape = SquircleGeometry.path(in: plate, radius: radius)

            // Plate with its drop shadow.
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k,
                        color: CGColor(gray: 0, alpha: 0.28))
            c.addPath(shape); c.setFillColor(bottom); c.fillPath()
            c.restoreGState()

            c.saveGState()
            c.addPath(shape); c.clip()
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [top, bottom] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
            // Faint inner edge so the plate holds on dark Docks.
            // A concentric line just inside the edge: the plate's outline offset by half the stroke.
            let edge = max(1, 4 * k)
            c.addPath(SquircleGeometry.path(in: plate, radius: radius, offset: edge / 2))
            c.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); c.setLineWidth(edge); c.strokePath()

            // The bird, slightly above optical center, with a soft lift.
            let markRect = CGRect(x: plate.minX, y: plate.minY + 128 * k, width: plate.width, height: 600 * k)
                .insetBy(dx: 0, dy: 0)
            c.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 14 * k, color: CGColor(gray: 0, alpha: 0.16))
            c.beginTransparencyLayer(auxiliaryInfo: nil)
            c.addPath(FlamingoMarkPath.bird(in: markRect, flipped: true)); c.setFillColor(bird); c.fillPath()
            c.addPath(FlamingoMarkPath.tip(in: markRect, flipped: true)); c.setFillColor(beakTip); c.fillPath()
            c.endTransparencyLayer()
            c.restoreGState()
        }
    }

    /// Black mark on clear, for `NSImage.isTemplate`. Mark is 18pt tall in a 22pt square.
    static func menuBarTemplate(_ px: Int) -> CGImage {
        draw(px, px) { c in
            let k = CGFloat(px) / 22
            let r = CGRect(x: 0, y: 2 * k, width: 22 * k, height: 18 * k)
            c.addPath(FlamingoMarkPath.path(in: r, flipped: true))
            c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fillPath()
        }
    }

    /// The icon at Dock size between neutral plates, on a light and a dark strip.
    static func dockMock() -> CGImage {
        draw(1200, 520) { c in
            for (i, shade) in [CGFloat(0.93), 0.16].enumerated() {
                let y = CGFloat(i) * 260
                c.setFillColor(CGColor(gray: shade, alpha: 1)); c.fill(CGRect(x: 0, y: y, width: 1200, height: 260))
                var x: CGFloat = 40
                for size in [256, 128, 64, 32, 16] {
                    let img = appIcon(size * 2)
                    let s = CGFloat(size)
                    c.interpolationQuality = .high
                    c.draw(img, in: CGRect(x: x, y: y + (260 - s) / 2, width: s, height: s))
                    x += s + 40
                }
            }
        }
    }

    // MARK: Plumbing

    static func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.setShouldAntialias(true)
        body(c)
        return c.makeImage()!
    }

    static func write(_ img: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    static func writeCatalog(_ xc: URL, iconset: URL) throws {
        let fm = FileManager.default
        let icon = xc.appendingPathComponent("AppIcon.appiconset")
        let accent = xc.appendingPathComponent("AccentColor.colorset")
        try fm.createDirectory(at: icon, withIntermediateDirectories: true)
        try fm.createDirectory(at: accent, withIntermediateDirectories: true)
        try #"{"info":{"author":"xcode","version":1}}"#.write(to: xc.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

        var images: [String] = []
        for (name, px) in iconsetSizes {
            try fm.copyItem(at: iconset.appendingPathComponent("\(name).png"), to: icon.appendingPathComponent("\(name).png"))
            let scale = name.hasSuffix("@2x") ? 2 : 1
            let pt = px / scale
            images.append(#"{"filename":"\#(name).png","idiom":"mac","scale":"\#(scale)x","size":"\#(pt)x\#(pt)"}"#)
        }
        try #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
            .write(to: icon.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

        // Must match Theme.NS.accent.
        func comp(_ hex: String) -> String {
            let v = Int(hex, radix: 16)!
            return #"{"red":"0x\#(String(format: "%02X", (v >> 16) & 0xFF))","green":"0x\#(String(format: "%02X", (v >> 8) & 0xFF))","blue":"0x\#(String(format: "%02X", v & 0xFF))","alpha":"1.000"}"#
        }
        let accentJSON = #"""
        {"colors":[
          {"idiom":"universal","color":{"color-space":"srgb","components":\#(comp("D23B57"))}},
          {"idiom":"universal","appearances":[{"appearance":"luminosity","value":"dark"}],"color":{"color-space":"srgb","components":\#(comp("FF7A88"))}},
          {"idiom":"universal","appearances":[{"appearance":"contrast","value":"high"}],"color":{"color-space":"srgb","components":\#(comp("B0233F"))}},
          {"idiom":"universal","appearances":[{"appearance":"luminosity","value":"dark"},{"appearance":"contrast","value":"high"}],"color":{"color-space":"srgb","components":\#(comp("FF9DA8"))}}
        ],"info":{"author":"xcode","version":1}}
        """#
        try accentJSON.write(to: accent.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    }

    static func which(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--find", tool]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            FileHandle.standardError.write(Data("\(tool) failed:\n\(log)\n".utf8))
            throw CocoaError(.executableLoad)
        }
    }
}
