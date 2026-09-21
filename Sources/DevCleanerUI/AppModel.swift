import Foundation
import Observation
import CleanerCore

/// What the app is doing, and everything its two surfaces need to draw.
///
/// `@MainActor` because every stored property here is read by a view during layout, and
/// `@Observable` so SwiftUI re-renders when one changes. Neither annotation puts work on
/// the main thread: every call into the engine goes through `CleanerEngine`, whose async
/// requirements are `@concurrent` and therefore run on the concurrent pool in this
/// language mode and the next one.
///
/// **One surface cleans.** The window deals the deck and removes things a card at a time;
/// the menu bar draws `statusPanel`, which is a glance and four buttons that remove nothing.
/// So there is one clean path here — `cleanCurrentProject` — and no second list, no ticks and
/// no run summary to keep in step with it.
@MainActor
@Observable
public final class AppModel {
    /// Spec §8.2. What the app is **doing**, and nothing else. The two busy states carry the
    /// latest progress report so the view has something to say beyond a spinner.
    ///
    /// A finished run is deliberately not one of these. A card's clean ends by recording a
    /// decision, showing the card what the run did for `cardResultSeconds` and then dealing
    /// the next card; where it left something behind, the card is held by
    /// `cardAwaitingAcknowledgement` instead. Neither of those is a phase, because the phase
    /// is what `isBusy` reads and a held card leaves the app free to scan.
    ///
    /// The **beat** is the one place that reads oddly out of context: it happens inside the
    /// run's own task, so the phase is still `.running` throughout it and `isBusy` is still
    /// true. That is deliberate rather than incidental — it is what keeps both of the card's
    /// buttons dead while it is showing its result, and what makes `waitForWork()` mean
    /// "everything about that clean is over".
    public enum Phase: Sendable, Equatable {
        case idle
        case scanning(ScanProgress?)
        case running(ExecutionProgress?)
    }

    public private(set) var phase: Phase = .idle
    /// The scan being shown. Survives across a rescan, so neither surface ever goes blank;
    /// a card's clean prunes the rows that went rather than dropping the whole of it.
    public private(set) var result: ScanResult?
    public private(set) var settings: Settings
    /// Why the last scan could not be cached, if it could not. Shown rather than
    /// swallowed: without it both surfaces show an age that never changes and nothing says
    /// why.
    public private(set) var lastCacheError: String?
    /// The last scan progress seen, kept after the phase moves on so a test can assert the
    /// callback was wired up at all.
    public private(set) var sawScanProgress: ScanProgress?

    /// What the user has said about each card so far this session, keyed by
    /// `ProjectCard.id` — a project's directory, or a scanner's identifier.
    ///
    /// Session state, not settings: nothing here is written to disk. A skip means "not
    /// now", and the next launch is a new "now". It survives a fresh scan landing, though,
    /// because a background scan arrives without the user asking and must not deal them
    /// twenty-four cards they have already answered.
    public private(set) var projectDecisions: [String: ProjectDecision] = [:]

    /// The rows of a checklist page the user has **ticked**, by `CleanupItem.id`.
    ///
    /// The ticks themselves, and the empty set means nothing is ticked — which is where the
    /// page starts. The user asked for that after living with it: the rows are their own
    /// films and lesson videos, so the page has to open from "nothing goes" and every file
    /// that goes is one they chose.
    ///
    /// It is also the only way round that is safe. Held as the absences, with an empty set
    /// meaning everything, the default state of this model was an offer to trash every large
    /// file on the disk — and every route that read a card without subtracting them was that
    /// offer reaching the button. This way a row gets into a run by being named here and no
    /// other way, so the failure mode of losing this set is a page that does nothing. It
    /// means a row a later scan has newly found arrives unticked, which is the same answer
    /// the page gives for every row it has never been asked about.
    ///
    /// Keyed by the item's identifier, which is `<scannerID>|<path>`, never by the row's
    /// name or its place on the page: two of these files really are called `scan.pdf`, and a
    /// page holding both must be able to have one ticked and one not.
    ///
    /// Session state, and **forgotten whenever the scan underneath it changes** — see
    /// `setResult`. A tick is a judgement about one measurement, which is the rule this
    /// codebase has always had about ticks, and the opposite of the rule about skips.
    public private(set) var tickedChecklistIDs: Set<String> = []

    /// The deck's order and sizes as this session fixed them, or empty until the first
    /// card is decided. See `rememberDeckOrder` and `forgetVanishedDeckSlots`.
    private var deckSession: [ProjectDeckSlot] = []

    /// The run the **deck** started, and how far it has got: the card's own identifier, so
    /// the window can tell its run from anybody else's.
    ///
    /// `phase` cannot answer that question. It is one slot for the whole app, so a clean
    /// started anywhere puts the window into `.running` — and a card that read progress from
    /// it struck its folders through and titled its button "Cleaning… 57 of 8" while every
    /// one of those folders was still on disk. The count belonged to a different run over a
    /// different list.
    ///
    /// Set only by `cleanCurrentProject`, cleared in `finishCardRun`. A `nil` here with
    /// `phase == .running` is exactly "somebody else's clean is going", which is what the
    /// action note under the buttons says.
    ///
    /// Nothing produces that state today: the menu bar stopped cleaning when it became a
    /// status item, so every run is a card's. It is kept because this pair is the only thing
    /// that can tell two runs apart, and the failure mode of losing it is a card that strikes
    /// through folders another run is not touching.
    public private(set) var cardRun: (cardID: String, progress: ExecutionProgress?)?

    /// When the card on screen became the card on screen, or `nil` for the first card of
    /// the session — which nothing advanced to.
    ///
    /// `@ObservationIgnored`, and nothing draws from it. It is read by
    /// `cleanCurrentProject` alone, which refuses for `cardSettleSeconds` after the deck
    /// moves; see that constant for why. Observed instead, it would ask every redraw to
    /// depend on a moment in time that nothing publishes a change for.
    @ObservationIgnored private var cardBecameCurrentAt: Date?

    /// The card whose run has just ended, and what the run did to it.
    ///
    /// **The one fact the card draws its "after" from**, and the reason it exists is that
    /// there used to be no such fact. A run ended, `cardRun` was cleared, and the card went
    /// back to the offer it had been showing before the button was pressed: every bar full
    /// again over folders that had gone, and the same big number. The user pressed "Delete
    /// 8.5 GB for good", watched the bars drain, watched them refill, and asked whether the
    /// space had really been purged.
    ///
    /// Set the instant the run ends and held until the deck moves on, which is one of two
    /// things: `cardResultSeconds` — the beat — on a clean that went through, or Next on one
    /// that did not. While it is set it **is** the card on screen: see `currentProjectCard`.
    ///
    /// Everything about it is read out of the run's own `RunRecord` — see `CardRunResult` —
    /// never out of the progress reports, which are about what the run was *doing*.
    public private(set) var cardResult: (card: ProjectCard, result: CardRunResult)?

    /// The card whose clean left something behind, and the lines saying what.
    ///
    /// The deck stops on that card until the user presses Next. Advancing straight past it
    /// would show a report of a failure for a third of a second and then deal the next
    /// project over the top of it — and a refused folder is exactly the thing the user has
    /// to know about, because it is still on the disk and still in the total they were
    /// promised.
    ///
    /// **Derived from `cardResult` rather than stored beside it**, because it is the same
    /// fact asked a narrower question — "is the deck stopped here?" — and two stored copies
    /// could disagree about it. `CardRunResult.holdsTheCard` is where the rule lives, and the
    /// change it carries is that a run note which only restates what the card already said
    /// no longer stops anything: a successful permanent deletion used to be held behind
    /// "Next project" under the executor's "were removed outright" sentence in orange, which
    /// reads as a failure.
    public var cardAwaitingAcknowledgement: (card: ProjectCard, problems: [String])? {
        guard let cardResult, cardResult.result.holdsTheCard else { return nil }
        return (cardResult.card, cardResult.result.problems)
    }

    /// What the card on screen has to say about the run that has just ended on it, or `nil`
    /// when no run has just ended on it.
    ///
    /// The window's one way in. It needs no card to match against, because whenever
    /// `cardResult` is set the card on screen is that card — `currentProjectCard` returns it
    /// — so a view asking "is this result mine?" would be asking a question with one answer.
    /// That is the opposite of `cardRun`, which names its card precisely because a run can
    /// belong to somebody else.
    public var currentCardResult: CardRunResult? { cardResult?.result }

    /// Whether anything landed in the Trash this session under a name Finder hides — one
    /// beginning with a dot. Read out of each run's own record, so it is about what really
    /// moved and where it ended up, never about what a card offered.
    ///
    /// Normally false now, because the executor renames a project's build folder before it
    /// goes; this is the note for the runs where that could not be done, and
    /// `ProjectDeckText.hiddenInTrashNote` is what the end card then says.
    public private(set) var trashedHiddenFolders = false

    /// Whether this deck session has already asked for the one rescan it gets.
    ///
    /// Once, not per card. The deck runs out, the loop measures again, and whatever the new
    /// scan finds is the deck the user carries on with — but a session that ends up empty
    /// again must not ask a second time, or an app left open would scan every time its last
    /// card was answered.
    private var didRequestDeckRescan = false

    /// The deck built from the scan on screen, held until that scan changes.
    ///
    /// Building it walks every row of a scan — a couple of hundred on a real dev machine —
    /// groups them by project, sorts, formats every size and writes every sentence. One
    /// SwiftUI body pass asks for the deck four or five times over (`projectDeck`,
    /// `sessionCards`, `currentProjectCard`, `deckSlots`, `deckSummary`), and each of those
    /// used to build it again.
    ///
    /// `@ObservationIgnored` on purpose, and it is what makes this safe: the cache is
    /// written from inside a getter that SwiftUI calls during layout, and an **observed**
    /// property written there would register a change in the middle of the pass that is
    /// reading it. Nothing depends on this field; everything depends on `result`, which is
    /// observed, and `setResult` is the one place that changes either.
    @ObservationIgnored private var builtDeck: ProjectDeck?

    /// How many times the deck has really been built.
    ///
    /// Internal rather than public: it is a window onto the memo above for
    /// `theDeckIsBuiltOncePerAppliedScanHoweverOftenItIsRead`, which is the only way to
    /// pin "once per applied result" from outside — the deck is a value, so two builds of
    /// one scan are indistinguishable by their output. Not observed, for the same reason
    /// `builtDeck` is not.
    @ObservationIgnored var deckBuildCount = 0

    private let engine: any CleanerEngine
    private let cache: ScanCache
    private let clock: @Sendable () -> Date
    /// How the card's result beat waits. Injected for the reason `BackgroundScanLoop`'s is:
    /// `cardResultSeconds` is under a second, but seventy cleans in a test suite are not, and
    /// a suite that really slept could not say when the beat had started or ended either.
    private let sleeper: any Sleeping
    public let home: String
    private var work: Task<Void, Never>?
    /// The background loop, which owns the schedule. `weak` because it owns this model in
    /// turn, and `@ObservationIgnored` because nothing on screen is drawn from it.
    ///
    /// `nil` in every test that builds a model on its own, which is why the two things it is
    /// asked for — a scan after a clean, and a changed interval after a save — each have a
    /// test that builds the real loop as well.
    @ObservationIgnored private weak var scans: (any ScanRequesting)?

    public init(
        engine: any CleanerEngine,
        cache: ScanCache,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleeper: any Sleeping = TaskSleeper()
    ) {
        self.engine = engine
        self.cache = cache
        self.home = home
        self.clock = clock
        self.sleeper = sleeper
        self.settings = engine.settings()
        // Spec §9: the app opens instantly with the last cached result — a deck to work
        // through and an amount in the menu bar. Reading one small JSON file is the whole of
        // "instantly"; the 51-second scan is never on this path.
        if let cached = cache.load() { apply(cached) }
    }

    public var isBusy: Bool {
        switch phase {
        case .scanning, .running: return true
        case .idle:               return false
        }
    }

    /// Told to the app by `BackgroundScanLoop` as that loop is built.
    public func useForScanRequests(_ requester: any ScanRequesting) { scans = requester }

    /// "2h ago", or `nil` when no scan has ever finished.
    public var scanAgeText: String? {
        guard let result else { return nil }
        return AgeText.since(result.generatedAt, now: clock())
    }

    /// The whole menu bar panel, ready to draw. Never `nil`: a machine that has measured
    /// nothing says so.
    ///
    /// Built here rather than in the view because it needs a `now`, and the app must have
    /// exactly one clock. A second one in `DevCleanerApp` would render an age no test can
    /// pin, and it could disagree with `scanAgeText` — the window's own subtitle — on the
    /// same screen.
    ///
    /// The deck goes in for the amount, and the scan for everything else; the reasoning for
    /// the split is on `StatusPanelModel.init`. Reading the deck here is cheap: `projectDeck`
    /// builds it once per applied scan and holds it.
    public var statusPanel: StatusPanelModel {
        StatusPanelModel(
            deck: projectDeck, result: result, phase: phase, cacheError: lastCacheError,
            now: clock(), home: home)
    }

    // MARK: - the project deck

    /// The deck built from the scan on screen. `nil` before the first scan.
    ///
    /// Derived from `result` and never stored beside it, so it cannot drift: a clean prunes
    /// the rows it removed out of the scan and the very next read of this is a deck without
    /// that project in it. The clock is this model's, for the reason `header` gives — a
    /// second one in the view renders a "last changed" no test can pin.
    ///
    /// Built once per applied scan and then held. Reading it is not free — see `builtDeck`
    /// — and a body pass asks four or five different questions that each start here.
    ///
    /// The one thing frozen by holding it is `ProjectCard.lastChangedText`, which is
    /// measured against `now`. That is fine and deliberate: it is worded in days, weeks and
    /// months, a scan lands at least every `backgroundScanIntervalHours`, and every clean
    /// applies a pruned result — so "last changed 3 days ago" cannot go stale by a whole
    /// day without something replacing the scan it came from. Rebuilding per read would buy
    /// a precision no user can see at the cost this change exists to remove.
    public var projectDeck: ProjectDeck? {
        guard let result else { return nil }
        if let builtDeck { return builtDeck }
        deckBuildCount += 1
        // `moveToTrash` goes in because a card's promise line depends on it, so the memo has
        // to be dropped when the setting changes as well as when the scan does — which is
        // what `apply(_ updated: Settings)` does.
        let deck = ProjectDeck(
            result: result, home: home, now: clock(), moveToTrash: settings.moveToTrash)
        builtDeck = deck
        return deck
    }

    /// The deck's cards in the order this session works through them.
    ///
    /// The session's order once one is fixed, otherwise the scan's. Restricted to cards
    /// that still exist: a cleaned project's rows are pruned out of the result, so its card
    /// is gone from here — while its slot stays in `deckSlots`, which is what keeps the
    /// counting and the skyline still.
    public var sessionCards: [ProjectCard] {
        guard let deck = projectDeck else { return [] }
        guard !deckSession.isEmpty else { return applyingTicks(to: deck.cards) }
        let byID = Dictionary(deck.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(deckSession.map(\.id))
        // The same rule `rememberDeckOrder` applies to the slots, so the order the cards are
        // dealt in and the order the skyline draws cannot disagree about where a newcomer
        // went. See `Self.deckOrder`.
        let ordered = Self.deckOrder(
            deckSession.compactMap { byID[$0.id] },
            adding: deck.cards.filter { !known.contains($0.id) && !$0.isInterstitial },
            isBigThing: \.isBigThing)

        // The interstitial is spliced back in rather than remembered, and it has to be:
        // it holds no slot — see `ProjectDeck.interstitialCardID` — so it cannot come out
        // of the order above, and appended with the rest of the newly-found cards it would
        // land *after* the big things it is supposed to introduce.
        //
        // Its place is structural rather than historical. It sits immediately before the
        // first of the user's own files, wherever a later scan has moved that: if every big
        // thing has been answered it is at the end, which is where it belongs, because
        // `currentProjectCard` has already passed it by then.
        guard let interstitial = deck.cards.first(where: \.isInterstitial) else {
            return applyingTicks(to: ordered)
        }
        var cards = ordered
        cards.insert(interstitial, at: ordered.firstIndex(where: \.isBigThing) ?? ordered.count)
        return applyingTicks(to: cards)
    }

    /// Where a card the session has not seen belongs in an order that is already fixed.
    ///
    /// **A newcomer that comes back on its own goes in front of the big things; only a big
    /// thing is appended.** Appending everything is what the deck used to do, and it put a
    /// newly found `.build` card — Return live, blue, "Clean up 20.0 GB" — into the half the
    /// interstitial has just promised is the user's own and click-only. It happens on an
    /// ordinary launch: the deck opens on the cached scan, Skip keeps working through the
    /// 51-second launch scan, and whatever that scan has newly found lands in an order a
    /// skip has already fixed.
    ///
    /// The split is the **first big thing in the order so far**, which is also where
    /// `sessionCards` splices the interstitial, so a newcomer can never come down on the
    /// wrong side of it. A deck with no big things puts everything at the end, exactly as
    /// before.
    ///
    /// Generic over the two things that carry this order — the live cards and the session's
    /// slots — because they have to stay in step: the cards are what is dealt and the slots
    /// are what "3 of 24" counts and the skyline draws, and two spellings of one rule is how
    /// those two come to disagree.
    ///
    /// Relative order within each half is kept, so the deck's own biggest-first sorting
    /// survives.
    static func deckOrder<Card>(
        _ existing: [Card], adding newcomers: [Card], isBigThing: (Card) -> Bool
    ) -> [Card] {
        guard !newcomers.isEmpty else { return existing }
        var ordered = existing
        ordered.insert(
            contentsOf: newcomers.filter { !isBigThing($0) },
            at: existing.firstIndex(where: isBigThing) ?? existing.count)
        ordered.append(contentsOf: newcomers.filter(isBigThing))
        return ordered
    }

    /// The cards as the user has left them: the checklist page's boxes applied.
    ///
    /// **On the cards and deliberately not on the memoised deck.** `projectDeck` builds one
    /// deck per applied scan and holds it — a couple of hundred rows grouped, sorted, sized
    /// and phrased — and a box changes what one card shows without the scan changing at all.
    /// Dropping the memo on every click would rebuild all of that per press, and it would
    /// make the memo's correctness depend on remembering to clear it from a second place.
    /// `ProjectCard.applyingTicks` is a pure function over the card the memo holds instead,
    /// and it answers `self` for every kind of card that has no boxes.
    ///
    /// `deckSlots` deliberately does **not** go through here: a slot remembers what the card
    /// was holding, and the bar over the page is how big the page is rather than how much of
    /// it the user has ticked so far.
    ///
    /// **An empty set is the page exactly as it was dealt**, so there is nothing to derive
    /// and the memo's own card is the answer — which is now the common case, because nothing
    /// is ticked until the user says so. The shortcut is safe in the direction that matters:
    /// the card in the memo hands the engine nothing.
    private func applyingTicks(to cards: [ProjectCard]) -> [ProjectCard] {
        guard !tickedChecklistIDs.isEmpty else { return cards }
        return cards.map { $0.applyingTicks(tickedIDs: tickedChecklistIDs) }
    }

    /// Ticks or clears one row of the checklist page on screen.
    ///
    /// **Frozen while a clean is running**, the same rule as Skip and for a sharper reason:
    /// `cleanCurrentProject` has already handed the engine the list the boxes produced, and
    /// a box changed after that would leave the card counting rows the run is not touching —
    /// the bars drain against `ProjectCardFolder.runIndex`, which is a position in the list
    /// that went. A background scan does not freeze them, because it takes about 51 seconds
    /// and the page is still the user's to read; when it lands it replaces the rows, and the
    /// boxes go with them.
    ///
    /// Frozen again once the run is over and the card is being **held for its problems**: the
    /// rows are still on screen and still carry boxes, but the card has stopped being a
    /// question and become a report of what happened. The only answer it takes is Next.
    ///
    /// Only a row of the card on screen. The identifier is checked against it rather than
    /// taken on trust, so this set cannot come to name rows of a page that is no longer
    /// being asked about — and so "tick this row" can never mean anything but what the user
    /// clicked.
    public func setChecklistRow(_ id: String, ticked: Bool) {
        guard !isCleaningProject,
              cardAwaitingAcknowledgement == nil,
              let card = currentProjectCard, card.isChecklist,
              card.folders.contains(where: { $0.id == id })
        else { return }
        if ticked {
            tickedChecklistIDs.insert(id)
        } else {
            tickedChecklistIDs.remove(id)
        }
    }

    /// "Select all" and "Select none", over the page on screen.
    ///
    /// Restricted to **that page's** rows in both directions, which is why "Select none" is
    /// not `tickedChecklistIDs = []`: a second checklist page in one deck — a scanner this
    /// build does not know, dealt out of a cached scan — would otherwise have its boxes
    /// changed by a press on the first one.
    ///
    /// The word on the button travels with the effect in
    /// `ProjectCard.ChecklistSelectAll`, so a control reading "Select none" cannot tick
    /// everything.
    public func setAllChecklistRows(ticked: Bool) {
        guard !isCleaningProject,
              cardAwaitingAcknowledgement == nil,
              let card = currentProjectCard, card.isChecklist
        else { return }
        let ids = card.folders.map(\.id)
        if ticked {
            tickedChecklistIDs.formUnion(ids)
        } else {
            tickedChecklistIDs.subtract(ids)
        }
    }

    /// The card on screen: the first one this session has not answered.
    ///
    /// A card whose run has just ended holds the deck here although its decision is already
    /// recorded — for `cardResultSeconds` when the run went through, and until the user
    /// presses Next when it did not. `cardResult` is what keeps it here, and it is the one
    /// thing that has to be asked before the decisions, because the card being shown its own
    /// result is by definition a card that has been answered.
    public var currentProjectCard: ProjectCard? {
        if let cardResult { return cardResult.card }
        return sessionCards.first { projectDecisions[$0.id] == nil }
    }

    /// The session's deck: what "3 of 24" counts and what the skyline draws.
    ///
    /// Empty `deckSession` means no card has been answered yet, so there is nothing to hold
    /// still and the live deck is the answer.
    /// A slot is a card with **bytes in it**, which is why the interstitial has none: the
    /// skyline draws one bar per slot at a height taken from its total, and "3 of 24"
    /// counts them. The reasoning is on `ProjectDeck.interstitialCardID`.
    public var deckSlots: [ProjectDeckSlot] {
        guard !deckSession.isEmpty else {
            return (projectDeck?.cards ?? []).filter { !$0.isInterstitial }.map {
                ProjectDeckSlot(id: $0.id, totalBytes: $0.totalBytes,
                                isBigThing: $0.isBigThing)
            }
        }
        return deckSession
    }

    /// 1-based, over the session's deck: `(3, 24)`. `nil` when no card is on screen.
    public var projectPosition: (index: Int, count: Int)? {
        guard let current = currentProjectCard else { return nil }
        let slots = deckSlots
        guard let index = slots.firstIndex(where: { $0.id == current.id }) else { return nil }
        return (index + 1, slots.count)
    }

    /// What this session has really moved.
    ///
    /// `ProjectDeckSummary`'s rule, not a second sum: the figure over the skyline and the
    /// figure on the end card are one number added up once.
    public var deckSessionBytes: Int64 {
        ProjectDeckSummary.sessionBytes(of: projectDecisions)
    }

    /// The strip above the card and the card at the end, ready to draw. `nil` before the
    /// first scan, exactly as `projectDeck` is.
    ///
    /// Built here because it needs `settings.moveToTrash`, and resolving that is the whole
    /// point: the view must not choose between "In the Trash so far" and "Deleted so far"
    /// for itself. Nothing on this screen reads `Settings`.
    public var deckSummary: ProjectDeckSummary? {
        guard projectDeck != nil else { return nil }
        return ProjectDeckSummary(
            slots: deckSlots, decisions: projectDecisions,
            currentCardID: currentProjectCard?.id, moveToTrash: settings.moveToTrash,
            trashedHiddenFolders: trashedHiddenFolders)
    }

    /// The Trash the end card's button opens.
    ///
    /// Built from this model's `home` rather than from `FileManager`'s, so the window opens
    /// the Trash of the home the rest of the app measured — and so a test can say what the
    /// button would open. The button is only offered when `ProjectDeckSummary.openTrashText`
    /// is there, which is Trash mode with something actually in it.
    public var trashDirectory: URL { URL(fileURLWithPath: home + "/.Trash") }

    /// True while a clean is under way. A scan is not: one runs in the background every six
    /// hours and takes about 51 seconds, and the Skip button must not go dead for that long.
    private var isCleaningProject: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Brings the session's deck order up to date with the scan on screen.
    ///
    /// Called before a decision is recorded, and again when a fresh scan lands on a deck
    /// that already has decisions in it.
    ///
    /// **Empty means nothing has been decided**, and then there is nothing to hold still:
    /// the deck takes its order from whatever scan is on screen, which is right, because
    /// the cached scan the app opened with may be six hours old. The first decision fixes
    /// the order, and from then on a later scan can only **add** to it. So "3 of 24" never
    /// renumbers the cards already answered, a cleaned project keeps its slot and its height
    /// in the skyline after its rows are pruned away, and a project that has newly grown past
    /// the floor waits its turn rather than jumping in front of the card being read.
    ///
    /// Where it waits is `Self.deckOrder`'s decision, and it is not simply "at the end":
    /// only a big thing goes there. The two halves of the deck are two different promises,
    /// and a newly found cache dealt behind the card that introduces the user's own files
    /// would be the one card in that half that comes back on its own — blue, Return live,
    /// under a promise it contradicts.
    private func rememberDeckOrder() {
        guard let deck = projectDeck else { return }
        let known = Set(deckSession.map(\.id))
        deckSession = Self.deckOrder(
            deckSession,
            adding: deck.cards
                // The interstitial is not a slot — see `ProjectDeck.interstitialCardID` —
                // and `sessionCards` splices it back into the order instead.
                .filter { !known.contains($0.id) && !$0.isInterstitial }
                .map { ProjectDeckSlot(id: $0.id, totalBytes: $0.totalBytes,
                                       isBigThing: $0.isBigThing) },
            isBigThing: \.isBigThing)
    }

    /// Drops the slots of projects that are neither answered nor still there.
    ///
    /// `rememberDeckOrder` only ever appends, which is what holds "3 of 24" and the skyline
    /// still while the user works through a deck. Appending alone is not enough once a scan
    /// can find **less** than the one before it, and two ordinary things do that: a clean
    /// run from the menu bar drops the whole scan and the rescan behind it comes back with
    /// almost no project rows, and a `flutter clean` in a terminal empties a project the
    /// deck had a card for. The strip then said "Project 2 of 24" over three real cards,
    /// with twenty-one `.upcoming` bars for projects that can never be dealt — and the deck
    /// ended at position 2 of 24, which reads as the window having given up.
    ///
    /// An **answered** slot is kept whatever the scan now says. Those are the session's
    /// history: they carry what each project was worth when it was cleaned or skipped, they
    /// are what the session total and the skyline are built from, and a cleaned project has
    /// no card by design. A slot that is neither answered nor a live card is a project the
    /// user was never shown and now cannot be, so nothing is lost by forgetting it.
    private func forgetVanishedDeckSlots() {
        guard !deckSession.isEmpty else { return }
        let live = Set((projectDeck?.cards ?? []).map(\.id))
        deckSession.removeAll { !live.contains($0.id) && projectDecisions[$0.id] == nil }
    }

    /// Records that the deck has just moved, which starts the settle window.
    ///
    /// Called from every path that changes which card is on screen: a clean recording its
    /// decision, a skip, Next after a problem, and going back through the skipped ones.
    private func deckAdvanced() { cardBecameCurrentAt = clock() }

    /// Whether the card on screen has been there long enough to be acted on.
    ///
    /// `true` for the first card of a session, which nothing advanced to — that is what the
    /// `nil` means.
    private var currentCardHasSettled: Bool {
        guard let since = cardBecameCurrentAt else { return true }
        return clock().timeIntervalSince(since) >= Self.cardSettleSeconds
    }

    /// Starts cleaning the card on screen. Returns whether it started. The app's one clean.
    ///
    /// It records no run summary. The card itself is the answer — for `cardResultSeconds` it
    /// shows what the run did to it, drained rows and "8.5 GB → 0 GB" — and there is no panel
    /// anywhere that would draw one.
    ///
    /// It does not ask for a rescan. A scan takes about 51 seconds, and a rescan between
    /// cards would blank the deck the user is working through, twenty-four times.
    ///
    /// Instead it **prunes**: the rows that really went are dropped from `result` and the
    /// pruned scan is written back to the cache. Every number on both surfaces stays true
    /// without measuring anything again, and the next launch reads back a cache that does
    /// not offer folders this run has already removed.
    /// How long a freshly dealt card refuses to be cleaned.
    ///
    /// Clean up is the window's default action, so Return presses it — and macOS repeats a
    /// held key about thirty times a second. Nothing else stands in the way: there is no
    /// confirmation, and the run is fast on a fake and quick enough on a real project. A user
    /// who held Return for a second cleaned project after project, each decision taken while
    /// the next card was still animating in, and the only record of what went was the Trash.
    ///
    /// `cardResultSeconds` now stands in the way as well, and it is not a substitute: the
    /// beat is time the app is busy rather than time this window is counting, so the two add
    /// up rather than overlapping. This one is still what a test can read, and still what
    /// holds if the beat is ever shortened to nothing.
    ///
    /// 0.6 seconds, against a key-repeat delay of about 0.25 and a repeat interval of about
    /// 0.03, and about twice the 0.28-second deal animation — so by the time the button
    /// answers again the card under the cursor is the card being acted on. Short enough that
    /// nobody deciding project by project ever meets it.
    ///
    /// **It rate-limits a held key; it does not stop one.** That was claimed here and it was
    /// wrong: macOS goes on repeating for as long as the key is down, so a Return held
    /// through the deck answered a card every 0.6 seconds — a dozen cards in eight seconds,
    /// each of them cleaned, and in permanent mode deleted outright. What stops it is a
    /// **fresh** key press being required, which is `DeckKeyboard`: the window swallows the
    /// repeats before any button sees them. This window is the second line, and it is the
    /// half that can be tested — it is also the half that still holds if the monitor is ever
    /// not installed, which is why it stays.
    ///
    /// Only Clean up and the problems card's Next. Skip removes nothing, and a user flicking
    /// through twenty-four projects with the arrow key is the deck working as intended.
    ///
    /// `nonisolated` so anything can read it — a view sizing an animation against it, or a
    /// test stepping a clock past it. It is an immutable number; the isolation this class
    /// carries is about its mutable state.
    public nonisolated static let cardSettleSeconds: TimeInterval = 0.6

    /// How long a cleaned card stays on screen showing what the run did, before the deck
    /// deals the next one.
    ///
    /// **The deck used to deal the next card in the same instant the run ended.** On a clean
    /// with nothing to report that was the whole of the feedback: the bars the user was
    /// watching drain refilled, the card faded, and the next project rose in — so the one
    /// moment that says *it worked* never existed. The user's own words were "I'm not sure if
    /// it works or if this space was really purged".
    ///
    /// 0.9 seconds, against the 0.28-second deal animation and the 0.45-second drain: long
    /// enough for the drained bars to finish emptying and for "8.5 GB → 0 GB" and "Deleted
    /// for good." to be read, short enough that somebody working through twenty-four cards
    /// never waits for it. Both buttons are dead throughout — `isBusy` is still true — so the
    /// beat cannot be answered through, and `cardSettleSeconds` then starts when the next
    /// card arrives.
    ///
    /// **Only the dealing waits.** The decision, the session totals, the prune and the cache
    /// write all happen the moment the run ends, before this: the truth about the disk is not
    /// something to hold back for a beat, and a window closed mid-beat must not lose it.
    ///
    /// A card being **held** for its problems gets no beat. It is already stopped, for longer
    /// and with a button to press, and a beat before the report would delay the one thing the
    /// user has to read.
    ///
    /// `nonisolated` for the same reason `cardSettleSeconds` is: it is an immutable number,
    /// and a test stepping past it should not need the actor.
    public nonisolated static let cardResultSeconds: TimeInterval = 0.9

    @discardableResult
    public func cleanCurrentProject() -> Bool {
        guard !isBusy,
              cardAwaitingAcknowledgement == nil,
              currentCardHasSettled,
              let card = currentProjectCard
        else { return false }
        // The interstitial's primary button is "Look through them", which removes nothing:
        // it notes the card as answered and lets the deck deal the first big thing.
        //
        // Dispatched here rather than in the window, and the window is why. Both buttons
        // read their titles off the card — `primaryActionTitle` and `secondaryActionTitle` —
        // so a view that decided for itself which model call each one made could label a
        // button "Look through them" and wire it to a clean. It arrives through this method
        // rather than one of its own so the interstitial gets the settle window for free:
        // the primary button sits exactly where Clean up sat on the card before it, and a
        // held Return must not carry through.
        guard !card.isInterstitial else {
            rememberDeckOrder()
            projectDecisions[card.id] = .skipped
            deckAdvanced()
            // Asked here as well, for the same reason every other answering path asks: a
            // background scan can have pruned the last of the user's own files away while
            // this card was on screen, and then "Look through them" is what ends the deck.
            requestRescanIfTheDeckIsFinished()
            return true
        }
        // Nothing to hand over. The interstitial is answered above; what reaches here with an
        // empty list is a checklist page with every box still clear, which is the state it is
        // dealt in — so this guard is the model's own refusal, standing whether or not the
        // window remembered to disable the button.
        guard !card.items.isEmpty else { return false }
        // Before the decision, so the first clean of a session fixes the deck's order
        // while the card being cleaned is still in it.
        rememberDeckOrder()

        phase = .running(nil)
        // Named here, before the run starts, so the window can tell this run from a clean
        // any other run: `phase` is shared and cannot say whose run it is.
        cardRun = (card.id, nil)
        let engine = self.engine
        let cache = self.cache
        let startedAt = clock()
        // The card's own list, in the card's own order, so the executor's per-item reports
        // name the rows in the order the user is reading them.
        let items = card.items

        let report: @Sendable (ExecutionProgress) -> Void = { [self] progress in
            Task { @MainActor in self.applyCardRunReport(progress) }
        }

        work = Task { [self] in
            // `clean(items:)`, never `cleanDefault`: this is one project out of a scan of
            // the whole machine, so the engine must remove exactly what it is handed.
            let record = await engine.clean(items: items, now: startedAt, progress: report)
            // The record read against the card it came from, once, here — so the bars the
            // card drains, the amount it says is left and the rows the scan is pruned by are
            // all one reading of one run.
            let outcome = CardRunResult(card: card, record: record)
            let pruned = result.map { Self.pruning($0, removing: outcome.removedItemIDs) }
            // Off the main actor and before anything is drawn, exactly as the scan's write
            // is: the redraw must not wait on a disk that is busy.
            var cacheError: String?
            if let pruned { cacheError = await Self.store(pruned, in: cache) }
            // **Truth first.** Everything the run means is applied here, before the beat:
            // the decision, the session totals, the pruned scan and the cache error. A
            // window closed or a `cancel()` arriving during the beat therefore costs the
            // user nothing but the beat.
            landCardRun(card, record: record, outcome: outcome, cacheError: cacheError,
                        pruned: pruned)
            // The beat: the card keeps its result for a moment so the user can see that the
            // press did something. Its own awaited step, inside `work` and above the line
            // below, which is what lets a test see the state on both sides of it —
            // `waitForWork()` and `isBusy` both cover it, and nothing is mutated after the
            // phase clears.
            //
            // The throw is **swallowed**, unlike the loop's: a cancelled beat is a beat cut
            // short, and a `return` here would leave `phase` on `.running` for the rest of
            // the session with Clean up and Scan again dead behind it.
            if !outcome.holdsTheCard {
                try? await sleeper.sleep(seconds: Self.cardResultSeconds)
            }
            // Nothing goes below this line — no test can see it. The reason is on `finishRun`.
            finishCardRun(holding: outcome.holdsTheCard)
        }
        return true
    }

    /// Leaves the card alone and moves on.
    ///
    /// Refused while a clean is running, because the card on screen is the one being
    /// cleaned and skipping it would record an answer the run is about to overwrite. A
    /// background **scan** does not refuse it: that runs unasked, for about 51 seconds, and
    /// the deck is still the user's to work through while it does.
    public func skipCurrentProject() {
        guard !isCleaningProject,
              cardAwaitingAcknowledgement == nil,
              let card = currentProjectCard
        else { return }
        rememberDeckOrder()
        projectDecisions[card.id] = .skipped
        // "Skip them all": the interstitial's secondary answers for the whole second half
        // of the deck at once, because a user who has just cleaned twelve caches and does
        // not want to be asked about their downloads should be able to say so once. The
        // alternative is arrow-keying through fourteen cards, which is how a user learns to
        // arrow-key without reading — and these are the cards that must be read.
        //
        // Recorded per card rather than as one flag, so every one of them keeps its slot,
        // its bar in the skyline and its share of "14 skipped · 49.2 GB", and so
        // `reviewSkippedProjects` can bring them all back if the user changes their mind.
        if card.isInterstitial {
            for bigThing in sessionCards where bigThing.isBigThing {
                projectDecisions[bigThing.id] = .skipped
            }
        }
        deckAdvanced()
        requestRescanIfTheDeckIsFinished()
    }

    /// Puts away the problems of the card just cleaned and moves on.
    ///
    /// **Held back by the settle window like Clean up**, and this is the one button where
    /// that matters most. "Next project" is the window's default action, so Return presses
    /// it; the Return that started the clean is still down when `finishCardRun` puts the
    /// problems on screen, and the next key repeat — about 33 ms later — pressed this. The
    /// only report the app ever makes of a folder it could not remove was on screen for one
    /// frame, over a folder still sitting on the disk and still inside the total the user
    /// was promised.
    ///
    /// `finishCardRun` sets the timestamp this reads, whether or not a card is being held,
    /// so the window is already open by the time the problems appear. The view swallows
    /// repeats of a held Return as well — see `DeckKeyboard` — and the two are deliberate
    /// belt and braces: that one is the robust stop and lives where `NSEvent` can be
    /// reached, this one is the rule a test can read.
    public func acknowledgeProblems() {
        guard cardAwaitingAcknowledgement != nil, currentCardHasSettled else { return }
        // The whole result goes, not only the problem lines: the card is leaving, and the
        // next one must not be dealt over a drained bar and a "→ 0 GB" belonging to the
        // project before it.
        cardResult = nil
        deckAdvanced()
        // Asked here as well, because the card being held was the last one: until Next is
        // pressed there is a card on screen, so the end of the deck had not arrived yet.
        requestRescanIfTheDeckIsFinished()
    }

    /// Forgets every skip, so those cards come back.
    ///
    /// Only the skips. A `.cleaned` decision is not a decision the user can change their
    /// mind about — the folders are gone — and it is what the session total and the skyline
    /// are built from.
    ///
    /// The one rescan this session gets is **not** re-armed. The deck the user is going
    /// back through was measured a moment ago, and a second 51-second scan is the last
    /// thing a second pass needs.
    ///
    /// Refused while a clean is running — including the beat a finished card holds its result
    /// for — and while a card is being held for its problems, the same two conditions Skip
    /// and Clean up refuse under. The button is only ever on the end card, so neither state
    /// can be reached by clicking; the guard is here because forgetting every skip while a
    /// run is in flight would deal a card out from under it, and a model that answers the
    /// question is a model a test can ask. A background **scan** does not refuse it, for the
    /// reason `skipCurrentProject` gives: it runs unasked for about 51 seconds and the deck
    /// is still the user's.
    public func reviewSkippedProjects() {
        guard !isCleaningProject, cardAwaitingAcknowledgement == nil else { return }
        projectDecisions = projectDecisions.filter { $0.value != .skipped }
        // A card arrives under the cursor the moment this returns, and the button that was
        // just pressed sits where Clean up will be — so the same settle window applies.
        deckAdvanced()
    }

    /// Applies everything a card's clean **means**, the instant the run ends: the decision,
    /// the session totals, the pruned scan, and the result the card now shows.
    ///
    /// Split from `finishCardRun` so the beat can sit between the two. Everything true about
    /// the disk lands here, before any waiting; the other half only takes the card away. So a
    /// window closed during the beat, a `cancel()`, or a crash costs the user the beat and
    /// nothing else — the cache on disk already agrees with what went.
    private func landCardRun(
        _ card: ProjectCard, record: RunRecord, outcome: CardRunResult,
        cacheError: String?, pruned: ScanResult?
    ) {
        // What really went, out of the run's own record — never the card's total. A run can
        // be cancelled and a folder can be refused, and a session figure built from the
        // offer would be a number the disk disagrees with.
        //
        // The run's `notes` join the per-row problems, after them. They are not failures:
        // Xcode having been open, a run the user cancelled, devices removed outright. But
        // they are the things the session will not say again — nothing else in the app
        // reports a finished run — so they are kept on the decision whether or not they are
        // what stops the deck. Per-row reasons come first because those are the ones with
        // something to fix. `CardRunResult` is where both that order and the stopping rule
        // live.
        projectDecisions[card.id] = .cleaned(
            trashedBytes: record.trashedBytes,
            deletedBytes: record.permanentlyDeletedBytes,
            problems: outcome.problems)
        // Where the folder LANDED, not where it came from. The executor renames a project's
        // build folder to "<project> – <folder>" on the way out, so a `.build` normally
        // arrives in the Trash visible and needs no note; `trashedTo` is the only thing that
        // knows whether that worked. Falling back to `target` covers the entry that has no
        // landing place to report — a remover that returns none, and a stored run written
        // before any of this existed.
        if record.entries.contains(where: {
            $0.outcome == .trashed
                && ProjectDeckText.isHiddenInFinder($0.trashedTo ?? $0.target)
        }) { trashedHiddenFolders = true }
        if let pruned { apply(pruned) }
        // The card stops being a question and becomes a report of what happened. It is still
        // `currentProjectCard` while this is set, which is what keeps the drained bars and
        // the "8.5 GB → 0 GB" headline on screen instead of the next project.
        cardResult = (card, outcome)
        lastCacheError = cacheError
        // A **held** card's settle window opens here, before its problems are on screen,
        // rather than when the deck next moves. "Next project" is the window's default
        // action, so the Return that started the clean is still down and its next repeat —
        // about 33 ms later — would press it; `acknowledgeProblems` reads this timestamp for
        // exactly that reason.
        //
        // A card with a beat gets its window when the **next** card is dealt, at the end of
        // `finishCardRun`, because that is when a card arrives under the cursor. Its own
        // buttons are dead throughout the beat — `isBusy` — so nothing needs holding back
        // here.
        //
        // What this buys is a **delay**, not immunity. A held key goes on repeating, so the
        // window rate-limits it to one press per `cardSettleSeconds` and no more — see that
        // constant. Nothing here can stop a held key; only `DeckKeyboard`, which the window
        // applies to the events themselves, can.
        if outcome.holdsTheCard { deckAdvanced() }
    }

    /// Takes the card away and gives the app back: the second half of a card's clean, after
    /// the beat.
    ///
    /// `holding` is `CardRunResult.holdsTheCard`, and it decides the one thing left to
    /// decide — whether the card goes now or waits for Next. It is passed rather than read
    /// back off `cardResult` so this cannot disagree with the branch that chose to wait.
    ///
    /// **Nothing may be added after the call to this from `cleanCurrentProject`'s task**,
    /// for the reason spelled out on `finishRun`: every test waits on `!isBusy`, which this
    /// satisfies the instant it clears the phase, so a statement after the call runs
    /// unobserved and a mutation of it survives. The beat is above the call for that reason
    /// rather than below it.
    private func finishCardRun(holding: Bool) {
        if !holding {
            // The beat is over: the result goes, the next card is dealt, and the window
            // opens on it.
            cardResult = nil
            deckAdvanced()
        }
        // Before the phase clears, so the unstructured task inside is created while this is
        // still the last word on what the deck holds. Creating it is synchronous; it cannot
        // run until this returns. A no-op while a card is being held, because a held card is
        // a card on screen and the deck has therefore not run out.
        requestRescanIfTheDeckIsFinished()
        // Both cleared last, together: they are one fact — "the deck's run is over".
        //
        // **`cardRun` deliberately survives the beat**, which is why it is cleared here and
        // not in `landCardRun`. It is what tells the window the run on screen is this card's,
        // and the primary button's title follows it: kept, the button reads "Cleaning… 8 of
        // 8" for the length of the beat, which is true and finished. Cleared a beat early it
        // would go back to "Delete 8.5 GB for good" — a live-looking offer, over a card whose
        // rows have just been struck through, for 0.9 seconds.
        cardRun = nil
        phase = .idle
        work = nil
    }

    /// The scan without the rows a run removed.
    ///
    /// Everything else is carried over untouched, `generatedAt` included: the measurement
    /// really was taken then, and the rows that are left were not affected by removing the
    /// ones that went. `availableBytes` is carried over too, deliberately — the run's own
    /// `availableBytesAfter` is a newer reading of free space, but it is `0` on any machine
    /// whose volume could not be read, and that would put "0 KB free" in the menu bar
    /// panel on the strength of one failed query.
    static func pruning(_ result: ScanResult, removing ids: Set<String>) -> ScanResult {
        guard !ids.isEmpty else { return result }
        return ScanResult(
            items: result.items.filter { !ids.contains($0.id) },
            generatedAt: result.generatedAt,
            availableBytes: result.availableBytes,
            skippedScannerIDs: result.skippedScannerIDs,
            ignoredProjectRoots: result.ignoredProjectRoots)
    }

    /// Asks the loop to measure again, once, when the deck has run out after at least one
    /// clean.
    ///
    /// After a clean, because that is the only way the scan on screen has become
    /// incomplete: the prune is exact for the folders it removed, but a clean can free a
    /// project past nothing at all while other projects have grown since the scan, and the
    /// end card is where the user stops and reads totals. A deck skipped right through has
    /// learned nothing new and is left alone.
    ///
    /// Through the loop rather than `startScan()`, for the reason on
    /// `BackgroundScanLoop.rescan`: the scheduler holds the countdown, and it is the
    /// request through that door which restarts it.
    private func requestRescanIfTheDeckIsFinished() {
        guard !didRequestDeckRescan,
              currentProjectCard == nil,
              projectDecisions.values.contains(where: {
                  if case .cleaned = $0 { return true }
                  return false
              })
        else { return }
        didRequestDeckRescan = true
        // Unstructured for the same reason `finishRun`'s rescan is: this can be reached
        // from the run's own task, which a Cancel may already have cancelled, and a child
        // would inherit that cancellation and skip the scan.
        Task { [scans] in await scans?.rescan() }
    }

    // MARK: - scanning

    /// Starts a scan unless one is already under way. Returns whether it started.
    @discardableResult
    public func startScan() -> Bool {
        guard !isBusy else { return false }
        phase = .scanning(nil)
        let engine = self.engine
        let cache = self.cache
        let startedAt = clock()

        // Built once, before the task, rather than per report. `self` is captured strongly:
        // the model belongs to the app and outlives every view, and the cycle it makes
        // with `work` ends when the task finishes and clears it.
        let report: @Sendable (ScanProgress) -> Void = { [self] progress in
            Task { @MainActor in self.applyScanReport(progress) }
        }

        work = Task { [self] in
            let scanned = await engine.scan(now: startedAt, progress: report)
            // A cancelled scan is not adopted and not cached. No scanner is cancellation
            // aware today, so `cancel()` cannot stop the ~51 seconds — but the result it
            // produces must not land, or the day a scanner does learn to stop early a
            // half-finished scan is written over the good cache and shown as a real one.
            guard !Task.isCancelled else { return abandonScan() }
            // Written before the state is applied, and off the main actor, so a slow
            // disk cannot stall a redraw.
            let cacheError = await Self.store(scanned, in: cache)
            finish(scanned, cacheError: cacheError)
        }
        return true
    }

    /// Returns once the scan or run under way has finished, or straight away when there is
    /// none.
    ///
    /// For `BackgroundScanLoop`, which has to know when its scan ended. Awaiting the task
    /// itself rather than polling `isBusy`: it is exact, it costs nothing while waiting, and
    /// it needs no second sleep in a loop whose whole job is deciding how long to sleep.
    ///
    /// The handle is **not** handed out. `work` is what `cancel()` acts on, and a caller
    /// holding it could stop a clean halfway through from outside the state machine.
    ///
    /// It does not return early when the caller is cancelled, because the thing it waits for
    /// does not stop early either: no scanner checks for cancellation, so a cancelled scan
    /// measures for its full ~51 seconds. Promising sooner would be a promise this app
    /// cannot keep.
    public func waitForWork() async {
        await work?.value
    }

    /// Leaves the previous scan on screen and goes back to idle, so a cancelled scan costs
    /// nothing but the wait. Not `.idle` by way of `finish`, which would adopt the result.
    private func abandonScan() {
        phase = .idle
        work = nil
    }

    /// Takes one scan report, from wherever the engine happened to be running.
    ///
    /// Internal rather than folded into the closure so the rule below can be tested at all.
    /// A report is delivered by hopping onto the main actor, and the last report of a scan
    /// routinely arrives **after** the scan itself has returned — the engine reports from a
    /// synchronous closure off the main actor, and which of the two main-actor jobs runs
    /// first is the runtime's business. Without the guard that late report puts the app
    /// back into `.scanning` and nothing ever takes it out again: `isBusy` stays true, and
    /// Scan again and Clean up both refuse for the rest of the session.
    func applyScanReport(_ progress: ScanProgress) {
        sawScanProgress = progress
        guard case .scanning = phase else { return }
        phase = .scanning(progress)
    }

    /// The same rule for a run, with the same consequence for the same reason.
    func applyRunReport(_ progress: ExecutionProgress) {
        guard case .running = phase else { return }
        phase = .running(progress)
    }

    /// The same, for a run the **deck** started: the shared phase and the card's own report
    /// move together.
    ///
    /// The second half is guarded on `cardRun` rather than on the phase, and that is what
    /// stops a late report from one card's finished run attaching itself to the next card's
    /// — `finishCardRun` clears `cardRun`, so there is nothing left for the report to land
    /// on.
    func applyCardRunReport(_ progress: ExecutionProgress) {
        applyRunReport(progress)
        guard let cardID = cardRun?.cardID else { return }
        cardRun = (cardID, progress)
    }

    /// Writes the cache and returns what went wrong, or `nil`.
    ///
    /// `nonisolated` and `@concurrent` on purpose. `Task { }` inside `startScan` inherits
    /// this class's `@MainActor` isolation, so a plain `try cache.save(...)` there would
    /// run the file write on the thread that draws the card — small on a healthy disk,
    /// not small on a busy or encrypted one, and pointless either way because nothing on
    /// screen is waiting for it.
    @concurrent
    private nonisolated static func store(
        _ scanned: ScanResult, in cache: ScanCache
    ) async -> String? {
        do {
            try cache.save(scanned)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func finish(_ scanned: ScanResult, cacheError: String?) {
        apply(scanned)
        lastCacheError = cacheError
        phase = .idle
        work = nil
    }

    /// Adopts a scan: the cards are rebuilt from it, and the session's order is brought up
    /// to date.
    ///
    /// The deck's decisions **survive** a scan landing, and that is deliberate. A skip is the
    /// user saying "not this project, not now", which a background scan arriving unasked does
    /// not change — so the decisions stay, and the order they were taken in is extended
    /// rather than replaced. See `rememberDeckOrder`.
    private func apply(_ scanned: ScanResult) {
        setResult(scanned)
        // Only when a session is already under way. Before the first decision there is
        // nothing to hold still, and snapshotting here would freeze the order of whatever
        // scan happened to be in the cache at launch.
        //
        // Both directions, and in this order: take in whatever the scan has newly found,
        // then forget the projects it no longer has. Either one alone leaves the strip
        // lying — see `rememberDeckOrder` and `forgetVanishedDeckSlots`.
        if !deckSession.isEmpty {
            rememberDeckOrder()
            forgetVanishedDeckSlots()
        }
    }

    /// The one place `result` changes.
    ///
    /// It exists so the deck memo cannot be left stale. `builtDeck` is only ever correct
    /// for the scan it was built from, and the failure mode of forgetting to clear it is
    /// the worst kind: the window would go on offering a card for folders a clean had
    /// already removed, and pressing Clean up would hand the engine their identifiers.
    ///
    /// **The checklist page's ticks are forgotten here too**, and for the same reason: a tick
    /// is a judgement about one measurement. The rows of the new scan are different rows —
    /// a file may have grown, shrunk, moved or gone, and the page is capped at
    /// `LargeFilesScanner.maximumRows` so a newcomer can push another row off it — and
    /// carrying a tick across would leave the set naming identifiers nothing on the page has,
    /// while a file the user has never looked at could arrive already ticked. The page is
    /// dealt with nothing ticked again, which is where the user asked it to start.
    ///
    /// A **prune** goes through here as well, which is right and costs nothing: a page whose
    /// clean has just been pruned already carries a `.cleaned` decision, so it is not dealt
    /// again, and the rows the user left unticked were never handed over and are still in the
    /// scan for the next session.
    private func setResult(_ scanned: ScanResult?) {
        result = scanned
        builtDeck = nil
        tickedChecklistIDs = []
    }

    // MARK: - cancelling

    /// Spec §8.2: stops before the next item; what is already removed stays removed.
    ///
    /// **A run stops; a scan does not.** No scanner checks for cancellation, so a cancelled
    /// scan keeps measuring for its full ~51 seconds and only its result is thrown away —
    /// the app goes back to idle still showing the scan it had. Whatever wires a Cancel
    /// button to this must not promise a scan stops sooner than that.
    ///
    /// **No control calls it today.** The menu bar's Cancel went with the checklist, and the
    /// deck never had one: a card's clean is a handful of folders and is over in moments,
    /// where the popover's Cancel existed for a run over the whole machine's ticked list. The
    /// method stays because cancellation is what makes `Executor`'s per-item check mean
    /// anything, and because a task left uncancellable is a task that has to be finished.
    ///
    /// Cancelling this handle is enough because the engine call is awaited **on** this task,
    /// so the engine's work is a child of it and inherits the cancellation. `Executor` then
    /// asks `isCancelled` before each item, which is the only thing that stops it: its loop
    /// calls a synchronous `perform` and has no suspension point of its own, so without that
    /// check a cancelled run would carry on and delete everything.
    ///
    /// What does **not** work is starting the run without keeping the handle. Cancellation
    /// travels through the handle, not through the enclosing scope: `work` is unstructured,
    /// so nothing else reaches it.
    public func cancel() { work?.cancel() }

    // MARK: - settings

    public func reloadSettings() {
        settings = engine.settings()
        // The deck is built against `moveToTrash` — every card's promise line — so a
        // changed setting makes the held one wrong in the one place it must not be.
        builtDeck = nil
    }

    /// Called by the settings window after a successful save, so the menu bar picks up a
    /// changed amount preference and the deck a changed Trash mode, without a rescan.
    ///
    /// The background interval is handed to the loop as well, because nothing else would
    /// ever read it again: `BackgroundScanLoop` is built once in `DevCleanerApp.init()` and
    /// held in `@State` by design, so its `ScanScheduler` was constructed from the value that
    /// was on disk at launch. Without this the user sets 1 hour, sees no error, and the app
    /// keeps scanning every 6 hours for the rest of the session — a setting accepted and
    /// silently discarded.
    ///
    /// The hand-over is on a task of its own because the scheduler is an actor and this is
    /// called from a button. The loop is asleep on the old answer when Save is pressed, so
    /// the new interval applies at its next wake at the latest either way.
    public func apply(_ updated: Settings) {
        settings = updated
        // Same reason as `reloadSettings`: the held deck's promise lines were written
        // against the old Trash setting, and a card promising the Trash over a run that
        // deletes outright is the one mistake this whole file is careful about.
        builtDeck = nil
        Task { [scans] in await scans?.useIntervalHours(updated.backgroundScanIntervalHours) }
    }
}
