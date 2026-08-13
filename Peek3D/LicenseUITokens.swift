import SwiftUI

/// Shared visual tokens for the trial/license UI (`TrialGateView`,
/// `LicenseEntrySheet`, `SettingsView`, and the trial-countdown bits of
/// `WelcomeView`/`ContentView`). Extracted here rather than inlined per call
/// site — unlike the rest of the app's chrome (background `Color(white: 0.04)`,
/// accent `Color(red: 0.35, green: 0.68, blue: 1.0)`, surfaces/borders at
/// white 3/6/10% and 8/15%, radii 8/16/18 — all still inlined at their own
/// call sites, per existing convention in `WelcomeView.swift`) — because this
/// file introduces two things that didn't exist anywhere in the app before:
/// a warning color, and a filled (non-ghost) button chrome.
extension Color {
    /// Warning/urgency accent for the critical trial phase (3-1 opens
    /// remaining) and its countdown link. Everything else in the app's
    /// palette is either the accent blue or a shade of white/black; this is
    /// the first color that means "pay attention", so it gets a name instead
    /// of being a literal repeated at every call site.
    static let peekAmber = Color(red: 0.95, green: 0.65, blue: 0.25)

    /// Genuine-failure accent for `LicenseEntrySheet`'s four error states —
    /// distinct from `peekAmber`'s "pay attention, not broken" register per
    /// this feature's color mapping (red = error, amber = warning, green =
    /// success). Verified by hand-computing WCAG relative luminance for both
    /// the icon (opaque, against the banner background below) and the
    /// message text (white at 80% opacity, against the same background):
    /// icon contrast ≈4.8:1, text contrast ≈9.1:1 against
    /// `Color.peekError.opacity(0.18)` composited over the sheet's
    /// `Color(white: 0.1)` base — both clear WCAG AA's 4.5:1 for normal text
    /// with margin.
    static let peekError = Color(red: 1.0, green: 0.42, blue: 0.38)
}

/// Solid accent-blue button chrome. Until this feature, every button in the
/// app used the "ghost" look (translucent white fill, hairline border —
/// see `WelcomeView`'s "Choose a file…" button) inlined per call site; nothing
/// needed more visual weight than that. "Acquista licenza" is the first CTA
/// that does, so it gets a real fill instead of a third inline copy of the
/// ghost recipe.
///
/// `fillWidth` defaults to `false` (content-hugging, e.g. the entry sheet's
/// "Attiva") so the same style serves both a full-bleed CTA
/// (`TrialGateView`, pass `fillWidth: true`) and a compact one without two
/// separate types.
struct PeekFilledButtonStyle: ButtonStyle {
    var fillWidth: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .background(
                // Disabled reads as a flat, desaturated fill (e.g. the entry
                // sheet's "Attiva" before any text is typed) rather than
                // full accent blue, which otherwise reads as clickable
                // regardless of `.disabled` — confirmed by piloting the real
                // sheet: without this, pressing a disabled "Attiva" produced
                // no error and no visible reason why.
                (isEnabled ? Color(red: 0.35, green: 0.68, blue: 1.0) : Color.white.opacity(0.12))
                    .opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

/// Formalizes the existing inline "ghost" button recipe (translucent white
/// fill + hairline border) already used ad hoc across the app into a
/// reusable style, for the new license UI's secondary actions ("Ho già una
/// licenza", "Cambia licenza"). Deliberately NOT retroactively applied to
/// existing buttons elsewhere (e.g. `WelcomeView`'s own "Choose a file…") —
/// out of scope here, and they already work.
struct PeekGhostButtonStyle: ButtonStyle {
    var fillWidth: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.15)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The trial-countdown copy, shared between `WelcomeView`'s footer,
/// `ContentView`'s critical-phase toast, and `SettingsView`'s status line so
/// the wording never drifts between the places it appears.
enum TrialCopy {
    /// Routed through the String Catalog's own plural variation (`trial.remainingCount`,
    /// "one"/"other" in both `en` and `it`) rather than the manual `remaining == 1 ? … : …`
    /// this used to be — Italian and English don't just swap "opening"/"openings",
    /// the whole sentence reorders ("Ti resta 1 apertura" vs "Ti restano 3 aperture"),
    /// which is exactly the class of thing CLDR plural rules exist to own instead of
    /// a call site guessing at it.
    static func remainingText(_ remaining: Int) -> String {
        String(
            localized: "trial.remainingCount",
            defaultValue: "\(remaining) opening(s) left",
            comment: "Trial countdown shown in the Welcome footer, in-viewer toast, and Settings. Pluralizes on the remaining-opens count."
        )
    }

    /// Short label for "the trial is over", shared between `TrialGateView`'s
    /// headline and `SettingsView`'s compact status line — both show the exact
    /// same two words in Italian too, so this is one key, not two coincidentally
    /// identical ones (see this project's CLAUDE.md note on not reusing a key
    /// just because today's text happens to match).
    static var exhaustedShort: String {
        String(
            localized: "trial.exhaustedShort",
            defaultValue: "Trial expired",
            comment: "Short label meaning the trial has ended, used both as TrialGateView's headline and SettingsView's status line."
        )
    }
}
