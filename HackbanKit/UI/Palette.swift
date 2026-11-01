import SwiftUI
import UIKit

/// Hackban's label palette (src/app/_components/ui.tsx), with the same light/dark pairs.
public enum Palette {
    public static let brand = Color(hex: "#ec3750")

    // [subtle, mid, bold]
    static let light: [String: [String]] = [
        "green": ["#baf3db", "#4bce97", "#1f845a"], "yellow": ["#f8e6a0", "#f5cd47", "#946f00"],
        "orange": ["#fedec8", "#fea362", "#c25100"], "red": ["#ffd5d2", "#f87168", "#c9372c"],
        "purple": ["#dfd8fd", "#9f8fef", "#6e5dc6"], "blue": ["#cce0ff", "#579dff", "#0c66e4"],
        "sky": ["#c6edfb", "#6cc3e0", "#227d9b"], "lime": ["#d3f1a7", "#94c748", "#5b7f24"],
        "pink": ["#fdd0ec", "#e774bb", "#ae4787"], "black": ["#dcdfe4", "#8590a2", "#626f86"],
    ]
    static let dark: [String: [String]] = [
        "green": ["#164b35", "#216e4e", "#4bce97"], "yellow": ["#533f04", "#7f5f01", "#e2b203"],
        "orange": ["#702e00", "#a54800", "#fea362"], "red": ["#5d1f1a", "#ae2e24", "#f87168"],
        "purple": ["#352c63", "#5e4db2", "#9f8fef"], "blue": ["#09326c", "#0055cc", "#579dff"],
        "sky": ["#164555", "#206a83", "#6cc3e0"], "lime": ["#37471f", "#4c6b1f", "#94c748"],
        "pink": ["#50253f", "#943d73", "#e774bb"], "black": ["#454f59", "#596773", "#8c9bab"],
    ]

    public static let baseColors = ["green", "yellow", "orange", "red", "purple", "blue", "sky", "lime", "pink", "black"]
    /// All 30 label colors: `green_light`, `green`, `green_dark`, ...
    public static let labelColors: [String] = baseColors.flatMap { ["\($0)_light", $0, "\($0)_dark"] }

    public static let boardColors = ["#0079bf", "#d29034", "#519839", "#b04632", "#89609e", "#cd5a91", "#4bbf6b", "#00aecc", "#838c91"]
    public static let boardGradients = [
        "linear-gradient(135deg, #0c66e4 0%, #37b4c3 100%)",
        "linear-gradient(135deg, #09326c 0%, #0c66e4 100%)",
        "linear-gradient(135deg, #5e4db2 0%, #e774bb 100%)",
        "linear-gradient(135deg, #e34935 0%, #faa53d 100%)",
        "linear-gradient(135deg, #1f845a 0%, #7ee2b8 100%)",
        "linear-gradient(135deg, #172b4d 0%, #44546f 100%)",
    ]

    private static func dynamic(_ l: String, _ d: String) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: d) : UIColor(hex: l) })
    }

    /// Background and text colors for a label chip.
    public static func label(_ color: String?) -> (background: Color, foreground: Color) {
        guard let color, !color.isEmpty else { return (Color(.tertiarySystemFill), .primary) }
        let parts = color.split(separator: "_").map(String.init)
        let base = parts[0]
        let l = light[base] ?? light["black"]!, d = dark[base] ?? dark["black"]!
        switch parts.count > 1 ? parts[1] : "" {
        case "light": return (dynamic(l[0], d[0]), dynamic("#172b4d", "#dee4ea"))
        case "dark": return (dynamic(l[2], d[2]), dynamic("#ffffff", "#1d2125"))
        default: return (dynamic(l[1], d[1]), dynamic("#172b4d", "#ffffff"))
        }
    }

    /// Solid color for covers and list accents.
    public static func solid(_ color: String?) -> Color {
        guard let color, let base = color.split(separator: "_").first.map(String.init), let l = light[base] else { return Color(.systemGray3) }
        return Color(hex: l[1])
    }

    public static func name(_ color: String?) -> String {
        guard let color else { return "No color" }
        let parts = color.split(separator: "_").map(String.init)
        let base = parts[0].capitalized
        if parts.count > 1 { return "\(parts[1] == "light" ? "Subtle" : "Bold") \(base.lowercased())" }
        return base
    }
}

public extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}

public extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let a = hasAlpha ? CGFloat(v & 0xff) / 255 : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

/// A board background: a hex color or `linear-gradient(135deg, #a 0%, #b 100%)`.
public struct BoardBackground: View {
    public var background: String
    public var image: String?

    public init(_ background: String, image: String? = nil) { self.background = background; self.image = image }

    public var body: some View {
        ZStack {
            BoardBackground.fill(background)
            if let image, let url = URL(string: image) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                }
            }
        }
        .clipped()
    }

    public static func colors(_ background: String) -> [Color] {
        let hexes = background.matches(of: /#[0-9a-fA-F]{3,8}/).map { String($0.output) }
        return hexes.isEmpty ? [Color(hex: "#0079bf")] : hexes.map(Color.init(hex:))
    }

    @ViewBuilder public static func fill(_ background: String) -> some View {
        let colors = colors(background)
        if colors.count > 1 {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            colors[0]
        }
    }

    /// The dominant color, for tinting.
    public static func primary(_ background: String) -> Color { colors(background)[0] }
}
