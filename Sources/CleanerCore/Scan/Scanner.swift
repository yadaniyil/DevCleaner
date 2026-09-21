import Foundation

// @unchecked because of the stored FileManager — see Global Constraints.
public struct ScanContext: @unchecked Sendable {
    public let settings: Settings
    public let protection: ProtectionSet
    public let projects: [DiscoveredProject]
    /// When each project last changed, keyed by `DiscoveredProject.path`.
    ///
    /// The same dictionary `ProtectionResolver` was given, carried on rather than
    /// discarded once protection is resolved. `ActivityInspector` walks every project for
    /// it and asks `git log` about each one — about 29 seconds of a 51-second scan on a
    /// real dev machine — so an interface that wanted to say "last changed 4 months ago"
    /// and re-derived it would pay that again and could reach a different answer than the
    /// one protection was decided on.
    ///
    /// A project with no entry is a project whose age is **unknown**, which is not the
    /// same as old: `ActivityInspector.lastActivity` answers `nil` for a project it could
    /// neither date from a file nor from git. Nothing may substitute a date for it.
    public let activity: [String: Date]
    public let devices: DeviceInventory
    public let home: String
    public let androidSDKPath: String
    public let sizeMeasurer: any SizeMeasuring
    public let runner: any ProcessRunner
    public let fileManager: FileManager
    public let now: Date
    /// Entries of `Settings.projectRoots` that were refused rather than walked, because
    /// they name the home directory or `/`.
    ///
    /// `SettingsStore.save` refuses to store such a value, but `load()` still reads a
    /// hand-edited `settings.json` without validating it, and a root of `~` would send
    /// `ProjectDiscovery` through the whole home directory. `CleanerService` drops them
    /// and records them here so the interface can say which setting was ignored instead
    /// of quietly finding no projects.
    public let ignoredProjectRoots: [String]

    /// `activity` defaults to empty, so every existing call site compiles unchanged and
    /// reads as what it is: a context built without one says nothing about when anything
    /// changed, rather than claiming everything changed at the epoch.
    public init(
        settings: Settings, protection: ProtectionSet, projects: [DiscoveredProject],
        activity: [String: Date] = [:],
        devices: DeviceInventory, home: String, androidSDKPath: String,
        sizeMeasurer: any SizeMeasuring, runner: any ProcessRunner,
        fileManager: FileManager, now: Date, ignoredProjectRoots: [String] = []
    ) {
        self.settings = settings
        self.protection = protection
        self.projects = projects
        self.activity = activity
        self.devices = devices
        self.home = home
        self.androidSDKPath = androidSDKPath
        self.sizeMeasurer = sizeMeasurer
        self.runner = runner
        self.fileManager = fileManager
        self.now = now
        self.ignoredProjectRoots = ignoredProjectRoots
    }

    /// Absolute path for a location under the home directory.
    public func homePath(_ relative: String) -> String {
        (home as NSString).appendingPathComponent(relative)
    }
}

/// How the main window's deck deals one scanner's rows.
///
/// The scanner is the only thing that can answer this, which is why it is declared here
/// rather than decided by the deck. `.grouped` is right when the rows share one nature and
/// one decision: all sixteen simulators are one question, and a user who wants some of
/// them gone and not others is asking something this window does not offer. `.perItem` is
/// right when they do not — a user may want `~/.cache/uv` gone and `~/.cache/huggingface`
/// kept, and a 4 GB installer in `~/Downloads` has nothing whatever to do with the 2 GB
/// video beside it. The deck has no per-row ticks, so one card for those would be an
/// all-or-nothing button over a list of unrelated things.
public enum DeckDealing: Sendable, Equatable {
    /// One card for everything the scanner found.
    case grouped
    /// One card per row.
    case perItem
    /// **No card at all.** The rows are measured and named on the end card, and nothing
    /// in the app ever removes them.
    ///
    /// The third answer to "how does the deck deal this?" is "it does not", and it exists
    /// because two scanners turned out to be measuring things the user does not want this
    /// app to touch. Shown the real cards, they were plain that they would not be cleaning
    /// the browser caches — and the same about `other.electronCaches`, whose rows are
    /// Slack's and Claude's and VS Code's own working caches. A card is a **question**, and
    /// a question the user has already answered is a card they learn to skip; a dozen of
    /// those is how the cards that matter stop being read.
    ///
    /// The rows are still scanned and still sized, because the answer is not "hide this".
    /// `ProjectDeck.moreToGain` lists them on the last page with their sizes, so a user
    /// who wants the 3.2 GB of Brave cache back knows it is there and knows Brave's own
    /// settings are where to go for it.
    ///
    /// **Declaring this is not what keeps the rows out of a clean.** Every route that
    /// removes something reads `CleanupItem.selectedByDefault`, not this, so a
    /// `.mentionOnly` scanner's rows are `startsUnticked` as well — see `AppCacheScanner`.
    /// This enum only decides what the window draws, and a safety rule that lived in a
    /// drawing decision would be one refactor away from being gone.
    ///
    /// Two other places say what these rows are, and one deliberately does not.
    /// `ReportText.mentionOnlyNote` is the CLI listing's sentence, which exists because
    /// "offered but not ticked" alone would send a reader looking for the button. The
    /// **settings screen** needs nothing: its section is headed "What to look at", and its
    /// one line of help — "A scanner switched off here is not measured and is left out of
    /// the total" — is exactly true of these two, because switching one off is what stops
    /// the last page mentioning it. A switch that already means "measure this" did not need
    /// a second meaning bolted on.
    case mentionOnly
    /// One card for the scanner, whose rows carry **checkboxes**.
    ///
    /// For rows that share a place in the deck but not a decision: `big.largeFiles` finds
    /// fifty unrelated files, and one card per file would be fifty cards while one
    /// all-or-nothing card would be a button over somebody's lesson videos and their test
    /// fixtures at once. The user asked for exactly this shape — **nothing ticked when the
    /// page opens**, tick what should go, one button for those.
    ///
    /// The ticks are the window's, not the engine's. A `.checklist` scanner's rows are
    /// `startsUnticked` like every other big thing, so no default route ever takes one; the
    /// page hands the engine exactly the rows the user ticked, and nothing at all until they
    /// tick something.
    case checklist
}

/// Named `CleanupScanner`, not `Scanner`, because Foundation exports a `Scanner`
/// class. Any file outside this module that imports both Foundation and
/// CleanerCore cannot resolve a bare `Scanner` — that includes the CLI target and
/// the menu bar app, not just tests.
public protocol CleanupScanner: Sendable {
    var id: String { get }
    var group: GroupID { get }
    var title: String { get }
    /// See `DeckDealing`. Defaults to `.grouped`, which is what every scanner written
    /// before the deck existed means, so only the three that differ say anything.
    var deckDealing: DeckDealing { get }
    /// Never throws. An unreadable location yields an empty list so that one
    /// broken scanner cannot stop the rest of the scan.
    func scan(_ context: ScanContext) async -> [CleanupItem]
}

extension CleanupScanner {
    public var deckDealing: DeckDealing { .grouped }
}

/// One element of `ScanResult.items`, decoded so that a single unreadable row costs that
/// row alone instead of the whole cached scan.
///
/// The same shape as `LenientRunEntry` in `Execute/Executor.swift`, and for the same
/// reason: swallowing the error here still advances the unkeyed container, which a bare
/// `try?` around `decode([CleanupItem].self)` would not.
private struct LenientCleanupItem: Decodable {
    let item: CleanupItem?

    init(from decoder: any Decoder) throws {
        item = try? CleanupItem(from: decoder)
    }
}

public struct ScanResult: Codable, Sendable, Equatable {
    /// Every row the scan produced, protected ones included, **de-duplicated by target**
    /// when it came from `ScanEngine`. The totals below de-duplicate again on
    /// `CleanupItem.method`, so a hand-built result cannot over-report either.
    public let items: [CleanupItem]
    public let generatedAt: Date
    public let availableBytes: Int64
    public let skippedScannerIDs: [String]
    /// See `ScanContext.ignoredProjectRoots`. Entries of `Settings.projectRoots` that were
    /// refused rather than walked.
    public let ignoredProjectRoots: [String]

    public init(items: [CleanupItem], generatedAt: Date, availableBytes: Int64,
                skippedScannerIDs: [String], ignoredProjectRoots: [String] = []) {
        self.items = items
        self.generatedAt = generatedAt
        self.availableBytes = availableBytes
        self.skippedScannerIDs = skippedScannerIDs
        self.ignoredProjectRoots = ignoredProjectRoots
    }

    private enum CodingKeys: String, CodingKey {
        case items, generatedAt, availableBytes, skippedScannerIDs, ignoredProjectRoots
    }

    /// Hand-written for the same reason as `RunRecord.init(from:)`.
    ///
    /// A scan result is cached on disk, so one written by a different build of the app has
    /// to load rather than be thrown away whole: a synthesised `decode` turns a missing
    /// non-optional key into `DecodingError.keyNotFound`, and the caller's `try?` then
    /// discards every row. `generatedAt` is the one key with no sensible fallback — it is
    /// what decides whether the cache is stale, and a result with no time is not a scan.
    ///
    /// **Every field added from here on is read with `decodeIfPresent(...) ?? <default>`.**
    /// `aCachedScanMissingTheNewestFieldStillLoads` in `CleanerServiceTests` fails the
    /// moment one is not.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        items = (try container.decodeIfPresent([LenientCleanupItem].self, forKey: .items) ?? [])
            .compactMap(\.item)
        availableBytes = try container.decodeIfPresent(Int64.self, forKey: .availableBytes) ?? 0
        skippedScannerIDs =
            try container.decodeIfPresent([String].self, forKey: .skippedScannerIDs) ?? []
        ignoredProjectRoots =
            try container.decodeIfPresent([String].self, forKey: .ignoredProjectRoots) ?? []
    }

    /// The rows an interface ticks when the list first appears, and the list to hand
    /// straight to `CleanerService.clean`.
    ///
    /// `selectedByDefault`, never `isDeletable`. The two Android NDK rows are deletable and
    /// deliberately not ticked; filtering on `isDeletable` puts 5.57 GB of re-download into
    /// a clean the user never asked for.
    public var defaultSelection: [CleanupItem] { items.filter(\.selectedByDefault) }

    /// **The headline: how much a default clean would remove, at most.**
    ///
    /// Three things this is not, each of which the old total got wrong:
    ///
    /// 1. It is not the sum over `isDeletable`. The Android NDK rows are deletable and
    ///    start unticked, so counting them promised 5.57 GB that a default clean does not
    ///    touch. Use `untickedDeletableBytes` for what ticking them would add.
    /// 2. It is not a sum that can count one directory twice. Two rows naming one target
    ///    contribute once — see `total(of:)`.
    /// 3. It is not a promise. `possiblySharedBytes` is the part of this number whose
    ///    blocks may be shared with files that are staying, and in Trash mode none of it
    ///    reaches the free-space figure until the Trash is emptied. An interface that
    ///    prints one number should print this one as an upper bound, and show
    ///    `reclaimableBytes - possiblySharedBytes` … `reclaimableBytes` when the second is
    ///    not zero.
    public var reclaimableBytes: Int64 { Self.total(of: defaultSelection) }

    /// Deletable, shown with its size, and **not** ticked — the Android NDK today.
    ///
    /// Kept apart from `reclaimableBytes` so an interface can offer "and 5.57 GB more if
    /// you tick the NDK" without ever adding it to a default clean.
    public var untickedDeletableBytes: Int64 {
        Self.total(of: items.filter { $0.isDeletable && $0.startsUnticked })
    }

    /// The part of `reclaimableBytes` that may not come back at all.
    ///
    /// Rows whose measured bytes may be shared with files that are staying — the pnpm
    /// store and the bun cache. See `CleanupItem.sizeMayBeShared`. Zero means the headline
    /// has no such row in it.
    public var possiblySharedBytes: Int64 {
        Self.total(of: defaultSelection.filter(\.sizeMayBeShared))
    }

    public func items(in group: GroupID) -> [CleanupItem] {
        items.filter { $0.group == group }
    }

    /// The same rule as `reclaimableBytes`, for one group.
    public func reclaimableBytes(in group: GroupID) -> Int64 {
        Self.total(of: items(in: group).filter(\.selectedByDefault))
    }

    /// The same de-duplicating rule as every total above, for any subset of rows.
    ///
    /// Exists so that an interface splitting a selection into "goes to the Trash" and
    /// "removed permanently" adds each part up exactly the way the headline adds up the
    /// whole. A second, hand-written sum in the interface is a second chance to promise
    /// bytes that exist once.
    public static func totalBytes(of items: [CleanupItem]) -> Int64 { total(of: items) }

    /// Adds up sizes, counting each deletion target once.
    ///
    /// Two rows naming one target are one lot of bytes on disk. Nothing produces such a
    /// pair today — `ScanEngine` already drops the second, comparing canonical paths, which
    /// catches spellings this cannot — but a total that double-counts is a total that
    /// promises space which does not exist, and the sum is the last place able to refuse.
    private static func total(of items: [CleanupItem]) -> Int64 {
        var seen: Set<DeletionMethod> = []
        return items.reduce(into: Int64(0)) { total, item in
            guard seen.insert(item.method).inserted else { return }
            total += item.sizeBytes
        }
    }
}

/// Where a scan has got to, reported **before** each scanner runs.
///
/// Before, not after, because a scan takes about 50 seconds on a real dev machine and almost
/// all of it is `du`. "Finished 3 of 16" says nothing about the wait the user is in the
/// middle of; "starting Android emulators, 3 done" names what is holding them up.
///
/// `completed` is therefore the number of scanners already finished, and it reaches
/// `total` only in the last callback's successor — which never comes, because there is
/// nothing left to announce. A caller that wants a "done" line prints it after `scan`
/// returns.
public struct ScanProgress: Sendable, Equatable {
    /// Scanners finished before this one started.
    public let completed: Int
    /// Every scanner in the registry, including any the settings skip.
    public let total: Int
    public let currentID: String
    public let currentTitle: String

    public init(completed: Int, total: Int, currentID: String, currentTitle: String) {
        self.completed = completed
        self.total = total
        self.currentID = currentID
        self.currentTitle = currentTitle
    }
}

public struct ScanEngine: Sendable {
    private let scanners: [any CleanupScanner]

    public init(scanners: [any CleanupScanner]) { self.scanners = scanners }

    /// `progress` defaults to doing nothing, so every existing caller is unchanged.
    public func scan(
        context: ScanContext,
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) async -> ScanResult {
        var items: [CleanupItem] = []
        var skipped: [String] = []
        /// Where in `items` the row for each target sits.
        var positionOfTarget: [String: Int] = [:]

        for (index, scanner) in scanners.enumerated() {
            // Announced even when it is about to be skipped, so `completed` and `total`
            // count the same list the settings screen shows and the numbers add up.
            progress(ScanProgress(
                completed: index, total: scanners.count,
                currentID: scanner.id, currentTitle: scanner.title))
            if context.settings.isSkipped(scanner.id) {
                skipped.append(scanner.id)
                continue
            }
            for item in await scanner.scan(context) {
                let target = Self.target(of: item.method)
                guard let existing = positionOfTarget[target] else {
                    positionOfTarget[target] = items.count
                    items.append(item)
                    continue
                }
                // Two rows for one target. The first is kept, so the display order of the
                // scanner registry decides, **unless** the later one is protected and the
                // kept one is not: a target something says must not be deleted must not be
                // represented by a row the interface will tick.
                if items[existing].isDeletable, !item.isDeletable {
                    items[existing] = item
                }
            }
        }

        let available = (try? FreeSpace.availableBytes(forVolumeContaining: context.home)) ?? 0
        return ScanResult(
            items: Self.droppingLargeFilesInsideAnotherRow(items), generatedAt: context.now,
            availableBytes: available, skippedScannerIDs: skipped,
            ignoredProjectRoots: context.ignoredProjectRoots)
    }

    /// Drops every `big.largeFiles` row that sits **inside** some other row's deletion
    /// target.
    ///
    /// `big.largeFiles` is the one scanner that looks everywhere, so it is the one scanner
    /// whose rows can land inside another's. Both ways that happens cost the user
    /// something:
    ///
    /// * A 1.7 GB test fixture under `~/dev/app/build`. `projects.buildOutput` already
    ///   offers that folder, so the file would be asked about twice — once as part of a
    ///   build folder that comes back, once as a film that does not — and whichever card
    ///   the user answered second would be describing bytes that had already gone.
    /// * A 1.2 GB scan inside a project the resolver **kept**. That row is protected, which
    ///   means "must not be deleted at all"; offering the file inside it with a checkbox
    ///   beside it would be the app taking back the promise one file at a time. This is why
    ///   the rule reads every other row — ticked, unticked and protected alike — and not
    ///   just the ones a clean would touch.
    ///
    /// Scanners run independently and know nothing of each other, so this belongs here,
    /// where the rows meet, and nowhere else.
    ///
    /// **Separator-aware**, so `~/dev/app/build` does not swallow `~/dev/app/build2/big.mov`
    /// — the standing rule in this package about path prefixes. Compared lower-cased, and
    /// on both the stated and the canonicalised spelling of each target: unlike
    /// `target(of:)`, where a wrong merge silently drops a row from the list, the wrong
    /// answer here is to keep a duplicate offer of somebody's file, so every spelling that
    /// says "inside" is enough.
    static func droppingLargeFilesInsideAnotherRow(_ items: [CleanupItem]) -> [CleanupItem] {
        let containers = items
            .filter { $0.scannerID != LargeFilesScanner.scannerID }
            .compactMap(\.method.path)
            .flatMap(Self.spellings)
        guard !containers.isEmpty else { return items }
        return items.filter { item in
            guard item.scannerID == LargeFilesScanner.scannerID,
                  let path = item.method.path
            else { return true }
            let candidates = Self.spellings(of: path)
            return !containers.contains { container in
                candidates.contains { $0.hasPrefix(container + "/") }
            }
        }
    }

    /// The spellings of one path worth comparing: as the row states it, and canonicalised
    /// the way `validate` canonicalises. Lower-cased, and without a trailing slash so the
    /// caller can append exactly one.
    ///
    /// Two, because a row's own string and its canonical form differ whenever a parent is a
    /// symlink — and on a path that does not exist the canonical form is not available at
    /// all, which is the normal case for a hand-built fixture and must not quietly turn the
    /// comparison into one between a resolved path and an unresolved one.
    private static func spellings(of path: String) -> [String] {
        Set([path, PathGuard.canonicaliseKeepingLeaf(path) ?? path].map {
            ($0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0).lowercased()
        }).sorted()
    }

    /// The thing an item removes, in a form two scanners naming one target agree on.
    ///
    /// A path is canonicalised with its final component left verbatim — the rule
    /// `PathGuard.validate` uses — so `<root>/app/build` and `<root>/./app/build` are one
    /// row rather than two, while a symlink at the leaf keeps its own identity and is not
    /// merged with what it points at. A path that cannot be canonicalised keeps its own
    /// string, which can only fail to merge two rows and never merge two different ones.
    ///
    /// Case is kept, deliberately. `realpath` case-corrects every component but the leaf,
    /// and every leaf here came out of `contentsOfDirectory`, so it is already the on-disk
    /// spelling; lowering it would merge two genuinely different directories on a
    /// case-sensitive volume and silently drop one of them from the list.
    ///
    /// The three device cases are prefixed apart so a UDID can never collide with a path.
    static func target(of method: DeletionMethod) -> String {
        switch method {
        case .removePath(let path):
            return "path:" + (PathGuard.canonicaliseKeepingLeaf(path) ?? path)
        case .deleteSimulator(let udid):
            return "simulator:" + udid
        case .deleteSimulatorRuntime(let identifier):
            return "runtime:" + identifier
        case .deleteAVD(let name):
            return "avd:" + name
        }
    }
}
