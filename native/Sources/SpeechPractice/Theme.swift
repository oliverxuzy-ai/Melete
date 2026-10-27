import SwiftUI
import AppKit
import CoreText

// Melete design tokens. The idea behind them is ancient polychromy: Greek marble was
// painted, and the paint only went where something mattered. Surfaces here stay quiet
// marble; each pigment has exactly one job. See docs/DESIGN.md for the reasoning.

// MARK: - Color

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    /// Resolves per appearance, so one token works in light and dark windows.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let dark0 = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: dark0 ? dark : light)
        })
    }
}

enum Palette {
    /// Window ground: Pentelic marble by day, a blue night by night.
    static let marble = Color(light: 0xF2F2EF, dark: 0x0F1117)
    /// Paper surfaces that hold content.
    static let raised = Color(light: 0xFBFBF9, dark: 0x181B23)
    /// Inset wells and tracks.
    static let well = Color(light: 0xE6E6E0, dark: 0x0A0C11)
    static let ink = Color(light: 0x1A1916, dark: 0xECEAE4)
    /// Hairlines, like the grey veins in marble.
    static let vein = Color(light: 0xDAD9D2, dark: 0x2A2F3A)
    /// Egyptian blue: your voice and everything you can act on.
    static let kyanos = Color(light: 0x2C4AA0, dark: 0x93A8FF)
    /// Cinnabar: only while the microphone is live.
    static let cinnabar = Color(light: 0xC23A1E, dark: 0xFF6E52)
    /// Gilding: rewards, laurels, the reference speaker.
    static let ochre = Color(light: 0xAD7D21, dark: 0xE7BA5C)
    /// Malachite: inside the target.
    static let malachite = Color(light: 0x3B7650, dark: 0x7FC79A)

    static var ink2: Color { ink.opacity(0.64) }
    static var ink3: Color { ink.opacity(0.42) }
}

// MARK: - Type

/// Iowan Old Style (a humanist old style that ships with macOS) for display text and
/// numerals, cascading to Songti SC for Chinese. SF Pro stays the interface face.
enum Typeface {
    static func display(_ size: CGFloat, bold: Bool = false) -> Font {
        cascade(bold ? "IowanOldStyle-Bold" : "IowanOldStyle-Roman",
                bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size)
    }

    /// Quotes and coaching notes. Kaiti plays the role of italic in Chinese typesetting.
    static func italic(_ size: CGFloat) -> Font {
        cascade("IowanOldStyle-Italic", "STKaitiSC-Regular", size)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Building a cascading CTFont is slow enough to show up when a long list of lines is laid
    /// out at once (the reference subtitles), so each face and size is made once.
    static func cascade(_ latin: String, _ cjk: String, _ size: CGFloat) -> Font {
        FontCache.shared.font("\(latin)|\(cjk)|\(size)") {
            let cjkDesc = CTFontDescriptorCreateWithNameAndSize(cjk as CFString, size)
            let attrs: [CFString: Any] = [kCTFontNameAttribute: latin, kCTFontCascadeListAttribute: [cjkDesc]]
            let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
            return Font(CTFontCreateWithFontDescriptor(desc, size, nil))
        }
    }
}

final class FontCache: @unchecked Sendable {
    static let shared = FontCache()
    private var fonts: [String: Font] = [:]
    private let lock = NSLock()

    func font(_ key: String, make: () -> Font) -> Font {
        lock.lock(); defer { lock.unlock() }
        if let f = fonts[key] { return f }
        let f = make()
        fonts[key] = f
        return f
    }
}

// MARK: - Shape

enum Radius {
    static let chip: CGFloat = 8
    static let tile: CGFloat = 14
    static let panel: CGFloat = 20
    static let stage: CGFloat = 30
}

// MARK: - Motion
// Every curve imitates the material it moves. One line each in docs/DESIGN.md.

enum Motion {
    /// Liquid glass merging and splitting: a droplet, so a little give.
    static let glass = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// Text and results that become a record: stamped into stone, no rebound.
    static let stone = Animation.timingCurve(0.2, 0.85, 0.15, 1, duration: 0.34)
    /// Laurel leaves unfurling: a living thing, so it overshoots once.
    static let leaf = Animation.spring(response: 0.55, dampingFraction: 0.6)
    /// One calm breath before you speak (about four seconds in, four out).
    static let breath = Animation.easeInOut(duration: 4).repeatForever(autoreverses: true)
    /// Odometer digits: quick and exact.
    static let ticker = Animation.snappy(duration: 0.28)
    /// Paper sliding over paper.
    static let paper = Animation.easeOut(duration: 0.22)
}

// MARK: - Surfaces

struct PaperSurface: ViewModifier {
    var radius: CGFloat = Radius.panel
    var fill: Color = Palette.raised
    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.vein, lineWidth: 1))
    }
}

extension View {
    func paper(radius: CGFloat = Radius.panel, fill: Color = Palette.raised) -> some View {
        modifier(PaperSurface(radius: radius, fill: fill))
    }

    /// The window ground used behind every page.
    func marbleGround() -> some View {
        background(Palette.marble.ignoresSafeArea())
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Palette.vein).frame(height: 1) }
}

// MARK: - Ornament

/// A Greek key (meander) band. Used sparingly as a structural divider.
struct Meander: Shape {
    var unit: CGFloat = 6
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let u = unit
        let h = rect.height
        let step = u * 4
        var x = rect.minX
        let y0 = rect.minY + (h - u * 3) / 2
        p.move(to: CGPoint(x: x, y: y0 + u * 3))
        while x + step <= rect.maxX + 0.5 {
            // One key: up, right, down, left, down, right along the base.
            p.addLine(to: CGPoint(x: x, y: y0))
            p.addLine(to: CGPoint(x: x + u * 3, y: y0))
            p.addLine(to: CGPoint(x: x + u * 3, y: y0 + u * 2))
            p.addLine(to: CGPoint(x: x + u, y: y0 + u * 2))
            p.addLine(to: CGPoint(x: x + u, y: y0 + u))
            p.addLine(to: CGPoint(x: x + u * 2, y: y0 + u))
            p.move(to: CGPoint(x: x, y: y0 + u * 3))
            p.addLine(to: CGPoint(x: x + step, y: y0 + u * 3))
            x += step
        }
        return p
    }
}

struct MeanderRule: View {
    var color: Color = Palette.vein
    var body: some View {
        Meander(unit: 4).stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .square, lineJoin: .miter))
            .frame(height: 14)
            .accessibilityHidden(true)
    }
}

/// A pointed laurel leaf (a vesica), drawn along its local y axis.
struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = CGPoint(x: rect.midX, y: rect.minY)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY)
        p.move(to: bottom)
        p.addQuadCurve(to: top, control: CGPoint(x: rect.minX - rect.width * 0.15, y: rect.midY))
        p.addQuadCurve(to: bottom, control: CGPoint(x: rect.maxX + rect.width * 0.15, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Buttons

/// The one prominent action on a page: Egyptian blue glass.
struct PrimaryGlass: ViewModifier {
    var tint: Color = Palette.kyanos
    func body(content: Content) -> some View {
        content.buttonStyle(.glassProminent).tint(tint).controlSize(.large)
    }
}

extension View {
    func primaryGlass(_ tint: Color = Palette.kyanos) -> some View { modifier(PrimaryGlass(tint: tint)) }
}

/// A quiet text button that reads as part of the page.
struct InkButtonStyle: ButtonStyle {
    var color: Color = Palette.kyanos
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.ui(13, .medium))
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Formatting helpers

enum Greek {
    /// Greek names used for exercise types and training blocks. Chinese stays the label.
    static let melete = "Μελέτη"
}

