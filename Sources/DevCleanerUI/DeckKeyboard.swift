import Foundation

// What the deck window does to a key event before any button sees it.
//
// One rule, and it exists because the settle window was not enough. `AppModel.cardSettleSeconds`
// refuses a second answer for 0.6 seconds after the deck moves, which rate-limits a held
// Return — it does not stop one. macOS repeats a held key for as long as it is down, so a
// Return leaned on walked the deck at roughly one card per 0.6 seconds: a dozen cards in eight
// seconds, each of them cleaned, and in permanent mode deleted outright rather than trashed.
// The comment on the constant claimed immunity; it never had any.
//
// The fix is to require a **fresh press**. `NSEvent` says whether a key-down is a repeat, so
// the window swallows the repeats and every card needs its own press. That has to happen in
// `DevCleanerApp`, where `NSEvent` can be reached; what lives here is the decision itself, so
// the rule is one a test can read rather than a condition inside a monitor closure. The view
// asks this and obeys.

/// Whether the deck window swallows a key-down event.
public enum DeckKeyboard {

    /// The virtual key codes for Return and the keypad's Enter.
    ///
    /// Key codes rather than the event's characters, which are what `.defaultAction` itself
    /// matches on: a layout can move a character but not a key code, and `"\r"` arrives from
    /// more than one place. Both keys, because `.keyboardShortcut(.defaultAction)` answers to
    /// both — a repeat swallowed on one and let through on the other would be a fix that held
    /// on most keyboards.
    ///
    /// `36` is Return and `76` is the keypad's Enter, from `Carbon.HIToolbox`'s
    /// `kVK_Return` and `kVK_ANSI_KeypadEnter`. Written out rather than imported: this
    /// library has no business linking Carbon for two integers, and the names are here in the
    /// comment where the numbers are.
    public static let primaryActionKeyCodes: Set<UInt16> = [36, 76]

    /// Whether this key-down is one the deck window must not pass on.
    ///
    /// Exactly the repeats of the key that answers a card, and only while the deck window is
    /// the key window. Three conditions, and dropping any of them breaks something real:
    ///
    /// **`isARepeat`** is the whole of the rule. The first press of Return is the user
    /// answering a card and must go through; every press after it without the key coming up
    /// is the same press, and the deck deals a new question under it.
    ///
    /// **The key code** keeps it to Return. The right arrow is held down through the deck on
    /// purpose — skipping removes nothing, and flicking through twenty-four cards is the deck
    /// working as intended — so a rule about every repeat would take that away. What made the
    /// arrow dangerous was the interstitial's secondary meaning "skip them all", and that is
    /// fixed where it belongs, on the card: see `ProjectCard.secondaryAnswersToArrow`.
    ///
    /// **The window** keeps it out of everything else the app puts on screen. The settings
    /// window holds text fields, where a held Return is nobody's business but the field's.
    ///
    /// Returns `true` to mean "swallow it", so the monitor's answer reads the same way round
    /// as the question.
    public static func swallowsKeyDown(
        keyCode: UInt16, isARepeat: Bool, isDeckWindowKey: Bool
    ) -> Bool {
        isARepeat && isDeckWindowKey && primaryActionKeyCodes.contains(keyCode)
    }
}
