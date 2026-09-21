import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

// The deck's state machine: one card on screen, Clean up or Skip, and a session that has
// to keep counting straight while the scan underneath it is pruned card by card.
//
// This is the app's **only** clean path now — the menu bar is a status item — so everything
// about removing anything is here. `AppModelTests.swift` keeps the rest of the model: opening
// on a cache, scanning, and the settings it holds.

/// Three projects' worth of rows, biggest project last in the list so no test can pass by
/// accident on the order they were written in.
private func threeProjects() -> [CleanupItem] {
    [
        folderRow(project: "game", folder: ".build", sizeBytes: 946_000_000),
        folderRow(project: "game", folder: "ios/Pods", sizeBytes: 400_000_000,
                  risk: .elevated),
        folderRow(project: "tool", folder: ".build", sizeBytes: 2_000_000_000),
        folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000,
                  risk: .elevated),
    ]
}

/// A model opened on a cache holding exactly `rows` — the app's real startup path, and the
/// premise of almost every test below.
///
/// The rows are **used**, not decoration: the helper writes them to the cache and the model
/// reads them back in its initialiser, so `makeDeckModel(threeProjects(), …)` is the whole
/// of "a session that opens on those three projects". It used to ignore the argument while
/// each test saved the same fixture again a line above, which read as if the parameter were
/// doing the work.
///
/// `clock` is injected for the tests that have to move time — the settle window after a card
/// is answered is measured against it.
@MainActor
private func makeDeckModel(
    _ rows: [CleanupItem], cache: ScanCache, engine: FakeEngine,
    clock: @escaping @Sendable () -> Date = { now }
) throws -> AppModel {
    try cache.save(makeResult(rows))
    return AppModel(engine: engine, cache: cache, home: testHome, clock: clock)
}

/// Moves a test's clock past the window `cleanCurrentProject` refuses inside.
///
/// Every test that answers more than one card needs this, and needing it **is** the rule
/// working: the deck turns Clean up down for `AppModel.cardSettleSeconds` after it moves, so
/// that a held Return key cannot walk through project after project. A pinned clock never
/// leaves that window, so a test stepping from card to card has to do what a hand does
/// between two deliberate presses.
private func handPauses(_ clock: MovableClock) {
    clock.advance(by: AppModel.cardSettleSeconds)
}

// MARK: - the deck itself

@MainActor
@Test func theDeckDealsTheBiggestProjectFirstAndSaysWhereTheUserIs() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
        let model = try makeDeckModel(threeProjects(), cache: cache, engine: FakeEngine())

    let deck = try #require(model.projectDeck)
    #expect(deck.cards.map(\.name) == ["site", "tool", "game"])
    #expect(model.currentProjectCard?.name == "site")
    let position = try #require(model.projectPosition)
    #expect(position == (1, 3))
    #expect(model.deckSummary?.positionText == "1 of 3")
}

@MainActor
@Test func thereIsNoDeckAndNoCardBeforeTheFirstScan() {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: testHome, clock: { now })

    #expect(model.projectDeck == nil)
    #expect(model.currentProjectCard == nil)
    #expect(model.projectPosition == nil)
    #expect(model.deckSummary == nil)
    #expect(!model.cleanCurrentProject())
}

/// The mode-dependent copy is resolved by the model out of the settings it already holds,
/// so no view reads `Settings` to choose between "In the Trash so far" and "Deleted so
/// far" — and cannot get it the wrong way round over a run that put 12 GB in the Trash.
@MainActor
@Test func theSummaryTakesItsTrashOrDeleteWordingFromTheSettingsTheModelHolds() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var permanent = Settings.makeDefault(home: testHome)
    permanent.moveToTrash = false
    let model = try makeDeckModel(
        threeProjects(), cache: cache, engine: FakeEngine(settings: permanent))

    #expect(try #require(model.deckSummary).sessionLabel == "Cleaned so far")
    // The promise is the card's, because a deck can hold three cards needing three
    // different sentences — but which mode it is written in still comes from the settings
    // the model holds, and nothing downstream reads `Settings` to find out.
    #expect(try #require(model.currentProjectCard).promiseText
        == "Your code stays. Only these folders are deleted — for good.")
}

// MARK: - skipping

@MainActor
@Test func skippingACardMovesToTheNextOneAndLeavesTheScanAlone() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
        let model = try makeDeckModel(threeProjects(), cache: cache, engine: FakeEngine())

    model.skipCurrentProject()

    #expect(model.currentProjectCard?.name == "tool")
    #expect(model.projectDecisions["\(testHome)/dev/site"] == .skipped)
    // Nothing was removed and nothing was measured again: a skip is an answer, not an act.
    #expect(model.result?.items.count == 4)
    #expect(cache.load()?.items.count == 4)
    #expect(model.deckSessionBytes == 0)
    let position = try #require(model.projectPosition)
    #expect(position == (2, 3))
}

/// A skipped card keeps its place and its height. The skyline is the only thing on screen
/// that says how much of the deck is left, and a bar that vanished when it was answered
/// would make the strip shorten under the user's hand.
@MainActor
@Test func aSkippedCardKeepsItsBarAndTheCountStaysTheSame() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
        let model = try makeDeckModel(threeProjects(), cache: cache, engine: FakeEngine())

    model.skipCurrentProject()
    model.skipCurrentProject()

    let summary = try #require(model.deckSummary)
    #expect(summary.skyline.map(\.state) == [.skipped, .skipped, .current])
    #expect(summary.positionText == "3 of 3")
    #expect(summary.skippedText == "2 skipped · 11.0 GB")
}

@MainActor
@Test func skippingWithNoCardOnScreenDoesNothing() {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: testHome, clock: { now })

    model.skipCurrentProject()

    #expect(model.projectDecisions.isEmpty)
}

// MARK: - cleaning one card

/// The heart of it. A card's clean removes that project's folders, drops those rows from
/// the scan on screen **and** from the cache, and deals the next card — without a summary
/// panel and without measuring anything again.
@MainActor
@Test func cleaningACardPrunesTheRowsThatWentAndSavesThePrunedScan() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine)
    #expect(model.currentProjectCard?.name == "site")

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    // The cleaned project's row is gone from the scan the app is showing…
    #expect(model.result?.items.map(\.name) == [".build", "ios/Pods", ".build"])
    #expect(model.result?.items.allSatisfy { $0.detail != "site" } == true)
    // …and from the stored scan, so the next launch does not offer it again.
    let stored = try #require(cache.load())
    #expect(stored.items.count == 3)
    #expect(stored.items.allSatisfy { $0.detail != "site" })
    #expect(model.lastCacheError == nil)
    // The rest of the scan is carried over rather than rebuilt.
    #expect(stored.generatedAt == now)
    #expect(stored.availableBytes == 219_000_000_000)
    // And the menu bar's amount follows the prune, because it is the deck's own offer.
    #expect(model.statusPanel.amountText == "3.3 GB")
    // And the deck has moved on.
    #expect(model.currentProjectCard?.name == "tool")
    #expect(model.deckSessionBytes == 9_000_000_000)
    #expect(model.deckSummary?.sessionBytesText == "9.0 GB")
}

/// A card of a project the user is working in cleans exactly like any other, and that is
/// the point of the whole chain.
///
/// These rows are `startsUnticked` and outside `ScanResult.defaultSelection`, so nothing in
/// the app ticks them — which is precisely why the deck must hand the engine the list by
/// identifier. `cleanCurrentProject` calls `clean(items:)` and never `cleanDefault`, and
/// this asserts both: the exact identifiers go over, and `cleanDefault` is not called at
/// all. Routed through the defaults instead, the button under a 3.3 GB card would run a
/// clean that removed nothing and then report success.
@MainActor
@Test func cleaningAnActiveProjectsCardHandsOverItsUntickedFoldersAndPrunesThem() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = [
        folderRow(project: "Sample Game", folder: ".build", sizeBytes: 946_000_000,
                  untickedReason: .recentActivity(days: 14)),
        folderRow(project: "Sample Game", folder: ".build-cows", sizeBytes: 2_400_000_000,
                  untickedReason: .recentActivity(days: 14)),
        folderRow(project: "stale", folder: "build", sizeBytes: 100_000_000),
    ]
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let model = try makeDeckModel(rows, cache: cache, engine: engine)

    let card = try #require(model.currentProjectCard)
    #expect(card.name == "Sample Game")
    #expect(card.cautionLines
        == ["You changed this in the last 14 days. Its next build starts from scratch."])
    // Nothing has ticked these, and the menu bar's amount agrees: they are offered on this
    // card, not promised in the glance — `ProjectDeck.defaultOfferBytes` says why.
    #expect(model.statusPanel.amountText == "100 MB")

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    let handed = await engine.log.cleans
    #expect(handed == [[
        "projects.buildOutput|\(testHome)/dev/Sample Game/.build-cows",
        "projects.buildOutput|\(testHome)/dev/Sample Game/.build",
    ]])
    let defaults = await engine.log.cleanDefaults
    #expect(defaults == 0)

    // Pruned out of the scan and out of the cache, exactly as a ticked card's rows are.
    #expect(model.result?.items.map(\.name) == ["build"])
    #expect(cache.load()?.items.count == 1)
    #expect(model.deckSessionBytes == 3_346_000_000)
    #expect(model.currentProjectCard?.name == "stale")
}

/// A card's clean hands the engine exactly the card's items, in the card's own order, and
/// never goes through `cleanDefault` — which would derive the whole machine's default
/// selection and clean all of it.
@MainActor
@Test func cleaningACardCleansThatCardsFoldersAndNothingElse() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = threeProjects()
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(rows, cache: cache, engine: engine, clock: clock.read)

    // Skip past the one-folder projects to the card with two folders in it.
    model.skipCurrentProject()
    model.skipCurrentProject()
    handPauses(clock)
    let card = try #require(model.currentProjectCard)
    #expect(card.name == "game")

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    let handed = await engine.log.cleans
    #expect(handed == [card.items.map(\.id)])
    #expect(handed == [[
        "projects.buildOutput|\(testHome)/dev/game/.build",
        "projects.buildOutput|\(testHome)/dev/game/ios/Pods",
    ]])
    let defaults = await engine.log.cleanDefaults
    #expect(defaults == 0)
}

/// The run is given the injected clock, exactly as a scan is.
/// `RunRecord.startedAt` is this value and it is what the stored run log is named after.
@MainActor
@Test func aCardsCleanIsGivenTheInjectedClock() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let engine = FakeEngine()
    let stamp = now.addingTimeInterval(90)
    let model = try makeDeckModel(
        threeProjects(), cache: cache, engine: engine, clock: { stamp })

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    let times = await engine.log.times
    #expect(times == [stamp])
}

/// Only what really went. A refused folder is still on the disk, so pruning it would take
/// a real folder out of both surfaces' totals and off its own card: the space would look
/// recovered and the folder would never be offered again.
@MainActor
@Test func aFolderTheRunCouldNotRemoveStaysInTheScan() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = threeProjects()
    let pods = try #require(rows.first { $0.name == "ios/Pods" })
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    engine.refusedItemIDs = [pods.id]
    let clock = MovableClock()
    let model = try makeDeckModel(rows, cache: cache, engine: engine, clock: clock.read)
    model.skipCurrentProject()
    model.skipCurrentProject()
    handPauses(clock)
    #expect(model.currentProjectCard?.name == "game")

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    #expect(model.result?.items.map(\.id).contains(pods.id) == true)
    #expect(cache.load()?.items.map(\.id).contains(pods.id) == true)
    // Only the folder that went is counted.
    #expect(model.deckSessionBytes == 946_000_000)
}

// MARK: - cleaning a tool card

/// A deck the way a real session sees one: the biggest thing on the disk is a set of
/// simulators that cannot be undone, then a cache, then a project.
///
/// Three kinds of card in one deck is the premise of everything below. The state machine was
/// written when every card was a project, and what has to keep holding is that none of it
/// cared: the prune, the settle window, `cardRun` and the slots all key on the card's
/// identifier, which is a scanner's now as well as a path.
private func mixedRows() -> [CleanupItem] {
    [
        folderRow(project: "game", folder: ".build", sizeBytes: 946_000_000),
        toolRow(name: "ModuleCache",
                relativePath: "Library/Developer/Xcode/DerivedData/ModuleCache",
                sizeBytes: 9_100_000_000, detail: "its project folder is gone"),
        simulatorRow(name: "iPhone 17 Pro", udid: "AAA", sizeBytes: 21_400_000_000),
    ]
}

/// A tool card cleans exactly the way a project's card does: its own rows by identifier,
/// pruned out of the scan and out of the cache, and the next card dealt — no summary panel
/// and nothing measured again.
@MainActor
@Test func cleaningAToolCardPrunesItsRowsAndDealsTheNextCard() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(mixedRows(), cache: cache, engine: engine, clock: clock.read)

    // The simulators are dealt first, being the biggest; the cache is next.
    #expect(model.sessionCards.map(\.name) == ["iOS simulators", "Derived data", "game"])
    model.skipCurrentProject()
    handPauses(clock)
    let card = try #require(model.currentProjectCard)
    #expect(card.id == "xcode.derivedData")

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    let handed = await engine.log.cleans
    #expect(handed == [["xcode.derivedData|\(testHome)"
        + "/Library/Developer/Xcode/DerivedData/ModuleCache"]])
    let defaults = await engine.log.cleanDefaults
    #expect(defaults == 0)
    // Pruned out of the scan on screen and out of the stored one, so the next launch does
    // not offer a folder this run removed.
    #expect(model.result?.items.map(\.name) == [".build", "iPhone 17 Pro"])
    #expect(cache.load()?.items.count == 2)
    #expect(model.projectDecisions["xcode.derivedData"]
        == .cleaned(trashedBytes: 9_100_000_000, deletedBytes: 0, problems: []))
    #expect(model.currentProjectCard?.name == "game")
    #expect(model.deckSummary?.sessionBytesText == "9.1 GB")
}

/// A protected row never reaches `engine.clean`, whichever card it was held back from.
///
/// The executor refuses one itself and `PathGuard` refuses its path, but those are the last
/// two of three independent guards and neither of them is on this side of the button: a card
/// that listed a booted simulator or a live project's derived data would already have
/// promised its bytes in the total the user pressed.
@MainActor
@Test func aProtectedRowIsNeverHandedToTheEngine() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let offered = toolRow(
        name: "ModuleCache", relativePath: "Library/Developer/Xcode/DerivedData/ModuleCache",
        sizeBytes: 9_100_000_000)
    let held = toolRow(
        name: "Live", relativePath: "Library/Developer/Xcode/DerivedData/Live",
        sizeBytes: 4_400_000_000, detail: "kept for app",
        protection: .recentActivity(days: 14))
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let model = try makeDeckModel([offered, held], cache: cache, engine: engine)

    let card = try #require(model.currentProjectCard)
    #expect(card.keptText == "1 kept · changed in the last 14 days · 4.4 GB")
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    let handed = await engine.log.cleans
    #expect(handed == [[offered.id]])
    // And it is still there afterwards, because nothing touched it.
    #expect(model.result?.items.map(\.id) == [held.id])
}

/// The session's two amounts, kept apart from the run's record to the end card.
///
/// A simulator card reports `.deleted` however the Trash setting is set, because `simctl
/// delete` has no Trash to use. So the moment one is answered the session label stops
/// claiming the Trash, and the end card names the two amounts separately rather than adding
/// them under one word.
@MainActor
@Test func theSessionKeepsWhatWentToTheTrashApartFromWhatWentForGood() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(mixedRows(), cache: cache, engine: engine, clock: clock.read)

    // The simulators first: 21.4 GB that cannot be got back.
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    #expect(model.projectDecisions["ios.simulators"]
        == .cleaned(trashedBytes: 0, deletedBytes: 21_400_000_000, problems: []))
    let midway = try #require(model.deckSummary)
    #expect(midway.sessionLabel == "Cleaned so far")
    #expect(midway.sessionTrashedBytes == 0)
    #expect(midway.sessionDeletedBytes == 21_400_000_000)

    // Then the cache, which really does go to the Trash.
    handPauses(clock)
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    handPauses(clock)
    model.skipCurrentProject()

    #expect(model.currentProjectCard == nil)
    let summary = try #require(model.deckSummary)
    #expect(summary.sessionTrashedBytes == 9_100_000_000)
    #expect(summary.sessionDeletedBytes == 21_400_000_000)
    #expect(summary.sessionBytesText == "30.5 GB")
    #expect(summary.endHeadline == "That's everything.")
    #expect(summary.endDetailLines == [
        "9.1 GB moved to the Trash",
        "21.4 GB deleted for good",
        "from 2 cards",
    ])
    // Something is in the Trash, so the note and the button are both earned.
    #expect(summary.endNote == "The space comes back when you empty the Trash.")
    #expect(summary.openTrashText == "Open the Trash")
    #expect(summary.skippedText == "1 skipped · 946 MB")
}

/// A session that only destroyed devices has put nothing in the Trash, and the end card must
/// not offer to open one or promise space that emptying it would release.
@MainActor
@Test func aSessionThatOnlyDeletedDevicesOffersNoTrash() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let model = try makeDeckModel(
        [simulatorRow(name: "iPhone 17 Pro", udid: "AAA", sizeBytes: 21_400_000_000)],
        cache: cache, engine: engine)

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    let summary = try #require(model.deckSummary)
    #expect(summary.endDetailLines == ["21.4 GB deleted for good", "from 1 card"])
    #expect(summary.endNote == nil)
    #expect(summary.openTrashText == nil)
    #expect(summary.hiddenInTrashNote == nil)
}

/// A device the run **skipped** — a simulator that is booted, an emulator `adb` would not
/// talk about — is still on the disk afterwards. So it stays in the scan, and the card is
/// held until the user has read why.
///
/// The pruning rule is what makes this matter: a skipped row pruned out of the result would
/// take 21.4 GB off both surfaces' totals, off its own card, and out of every future scan of
/// the session, while the simulator sat there.
@MainActor
@Test func aDeviceTheRunSkippedStaysInTheScanAndComesBackAsAProblem() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = mixedRows()
    let simulator = try #require(rows.first { $0.name == "iPhone 17 Pro" })
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    engine.skippedItemIDs = [simulator.id]
    let clock = MovableClock()
    let model = try makeDeckModel(rows, cache: cache, engine: engine, clock: clock.read)

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    let awaiting = try #require(model.cardAwaitingAcknowledgement)
    #expect(awaiting.card.id == "ios.simulators")
    #expect(awaiting.problems == ["iPhone 17 Pro: the simulator is running; deleting one "
        + "cannot be undone, so it was left alone"])
    // Still there, on screen and in the cache, and nothing was counted as recovered.
    #expect(model.result?.items.map(\.id).contains(simulator.id) == true)
    #expect(cache.load()?.items.map(\.id).contains(simulator.id) == true)
    #expect(model.deckSessionBytes == 0)
    #expect(model.deckSummary?.sessionLabel == "In the Trash so far")

    // Next is held back by the settle window like Clean up — it is the window's default
    // action too, so the Return that started this clean would otherwise have dismissed the
    // report of the row it refused. See `AppModel.acknowledgeProblems`.
    handPauses(clock)
    model.acknowledgeProblems()

    // The card does not come round again — the user answered it — but the row is still in
    // the scan, so the menu bar's amount and the next session both still count it.
    #expect(model.currentProjectCard?.name == "Derived data")
    #expect(model.result?.items.map(\.id).contains(simulator.id) == true)
}

/// A run's notes are things the user will not be told twice: Xcode having been open, a
/// cancelled run, devices removed outright. The deck has no summary panel, so they join the
/// card's problem lines and the card waits until Next is pressed.
@MainActor
@Test func aRunsNotesAreShownOnTheCardBeforeTheDeckMovesOn() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    engine.runNotes = [Executor.Note.xcodeWasOpen]
    let clock = MovableClock()
    let model = try makeDeckModel(mixedRows(), cache: cache, engine: engine, clock: clock.read)
    model.skipCurrentProject()                          // the simulators
    handPauses(clock)
    #expect(model.currentProjectCard?.name == "Derived data")

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    let awaiting = try #require(model.cardAwaitingAcknowledgement)
    #expect(awaiting.problems == [Executor.Note.xcodeWasOpen])
    // The clean itself went through: the note is something to read, not a failure.
    #expect(model.projectDecisions["xcode.derivedData"]
        == .cleaned(trashedBytes: 9_100_000_000, deletedBytes: 0,
                    problems: [Executor.Note.xcodeWasOpen]))
    #expect(model.result?.items.map(\.name) == [".build", "iPhone 17 Pro"])
}

/// The settle window, `cardRun` and the slots hold across a deck of three different kinds of
/// card, because none of them ever cared what a card was about.
@MainActor
@Test func theSettleWindowAndTheSlotsHoldAcrossAMixedDeck() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(mixedRows(), cache: cache, engine: engine, clock: clock.read)

    // The first card of the session answers at once — nothing advanced to it — and names
    // its own run while it is going.
    #expect(model.cleanCurrentProject())
    #expect(model.cardRun?.cardID == "ios.simulators")
    #expect(await waitUntilIdle(model))
    #expect(model.cardRun?.cardID == nil)

    // A held Return arriving in the same instant the phase went idle is refused, whatever
    // sort of card is underneath it.
    #expect(!model.cleanCurrentProject())
    clock.advance(by: AppModel.cardSettleSeconds - 0.01)
    #expect(!model.cleanCurrentProject())
    clock.advance(by: 0.01)
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    // Both answered slots keep their place and their height although both cards are gone
    // from the pruned scan, and the strip still counts all three.
    #expect(model.deckSlots.map(\.id)
        == ["ios.simulators", "xcode.derivedData", "\(testHome)/dev/game"])
    let summary = try #require(model.deckSummary)
    #expect(summary.positionText == "3 of 3")
    #expect(summary.skyline.map(\.state) == [.cleaned, .cleaned, .current])
}

/// The deck is built against the Trash setting, so saving a change has to drop the held one.
///
/// The memo is what makes a body pass cheap, and it is only ever right for the scan **and
/// the mode** it was built from. Left standing, a card would go on promising the Trash after
/// the user switched to deleting outright — which is the one sentence in this window that
/// must never be stale.
@MainActor
@Test func changingTheTrashSettingRebuildsTheHeldDeck() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let engine = FakeEngine()
    let model = try makeDeckModel(mixedRows(), cache: cache, engine: engine)
    model.skipCurrentProject()                          // past the simulators
    #expect(try #require(model.currentProjectCard).promiseText
        == "Only what is listed here goes to the Trash.")

    var permanent = Settings.makeDefault(home: testHome)
    permanent.moveToTrash = false
    model.apply(permanent)

    #expect(try #require(model.currentProjectCard).promiseText
        == "Only what is listed here is deleted — for good.")
    #expect(try #require(model.deckSummary).sessionLabel == "Cleaned so far")

    // And again when the settings are reloaded from the engine rather than handed over.
    engine.settingsBox.set(Settings.makeDefault(home: testHome))
    model.reloadSettings()
    #expect(try #require(model.currentProjectCard).promiseText
        == "Only what is listed here goes to the Trash.")
}

// MARK: - a clean that left something behind

/// The card stays until the user says Next. Dealing the following project straight away
/// would flash the failure and bury it — and a refused folder is exactly the thing they
/// have to know about, because it is still on the disk and still in the total they were
/// promised.
@MainActor
@Test func aCleanThatLeftSomethingBehindHoldsTheCardUntilItIsAcknowledged() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = threeProjects()
    let pods = try #require(rows.first { $0.name == "ios/Pods" })
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    engine.refusedItemIDs = [pods.id]
    let clock = MovableClock()
    let model = try makeDeckModel(rows, cache: cache, engine: engine, clock: clock.read)
    model.skipCurrentProject()
    model.skipCurrentProject()
    handPauses(clock)

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    let awaiting = try #require(model.cardAwaitingAcknowledgement)
    #expect(awaiting.card.id == "\(testHome)/dev/game")
    #expect(awaiting.problems == ["ios/Pods: refused: the guard said no"])
    // The deck is still on that card, and neither button can take it away.
    #expect(model.currentProjectCard?.id == awaiting.card.id)
    #expect(!model.cleanCurrentProject())
    model.skipCurrentProject()
    #expect(model.currentProjectCard?.id == awaiting.card.id)
    // Nor can the Return that started the clean: Next is the window's default action, and
    // `finishCardRun` opened the settle window before it put these problems on screen.
    model.acknowledgeProblems()
    #expect(model.currentProjectCard?.id == awaiting.card.id)

    handPauses(clock)
    model.acknowledgeProblems()

    #expect(model.cardAwaitingAcknowledgement?.card == nil)
    // The project does not come round again: its answer is recorded, refused folder and all.
    #expect(model.currentProjectCard == nil)
    #expect(model.projectDecisions["\(testHome)/dev/game"]
        == .cleaned(trashedBytes: 946_000_000, deletedBytes: 0,
                    problems: ["ios/Pods: refused: the guard said no"]))
}

/// A clean that went through holds nothing, so the next card is dealt straight away.
@MainActor
@Test func aCleanWithNoProblemsHoldsNothing() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine)

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    #expect(model.cardAwaitingAcknowledgement?.card == nil)
    #expect(model.currentProjectCard?.name == "tool")
}

@MainActor
@Test func acknowledgingWhenNothingIsBeingHeldChangesNothing() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
        let model = try makeDeckModel(threeProjects(), cache: cache, engine: FakeEngine())

    model.acknowledgeProblems()

    #expect(model.currentProjectCard?.name == "site")
    #expect(model.projectDecisions.isEmpty)
}

// MARK: - the busy guard and cancelling

/// `work` is one slot. A second run would overwrite the first run's handle, `cancel()`
/// would then reach only the second, and the first would carry on deleting with nothing
/// left that could stop it.
@MainActor
@Test func aSecondCardCleanIsRefusedWhileOneIsRunning() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.spinsUntilCancelled = true
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine)

    #expect(model.cleanCurrentProject())
    #expect(!model.cleanCurrentProject())
    // And a skip cannot move the card out from under the run that is cleaning it.
    model.skipCurrentProject()
    #expect(model.projectDecisions.isEmpty)

    model.cancel()
    #expect(await waitUntilIdle(model))
    let cleans = await engine.log.cleans
    #expect(cleans.count == 1)
}

/// Refused during a scan as well, because `work` is the same one slot. A scan takes about
/// 51 seconds, so the Clean button really is unavailable for that long — which is why
/// Skip is not.
@MainActor
@Test func cleaningACardIsRefusedWhileAScanRunsButSkippingIsNot() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine(result: makeResult(threeProjects()))
    engine.spinsUntilCancelled = true
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine)

    #expect(model.startScan())
    #expect(!model.cleanCurrentProject())
    model.skipCurrentProject()
    #expect(model.projectDecisions["\(testHome)/dev/site"] == .skipped)

    model.cancel()
    #expect(await waitUntilIdle(model))
}

/// Spec §8.2: a run stops before the next item, and what is already removed stays
/// removed. The fake spins until its task is cancelled, so this pins that `cancel()`
/// really reaches the task a card's clean is on — which is what makes `Executor`'s
/// per-item check fire.
@MainActor
@Test func cancellingACardsCleanStopsItAndPrunesOnlyWhatTheRecordNames() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.spinsUntilCancelled = true
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine)

    #expect(model.cleanCurrentProject())
    #expect(model.isBusy)
    model.cancel()
    #expect(await waitUntilIdle(model))

    #expect(!model.isBusy)
    // The pinned record names no entry, so nothing was removed and nothing is pruned.
    #expect(model.result?.items.count == 4)
    #expect(model.deckSessionBytes == 0)
}

// MARK: - going back through the skipped ones

@MainActor
@Test func reviewingTheSkippedProjectsBringsThoseCardsBack() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(
        threeProjects(), cache: cache, engine: engine, clock: clock.read)

    model.skipCurrentProject()          // site
    handPauses(clock)
    #expect(model.cleanCurrentProject())  // tool
    #expect(await waitUntilIdle(model))
    model.skipCurrentProject()          // game
    #expect(model.currentProjectCard == nil)

    model.reviewSkippedProjects()
    handPauses(clock)

    // Both skipped cards are back, in the order the session dealt them.
    #expect(model.currentProjectCard?.name == "site")
    #expect(model.deckSummary?.skippedText == nil)
    // The cleaned one is not: its folders are gone, and it is what the session total and
    // the skyline are built from.
    #expect(model.projectDecisions["\(testHome)/dev/tool"]
        == .cleaned(trashedBytes: 2_000_000_000, deletedBytes: 0, problems: []))
    #expect(model.deckSessionBytes == 2_000_000_000)
    #expect(model.deckSummary?.skyline.map(\.state) == [.current, .cleaned, .upcoming])
}

// MARK: - a fresh scan landing under a deck in progress

/// A background scan arrives without the user asking. It must not deal them cards they
/// have already answered, and it must not push a project it has newly found in front of
/// the one they are reading.
///
/// A tick is the opposite case and stays the opposite way round — `aFreshScanRebuildsThe
/// TicksRatherThanKeepingThem` — because a tick is a judgement about a measurement and a
/// skip is "not this project, not now".
@MainActor
@Test func aFreshScanKeepsTheSkipsAndAppendsWhateverItHasNewlyFound() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let newcomer = folderRow(project: "fresh", folder: "build", sizeBytes: 20_000_000_000)
    let model = try makeDeckModel(
        threeProjects(), cache: cache,
        engine: FakeEngine(result: makeResult(threeProjects() + [newcomer])))

    model.skipCurrentProject()          // site, the biggest
    #expect(model.currentProjectCard?.name == "tool")

    #expect(model.startScan())
    #expect(await waitUntilIdle(model))

    // The skip survived, so the card on screen is still the one the user was reading.
    #expect(model.projectDecisions["\(testHome)/dev/site"] == .skipped)
    #expect(model.currentProjectCard?.name == "tool")
    // And the newcomer is at the end of the deck although it is the biggest project on
    // the machine: the order was fixed when the first card was answered.
    let summary = try #require(model.deckSummary)
    #expect(summary.positionText == "2 of 4")
    #expect(summary.skyline.map(\.state) == [.skipped, .current, .upcoming, .upcoming])
    #expect(model.sessionCards.map(\.name) == ["site", "tool", "game", "fresh"])
}

/// Before the first decision there is nothing to hold still, so a scan landing takes the
/// order it found. The alternative is freezing whatever order was in the cache at launch,
/// which may be six hours old and may name projects that have since been cleaned by hand.
@MainActor
@Test func aScanLandingBeforeAnyDecisionSimplyReplacesTheDeck() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let model = try makeDeckModel(
        [folderRow(project: "stale-cache", folder: "build", sizeBytes: 5_000_000_000)],
        cache: cache, engine: FakeEngine(result: makeResult(threeProjects())))
    #expect(model.currentProjectCard?.name == "stale-cache")

    #expect(model.startScan())
    #expect(await waitUntilIdle(model))

    #expect(model.sessionCards.map(\.name) == ["site", "tool", "game"])
    #expect(model.deckSummary?.positionText == "1 of 3")
}

// MARK: - the end of the deck

/// The deck has no rescan **between** cards — a scan takes about 51 seconds and would
/// blank the card the user is working through, twenty-four times — and exactly one when it
/// runs out, because the end card is where they stop and read totals.
///
/// The loop is built, which is what wires it to the model, and its forever-loop is never
/// run: the only thing under test is the scan the model asks for by itself.
@MainActor
@Test func theDeckAsksForOneFreshScanWhenItRunsOutAndNoneBetweenCards() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine(result: makeResult([
        folderRow(project: "third", folder: "build", sizeBytes: 4_000_000_000),
    ]))
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel([
        folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000),
        folderRow(project: "tool", folder: ".build", sizeBytes: 2_000_000_000),
    ], cache: cache, engine: engine, clock: clock.read)
    let loop = BackgroundScanLoop(
        model: model, scheduler: ScanScheduler(intervalHours: 6),
        sleeper: FakeSleeper(clock: clock), clock: clock.read)

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    // A card is still waiting, so nothing was measured again.
    #expect(model.currentProjectCard?.name == "tool")
    let betweenCards = await engine.log.scans
    #expect(betweenCards == 0)

    handPauses(clock)
    #expect(model.cleanCurrentProject())
    #expect(await waitUntil { model.currentProjectCard?.name == "third" })
    let atTheEnd = await engine.log.scans
    #expect(atTheEnd == 1)

    // The deck runs out a second time, and the one rescan it gets is not asked for again:
    // an app left open would otherwise measure the whole machine every time its last card
    // was answered.
    handPauses(clock)
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    #expect(model.currentProjectCard == nil)
    #expect(await waitUntil { model.result?.items.isEmpty == true })
    let after = await engine.log.scans
    #expect(after == 1)
    withExtendedLifetime(loop) {}
}

/// A deck the user only skipped their way through has learned nothing new, so it does not
/// spend 51 seconds measuring the machine again.
@MainActor
@Test func aDeckThatWasOnlySkippedThroughAsksForNoRescan() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let engine = FakeEngine(result: makeResult(threeProjects()))
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine)
    let clock = MovableClock()
    let loop = BackgroundScanLoop(
        model: model, scheduler: ScanScheduler(intervalHours: 6),
        sleeper: FakeSleeper(clock: clock), clock: clock.read)

    model.skipCurrentProject()
    model.skipCurrentProject()
    model.skipCurrentProject()

    #expect(model.currentProjectCard == nil)
    // Yielded a few times, so a rescan asked for on a task of its own would have started.
    for _ in 0..<10 { await Task.yield() }
    let scans = await engine.log.scans
    #expect(scans == 0)
    withExtendedLifetime(loop) {}
}

/// What the last card says, from a session that cleaned two projects and left one alone.
@MainActor
@Test func theEndCardSumsUpTheSession() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(threeProjects() + [
        protectedProjectRow(project: "work", sizeBytes: 9_200_000_000),
        folderRow(project: "crumb", folder: "build", sizeBytes: 4_000_000),
    ], cache: cache, engine: engine, clock: clock.read)

    #expect(model.cleanCurrentProject())            // site, 9.0 GB
    #expect(await waitUntilIdle(model))
    handPauses(clock)
    #expect(model.cleanCurrentProject())            // tool, 2.0 GB
    #expect(await waitUntilIdle(model))
    model.skipCurrentProject()                      // game, 1.3 GB

    #expect(model.currentProjectCard == nil)
    let summary = try #require(model.deckSummary)
    #expect(summary.endHeadline == "That's everything.")
    #expect(summary.sessionBytesText == "11.0 GB")
    #expect(summary.endDetailLines == ["11.0 GB moved to the Trash", "from 2 cards"])
    #expect(summary.endNote == "The space comes back when you empty the Trash.")
    #expect(summary.skippedText == "1 skipped · 1.3 GB")
    #expect(summary.reviewSkippedText == "Go through skipped again")
    #expect(summary.openTrashText == "Open the Trash")
    #expect(summary.positionText == nil)
    // The two kinds of project that never got a card are still accounted for.
    let deck = try #require(model.projectDeck)
    #expect(deck.keptProjectsText == "1 pinned project was left alone · 9.2 GB")
    #expect(deck.smallThingsText == "1 small thing under 50 MB was not shown · 4 MB")
}

/// The end card's button opens the Trash of the home the rest of the app measured, not
/// whatever `FileManager` thinks the current user's is. The two are the same on a real Mac
/// and are deliberately not the same under test, which is the only way to say what the
/// button would open.
///
/// It opens the folder and nothing else. Nothing in this app empties a Trash: it is the undo
/// the whole tool is built around, and `ProjectDeckText.emptyTheTrashNote` asks the user to
/// do it themselves.
@MainActor
@Test func theEndCardsButtonPointsAtTheTrashOfTheHomeTheAppMeasured() {
    let model = AppModel(
        engine: FakeEngine(), cache: ScanCache(directory: TempDir().url),
        home: testHome, clock: { now })

    #expect(model.trashDirectory.path == "\(testHome)/.Trash")
    #expect(model.trashDirectory.isFileURL)
}

/// A machine with nothing worth a card says so rather than showing an empty deck, and it
/// does not ask for a scan it has no reason to run.
@MainActor
@Test func aMachineWithNothingWorthCleaningSaysSoAtOnce() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let model = try makeDeckModel(
        [folderRow(project: "crumb", folder: "build", sizeBytes: 4_000_000)],
        cache: cache, engine: FakeEngine())

    #expect(model.currentProjectCard == nil)
    let summary = try #require(model.deckSummary)
    #expect(summary.endHeadline == "Nothing to clean up.")
    #expect(summary.endDetailLines == ["Nothing here holds more than 50 MB."])
    #expect(summary.skyline.isEmpty)
    #expect(summary.reviewSkippedText == nil)
}

// MARK: - slots for projects that are no longer there

/// The session's deck forgets a project that has stopped having anything to clean.
///
/// `rememberDeckOrder` only appends, which is what holds "3 of 24" and the skyline still
/// while the user works through a deck. Appending alone stops being enough the moment a
/// scan can find **less** than the one before it — and the plainest way that happens is a
/// `flutter clean` in a terminal, or a project deleted outright. Left in, the strip said
/// "Project 2 of 24" over three real cards, with twenty-one bars for projects the deck
/// could never deal, and the session ended at position 2 of 24.
@MainActor
@Test func aScanThatHasLostAProjectDropsItsSlotFromTheStrip() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    // The rescan finds `site` and `game` only: `tool` has been cleaned by hand.
    let survivors = threeProjects().filter { $0.detail != "tool" }
    let clock = MovableClock()
    let model = try makeDeckModel(
        threeProjects(), cache: cache,
        engine: FakeEngine(result: makeResult(survivors)), clock: clock.read)

    model.skipCurrentProject()                          // site, answered and kept
    #expect(model.projectPosition.map { [$0.index, $0.count] } == [2, 3])

    #expect(model.startScan())
    #expect(await waitUntilIdle(model))

    // Two slots: the answered one, and the one card that is still there.
    #expect(model.deckSlots.map(\.id) == ["\(testHome)/dev/site", "\(testHome)/dev/game"])
    #expect(model.projectPosition.map { [$0.index, $0.count] } == [2, 2])
    let summary = try #require(model.deckSummary)
    #expect(summary.positionText == "2 of 2")
    #expect(summary.skyline.map(\.state) == [.skipped, .current])
    // The skipped project keeps the total the deck remembered for it, so the strip's
    // "1 skipped" figure does not move because a different project vanished.
    #expect(summary.skippedText == "1 skipped · 9.0 GB")
}

/// The same, for a slot the session has already **cleaned**.
///
/// The cleaned card's slot survives whatever a later scan says — it is the session's
/// history, it carries what that project was worth, and the skyline and the session total
/// are built from it. A card's clean prunes its own rows, so without that rule a cleaned
/// project would vanish from the strip the moment the next scan landed and the session total
/// would have nothing left to stand on. The slot of a project nobody answered does not
/// survive, and the scan's newly-found project is appended after both.
@MainActor
@Test func aCleanedSlotSurvivesAScanThatHasLostEverythingElse() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine(result: makeResult([
        folderRow(project: "fresh", folder: "build", sizeBytes: 3_000_000_000),
    ]))
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(
        threeProjects(), cache: cache, engine: engine, clock: clock.read)

    // One card cleaned on the deck, so the session's order is fixed at three.
    #expect(model.cleanCurrentProject())                // site
    #expect(await waitUntilIdle(model))
    #expect(model.deckSlots.count == 3)

    // …then a background scan lands with none of them in it.
    #expect(model.startScan())
    #expect(await waitUntilIdle(model))

    // The cleaned project keeps its bar and its bytes; `tool` and `game`, which the user
    // never answered and the new scan no longer has, are gone.
    #expect(model.deckSlots.map(\.id) == ["\(testHome)/dev/site", "\(testHome)/dev/fresh"])
    let summary = try #require(model.deckSummary)
    #expect(summary.positionText == "2 of 2")
    #expect(summary.skyline.map(\.state) == [.cleaned, .current])
    #expect(summary.sessionBytesText == "9.0 GB")
    #expect(model.currentProjectCard?.name == "fresh")
}

/// Pruning a slot must not re-arm the one rescan a deck session gets.
///
/// The two interact: forgetting slots can empty the deck, and the end of the deck is what
/// asks for a scan. Re-armed, an app left open would measure the whole machine every time a
/// project it had already answered dropped out of a background scan.
@MainActor
@Test func forgettingSlotsDoesNotGiveTheSessionASecondRescan() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine(result: makeResult([]))
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel([
        folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000),
        folderRow(project: "tool", folder: ".build", sizeBytes: 2_000_000_000),
    ], cache: cache, engine: engine, clock: clock.read)
    let loop = BackgroundScanLoop(
        model: model, scheduler: ScanScheduler(intervalHours: 6),
        sleeper: FakeSleeper(clock: clock), clock: clock.read)

    // Clean the first card, then answer the last one — which empties the deck and spends
    // the session's one rescan. The rescan finds nothing at all.
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    handPauses(clock)
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    // Waited on the scan itself. The prune leaves `result` empty too, so waiting on that
    // would be satisfied before the rescan had started and would test nothing.
    #expect(await waitUntilAwaiting { await engine.log.scans == 1 })

    // Both slots were answered, so both survive the prune and the end card still adds up.
    #expect(model.deckSlots.count == 2)
    #expect(model.currentProjectCard == nil)
    #expect(model.deckSummary?.sessionBytesText == "11.0 GB")
    // And no second scan was asked for.
    for _ in 0..<10 { await Task.yield() }
    let later = await engine.log.scans
    #expect(later == 1)
    withExtendedLifetime(loop) {}
}

// MARK: - whose run is it

/// The card's own run does name the card, and carries the progress the card's rows drain on.
@MainActor
@Test func theCardsOwnRunNamesTheCardAndCarriesItsProgress() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.spinsUntilCancelled = true
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine)
    let card = try #require(model.currentProjectCard)

    #expect(model.cleanCurrentProject())

    // `nil` progress the instant the button is pressed, which is the state the title's
    // fallback is written for.
    #expect(model.cardRun?.cardID == card.id)
    #expect(model.cardRun?.progress == nil)

    // The fake reports once before it starts spinning.
    let expected = ExecutionProgress(completed: 1, total: 1, currentName: "Yarn")
    #expect(await waitUntil { model.cardRun?.progress == expected })
    #expect(ProjectDeckText.cleaning(model.cardRun?.progress, of: card.folders.count)
        == "Cleaning… 1 of 1")

    model.cancel()
    #expect(await waitUntilIdle(model))
    // Cleared with the run, or a finished card's folders would stay struck through.
    #expect(model.cardRun?.cardID == nil)
}

/// A report that lands after the card's run has ended does not reattach itself to whatever
/// is running next — the next card's clean, most likely, since the deck deals one the moment
/// this run ends.
@MainActor
@Test func aCardRunReportArrivingLateIsDropped() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine)

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    #expect(model.cardRun?.cardID == nil)

    model.applyCardRunReport(ExecutionProgress(completed: 9, total: 9, currentName: "Late"))

    #expect(model.cardRun?.cardID == nil)
    #expect(model.phase == .idle)
}

// MARK: - a held Return key

/// Clean up is the window's default action, so Return presses it — and macOS repeats a held
/// key about thirty times a second. Nothing else stood in the way: no confirmation, and
/// `phase` back to `.idle` the instant a run ends. A user who held Return for a second
/// cleaned project after project, each decision taken while the next card was still
/// animating in, with only the Trash to say what had gone.
@MainActor
@Test func aSecondCleanIsRefusedUntilTheNewCardHasSettled() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(
        threeProjects(), cache: cache, engine: engine, clock: clock.read)

    // The first card of the session is not subject to it: nothing advanced to it.
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    #expect(model.currentProjectCard?.name == "tool")

    // A key repeat, arriving in the same instant the phase went idle.
    #expect(!model.cleanCurrentProject())
    // Still not, a moment short of the window.
    clock.advance(by: AppModel.cardSettleSeconds - 0.01)
    #expect(!model.cleanCurrentProject())
    let cleansSoFar = await engine.log.cleans
    #expect(cleansSoFar.count == 1)
    // The card is where it was, untouched.
    #expect(model.currentProjectCard?.name == "tool")

    clock.advance(by: 0.01)

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    let cleansNow = await engine.log.cleans
    #expect(cleansNow.count == 2)
}

/// Every way the deck moves opens the window, not just a clean: a skip, Next after a
/// problem, and going back through the skipped ones all put a new card under a cursor that
/// is already over Clean up.
@MainActor
@Test func everyWayTheDeckAdvancesStartsTheSettleWindow() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = threeProjects()
    let pods = try #require(rows.first { $0.name == "ios/Pods" })
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    engine.refusedItemIDs = [pods.id]
    let clock = MovableClock()
    let model = try makeDeckModel(rows, cache: cache, engine: engine, clock: clock.read)

    // A skip.
    model.skipCurrentProject()
    #expect(!model.cleanCurrentProject())
    handPauses(clock)
    #expect(model.cleanCurrentProject())                // tool
    #expect(await waitUntilIdle(model))

    // Next, after a clean that left something behind.
    handPauses(clock)
    #expect(model.cleanCurrentProject())                // game, whose Pods are refused
    #expect(await waitUntilIdle(model))
    #expect(model.cardAwaitingAcknowledgement?.card != nil)
    // Next waits too, so the clock has to move before it can be pressed at all.
    handPauses(clock)
    model.acknowledgeProblems()
    #expect(!model.cleanCurrentProject())

    // Going back through the skipped ones.
    handPauses(clock)
    model.reviewSkippedProjects()
    #expect(model.currentProjectCard?.name == "site")
    #expect(!model.cleanCurrentProject())
    handPauses(clock)
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
}

/// Skip is deliberately not held back. It removes nothing, and a user flicking through
/// twenty-four projects with the arrow key is the deck working as intended.
@MainActor
@Test func skipIsNotHeldBackByTheSettleWindow() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let clock = MovableClock()
    let model = try makeDeckModel(
        threeProjects(), cache: cache, engine: FakeEngine(), clock: clock.read)

    model.skipCurrentProject()
    model.skipCurrentProject()
    model.skipCurrentProject()

    #expect(model.currentProjectCard == nil)
    #expect(model.deckSummary?.skippedCount == 3)
}

// MARK: - how often the deck is built

/// One build per applied scan, however many questions the window asks.
///
/// Building the deck walks every row of a scan — a couple of hundred on a real dev machine
/// — groups them by project, sorts them and writes every sentence. A SwiftUI body pass asks
/// four or five separate questions that each start from the deck, and each of those used to
/// build it again. `deckBuildCount` is the only way to see it from outside: the deck is a
/// value, so two builds of one scan are indistinguishable by what they produce.
@MainActor
@Test func theDeckIsBuiltOncePerAppliedScanHoweverOftenItIsRead() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine(result: makeResult(threeProjects()))
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(
        threeProjects(), cache: cache, engine: engine, clock: clock.read)

    // Nothing is built until something asks. Applying a scan only drops the held one —
    // the model has no view and no reason to walk two hundred rows on its own.
    #expect(model.deckBuildCount == 0)

    // A body pass, as the window really reads it.
    for _ in 0..<3 {
        _ = model.projectDeck
        _ = model.deckSummary
        _ = model.currentProjectCard
        _ = model.sessionCards
        _ = model.deckSlots
        _ = model.projectPosition
    }
    #expect(model.deckBuildCount == 1)

    // A clean applies a pruned scan, so the deck is built again — and exactly once, over
    // however many reads the redraw after it makes.
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    let afterTheClean = model.deckBuildCount
    #expect(afterTheClean > 1)
    _ = model.deckSummary
    _ = model.projectDeck
    #expect(model.deckBuildCount == afterTheClean)
    // And the rebuilt deck really is the pruned one, so the memo is not stale.
    #expect(model.projectDeck?.cards.map(\.name) == ["tool", "game"])
}

/// A fresh scan invalidates the memo, and so does the whole scan being dropped.
@MainActor
@Test func theHeldDeckIsDroppedWheneverTheScanUnderneathItChanges() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let model = try makeDeckModel(
        threeProjects(), cache: cache,
        engine: FakeEngine(result: makeResult([
            folderRow(project: "fresh", folder: "build", sizeBytes: 3_000_000_000),
        ])))
    #expect(model.projectDeck?.cards.map(\.name) == ["site", "tool", "game"])

    #expect(model.startScan())
    #expect(await waitUntilIdle(model))
    #expect(model.projectDeck?.cards.map(\.name) == ["fresh"])
}

/// Six projects' `.build` folders went into the Trash, the user opened it, saw none of them
/// and concluded they had been deleted outright: Finder hides a dot-name in the Trash as it
/// does anywhere else. The executor now renames a project's build folder on the way out, so
/// the note is for the runs where that could not be done — and the answer comes from where
/// each folder **landed**, never from where it came from.
@MainActor
@Test func theEndCardSaysNothingWhileEveryFolderLandsUnderAVisibleName() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine, clock: clock.read)

    #expect(model.cleanCurrentProject())            // site: node_modules, which Finder shows
    #expect(await waitUntilIdle(model))
    #expect(model.trashedHiddenFolders == false)
    #expect(try #require(model.deckSummary).hiddenInTrashNote == nil)

    handPauses(clock)
    // tool's `.build`: hidden where it was, and it landed as "tool – .build", which is not.
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    #expect(model.trashedHiddenFolders == false)
    #expect(try #require(model.deckSummary).hiddenInTrashNote == nil)
}

/// And the note appears the moment a folder really does land hidden, which is what happens
/// when the rename could not be made: the Trash then holds a `.build` the user cannot see.
@MainActor
@Test func theEndCardSaysWhenSomethingLandedInTheTrashHiddenThere() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    engine.unrenamedItemIDs = ["projects.buildOutput|\(testHome)/dev/tool/.build"]
    let clock = MovableClock()
    let model = try makeDeckModel(threeProjects(), cache: cache, engine: engine, clock: clock.read)

    #expect(model.cleanCurrentProject())            // site, renamed and visible
    #expect(await waitUntilIdle(model))
    #expect(model.trashedHiddenFolders == false)

    handPauses(clock)
    #expect(model.cleanCurrentProject())            // tool, landed as `.build`
    #expect(await waitUntilIdle(model))
    #expect(model.trashedHiddenFolders)
    #expect(try #require(model.deckSummary).hiddenInTrashNote
        == ProjectDeckText.hiddenInTrashNote)
}

// MARK: - the card between the two halves of the deck

/// One cache and two of the user's own files, so the deck has both halves and an
/// interstitial between them.
private func twoHalves() -> [CleanupItem] {
    [
        xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000),
        modelRow(publisher: "lmstudio-community", model: "Qwen3-30B-GGUF",
                 sizeBytes: 18_000_000_000),
        downloadRow(name: "Xcode_26.1_beta.xip", sizeBytes: 7_000_000_000),
    ]
}

@MainActor
@Test func theDeckDealsTheInterstitialBeforeTheFirstOfTheUsersOwnFiles() throws {
    let temp = TempDir()
    let model = try makeDeckModel(twoHalves(), cache: ScanCache(directory: temp.url),
                                  engine: FakeEngine())

    #expect(model.sessionCards.map(\.name) == [
        "uv", ProjectDeckText.interstitialHeadline,
        "lmstudio-community/Qwen3-30B-GGUF", "Xcode_26.1_beta.xip",
    ])
    // It holds no slot, so the counter counts the three cards that hold bytes.
    #expect(model.deckSlots.map(\.id) == [
        "other.xdgCache|/Users/test/.cache/uv",
        "big.aiModels|/Users/test/.lmstudio/models/lmstudio-community/Qwen3-30B-GGUF",
        "big.downloads|/Users/test/Downloads/Xcode_26.1_beta.xip",
    ])
    #expect(model.deckSlots.map(\.isBigThing) == [false, true, true])
    #expect(model.deckSummary?.positionText == "1 of 3")
}

/// "Look through them" **removes nothing**. It notes the card as answered and lets the deck
/// deal the first of the user's own files.
@MainActor
@Test func lookingThroughTheBigThingsRemovesNothingAndDealsTheFirstOne() async throws {
    let temp = TempDir()
    let engine = FakeEngine()
    let clock = MovableClock()
    let model = try makeDeckModel(twoHalves(), cache: ScanCache(directory: temp.url),
                                  engine: engine, clock: clock.read)

    // Past the cache card first, so the interstitial is the one on screen.
    model.skipCurrentProject()
    handPauses(clock)
    #expect(model.currentProjectCard?.isInterstitial == true)
    // No position while it is up: it holds no slot.
    #expect(model.deckSummary?.positionText == nil)

    #expect(model.cleanCurrentProject())

    #expect(model.currentProjectCard?.name == "lmstudio-community/Qwen3-30B-GGUF")
    #expect(model.deckSummary?.positionText == "2 of 3")
    // Nothing was handed to the engine, and nothing about the session moved.
    #expect(await engine.log.cleans.isEmpty)
    #expect(model.deckSessionBytes == 0)
    #expect(!model.isBusy)
    // It is not counted as a skipped card either, although it recorded a decision so the
    // deck does not deal it twice.
    #expect(model.deckSummary?.skippedCount == 1)
    #expect(model.deckSummary?.skippedBytes == 1_100_000_000)
}

/// "Skip them all" answers for the whole second half at once — and records each card
/// separately, so every one keeps its slot, its bar and its share of the skipped total.
@MainActor
@Test func skippingThemAllAnswersEveryOneOfTheUsersOwnFiles() async throws {
    let temp = TempDir()
    let engine = FakeEngine()
    let clock = MovableClock()
    let model = try makeDeckModel(twoHalves(), cache: ScanCache(directory: temp.url),
                                  engine: engine, clock: clock.read)

    model.skipCurrentProject()          // the cache card
    handPauses(clock)
    #expect(model.currentProjectCard?.isInterstitial == true)
    model.skipCurrentProject()          // "Skip them all"

    // The deck is finished: there is nothing left to ask.
    #expect(model.currentProjectCard == nil)
    #expect(await engine.log.cleans.isEmpty)
    let summary = try #require(model.deckSummary)
    #expect(summary.skippedCount == 3)
    #expect(summary.skippedBytes == 26_100_000_000)
    #expect(summary.skyline.map(\.state) == [.skipped, .skipped, .skipped])
    #expect(summary.endDetailLines == [ProjectDeckText.endDetailNothingCleaned])
}

/// Going back through the skipped ones brings the interstitial back too, which is right: the
/// user is about to be asked about their own files again, and that is the card that says so.
@MainActor
@Test func goingBackThroughSkippedBringsTheInterstitialBack() throws {
    let temp = TempDir()
    let clock = MovableClock()
    let model = try makeDeckModel(twoHalves(), cache: ScanCache(directory: temp.url),
                                  engine: FakeEngine(), clock: clock.read)

    model.skipCurrentProject()
    handPauses(clock)
    model.skipCurrentProject()          // "Skip them all"
    #expect(model.currentProjectCard == nil)

    model.reviewSkippedProjects()

    #expect(model.currentProjectCard?.name == "uv")
    #expect(model.sessionCards.map(\.isInterstitial) == [false, true, false, false])
}

/// **The interstitial obeys the settle window like any card.** Its primary button sits
/// exactly where Clean up sat on the card before it, and a held Return must not carry
/// through — which it would if the card were answered by a path of its own.
@MainActor
@Test func theInterstitialRefusesToBeAnsweredInsideTheSettleWindow() throws {
    let temp = TempDir()
    let clock = MovableClock()
    let model = try makeDeckModel(twoHalves(), cache: ScanCache(directory: temp.url),
                                  engine: FakeEngine(), clock: clock.read)

    model.skipCurrentProject()          // the deck has just moved
    #expect(model.currentProjectCard?.isInterstitial == true)

    #expect(model.cleanCurrentProject() == false)
    #expect(model.currentProjectCard?.isInterstitial == true)

    handPauses(clock)
    #expect(model.cleanCurrentProject())
    #expect(model.currentProjectCard?.isInterstitial == false)
}

/// The interstitial stays where it belongs after a decision fixes the deck's order.
///
/// It holds no slot, so it cannot come out of the remembered order — appended with the rest
/// of the cards the session has not seen, it would land *after* the big things it is
/// supposed to introduce. `AppModel.sessionCards` splices it back in instead.
@MainActor
@Test func theInterstitialStaysBeforeTheBigThingsAfterTheOrderIsFixed() throws {
    let temp = TempDir()
    let clock = MovableClock()
    let model = try makeDeckModel(twoHalves(), cache: ScanCache(directory: temp.url),
                                  engine: FakeEngine(), clock: clock.read)

    // The first decision is what fixes the order, and from then on `sessionCards` is built
    // from the slots.
    model.skipCurrentProject()
    handPauses(clock)

    #expect(model.sessionCards.map(\.name) == [
        "uv", ProjectDeckText.interstitialHeadline,
        "lmstudio-community/Qwen3-30B-GGUF", "Xcode_26.1_beta.xip",
    ])
}

/// Cleaning one of the user's own files hands the engine **that one row** and prunes it, the
/// same path an ordinary card takes.
@MainActor
@Test func cleaningOneOfTheUsersOwnFilesHandsTheEngineThatOneRow() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try makeDeckModel(twoHalves(), cache: cache, engine: engine,
                                  clock: clock.read)

    model.skipCurrentProject()          // the cache card
    handPauses(clock)
    model.cleanCurrentProject()         // "Look through them"
    handPauses(clock)

    let card = try #require(model.currentProjectCard)
    #expect(card.isBigThing)
    #expect(card.primaryActionTitle == "Move 18.0 GB to Trash")
    #expect(card.answersToReturn == false)
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    #expect(await engine.log.cleans == [[
        "big.aiModels|/Users/test/.lmstudio/models/lmstudio-community/Qwen3-30B-GGUF",
    ]])
    #expect(model.deckSessionBytes == 18_000_000_000)
    // Pruned out of the scan, and the slot keeps its place and its colour.
    #expect(model.projectDeck?.cards.contains {
        $0.name == "lmstudio-community/Qwen3-30B-GGUF"
    } == false)
    let summary = try #require(model.deckSummary)
    #expect(summary.skyline.map(\.state) == [.skipped, .cleanedBigThing, .current])
    #expect(summary.sessionTrashedBytes == 18_000_000_000)
}

// MARK: - the page with the checkboxes

/// Three of the files `big.largeFiles` finds, in no particular order, so the page's own
/// biggest-first ordering is what the assertions below read.
private func largeFilePage() -> [CleanupItem] {
    [
        largeFileRow(name: "cards.db", folder: "dev/workspace-two/client-app/tools/carddb/out",
                     sizeBytes: 876_000_000),
        largeFileRow(name: "scan.pdf", folder: "Documents/archive/scans/batch-a/current",
                     sizeBytes: 1_200_000_000),
        largeFileRow(name: "gallery_1fps.rgb", folder: "dev/lesson-tool/work/lesson43/frames",
                     sizeBytes: 648_000_000),
    ]
}

/// A model with the page on screen: the interstitial answered, the settle window open.
///
/// The page is a big thing, so there is always a card in front of it — that is the whole of
/// what the interstitial is for — and every test below starts from the same two presses a
/// user would make.
@MainActor
private func modelShowingTheChecklistPage(
    _ rows: [CleanupItem], cache: ScanCache, engine: FakeEngine, clock: MovableClock
) throws -> AppModel {
    let model = try makeDeckModel(rows, cache: cache, engine: engine, clock: clock.read)
    #expect(model.currentProjectCard?.isInterstitial == true)
    #expect(model.cleanCurrentProject())              // "Look through them"
    handPauses(clock)
    return model
}

/// **The page is dealt with nothing ticked, and Clean up hands the engine exactly what the
/// user has ticked, in the order the rows are drawn.**
///
/// The user asked for precisely this after living with it: all of them unchecked by default,
/// because some of these files matter a great deal to whoever owns them, and every box is
/// theirs to tick. So the page opens offering nothing, the boxes
/// are how the offer is built up, and the list that goes to the engine is derived from them —
/// the rows the user left alone are still on the card and must not be in the run.
@MainActor
@Test func theChecklistPageHandsTheEngineExactlyWhatIsTicked() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = largeFilePage()
    let database = try #require(rows.first { $0.name == "cards.db" })
    let scan = try #require(rows.first { $0.name == "scan.pdf" })
    let frames = try #require(rows.first { $0.name == "gallery_1fps.rgb" })
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try modelShowingTheChecklistPage(
        rows, cache: cache, engine: engine, clock: clock)

    let dealt = try #require(model.currentProjectCard)
    #expect(dealt.isChecklist)
    #expect(dealt.folders.map(\.name) == ["scan.pdf", "cards.db", "gallery_1fps.rgb"])
    #expect(dealt.folders.map(\.isTicked) == [false, false, false])
    #expect(dealt.folderCountText == "0 of 3 files")
    #expect(dealt.primaryActionTitle == "Tick the files to move to the Trash")
    #expect(dealt.isPrimaryActionEnabled == false)
    #expect(dealt.totalHeadline.number == "0")
    #expect(dealt.totalHeadline.outOf == "of 2.7 GB")
    // Nothing is stored for a page nobody has touched, and nothing is offered: the set holds
    // the ticks, so the state the user asked for is the empty one.
    #expect(model.tickedChecklistIDs.isEmpty)
    #expect(dealt.items.isEmpty)
    // **A press before anything is ticked is refused by the model**, not only dead in the
    // window — and nothing reaches the engine.
    #expect(model.cleanCurrentProject() == false)
    #expect(await engine.log.cleans.isEmpty)

    model.setChecklistRow(scan.id, ticked: true)
    model.setChecklistRow(frames.id, ticked: true)

    #expect(model.tickedChecklistIDs == [scan.id, frames.id])
    let edited = try #require(model.currentProjectCard)
    #expect(edited.folders.map(\.isTicked) == [true, false, true])
    #expect(edited.folderCountText == "2 of 3 files")
    #expect(edited.primaryActionTitle == "Move 1.8 GB to Trash")
    // The headline climbs while the total stays put: 1.8 GB chosen out of the 2.7 GB there is.
    #expect(edited.totalHeadline.number == "1.8")
    #expect(edited.totalHeadline.outOf == "of 2.7 GB")
    // The unticked row is in no run, so it can never drain while the file sits on the disk.
    #expect(edited.folders.map(\.runIndex) == [0, nil, 1])
    // And a tick can be taken back.
    model.setChecklistRow(frames.id, ticked: false)
    #expect(model.tickedChecklistIDs == [scan.id])
    model.setChecklistRow(frames.id, ticked: true)

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    // **Exactly the ticked rows, in display order, and nothing else.**
    #expect(await engine.log.cleans == [[scan.id, frames.id]])
    #expect(model.deckSessionBytes == 1_848_000_000)
    #expect(model.projectDecisions["big.largeFiles"]
            == .cleaned(trashedBytes: 1_848_000_000, deletedBytes: 0, problems: []))
    // The database is untouched: the file the user never ticked is still in the scan.
    #expect(model.result?.items.map(\.id) == [database.id])
}

/// **The row the user left unticked survives the prune**, on screen and in the cache.
///
/// The prune drops what the run's own record says went, which is the ticked rows and no more.
/// A page that pruned everything it had drawn would take the 876 MB out of the menu bar's
/// reckoning and out of every later scan of the session, while the file sat there.
@MainActor
@Test func anUntickedRowIsNotPrunedWithTheOnesThatWent() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = largeFilePage()
    let database = try #require(rows.first { $0.name == "cards.db" })
    let scan = try #require(rows.first { $0.name == "scan.pdf" })
    let frames = try #require(rows.first { $0.name == "gallery_1fps.rgb" })
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try modelShowingTheChecklistPage(
        rows, cache: cache, engine: engine, clock: clock)

    model.setChecklistRow(scan.id, ticked: true)
    model.setChecklistRow(frames.id, ticked: true)
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    #expect(model.result?.items.map(\.id) == [database.id])
    #expect(cache.load()?.items.map(\.id) == [database.id])
    #expect(model.result?.items.map(\.id).contains(scan.id) == false)
    // The card counts as answered all the same, so the deck does not come back to it: the
    // user made a decision about this page and it was carried out.
    #expect(model.currentProjectCard == nil)
    // And the ticks are forgotten with the scan they were about — see `AppModel.setResult`.
    #expect(model.tickedChecklistIDs.isEmpty)
}

/// "Select all", then "Select none". One control, whose word and whose effect travel together.
///
/// With every box clear — which is how the page is dealt — the button is dead and says what to
/// do, and `cleanCurrentProject` refuses on its own account too: the guard against an empty
/// list is in the model, not only in whatever the window happens to have disabled.
@MainActor
@Test func selectAllFillsThePageAndSelectNoneEmptiesItAgain() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = largeFilePage()
    let engine = FakeEngine()
    let clock = MovableClock()
    let model = try modelShowingTheChecklistPage(
        rows, cache: cache, engine: engine, clock: clock)
    // The page is dealt with nothing ticked, so the move on offer is the way to the other
    // extreme — and a press before anything is chosen is refused.
    let empty = try #require(model.currentProjectCard)
    #expect(empty.checklistSelectAll?.title == "Select all")
    #expect(empty.primaryActionTitle == "Tick the files to move to the Trash")
    #expect(empty.isPrimaryActionEnabled == false)
    #expect(empty.folderCountText == "0 of 3 files")
    #expect(model.cleanCurrentProject() == false)
    #expect(await engine.log.cleans.isEmpty)

    model.setAllChecklistRows(ticked: true)

    #expect(model.tickedChecklistIDs == Set(rows.map(\.id)))
    let full = try #require(model.currentProjectCard)
    #expect(full.primaryActionTitle == "Move 2.7 GB to Trash")
    #expect(full.isPrimaryActionEnabled)
    #expect(full.folderCountText == "3 of 3 files")
    #expect(full.checklistSelectAll?.title == "Select none")

    model.setAllChecklistRows(ticked: false)

    #expect(model.tickedChecklistIDs.isEmpty)
    let cleared = try #require(model.currentProjectCard)
    #expect(cleared.primaryActionTitle == "Tick the files to move to the Trash")
    #expect(cleared.isPrimaryActionEnabled == false)
    #expect(cleared.checklistSelectAll?.title == "Select all")
}

/// "Select all" and then Clean up: **every row, in display order**, and nothing added by the
/// journey there.
///
/// The other end of `theChecklistPageHandsTheEngineExactlyWhatIsTicked`. Between them they
/// pin all three states a press can be made in — none ticked, some ticked, all ticked — and
/// the FakeEngine's own record is what says the order was the order the rows are drawn in,
/// which is what makes the drain animation the real progress.
@MainActor
@Test func selectAllThenCleanHandsTheEngineEveryRowInDisplayOrder() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = largeFilePage()
    let database = try #require(rows.first { $0.name == "cards.db" })
    let scan = try #require(rows.first { $0.name == "scan.pdf" })
    let frames = try #require(rows.first { $0.name == "gallery_1fps.rgb" })
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    let clock = MovableClock()
    let model = try modelShowingTheChecklistPage(
        rows, cache: cache, engine: engine, clock: clock)

    model.setAllChecklistRows(ticked: true)
    let full = try #require(model.currentProjectCard)
    // Biggest first, which is the order the page draws and the order the engine will work in.
    #expect(full.items.map(\.id) == [scan.id, database.id, frames.id])
    #expect(full.runItemCount == 3)
    #expect(full.totalHeadline.number == "2.7")
    #expect(full.totalHeadline.outOf == "of 2.7 GB")

    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))

    #expect(await engine.log.cleans == [[scan.id, database.id, frames.id]])
    #expect(model.deckSessionBytes == 2_724_000_000)
    // Nothing left to come back to, and nothing left in the scan.
    #expect(model.result?.items.isEmpty == true)
}

/// **The ticks are forgotten when a scan replaces the rows.**
///
/// The rule this codebase has always had about ticks, and the opposite of the one about skips:
/// a skip is "not this project, not now", which a background scan arriving unasked does not
/// change, while a tick is a judgement about one measurement. The new scan's rows are
/// different rows — a file may have grown, moved or gone — so carrying a tick across would
/// leave it naming identifiers the page no longer has, while a file the user has never looked
/// at could arrive already ticked.
@MainActor
@Test func aFreshScanRebuildsTheBoxesRatherThanKeepingThem() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = largeFilePage()
    let database = try #require(rows.first { $0.name == "cards.db" })
    let clock = MovableClock()
    let model = try modelShowingTheChecklistPage(
        rows, cache: cache, engine: FakeEngine(result: makeResult(rows)),
        clock: clock)

    model.setChecklistRow(database.id, ticked: true)
    #expect(model.tickedChecklistIDs == [database.id])

    #expect(model.startScan())
    #expect(await waitUntilIdle(model))

    #expect(model.tickedChecklistIDs.isEmpty)
    let page = try #require(model.currentProjectCard)
    #expect(page.isChecklist)
    #expect(page.folders.map(\.isTicked) == [false, false, false])
    #expect(page.primaryActionTitle == "Tick the files to move to the Trash")
    #expect(page.items.isEmpty)
}

/// **A box cannot be changed while the run is going.**
///
/// Clean up has already handed the engine the list the boxes produced. A box changed after
/// that would leave the card counting rows the run is not touching — and the bars drain
/// against `ProjectCardFolder.runIndex`, a position in the list that went, so a row moving in
/// or out of it mid-run is a row striking itself through for somebody else's progress.
@MainActor
@Test func theBoxesAreFrozenWhileTheRunIsGoing() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = largeFilePage()
    let database = try #require(rows.first { $0.name == "cards.db" })
    let scan = try #require(rows.first { $0.name == "scan.pdf" })
    var engine = FakeEngine()
    engine.spinsUntilCancelled = true
    let clock = MovableClock()
    let model = try modelShowingTheChecklistPage(
        rows, cache: cache, engine: engine, clock: clock)

    // One row ticked, and that is the run's list from the moment Clean up is pressed.
    model.setChecklistRow(scan.id, ticked: true)
    #expect(model.cleanCurrentProject())

    model.setChecklistRow(database.id, ticked: true)
    model.setChecklistRow(scan.id, ticked: false)
    model.setAllChecklistRows(ticked: true)
    #expect(model.tickedChecklistIDs == [scan.id])

    model.cancel()
    #expect(await waitUntilIdle(model))
}

/// Only a row of the page on screen, and only while there is one.
///
/// The set is what `ProjectCard.applyingTicks` builds the engine's list from, so an identifier
/// that could get in from anywhere else would be able to put a row into a run the user never
/// asked for, off a card they are not even looking at.
@MainActor
@Test func onlyARowOfThePageOnScreenCanBeTicked() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let cacheRow = xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000)
    let rows = largeFilePage() + [cacheRow]
    let clock = MovableClock()
    // The cache card is on screen, not the page: nothing here has a box at all.
    let model = try makeDeckModel(rows, cache: cache, engine: FakeEngine(), clock: clock.read)
    #expect(model.currentProjectCard?.isChecklist == false)

    model.setChecklistRow(cacheRow.id, ticked: true)
    model.setAllChecklistRows(ticked: true)
    #expect(model.tickedChecklistIDs.isEmpty)

    // Now the page, and a row of the card that is no longer on screen still cannot be
    // ticked — nor can an identifier nothing on the page carries.
    model.skipCurrentProject()
    handPauses(clock)
    #expect(model.cleanCurrentProject())              // "Look through them"
    handPauses(clock)
    #expect(model.currentProjectCard?.isChecklist == true)

    model.setChecklistRow(cacheRow.id, ticked: true)
    model.setChecklistRow("big.largeFiles|/Users/test/nothing-here", ticked: true)
    #expect(model.tickedChecklistIDs.isEmpty)
    #expect(model.currentProjectCard?.folderCountText == "0 of 3 files")
}

/// **A box does not rebuild the deck, and it does not move the skyline.**
///
/// Both halves are decisions the plan asked for. Building the deck walks every row of a scan,
/// and a box changes what one card shows without the scan changing at all — so the memo is
/// left alone and `ProjectCard.applyingTicks` derives the page from it. A slot, on the other
/// hand, remembers what the card is **holding**: the bar in the strip is how big this page is,
/// not how much of it the user has ticked so far, and a strip that grew as boxes were ticked
/// would make the deck look as though the page were getting bigger.
@MainActor
@Test func aBoxChangesNeitherTheHeldDeckNorTheSkyline() throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = largeFilePage()
    let database = try #require(rows.first { $0.name == "cards.db" })
    let clock = MovableClock()
    let model = try modelShowingTheChecklistPage(
        rows, cache: cache, engine: FakeEngine(), clock: clock)
    let builds = model.deckBuildCount
    #expect(builds == 1)

    model.setAllChecklistRows(ticked: true)
    model.setChecklistRow(database.id, ticked: false)

    // A body pass over a page whose boxes have moved twice, and the deck was built once.
    _ = model.projectDeck
    _ = model.sessionCards
    _ = model.currentProjectCard
    _ = model.deckSlots
    _ = model.deckSummary
    #expect(model.deckBuildCount == builds)

    #expect(model.currentProjectCard?.folderCountText == "2 of 3 files")
    // The slot — and so the bar over the card — is the whole page either way, as is the
    // second figure in the headline.
    #expect(model.deckSlots.map(\.totalBytes) == [2_724_000_000])
    #expect(model.deckSlots.map(\.isBigThing) == [true])
    #expect(model.currentProjectCard?.totalHeadline.outOf == "of 2.7 GB")
    #expect(model.deckSummary?.positionText == "1 of 1")
}

// MARK: - where a card a later scan has found belongs

/// **Finding 2. A newly found card that comes back on its own is dealt before the big things;
/// only a new big thing goes on the end.**
///
/// Appending everything is what the deck used to do, and it put a card like `fresh` — blue,
/// Return live, "Clean up 20.0 GB" — into the half the interstitial has just promised is the
/// user's own and click-only. It happens on an ordinary launch: the window opens on the cached
/// scan, Skip keeps working through the 51-second launch scan, and whatever that scan has
/// newly found lands in an order a skip has already fixed.
@MainActor
@Test func aNewlyFoundCardIsDealtOnItsOwnSideOfTheInterstitial() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let fresh = folderRow(project: "fresh", folder: "build", sizeBytes: 20_000_000_000)
    // Bigger than the `Xcode` download already in the deck, so an order that sorted the
    // newcomer in by size would put it in front of it. It is appended instead, which is what
    // keeps every card already answered where it was.
    let docker = downloadRow(name: "Docker.dmg", sizeBytes: 9_000_000_000)
    let model = try makeDeckModel(
        twoHalves(), cache: cache,
        engine: FakeEngine(result: makeResult(twoHalves() + [fresh, docker])))

    model.skipCurrentProject()          // the cache card, which fixes the order
    #expect(model.currentProjectCard?.isInterstitial == true)

    #expect(model.startScan())
    #expect(await waitUntilIdle(model))

    #expect(model.sessionCards.map(\.name) == [
        "uv",
        // In front of the card that says the promise changes, where it belongs.
        "fresh",
        ProjectDeckText.interstitialHeadline,
        "lmstudio-community/Qwen3-30B-GGUF", "Xcode_26.1_beta.xip",
        // And the new big thing on the end, behind the 7 GB card it is bigger than.
        "Docker.dmg",
    ])
    #expect(model.deckSlots.map(\.isBigThing) == [false, false, true, true, true])
    // The card the user is now being asked about is on the regenerable side of the deck, so
    // it answers to Return like the cards around it.
    #expect(model.currentProjectCard?.name == "fresh")
    #expect(model.currentProjectCard?.answersToReturn == true)
    #expect(model.deckSummary?.positionText == "2 of 5")
}

/// A deck with no big things in it puts every newcomer on the end, exactly as before: there is
/// no second half for one to fall into.
@MainActor
@Test func withNoBigThingsANewcomerStillWaitsAtTheEnd() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let newcomer = folderRow(project: "fresh", folder: "build", sizeBytes: 20_000_000_000)
    let model = try makeDeckModel(
        threeProjects(), cache: cache,
        engine: FakeEngine(result: makeResult(threeProjects() + [newcomer])))

    model.skipCurrentProject()          // site, the biggest
    #expect(model.startScan())
    #expect(await waitUntilIdle(model))

    #expect(model.sessionCards.map(\.name) == ["site", "tool", "game", "fresh"])
    #expect(model.deckSummary?.positionText == "2 of 4")
}

// MARK: - the key that started the clean cannot dismiss what it left behind

/// **Finding 1.** "Next project" is the window's default action, so a held Return reached it
/// on the next key repeat — about 33 ms after the run ended — and the only report this app
/// ever makes of a folder it could not remove was on screen for a single frame, over a folder
/// still sitting on the disk and still inside the total the user was promised.
///
/// The settle window `finishCardRun` opens is what stands in the way now, timed exactly as
/// Clean up's is. The window also swallows the repeats themselves — `DeckKeyboard` — and the
/// two are deliberate belt and braces; this is the half a test can read.
@MainActor
@Test func theProblemsCardCannotBeDismissedByTheKeyThatStartedTheClean() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = threeProjects()
    let pods = try #require(rows.first { $0.name == "ios/Pods" })
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    engine.refusedItemIDs = [pods.id]
    let clock = MovableClock()
    let model = try makeDeckModel(rows, cache: cache, engine: engine, clock: clock.read)
    model.skipCurrentProject()          // site
    model.skipCurrentProject()          // tool
    handPauses(clock)

    #expect(model.cleanCurrentProject())              // game, whose Pods are refused
    #expect(await waitUntilIdle(model))
    let awaiting = try #require(model.cardAwaitingAcknowledgement)
    #expect(awaiting.problems == ["ios/Pods: refused: the guard said no"])

    // The key repeat, arriving in the same instant the run ended.
    model.acknowledgeProblems()
    #expect(model.cardAwaitingAcknowledgement?.problems == awaiting.problems)
    // Still there a moment short of the window.
    clock.advance(by: AppModel.cardSettleSeconds - 0.01)
    model.acknowledgeProblems()
    #expect(model.cardAwaitingAcknowledgement?.problems == awaiting.problems)
    #expect(model.currentProjectCard?.id == awaiting.card.id)

    clock.advance(by: 0.01)
    model.acknowledgeProblems()

    #expect(model.cardAwaitingAcknowledgement?.problems == nil)
    #expect(model.currentProjectCard == nil)
}

/// And frozen again once the run is over and the page is being held for its problems.
///
/// The rows are still on screen and still carry boxes — the card is a value the run froze —
/// but it has stopped being a question: what it is now showing is which of those files could
/// not be moved, and the only answer it takes is Next.
@MainActor
@Test func theBoxesAreFrozenWhileThePageIsShowingItsProblems() async throws {
    let temp = TempDir()
    let cache = ScanCache(directory: temp.url)
    let rows = largeFilePage()
    let scan = try #require(rows.first { $0.name == "scan.pdf" })
    let frames = try #require(rows.first { $0.name == "gallery_1fps.rgb" })
    var engine = FakeEngine()
    engine.recordsWhatItIsHanded = true
    engine.refusedItemIDs = [scan.id]
    let clock = MovableClock()
    let model = try modelShowingTheChecklistPage(
        rows, cache: cache, engine: engine, clock: clock)

    model.setAllChecklistRows(ticked: true)
    #expect(model.cleanCurrentProject())
    #expect(await waitUntilIdle(model))
    let awaiting = try #require(model.cardAwaitingAcknowledgement)
    #expect(awaiting.problems == ["scan.pdf: refused: the guard said no"])
    #expect(awaiting.card.isChecklist)

    // The run's prune replaced the scan, so the ticks are already forgotten with it — and
    // nothing said here can put one back while the card is being held.
    #expect(model.tickedChecklistIDs.isEmpty)
    model.setChecklistRow(frames.id, ticked: true)
    model.setChecklistRow(scan.id, ticked: true)
    model.setAllChecklistRows(ticked: true)

    #expect(model.tickedChecklistIDs.isEmpty)
    // The card the run froze is still the card on screen, still reading what went.
    #expect(model.currentProjectCard?.folderCountText == "3 of 3 files")
    // **Looking is still allowed.** The boxes are frozen and the reveal button is not: it
    // changes nothing, and "which of these could not be moved?" is exactly the moment the
    // user wants to go and look.
    #expect(awaiting.card.folders.allSatisfy { $0.reveal != nil })
    // The refused file is still in the scan, and the two that went are not.
    #expect(model.result?.items.map(\.id) == [scan.id])
}
