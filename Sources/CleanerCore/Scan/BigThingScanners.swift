import Foundation

// The two scanners in `GroupID.bigThings`, and the one rule they share.
//
// Everything else in this package offers something a tool made and a tool will make again.
// These offer things **nothing on this machine will re-create by itself**: the user's own
// downloads, and the AI models an app went and fetched. A model is not literally the user's
// file — some tool did write it — and it belongs here all the same, because the test that
// matters is not who created it but what happens when it is gone. A `.build` folder comes
// back from the next build; a model comes back only when somebody downloads a gigabyte
// again, and until they do the app that needs it is broken. `~/.cache/huggingface` was
// filed as a cache on exactly the other reading, and `XDGCacheScanner.excludedChildren`
// records what that cost.
//
// The promise is therefore withdrawn rather than qualified — `RiskLevel.irreplaceable` —
// and three things follow from it, all of them in code:
//
//   1. every row is `startsUnticked`, so no default clean, no `cleanDefault`, no
//      `devcleaner clean` and no menu-bar figure ever includes one;
//   2. the executor always moves them to the Trash, whatever `Settings.moveToTrash` says —
//      see `CleanupItem.goesToTheTrash(moveToTrash:)`;
//   3. the deck deals them one card at a time, after everything that comes back, behind a
//      card that says the promise has changed, and each one has to be clicked.

/// The floor `big.downloads` uses. `big.aiModels` has its own, and lower — see
/// `AIModelScanner.minimumBytes`.
public enum BigThings {
    /// The floor a file or folder has to clear to be worth a card.
    ///
    /// 500 MB, ten times the deck's own `minimumCardBytes`, and deliberately much higher.
    /// This is the one group where the app is asking about the user's own things, so the
    /// question has to be worth the intrusion: `~/Downloads` on a real dev machine holds
    /// 30 GB in about a dozen entries over this floor and several hundred under it, and a
    /// deck that asked about a 60 MB PDF would have taught the user to stop reading the
    /// cards before it reached the 7 GB one.
    ///
    /// **`AIModelScanner` no longer uses it**, and has its own lower floor for a reason
    /// worth reading there: a download is something the user chose to keep, while a model
    /// is something an app *depends on*, and the two are not worth the same question.
    public static let minimumBytes: Int64 = 500_000_000
}

/// Large files and folders sitting directly in `~/Downloads`.
///
/// **Direct children only.** Never `~/Downloads` itself — `PathGuard.forRun` names it a
/// forbidden target as well as a root, so two independent rules say so — and never a
/// grandchild, because a folder is one thing the user recognises and picking pieces out of
/// it is not a question this window can ask.
///
/// **A refused permission reads as "nothing found".** `~/Downloads` is protected by TCC, so
/// the first read prompts the user and a refusal makes `contentsOfDirectory` throw.
/// `ScanHelpers.children` answers an empty list for that, which is exactly right here: the
/// scan carries on, every other scanner is unaffected, and the deck simply has no downloads
/// card. It costs one failed syscall rather than a timeout, so it cannot slow the scan
/// either, and there is nothing for the user to fix in this app — the switch is in System
/// Settings.
public struct DownloadsScanner: CleanupScanner {
    public static let scannerID = "big.downloads"

    public let id = Self.scannerID
    public let group = GroupID.bigThings
    public let title = "Downloads"
    /// One card per file. A 7 GB simulator runtime installer and the video beside it have
    /// nothing to do with each other, and one button over both is not a question.
    public var deckDealing: DeckDealing { .perItem }

    public init() {}

    // The sentences, by what the thing is. Named constants because the deck prints them as a
    // card's one line of explanation and a test compares them.

    /// The only one of the four that says the user can get it back. It says "usually"
    /// because it cannot know: a beta installer Apple has withdrawn is gone.
    public static let installerDetail = "An installer. You can usually download it again."
    public static let archiveDetail = "An archive."
    public static let folderDetail = "A folder."
    public static let fileDetail = "A file."

    /// Extensions that are almost always something fetched from a vendor.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "xip", "iso", "ipa"]
    /// Extensions that are a wrapper around something else. Deliberately not merged with the
    /// installers: an archive is as often a thing the user made as a thing they downloaded,
    /// so it gets the sentence that promises nothing.
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "7z", "rar",
                                                 "bz2", "xz"]

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        let root = context.homePath("Downloads")
        // Files as well as folders — a 7 GB `.dmg` is the commonest single thing in here —
        // so, unlike almost every other scanner, there is no `filter(\.isDirectory)`. What
        // is filtered is a symbolic link, whose size would be whatever it points at while
        // trashing it frees nothing. `ScanHelpers.children` has already dropped the
        // dot-names, so `.DS_Store` and the half-finished `.download` bundles stay out.
        let children = ScanHelpers.children(of: root, fileManager: context.fileManager)
            .filter { !ScanHelpers.isSymbolicLink($0.path, fileManager: context.fileManager) }
            .sorted { $0.name < $1.name }
        let sizes = await context.sizeMeasurer.sizes(of: children.map(\.path))

        return children.compactMap { child in
            let size = ScanHelpers.measured(sizes, child.path)
            guard size.bytes >= BigThings.minimumBytes else { return nil }
            return ScanHelpers.item(
                scannerID: id, group: group, path: child.path,
                // The file's own name, which is also the card's title, and which is the
                // whole of why this group needs no Trash rename: `Xcode_26.1_beta.xip`
                // already reads as itself in the Trash.
                name: child.name,
                detail: Self.detail(of: child),
                sizeBytes: size.bytes,
                lastUsed: Self.added(child.path) ?? child.modified,
                risk: .irreplaceable,
                // Never ticked. The rule this whole group exists under.
                startsUnticked: true)
        }
    }

    /// Which of the four sentences this entry gets.
    ///
    /// A folder is answered first and by kind rather than by name, because a folder called
    /// `Xcode.app` or `release.zip` is still a folder and the extension would lie about it.
    static func detail(of child: ScanHelpers.Child) -> String {
        guard !child.isDirectory else { return folderDetail }
        let extension_ = (child.name as NSString).pathExtension.lowercased()
        if installerExtensions.contains(extension_) { return installerDetail }
        if archiveExtensions.contains(extension_) { return archiveDetail }
        return fileDetail
    }

    /// When this landed in `~/Downloads`.
    ///
    /// `addedToDirectoryDateKey` is the timestamp Finder's own "Date Added" column shows,
    /// and it is the only one that answers the question the card asks. A `.dmg`'s
    /// modification date is whenever its author built it, which for `Xcode_16.2.xip` is a
    /// year before it reached this Mac — so a card reading "added 1 year ago" would be
    /// describing Apple's build server rather than the user's download.
    ///
    /// Read through `URL` rather than the injected `FileManager` because `FileManager` has
    /// no API for it at all. It is a `stat`, it touches nothing, and the caller falls back
    /// to the modification date `ScanHelpers.children` already has when it answers `nil`.
    static func added(_ path: String) -> Date? {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.addedToDirectoryDateKey])
        return values?.addedToDirectoryDate
    }
}

/// **The models on this machine that an app loads at run time**: LM Studio's 19 GB of
/// language models, the Hugging Face hub cache, and Ollama's store.
///
/// Three stores, one scanner, because they hold the same kind of thing and the user's
/// question about each of them is the same: *is this a model I still use?* Splitting them
/// per vendor would have put three scanners in the settings screen for one decision, and —
/// more to the point — would have let one of them be written without the rules the other
/// two follow.
///
/// `.irreplaceable` like every row in this group, and each store's detail says where it
/// comes back from. Those are real answers and still expensive ones: a 12 GB download over
/// whatever connection the user has.
///
/// **The Hugging Face rows are here because of an incident.** They used to be a single
/// `other.xdgCache` card headed `huggingface`, and pressing it broke the user's dictation
/// app for as long as it took to fetch 1.1 GB back. The whole story is on
/// `XDGCacheScanner.excludedChildren`; what it bought is this: one row per model, named
/// after the model rather than after the directory, so the card says
/// `org/whisper-large-v3-gguf` and the user can recognise the thing they depend
/// on before they answer.
public struct AIModelScanner: CleanupScanner {
    public static let scannerID = "big.aiModels"

    public let id = Self.scannerID
    public let group = GroupID.bigThings
    public let title = "AI models"
    /// One card per model. This is the group's clearest case: a user wants one 12 GB model
    /// gone and the two they are actually using kept.
    public var deckDealing: DeckDealing { .perItem }

    public init() {}

    /// The floor a row of this scanner has to clear, **lower than the rest of the group's**.
    ///
    /// `BigThings.minimumBytes` is 500 MB because a download in `~/Downloads` is something
    /// the user chose to keep, and a card about a 60 MB PDF teaches them to stop reading
    /// cards. A model is the other way round: it is something an *app* chose to keep, the
    /// user often does not know it is there at all, and the size of it says nothing about
    /// how much it matters. The model that broke the dictation app was 1.1 GB; the same app
    /// shipped with `whisper-base`, which is about 140 MB, and losing that would have cost
    /// exactly as much.
    ///
    /// 100 MB, which is over every tokenizer-and-config-only entry the Hugging Face hub
    /// accumulates — those are a few hundred kilobytes each, and there can be dozens — and
    /// under every set of weights any app actually loads.
    public static let minimumBytes: Int64 = 100_000_000

    // MARK: LM Studio

    /// Where LM Studio keeps them, relative to the home directory. The `models` subfolder
    /// and never `~/.lmstudio`, whose siblings are the app's own configuration.
    public static let relativeRoot = ".lmstudio/models"

    public static let detail = "Download it again in LM Studio."

    // MARK: Hugging Face

    /// The shared cache anything built on the `huggingface_hub` library downloads into:
    /// `transformers`, `diffusers`, `sentence-transformers`, and the desktop apps that
    /// embed them.
    ///
    /// The `hub` subfolder and never `~/.cache/huggingface`, whose siblings are the
    /// library's own state, and never `~/.cache`, which is every tool's cache at once.
    /// `PathGuard.forRun` makes this the root and both of those forbidden targets.
    public static let huggingFaceRelativeRoot = ".cache/huggingface/hub"

    /// How the hub spells a repository id as a directory: `models--<org>--<name>`.
    ///
    /// The prefix is the whole of what this scanner offers from that directory.
    /// `datasets--…` sits beside it and is left alone in this pass — a dataset is not a
    /// thing an app silently reloads at launch, and offering it would be a question written
    /// without having looked at one.
    public static let huggingFaceModelPrefix = "models--"

    /// What a Hugging Face row says about itself.
    ///
    /// Two clauses, and the second is the one the old `huggingface` card was missing. "An
    /// AI model an app downloaded" names the kind of thing; "(Hugging Face cache)" is where
    /// a user who goes looking will find it; and the last sentence is the cost, in the only
    /// terms that matter — some app on this Mac has to fetch it again before it works.
    public static let huggingFaceDetail =
        "An AI model an app downloaded (Hugging Face cache). "
        + "The app that uses it has to download it again."

    // MARK: Ollama

    /// Ollama's store, relative to the home directory.
    ///
    /// The `models` subfolder and **never** `~/.ollama`: that directory also holds
    /// `id_ed25519` and `id_ed25519.pub`, the keypair Ollama signs registry requests with.
    /// `PathGuard.forRun` admits this as an exact path with no root anywhere above it, for
    /// that reason and no other.
    public static let ollamaRelativeRoot = ".ollama/models"

    /// **One row for the whole store, not one per model**, and the reason is honesty.
    ///
    /// Ollama names models in `manifests/<registry>/<namespace>/<model>/<tag>` and keeps
    /// the weights in `blobs`, content-addressed and **shared between models**: two tags of
    /// one model, and often two different models, point at the same layers. A row per
    /// manifest could name a model, but the only size it could honestly claim is "somewhere
    /// between nothing and 4 GB, depending which of these you also delete" — and deleting
    /// one would leave the blobs behind, so the card would free nothing it promised.
    ///
    /// So the card is the store: one thing, one size that is exactly right, one sentence.
    /// A user who wants a single model gone has `ollama rm`, which understands the sharing.
    public static let ollamaName = "Ollama models"
    public static let ollamaDetail =
        "Every model Ollama downloaded. ollama pull gets them back."

    public func scan(_ context: ScanContext) async -> [CleanupItem] {
        // Every path in one list before anything is measured, so `sizes(of:)` keeps its cap
        // of four `du` processes across all three stores rather than per store.
        let found = Self.lmStudioModels(context)
            + Self.huggingFaceModels(context)
            + Self.ollamaStore(context)
        let sizes = await context.sizeMeasurer.sizes(of: found.map(\.path))

        return found.compactMap { entry in
            let size = ScanHelpers.measured(sizes, entry.path)
            guard size.bytes >= Self.minimumBytes else { return nil }
            return ScanHelpers.item(
                scannerID: id, group: group, path: entry.path,
                name: entry.name, detail: entry.detail,
                sizeBytes: size.bytes,
                // The folder's own date, which here really is the user's: it is when the
                // download finished.
                lastUsed: entry.modified,
                risk: .irreplaceable,
                startsUnticked: true)
        }
    }

    /// One thing this scanner found: where it is, what to call it, and what to say about it.
    ///
    /// A named type rather than three parallel arrays, because the three stores name their
    /// rows by three different rules and the sentence has to travel with the path it
    /// belongs to. Pairing them up again after the measurement is how a model ends up
    /// wearing another store's explanation.
    private struct Found {
        let path: String
        let name: String
        let detail: String
        let modified: Date?
    }

    /// `<publisher>/<model>` under `~/.lmstudio/models`, which is the unit LM Studio itself
    /// deals in — the publisher folder above it is a namespace holding several unrelated
    /// models, and the files below it are one model's shards.
    private static func lmStudioModels(_ context: ScanContext) -> [Found] {
        directories(in: context.homePath(relativeRoot), context)
            .flatMap { publisher in
                directories(in: publisher.path, context).map { model in
                    Found(
                        path: model.path,
                        // `<publisher>/<model>`, the name LM Studio shows and the name the
                        // user searched for. The model folder alone would be ambiguous —
                        // two publishers ship a `Llama-3.2-3B-Instruct-GGUF`.
                        name: "\(publisher.name)/\(model.name)",
                        detail: detail, modified: model.modified)
                }
            }
    }

    /// One row per `models--<org>--<name>` directory directly under the hub.
    ///
    /// Direct children only. A level down is `snapshots/<revision>`, `blobs` and `refs` —
    /// the pieces of one model, which is not a thing the user chose and not a thing they
    /// could decide about.
    private static func huggingFaceModels(_ context: ScanContext) -> [Found] {
        directories(in: context.homePath(huggingFaceRelativeRoot), context)
            .compactMap { entry in
                guard let name = huggingFaceName(ofDirectory: entry.name) else { return nil }
                return Found(
                    path: entry.path, name: name,
                    detail: huggingFaceDetail, modified: entry.modified)
            }
    }

    /// `models--org--whisper-large-v3-gguf` -> `org/whisper-large-v3-gguf`,
    /// and `nil` for anything that is not a model directory at all.
    ///
    /// The hub writes a repository id with its `/` replaced by `--`, so the transformation
    /// back is that substitution read in reverse. A repository with no organisation —
    /// `gpt2` — is `models--gpt2` and comes back as `gpt2`, which is correct: the name is
    /// the repository id, whatever shape it has.
    ///
    /// Empty components are dropped rather than joined. Nothing the hub writes produces
    /// one; a hand-made `models--org--` would otherwise be named "org/", which is a name
    /// that looks like a path and is not.
    static func huggingFaceName(ofDirectory directory: String) -> String? {
        guard directory.hasPrefix(huggingFaceModelPrefix) else { return nil }
        let parts = directory.dropFirst(huggingFaceModelPrefix.count)
            .components(separatedBy: "--")
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// `~/.ollama/models`, or nothing at all when Ollama has never run.
    ///
    /// A directory rather than a child of one, so the same three rules as everywhere else
    /// in this file are asked of the store itself: it has to exist, be a real directory,
    /// and not be a link somebody put there pointing at something bigger.
    private static func ollamaStore(_ context: ScanContext) -> [Found] {
        let path = context.homePath(ollamaRelativeRoot)
        var isDirectory: ObjCBool = false
        guard context.fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !ScanHelpers.isSymbolicLink(path, fileManager: context.fileManager)
        else { return [] }
        let attributes = try? context.fileManager.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date
        return [Found(path: path, name: ollamaName, detail: ollamaDetail, modified: modified)]
    }

    /// Real subdirectories, in a fixed order, links excluded.
    ///
    /// Shared by every level of every store because they all need the same three rules, and
    /// a model directory reached through a link at any level would be sized as its target
    /// while trashing the link frees nothing.
    private static func directories(
        in path: String, _ context: ScanContext
    ) -> [ScanHelpers.Child] {
        ScanHelpers.children(of: path, fileManager: context.fileManager)
            .filter(\.isDirectory)
            .filter { !ScanHelpers.isSymbolicLink($0.path, fileManager: context.fileManager) }
            .sorted { $0.name < $1.name }
    }
}
