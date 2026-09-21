import Testing
import Foundation
@testable import CleanerCore

private let now = Date(timeIntervalSince1970: 1_786_000_000)

private func context(temp: TempDir, sizes: [String: Int64] = [:],
                     sizeMeasurer: (any SizeMeasuring)? = nil,
                     settings: Settings? = nil) -> ScanContext {
    ScanContext(
        settings: settings ?? .makeDefault(home: temp.path), protection: .empty, projects: [],
        devices: .empty, home: temp.path, androidSDKPath: temp.path + "/sdk",
        sizeMeasurer: sizeMeasurer ?? FixedSizeMeasurer(sizes),
        runner: FakeProcessRunner(responses: [:]),
        fileManager: .default, now: now)
}

/// Big enough to clear `BigThings.minimumBytes`, so a fixture only has to say "large".
private let large: Int64 = 4_000_000_000

// MARK: - Downloads

@Test func downloadsOffersDirectChildrenOverTheFloorAndNothingElse() async {
    let temp = TempDir()
    let installer = temp.makeFile("Downloads/Xcode_26.1_beta.xip")
    let folder = temp.makeDirectory("Downloads/conference recordings")
    let small = temp.makeFile("Downloads/invoice.pdf")
    let nested = temp.makeFile("Downloads/conference recordings/day-one.mov")

    let items = await DownloadsScanner().scan(context(temp: temp, sizes: [
        installer: 7_000_000_000, folder: 5_000_000_000,
        small: 400_000_000, nested: 5_000_000_000,
    ]))

    // Sorted by name, so the deck deals the same cards in the same order every scan.
    #expect(items.map(\.name) == ["Xcode_26.1_beta.xip", "conference recordings"])
    #expect(items.map(\.method) == [.removePath(installer), .removePath(folder)])
    #expect(items.contains { $0.method == .removePath(small) } == false)
    // Direct children only: a folder is one thing the user recognises, and picking pieces
    // out of it is not a question this window can ask.
    #expect(items.contains { $0.method == .removePath(nested) } == false)
    // Never the folder itself, whatever it holds.
    #expect(items.contains { $0.method == .removePath(temp.path + "/Downloads") } == false)
    #expect(BigThings.minimumBytes == 500_000_000)
}

/// Every big thing carries the three properties the whole group is defined by.
@Test func everyDownloadsRowIsIrreplaceableUntickedAndInTheBigThingsGroup() async throws {
    let temp = TempDir()
    let installer = temp.makeFile("Downloads/Xcode_26.1_beta.xip")

    let items = await DownloadsScanner().scan(context(
        temp: temp, sizes: [installer: 7_000_000_000]))

    let item = try #require(items.first)
    #expect(item.group == .bigThings)
    #expect(item.risk == .irreplaceable)
    #expect(item.startsUnticked)
    #expect(item.isDeletable)
    // Deletable and never ticked. Those are different facts and both are needed: the deck
    // puts it on a card the user has to press, and no default clean may include it.
    #expect(!item.selectedByDefault)
    #expect(item.id == "big.downloads|\(installer)")
}

/// The sentence is chosen by what the thing is, and only one of the four promises the user
/// can get it back. A folder is answered by kind rather than by name, so `release.zip` as a
/// directory is still "A folder."
@Test func eachDownloadSaysWhatKindOfThingItIs() async {
    let temp = TempDir()
    let paths = [
        "Downloads/Xcode_26.1_beta.xip", "Downloads/Docker.dmg",
        "Downloads/backup.zip", "Downloads/logs.tar.gz",
        "Downloads/keynote.mov", "Downloads/no-extension",
    ].map { temp.makeFile($0) }
    let folder = temp.makeDirectory("Downloads/release.zip")
    let sizes = Dictionary(uniqueKeysWithValues: (paths + [folder]).map { ($0, large) })

    var details: [String: String] = [:]
    for item in await DownloadsScanner().scan(context(temp: temp, sizes: sizes)) {
        details[item.name] = item.detail ?? "<none>"
    }

    #expect(details == [
        "Xcode_26.1_beta.xip": DownloadsScanner.installerDetail,
        "Docker.dmg": DownloadsScanner.installerDetail,
        "backup.zip": DownloadsScanner.archiveDetail,
        "logs.tar.gz": DownloadsScanner.archiveDetail,
        "keynote.mov": DownloadsScanner.fileDetail,
        "no-extension": DownloadsScanner.fileDetail,
        // A directory, whatever it is called.
        "release.zip": DownloadsScanner.folderDetail,
    ])
    #expect(DownloadsScanner.installerDetail
            == "An installer. You can usually download it again.")
    #expect(DownloadsScanner.archiveDetail == "An archive.")
    #expect(DownloadsScanner.folderDetail == "A folder.")
    #expect(DownloadsScanner.fileDetail == "A file.")
}

/// **A refused `~/Downloads` permission must read as "nothing found".**
///
/// The folder is protected by TCC: the first read prompts, and a refusal makes
/// `contentsOfDirectory` throw. `ScanHelpers.children` answers an empty list for that, and a
/// missing directory is the same shape — one failed syscall, no error anywhere, and every
/// other scanner in the run untouched.
@Test func aDownloadsFolderThatCannotBeReadLooksLikeNothingFoundAndStopsNothing() async {
    let temp = TempDir()
    // No `Downloads` at all, which is the same thing the refusal produces: an unreadable
    // directory rather than an empty one.
    #expect(await DownloadsScanner().scan(context(temp: temp)).isEmpty)

    // And it does not stop the rest of a scan. The engine runs every scanner and the
    // downloads one simply contributes no rows.
    let cache = temp.makeDirectory(".cache/uv")
    let result = await ScanEngine(scanners: [DownloadsScanner(), XDGCacheScanner()])
        .scan(context: context(temp: temp, sizes: [cache: 1_100_000_000]))
    #expect(result.items.map(\.method) == [.removePath(cache)])
    #expect(result.skippedScannerIDs.isEmpty)
}

/// A symbolic link is never offered: its size would be whatever it points at while trashing
/// it moves the link and frees none of those bytes.
@Test func aSymbolicLinkInDownloadsIsNeverOffered() async {
    let temp = TempDir()
    let real = temp.makeFile("Downloads/Docker.dmg")
    let elsewhere = temp.makeDirectory("Movies/archive")
    let link = temp.makeSymlink("Downloads/shortcut", to: elsewhere)

    let items = await DownloadsScanner().scan(context(temp: temp, sizes: [
        real: large, link: 30_000_000_000, elsewhere: 30_000_000_000,
    ]))

    #expect(items.map(\.method) == [.removePath(real)])
    #expect(items.contains { $0.method == .removePath(link) } == false)
}

/// The date the card prints is the date the file **arrived**, which is the only one that
/// answers the question. A `.dmg`'s modification date is whenever its author built it — for
/// `Xcode_16.2.xip` a year before it reached this Mac — so "added 1 year ago" from that would
/// be describing Apple's build server.
@Test func aDownloadsRowIsDatedByWhenItArrivedRatherThanWhenItWasBuilt() async throws {
    let temp = TempDir()
    let built = Date(timeIntervalSince1970: 1_600_000_000)
    let installer = temp.makeFile("Downloads/Docker.dmg", modified: built)

    let items = await DownloadsScanner().scan(context(temp: temp, sizes: [installer: large]))
    let item = try #require(items.first)

    // The fixture was created just now, so its added-date is now and its modification date
    // is 2020. Whichever the filesystem supports, the row must not be dated 2020.
    let added = try #require(DownloadsScanner.added(installer))
    #expect(item.lastUsed == added)
    #expect(item.lastUsed != built)
    // And the fallback is the modification date, for a path with no added-date at all.
    #expect(DownloadsScanner.added("/nonexistent/thing") == nil)
}

// MARK: - AI models

@Test func aiModelsOfferOnePublisherSlashModelDirectoryPerRow() async {
    let temp = TempDir()
    let big = temp.makeDirectory(".lmstudio/models/lmstudio-community/Qwen3-30B-GGUF")
    let other = temp.makeDirectory(".lmstudio/models/mlx-community/Llama-3.2-3B")
    let small = temp.makeDirectory(".lmstudio/models/tiny/nano-model")
    let shard = temp.makeDirectory(
        ".lmstudio/models/lmstudio-community/Qwen3-30B-GGUF/shards")

    let items = await AIModelScanner().scan(context(temp: temp, sizes: [
        big: 18_000_000_000, other: 2_000_000_000, small: 40_000_000,
        shard: 18_000_000_000,
    ]))

    #expect(items.map(\.name)
            == ["lmstudio-community/Qwen3-30B-GGUF", "mlx-community/Llama-3.2-3B"])
    #expect(items.map(\.method) == [.removePath(big), .removePath(other)])
    #expect(items.allSatisfy { $0.group == .bigThings })
    #expect(items.allSatisfy { $0.risk == .irreplaceable })
    #expect(items.allSatisfy { $0.startsUnticked })
    #expect(items.allSatisfy { $0.detail == "Download it again in LM Studio." })
    #expect(items.contains { $0.method == .removePath(small) } == false)
    // One level too deep: a model's shards are not a thing the user chose to download.
    #expect(items.contains { $0.method == .removePath(shard) } == false)
}

/// Neither the publisher folder nor the store itself is ever a row. The publisher folder is a
/// namespace holding unrelated models, and the store is every model at once.
@Test func aiModelsNeverOfferThePublisherFolderOrTheStoreItself() async {
    let temp = TempDir()
    let model = temp.makeDirectory(".lmstudio/models/lmstudio-community/Qwen3-30B-GGUF")
    let publisher = temp.path + "/.lmstudio/models/lmstudio-community"
    let store = temp.path + "/.lmstudio/models"

    let items = await AIModelScanner().scan(context(temp: temp, sizes: [
        model: 18_000_000_000, publisher: 19_000_000_000, store: 19_000_000_000,
    ]))

    #expect(items.map(\.method) == [.removePath(model)])
    #expect(items.contains { $0.method == .removePath(publisher) } == false)
    #expect(items.contains { $0.method == .removePath(store) } == false)
    #expect(items.contains { $0.method == .removePath(temp.path + "/.lmstudio") } == false)
    #expect(AIModelScanner.relativeRoot == ".lmstudio/models")
}

@Test func aiModelsAreSilentWhenNoModelStoreIsInstalled() async {
    #expect(await AIModelScanner().scan(context(temp: TempDir())).isEmpty)
}

/// **The floor for a model is a fifth of the group's**, and the difference is deliberate.
///
/// `BigThings.minimumBytes` is 500 MB because a file in `~/Downloads` is something the user
/// chose to keep, and a card about a 60 MB PDF teaches them to stop reading cards. A model is
/// the other way round: an *app* chose to keep it, the user often does not know it is there,
/// and the size says nothing about how much it matters. The model that broke the dictation
/// app was 1.1 GB; the same app ships with `whisper-base`, about 140 MB, whose loss would
/// have cost exactly the same.
@Test func aModelIsWorthACardAtAFifthOfTheSizeADownloadHasToReach() async {
    let temp = TempDir()
    let small = temp.makeDirectory(".cache/huggingface/hub/models--openai--whisper-base")
    let tiny = temp.makeDirectory(".cache/huggingface/hub/models--bert--config-only")

    let items = await AIModelScanner().scan(context(temp: temp, sizes: [
        small: 140_000_000, tiny: 400_000,
    ]))

    #expect(items.map(\.name) == ["openai/whisper-base"])
    #expect(items.map(\.sizeBytes) == [140_000_000])
    // Over this scanner's floor and well under the group's, which is what makes it a real
    // difference rather than two spellings of one number.
    #expect(AIModelScanner.minimumBytes == 100_000_000)
    #expect(BigThings.minimumBytes == 500_000_000)
    // The hub's tokenizer-and-config-only entries — a few hundred kilobytes, and there can
    // be dozens — stay out.
    #expect(items.contains { $0.method == .removePath(tiny) } == false)
}

// MARK: - the incident: Hugging Face models are their own rows now

/// **One row per model, named after the model.**
///
/// This is what the `huggingface` card should have been. That card named a *directory*, and
/// nothing on it connected the word to the app the user relied on; when they pressed Clean
/// up, `~/.cache/huggingface/hub/models--ml-labs--whisper-large-v3-gguf` went with the
/// rest and their dictation stopped working until it had fetched 1.1 GB back. A card headed
/// `ml-labs/whisper-large-v3-gguf` is a card they could have recognised — which is the
/// whole of the fix, and the reason the name is undone from the hub's spelling rather than
/// printed as the folder.
@Test func huggingFaceModelsAreOneRowPerModelNamedAsTheRepositoryIs() async throws {
    let temp = TempDir()
    let whisper = temp.makeDirectory(
        ".cache/huggingface/hub/models--ml-labs--whisper-large-v3-gguf")
    let gpt2 = temp.makeDirectory(".cache/huggingface/hub/models--gpt2")

    let items = await AIModelScanner().scan(context(temp: temp, sizes: [
        whisper: 1_250_000_000, gpt2: 550_000_000,
    ]))

    // Sorted by the directory's name, so the deck deals the same cards in the same order on
    // every scan — `models--gpt2` before `models--ml-labs--…`.
    #expect(items.map(\.name) == ["gpt2", "ml-labs/whisper-large-v3-gguf"])
    #expect(items.map(\.method) == [.removePath(gpt2), .removePath(whisper)])
    // The same treatment as an LM Studio model, and every part of it matters: the group
    // sorts it behind the interstitial, `.irreplaceable` makes the executor always trash it
    // whatever `moveToTrash` says, and `startsUnticked` keeps it out of every default clean.
    #expect(items.allSatisfy { $0.group == .bigThings })
    #expect(items.allSatisfy { $0.risk == .irreplaceable })
    #expect(items.allSatisfy { $0.startsUnticked })
    #expect(items.allSatisfy { !$0.selectedByDefault })
    #expect(items.allSatisfy { $0.goesToTheTrash(moveToTrash: false) })
    // The sentence names the kind of thing, where to find it, and the cost — in the only
    // terms that matter, which the old card's "a script next asks for them" did not.
    #expect(items.allSatisfy { $0.detail == AIModelScanner.huggingFaceDetail })
    #expect(AIModelScanner.huggingFaceDetail
            == "An AI model an app downloaded (Hugging Face cache). "
            + "The app that uses it has to download it again.")
}

/// Never the cache around them, and nothing in it that is not a model.
///
/// `~/.cache/huggingface` as a whole is what the incident was; `hub` is every model at once;
/// and a level below a model directory is `snapshots`, `blobs` and `refs`, which are pieces
/// of one model rather than anything the user chose. `datasets--…` sits beside the models
/// and is left alone in this pass — a dataset is not a thing an app silently reloads at
/// launch, and offering it would be a question written without having looked at one.
@Test func huggingFaceOffersNeitherTheCacheTheHubNorAnythingThatIsNotAModel() async {
    let temp = TempDir()
    let model = temp.makeDirectory(".cache/huggingface/hub/models--openai--whisper-large-v3")
    let snapshots = temp.makeDirectory(
        ".cache/huggingface/hub/models--openai--whisper-large-v3/snapshots")
    let dataset = temp.makeDirectory(".cache/huggingface/hub/datasets--squad")
    let hub = temp.path + "/.cache/huggingface/hub"
    let cache = temp.path + "/.cache/huggingface"

    let items = await AIModelScanner().scan(context(temp: temp, sizes: [
        model: 3_000_000_000, snapshots: 3_000_000_000,
        dataset: 9_000_000_000, hub: 12_000_000_000, cache: 12_000_000_000,
    ]))

    #expect(items.map(\.method) == [.removePath(model)])
    for path in [snapshots, dataset, hub, cache, temp.path + "/.cache"] {
        #expect(items.contains { $0.method == .removePath(path) } == false, "\(path)")
    }
    #expect(AIModelScanner.huggingFaceRelativeRoot == ".cache/huggingface/hub")
    #expect(AIModelScanner.huggingFaceModelPrefix == "models--")
}

/// The hub writes a repository id with its slashes replaced by `--`, so the name is that
/// substitution read backwards.
@Test func aHuggingFaceDirectoryNameUndoesTheHubsSpelling() {
    #expect(AIModelScanner.huggingFaceName(
        ofDirectory: "models--ml-labs--whisper-large-v3-gguf")
        == "ml-labs/whisper-large-v3-gguf")
    // A repository with no organisation. The name is the repository id whatever shape it
    // has, so `gpt2` comes back as itself rather than being refused for having no slash.
    #expect(AIModelScanner.huggingFaceName(ofDirectory: "models--gpt2") == "gpt2")
    // Hyphens inside a component survive: the separator is two of them.
    #expect(AIModelScanner.huggingFaceName(ofDirectory: "models--mlx-community--Llama-3.2-3B")
            == "mlx-community/Llama-3.2-3B")
    // Not a model directory at all.
    #expect(AIModelScanner.huggingFaceName(ofDirectory: "datasets--squad") == nil)
    #expect(AIModelScanner.huggingFaceName(ofDirectory: "version.txt") == nil)
    #expect(AIModelScanner.huggingFaceName(ofDirectory: "models--") == nil)
    // Empty components are dropped rather than joined, so a hand-made name cannot produce
    // something that looks like a path and is not.
    #expect(AIModelScanner.huggingFaceName(ofDirectory: "models--org--") == "org")
}

// MARK: - Ollama

/// **One row for the whole store, not one per model**, and the reason is honesty about
/// shared blobs.
///
/// Ollama names models under `manifests/<registry>/<namespace>/<model>/<tag>` and keeps the
/// weights in `blobs`, content-addressed and shared: two tags of one model, and often two
/// different models, point at the same layers. A row per manifest could name a model, but
/// the only size it could honestly claim is "somewhere between nothing and 4 GB, depending
/// which of these you also delete" — and removing one would leave the blobs behind, so the
/// card would free nothing it promised.
@Test func ollamaIsOneRowForTheWholeStoreWithASizeThatIsExactlyRight() async throws {
    let temp = TempDir()
    let store = temp.makeDirectory(".ollama/models")
    temp.makeDirectory(".ollama/models/manifests/registry.ollama.ai/library/llama3/latest")
    temp.makeDirectory(".ollama/models/blobs")
    // The keypair Ollama signs registry requests with, beside the store. Nothing may reach
    // it — see `theRunGuardAdmitsTheOllamaStoreWithoutARootOverItsKeys`.
    temp.makeFile(".ollama/id_ed25519")

    let items = await AIModelScanner().scan(context(temp: temp, sizes: [
        store: 4_700_000_000,
    ]))
    let row = try #require(items.first)

    #expect(items.count == 1)
    #expect(row.name == "Ollama models")
    #expect(row.method == .removePath(store))
    #expect(row.detail == "Every model Ollama downloaded. ollama pull gets them back.")
    #expect(row.group == .bigThings)
    #expect(row.risk == .irreplaceable)
    #expect(row.startsUnticked)
    // Never `~/.ollama` itself, and never a manifest or a blob.
    for path in [temp.path + "/.ollama",
                 store + "/manifests/registry.ollama.ai/library/llama3/latest",
                 store + "/blobs"] {
        #expect(items.contains { $0.method == .removePath(path) } == false, "\(path)")
    }
    #expect(AIModelScanner.ollamaRelativeRoot == ".ollama/models")
}

/// Ollama installed with nothing pulled — which is the state of the machine this was written
/// on. An empty store is under the floor, so there is no card: a question worth nothing.
@Test func ollamaWithNoModelsPulledIsNotOffered() async {
    let temp = TempDir()
    let store = temp.makeDirectory(".ollama/models")
    #expect(await AIModelScanner().scan(context(temp: temp, sizes: [store: 8_000])).isEmpty)
    // And a store `du` could not size at all, which arrives as zero and is below any floor.
    #expect(await AIModelScanner().scan(context(temp: temp)).isEmpty)
}

/// A link is never offered, at any level of any of the three stores: its size would be
/// whatever it points at while trashing it moves the link and frees none of those bytes.
@Test func noModelStoreOffersASymbolicLink() async {
    let temp = TempDir()
    let elsewhere = temp.makeDirectory("Volumes/external/models")
    let hubLink = temp.makeSymlink(
        ".cache/huggingface/hub/models--openai--whisper-large-v3", to: elsewhere)
    let ollamaLink = temp.makeSymlink(".ollama/models", to: elsewhere)
    let lmLink = temp.makeSymlink(".lmstudio/models/publisher", to: elsewhere)

    let items = await AIModelScanner().scan(context(temp: temp, sizes: [
        hubLink: 40_000_000_000, ollamaLink: 40_000_000_000, lmLink: 40_000_000_000,
        elsewhere: 40_000_000_000,
    ]))

    #expect(items.isEmpty)
}

/// All three stores measured in **one** batched call, so `sizes(of:)` keeps its cap of four
/// `du` processes across the scanner rather than per store.
@Test func theModelScannerMeasuresEveryStoreInOneBatchedCall() async throws {
    let temp = TempDir()
    let lm = temp.makeDirectory(".lmstudio/models/lmstudio-community/Qwen3-30B-GGUF")
    let hub = temp.makeDirectory(".cache/huggingface/hub/models--openai--whisper-large-v3")
    let ollama = temp.makeDirectory(".ollama/models")

    let measurer = CallCountingSizeMeasurer([lm: 18_000_000_000])
    _ = await AIModelScanner().scan(context(temp: temp, sizeMeasurer: measurer))

    #expect(await measurer.callCount == 1)
    #expect(try #require(await measurer.batches.first).sorted()
            == [lm, hub, ollama].sorted())
}

// MARK: - nothing ticks a big thing, anywhere

/// **The rule the whole group rests on**, checked at every place a list of rows is derived.
///
/// Each of these is a separate route to a deletion and each one used to read
/// `isDeletable`-shaped questions at some point in this package's history: the scan's own
/// default tick, and the service's `cleanDefault` (which is what `devcleaner clean` runs).
/// The app's own reading of the same rule — the amount the menu bar shows — is pinned in
/// `DevCleanerUITests`, because the deck lives in the other module.
@Test func noBigThingIsEverTickedByDefaultOrByTheDefaultClean() async throws {
    let temp = TempDir()
    let installer = temp.makeFile("Downloads/Xcode_26.1_beta.xip")
    let model = temp.makeDirectory(".lmstudio/models/lmstudio-community/Qwen3-30B-GGUF")
    let cache = temp.makeDirectory(".cache/uv")

    let result = await ScanEngine(
        scanners: [DownloadsScanner(), AIModelScanner(), XDGCacheScanner()]
    ).scan(context: context(temp: temp, sizes: [
        installer: 7_000_000_000, model: 18_000_000_000, cache: 1_100_000_000,
    ]))

    #expect(result.items.count == 3)
    // The ordinary cache row is ticked; neither big thing is.
    #expect(result.defaultSelection.map(\.method) == [.removePath(cache)])
    #expect(result.reclaimableBytes == 1_100_000_000)
    // They are still accounted for, on the line that says what ticking them would add.
    #expect(result.untickedDeletableBytes == 25_000_000_000)
    #expect(result.reclaimableBytes(in: .bigThings) == 0)
    #expect(result.items(in: .bigThings).count == 2)
}

/// `cleanDefault` is what `devcleaner clean` runs after the user types the confirmation
/// word. It removes
/// `ScanResult.defaultSelection`, so a big thing can only ever be removed by being handed
/// over deliberately.
@Test func theDefaultCleanRemovesNoBigThing() async throws {
    let temp = TempDir()
    let installer = temp.makeFile("Downloads/Xcode_26.1_beta.xip")
    let cache = temp.makeDirectory(".cache/uv")
    var settings = Settings.makeDefault(home: temp.path)
    settings.projectRoots = []
    let store = SettingsStore(directory: temp.url, home: temp.path)
    try store.save(settings)
    let service = CleanerService(
        settingsStore: store,
        runLog: RunLog(directory: temp.url.appendingPathComponent("runs")),
        runner: FakeProcessRunner(responses: [:]), remover: FakeFileRemover(),
        sizeMeasurer: FixedSizeMeasurer([installer: 7_000_000_000, cache: 1_100_000_000]),
        fileManager: .default, home: temp.path,
        androidSDKPath: temp.path + "/sdk", clock: { now })

    let result = await ScanEngine(scanners: [DownloadsScanner(), XDGCacheScanner()])
        .scan(context: context(temp: temp, sizes: [
            installer: 7_000_000_000, cache: 1_100_000_000,
        ]))
    let record = await service.cleanDefault(result, now: now) { _ in }

    // `itemID` rather than `target`: the executor records the path the guard approved,
    // which `realpath` has resolved through `/private/var`, while the identifier is the
    // row's own and is exact.
    #expect(record.entries.map(\.itemID) == ["other.xdgCache|\(cache)"])
    #expect(record.entries.contains { $0.itemID.hasPrefix("big.") } == false)
    #expect(record.trashedCount == 1)
}
