import Foundation
import CoreGraphics

// Melete app icon: the water clock from the stage, a glass orb half full of Egyptian blue water,
// on a marble ground. Written as an Icon Composer package (AppIcon.icon) so macOS 26 draws the
// glass itself and makes the dark, clear and tinted versions.
//
// Regenerate with ./build_assets/make_icon.sh (needs Xcode). It writes AppIcon.icon, then compiles
// it into Assets.car and AppIcon.icns, which build_native.sh copies into the app.
// AppIcon.icon also opens in Icon Composer for hand edits; rerunning this script overwrites them.
//
// The shapes are plain fills on a 1024 canvas (y down, as in SVG). Keep them simple: in the clear
// and tinted styles the system keeps only the shapes, converted to brightness.

func svgPath(_ p: CGPath) -> String {
    func f(_ q: CGPoint) -> String { String(format: "%.2f %.2f", q.x, q.y) }
    var s = ""
    p.applyWithBlock { e in
        let pts = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: s += "M\(f(pts[0])) "
        case .addLineToPoint: s += "L\(f(pts[0])) "
        case .addQuadCurveToPoint: s += "Q\(f(pts[0])) \(f(pts[1])) "
        case .addCurveToPoint: s += "C\(f(pts[0])) \(f(pts[1])) \(f(pts[2])) "
        case .closeSubpath: s += "Z "
        @unknown default: break
        }
    }
    return s
}

func svg(_ p: CGPath, fill: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">"
        + "<path d=\"\(svgPath(p))\" fill=\"\(fill)\"/></svg>\n"
}

// The orb fills two thirds of the tile; the water stands a little below the middle with one slow swell.
let centre = CGPoint(x: 512, y: 512), radius: CGFloat = 340
let vessel = CGPath(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
let level: CGFloat = 548, swell: CGFloat = 24, wavelength: CGFloat = 400
let below = CGMutablePath()
below.move(to: CGPoint(x: 0, y: level))
for i in 0...256 {
    let x = CGFloat(i) * 1024 / 256
    below.addLine(to: CGPoint(x: x, y: level + swell * sin((x - 140) / wavelength * 2 * .pi)))
}
below.addLine(to: CGPoint(x: 1024, y: 1024))
below.addLine(to: CGPoint(x: 0, y: 1024))
below.closeSubpath()
let water = vessel.intersection(below)

// Layers listed first sit in front. Marble ground (Palette.marble), Egyptian blue water (Palette.kyanos).
// Dark: the empty glass dims so the water carries the icon. Clear and tinted: the water turns white
// and the glass nearly vanishes, so the orb still reads as half full in one colour.
let json = """
{
  "fill" : { "automatic-gradient" : "srgb:0.94902,0.94902,0.93725,1.00000" },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : true,
          "image-name" : "water.svg",
          "name" : "water",
          "fill-specializations" : [
            { "appearance" : "tinted", "value" : { "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" } }
          ]
        },
        {
          "glass" : true,
          "image-name" : "vessel.svg",
          "name" : "vessel",
          "opacity-specializations" : [
            { "value" : 0.55 },
            { "appearance" : "dark", "value" : 0.3 },
            { "appearance" : "tinted", "value" : 0.18 }
          ]
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.15 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}

"""

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build_assets")
let icon = out.appendingPathComponent("AppIcon.icon")
try? FileManager.default.removeItem(at: icon)
try! FileManager.default.createDirectory(at: icon.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try! svg(water, fill: "#2C4AA0").write(to: icon.appendingPathComponent("Assets/water.svg"), atomically: true, encoding: .utf8)
try! svg(vessel, fill: "#FFFFFF").write(to: icon.appendingPathComponent("Assets/vessel.svg"), atomically: true, encoding: .utf8)
try! json.write(to: icon.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("wrote \(icon.path)")
