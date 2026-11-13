// Purpose: CompanionAppearance, how the desktop companion looks: which creature it is, its size
//          (the side of one pixel) and its colour (the creature's own, or one the user picked).
//          Persisted and shared.
// Dependencies: Sources/App/Config/AppTheme.swift (ThemeColor hex helpers),
//               Sources/App/Components/DesignSystem.swift (accent)
// Used by: Sources/App/Supporting/CompanionPlacement.swift (sizes), Sources/App/Views/CompanionView.swift
//          and Sources/App/Components/PillPixelStyle.swift (colour), Sources/App/Supporting/
//          CompanionController.swift (resizes its panels), Sources/App/Views/AppearanceSettingsView.swift
// Notes: User request 2026-10-13: size and colour adjustable in Settings, Appearance; a choice of
//        other creatures may follow later. Sizes are whole-point pixels (2, 3, 4 pt) so the pixel
//        art stays crisp; 3 pt is the size the creature was designed at. One colour for light and
//        dark mode: the creature floats over every app, not inside a themed window. Keys:
//        mm.companionSize (small, medium, large), mm.companionColor (hex, absent = theme accent),
//        mm.companionLastColor (the last own colour, restored when switching back to it),
//        mm.companionAvatar (blob, duck, dog, puppy, pug, cat, coolCat, sweetCat, lime; MascotAvatar), mm.companionComesOnShake
//        (default on: shaking the mouse brings the creature to the pointer),
//        mm.companionShakeStrength (1 gentle to 5 hard, default 3; MouseShakeDetector levels),
//        mm.companionVisibleInScreenShares (default off: the creature is hidden from screen
//        capture and during a screen share; on, viewers see it and it stays).

import AppKit
import Observation
import SwiftUI

extension Notification.Name {
    /// Posted after the companion's size or colour changed.
    static let companionAppearanceChanged = Notification.Name("CompanionAppearanceChanged")
}

@Observable
@MainActor
final class CompanionAppearance {
    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }
        /// The side of one pixel in points.
        var pixel: CGFloat {
            switch self {
            case .small: 2
            case .medium: 3
            case .large: 4
            }
        }
    }

    static let shared = CompanionAppearance()

    private let defaults: UserDefaults
    /// False while init reads the stored values: @Observable runs didSet there too, and a
    /// change notice from inside `shared`'s own initialisation sent observers that read `shared`
    /// into a recursive dispatch_once, which traps (the app crashed at launch).
    @ObservationIgnored private var isLoaded = false

    private func announceChange() {
        guard isLoaded else { return }
        NotificationCenter.default.post(name: .companionAppearanceChanged, object: nil)
    }

    var avatar: MascotAvatar {
        didSet {
            defaults.set(avatar.rawValue, forKey: "mm.companionAvatar")
            announceChange()
        }
    }

    /// Shaking the mouse brings the creature to the pointer.
    var comesOnShake: Bool {
        didSet {
            defaults.set(comesOnShake, forKey: "mm.companionComesOnShake")
            announceChange()
        }
    }

    /// How hard the mouse must be shaken: 1 gentle to 5 hard (MouseShakeDetector.strengths).
    var shakeStrength: Int {
        didSet {
            let clamped = min(max(shakeStrength, MouseShakeDetector.strengths.lowerBound),
                              MouseShakeDetector.strengths.upperBound)
            guard clamped == shakeStrength else { shakeStrength = clamped; return }
            defaults.set(shakeStrength, forKey: "mm.companionShakeStrength")
            announceChange()
        }
    }

    /// The name of a shake strength, for VoiceOver and the settings catalog.
    static func shakeStrengthLabel(_ strength: Int) -> String {
        switch strength {
        case ...1: "Gentle"
        case 2: "Light"
        case 3: "Normal"
        case 4: "Firm"
        default: "Hard"
        }
    }

    /// Others see the creature when the screen is shared, and it stays on screen meanwhile.
    var visibleInScreenShares: Bool {
        didSet {
            defaults.set(visibleInScreenShares, forKey: "mm.companionVisibleInScreenShares")
            announceChange()
        }
    }

    var size: Size {
        didSet {
            defaults.set(size.rawValue, forKey: "mm.companionSize")
            announceChange()
        }
    }

    /// The user's colour as 0xRRGGBB, nil for the theme's accent.
    var customColor: UInt32? {
        didSet {
            if let customColor {
                defaults.set(Int(customColor), forKey: "mm.companionColor")
                defaults.set(Int(customColor), forKey: "mm.companionLastColor")
            } else {
                defaults.removeObject(forKey: "mm.companionColor")
            }
            announceChange()
        }
    }

    /// The colour to show when the user switches to their own colour: the last one they picked,
    /// or the accent turned a third of the way round the colour wheel, so the switch visibly
    /// does something.
    var suggestedOwnColor: UInt32 {
        if let last = defaults.object(forKey: "mm.companionLastColor") as? Int { return UInt32(truncatingIfNeeded: last) }
        let accent = NSColor(DesignSystem.Colors.accent).usingColorSpace(.sRGB) ?? .systemBlue
        let rotated = NSColor(hue: (accent.hueComponent + 0.33).truncatingRemainder(dividingBy: 1),
                              saturation: max(accent.saturationComponent, 0.5),
                              brightness: max(accent.brightnessComponent, 0.6), alpha: 1)
        return ThemeColor.hex(of: rotated)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        avatar = MascotAvatar(rawValue: defaults.string(forKey: "mm.companionAvatar") ?? "") ?? .blob
        comesOnShake = defaults.object(forKey: "mm.companionComesOnShake") as? Bool ?? true
        let storedStrength = defaults.object(forKey: "mm.companionShakeStrength") as? Int ?? MouseShakeDetector.defaultStrength
        shakeStrength = min(max(storedStrength, MouseShakeDetector.strengths.lowerBound),
                            MouseShakeDetector.strengths.upperBound)
        visibleInScreenShares = defaults.bool(forKey: "mm.companionVisibleInScreenShares")
        size = Size(rawValue: defaults.string(forKey: "mm.companionSize") ?? "") ?? .medium
        customColor = (defaults.object(forKey: "mm.companionColor") as? Int).map { UInt32(truncatingIfNeeded: $0) }
        isLoaded = true
    }

    var pixel: CGFloat { size.pixel }

    /// The creature's body colour; its outline and shine derive from it.
    var bodyColor: Color { bodyColor(for: avatar) }

    /// An avatar's body colour: the own colour, else its natural one, else the theme's accent.
    func bodyColor(for avatar: MascotAvatar) -> Color {
        if let hex = customColor ?? avatar.naturalBody { return Color(nsColor: ThemeColor.srgb(hex)) }
        return DesignSystem.Colors.accent
    }
}
