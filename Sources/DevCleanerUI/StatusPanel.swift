import Foundation
import CoreGraphics
import CleanerCore

/// A status item, not a second way to clean.
///
/// The menu bar used to hold the whole tool: five collapsible groups, a hundred tick boxes,
/// a stacked bar, a review sheet and a run summary — the app in a 440-point strip. The
/// window is the app now, and it deals every one of those rows as a card, so the strip has
/// one job left: say whether it is worth opening.
///
/// So this is a glance. One amount, where that amount is — the four biggest cards, as bars,
/// and a line for the rest — the two facts that give it context, whatever went wrong while
/// measuring, and four buttons, none of which removes anything. The one that matters opens
/// the window.
public enum StatusPanelMetrics {
    /// Narrow enough to read as a status item rather than as the window moved into the
    /// corner of the screen.
    ///
    /// 300 points is what the widest row of controls needs — "Scan again", "Settings…" and
    /// "Quit" spread edge to edge inside a 16-point inset — and it is about as narrow as a
    /// bar with a card's name at one end and its size at the other can be. The old 440 was
    /// sized for a list of folder names with their paths and sizes, and there is no list any
    /// more.
    public static let width: CGFloat = 300
}

/// Every word the menu bar panel says.
public enum StatusPanelText {
    /// The panel's one real action. Names the product rather than "the window", because the
    /// user clicked an icon in the menu bar and the thing that opens has to be recognisable
    /// as what they clicked.
    public static let openWindow = "Open DevCleaner"

    /// "Quit", not "Quit DevCleaner".
    ///
    /// The three quiet controls are spread edge to edge along the foot of the panel now
    /// rather than stacked in a column, and the long form was the only one of the three that
    /// did not fit. Nothing is lost by shortening it: the product is named twice directly
    /// above — on the primary button, and by the icon the user clicked to get here — so
    /// there is no other application this button could be quitting.
    public static let quit = "Quit"

    /// The same words the window's own controls use, because they are the same two actions
    /// through the same two doors — `BackgroundScanLoop.rescan` and `openSettings`.
    ///
    /// Spelled as references rather than retyped, so the panel's vocabulary is in one place
    /// and the two surfaces cannot be reworded apart: a menu bar offering "Rescan" beside a
    /// window offering "Scan again" reads as two different operations.
    ///
    /// The ellipsis is the panel's own and the word underneath it is still `ChromeText`'s.
    /// It is the platform's mark for a control that opens somewhere to make the choice
    /// rather than making it on the spot, which is what this one does — and the button
    /// beside it, "Scan again", is the kind that does not.
    public static let scanAgain = ProjectDeckText.scanAgain
    public static let settings = ChromeText.settings + "…"

    /// "at least", never "up to".
    ///
    /// The old header's prefix was right about the old number: `reclaimableBytes` counted
    /// everything on offer, some of which shared blocks with files that were staying, so the
    /// honest reading was an upper bound. This number is the opposite. It leaves out the rows
    /// a card holds back and every one of the user's own files — see
    /// `ProjectDeck.defaultOfferBytes` — so the deck can only ever offer more than it, and
    /// "up to" printed above it would be a promise in the wrong direction.
    ///
    /// It leads `amountDetail` rather than standing in a label of its own, which is where the
    /// mock put it. The two halves are one reading — *at least this much, and your own big
    /// files are extra* — and set in opposite corners of a 300-point panel the user had to
    /// assemble it for themselves.
    public static let amountPrefix = "at least"

    /// The eyebrow over the amount. Says what the number is *for*, which the number and its
    /// prefix together do not.
    ///
    /// Title case, although it is drawn in capitals. Which is the same rule every card's
    /// eyebrow follows: the uppercase and its tracking are typography, applied by the view
    /// that draws it, and a string stored shouting is a string that cannot be read anywhere
    /// else.
    public static let readyToCleanUp = "Ready to clean up"

    /// The hover sentence, which is where the rest of the reason lives — the line under the
    /// number is one line wide.
    ///
    /// Names both exclusions, because they are the two things a user could otherwise catch
    /// the panel out on: the window offers a 7 GB download and a 5.6 GB NDK this number
    /// never mentioned.
    public static let amountHelp =
        "What a pass through DevCleaner would take with no extra decisions. "
        + "Your own large files, and anything a card holds back, are extra."

    /// "at least — in 24 cards. Your own big files are extra." — the one line under the
    /// number.
    ///
    /// Three jobs in one sentence, because the panel has room for one. The prefix says which
    /// direction the figure can only move in; the count says the number is a sum of
    /// decisions the user is going to be asked to make, which is what turns "109.6 GB" into
    /// "a session in that window"; and the last clause names the exclusion a user would
    /// otherwise catch the panel out on, since their own big files are the only part of the
    /// deck the number deliberately ignores.
    ///
    /// The count is the cards the amount is **made of** — see `StatusPanelModel.rows` — and
    /// not the length of the deck, which also holds the cards behind the interstitial and
    /// any card offering nothing by default. Through `ProjectDeckText.counted`, like every
    /// other plural in this app, so a tidy machine cannot read "in 1 cards".
    public static func amountDetail(cardCount: Int) -> String {
        "\(amountPrefix) — in " + ProjectDeckText.counted(cardCount, "card")
            + ". Your own big files are extra."
    }

    /// "free on this Mac" — the words after the free-space figure.
    ///
    /// Kept apart from the figure so the view can set the size in the primary colour and
    /// this in the secondary, which is what makes one line read as one number with a label
    /// rather than as a sentence. Splitting it here rather than in the view is the same rule
    /// `SizeHeadline` follows: where one weight ends and the next begins is a decision, and
    /// one taken inside a SwiftUI body is a decision no test can read.
    ///
    /// "on this Mac", because the figure beside it is the volume the app measured and the
    /// amount above it is not: a panel reading "266.6 GB free" over "at least 109.6 GB"
    /// invites the two to be added together.
    public static let freeNote = "free on this Mac"

    /// "scanned 2h ago" — the other end of that line.
    ///
    /// A function rather than a constant plus an age joined in the view, because the verb is
    /// the whole of what it claims: the age on its own is a duration, and "scanned" is what
    /// says the numbers on this panel are that old. Dropped entirely while the app is
    /// working — see `StatusPanelModel.scannedText`.
    public static func scanned(_ age: String) -> String { "scanned \(age)" }

    /// "and 20 more · 46.9 GB" — the cards with no bar of their own.
    ///
    /// The end card's own fold line, spelled as a reference rather than retyped. Both say
    /// the same thing about a list that has been cut short, and the thing that matters in
    /// both is the **total**: a reader who cannot see the fifth bar can still see that the
    /// fifth onwards come to 46.9 GB, which is what tells them whether the number above is
    /// mostly on screen or mostly not.
    public static func andMore(count: Int, bytes: Int64) -> String {
        ProjectDeckText.moreToGainRest(count: count, bytes: bytes)
    }
}

// MARK: - one card, as a bar

/// One of the biggest cards, drawn as a bar: what it is called, what it is worth, and how
/// much of the panel's widest bar it fills.
///
/// Everything here is already a string, a `Double` or a token. The bar in particular is a
/// `fraction` and never two sizes to divide — the same rule `ProjectCardFolder` follows, for
/// the same reason: a view that divides is a view deciding what the bars compare against,
/// and no test can reach it there.
public struct StatusPanelRow: Identifiable, Equatable, Sendable {
    /// `ProjectCard.id` — a project's directory or a scanner's identifier. The card this bar
    /// is about, so a test can hold the bar against the card rather than against a second
    /// rule that happens to agree.
    public let id: String
    /// The card's own name: "iOS simulators", "Derived data", "Sample Game - iOS".
    public let title: String
    /// **This card's share of `ProjectDeck.defaultOfferBytes`**, and not
    /// `ProjectCard.totalBytes`.
    ///
    /// The two differ on any card holding a row the deck does not tick — the Android NDK's
    /// card is 5.6 GB bigger than its offer — and the bars have to add up to the number they
    /// are drawn under. See `StatusPanelModel.rows`.
    public let sizeBytes: Int64
    public let sizeText: String
    /// `0...1` against the biggest bar on the panel, so the top one is always full.
    public let fraction: Double
    /// Blue or amber, and it is the **card's** answer rather than a second rule here:
    /// `ProjectCard.primaryActionTone` is amber exactly when the card has to be clicked. So
    /// sixteen simulators are amber in this strip, amber in the deck's skyline and amber on
    /// the button that destroys them.
    public let tone: ProjectCard.PrimaryActionTone
}

/// Everything the menu bar panel draws: one amount, where it is, where the machine stands,
/// and anything that went wrong while measuring.
///
/// There is always something true to say — a machine that has measured nothing says so — and
/// an optional panel would put that branch in the view.
public struct StatusPanelModel: Sendable, Equatable {
    /// `StatusPanelText.readyToCleanUp`, or `nil` when there is no amount to introduce.
    ///
    /// The first of five fields set and cleared together with the amount: the eyebrow, the
    /// figure, the figure split for the view's two type sizes, the sentence under it, and —
    /// the other way round — the sentence that stands in for all four. "Ready to clean up"
    /// over "Nothing to clean up." is the panel contradicting itself in two lines.
    public let eyebrow: String?
    /// "9.1 GB", or `nil` — before the first scan, and when a pass through the deck would
    /// take nothing.
    public let amountText: String?
    /// The same string split into its numeral and its unit, because the panel sets the two
    /// at different sizes.
    ///
    /// The split is `SizeHeadline`'s, as it is on a card: which characters are the unit is a
    /// decision, and `amountText.components(separatedBy: " ").first` written into a SwiftUI
    /// body is a decision no test can read. Two readings of one value rather than two values
    /// — both come from `ProjectDeck.defaultOfferText`, in one statement — so the number
    /// drawn large and the number the menu bar label prints cannot be two roundings of two
    /// totals.
    public let amountHeadline: SizeHeadline?
    /// "at least — in 24 cards. Your own big files are extra.", or `nil` with no amount.
    public let amountDetail: String?
    /// The sentence that stands **in place of** the number: "Nothing to clean up.",
    /// "Nothing has been measured yet.". `nil` whenever there is an amount.
    ///
    /// The window's own wording for both empty cases, because they are the same two facts it
    /// puts on its empty card and its end card. Two surfaces describing one machine in two
    /// sentences is how a user learns to distrust both.
    public let amountNote: String?
    /// The hover sentence, and **empty** when there is no amount to explain.
    ///
    /// An empty string rather than an optional, so the view's `.help(panel.amountHelp)`
    /// needs no branch of its own — the same rule the old header's `headlineHelp` followed,
    /// for the same reason: a branch in the view is a decision no test can read.
    public let amountHelp: String

    /// The biggest cards the amount is made of, as bars, biggest share first. Empty when
    /// there is no amount.
    ///
    /// **Why the panel has them at all.** The amount says how much and nothing about what,
    /// and those are different questions: 70.7 GB that is sixteen simulators is a session
    /// the user may not want, and 70.7 GB that is derived data and `node_modules` is one
    /// they can take with the keyboard in a minute. The window answers it a card at a time;
    /// the panel is where the user decides whether to go there at all.
    ///
    /// **Each bar carries its card's share of `ProjectDeck.defaultOfferBytes`**, never
    /// `ProjectCard.totalBytes`, and the two are not the same number: a card's total
    /// includes the rows the deck deliberately does not tick. Sized from the total, four
    /// bars could come to more than the figure printed above them — which is the one thing
    /// this panel cannot afford, because the bars are how the figure is read.
    ///
    /// Capped at `rowLimit`, with `moreText` carrying the rest, so rows plus the fold line
    /// come to exactly the headline.
    public let rows: [StatusPanelRow]
    /// "and 20 more · 46.9 GB", or `nil` when every card the amount is made of has a bar.
    public let moreText: String?

    /// "1.2 TB", or `nil` before the first scan, where it would be an invention — nothing
    /// has read the volume.
    ///
    /// The scan's reading of the volume, not a fresh one: the panel must not be the only
    /// place in the app that queries the disk, and a second reading here would disagree with
    /// the window's numbers by whatever has happened since.
    public let freeSizeText: String?
    /// "free on this Mac" — the words after that figure, set and cleared with it.
    public let freeNote: String?
    /// "scanned 2h ago", or `nil` before the first scan and **for as long as the app is
    /// working**.
    ///
    /// Dropped during a scan because the numbers beside it are being replaced, and during a
    /// run because they are being pruned: a clean takes its rows out of the scan on screen,
    /// so an age printed over that is dating a measurement the app is in the middle of
    /// revising. What the user wants on that line while either is going is what is happening
    /// now, and `progressText` is what says it.
    public let scannedText: String?
    /// The engine's own progress line while a scan or a run is going, otherwise `nil`.
    ///
    /// The amount above it stays. A scan takes about 51 seconds and blanking the number for
    /// that long — every launch, and every `backgroundScanIntervalHours` after it — would
    /// make the status item look broken; this line is what says the number is being checked.
    public let progressText: String?
    /// Things that went wrong or were switched off, in the user's words. Empty is the
    /// normal case.
    public let problems: [String]

    /// How many cards get a bar of their own.
    ///
    /// Four. The panel is 300 points wide and it is a glance: a real dev machine has two
    /// dozen cards over the floor, and a strip that drew all of them would be the window
    /// moved into the corner of the screen — which is the shape this app took the menu bar
    /// out of. Four is enough to answer the question. On the machine this panel was designed
    /// against they are 62.7 GB of a 109.6 GB amount — more than half of it, named — and
    /// `moreText` carries the other twenty cards in one line.
    public static let rowLimit = 4

    /// Takes the deck rather than the scan for the amount, and the scan as well for
    /// everything else.
    ///
    /// The split is deliberate. The amount and the bars must be the deck's own cards — see
    /// `ProjectDeck.defaultOfferBytes` — while free space, the age and the problems are
    /// facts about the measurement itself, which the deck does not carry. Both arrive
    /// already paired by `AppModel`, which sets them together.
    ///
    /// `phase` rather than a `Bool`, for the reason `ProjectDeckText.windowSubtitle` takes
    /// it: reducing four states to "is something running" **is** the decision, and in
    /// `DevCleanerApp` a view that answered it wrong would leave "scanned just now" over a
    /// scan in progress.
    public init(
        deck: ProjectDeck?, result: ScanResult?, phase: AppModel.Phase,
        cacheError: String?, now: Date, home: String
    ) {
        let bytes = deck?.defaultOfferBytes ?? 0
        // A number only when there is something to offer. Zero is printed by the **label**,
        // where "0 KB" is an honest and stable width, and replaced here by the window's own
        // sentence for the same fact: "Ready to clean up / at least 0 KB" invites the user to
        // open a window with nothing in it.
        let hasAmount = deck != nil && bytes > 0
        // Every card the amount is made of, biggest share first. Empty on a machine with no
        // amount, which is what leaves the bars and the fold line off the panel without a
        // second test of `hasAmount`.
        let shares = deck.map(Self.shares(in:)) ?? []
        let drawn = shares.prefix(Self.rowLimit)
        // Against the biggest share on the panel, which is the first of them, so the top bar
        // is full and the rest are read against it. Against the **headline** instead — which
        // is the other honest reading — four bars would each be a quarter or a third of the
        // width on a real machine and the strip would be mostly empty track; and the
        // comparison worth drawing here is between the cards, because "where is it?" is the
        // question the bars answer.
        let widest = drawn.first?.bytes ?? 0
        rows = drawn.map { share in
            StatusPanelRow(
                id: share.card.id, title: share.card.name, sizeBytes: share.bytes,
                sizeText: ByteText.short(share.bytes),
                // The card's own zero guard, so a panel and a card round and divide by the
                // same rule.
                fraction: ProjectCardFolder.fraction(share.bytes, of: widest),
                tone: share.card.primaryActionTone)
        }
        let rest = shares.dropFirst(Self.rowLimit)
        moreText = rest.isEmpty
            ? nil
            : StatusPanelText.andMore(
                count: rest.count, bytes: rest.reduce(into: Int64(0)) { $0 += $1.bytes })

        eyebrow = hasAmount ? StatusPanelText.readyToCleanUp : nil
        let amountText = hasAmount ? deck?.defaultOfferText : nil
        self.amountText = amountText
        // One value read twice, in one statement, so the two cannot come from two totals.
        amountHeadline = amountText.map(SizeHeadline.init)
        // The count is the cards with a share, which is `shares` — not `deck.cards.count`,
        // which includes the user's own files, the interstitial and any card the deck deals
        // with nothing ticked on it.
        amountDetail = hasAmount
            ? StatusPanelText.amountDetail(cardCount: shares.count)
            : nil
        amountHelp = hasAmount ? StatusPanelText.amountHelp : ""
        amountNote = hasAmount
            ? nil
            : (result == nil ? ProjectDeckText.noScanYet : ProjectDeckText.nothingHeadline)

        switch phase {
        case .idle:                     progressText = nil
        case .scanning(let progress):   progressText = ChromeText.scanning(progress)
        case .running(let progress):    progressText = ChromeText.running(progress)
        }

        freeSizeText = result.map { ByteText.short($0.availableBytes) }
        freeNote = result == nil ? nil : StatusPanelText.freeNote
        // Gone for the whole of a scan or a run, where it would claim the numbers beside it
        // are a measurement that still stands.
        scannedText = phase == .idle
            ? result.map { StatusPanelText.scanned(AgeText.since($0.generatedAt, now: now)) }
            : nil

        var problems = result.map { Self.problems(of: $0, reporter: ReportText(home: home)) }
            ?? []
        // Last, and reported even with no scan behind it — which is exactly the machine it
        // happens on, because the launch scan's own write is the first thing to fail. The two
        // above it are properties of a measurement that landed; this one is why one did not
        // reach the disk.
        if let cacheError { problems.append(cacheError) }
        self.problems = problems
    }

    /// What each card contributes to `ProjectDeck.defaultOfferBytes`, biggest first, with
    /// the cards that contribute nothing left out.
    ///
    /// **This is that total taken apart, and it has to add back up to it.** So it repeats
    /// the total's three rules exactly: only the cards in front of the interstitial, because
    /// the user's own files are not in the amount; only `selectedByDefault` rows, because a
    /// row a card holds back is not; and each `DeletionMethod` counted **once across the
    /// whole half**, in the order `ProjectDeck.defaultOfferBytes` flattens the cards, which
    /// is what `ScanResult.totalBytes` does to the same list. Two cards naming
    /// `~/Library/Caches/shared` are 20.1 GB between them, so the second card's share of it
    /// is nothing — and a panel that summed each card in isolation would draw two 20.1 GB
    /// bars under a 20.1 GB headline. `theBarsAndTheMoreLineAddUpToTheHeadline` is what holds
    /// the two in step.
    ///
    /// A card with no share is dropped rather than drawn at zero. A bar of no length under a
    /// card's name says "there is something here" about nothing, and counting it in
    /// `amountDetail` would promise that the figure came partly from a card it did not.
    ///
    /// Ordered by the **share** and not by `ProjectCard.totalBytes`, which is the deck's own
    /// order: the Android NDK's card is the biggest on some machines and offers a gigabyte,
    /// and drawn as the panel's longest bar it would be the loudest thing on screen over
    /// bytes the number above does not contain. Ties broken by identifier, so the panel is
    /// the same on every scan of the same machine — the rule every ordered list in this app
    /// follows.
    static func shares(in deck: ProjectDeck) -> [(card: ProjectCard, bytes: Int64)] {
        var seen: Set<DeletionMethod> = []
        var shares: [(card: ProjectCard, bytes: Int64)] = []
        for card in deck.cards where !card.isBigThing && !card.isInterstitial {
            var bytes: Int64 = 0
            for item in card.items where item.selectedByDefault {
                guard seen.insert(item.method).inserted else { continue }
                bytes += item.sizeBytes
            }
            if bytes > 0 { shares.append((card, bytes)) }
        }
        return shares.sorted {
            $0.bytes == $1.bytes ? $0.card.id < $1.card.id : $0.bytes > $1.bytes
        }
    }

    /// Things that went wrong or were switched off, in the user's words.
    ///
    /// **The panel is the only place these appear.** The window's deck answers "may this
    /// go?" about one card at a time and has nowhere to say that a whole area of the disk
    /// went unmeasured, so dropping them with the old header would have dropped them from
    /// the app.
    ///
    /// The refusal first, then the choice. `ScanContext.ignoredProjectRoots` is a root the
    /// engine **dropped** rather than walked — a hand-edited `settings.json` naming `~` — so
    /// an area of the disk went unmeasured and the amount above is missing whatever lives
    /// there. Saying so is the difference between "your setting was ignored" and "you have no
    /// projects". A skipped scanner is the user's own setting, working as asked, and is the
    /// less surprising of the two.
    ///
    /// A function of its own rather than a block inside the initialiser, so the two
    /// sentences and the order they come in stay one named rule.
    static func problems(of result: ScanResult, reporter: ReportText) -> [String] {
        var problems: [String] = []
        if !result.ignoredProjectRoots.isEmpty {
            problems.append("Ignored, too wide to be a project root: "
                + result.ignoredProjectRoots.map(reporter.abbreviate).joined(separator: ", "))
        }
        if !result.skippedScannerIDs.isEmpty {
            problems.append("Switched off in settings: "
                + result.skippedScannerIDs.joined(separator: ", "))
        }
        return problems
    }
}
