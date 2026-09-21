import Testing
import Foundation
@testable import DevCleanerUI
import CleanerCore

/// `moveToTrash` defaults to the shipping default rather than being left out, because the
/// deck now writes each card's promise line and cannot be built without knowing the mode.
private func deck(
    _ items: [CleanupItem], now moment: Date = now, moveToTrash: Bool = true
) -> ProjectDeck {
    ProjectDeck(
        result: makeResult(items), home: testHome, now: moment, moveToTrash: moveToTrash)
}

// MARK: - grouping

@Test func everyFolderOfOneProjectLandsOnOneCard() throws {
    let built = deck([
        folderRow(project: "game", folder: ".build", sizeBytes: 946_000_000),
        folderRow(project: "game", folder: ".build-cows", sizeBytes: 120_000_000),
        folderRow(project: "game", folder: "ios/Pods", sizeBytes: 400_000_000),
    ])

    #expect(built.cards.count == 1)
    let card = try #require(built.cards.first)
    #expect(card.id == "/Users/test/dev/game")
    #expect(card.name == "game")
    #expect(card.pathText == "~/dev/game")
    #expect(card.folders.map(\.name) == [".build", "ios/Pods", ".build-cows"])
    #expect(card.totalBytes == 1_466_000_000)
    #expect(card.totalText == "1.5 GB")
}

/// Grouped by **directory**, never by the project's name. Two projects called
/// `shared-project-name` sit under one `~/dev` on a real dev machine, and a deck grouped
/// by name would put one project's folders on the other's card — under its path, inside
/// its total, behind a button that deletes.
@Test func twoProjectsSharingANameStayTwoCards() throws {
    let built = deck([
        folderRow(project: "workspace-one/shared", folder: "build",
                  sizeBytes: 3_000_000_000, projectName: "shared"),
        folderRow(project: "workspace-two/shared", folder: "build",
                  sizeBytes: 1_000_000_000, projectName: "shared"),
    ])

    #expect(built.cards.map(\.id) == [
        "/Users/test/dev/workspace-one/shared",
        "/Users/test/dev/workspace-two/shared",
    ])
    #expect(built.cards.allSatisfy { $0.name == "shared" })
    #expect(try #require(built.cards.first).pathText == "~/dev/workspace-one/shared")
}

/// A row whose path does not end in `/<name>` is dropped, not guessed at. Nothing this
/// scanner builds can be shaped that way, which is exactly why the check is worth having:
/// if one ever were, the card would be naming a directory nothing measured, and the button
/// under it deletes.
@Test func aRowWhosePathDoesNotEndInItsNameIsDropped() {
    let honest = folderRow(project: "game", folder: "build", sizeBytes: 900_000_000)
    let mismatched = CleanupItem(
        id: "projects.buildOutput|/Users/test/dev/other/somewhere-else",
        scannerID: "projects.buildOutput", group: .projects,
        name: "build", detail: "other", sizeBytes: 5_000_000_000,
        lastUsed: nil, risk: .safe, protection: nil,
        method: .removePath("/Users/test/dev/other/somewhere-else"))

    let built = deck([honest, mismatched])

    #expect(built.cards.map(\.id) == ["/Users/test/dev/game"])
    #expect(built.cards.flatMap(\.items).map(\.id) == [honest.id])
}

/// Another scanner's rows get a card of their **own**, never a place on a project's.
///
/// This used to assert they got no card at all, and the change is the point of the deck
/// covering everything — but the half that has to stay true is the grouping. A shared cache
/// belongs to a tool, not to a project, and a deck that swept these onto the card in front
/// of it would offer to delete `~/Library/Caches` under a project's name and inside its
/// total.
@Test func rowsFromEveryOtherScannerGetACardOfTheirOwn() throws {
    let built = deck([
        folderRow(project: "game", folder: "build", sizeBytes: 900_000_000),
        toolRow(scanner: "xcode.derivedData", name: "Runner",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner",
                sizeBytes: 40_000_000_000),
        toolRow(scanner: "flutter.pubCache", group: .flutterAndDart, name: "hosted",
                relativePath: ".pub-cache/hosted", sizeBytes: 9_000_000_000),
    ])

    // One card each, biggest first, and the project's card holds only its own folder.
    #expect(built.cards.map(\.id)
        == ["xcode.derivedData", "flutter.pubCache", "/Users/test/dev/game"])
    let project = try #require(built.cards.first { $0.id == "/Users/test/dev/game" })
    #expect(project.items.map(\.name) == ["build"])
    #expect(project.totalBytes == 900_000_000)
}

/// A folder worth nothing stays off the card, which is also how every **unmeasured** row
/// stays off it: `ScanHelpers.measured` answers zero for a folder `du` could not size, so
/// the size rule subsumes that case without the deck having to ask about it.
///
/// A card built from one would print a folder at "0 KB", add nothing to the total, and hand
/// the engine a deletion whose cost the user was never shown — and the bar beside it would
/// be empty on a row the Clean button is going to act on.
@Test func aFolderWorthNothingStaysOffTheCardEvenThoughItIsDeletable() throws {
    let built = deck([
        folderRow(project: "game", folder: "build", sizeBytes: 900_000_000),
        folderRow(project: "game", folder: ".build", sizeBytes: 0, startsUnticked: true),
    ])

    let card = try #require(built.cards.first)
    #expect(card.folders.map(\.name) == ["build"])
    #expect(card.items.map(\.name) == ["build"])
    #expect(card.totalBytes == 900_000_000)
}

/// The same rule over an **active** project, where the row carries a reason as well.
///
/// Two kinds of unticked row meet here and they must not be confused: `.dart_tool` could
/// not be measured and is worth nothing to offer, while `.build` is 946 MB the user can
/// have back. Both start unticked and both carry the reason; only the measured one is on
/// the card, and the pair is told apart by the size rather than by the flag.
@Test func anUnmeasuredFolderOfAnActiveProjectStaysOffTheCardButItsSiblingDoesNot() throws {
    let built = deck([
        folderRow(project: "game", folder: ".build", sizeBytes: 946_000_000,
                  untickedReason: .recentActivity(days: 14)),
        folderRow(project: "game", folder: ".dart_tool", sizeBytes: 0,
                  untickedReason: .recentActivity(days: 14)),
    ])

    let card = try #require(built.cards.first)
    #expect(card.folders.map(\.name) == [".build"])
    #expect(card.totalBytes == 946_000_000)
}

// MARK: - projects the user is working in

/// The reason the deck exists at all on this Mac.
///
/// A read-only scan found **every** project holding build output marked "changed in the
/// last 14 days" — so while recent activity meant "never offered", the deck was empty and
/// the user's own example of a card, Sample Game, was one of the projects it could not show.
/// Those folders now arrive offered and unticked, and the deck takes them.
///
/// It does not break the house tick rule, and the difference is what "ticked" guards
/// against. The rule exists so that a **blind** clean — the CLI's `cleanDefault`, and the
/// amount the menu bar glances at — cannot take a folder the user did not look at; both still
/// derive their list from `selectedByDefault` and still leave every one of these behind.
/// Pressing
/// Clean up on a card that names this project, lists these folders and prints this total
/// **is** the user asking for exactly them.
@Test func anActiveProjectsFoldersGetACardOfTheirOwn() throws {
    let built = deck([
        folderRow(project: "Sample Game", folder: ".build", sizeBytes: 946_000_000,
                  untickedReason: .recentActivity(days: 14)),
        folderRow(project: "Sample Game", folder: ".build-cows", sizeBytes: 2_400_000_000,
                  untickedReason: .recentActivity(days: 14)),
    ])

    #expect(built.cards.count == 1)
    let card = try #require(built.cards.first)
    #expect(card.id == "/Users/test/dev/Sample Game")
    #expect(card.folders.map(\.name) == [".build-cows", ".build"])
    #expect(card.totalBytes == 3_346_000_000)
    // The card's items are what Clean up hands the engine, and they are the unticked rows.
    #expect(card.items.allSatisfy { !$0.selectedByDefault })
    #expect(card.items.map(\.id) == card.folders.map(\.id))
}

/// The card's name is the **project directory's** last component, never `detail` — which
/// now carries the reason as well and would print "Sample Game · changed in the last 14
/// days" as a 26-point heading.
@Test func aCardTakesItsNameFromTheProjectDirectoryAndNotFromTheRowsDetail() throws {
    let built = deck([
        folderRow(project: "Sample Game", folder: ".build", sizeBytes: 946_000_000,
                  untickedReason: .recentActivity(days: 14)),
    ])

    let card = try #require(built.cards.first)
    #expect(card.name == "Sample Game")
    #expect(card.pathText == "~/dev/Sample Game")
    // Rule 4: the fixture's detail really does carry the reason, so a card reading it would
    // fail here rather than passing on a plain fixture.
    #expect(card.items.first?.detail == "Sample Game · changed in the last 14 days")
}

/// A nested project keeps the last component of its own directory, not the whole path.
@Test func aNestedProjectsCardIsNamedAfterItsOwnFolder() throws {
    let built = deck([
        folderRow(project: "workspace/client-app", folder: "build",
                  sizeBytes: 900_000_000, projectName: "client-app"),
    ])

    #expect(built.cards.map(\.name) == ["client-app"])
}

/// The one line that makes the offer honest, and the whole reason the folders are offered
/// rather than withheld.
@Test func theCardsCautionComesFromTheReasonItsRowsCarry() throws {
    let built = deck([
        folderRow(project: "Sample Game", folder: ".build", sizeBytes: 946_000_000,
                  untickedReason: .recentActivity(days: 14)),
        folderRow(project: "stale", folder: "build", sizeBytes: 2_000_000_000),
    ])

    #expect(try #require(built.cards.first { $0.name == "Sample Game" }).cautionLines
        == ["You changed this in the last 14 days. Its next build starts from scratch."])
    // A project nobody has touched needs no caution, and a blank line would be a piece of
    // window that appears and disappears between cards.
    #expect(try #require(built.cards.first { $0.name == "stale" }).cautionLines.isEmpty)
}

/// The days come from the reason, which came from `Settings.activeThresholdDays`, so a user
/// who set the window to 30 reads 30.
@Test func theCautionNamesTheNumberOfDaysTheSettingsChose() {
    #expect(ProjectDeckText.caution(for: .recentActivity(days: 30))
        == "You changed this in the last 30 days. Its next build starts from scratch.")
    // Unreachable today — a pin is withheld and never reaches a card — but the reason's own
    // words are the only text guaranteed not to lie about whatever arrives next.
    #expect(ProjectDeckText.caution(for: .pinnedProject)
        == "You're using this project — pinned. Its next build starts from scratch.")
}

/// Active projects are **not** pushed to the end of the deck. The deck is ordered by what
/// is worth deciding, and on this Mac the biggest projects are precisely the ones being
/// worked on — sorted to the back they would be behind twenty cards of crumbs.
@Test func anActiveProjectIsDealtBySizeLikeAnyOther() {
    let built = deck([
        folderRow(project: "stale-small", folder: "build", sizeBytes: 100_000_000),
        folderRow(project: "active-big", folder: ".build", sizeBytes: 12_000_000_000,
                  untickedReason: .recentActivity(days: 14)),
        folderRow(project: "stale-mid", folder: "build", sizeBytes: 2_000_000_000),
    ])

    #expect(built.cards.map(\.name) == ["active-big", "stale-mid", "stale-small"])
}

/// A card whose folders are partly held back takes the caution from the rows that carry
/// one. The mix is reachable through a cached scan: a project can be active while one of
/// its folders could not be sized.
@Test func aCardWithSomeCautionedRowsStillShowsTheCaution() throws {
    let built = deck([
        folderRow(project: "app", folder: "build", sizeBytes: 900_000_000),
        folderRow(project: "app", folder: ".build", sizeBytes: 400_000_000,
                  untickedReason: .recentActivity(days: 21)),
    ])

    let card = try #require(built.cards.first)
    #expect(card.folders.count == 2)
    #expect(card.cautionLines
        == ["You changed this in the last 21 days. Its next build starts from scratch."])
}

/// A device row cannot be on a card: there is no path to group it under, and `simctl
/// delete` has no Trash whatever the settings say — which is the opposite of everything
/// the card promises.
@Test func aRowWithNoPathIsNotOnACard() {
    let device = CleanupItem(
        id: "projects.buildOutput|device", scannerID: "projects.buildOutput",
        group: .projects, name: "build", detail: "game", sizeBytes: 7_000_000_000,
        lastUsed: nil, risk: .safe, protection: nil, method: .deleteSimulator(udid: "AAA"))

    #expect(deck([device]).cards.isEmpty)
}

// MARK: - order

@Test func theBiggestProjectIsDealtFirstAndTiesGoByPath() {
    let built = deck([
        folderRow(project: "small", folder: "build", sizeBytes: 100_000_000),
        folderRow(project: "huge", folder: "build", sizeBytes: 12_000_000_000),
        folderRow(project: "zebra", folder: "build", sizeBytes: 2_000_000_000),
        folderRow(project: "alpha", folder: "build", sizeBytes: 2_000_000_000),
    ])

    #expect(built.cards.map(\.name) == ["huge", "alpha", "zebra", "small"])
}

/// `items` is the list Clean hands the engine, and it has to be in the same order as
/// `folders`: the executor works through it one at a time and reports per item, so the
/// view drains row *i* when `completed > i`. Two different orders would drain the wrong
/// rows, which is worse than no animation — it would say a folder is gone while it is
/// still there.
@Test func theItemsHandedToTheEngineAreInTheSameOrderAsTheFoldersOnTheCard() throws {
    let built = deck([
        folderRow(project: "game", folder: "ios/Pods", sizeBytes: 400_000_000),
        folderRow(project: "game", folder: ".build", sizeBytes: 946_000_000),
        folderRow(project: "game", folder: ".build-cows", sizeBytes: 120_000_000),
    ])

    let card = try #require(built.cards.first)
    #expect(card.items.map(\.id) == card.folders.map(\.id))
    #expect(card.items.count == card.folders.count)
    #expect(card.items.map(\.name) == [".build", "ios/Pods", ".build-cows"])
}

/// Same-sized folders are ordered by identifier, so the card is dealt the same way on
/// every scan of the same machine — and `items` keeps step with it.
@Test func foldersOfEqualSizeAreOrderedByIdentifier() throws {
    let built = deck([
        folderRow(project: "game", folder: "zeta", sizeBytes: 500_000_000),
        folderRow(project: "game", folder: "alpha", sizeBytes: 500_000_000),
    ])

    let card = try #require(built.cards.first)
    #expect(card.folders.map(\.name) == ["alpha", "zeta"])
    #expect(card.items.map(\.id) == card.folders.map(\.id))
}

// MARK: - bars

/// Against the biggest folder on **this** card, never across the deck. Only one card is on
/// screen, so there is no cross-card comparison for the eye to make; scaled against the
/// whole deck, a tidy project's rows would all be hairlines because some other project has
/// 12 GB in it.
@Test func aFoldersBarIsAShareOfTheBiggestFolderOnItsOwnCard() throws {
    let built = deck([
        folderRow(project: "game", folder: "build", sizeBytes: 1_000_000_000),
        folderRow(project: "game", folder: ".build", sizeBytes: 250_000_000),
        folderRow(project: "other", folder: "build", sizeBytes: 12_000_000_000),
    ])

    let card = try #require(built.cards.first { $0.name == "game" })
    #expect(card.folders.map(\.fraction) == [1.0, 0.25])
}

/// A machine where `du` measured nothing still produces real rows, all of them 0 bytes.
/// Without the guard every bar is `nan`, which SwiftUI draws at whatever width it likes.
@Test func barsOnACardOfZeroBytedFoldersAreZeroRatherThanNotANumber() {
    #expect(ProjectCardFolder.fraction(0, of: 0) == 0)
    #expect(ProjectCardFolder.fraction(5, of: 0) == 0)
}

// MARK: - the floor

@Test func aProjectUnderTheFloorGetsALineInsteadOfACard() throws {
    let built = deck([
        folderRow(project: "big", folder: "build", sizeBytes: 3_000_000_000),
        folderRow(project: "tiny", folder: ".dart_tool", sizeBytes: 12_000_000),
        folderRow(project: "also-tiny", folder: ".dart_tool", sizeBytes: 30_000_000),
    ])

    #expect(built.cards.map(\.name) == ["big"])
    #expect(built.smallThingsText == "2 small things under 50 MB were not shown · 42 MB")
}

/// The floor is a total, not a per-folder rule: three 20 MB folders in one project are
/// 60 MB the user can have back in one click.
@Test func aProjectOfSmallFoldersAddingUpPastTheFloorStillGetsACard() {
    let built = deck([
        folderRow(project: "app", folder: "build", sizeBytes: 20_000_000),
        folderRow(project: "app", folder: ".dart_tool", sizeBytes: 20_000_000),
        folderRow(project: "app", folder: ".symlinks", sizeBytes: 20_000_000),
    ])

    #expect(built.cards.map(\.name) == ["app"])
    #expect(built.smallThingsText == nil)
}

@Test func aProjectExactlyOnTheFloorGetsACard() {
    let built = deck([
        folderRow(project: "app", folder: "build", sizeBytes: ProjectDeck.minimumCardBytes),
    ])

    #expect(built.cards.map(\.name) == ["app"])
    #expect(built.smallThingsText == nil)
}

@Test func oneSmallProjectIsCountedInTheSingular() {
    let built = deck([folderRow(project: "tiny", folder: "build", sizeBytes: 9_000_000)])

    #expect(built.cards.isEmpty)
    #expect(built.smallThingsText == "1 small thing under 50 MB was not shown · 9 MB")
}

// MARK: - protected projects

/// A protected project is never in the deck: the tool will not touch it, so a Clean button
/// over it would be an offer the engine refuses. It still gets a line, because dropping it
/// answers "where did my 40 GB go?" with silence.
///
/// A **pin** is the only reason that reaches this today — recent activity now produces
/// offered-unticked rows and a card — so the line says so. Naming the reason is worth a
/// sentence of its own: "left alone" with nothing after it invites the question, and the
/// answer ("because you pinned it") is also where the user goes to change their mind.
@Test func aPinnedProjectGetsALineAndNeverACard() {
    let built = deck([
        folderRow(project: "stale", folder: "build", sizeBytes: 2_000_000_000),
        protectedProjectRow(project: "work", sizeBytes: 8_000_000_000),
        protectedProjectRow(project: "spike", sizeBytes: 1_200_000_000),
    ])

    #expect(built.cards.map(\.name) == ["stale"])
    #expect(built.keptProjectsText == "2 pinned projects were left alone · 9.2 GB")
}

@Test func onePinnedProjectIsCountedInTheSingular() {
    let built = deck([protectedProjectRow(project: "work", sizeBytes: 2_100_000_000)])

    #expect(built.keptProjectsText == "1 pinned project was left alone · 2.1 GB")
}

/// A protected row whose reason is **not** a pin drops the claim rather than guessing.
///
/// Reachable through the cache, not through today's scanner: a `cache.json` written before
/// recent activity started producing offered rows holds protected summary rows carrying
/// `.recentActivity`, and it is read back on the next launch. Calling those "pinned" would
/// be a sentence the settings window contradicts.
@Test func aKeptProjectThatIsNotPinnedIsCountedWithoutNamingAReason() {
    let built = deck([
        protectedProjectRow(project: "work", sizeBytes: 8_000_000_000),
        protectedProjectRow(project: "cached", sizeBytes: 1_200_000_000,
                            reason: .recentActivity(days: 14)),
    ])

    #expect(built.keptProjectsText == "2 projects were left alone · 9.2 GB")
}

@Test func aDeckWithNothingKeptAndNothingSmallSaysNeither() {
    let built = deck([folderRow(project: "app", folder: "build", sizeBytes: 900_000_000)])

    #expect(built.keptProjectsText == nil)
    #expect(built.smallThingsText == nil)
}

@Test func thereIsNoDeckBeforeAnythingHasBeenScanned() {
    let built = deck([])

    #expect(built.cards.isEmpty)
    #expect(built.keptProjectsText == nil)
    #expect(built.smallThingsText == nil)
}

// MARK: - how each folder comes back

/// Every name the scanner's fixed list can produce, plus the shapes it invents. A hint is
/// the only thing on the row that tells the user what saying yes costs them, so a wrong
/// one is worse than none.
@Test func everyFolderNameGetsTheRightRestoreHint() {
    for name in ["build", ".build", ".build-rel", ".build-cows", "DerivedData",
                 "ios/build", "android/build", "app/build", "android/.gradle", ".gradle",
                 "target", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache",
                 ".expo"] {
        #expect(ProjectDeckText.restoreHint(forFolderNamed: name) == "Next build remakes it",
                "\(name)")
    }
    for name in [".dart_tool", ".symlinks"] {
        #expect(ProjectDeckText.restoreHint(forFolderNamed: name)
            == "flutter pub get remakes it", "\(name)")
    }
    for name in ["Pods", "ios/Pods", "macos/Pods"] {
        #expect(ProjectDeckText.restoreHint(forFolderNamed: name)
            == "pod install downloads it again", "\(name)")
    }
    #expect(ProjectDeckText.restoreHint(forFolderNamed: "node_modules")
        == "npm install downloads it again")
}

/// A worktree row names the worktree, because that is the fact that decides: a user has
/// finished with `security-hardening` and is still working in `feature-sync`, and "Next
/// build remakes it" says nothing about which is which.
@Test func aWorktreeRowNamesTheWorktreeItBelongsTo() {
    #expect(ProjectDeckText.restoreHint(
        forFolderNamed: ".claude/worktrees/feature-sync/build")
        == "Build output of worktree feature-sync")
    #expect(ProjectDeckText.restoreHint(
        forFolderNamed: ".claude/worktrees/security-hardening/.build")
        == "Build output of worktree security-hardening")
}

/// Rule 4 for the worktree rule: names that begin the same way and are not a worktree's
/// build output fall through to the ordinary sentence rather than naming an empty worktree.
@Test func aNameThatMerelyStartsLikeAWorktreePathIsNotReadAsOne() {
    #expect(ProjectDeckText.worktreeName(in: ".claude/worktrees") == nil)
    #expect(ProjectDeckText.worktreeName(in: ".claude/worktrees/") == nil)
    #expect(ProjectDeckText.worktreeName(in: ".claude/worktrees//build") == nil)
    #expect(ProjectDeckText.worktreeName(in: ".claudex/worktrees/a/build") == nil)
    #expect(ProjectDeckText.restoreHint(forFolderNamed: ".claude/worktrees")
        == "Next build remakes it")
}

/// An unknown name is build output, which is what the scanner's list is made of. The
/// warning that actually matters is `needsDownload`, and it comes from the scanner's own
/// risk rather than from the sentence table.
@Test func aFolderNameTheHintTableHasNeverSeenIsTreatedAsBuildOutput() {
    #expect(ProjectDeckText.restoreHint(forFolderNamed: "out")
        == "Next build remakes it")
}

@Test func onlyTheFoldersThatNeedTheNetworkAreMarkedAsADownload() throws {
    let built = deck([
        folderRow(project: "app", folder: "build", sizeBytes: 900_000_000),
        folderRow(project: "app", folder: "ios/Pods", sizeBytes: 400_000_000,
                  risk: .elevated),
    ])

    let card = try #require(built.cards.first)
    #expect(try #require(card.folders.first { $0.name == "ios/Pods" }).needsDownload)
    #expect(!(try #require(card.folders.first { $0.name == "build" }).needsDownload))
}

// MARK: - the sentence under the total

/// A card whose folders are all build output really does rebuild itself, and that is the
/// claim worth making. A card holding `node_modules` does not — the row beside it says
/// "npm install downloads it again" — and a heading claiming otherwise two lines above is
/// how a tool teaches its user to stop reading it.
@Test func theFolderCountSaysRebuildOnlyWhenNothingNeedsTheNetwork() {
    #expect(ProjectDeckText.folderCount(8, needsDownload: false)
        == "in 8 folders that rebuild themselves")
    #expect(ProjectDeckText.folderCount(1, needsDownload: false)
        == "in 1 folder that rebuilds itself")
    #expect(ProjectDeckText.folderCount(4, needsDownload: true)
        == "in 4 folders that come back on their own")
    #expect(ProjectDeckText.folderCount(1, needsDownload: true)
        == "in 1 folder that comes back on its own")
}

@Test func theCardCountsItsOwnFoldersAndNoticesADownloadAmongThem() throws {
    let built = deck([
        folderRow(project: "app", folder: "build", sizeBytes: 900_000_000),
        folderRow(project: "app", folder: "node_modules", sizeBytes: 800_000_000,
                  risk: .elevated),
        folderRow(project: "pkg", folder: ".build", sizeBytes: 900_000_000),
    ])

    #expect(try #require(built.cards.first { $0.name == "app" }).folderCountText
        == "in 2 folders that come back on their own")
    #expect(try #require(built.cards.first { $0.name == "pkg" }).folderCountText
        == "in 1 folder that rebuilds itself")
}

// MARK: - when the project last changed

/// Words, not days. "123d ago" is arithmetic; the question the line answers is "have I
/// finished with this?".
@Test func theAgeOfAProjectIsSaidInWords() {
    func age(days: Double) -> String {
        ProjectDeckText.age(now.addingTimeInterval(-days * 86_400), now: now)
    }
    #expect(age(days: 0) == "today")
    #expect(age(days: 0.5) == "today")
    #expect(age(days: 1) == "yesterday")
    #expect(age(days: 2) == "2 days ago")
    #expect(age(days: 6) == "6 days ago")
    #expect(age(days: 7) == "1 week ago")
    #expect(age(days: 13) == "1 week ago")
    #expect(age(days: 14) == "2 weeks ago")
    #expect(age(days: 29) == "4 weeks ago")
    #expect(age(days: 30) == "1 month ago")
    #expect(age(days: 120) == "4 months ago")
    #expect(age(days: 364) == "12 months ago")
    #expect(age(days: 365) == "1 year ago")
    #expect(age(days: 900) == "2 years ago")
}

/// A clock moved back, or a file stamped ahead, reads as today rather than as a negative
/// count of days.
@Test func aProjectDatedInTheFutureReadsAsToday() {
    #expect(ProjectDeckText.age(now.addingTimeInterval(86_400 * 5), now: now) == "today")
}

/// The newest date among the card's rows, because every row of a project carries the
/// project's own date and a card is about the project.
@Test func theCardTakesTheNewestDateItsRowsCarry() throws {
    let built = deck([
        folderRow(project: "app", folder: "build", sizeBytes: 900_000_000,
                  lastUsed: now.addingTimeInterval(-86_400 * 200)),
        folderRow(project: "app", folder: ".build", sizeBytes: 100_000_000,
                  lastUsed: now.addingTimeInterval(-86_400 * 3)),
    ])

    #expect(try #require(built.cards.first).lastChangedText == "last changed 3 days ago")
}

/// `nil` rather than a guess. "last changed today" is the worst possible substitute for a
/// date the scan does not have: it is the reading that most strongly says do not clean this.
@Test func aCardWithNoDatedRowsSaysNothingAboutWhenItChanged() throws {
    let built = deck([folderRow(project: "app", folder: "build", sizeBytes: 900_000_000)])

    #expect(try #require(built.cards.first).lastChangedText == nil)
}

// MARK: - one card per scanner

/// Xcode's derived data folder names end in 28 letters of hash, and the hash is of no use
/// whatever to the person deciding whether to delete one.
private let runnerHash = "blblggpuoxuymgejdrqraclibwkw"

/// Three derived data rows shaped the way the scanner shapes them: a folder under
/// `~/Library/Developer/Xcode/DerivedData`, named `<workspace>-<hash>`, with the scanner's
/// own sentence about which project it belongs to.
private func derivedDataRows() -> [CleanupItem] {
    [
        toolRow(name: "Runner-\(runnerHash)",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner-\(runnerHash)",
                sizeBytes: 5_000_000_000, detail: "its project folder is gone"),
        toolRow(name: "SampleCards-\(runnerHash)",
                relativePath: "Library/Developer/Xcode/DerivedData/SampleCards-\(runnerHash)",
                sizeBytes: 3_000_000_000, detail: nil),
        toolRow(name: "Notes-\(runnerHash)",
                relativePath: "Library/Developer/Xcode/DerivedData/Notes-\(runnerHash)",
                sizeBytes: 1_100_000_000, detail: "its project folder is gone"),
    ]
}

/// The whole of 1a in one assertion: a scanner with something to clean is **one** card,
/// titled and filed the way `devcleaner scan` titles and files the same rows, listing every
/// row it is offering biggest first, with `items` in step so the view drains the right ones.
@Test func aScannerWithSomethingToCleanGetsOneCardForAllOfIt() throws {
    let built = deck(derivedDataRows())

    #expect(built.cards.count == 1)
    let card = try #require(built.cards.first)
    #expect(card.kind == .tool(scannerID: "xcode.derivedData"))
    // The identity is the scanner, which is what the session's decisions and the skyline
    // are keyed on — and cannot collide with a project's path.
    #expect(card.id == "xcode.derivedData")
    // The scanner's own title and group, out of the registry rather than spelled here.
    #expect(card.name == "Derived data")
    #expect(card.eyebrow == "Xcode & iOS")
    #expect(card.pathText == "~/Library/Developer/Xcode/DerivedData")
    #expect(card.totalBytes == 9_100_000_000)
    #expect(card.totalText == "9.1 GB")
    #expect(card.folderCountText == "in 3 items")
    #expect(card.folders.map(\.sizeBytes) == [5_000_000_000, 3_000_000_000, 1_100_000_000])
    #expect(card.items.map(\.id) == card.folders.map(\.id))
    // Nothing is held back and nothing is dangerous, so the card has no caution and no
    // kept line.
    #expect(card.cautionLines.isEmpty)
    #expect(card.keptText == nil)
}

/// A tool card makes **no claim** that its rows come back on their own, and that silence is
/// the decision: a simulator does not come back at all and a runtime is a multi-gigabyte
/// download. The project sentence stays exactly as it was, because a project's build folders
/// really do rebuild themselves.
@Test func aToolCardCountsItsRowsWithoutPromisingTheyComeBack() {
    #expect(ProjectDeckText.itemCount(16) == "in 16 items")
    #expect(ProjectDeckText.itemCount(1) == "in 1 item")
    #expect(ProjectDeckText.folderCount(8, needsDownload: false)
        == "in 8 folders that rebuild themselves")
}

/// Never one card per `GroupID`. Derived data is remade by the next build and a simulator is
/// destroyed outright with every app installed in it; one card covering both would have one
/// promise line, one button and no way to write either truthfully.
@Test func twoScannersOfOneGroupAreNeverMixedOntoOneCard() throws {
    let built = deck(derivedDataRows() + [
        simulatorRow(name: "iPhone 17 Pro", udid: "AAA", sizeBytes: 12_000_000_000),
        simulatorRow(name: "iPad Air", udid: "BBB", sizeBytes: 9_400_000_000),
    ])

    #expect(built.cards.map(\.id) == ["ios.simulators", "xcode.derivedData"])
    #expect(built.cards.map(\.name) == ["iOS simulators", "Derived data"])
    #expect(built.cards.allSatisfy { $0.eyebrow == "Xcode & iOS" })
    let simulators = try #require(built.cards.first)
    #expect(simulators.folders.map(\.name) == ["iPhone 17 Pro", "iPad Air"])
}

/// The row's hint is the **scanner's** own sentence. It is already honest and already
/// specific to the row — "its project folder is gone" against "kept for app" — and anything
/// this file invented would be a second, vaguer account of the same fact.
@Test func aToolRowsHintIsTheSentenceItsScannerWrote() throws {
    let card = try #require(deck(derivedDataRows()).cards.first)

    #expect(card.folders.map(\.restoreHint)
        == ["its project folder is gone", "", "its project folder is gone"])
}

/// The name a derived data row shows is the part before Xcode's hash.
///
/// `Runner-blblggpuoxuymgejdrqraclibwkw` is most of the width of the row, unpronounceable,
/// and pushes the only part that identifies the project out of sight.
@Test func aDerivedDataRowIsNamedForItsProjectAndNotForXcodesHash() throws {
    let card = try #require(deck(derivedDataRows()).cards.first)

    #expect(card.folders.map(\.name) == ["Runner", "SampleCards", "Notes"])
    // The item handed to the engine keeps the real folder name, because that is what the
    // row's identity and its path are made of.
    #expect(card.items.map(\.name) == [
        "Runner-\(runnerHash)", "SampleCards-\(runnerHash)", "Notes-\(runnerHash)",
    ])
}

/// Only a 28-letter lower-case hash after the last hyphen, with something in front of it.
/// Anything else keeps the whole name: cutting on "the last hyphen" would turn `my-app` into
/// `my`, and a folder a user made by hand is not Xcode's to rename.
@Test func onlyXcodesOwnHashIsTakenOffADerivedDataName() {
    #expect(ProjectDeckText.derivedDataName("Runner-\(runnerHash)") == "Runner")
    #expect(ProjectDeckText.derivedDataName("my-app-\(runnerHash)") == "my-app")
    // No hyphen at all.
    #expect(ProjectDeckText.derivedDataName("ModuleCache") == "ModuleCache")
    // A hyphen, but not a hash: the wrong length, the wrong case, the wrong characters.
    #expect(ProjectDeckText.derivedDataName("my-app") == "my-app")
    #expect(ProjectDeckText.derivedDataName("my-\(runnerHash)x") == "my-\(runnerHash)x")
    #expect(ProjectDeckText.derivedDataName("my-\(runnerHash.uppercased())")
        == "my-\(runnerHash.uppercased())")
    #expect(ProjectDeckText.derivedDataName("my-blblggpuoxuymgejdrqraclibwk9")
        == "my-blblggpuoxuymgejdrqraclibwk9")
    // Nothing in front of the hash, so there would be nothing left to show.
    #expect(ProjectDeckText.derivedDataName("-\(runnerHash)") == "-\(runnerHash)")
    #expect(ProjectDeckText.derivedDataName("") == "")
    // And no other scanner's names are touched.
    let gradle = toolRow(
        scanner: "android.gradle", group: .android, name: "transforms-3",
        relativePath: ".gradle/caches/transforms-3", sizeBytes: 1)
    #expect(ProjectDeckText.rowName(of: gradle) == "transforms-3")
}

/// The location line is the deepest directory that holds every row — the answer to "where
/// is this?" — and `nil` when there is no such place worth printing.
@Test func theLocationLineIsTheDeepestDirectoryEveryRowShares() throws {
    let reporter = ReportText(home: testHome)

    // One directory: derived data's folders are all children of it.
    #expect(ProjectDeck.location(of: derivedDataRows(), reporter: reporter)
        == "~/Library/Developer/Xcode/DerivedData")

    // Two sibling directories: the honest answer is the folder above both, which is still
    // somewhere the user can go and look.
    let deviceSupport = [
        toolRow(scanner: "xcode.deviceSupport", name: "iOS 18.0",
                relativePath: "Library/Developer/Xcode/iOS DeviceSupport/18.0",
                sizeBytes: 20_000_000_000),
        toolRow(scanner: "xcode.deviceSupport", name: "watchOS 11.0",
                relativePath: "Library/Developer/Xcode/watchOS DeviceSupport/11.0",
                sizeBytes: 7_000_000_000),
    ]
    #expect(ProjectDeck.location(of: deviceSupport, reporter: reporter)
        == "~/Library/Developer/Xcode")

    // Rows that only meet at the home directory: "~" locates nothing, so the line is
    // dropped and the rows' own names are the whole of the answer.
    let jsCaches = [
        toolRow(scanner: "other.jsPackages", group: .otherCaches, name: "npm cache",
                relativePath: ".npm/_cacache", sizeBytes: 4_000_000_000),
        toolRow(scanner: "other.jsPackages", group: .otherCaches, name: "Yarn cache",
                relativePath: "Library/Caches/Yarn", sizeBytes: 4_000_000_000),
    ]
    #expect(ProjectDeck.location(of: jsCaches, reporter: reporter) == nil)

    // A device has no path at all, and a card that mixed devices with paths must not be
    // labelled with the location of the half that has one.
    #expect(ProjectDeck.location(
        of: [simulatorRow(name: "iPhone", udid: "AAA", sizeBytes: 9)], reporter: reporter)
        == nil)
    #expect(ProjectDeck.location(
        of: derivedDataRows() + [simulatorRow(name: "iPhone", udid: "AAA", sizeBytes: 9)],
        reporter: reporter) == nil)
    #expect(ProjectDeck.location(of: [], reporter: reporter) == nil)
}

@Test func aSimulatorCardHasNoLocationAndNoDate() throws {
    let built = deck([simulatorRow(name: "iPhone 17 Pro", udid: "AAA", sizeBytes: 12_000_000_000)])

    let card = try #require(built.cards.first)
    #expect(card.pathText == nil)
    // A cache's newest file says when a build last ran, which is not a fact about anything
    // the user recognises — so a tool card says nothing about it rather than saying
    // something that reads like a project's "last changed 4 months ago".
    #expect(card.lastChangedText == nil)
}

// MARK: - what a tool card is not offering

/// A protected row is not on the card's list and never reaches the engine. It is counted
/// beside the rows instead, because a card showing 9.1 GB while the disk says 13.5 GB looks
/// like a measurement that cannot be trusted.
@Test func aProtectedRowIsCountedBesideTheCardAndNeverOnIt() throws {
    let built = deck(derivedDataRows() + [
        toolRow(name: "Live-\(runnerHash)",
                relativePath: "Library/Developer/Xcode/DerivedData/Live-\(runnerHash)",
                sizeBytes: 4_400_000_000, detail: "kept for app",
                protection: .recentActivity(days: 14)),
        toolRow(name: "Pinned-\(runnerHash)",
                relativePath: "Library/Developer/Xcode/DerivedData/Pinned-\(runnerHash)",
                sizeBytes: 1_000_000_000, detail: "kept for site",
                protection: .pinnedProject),
    ])

    let card = try #require(built.cards.first)
    #expect(card.folders.count == 3)
    #expect(card.items.allSatisfy { $0.protection == nil })
    #expect(card.totalBytes == 9_100_000_000)
    // Two different reasons, so the line does not pick one of them to print over the other.
    #expect(card.keptText == "2 kept because they are in use · 5.4 GB")
}

/// One shared reason is named, because it is usually also where the user goes to change
/// their mind.
@Test func aKeptLineNamesTheReasonWhenEveryHeldRowSharesOne() throws {
    let built = deck([
        runtimeRow(name: "iOS 26.5", identifier: "iOS-26-5", sizeBytes: 17_300_000_000),
        runtimeRow(name: "iOS 18.0", identifier: "iOS-18-0", sizeBytes: 13_500_000_000,
                   protection: .newestRuntime),
    ])

    #expect(try #require(built.cards.first).keptText
        == "1 kept · newest installed runtime · 13.5 GB")
    #expect(ProjectDeckText.keptRows(
        reasons: [.runtimeUsedByKeptDevice, .runtimeUsedByKeptDevice], bytes: 13_500_000_000)
        == "2 kept · used by the simulator you keep · 13.5 GB")
    #expect(ProjectDeckText.keptRows(reasons: [.bootedDevice], bytes: 3_000_000_000)
        == "1 kept · running right now · 3.0 GB")
    #expect(ProjectDeckText.keptRows(
        reasons: [.bootedDevice, .newestRuntime], bytes: 3_000_000_000)
        == "2 kept because they are in use · 3.0 GB")
    #expect(ProjectDeckText.keptRows(
        reasons: [.sdkInUse(by: "app"), .sdkInUse(by: "site")], bytes: 2_100_000_000)
        == "2 kept because they are in use · 2.1 GB")
}

/// A scanner with nothing to offer at all gets no card — there would be nothing on it to
/// press a button about — and is named on the end card instead. On this Mac that is the
/// emulator and its system image, 12 GB the user would otherwise go looking for.
@Test func aScannerWhoseEveryRowIsKeptGetsNoCardAndIsNamedAtTheEnd() {
    let built = deck([
        folderRow(project: "app", folder: "build", sizeBytes: 900_000_000),
        toolRow(scanner: "android.avds", group: .android, name: "Pixel_8_API_34",
                relativePath: ".android/avd/Pixel_8_API_34.avd", sizeBytes: 7_000_000_000,
                protection: .mostRecentlyUsedDevice),
        toolRow(scanner: "android.systemImages", group: .android, name: "android-34",
                relativePath: "Library/Android/sdk/system-images/android-34",
                sizeBytes: 5_000_000_000, protection: .sdkInUse(by: "Pixel_8_API_34")),
    ])

    #expect(built.cards.map(\.id) == ["/Users/test/dev/app"])
    #expect(built.keptToolsText
        == "Left alone because they are in use: Android emulators, "
            + "Android system images · 12.0 GB")
    // Not folded into the small-things line: nothing about it was small, and nothing about
    // it was hidden for being small.
    #expect(built.smallThingsText == nil)
}

@Test func oneKeptScannerIsNamedInTheSingular() {
    let built = deck([
        toolRow(scanner: "android.avds", group: .android, name: "Pixel_8_API_34",
                relativePath: ".android/avd/Pixel_8_API_34.avd", sizeBytes: 7_000_000_000,
                protection: .bootedDevice),
    ])

    #expect(built.cards.isEmpty)
    #expect(built.keptToolsText
        == "Left alone because it is in use: Android emulators · 7.0 GB")
}

/// Under the floor, a scanner folds into the same line a small project does: the decision is
/// not worth asking for, and the space is still accounted for.
@Test func aScannerUnderTheFloorFoldsIntoTheSmallThingsLineWithTheProjects() {
    let built = deck([
        folderRow(project: "big", folder: "build", sizeBytes: 3_000_000_000),
        folderRow(project: "tiny", folder: ".dart_tool", sizeBytes: 4_000_000),
        toolRow(scanner: "ios.simulatorCaches", name: "Simulator caches",
                relativePath: "Library/Developer/CoreSimulator/Caches", sizeBytes: 3_000_000),
    ])

    #expect(built.cards.map(\.name) == ["big"])
    #expect(built.smallThingsText == "2 small things under 50 MB were not shown · 7 MB")
}

/// One card per scanner, whatever order its rows arrive in and however many of them are
/// dropped.
///
/// The interesting case is a scanner whose **first** row is the unmeasured one, because that
/// row lands in neither of the two collections the card is built from. Read the order off
/// those, and the scanner is counted again on its second row and dealt twice — two cards
/// with one identifier, two bars in the skyline, and a `ForEach` over duplicate identities.
@Test func aScannerWhoseFirstRowIsUnmeasuredIsStillOnlyOneCard() throws {
    let built = deck([
        toolRow(name: "Unmeasured",
                relativePath: "Library/Developer/Xcode/DerivedData/Unmeasured",
                sizeBytes: 0, startsUnticked: true),
        toolRow(name: "Runner",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner",
                sizeBytes: 5_000_000_000),
        toolRow(name: "Notes",
                relativePath: "Library/Developer/Xcode/DerivedData/Notes",
                sizeBytes: 1_000_000_000),
    ])

    #expect(built.cards.map(\.id) == ["xcode.derivedData"])
    let card = try #require(built.cards.first)
    #expect(card.folders.map(\.name) == ["Runner", "Notes"])
    #expect(card.totalBytes == 6_000_000_000)
}

/// The same, for a scanner whose first row is a protected one.
@Test func aScannerWhoseFirstRowIsKeptIsStillOnlyOneCard() {
    let built = deck([
        runtimeRow(name: "iOS 18.0", identifier: "iOS-18-0", sizeBytes: 13_500_000_000,
                   protection: .newestRuntime),
        runtimeRow(name: "iOS 26.5", identifier: "iOS-26-5", sizeBytes: 17_300_000_000),
    ])

    #expect(built.cards.map(\.id) == ["ios.runtimes"])
    #expect(built.keptToolsText == nil)
}

/// A scanner that found nothing measurable is not a "small thing" either: there is nothing
/// to count and nothing to total, and a line reading "1 small thing … · 0 KB" would be the
/// window inventing a fact.
@Test func aScannerWithNothingMeasurableIsNotCountedAsSmall() {
    let built = deck([
        folderRow(project: "big", folder: "build", sizeBytes: 3_000_000_000),
        toolRow(scanner: "ios.simulatorCaches", name: "Simulator caches",
                relativePath: "Library/Developer/CoreSimulator/Caches", sizeBytes: 0),
        toolRow(scanner: "flutter.pubCache", group: .flutterAndDart, name: "hosted",
                relativePath: ".pub-cache/hosted", sizeBytes: 0, startsUnticked: true),
    ])

    #expect(built.cards.map(\.name) == ["big"])
    #expect(built.smallThingsText == nil)
}

// MARK: - the order of a mixed deck

/// Projects and scanners are dealt together, biggest first. The user's goal is the biggest
/// gains first, and on this Mac four of the five biggest things on the disk are caches.
@Test func theDeckDealsProjectsAndScannersTogetherBiggestFirst() {
    let built = deck([
        folderRow(project: "Sample Game", folder: ".build", sizeBytes: 3_300_000_000),
        toolRow(scanner: "xcode.deviceSupport", name: "iOS 18.0",
                relativePath: "Library/Developer/Xcode/iOS DeviceSupport/18.0",
                sizeBytes: 27_000_000_000),
        simulatorRow(name: "iPhone 17 Pro", udid: "AAA", sizeBytes: 21_400_000_000),
        folderRow(project: "site", folder: "node_modules", sizeBytes: 9_000_000_000,
                  risk: .elevated),
        toolRow(scanner: "flutter.pubCache", group: .flutterAndDart, name: "hosted",
                relativePath: ".pub-cache/hosted", sizeBytes: 10_000_000_000),
    ])

    #expect(built.cards.map(\.name) == [
        "Device support files", "iOS simulators", "Dart package cache", "site", "Sample Game",
    ])
}

/// Ties go by identifier, so a deck holding two equal cards is dealt the same way on every
/// scan of the same machine — and a scanner's identifier sorts against a project's path
/// without either of them being special-cased.
@Test func cardsOfEqualSizeAreDealtInIdentifierOrder() {
    let built = deck([
        folderRow(project: "app", folder: "build", sizeBytes: 2_000_000_000),
        toolRow(scanner: "android.gradle", group: .android, name: "Build cache",
                relativePath: ".gradle/caches/build-cache-1", sizeBytes: 2_000_000_000),
    ])

    #expect(built.cards.map(\.id) == ["/Users/test/dev/app", "android.gradle"])
}

// MARK: - the card that cannot be undone

/// The safety rule, all four halves of it in one place.
///
/// `simctl delete` destroys the device directory — every installed app, its databases, its
/// user defaults — and there is no Trash and no undo. Return is the window's default action,
/// so nine reversible cards in a row train the user's hand; this card says what it is twice,
/// names the act in its button, and cannot be answered by that key at all.
@Test func aCardThatDeletesForGoodSaysSoTwiceAndTakesAwayTheReturnKey() throws {
    let built = deck([
        simulatorRow(name: "iPhone 17 Pro", udid: "AAA", sizeBytes: 12_000_000_000),
        simulatorRow(name: "iPad Air", udid: "BBB", sizeBytes: 9_400_000_000),
    ])

    let card = try #require(built.cards.first)
    #expect(card.totalText == "21.4 GB")
    // 1: on the card.
    #expect(card.cautionLines == ["Deleted for good. These do not go to the Trash."])
    // 2: above the buttons, in the engine's own words.
    #expect(card.promiseText == CleanerService.Warning.devicesAreRemovedPermanently)
    // 3: the button names the act rather than reading like the nine before it.
    #expect(card.primaryActionTitle == "Delete 21.4 GB for good")
    // 4: and no key answers it.
    #expect(!card.answersToReturn)
    #expect(card.primaryActionKeyHint == nil)
}

/// The promise on a permanent card is the engine's own sentence rather than one of the
/// deck's, so the two cannot come to disagree about the most expensive fact in the app — and
/// the engine's is the one that knows about the machine where an emulator really does go to
/// the Trash because `avdmanager` is missing.
@Test func thePermanentPromiseIsTheEnginesOwnWarning() throws {
    let simulator = simulatorRow(name: "iPhone 17 Pro", udid: "AAA", sizeBytes: 12_000_000_000)

    for moveToTrash in [true, false] {
        let card = try #require(deck([simulator], moveToTrash: moveToTrash).cards.first)
        #expect(card.promiseText
            == CleanerService.warnings(for: [simulator], moveToTrash: moveToTrash)
                .joined(separator: " "))
        #expect(!card.answersToReturn)
    }
    // A runtime is the same rule: `simctl runtime delete` has no Trash either.
    let runtime = try #require(deck([
        runtimeRow(name: "iOS 26.5", identifier: "iOS-26-5", sizeBytes: 17_300_000_000),
    ]).cards.first)
    #expect(runtime.promiseText == CleanerService.Warning.devicesAreRemovedPermanently)
    #expect(runtime.primaryActionTitle == "Delete 17.3 GB for good")
    #expect(!runtime.answersToReturn)
}

/// Every other card keeps the key. The deck is a thing you work through, and taking Return
/// away from the twenty reversible cards as well would only teach the user that the window
/// does not answer its keyboard.
///
/// A user who switched the Trash off keeps it too, and that is the one deliberate line in
/// this rule: the setting applies to every card in the deck, it is reversible in settings,
/// and the card's promise line in that mode already reads "deleted — for good". The flag is
/// for the card that ignores the setting because `simctl` has no Trash to honour.
@Test func anOrdinaryCardStillAnswersToReturn() throws {
    let project = try #require(deck([
        folderRow(project: "app", folder: "build", sizeBytes: 900_000_000),
    ]).cards.first)
    #expect(project.answersToReturn)
    #expect(project.primaryActionTitle == "Clean up 900 MB")
    #expect(project.primaryActionKeyHint == "⏎")

    let cache = try #require(deck(derivedDataRows()).cards.first)
    #expect(cache.answersToReturn)
    #expect(cache.primaryActionTitle == "Clean up 9.1 GB")
    #expect(cache.primaryActionKeyHint == "⏎")

    // Permanent mode, where these rows are deleted rather than trashed. The key stays and
    // the button keeps its ordinary title; what says what will happen is the promise line.
    let permanent = deck(derivedDataRows(), moveToTrash: false)
    let outright = try #require(permanent.cards.first)
    #expect(outright.answersToReturn)
    #expect(outright.primaryActionTitle == "Clean up 9.1 GB")
    #expect(outright.promiseText == "Only what is listed here is deleted — for good.")
    #expect(outright.cautionLines.isEmpty)
}

/// Each kind of card writes its own promise, in the mode the deck was built for. A project
/// says the user's code stays; a shared cache has no code to reassure anybody about and says
/// instead that the button reaches nothing outside the list.
@Test func theCardWritesItsOwnPromise() throws {
    let rows = [
        folderRow(project: "app", folder: "build", sizeBytes: 900_000_000),
        toolRow(name: "Runner-\(runnerHash)",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner-\(runnerHash)",
                sizeBytes: 5_000_000_000),
    ]

    let trash = deck(rows, moveToTrash: true)
    #expect(try #require(trash.cards.first { $0.kind == .project }).promiseText
        == "Your code stays. Only these folders go to the Trash.")
    #expect(try #require(trash.cards.first { $0.kind != .project }).promiseText
        == "Only what is listed here goes to the Trash.")

    let permanent = deck(rows, moveToTrash: false)
    #expect(try #require(permanent.cards.first { $0.kind == .project }).promiseText
        == "Your code stays. Only these folders are deleted — for good.")
    #expect(try #require(permanent.cards.first { $0.kind != .project }).promiseText
        == "Only what is listed here is deleted — for good.")
}

/// The Android NDK: 5.6 GB that is deletable, offered, and deliberately never ticked. It is
/// **on** the card — the deck names it, sizes it and waits, which is the opposite of the
/// blind clean the tick rule exists to protect — and the card says what saying yes costs.
@Test func aCardHoldingRowsANormalCleanLeavesAloneSaysSo() throws {
    let built = deck([
        toolRow(scanner: "android.ndk", group: .android, name: "27.0.12077973",
                relativePath: "Library/Android/sdk/ndk/27.0.12077973",
                sizeBytes: 3_600_000_000, risk: .elevated, startsUnticked: true),
        toolRow(scanner: "android.ndk", group: .android, name: "26.1.10909125",
                relativePath: "Library/Android/sdk/ndk/26.1.10909125",
                sizeBytes: 2_000_000_000, risk: .elevated, startsUnticked: true),
    ])

    let card = try #require(built.cards.first)
    #expect(card.name == "Android NDK")
    #expect(card.folders.count == 2)
    #expect(card.totalText == "5.6 GB")
    #expect(card.cautionLines
        == ["A normal clean leaves this alone: getting it back is a large download."])
    // Nothing here is permanent, so the key stays and the button is the ordinary one.
    #expect(card.answersToReturn)
    #expect(card.primaryActionTitle == "Clean up 5.6 GB")
    // And these rows really are the ones no blind clean would take.
    #expect(card.items.allSatisfy { !$0.selectedByDefault })
}

/// Both cautions at once, in the order they are read: what the card does, then what a normal
/// clean would have done. Not reachable from today's scanners — the NDK is a path and the
/// devices are not — which is exactly why the card composes the lines instead of choosing
/// between them.
@Test func aCardCanCarryBothCautionsAtOnce() throws {
    let built = deck([
        CleanupItem(
            id: "ios.simulators|AAA", scannerID: "ios.simulators", group: .xcodeAndIOS,
            name: "iPhone 17 Pro", detail: "never booted", sizeBytes: 12_000_000_000,
            lastUsed: nil, risk: .elevated, protection: nil,
            method: .deleteSimulator(udid: "AAA"), startsUnticked: true),
    ])

    #expect(try #require(built.cards.first).cautionLines == [
        "Deleted for good. These do not go to the Trash.",
        "A normal clean leaves this alone: getting it back is a large download.",
    ])
}

/// A scanner identifier this build does not know can only arrive out of a cached scan
/// written by a different build. Its rows are still dealt, under the identifier and the
/// group the rows carry, because hiding gigabytes behind a failed lookup is the one answer
/// that leaves nothing on screen to explain the missing space.
@Test func rowsFromAnUnknownScannerAreStillDealtRatherThanDropped() throws {
    let built = deck([
        toolRow(scanner: "xcode.somethingNewer", name: "Whatever it is",
                relativePath: "Library/Developer/Xcode/Newer/thing", sizeBytes: 8_000_000_000),
    ])

    let card = try #require(built.cards.first)
    #expect(card.id == "xcode.somethingNewer")
    #expect(card.name == "xcode.somethingNewer")
    #expect(card.eyebrow == "Xcode & iOS")
    #expect(card.totalText == "8.0 GB")
}

/// The eyebrow on a project card, and the noun the position counter no longer needs.
@Test func aProjectCardSaysItIsAProject() throws {
    #expect(try #require(deck([
        folderRow(project: "app", folder: "build", sizeBytes: 900_000_000),
    ]).cards.first).eyebrow == "Project")
    #expect(ProjectDeckText.projectEyebrow == "Project")
}

// MARK: - the session strip

private func slots(_ pairs: [(String, Int64)]) -> [ProjectDeckSlot] {
    pairs.map { ProjectDeckSlot(id: $0.0, totalBytes: $0.1) }
}

@Test func thePositionIsOneBasedOverTheWholeSessionDeck() throws {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 9), ("b", 8), ("c", 7)]),
        decisions: ["a": .cleaned(trashedBytes: 9, deletedBytes: 0, problems: []), "b": .skipped],
        currentCardID: "c", moveToTrash: true)

    // No noun: the deck mixes projects with scanners, and the card's own eyebrow says
    // which of the two the user is looking at.
    #expect(summary.positionText == "3 of 3")
}

/// Every slot keeps its place and its height after the card is cleaned out of the result.
/// A skyline that renumbered would make "3 of 24" read "3 of 23" the moment the user
/// cleaned something, and the bars would all grow because the tallest had gone.
@Test func aCleanedSlotKeepsItsPlaceAndItsHeightInTheSkyline() throws {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 12_000_000_000), ("b", 3_000_000_000), ("c", 51_000_000)]),
        decisions: ["a": .cleaned(trashedBytes: 12_000_000_000, deletedBytes: 0, problems: [])],
        currentCardID: "b", moveToTrash: true)

    #expect(summary.skyline.map(\.id) == ["a", "b", "c"])
    #expect(summary.skyline.map(\.state) == [.cleaned, .current, .upcoming])
    let tallest = try #require(summary.skyline.first)
    #expect(tallest.fraction == 1.0)
}

@Test func aSkippedSlotReadsAsSkipped() {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 9), ("b", 8)]),
        decisions: ["a": .skipped], currentCardID: "b", moveToTrash: true)

    #expect(summary.skyline.map(\.state) == [.skipped, .current])
}

/// The card on screen reads as current even when it has already been cleaned, which is
/// the problems state: the user is reading that card, and the bar under their eye should
/// be the one they are looking at.
@Test func theCardOnScreenReadsAsCurrentEvenAfterItWasCleaned() {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 9), ("b", 8)]),
        decisions: ["a": .cleaned(trashedBytes: 4, deletedBytes: 0, problems: ["build: refused"])],
        currentCardID: "a", moveToTrash: true)

    #expect(summary.skyline.map(\.state) == [.current, .upcoming])
}

/// Square-rooted, because linear is unreadable: a real deck runs from 12 GB down to
/// 51 MB, and every bar after the first few would be a fraction of a pixel in a 30pt
/// strip — with no way to see that eleven of those flat bars are already cleaned.
@Test func smallProjectsStayVisibleInTheSkyline() {
    let biggest: Int64 = 12_000_000_000
    let linear = Double(51_000_000) / Double(biggest)
    let scaled = ProjectDeckSummary.skylineFraction(51_000_000, of: biggest)

    #expect(scaled > linear * 10)
    #expect(scaled < 1)
    // Monotonic, so the deck still reads as "they get smaller from here".
    #expect(ProjectDeckSummary.skylineFraction(3_000_000_000, of: biggest) > scaled)
    #expect(ProjectDeckSummary.skylineFraction(biggest, of: biggest) == 1)
    #expect(ProjectDeckSummary.skylineFraction(0, of: biggest) == 0)
    #expect(ProjectDeckSummary.skylineFraction(5, of: 0) == 0)
}

@Test func thereIsNoPositionWhenNoCardIsOnScreen() {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 9)]), decisions: ["a": .skipped],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.positionText == nil)
}

/// The session total is what really moved, added up in one place so the number over the
/// skyline and the number on the end card cannot disagree.
@Test func theSessionTotalAddsUpWhatTheRunsReallyMoved() {
    let decisions: [String: ProjectDecision] = [
        "a": .cleaned(trashedBytes: 9_000_000_000, deletedBytes: 0, problems: []),
        "b": .cleaned(trashedBytes: 3_400_000_000, deletedBytes: 0, problems: ["build: refused"]),
        "c": .skipped,
    ]

    #expect(ProjectDeckSummary.sessionBytes(of: decisions) == 12_400_000_000)
    let summary = ProjectDeckSummary(
        slots: slots([("a", 9_000_000_000), ("b", 4_000_000_000), ("c", 3_400_000_000)]),
        decisions: decisions, currentCardID: nil, moveToTrash: true)
    #expect(summary.sessionBytesText == "12.4 GB")
    #expect(summary.cleanedCount == 2)
}

/// A skipped project's total comes from the slot, which remembers what it was holding when
/// the deck was dealt — the card itself may be gone, or a later scan may have changed it.
@Test func theSkippedTotalComesFromWhatTheDeckRemembered() {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 2_000_000_000), ("b", 1_400_000_000), ("c", 9_000_000_000)]),
        decisions: ["a": .skipped, "b": .skipped,
                    "c": .cleaned(trashedBytes: 9_000_000_000, deletedBytes: 0, problems: [])],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.skippedCount == 2)
    #expect(summary.skippedBytes == 3_400_000_000)
    #expect(summary.skippedBytesText == "3.4 GB")
    #expect(summary.skippedText == "2 skipped · 3.4 GB")
}

// MARK: - what the two modes say

/// Every mode-dependent sentence is resolved here so no view branches on `Settings`.
/// "Deleted so far" over a run that put 12 GB in the Trash is the mistake that makes a
/// user stop looking in their Trash for a folder that is sitting in it.
///
/// The promise line is **not** here any more — it moved to the card when the deck started
/// dealing cards that cannot be undone, because three cards in one deck can need three
/// different sentences. `theCardWritesItsOwnPromise` is where it is pinned now.
@Test func everyModeDependentSentenceIsResolvedBeforeTheViewSeesIt() {
    let trash = ProjectDeckSummary(
        slots: slots([("a", 9_000_000)]),
        decisions: ["a": .cleaned(trashedBytes: 9_000_000, deletedBytes: 0, problems: [])],
        currentCardID: nil, moveToTrash: true)
    #expect(trash.sessionLabel == "In the Trash so far")
    #expect(trash.endDetailLines == ["9 MB moved to the Trash", "from 1 card"])
    #expect(trash.endNote == "The space comes back when you empty the Trash.")
    #expect(trash.openTrashText == "Open the Trash")

    // Permanent mode: every path row is deleted outright, so the run records deleted bytes
    // and there is no Trash to empty or open.
    let permanent = ProjectDeckSummary(
        slots: slots([("a", 9_000_000)]),
        decisions: ["a": .cleaned(trashedBytes: 0, deletedBytes: 9_000_000, problems: [])],
        currentCardID: nil, moveToTrash: false)
    #expect(permanent.sessionLabel == "Cleaned so far")
    #expect(permanent.endDetailLines == ["9 MB deleted for good", "from 1 card"])
    #expect(permanent.endNote == nil)
    #expect(permanent.openTrashText == nil)
}

/// The label over the running total claims the Trash only while that is the whole truth.
///
/// One simulator card puts 21.4 GB beyond recovery, and it can be answered in the middle of
/// a session that has otherwise only trashed things. "In the Trash so far" over the sum
/// would send the user looking for a runtime that is not there — so the moment anything has
/// gone for good the label drops the claim, and the end card names the two amounts apart.
@Test func theSessionLabelStopsClaimingTheTrashOnceSomethingWentForGood() {
    func label(trashed: Int64, deleted: Int64, moveToTrash: Bool = true) -> String {
        ProjectDeckSummary(
            slots: slots([("a", 9)]),
            decisions: ["a": .cleaned(
                trashedBytes: trashed, deletedBytes: deleted, problems: [])],
            currentCardID: nil, moveToTrash: moveToTrash).sessionLabel
    }
    #expect(label(trashed: 4_400_000_000, deleted: 0) == "In the Trash so far")
    #expect(label(trashed: 4_400_000_000, deleted: 17_300_000_000) == "Cleaned so far")
    #expect(label(trashed: 0, deleted: 17_300_000_000) == "Cleaned so far")
    // Nothing has happened yet, and the Trash is still the whole truth of what will.
    #expect(label(trashed: 0, deleted: 0) == "In the Trash so far")
    // Permanent mode never claims the Trash, whatever the run recorded.
    #expect(label(trashed: 0, deleted: 0, moveToTrash: false) == "Cleaned so far")
    #expect(ProjectDeckText.sessionLabel(moveToTrash: true, deletedForGood: false)
        == "In the Trash so far")
    #expect(ProjectDeckText.sessionLabel(moveToTrash: true, deletedForGood: true)
        == "Cleaned so far")
}

/// The two amounts are kept apart from the run's record to the end card, because they mean
/// opposite things: one lot is sitting in the Trash and comes back, the other is gone.
@Test func theEndCardNamesWhatWentToTheTrashAndWhatWentForGoodSeparately() {
    let decisions: [String: ProjectDecision] = [
        "/p/a": .cleaned(trashedBytes: 4_400_000_000, deletedBytes: 0, problems: []),
        "ios.simulators": .cleaned(
            trashedBytes: 0, deletedBytes: 21_400_000_000, problems: []),
        "ios.runtimes": .cleaned(trashedBytes: 0, deletedBytes: 17_300_000_000, problems: []),
    ]
    let summary = ProjectDeckSummary(
        slots: slots([("/p/a", 4_400_000_000), ("ios.simulators", 21_400_000_000),
                      ("ios.runtimes", 17_300_000_000)]),
        decisions: decisions, currentCardID: nil, moveToTrash: true)

    #expect(summary.sessionTrashedBytes == 4_400_000_000)
    #expect(summary.sessionDeletedBytes == 38_700_000_000)
    // The big number is the sum, which is exactly why every line under it has to say where
    // its own share went.
    #expect(summary.sessionBytesText == "43.1 GB")
    #expect(summary.endDetailLines == [
        "4.4 GB moved to the Trash",
        "38.7 GB deleted for good",
        "from 3 cards",
    ])
    // Something really is in the Trash, so both of those are offered.
    #expect(summary.endNote == "The space comes back when you empty the Trash.")
    #expect(summary.openTrashText == "Open the Trash")
    #expect(ProjectDeckSummary.trashedBytes(of: decisions) == 4_400_000_000)
    #expect(ProjectDeckSummary.deletedBytes(of: decisions) == 38_700_000_000)
    #expect(ProjectDeckSummary.sessionBytes(of: decisions) == 43_100_000_000)
}

/// A session that only destroyed devices has put **nothing** in the Trash, so neither the
/// note about emptying it nor the button that opens it belongs on the card — even in Trash
/// mode, where the setting on its own would have offered both.
@Test func aSessionThatOnlyDeletedForGoodOffersNoTrashToOpen() {
    let summary = ProjectDeckSummary(
        slots: slots([("ios.simulators", 21_400_000_000)]),
        decisions: ["ios.simulators": .cleaned(
            trashedBytes: 0, deletedBytes: 21_400_000_000, problems: [])],
        currentCardID: nil, moveToTrash: true, trashedHiddenFolders: true)

    #expect(summary.endDetailLines == ["21.4 GB deleted for good", "from 1 card"])
    #expect(summary.endNote == nil)
    #expect(summary.openTrashText == nil)
    // And the hidden-folder note rides on the same fact.
    #expect(summary.hiddenInTrashNote == nil)
}

/// A cancelled run records a cleaned card that moved nothing. Neither a note about space
/// nor a button into the Trash means anything then, so both follow the bytes rather than
/// the count — and the card count is all the detail there is left to print.
@Test func aCleanThatMovedNothingOffersNoTrashToOpen() {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 9)]),
        decisions: ["a": .cleaned(
            trashedBytes: 0, deletedBytes: 0,
            problems: ["build: you cancelled the run"])],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.cleanedCount == 1)
    #expect(summary.endDetailLines == ["from 1 card"])
    #expect(summary.endNote == nil)
    #expect(summary.openTrashText == nil)
}

// MARK: - the end of the deck

@Test func theEndOfTheDeckSumsUpWhatHappened() {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 9_000_000_000), ("b", 3_400_000_000)]),
        decisions: ["a": .cleaned(trashedBytes: 9_000_000_000, deletedBytes: 0, problems: []),
                    "b": .skipped],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.endHeadline == "That's everything.")
    #expect(summary.endDetailLines == ["9.0 GB moved to the Trash", "from 1 card"])
    #expect(summary.skippedText == "1 skipped · 3.4 GB")
    #expect(summary.reviewSkippedText == "Go through skipped again")
}

/// A deck the user skipped their way through. A bare count would put "from 0 cards" on
/// screen, which reads as a failure rather than as a decision they made twenty-four times.
@Test func aDeckThatWasSkippedRightThroughSaysSoInsteadOfCountingZero() {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 9), ("b", 8)]),
        decisions: ["a": .skipped, "b": .skipped],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.endHeadline == "That's everything.")
    #expect(summary.endDetailLines == ["You left everything alone."])
    #expect(summary.endNote == nil)
}

@Test func aMachineWithNothingWorthCleaningSaysThatInstead() {
    let summary = ProjectDeckSummary(
        slots: [], decisions: [:], currentCardID: nil, moveToTrash: true)

    #expect(summary.endHeadline == "Nothing to clean up.")
    // Not "no project": the deck deals every scanner now, so a machine that gets here has
    // nothing over the floor anywhere.
    #expect(summary.endDetailLines == ["Nothing here holds more than 50 MB."])
    #expect(summary.skippedText == nil)
    #expect(summary.reviewSkippedText == nil)
    #expect(summary.openTrashText == nil)
    #expect(summary.sessionBytesText == "0 KB")
}

/// The floor is printed from the constant rather than typed, so raising it cannot leave a
/// sentence behind naming the old one.
@Test func theNothingToCleanLineNamesTheFloorTheDeckActuallyUses() {
    #expect(ProjectDeckText.nothingDetail
        .contains(ByteText.short(ProjectDeck.minimumCardBytes)))
}

// MARK: - the number set large

/// The card sets "2.9" at 96 points and "GB" at 40, so where one ends and the other begins
/// is a decision — and one taken inside a SwiftUI body is a decision nothing can read.
@Test func theGainIsSplitIntoItsNumeralAndItsUnit() {
    #expect(SizeHeadline("2.9 GB").number == "2.9")
    #expect(SizeHeadline("2.9 GB").unit == "GB")
    #expect(SizeHeadline("946 MB").number == "946")
    #expect(SizeHeadline("0 KB").unit == "KB")
    // An ordinary amount is the whole of itself, so there is no second figure — and the small
    // half the view sets at 40 points is the bare unit.
    #expect(SizeHeadline("2.9 GB").outOf == nil)
    #expect(SizeHeadline("2.9 GB").trailingText == "GB")
}

/// Every size the deck prints comes out of `ByteText.short`, which always writes one space.
/// A string without one keeps the whole of itself as the numeral rather than leaving the
/// window with an empty headline over a real total.
@Test func aSizeWithNoUnitToSplitOffKeepsAllOfItselfAsTheNumber() {
    #expect(SizeHeadline("2.9").number == "2.9")
    #expect(SizeHeadline("2.9").unit == nil)
    #expect(SizeHeadline("").number == "")
    #expect(SizeHeadline("2.9 ").unit == nil)
}

/// The number over the rows is the card's own total formatted once, so the headline and the
/// Clean button cannot disagree about what the project is worth.
@Test func theCardsHeadlineIsItsOwnTotal() throws {
    let card = try #require(deck([
        folderRow(project: "game", folder: ".build", sizeBytes: 2_500_000_000),
        folderRow(project: "game", folder: "ios/Pods", sizeBytes: 400_000_000),
    ]).cards.first)

    #expect(card.totalHeadline.number == "2.9")
    #expect(card.totalHeadline.unit == "GB")
    #expect(card.totalText == "\(card.totalHeadline.number) \(card.totalHeadline.unit ?? "")")
}

/// `nil` rather than "0 KB". The gain number is what the user reads from across the room,
/// and a 96-point zero over "You left every project alone" reads as the app reporting a
/// failure instead of a decision the user made twenty-four times.
@Test func theEndCardHasNoNumberToSetLargeWhenNothingMoved() {
    let skippedThrough = ProjectDeckSummary(
        slots: slots([("a", 9), ("b", 8)]),
        decisions: ["a": .skipped, "b": .skipped],
        currentCardID: nil, moveToTrash: true)
    #expect(skippedThrough.endGain == nil)

    let nothingToClean = ProjectDeckSummary(
        slots: [], decisions: [:], currentCardID: nil, moveToTrash: true)
    #expect(nothingToClean.endGain == nil)

    // A cancelled run records a `.cleaned` decision that moved nothing, and there is no
    // more to set large about that than about a skip.
    let cancelled = ProjectDeckSummary(
        slots: slots([("a", 9_000_000_000)]),
        decisions: ["a": .cleaned(trashedBytes: 0, deletedBytes: 0, problems: [])],
        currentCardID: nil, moveToTrash: true)
    #expect(cancelled.endGain == nil)
}

@Test func theEndCardSetsTheSessionTotalLargeWhenSomethingMoved() throws {
    let summary = ProjectDeckSummary(
        slots: slots([("a", 12_400_000_000)]),
        decisions: ["a": .cleaned(trashedBytes: 12_400_000_000, deletedBytes: 0, problems: [])],
        currentCardID: nil, moveToTrash: true)

    let gain = try #require(summary.endGain)
    #expect(gain.number == "12.4")
    #expect(gain.unit == "GB")
    // One number formatted once: the strip's counter and the end card's numeral are the
    // same value split, never two sums.
    #expect(summary.sessionBytesText == "12.4 GB")
}

// MARK: - the rows draining on real progress

/// The one piece of motion on the card, and it is the run's own progress: `items` is in the
/// same order as `folders` and `Executor` works through that list one at a time, so
/// `completed` is exactly how many rows have really gone.
@Test func aFolderIsDrainedOnlyOnceTheRunHasPassedIt() {
    let progress = ExecutionProgress(completed: 2, total: 8, currentName: ".build-release")

    #expect(ProjectCard.isFolderDrained(at: 0, progress: progress))
    #expect(ProjectCard.isFolderDrained(at: 1, progress: progress))
    // The row being worked on now is not drained yet — it is still on the disk.
    #expect(!ProjectCard.isFolderDrained(at: 2, progress: progress))
    #expect(!ProjectCard.isFolderDrained(at: 7, progress: progress))
}

/// `.running(nil)` is the state the Clean up button is pressed into, and a run whose first
/// folder is still being removed has emptied none of them.
@Test func noReportYetDrainsNothing() {
    #expect(!ProjectCard.isFolderDrained(at: 0, progress: nil))
    #expect(!ProjectCard.isFolderDrained(
        at: 0, progress: ExecutionProgress(completed: 0, total: 8, currentName: ".build")))
}

/// The total on the button is the card's folder count and not the report's, because the
/// button has to say something before the first report arrives: "Cleaning… 0 of 0" above
/// eight folders waiting to drain is a button that looks broken.
@Test func theCleaningTitleCountsTheCardsFoldersFromTheFirstFrame() {
    #expect(ProjectDeckText.cleaning(nil, of: 8) == "Cleaning… 0 of 8")
    #expect(ProjectDeckText.cleaning(
        ExecutionProgress(completed: 2, total: 8, currentName: ".build-rel"), of: 8)
        == "Cleaning… 2 of 8")
}

// MARK: - the rest of the copy

/// The deck's chrome, pinned here because the view is a separate target that a test cannot
/// import: a sentence written in `DevCleanerApp` is a sentence nothing can check, and the
/// whole reason these live in `DevCleanerUI` is so that this file is where they change.
///
/// Sentence case, no exclamation marks and no "successfully", which is the house voice
/// throughout — compare `CleanerService.Warning` and `StatusPanelText.amountHelp`.
@Test func theDecksButtonsAndWaitingStatesSayTheseExactWords() {
    #expect(ProjectDeckText.skip == "Skip")
    #expect(ProjectDeckText.cleanUp("2.9 GB") == "Clean up 2.9 GB")
    #expect(ProjectDeckText.cleaning(completed: 2, total: 8) == "Cleaning… 2 of 8")
    #expect(ProjectDeckText.nextProject == "Next project")
    #expect(ProjectDeckText.reviewSkipped == "Go through skipped again")
    #expect(ProjectDeckText.openTrash == "Open the Trash")
    #expect(ProjectDeckText.scanNow == "Scan now")
    #expect(ProjectDeckText.scanAgain == "Scan again")
    // "everything", not "your projects": the deck deals the caches and the simulators too,
    // and the scan behind this sentence always measured all of them.
    #expect(ProjectDeckText.scanning == "Measuring everything on this Mac…")
    #expect(ProjectDeckText.cleanUpWaitsForScan
        == "Measuring everything again. Clean up unlocks when it finishes.")
    #expect(ProjectDeckText.noScanYet == "Nothing has been measured yet.")
}

/// Two different glyphs, each naming the key its own button is wired to. Swapped, they
/// would teach Return for the skip and the arrow for the deletion — and a glyph typed into
/// a SwiftUI body is a glyph no test can hold beside the shortcut next to it.
@Test func theTwoKeyboardHintsNameTwoDifferentKeys() {
    #expect(ProjectDeckText.cleanUpKeyHint == "⏎")
    #expect(ProjectDeckText.skipKeyHint == "→")
    #expect(ProjectDeckText.cleanUpKeyHint != ProjectDeckText.skipKeyHint)
}

/// The titlebar is the only thing a background scan may change about a deck being read. It
/// runs unasked for about 51 seconds, so the subtitle has to say so while the card stays
/// exactly where it is — and reducing four phases to "is this a scan" is the decision.
@MainActor
@Test func theTitlebarSaysWhatIsHappeningOrWhenItLastMeasured() {
    #expect(ProjectDeckText.windowSubtitle(phase: .idle, scanAge: "2h ago")
        == "Scanned 2h ago")
    #expect(ProjectDeckText.windowSubtitle(phase: .scanning(nil), scanAge: "2h ago")
        == ProjectDeckText.scanning)
    // A scan is a scan whether or not a report has arrived yet.
    #expect(ProjectDeckText.windowSubtitle(
        phase: .scanning(ScanProgress(
            completed: 3, total: 16, currentID: "android.avds",
            currentTitle: "Android emulators")),
        scanAge: "2h ago") == ProjectDeckText.scanning)
    // A clean leaves the age alone: the scan really was taken then, and the Clean up button
    // is already saying what the run is doing.
    #expect(ProjectDeckText.windowSubtitle(phase: .running(nil), scanAge: "2h ago")
        == "Scanned 2h ago")
    // Nothing measured yet says the same thing the middle of the window is saying.
    #expect(ProjectDeckText.windowSubtitle(phase: .idle, scanAge: nil)
        == ProjectDeckText.noScanYet)
}

/// The button's size comes from the card's own total, so the number on the button and the
/// number above the rows are one value formatted once.
@Test func theCleanButtonCarriesTheCardsOwnTotal() throws {
    let built = deck([
        folderRow(project: "game", folder: ".build", sizeBytes: 2_500_000_000),
        folderRow(project: "game", folder: "ios/Pods", sizeBytes: 400_000_000),
    ])

    let card = try #require(built.cards.first)
    #expect(card.totalText == "2.9 GB")
    #expect(ProjectDeckText.cleanUp(card.totalText) == "Clean up 2.9 GB")
}

/// The end card no longer sends the user to the menu bar for the rest of their disk.
///
/// It used to: the window showed projects only, so without a pointer the 40 GB of derived
/// data a user came looking for simply appeared to have gone. The deck deals derived data
/// itself now, and a line saying otherwise would be the app telling the user to go somewhere
/// else to do what this window just did. Pinned as an absence, because the sentence was
/// tested and deleting it without a word here is how it would come back.
@Test func theEndCardNoLongerSendsTheUserToTheMenuBarForTheRest() {
    let summary = ProjectDeckSummary(
        slots: [ProjectDeckSlot(id: "xcode.derivedData", totalBytes: 9_100_000_000)],
        decisions: ["xcode.derivedData": .cleaned(
            trashedBytes: 9_100_000_000, deletedBytes: 0, problems: [])],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.endDetailLines.allSatisfy { !$0.contains("menu bar") })
    #expect(summary.endHeadline == "That's everything.")
}

/// Clean up is dead for the whole of a scan — a minute, from the moment the app opens — and
/// the line above it has to say so rather than go on promising things about the Trash.
@Test func theLineAboveTheButtonsExplainsADeadCleanUpWhileAScanRuns() {
    let promise = ProjectDeckText.promise(moveToTrash: true)
    #expect(ProjectDeckText.actionNote(
        phase: .scanning(nil), isCleaningThisCard: false, promise: promise)
        == ProjectDeckText.cleanUpWaitsForScan)
    #expect(ProjectDeckText.actionNote(
        phase: .idle, isCleaningThisCard: false, promise: promise) == promise)
}

/// The three states the line has to tell apart, and the one that used to be wrong.
///
/// `work` is a single slot for the whole app, so any clean greys Clean up out on every
/// card — and the phase alone cannot say whose run it is. Told only "something is running",
/// the window either kept promising things about the Trash over a dead button or claimed to
/// be measuring. `AppModel.cardRun` is what answers it, and this is the sentence that answer
/// buys.
///
/// Nothing reaches the second state today — the menu bar stopped cleaning when it became a
/// status item, so every run belongs to the card on screen — which is why the sentence no
/// longer names where the run came from. The rule is still pinned here: `cardRun` and this
/// function are the only things able to tell two runs apart, and the failure they guard
/// against is a card printing its own promise over somebody else's clean.
@Test func theLineAboveTheButtonsTellsThisCardsRunApartFromSomebodyElses() {
    let promise = ProjectDeckText.promise(moveToTrash: true)
    // This card's own clean: the button beside the line is counting folders off, which
    // explains itself, so the promise stays.
    #expect(ProjectDeckText.actionNote(
        phase: .running(nil), isCleaningThisCard: true, promise: promise) == promise)
    // Somebody else's clean: the button is dead and nothing on this screen said why.
    #expect(ProjectDeckText.actionNote(
        phase: .running(ExecutionProgress(completed: 57, total: 92, currentName: "Yarn")),
        isCleaningThisCard: false, promise: promise)
        == "A clean is already running. Clean up unlocks when it finishes.")
    #expect(ProjectDeckText.actionNote(
        phase: .running(nil), isCleaningThisCard: false, promise: promise)
        == ProjectDeckText.cleanUpWaitsForOtherRun)
    // A scan wins over both, because it is what the titlebar is already reporting.
    #expect(ProjectDeckText.actionNote(
        phase: .scanning(nil), isCleaningThisCard: true, promise: promise)
        == ProjectDeckText.cleanUpWaitsForScan)
}

/// The note about hidden folders rides on the note about emptying the Trash: never when
/// nothing landed in the Trash, and never unless a dot-name really went there.
///
/// It follows the **trashed bytes** rather than the Trash setting, which is a change and a
/// deliberate one: an emulator goes to the Trash even in permanent mode when `avdmanager` is
/// missing, and a note about a folder sitting in there is right whenever something is.
@Test func theHiddenInTrashNoteOnlyAppearsBesideTheEmptyTheTrashNote() {
    let slots = [ProjectDeckSlot(id: "/p/a", totalBytes: 1_000_000_000)]
    let cleaned: [String: ProjectDecision] = [
        "/p/a": .cleaned(trashedBytes: 1_000_000_000, deletedBytes: 0, problems: []),
    ]
    let nothingMoved: [String: ProjectDecision] = [
        "/p/a": .cleaned(trashedBytes: 0, deletedBytes: 0, problems: []),
    ]
    let deletedOutright: [String: ProjectDecision] = [
        "/p/a": .cleaned(trashedBytes: 0, deletedBytes: 1_000_000_000, problems: []),
    ]

    func note(_ decisions: [String: ProjectDecision], trash: Bool, hidden: Bool) -> String? {
        ProjectDeckSummary(
            slots: slots, decisions: decisions, currentCardID: nil,
            moveToTrash: trash, trashedHiddenFolders: hidden).hiddenInTrashNote
    }
    #expect(note(cleaned, trash: true, hidden: true) == ProjectDeckText.hiddenInTrashNote)
    #expect(note(cleaned, trash: true, hidden: false) == nil)
    // Deleted outright: there is nothing in the Trash to be hidden in it.
    #expect(note(deletedOutright, trash: true, hidden: true) == nil)
    #expect(note(deletedOutright, trash: false, hidden: true) == nil)
    // Trashed although the setting says otherwise — the emulator fallback. The folder
    // really is in there, so the note about seeing it is right.
    #expect(note(cleaned, trash: false, hidden: true) == ProjectDeckText.hiddenInTrashNote)
    #expect(note(nothingMoved, trash: true, hidden: true) == nil)
}

@Test func aNameBeginningWithADotIsWhatFinderHides() {
    #expect(ProjectDeckText.isHiddenInFinder("/Users/x/dev/app/.build"))
    #expect(ProjectDeckText.isHiddenInFinder("/Users/x/dev/app/.build-release"))
    #expect(!ProjectDeckText.isHiddenInFinder("/Users/x/dev/app/build"))
    // The folder's own name, not anything above it.
    #expect(!ProjectDeckText.isHiddenInFinder("/Users/x/.hidden/app/ios/Pods"))
}

// MARK: - one card per row, for the scanners whose rows are unrelated

/// `other.xdgCache` gets a card each, and that is the scanner's own declaration rather than
/// a list kept in the deck: a user may want `uv` gone and `pre-commit` kept, and this
/// window has no per-row ticks, so one card for both would be an all-or-nothing button over
/// two unrelated things.
@Test func aPerItemScannerGetsOneCardPerRow() throws {
    let built = deck([
        xdgCacheRow(name: "nimbus", sizeBytes: 2_400_000_000),
        xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000),
        xdgCacheRow(name: "pre-commit", sizeBytes: 1_200_000_000),
    ])

    #expect(built.cards.count == 3)
    #expect(built.cards.map(\.name) == ["nimbus", "pre-commit", "uv"])
    // One row each, and the card's identity is the row's — several cards share one scanner
    // now, so the scanner's identifier could not tell them apart.
    #expect(built.cards.allSatisfy { $0.items.count == 1 })
    #expect(built.cards.map(\.id) == built.cards.flatMap { $0.items.map(\.id) })
    #expect(built.cards.allSatisfy { $0.kind == .tool(scannerID: "other.xdgCache") })
    // A grouped scanner beside it is still one card, which is what makes this a contrast
    // rather than a change of default.
    let mixed = deck([
        xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000),
        toolRow(scanner: "xcode.derivedData", name: "Runner",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner",
                sizeBytes: 900_000_000),
        toolRow(scanner: "xcode.derivedData", name: "Gallery",
                relativePath: "Library/Developer/Xcode/DerivedData/Gallery",
                sizeBytes: 800_000_000),
    ])
    #expect(mixed.cards.map(\.id) == ["xcode.derivedData", "other.xdgCache|/Users/test/.cache/uv"])
}

/// The card is titled by its row and located by the folder that row sits **in** — the title
/// already says which thing, so what the location line has left to answer is where.
@Test func aPerItemCardIsTitledByItsRowAndLocatedByItsParentFolder() throws {
    let built = deck([
        xdgCacheRow(name: "pre-commit", sizeBytes: 1_200_000_000),
        modelRow(publisher: "lmstudio-community", model: "Qwen3-30B-GGUF",
                 sizeBytes: 18_000_000_000),
    ])

    let cache = try #require(built.cards.first { $0.name == "pre-commit" })
    #expect(cache.pathText == "~/.cache")
    #expect(cache.totalText == "1.2 GB")
    let model = try #require(built.cards.first { $0.name == "lmstudio-community/Qwen3-30B-GGUF" })
    #expect(model.pathText == "~/.lmstudio/models/lmstudio-community")
    #expect(model.totalText == "18.0 GB")
    // The single row is a bare bar: its name and size, and **no hint** — the hint would be
    // the row's own sentence, which is already the line under the big number.
    #expect(model.folders.map(\.name) == ["lmstudio-community/Qwen3-30B-GGUF"])
    #expect(model.folders.map(\.restoreHint) == [""])
    #expect(model.folders.map(\.fraction) == [1])
    #expect(model.folderCountText == "Download it again in LM Studio.")
}

/// "added 5 months ago", from the row's own `lastUsed`. A different verb from a project's
/// "last changed", because it is a different fact: how long this has been sitting here.
@Test func aPerItemCardSaysWhenTheFileArrived() throws {
    let fiveMonthsAgo = now.addingTimeInterval(-150 * 86_400)
    let built = deck([
        downloadRow(name: "Xcode_26.1_beta.xip", sizeBytes: 7_000_000_000,
                    lastUsed: fiveMonthsAgo),
        downloadRow(name: "undated.dmg", sizeBytes: 3_000_000_000),
    ])

    let dated = try #require(built.cards.first { $0.name == "Xcode_26.1_beta.xip" })
    #expect(dated.lastChangedText == "added 5 months ago")
    // No date, no guess. `nil` rather than "added today", which is the reading that most
    // strongly says leave this alone.
    let undated = try #require(built.cards.first { $0.name == "undated.dmg" })
    #expect(undated.lastChangedText == nil)
}

/// A per-item row under the floor folds into the small-things line exactly as a small
/// project does, so its bytes are still accounted for.
@Test func aSmallPerItemRowFoldsIntoTheSmallThingsLine() {
    let built = deck([
        xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000),
        xdgCacheRow(name: "tiny", sizeBytes: 4_000_000),
        xdgCacheRow(name: "alsoTiny", sizeBytes: 3_000_000),
    ])

    #expect(built.cards.map(\.name) == ["uv"])
    #expect(built.smallThingsText == "2 small things under 50 MB were not shown · 7 MB")
}

// MARK: - the user's own files come last, behind a card that says so

/// **The two halves are never mixed by size.** A 19 GB language model does not get dealt
/// before a 9 GB cache: everything that comes back on its own is asked about first, biggest
/// first, and only then the things that do not.
@Test func bigThingsAreDealtAfterEveryRegenerableCardAndNeverMixedBySize() throws {
    let built = deck([
        modelRow(publisher: "lmstudio-community", model: "Qwen3-30B-GGUF",
                 sizeBytes: 19_000_000_000),
        downloadRow(name: "Xcode_26.1_beta.xip", sizeBytes: 7_000_000_000),
        toolRow(scanner: "xcode.derivedData", name: "Runner",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner",
                sizeBytes: 9_100_000_000),
        folderRow(project: "game", folder: "build", sizeBytes: 3_300_000_000),
    ])

    #expect(built.cards.map(\.name) == [
        // Regenerable, biggest first. The grouped card is titled by its scanner ("Derived
        // data"); a per-item card is titled by its row.
        "Derived data", "game",
        // Then the card that says the promise is changing.
        ProjectDeckText.interstitialHeadline,
        // Then the user's own files, biggest first among themselves.
        "lmstudio-community/Qwen3-30B-GGUF", "Xcode_26.1_beta.xip",
    ])
    #expect(built.cards.map(\.isBigThing) == [false, false, false, true, true])
    #expect(built.cards.filter { $0.isInterstitial }.count == 1)
}

/// No big things, no interstitial. A card introducing an empty second half would be a card
/// the user has to press to be told there is nothing there.
@Test func thereIsNoInterstitialWhenNothingBigIsOffered() {
    let built = deck([
        folderRow(project: "game", folder: "build", sizeBytes: 3_300_000_000),
        xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000),
    ])

    #expect(built.cards.contains { $0.isInterstitial } == false)
    #expect(built.cards.map(\.name) == ["game", "uv"])
}

/// The interstitial's number and its count come from the cards behind it, so they cannot
/// disagree with what the deck is about to deal — and the sentence deliberately does not
/// repeat the amount, which is set at 96 points two lines above it.
@Test func theInterstitialCountsAndTotalsTheCardsBehindIt() throws {
    let built = deck([
        modelRow(publisher: "lmstudio-community", model: "Qwen3-30B-GGUF",
                 sizeBytes: 19_000_000_000),
        downloadRow(name: "Xcode_26.1_beta.xip", sizeBytes: 7_000_000_000),
        downloadRow(name: "recordings.zip", sizeBytes: 3_000_000_000,
                    detail: DownloadsScanner.archiveDetail),
    ])

    let card = try #require(built.cards.first { $0.isInterstitial })
    #expect(card.id == ProjectDeck.interstitialCardID)
    #expect(card.name == "That's everything that comes back.")
    #expect(card.eyebrow == "Big things")
    #expect(card.totalBytes == 29_000_000_000)
    #expect(card.totalText == "29.0 GB")
    #expect(card.folderCountText
            == "Next: 3 big things that are yours. They do not come back; "
            + "they go to the Trash only if you say so.")
    #expect(card.promiseText == "Looking through them decides nothing.")
    // It offers nothing to the engine, which is the other half of why `AppModel` answers it
    // without calling one.
    #expect(card.items.isEmpty)
    #expect(card.folders.isEmpty)
    #expect(card.pathText == nil)
    #expect(card.revealURL == nil)
    // Both buttons come off the card: "Look through them" and "Skip them all". Looking
    // costs nothing, so Return still answers it.
    #expect(card.primaryActionTitle == "Look through them")
    #expect(card.secondaryActionTitle == "Skip them all")
    #expect(card.primaryActionKeyHint == ProjectDeckText.cleanUpKeyHint)
    #expect(card.answersToReturn)
}

/// Singular, so the sentence never reads "1 big things".
@Test func theInterstitialCountsOneBigThingInTheSingular() throws {
    let built = deck([downloadRow(name: "Docker.dmg", sizeBytes: 4_000_000_000)])
    let card = try #require(built.cards.first { $0.isInterstitial })
    #expect(card.folderCountText
            == "Next: 1 big thing that is yours. It does not come back; "
            + "it goes to the Trash only if you say so.")
}

/// **The card that has to be clicked.** Everything about it says the promise is different:
/// the eyebrow, the caution, the button's verb, and the absence of a Return key.
@Test func aBigThingCardMustBeClickedAndSaysWhyTwice() throws {
    let built = deck([downloadRow(name: "Xcode_26.1_beta.xip", sizeBytes: 7_000_000_000)])

    let card = try #require(built.cards.first { $0.isBigThing })
    #expect(card.eyebrow == "Big, but yours")
    #expect(card.name == "Xcode_26.1_beta.xip")
    #expect(card.cautionLines == [
        "This does not come back. It goes to the Trash, where you can still get it back.",
    ])
    #expect(card.primaryActionTitle == "Move 7.0 GB to Trash")
    // No key at all, and no glyph promising one. The same mechanism the permanent cards use
    // — nine reversible cards in a row train the user's hand, and this is the press that
    // moves something nothing will bring back.
    #expect(card.answersToReturn == false)
    #expect(card.primaryActionKeyHint == nil)
    #expect(card.secondaryActionTitle == ProjectDeckText.skip)
    // And the quiet action, because this is a file the user chose to have: only Finder can
    // answer "is this the archive I still need?".
    #expect(card.revealURL == URL(fileURLWithPath: "/Users/test/Downloads/Xcode_26.1_beta.xip"))
    #expect(ProjectDeckText.showInFinder == "Show in Finder")
    // Amber rather than blue: the colour must not say "the next build remakes it".
    #expect(card.folders.map(\.needsDownload) == [true])
}

/// **The one promise line in the deck that does not depend on the Trash setting**, because
/// the thing it describes does not either: the executor always trashes one of the user's own
/// files. `toolPromise` here would print "deleted — for good" about a file that is going to
/// be sitting in the user's Trash.
@Test func aBigThingsPromiseIsTheSameInBothModes() throws {
    let rows = [downloadRow(name: "Docker.dmg", sizeBytes: 4_000_000_000)]
    let expected = "It goes to the Trash whatever your settings say. "
        + "Your own files are never deleted outright."

    let trash = try #require(deck(rows, moveToTrash: true).cards.first { $0.isBigThing })
    let permanent = try #require(
        deck(rows, moveToTrash: false).cards.first { $0.isBigThing })

    #expect(trash.promiseText == expected)
    #expect(permanent.promiseText == expected)
    // Rule 4: an ordinary card in the same two decks really does change, so this is a
    // property of the big-thing card and not of the fixture.
    let ordinaryTrash = deck([xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000)],
                             moveToTrash: true).cards.first?.promiseText
    let ordinaryPermanent = deck([xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000)],
                                 moveToTrash: false).cards.first?.promiseText
    #expect(ordinaryTrash != ordinaryPermanent)
}

// MARK: - the device support card keeps the folder Xcode is using

/// The kept folder is named on the card and **never handed to the engine**.
///
/// A card showing 13.7 GB where the disk says 27 GB looks like a measurement that cannot be
/// trusted, so the kept rows get the quiet line under the list — in the reason's own words,
/// which is also where the user would go to understand it.
@Test func theDeviceSupportCardKeepsTheFolderXcodeIsUsingAndSaysSo() throws {
    let built = deck([
        deviceSupportRow(name: "iPhone17,2 27.0 (24A435)", sizeBytes: 7_000_000_000,
                         isKept: true),
        deviceSupportRow(name: "iPad15,7 26.6 (23G71)", sizeBytes: 6_000_000_000,
                         isKept: true),
        deviceSupportRow(name: "iPhone17,2 27.0 (24A5424a)", sizeBytes: 6_800_000_000),
        deviceSupportRow(name: "iPhone17,2 27.0 (24A5430a)", sizeBytes: 6_900_000_000),
    ])

    let card = try #require(built.cards.first { $0.id == "xcode.deviceSupport" })
    #expect(card.keptText == "2 kept · newest for this device · 13.0 GB")
    // Only the two older builds are offered, and only they can reach `engine.clean`.
    #expect(card.folders.map(\.name)
            == ["iOS iPhone17,2 27.0 (24A5430a)", "iOS iPhone17,2 27.0 (24A5424a)"])
    #expect(card.items.allSatisfy { $0.protection == nil })
    #expect(card.items.count == 2)
    #expect(card.totalBytes == 13_700_000_000)
    // Amber, because nothing on this Mac rebuilds it: the symbols come off the device.
    #expect(card.folders.allSatisfy { $0.needsDownload })
}

// MARK: - the session strip, once one of the user's own files is in it

/// The same helper, for a deck that has big things in it. A slot remembers whether it was
/// one, because the card is gone once its rows are pruned and both the skyline's colour and
/// the end card's line still need the answer.
private func bigSlots(_ triples: [(String, Int64, Bool)]) -> [ProjectDeckSlot] {
    triples.map { ProjectDeckSlot(id: $0.0, totalBytes: $0.1, isBigThing: $0.2) }
}

/// A cleaned big thing gets its own reading in the strip, so the shape of the session shows
/// **where the promise changed** — nine caches and one language model are two different
/// things and a strip of one colour would say they were the same.
@Test func aCleanedBigThingGetsItsOwnSkylineState() {
    let summary = ProjectDeckSummary(
        slots: bigSlots([("cache", 9_000_000_000, false), ("model", 18_000_000_000, true),
                         ("download", 7_000_000_000, true)]),
        decisions: [
            "cache": .cleaned(trashedBytes: 9_000_000_000, deletedBytes: 0, problems: []),
            "model": .cleaned(trashedBytes: 18_000_000_000, deletedBytes: 0, problems: []),
        ],
        currentCardID: "download", moveToTrash: true)

    #expect(summary.skyline.map(\.state) == [.cleaned, .cleanedBigThing, .current])
    // Skipping one reads the same as skipping anything else: nothing happened to it, so
    // there is no promise to have changed.
    let skipped = ProjectDeckSummary(
        slots: bigSlots([("model", 18_000_000_000, true)]),
        decisions: ["model": .skipped], currentCardID: nil, moveToTrash: true)
    #expect(skipped.skyline.map(\.state) == [.skipped])
}

/// The end card counts them on a line of their own — as a **breakdown** of the Trash line
/// above, not a further amount, because the user's own files always go to the Trash and
/// their bytes are already in it.
@Test func theEndCardCountsBigThingsOnALineOfTheirOwn() {
    let summary = ProjectDeckSummary(
        slots: bigSlots([("cache", 4_400_000_000, false), ("model", 18_000_000_000, true),
                         ("download", 3_000_000_000, true)]),
        decisions: [
            "cache": .cleaned(trashedBytes: 4_400_000_000, deletedBytes: 0, problems: []),
            "model": .cleaned(trashedBytes: 18_000_000_000, deletedBytes: 0, problems: []),
            "download": .cleaned(trashedBytes: 3_000_000_000, deletedBytes: 0, problems: []),
        ],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.endDetailLines == [
        "25.4 GB moved to the Trash",
        "including 2 big things · 21.0 GB",
        "from 3 cards",
    ])
    // 25.4 GB really is the whole of it: the 21.0 GB is inside that figure, which is why
    // the line says "including" rather than naming a second amount.
    #expect(summary.sessionTrashedBytes == 25_400_000_000)
    #expect(summary.sessionBytes == 25_400_000_000)
}

/// Singular, and absent when none was cleaned — a session that skipped every big thing has
/// no such line to draw.
@Test func theBigThingsLineIsSingularForOneAndAbsentForNone() {
    let one = ProjectDeckSummary(
        slots: bigSlots([("model", 18_000_000_000, true)]),
        decisions: ["model": .cleaned(trashedBytes: 18_000_000_000, deletedBytes: 0,
                                      problems: [])],
        currentCardID: nil, moveToTrash: true)
    #expect(one.endDetailLines == [
        "18.0 GB moved to the Trash", "including 1 big thing · 18.0 GB", "from 1 card",
    ])

    let none = ProjectDeckSummary(
        slots: bigSlots([("cache", 4_400_000_000, false), ("model", 18_000_000_000, true)]),
        decisions: [
            "cache": .cleaned(trashedBytes: 4_400_000_000, deletedBytes: 0, problems: []),
            "model": .skipped,
        ],
        currentCardID: nil, moveToTrash: true)
    #expect(none.endDetailLines == ["4.4 GB moved to the Trash", "from 1 card"])
}

/// **Answering the interstitial is not a skipped card.** It holds no slot, because it holds
/// no bytes, and the skip count is taken over the slots for exactly this reason: read off
/// the decisions, "Skip them all" would report one more skipped card than the deck ever had
/// with nothing in `skippedBytes` to account for it.
@Test func answeringTheInterstitialIsNeverCountedAsASkippedCard() {
    let summary = ProjectDeckSummary(
        slots: bigSlots([("model", 18_000_000_000, true)]),
        decisions: [
            ProjectDeck.interstitialCardID: .skipped,
            "model": .skipped,
        ],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.skippedCount == 1)
    #expect(summary.skippedText == "1 skipped · 18.0 GB")
    #expect(summary.skippedBytes == 18_000_000_000)
    #expect(summary.skyline.map(\.id) == ["model"])
    // And the headline is still the one for a session where something happened, rather than
    // "Nothing to clean up." — the user did decide, twice.
    #expect(summary.endHeadline == ProjectDeckText.endHeadline)
    #expect(summary.endDetailLines == [ProjectDeckText.endDetailNothingCleaned])
}

/// No bar is `current` while the interstitial is on screen, and there is no position to
/// print. The card's own headline is what says where the user is — see
/// `ProjectDeck.interstitialCardID`.
@Test func theInterstitialHasNoPositionAndNoCurrentBar() {
    let summary = ProjectDeckSummary(
        slots: bigSlots([("cache", 9_000_000_000, false), ("model", 18_000_000_000, true)]),
        decisions: ["cache": .cleaned(trashedBytes: 9_000_000_000, deletedBytes: 0,
                                      problems: [])],
        currentCardID: ProjectDeck.interstitialCardID, moveToTrash: true)

    #expect(summary.positionText == nil)
    #expect(summary.skyline.map(\.state) == [.cleaned, .upcoming])
}

/// A big-things scanner **this build has never heard of** still gets a card that cannot be
/// answered by Return.
///
/// Reachable through the cache: a `cache.json` a newer build wrote holds a scanner
/// identifier this one has no entry for, so `CleanerService.scanner(withID:)` answers `nil`,
/// its `DeckDealing` is unknown, and its rows fall back to one grouped card. Every one of the
/// card's dangerous properties is read off the **rows' group** rather than off a list of
/// big-things scanners kept in the deck, so that fallback card is still click-only, still
/// sorted after everything that comes back, and still carries the promise that does not
/// depend on the Trash setting.
@Test func aBigThingsScannerThisBuildDoesNotKnowIsStillDealtAsOne() throws {
    let unknown = CleanupItem(
        id: "big.photoLibraries|/Users/test/Pictures/old.photoslibrary",
        scannerID: "big.photoLibraries", group: .bigThings,
        name: "old.photoslibrary", detail: "A folder.", sizeBytes: 40_000_000_000,
        lastUsed: nil, risk: .irreplaceable, protection: nil,
        method: .removePath("/Users/test/Pictures/old.photoslibrary"),
        startsUnticked: true)
    let built = deck([unknown, xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000)],
                     moveToTrash: false)

    // Sorted after the 1.1 GB cache despite being forty times its size, and behind the
    // card that says the promise has changed.
    #expect(built.cards.map(\.id)
            == ["other.xdgCache|/Users/test/.cache/uv", ProjectDeck.interstitialCardID,
                "big.photoLibraries"])
    let card = try #require(built.cards.last)
    #expect(card.isBigThing)
    #expect(card.kind == .bigThing(scannerID: "big.photoLibraries"))
    #expect(card.answersToReturn == false)
    #expect(card.primaryActionKeyHint == nil)
    #expect(card.primaryActionTitle == "Move 40.0 GB to Trash")
    #expect(card.eyebrow == "Big, but yours")
    #expect(card.cautionLines.first == ProjectDeckText.bigThingCaution)
    // Permanent mode, and the promise still says the Trash — because that is what the
    // executor will really do with an `.irreplaceable` row.
    #expect(card.promiseText == ProjectDeckText.bigThingPromise)
    // The scanner's name could not be looked up, so the card is headed by the identifier
    // rather than hiding 40 GB with nothing on screen to explain it.
    #expect(card.name == "big.photoLibraries")
}

/// A card holding **both** a device and one of the user's own files keeps the permanence
/// wording, which is the stronger claim — and is click-only either way, which is the
/// property that matters. Nothing produces such a card; this pins which reading wins if
/// anything ever does.
@Test func permanenceWinsOverTheUsersOwnFilesOnACardHoldingBoth() throws {
    let device = simulatorRow(name: "iPhone 17 Pro", udid: "UDID-1",
                              sizeBytes: 12_000_000_000)
    let odd = CleanupItem(
        id: "ios.simulators|/Users/test/Downloads/weird", scannerID: "ios.simulators",
        group: .bigThings, name: "weird", detail: nil, sizeBytes: 1_000_000_000,
        lastUsed: nil, risk: .irreplaceable, protection: nil,
        method: .removePath("/Users/test/Downloads/weird"), startsUnticked: true)
    let built = deck([device, odd])

    let card = try #require(built.cards.first { $0.id == "ios.simulators" })
    #expect(card.primaryActionTitle == ProjectDeckText.deleteForGood("13.0 GB"))
    #expect(card.cautionLines.contains(ProjectDeckText.permanentCaution))
    #expect(card.cautionLines.contains(ProjectDeckText.bigThingCaution) == false)
    #expect(card.answersToReturn == false)
    #expect(card.primaryActionKeyHint == nil)
}

/// Both counts are taken over the **slots**, not over the decisions.
///
/// The skip count is where it is load-bearing — answering the interstitial records a
/// `.skipped` decision, and it holds no slot — but the cleaned count is restricted the same
/// way for symmetry: counted off the decisions, the next card without a slot would be free
/// to appear in "from 4 cards" with no bytes anywhere accounting for it.
@Test func bothEndCardCountsAreTakenOverTheSlotsRatherThanTheDecisions() {
    let summary = ProjectDeckSummary(
        slots: slots([("cache", 4_400_000_000)]),
        decisions: [
            "cache": .cleaned(trashedBytes: 4_400_000_000, deletedBytes: 0, problems: []),
            // Two decisions with no slot at all: the interstitial, and a card a later scan
            // dropped before it was ever dealt.
            ProjectDeck.interstitialCardID: .skipped,
            "vanished": .cleaned(trashedBytes: 9_000_000_000, deletedBytes: 0, problems: []),
        ],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.cleanedCount == 1)
    #expect(summary.skippedCount == 0)
    #expect(summary.endDetailLines == ["13.4 GB moved to the Trash", "from 1 card"])
    // The **bytes** deliberately still come from every decision: those really did move, and
    // a session total that forgot them would be a number the disk disagrees with. Only the
    // card counts are about the deck's own shape.
    #expect(summary.sessionTrashedBytes == 13_400_000_000)
}

// MARK: - the scanners the app mentions rather than deals

/// **A `.mentionOnly` scanner's rows are counted nowhere the deck counts anything.**
///
/// The user asked for the browser caches and the desktop app caches out of the deck and
/// mentioned on the last page instead. "Out of the deck" is not one thing: a card, a slot in
/// the skyline, a place in "3 of 24", a share of the small-things line, a name in the
/// kept-tools line and a contribution to the menu bar's amount are six separate ways for
/// 4.5 GB to come back and be asked about. Each of them is checked here, because each is a
/// separate read of `result.items` somewhere downstream.
@Test func aMentionOnlyScannerGetsNoCardAndIsCountedInNoDeckTotal() {
    let built = deck([
        toolRow(scanner: "xcode.derivedData", name: "Runner",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner",
                sizeBytes: 9_100_000_000),
        appCacheRow(name: "Brave browsing cache",
                    relativePath: "Library/Caches/BraveSoftware", sizeBytes: 3_200_000_000),
        electronCacheRow(app: "Slack", folder: "Cache", sizeBytes: 1_300_000_000),
    ])

    #expect(built.cards.map(\.id) == ["xcode.derivedData"])
    #expect(built.cards.flatMap(\.items).allSatisfy { $0.scannerID == "xcode.derivedData" })
    // Not "not shown", and not small: folding 4.5 GB into a line reading "small things under
    // 50 MB" would be the one arithmetically false line on the end card.
    #expect(built.smallThingsText == nil)
    // Not "left alone because they are in use" either — nothing is using them, the app has
    // decided not to be the thing that removes them.
    #expect(built.keptToolsText == nil)
    // And not in the amount the status panel shows, which is what a pass through the deck
    // would take: there is nothing in the deck to press.
    #expect(built.defaultOfferBytes == 9_100_000_000)
}

/// The note itself: one line per thing, biggest first, with its size.
///
/// "More space to gain: list of caches and their size in GB" is what was asked for, and the
/// list is where the honesty of the whole arrangement sits — the app measured this and will
/// not touch it, so the least it can do is say how much there is.
@Test func theEndCardNamesEveryMentionedCacheWithItsSize() throws {
    let built = deck([
        appCacheRow(name: "Brave browsing cache",
                    relativePath: "Library/Caches/BraveSoftware", sizeBytes: 3_200_000_000),
        appCacheRow(name: "Chrome browsing cache",
                    relativePath: "Library/Caches/Google/Chrome", sizeBytes: 1_200_000_000),
        electronCacheRow(app: "Slack", folder: "Cache", sizeBytes: 1_300_000_000),
        electronCacheRow(app: "Claude", folder: "Cache", sizeBytes: 1_100_000_000),
    ])

    let more = try #require(built.moreToGain)
    #expect(more.title == "More space to gain")
    #expect(more.lines == [
        "Brave browsing cache · 3.2 GB",
        "Slack · 1.3 GB",
        "Chrome browsing cache · 1.2 GB",
        "Claude · 1.1 GB",
    ])
    #expect(more.note == "DevCleaner never removes these. "
            + "Each one belongs to the app that wrote it, and that app is where to clear it.")
}

/// **Electron rows are summed per app**, and the app comes from the scanner's own rule.
///
/// `other.electronCaches` produces one row per cache *subfolder* because a `removePath` is
/// one path — six for Slack alone — and six lines reading "Slack – GPUCache", "Slack – Code
/// Cache" are six lines nobody can act on. One "Slack · 1.6 GB" is the number the user
/// wanted. The split is `ElectronCacheScanner.app(ofRowNamed:)`, not an en dash the deck
/// knows about, so rewording a row cannot quietly stop the summing.
@Test func theMentionedElectronRowsAreSummedPerAppRatherThanListedPerFolder() throws {
    let built = deck([
        electronCacheRow(app: "Slack", folder: "Cache", sizeBytes: 900_000_000),
        electronCacheRow(app: "Slack", folder: "Code Cache", sizeBytes: 400_000_000),
        electronCacheRow(app: "Slack", folder: "GPUCache", sizeBytes: 300_000_000),
        electronCacheRow(app: "Code", folder: "CachedData", sizeBytes: 1_900_000_000),
    ])

    let more = try #require(built.moreToGain)
    #expect(more.lines == ["Code · 1.9 GB", "Slack · 1.6 GB"])
}

/// The floor goes on the **line**, after the summing, and that half is load-bearing.
///
/// Six 40 MB Slack folders are 240 MB the user might want; a floor applied row by row would
/// drop all six and report nothing. An entry that is genuinely under the floor is dropped
/// outright rather than folded into the "and N more" count — "and 9 more · 60 MB" over nine
/// lines nobody would have read is a worse answer than silence.
@Test func theMentionedListsFloorIsAppliedAfterTheSummingAndNotBeforeIt() throws {
    let built = deck([
        electronCacheRow(app: "Slack", folder: "Cache", sizeBytes: 40_000_000),
        electronCacheRow(app: "Slack", folder: "Code Cache", sizeBytes: 40_000_000),
        electronCacheRow(app: "Slack", folder: "GPUCache", sizeBytes: 40_000_000),
        electronCacheRow(app: "Slack", folder: "CachedData", sizeBytes: 40_000_000),
        electronCacheRow(app: "Slack", folder: "CachedExtensionVSIXs", sizeBytes: 40_000_000),
        electronCacheRow(app: "Slack", folder: "Service Worker/CacheStorage",
                         sizeBytes: 40_000_000),
        // Under the floor on its own and with nothing to add to.
        appCacheRow(name: "Firefox cache", relativePath: "Library/Caches/Firefox",
                    sizeBytes: 12_000_000),
    ])

    let more = try #require(built.moreToGain)
    #expect(more.lines == ["Slack · 240 MB"])
    #expect(ProjectDeck.minimumCardBytes == 50_000_000)
}

/// Six lines, then the rest folded into one that keeps the total.
///
/// The section is a footnote under two other quiet blocks at the bottom of the end card, and
/// a real machine has ten or twelve entries over the floor. What the fold has to keep is the
/// **amount**: a reader who cannot see the seventh line can still see what the seventh
/// onwards come to, which is what tells them whether to go looking.
@Test func theMentionedListShowsSixLinesAndFoldsTheRestIntoOneWithItsTotal() throws {
    let built = deck([
        appCacheRow(name: "Brave browsing cache",
                    relativePath: "Library/Caches/BraveSoftware", sizeBytes: 3_200_000_000),
        electronCacheRow(app: "Code", folder: "CachedData", sizeBytes: 1_900_000_000),
        electronCacheRow(app: "Cursor", folder: "Cache", sizeBytes: 1_400_000_000),
        electronCacheRow(app: "Slack", folder: "Cache", sizeBytes: 1_300_000_000),
        appCacheRow(name: "Chrome browsing cache",
                    relativePath: "Library/Caches/Google/Chrome", sizeBytes: 1_200_000_000),
        electronCacheRow(app: "Claude", folder: "Cache", sizeBytes: 1_100_000_000),
        // The seventh onwards: 412 MB between them.
        electronCacheRow(app: "Notion", folder: "Cache", sizeBytes: 200_000_000),
        electronCacheRow(app: "Figma", folder: "Cache", sizeBytes: 112_000_000),
        appCacheRow(name: "Spotify cache", relativePath: "Library/Caches/com.spotify.client",
                    sizeBytes: 100_000_000),
    ])

    let more = try #require(built.moreToGain)
    #expect(more.lines.count == ProjectDeck.moreToGainLines + 1)
    #expect(more.lines.last == "and 3 more · 412 MB")
    #expect(ProjectDeck.moreToGainLines == 6)
}

/// No section at all when there is nothing to say — no heading, no note.
///
/// A machine with no browser and no Electron app has no more space to gain, and a heading
/// standing over an empty list is furniture. The same `nil` covers the case where everything
/// found is under the floor.
@Test func thereIsNoMoreToGainSectionWhenThereIsNothingToMention() {
    #expect(deck([xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000)]).moreToGain == nil)
    #expect(deck([
        appCacheRow(name: "Firefox cache", relativePath: "Library/Caches/Firefox",
                    sizeBytes: 12_000_000),
    ]).moreToGain == nil)
    // And on the deck that reaches the "Nothing to clean up." card, where it is the one
    // thing on screen with a number on it.
    #expect(deck([]).moreToGain == nil)
}

// MARK: - a folder in ~/.cache whose tool the app cannot name

/// **Not answerable by reflex.** The card is dealt, and it has to be clicked.
///
/// `other.xdgCache` is the one scanner that offers folders it has no name for, and the only
/// grounds for doing so are the XDG convention: everything in `~/.cache` is disposable and
/// re-created by whichever tool wrote it. The `huggingface` card is what that convention
/// being wrong once cost — a dictation app down until it had re-fetched 1.1 GB. The model
/// stores are excluded by name now, but the next one has not been published yet, so an
/// unnamed folder gets the caution, loses the Return key, and its button goes amber.
@Test func anUnknownToolInTheCacheGetsACautionAndNoReturnKey() throws {
    let built = deck([
        xdgCacheRow(name: "nimbus", sizeBytes: 2_400_000_000),
        xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000),
    ])

    let unknown = try #require(built.cards.first { $0.name == "nimbus" })
    #expect(unknown.cautionLines == [ProjectDeckText.unknownToolCaution])
    #expect(ProjectDeckText.unknownToolCaution
            == "DevCleaner does not know this tool. It should rebuild this folder, "
            + "but it may have to download things again.")
    #expect(unknown.answersToReturn == false)
    #expect(unknown.primaryActionKeyHint == nil)
    #expect(unknown.primaryActionTone == .deliberate)
    // The verb is still right — this really is a cache that should rebuild — so the label is
    // unchanged. The friction is the caution, the missing key and the colour.
    #expect(unknown.primaryActionTitle == "Clean up 2.4 GB")

    // Rule 4: the tool the app **can** name is untouched by all of it.
    let known = try #require(built.cards.first { $0.name == "uv" })
    #expect(known.cautionLines.isEmpty)
    #expect(known.answersToReturn)
    #expect(known.primaryActionKeyHint == ProjectDeckText.cleanUpKeyHint)
    #expect(known.primaryActionTone == .regenerable)
}

/// A stale `huggingface` row — the incident's own card, arriving out of a `cache.json` an
/// older build wrote — is the **hardest** card in the deck to answer, not the easiest.
///
/// The scanner cannot produce it any more, so this is the only way one can reach the window.
/// `XDGCacheScanner.knows` answers `false` for every excluded store for exactly this reason:
/// the safe direction for the name that caused the incident is the one that takes the key
/// away.
@Test func aStaleHuggingFaceCardFromAnOlderCacheIsClickOnly() throws {
    let built = deck([xdgCacheRow(
        name: "huggingface", sizeBytes: 1_250_000_000,
        detail: "models are downloaded again when a script next asks for them")])

    let card = try #require(built.cards.first)
    #expect(card.name == "huggingface")
    #expect(card.cautionLines == [ProjectDeckText.unknownToolCaution])
    #expect(card.answersToReturn == false)
    #expect(card.primaryActionTone == .deliberate)
}

/// The predicate the card reads, checked on its own so the gate on the scanner identifier is
/// visible.
///
/// Without it, every row in the deck whose name is not one of nine tool names — every
/// project, every simulator, every derived data folder — would answer `true`.
@Test func onlyACacheFolderCanBeAnUnknownTool() {
    #expect(ProjectDeck.isUnfamiliarTool(xdgCacheRow(name: "nimbus", sizeBytes: 1)))
    #expect(!ProjectDeck.isUnfamiliarTool(xdgCacheRow(name: "uv", sizeBytes: 1)))
    // A name added to `knownDetails` loses the caution and gets its Return key on the
    // strength of that alone — which is what makes adding one a decision, not a detail.
    #expect(!ProjectDeck.isUnfamiliarTool(
        xdgCacheRow(name: "codex-runtimes", sizeBytes: 1)))
    #expect(!ProjectDeck.isUnfamiliarTool(toolRow(
        scanner: "xcode.derivedData", name: "Runner",
        relativePath: "Library/Developer/Xcode/DerivedData/Runner", sizeBytes: 1)))
    #expect(!ProjectDeck.isUnfamiliarTool(
        folderRow(project: "game", folder: ".build", sizeBytes: 1)))
    #expect(!ProjectDeck.isUnfamiliarTool(
        downloadRow(name: "Docker.dmg", sizeBytes: 1)))
}

/// An unticked unknown row is still **dealt**, which is the other half of the arrangement.
///
/// The scanner leaves it out of every default clean, and the deck puts it on a card with its
/// size and its caution and waits — so pressing Clean up under all that is the user asking
/// for exactly this folder. The row filter for tool cards admits `startsUnticked` rows on
/// purpose; a filter that read `selectedByDefault` would hide 2.4 GB with nothing on screen
/// to explain it.
@Test func anUntickedUnknownCacheRowStillGetsItsOwnCard() throws {
    let built = deck([xdgCacheRow(name: "glimmer2", sizeBytes: 2_400_000_000)])

    let card = try #require(built.cards.first)
    #expect(card.items.map(\.name) == ["glimmer2"])
    #expect(card.items.allSatisfy { $0.startsUnticked })
    #expect(card.totalText == "2.4 GB")
    // And it is **not** in the amount the status panel shows: that number is what a pass
    // through the deck would take if the user decided nothing, and nothing takes this.
    #expect(built.defaultOfferBytes == 0)
}

// MARK: - the primary button's colour

/// **Amber exactly when the button has to be clicked.**
///
/// Until now every primary button in the window was `DeckStyle.rebuild`, and in this app's
/// palette that blue means something: it is the colour a row's bar goes when the next build
/// remakes it. So "Delete 21.4 GB for good" and "Move 23.1 GB to Trash" were drawn in the
/// colour that says *this comes back by itself*, beside rows painted amber for saying the
/// opposite.
///
/// The tone is derived from `answersToReturn` rather than stored beside it, so the key and
/// the colour cannot part company — a card that lost its Return key without changing colour
/// would look like the nine safe ones and not answer the key the user has been pressing.
@Test func thePrimaryButtonIsAmberOnExactlyTheCardsThatHaveToBeClicked() throws {
    let built = deck([
        // Blue: comes back, answers Return.
        toolRow(scanner: "xcode.derivedData", name: "Runner",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner",
                sizeBytes: 9_100_000_000),
        folderRow(project: "game", folder: "build", sizeBytes: 3_300_000_000),
        xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000),
        // Amber: the app cannot name the tool.
        xdgCacheRow(name: "nimbus", sizeBytes: 2_400_000_000),
        // Amber: deleted for good, no Trash.
        simulatorRow(name: "iPhone 17 Pro", udid: "UDID-1", sizeBytes: 21_400_000_000),
        // Amber: the user's own file.
        downloadRow(name: "Xcode_26.1_beta.xip", sizeBytes: 7_000_000_000),
    ])

    var tones: [String: ProjectCard.PrimaryActionTone] = [:]
    for card in built.cards { tones[card.name] = card.primaryActionTone }

    #expect(tones["Derived data"] == .regenerable)
    #expect(tones["game"] == .regenerable)
    #expect(tones["uv"] == .regenerable)
    #expect(tones["nimbus"] == .deliberate)
    #expect(tones["iOS simulators"] == .deliberate)
    #expect(tones["Xcode_26.1_beta.xip"] == .deliberate)
    // **The interstitial stays blue.** Its "Look through them" removes nothing and answers
    // Return, which is what the tone follows — the plan's own rule, that the colour is
    // amber exactly where the key is gone.
    #expect(tones[ProjectDeckText.interstitialHeadline] == .regenerable)

    // Said once more as the rule rather than as six examples, over every card in the deck.
    for card in built.cards {
        #expect(card.primaryActionTone == (card.answersToReturn ? .regenerable : .deliberate),
                "\(card.name)")
    }
}

// MARK: - the models the incident moved

/// A Hugging Face model is dealt exactly as an LM Studio one is, and named after the model.
///
/// This is the card that should have existed instead of `huggingface`. It is behind the
/// interstitial, it has no Return key, its promise says the Trash whatever the settings say,
/// and — the whole point — its heading is a name the user can recognise as the thing their
/// dictation app needs.
@Test func aHuggingFaceModelIsDealtAsOneOfTheUsersOwnThingsUnderItsOwnName() throws {
    let built = deck([
        huggingFaceModelRow(org: "ml-labs", model: "whisper-large-v3-gguf",
                            sizeBytes: 1_250_000_000),
        ollamaRow(sizeBytes: 4_700_000_000),
    ], moveToTrash: false)

    let model = try #require(
        built.cards.first { $0.name == "ml-labs/whisper-large-v3-gguf" })
    #expect(model.isBigThing)
    #expect(model.eyebrow == ProjectDeckText.bigThingEyebrow)
    #expect(model.pathText == "~/.cache/huggingface/hub")
    #expect(model.folderCountText == AIModelScanner.huggingFaceDetail)
    #expect(model.primaryActionTitle == "Move 1.2 GB to Trash")
    #expect(model.answersToReturn == false)
    #expect(model.primaryActionTone == .deliberate)
    // Permanent mode, and the promise still says the Trash, because that is what the
    // executor really does with an `.irreplaceable` row.
    #expect(model.promiseText == ProjectDeckText.bigThingPromise)
    #expect(model.cautionLines == [ProjectDeckText.bigThingCaution])
    // And Finder, because "is this the model I still use?" is a question only looking can
    // answer.
    #expect(model.revealURL == URL(fileURLWithPath:
        "/Users/test/.cache/huggingface/hub/models--ml-labs--whisper-large-v3-gguf"))

    // Ollama's one row is the whole store, and it is dealt the same way.
    let ollama = try #require(built.cards.first { $0.name == "Ollama models" })
    #expect(ollama.isBigThing)
    #expect(ollama.pathText == "~/.ollama")
    #expect(ollama.folderCountText
            == "Every model Ollama downloaded. ollama pull gets them back.")
    #expect(ollama.answersToReturn == false)

    // Both behind the card that says the promise has changed, and neither in the amount the
    // status panel shows.
    #expect(built.cards.map(\.isBigThing) == [false, true, true])
    #expect(built.cards.first?.isInterstitial == true)
    #expect(built.defaultOfferBytes == 0)
}

// MARK: - the page with the checkboxes

/// The files `big.largeFiles` finds, in no particular order and with two of them sharing a
/// name — which is the case the row's folder line exists for, and the reason a row's identity
/// is its identifier.
///
/// Four rather than the fifty-six a real home folder answers with. It is enough to tell every
/// rule on the page apart, and the sizes are the real ones off the machine this page was
/// written for.
private func largeFiles() -> [CleanupItem] {
    [
        largeFileRow(name: "cards.db", folder: "dev/workspace-two/client-app/tools/carddb/out",
                     sizeBytes: 876_000_000),
        largeFileRow(name: "scan.pdf", folder: "Documents/archive/scans/batch-a/current",
                     sizeBytes: 1_200_000_000, lastUsed: now.addingTimeInterval(-86_400 * 90)),
        largeFileRow(name: "gallery_1fps.rgb", folder: "dev/lesson-tool/work/lesson43/frames",
                     sizeBytes: 648_000_000),
        largeFileRow(name: "scan.pdf", folder: "Documents/archive/scans/batch-b/current",
                     sizeBytes: 600_000_000),
    ]
}

/// **One page, and nothing ticked on it**, which is what the user asked for after living with
/// the page: nothing unchecked by default, because some of these files matter a great deal to
/// whoever owns them, and every box on the page is the user's own to tick.
///
/// So the page opens offering nothing: `items` is empty, the button names no amount and cannot
/// be pressed, and the headline says what there is to choose from rather than what is going.
/// Every file that ever goes from here is one the user ticked.
///
/// And it is a big thing besides, so everything true of the user's own files is true here:
/// behind the interstitial, no Return key, an amber button, and wording that names the Trash
/// whatever the Trash setting says. What the page adds on top is the boxes — and every number
/// on the card following them.
@Test func theLargeFilesPageIsDealtWithNothingTicked() throws {
    let built = deck(largeFiles(), moveToTrash: false)

    let card = try #require(built.cards.first { $0.isChecklist })
    #expect(card.id == "big.largeFiles")
    #expect(card.kind == .bigThing(scannerID: "big.largeFiles"))
    #expect(card.name == "Large files")
    #expect(card.eyebrow == ProjectDeckText.bigThingEyebrow)
    // Biggest first, ties by identifier, exactly like every other card — and `checklistItems`
    // is in the same order, which is the promise the drain animation acts on once rows are
    // ticked.
    #expect(card.folders.map(\.name) == ["scan.pdf", "cards.db", "gallery_1fps.rgb", "scan.pdf"])
    #expect(card.checklistItems.map(\.id) == card.folders.map(\.id))
    #expect(card.folders.map(\.isTicked) == [false, false, false, false])
    // In no run at all, every one of them: a row that is not going cannot drain.
    #expect(card.folders.map(\.runIndex) == [nil, nil, nil, nil])
    // **Nothing is handed over.** The list Clean up would give the engine is empty, so the
    // page is safe even if something reached it without applying the user's ticks.
    #expect(card.items.isEmpty)
    #expect(card.runItemCount == 0)
    // The total is the whole page and does not move with the ticks — it is the figure the
    // ticked amount is measured against.
    #expect(card.totalBytes == 3_324_000_000)
    #expect(card.totalText == "3.3 GB")
    #expect(card.folderCountText == "0 of 4 files")
    // "0 of 3.3 GB": nothing chosen, out of everything there is.
    #expect(card.totalHeadline.number == "0")
    #expect(card.totalHeadline.outOf == "of 3.3 GB")
    #expect(card.totalHeadline.trailingText == "of 3.3 GB")
    // The button says what to do rather than naming an amount of nothing, and it is dead.
    #expect(card.primaryActionTitle == "Tick the files to move to the Trash")
    #expect(card.isPrimaryActionEnabled == false)
    // Click-only and amber, like every card the user has to mean.
    #expect(card.answersToReturn == false)
    #expect(card.primaryActionKeyHint == nil)
    #expect(card.primaryActionTone == .deliberate)
    // Plural, because this card is a list. The singular sentence over four rows would be the
    // card's most important line miscounting what it is about.
    #expect(card.cautionLines == [
        "These do not come back. They go to the Trash, where you can still get them back.",
    ])
    // Permanent mode, and the promise still says the Trash — the executor always trashes an
    // `.irreplaceable` row.
    #expect(card.promiseText == "They go to the Trash whatever your settings say. "
            + "Your own files are never deleted outright.")
    // Dealt with nothing ticked, so the one bulk move worth offering is the way to the other
    // extreme: tick them all, then clear the two I want to keep.
    #expect(card.checklistSelectAll
            == ProjectCard.ChecklistSelectAll(title: "Select all", ticksEverything: true))
    // No one place to name. These files are scattered from `~/dev` to `~/Documents`, so the
    // only directory that contains all of them is the home folder — and "~" locates nothing.
    #expect(card.pathText == nil)
    // No card-level Finder button either: the card is a list, so looking is per row.
    #expect(card.revealURL == nil)
}

/// **The empty set is the page exactly as it was dealt**, which is what makes `AppModel`'s
/// shortcut past `applyingTicks` safe — and makes the safe state the one that needs no work.
@Test func applyingNoTicksIsThePageAsItWasDealt() throws {
    let built = deck(largeFiles())
    let dealt = try #require(built.cards.first { $0.isChecklist })

    #expect(dealt.applyingTicks(tickedIDs: []) == dealt)
}

/// The two `scan.pdf`s, which is the whole reason a row carries a folder line.
///
/// Same name, different files. What tells them apart on screen is the `~`-abbreviated folder
/// the scanner wrote; what tells them apart to everything downstream is the identifier, which
/// is the path. The tooltip is the path, because the visible line is middle-truncated and what
/// a hover wants is the part that was cut plus the file name.
@Test func twoFilesWithOneNameAreToldApartByTheirFolderAndTheirPath() throws {
    let built = deck(largeFiles())
    let card = try #require(built.cards.first { $0.isChecklist })

    let pdfs = card.folders.filter { $0.name == "scan.pdf" }
    #expect(pdfs.count == 2)
    #expect(pdfs.map(\.restoreHint) == [
        "~/Documents/archive/scans/batch-a/current",
        "~/Documents/archive/scans/batch-b/current",
    ])
    #expect(pdfs.map(\.helpText) == [
        "~/Documents/archive/scans/batch-a/current/scan.pdf",
        "~/Documents/archive/scans/batch-b/current/scan.pdf",
    ])
    #expect(pdfs.map(\.id) == [
        "big.largeFiles|/Users/test/Documents/archive/scans/batch-a/current/scan.pdf",
        "big.largeFiles|/Users/test/Documents/archive/scans/batch-b/current/scan.pdf",
    ])
    // Finder per row, because "is this the scan I still need?" is a question only looking can
    // answer — and on this card there are four different answers.
    #expect(pdfs.map(\.revealURL) == [
        URL(fileURLWithPath:
            "/Users/test/Documents/archive/scans/batch-a/current/scan.pdf"),
        URL(fileURLWithPath:
            "/Users/test/Documents/archive/scans/batch-b/current/scan.pdf"),
    ])
    // Amber bars, because the colour must not say "the next build remakes it" over one of
    // the user's own files. Read off each row's own risk, not off the card.
    #expect(card.folders.map(\.needsDownload) == [true, true, true, true])
}

/// **Every number on the page follows the boxes**, and the list handed to the engine is
/// exactly the ticked rows in display order.
///
/// That order is what the drain animation is built on: the executor works through the list it
/// is given one at a time and reports per item, so row 3 of the page being row 2 of the run
/// is a fact the row has to carry — `ProjectCardFolder.runIndex` — rather than one the view
/// could work out from where the row is drawn.
@Test func tickingBoxesFollowsThroughToEveryNumberOnThePage() throws {
    let built = deck(largeFiles())
    let dealt = try #require(built.cards.first { $0.isChecklist })
    let widths = dealt.folders.map(\.fraction)

    // The bigger of the two scans and the frame dump, ticked.
    let card = dealt.applyingTicks(tickedIDs: [
        "big.largeFiles|/Users/test/Documents/archive/scans/batch-a/current/scan.pdf",
        "big.largeFiles|/Users/test/dev/lesson-tool/work/lesson43/frames/gallery_1fps.rgb",
    ])

    #expect(card.folders.map(\.isTicked) == [true, false, true, false])
    // An unticked row is in no run at all, so it never drains.
    #expect(card.folders.map(\.runIndex) == [0, nil, 1, nil])
    #expect(card.items.map(\.name) == ["scan.pdf", "gallery_1fps.rgb"])
    #expect(card.primaryActionTitle == "Move 1.8 GB to Trash")
    #expect(card.folderCountText == "2 of 4 files")
    #expect(card.isPrimaryActionEnabled)
    // **The total does not move with the ticks**, and that is the point of the headline: the
    // 1.8 GB the user has chosen, out of the 3.3 GB the page holds, in one unit.
    #expect(card.totalBytes == 3_324_000_000)
    #expect(card.totalText == "3.3 GB")
    #expect(card.totalHeadline.number == "1.8")
    #expect(card.totalHeadline.outOf == "of 3.3 GB")
    // The way on, now that the page is no longer at either extreme.
    #expect(card.checklistSelectAll
            == ProjectCard.ChecklistSelectAll(title: "Select all", ticksEverything: true))
    // Every row is still drawn, and the bars are still scaled against the biggest file on
    // the page: ticking a box must not silently rescale the rest of the list.
    #expect(card.folders.count == 4)
    #expect(card.folders.map(\.fraction) == widths)
    // And the rows it picks from are carried through unchanged, so a second press picks from
    // the same list rather than from what the first one left.
    #expect(card.checklistItems.map(\.id) == dealt.checklistItems.map(\.id))
    // Nothing about the card's identity, its wording or its keyboard changed.
    #expect(card.id == dealt.id)
    #expect(card.answersToReturn == false)
    #expect(card.cautionLines == dealt.cautionLines)
    #expect(card.promiseText == dealt.promiseText)
    // And the running title counts the run rather than the page. Four rows are drawn and
    // two are going, so "Cleaning… 1 of 2" — a button counting to 4 would report a finished
    // run as half done.
    #expect(card.runItemCount == 2)
    #expect(ProjectDeckText.cleaning(nil, of: card.runItemCount) == "Cleaning… 0 of 2")
}

/// Every box ticked — "Select all", or a user who really does want the lot gone.
///
/// The page is now at the other extreme from where it was dealt, so the one bulk move on
/// offer is the way back, and every row is in the run in display order.
@Test func aPageWithEveryBoxTickedHandsOverTheWholeList() throws {
    let built = deck(largeFiles())
    let dealt = try #require(built.cards.first { $0.isChecklist })

    let card = dealt.applyingTicks(tickedIDs: Set(dealt.folders.map(\.id)))

    #expect(card.primaryActionTitle == "Move 3.3 GB to Trash")
    #expect(card.isPrimaryActionEnabled)
    #expect(card.items.map(\.id) == card.folders.map(\.id))
    #expect(card.folderCountText == "4 of 4 files")
    #expect(card.folders.allSatisfy { $0.isTicked == true })
    #expect(card.folders.map(\.runIndex) == [0, 1, 2, 3])
    // Ticked and total are the same amount now, and the headline still prints both — "3.3 of
    // 3.3 GB" is the page saying it is about to move everything it holds.
    #expect(card.totalHeadline.number == "3.3")
    #expect(card.totalHeadline.outOf == "of 3.3 GB")
    #expect(card.checklistSelectAll
            == ProjectCard.ChecklistSelectAll(title: "Select none", ticksEverything: false))
}

/// **The ticked figure is printed in the total's own scale**, so the two read as one quantity.
///
/// `ByteText.short` would write 582 MB of a 41.3 GB page as "582 MB", and "582 MB of 41.3 GB"
/// is two facts side by side rather than a part of a whole — at a glance 582 is the bigger
/// number. "0.6 of 41.3 GB" is the thing the user is being told. The decimals follow that
/// scale's rule, so a page totalling in MB counts in whole MB, and a plain "0" is what a page
/// with nothing ticked says: this is the first thing on the card and it is set at 96 points,
/// where "0.0" would be precision about nothing.
@Test func theTickedFigureIsPrintedInTheSameUnitAsTheTotal() {
    // 582 MB out of 41.3 GB, in gigabytes, because the total is.
    let small = SizeHeadline(tickedBytes: 582_000_000, of: 41_300_000_000)
    #expect(small.number == "0.6")
    #expect(small.outOf == "of 41.3 GB")
    #expect(small.unit == nil)

    // A film, and the figure the button is about.
    let film = SizeHeadline(tickedBytes: 3_800_000_000, of: 41_300_000_000)
    #expect(film.number == "3.8")
    #expect(film.outOf == "of 41.3 GB")

    // Nothing ticked is a plain "0", in every scale.
    #expect(SizeHeadline(tickedBytes: 0, of: 41_300_000_000).number == "0")
    #expect(SizeHeadline(tickedBytes: 0, of: 640_000_000).number == "0")
    #expect(SizeHeadline(tickedBytes: 0, of: 640_000_000).outOf == "of 640 MB")

    // A page that totals in megabytes counts in whole megabytes, following the same rule
    // `ByteText.short` follows for a size of that size.
    let megabytes = SizeHeadline(tickedBytes: 120_000_000, of: 640_000_000)
    #expect(megabytes.number == "120")
    #expect(megabytes.outOf == "of 640 MB")
    // And a kilobyte page counts in whole kilobytes.
    #expect(SizeHeadline(tickedBytes: 4_000, of: 40_000).number == "4")
    #expect(SizeHeadline(tickedBytes: 4_000, of: 40_000).outOf == "of 40 KB")

    // Everything ticked reads as the same amount twice, which is exactly what it means.
    let all = SizeHeadline(tickedBytes: 41_300_000_000, of: 41_300_000_000)
    #expect(all.number == "41.3")
    #expect(all.outOf == "of 41.3 GB")
}

/// One file on the page reads "0 of 1 file", and the caution goes back to the singular: the
/// card really is about one thing, and every sentence on it counts the same way.
@Test func aPageHoldingOneFileCountsItInTheSingular() throws {
    let built = deck([largeFileRow(name: "12-iphone-4k-hevc-huge.mov",
                                  folder: "dev/gallery/test-media/generated",
                                  sizeBytes: 1_700_000_000)])

    let card = try #require(built.cards.first { $0.isChecklist })
    #expect(card.folderCountText == "0 of 1 file")
    #expect(card.cautionLines == [
        "This does not come back. It goes to the Trash, where you can still get it back.",
    ])
    #expect(card.primaryActionTitle == "Tick the files to move to the Trash")
    #expect(card.totalHeadline.number == "0")
    #expect(card.totalHeadline.outOf == "of 1.7 GB")
    // And once it is ticked, the button names the one file's own size.
    let ticked = card.applyingTicks(tickedIDs: Set(card.folders.map(\.id)))
    #expect(ticked.folderCountText == "1 of 1 file")
    #expect(ticked.primaryActionTitle == "Move 1.7 GB to Trash")
    // One row, one folder to name, so the card can say where it is after all.
    #expect(card.pathText == "~/dev/gallery/test-media/generated")
}

/// **The reveal button is offered exactly where there is somewhere to go**, with the words a
/// screen reader needs.
///
/// The user asked for it: they open these in Finder a lot to decide, and the context menu is
/// two gestures. Which rows have one, where it points and what it is called are all the
/// model's answers — the window draws a button where it finds a `reveal` and nothing else.
@Test func everyRowOfThePageOffersOneClickToFinder() throws {
    let built = deck(largeFiles())
    let card = try #require(built.cards.first { $0.isChecklist })

    #expect(card.folders.compactMap(\.reveal).count == 4)
    let database = try #require(card.folders.first { $0.name == "cards.db" }?.reveal)
    #expect(database.url == URL(fileURLWithPath:
        "/Users/test/dev/workspace-two/client-app/tools/carddb/out/cards.db"))
    // The same words as the context menu it duplicates, and the same as the card-level
    // action on a page that is one file.
    #expect(database.help == "Show in Finder")
    #expect(database.help == ProjectDeckText.showInFinder)
    // Named, because forty rows of "Show in Finder" is forty identical announcements.
    #expect(database.accessibilityLabel == "Show cards.db in Finder")
    // It survives the ticks in both directions: looking is always allowed, and it is how the
    // page is answered at all.
    let ticked = card.applyingTicks(tickedIDs: Set(card.folders.map(\.id)))
    #expect(ticked.folders.map(\.reveal) == card.folders.map(\.reveal))

    // And no row of any other kind of card has one, so no project card grows a button.
    let ordinary = deck([folderRow(project: "game", folder: ".build",
                                   sizeBytes: 946_000_000)])
    #expect(ordinary.cards.flatMap(\.folders).allSatisfy { $0.reveal == nil })
}

/// **No other kind of card has boxes, and an identifier cannot give one.**
///
/// The guard is not decoration. A set of ticks is only ever filled from the page on screen,
/// but `applyingTicks` is what decides which rows Clean up hands over — so a set that somehow
/// named a project's `.build` must not be able to change that list in either direction,
/// leaving the card promising bytes the run was never asked to move.
@Test func tickingBoxesLeavesEveryOtherKindOfCardExactlyAsItWas() throws {
    let built = deck([
        folderRow(project: "game", folder: ".build", sizeBytes: 946_000_000),
        downloadRow(name: "Xcode_26.1_beta.xip", sizeBytes: 7_000_000_000),
    ])
    let everyRowID = Set(built.cards.flatMap(\.items).map(\.id))

    for card in built.cards {
        #expect(card.applyingTicks(tickedIDs: everyRowID) == card)
        #expect(card.applyingTicks(tickedIDs: []) == card)
        // Nothing waiting to be picked from either: `items` is already the whole list.
        #expect(card.checklistItems.isEmpty)
    }
    // And the two cards really do hold rows those identifiers name, so this is a property of
    // `isChecklist` rather than of an empty fixture.
    #expect(built.cards.contains { !$0.items.isEmpty })
}

/// The page is one big-thing slot and counts like any other: behind the interstitial, inside
/// its total, and outside the amount the menu bar advertises.
@Test func thePageTakesOneBigThingsPlaceInTheDeck() throws {
    let built = deck(largeFiles() + [
        toolRow(scanner: "xcode.derivedData", name: "Runner",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner",
                sizeBytes: 9_100_000_000),
        downloadRow(name: "Xcode_26.1_beta.xip", sizeBytes: 7_000_000_000),
    ])

    #expect(built.cards.map(\.id) == [
        "xcode.derivedData", ProjectDeck.interstitialCardID,
        "big.downloads|/Users/test/Downloads/Xcode_26.1_beta.xip", "big.largeFiles",
    ])
    // One card for all four files, so the interstitial counts it once — and totals what it
    // holds, which is the sum of the rows on the page.
    let interstitial = try #require(built.cards.first { $0.isInterstitial })
    #expect(interstitial.totalBytes == 10_324_000_000)
    #expect(interstitial.folderCountText
            == "Next: 2 big things that are yours. They do not come back; "
            + "they go to the Trash only if you say so.")
    // Never in the number the menu bar shows: every row is `startsUnticked`, and the amount
    // is about the half of the deck that comes back on its own.
    #expect(built.defaultOfferBytes == 9_100_000_000)
}

// MARK: - what the arrow key answers for

/// **Finding 3.** The glyph and the shortcut are decided together, on the card.
///
/// They were a literal `"→"` and a hard-coded `.keyboardShortcut(.rightArrow)` in the window,
/// so both survived unchanged onto the one card where that button means something else: the
/// interstitial's secondary is "Skip them all", and an arrow held down through the first half
/// of the deck pressed it on the next repeat — every one of the user's own files skipped
/// unread, which is the one set of cards that exists to be read.
@Test func onlyTheButtonThatSkipsOneThingAnswersToTheArrow() throws {
    let built = deck([
        xdgCacheRow(name: "uv", sizeBytes: 1_100_000_000),
        downloadRow(name: "Xcode_26.1_beta.xip", sizeBytes: 7_000_000_000),
    ])

    let ordinary = try #require(built.cards.first { !$0.isInterstitial })
    #expect(ordinary.secondaryActionTitle == "Skip")
    #expect(ordinary.secondaryActionKeyHint == "→")
    #expect(ordinary.secondaryAnswersToArrow)

    let interstitial = try #require(built.cards.first { $0.isInterstitial })
    #expect(interstitial.secondaryActionTitle == "Skip them all")
    #expect(interstitial.secondaryActionKeyHint == nil)
    #expect(interstitial.secondaryAnswersToArrow == false)
    // Return still answers "Look through them", so the card is not a dead end for somebody
    // working from the keyboard. What it no longer has is a key that can be held through it.
    #expect(interstitial.answersToReturn)
    #expect(interstitial.primaryActionKeyHint == "⏎")
}

/// **Finding 5.** Big-thing-ness is read off `risk == .irreplaceable` as well as off the
/// group, so an irreplaceable row filed anywhere can never get an ordinary card.
///
/// The executor's always-Trash rule keys on the risk — `CleanupItem.goesToTheTrash` — and the
/// group is only the deck's own filing of a row. Read from the group alone, such a row would
/// get a blue button with a Return key and, in permanent mode, a promise that it is deleted
/// for good, about a file that is going to be sitting in the user's Trash.
@Test func anIrreplaceableRowInAnotherGroupIsStillDealtAsABigThing() throws {
    let grouped = CleanupItem(
        id: "other.libraryCaches|/Users/test/Library/Caches/odd",
        scannerID: "other.libraryCaches", group: .otherCaches,
        name: "odd", detail: "A folder.", sizeBytes: 2_000_000_000,
        lastUsed: nil, risk: .irreplaceable, protection: nil,
        method: .removePath("/Users/test/Library/Caches/odd"))
    let built = deck([grouped, folderRow(project: "game", folder: "build",
                                         sizeBytes: 3_300_000_000)],
                     moveToTrash: false)

    let card = try #require(built.cards.first { $0.id == "other.libraryCaches" })
    #expect(card.isBigThing)
    #expect(card.answersToReturn == false)
    #expect(card.primaryActionKeyHint == nil)
    #expect(card.primaryActionTone == .deliberate)
    #expect(card.primaryActionTitle == "Move 2.0 GB to Trash")
    #expect(card.promiseText == ProjectDeckText.bigThingPromise)
    // Behind the card that says the promise has changed, although its group says otherwise.
    #expect(built.cards.map(\.isBigThing) == [false, false, true])
    #expect(built.cards.first { $0.isInterstitial } != nil)
    // And out of the amount the menu bar advertises, which counts the regenerable half only.
    #expect(built.defaultOfferBytes == 3_300_000_000)
}

/// The same, down the per-item path, which decides it from the row on its own.
@Test func anIrreplaceablePerItemRowIsStillDealtAsABigThing() throws {
    let cache = CleanupItem(
        id: "other.xdgCache|/Users/test/.cache/uv", scannerID: "other.xdgCache",
        group: .otherCaches, name: "uv",
        detail: XDGCacheScanner.detail(forChildNamed: "uv"), sizeBytes: 1_100_000_000,
        lastUsed: nil, risk: .irreplaceable, protection: nil,
        method: .removePath("/Users/test/.cache/uv"))

    let card = try #require(deck([cache]).cards.first { !$0.isInterstitial })
    #expect(card.isBigThing)
    #expect(card.kind == .bigThing(scannerID: "other.xdgCache"))
    #expect(card.answersToReturn == false)
    #expect(card.promiseText == ProjectDeckText.bigThingPromise)
    #expect(card.cautionLines == [ProjectDeckText.bigThingCaution])
}

// MARK: - a held Return answers one card and no more

/// **Finding 4.** The repeats of a held Return are swallowed; the first press is not.
///
/// The settle window rate-limits a held key and was documented as stopping one, which it never
/// did: macOS repeats for as long as the key is down, so Return leaned on walked the deck at
/// about a card every 0.6 seconds, cleaning each of them. This is the rule that makes every
/// card need a press of its own.
@Test func onlyARepeatOfTheKeyThatAnswersACardIsSwallowed() {
    // The press the user meant.
    #expect(DeckKeyboard.swallowsKeyDown(
        keyCode: 36, isARepeat: false, isDeckWindowKey: true) == false)
    // The same key still down, thirty times a second.
    #expect(DeckKeyboard.swallowsKeyDown(
        keyCode: 36, isARepeat: true, isDeckWindowKey: true))
    // The keypad's Enter, which `.defaultAction` answers to as well — a fix that held on one
    // of the two keys would be no fix at all.
    #expect(DeckKeyboard.swallowsKeyDown(
        keyCode: 76, isARepeat: true, isDeckWindowKey: true))
    #expect(DeckKeyboard.primaryActionKeyCodes == [36, 76])
}

/// Everything else goes through, and both exceptions are deliberate.
///
/// The **right arrow** is held down through the deck on purpose: skipping removes nothing, and
/// flicking through twenty-four cards is the deck working as intended. What made the arrow
/// dangerous was the interstitial's secondary meaning "skip them all", and that is fixed on
/// the card — `ProjectCard.secondaryAnswersToArrow`.
///
/// **Another window** is nobody's business: the settings window holds text fields, and a
/// field is entitled to every repeat it gets.
@Test func aHeldKeyIsLeftAloneOutsideTheDeckAndOnEveryOtherKey() {
    #expect(DeckKeyboard.swallowsKeyDown(
        keyCode: 124, isARepeat: true, isDeckWindowKey: true) == false)
    #expect(DeckKeyboard.swallowsKeyDown(
        keyCode: 36, isARepeat: true, isDeckWindowKey: false) == false)
    #expect(DeckKeyboard.swallowsKeyDown(
        keyCode: 36, isARepeat: false, isDeckWindowKey: false) == false)
}

/// And the end card's own button answers to no key, for the same reason.
///
/// It was the window's default action, which put a Finder window at the end of a held Return:
/// the key that answered the last card reached the end card on its next repeat. Opening a
/// folder is harmless; the deck teaching a user that holding Return is the way through it is
/// not, and the end card is the last place that lesson would have been confirmed.
@Test func theEndCardsOpenTheTrashButtonAnswersToNoKey() {
    let summary = ProjectDeckSummary(
        slots: slots([("cache", 4_400_000_000)]),
        decisions: ["cache": .cleaned(trashedBytes: 4_400_000_000, deletedBytes: 0,
                                      problems: [])],
        currentCardID: nil, moveToTrash: true)

    #expect(summary.openTrashText == "Open the Trash")
    #expect(summary.openTrashAnswersToReturn == false)
}

/// **An ordinary row is not a choice, and says so.**
///
/// `isTicked` is `nil` rather than `false` on every card but the checklist page, which is what
/// keeps an empty checkbox from appearing beside every folder of every project in the deck —
/// and `revealURL` is `nil`, so no other row grows a Finder menu. Both are the model's answer;
/// the window draws a box exactly where it finds one.
///
/// `helpText` falls back to the visible line, so the only rows whose tooltip differs from what
/// they show are the ones that asked for it.
@Test func aRowThatIsNotAChoiceCarriesNoBoxAndNoFinderMenu() throws {
    let built = deck([
        folderRow(project: "game", folder: ".build", sizeBytes: 946_000_000),
        folderRow(project: "game", folder: "ios/Pods", sizeBytes: 400_000_000,
                  risk: .elevated),
        toolRow(scanner: "xcode.derivedData", name: "Runner",
                relativePath: "Library/Developer/Xcode/DerivedData/Runner",
                sizeBytes: 9_100_000_000),
    ])

    // The derived data card comes first, being the bigger of the two.
    let rows = built.cards.flatMap(\.folders)
    #expect(rows.map(\.name) == ["Runner", ".build", "ios/Pods"])
    #expect(rows.map(\.isTicked) == [nil, nil, nil])
    #expect(rows.map(\.revealURL) == [nil, nil, nil])
    // A tooltip is the row's own line, in full — including the empty one, for a row whose
    // scanner wrote no sentence at all.
    #expect(rows.map(\.helpText) == rows.map(\.restoreHint))
    #expect(rows.map(\.helpText)
            == ["", "Next build remakes it", "pod install downloads it again"])
    // And no card here offers one either, so nothing in this deck draws a Finder button.
    #expect(built.cards.map(\.revealURL) == [nil, nil])
    #expect(built.cards.map(\.isChecklist) == [false, false])
    #expect(built.cards.map(\.checklistSelectAll) == [nil, nil])
}
