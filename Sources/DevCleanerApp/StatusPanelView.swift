import SwiftUI
import AppKit
import DevCleanerUI

/// The menu bar panel: a glance, and the way in.
///
/// This used to be the app — five collapsible groups, a hundred tick boxes, a stacked bar, a
/// review sheet and a run summary, in a 440-point strip. The window deals every one of those
/// rows as a card now, so there is one way to clean and this is not it: nothing in this file
/// removes anything, and the only decision on screen is whether to open the window.
///
/// It is drawn in the **deck's** language rather than in system controls, which is the change
/// this file exists for. The amount is set in the compressed numeral a card's gain uses, the
/// biggest cards are the same tinted bars with the same two tokens the window's folder rows
/// have, and the one real button is the deck's own filled primary. The panel was a
/// system-font number over a small default button with a focus ring before, which read as a
/// different application from the window it opens.
///
/// Every sentence, every number and every colour token is somebody else's: `StatusPanelModel`
/// decides the words, the totals and which bars there are — including the two scan problems
/// this is the app's only home for, because a deck of cards has nowhere to say that a whole
/// area of the disk went unmeasured — and `DeckStyle` owns the palette.
struct StatusPanelView: View {
    /// A plain `let`, not `@Bindable`: nothing here writes to the model, and `@Bindable` is
    /// only for `$model.something`. Redraws still arrive — `@Observable` tracking is on the
    /// property reads inside `body`, not on the wrapper.
    let model: AppModel
    /// Carried down so Scan again goes through the scheduler. Handing the loop down is the
    /// only way the button and the background interval can share one countdown.
    let scans: BackgroundScanLoop
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // `model.statusPanel`, not a `StatusPanelModel` built here: the age it shows is
        // measured against the model's own injected clock rather than a second one in this
        // target that no test could pin.
        let panel = model.statusPanel

        // Spacing by hand rather than one stack spacing, because the gaps are not equal:
        // the eyebrow sits tight under nothing and the number tight under the eyebrow, while
        // the bars, the rule and the buttons each want their own air. Every number here is
        // the approved mock's.
        VStack(alignment: .leading, spacing: 0) {
            amount(panel)
            bars(panel)
            // The only place in the app that says an area of the disk went unmeasured, or
            // that a scanner is switched off, or that the cache could not be written.
            problems(panel)
            // Above the rule, and under everything the scan is about to change its mind
            // about: this line is what says the numbers over it are being checked.
            progress(panel)
            status(panel)
            openButton
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        // Less at the foot: the three quiet buttons carry their own hit-area padding, so a
        // full inset under them would read as a gap rather than as a margin.
        .padding(.bottom, 10)
        .frame(width: StatusPanelMetrics.width)
        // No background of its own, and no card inside one. `menuBarExtraStyle(.window)`
        // already draws the system's popover surface, and a second fill over it is a flatter
        // panel than the platform's — the window has a card because it has a desk to sit on.
    }

    // MARK: - the amount

    /// The eyebrow, the amount in the deck's numeral, and the one line that says what it is.
    ///
    /// All four arrive together or none of them does — see `StatusPanelModel.eyebrow` — so a
    /// machine with nothing to offer draws the sentence that stands in for them and nothing
    /// else. The hover sentence is on the whole block, because it explains the number and the
    /// line under it at once.
    @ViewBuilder
    private func amount(_ panel: StatusPanelModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let eyebrow = panel.eyebrow {
                // The deck card's own eyebrow: 11-point semibold, secondary, and set in
                // capitals **here** rather than stored shouting.
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .lineLimit(1)
            }
            if let headline = panel.amountHeadline, let text = panel.amountText {
                StatusPanelNumber(headline: headline, text: text)
                    .padding(.top, 8)
            }
            if let detail = panel.amountDetail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .wrapped()
                    .padding(.top, 4)
            }
            // The sentence in place of the number, on a machine with nothing to offer and on
            // one that has measured nothing. Set in the primary colour at reading size: it is
            // the only thing this panel has to say.
            if let note = panel.amountNote {
                Text(note)
                    .font(.system(size: 13))
                    .wrapped()
            }
        }
        .help(panel.amountHelp)
    }

    /// The biggest cards as bars, and one quiet line for the rest.
    ///
    /// Which cards, in which order, at what fraction and in which tone is all
    /// `StatusPanelModel.rows` — including the promise that the bars and the fold line add up
    /// to the number above them.
    @ViewBuilder
    private func bars(_ panel: StatusPanelModel) -> some View {
        if !panel.rows.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(panel.rows) { row in
                    StatusPanelBar(row: row)
                }
            }
            .padding(.top, 12)
        }
        if let more = panel.moreText {
            Text(more)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .wrapped()
                .padding(.top, 5)
        }
    }

    @ViewBuilder
    private func problems(_ panel: StatusPanelModel) -> some View {
        if !panel.problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(panel.problems, id: \.self) { problem in
                    Text(problem).font(.caption).foregroundStyle(.orange).wrapped()
                }
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func progress(_ panel: StatusPanelModel) -> some View {
        if let progress = panel.progressText {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).font(.system(size: 12)).foregroundStyle(.secondary).wrapped()
            }
            .padding(.top, 10)
        }
    }

    /// Where the machine stands: how much room there is, and when that was measured.
    ///
    /// Under a hairline, because it is the one part of the panel that is not about the
    /// amount. Both halves of the left side are the model's own strings — the figure and the
    /// words after it — so the two weights on one line are not this file deciding where a
    /// number ends.
    ///
    /// Drawn only once something has been measured. Before that there is no free-space
    /// reading and no age, and a rule over an empty line is furniture with nothing under it.
    @ViewBuilder
    private func status(_ panel: StatusPanelModel) -> some View {
        if let free = panel.freeSizeText {
            Divider().padding(.top, 12)
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text(free).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    if let note = panel.freeNote {
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                // Gone for the whole of a scan or a run: see `StatusPanelModel.scannedText`.
                if let scanned = panel.scannedText {
                    Text(scanned).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .padding(.top, 10)
        }
    }

    // MARK: - the buttons

    /// The window, full width, in the deck's own primary.
    ///
    /// `DeckButtonStyle` as the window declares it, rather than a copy sized for this panel:
    /// it is the same button — the app's one filled action — and two declarations of it are
    /// two things to keep in step. It is 38 points tall here as a result, four more than the
    /// mock drew, which is the right trade for one button style in the app.
    ///
    /// It is the default action, and it is the only button here safe to be one: it opens a
    /// window. The deck's own Return key belongs to a card's Clean up, behind the settle
    /// window `AppModel.cardSettleSeconds` describes, and nothing in the menu bar may reach
    /// it.
    ///
    /// `focusEffectDisabled` because the panel opens with this button first in the view and
    /// macOS draws a keyboard focus ring around it — a blue halo on a blue button, on a
    /// surface the user opened by clicking an icon rather than by tabbing anywhere. The key
    /// still works: the shortcut is what answers Return, not the focus.
    private var openButton: some View {
        Button(StatusPanelText.openWindow) { openDeck() }
            .buttonStyle(DeckButtonStyle(.primary, fillsWidth: true))
            .keyboardShortcut(.defaultAction)
            .focusEffectDisabled()
            .padding(.top, 12)
    }

    /// The three that keep the app itself, spread along the foot of the panel.
    ///
    /// Quiet on purpose: none of them is what the panel is for, and the one that is sits
    /// filled directly above. Spread rather than grouped at one edge because there are
    /// exactly three and 268 points to put them in, which is the arrangement where each one
    /// is its own target and none of them reads as a pair.
    private var footer: some View {
        HStack(spacing: 6) {
            // Through the loop, not straight to the model: the scheduler holds the
            // countdown, and a manual scan it never hears about leaves the background
            // interval due a minute later. `BackgroundScanLoop.rescan` says the rest.
            Button(StatusPanelText.scanAgain) {
                Task { await scans.rescan() }
            }
            .disabled(model.isBusy)
            Spacer(minLength: 0)
            Button(StatusPanelText.settings) { openSettings() }
            Spacer(minLength: 0)
            Button(StatusPanelText.quit) { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(StatusPanelFooterStyle())
        .padding(.top, 8)
        // Back out the hit-area padding the style adds, so the words line up with the
        // number and the bars above them instead of sitting six points inside the inset.
        .padding(.horizontal, -6)
    }

    /// Opens the deck, or brings it forward when it is already open.
    ///
    /// Two calls, and both are needed. `openWindow` creates the scene's window or raises the
    /// existing one, but the app is behind whatever the user was working in — the click that
    /// got here was on a menu bar icon — so without `activate()` the window is ordered in
    /// behind their editor and the button looks like it did nothing.
    ///
    /// The identifier is `MainWindowMetrics.sceneID`, the same constant `DevCleanerApp`
    /// declares the scene with. `openWindow(id:)` fails silently on an unknown identifier,
    /// so a second spelling here would be a dead primary button with nothing explaining it.
    private func openDeck() {
        openWindow(id: MainWindowMetrics.sceneID)
        NSApplication.shared.activate()
    }
}

// MARK: - the amount, set large

/// The panel's gain number: the deck's numeral at the size a 300-point strip can hold.
///
/// The window's `GainNumber` is the same idea at 96 and 40 points, which is a number sized to
/// be read from across the room on a card that is nothing else. Those sizes are written into
/// that view, and this one cannot borrow it without parameterising the card's own headline —
/// so the type sizes differ and everything else is deliberately identical: the same
/// compressed heavy face, the same baseline-aligned unit, the same `SizeHeadline` split.
///
/// Which characters are the unit is **not** decided here. `StatusPanelModel.amountHeadline`
/// carries the split, for the reason it is on `SizeHeadline`: a body that cut the string on
/// its first space would be a decision no test can read.
struct StatusPanelNumber: View {
    let headline: SizeHeadline
    /// The whole size as one string — "109.6 GB" — for anything that reads the panel aloud.
    ///
    /// The two `Text`s are two accessibility elements otherwise, so VoiceOver announces
    /// "109.6" and "GB" as separate items with the eyebrow between them in the rotor. One
    /// label over the pair is the number as the user would say it.
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(headline.number)
                .font(.system(size: 64, weight: .heavy))
                .fontWidth(.compressed)
                .monospacedDigit()
            if let unit = headline.unit {
                Text(unit)
                    .font(.system(size: 28, weight: .heavy))
                    .fontWidth(.compressed)
            }
        }
        .lineLimit(1)
        // A 64-point line box is about a third taller than the digits in it, and that third
        // would be empty space between the eyebrow above and the sentence below. Negative
        // padding takes the slack out of the frame without clipping anything: digits have no
        // descenders, and neither has "GB".
        .padding(.vertical, -6)
        // "1200.0" plus its unit still has to fit on one line rather than truncating the
        // thing the panel is about.
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - one card, as a bar

/// One of the biggest cards: its name, its share of the amount, and a tinted bar behind both.
///
/// The window's folder row at panel scale — the same track, the same two tinted fills, the
/// same coloured leading edge — because it is the same thing being drawn: a size as a
/// proportion of the biggest one beside it. Shorter, with no restore hint, because a card is
/// not a folder and the panel is not asking anything.
struct StatusPanelBar: View {
    let row: StatusPanelRow

    private static let height: CGFloat = 24
    private static let radius: CGFloat = 6
    /// Thinner than the card's three points, because the bar is ten points shorter.
    private static let edgeWidth: CGFloat = 2.5

    /// The edge and the fill, as one decision, from the card's own tone.
    ///
    /// Together for the reason `DeckButtonStyle` keeps its fill and its label colour
    /// together: they are one token read at two strengths, and a bar with a blue edge over an
    /// amber fill is a row saying both things at once. Which tone it is is the **card's**
    /// answer — `ProjectCard.primaryActionTone`, carried on `StatusPanelRow.tone` — so a
    /// simulator card is amber here, amber in the skyline and amber on the button that
    /// destroys it.
    private var accent: (edge: Color, fill: Color) {
        switch row.tone {
        case .regenerable: (DeckStyle.rebuild, DeckStyle.rebuildFill)
        case .deliberate:  (DeckStyle.download, DeckStyle.downloadFill)
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Self.radius).fill(DeckStyle.track)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Rectangle().fill(accent.edge).frame(width: Self.edgeWidth)
                    Rectangle().fill(accent.fill)
                }
                .frame(width: max(0, geometry.size.width * row.fraction))
            }
            // Clipped to the track, so the leading edge is inside the rounded corner rather
            // than a tick mark sticking out of it.
            .clipShape(RoundedRectangle(cornerRadius: Self.radius))
            HStack(spacing: 6) {
                Text(row.title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                // **The size is never the thing that gives way.** The card's own folder row
                // hands the room to the name and lets the line beside it truncate, because
                // there that line is a sentence. Here it is the number the bar is about, and
                // a "21.4 G…" under a headline these rows are supposed to add up to is the
                // one thing on this panel that cannot be cut. A long card name shortens
                // instead — its bar and its place in the order still say which card it is.
                Text(row.sizeText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
        }
        .frame(height: Self.height)
        // One element per bar: "iOS simulators, 21.4 GB", rather than two items a rotor
        // walks through separately.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - the three quiet controls

/// The panel's footer buttons: secondary text, a comfortable target, and no bezel.
///
/// A style rather than three modifiers on three buttons, for the reason `DeckButtonStyle` is
/// one: the padding that makes them hittable, the pressed state and the disabled state are
/// the same three answers for all three controls, and Scan again is the one that goes dead —
/// while a scan runs it has to stay recognisably the same button.
///
/// `.plain` and not `.borderless`, which is what this footer used to use: macOS draws a
/// borderless button's title in the accent colour, so the three controls that are *not* the
/// point of the panel were the only blue text on it apart from the button that is.
private struct StatusPanelFooterStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return configuration.label
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            // The faintest of the deck's fills, which is the one it uses for an empty bar:
            // enough to show the press landed on this word and not the one beside it.
            .background(shape.fill(configuration.isPressed ? DeckStyle.track : .clear))
            // The same strength a disabled deck button keeps, so Scan again reads as the
            // button that comes back rather than as a label.
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

extension View {
    /// Wrap onto as many lines as the sentence needs, instead of truncating to one.
    ///
    /// Both windows are fixed-width columns and every sentence in them is a whole sentence,
    /// written to be read. Without this the enclosing stack sizes each `Text` at its ideal
    /// width — one line, however long — and what the user gets is
    /// `Simulators, runtimes and emulators are normally removed permanently.…`, with the
    /// part that says there is no undo cut off. Truncation here does not shorten a label;
    /// it removes the warning.
    func wrapped() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}
