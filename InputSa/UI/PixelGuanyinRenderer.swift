import AppKit

/// Generates pixel-art Guanyin Bodhisattva images programmatically.
/// Keeps the app self-contained with no external image assets required.
/// Style: Japanese minimalist — fine lines, warm gold, lotus, serene expression.
final class PixelGuanyinRenderer {

    static let shared = PixelGuanyinRenderer()

    // MARK: - Color Palette (Japanese Minimalist)
    private enum Color {
        static let transparent  = NSColor.clear
        static let outline      = NSColor(white: 0.15, alpha: 1.0)    // Near-black lines
        static let skin         = NSColor(red: 0.98, green: 0.92, blue: 0.84, alpha: 1.0) // Warm ivory
        static let robe         = NSColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1.0) // Off-white
        static let robeShade    = NSColor(red: 0.87, green: 0.87, blue: 0.84, alpha: 1.0) // Light grey
        static let halo         = NSColor(red: 0.96, green: 0.86, blue: 0.60, alpha: 1.0) // Warm gold
        static let lotus        = NSColor(red: 0.96, green: 0.75, blue: 0.78, alpha: 1.0) // Soft pink
        static let lotusCenter  = NSColor(red: 0.96, green: 0.86, blue: 0.60, alpha: 1.0) // Gold center
        static let vase         = NSColor(red: 0.82, green: 0.90, blue: 0.95, alpha: 1.0) // Celadon
        static let headband     = NSColor(red: 0.96, green: 0.86, blue: 0.60, alpha: 1.0) // Gold
        static let headphone    = NSColor(white: 0.30, alpha: 1.0)    // Dark grey headphones
        static let headphoneGlow = NSColor(red: 0.60, green: 0.80, blue: 1.0, alpha: 0.9) // Blue glow
    }

    // MARK: - 16×16 Menu Icon (static, seated Guanyin silhouette)
    func menuIcon(dark: Bool = false) -> NSImage {
        let size = CGSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            // Simple silhouette: head + robe triangle + halo dots
            let fg = dark ? NSColor.white : NSColor(white: 0.15, alpha: 1)
            fg.setFill()

            // Halo (top arc dots)
            for i in 0..<5 {
                NSRect(x: CGFloat(4 + i * 2), y: 13, width: 1, height: 1).fill()
            }
            // Head
            NSRect(x: 6, y: 10, width: 4, height: 3).fill()
            // Body (trapezoid via rects)
            NSRect(x: 5, y: 7, width: 6, height: 3).fill()
            NSRect(x: 4, y: 4, width: 8, height: 3).fill()
            NSRect(x: 3, y: 1, width: 10, height: 3).fill()
            // Lotus base
            let accent = dark ? NSColor(white: 0.8, alpha: 1) : NSColor(red: 0.96, green: 0.75, blue: 0.78, alpha: 1)
            accent.setFill()
            NSRect(x: 4, y: 0, width: 8, height: 1).fill()
            return true
        }
    }

    // MARK: - 24×24 Badge Icon (seated, hands together, lotus seat)
    func badgeIcon() -> NSImage {
        return drawPixelArt(size: 24, pixels: guanyin24Pixels())
    }

    // MARK: - 64×64 Preferences Banner (detailed, colorful)
    func preferencesIcon() -> NSImage {
        return drawPixelArt(size: 64, pixels: guanyin64Pixels())
    }

    // MARK: - 24×24 Listening Frames (wearing headphones, floating on lotus)
    func listeningFrames(frameIndex: Int) -> NSImage {
        let offset: CGFloat = [0, -1, -2, -1][frameIndex % 4]  // Float animation: 0,-1,-2,-1
        return drawPixelArt(size: 24, pixels: guanyin24ListeningPixels(), yOffset: offset)
    }

    // MARK: - Drawing Engine
    private func drawPixelArt(size: Int, pixels: [[Int]], yOffset: CGFloat = 0) -> NSImage {
        let nsSize = CGSize(width: size, height: size)
        let palette = pixelPalette(forSize: size)

        return NSImage(size: nsSize, flipped: false) { rect in
            for (row, rowPixels) in pixels.enumerated() {
                for (col, colorIndex) in rowPixels.enumerated() {
                    guard colorIndex > 0, colorIndex < palette.count else { continue }
                    let color = palette[colorIndex]
                    color.setFill()
                    let y = CGFloat(size - 1 - row) + yOffset
                    NSRect(x: CGFloat(col), y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
    }

    // MARK: - Color Palettes
    private func pixelPalette(forSize size: Int) -> [NSColor] {
        // Index 0 = transparent, 1 = outline, 2 = skin, 3 = robe, 4 = robe shade,
        // 5 = halo/gold, 6 = lotus pink, 7 = vase/celadon, 8 = headphone, 9 = headphone glow
        return [
            .clear,                 // 0 transparent
            Color.outline,          // 1
            Color.skin,             // 2
            Color.robe,             // 3
            Color.robeShade,        // 4
            Color.halo,             // 5 gold
            Color.lotus,            // 6
            Color.vase,             // 7
            Color.headphone,        // 8
            Color.headphoneGlow,    // 9
            Color.lotusCenter,      // 10
            NSColor(red: 0.92, green: 0.88, blue: 0.82, alpha: 1.0), // 11 warm white background
        ]
    }

    // MARK: - 24×24 Pixel Data: Seated Guanyin (static)
    private func guanyin24Pixels() -> [[Int]] {
        // Row 0 = top of image
        // 0=transparent, 1=outline, 2=skin, 3=robe, 4=shade, 5=gold, 6=lotus, 10=lotus gold
        return [
            [0,0,0,0,0,0,5,5,5,5,5,5,5,5,5,5,5,0,0,0,0,0,0,0], // row 0 halo arc
            [0,0,0,0,0,5,5,0,0,0,0,0,0,0,0,0,5,5,0,0,0,0,0,0], // row 1 halo
            [0,0,0,0,5,5,0,0,0,0,0,0,0,0,0,0,0,5,5,0,0,0,0,0], // row 2 halo
            [0,0,0,0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0], // row 3 headband top
            [0,0,0,0,0,0,0,1,5,5,5,5,5,5,1,0,0,0,0,0,0,0,0,0], // row 4 headband
            [0,0,0,0,0,0,0,1,2,2,2,2,2,2,1,0,0,0,0,0,0,0,0,0], // row 5 forehead
            [0,0,0,0,0,0,0,1,2,1,2,2,1,2,1,0,0,0,0,0,0,0,0,0], // row 6 eyes
            [0,0,0,0,0,0,0,1,2,2,2,2,2,2,1,0,0,0,0,0,0,0,0,0], // row 7 lower face
            [0,0,0,0,0,0,0,1,2,2,1,1,2,2,1,0,0,0,0,0,0,0,0,0], // row 8 nose/mouth
            [0,0,0,0,0,0,1,3,3,3,3,3,3,3,3,1,0,0,0,0,0,0,0,0], // row 9 neck/collar
            [0,0,0,0,0,1,3,3,4,3,3,3,4,3,3,3,1,0,0,0,0,0,0,0], // row 10 chest
            [0,0,0,0,1,3,3,3,4,2,3,3,2,4,3,3,3,1,0,0,0,0,0,0], // row 11 hands/vase area
            [0,0,0,0,1,3,3,3,3,7,7,7,7,3,3,3,3,1,0,0,0,0,0,0], // row 12 vase
            [0,0,0,1,3,3,4,3,3,7,7,7,7,3,3,4,3,3,1,0,0,0,0,0], // row 13 lower robe
            [0,0,0,1,3,3,3,4,3,3,3,3,3,3,4,3,3,3,1,0,0,0,0,0], // row 14 wide robe
            [0,0,1,3,3,3,3,3,4,3,3,3,3,4,3,3,3,3,3,1,0,0,0,0], // row 15
            [0,1,3,3,3,3,3,3,3,4,3,3,4,3,3,3,3,3,3,3,1,0,0,0], // row 16 skirt
            [0,1,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,1,0,0,0], // row 17
            [0,0,1,1,3,3,3,3,3,3,3,3,3,3,3,3,3,3,1,1,0,0,0,0], // row 18 hem
            [0,0,0,0,6,6,6,6,6,10,10,10,10,6,6,6,6,6,0,0,0,0,0,0], // row 19 lotus top
            [0,0,0,0,1,6,6,6,6,10,10,10,10,6,6,6,6,1,0,0,0,0,0,0], // row 20 lotus
            [0,0,0,0,0,1,6,6,10,10,10,10,10,10,6,6,1,0,0,0,0,0,0], // row 21 lotus base
            [0,0,0,0,0,0,1,1,1,6,6,6,6,6,1,1,1,0,0,0,0,0,0,0], // row 22 stem
            [0,0,0,0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0], // row 23 stem bottom
        ]
    }

    // MARK: - 24×24 Listening Guanyin (with pixel headphones)
    private func guanyin24ListeningPixels() -> [[Int]] {
        var pixels = guanyin24Pixels()
        // Add headphones at rows 4-6, columns 6-7 (left) and 16-17 (right)
        // Left earpiece
        pixels[4][6] = 8; pixels[4][7] = 8
        pixels[5][6] = 8; pixels[5][7] = 8
        pixels[6][6] = 8
        // Right earpiece
        pixels[4][15] = 8; pixels[4][16] = 8
        pixels[5][15] = 8; pixels[5][16] = 8
        pixels[6][16] = 8
        // Headband arc connecting them (row 3)
        pixels[3][6] = 8; pixels[3][7] = 8; pixels[3][8] = 8
        pixels[3][14] = 8; pixels[3][15] = 8; pixels[3][16] = 8
        // Glow dots near earpieces
        pixels[4][5] = 9; pixels[4][18] = 9
        return pixels
    }

    // MARK: - 64×64 Detailed Guanyin (preferences banner)
    private func guanyin64Pixels() -> [[Int]] {
        // Generate a scaled-up version of the 24×24 with more detail
        let base = guanyin24Pixels()
        var result = Array(repeating: Array(repeating: 0, count: 64), count: 64)
        let offset = (64 - 24 * 2) / 2  // center horizontally

        for (row, rowPix) in base.enumerated() {
            for (col, colorIdx) in rowPix.enumerated() {
                let targetRow = row * 2 + (64 - 24 * 2) / 2
                let targetCol = col * 2 + offset
                guard targetRow >= 0, targetRow + 1 < 64,
                      targetCol >= 0, targetCol + 1 < 64 else { continue }
                result[targetRow][targetCol]         = colorIdx
                result[targetRow][targetCol + 1]     = colorIdx
                result[targetRow + 1][targetCol]     = colorIdx
                result[targetRow + 1][targetCol + 1] = colorIdx
            }
        }
        return result
    }
}
