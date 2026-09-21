import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

// The menu bar is a status item now, not a second way to clean. Everything below is about
// the one amount it shows, the two surfaces agreeing on it, the bars that say where that
// amount is, and the problems that have nowhere else to go.

// MARK: - the one amount

/// The amount is the deck's own cards, counting only what a normal clean takes.
///
/// `ScanResult.reclaimableBytes` is the number the old header showed, and it is the wrong
/// one now: it totals rows the deck never deals. The 4 MB crumb below
/// `ProjectDeck.minimumCardBytes` gets no card — it is counted in the small-things line —
/// so a menu bar built from the scan promises space no amount of pressing Clean up can
/// reach.
@Test func theAmountIsWhatTheDecksCardsOffer() {
    let deck = ProjectDeck(
        result: makeResult([
            toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                    sizeBytes: 9_100_000_000),
            folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000),
            folderRow(project: "crumb", folder: "build", sizeBytes: 4_000_000),
        ]),
        home: testHome, now: now, moveToTrash: true)

    #expect(deck.defaultOfferBytes == 18_100_000_000)
    #expect(deck.defaultOfferText == "18.1 GB")
    // The crumb really was left out rather than rounded away.
    #expect(deck.smallThingsText == "1 small thing under 50 MB was not shown · 4 MB")
}

/// A row a card holds back is on the card and out of the amount.
///
/// The Android NDK is 5.6 GB, deletable, and `startsUnticked`: its card names it, sizes it
/// and carries `ProjectDeckText.untickedCaution`, so pressing Clean up there really does
/// remove it. The menu bar has one line and no room for the caution, so counting it would
/// advertise a large network re-download as space waiting to be had.
///
/// That makes the amount a **floor** and never a ceiling, which is why it is prefixed "at
/// least" rather than the old header's "up to".
@Test func aCautionedRowIsOfferedOnItsCardAndLeftOutOfTheAmount() throws {
    let deck = ProjectDeck(
        result: makeResult([
            toolRow(scanner: "android.ndk", group: .android, name: "NDK 26",
                    relativePath: "Library/Android/sdk/ndk/26", sizeBytes: 5_570_000_000,
                    startsUnticked: true),
            toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                    sizeBytes: 9_100_000_000),
        ]),
        home: testHome, now: now, moveToTrash: true)

    let ndk = try #require(deck.cards.first { $0.name == "Android NDK" })
    #expect(ndk.items.map(\.name) == ["NDK 26"])
    #expect(ndk.cautionLines.contains(ProjectDeckText.untickedCaution))

    #expect(deck.defaultOfferBytes == 9_100_000_000)
}

/// A cache the app has decided not to clean is never in the amount, and neither is a
/// `~/.cache` folder whose tool it cannot name.
///
/// The status item is the one surface with no room for anything but a number, and the number
/// it shows is what a pass through the deck would take if the user decided nothing. A
/// browser cache has no card to press at all; an unknown folder has a card that has to be
/// clicked, over a caution. Counting either would advertise space that only a decision the
/// panel cannot describe would release.
@Test func neitherAMentionedCacheNorAnUnknownToolIsInTheAmount() {
    let deck = ProjectDeck(
        result: makeResult([
            toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                    sizeBytes: 9_100_000_000),
            appCacheRow(name: "Brave browsing cache",
                        relativePath: "Library/Caches/BraveSoftware",
                        sizeBytes: 3_200_000_000),
            electronCacheRow(app: "Slack", folder: "Cache", sizeBytes: 1_300_000_000),
            xdgCacheRow(name: "nimbus", sizeBytes: 2_400_000_000),
            // Rule 4: a tool the app **can** name is still counted, so the exclusions above
            // are about what they say and not about `~/.cache` as a whole.
            xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000),
        ]),
        home: testHome, now: now, moveToTrash: true)

    #expect(deck.defaultOfferBytes == 10_200_000_000)
    #expect(deck.defaultOfferText == "10.2 GB")
    // The 4.5 GB nothing offers is still accounted for, on the end card's own section.
    #expect(deck.moreToGain?.lines == ["Brave browsing cache · 3.2 GB", "Slack · 1.3 GB"])
    // And the 2.4 GB with a card is on the card, out of the amount.
    #expect(deck.cards.contains { $0.name == "nimbus" })
}

/// The user's own large files are never in the amount.
///
/// They are the second half of the deck, behind an interstitial, and nothing brings one
/// back. A menu bar counting a 7 GB download as reclaimable would be the app recommending
/// the one deletion its own card warns hardest about — and it would be doing it in the one
/// place with no room for the warning.
@Test func theUsersOwnFilesAreNeverInTheAmount() {
    let deck = ProjectDeck(
        result: makeResult([
            toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                    sizeBytes: 9_100_000_000),
            downloadRow(name: "Xcode_16.xip", sizeBytes: 7_000_000_000),
        ]),
        home: testHome, now: now, moveToTrash: true)

    #expect(deck.cards.map(\.isBigThing).contains(true))
    #expect(deck.defaultOfferBytes == 9_100_000_000)
}

/// A protected row is in no card and in no amount. The tool will not touch it, so promising
/// its bytes in the menu bar is promising a clean the engine refuses.
@Test func aKeptRowIsNeverInTheAmount() {
    let deck = ProjectDeck(
        result: makeResult([
            toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                    sizeBytes: 9_100_000_000),
            toolRow(scanner: "android.systemImages", group: .android, name: "System image",
                    relativePath: "Library/Android/sdk/system-images/33",
                    sizeBytes: 12_000_000_000, protection: .sdkInUse(by: "an emulator")),
        ]),
        home: testHome, now: now, moveToTrash: true)

    #expect(deck.keptToolsText != nil)
    #expect(deck.defaultOfferBytes == 9_100_000_000)
}

/// Two cards' rows naming one directory are one lot of bytes on disk.
///
/// Totalled through `ScanResult.totalBytes` across the whole first half rather than card by
/// card, for the reason every other total in this app is: added up per card and summed, one
/// target would be counted twice and the menu bar would say 40.2 GB over a disk holding
/// 20.1 GB of it.
@Test func theAmountCountsOneTargetOnceWhenTwoCardsNameIt() {
    let oneDirectory = DeletionMethod.removePath("\(testHome)/Library/Caches/shared")
    let deck = ProjectDeck(
        result: makeResult([
            makeItem(
                id: "xcode.derivedData|shared", scannerID: "xcode.derivedData",
                group: .xcodeAndIOS, name: "first", sizeBytes: 20_100_000_000,
                method: oneDirectory),
            makeItem(
                id: "other.libraryCaches|shared", scannerID: "other.libraryCaches",
                group: .otherCaches, name: "second", sizeBytes: 20_100_000_000,
                method: oneDirectory),
        ]),
        home: testHome, now: now, moveToTrash: true)

    #expect(deck.cards.count == 2)
    #expect(deck.defaultOfferBytes == 20_100_000_000)
}

/// A machine whose only cards are the user's own files offers nothing by default, and says
/// so with a number rather than with silence.
@Test func aDeckOfNothingButBigThingsOffersNothing() {
    let deck = ProjectDeck(
        result: makeResult([downloadRow(name: "Xcode_16.xip", sizeBytes: 7_000_000_000)]),
        home: testHome, now: now, moveToTrash: true)

    #expect(deck.defaultOfferBytes == 0)
    #expect(deck.defaultOfferText == "0 KB")
}

// MARK: - the menu bar item

@MainActor
@Test func theMenuBarShowsWhatTheDeckOffers() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([
        folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000),
    ]))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: testHome, clock: { now })

    #expect(MenuBarLabel.text(deck: model.projectDeck, showsAmount: true) == "9.0 GB")
}

@Test func theMenuBarShowsNoTextWhenTheUserAsksForTheIconAlone() {
    let deck = ProjectDeck(
        result: makeResult([
            folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000),
        ]),
        home: testHome, now: now, moveToTrash: true)

    #expect(MenuBarLabel.text(deck: deck, showsAmount: false) == nil)
}

/// Before the first scan there is no honest number to show, and a "0 GB" in the menu bar
/// would say the machine is clean.
@Test func theMenuBarShowsNoTextBeforeTheFirstScan() {
    #expect(MenuBarLabel.text(deck: nil, showsAmount: true) == nil)
}

/// After a scan, "0 KB" is honest and is shown. `nil` there would put the icon back to its
/// before-the-first-scan look while a measured deck was sitting behind it.
@Test func theMenuBarSaysZeroRatherThanNothingOnceSomethingHasBeenMeasured() {
    let deck = ProjectDeck(
        result: makeResult([downloadRow(name: "Xcode_16.xip", sizeBytes: 7_000_000_000)]),
        home: testHome, now: now, moveToTrash: true)

    #expect(MenuBarLabel.text(deck: deck, showsAmount: true) == "0 KB")
}

/// The label and the panel under it are on screen together, so they are one number read
/// twice and never two numbers.
///
/// Both go through `ProjectDeck.defaultOfferText`. A second `ByteText.short` call on a
/// second total is how the old header and the old menu bar came to disagree by 19 GB.
@Test func theMenuBarAndThePanelAgreeOnTheAmount() {
    let deck = ProjectDeck(
        result: makeResult([
            toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                    sizeBytes: 9_100_000_000),
            toolRow(scanner: "android.ndk", group: .android, name: "NDK 26",
                    relativePath: "Library/Android/sdk/ndk/26", sizeBytes: 5_570_000_000,
                    startsUnticked: true),
            downloadRow(name: "Xcode_16.xip", sizeBytes: 7_000_000_000),
        ]),
        home: testHome, now: now, moveToTrash: true)
    let panel = StatusPanelModel(
        deck: deck, result: makeResult([]), phase: .idle, cacheError: nil,
        now: now, home: testHome)

    #expect(panel.amountText == "9.1 GB")
    #expect(MenuBarLabel.text(deck: deck, showsAmount: true) == panel.amountText)
    // The number the panel **draws** is that same string split for its two type sizes, so
    // the large numeral cannot be a second rounding of a second total.
    #expect(panel.amountHeadline == SizeHeadline("9.1 GB"))
}

// MARK: - the panel

/// What the panel says on an ordinary machine: the amount, where it is, and the two facts a
/// glance is for.
@Test func thePanelShowsTheAmountItsCardCountAndWhereTheMachineStands() {
    let result = makeResult([
        folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000),
    ], generatedAt: now.addingTimeInterval(-7_200), availableBytes: 1_200_000_000_000)
    let deck = ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true)
    let panel = StatusPanelModel(
        deck: deck, result: result, phase: .idle, cacheError: nil, now: now, home: testHome)

    #expect(panel.eyebrow == "Ready to clean up")
    #expect(panel.amountText == "9.0 GB")
    #expect(panel.amountHeadline == SizeHeadline("9.0 GB"))
    #expect(panel.amountDetail == "at least — in 1 card. Your own big files are extra.")
    // No stand-in sentence: there is a number, and the note is what replaces one.
    #expect(panel.amountNote == nil)
    #expect(panel.freeSizeText == "1200.0 GB")
    #expect(panel.freeNote == "free on this Mac")
    #expect(panel.scannedText == "scanned 2h ago")
    #expect(panel.progressText == nil)
    #expect(panel.problems.isEmpty)
}

/// "at least", never "up to". The amount leaves out the rows a card holds back and every
/// one of the user's own files, so the deck can only ever offer more than it — and the old
/// header's prefix, printed over this number, would be a promise in the wrong direction.
///
/// The prefix leads the sentence under the number rather than sitting in a label of its own,
/// which is where the mock put it: it is the first half of one reading — "at least this
/// much, and your own big files are extra" — and split across two corners of the panel the
/// user had to assemble it themselves.
@Test func theAmountIsPrefixedAsAFloorAndNotAsACeiling() {
    #expect(StatusPanelText.amountPrefix == "at least")
    #expect(!StatusPanelText.amountPrefix.contains("up to"))
    #expect(StatusPanelText.amountDetail(cardCount: 24)
        == "at least — in 24 cards. Your own big files are extra.")
    #expect(StatusPanelText.amountDetail(cardCount: 24)
        .hasPrefix(StatusPanelText.amountPrefix))
    // The hover sentence is what carries the rest of the reason, because the line above it
    // is one line wide.
    #expect(StatusPanelText.amountHelp
        == "What a pass through DevCleaner would take with no extra decisions. "
            + "Your own large files, and anything a card holds back, are extra.")
}

/// One card is "1 card". Every plural in the deck goes through one rule, and this sentence
/// is in it — a panel reading "in 1 cards" on a tidy machine is the app's only number line
/// getting its own grammar wrong.
@Test func theCardCountIsSingularOnAMachineWithOneCard() {
    #expect(StatusPanelText.amountDetail(cardCount: 1)
        == "at least — in 1 card. Your own big files are extra.")
}

/// Nothing to clean up is a sentence, not "0 KB" under an eyebrow that says the machine is
/// ready.
///
/// The same sentence the window's own end card shows, because it is the same fact — and a
/// "0 KB" there would invite the user to open a window with nothing in it. No eyebrow, no
/// bars and no "more" line either: every one of them is about an amount that is not there.
@Test func thePanelSaysNothingToCleanUpRatherThanZero() {
    let result = makeResult([downloadRow(name: "Xcode_16.xip", sizeBytes: 7_000_000_000)])
    let deck = ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true)
    let panel = StatusPanelModel(
        deck: deck, result: result, phase: .idle, cacheError: nil, now: now, home: testHome)

    #expect(panel.amountText == nil)
    #expect(panel.amountHeadline == nil)
    #expect(panel.eyebrow == nil)
    #expect(panel.amountDetail == nil)
    #expect(panel.amountNote == ProjectDeckText.nothingHeadline)
    #expect(panel.amountHelp.isEmpty)
    #expect(panel.rows.isEmpty)
    #expect(panel.moreText == nil)
    // Free space and the age still belong: the scan really happened.
    #expect(panel.freeSizeText == "219.0 GB")
    #expect(panel.scannedText == "scanned just now")
}

/// Before the first scan there is no amount, no bars, no free-space reading and no age —
/// and the panel says the one true thing instead of five empty ones.
@Test func thePanelBeforeTheFirstScanSaysNothingHasBeenMeasured() {
    let panel = StatusPanelModel(
        deck: nil, result: nil, phase: .idle, cacheError: nil, now: now, home: testHome)

    #expect(panel.amountText == nil)
    #expect(panel.amountNote == ProjectDeckText.noScanYet)
    #expect(panel.rows.isEmpty)
    #expect(panel.moreText == nil)
    #expect(panel.freeSizeText == nil)
    #expect(panel.freeNote == nil)
    #expect(panel.scannedText == nil)
    #expect(panel.progressText == nil)
}

/// While a scan runs the panel keeps the amount it had and adds the engine's own line.
///
/// Keeping the amount is deliberate: the scan takes about 51 seconds and blanking the
/// number for that long, every launch and every six hours, would make the status item look
/// broken. The progress line is what says the number is being checked.
@Test func thePanelShowsTheScansProgressUnderTheAmountItAlreadyHad() {
    let result = makeResult([
        folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000),
    ])
    let deck = ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true)
    let progress = ScanProgress(
        completed: 3, total: 16, currentID: "android.avds", currentTitle: "Android emulators")
    let panel = StatusPanelModel(
        deck: deck, result: result, phase: .scanning(progress), cacheError: nil,
        now: now, home: testHome)

    #expect(panel.amountText == "9.0 GB")
    // And the bars it already had, for the same reason: a panel whose rows emptied for
    // fifty seconds every launch would look broken rather than busy.
    #expect(panel.rows.map(\.title) == ["site"])
    #expect(panel.progressText == "[3/16] Android emulators")
    // The age goes while the scan runs: "scanned just now" beside a scan that has not
    // finished is the one reading the user must not take. Free space stays — it is the
    // volume's reading, and it is not what the scan is about to change its mind on.
    #expect(panel.scannedText == nil)
    #expect(panel.freeSizeText == "219.0 GB")
    #expect(panel.freeNote == "free on this Mac")
}

/// A clean is the window's, but the phase is shared, so the panel says what the app is
/// doing rather than leaving the user to guess why Scan again is dead.
///
/// The age goes for a run as well as for a scan. A clean prunes the rows it removed out of
/// the scan on screen, so while one is going the numbers beside that age are a measurement
/// the app is in the middle of revising.
@Test func thePanelShowsARunsProgressToo() {
    let result = makeResult([
        folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000),
    ])
    let deck = ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true)
    let panel = StatusPanelModel(
        deck: deck, result: result,
        phase: .running(ExecutionProgress(completed: 7, total: 48, currentName: "DerivedData")),
        cacheError: nil, now: now, home: testHome)

    #expect(panel.progressText == "[7/48] DerivedData")
    #expect(panel.scannedText == nil)
    #expect(panel.freeSizeText == "219.0 GB")
}

// MARK: - the bars: where the amount is

/// The biggest cards, as bars, biggest first — the panel's answer to "where is it?".
///
/// The amount on its own says how much and nothing about what: a user looking at 70.7 GB
/// cannot tell whether the window is going to ask them about sixteen simulators or about
/// their node_modules, which is the difference between opening it now and opening it later.
@Test func theBiggestCardsAreDrawnAsBarsBiggestFirst() {
    let panel = panelFor([
        simulatorRow(name: "iPhone 17 Pro", udid: "A1", sizeBytes: 21_400_000_000),
        runtimeRow(name: "iOS 26.0", identifier: "R1", sizeBytes: 17_300_000_000),
        deviceSupportRow(name: "18.0", sizeBytes: 14_000_000_000),
        toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                sizeBytes: 10_000_000_000),
    ])

    #expect(panel.rows.map(\.title) == [
        "iOS simulators", "Simulator runtimes", "Device support files", "Derived data",
    ])
    #expect(panel.rows.map(\.sizeText) == ["21.4 GB", "17.3 GB", "14.0 GB", "10.0 GB"])
    #expect(panel.amountText == "62.7 GB")
    #expect(panel.amountDetail == "at least — in 4 cards. Your own big files are extra.")
}

/// Each bar is drawn against the biggest of them, so the top one is full.
///
/// A `fraction` and never two sizes to divide, for the reason `ProjectCardFolder.fraction`
/// gives: a view that divides is a view deciding what the bars compare against, and no test
/// can reach it there.
@Test func theBarsAreScaledAgainstTheBiggestOfThem() {
    let panel = panelFor([
        toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                sizeBytes: 20_000_000_000),
        deviceSupportRow(name: "18.0", sizeBytes: 5_000_000_000),
    ])

    #expect(panel.rows.map(\.fraction) == [1, 0.25])
    // Nothing is ever divided by zero: a machine with nothing measured on it has no bars
    // at all, because a card offering no bytes is not one.
    #expect(panelFor([]).rows.isEmpty)
}

/// Four bars, and then one quiet line for the rest.
///
/// The panel is 300 points wide and it is a glance, not the window's list: a real dev
/// machine has two dozen cards, and a strip that drew all of them would be the window moved
/// into the corner of the screen — which is exactly what this app took the menu bar out of.
@Test func onlyFourBarsAreDrawnAndTheRestAreOneQuietLine() {
    let panel = panelFor([
        simulatorRow(name: "iPhone 17 Pro", udid: "A1", sizeBytes: 21_400_000_000),
        runtimeRow(name: "iOS 26.0", identifier: "R1", sizeBytes: 17_300_000_000),
        deviceSupportRow(name: "18.0", sizeBytes: 14_000_000_000),
        toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                sizeBytes: 10_000_000_000),
        folderRow(project: "site", folder: "node_modules", sizeBytes: 6_000_000_000),
        folderRow(project: "app", folder: "build", sizeBytes: 2_000_000_000),
    ])

    #expect(panel.rows.count == StatusPanelModel.rowLimit)
    #expect(panel.rows.count == 4)
    #expect(panel.moreText == "and 2 more · 8.0 GB")
    // The count above still counts every card, not the four with a bar: it is what the
    // number is made of, and the bars are only the part that fits.
    #expect(panel.amountDetail == "at least — in 6 cards. Your own big files are extra.")
}

/// **The bars and the "more" line add up to the number above them.**
///
/// The one arithmetic promise this panel makes. Each bar carries its card's share of
/// `ProjectDeck.defaultOfferBytes` — not the card's total, which includes the rows a card
/// holds back — and the fold line carries the remainder, so a user can read the four bars,
/// add the tail and land on the headline. A bar sized from the card's total would leave a
/// panel whose own rows come to more than the number they are under.
@Test func theBarsAndTheMoreLineAddUpToTheHeadline() {
    let rows = [
        simulatorRow(name: "iPhone 17 Pro", udid: "A1", sizeBytes: 21_400_000_000),
        runtimeRow(name: "iOS 26.0", identifier: "R1", sizeBytes: 17_300_000_000),
        deviceSupportRow(name: "18.0", sizeBytes: 14_000_000_000),
        toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                sizeBytes: 10_000_000_000),
        folderRow(project: "site", folder: "node_modules", sizeBytes: 6_000_000_000),
        folderRow(project: "app", folder: "build", sizeBytes: 2_000_000_000),
    ]
    let result = makeResult(rows)
    let deck = ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true)
    let panel = StatusPanelModel(
        deck: deck, result: result, phase: .idle, cacheError: nil, now: now, home: testHome)

    let drawn = panel.rows.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
    #expect(drawn == 62_700_000_000)
    #expect(deck.defaultOfferBytes == 70_700_000_000)
    #expect(panel.moreText
        == ProjectDeckText.moreToGainRest(count: 2, bytes: deck.defaultOfferBytes - drawn))
}

/// One directory named by two cards is one bar, so the bars still add up.
///
/// `ProjectDeck.defaultOfferBytes` de-duplicates on `DeletionMethod` across the whole half
/// at once — two cards naming `~/Library/Caches/shared` contribute 20.1 GB between them, not
/// 40.2 GB. A panel that sized each bar from its own card in isolation would draw two 20.1 GB
/// bars under a 20.1 GB headline and a "more" line of minus twenty gigabytes.
@Test func oneDirectoryUnderTwoCardsIsCountedInOneBarOnly() {
    let oneDirectory = DeletionMethod.removePath("\(testHome)/Library/Caches/shared")
    let panel = panelFor([
        makeItem(
            id: "xcode.derivedData|shared", scannerID: "xcode.derivedData",
            group: .xcodeAndIOS, name: "first", sizeBytes: 20_100_000_000,
            method: oneDirectory),
        makeItem(
            id: "other.libraryCaches|shared", scannerID: "other.libraryCaches",
            group: .otherCaches, name: "second", sizeBytes: 20_100_000_000,
            method: oneDirectory),
    ])

    #expect(panel.amountText == "20.1 GB")
    // One bar, and the second card is not a second one: everything it would contribute is
    // already in the bar above, so its own share of the amount is nothing.
    #expect(panel.rows.map(\.sizeText) == ["20.1 GB"])
    #expect(panel.rows.reduce(into: Int64(0)) { $0 += $1.sizeBytes } == 20_100_000_000)
    #expect(panel.moreText == nil)
    #expect(panel.amountDetail == "at least — in 1 card. Your own big files are extra.")
}

/// **A bar is amber exactly when its card has to be clicked.**
///
/// The colour is the card's own `ProjectCard.primaryActionTone`, read rather than re-decided
/// here, so the panel and the card it is about cannot disagree: sixteen simulators are a
/// permanent deletion and they are amber in the strip, in the deck's skyline and on the
/// button that does it.
@Test func aBarIsAmberExactlyWhenItsCardHasToBeClicked() throws {
    let rows = [
        simulatorRow(name: "iPhone 17 Pro", udid: "A1", sizeBytes: 21_400_000_000),
        toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                sizeBytes: 10_000_000_000),
    ]
    let result = makeResult(rows)
    let deck = ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true)
    let panel = StatusPanelModel(
        deck: deck, result: result, phase: .idle, cacheError: nil, now: now, home: testHome)

    #expect(panel.rows.map(\.tone) == [.deliberate, .regenerable])
    // The same answer the card gives, not a second rule that happens to agree today.
    for row in panel.rows {
        let card = try #require(deck.cards.first { $0.id == row.id })
        #expect(row.tone == card.primaryActionTone)
    }
}

/// The bars follow the **offer**, not the card's total.
///
/// The Android NDK card holds 5.57 GB the deck deliberately does not tick, so its card is
/// bigger than its offer. Ordered by the total it would come first and be drawn as the
/// largest bar in the panel, over bytes the number above does not contain.
@Test func theBarsFollowTheOfferAndNotTheCardsTotal() {
    let panel = panelFor([
        toolRow(scanner: "android.ndk", group: .android, name: "NDK 26",
                relativePath: "Library/Android/sdk/ndk/26", sizeBytes: 12_000_000_000,
                startsUnticked: true),
        toolRow(scanner: "android.ndk", group: .android, name: "NDK 25",
                relativePath: "Library/Android/sdk/ndk/25", sizeBytes: 1_000_000_000),
        toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                sizeBytes: 9_100_000_000),
    ])

    #expect(panel.rows.map(\.title) == ["Derived data", "Android NDK"])
    #expect(panel.rows.map(\.sizeText) == ["9.1 GB", "1.0 GB"])
    #expect(panel.amountText == "10.1 GB")
}

/// A card the deck deals that offers nothing by default is no bar and is in no count.
///
/// A zero-length bar under a title is a row that says "there is something here" about
/// nothing, and counting it would make the sentence over the bars promise a card the
/// number does not come from. The card is still in the deck, where its caution can be read.
@Test func aCardThatOffersNothingIsNeitherABarNorInTheCount() {
    let panel = panelFor([
        toolRow(scanner: "android.ndk", group: .android, name: "NDK 26",
                relativePath: "Library/Android/sdk/ndk/26", sizeBytes: 5_570_000_000,
                startsUnticked: true),
        toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                sizeBytes: 9_100_000_000),
    ])

    #expect(panel.rows.map(\.title) == ["Derived data"])
    #expect(panel.moreText == nil)
    #expect(panel.amountDetail == "at least — in 1 card. Your own big files are extra.")
}

/// **No bar is ever one of the user's own files, the interstitial, or a cache nothing
/// cleans.**
///
/// The three exclusions `ProjectDeck.defaultOfferBytes` makes, held at the other end: the
/// bars are what the number is made of, so anything the number leaves out must not appear
/// beside it. A 7 GB download drawn as a bar under "ready to clean up" would be the panel
/// recommending the one deletion the deck warns hardest about, in the one place with no room
/// for the warning; a browser cache drawn there has no button anywhere in the app.
@Test func noBarIsEverABigThingTheInterstitialOrACacheNothingCleans() {
    let panel = panelFor([
        toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                sizeBytes: 9_100_000_000),
        downloadRow(name: "Xcode_16.xip", sizeBytes: 7_000_000_000),
        appCacheRow(name: "Brave browsing cache",
                    relativePath: "Library/Caches/BraveSoftware",
                    sizeBytes: 3_200_000_000),
        electronCacheRow(app: "Slack", folder: "Cache", sizeBytes: 1_300_000_000),
    ])

    #expect(panel.rows.map(\.title) == ["Derived data"])
    #expect(panel.moreText == nil)
    #expect(panel.amountText == "9.1 GB")
    #expect(!panel.rows.contains { $0.id == ProjectDeck.interstitialCardID })
}

/// No fold line when every card already has a bar. "and 0 more · 0 KB" under four bars that
/// are the whole of it is a line about nothing.
@Test func thereIsNoMoreLineWhenEveryCardIsAlreadyABar() {
    let panel = panelFor([
        toolRow(name: "Derived data", relativePath: "Library/Developer/Xcode/DerivedData",
                sizeBytes: 9_100_000_000),
        deviceSupportRow(name: "18.0", sizeBytes: 5_000_000_000),
    ])

    #expect(panel.rows.count == 2)
    #expect(panel.moreText == nil)
}

// MARK: - the problems the panel is now the only home for

/// An ignored project root is an area of the disk that went **unmeasured**, so every number
/// on both surfaces is missing whatever lives there. The deck's window has no line for it,
/// which is why it is here.
@Test func anIgnoredProjectRootIsReportedAsAProblem() {
    let result = makeResult([], ignoredRoots: ["/Users/test"])
    let panel = StatusPanelModel(
        deck: ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true),
        result: result, phase: .idle, cacheError: nil, now: now, home: testHome)

    #expect(panel.problems == ["Ignored, too wide to be a project root: ~"])
}

@Test func aScannerSwitchedOffInSettingsIsReportedAsAProblem() {
    let result = makeResult([], skipped: ["ios.simulators", "android.avds"])
    let panel = StatusPanelModel(
        deck: ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true),
        result: result, phase: .idle, cacheError: nil, now: now, home: testHome)

    #expect(panel.problems == ["Switched off in settings: ios.simulators, android.avds"])
}

/// The refusal first, then the choice, then whatever went wrong with the cache.
///
/// A skipped scanner is the user's own setting working as asked; an ignored root is the
/// engine refusing one, and it is the one that makes the amount above it incomplete.
@Test func everyProblemIsListedWithTheRefusalFirst() {
    let result = makeResult([], skipped: ["ios.simulators"], ignoredRoots: ["/Users/test"])
    let panel = StatusPanelModel(
        deck: ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true),
        result: result, phase: .idle, cacheError: "the disk is full",
        now: now, home: testHome)

    #expect(panel.problems == [
        "Ignored, too wide to be a project root: ~",
        "Switched off in settings: ios.simulators",
        "the disk is full",
    ])
}

/// A cache that could not be written is reported even before a scan has ever landed —
/// which is exactly the machine it happens on, because the launch scan's own write is the
/// first thing to fail.
@Test func aCacheErrorIsReportedWithNoScanBehindIt() {
    let panel = StatusPanelModel(
        deck: nil, result: nil, phase: .idle, cacheError: "read-only file system",
        now: now, home: testHome)

    #expect(panel.problems == ["read-only file system"])
}

// MARK: - the panel the app really draws

/// Built by the model, from the model's own clock, for the reason the old header was: a
/// second clock in `DevCleanerApp` renders an age no test can pin and could disagree with
/// the window's subtitle on the same screen.
@MainActor
@Test func theModelBuildsThePanelFromItsOwnClockAndScan() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    try cache.save(makeResult([
        folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000),
    ], generatedAt: now.addingTimeInterval(-3_600)))
    let model = AppModel(
        engine: FakeEngine(), cache: cache, home: testHome, clock: { now })

    #expect(model.statusPanel.amountText == "9.0 GB")
    #expect(model.statusPanel.freeSizeText == "219.0 GB")
    #expect(model.statusPanel.scannedText == "scanned 1h ago")
    // The bars come off the same deck the window deals, which is the memo `projectDeck`
    // holds rather than a second build of its own.
    #expect(model.statusPanel.rows.map(\.title) == ["site"])
}

/// The panel is never `nil`. There is always something true to say — even on a machine that
/// has measured nothing — and an optional here would put that branch in the view.
@MainActor
@Test func thereIsAlwaysAPanelEvenBeforeAnythingHasBeenMeasured() {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: testHome, clock: { now })

    #expect(model.statusPanel.amountNote == ProjectDeckText.noScanYet)
}

// MARK: - the buttons

/// Every word on the four controls, pinned by value. A reworded button is a product change.
///
/// The footer's three are short now, because they are spread edge to edge across 268 points
/// of panel rather than stacked in a column: "Quit", not "Quit DevCleaner", which the
/// primary button above it already names. "Settings…" keeps the platform's ellipsis, because
/// pressing it opens a window rather than doing the thing.
@Test func thePanelsButtonsSayWhatTheyDo() {
    #expect(StatusPanelText.openWindow == "Open DevCleaner")
    #expect(StatusPanelText.quit == "Quit")
    #expect(StatusPanelText.scanAgain == "Scan again")
    #expect(StatusPanelText.settings == "Settings…")
    // The same words the window's own controls use, because they are the same two actions
    // through the same two doors — `BackgroundScanLoop.rescan` and `openSettings`. Spelled
    // as a reference rather than retyped, so the two cannot be reworded apart.
    #expect(StatusPanelText.scanAgain == ProjectDeckText.scanAgain)
    #expect(StatusPanelText.settings.hasPrefix(ChromeText.settings))
}

/// The button and the scene it opens name one identifier.
///
/// `openWindow(id:)` silently does nothing when the identifier does not match a `Window`
/// scene, so two spellings of "deck" would leave the panel's primary button dead with
/// nothing on screen saying why.
@Test func thePanelOpensTheWindowSceneByTheIdentifierThatSceneIsDeclaredWith() {
    #expect(MainWindowMetrics.sceneID == "deck")
}

/// Narrow enough to read as a status item rather than as the window moved to the corner.
@Test func thePanelIsCompact() {
    #expect(StatusPanelMetrics.width == 300)
    #expect(StatusPanelMetrics.width < MainWindowMetrics.minWidth)
}

// MARK: - a panel over a machine, in one line

/// The panel a scan of these rows produces, idle, over the default free space.
///
/// A helper rather than six lines repeated in every test above, because every one of those
/// tests is about the **bars** and none of them is about the phase, the cache or the clock.
/// It lives here rather than in `Doubles.swift` for the reason that file's own fixtures are
/// shared: this one is read by nothing else, and a fixture with one reader belongs beside it.
private func panelFor(_ items: [CleanupItem]) -> StatusPanelModel {
    let result = makeResult(items)
    return StatusPanelModel(
        deck: ProjectDeck(result: result, home: testHome, now: now, moveToTrash: true),
        result: result, phase: .idle, cacheError: nil, now: now, home: testHome)
}
