import SwiftUI
import AppKit
import DevCleanerUI
import CleanerCore

/// The desktop window: the deck, and the only surface that removes anything.
///
/// The menu bar is a status item — one amount and a button that opens this — so there is one
/// way to clean and this is it. The window asks one question, *may this go?*, about one thing
/// at a time, and it asks it the way a person would: here is the project or the tool, here is
/// what it is holding, here is how each part comes back. Clean up, or Skip. No checkboxes,
/// no tiers, no review sheet.
///
/// A card is a project, a whole scanner, or one file of the user's own. The deck has two
/// halves: everything that comes back on its own, biggest first and mixed together, and then
/// — behind one card that says the promise is changing — the things that do not come back at
/// all. The cards that behave differently are the ones that cannot be undone and the ones
/// that are the user's: each says so twice, each has a button that names what it really does,
/// and neither has a Return shortcut. Every one of those is the card's own property — see
/// `ProjectCard.answersToReturn` — because a window deciding for itself which deletions are
/// permanent is a decision no test can read.
///
/// Everything on screen is a bar of bytes. The folder rows are bars, the deck above them is a
/// skyline of bars, and cleaning **drains** the rows in the order the engine is really working
/// through them — `ExecutionProgress`, never a timer. That is the one piece of motion; the
/// rest is quiet native macOS.
///
/// Nothing below this line classifies, totals or phrases anything. Every sentence is
/// `ProjectDeckText`'s or `ProjectDeckSummary`'s, every size arrives already formatted, every
/// bar arrives as a `fraction`, and the two mode-dependent lines — Trash or permanent — are
/// resolved by the model, so this file never reads `Settings`. What it does own is the
/// palette, the type sizes and the motion: see `DeckStyle`.
struct MainWindowView: View {
    /// Which button took the last card away.
    ///
    /// The two answers leave differently — a skip slides and tilts off to the left, a clean
    /// settles and fades — and a transition cannot ask why it is being removed. So the button
    /// records the answer before the card goes, and the removal reads it.
    private enum Answer {
        case cleaned
        case skipped
    }

    @Bindable var model: AppModel
    let scans: BackgroundScanLoop
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastAnswer: Answer = .cleaned
    /// What makes a held Return stop at one card — see `DeckKeyMonitor`.
    ///
    /// Built in `onAppear` rather than as this property's initial value, because it is
    /// `@MainActor` and a `View`'s stored properties are initialised wherever the struct is
    /// made. `nil` until then, which is a window that swallows nothing; the settle window in
    /// `AppModel` is what covers that gap.
    @State private var keys: DeckKeyMonitor?

    var body: some View {
        // Read once, at the top, and handed down, so the branches below cannot disagree
        // about which card is on screen halfway through a pass.
        //
        // Cheap now either way: `AppModel.projectDeck` builds the deck once per applied scan
        // and holds it, which is what makes these three reads — and the further ones inside
        // `deckSummary` — one walk of a couple of hundred rows per scan rather than five per
        // redraw. This line is no longer what keeps that cost down; it keeps the *values*
        // consistent.
        let deck = model.projectDeck
        let summary = model.deckSummary
        let card = model.currentProjectCard

        return VStack(spacing: 0) {
            // Only once there is a deck to be somewhere in. Before the first scan the strip
            // would be a session counter reading 0 KB over an empty skyline, above a window
            // that is still measuring.
            if let summary, !summary.skyline.isEmpty {
                DeckStripView(summary: summary)
            }
            if let cacheError = model.lastCacheError {
                Text(cacheError)
                    .font(.caption).foregroundStyle(.orange).wrapped()
                    .padding(.horizontal, DeckStyle.inset).padding(.top, 8)
            }
            stage(card: card, summary: summary, deck: deck)
            actions(card: card, summary: summary)
        }
        // The column stops growing here and sits centred; `MainWindowMetrics` says why.
        .frame(maxWidth: MainWindowMetrics.maxContentWidth)
        .frame(maxWidth: .infinity)
        .frame(minWidth: MainWindowMetrics.minWidth, minHeight: MainWindowMetrics.minHeight)
        .background(DeckStyle.window)
        // The one thing a background scan is allowed to change about a deck being read. It
        // runs unasked for about 51 seconds, and the card must stay exactly where it is.
        .navigationSubtitle(ProjectDeckText.windowSubtitle(
            phase: model.phase, scanAge: model.scanAgeText))
        // Which window this is, so the monitor below can tell a held Return in the deck from
        // one in a settings field. Identity only, and set only when it really changes, so
        // this cannot ask for a layout pass of its own.
        .background(WindowReader { window in
            if keys?.window !== window { keys?.window = window }
        })
        .onAppear {
            // Created here and not torn down until the window goes: a monitor added per
            // redraw would be dozens of monitors over a session, each one still swallowing.
            if keys == nil { keys = DeckKeyMonitor() }
            keys?.start()
        }
        .onDisappear { keys?.stop() }
        .toolbar {
            ToolbarItem {
                // Through the loop, not straight to the model: the scheduler holds the
                // countdown, and a manual scan it never hears about leaves the background
                // interval due a minute later. `BackgroundScanLoop.rescan` says the rest.
                Button {
                    Task { await scans.rescan() }
                } label: {
                    Label(ProjectDeckText.scanAgain, systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
                .help(ProjectDeckText.scanAgain)
            }
            ToolbarItem {
                Button {
                    openSettings()
                } label: {
                    Label(ChromeText.settings, systemImage: "gearshape")
                }
                .help(ChromeText.settings)
            }
        }
    }

    // MARK: - the middle

    /// The card, the card at the end of the deck, or the window before there is either.
    ///
    /// Top-aligned and not stretched, because the card hugs its content: a project with two
    /// folders is a short card with space under it, not a tall card with a void in the
    /// middle. `ProjectCardView` is the one that grows until it meets the action area.
    @ViewBuilder
    private func stage(
        card: ProjectCard?, summary: ProjectDeckSummary?, deck: ProjectDeck?
    ) -> some View {
        ZStack(alignment: .top) {
            if let card {
                ProjectCardView(
                    card: card,
                    // Only this card's own run drains its rows. Any other run leaves every
                    // bar full, which is the truth: those folders are still there.
                    progress: ownRun(of: card).progress,
                    problems: model.cardAwaitingAcknowledgement?.problems ?? [],
                    // A box on a checklist page. Straight through to the model, which owns
                    // every rule about them: which rows may be changed, when they are frozen,
                    // and when they are forgotten.
                    setRowTicked: { model.setChecklistRow($0, ticked: $1) },
                    setAllRowsTicked: { model.setAllChecklistRows(ticked: $0) })
                    // Identity is the project's directory, so answering one card really
                    // replaces it rather than re-labelling the one on screen — which is what
                    // makes the transition below a transition at all.
                    .id(card.id)
                    .transition(cardTransition)
            } else if let summary, let deck {
                EndCardView(summary: summary, deck: deck)
                    .transition(cardTransition)
            } else {
                waiting
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, DeckStyle.inset)
        .padding(.top, 18)
        // Keyed on which card is on screen, so the deck's own comings and goings animate and
        // nothing else does: a row draining mid-run does not change this value, and the drain
        // keeps its own slower animation.
        .animation(DeckStyle.deal(reduceMotion: reduceMotion), value: card?.id)
    }

    /// Before there is a deck: the scan the app is running, or the offer to run one.
    @ViewBuilder
    private var waiting: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .scanning(let progress):
                ProgressView().controlSize(.small)
                Text(ProjectDeckText.scanning)
                    .font(.system(size: 15, weight: .semibold))
                // The engine's own words underneath, so a minute of waiting says which of
                // scanners in the registry it is waiting on.
                Text(ChromeText.scanning(progress))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).wrapped()
            case .running(let progress):
                ProgressView().controlSize(.small)
                Text(ChromeText.running(progress))
                    .font(.callout).foregroundStyle(.secondary)
            case .idle:
                Text(ProjectDeckText.noScanYet)
                    .font(.system(size: 15, weight: .semibold))
                Button(ProjectDeckText.scanNow) {
                    Task { await scans.rescan() }
                }
                .buttonStyle(DeckButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - the pinned bottom

    /// The action area, at the window's bottom edge rather than under the card, so the two
    /// buttons are in the same place on every card however tall it is.
    ///
    /// Exactly one of the three branches is ever on screen, and that is load-bearing rather
    /// than tidy: Skip's shortcut is a **bare right arrow**, which is window-wide while the
    /// button exists. It is deliberate — the deck is a thing you flick through — and it is
    /// safe only because the button lives inside `cardButtons` and nowhere else, so the key
    /// is free again the moment the deck is showing problems, the end card, or a window
    /// with no scan in it. Moving the shortcut up to this function, or adding a second Skip
    /// anywhere, would take the arrow key away from whatever those states put on screen.
    ///
    /// **Which card the arrow answers for is the card's decision, not this file's.** It used
    /// to be a literal here, and so it kept its binding while the button's meaning changed
    /// underneath it: on the interstitial that secondary is "Skip them all", and an arrow
    /// held through the first half of the deck pressed it on the next repeat — every one of
    /// the user's own files skipped unread. See `ProjectCard.secondaryAnswersToArrow`.
    @ViewBuilder
    private func actions(card: ProjectCard?, summary: ProjectDeckSummary?) -> some View {
        VStack(spacing: 10) {
            if model.cardAwaitingAcknowledgement != nil {
                // One button, and it says where it takes them. The card's problems are still
                // on screen above it.
                Button(ProjectDeckText.nextProject) { model.acknowledgeProblems() }
                    .buttonStyle(DeckButtonStyle(.primary, fillsWidth: true))
                    .keyboardShortcut(.defaultAction)
            } else if let card {
                // The promise is the **card's**, not the session's. A project card says the
                // user's code stays, a tool card says the button reaches nothing outside its
                // own list, and a simulator card quotes the engine's own warning that
                // nothing comes back — and only the card knows which of the three it is.
                Text(ProjectDeckText.actionNote(
                    phase: model.phase,
                    isCleaningThisCard: ownRun(of: card).isMine,
                    promise: card.promiseText))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).wrapped()
                cardButtons(card)
            } else if let summary {
                endButtons(summary)
            }
        }
        .padding(.horizontal, DeckStyle.inset)
        .padding(.top, 14)
        .padding(.bottom, 18)
        // No focus ring on the two answers. With keyboard navigation switched on, macOS rings
        // the first control in the window — Skip — the moment the window opens, and a bright
        // ring round the *secondary* button reads as the app recommending it. The buttons stay
        // focusable and keep their keys (Return, the arrow); only the ring is not drawn.
        .focusEffectDisabled()
    }

    private func cardButtons(_ card: ProjectCard) -> some View {
        HStack(spacing: 10) {
            Button {
                lastAnswer = .skipped
                // One call for both meanings. On an ordinary card it skips that card; on
                // the interstitial it skips every one of the user's own files at once,
                // which is what its label says — `AppModel.skipCurrentProject` owns the
                // difference, because a window choosing between two model calls for a
                // button whose title it did not write is a window that can put the wrong
                // words on the wrong action.
                model.skipCurrentProject()
            } label: {
                // The width is the label's, so the bezel itself is this wide. A frame on the
                // button only reserves the space and leaves the bezel hugging the word.
                // Wider on the interstitial, whose "Skip them all" does not fit 104 points.
                //
                // The glyph is the card's, decided beside the shortcut below, so a "→" can
                // never be printed on a button no arrow presses.
                ActionTitle(title: card.secondaryActionTitle, hint: card.secondaryActionKeyHint)
                    .frame(width: card.isInterstitial ? nil : 104)
            }
            .buttonStyle(DeckButtonStyle(.secondary))
            // A bare arrow, no modifier, on every card that skips one thing: the deck is a
            // thing you flick through, and the other hand is on Return. `nil` removes the
            // shortcut on the one card where the same button answers for fourteen.
            .keyboardShortcut(card.secondaryAnswersToArrow
                ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
            // Dead while a clean is running — anybody's — and never merely while the app
            // is busy. `AppModel.skipCurrentProject` refuses during a run, whichever surface
            // started it, so a live button there would do nothing; but a background scan
            // runs unasked for about 51 seconds and the model deliberately keeps taking
            // skips through one, and a Skip greyed out for that long would be the deck
            // seizing up for no reason the user can see.
            .disabled(isRunning)

            Button {
                lastAnswer = .cleaned
                // The deck's own clean, which is the app's only one: this card's items by
                // identifier, pruned out of the scan afterwards, with no measuring in
                // between.
                model.cleanCurrentProject()
            } label: {
                ActionTitle(title: cleanTitle(card), hint: card.primaryActionKeyHint)
                    .frame(maxWidth: .infinity)
            }
            // Amber on a card the user has to mean, blue on the rest — and the card is what
            // decides, exactly as it decides the key. `ProjectCard.primaryActionTone` reads
            // it off `answersToReturn` for that reason: "Delete 21.4 GB for good" in the
            // colour a rebuilding folder's bar goes was the colour contradicting the words.
            .buttonStyle(DeckButtonStyle(.primary, tone: card.primaryActionTone))
            // The card decides, and the reason is on `ProjectCard.answersToReturn`: a card
            // that destroys sixteen simulators must not be answerable by a Return key the
            // previous nine cards taught the user to press. `nil` removes the shortcut —
            // and with it the default-action ring — rather than binding a different key,
            // because there is no key this button should have.
            .keyboardShortcut(card.answersToReturn ? .defaultAction : nil)
            // Two different questions, both of which have to be yes.
            //
            // `isBusy`, not `isRunning`: `work` is one slot, so `cleanCurrentProject`
            // refuses during a background scan as well, and a live button that does nothing
            // is worse than a dead one. The line above the buttons says which of the two it
            // is waiting for — `ProjectDeckText.actionNote`.
            //
            // `isPrimaryActionEnabled` is the card's own answer, and today it is false on
            // exactly one card: a checklist page with every box clear — which is the state it
            // is dealt in — where the title reads "Tick the files to move to the Trash"
            // rather than naming an amount. The words and the deadness travel together on the
            // card, which is the only place they can be kept in step.
            .disabled(model.isBusy || !card.isPrimaryActionEnabled)
        }
    }

    /// Whichever of the two end-card buttons the session earned. Both are `nil` on a deck
    /// worked through in permanent mode with nothing skipped, and then this is empty — the
    /// toolbar's Scan again is the way on.
    @ViewBuilder
    private func endButtons(_ summary: ProjectDeckSummary) -> some View {
        HStack(spacing: 10) {
            if let review = summary.reviewSkippedText {
                Button(review) { model.reviewSkippedProjects() }
                    .buttonStyle(DeckButtonStyle(.secondary))
            }
            if let openTrash = summary.openTrashText {
                Button {
                    // Opens the folder. It does not empty it, and nothing in this app does:
                    // the Trash is the undo the whole tool is built around.
                    NSWorkspace.shared.open(model.trashDirectory)
                } label: {
                    // The width is the label's, so the bezel fills the row. A frame on the
                    // button only reserves the space and leaves the bezel hugging the words.
                    Text(openTrash).frame(maxWidth: .infinity)
                }
                .buttonStyle(DeckButtonStyle(.primary))
                // **No key**, and the summary is what says so — see
                // `ProjectDeckSummary.openTrashAnswersToReturn`. It was the window's default
                // action, which put a Finder window at the end of a held Return: the key
                // that answered the last card of the deck reached this button on its next
                // repeat. Opening a folder is harmless; what is not is the deck teaching a
                // user that holding Return is the way through it, and the end card is the
                // last place that lesson would have been confirmed.
                .keyboardShortcut(summary.openTrashAnswersToReturn ? .defaultAction : nil)
            }
        }
    }

    // MARK: - whose run is on screen

    /// The run **this card** started, or `nil` when the run on screen is not its own.
    ///
    /// Never `model.phase`, which is one slot for the whole app. Read from the phase, a
    /// clean the user confirmed on the old menu bar checklist titled this button
    /// "Cleaning… 57 of 8" and struck through folders that were still on disk — the count
    /// and the progress belonged to a different run over a different list.
    /// `AppModel.cardRun` names the card, so this can ask whether the run is ours.
    ///
    /// The words and the drain rule stay the library's — `ProjectDeckText.cleaning` and
    /// `ProjectCard.isFolderDrained` — so all this does is answer that one question.
    /// Two answers rather than a double optional: "is this our run" and "how far has it
    /// got" are different questions, and `nil` is a real answer to the second one — the
    /// state the button is pressed into, before the executor's first report.
    private func ownRun(of card: ProjectCard) -> (isMine: Bool, progress: ExecutionProgress?) {
        guard let run = model.cardRun, run.cardID == card.id else { return (false, nil) }
        return (true, run.progress)
    }

    /// True while a clean is running, whoever started it. What Skip is disabled on:
    /// `AppModel.skipCurrentProject` refuses during any run, so a live button there would
    /// do nothing at all.
    private var isRunning: Bool {
        if case .running = model.phase { return true }
        return false
    }

    /// The primary button's title: the run's progress while this card's own clean is going,
    /// and otherwise whatever the card says its action is — "Clean up 9.1 GB", or "Delete
    /// 21.4 GB for good".
    private func cleanTitle(_ card: ProjectCard) -> String {
        let run = ownRun(of: card)
        return run.isMine
            // The card's count of what it handed over, not of what it drew — see
            // `ProjectCard.runItemCount`. On a checklist page the two differ.
            ? ProjectDeckText.cleaning(run.progress, of: card.runItemCount)
            : card.primaryActionTitle
    }

    /// How a card comes and goes.
    ///
    /// The answer chooses the exit, because the two answers mean different things: a skip
    /// pushes the project aside and the card leaves sideways with a slight tilt, while a
    /// clean is something happening to the card itself, so it settles and fades in place.
    /// Either way the next card rises in, which is the deck being dealt.
    ///
    /// `accessibilityReduceMotion` collapses all of it to a crossfade. Sliding and tilting
    /// are exactly what that setting exists to switch off, and nothing in this window's
    /// meaning is carried by the movement — the skyline and the position line say where the
    /// user is.
    private var cardTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let leaving: AnyTransition = switch lastAnswer {
        case .skipped:
            .opacity
                .combined(with: .offset(x: -40))
                .combined(with: .modifier(
                    active: TiltModifier(degrees: -1.2), identity: TiltModifier(degrees: 0)))
        case .cleaned:
            .opacity.combined(with: .scale(scale: 0.97))
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: leaving)
    }
}

/// A rotation a transition can interpolate. `AnyTransition` has offset and scale of its own
/// but no rotation, and the skip's tilt is what makes it read as a card being pushed away
/// rather than a panel sliding out.
private struct TiltModifier: ViewModifier {
    let degrees: Double

    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(degrees))
    }
}

// MARK: - a held Return answers one card and no more

/// Swallows the repeats of a held Return while the deck window is key, so the primary button
/// needs a **fresh** press for every card.
///
/// `AppModel.cardSettleSeconds` was the only thing standing in the way, and a settle window
/// rate-limits a held key rather than stopping one: macOS goes on repeating for as long as
/// the key is down, so a Return leaned on walked the deck at about one card per 0.6 seconds,
/// cleaning each of them — deleting outright, for a user who had turned the Trash off. This
/// is what makes the press deliberate; the window stays as the second line.
///
/// A class, and held by the view in `@State`, because the monitor's handler outlives the body
/// pass that installed it: it has to read *the current* window, and a closure that captured a
/// `View`'s stored property would have captured `nil` at install time and kept it for ever.
///
/// The rule itself is not here. Which events are swallowed is `DeckKeyboard.swallowsKeyDown`,
/// in the library, where a test can read it; this file owns only the two things a test cannot
/// reach — the monitor and the window it is about.
@MainActor
final class DeckKeyMonitor {
    /// The window the deck is in, kept up to date by `WindowReader`.
    ///
    /// `weak`, because the window owns the view hierarchy that owns this. `nil` before the
    /// first layout pass has a window to report, and then nothing is swallowed — deliberately
    /// fail-open: a deck that swallowed every Return because it could not identify its own
    /// window would be a window with no primary button at all.
    weak var window: NSWindow?

    private var monitor: Any?

    /// Adds the monitor, once. Called from `onAppear`, which SwiftUI can run more than once
    /// for one window.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // **Local**, so it only ever sees this app's own key events, and returning the
            // event unchanged is the whole of "let it through". `nil` is what swallows one.
            guard let self else { return event }
            let isDeckWindowKey = window.map { $0.isKeyWindow && event.window === $0 } ?? false
            return DeckKeyboard.swallowsKeyDown(
                keyCode: event.keyCode,
                isARepeat: event.isARepeat,
                isDeckWindowKey: isDeckWindowKey)
                ? nil
                : event
        }
    }

    /// Takes it off again when the window goes. A monitor left behind would go on swallowing
    /// Return repeats for the rest of the process, in whatever window was up.
    ///
    /// Called from `onDisappear`, and **not** from a `deinit`: `removeMonitor` is AppKit, a
    /// `deinit` is not isolated to any actor, and a `MainActor.assumeIsolated` there traps if
    /// SwiftUI ever releases its `@State` storage off the main thread. The window going away
    /// is what this is about, and `onDisappear` is the event for that.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Hands back the `NSWindow` a SwiftUI view has ended up in.
///
/// SwiftUI has no way to ask, and the deck needs the answer for one reason only: to tell a
/// held Return in this window from one in the settings window, where a text field is entitled
/// to every repeat it gets.
///
/// The window is `nil` while `makeNSView` runs — the view is not in a hierarchy yet — so that
/// half answers on the next turn of the run loop and the update below answers on the spot.
/// Nothing here touches SwiftUI state, so this cannot ask for a layout pass of its own.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in found(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        found(view.window)
    }
}

// MARK: - the strip above the card

/// Where the user is, what they have recovered, and the deck as a skyline of bars.
struct DeckStripView: View {
    let summary: ProjectDeckSummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                // `nil` at the end of the deck, where there is no position to be in. The
                // counter on the right is two lines tall and sets this row's height, so
                // dropping the text moves nothing.
                if let position = summary.positionText {
                    Text(position).font(.system(size: 13, weight: .semibold))
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(summary.sessionLabel)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(summary.sessionBytesText)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        // The total ticks up rather than cutting, which is the one place the
                        // window shows what a card was worth after it has gone.
                        .contentTransition(.numericText())
                }
            }
            SkylineView(bars: summary.skyline)
        }
        .padding(.horizontal, DeckStyle.inset)
        .padding(.top, 10)
        // Keyed on the session total, which is the one number here that moves: without an
        // animation driving it `contentTransition(.numericText())` above has nothing to
        // interpolate and the figure simply cuts. The bar that was just answered changes
        // colour on the same beat, which is what ties the two halves of the strip together.
        .animation(DeckStyle.deal(reduceMotion: reduceMotion), value: summary.sessionBytes)
    }
}

/// The whole deck in 30 points: one bar per project, tallest first, each drawn in the state
/// the user left it in.
///
/// `fraction` arrives square-rooted, so the 51 MB project at the end of a deck that starts at
/// 12 GB is still tall enough to show whether it has been answered — see
/// `ProjectDeckSummary.skylineFraction`. Hidden from accessibility because the position line
/// above it says the same thing in words.
struct SkylineView: View {
    let bars: [SkylineBar]

    private static let height: CGFloat = 30

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(bars) { bar in
                shape(for: bar.state)
                    .frame(minWidth: 2, maxWidth: .infinity)
                    // A floor of 3 points, so an answered project is never a bar too short
                    // to have a state at all.
                    .frame(height: max(3, bar.fraction * Self.height))
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .accessibilityHidden(true)
    }

    /// Five readings. Cleaned is filled in the rebuild colour and a cleaned big thing in the
    /// download colour, the card on screen is filled in ink, an upcoming project is a faint
    /// block, and a skipped one is **hollow** — an outline, because nothing happened to it.
    @ViewBuilder
    private func shape(for state: SkylineBar.State) -> some View {
        let bar = UnevenRoundedRectangle(
            topLeadingRadius: 2, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 2)
        switch state {
        case .cleaned:  bar.fill(DeckStyle.rebuild)
        // The one place the strip shows that the promise changed: a cleaned big thing is
        // filled in the amber token rather than the blue, so a session that trashed nine
        // caches and one language model reads as two different things at a glance.
        case .cleanedBigThing: bar.fill(DeckStyle.download)
        case .current:  bar.fill(.primary)
        case .skipped:  bar.strokeBorder(.secondary, lineWidth: 1.5)
        case .upcoming: bar.fill(DeckStyle.hairline)
        }
    }
}

// MARK: - the card

/// The raised card every state of the deck is drawn on: one shell, so the end card and the
/// project card cannot drift into two different cards.
struct DeckCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(DeckStyle.card))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(DeckStyle.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }
}

/// One project: what it is, where it is, what it is worth, and which folders make up that
/// number.
struct ProjectCardView: View {
    let card: ProjectCard
    /// The run's report while this card is being cleaned. `nil` the rest of the time, which
    /// is what leaves every bar full.
    let progress: ExecutionProgress?
    /// The lines a finished clean left behind, empty in the ordinary case.
    let problems: [String]
    /// Ticks or clears one row of a checklist page, by identifier. A no-op by default,
    /// because every other kind of card has no boxes to press — `ProjectCard.folders` say so
    /// themselves, in `ProjectCardFolder.isTicked`.
    var setRowTicked: (String, Bool) -> Void = { _, _ in }
    /// "Select all" or "Select none", whichever the card is offering.
    var setAllRowsTicked: (Bool) -> Void = { _ in }

    var body: some View {
        // The card hugs its content until its rows no longer fit, and then — and only then —
        // the rows scroll. `ViewThatFits` picks the first arrangement that fits the height it
        // is offered: a two-folder card is short, with window under it, rather than a tall
        // card with a void between its rows and its edge. Measuring the rows by hand and
        // clamping a `ScrollView` would be the same thing with two preference keys and a
        // `GeometryReader`, and it would get the first frame wrong.
        ViewThatFits(in: .vertical) {
            shell(rowsScroll: false)
            shell(rowsScroll: true)
        }
    }

    private func shell(rowsScroll: Bool) -> some View {
        DeckCard {
            heading
            GainNumber(headline: card.totalHeadline)
                .padding(.top, 10)
            Text(card.folderCountText)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .wrapped()
                .padding(.top, 4)
            // Over the rows, because it is about all of them: one quiet text button whose
            // word follows the boxes. `nil` on every card that has none.
            //
            // Both the word and what pressing it does come off the card together — see
            // `ProjectCard.ChecklistSelectAll` — so a control labelled "Select none" cannot
            // be the one that ticks everything. A link rather than a third bezel: it is not
            // one of the two answers the card is asking for.
            if let selectAll = card.checklistSelectAll {
                Button(selectAll.title) { setAllRowsTicked(selectAll.ticksEverything) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.top, 8)
            }
            if rowsScroll {
                ScrollView {
                    rows
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
                .padding(.top, 16)
            } else {
                rows.padding(.top, 16)
            }
            // What this card is **not** offering. Under the rows, because it is about the
            // same list — 22 derived data folders offered, 5 kept for projects that are
            // still there — and a card showing 9.1 GB with no mention of the rest looks
            // like a measurement that disagrees with the disk.
            if let kept = card.keptText {
                Text(kept)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .wrapped()
                    .padding(.top, 8)
            }
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.self) { problem in
                        Text(problem)
                            .font(.caption).foregroundStyle(.orange).wrapped()
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            // What sort of card this is: "Project", or the technology the rows belong
            // to. It is what lets the counter above read "3 of 24" with no noun —
            // and on a deck that mixes a project with derived data, it is the difference
            // between a heading the user can place and one they cannot.
            Text(card.eyebrow)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)
            Text(card.name)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.4)
                .lineLimit(2)
            HStack(spacing: 8) {
                // `nil` on a card with no one place to name: a simulator has no path, and a
                // set of caches scattered across four directories has no common parent
                // worth printing. Middle truncation, because the end of a path is the
                // project and the start is where it lives, and both are worth more than the
                // workspace folder in between.
                if let path = card.pathText {
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // `nil` when the scan could not date the project, and always `nil` on a tool
                // card. No stand-in: "last changed today" is the reading that most strongly
                // says do not clean this.
                if let changed = card.lastChangedText {
                    Text(changed)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // The one card in the deck where looking first is the reasonable thing to do:
            // it is a file the user chose to have, and "is this the archive I still need?"
            // is a question only Finder can answer. A plain link rather than a third bezel,
            // because it is not one of the two answers the card is asking for.
            //
            // `nil` on every other kind of card, and which those are is the model's
            // decision — `ProjectCard.revealURL`, which is also where the URL comes from,
            // built against the home the rest of the app measured.
            if let reveal = card.revealURL {
                Button(ProjectDeckText.showInFinder) {
                    // Selects it in a Finder window rather than opening it. Opening a
                    // 7 GB `.xip` would start unarchiving it, and opening a folder of
                    // model shards is no use at all.
                    NSWorkspace.shared.activateFileViewerSelecting([reveal])
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .padding(.top, 2)
            }
            // The lines that argue with the button below them, so they sit directly under
            // the path rather than among the rows: each is a fact about the **card**, like
            // the two lines above them, and not about any one folder. None to two of them —
            // `ProjectCard.cautionLines` says which and why.
            //
            // The glyph carries the orange and the sentence does not. `.secondary` would
            // file these with the path and the date, which are context; full `.primary` with
            // an orange mark beside it reads as something to take in without shouting, and
            // the words are legible to a colour-blind user with the colour ignored
            // entirely — the same rule as the folder rows, where the hint says in words
            // what the fill says in blue or orange.
            ForEach(card.cautionLines, id: \.self) { caution in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(DeckStyle.download)
                    Text(caution)
                        .lineLimit(2)
                        .wrapped()
                }
                .font(.system(size: 12))
                .padding(.top, 2)
            }
        }
    }

    /// The folders, biggest first — which on every card but the checklist page is also the
    /// order the engine works through them in.
    ///
    /// Each row drains on its **own** `runIndex` rather than on its place in this list, and
    /// the two part company exactly once: a checklist page draws the rows the user cleared as
    /// well, and those are in no run at all. Drained by position, an unticked row would strike
    /// itself through while the file it names sat untouched on the disk.
    private var rows: some View {
        VStack(spacing: 5) {
            ForEach(card.folders) { folder in
                FolderRowView(
                    folder: folder,
                    isDrained: ProjectCard.isFolderDrained(
                        at: folder.runIndex, progress: progress),
                    setTicked: { setRowTicked(folder.id, $0) })
            }
        }
    }
}

/// The row **is** the bar.
///
/// The folder's name, how it comes back, and its size sit inside the track that measures it,
/// so a long name cannot push the number away from its own bar. The fill is the token at low
/// opacity with a solid three-point leading edge, and its length is `fraction` — already
/// worked out against the biggest folder on this card, so this file cannot decide what the
/// bars compare against.
///
/// On a checklist page the same bar grows a checkbox — and the whole of it becomes that
/// checkbox's label, so clicking anywhere on the row ticks it: see `tickable`. It grows a
/// reveal button at its trailing edge too, which is the one part of the row that is not the
/// checkbox.
///
/// `@MainActor` so the checkbox's `Binding` can be built at all. `Binding.init(get:set:)`
/// wants two `@isolated(any) @Sendable` closures, and the setter is this row's `setTicked` —
/// a function value that is not `Sendable` and cannot be, because it ends at
/// `AppModel`. Isolating the view is what makes the closures main-actor isolated, which is
/// the other way that requirement is met; the alternative was a hand-drawn box with a tap
/// gesture, which is not a checkbox to a screen reader.
@MainActor
struct FolderRowView: View {
    let folder: ProjectCardFolder
    /// The run has finished with this folder: the fill runs out and the text is struck
    /// through. Animated here rather than by the card's own transition, and more slowly, so
    /// eight folders read as a queue draining rather than a flicker.
    let isDrained: Bool
    /// Ticks or clears this row. Never called on a card whose rows have no boxes, because
    /// nothing on such a row is a control — see `tickable`.
    var setTicked: (Bool) -> Void = { _ in }

    private static let height: CGFloat = 34
    private static let radius: CGFloat = 8

    /// **The size never yields.** It is why the row exists — the user is deciding by size —
    /// and it was the one thing a long name could push off the row entirely: a 60-character
    /// film name took its ideal width at priority 1 and left the number, at the default 0,
    /// nothing at all. Highest priority here means the HStack satisfies it first, whatever
    /// else has to be cut.
    private static let sizePriority: Double = 2
    /// The name yields before the size does, in the middle, and takes what is left after it.
    private static let namePriority: Double = 1
    /// The folder yields **first** and may go entirely: at a lower priority than the rest it
    /// is offered only the leftover, which on a cramped row is nothing, and a zero-width line
    /// with `lineLimit(1)` draws nothing. It is the least of the three — the name says which
    /// file, the number says what it is worth, and the folder only tells two files of one name
    /// apart. The whole path stays in `.help`, which is on the row rather than on this line
    /// precisely so the tooltip does not vanish with the text.
    private static let folderPriority: Double = -1
    /// The reveal button's column, reserved on every checklist row whether or not that row has
    /// somewhere to go, so the sizes stay in one column down the page.
    private static let revealWidth: CGFloat = 22

    /// Whether this row carries a box, which is the **model's** answer and not this file's:
    /// `ProjectCardFolder.isTicked` is `nil` on every row that is not a choice, which is
    /// every card but the checklist page. A view that drew a box for `false` would put an
    /// empty checkbox beside every folder of every project in the deck.
    private var tickable: Bool { folder.isTicked != nil }

    /// Blue when the next build remakes it, orange when it comes back over the network. The
    /// safest pair for colour-blind users, and the row says which in words either way — the
    /// colour is never the only thing carrying it.
    private var edge: Color { folder.needsDownload ? DeckStyle.download : DeckStyle.rebuild }
    private var fill: Color {
        folder.needsDownload ? DeckStyle.downloadFill : DeckStyle.rebuildFill
    }

    var body: some View {
        revealable {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.radius).fill(DeckStyle.track)
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Rectangle().fill(edge).frame(width: 3)
                        Rectangle().fill(fill)
                    }
                    .frame(width: isDrained
                           ? 0
                           : max(0, geometry.size.width * folder.fraction))
                }
                // Clipped to the track, so the three-point edge disappears with the fill
                // rather than being left behind as a tick mark on an empty row.
                .clipShape(RoundedRectangle(cornerRadius: Self.radius))
                control.padding(.horizontal, 12)
            }
            .frame(height: Self.height)
            .animation(DeckStyle.drain, value: isDrained)
        }
    }

    /// The row's contents: a plain label, or the same label as the label of a checkbox, with
    /// the reveal button beside it.
    ///
    /// A native `Toggle` with `.toggleStyle(.checkbox)`, and the **whole label** is the row,
    /// which is what makes the whole row clickable without a second hit target to keep in
    /// step with the box. It is also the only version of this that a screen reader can use:
    /// a drawn box with a tap gesture on it is a picture beside some text, where this is a
    /// checkbox announced with the file's name, its folder and its size.
    ///
    /// **The reveal button sits outside that label**, as the Toggle's sibling rather than
    /// inside it, and that is the whole reason for the `HStack`: a button inside the label
    /// would be a control inside another control's hit area, where one click would both
    /// reveal the file and tick the box. Out here it takes its own click and the rest of the
    /// row still toggles.
    @ViewBuilder
    private var control: some View {
        if tickable {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { folder.isTicked == true },
                                     set: { setTicked($0) })) {
                    label
                }
                .toggleStyle(.checkbox)
                // So the label is offered everything up to the reveal column and its trailing
                // size lands against the near edge of that column.
                .frame(maxWidth: .infinity, alignment: .leading)
                reveal
            }
        } else {
            label
        }
    }

    /// One click to Finder, at the trailing edge of a checklist row.
    ///
    /// The page is answered by **looking**: "is this the lesson video I still need?" is a
    /// question nothing on the card can settle, and the user does it for row after row. The
    /// context menu below does the same thing in two gestures, and it stays — a right-click is
    /// where a Mac user looks for it — but the thing done this often is worth a button.
    ///
    /// Not disabled by anything. The boxes freeze while a run is going and while the page is
    /// being held for its problems, and looking is allowed throughout: it changes nothing.
    ///
    /// The column is reserved on every checklist row, so a row whose item carries no path
    /// leaves a gap rather than pulling its size out of line with the rows above it.
    @ViewBuilder
    private var reveal: some View {
        Group {
            if let reveal = folder.reveal {
                Button {
                    // Selects it in a Finder window rather than opening it: opening a 3.8 GB
                    // film starts playing it, and the question was whether to keep it.
                    NSWorkspace.shared.activateFileViewerSelecting([reveal.url])
                } label: {
                    // The magnifier in a circle, which is what macOS itself puts on "show in
                    // enclosing folder". A plain `folder` would read as "open the folder",
                    // which is not what this does — it selects the file.
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        // The whole reserved column takes the click, not just the glyph: a
                        // 16-point target in a 34-point row is a target people miss, and
                        // missing it here means ticking the box instead.
                        .frame(width: Self.revealWidth, height: Self.height)
                        .contentShape(Rectangle())
                }
                // `.plain` rather than `.borderless`, which tints its label with the accent
                // colour: the icon is furniture beside the size, not a second amber thing on
                // a card that uses amber to mean "read this first".
                .buttonStyle(.plain)
                .help(reveal.help)
                // The words are the model's, including the file's name: forty rows of "Show in
                // Finder" is forty identical announcements to somebody moving by keyboard.
                .accessibilityLabel(reveal.accessibilityLabel)
            }
        }
        .frame(width: Self.revealWidth)
    }

    /// One line, always — and that is the fix for the checkbox riding high.
    ///
    /// The size had no `lineLimit`, so on a row whose name took the whole width it was offered
    /// almost none and wrapped: "3.8" over "GB", sometimes worse. A two-line label is a label
    /// the checkbox style aligns to the **first** line of, which is what put the box up near
    /// the top of the bar. With every line of the row bounded to one, the label is one line
    /// tall in every case and the box is centred in the 34-point row by the `ZStack` above.
    private var label: some View {
        HStack(spacing: 10) {
            Text(folder.name)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                // **Middle on a checklist page**, so the extension survives: `.mov`, `.rgb`
                // and `.db` are half of what tells a film from a frame dump from a build
                // artefact, and `12-iphone-4k-hevc-hu…` has lost the part that says what it
                // is. A folder name on every other card is read from the front.
                .truncationMode(tickable ? .middle : .tail)
                // The name before the folder line: that line is one of four sentences the
                // user learns in a card or two, and the name is the thing they have to
                // recognise. Behind the size, which never yields at all.
                .layoutPriority(Self.namePriority)
            Text(folder.restoreHint)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
                // Middle on a checklist page, tail everywhere else, and that is typography
                // rather than a decision about the row: the hint there is the folder the file
                // sits in, whose two ends — where it lives and which project it is — are
                // worth more than the workspace directory in the middle, exactly as on the
                // card's own path line. A sentence, which is what every other card's hint is,
                // reads from the front and is cut at the end.
                .truncationMode(tickable ? .middle : .tail)
                .layoutPriority(Self.folderPriority)
            Spacer(minLength: 6)
            Text(folder.sizeText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(Self.sizePriority)
        }
        // A project's hint is four words and always fits. A tool row's is the scanner's own
        // sentence — "deleting it destroys the device and every app installed in it, with no
        // Trash and no undo" — which does not, and it is the row's whole explanation. Hovering
        // is how the rest of it is read.
        //
        // **On the row, not on the line it describes.** That line is the first thing squeezed
        // out of a cramped row, and a tooltip that disappeared with it would take the path
        // with it exactly when the path was no longer on screen.
        //
        // `helpText`, not `restoreHint`: the two differ on a checklist page, where the visible
        // line is the folder and what a hover wants is the part that was cut plus the file
        // name — together, the path. Which string that is is the model's decision; see
        // `ProjectCardFolder.helpText`.
        .help(folder.helpText)
        .strikethrough(isDrained)
        .opacity(isDrained ? 0.4 : 1)
    }

    /// Adds "Show in Finder" to the row, on a row that has somewhere to go.
    ///
    /// The one kind of row where looking first is the reasonable thing to do: a checklist
    /// page is a list of files the user chose to have, and "is this the archive I still
    /// need?" is a question only Finder can answer. Per row, because the card is a list —
    /// `ProjectCard.revealURL` is the same affordance on a card that *is* one file.
    ///
    /// **Kept now that the row has a button for it as well.** The button is what the user
    /// asked for — they open these in Finder a lot and a right-click then a menu item is two
    /// gestures — and this is where a Mac user looks for the same thing, so taking it away
    /// would be an affordance removed to no purpose. Both go to `ProjectCardFolder.reveal`
    /// for the URL and the words, so they cannot come to mean different things.
    ///
    /// Applied only when there is a URL, so no other row in the deck grows an empty menu.
    /// Which rows have one is the model's decision: `ProjectCardFolder.revealURL`.
    @ViewBuilder
    private func revealable<Content: View>(@ViewBuilder _ row: () -> Content) -> some View {
        if let reveal = folder.revealURL {
            row().contextMenu {
                Button(ProjectDeckText.showInFinder) {
                    // Selects it in a Finder window rather than opening it: opening a 3.8 GB
                    // film starts playing it, and the question was whether to keep it.
                    NSWorkspace.shared.activateFileViewerSelecting([reveal])
                }
            }
        } else {
            row()
        }
    }
}

/// The gain, set like the capacity printed on a drive label: a compressed heavy numeral at 96
/// points with its unit at 40, baseline-aligned.
///
/// The one deliberately loud thing in the window. The user's complaint about what this
/// window used to be was that its numbers were too small to decide from, and this is the
/// answer — a card you can read from across the room.
///
/// The split into number and unit is `SizeHeadline`'s, not this view's: which characters are
/// the unit is a decision, and one taken inside a SwiftUI body is a decision no test can
/// read.
///
/// The small half is `trailingText`, which is the bare unit on an ordinary card and the whole
/// "of 41.3 GB" on a checklist page — where the big numeral is what the user has ticked out of
/// what there is. Set identically either way, because typographically they are the same thing:
/// the quiet half of one quantity. Which of the two it is is also the model's answer rather
/// than an `??` in this body.
struct GainNumber: View {
    let headline: SizeHeadline

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(headline.number)
                .font(.system(size: 96, weight: .heavy))
                .fontWidth(.compressed)
                .monospacedDigit()
            if let trailing = headline.trailingText {
                Text(trailing)
                    .font(.system(size: 40, weight: .heavy))
                    .fontWidth(.compressed)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        // A 96-point line box is about a third taller than the digits in it, and that third
        // would be empty space between the path above and the folder count below. Negative
        // padding takes the slack out of the frame without clipping anything: digits have no
        // descenders, and neither has "GB".
        .padding(.vertical, -8)
        // On the narrowest window a four-character number like "104" plus its unit still has
        // to fit on one line rather than truncating the thing the card is about — and a
        // checklist page's "0.6 of 41.3 GB" is the longest of these headlines by some way.
        .minimumScaleFactor(0.6)
    }
}

// MARK: - the card at the end of the deck

/// The last card: what the session came to, what is waiting in the Trash, and what was left
/// alone.
///
/// The same shell as a project card, deliberately — the deck ends where it was read, not in a
/// different kind of panel. Every sentence here is already chosen: `ProjectDeckSummary`
/// decides whether the headline is "That's everything." or "Nothing to clean up.", whether
/// there is a number to set large at all, how many amount lines there are under it, and which
/// of the two buttons the session earned.
struct EndCardView: View {
    let summary: ProjectDeckSummary
    /// The three kinds of thing that never got a card: a pinned project, a scanner whose
    /// every row is in use, and everything under the floor. All three lines are `nil` on a
    /// machine where none of it happened.
    let deck: ProjectDeck

    var body: some View {
        DeckCard {
            Text(summary.endHeadline)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.4)
                .wrapped()
            // `nil` on a deck that moved nothing. A 96-point zero over "You left every
            // project alone" would read as a failure rather than as a decision.
            if let gain = summary.endGain {
                GainNumber(headline: gain).padding(.top, 10)
            }
            // One line per amount, because the number above them is a sum: "4.4 GB moved to
            // the Trash" and "17.3 GB deleted for good" are two different promises, and
            // `ProjectDeckSummary.endDetailLines` is what decides how many there are.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(summary.endDetailLines, id: \.self) { line in
                    Text(line).wrapped()
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.top, summary.endGain == nil ? 8 : 4)
            if let note = summary.endNote {
                Text(note).font(.system(size: 12)).wrapped().padding(.top, 14)
            }
            if let hidden = summary.hiddenInTrashNote {
                Text(hidden)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .wrapped()
                    .padding(.top, 4)
            }
            if let skipped = summary.skippedText {
                Text(skipped)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .wrapped()
                    .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let kept = deck.keptProjectsText {
                    Text(kept)
                }
                // The scanners that got no card at all because everything they found is in
                // use — the emulator and its system image on this Mac, 12 GB the user would
                // otherwise go looking for.
                if let keptTools = deck.keptToolsText {
                    Text(keptTools)
                }
                if let small = deck.smallThingsText {
                    Text(small)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .wrapped()
            .padding(.top, 18)
            // The space this app will not take: the browser caches and the desktop apps'
            // own, measured every scan and offered by nothing. Under the quiet lines above,
            // because those are about what this session did and this is about what is still
            // there — and `nil` on a machine where there is nothing to say, so no heading
            // ever stands over an empty list. Every word and every number is
            // `ProjectDeck.moreToGain`'s; this draws three things.
            if let more = deck.moreToGain {
                VStack(alignment: .leading, spacing: 3) {
                    Text(more.title)
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(more.lines, id: \.self) { line in
                        // `monospacedDigit` so the sizes at the ends of the lines line up
                        // as a column instead of ragging against the proportional name in
                        // front of them.
                        Text(line).font(.system(size: 12).monospacedDigit()).wrapped()
                    }
                    Text(more.note)
                        .font(.system(size: 11))
                        .wrapped()
                        .padding(.top, 3)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 16)
            }
        }
    }
}

// MARK: - a button's title and its keyboard hint

/// "Clean up 2.9 GB ⏎".
///
/// Two `Text`s rather than one string, so the hint can be dimmed against whatever the button
/// style paints behind it — a primary button's label is `onRebuild`, and `.secondary` there
/// would be the wrong grey. Both words are `ProjectDeckText`'s; only the opacity is this file's.
///
/// The hint is optional because one button in the deck has no key: "Delete 21.4 GB for good"
/// must be clicked, so printing a "⏎" on it would teach a key that does nothing. Which
/// buttons those are is the model's decision — `ProjectCard.primaryActionKeyHint`.
struct ActionTitle: View {
    let title: String
    let hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let hint {
                Text(hint).opacity(0.6)
            }
        }
    }
}

// MARK: - the two buttons

/// The deck's own buttons: one filled, one quiet.
///
/// Not `.borderedProminent` with a tint, which is what this window used first. macOS paints a
/// prominent button in its tint **only while the window is key**, and hands it the plain
/// bezel the rest of the time — so on a window the user had merely not clicked yet, Clean up
/// was the same white as Skip beside it, and the one button this window exists for was the
/// one that did not stand out. The answer on the card has to be findable at a glance whatever
/// the window's state, so the fill is drawn here and is always there.
///
/// Everything a system button would have given is put back by hand: a pressed state, a
/// disabled state that still reads as the same button, and one height for both kinds so the
/// pair sits on one line.
struct DeckButtonStyle: ButtonStyle {
    enum Kind {
        /// The answer the window is asking for: Clean up, Next project, Open the Trash.
        case primary
        /// The way round it: Skip, Go through skipped again.
        case secondary
    }

    private let kind: Kind
    private let tone: ProjectCard.PrimaryActionTone
    private let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    /// `fillsWidth` for a button whose label does not carry its own width. Clean up and Open
    /// the Trash frame their labels themselves; a plain `Button("Next project")` cannot.
    ///
    /// `tone` defaults to `.regenerable`, so the three primary buttons that are not a card's
    /// answer — Scan now, Next project, Open the Trash — stay the accent blue without
    /// saying anything. Only `cardButtons` passes the card's own, and only a card can know:
    /// see `ProjectCard.primaryActionTone`.
    init(_ kind: Kind, tone: ProjectCard.PrimaryActionTone = .regenerable,
         fillsWidth: Bool = false) {
        self.kind = kind
        self.tone = tone
        self.fillsWidth = fillsWidth
    }

    /// The fill and the label colour, as one decision. Amber is not simply a different
    /// background: white on `DeckStyle.download` is a contrast ratio of 3.5:1 in the light
    /// appearance and 2.2:1 in the dark, so the pair has to travel together — see
    /// `DeckStyle.onDownload`.
    private var isAmber: Bool { kind == .primary && tone == .deliberate }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(
                kind == .secondary
                    ? Color.primary
                    : (isAmber ? DeckStyle.onDownload : DeckStyle.onRebuild))
            .lineLimit(1)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(shape.fill(
                kind == .secondary
                    ? DeckStyle.card
                    : (isAmber ? DeckStyle.download : DeckStyle.rebuild)))
            .overlay {
                if kind == .secondary { shape.strokeBorder(DeckStyle.hairline) }
            }
            // Pressed darkens rather than fades, so a pressed primary is still the primary.
            .brightness(configuration.isPressed ? -0.08 : 0)
            // Disabled keeps its colour at a lower strength: Clean up is dead for the whole
            // of a scan, and it should still be recognisably the button that comes back.
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

// MARK: - the palette and the motion

/// The deck's colours, its insets and its two animations.
///
/// This is the one thing a view in this app owns. A colour cannot be asserted by a test that
/// can read `ProjectCard` — it is not in the data and it changes nothing about what a click
/// removes — and putting a `Color` in `DevCleanerUI` would make that library import SwiftUI
/// for something no decision depends on. What is **not** here is anything a test could
/// disagree with: no titles, no sizes in bytes, no thresholds, no rules about what goes.
enum DeckStyle {
    /// The content inset on every side of the window's own edge.
    static let inset: CGFloat = 28

    /// The folder comes back locally: the next build remakes it. Also the deck's accent —
    /// the Clean up button, and a cleaned bar in the skyline.
    private static let rebuildLight = NSColor(
        srgbRed: 0.204, green: 0.341, blue: 0.835, alpha: 1)     // #3457D5
    private static let rebuildDark = NSColor(
        srgbRed: 0.482, green: 0.576, blue: 1.000, alpha: 1)     // #7B93FF
    /// The folder comes back over the network. The pair is blue and orange on purpose: it is
    /// the safest one for colour-blind users, and the row says which case it is in words too.
    private static let downloadLight = NSColor(
        srgbRed: 0.788, green: 0.451, blue: 0.102, alpha: 1)     // #C9731A
    private static let downloadDark = NSColor(
        srgbRed: 0.941, green: 0.627, blue: 0.294, alpha: 1)     // #F0A04B

    /// The near-black navy that goes **on** a light fill. Named, because two things write
    /// on one now and a second literal is a second colour.
    private static let ink = NSColor(
        srgbRed: 0.043, green: 0.063, blue: 0.188, alpha: 1)      // #0B1030

    static let rebuild = dynamic(light: rebuildLight, dark: rebuildDark)
    /// What is written on a `rebuild` fill: white on the deep blue, and a near-black navy on
    /// the lighter blue the dark appearance uses, where white would wash out.
    static let onRebuild = dynamic(light: .white, dark: ink)
    static let download = dynamic(light: downloadLight, dark: downloadDark)
    /// What is written on a `download` fill: the same navy in **both** appearances, which is
    /// the one place these two tokens differ in shape.
    ///
    /// Measured rather than chosen. Against `#C9731A` white is 3.5:1 and the navy is 5.2:1;
    /// against the dark appearance's `#F0A04B` white is 2.2:1 — below even the large-text
    /// threshold — and the navy is 8.4:1. Amber is a light colour in both appearances, so
    /// unlike the blue there is no side of it that wants white, and a `dynamic` pair that
    /// happens to hold one value twice is still the right shape: it says which token this is
    /// for, and it is where a future amber that needs a lighter label would be fixed.
    static let onDownload = dynamic(light: ink, dark: ink)

    /// A row's fill: the token at low opacity, a little stronger in the dark where the card
    /// behind it is already dark. Dynamic colours rather than `.opacity` on the token above,
    /// because the two appearances want two different opacities and a `Color` cannot ask
    /// which one it is being drawn in.
    static let rebuildFill = dynamic(
        light: rebuildLight.withAlphaComponent(0.17),
        dark: rebuildDark.withAlphaComponent(0.22))
    static let downloadFill = dynamic(
        light: downloadLight.withAlphaComponent(0.17),
        dark: downloadDark.withAlphaComponent(0.22))

    /// The empty part of a row's bar. Barely there: it marks where a bar could reach without
    /// competing with the bar that is there.
    static let track = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.045),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06))

    static let window = Color(nsColor: .windowBackgroundColor)
    /// The raised card. `controlBackgroundColor` rather than a hand-picked white, so a card
    /// on a Mac with an increased-contrast or tinted appearance is still the system's idea of
    /// a raised surface.
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    /// A card being answered and the next one arriving. 0.28 seconds is long enough to read
    /// as the deck moving and short enough that a user going through twenty-four projects
    /// never waits for it.
    ///
    /// Under `accessibilityReduceMotion` it is only a crossfade, and shorter: the transition
    /// it drives has already dropped its offsets and its tilt, so there is nothing left for a
    /// long curve to describe.
    static func deal(reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? 0.18 : 0.28)
    }

    /// A row emptying. Slower than the deal on purpose — this is the one thing on screen
    /// the user is meant to watch.
    static let drain = Animation.easeInOut(duration: 0.45)

    /// Light and dark chosen by hand rather than left to one colour for both. The tokens are
    /// set against a card in one appearance and against a dark card in the other, and
    /// `NSColor`'s dynamic provider means the choice is still the appearance's rather than a
    /// snapshot of whichever one happened to be on at launch.
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
