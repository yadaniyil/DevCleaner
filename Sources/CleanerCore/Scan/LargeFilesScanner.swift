import Foundation

/// Large files anywhere in the user's home folder — the page macOS calls "Large Files".
///
/// Identity first: `id`, `group`, `title` and `deckDealing` are the contract the deck's
/// checklist page is built against. What it finds, and the rules about what it must never
/// offer, are in `scan`.
///
/// **Why the app never found them.** Nothing in this package looked. The two things
/// `GroupID.bigThings` knew about were two fixed places — direct children of `~/Downloads`
/// over 500 MB, and the three AI model stores — and the files macOS lists are in neither.
/// On the Mac this was written for they are four 3.8 GB films under `~/Documents`, a 1.7 GB
/// simulator fixture in a project's `test-media`, sixteen scanned PDFs of 0.6–1.2 GB, an
/// 876 MB card database in a tool's `out` folder, and a shelf of 250–500 MB lesson videos:
/// fifty-six files outside `~/Library`, not one of them in a directory any scanner had a
/// name for. The request was that the app stop missing them, and the reason it missed them
/// is that there was nothing to find them with.
///
/// **Why it asks Spotlight rather than walking.** A walk of a home folder deep enough to
/// reach those paths is the slowest thing this app could do — `ProjectDiscovery` is capped
/// at four levels for exactly that reason, and the films are five deep. `mdfind -onlyin ~
/// 'kMDItemFSSize>=200000000'` answers with all fifty-six in 0.13 seconds, because
/// Spotlight has the index already; it is almost certainly where macOS Storage gets the
/// same list. So this scanner asks the index — and then believes none of it. Every path it
/// is handed is checked on disk by `LargeFileLicence`, which is the same rule
/// `CleanerService.clean` re-applies before anything is allowed to move, so what may be
/// offered and what may be removed cannot drift apart.
///
/// **This is the one scanner that offers the user's own files from anywhere under home**,
/// which is why the rules live in a shared function with tests of their own rather than in
/// this method: see `LargeFileLicence`.
public struct LargeFilesScanner: CleanupScanner {
    public static let scannerID = "big.largeFiles"

    public let id = Self.scannerID
    public let group = GroupID.bigThings
    public let title = "Large files"
    /// One page with a checkbox per file — see `DeckDealing.checklist`.
    public var deckDealing: DeckDealing { .checklist }

    public init() {}

    /// Spotlight's command line front end, by absolute path like every other tool this
    /// package runs, and only ever through `ScanContext.runner`.
    public static let mdfindPath = "/usr/bin/mdfind"

    /// The query: files at or over the floor, and nothing else said about them.
    ///
    /// Deliberately **not** `kMDItemFSSize >= 200000000` with spaces, although mdfind
    /// accepts that too. The test doubles in this package identify a command by its
    /// arguments joined with a single space, and an argument containing one is the one
    /// thing that makes that key ambiguous; the spaceless spelling keeps every stub in the
    /// suite readable as a plain string literal.
    ///
    /// Nothing here filters by location beyond `-onlyin <home>`, and nothing asks Spotlight
    /// about kind, name or date. The index is a hint about where to look, and every rule
    /// about what may be offered is applied against the disk afterwards — a query clever
    /// enough to be trusted is a query whose mistakes would be invisible.
    public static let spotlightQuery = "kMDItemFSSize>=\(LargeFileLicence.minimumBytes)"

    /// How many rows the page may have, biggest first.
    ///
    /// A checklist is only answerable while it can be read. 56 rows is the real number on
    /// the machine this was written for; a home folder holding a video library or a decade
    /// of scanned documents could answer with ten thousand, and a page with ten thousand
    /// checkboxes on it is not a question — it is a wall the user closes. Two hundred is far
    /// past any plausible honest list and still a bounded amount of work for the window.
    ///
    /// Biggest first, so the cap can only ever drop the rows that matter least.
    public static let maximumRows = 200

    /// The folders under home that macOS keeps behind a permission prompt, and that this page
    /// has to be allowed into. `Downloads` is the third such folder and is deliberately not
    /// here: it is `big.downloads`' folder, and that scanner does its own asking.
    ///
    /// **Without this the page is silently missing the biggest files on the disk.** On the
    /// machine this was written for, the first real scan offered thirty files — every one
    /// under `~/dev` — and none of the twenty-three in `~/Documents`, which included the
    /// four largest files the user owns. Nothing had failed. Spotlight answers a process
    /// that has not been granted a protected folder as though the folder were empty, no
    /// prompt is shown for a query, and `mdfind` run from a terminal that *has* the grant
    /// finds all of them — so the gap is invisible from everywhere except the page itself.
    public static let foldersBehindAPermissionPrompt = ["Documents", "Desktop"]

    /// Lists each protected folder once, which is the thing that makes macOS ask.
    ///
    /// The listing is thrown away. It is the *attempt* that matters: the first one puts up
    /// the system's own "would like to access files in your Documents folder" prompt, and
    /// every later one is answered from the user's decision without asking again. A refusal
    /// is an ordinary outcome — Spotlight goes on answering as if the folder were empty, the
    /// page is shorter, and nothing here is an error. A folder that does not exist is the
    /// same non-event.
    ///
    /// Before the query and not after, so that on the very scan where the user says yes the
    /// index already answers for the folder they just allowed.
    static func askForProtectedFolders(_ context: ScanContext) {
        for folder in foldersBehindAPermissionPrompt {
            _ = try? context.fileManager.contentsOfDirectory(atPath: context.homePath(folder))
        }
    }

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        Self.askForProtectedFolders(context)
        let found = Self.biggestFirst(Self.licenced(Self.spotlightPaths(context), context))
        // The same canonical home each path was checked against — `realpath` of the same
        // string, so the two cannot disagree — and used for nothing but the row's `detail`.
        // A home that cannot be resolved licences nothing at all, so the fallback here is
        // unreachable rather than a second answer.
        let text = ReportText(home: PathGuard.canonicalise(context.home) ?? context.home)

        return found.map { licence in
            let path = licence.path as NSString
            return ScanHelpers.item(
                scannerID: id, group: group, path: licence.path,
                // The file's own name, which is what the user recognises and what they saw
                // in macOS Storage.
                name: path.lastPathComponent,
                // The parent folder, abbreviated. **This is what tells two rows apart**:
                // `~/Documents/archive/scans/batch-a/current` holds a
                // `scan.pdf` and so do fifteen sibling folders, and a page of sixteen
                // identical names with checkboxes beside them is unanswerable.
                detail: text.abbreviate(path.deletingLastPathComponent),
                // Read off the disk by the licence, never off the Spotlight index.
                sizeBytes: licence.sizeBytes,
                // When the user last changed it, which for one of their own files is the
                // only date that means anything. Not the added-to-folder date
                // `big.downloads` uses: that answers "when did this land here", which is a
                // question about a download and not about a film somebody has kept.
                lastUsed: licence.modified,
                risk: .irreplaceable,
                // Never ticked. The rule the whole of `GroupID.bigThings` exists under, and
                // here it is the difference between a page the user answers and a button
                // that moves their films to the Trash for them.
                startsUnticked: true)
        }
    }

    /// What Spotlight answered, as untrusted strings.
    ///
    /// **Every way of failing is the same answer: no rows.** Spotlight switched off for the
    /// volume, indexing not finished, `mdfind` refusing to run at all, a non-zero exit, an
    /// empty index — all of them produce an empty list, never an error and never a fallback
    /// walk of the home folder. This scanner finding nothing has to be an ordinary outcome,
    /// because on a machine with Spotlight disabled it is the *permanent* outcome, and a
    /// scan that failed or crawled for two minutes because of it would be the app punishing
    /// the user for a system setting.
    ///
    /// **Nothing is trimmed and nothing is trusted.** `mdfind` separates paths with
    /// newlines and has no `-0`, so a file whose name contains a newline arrives as two
    /// fragments — neither of which exists on disk, so both are dropped, and that file is
    /// silently not offered. That is the safe direction and the only one available. Stray
    /// whitespace is left on for the same reason: a filename may legally end in a space, so
    /// trimming could turn one real path into another real path, while a line carrying a
    /// `\r` or any other stray character simply fails to exist and falls away in
    /// `LargeFileLicence`.
    static func spotlightPaths(_ context: ScanContext) -> [String] {
        guard let result = try? context.runner.run(
            mdfindPath, ["-onlyin", context.home, spotlightQuery]),
            result.succeeded
        else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    /// The licence for each path that earns one, each file once.
    ///
    /// De-duplicated on the canonical path rather than on what Spotlight said, so two
    /// spellings of one file cannot take two of the two hundred rows. `ScanEngine`
    /// de-duplicates by target as well and would drop the second row anyway; this is what
    /// keeps the scanner's own count and its cap honest before it gets there.
    static func licenced(_ paths: [String], _ context: ScanContext) -> [LargeFileLicence] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard let licence = LargeFileLicence.granted(
                for: path, home: context.home, fileManager: context.fileManager)
            else { return nil }
            guard seen.insert(licence.path).inserted else { return nil }
            return licence
        }
    }

    /// Biggest first, cut to `maximumRows`. Ties broken by path, so a page dealt twice from
    /// one scan is the same page and the checkboxes do not move under the cursor.
    static func biggestFirst(_ found: [LargeFileLicence]) -> [LargeFileLicence] {
        Array(found.sorted {
            $0.sizeBytes == $1.sizeBytes ? $0.path < $1.path : $0.sizeBytes > $1.sizeBytes
        }.prefix(maximumRows))
    }
}

/// **The one rule about what this app may do to a file of the user's own**, asked twice:
/// once by `LargeFilesScanner` to decide what may be offered, and again by
/// `CleanerService.clean` to decide what may be removed.
///
/// One function rather than two lists of checks, because the two questions are the same
/// question and a difference between them is a hole. The scan is minutes old by the time
/// anybody presses a button: the file may have been replaced by a directory, or by a
/// symlink pointing at somebody's photo library, or moved, or truncated. So the licence is
/// **per file and re-earned**, and the guard for the run admits exactly the paths that earn
/// it again right then — see `PathGuard.forRun`.
///
/// **The home folder is not a `PathGuard` root and must never become one.** That is the
/// whole difficulty of this feature. These files are anywhere under home, so there is no
/// narrow containing directory to name; the alternative to a per-file licence is a licence
/// over `~`, which would be a licence over `~/Documents`, `~/Desktop`, `~/Movies` and
/// everything else the user has, granted for the sake of a checklist page. Every rule below
/// is therefore a rule about one path, and the only thing it ever admits is that path.
public struct LargeFileLicence: Sendable, Equatable {
    /// The **canonical** path the licence is for: parent resolved, final component left
    /// verbatim, exactly as `PathGuard.validate` canonicalises what it is asked about.
    ///
    /// This is the string to act on. Spotlight's spelling may contain a `..`, a `.`, or a
    /// symlinked parent, and the path that was checked is the only path it is safe to
    /// remove — the same rule `PathGuard.validate` states about its own return value.
    public let path: String
    /// The size **read off the disk**, which is what the row shows.
    ///
    /// Spotlight's `kMDItemFSSize` is an index entry and can be minutes or months stale;
    /// this comes from the same `lstat` that decided the thing is a regular file, so the
    /// kind and the size cannot describe two different moments.
    ///
    /// The file's own length, which is the number Finder, `ls` and macOS Storage all show
    /// for it — deliberately not a count of allocated blocks. The one case where the two
    /// differ is a sparse or cloned file, where trashing frees less than this says; that is
    /// true of every size in this app and is what the group's Trash sentence already says.
    public let sizeBytes: Int64
    /// When the user last changed it. `nil` when the filesystem would not say.
    public let modified: Date?

    /// The floor a file has to clear to be worth a checkbox.
    ///
    /// 200 MB, decimal, and lower than `BigThings.minimumBytes` — which is 500 MB because a
    /// download under that is not worth a card of its own. This is a different shape of
    /// question: one page holding everything, where a row costs the user a line to read
    /// rather than a card to answer, so the floor can sit where the files actually are.
    /// macOS Storage's own Large Files list starts at about this size, the user's smallest
    /// example was 355 MB, and the 250–500 MB lesson videos are the ones they are most
    /// likely to want gone. Under 200 MB a dev machine's home folder has thousands of
    /// files and none of them is the problem.
    public static let minimumBytes: Int64 = 200_000_000

    /// Top-level folders of the home directory that are never looked in.
    ///
    /// `Library` is the machine's, not the user's: application support, mail, container
    /// data, and this app's own `settings.json`, `cache.json` and run log — which is what
    /// keeps a scan from offering the file the next scan is read from. Nothing in there is
    /// a file the user put somewhere, and `mdfind` answers with plenty of it.
    ///
    /// `Downloads` belongs to `big.downloads`, which asks about its direct children with a
    /// 500 MB floor and sentences about what each one is. Two scanners offering one file is
    /// two cards for one decision, and `ScanEngine` cannot tell which of them to keep.
    ///
    /// Compared case-insensitively, because macOS volumes are case-insensitive by default
    /// and `library` names the same directory.
    public static let excludedTopLevelFolders = ["Library", "Downloads"]

    /// Path component extensions that mean "this is one thing, not a folder of things".
    ///
    /// A 1.2 GB video inside `Photos Library.photoslibrary` is not a file the user can
    /// answer about: it is a frame of something Photos owns, and removing it corrupts the
    /// library rather than freeing space the user chose to give up. The same is true of an
    /// app's payload, an archive's `.dSYM`, a GarageBand project's audio.
    ///
    /// **Decided by extension rather than by `URL.isPackage`**, and the reason is that the
    /// question is about ancestors, not about the file. `isPackage` answers for the
    /// directory itself, so the file inside `Foo.app` would answer "not a package" and be
    /// offered; asking it of every ancestor of every candidate is a LaunchServices lookup
    /// per component whose answer depends on which apps happen to be installed. A scan's
    /// safety rule cannot mean different things on two Macs, so this is a fixed list, read
    /// against every component of the path.
    ///
    /// Lower-cased on both sides: `.DSYM` and `.dSYM` are one kind of thing.
    public static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "plugin", "xpc",
        "photoslibrary", "aplibrary", "tvlibrary", "imovielibrary", "theater", "fcpbundle",
        "xcarchive", "dsym", "xcodeproj", "xcworkspace", "playground", "docset",
        "band", "logicx", "pages", "numbers", "key", "rtfd", "sparsebundle", "download",
    ]

    /// Whether this path may be offered, and what to say about it. `nil` means no.
    ///
    /// Every rule is stated once, here, and each of them is tested end to end through
    /// `CleanerService.clean` as well as from the scanner's side:
    ///
    /// 1. **Absolute.** A relative path resolves against whatever directory the process is
    ///    running in, so its verdict would depend on that. Spotlight answers with absolute
    ///    paths; a line that is not one did not come from Spotlight.
    /// 2. **Resolvable, and acted on as resolved.** The parent is canonicalised and the
    ///    final component left verbatim, so a `..` cannot walk out of the rules below and a
    ///    symlink at the leaf keeps its own identity instead of standing in for its target.
    /// 3. **Strictly under the home directory**, separator-aware, so a home of `/Users/x`
    ///    does not admit `/Users/xavier`.
    /// 4. **Not in `~/Library` and not in `~/Downloads`** — see `excludedTopLevelFolders`.
    /// 5. **No hidden component.** A path with a `/.` in it is somebody's tool state:
    ///    `~/.cache`, `~/.Trash`, a repository's `.git`. The user did not put a file there
    ///    and cannot judge one from its name, and `~/.Trash` in particular is a list of
    ///    things they have already thrown away.
    /// 6. **Not inside a package** — see `packageExtensions`.
    /// 7. **A regular file.** Not a directory, which would be a whole tree removed for a
    ///    row that claimed to be a file; not a symlink, whose size is its target's while
    ///    trashing it frees nothing at all. `attributesOfItem` is `lstat`-shaped and reports
    ///    the link itself, which is the answer `fileExists` cannot give.
    /// 8. **At or over `minimumBytes`, measured now.** A file that has shrunk since the scan
    ///    is a file whose row is describing something that no longer exists.
    ///
    /// What is deliberately **not** here is the scanner's identifier: this answers about a
    /// path, and `allowedExactPaths(for:home:fileManager:)` is what answers about a row.
    public static func granted(
        for path: String, home: String, fileManager: FileManager
    ) -> LargeFileLicence? {
        guard path.hasPrefix("/") else { return nil }
        guard let home = PathGuard.canonicalise(home),
              let target = PathGuard.canonicaliseKeepingLeaf(path),
              target.hasPrefix(home + "/")
        else { return nil }

        let components = (String(target.dropFirst(home.count + 1)) as NSString).pathComponents
        guard let top = components.first else { return nil }
        guard !excludedTopLevelFolders.contains(where: {
            top.caseInsensitiveCompare($0) == .orderedSame
        }) else { return nil }
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return nil }
        guard !components.contains(where: {
            packageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }) else { return nil }

        guard let attributes = try? fileManager.attributesOfItem(atPath: target),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= minimumBytes
        else { return nil }

        return LargeFileLicence(
            path: target, sizeBytes: size,
            modified: attributes[.modificationDate] as? Date)
    }

    /// The paths a run may remove, out of the rows it was handed.
    ///
    /// This is the whole of what `big.largeFiles` contributes to `PathGuard.forRun`, and it
    /// contributes **exact paths only**: no root, nothing about a parent, nothing about a
    /// sibling. A row from any other scanner earns nothing here however it is spelled — a
    /// forged item naming somebody's `~/Documents/taxes.pdf` under
    /// `scannerID: "projects.buildOutput"` is refused by the guard exactly as it was before
    /// this feature existed, and one naming it under this scanner's identifier still has to
    /// pass every rule in `granted(for:home:fileManager:)` against the disk as it is now.
    public static func allowedExactPaths(
        for items: [CleanupItem], home: String, fileManager: FileManager
    ) -> [String] {
        items.compactMap { item in
            guard item.scannerID == LargeFilesScanner.scannerID,
                  case .removePath(let path) = item.method
            else { return nil }
            return granted(for: path, home: home, fileManager: fileManager)?.path
        }
    }
}
