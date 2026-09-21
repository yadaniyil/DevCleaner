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

// MARK: - browser and app caches

@Test func browserCachesAreOfferedFromAnAllowlistAndNothingElseIs() async {
    let temp = TempDir()
    let brave = temp.makeDirectory("Library/Caches/BraveSoftware")
    let chrome = temp.makeDirectory("Library/Caches/Google/Chrome")
    let spotify = temp.makeDirectory("Library/Caches/com.spotify.client")
    // Neighbours that must never be offered: Mail, Photos, and Safari, which is protected
    // by TCC so a row for it could only ever be an error message.
    temp.makeDirectory("Library/Caches/com.apple.mail")
    temp.makeDirectory("Library/Caches/com.apple.Safari")
    temp.makeDirectory("Library/Caches/com.apple.photolibraryd")

    let items = await AppCacheScanner().scan(context(temp: temp, sizes: [
        brave: 3_100_000_000, chrome: 1_400_000_000, spotify: 800_000_000,
    ]))

    #expect(items.map(\.name)
            == ["Brave browsing cache", "Chrome browsing cache", "Spotify cache"])
    #expect(items.map(\.method)
            == [.removePath(brave), .removePath(chrome), .removePath(spotify)])
    #expect(items.allSatisfy { $0.isDeletable })
    #expect(items.allSatisfy { $0.group == .otherCaches })
    #expect(items.reduce(0) { $0 + $1.sizeBytes } == 5_300_000_000)
}

/// `~/Library/Caches/Google` is **never** the row, and this is why. It is the parent of
/// `AndroidStudio<version>`, which `other.libraryCaches` offers as a row of its own — so a
/// row for the parent would contain another scanner's row. `ScanEngine` de-duplicates on the
/// deletion target and these are two different paths, so both would survive and the headline
/// would count the Android Studio cache twice.
@Test func theGoogleCacheParentIsNeverOfferedBecauseAndroidStudioLivesInIt() async {
    let temp = TempDir()
    let chrome = temp.makeDirectory("Library/Caches/Google/Chrome")
    let studio = temp.makeDirectory("Library/Caches/Google/AndroidStudio2025.2")
    let parent = temp.path + "/Library/Caches/Google"

    let app = await AppCacheScanner().scan(context(
        temp: temp, sizes: [chrome: 1_400_000_000, studio: 3_000_000_000]))
    let library = await LibraryCachesScanner().scan(context(
        temp: temp, sizes: [chrome: 1_400_000_000, studio: 3_000_000_000]))

    #expect(app.map(\.method) == [.removePath(chrome)])
    #expect(library.map(\.method) == [.removePath(studio)])
    #expect((app + library).contains { $0.method == .removePath(parent) } == false)
    // The two rows together are the two folders and nothing more, counted once each.
    #expect(ScanResult.totalBytes(of: app + library) == 4_400_000_000)
    // And they land on **different sides** of the tick rule, which is the point of
    // `other.appCaches` becoming `.mentionOnly`: the Android Studio cache is ticked and the
    // Chrome one is only ever reported. Totalled together they would still be 4.4 GB, and
    // a headline that said so would promise 1.4 GB no button in the app can reach.
    let result = ScanResult(items: app + library, generatedAt: now, availableBytes: 0,
                            skippedScannerIDs: [])
    #expect(result.reclaimableBytes == 3_000_000_000)
    #expect(result.untickedDeletableBytes == 1_400_000_000)
}

/// Two folders per Chromium browser, and they are not the same thing: the profile's cache
/// and the app's own `NSURLCache`. Both appear on a real dev machine, and they are named
/// apart — two rows reading "Brave" are two rows the user cannot choose between.
@Test func theTwoBraveCacheFoldersAreOfferedUnderDifferentNames() async {
    let temp = TempDir()
    let profile = temp.makeDirectory("Library/Caches/BraveSoftware")
    let app = temp.makeDirectory("Library/Caches/com.brave.Browser")

    let items = await AppCacheScanner().scan(context(
        temp: temp, sizes: [profile: 3_100_000_000, app: 800_000_000]))

    #expect(items.map(\.name) == ["Brave browsing cache", "Brave app cache"])
    #expect(Set(items.map(\.name)).count == items.count)
}

/// A browser cache is `.safe` and the two downloads beside it are not, and the difference is
/// what the risk level is for: nothing waits on a browsing cache — the user notices a slower
/// page — while a Firefox update and a Spotify library are deliberate fetches of whole
/// things.
@Test func onlyTheDownloadRowsOfTheAppCacheScannerAreElevated() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Caches/BraveSoftware")
    temp.makeDirectory("Library/Caches/Google/Chrome")
    temp.makeDirectory("Library/Caches/Firefox")
    temp.makeDirectory("Library/Caches/Mozilla")
    temp.makeDirectory("Library/Caches/com.spotify.client")

    let items = await AppCacheScanner().scan(context(temp: temp))

    #expect(items.count == 5)
    #expect(items.filter { $0.risk == .elevated }.map(\.name).sorted()
            == ["Firefox update downloads", "Spotify cache"])
}

@Test func everyAppCacheRowSaysHowItComesBack() async {
    let temp = TempDir()
    for folder in ["BraveSoftware", "com.brave.Browser", "Google/Chrome",
                   "Google/Chrome-headless", "com.google.Chrome", "Firefox", "Mozilla",
                   "com.spotify.client"] {
        temp.makeDirectory("Library/Caches/\(folder)")
    }

    var details: [String: String] = [:]
    for item in await AppCacheScanner().scan(context(temp: temp)) {
        details[item.name] = item.detail ?? "<none>"
    }

    #expect(details == [
        "Brave browsing cache": "the browser rebuilds it as you browse",
        "Brave app cache": "the browser rebuilds it as you browse",
        "Chrome browsing cache": "the browser rebuilds it as you browse",
        "Chrome headless cache": "the browser rebuilds it as you browse",
        "Chrome app cache": "the browser rebuilds it as you browse",
        "Firefox cache": "the browser rebuilds it as you browse",
        "Firefox update downloads": "re-downloaded the next time Firefox updates",
        "Spotify cache": "re-downloaded as you play music again",
    ])
}

@Test func aFileNamedLikeABrowserCacheIsNotOffered() async {
    let temp = TempDir()
    temp.makeFile("Library/Caches/BraveSoftware")
    #expect(await AppCacheScanner().scan(context(temp: temp)).isEmpty)
}

// MARK: - the developer tool caches the allowlist grew by

/// The five names added to `other.libraryCaches`, which is the scanner whose whole point is
/// that adding a name is a code change somebody reviews.
@Test func theDeveloperToolCacheAllowlistOffersTheFiveNewNames() async {
    let temp = TempDir()
    let playwright = temp.makeDirectory("Library/Caches/ms-playwright")
    let pip = temp.makeDirectory("Library/Caches/pip")
    let typescript = temp.makeDirectory("Library/Caches/typescript")
    let nodeGyp = temp.makeDirectory("Library/Caches/node-gyp")
    let goBuild = temp.makeDirectory("Library/Caches/go-build")

    let items = await LibraryCachesScanner().scan(context(temp: temp, sizes: [
        playwright: 500_000_000, pip: 300_000_000, typescript: 60_000_000,
        nodeGyp: 120_000_000, goBuild: 900_000_000,
    ]))

    #expect(items.map(\.name) == [
        "Playwright browsers", "pip downloads", "TypeScript type downloads",
        "Node build headers", "Go build cache",
    ])
    #expect(items.map(\.method) == [
        .removePath(playwright), .removePath(pip), .removePath(typescript),
        .removePath(nodeGyp), .removePath(goBuild),
    ])
    // `go build` remakes its own cache with no network involved; the other four are fetches.
    #expect(items.filter { $0.risk == .safe }.map(\.name) == ["Go build cache"])
    #expect(items.map { $0.detail ?? "<none>" } == [
        "re-downloaded on the next playwright install",
        "re-downloaded on the next pip install",
        "re-downloaded the next time an editor needs them",
        "re-downloaded the next time a native module is built",
        "rebuilt on the next go build",
    ])
}

// MARK: - ~/.cache

@Test func theXDGCacheOffersOneRowPerDirectChildOverTheFloor() async {
    let temp = TempDir()
    let nimbus = temp.makeDirectory(".cache/nimbus")
    let uv = temp.makeDirectory(".cache/uv")
    let pip = temp.makeDirectory(".cache/pip")
    let small = temp.makeDirectory(".cache/tiny-tool")

    let items = await XDGCacheScanner().scan(context(temp: temp, sizes: [
        nimbus: 2_400_000_000, uv: 1_100_000_000, pip: 1_200_000_000,
        small: 4_000_000,
    ]))

    // Sorted by name, so the deck deals the same cards in the same order on every scan.
    #expect(items.map(\.name) == ["nimbus", "pip", "uv"])
    #expect(items.map(\.method)
            == [.removePath(nimbus), .removePath(pip), .removePath(uv)])
    #expect(items.allSatisfy { $0.group == .otherCaches })
    #expect(items.allSatisfy { $0.risk == .elevated })
    #expect(items.allSatisfy { $0.isDeletable })
    #expect(items.contains { $0.method == .removePath(small) } == false)
}

// MARK: - the incident: ~/.cache/huggingface

/// **`~/.cache/huggingface` is never a row again, whatever it holds and however big it is.**
///
/// The card that used to exist read "huggingface · 1.25 GB" over "models are downloaded
/// again when a script next asks for them". A user pressed Clean up on it, and minutes later
/// their dictation app logged `Failed to load model: Model not found`, because
/// its working Whisper model lived at
/// `~/.cache/huggingface/hub/models--ml-labs--whisper-large-v3-gguf`. The sentence was
/// true about a *script*; the thing in the folder was an installed model an app loads at
/// launch.
///
/// The models are offered now — by `big.aiModels`, one per model, named after the model, and
/// that is what makes them recognisable. What this test pins is the other half: no route
/// through this scanner can reach the directory that contained them.
@Test func theXDGCacheNeverOffersHuggingFaceOrAnyOtherModelStore() async {
    let temp = TempDir()
    let uv = temp.makeDirectory(".cache/uv")
    let stores = ["huggingface", "torch", "whisper", "lm-studio", "ollama",
                  "modelscope", "nltk_data"].map { temp.makeDirectory(".cache/\($0)") }
    // Deliberately the biggest things in the directory, so nothing about the floor or the
    // ordering is what is keeping them out.
    var sizes = Dictionary(uniqueKeysWithValues: stores.map { ($0, Int64(40_000_000_000)) })
    sizes[uv] = 1_100_000_000

    let items = await XDGCacheScanner().scan(context(temp: temp, sizes: sizes))

    #expect(items.map(\.method) == [.removePath(uv)])
    for store in stores {
        #expect(items.contains { $0.method == .removePath(store) } == false, "\(store)")
    }
    // The list is the scanner's own published set, and `PathGuard.forRun` reads the same one
    // to forbid each of these as a target — see `everyExcludedModelStoreIsAForbiddenTarget`.
    #expect(XDGCacheScanner.excludedChildren == [
        "huggingface", "torch", "whisper", "lm-studio", "ollama", "modelscope", "nltk_data",
    ])
    // And the sentence that came with the old card is gone from the source entirely, rather
    // than left behind as prose nothing prints which still claims the thing that was wrong.
    #expect(XDGCacheScanner.knownDetails["huggingface"] == nil)
    #expect(!XDGCacheScanner.knows(childNamed: "huggingface"))
    #expect(XDGCacheScanner.excludedChildren.allSatisfy { $0 == $0.lowercased() })
}

/// The exclusion is case-insensitive, because macOS volumes are by default:
/// `~/.cache/HuggingFace` and `~/.cache/huggingface` are one directory, and a `Set.contains`
/// on the raw name would offer the first while refusing the second.
///
/// `PathGuard.validate` lower-cases both sides of its forbidden test for the same reason, so
/// a row like this would be refused after the button was pressed — which is a clean that
/// frees nothing with the reason buried in a run log. This is the layer that stops it being
/// offered at all.
@Test func theXDGCacheExclusionIgnoresCaseTheWayTheFilesystemDoes() async {
    let temp = TempDir()
    let shouty = temp.makeDirectory(".cache/HuggingFace")
    let mixed = temp.makeDirectory(".cache/Torch")

    let items = await XDGCacheScanner().scan(context(temp: temp, sizes: [
        shouty: 1_250_000_000, mixed: 3_000_000_000,
    ]))

    #expect(items.isEmpty)
}

/// **This scanner ticks only what it can name.**
///
/// `excludedChildren` is a denylist and a denylist of model stores can never be finished —
/// `sentence-transformers`, `gpt4all`, `mlx`, `open_clip`, `diffusers`, `spacy` and
/// `llama.cpp` all write into this directory too. A card over the next one costs what the
/// dictation-app incident cost; a *default clean* over it costs more, because `devcleaner clean`
/// shows no card at all and in permanent mode the executor does not even leave it in the
/// Trash.
///
/// So the rule is turned round. The nine tools this scanner has a sentence for keep exactly
/// their old behaviour; everything else is offered with its size and left for the user to
/// ask for. The deck still deals those as cards — click-only ones, carrying a caution — and
/// that half is pinned in `DevCleanerUITests`.
@Test func theXDGCacheTicksOnlyTheToolsItCanName() async throws {
    let temp = TempDir()
    let uv = temp.makeDirectory(".cache/uv")
    let goBuild = temp.makeDirectory(".cache/go-build")
    let nimbus = temp.makeDirectory(".cache/nimbus")
    let chroma = temp.makeDirectory(".cache/chroma")

    let items = await XDGCacheScanner().scan(context(temp: temp, sizes: [
        uv: 1_100_000_000, goBuild: 900_000_000,
        nimbus: 2_400_000_000, chroma: 600_000_000,
    ]))
    let result = ScanResult(items: items, generatedAt: now, availableBytes: 0,
                            skippedScannerIDs: [])

    #expect(result.defaultSelection.map(\.name).sorted() == ["go-build", "uv"])
    #expect(result.reclaimableBytes == 2_000_000_000)
    // Offered, sized, and accounted for on the line that says what ticking them would add.
    #expect(result.untickedDeletableBytes == 3_000_000_000)
    #expect(items.filter(\.startsUnticked).map(\.name).sorted() == ["chroma", "nimbus"])
    // **No `untickedReason`.** That field is a `ProtectionReason` — a vocabulary of
    // "something is using this" — and the reason here is that the app does not know, which
    // is not one of its cases and not a claim about the folder.
    #expect(items.allSatisfy { $0.untickedReason == nil })
    // Rule 4: `knows` really does distinguish, rather than answering one way for everything.
    #expect(XDGCacheScanner.knows(childNamed: "uv"))
    #expect(!XDGCacheScanner.knows(childNamed: "nimbus"))
    #expect(XDGCacheScanner.knownDetails.count == 9)
}

/// `codex-runtimes` is a **named** tool, which is the whole of what that costs it: the row is
/// ticked by default, it counts towards `reclaimableBytes`, and the deck's card for it is an
/// ordinary Return-answerable one.
///
/// It earned that by being watched: removing
/// `~/.cache/codex-runtimes/codex-primary-runtime` cost 1.6 GB, and the app fetched the whole
/// of it back on its own the same day — the same fact `ms-playwright` is in the list for. The
/// sentence says which kind of coming-back it is, because "rebuilt" and "re-downloaded" are
/// not the same price on somebody's connection.
@Test func theCodexRuntimeStoreIsANamedToolAndIsTickedLikeOne() async throws {
    let temp = TempDir()
    let codex = temp.makeDirectory(".cache/codex-runtimes")
    let unknown = temp.makeDirectory(".cache/glimmer2")

    let items = await XDGCacheScanner().scan(context(temp: temp, sizes: [
        codex: 1_600_000_000, unknown: 2_400_000_000,
    ]))
    let result = ScanResult(items: items, generatedAt: now, availableBytes: 0,
                            skippedScannerIDs: [])

    #expect(XDGCacheScanner.knows(childNamed: "codex-runtimes"))
    #expect(XDGCacheScanner.detail(forChildNamed: "codex-runtimes")
            == "re-downloaded the next time the Codex app runs")
    // Ticked, and counted in the amount a pass through the deck would take.
    let row = try #require(items.first { $0.name == "codex-runtimes" })
    #expect(!row.startsUnticked)
    #expect(row.selectedByDefault)
    #expect(result.reclaimableBytes == 1_600_000_000)
    // Rule 4: the folder beside it that nothing can name is still left out of all of that.
    #expect(items.filter(\.startsUnticked).map(\.name) == ["glimmer2"])
}

/// The floor is the same rule that keeps an unmeasured child out. `ScanHelpers.measured`
/// answers zero for a folder `du` could not size, and zero is below any floor — which is the
/// right answer for this scanner in particular: it has no name for most of what it lists, so
/// a card reading "0 KB" over a folder nobody can identify is nothing to decide about.
@Test func anUnmeasuredChildOfTheXDGCacheIsLeftOutEntirely() async {
    let temp = TempDir()
    let measured = temp.makeDirectory(".cache/uv")
    let unmeasured = temp.makeDirectory(".cache/nimbus")

    let items = await XDGCacheScanner().scan(context(
        temp: temp, sizeMeasurer: PartialSizeMeasurer([measured: 1_100_000_000])))

    #expect(items.map(\.method) == [.removePath(measured)])
    #expect(items.contains { $0.method == .removePath(unmeasured) } == false)
    #expect(XDGCacheScanner.minimumBytes == 50_000_000)
}

/// **Direct children only, and the directory itself never.** `~/.cache` holds every tool's
/// cache at once, and a row for it would be an all-or-nothing button over the lot; a
/// grandchild would leave a gap its tool does not expect.
@Test func theXDGCacheNeverOffersItsOwnDirectoryOrAGrandchild() async {
    let temp = TempDir()
    let child = temp.makeDirectory(".cache/uv")
    let grandchild = temp.makeDirectory(".cache/uv/archive-v0")

    let items = await XDGCacheScanner().scan(context(temp: temp, sizes: [
        child: 1_100_000_000, grandchild: 900_000_000,
    ]))

    #expect(items.map(\.method) == [.removePath(child)])
    #expect(items.contains { $0.method == .removePath(temp.path + "/.cache") } == false)
    #expect(items.contains { $0.method == .removePath(grandchild) } == false)
}

/// A symbolic link is never offered. This is the one scanner that enumerates a directory it
/// has no allowlist for, so it is the only one where a link somebody put there would decide
/// what gets offered: it would be sized by whatever it points at while trashing it moved the
/// link and freed none of those bytes.
@Test func aSymbolicLinkInTheXDGCacheIsNeverOffered() async {
    let temp = TempDir()
    let real = temp.makeDirectory(".cache/uv")
    let elsewhere = temp.makeDirectory("somewhere/big")
    let link = temp.makeSymlink(".cache/linked", to: elsewhere)

    let items = await XDGCacheScanner().scan(context(temp: temp, sizes: [
        real: 1_100_000_000, link: 9_000_000_000, elsewhere: 9_000_000_000,
    ]))

    #expect(items.map(\.method) == [.removePath(real)])
    #expect(items.contains { $0.method == .removePath(link) } == false)
    // The helper answers about the link itself rather than what it points at, which is the
    // distinction `fileExists(atPath:isDirectory:)` cannot make.
    #expect(ScanHelpers.isSymbolicLink(link))
    #expect(!ScanHelpers.isSymbolicLink(real))
}

/// A plain file in `~/.cache` is not a cache folder. Every tool that uses this directory
/// writes a directory into it, and a file there is a lock or a stray.
@Test func aPlainFileInTheXDGCacheIsNotOffered() async {
    let temp = TempDir()
    let file = temp.makeFile(".cache/some.lock")
    let items = await XDGCacheScanner().scan(context(temp: temp, sizes: [file: 900_000_000]))
    #expect(items.isEmpty)
}

/// The known names get a sentence specific to their tool and the rest get one honest generic
/// one. "models are downloaded again when a script next asks for them" is the difference
/// between shrugging at 1.2 GB and knowing what will silently re-fetch it.
@Test func theXDGCacheNamesItKnowsGetASpecificSentenceAndTheRestAGenericOne() async throws {
    let names = ["uv", "pip", "firebase", "pre-commit", "codex-runtimes",
                 "nimbus", "glimmer2"]
    let temp = TempDir()
    for name in names { temp.makeDirectory(".cache/\(name)") }
    let sizes = Dictionary(uniqueKeysWithValues: names.map {
        (temp.path + "/.cache/" + $0, Int64(1_000_000_000))
    })

    var details: [String: String] = [:]
    for item in await XDGCacheScanner().scan(context(temp: temp, sizes: sizes)) {
        details[item.name] = item.detail ?? "<none>"
    }

    #expect(details == [
        "uv": "re-downloaded on the next uv install",
        "pip": "re-downloaded on the next pip install",
        "firebase": "re-downloaded the next time the Firebase tools run",
        "pre-commit": "hook environments are rebuilt on the next pre-commit run",
        "codex-runtimes": "re-downloaded the next time the Codex app runs",
        // The two this build has never heard of, which is the case the scanner exists to
        // handle at all — and the case that is now offered unticked and behind a caution.
        "nimbus": XDGCacheScanner.unknownDetail,
        "glimmer2": XDGCacheScanner.unknownDetail,
    ])
    #expect(XDGCacheScanner.unknownDetail == "a tool's cache folder; the tool re-creates it")
}

@Test func theXDGCacheIsSilentWhenTheDirectoryIsNotThere() async {
    #expect(await XDGCacheScanner().scan(context(temp: TempDir())).isEmpty)
}

/// Rule 9: one batched call, so `sizes(of:)` keeps its cap of four `du` processes.
@Test func theNewCacheScannersEachMeasureEverythingInOneBatchedCall() async throws {
    let temp = TempDir()
    let uv = temp.makeDirectory(".cache/uv")
    let nimbus = temp.makeDirectory(".cache/nimbus")
    let brave = temp.makeDirectory("Library/Caches/BraveSoftware")
    let chrome = temp.makeDirectory("Library/Caches/Google/Chrome")
    let codeCache = temp.makeDirectory("Library/Application Support/Code/Cache")
    let cursorGPU = temp.makeDirectory("Library/Application Support/Cursor/GPUCache")

    let xdg = CallCountingSizeMeasurer([uv: 1_100_000_000, nimbus: 2_400_000_000])
    _ = await XDGCacheScanner().scan(context(temp: temp, sizeMeasurer: xdg))
    #expect(await xdg.callCount == 1)
    #expect(try #require(await xdg.batches.first).sorted() == [nimbus, uv].sorted())

    let app = CallCountingSizeMeasurer([brave: 3_100_000_000])
    _ = await AppCacheScanner().scan(context(temp: temp, sizeMeasurer: app))
    #expect(await app.callCount == 1)
    #expect(try #require(await app.batches.first).sorted() == [brave, chrome].sorted())

    let electron = CallCountingSizeMeasurer([codeCache: 900_000_000])
    _ = await ElectronCacheScanner().scan(context(temp: temp, sizeMeasurer: electron))
    #expect(await electron.callCount == 1)
    #expect(try #require(await electron.batches.first).sorted()
            == [codeCache, cursorGPU].sorted())
}

// MARK: - desktop app caches

@Test func desktopAppCachesOfferOnlyTheNamedCacheSubfoldersOfTheNamedApps() async {
    let temp = TempDir()
    let codeCache = temp.makeDirectory("Library/Application Support/Code/Cache")
    let codeCodeCache = temp.makeDirectory("Library/Application Support/Code/Code Cache")
    let slackGPU = temp.makeDirectory("Library/Application Support/Slack/GPUCache")

    let items = await ElectronCacheScanner().scan(context(temp: temp, sizes: [
        codeCache: 700_000_000, codeCodeCache: 400_000_000, slackGPU: 200_000_000,
    ]))

    #expect(items.map(\.name) == ["Code – Cache", "Code – Code Cache", "Slack – GPUCache"])
    #expect(items.map(\.method)
            == [.removePath(codeCache), .removePath(codeCodeCache), .removePath(slackGPU)])
    #expect(items.allSatisfy { $0.risk == .safe })
    #expect(items.allSatisfy { $0.isDeletable })
    #expect(items.map { $0.detail ?? "<none>" }
            == ["rebuilt as you use Code", "rebuilt as you use Code",
                "rebuilt as you use Slack"])
}

/// **The whole point of the scanner.** The same app folder holds every setting, keybinding
/// and snippet the user has, their local storage, their IndexedDB and the cookie that keeps
/// them signed in to Slack. None of it is a cache and none of it comes back.
@Test func noAppsOwnDataIsEverOfferedByTheDesktopAppCacheScanner() async {
    let temp = TempDir()
    let cache = temp.makeDirectory("Library/Application Support/Code/Cache")
    let forbidden = [
        "Library/Application Support/Code/User",
        "Library/Application Support/Code/Local Storage",
        "Library/Application Support/Code/IndexedDB",
        "Library/Application Support/Slack/Cookies",
        "Library/Application Support/Slack/storage",
        // A running app's internal state, named out of scope by the plan: nothing here is a
        // cache, and Claude rebuilds neither of them.
        "Library/Application Support/Claude/vm_bundles",
        "Library/Application Support/Claude/simulator-builds",
    ].map { temp.makeDirectory($0) }
    let appFolder = temp.makeDirectory("Library/Application Support/Code")
    let container = temp.makeDirectory("Library/Application Support")
    // An app the allowlist does not name, whose cache subfolder is spelled the same way.
    let unknownApp = temp.makeDirectory("Library/Application Support/Telegram Desktop/Cache")

    let items = await ElectronCacheScanner().scan(context(temp: temp, sizes: [
        cache: 700_000_000, unknownApp: 1_500_000_000,
    ]))

    #expect(items.map(\.method) == [.removePath(cache)])
    for path in forbidden + [appFolder, container, unknownApp] {
        #expect(items.contains { $0.method == .removePath(path) } == false, "\(path)")
    }
}

/// The complete statement of what this scanner can name, generated from the two lists above
/// rather than written out beside them.
///
/// `PathGuard.runRelativeExactPaths` used to be built from it, granting the run a licence
/// over each of the 48. The scanner is `.mentionOnly` now and the licence has gone, so this
/// list is read by the test that asserts the guard **refuses** all of them —
/// `theRunGuardRefusesEveryElectronCachePath`. Either way what makes it worth having is that
/// it is exhaustive.
@Test func theDesktopAppCacheScannerPublishesEveryPathItCanEverName() async {
    let paths = ElectronCacheScanner.relativeCachePaths
    #expect(paths.count == ElectronCacheScanner.apps.count
            * ElectronCacheScanner.cacheFolders.count)
    #expect(paths.contains("Library/Application Support/Code/Service Worker/CacheStorage"))
    #expect(paths.contains("Library/Application Support/Claude/Cache"))
    // Nothing in the published list is an app folder or the container.
    #expect(paths.contains(ElectronCacheScanner.container) == false)
    for app in ElectronCacheScanner.relativeAppPaths {
        #expect(paths.contains(app) == false, "\(app)")
    }
    // Telegram Desktop is Qt rather than Electron, so none of these names exist in it and
    // whatever it does keep is its own business.
    #expect(ElectronCacheScanner.apps.contains("Telegram Desktop") == false)
    #expect(ElectronCacheScanner.apps == [
        "Code", "Cursor", "Slack", "discord", "Notion", "Figma", "Postman", "Claude",
    ])
}

@Test func theNewCacheScannersAreSilentWhenNothingIsInstalled() async {
    let temp = TempDir()
    #expect(await AppCacheScanner().scan(context(temp: temp)).isEmpty)
    #expect(await XDGCacheScanner().scan(context(temp: temp)).isEmpty)
    #expect(await ElectronCacheScanner().scan(context(temp: temp)).isEmpty)
}

// MARK: - the two scanners the app mentions rather than cleans

/// **No route in the app can remove one of these rows**, checked at each of the three places
/// a list of rows to delete is derived.
///
/// The user asked for exactly this after seeing the cards: the browser caches, which they
/// said they would not be cleaning, and the desktop apps' own caches out of the deck,
/// mentioned on the last page instead.
/// `DeckDealing.mentionOnly` is what stops the window drawing a card, and
/// nothing that deletes reads it — so this is the half that actually holds, and it holds
/// through `CleanupItem.startsUnticked` on every row.
@Test func neitherMentionOnlyScannerCanBeCleanedByAnyDefaultRoute() async throws {
    let temp = TempDir()
    let brave = temp.makeDirectory("Library/Caches/BraveSoftware")
    let slack = temp.makeDirectory("Library/Application Support/Slack/Cache")
    let uv = temp.makeDirectory(".cache/uv")
    let sizes: [String: Int64] = [
        brave: 3_200_000_000, slack: 1_300_000_000, uv: 1_100_000_000,
    ]

    let result = await ScanEngine(
        scanners: [AppCacheScanner(), XDGCacheScanner(), ElectronCacheScanner()]
    ).scan(context: context(temp: temp, sizes: sizes))

    // All three rows are there and measured — the note on the last page needs the sizes.
    #expect(result.items.count == 3)
    #expect(ScanResult.totalBytes(of: result.items) == 5_600_000_000)
    // Only the cache of a tool the app can name is ticked.
    #expect(result.defaultSelection.map(\.method) == [.removePath(uv)])
    #expect(result.reclaimableBytes == 1_100_000_000)
    #expect(result.untickedDeletableBytes == 4_500_000_000)

    // And `cleanDefault`, which is what `devcleaner clean` runs after the user types the
    // confirmation word, touches neither of them.
    var settings = Settings.makeDefault(home: temp.path)
    settings.projectRoots = []
    let store = SettingsStore(directory: temp.url, home: temp.path)
    try store.save(settings)
    let service = CleanerService(
        settingsStore: store,
        runLog: RunLog(directory: temp.url.appendingPathComponent("runs")),
        runner: FakeProcessRunner(responses: [:]), remover: FakeFileRemover(),
        sizeMeasurer: FixedSizeMeasurer(sizes), fileManager: .default, home: temp.path,
        androidSDKPath: temp.path + "/sdk", clock: { now })
    let record = await service.cleanDefault(result, now: now) { _ in }

    #expect(record.entries.map(\.itemID) == ["other.xdgCache|\(uv)"])
    #expect(record.entries.contains { $0.itemID.hasPrefix("other.appCaches") } == false)
    #expect(record.entries.contains { $0.itemID.hasPrefix("other.electronCaches") } == false)
}

/// The listing still shows them, with their sizes, and says the thing `untickedNote` alone
/// would not: there is no switch anywhere that turns this one on.
///
/// Showing them matters. `devcleaner scan` is where the numbers are findable, and a row that
/// vanished would leave 4.5 GB the tool measured and never mentioned. What it must not do is
/// describe these the same way it describes the Android NDK — that row is unticked *and* has
/// a card with a button, and a reader told the same sentence about both would go looking for
/// this one's button.
@Test func theListingShowsAMentionOnlyRowAsOfferedAndSaysNothingRemovesIt() async throws {
    let temp = TempDir()
    let brave = temp.makeDirectory("Library/Caches/BraveSoftware")
    let items = await AppCacheScanner().scan(context(
        temp: temp, sizes: [brave: 3_200_000_000]))
    let row = try #require(items.first)
    let reporter = ReportText(home: temp.path)

    #expect(ReportText.mark(for: row) == " ")
    let target = reporter.targetLine(row)
    #expect(target.contains(ReportText.untickedNote))
    #expect(target.contains(ReportText.mentionOnlyNote))
    #expect(ReportText.mentionOnlyNote
            == "devcleaner never removes it — the app that wrote it clears its own cache")
    // Rule 4: an ordinary unticked row — the Android NDK's shape — gets the first note and
    // not the second, because that one really does have a button on a card.
    let ndk = ScanHelpers.item(
        scannerID: "android.ndk", group: .android, path: temp.path + "/sdk/ndk/27.0",
        name: "NDK 27.0", sizeBytes: 5_570_000_000, risk: .elevated, startsUnticked: true)
    #expect(reporter.targetLine(ndk).contains(ReportText.untickedNote))
    #expect(reporter.targetLine(ndk).contains(ReportText.mentionOnlyNote) == false)
}

/// The app a row belongs to, published by the scanner that names the rows.
///
/// `ProjectDeck.moreToGain` lists one line per **app** — six rows of Slack's add up to one
/// "Slack · 1.3 GB" — and a row carries its subfolder, not its app. The deck splitting on an
/// en dash of its own would be a second spelling of this scanner's naming rule, and the day
/// a row's name is reworded the note would quietly stop summing.
@Test func theDesktopAppCacheScannerSaysWhichAppARowBelongsTo() async {
    #expect(ElectronCacheScanner.app(ofRowNamed: "Slack – GPUCache") == "Slack")
    #expect(ElectronCacheScanner.app(ofRowNamed: "Code – Service Worker/CacheStorage")
            == "Code")
    // Not an app this scanner knows: listed under its own name rather than under a heading
    // invented from half of it.
    #expect(ElectronCacheScanner.app(ofRowNamed: "Telegram Desktop – Cache") == nil)
    #expect(ElectronCacheScanner.app(ofRowNamed: "Brave browsing cache") == nil)
    // And it agrees with what the scanner really writes, over a real fixture — a hand-typed
    // separator here would pass while the real rows stopped matching.
    let temp = TempDir()
    let slack = temp.makeDirectory("Library/Application Support/Slack/GPUCache")
    let rows = await ElectronCacheScanner().scan(context(
        temp: temp, sizes: [slack: 200_000_000]))
    #expect(rows.compactMap { ElectronCacheScanner.app(ofRowNamed: $0.name) } == ["Slack"])
}

// MARK: - identity

/// Rule 3. These identifiers are persisted in `Settings.alwaysSkipScannerIDs`, so renaming
/// one silently switches a scanner back on for a user who had switched it off.
@Test func theNewCacheScannerIdentitiesGroupsAndTitlesAreStable() {
    #expect(AppCacheScanner().id == "other.appCaches")
    #expect(XDGCacheScanner().id == "other.xdgCache")
    #expect(ElectronCacheScanner().id == "other.electronCaches")
    #expect(AppCacheScanner().group == .otherCaches)
    #expect(XDGCacheScanner().group == .otherCaches)
    #expect(ElectronCacheScanner().group == .otherCaches)
    #expect(AppCacheScanner().title == "Browser and app caches")
    #expect(XDGCacheScanner().title == "Caches in ~/.cache")
    #expect(ElectronCacheScanner().title == "Desktop app caches")
    // How the deck deals each of them, which is also persisted nowhere and read everywhere.
    #expect(AppCacheScanner().deckDealing == .mentionOnly)
    #expect(XDGCacheScanner().deckDealing == .perItem)
    #expect(ElectronCacheScanner().deckDealing == .mentionOnly)
}

@Test func skippingByIdentifierUsesTheStringsTheNewCacheScannersPublish() async {
    let temp = TempDir()
    temp.makeDirectory("Library/Caches/BraveSoftware")
    temp.makeDirectory(".cache/uv")
    temp.makeDirectory("Library/Application Support/Code/Cache")

    var settings = Settings.makeDefault(home: temp.path)
    settings.alwaysSkipScannerIDs = [
        "other.appCaches", "other.xdgCache", "other.electronCaches",
    ]

    let result = await ScanEngine(
        scanners: [AppCacheScanner(), XDGCacheScanner(), ElectronCacheScanner()]
    ).scan(context: context(temp: temp, settings: settings))

    #expect(result.items.isEmpty)
    #expect(result.skippedScannerIDs
            == ["other.appCaches", "other.xdgCache", "other.electronCaches"])
}
