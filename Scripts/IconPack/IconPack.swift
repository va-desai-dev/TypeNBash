// Builds TypeNBash's own file-icon symbols from SVG artwork, outside the app.
//
// Reads Scripts/IconPack/pack.json, turns each source (a Material asset, any
// .svg in the repo, or one of Apple's own SF Symbols) into an SF Symbol
// template, and writes it as a .symbolset into the asset catalog. actool is the judge: every symbol is
// compiled before the run counts as clean, and --preview draws the compiled
// symbols in each rendering mode so they can be reviewed without the SF
// Symbols app.
//
//   xcrun swift Scripts/IconPack/IconPack.swift
//   xcrun swift Scripts/IconPack/IconPack.swift --preview ~/Desktop/pack.png
//   xcrun swift Scripts/IconPack/IconPack.swift --manifest icons-creation/curated.json --review /tmp/review.png
//
// The output folder belongs to this script: symbolsets not in pack.json are deleted.
//
// How an SF Symbol source becomes a symbol: its Ultralight, Regular and Black
// outlines and Apple's own layer annotations are read from macOS's CoreGlyphs
// catalog, so it comes out exactly as "Duplicate as Custom Symbol" would, ready
// for a palette override. Symbols Apple restricts are refused.
//
// How an SVG source becomes a symbol:
//   - Each run of same-coloured shapes, in paint order, is one layer.
//   - Multicolor keeps every layer's colour (or the manifest's palette override).
//   - Monochrome and hierarchical need cut-outs instead of over-painting: a layer
//     that sits inside an earlier one is carved out of it (clear-behind), and a
//     layer inside a carved one is filled again.
//   - All weights share one drawing; the art has no weights to draw from.
//
// A finished SF Symbol template (one with a "Symbols" group, e.g. made in the SF
// Symbols app or by icons-creation/svg-sf-converter.py) goes in exactly as drawn.
//
// A symbol with a `glyph` is an enclosure: the glyph is cut out of the middle of
// `from` at every weight, the way the SF Symbols app combines a symbol with a
// shield. `from` can be any shape the app can't enclose, such as sf:doc.fill.

import AppKit

let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized

// MARK: - Manifest

struct Manifest: Decodable {
    struct Symbol: Decodable {
        /// Asset name inside `output`, e.g. "swift" → `Image("pack/swift")`.
        var name: String
        /// A Material asset name, a repo-relative path ending in ".svg", or
        /// "sf:<name>" for an Apple SF Symbol (old names like "doc.text" work).
        var from: String
        /// Art cut out of `from`, given the same way as `from`, e.g. a brand logo out
        /// of "sf:doc.fill". An SF Symbol or template glyph keeps its own weights.
        var glyph: String?
        /// "multicolor" (default), "hierarchical" or "monochrome": how the symbol
        /// draws when the app doesn't ask for a mode.
        var rendering: String?
        /// Replaces layer colours in paint order; null keeps that layer's colour.
        var palette: [String?]?
        /// Review-only metadata; file associations make the gallery searchable.
        var category: String?
        var reason: String?
        var matches: [String]?
    }
    var sources: String
    var output: String
    var symbols: [Symbol]
    /// Reuse a reviewed selection while writing to a different catalog.
    var symbolsFrom: String?
}

// MARK: - SVG → coloured shapes

struct Paint {
    var path: CGPath
    var color: String
    var opacity: CGFloat
}

final class SVGReader: NSObject, XMLParserDelegate {
    var viewBox = CGRect(x: 0, y: 0, width: 16, height: 16)
    var paints: [Paint] = []
    var problems: Set<String> = []

    private var attributes: [[String: String]] = [[:]]
    private var transforms: [CGAffineTransform] = [.identity]
    private var hiddenDepth = 0
    private var gradientStops: [String: [String]] = [:]
    private var gradientLinks: [String: String] = [:]
    private var gradient: String?
    /// Only paths inside the element with this id are read, relative to its origin.
    private let scope: String?
    private var scopeDepth = 0

    private static let inherited: Set<String> = [
        "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
    ]
    private static let hiddenContainers: Set<String> = [
        "defs", "clipPath", "mask", "metadata", "title", "desc", "symbol", "pattern", "style",
    ]

    init(url: URL, scope: String? = nil) throws {
        self.scope = scope
        super.init()
        let parser = XMLParser(data: try Data(contentsOf: url))
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        paints = paints.compactMap { paint in
            guard paint.color.hasPrefix("url(") else { return paint }
            guard let color = gradientColor(paint.color) else { problems.insert("unresolved gradient"); return nil }
            problems.insert("gradient flattened")
            return Paint(path: paint.path, color: color, opacity: paint.opacity)
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes raw: [String: String]) {
        var own = raw
        for declaration in (raw["style"] ?? "").split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { own[pair[0]] = pair[1] }
        }
        var merged = attributes.last!.filter { Self.inherited.contains($0.key) }
        merged.merge(own) { $1 }
        // Opacity multiplies down the tree.
        merged["opacity"] = String((Double(attributes.last!["opacity"] ?? "1") ?? 1) * (Double(own["opacity"] ?? "1") ?? 1))
        attributes.append(merged)
        // A template's weight group hangs from the baseline: its own placement is dropped.
        let entersScope = scope != nil && own["id"] == scope
        if scopeDepth > 0 || entersScope { scopeDepth += 1 }
        transforms.append(entersScope ? .identity : Self.transform(own["transform"] ?? "").concatenating(transforms.last!))

        switch name {
            case "linearGradient", "radialGradient":
                gradient = own["id"]
                if let id = own["id"], let link = own["xlink:href"] ?? own["href"] { gradientLinks[id] = String(link.dropFirst()) }
            case "stop":
                if let gradient, let color = Self.color(own["stop-color"] ?? "black") { gradientStops[gradient, default: []].append(color) }
            default: break
        }
        if Self.hiddenContainers.contains(name) || own["display"] == "none" || own["visibility"] == "hidden" || name.contains(":") {
            hiddenDepth += 1
            if name == "style" { problems.insert("<style> block ignored") }
        }
        guard hiddenDepth == 0, scope == nil || scopeDepth > 0 else { return }
        if own["clip-path"] != nil { problems.insert("clip-path ignored") }
        if own["mask"] != nil { problems.insert("mask ignored") }

        switch name {
            case "svg":
                let box = (own["viewBox"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                if box.count == 4 { viewBox = CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) }
            case "path": add(SVGPath.parse(own["d"] ?? ""), merged)
            case "rect":
                let rect = CGRect(x: len(own["x"]), y: len(own["y"]), width: len(own["width"]), height: len(own["height"]))
                var rx = len(own["rx"] ?? own["ry"]), ry = len(own["ry"] ?? own["rx"])
                rx = min(rx, rect.width / 2); ry = min(ry, rect.height / 2)
                add(rx > 0 || ry > 0 ? CGPath(roundedRect: rect, cornerWidth: rx, cornerHeight: ry, transform: nil) : CGPath(rect: rect, transform: nil), merged)
            case "circle":
                let r = len(own["r"])
                add(CGPath(ellipseIn: CGRect(x: len(own["cx"]) - r, y: len(own["cy"]) - r, width: 2 * r, height: 2 * r), transform: nil), merged)
            case "ellipse":
                let rx = len(own["rx"]), ry = len(own["ry"])
                add(CGPath(ellipseIn: CGRect(x: len(own["cx"]) - rx, y: len(own["cy"]) - ry, width: 2 * rx, height: 2 * ry), transform: nil), merged)
            case "polygon", "polyline":
                let n = (own["points"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline }).compactMap { Double($0) }
                let path = CGMutablePath()
                path.addLines(between: stride(from: 0, to: n.count - 1, by: 2).map { CGPoint(x: n[$0], y: n[$0 + 1]) })
                if name == "polygon" { path.closeSubpath() }
                add(path, merged)
            case "line":
                let path = CGMutablePath()
                path.addLines(between: [CGPoint(x: len(own["x1"]), y: len(own["y1"])), CGPoint(x: len(own["x2"]), y: len(own["y2"]))])
                add(path, merged)
            case "use", "image", "text": problems.insert("<\(name)> skipped")
            default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if (Self.hiddenContainers.contains(name) || name.contains(":")
            || attributes.last!["display"] == "none" || attributes.last!["visibility"] == "hidden"), hiddenDepth > 0 {
            hiddenDepth -= 1
        }
        if name == "linearGradient" || name == "radialGradient" { gradient = nil }
        if scopeDepth > 0 { scopeDepth -= 1 }
        attributes.removeLast()
        transforms.removeLast()
    }

    private func add(_ local: CGPath, _ style: [String: String]) {
        var ctm = transforms.last!
        let opacity = CGFloat(Double(style["opacity"] ?? "1") ?? 1)
        let fill = style["fill"] ?? "black"
        if fill != "none", let color = fill.hasPrefix("url(") ? fill : Self.color(fill) {
            let rule: CGPathFillRule = style["fill-rule"] == "evenodd" ? .evenOdd : .winding
            let fillOpacity = CGFloat(Double(style["fill-opacity"] ?? "1") ?? 1)
            if let path = local.copy(using: &ctm)?.normalized(using: rule), !path.isEmpty {
                paints.append(Paint(path: path, color: color, opacity: opacity * fillOpacity))
            }
        }
        if let stroke = style["stroke"], stroke != "none", let color = stroke.hasPrefix("url(") ? stroke : Self.color(stroke) {
            let width = len(style["stroke-width"] ?? "1")
            let cap: CGLineCap = ["round": .round, "square": .square][style["stroke-linecap"] ?? ""] ?? .butt
            let join: CGLineJoin = ["round": .round, "bevel": .bevel][style["stroke-linejoin"] ?? ""] ?? .miter
            let outline = local.copy(strokingWithWidth: width, lineCap: cap, lineJoin: join, miterLimit: 4)
            if width > 0, let path = outline.copy(using: &ctm)?.normalized(), !path.isEmpty {
                paints.append(Paint(path: path, color: color, opacity: opacity))
            }
        }
        if opacity < 1 { problems.insert("opacity kept as layer opacity") }
    }

    /// A gradient becomes the average of its stops.
    private func gradientColor(_ reference: String) -> String? {
        var id = String(reference.dropFirst(5).prefix { $0 != ")" })
        while gradientStops[id] == nil, let link = gradientLinks[id] { id = link }
        guard let stops = gradientStops[id], !stops.isEmpty else { return nil }
        let rgb = stops.map(Self.rgb).reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
        let n = Double(stops.count)
        return String(format: "#%02X%02X%02X", Int(rgb.0 / n), Int(rgb.1 / n), Int(rgb.2 / n))
    }

    private func len(_ value: String?) -> CGFloat {
        CGFloat(Double((value ?? "0").replacingOccurrences(of: "px", with: "")) ?? 0)
    }

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        return (Double(v >> 16 & 0xFF), Double(v >> 8 & 0xFF), Double(v & 0xFF))
    }

    /// Normalises a paint to "#RRGGBB", or nil for "none" and colours it can't read.
    static func color(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        let named = ["black": "#000000", "white": "#FFFFFF", "red": "#FF0000", "green": "#008000", "blue": "#0000FF",
                     "currentcolor": "#000000", "gray": "#808080", "grey": "#808080", "yellow": "#FFFF00", "orange": "#FFA500"]
        if let hex = named[v] { return hex }
        if v.hasPrefix("#") {
            let digits = v.dropFirst()
            if digits.count == 3 { return "#" + digits.map { "\($0)\($0)" }.joined().uppercased() }
            if digits.count == 6 { return "#" + digits.uppercased() }
        }
        if v.hasPrefix("rgb(") {
            let n = v.dropFirst(4).dropLast().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if n.count == 3 { return String(format: "#%02X%02X%02X", n[0], n[1], n[2]) }
        }
        return nil
    }

    static func transform(_ list: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        let pattern = #/(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)/#
        for match in list.matches(of: pattern) {
            let n = match.2.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }.map { CGFloat($0) }
            guard !n.isEmpty else { continue }
            let t: CGAffineTransform
            switch match.1 {
                case "matrix" where n.count == 6: t = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                case "translate": t = CGAffineTransform(translationX: n[0], y: n.count > 1 ? n[1] : 0)
                case "scale": t = CGAffineTransform(scaleX: n[0], y: n.count > 1 ? n[1] : n[0])
                case "rotate":
                    let r = CGAffineTransform(rotationAngle: n[0] * .pi / 180)
                    t = n.count == 3
                        ? CGAffineTransform(translationX: -n[1], y: -n[2]).concatenating(r).concatenating(CGAffineTransform(translationX: n[1], y: n[2]))
                        : r
                case "skewX": t = CGAffineTransform(a: 1, b: 0, c: tan(n[0] * .pi / 180), d: 1, tx: 0, ty: 0)
                case "skewY": t = CGAffineTransform(a: 1, b: tan(n[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
                default: continue
            }
            // "transform=A B" maps a point through B first, then A.
            result = t.concatenating(result)
        }
        return result
    }
}

// MARK: - SVG path data

enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        var s = Scanner(Array(d.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        var command: UInt8 = 0

        while true {
            if let next = s.command() { command = next } else if !s.hasNumber() { break }
            let relative = command >= 97
            func point() -> CGPoint {
                let x = s.number(), y = s.number()
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            var control: CGPoint?
            switch command | 0x20 {
                case UInt8(ascii: "m"):
                    current = point(); start = current
                    path.move(to: current)
                    command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
                case UInt8(ascii: "l"): current = point(); path.addLine(to: current)
                case UInt8(ascii: "h"):
                    let x = s.number(); current.x = relative ? current.x + x : x; path.addLine(to: current)
                case UInt8(ascii: "v"):
                    let y = s.number(); current.y = relative ? current.y + y : y; path.addLine(to: current)
                case UInt8(ascii: "c"):
                    let c1 = point(), c2 = point(), end = point()
                    path.addCurve(to: end, control1: c1, control2: c2); current = end; control = c2
                case UInt8(ascii: "s"):
                    let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let c2 = point(), end = point()
                    path.addCurve(to: end, control1: c1, control2: c2); current = end; control = c2
                case UInt8(ascii: "q"):
                    let c = point(), end = point()
                    path.addQuadCurve(to: end, control: c); current = end; control = c
                case UInt8(ascii: "t"):
                    let c = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let end = point()
                    path.addQuadCurve(to: end, control: c); current = end; control = c
                case UInt8(ascii: "a"):
                    let rx = s.number(), ry = s.number(), angle = s.number(), large = s.flag(), sweep = s.flag()
                    let end = point()
                    arc(path, from: current, rx: rx, ry: ry, degrees: angle, large: large, sweep: sweep, to: end)
                    current = end
                case UInt8(ascii: "z"):
                    // Numbers can't follow Z without a new command; stop rather than loop.
                    path.closeSubpath(); current = start; command = 0
                default: return path
            }
            // S reflects only a C/S control point and T only a Q/T one; close enough for icon art.
            lastControl = control
            if s.failed { break }
        }
        return path
    }

    /// SVG elliptical arc → cubic Béziers (SVG 1.1 appendix F.6.5).
    static func arc(_ path: CGMutablePath, from p0: CGPoint, rx: CGFloat, ry: CGFloat, degrees: CGFloat,
                    large: Bool, sweep: Bool, to p1: CGPoint) {
        var rx = abs(rx), ry = abs(ry)
        guard p0 != p1 else { return }
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
        let phi = degrees * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments), k = 4.0 / 3.0 * tan(step / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cosPhi * x - ry * sinPhi * y, y: cy + rx * sinPhi * x + ry * cosPhi * y)
        }
        for i in 0..<segments {
            let a1 = theta + CGFloat(i) * step, a2 = a1 + step
            path.addCurve(
                to: i == segments - 1 ? p1 : map(cos(a2), sin(a2)),
                control1: map(cos(a1) - k * sin(a1), sin(a1) + k * cos(a1)),
                control2: map(cos(a2) + k * sin(a2), sin(a2) - k * cos(a2))
            )
        }
    }

    struct Scanner {
        let bytes: [UInt8]
        var i = 0
        var failed = false
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skip() {
            while i < bytes.count, [32, 44, 9, 10, 13].contains(bytes[i]) { i += 1 }
        }
        mutating func command() -> UInt8? {
            skip()
            guard i < bytes.count, (65...90).contains(bytes[i]) || (97...122).contains(bytes[i]), bytes[i] != 101, bytes[i] != 69
            else { return nil }
            i += 1
            return bytes[i - 1]
        }
        mutating func hasNumber() -> Bool {
            skip()
            return i < bytes.count && (bytes[i] == 45 || bytes[i] == 43 || bytes[i] == 46 || (48...57).contains(bytes[i]))
        }
        mutating func number() -> CGFloat {
            guard hasNumber() else { failed = true; return 0 }
            let start = i
            if bytes[i] == 45 || bytes[i] == 43 { i += 1 }
            while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 }
            if i < bytes.count, bytes[i] == 46 { i += 1; while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 } }
            if i < bytes.count, bytes[i] == 101 || bytes[i] == 69 {
                i += 1
                if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
                while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 }
            }
            return CGFloat(Double(String(decoding: bytes[start..<i], as: UTF8.self)) ?? 0)
        }
        /// Arc flags may be packed without separators ("a1 1 0 01.5.5").
        mutating func flag() -> Bool {
            skip()
            guard i < bytes.count else { failed = true; return false }
            i += 1
            return bytes[i - 1] == 49
        }
    }
}

// MARK: - Layers

/// The weights every template carries, at Small scale: (template id, CoreUI weight, template x).
let weights = [("Ultralight-S", 1, 515.0), ("Regular-S", 4, 1405.0), ("Black-S", 9, 2888.0)]

/// One shape of the symbol, in template coordinates (baseline at y = 0, y grows down).
struct Layer {
    enum Role { case fill, erase, knockout }

    /// One outline per entry in `weights`.
    var paths: [CGPath]
    /// "#RRGGBB", or an Apple colour name ("tintColor", "systemGreenColor", "white").
    var color: String
    var opacity: CGFloat = 1
    /// "primary", "secondary" or "tertiary".
    var hierarchy = "primary"
    /// `erase` is an invisible cut-out; `knockout` cuts out, then draws itself.
    var monochrome = Role.fill
    var hierarchical = Role.fill
    var multicolor = Role.fill
}

/// Paint runs → layers. A run that sits inside an earlier one is carved out of it
/// in monochrome and hierarchical; inside a carved one, filled again.
func svgLayers(from paints: [Paint], viewBox: CGRect) -> [Layer] {
    var runs: [Paint] = []
    for paint in paints {
        if let last = runs.last, last.color == paint.color, last.opacity == paint.opacity {
            runs[runs.count - 1].path = last.path.union(paint.path)
        } else {
            runs.append(paint)
        }
    }
    var carved = Array(repeating: false, count: runs.count)
    for i in runs.indices {
        let box = runs[i].path.boundingBoxOfPath
        let samples = (0..<24).flatMap { x in (0..<24).map { y in
            CGPoint(x: box.minX + box.width * (CGFloat(x) + 0.5) / 24, y: box.minY + box.height * (CGFloat(y) + 0.5) / 24)
        } }.filter { runs[i].path.contains($0) }
        guard !samples.isEmpty else { continue }
        if let parent = (0..<i).reversed().first(where: { j in
            Double(samples.filter { runs[j].path.contains($0) }.count) >= 0.95 * Double(samples.count)
        }) {
            carved[i] = !carved[parent]
        }
    }
    // An 80-unit square centred on the cap height, like the app's vault.symbols.2.
    let side = max(viewBox.width, viewBox.height), scale = 80 / side
    var place = CGAffineTransform(translationX: -viewBox.minX + (side - viewBox.width) / 2,
                                  y: -viewBox.minY + (side - viewBox.height) / 2)
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: 0, y: -capline / 2 - 40))
    return runs.indices.map { i in
        let path = runs[i].path.copy(using: &place)!
        return Layer(paths: Array(repeating: path, count: weights.count), color: runs[i].color, opacity: runs[i].opacity,
                     hierarchy: carved[i] ? "secondary" : "primary",
                     monochrome: carved[i] ? .erase : .fill, hierarchical: carved[i] ? .knockout : .fill)
    }
}

// Weights are interpolated, so each layer's path needs the same commands at every
// weight; actool silently drops a symbol whose weights differ. CoreGraphics' boolean
// operations restructure a path differently at each size, so nothing below uses
// them on per-weight art.

/// The path's commands, e.g. "MLCZ": what must match across weights.
func structure(_ path: CGPath) -> String {
    var s = ""
    path.applyWithBlock { s.append(["M", "L", "Q", "C", "Z"][Int($0.pointee.type.rawValue)]) }
    return s
}

/// The filled shape at one weight: fills added, cut-outs taken away. A lone layer is
/// returned untouched, so its weights stay compatible.
func outline(_ layers: [Layer], weight w: Int) -> CGPath {
    if layers.count == 1, layers[0].monochrome != .erase { return layers[0].paths[w] }
    return layers.reduce(CGMutablePath() as CGPath) { shape, layer in
        layer.monochrome == .erase ? shape.subtracting(layer.paths[w]) : shape.union(layer.paths[w])
    }
}

/// Subpaths as their start point and segments (type, control points, end point).
func contours(_ path: CGPath) -> [(start: CGPoint, segments: [(CGPathElementType, [CGPoint], CGPoint)], closed: Bool)] {
    var result: [(start: CGPoint, segments: [(CGPathElementType, [CGPoint], CGPoint)], closed: Bool)] = []
    path.applyWithBlock { pointer in
        let e = pointer.pointee
        switch e.type {
            case .moveToPoint: result.append((e.points[0], [], false))
            case .addLineToPoint: result[result.count - 1].segments.append((.addLineToPoint, [], e.points[0]))
            case .addQuadCurveToPoint: result[result.count - 1].segments.append((.addQuadCurveToPoint, [e.points[0]], e.points[1]))
            case .addCurveToPoint: result[result.count - 1].segments.append((.addCurveToPoint, [e.points[0], e.points[1]], e.points[2]))
            case .closeSubpath: result[result.count - 1].closed = true
            @unknown default: break
        }
    }
    return result
}

/// Every subpath drawn the other way round, which flips its winding.
func reversed(_ path: CGPath) -> CGPath {
    let out = CGMutablePath()
    for contour in contours(path) {
        let points = [contour.start] + contour.segments.map(\.2)
        out.move(to: points.last!)
        for (i, segment) in contour.segments.enumerated().reversed() {
            switch segment.0 {
                case .addCurveToPoint: out.addCurve(to: points[i], control1: segment.1[1], control2: segment.1[0])
                case .addQuadCurveToPoint: out.addQuadCurve(to: points[i], control: segment.1[0])
                default: out.addLine(to: points[i])
            }
        }
        if contour.closed { out.closeSubpath() }
    }
    return out
}

/// Signed area of the path's largest subpath, from its on-curve points: the sign is its winding.
func winding(_ path: CGPath) -> CGFloat {
    contours(path).map { contour in
        let p = [contour.start] + contour.segments.map(\.2)
        return zip(p, p.dropFirst() + [p[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y } / 2
    }.max { abs($0) < abs($1) } ?? 0
}

/// `glyph` (one outline per weight) cut out of the enclosure's body. It fills just
/// over half the enclosure, a little below centre so a page's folded corner stays clear.
///
/// The cut is a real hole: the glyph is added to each enclosure layer it sits on,
/// wound the other way. Xcode's asset catalog editor doesn't draw clear-behind
/// layers, and a boolean subtraction would break weight compatibility. The glyph
/// itself shows only in multicolor, in white.
func enclose(_ enclosure: [Layer], glyph: [CGPath]) -> [Layer] {
    var cut = Layer(paths: [], color: "white", monochrome: .erase, hierarchical: .erase)
    for w in weights.indices {
        let body = outline(enclosure, weight: w).boundingBoxOfPath, art = glyph[w].boundingBoxOfPath
        let scale = 0.55 * min(body.width, body.height) / max(art.width, art.height)
        var place = CGAffineTransform(translationX: -art.midX, y: -art.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: body.midX, y: body.midY + 0.1 * body.height))
        cut.paths.append(glyph[w].copy(using: &place)!)
    }
    var holed = enclosure
    for i in holed.indices where holed[i].monochrome == .fill
        && holed[i].paths[0].boundingBoxOfPath.contains(cut.paths[0].boundingBoxOfPath) {
        holed[i].paths = zip(holed[i].paths, cut.paths).map { layer, art in
            let path = layer.mutableCopy()!
            path.addPath(winding(layer) * winding(art) > 0 ? reversed(art) : art)
            return path
        }
    }
    return holed + [cut]
}

struct Refusal: Error, CustomStringConvertible { var description: String }

/// Apple's own symbols, read from macOS's CoreGlyphs catalog through CoreUI. That's
/// private API, which is fine for a script that never ships in the app; if a macOS
/// update moves it, this enum is the only part to fix.
enum SystemSymbols {
    static let resources = URL(filePath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")
    static let restrictions = strings("symbol_restrictions.strings")
    static let aliases = strings("name_aliases.strings")

    private static func strings(_ file: String) -> [String: String] {
        (NSDictionary(contentsOf: resources.appending(path: file)) as? [String: String]) ?? [:]
    }

    private static let catalog: AnyObject = {
        dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW)
        let type = NSClassFromString("CUICatalog") as! NSObject.Type
        let initializer = NSSelectorFromString("initWithURL:error:")
        typealias Init = @convention(c) (AnyObject, Selector, NSURL, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let instance = type.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        return unsafeBitCast(class_getMethodImplementation(type, initializer), to: Init.self)(
            instance, initializer, resources.appending(path: "Assets.car") as NSURL, nil)!
    }()

    private static func glyph(_ name: String, weight: Int) -> NSObject? {
        let selector = NSSelectorFromString("namedVectorGlyphWithName:scaleFactor:deviceIdiom:layoutDirection:glyphSize:glyphWeight:glyphPointSize:appearanceName:")
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, CGFloat, Int, Int, Int, Int, CGFloat, NSString?) -> AnyObject?
        let lookup = unsafeBitCast(catalog.method(for: selector), to: Lookup.self)
        // Size 1 is Small; templates are drawn at 100 pt.
        return lookup(catalog, selector, name as NSString, 1, 0, 0, 1, weight, 100, nil) as? NSObject
    }

    private static func leaves(_ glyph: NSObject, _ key: String) -> [NSObject] {
        func flatten(_ layer: NSObject) -> [NSObject] {
            let sublayers = layer.value(forKey: "sublayers") as? [NSObject] ?? []
            return sublayers.isEmpty ? [layer] : sublayers.flatMap(flatten)
        }
        return (glyph.value(forKey: key) as? [NSObject] ?? []).flatMap(flatten)
    }

    /// A layer's `shape`, or a glyph's whole `CGPath`; both return a bare CGPathRef.
    private static func path(_ object: NSObject, _ name: String) -> CGPath? {
        let selector = NSSelectorFromString(name)
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<CGPath>?
        return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)?.takeUnretainedValue()
    }
    private static func shape(_ layer: NSObject) -> CGPath? { path(layer, "shape") }
    private static func outline(_ glyph: NSObject) -> CGPath? { path(glyph, "CGPath") }

    /// Layers plus each weight's left and right margins.
    static func layers(_ requested: String) throws -> ([Layer], [ClosedRange<CGFloat>]) {
        let name = aliases[requested] ?? requested
        if let rule = restrictions[name] { throw Refusal(description: rule) }
        var layers: [Layer] = [], margins: [ClosedRange<CGFloat>] = []
        for (w, weight) in weights.enumerated() {
            guard let glyph = glyph(name, weight: weight.1) else { throw Refusal(description: "no SF Symbol named \(requested)") }
            // CoreUI shapes are y-down from the glyph's top; templates hang from the baseline,
            // with the glyph's bottom `baselineOffset` below it.
            let height = outline(glyph)?.boundingBoxOfPath.maxY ?? 0
            let baseline = glyph.value(forKey: "baselineOffset") as? CGFloat ?? 0
            var place = CGAffineTransform(translationX: 0, y: baseline - height)
            let monochrome = leaves(glyph, "monochromeLayers")
            let multicolor = leaves(glyph, "multicolorLayers"), hierarchical = leaves(glyph, "paletteLayers")
            var box = CGRect.null
            for (i, layer) in monochrome.enumerated() {
                guard let path = shape(layer)?.copy(using: &place) else { throw Refusal(description: "\(requested): layer \(i) has no outline") }
                box = box.union(path.boundingBoxOfPath)
                if w > 0 { layers[i].paths.append(path); continue }
                let erases = layer.value(forKey: "isEraserLayer") as? Bool == true
                var entry = Layer(paths: [path], color: "tintColor", monochrome: erases ? .erase : .fill,
                                  hierarchical: erases ? .erase : .fill, multicolor: erases ? .erase : .fill)
                // Each mode's layer name is its template class, e.g. "hierarchical-0:secondary".
                if multicolor.count == monochrome.count {
                    entry.color = multicolor[i].value(forKey: "fillColorName") as? String ?? "tintColor"
                    entry.multicolor = multicolor[i].value(forKey: "isEraserLayer") as? Bool == true ? .erase : .fill
                }
                if hierarchical.count == monochrome.count {
                    entry.hierarchy = String((hierarchical[i].value(forKey: "name") as? String ?? "").split(separator: ":").last ?? "primary")
                    entry.hierarchical = hierarchical[i].value(forKey: "isEraserLayer") as? Bool == true ? .erase : .fill
                }
                layers.append(entry)
            }
            margins.append(box.minX...box.maxX)
        }
        return (layers, margins)
    }
}

// MARK: - Symbol template

let capline = 70.459

func pathData(_ path: CGPath) -> String {
    func f(_ v: CGFloat) -> String {
        var s = String(format: "%.3f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
    func p(_ pt: CGPoint) -> String { "\(f(pt.x)) \(f(pt.y))" }
    var d = ""
    path.applyWithBlock { element in
        let e = element.pointee, pts = e.points
        switch e.type {
            case .moveToPoint: d += "M\(p(pts[0]))"
            case .addLineToPoint: d += "L\(p(pts[0]))"
            case .addQuadCurveToPoint: d += "Q\(p(pts[0])) \(p(pts[1]))"
            case .addCurveToPoint: d += "C\(p(pts[0])) \(p(pts[1])) \(p(pts[2]))"
            case .closeSubpath: d += "Z"
            @unknown default: break
        }
    }
    return d
}

func template(_ layers: [Layer], margins: [ClosedRange<CGFloat>]) -> String {
    func role(_ role: Layer.Role) -> String {
        switch role {
            case .fill: ""
            case .erase: "opacity:0.0;-sfsymbols-clear-behind:true;"
            case .knockout: "-sfsymbols-clear-behind:true;"
        }
    }
    var style = [".defaults {-sfsymbols-variable-value-mode:color;-sfsymbols-draw-reverses-motion-groups:true}"]
    var classes: [String] = []
    for (i, layer) in layers.enumerated() {
        // Custom colours need a class of their own carrying the fill; Apple's names resolve themselves.
        let custom = layer.color.hasPrefix("#")
        let colorClass = "multicolor-\(i):\(custom ? "c\(i)" : layer.color)"
        let paint = layer.multicolor == .fill
            ? (custom ? "fill:\(layer.color);" : "") + (layer.opacity < 1 ? String(format: "opacity:%.2f;", layer.opacity) : "")
            : role(layer.multicolor)
        style.append(".monochrome-\(i) {\(role(layer.monochrome))-sfsymbols-motion-group:0}")
        style.append(".\(colorClass) {\(paint)-sfsymbols-motion-group:0}")
        style.append(".hierarchical-\(i):\(layer.hierarchy) {\(role(layer.hierarchical))-sfsymbols-motion-group:0}")
        classes.append("monochrome-\(i) \(colorClass) hierarchical-\(i):\(layer.hierarchy) SFSymbolsPreviewWireframe")
    }
    let margins = zip(weights, margins).map { weight, margin in """
          <line id="left-margin-\(weight.0)" x1="\(weight.2 + margin.lowerBound)" x2="\(weight.2 + margin.lowerBound)" y1="600" y2="720"/>
          <line id="right-margin-\(weight.0)" x1="\(weight.2 + margin.upperBound)" x2="\(weight.2 + margin.upperBound)" y1="600" y2="720"/>
        """ }.joined(separator: "\n")
    let glyphs = weights.enumerated().map { w, weight in
        let paths = layers.indices.map { "   <path class=\"\(classes[$0])\" d=\"\(pathData(layers[$0].paths[w]))\"/>" }
        return "  <g id=\"\(weight.0)\" transform=\"matrix(1 0 0 1 \(weight.2) 696)\">\n\(paths.joined(separator: "\n"))\n  </g>"
    }.joined(separator: "\n")

    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 3300 2200">
     <!--Generated by Scripts/IconPack/IconPack.swift, template writer version: "138.0.0"-->
     <style>\(style.joined(separator: "\n"))
    .SFSymbolsPreviewWireframe {fill:none;opacity:1.0;stroke:black;stroke-width:0.5}
    </style>
     <g id="Notes">
      <text id="template-version">Template v.7.0</text>
     </g>
     <g id="Guides">
      <line id="Baseline-S" x1="263" x2="3036" y1="696" y2="696"/>
      <line id="Capline-S" x1="263" x2="3036" y1="\(696 - capline)" y2="\(696 - capline)"/>
      <line id="Baseline-M" x1="263" x2="3036" y1="1126" y2="1126"/>
      <line id="Capline-M" x1="263" x2="3036" y1="\(1126 - capline)" y2="\(1126 - capline)"/>
      <line id="Baseline-L" x1="263" x2="3036" y1="1556" y2="1556"/>
      <line id="Capline-L" x1="263" x2="3036" y1="\(1556 - capline)" y2="\(1556 - capline)"/>
    \(margins)
     </g>
     <g id="Symbols">
    \(glyphs)
     </g>
    </svg>

    """
}

// MARK: - Run

func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

let arguments = CommandLine.arguments
var manifestPath = "Scripts/IconPack/pack.json"
if let flag = arguments.firstIndex(of: "--manifest") {
    guard flag + 1 < arguments.count, !arguments[flag + 1].hasPrefix("--") else {
        throw Refusal(description: "--manifest needs a repo-relative JSON path")
    }
    manifestPath = arguments[flag + 1]
}
var manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: repo.appending(path: manifestPath)))
if let selection = manifest.symbolsFrom {
    guard manifest.symbols.isEmpty else { throw Refusal(description: "Use symbols or symbolsFrom, not both") }
    manifest.symbols = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: repo.appending(path: selection))).symbols
}
let output = repo.appending(path: manifest.output)
let fm = FileManager.default
try fm.createDirectory(at: output, withIntermediateDirectories: true)
try json(["info": ["author": "xcode", "version": 1], "properties": ["provides-namespace": true]])
    .write(to: output.appending(path: "Contents.json"))

var report: [String] = [], built: Set<String> = []

/// The artwork for `from`: a repo-relative .svg, or the SVG inside a Material imageset.
func source(_ from: String) throws -> URL {
    if from.hasSuffix(".svg") { return repo.appending(path: from) }
    let set = repo.appending(path: "\(manifest.sources)/\(from).imageset")
    guard let svg = try fm.contentsOfDirectory(atPath: set.path()).first(where: { $0.hasSuffix(".svg") }) else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: set.path()])
    }
    return set.appending(path: svg)
}

/// A finished SF Symbol template rather than plain artwork.
func isTemplate(_ url: URL) -> Bool {
    (try? String(contentsOf: url, encoding: .utf8))?.contains(#"<g id="Symbols""#) == true
}

/// Layers and per-weight margins for an SF Symbol, a template or plain artwork, plus the reader's notes.
func artwork(from: String) throws -> ([Layer], [ClosedRange<CGFloat>], [String]) {
    if from.hasPrefix("sf:") {
        let (layers, margins) = try SystemSymbols.layers(String(from.dropFirst(3)))
        return (layers, margins, [])
    }
    let url = try source(from)
    if isTemplate(url) {
        // Each weight's own drawing, as one shape.
        let paths = try weights.map { weight in
            let paints = try SVGReader(url: url, scope: weight.0).paints
            guard let first = paints.first else { throw Refusal(description: "\(from) has no \(weight.0) glyph") }
            return paints.dropFirst().reduce(first.path) { $0.union($1.path) }
        }
        let margins = paths.map { $0.boundingBoxOfPath.minX...$0.boundingBoxOfPath.maxX }
        return ([Layer(paths: paths, color: "tintColor")], margins, [])
    }
    let reader = try SVGReader(url: url)
    return (svgLayers(from: reader.paints, viewBox: reader.viewBox), Array(repeating: 0...80, count: weights.count), reader.problems.sorted())
}

func write(_ svg: String, as symbol: Manifest.Symbol) throws {
    let set = output.appending(path: "\(symbol.name).symbolset")
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    try svg.write(to: set.appending(path: "\(symbol.name).svg"), atomically: true, encoding: .utf8)
    try json([
        "info": ["author": "xcode", "version": 1],
        "properties": ["symbol-rendering-intent": symbol.rendering ?? "multicolor"],
        "symbols": [["filename": "\(symbol.name).svg", "idiom": "universal"]],
    ]).write(to: set.appending(path: "Contents.json"))
    built.insert("\(symbol.name).symbolset")
}

for symbol in manifest.symbols {
    var layers: [Layer], margins: [ClosedRange<CGFloat>], notes: [String]
    do {
        if symbol.glyph == nil, !symbol.from.hasPrefix("sf:"), case let url = try source(symbol.from), isTemplate(url) {
            try write(String(contentsOf: url, encoding: .utf8), as: symbol)
            report.append("\(symbol.name): as drawn")
            continue
        }
        (layers, margins, notes) = try artwork(from: symbol.from)
        if let glyph = symbol.glyph {
            let (art, _, artNotes) = try artwork(from: glyph)
            layers = enclose(layers, glyph: weights.indices.map { outline(art, weight: $0) })
            notes += artNotes
        }
    } catch {
        report.append("\(symbol.name): skipped — \(error)")
        continue
    }
    if let i = layers.firstIndex(where: { Set($0.paths.map(structure)).count > 1 }) {
        report.append("\(symbol.name): skipped — layer \(i) has a different path at each weight, which actool would silently drop")
        continue
    }
    for (i, color) in (symbol.palette ?? []).enumerated() where i < layers.count {
        if color == "tintColor" { layers[i].color = "tintColor" }
        else if let color, let hex = SVGReader.color(color) { layers[i].color = hex }
    }
    try write(template(layers, margins: margins), as: symbol)
    let cut = layers.filter { $0.monochrome != .fill }.count
    report.append("\(symbol.name): \(layers.count) layer(s), \(cut) cut out" + (notes.isEmpty ? "" : " — " + notes.joined(separator: ", ")))
}
for stale in try fm.contentsOfDirectory(atPath: output.path()) where stale.hasSuffix(".symbolset") && !built.contains(stale) {
    try fm.removeItem(at: output.appending(path: stale))
    report.append("removed \(stale)")
}
print(report.joined(separator: "\n"))

// actool compiles just this folder so a bad symbol can't hide behind the rest of the catalog.
let work = fm.temporaryDirectory.appending(path: "IconPack-\(ProcessInfo.processInfo.processIdentifier)")
let catalog = work.appending(path: "Pack.xcassets"), bundle = work.appending(path: "Pack.bundle")
try fm.createDirectory(at: catalog, withIntermediateDirectories: true)
try fm.createDirectory(at: bundle.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
try json(["info": ["author": "xcode", "version": 1]]).write(to: catalog.appending(path: "Contents.json"))
try fm.copyItem(at: output, to: catalog.appending(path: output.lastPathComponent))
try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "local.typenbash.iconpack", "CFBundlePackageType": "BNDL"], format: .xml, options: 0
).write(to: bundle.appending(path: "Contents/Info.plist"))

let actool = Process()
actool.executableURL = URL(filePath: "/usr/bin/xcrun")
actool.arguments = ["actool", catalog.path(), "--compile", bundle.appending(path: "Contents/Resources").path(),
                    "--platform", "macosx", "--minimum-deployment-target", "26.0",
                    "--output-format", "human-readable-text", "--errors", "--warnings"]
let pipe = Pipe()
actool.standardOutput = pipe
actool.standardError = FileHandle.nullDevice
try actool.run()
let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
actool.waitUntilExit()
// One line per symbol: "pack/name: reason".
let issues = log.split(separator: "\n").compactMap { line -> String? in
    guard line.contains("[universal]"), let set = line.range(of: "symbol image set ") else { return nil }
    return line[set.upperBound...].replacingOccurrences(of: "is not suitable: Symbol image file '(null)' ", with: "")
}
// actool can also leave a symbol out without a word, so each one is loaded back.
let compiled = Bundle(url: bundle)!
let prefix = output.lastPathComponent
let dropped = built.map { String($0.dropLast(".symbolset".count)) }.sorted()
    .filter { NSImage(symbolName: "\(prefix)/\($0)", bundle: compiled, variableValue: 1) == nil }
let clean = actool.terminationStatus == 0 && issues.isEmpty && dropped.isEmpty && built.count == manifest.symbols.count
print(clean
      ? "actool: \(built.count) symbols compiled cleanly"
      : (["Icon pack validation failed (actool exit \(actool.terminationStatus), \(built.count)/\(manifest.symbols.count) generated)"]
         + issues + dropped.map { "\(prefix)/\($0): missing from the compiled catalog" }).joined(separator: "\n"))
if !clean {
    try? fm.removeItem(at: work)
    exit(1)
}

// Every preview uses the compiled asset, including the default rendering column.
let reviewModes: [NSImage.SymbolConfiguration?] = [
    nil, .preferringMonochrome(), .init(hierarchicalColor: .systemBlue),
    .init(paletteColors: [.systemRed, .systemGreen]), .preferringMulticolor(),
]

/// NSImage's palette configuration otherwise overrides the catalog intent and
/// paints a shield and its lettering the same color. Honor the asset's default.
func reviewConfiguration(_ symbol: Manifest.Symbol, size: CGFloat, tint: NSColor,
                         modeIndex: Int) -> NSImage.SymbolConfiguration {
    var base = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
    let intent = symbol.rendering ?? "multicolor"
    // A single-color palette would also override the authored multicolor layers.
    if modeIndex != 4 && !(modeIndex == 0 && intent == "multicolor") {
        base = base.applying(.init(paletteColors: [tint]))
    }
    let rendering: NSImage.SymbolConfiguration
    if let mode = reviewModes[modeIndex] { rendering = mode }
    else {
        switch intent {
            case "monochrome": rendering = .preferringMonochrome()
            case "hierarchical": rendering = .init(hierarchicalColor: tint)
            default: rendering = .preferringMulticolor()
        }
    }
    return base.applying(rendering)
}

/// Actual sidebar sizes, on light and dark surfaces, shared by sheets and gallery.
func drawReviewSamples(_ symbol: Manifest.Symbol, at origin: CGPoint, modeIndex: Int) {
    for dark in [false, true] {
        let box = CGRect(x: origin.x + 4 + (dark ? 128 : 0), y: origin.y, width: 124, height: 68)
        (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).setFill()
        box.fill()
        for (i, pointSize) in [16.0, 24.0, 40.0].enumerated() {
            let config = reviewConfiguration(symbol, size: pointSize, tint: dark ? .white : .black, modeIndex: modeIndex)
            guard let image = NSImage(symbolName: "\(prefix)/\(symbol.name)", bundle: compiled, variableValue: 1)?
                .withSymbolConfiguration(config) else { continue }
            let fit = image.size, center = box.minX + [17.0, 52.0, 96.0][i]
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                image.draw(in: CGRect(x: center - fit.width / 2, y: box.midY - fit.height / 2, width: fit.width, height: fit.height))
            }
        }
    }
}

func writePNG(_ image: NSImage, to destination: URL) throws {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw Refusal(description: "Could not render \(destination.lastPathComponent)")
    }
    try png.write(to: destination)
}

// Paginate contact sheets so hundreds of icons remain readable at native resolution.
for flag in ["--preview", "--review"] {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { continue }
    let destination = URL(filePath: (arguments[index + 1] as NSString).expandingTildeInPath)
    let modesSheet = flag == "--preview", pageSize = 64
    for start in stride(from: 0, to: manifest.symbols.count, by: pageSize) {
        let page = Array(manifest.symbols[start..<min(start + pageSize, manifest.symbols.count)])
        let pageNumber = start / pageSize + 1
        let tileWidth = modesSheet ? 212.0 : 264.0, tileHeight = modesSheet ? 60.0 : 100.0
        let size = CGSize(width: tileWidth * 4, height: Double((page.count + 3) / 4) * tileHeight + 40)
        let sheet = NSImage(size: size, flipped: true) { _ in
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); CGRect(origin: .zero, size: size).fill()
            let title = modesSheet ? "default · mono · hierarchical · palette · multicolor" : "16 · 24 · 40 pt / default rendering / light + dark"
            ("\(title)  /  page \(pageNumber)" as NSString).draw(at: CGPoint(x: 8, y: 12),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
            for (n, symbol) in page.enumerated() {
                let x = Double(n % 4) * tileWidth, y = 40 + Double(n / 4) * tileHeight
                (symbol.name as NSString).draw(at: CGPoint(x: x + 8, y: y + 4),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black])
                if modesSheet {
                    for c in reviewModes.indices {
                        let config = reviewConfiguration(symbol, size: 26, tint: .black, modeIndex: c)
                        guard let image = NSImage(symbolName: "\(prefix)/\(symbol.name)", bundle: compiled, variableValue: 1)?
                            .withSymbolConfiguration(config) else { continue }
                        let fit = image.size
                        image.draw(in: CGRect(x: x + 22 + Double(c) * 40 - fit.width / 2,
                                              y: y + 40 - fit.height / 2, width: fit.width, height: fit.height))
                    }
                } else {
                    drawReviewSamples(symbol, at: CGPoint(x: x, y: y + 24), modeIndex: 0)
                }
            }
            return true
        }
        let pageURL = start == 0 ? destination : destination.deletingPathExtension()
            .appendingPathExtension(String(format: "%02d.png", pageNumber))
        try writePNG(sheet, to: pageURL)
        print("\(flag.dropFirst(2)): \(pageURL.path())")
    }
}

// Local, dependency-free review gallery. No runtime app assets or mappings change.
if let flag = arguments.firstIndex(of: "--gallery"), flag + 1 < arguments.count {
    let destination = URL(filePath: (arguments[flag + 1] as NSString).expandingTildeInPath)
    let previews = destination.deletingLastPathComponent().appending(path: "curated-previews")
    try fm.createDirectory(at: previews, withIntermediateDirectories: true)
    func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    var cards: [String] = [], empty: [String] = []
    for symbol in manifest.symbols {
        let sprite = NSImage(size: CGSize(width: 264 * reviewModes.count, height: 68), flipped: true) { _ in
            for i in reviewModes.indices {
                drawReviewSamples(symbol, at: CGPoint(x: Double(i) * 264, y: 0), modeIndex: i)
            }
            return true
        }
        try writePNG(sprite, to: previews.appending(path: "\(symbol.name).png"))
        // Check actual default pixels on both surfaces, not merely asset existence.
        let bitmap = NSBitmapImageRep(data: sprite.tiffRepresentation!)!
        let scale = Double(bitmap.pixelsWide) / sprite.size.width
        if symbol.rendering == "monochrome" {
            // Regression check: default shields must retain the same lettering
            // and cutouts as explicit monochrome, rather than becoming solid.
            var mismatch = false
            for y in stride(from: 0, to: Int(68 * scale), by: 2) {
                for x in stride(from: 0, to: Int(264 * scale), by: 2) {
                    let a = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let b = bitmap.colorAt(x: x + Int(264 * scale), y: y)!.usingColorSpace(.deviceRGB)!
                    if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                        + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent) > 0.03 {
                        mismatch = true
                    }
                }
            }
            if mismatch { empty.append("\(symbol.name) (default differs from monochrome intent)") }
        }
        for (side, left) in [("light", 4.0), ("dark", 132.0)] {
            let background = bitmap.colorAt(x: Int((left + 1) * scale), y: Int(scale))!.usingColorSpace(.deviceRGB)!
            var visible = 0
            for y in Int(8 * scale)..<Int(60 * scale) {
                for x in Int((left + 2) * scale)..<Int((left + 122) * scale) {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if abs(pixel.redComponent - background.redComponent) + abs(pixel.greenComponent - background.greenComponent)
                        + abs(pixel.blueComponent - background.blueComponent) > 0.3 { visible += 1 }
                }
            }
            if visible < 8 { empty.append("\(symbol.name) (\(side) default)") }
        }
        let category = symbol.category ?? "Other", matches = symbol.matches ?? []
        let search = ([symbol.name, category, symbol.from] + matches).joined(separator: " ").lowercased()
        let origin = symbol.from.hasPrefix("sf:") ? "SF Symbols" : symbol.from.hasPrefix("simple-icons/") ? "Simple Icons"
            : symbol.from.hasPrefix("icons-creation/icons/") ? "Material base mark" : "Custom symbol"
        cards.append("""
        <article class="card" data-search="\(html(search))" data-category="\(html(category))">
          <h2>\(html(symbol.name))</h2><p class="origin">\(html(origin))</p>
          <div class="sample" role="img" aria-label="\(html(symbol.name)): 16, 24, and 40 points on light and dark surfaces" style="background-image:url('curated-previews/\(symbol.name).png')"></div>
          <details><summary>Source &amp; file matches (\(matches.count))</summary><p>\(html(symbol.from))</p>
          <p>\(html(symbol.reason ?? "Selected base artwork with native symbol rendering."))</p>
          <p class="matches">\(html(matches.isEmpty ? "Review composition; no file mapping proposed." : matches.joined(separator: ", ")))</p></details>
        </article>
        """)
    }
    let categories = Set(manifest.symbols.compactMap(\.category)).sorted()
    let expectedPreviews = Set(manifest.symbols.map { "\($0.name).png" })
    for stale in try fm.contentsOfDirectory(atPath: previews.path())
        where stale.hasSuffix(".png") && !expectedPreviews.contains(stale) {
        try fm.removeItem(at: previews.appending(path: stale))
    }
    let options = categories.map { "<option>\(html($0))</option>" }.joined()
    let document = """
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>File icons — curated review</title>
    <style>
    :root{font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#202326;background:#f3f4f5;--mode:0}
    *{box-sizing:border-box}body{margin:0;padding:32px;max-width:1500px;margin-inline:auto}h1{font-size:30px;letter-spacing:-.7px;margin:0 0 8px}
    .intro{max-width:850px;line-height:1.6;color:#575d65}a{color:#285b95}.tools{position:sticky;top:0;z-index:1;background:#f3f4f5f5;padding:16px 0;display:flex;gap:12px;flex-wrap:wrap;align-items:end}
    label{display:grid;gap:6px;font-size:12px;color:#575d65}input,select{font:inherit;font-size:14px;padding:10px;border:1px solid #cdd2d8;border-radius:8px;background:white;color:#202326}input{width:340px;max-width:80vw}
    #count{font-size:12px;color:#575d65;margin:16px 0}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(294px,1fr));gap:14px}
    .card{background:white;border:1px solid #e0e3e7;border-radius:12px;padding:14px;min-width:0;align-self:start}.card[hidden]{display:none}
    h2{font-size:15px;margin:0 0 6px;overflow-wrap:anywhere}.origin{color:#6d737b;font-size:11px;margin:0 0 14px}.sample{width:264px;height:68px;max-width:100%;background-size:1320px 68px;background-position:calc(var(--mode) * -264px) 0;background-repeat:no-repeat}
    details{font-size:11px;line-height:1.5;margin-top:14px;color:#6d737b;overflow-wrap:anywhere}summary{cursor:pointer;color:#4e5762}details p{max-height:180px;overflow:auto}
    @media(max-width:600px){body{padding:20px 12px}.tools{position:static}.grid{grid-template-columns:1fr}.card{max-width:400px}}
    </style>
    <h1>File icons</h1><p class="intro">\(manifest.symbols.count) compiled symbols for review. Native document and folder enclosures, selected base logos, and your Markdown and config shield compositions. File associations are recorded in the coverage file.</p>
    <p class="intro">Each card shows <strong>16 · 24 · 40 pt</strong>, first on light and then dark. Default uses the compiled asset’s own rendering intent. <a href="curated.json">Selection manifest</a> · <a href="curated-coverage.json">File coverage</a> · <a href="curated-rendering.png">Rendering contact sheets</a></p>
    <div class="tools"><label>Find an icon or file<input id="search" type="search" placeholder="tsconfig, .swift, package.json…"></label>
    <label>Category<select id="category"><option value="">All categories</option>\(options)</select></label>
    <label>Rendering<select id="mode"><option value="0">Default</option><option value="1">Monochrome</option><option value="2">Hierarchical</option><option value="3">Palette</option><option value="4">Multicolor</option></select></label></div>
    <p id="count" aria-live="polite"></p><main class="grid">\(cards.joined(separator: "\n"))</main>
    <script>
    const search=document.querySelector('#search'), category=document.querySelector('#category'), mode=document.querySelector('#mode'), cards=[...document.querySelectorAll('.card')];
    function filter(){const q=search.value.trim().toLowerCase().replace(/^\\./,'');let n=0;for(const card of cards){card.hidden=!(card.dataset.search.includes(q)&&(!category.value||card.dataset.category===category.value));if(!card.hidden)n++;}document.querySelector('#count').textContent=n+' of '+cards.length+' symbols';}
    search.addEventListener('input',filter);category.addEventListener('change',filter);mode.addEventListener('change',()=>document.documentElement.style.setProperty('--mode',mode.value));filter();
    </script></html>
    """
    try document.write(to: destination, atomically: true, encoding: .utf8)
    print("gallery: \(destination.path())")
    guard empty.isEmpty else { throw Refusal(description: "Empty default renderings: \(empty.joined(separator: ", "))") }
    print("render validation: \(manifest.symbols.count) default symbols visible on light and dark; monochrome defaults match explicit rendering")
}
try? fm.removeItem(at: work)
