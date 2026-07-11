import AppKit

/// The pixel-art deity shown in the voice HUD. All sprites wear headphones
/// so the ear-particle animations (notes in, nectar out) stay meaningful.
enum HUDCharacter: String, CaseIterable {
    case guanyin
    case maitreya
    case guangong
    case jesus
    case confucius

    var displayName: String {
        switch self {
        case .guanyin:   return "觀世音菩薩"
        case .maitreya:  return "彌勒佛"
        case .guangong:  return "關公"
        case .jesus:     return "耶穌"
        case .confucius: return "孔子"
        }
    }

    /// Headphone ear-cup centers as fractions of the sprite image
    /// (x from left, y from bottom). Measured per artwork by grey-pixel
    /// clustering (scratchpad/ear_detect.py) — re-measure if sprites change.
    var earLeftFrac: CGPoint {
        switch self {
        case .guanyin:   return CGPoint(x: 0.137, y: 0.618)
        case .maitreya:  return CGPoint(x: 0.170, y: 0.753)
        case .guangong:  return CGPoint(x: 0.197, y: 0.706)
        case .jesus:     return CGPoint(x: 0.166, y: 0.674)
        case .confucius: return CGPoint(x: 0.176, y: 0.600)
        }
    }

    var earRightFrac: CGPoint {
        switch self {
        case .guanyin:   return CGPoint(x: 0.859, y: 0.616)
        case .maitreya:  return CGPoint(x: 0.828, y: 0.756)
        case .guangong:  return CGPoint(x: 0.867, y: 0.724)
        case .jesus:     return CGPoint(x: 0.832, y: 0.671)
        case .confucius: return CGPoint(x: 0.827, y: 0.610)
        }
    }

    /// Bundled sprite: Resources/hud/char_<name>.png
    var image: NSImage? {
        if let url = Bundle.main.url(forResource: "char_\(rawValue)", withExtension: "png", subdirectory: "hud"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // Legacy fallback: the original detailed Guanyin artwork.
        if self == .guanyin,
           let url = Bundle.main.url(forResource: "guanyin_hud", withExtension: "png", subdirectory: "hud"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }

    private static let defaultsKey = "com.inputsa.hudCharacter"

    static var current: HUDCharacter {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let c = HUDCharacter(rawValue: raw) else { return .guanyin }
            return c
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
