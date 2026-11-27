// Generates the legend mask atlas for the Lofree Flow 2 (84 keys, ANSI).
// White legends on black, covering the 16u x 6u key grid (304.8 x 114.3 mm).
// Usage: swift legends.swift <out.png> [width]
import AppKit
import CoreText

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "legends.png"
let W = args.count > 2 ? Int(args[2])! : 4096
let U: CGFloat = 19.05
let gridW = 16 * U, gridH = 6 * U
let S = CGFloat(W) / gridW                 // px per mm
let H = Int((gridH * S).rounded())

// Optional colours ("r,g,b" in sRGB 0-1): background then legend. Without them: white-on-black mask.
func rgb(_ s: String) -> [CGFloat] { s.split(separator: ",").map { CGFloat(Double($0)!) } }
let coloured = args.count > 4
let bg = coloured ? rgb(args[3]) : [0, 0, 0]
let fg = coloured ? rgb(args[4]) : [1, 1, 1]
let ctx: CGContext
if coloured {
    ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
} else {
    ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
}
let bgColor = CGColor(srgbRed: bg[0], green: bg[1], blue: bg[2], alpha: 1)
let fgColor = CGColor(srgbRed: fg[0], green: fg[1], blue: fg[2], alpha: 1)
ctx.setFillColor(bgColor)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
// mm space, origin top-left, y down
ctx.translateBy(x: 0, y: CGFloat(H))
ctx.scaleBy(x: S, y: -S)
ctx.setStrokeColor(fgColor)
ctx.setFillColor(fgColor)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let stroke: CGFloat = 0.30
let fontSize: CGFloat = 3.55
let baselineOff: CGFloat = 6.55     // legend baseline below the top of the key cell
let midOff: CGFloat = 5.30          // legend optical centre below the top of the key cell

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
    return base
}

enum Align { case left, center, right }

@discardableResult
func text(_ s: String, x: CGFloat, baseline: CGFloat, size: CGFloat = fontSize,
          align: Align = .center, weight: NSFont.Weight = .regular, tracking: CGFloat = 0.06) -> CGFloat {
    let attr = NSAttributedString(string: s, attributes: [
        .font: font(size, weight),
        .foregroundColor: NSColor(cgColor: fgColor)!,
        .kern: tracking,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - tracking
    var x0 = x
    switch align {
    case .center: x0 = x - w / 2
    case .right: x0 = x - w
    case .left: break
    }
    ctx.saveGState()
    ctx.translateBy(x: x0, y: baseline)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    return w
}

func line(_ pts: [(CGFloat, CGFloat)], closed: Bool = false, w: CGFloat = stroke) {
    guard let f = pts.first else { return }
    ctx.setLineWidth(w)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: f.0, y: f.1))
    for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
    if closed { ctx.closePath() }
    ctx.strokePath()
}

func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, fill: Bool = false, w: CGFloat = stroke) {
    let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
    if fill { ctx.fillEllipse(in: rect) } else { ctx.setLineWidth(w); ctx.strokeEllipse(in: rect) }
}

func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat, w: CGFloat = stroke) {
    ctx.setLineWidth(w)
    ctx.beginPath()
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
    ctx.strokePath()
}

func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, lw: CGFloat = stroke) {
    ctx.setLineWidth(lw)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.strokePath()
}

func rays(_ cx: CGFloat, _ cy: CGFloat, _ r0: CGFloat, _ r1: CGFloat, _ angles: [CGFloat], w: CGFloat = stroke) {
    for a in angles {
        let c = cos(a * .pi / 180), s = sin(a * .pi / 180)
        line([(cx + c * r0, cy + s * r0), (cx + c * r1, cy + s * r1)], w: w)
    }
}

// Outlined triangle pointing in a direction (0 = right, 90 = down, 180 = left, 270 = up)
func triangle(_ cx: CGFloat, _ cy: CGFloat, size: CGFloat, dir: CGFloat) {
    let h = size * 0.86, b = size
    var pts: [(CGFloat, CGFloat)] = [(h * 0.5, 0), (-h * 0.5, -b / 2), (-h * 0.5, b / 2)]
    let a = dir * .pi / 180
    pts = pts.map { (cx + $0.0 * cos(a) - $0.1 * sin(a), cy + $0.0 * sin(a) + $0.1 * cos(a)) }
    line(pts, closed: true)
}

func speaker(_ x: CGFloat, _ cy: CGFloat) {
    line([(x, cy - 0.45), (x + 0.55, cy - 0.45), (x + 1.25, cy - 1.0), (x + 1.25, cy + 1.0),
          (x + 0.55, cy + 0.45), (x, cy + 0.45)], closed: true)
}

// Icons are drawn with their left edge at x and vertical centre at cy.
func icon(_ name: String, x: CGFloat, cy: CGFloat) {
    switch name {
    case "sunLow":
        circle(x + 1.25, cy, 0.5)
        rays(x + 1.25, cy, 1.0, 1.12, stride(from: CGFloat(0), to: 360, by: 45).map { $0 })
    case "sunHigh":
        circle(x + 1.45, cy, 0.58)
        rays(x + 1.45, cy, 1.02, 1.5, stride(from: CGFloat(0), to: 360, by: 45).map { $0 })
    case "mission":
        // two overlapping window outlines
        rrect(x + 0.1, cy - 1.05, 2.0, 1.25, 0.22)
        ctx.setFillColor(bgColor)
        ctx.fill(CGRect(x: x + 1.05, y: cy - 0.42, width: 2.1, height: 1.6))
        ctx.setFillColor(fgColor)
        rrect(x + 1.25, cy - 0.22, 1.75, 1.2, 0.22)
    case "search":
        circle(x + 0.95, cy - 0.2, 0.78)
        line([(x + 1.52, cy + 0.38), (x + 2.15, cy + 1.02)])
    case "kbdLow":
        line([(x + 0.9, cy + 0.75), (x + 2.0, cy + 0.75)])
        rays(x + 1.45, cy + 0.55, 0.75, 1.0, [-90, -45, -135])
        rays(x + 1.45, cy + 0.55, 1.05, 1.3, [0, 180])
    case "kbdHigh":
        line([(x + 1.0, cy + 0.75), (x + 2.1, cy + 0.75)])
        rays(x + 1.55, cy + 0.55, 0.75, 1.45, [-90, -50, -130])
        rays(x + 1.55, cy + 0.55, 1.05, 1.6, [-12, -168])
    case "prev": triangle(x + 1.0, cy, size: 2.1, dir: 180)
    case "next": triangle(x + 1.0, cy, size: 2.1, dir: 0)
    case "playPause":
        rrect(x + 0.15, cy - 1.0, 0.85, 2.0, 0.2)
        rrect(x + 1.45, cy - 1.0, 0.85, 2.0, 0.2)
    case "mute":
        speaker(x, cy)
        line([(x + 1.85, cy - 0.5), (x + 2.85, cy + 0.5)])
        line([(x + 2.85, cy - 0.5), (x + 1.85, cy + 0.5)])
    case "volDown":
        speaker(x, cy)
        arc(x + 1.25, cy, 0.9, -42, 42)
    case "volUp":
        speaker(x, cy)
        arc(x + 1.25, cy, 0.8, -42, 42)
        arc(x + 1.25, cy, 1.45, -42, 42)
    case "screenshot":
        let a = x + 0.1, b = x + 2.5, t = cy - 1.2, bt = cy + 1.2, k: CGFloat = 0.7
        line([(a, t + k), (a, t + 0.25), (a + 0.25, t), (a + k, t)])
        line([(b - k, t), (b - 0.25, t), (b, t + 0.25), (b, t + k)])
        line([(b, bt - k), (b, bt - 0.25), (b - 0.25, bt), (b - k, bt)])
        line([(a + k, bt), (a + 0.25, bt), (a, bt - 0.25), (a, bt - k)])
        line([(x + 1.3, cy - 0.55), (x + 1.3, cy + 0.55)])
        line([(x + 0.75, cy), (x + 1.85, cy)])
    case "mic":
        rrect(x + 0.6, cy - 1.25, 0.8, 1.55, 0.4)
        arc(x + 1.0, cy - 0.15, 0.85, 0, 180)
        line([(x + 1.0, cy + 0.7), (x + 1.0, cy + 1.2)])
        line([(x + 0.55, cy + 1.2), (x + 1.45, cy + 1.2)])
    case "lock":
        rrect(x + 0.1, cy - 0.15, 2.3, 1.35, 0.3)
        // open shackle
        arc(x + 1.25, cy - 0.65, 0.62, 180, 360)
        line([(x + 0.63, cy - 0.65), (x + 0.63, cy - 0.15)])
    case "backspace":
        line([(x, cy), (x + 8.6, cy)])
        line([(x + 1.0, cy - 0.95), (x, cy), (x + 1.0, cy + 0.95)])
    default: break
    }
}

let iconWidth: [String: CGFloat] = [
    "sunLow": 2.5, "sunHigh": 2.95, "mission": 3.1, "search": 2.25, "kbdLow": 2.9, "kbdHigh": 3.2,
    "prev": 1.9, "next": 1.9, "playPause": 2.45, "mute": 2.95, "volDown": 2.3, "volUp": 2.85,
    "screenshot": 2.6, "mic": 2.0, "lock": 2.5,
]

/// "F1" + icon, centred as a group on the key.
func labelWithIcon(_ label: String, _ ic: String, cx: CGFloat, top: CGFloat) {
    let attr = NSAttributedString(string: label, attributes: [.font: font(fontSize), .kern: 0.06])
    let tw = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
    let gap: CGFloat = 0.55
    let iw = iconWidth[ic] ?? 2.5
    let x0 = cx - (tw + gap + iw) / 2
    text(label, x: x0, baseline: top + baselineOff, align: .left)
    icon(ic, x: x0 + tw + gap, cy: top + midOff)
}

/// "1 !" style pair.
func pair(_ a: String, _ b: String, cx: CGFloat, top: CGFloat) {
    text(a, x: cx - 0.7, baseline: top + baselineOff, align: .right)
    text(b, x: cx + 0.7, baseline: top + baselineOff, align: .left)
}

// --- Layout (x, w in units) -------------------------------------------------
struct K { let x: CGFloat; let row: Int; let w: CGFloat }
func cx(_ k: K) -> CGFloat { (k.x + k.w / 2) * U }
func top(_ k: K) -> CGFloat { CGFloat(k.row) * U }

// Row 0
let fIcons = ["sunLow", "sunHigh", "mission", "search", "kbdLow", "kbdHigh", "prev", "playPause", "next", "mute", "volDown", "volUp"]
text("esc", x: 0.5 * U, baseline: baselineOff)
for i in 0..<12 { labelWithIcon("F\(i + 1)", fIcons[i], cx: (CGFloat(i) + 1.5) * U, top: 0) }
labelWithIcon("pts", "screenshot", cx: 13.5 * U, top: 0)
labelWithIcon("ins", "mic", cx: 14.5 * U, top: 0)
labelWithIcon("del", "lock", cx: 15.5 * U, top: 0)

// Row 1
let nums: [(String, String)] = [("`", "~"), ("1", "!"), ("2", "@"), ("3", "#"), ("4", "$"), ("5", "%"), ("6", "^"),
                                ("7", "&"), ("8", "*"), ("9", "("), ("0", ")"), ("-", "—"), ("=", "+")]
for (i, p) in nums.enumerated() { pair(p.0, p.1, cx: (CGFloat(i) + 0.5) * U, top: U) }
icon("backspace", x: 14 * U - 4.3, cy: U + midOff)
text("home", x: 15.5 * U, baseline: U + baselineOff)

// Row 2
text("tab", x: 0.75 * U, baseline: 2 * U + baselineOff)
for (i, ch) in "QWERTYUIOP".enumerated() { text(String(ch), x: (1.5 + CGFloat(i) + 0.5) * U, baseline: 2 * U + baselineOff) }
pair("[", "{", cx: 12.0 * U, top: 2 * U)
pair("]", "}", cx: 13.0 * U, top: 2 * U)
pair("\\", "|", cx: 14.25 * U, top: 2 * U)
text("end", x: 15.5 * U, baseline: 2 * U + baselineOff)

// Row 3
text("caps", x: 0.875 * U, baseline: 3 * U + baselineOff)
circle(1.75 * U - 5.0, 3 * U + midOff + 0.1, 0.3, fill: true)
for (i, ch) in "ASDFGHJKL".enumerated() { text(String(ch), x: (1.75 + CGFloat(i) + 0.5) * U, baseline: 3 * U + baselineOff) }
pair(";", ":", cx: 11.25 * U, top: 3 * U)
pair("'", "\"", cx: 12.25 * U, top: 3 * U)
text("enter", x: (12.75 + 1.125) * U, baseline: 3 * U + baselineOff)
text("pgup", x: 15.5 * U, baseline: 3 * U + baselineOff)
// homing bars on F and J
for col in [3, 6] {
    let c = (1.75 + CGFloat(col) + 0.5) * U
    line([(c - 0.8, 3 * U + 15.3), (c + 0.8, 3 * U + 15.3)], w: 0.32)
}

// Row 4
text("shift", x: 1.125 * U, baseline: 4 * U + baselineOff)
for (i, ch) in "ZXCVBNM".enumerated() { text(String(ch), x: (2.25 + CGFloat(i) + 0.5) * U, baseline: 4 * U + baselineOff) }
pair(",", "<", cx: 9.75 * U, top: 4 * U)
pair(".", ">", cx: 10.75 * U, top: 4 * U)
pair("/", "?", cx: 11.75 * U, top: 4 * U)
text("shift", x: (12.25 + 0.875) * U, baseline: 4 * U + baselineOff)
triangle(14.5 * U, 4 * U + midOff + 0.1, size: 2.3, dir: 270)
text("pgdn", x: 15.5 * U, baseline: 4 * U + baselineOff)

// Row 5
text("ctrl", x: 0.625 * U, baseline: 5 * U + baselineOff)
text("option", x: 1.875 * U, baseline: 5 * U + baselineOff)
text("command", x: 3.125 * U, baseline: 5 * U + baselineOff, size: 3.3)
text("⌘", x: 10.5 * U, baseline: 5 * U + baselineOff + 0.1, size: 3.5, weight: .regular)
text("fn", x: 11.5 * U, baseline: 5 * U + baselineOff)
text("⌥", x: 12.5 * U, baseline: 5 * U + baselineOff + 0.1, size: 3.5, weight: .regular)
triangle(13.5 * U, 5 * U + midOff + 0.25, size: 2.3, dir: 180)
triangle(14.5 * U, 5 * U + midOff + 0.35, size: 2.3, dir: 90)
triangle(15.5 * U, 5 * U + midOff + 0.25, size: 2.3, dir: 0)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(W)x\(H)")
