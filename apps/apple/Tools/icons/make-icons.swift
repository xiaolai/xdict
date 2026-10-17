// XDict's icons for every platform, generated from one source (Tools/icons/README.md says what and why).
//
//   swift Tools/icons/make-icons.swift generate <apps/apple> <dir>   write every platform's set under <dir> (`apps/`'s layout)
//   swift Tools/icons/make-icons.swift verify <apps/apple> <dir>     measure a written set against the rules
//
// Run through `Tools/icons.sh`, which knows where the sets go and checks them for staleness.
//
// The source is `Resources/XDict.icon` (the app icon: its ground and mark colours, per appearance, and its two layers)
// and `Resources/MenuBarIcon.svg` (the designer's small-size glyph: the D solid, the sparkle cut out of it). Nothing
// here redraws either: a layer is the source's own markup with its white paint replaced by a colour, and every
// platform's picture is those layers placed on that platform's ground, at that platform's size and margin.
//
// macOS only, and on a build Mac (AGENTS.md): it rasterises through CoreSVG (`NSImage`), which ships with macOS, so
// the set needs no dependency. `verify` reads the written files back through ImageIO and measures pixels; it shares
// the rules' numbers with `generate`, never its drawing.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Failing

struct Failure: Error, CustomStringConvertible { let description: String }
func fail(_ message: String) -> Failure { Failure(description: message) }

// MARK: - Rules: every number a platform asks for, named once

/// The mark's own layout in the `.icon`: its ink spans this fraction of the canvas (measured by `verify`, row
/// `mark ink`). Everything below places the mark relative to it.
enum Rules {
    static let appID = "ai.xdict.app"
    static let name = "XDict"
    /// A plate's corner: the superellipse |x|^n + |y|^n = 1 that fits Apple's squircle best (n = 4.4, measured against
    /// Notes, Calendar and Terminal on macOS 27.0.1). One plate shape on every platform that does not mask for itself.
    static let plateExponent = 4.4
    /// Apple's grid: the tile is 824 of 1024. Linux and a PWA's `any` icon use it (GNOME asks for margin and names no
    /// number; Chrome draws an `any` icon as given).
    static let gridMargin = 100.0 / 1024.0
    /// A tight plate for small, crowded places: Windows' 48-px grid less 2 px a side, favicons, the extension's small
    /// icons, Android's legacy launcher icons.
    static let tightMargin = 2.0 / 48.0
    /// Chrome's extension icon at 128: 96 px of artwork, 16 px of transparent margin a side.
    static let extensionMargin = 16.0 / 128.0
    /// At or below this many pixels a picture uses the glyph, not the outlined mark: the mark's stroke is 8 of 100
    /// units and its sparkle's waist 3, which is under a pixel here (the designer's reason for the glyph itself).
    static let glyphAtOrBelow = 32
    /// Android's adaptive icon: a 108 dp canvas, 72 dp shown, everything that matters inside a 66 dp circle.
    static let androidCanvas = 108.0, androidViewport = 72.0, androidSafeDiameter = 66.0
    /// The mark's farthest ink from the centre, in dp of the 108 canvas: 1 dp inside the 33 dp safe radius.
    static let androidMarkRadius = 32.0
    /// A maskable PWA icon: everything that matters inside a circle of 40% of the width (W3C, "maskable").
    static let maskableSafeRadius = 0.40, maskableMarkRadius = 0.37
    /// Glyph-only icons (tray, toolbar, notification, pinned tab) fill this fraction of their box, both axes fitted.
    static let trayFill = 14.0 / 16.0
    static let notificationFill = 20.0 / 24.0
    /// Windows 10 tiles: the mark on the tile's own colour, at this fraction of the tile's height.
    static let tileMark = 0.5, smallTileMark = 0.66
    static let windowsScales = [100, 125, 150, 200, 400]
    static let windowsTargetSizes = [16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256]
    static let icoSizes = [16, 24, 32, 48, 64, 256]
    static let trayIcoSizes = [16, 20, 24, 32, 40, 48, 64]
    static let linuxSizes = [16, 22, 24, 32, 48, 64, 128, 256, 512]
    static let linuxTraySizes = [16, 22, 24, 32, 48]
    static let androidDensities: [(String, Double)] = [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]
    /// Colours of the surfaces the glyph-only icons sit on, for the contrast rows (Windows 11's taskbars, Firefox's
    /// toolbars, GNOME's top bar). Approximations of the systems' own defaults, stated as such in the README.
    static let lightSurface = "#F3F3F3", darkSurface = "#202020"
    /// Ink for the glyph-only icons on a light and a dark surface.
    static let inkOnLight = "#1C1C1C", inkOnDark = "#FFFFFF"
}

// MARK: - The source

struct Source {
    var groundLight: String, groundDark: String, markLight: String, markDark: String
    /// The `.icon`'s layers, back to front, each the source's markup with `{PAINT}` where its white was.
    var layers: [String]
    /// The glyph's markup, with `{PAINT}` where its black was.
    var glyph: String

    static func load(apple: URL) throws -> Source {
        let document = apple.appendingPathComponent("Resources/XDict.icon")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: document.appendingPathComponent("icon.json")))
        guard let root = json as? [String: Any], let groups = root["groups"] as? [[String: Any]], groups.count == 1,
              let layers = groups[0]["layers"] as? [[String: Any]], !layers.isEmpty
        else { throw fail("icon.json: expected one group with layers") }
        let ground = try fills(root["fill-specializations"], "the document's fill")
        var marks: [(String, String)] = []
        var markup: [String] = []
        for layer in layers.reversed() {   // groups and layers are listed top first
            guard let image = layer["image-name"] as? String else { throw fail("icon.json: a layer has no image-name") }
            marks.append(try fills(layer["fill-specializations"], image))
            let svg = try String(contentsOf: document.appendingPathComponent("Assets/\(image)"), encoding: .utf8)
            markup.append(try paintable(svg, white: true, what: image))
        }
        guard Set(marks.map { $0.0 }).count == 1, Set(marks.map { $0.1 }).count == 1
        else { throw fail("icon.json: the layers have different colours; the platforms' pictures assume one mark colour") }
        let glyphSVG = try String(contentsOf: apple.appendingPathComponent("Resources/MenuBarIcon.svg"), encoding: .utf8)
        return Source(groundLight: ground.0, groundDark: ground.1, markLight: marks[0].0, markDark: marks[0].1,
                      layers: markup, glyph: try paintable(glyphSVG, white: false, what: "MenuBarIcon.svg"))
    }

    /// (default, dark) of a `fill-specializations` list of solid sRGB colours.
    private static func fills(_ node: Any?, _ what: String) throws -> (String, String) {
        guard let list = node as? [[String: Any]] else { throw fail("icon.json: \(what) has no fill-specializations") }
        var found: [String: String] = [:]
        for entry in list {
            guard let value = entry["value"] as? [String: Any], let solid = value["solid"] as? String
            else { throw fail("icon.json: \(what) has a fill that is not solid") }
            found[entry["appearance"] as? String ?? "default"] = try hex(solid)
        }
        guard let light = found["default"], let dark = found["dark"]
        else { throw fail("icon.json: \(what) lacks a default or a dark fill") }
        return (light, dark)
    }

    private static func hex(_ srgb: String) throws -> String {
        guard srgb.hasPrefix("srgb:") else { throw fail("icon.json: \(srgb) is not srgb:") }
        let parts = srgb.dropFirst(5).split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[3] == 1 else { throw fail("icon.json: \(srgb) is not an opaque srgb colour") }
        return "#" + parts.prefix(3).map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    /// A source SVG's inner markup with its one paint replaced by `{PAINT}`. Strict: a 100-unit viewBox, no text, no
    /// effects, and no paint but the one expected (white for a layer, black for the glyph) — anything else would ride
    /// into every platform's picture unrecoloured, or render differently from one rasteriser to the next.
    private static func paintable(_ svg: String, white: Bool, what: String) throws -> String {
        guard svg.contains("viewBox=\"0 0 100 100\"") else { throw fail("\(what): not a 100-unit viewBox") }
        for refused in ["<text", "<filter", "<mask", "Gradient", "<image", "<use", "style="] where svg.contains(refused) {
            throw fail("\(what): holds \(refused), which this generator does not reproduce")
        }
        guard let open = svg.range(of: "<svg"), let openEnd = svg.range(of: ">", range: open.upperBound..<svg.endIndex),
              let close = svg.range(of: "</svg>", options: .backwards)
        else { throw fail("\(what): not an <svg> element") }
        let inner = String(svg[openEnd.upperBound..<close.lowerBound])
        let paint = white ? "#FFFFFF" : "#000000"
        let regex = try NSRegularExpression(pattern: "(fill|stroke)=\"([^\"]*)\"")
        let range = NSRange(inner.startIndex..., in: inner)
        var painted = 0
        for match in regex.matches(in: inner, range: range) {
            let value = (inner as NSString).substring(with: match.range(at: 2))
            if value.uppercased() == paint { painted += 1 } else if value != "none" {
                throw fail("\(what): paints \(value); only \(paint) is recoloured")
            }
        }
        guard painted > 0 else { throw fail("\(what): paints nothing in \(paint)") }
        return inner.replacingOccurrences(of: "\"\(paint)\"", with: "\"{PAINT}\"", options: .caseInsensitive)
    }
}

// MARK: - Pictures, as SVG in a 100-unit space

enum Content { case mark, glyph }

struct Art {
    let source: Source

    /// The mark or the glyph, `scale` times its source layout, centred on (50, 50).
    func content(_ content: Content, paint: String, scale: Double) -> String {
        let markup = content == .mark ? source.layers.joined() : source.glyph
        return "<g transform=\"translate(50 50) scale(\(fmt(scale))) translate(-50 -50)\">"
            + markup.replacingOccurrences(of: "{PAINT}", with: paint) + "</g>"
    }

    /// The glyph's source layout puts its ink at 72.96 units (18..82 scaled by 1.14); the mark's at 74.23 (14..86 by
    /// 1.031). These convert "ink spans this fraction" into a scale. `verify` measures the result.
    static let markInk = 0.7423, glyphInk = 0.7296

    /// A superellipse plate inset by `margin` of the canvas a side.
    static func plate(margin: Double, paint: String) -> String {
        let half = 50 * (1 - 2 * margin), n = Rules.plateExponent
        var points: [String] = []
        for step in 0..<360 {
            let t = Double(step) / 360 * 2 * Double.pi
            let x = 50 + half * signedPower(cos(t), 2 / n)
            let y = 50 + half * signedPower(sin(t), 2 / n)
            points.append("\(fmt(x)),\(fmt(y))")
        }
        return "<polygon fill=\"\(paint)\" points=\"\(points.joined(separator: " "))\"/>"
    }

    static func circle(margin: Double, paint: String) -> String {
        "<circle fill=\"\(paint)\" cx=\"50\" cy=\"50\" r=\"\(fmt(50 * (1 - 2 * margin)))\"/>"
    }

    static func square(paint: String) -> String { "<rect fill=\"\(paint)\" width=\"100\" height=\"100\"/>" }

    /// A whole document: `body` in the 100-unit square, centred in a `width` x `height` canvas.
    static func document(_ body: String, width: Int = 100, height: Int = 100) -> String {
        let viewWidth = 100 * Double(width) / Double(height)
        let shift = (viewWidth - 100) / 2
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" "
            + "viewBox=\"0 0 \(fmt(viewWidth)) 100\"><g transform=\"translate(\(fmt(shift)) 0)\">\(body)</g></svg>\n"
    }

    /// The app's tile: ground on a plate, the mark (or at small sizes the glyph) at the `.icon`'s proportion of it.
    func tile(pixels: Int, margin: Double, dark: Bool = false, shape: (Double, String) -> String = Art.plate) -> String {
        let ground = dark ? source.groundDark : source.groundLight, ink = dark ? source.markDark : source.markLight
        let small = pixels <= Rules.glyphAtOrBelow
        let scale = (1 - 2 * margin) * (small ? Art.markInk / Art.glyphInk : 1)
        return shape(margin, ground) + content(small ? .glyph : .mark, paint: ink, scale: scale)
    }

    /// A mark (or glyph) alone, its ink spanning `fill` of the canvas.
    func alone(pixels: Int, fill: Double, paint: String, forceGlyph: Bool = false) -> String {
        let glyph = forceGlyph || pixels <= Rules.glyphAtOrBelow
        return content(glyph ? .glyph : .mark, paint: paint, scale: fill / (glyph ? Art.glyphInk : Art.markInk))
    }
}

func signedPower(_ value: Double, _ exponent: Double) -> Double {
    value < 0 ? -pow(-value, exponent) : pow(value, exponent)
}

func fmt(_ value: Double) -> String {
    var text = String(format: "%.3f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

// MARK: - Rasterising and writing

final class Writer {
    let root: URL
    private(set) var written: [String] = []
    init(root: URL) { self.root = root }

    func url(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        written.append(path)
        return url
    }

    func text(_ path: String, _ content: String) throws {
        try Data(content.utf8).write(to: try url(path))
    }

    /// `svg` rasterised by CoreSVG at exactly `width` x `height` pixels, sRGB, as PNG bytes.
    static func raster(_ svg: String, width: Int, height: Int) throws -> Data {
        guard let image = NSImage(data: Data(svg.utf8)) else { throw fail("CoreSVG could not read a generated SVG") }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw fail("no bitmap context") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let picture = context.makeImage() else { throw fail("the bitmap made no image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw fail("no PNG encoder") }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw fail("PNG encoding failed") }
        return data as Data
    }

    func png(_ path: String, _ body: String, width: Int, height: Int? = nil) throws {
        let height = height ?? width
        try Writer.raster(Art.document(body, width: width, height: height), width: width, height: height)
            .write(to: try url(path))
    }

    /// A Windows `.ico` holding one PNG per size (PNG members are read by Windows since Vista, at every size).
    func ico(_ path: String, sizes: [Int], body: (Int) -> String) throws {
        let images = try sizes.map { try Writer.raster(Art.document(body($0), width: $0, height: $0), width: $0, height: $0) }
        var data = Data()
        func le16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func le32(_ v: Int) { le16(v & 0xFFFF); le16(v >> 16 & 0xFFFF) }
        le16(0); le16(1); le16(sizes.count)
        var offset = 6 + 16 * sizes.count
        for (size, image) in zip(sizes, images) {
            data.append(contentsOf: [UInt8(size >= 256 ? 0 : size), UInt8(size >= 256 ? 0 : size), 0, 0])
            le16(1); le16(32); le32(image.count); le32(offset)
            offset += image.count
        }
        images.forEach { data.append($0) }
        try data.write(to: try url(path))
    }
}

// MARK: - The platforms

func generate(source: Source, into root: URL) throws -> [String] {
    let art = Art(source: source), out = Writer(root: root)
    try android(art, out)
    try windows(art, out)
    try linux(art, out)
    try web(art, out)
    try browserExtension(art, out)
    return out.written
}

func android(_ art: Art, _ out: Writer) throws {
    let res = "android/icons/res"
    // The foreground's mark, its farthest ink `androidMarkRadius` dp from the centre of the 108 dp canvas. The mark's
    // farthest ink in its own layout is the outer corner of the D's stem: 46.49 units at scale 1 (verify measures it).
    let scale = (Rules.androidMarkRadius / Rules.androidCanvas * 100) / 46.49
    let foreground = { (paint: String) in art.content(.mark, paint: paint, scale: scale) }
    // What the 72 dp viewport shows, scaled to fill a canvas: legacy icons and the Play Store's are cut from it.
    let viewport = { (paint: String) in art.content(.mark, paint: paint, scale: scale * Rules.androidCanvas / Rules.androidViewport) }
    for (density, factor) in Rules.androidDensities {
        let adaptive = Int((Rules.androidCanvas * factor).rounded()), legacy = Int((48 * factor).rounded())
        let notification = Int((24 * factor).rounded())
        try out.png("\(res)/mipmap-\(density)/ic_launcher_foreground.png", foreground(art.source.markLight), width: adaptive)
        try out.png("\(res)/mipmap-\(density)/ic_launcher_monochrome.png", foreground("#FFFFFF"), width: adaptive)
        let inner = (1 - 2 * Rules.tightMargin)
        let legacyBody = { (shape: String) in
            shape + "<g transform=\"translate(50 50) scale(\(fmt(inner))) translate(-50 -50)\">"
                + viewport(art.source.markLight) + "</g>"
        }
        try out.png("\(res)/mipmap-\(density)/ic_launcher.png",
                    legacyBody(Art.plate(margin: Rules.tightMargin, paint: art.source.groundLight)), width: legacy)
        try out.png("\(res)/mipmap-\(density)/ic_launcher_round.png",
                    legacyBody(Art.circle(margin: Rules.tightMargin, paint: art.source.groundLight)), width: legacy)
        try out.png("\(res)/drawable-\(density)/ic_stat_xdict.png",
                    art.alone(pixels: notification, fill: Rules.notificationFill, paint: "#FFFFFF", forceGlyph: true),
                    width: notification)
    }
    let adaptiveXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Generated by apps/apple/Tools/icons/make-icons.swift from XDict.icon. Do not edit. -->
        <adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
            <background android:drawable="@color/ic_launcher_background"/>
            <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
            <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
        </adaptive-icon>

        """
    try out.text("\(res)/mipmap-anydpi-v26/ic_launcher.xml", adaptiveXML)
    try out.text("\(res)/mipmap-anydpi-v26/ic_launcher_round.xml", adaptiveXML)
    try out.text("\(res)/values/ic_launcher_background.xml", """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Generated by apps/apple/Tools/icons/make-icons.swift from XDict.icon. Do not edit. -->
        <resources>
            <color name="ic_launcher_background">\(art.source.groundLight)</color>
        </resources>

        """)
    try out.png("android/icons/play-store-512.png", Art.square(paint: art.source.groundLight) + viewport(art.source.markLight),
                width: 512)
}

func windows(_ art: Art, _ out: Writer) throws {
    let dir = "windows/icons"
    try out.ico("\(dir)/XDict.ico", sizes: Rules.icoSizes) { art.tile(pixels: $0, margin: Rules.tightMargin) }
    try out.ico("\(dir)/tray-on-light.ico", sizes: Rules.trayIcoSizes) {
        art.alone(pixels: $0, fill: Rules.trayFill, paint: Rules.inkOnLight, forceGlyph: true)
    }
    try out.ico("\(dir)/tray-on-dark.ico", sizes: Rules.trayIcoSizes) {
        art.alone(pixels: $0, fill: Rules.trayFill, paint: Rules.inkOnDark, forceGlyph: true)
    }
    let images = "\(dir)/Images"
    let unplatedFill = 1 - 2 * Rules.tightMargin
    for size in Rules.windowsTargetSizes {
        try out.png("\(images)/AppList.targetsize-\(size).png", art.tile(pixels: size, margin: Rules.tightMargin), width: size)
        // Unplated: the mark alone, in the colour each theme's taskbar needs (dark theme: the .icon's dark mark).
        try out.png("\(images)/AppList.targetsize-\(size)_altform-unplated.png",
                    art.alone(pixels: size, fill: unplatedFill, paint: art.source.markDark), width: size)
        try out.png("\(images)/AppList.targetsize-\(size)_altform-lightunplated.png",
                    art.alone(pixels: size, fill: unplatedFill, paint: art.source.markLight), width: size)
    }
    for scale in Rules.windowsScales {
        func px(_ base: Double) -> Int { Int((base * Double(scale) / 100).rounded()) }
        try out.png("\(images)/AppList.scale-\(scale).png", art.tile(pixels: px(44), margin: Rules.tightMargin), width: px(44))
        try out.png("\(images)/StoreLogo.scale-\(scale).png", art.tile(pixels: px(50), margin: Rules.tightMargin), width: px(50))
        // Windows 10 tiles: the dark mark on transparency, over the manifest's tile colour (the .icon's dark ground).
        let tile = { (height: Int, fill: Double) in art.alone(pixels: height, fill: fill, paint: art.source.markDark) }
        try out.png("\(images)/SmallTile.scale-\(scale).png", tile(px(71), Rules.smallTileMark), width: px(71))
        try out.png("\(images)/MedTile.scale-\(scale).png", tile(px(150), Rules.tileMark), width: px(150))
        try out.png("\(images)/WideTile.scale-\(scale).png", tile(px(150), Rules.tileMark), width: px(310), height: px(150))
        try out.png("\(images)/LargeTile.scale-\(scale).png", tile(px(310), Rules.tileMark), width: px(310))
    }
}

func linux(_ art: Art, _ out: Writer) throws {
    let hicolor = "linux/icons/hicolor"
    for size in Rules.linuxSizes {
        try out.png("\(hicolor)/\(size)x\(size)/apps/\(Rules.appID).png", art.tile(pixels: size, margin: Rules.gridMargin),
                    width: size)
    }
    try out.text("\(hicolor)/scalable/apps/\(Rules.appID).svg",
                 Art.document(art.tile(pixels: 512, margin: Rules.gridMargin), width: 128, height: 128))
    // Symbolic: GTK recolours it to the foreground; the grey is the convention for the file as drawn.
    try out.text("\(hicolor)/symbolic/apps/\(Rules.appID)-symbolic.svg",
                 Art.document(art.alone(pixels: 16, fill: Rules.trayFill, paint: "#2E3436", forceGlyph: true),
                              width: 16, height: 16))
    for size in Rules.linuxTraySizes {
        try out.png("\(hicolor)/\(size)x\(size)/status/\(Rules.appID)-tray-on-light.png",
                    art.alone(pixels: size, fill: Rules.trayFill, paint: Rules.inkOnLight, forceGlyph: true), width: size)
        try out.png("\(hicolor)/\(size)x\(size)/status/\(Rules.appID)-tray-on-dark.png",
                    art.alone(pixels: size, fill: Rules.trayFill, paint: Rules.inkOnDark, forceGlyph: true), width: size)
    }
    try out.text("linux/icons/\(Rules.appID).desktop", """
        # Generated by apps/apple/Tools/icons/make-icons.swift. Do not edit; see apps/linux/README.md.
        [Desktop Entry]
        Type=Application
        Name=\(Rules.name)
        Icon=\(Rules.appID)
        Exec=xdict %F
        Categories=Office;Dictionary;
        StartupWMClass=\(Rules.appID)

        """)
}

func web(_ art: Art, _ out: Writer) throws {
    let dir = "web/icons"
    let source = art.source
    try out.ico("\(dir)/favicon.ico", sizes: [16, 32, 48]) { art.tile(pixels: $0, margin: Rules.tightMargin) }
    // The SVG favicon follows the reader's appearance: the .icon's dark ground and mark under a dark scheme.
    let plate = Art.plate(margin: Rules.tightMargin, paint: "{GROUND}")
        .replacingOccurrences(of: "fill=\"{GROUND}\"", with: "class=\"ground\"")
    let mark = art.content(.mark, paint: "{MARK}", scale: 1 - 2 * Rules.tightMargin)
        .replacingOccurrences(of: "fill=\"{MARK}\"", with: "class=\"mark\"")
    guard !mark.contains("{MARK}") else { throw fail("the SVG favicon's mark has paint other than fill") }
    let style = "<style>.ground{fill:\(source.groundLight)}.mark{fill:\(source.markLight)}"
        + "@media (prefers-color-scheme:dark){.ground{fill:\(source.groundDark)}.mark{fill:\(source.markDark)}}</style>"
    try out.text("\(dir)/icon.svg", Art.document(style + plate + mark, width: 32, height: 32))
    // iOS masks a touch icon itself and puts transparency on black: full bleed, opaque, the .icon's own layout.
    try out.png("\(dir)/apple-touch-icon.png", Art.square(paint: source.groundLight) + art.content(.mark, paint: source.markLight, scale: 1),
                width: 180)
    for size in [192, 512] {
        try out.png("\(dir)/icon-\(size).png", art.tile(pixels: size, margin: Rules.gridMargin), width: size)
        let scale = Rules.maskableMarkRadius * 100 / 46.49
        try out.png("\(dir)/icon-maskable-\(size).png",
                    Art.square(paint: source.groundLight) + art.content(.mark, paint: source.markLight, scale: scale), width: size)
    }
    try out.text("\(dir)/safari-pinned-tab.svg",
                 Art.document(art.alone(pixels: 16, fill: 15.0 / 16.0, paint: "#000000", forceGlyph: true),
                              width: 16, height: 16))
    let manifest: [String: Any] = [
        "name": Rules.name, "short_name": Rules.name,
        "theme_color": source.groundLight, "background_color": source.groundLight,
        "icons": [
            ["src": "icons/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"],
            ["src": "icons/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"],
            ["src": "icons/icon-maskable-192.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable"],
            ["src": "icons/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable"],
            ["src": "icons/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any"],
        ],
    ]
    let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try out.text("\(dir)/manifest.webmanifest", String(decoding: json, as: UTF8.self) + "\n")
}

func browserExtension(_ art: Art, _ out: Writer) throws {
    let dir = "extension/icons"
    for size in [16, 32, 48] {
        try out.png("\(dir)/icon-\(size).png", art.tile(pixels: size, margin: Rules.tightMargin), width: size)
    }
    try out.png("\(dir)/icon-128.png", art.tile(pixels: 128, margin: Rules.extensionMargin), width: 128)
    // Firefox's `theme_icons`: `dark` is drawn on themes with dark text (light toolbars), `light` on dark ones.
    for size in [16, 32] {
        try out.png("\(dir)/toolbar-\(size)-dark.png",
                    art.alone(pixels: size, fill: Rules.trayFill, paint: Rules.inkOnLight, forceGlyph: true), width: size)
        try out.png("\(dir)/toolbar-\(size)-light.png",
                    art.alone(pixels: size, fill: Rules.trayFill, paint: Rules.inkOnDark, forceGlyph: true), width: size)
    }
}

// MARK: - Measuring

struct Pixels {
    let width: Int, height: Int, rgba: [UInt8]   // straight (unpremultiplied) RGBA, sRGB

    init(png data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw fail("an image does not decode") }
        try self.init(image)
    }

    init(_ image: CGImage) throws {
        width = image.width; height = image.height
        var premultiplied = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &premultiplied, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw fail("no context to read pixels") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var straight = premultiplied
        for i in stride(from: 0, to: straight.count, by: 4) where straight[i + 3] > 0 && straight[i + 3] < 255 {
            for c in 0..<3 { straight[i + c] = UInt8(min(255, Int(premultiplied[i + c]) * 255 / Int(straight[i + 3]))) }
        }
        rgba = straight
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * width + x) * 4 + 3] }
    var corners: [UInt8] { [alpha(0, 0), alpha(width - 1, 0), alpha(0, height - 1), alpha(width - 1, height - 1)] }
    var allOpaque: Bool { stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 255 } }

    /// Bounding box (x0, y0, x1, y1), exclusive, of the pixels `select` picks.
    func box(_ select: (Int) -> Bool) -> (Int, Int, Int, Int)? {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for y in 0..<height { for x in 0..<width where select((y * width + x) * 4) {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        return x1 < 0 ? nil : (x0, y0, x1 + 1, y1 + 1)
    }

    var inkBox: (Int, Int, Int, Int)? { box { rgba[$0 + 3] >= 128 } }

    /// The farthest selected pixel's distance from the centre, as a fraction of the width (pixel centres).
    func farthest(_ select: (Int) -> Bool) -> Double {
        var best = 0.0
        let cx = Double(width) / 2, cy = Double(height) / 2
        for y in 0..<height { for x in 0..<width where select((y * width + x) * 4) {
            best = max(best, hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy))
        } }
        return best / Double(width)
    }

    /// Whether the pixel at `i` is within `tolerance` of `hex` (and mostly opaque).
    func near(_ i: Int, _ hex: String, tolerance: Int = 60) -> Bool {
        let c = rgb(hex)
        return rgba[i + 3] >= 128 && abs(Int(rgba[i]) - c.0) + abs(Int(rgba[i + 1]) - c.1) + abs(Int(rgba[i + 2]) - c.2) < tolerance
    }
}

func rgb(_ hex: String) -> (Int, Int, Int) {
    let value = Int(hex.dropFirst(), radix: 16) ?? 0
    return (value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
}

func contrast(_ a: String, _ b: String) -> Double {
    func luminance(_ hex: String) -> Double {
        let c = rgb(hex)
        func channel(_ v: Int) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }
    let (l1, l2) = (luminance(a), luminance(b))
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

/// The PNG members of an `.ico`, by the size its directory states, each checked to decode at that size.
func icoMembers(_ data: Data) throws -> [Int: Pixels] {
    let bytes = [UInt8](data)
    func le16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    func le32(_ at: Int) -> Int { le16(at) | le16(at + 2) << 16 }
    guard bytes.count >= 6, le16(0) == 0, le16(2) == 1 else { throw fail("not an icon container") }
    var members: [Int: Pixels] = [:]
    for entry in 0..<le16(4) {
        let at = 6 + 16 * entry
        let size = bytes[at] == 0 ? 256 : Int(bytes[at])
        let length = le32(at + 8), offset = le32(at + 12)
        guard offset + length <= bytes.count else { throw fail("an icon member runs past the file") }
        let pixels = try Pixels(png: data.subdata(in: offset..<offset + length))
        guard pixels.width == size, pixels.height == size else {
            throw fail("an icon member says \(size) and decodes at \(pixels.width)x\(pixels.height)")
        }
        members[size] = pixels
    }
    return members
}

final class Report {
    private(set) var failures = 0
    func row(_ check: String, _ expected: String, _ got: String, _ pass: Bool) {
        if !pass { failures += 1 }
        print("| \(check) | \(expected) | \(got) | \(pass ? "yes" : "NO") |")
    }
}

func verify(root: URL, source: Source) throws -> Int {
    let report = Report()
    print("| Check | Expected | Got | Pass |\n|---|---|---|---|")
    func load(_ path: String) throws -> Pixels { try Pixels(png: Data(contentsOf: root.appendingPathComponent(path))) }
    func ink(_ p: Pixels) -> String {
        guard let b = p.inkBox else { return "empty" }
        return "(\(b.0),\(b.1))-(\(b.2),\(b.3)) of \(p.width)x\(p.height)"
    }
    func within(_ p: Pixels, margin: Double, slack: Int = 1) -> Bool {
        guard let b = p.inkBox else { return false }
        let m = Int((margin * Double(p.width)).rounded(.down)) - slack
        let mh = Int((margin * Double(p.height)).rounded(.down)) - slack
        return b.0 >= m && b.1 >= mh && b.2 <= p.width - m && b.3 <= p.height - mh
    }

    // The mark's own layout, from which every scale above is derived: ink 74.23% and farthest ink 46.49 units.
    let markOnly = try Pixels(png: Writer.raster(Art.document(Art(source: source).content(.mark, paint: "#000000", scale: 1),
                                                                width: 1024, height: 1024), width: 1024, height: 1024))
    let markBox = markOnly.inkBox ?? (0, 0, 0, 0)
    let markSpan = Double(max(markBox.2 - markBox.0, markBox.3 - markBox.1)) / 1024
    report.row("mark ink, .icon layout", "0.742 of the canvas (Art.markInk)", String(format: "%.3f", markSpan), abs(markSpan - Art.markInk) < 0.004)
    let markRadius = markOnly.farthest { markOnly.rgba[$0 + 3] >= 128 } * 100
    report.row("mark's farthest ink, .icon layout", "46.49 units", String(format: "%.2f", markRadius), abs(markRadius - 46.49) < 0.3)

    // Android.
    for (density, factor) in Rules.androidDensities {
        let size = Int((Rules.androidCanvas * factor).rounded())
        for layer in ["foreground", "monochrome"] {
            let p = try load("android/icons/res/mipmap-\(density)/ic_launcher_\(layer).png")
            let radius = p.farthest { p.rgba[$0 + 3] >= 128 } * Rules.androidCanvas
            report.row("Android \(layer) \(density)", "\(size) px, corners clear, ink within 33 dp of centre",
                       "\(p.width) px, corners \(p.corners), ink to \(String(format: "%.2f", radius)) dp",
                       p.width == size && p.height == size && p.corners.allSatisfy { $0 == 0 } && radius <= Rules.androidSafeDiameter / 2)
        }
        let legacy = Int((48 * factor).rounded())
        for name in ["ic_launcher", "ic_launcher_round"] {
            let p = try load("android/icons/res/mipmap-\(density)/\(name).png")
            report.row("Android \(name) \(density)", "\(legacy) px, corners clear", "\(p.width) px, corners \(p.corners)",
                       p.width == legacy && p.corners.allSatisfy { $0 == 0 })
        }
        let small = Int((24 * factor).rounded())
        let n = try load("android/icons/res/drawable-\(density)/ic_stat_xdict.png")
        let whiteOnly = stride(from: 0, to: n.rgba.count, by: 4).allSatisfy { n.rgba[$0 + 3] < 128 || n.near($0, "#FFFFFF", tolerance: 12) }
        report.row("Android notification \(density)", "\(small) px, white on alpha, ink inside 2 dp", "\(n.width) px, \(ink(n))",
                   n.width == small && whiteOnly && within(n, margin: 2.0 / 24))
    }
    let play = try load("android/icons/play-store-512.png")
    report.row("Play Store icon", "512 px, opaque", "\(play.width) px, opaque \(play.allOpaque)", play.width == 512 && play.allOpaque)

    // Windows.
    for (file, sizes) in [("XDict.ico", Rules.icoSizes), ("tray-on-light.ico", Rules.trayIcoSizes), ("tray-on-dark.ico", Rules.trayIcoSizes)] {
        let members = try icoMembers(Data(contentsOf: root.appendingPathComponent("windows/icons/\(file)")))
        let clear = members.values.allSatisfy { $0.corners.allSatisfy { $0 == 0 } }
        report.row("Windows \(file)", "members \(sizes), corners clear", "members \(members.keys.sorted()), corners clear \(clear)",
                   members.keys.sorted() == sizes && clear)
        if file.hasPrefix("tray") {
            let fits = members.values.allSatisfy { within($0, margin: (1 - Rules.trayFill) / 2) }
            report.row("Windows \(file) glyph", "ink inside 1/16 a side", "inside: \(fits)", fits)
        }
    }
    for size in Rules.windowsTargetSizes {
        for suffix in ["", "_altform-unplated", "_altform-lightunplated"] {
            let p = try load("windows/icons/Images/AppList.targetsize-\(size)\(suffix).png")
            report.row("Windows AppList \(size)\(suffix)", "\(size) px, ink inside 2/48", "\(p.width) px, \(ink(p))",
                       p.width == size && within(p, margin: Rules.tightMargin) && p.corners.allSatisfy { $0 == 0 })
        }
    }
    for scale in Rules.windowsScales {
        func px(_ base: Double) -> Int { Int((base * Double(scale) / 100).rounded()) }
        for (name, w, h) in [("AppList", px(44), px(44)), ("StoreLogo", px(50), px(50)), ("SmallTile", px(71), px(71)),
                             ("MedTile", px(150), px(150)), ("WideTile", px(310), px(150)), ("LargeTile", px(310), px(310))] {
            let p = try load("windows/icons/Images/\(name).scale-\(scale).png")
            report.row("Windows \(name).scale-\(scale)", "\(w)x\(h)", "\(p.width)x\(p.height)", p.width == w && p.height == h)
        }
    }

    // Linux.
    for size in Rules.linuxSizes {
        let p = try load("linux/icons/hicolor/\(size)x\(size)/apps/\(Rules.appID).png")
        report.row("Linux \(size)", "\(size) px, plate inside 100/1024", "\(p.width) px, \(ink(p))",
                   p.width == size && within(p, margin: Rules.gridMargin) && p.corners.allSatisfy { $0 == 0 })
    }
    for size in Rules.linuxTraySizes {
        for side in ["light", "dark"] {
            let p = try load("linux/icons/hicolor/\(size)x\(size)/status/\(Rules.appID)-tray-on-\(side).png")
            report.row("Linux tray \(size) on \(side)", "\(size) px, ink inside 1/16", "\(p.width) px, \(ink(p))",
                       p.width == size && within(p, margin: (1 - Rules.trayFill) / 2))
        }
    }
    let desktop = try String(contentsOf: root.appendingPathComponent("linux/icons/\(Rules.appID).desktop"), encoding: .utf8)
    report.row("Linux desktop entry", "Icon=\(Rules.appID)", desktop.contains("\nIcon=\(Rules.appID)\n") ? "Icon=\(Rules.appID)" : "missing",
               desktop.contains("\nIcon=\(Rules.appID)\n"))

    // Web.
    let favicons = try icoMembers(Data(contentsOf: root.appendingPathComponent("web/icons/favicon.ico")))
    report.row("favicon.ico", "members [16, 32, 48]", "members \(favicons.keys.sorted())", favicons.keys.sorted() == [16, 32, 48])
    let touch = try load("web/icons/apple-touch-icon.png")
    report.row("apple-touch-icon", "180 px, opaque", "\(touch.width) px, opaque \(touch.allOpaque)", touch.width == 180 && touch.allOpaque)
    for size in [192, 512] {
        let any = try load("web/icons/icon-\(size).png")
        report.row("PWA icon \(size)", "\(size) px, plate inside 100/1024, corners clear", "\(any.width) px, \(ink(any))",
                   any.width == size && within(any, margin: Rules.gridMargin) && any.corners.allSatisfy { $0 == 0 })
        let mask = try load("web/icons/icon-maskable-\(size).png")
        let radius = mask.farthest { mask.near($0, source.markLight, tolerance: 120) }
        report.row("PWA maskable \(size)", "\(size) px, opaque, mark within 0.40 of the width",
                   "\(mask.width) px, opaque \(mask.allOpaque), mark to \(String(format: "%.3f", radius))",
                   mask.width == size && mask.allOpaque && radius <= Rules.maskableSafeRadius)
    }

    // The browser extension.
    for size in [16, 32, 48, 128] {
        let p = try load("extension/icons/icon-\(size).png")
        let margin = size == 128 ? Rules.extensionMargin : Rules.tightMargin
        report.row("extension icon \(size)", "\(size) px, ink inside \(size == 128 ? "16/128" : "2/48")", "\(p.width) px, \(ink(p))",
                   p.width == size && within(p, margin: margin))
    }
    for size in [16, 32] {
        for side in ["dark", "light"] {
            let p = try load("extension/icons/toolbar-\(size)-\(side).png")
            report.row("extension toolbar \(size) \(side)", "\(size) px, ink inside 1/16", "\(p.width) px, \(ink(p))",
                       p.width == size && within(p, margin: (1 - Rules.trayFill) / 2))
        }
    }

    // Contrast (WCAG 2.x relative luminance). The mark is a graphic: 3:1 is the bar (WCAG 1.4.11).
    for (what, a, b) in [("mark on ground, light", source.markLight, source.groundLight),
                         ("mark on ground, dark", source.markDark, source.groundDark),
                         ("Windows unplated, dark taskbar", source.markDark, Rules.darkSurface),
                         ("Windows lightunplated, light taskbar", source.markLight, Rules.lightSurface),
                         ("tray ink on a light surface", Rules.inkOnLight, Rules.lightSurface),
                         ("tray ink on a dark surface", Rules.inkOnDark, Rules.darkSurface),
                         ("Windows tile mark on tile colour", source.markDark, source.groundDark)] {
        let ratio = contrast(a, b)
        report.row("contrast: \(what)", ">= 3.0:1", String(format: "%.2f:1 (%@ on %@)", ratio, a, b), ratio >= 3)
    }
    return report.failures
}

// MARK: - Main

do {
    let args = CommandLine.arguments
    guard args.count == 4, ["generate", "verify"].contains(args[1]) else {
        throw fail("usage: make-icons.swift generate|verify <apps/apple> <dir>")
    }
    let source = try Source.load(apple: URL(fileURLWithPath: args[2]))
    let root = URL(fileURLWithPath: args[3])
    if args[1] == "generate" {
        let written = try generate(source: source, into: root)
        print("make-icons: wrote \(written.count) files under \(root.path)")
    } else {
        let failures = try verify(root: root, source: source)
        guard failures == 0 else { throw fail("\(failures) check(s) failed") }
        print("make-icons: every check passed")
    }
} catch {
    FileHandle.standardError.write(Data("make-icons: \(error)\n".utf8))
    exit(1)
}
