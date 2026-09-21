import Foundation

// Three scanners for the caches that are **not** a developer tool's: the browsers, the
// XDG cache directory, and the Chromium-based desktop apps.
//
// They are separate scanners rather than more entries in `LibraryCachesScanner` because the
// deck deals one card per scanner and the cards answer different questions. "Developer tool
// caches" is about a toolchain — Xcode's index, SwiftPM's clones, Homebrew's bottles — and a
// user who switches that off in settings has said something about their tools. 3.1 GB of
// Brave is not a tool cache, and folding it in would put it behind a switch whose label
// never mentioned browsers.
//
// **And no two of the three are dealt the same way**, which is the clearest evidence that
// separating them was right. Two of them turned out to be measuring things the app should
// not offer to remove at all and became `DeckDealing.mentionOnly`; the third, `~/.cache`, is
// dealt one card per folder, ticks only the tools it can name, and had a whole category of
// row taken out of it after a card from it broke another app — see
// `XDGCacheScanner.excludedChildren`. Folded into one scanner, one of those decisions would
// have had to be wrong.

/// Browser and desktop-app caches directly under `~/Library/Caches`, from a fixed allowlist.
///
/// `~/Library/Caches` holds 158 folders on the machine this was written against, so this
/// scanner never asks what looks big: it looks for names it already knows, and adding one is
/// a code change somebody reviews. That is the same rule `LibraryCachesScanner` documents,
/// and it matters more here — a wrong guess in this directory reaches Mail, Photos and the
/// system daemons.
///
/// **`com.apple.Safari` is deliberately absent.** It is protected by TCC, so reading it
/// prompts the user for Full Disk Access and removing it fails: the row could only ever be an
/// error message beside a tick box.
///
/// **`Google` is never named, only `Google/Chrome` and `Google/Chrome-headless`.** The parent
/// also holds `AndroidStudio<version>`, which `other.libraryCaches` offers as its own row —
/// so a row for `Google` would contain another scanner's row. `ScanEngine` de-duplicates on
/// the deletion **target**, and those are two different paths, so both rows would survive and
/// the headline would count the Android Studio cache twice.
///
/// **Nothing in this app cleans these rows.** Shown the real cards, the user was plain that
/// they would not be cleaning them, and they were right: a browsing cache is the one thing
/// in this whole registry whose loss the user feels immediately and personally, on every
/// site they visit, and a browser is also perfectly capable of clearing it from its own
/// settings. So the scanner still measures, and the deck deals it no card at all: see
/// `DeckDealing.mentionOnly`, and `ProjectDeck.moreToGain`, which is where the sizes go.
public struct AppCacheScanner: CleanupScanner {
    public static let scannerID = "other.appCaches"

    public let id = Self.scannerID
    public let group = GroupID.otherCaches
    public let title = "Browser and app caches"
    /// No card. The rows are measured, named on the last page with their sizes, and never
    /// removed by anything — see `DeckDealing.mentionOnly`.
    public var deckDealing: DeckDealing { .mentionOnly }

    public init() {}

    /// The sentence every browser row carries.
    ///
    /// `.safe` rather than `.elevated`, and this is why: the bytes really do come off the
    /// network, but nothing waits for them. A browser fills its cache as pages are read and
    /// a user on a plane notices a slower page, not a failed build — which is the
    /// distinction `RiskLevel` draws. `Mozilla` below is the exception and says so.
    static let browserDetail = "the browser rebuilds it as you browse"

    private static let allowed: [FixedLocationScan] = [
        // Two folders per Chromium browser, and they are not the same thing: the profile's
        // own cache, and the app's `NSURLCache`. Both appear on a real dev machine, so both
        // are named — and named apart, because two rows reading "Brave" are two rows the
        // user cannot choose between.
        FixedLocationScan(relativePath: "Library/Caches/BraveSoftware",
                          name: "Brave browsing cache", detail: browserDetail),
        FixedLocationScan(relativePath: "Library/Caches/com.brave.Browser",
                          name: "Brave app cache", detail: browserDetail),
        FixedLocationScan(relativePath: "Library/Caches/Google/Chrome",
                          name: "Chrome browsing cache", detail: browserDetail),
        FixedLocationScan(relativePath: "Library/Caches/Google/Chrome-headless",
                          name: "Chrome headless cache", detail: browserDetail),
        FixedLocationScan(relativePath: "Library/Caches/com.google.Chrome",
                          name: "Chrome app cache", detail: browserDetail),
        FixedLocationScan(relativePath: "Library/Caches/Firefox",
                          name: "Firefox cache", detail: browserDetail),
        // Not a browsing cache: `~/Library/Caches/Mozilla` holds downloaded updates, which
        // come back as one deliberate fetch of a whole application rather than a page at a
        // time — so it is the one `.elevated` row here.
        FixedLocationScan(relativePath: "Library/Caches/Mozilla",
                          name: "Firefox update downloads",
                          detail: "re-downloaded the next time Firefox updates",
                          risk: .elevated),
        FixedLocationScan(relativePath: "Library/Caches/com.spotify.client",
                          name: "Spotify cache",
                          detail: "re-downloaded as you play music again",
                          risk: .elevated),
    ]

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        await FixedLocationScan.items(
            Self.allowed, scannerID: id, group: group, context: context,
            // **This, not `deckDealing`, is what keeps these out of a clean.** Every route
            // that removes something reads `CleanupItem.selectedByDefault` — the scan's own
            // `defaultSelection`, `CleanerService.cleanDefault`, `devcleaner clean`, the
            // amount the menu bar shows — and none of them has ever heard of a
            // `DeckDealing`. A safety rule that lived in the window's drawing decision
            // would be one refactor away from being gone.
            startsUnticked: true)
    }
}

/// Direct children of `~/.cache`, each one its own row.
///
/// **The one scanner in this package that offers folders it has no name for**, and the
/// reason is the directory itself. `~/.cache` is the XDG cache directory: by that convention
/// everything in it is disposable and re-created by whichever tool wrote it, which is a
/// promise about the *location* rather than about any particular folder. So the rule here is
/// the location plus a floor, and the rows the scanner cannot name get an honest generic
/// sentence instead of a specific one it would be inventing.
///
/// Four things keep that from becoming "delete whatever is big":
///
/// - **Direct children only.** Never `~/.cache` itself — `PathGuard.forRun` lists it as a
///   forbidden target as well as making it a root, so two independent rules say so — and
///   never a grandchild, whose tool would not recognise the gap.
/// - **Real directories, never a symbolic link.** A link here would be offered under a name
///   that is not a cache, sized by whatever it points at, and trashing it would move the
///   link and free none of those bytes. See `ScanHelpers.isSymbolicLink`.
/// - **A floor.** `~/.cache` on a real dev machine holds 7.8 GB in a handful of large
///   children and a long tail of a few kilobytes each; a card per tail entry is a question
///   not worth asking, and the floor is also what keeps a folder `du` could not measure out
///   of the list entirely.
/// - **`excludedChildren`.** The folders in this directory that the convention is wrong
///   about, because what is in them is an installed AI model and not a cache. That list
///   exists because of a real incident; it is documented on the constant.
public struct XDGCacheScanner: CleanupScanner {
    public static let scannerID = "other.xdgCache"

    public let id = Self.scannerID
    public let group = GroupID.otherCaches
    public let title = "Caches in ~/.cache"
    /// One card per folder: a user may want `uv` gone and `huggingface` kept, and these
    /// rows have nothing in common beyond the directory they sit in.
    public var deckDealing: DeckDealing { .perItem }

    public init() {}

    /// The floor a child has to clear to be offered at all.
    ///
    /// A named constant because two things read it: the scanner, and the test that pins
    /// which children a real `~/.cache` would produce.
    public static let minimumBytes: Int64 = 50_000_000

    /// What a folder this scanner has never heard of says about itself.
    ///
    /// Honest about being generic. The alternative — printing nothing — leaves a card with
    /// a folder name, a size and no reason at all to press either button.
    ///
    /// It is not the whole of what such a card says any more. The generic sentence is a
    /// shrug, and a shrug over a button that deletes 2.4 GB is not enough: the card also
    /// carries `ProjectDeckText.unknownToolCaution` and has no Return key. See
    /// `knows(childNamed:)`, which is the fact the deck reads to decide that.
    public static let unknownDetail = "a tool's cache folder; the tool re-creates it"

    /// **Children this scanner never offers at all, whatever their size.**
    ///
    /// This list is here because of an incident. A user pressed Clean up on a card headed
    /// `huggingface`, 1.25 GB, over the sentence "models are downloaded again when a script
    /// next asks for them". Minutes later their on-device dictation app logged `Failed to
    /// load model: Model not found` and stopped working until it had re-downloaded 1.1 GB.
    /// Its working Whisper model lived at
    /// `~/.cache/huggingface/hub/models--org--whisper-large-v3-gguf`, and
    /// nothing on that card connected the word "huggingface" to the app they rely on.
    ///
    /// The card was not wrong about the directory. It was wrong about what kind of thing
    /// was in it. `~/.cache`'s convention promises that a tool re-creates what it wrote,
    /// and a model store keeps that promise only in the sense that a gigabyte comes back
    /// over somebody's network while the app that needs it is broken. That is the
    /// distinction `GroupID.bigThings` exists for, so the models moved there — one row per
    /// model, click-only, always to the Trash, behind the interstitial (see
    /// `AIModelScanner`) — and `~/.cache/huggingface` as a **whole** is now offered by
    /// nothing at all.
    ///
    /// The other names are the same mistake waiting to be made: every one of them is a
    /// store of downloaded model weights that some app on the machine loads at run time.
    /// `ollama` and `lm-studio` are here as well as having their own rows in
    /// `AIModelScanner`, because a stray cache directory under one of those names must not
    /// be a second, un-warned route to the same bytes.
    ///
    /// **Excluded means not offered, not "offered more carefully".** Nothing in this app
    /// can delete one of these folders, and `PathGuard.forRun` says so a second time by
    /// registering each of them as a forbidden target — `~/.cache` is an allowed root, so
    /// "no scanner names it" would otherwise be the only thing standing in the way.
    ///
    /// Every entry is lower case, and `scan` compares against it that way, because macOS
    /// volumes are case-insensitive by default and `~/.cache/HuggingFace` is the same
    /// directory as `~/.cache/huggingface`.
    public static let excludedChildren: Set<String> = [
        "huggingface", "torch", "whisper", "lm-studio", "ollama", "modelscope", "nltk_data",
    ]

    /// Every row's risk. `.elevated` for all of them, including the ones rebuilt locally:
    /// this scanner does not know what most of these folders are, and the safe direction for
    /// an unknown is the one that warns.
    static let risk = RiskLevel.elevated

    /// The tools this scanner can name, and the sentence each one gets.
    ///
    /// Specific where it can be: "re-downloaded on the next uv install" is a fact the user
    /// can weigh, and `unknownDetail` is a shrug. It is a table rather than a `switch`
    /// because two things now need it — the sentence, and `knows(childNamed:)`, which is
    /// what the deck reads to decide whether the card gets a caution and loses its Return
    /// key. A `switch` can answer the first question and not the second, and a second list
    /// of "the names we know" would be free to disagree with this one.
    ///
    /// **`huggingface` is deliberately not here any more.** Its sentence used to read
    /// "models are downloaded again when a script next asks for them", which is the line
    /// the user read before they broke their dictation app — see `excludedChildren`. The
    /// scanner cannot produce that row at all now, so a sentence for it would be prose
    /// nothing prints, still claiming the thing that was not true.
    /// **`codex-runtimes` is here on the strength of watching it come back.** It holds
    /// `codex-primary-runtime/{dependencies,plugins,runtime.json}`, and after the folder was
    /// removed the app rebuilt all 1.6 GB of it by itself, unprompted, the same day. That is
    /// the same fact `ms-playwright` and `firebase` are in this list for — a fetch the tool
    /// makes again on its own — so the sentence says the cost out loud: it is a download,
    /// not a local rebuild.
    public static let knownDetails: [String: String] = [
        "uv":             "re-downloaded on the next uv install",
        "pip":            "re-downloaded on the next pip install",
        "firebase":       "re-downloaded the next time the Firebase tools run",
        "puppeteer":      "the browser is downloaded again on the next puppeteer install",
        "pre-commit":     "hook environments are rebuilt on the next pre-commit run",
        "ms-playwright":  "the browsers are downloaded again on the next playwright install",
        "node-gyp":       "re-downloaded the next time a native module is built",
        "go-build":       "rebuilt on the next go build",
        "codex-runtimes": "re-downloaded the next time the Codex app runs",
    ]

    /// The sentence for a folder, whether or not this scanner has heard of it.
    public static func detail(forChildNamed name: String) -> String {
        knownDetails[name] ?? unknownDetail
    }

    /// **Whether this scanner knows what wrote a folder**, which is the one fact about
    /// these rows that changes how the card may be answered.
    ///
    /// Published as a predicate, so the deck asks the scanner rather than deciding for
    /// itself. There are two other ways it could have been done and both are worse. A soft
    /// field on `CleanupItem` would put the answer in the cache, where a `cache.json`
    /// written before the rule existed carries the wrong one for ever; comparing
    /// `item.detail` against `unknownDetail` would make a piece of prose load-bearing, so
    /// rewording a sentence would silently give a card its Return key back. This reads the
    /// same table the sentence came from, so the two cannot disagree.
    ///
    /// The row's `name` **is** the folder's name — that is what `scan` sets it to — so
    /// there is nothing to parse and nothing to guess.
    ///
    /// A name in `excludedChildren` answers `false`, and that is the safe direction rather
    /// than an oversight. This scanner can no longer produce such a row, so the only way
    /// one reaches the deck is out of a `cache.json` an older build wrote — a stale
    /// `huggingface` card, exactly the one from the incident — and it should be the
    /// hardest card in the deck to answer by reflex, not the easiest.
    public static func knows(childNamed name: String) -> Bool {
        knownDetails[name] != nil
    }

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let root = context.homePath(".cache")
        let children = ScanHelpers.children(of: root, fileManager: context.fileManager)
            .filter(\.isDirectory)
            .filter { !ScanHelpers.isSymbolicLink($0.path, fileManager: context.fileManager) }
            // The model stores, which are not caches whatever directory they sit in. First,
            // before the size and before the name: an exclusion that ran after a floor or a
            // measurement would be an exclusion with a way round it.
            //
            // Case-insensitively, because macOS volumes are by default: `~/.cache/HuggingFace`
            // and `~/.cache/huggingface` are one directory, and a `Set.contains` on the raw
            // name would offer the first and refuse the second. `PathGuard.validate`
            // lower-cases both sides of its forbidden test for the same reason, so the guard
            // would refuse such a row anyway — this is the layer that stops it being offered
            // at all, which is the one the user sees.
            .filter { !Self.excludedChildren.contains($0.name.lowercased()) }
            // `contentsOfDirectory` promises no order, and a deck that reshuffles between
            // scans deals the user a different card than the one they were reading.
            .sorted { $0.name < $1.name }

        // One call with every path, so `sizes(of:)` keeps its cap of four `du` processes.
        let sizes = await context.sizeMeasurer.sizes(of: children.map(\.path))

        return children.compactMap { child in
            let size = ScanHelpers.measured(sizes, child.path)
            // The floor, which also settles the unmeasured case: `measured` answers zero
            // for a folder `du` could not size, and zero is below any floor. That is the
            // right answer here rather than an unticked row, because this scanner has no
            // name for what it would be offering — a card reading "0 KB" over a folder
            // nobody can identify is nothing for a user to decide about.
            guard size.bytes >= Self.minimumBytes else { return nil }
            return ScanHelpers.item(
                scannerID: id, group: group, path: child.path,
                // The folder's own name, which is also the card's title. It is the only
                // name there is — the tool that wrote it chose it.
                name: child.name,
                detail: Self.detail(forChildNamed: child.name),
                sizeBytes: size.bytes, lastUsed: child.modified, risk: Self.risk,
                // **A folder this scanner cannot name is offered and never ticked.**
                //
                // `excludedChildren` is a denylist, and a denylist of model stores can
                // never be finished: `sentence-transformers`, `gpt4all`, `mlx`, `open_clip`,
                // `diffusers`, `spacy`, `llama.cpp` and `chroma` all write here too, and the
                // next one has not been published yet. The dictation-app incident is what a card
                // over one of those costs; a *default clean* over one is worse, because
                // `devcleaner clean` never showed a card at all and in permanent mode the
                // executor does not even leave it in the Trash.
                //
                // So the rule is turned round: this scanner ticks only what it can name.
                // `uv`, `pip`, `go-build` and the five others keep exactly today's
                // behaviour — the app knows what wrote them and what it costs to lose them
                // — and everything else is offered with its size, left out of
                // `defaultSelection`, `CleanerService.cleanDefault`, `devcleaner clean` and
                // the amount the status panel shows, and dealt by the deck as a card that
                // has to be clicked. See `knows(childNamed:)` and
                // `ProjectDeckText.unknownToolCaution`.
                //
                // No `untickedReason`. That field is a `ProtectionReason` — a vocabulary of
                // "something is using this" — and the reason here is that the app does not
                // know, which is not one of its cases and not a claim about the folder.
                startsUnticked: !Self.knows(childNamed: child.name))
        }
    }
}

/// The cache subfolders of the Chromium-based desktop apps, under
/// `~/Library/Application Support`.
///
/// VS Code is 1.9 GB there, Cursor 1.4 GB and Slack 1.3 GB, and almost all of it is cache
/// that the app rewrites as it runs. The danger is entirely in the neighbours: the same app
/// folder holds `User` (every setting, keybinding and snippet), `Local Storage`, `IndexedDB`,
/// `Cookies` and `storage` — the app's data, and in Slack's case the reason you are still
/// signed in.
///
/// So this scanner names **only** the cache subfolders, never an app folder and never the
/// container — and `PathGuard.forRun` now names none of them at all. It used to admit each
/// one as an `allowedExactPath`, deliberately never a per-app root, because a root over
/// `Code` would have been a licence over `Code/User`. With the scanner `.mentionOnly` there
/// is nothing left to admit, so the licence went; the app folders and the container stay in
/// `runRelativeForbiddenTargets`, which is the statement that survives.
///
/// **Telegram Desktop is not here.** It is 1.5 GB and it is Qt rather than Electron, so none
/// of these subfolder names exist in it and whatever it does keep is its own business.
///
/// **Nothing in this app cleans these rows either.** The card read "Desktop app caches" over
/// forty-eight folders belonging to Slack, Claude, VS Code and Cursor, and the user's answer
/// was to take it out of the deck and mention it on the last page instead. The card was
/// never a good question: these are the working caches of apps that are *running while the
/// deck is on screen*, the gain is a slower first launch each, and the one thing a user
/// would actually want — "clear Slack's cache" — is a button inside Slack. See
/// `DeckDealing.mentionOnly`, and `PathGuard.runRelativeExactPaths` for the forty-eight
/// deletion licences this decision let the guard give back.
public struct ElectronCacheScanner: CleanupScanner {
    public static let scannerID = "other.electronCaches"

    public let id = Self.scannerID
    public let group = GroupID.otherCaches
    public let title = "Desktop app caches"
    /// No card. Summed **per app** and named on the last page — see
    /// `app(ofRowNamed:)`, which is how the note adds six rows of Slack's into one line.
    public var deckDealing: DeckDealing { .mentionOnly }

    public init() {}

    /// The container. **Never a root and never a target** — it holds `MobileSync`,
    /// `Firefox` profiles and every other app's data.
    public static let container = "Library/Application Support"

    /// The apps, by the folder name each one really uses. `discord` is lower case because
    /// that is how Discord writes it.
    public static let apps = [
        "Code", "Cursor", "Slack", "discord", "Notion", "Figma", "Postman", "Claude",
    ]

    /// The subfolders Chromium and VS Code write **caches** into, and nothing else.
    ///
    /// Chromium's four (`Cache`, `Code Cache`, `GPUCache`, `Service Worker/CacheStorage`)
    /// plus the two VS Code adds for its own bundles. Each one is rewritten from scratch by
    /// the running app; none of them holds anything the user typed.
    public static let cacheFolders = [
        "Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs",
        "Service Worker/CacheStorage",
    ]

    /// Every path this scanner can ever name, relative to the home directory.
    ///
    /// It used to be read by `PathGuard.runRelativeExactPaths`, which granted the run a
    /// licence over each of these. It is now read by the test that asserts the guard
    /// **refuses** every one of them — the scanner is `.mentionOnly`, nothing offers its
    /// rows for deletion, and 48 unexercisable approvals inside folders that also hold
    /// `Code/User` and `Slack/Cookies` are not free.
    ///
    /// So the list is kept and its job reversed. Either way what makes it worth having is
    /// that it is the **complete** statement of what this scanner can name, generated from
    /// the two lists above rather than written out beside them.
    public static var relativeCachePaths: [String] {
        apps.flatMap { app in cacheFolders.map { "\(container)/\(app)/\($0)" } }
    }

    /// Which app a row belongs to, or `nil` for a name this scanner did not write.
    ///
    /// The one fact `ProjectDeck.moreToGain` needs and a row does not carry: the note lists
    /// one line per **app**, so six rows reading "Slack – Cache", "Slack – GPUCache" and so
    /// on have to add up to one "Slack · 1.3 GB". A row is one subfolder because a
    /// `removePath` is one path, so the app can only come back out of the row.
    ///
    /// Published here, and taken apart with the same two constants `scan` puts it together
    /// from — `ProjectRowPath.separator` and `apps`. The deck splitting on an en dash of its
    /// own would be a second spelling of this scanner's naming rule, and the day a row's
    /// name is reworded the note would quietly stop summing and list six Slacks.
    ///
    /// The head has to be an app this scanner knows. A row whose name happens to contain an
    /// en dash — a stale one out of a `cache.json`, or a future app folder with a dash in
    /// its own name — answers `nil` and is listed under its own name rather than under a
    /// heading invented from half of it.
    public static func app(ofRowNamed name: String) -> String? {
        guard let separator = name.range(of: ProjectRowPath.separator) else { return nil }
        let head = String(name[..<separator.lowerBound])
        return apps.contains(head) ? head : nil
    }

    /// The app folders themselves, which `PathGuard.forRun` registers as forbidden targets.
    ///
    /// Belt and braces: the exact-path list above already means the guard admits nothing but
    /// the cache subfolders, so an app folder is refused as outside every root. This says it
    /// a second, independent way, and it is the statement that survives somebody later
    /// deciding a root would be tidier.
    public static var relativeAppPaths: [String] { apps.map { "\(container)/\($0)" } }

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        await FixedLocationScan.items(
            Self.apps.flatMap { app in
                Self.cacheFolders.map { folder in
                    FixedLocationScan(
                        relativePath: "\(Self.container)/\(app)/\(folder)",
                        // "Code – GPUCache". One `removePath` per row means one row per
                        // subfolder rather than one per app, so the app has to be in the
                        // name: six rows reading "GPUCache" would be six rows the user
                        // cannot tell apart. The separator is `ProjectRowPath.separator`,
                        // the same en dash the Trash names use.
                        name: app + ProjectRowPath.separator + folder,
                        detail: Self.detail(app: app))
                }
            },
            scannerID: id, group: group, context: context,
            // As on `AppCacheScanner`: this, and not `deckDealing`, is what keeps these
            // rows out of every default clean.
            startsUnticked: true)
    }

    /// What one of these rows says about itself.
    ///
    /// `.safe`, by `FixedLocationScan.items`' default, and it is the honest reading: the app
    /// writes these folders itself as it runs, with no download and no build waiting on
    /// them. The worst a clean costs is a slower first launch.
    public static func detail(app: String) -> String { "rebuilt as you use \(app)" }
}
