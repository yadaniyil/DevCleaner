import Foundation
import CleanerCore

// The main window stopped being a list. It is a deck of cards, one thing at a time: which
// folders would go, what each is worth, what the card adds up to, and two answers — Clean
// up, or Skip.
//
// A card is a **project** or a **scanner**. Every card used to be a project, and the names
// in this file are from then; a scanner is the right second unit because its rows share one
// nature and one honest story about how they come back. All sixteen simulators are one card
// and all twenty-two derived data folders are another, and never the two mixed — a card
// whose promise line has to cover "next build remakes it" and "gone for good, no Trash" at
// once is a card that cannot say either.
//
// Everything in this file is a plain value. No SwiftUI, no clock, no disk: the scan comes
// in as a `ScanResult`, the time as `now`, the home directory as `home`. Every string the
// deck shows and every number it rounds lives here rather than in `DevCleanerApp`, for the
// reason the whole `DevCleanerUI` target exists — a test target cannot import an executable,
// so a sentence written in a view is a sentence nothing can check.

// MARK: - every word the deck says

/// The deck's copy, in one place.
///
/// Keyed on what the sentence is about rather than on where it appears, so two cards
/// asking the same question get the same answer. The mode-dependent ones take
/// `moveToTrash` as a parameter and are also surfaced through `ProjectDeckSummary`, so the
/// view never reads `Settings` to decide what to say: "Deleted so far" over a run that put
/// 12 GB in the Trash is the kind of mistake that makes a user empty a Trash they thought
/// was already empty.
public enum ProjectDeckText {

    // MARK: how a folder comes back

    public static let rebuiltByTheNextBuild = "Next build remakes it"
    public static let restoredByFlutterPubGet = "flutter pub get remakes it"
    public static let restoredByPodInstall = "pod install downloads it again"
    public static let restoredByNpmInstall = "npm install downloads it again"

    public static func worktreeBuildOutput(_ worktree: String) -> String {
        "Build output of worktree \(worktree)"
    }

    /// The one line beside a folder saying how it gets back.
    ///
    /// The whole point of the card: the user is not being asked to trust a size, they are
    /// being asked whether they mind this folder going, and that depends entirely on what
    /// it costs to have it again. `pod install` needs the network and `node_modules` can
    /// need a package that has since been unpublished; a `.build-cows` needs a build.
    ///
    /// Keyed on the relative folder name, which is `CleanupItem.name` for every row this
    /// deck is built from, and the worktree case is tested first because those names carry
    /// a worktree in the middle and match nothing else.
    ///
    /// A `default` rather than an exhaustive switch, unlike `ProjectScanner.detail(for:)`.
    /// The two are not the same kind of decision: there, a missed `ProtectionReason` would
    /// print a sentence written for something else, so the build has to stop. Here every
    /// unlisted name is a build folder — that is what the scanner's fixed list is made of,
    /// plus `.build-…` variants whose suffixes are invented on the spot and cannot be
    /// listed at all — so the fall-through is the right answer rather than a shrug. And it
    /// is only a sentence: what actually warns about a download is `needsDownload`, which
    /// comes from the scanner's own `risk` and not from this table.
    public static func restoreHint(forFolderNamed name: String) -> String {
        if let worktree = worktreeName(in: name) { return worktreeBuildOutput(worktree) }
        switch name {
        case ".dart_tool", ".symlinks":
            return restoredByFlutterPubGet
        case "Pods", "ios/Pods", "macos/Pods":
            return restoredByPodInstall
        case "node_modules":
            return restoredByNpmInstall
        default:
            return rebuiltByTheNextBuild
        }
    }

    /// The worktree a `.claude/worktrees/<name>/build` row belongs to, or `nil`.
    ///
    /// The prefix comes from `ProjectBuildOutputScanner.worktreeContainer`, the constant
    /// the row's name was built with, rather than being spelled again here. A second
    /// spelling would fail silently: the row would stop being recognised as a worktree's
    /// and quietly fall back to the generic sentence.
    static func worktreeName(in folderName: String) -> String? {
        let prefix = ProjectBuildOutputScanner.worktreeContainer + "/"
        guard folderName.hasPrefix(prefix) else { return nil }
        let rest = folderName.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
        return String(rest[..<slash])
    }

    // MARK: when the project last changed

    /// "last changed 4 months ago".
    ///
    /// `AgeText.since` is deliberately not reused. It answers "123d ago", which is right
    /// beside a scan taken minutes ago and unreadable beside a project untouched since
    /// spring — and the question this line answers is "have I finished with this?", to
    /// which "4 months ago" is a yes and "123d ago" is arithmetic.
    ///
    /// Whole days from the seconds between the two dates, not calendar days. A `Calendar`
    /// needs a time zone, the only thing a time zone buys here is which side of midnight
    /// "yesterday" falls on, and a time zone read from the environment is a value no test
    /// can pin. A date in the future — a clock moved back, a file stamped ahead — reads as
    /// today rather than as a negative count of days.
    public static func lastChanged(_ date: Date, now: Date) -> String {
        "last changed " + age(date, now: now)
    }

    static func age(_ date: Date, now: Date) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1:      return "today"
        case 1:         return "yesterday"
        case 2..<7:     return "\(days) days ago"
        case 7..<30:    return counted(days / 7, "week") + " ago"
        case 30..<365:  return counted(days / 30, "month") + " ago"
        default:        return counted(days / 365, "year") + " ago"
        }
    }

    /// "1 week", "4 weeks". Every plural in this file goes through here so none of them
    /// can end up reading "1 weeks".
    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    // MARK: the card

    /// The sentence under the gain number: "in 8 folders that rebuild themselves".
    ///
    /// Two shapes, because one of them would be a promise the rows underneath it
    /// contradict. A card whose folders are all build output really does rebuild itself,
    /// and that is the claim worth making — it is why the user can say yes without
    /// thinking. A card holding `ios/Pods` or `node_modules` does not: those come back
    /// over the network, the row beside each of them says so, and a heading claiming
    /// otherwise two lines above is how a tool teaches its user to stop reading it.
    public static func folderCount(_ count: Int, needsDownload: Bool) -> String {
        if needsDownload {
            return count == 1
                ? "in 1 folder that comes back on its own"
                : "in \(count) folders that come back on their own"
        }
        return count == 1
            ? "in 1 folder that rebuilds itself"
            : "in \(count) folders that rebuild themselves"
    }

    /// The same line on a tool card: "in 16 items".
    ///
    /// It counts and says nothing else, and that silence is the decision. The project
    /// sentence above promises the folders come back — which is why a user can say yes
    /// without thinking — and a simulator does not come back at all, a runtime comes back
    /// as a several-gigabyte download from Apple and a spec repo comes back only with a
    /// network. Those promises belong per row, where each row's own `detail` makes them,
    /// and one heading covering all of them could only be true of the mildest.
    ///
    /// "items", not "folders": the rows of `ios.simulators` and `ios.runtimes` are devices,
    /// and there is no folder for the user to go and look at.
    public static func itemCount(_ count: Int) -> String {
        "in " + counted(count, "item")
    }

    /// What a derived data folder is called, once Xcode's hash is off the end.
    ///
    /// Xcode names the folder `<workspace>-<28 letters>`, hashed from the workspace path —
    /// `Runner-blblggpuoxuymgejdrqraclibwkw`. The hash is the reason two projects called
    /// `Runner` have two folders, and it is of no use whatever to the person deciding
    /// whether to delete one: it is unpronounceable, it is most of the width of the row,
    /// and it pushes the part that identifies the project out of sight. The row's `detail`
    /// still says which project it belongs to, or that the project is gone.
    ///
    /// Exactly 28 lowercase letters after the last hyphen, with something in front of it.
    /// Anything else keeps the whole name: a folder a user made by hand, a name with no
    /// hyphen, a hash of a different length from a future Xcode. Cutting on "the last
    /// hyphen" alone would turn `my-app` into `my`.
    public static func derivedDataName(_ name: String) -> String {
        guard let hyphen = name.lastIndex(of: "-") else { return name }
        let head = name[..<hyphen]
        let hash = name[name.index(after: hyphen)...]
        guard !head.isEmpty,
              hash.count == derivedDataHashLength,
              hash.allSatisfy({ $0.isLowercase && $0.isLetter && $0.isASCII })
        else { return name }
        return String(head)
    }

    /// The length of the hash Xcode appends. A constant so the test and the rule read the
    /// same number.
    static let derivedDataHashLength = 28

    /// The name to show for one row of a tool card.
    ///
    /// Only derived data is rewritten. Every other scanner's row is already named by the
    /// thing it is — "npm cache", "iPhone 17 Pro", "Downloaded dependencies" — and a
    /// second rule over those names could only make one of them wrong.
    public static func rowName(of item: CleanupItem) -> String {
        item.scannerID == DerivedDataScanner.scannerID
            ? derivedDataName(item.name)
            : item.name
    }

    /// The line that makes the offer honest, on a card the tool would once have refused to
    /// show at all.
    ///
    /// A project the user has been working in this fortnight is in the deck — that is the
    /// whole of the change `CleanupItem.untickedReason` was added for — and the price of
    /// showing it is saying so. Two clauses on purpose: the fact ("you changed this…"), and
    /// then what it costs ("its next build starts from scratch"), because the fact alone is
    /// a warning with no consequence attached and the user cannot weigh it.
    ///
    /// Exhaustive with no `default`, the same rule as `ProjectScanner.detail(for:)`: a new
    /// `ProtectionReason` must not slip through wearing a sentence written for recent
    /// activity. Only `.recentActivity` reaches a card today — a pin is withheld and never
    /// becomes one — so the rest fall to the reason's own words, which are the only text
    /// guaranteed not to lie about whatever arrives next.
    public static func caution(for reason: ProtectionReason) -> String {
        let consequence = "Its next build starts from scratch."
        switch reason {
        case .recentActivity(let days):
            return "You changed this in the last \(days) days. \(consequence)"
        case .pinnedProject,
             .mostRecentlyUsedDevice, .recentlyUsedDevice, .pinnedDevice, .bootedDevice,
             .sdkInUse, .newestRuntime, .runtimeUsedByKeptDevice,
             .runtimeUsedByProtectedDevice, .runtimeImageNotDeletable,
             .gradleVersionInUse, .newestDeviceSupport:
            return "You're using this project — \(reason.description). \(consequence)"
        }
    }

    /// The caution on a card that **cannot** be undone: the simulators, the runtimes and
    /// the emulators.
    ///
    /// Said on the card as well as above the buttons, and the repetition is deliberate.
    /// Every other card in the deck is answered with a key — Return cleans — and a user who
    /// has said yes to nine reversible cards in a row is not reading by the tenth. So this
    /// card says it twice, its button says "Delete … for good" rather than "Clean up", and
    /// it has no Return shortcut at all: see `ProjectCard.answersToReturn`.
    ///
    /// Short and flat on purpose. The engine's own sentence, which names the tools and the
    /// exception, is the one above the buttons — `permanentPromise` — and two long
    /// paragraphs of warning is how a user learns to skip both.
    public static let permanentCaution = "Deleted for good. These do not go to the Trash."

    /// The caution on a card for a folder in `~/.cache` whose tool the app cannot name — a
    /// dev machine answers with a handful of `chroma`-shaped folders nobody in this package
    /// has heard of, and some of them hold downloaded models.
    ///
    /// `other.xdgCache` is the one scanner that offers folders it has no name for, and the
    /// whole justification is the *location*: by the XDG convention everything in `~/.cache`
    /// is disposable and re-created by whichever tool wrote it. That is a promise the
    /// directory makes, not one this app can check — and the `huggingface` card proved how
    /// wrong it can be, because the thing in it was a model an app loads at launch. The
    /// model stores are excluded by name now, but the next one has not been heard of yet.
    ///
    /// So the unnamed folders are still offered — they are usually exactly what the
    /// convention says, and 2.4 GB under a name nothing here knows is real space — but they
    /// are not answerable by reflex: this line is on the card, and
    /// `ProjectCard.answersToReturn` is false, so the button has to be clicked and it is
    /// drawn in amber.
    ///
    /// Two clauses, the same shape as every other caution here: the fact ("does not know
    /// this tool"), then what it might cost ("may have to download things again"). "Should
    /// rebuild" and not "will": the honest strength of a claim made by a directory naming
    /// convention rather than by anything this app has looked at.
    public static let unknownToolCaution =
        "DevCleaner does not know this tool. It should rebuild this folder, "
        + "but it may have to download things again."

    /// The caution on a card holding rows a normal clean leaves alone — the Android NDK,
    /// 5.6 GB that only comes back over the network.
    ///
    /// These rows are on the card for the same reason an active project's folders are: the
    /// deck names the thing, lists the rows with their sizes, and waits, so pressing Clean
    /// up under all that is the user asking for exactly them. What it may not do is take
    /// them silently, and this is the sentence that keeps it honest — the fact ("a normal
    /// clean leaves this alone") and then the price ("a large download"), because the fact
    /// alone is a warning with nothing attached for the user to weigh.
    public static let untickedCaution =
        "A normal clean leaves this alone: getting it back is a large download."

    /// The line above the buttons on a **project** card. It is the one reassurance on the
    /// card, so it says what stays before it says what goes.
    public static func promise(moveToTrash: Bool) -> String {
        moveToTrash
            ? "Your code stays. Only these folders go to the Trash."
            : "Your code stays. Only these folders are deleted — for good."
    }

    /// The same line on a tool card.
    ///
    /// "Your code stays" is dropped, because on this card it would be answering a question
    /// nobody asked: nothing on a derived data or Gradle card is inside a project at all.
    /// What the user wants to know here is whether the button reaches past the list they
    /// are reading — a shared cache a dozen projects use — and the answer is no.
    public static func toolPromise(moveToTrash: Bool) -> String {
        moveToTrash
            ? "Only what is listed here goes to the Trash."
            : "Only what is listed here is deleted — for good."
    }

    /// The line above the buttons on a card that removes something for good, **in the
    /// engine's own words**.
    ///
    /// `CleanerService.warnings(for:moveToTrash:)` is what `devcleaner clean` prints before a
    /// real clean, and it is the engine's own account
    /// of what its executor is about to do — including the one machine where an emulator
    /// really does go to the Trash, because `avdmanager` is missing. Re-writing the
    /// sentence here would let the deck and the engine come to disagree about the most
    /// expensive fact in the app, and the deck's copy would be the one the user reads.
    ///
    /// Joined with a space, so a card that somehow held both a device and a path keeps both
    /// sentences. The fallback is unreachable while a caller only asks about a card with a
    /// permanent row in it — which is the only card that asks — and it is the engine's
    /// constant rather than a sentence of our own either way.
    public static func permanentPromise(for items: [CleanupItem], moveToTrash: Bool) -> String {
        let warnings = CleanerService.warnings(for: items, moveToTrash: moveToTrash)
        guard !warnings.isEmpty else {
            return CleanerService.Warning.devicesAreRemovedPermanently
        }
        return warnings.joined(separator: " ")
    }

    /// What the line above the buttons says while a scan holds the app's one work slot.
    ///
    /// `cleanCurrentProject` refuses during a scan, so Clean up is greyed out for the whole of
    /// it — about a minute, starting the moment the app opens, because the launch scan runs
    /// over the cached deck. A dead primary button with a reassurance about the Trash above
    /// it reads as a broken app; this says what it is waiting for and that it ends by itself.
    public static let cleanUpWaitsForScan =
        "Measuring everything again. Clean up unlocks when it finishes."

    /// The same, for a run that is not this card's.
    ///
    /// `work` is one slot for the whole app, so any clean greys Clean up out on every card.
    /// Left to the scan's sentence it would say the app was measuring, which is not what is
    /// happening; left to the promise it would leave a dead primary button with nothing
    /// explaining it.
    ///
    /// Nothing reaches this state today — the menu bar stopped cleaning when it became a
    /// status item, so every run belongs to the card on screen. The sentence no longer names
    /// where the run came from, because there is no longer a second place to point at, and
    /// naming one would be the only lie on the card.
    public static let cleanUpWaitsForOtherRun =
        "A clean is already running. Clean up unlocks when it finishes."

    /// The line above the buttons for the state the app is in: the promise, except while
    /// something else is holding Clean up down.
    ///
    /// `isCleaningThisCard` rather than a second look at the phase, because the phase cannot
    /// tell the two runs apart — `AppModel.cardRun` is what knows whose clean is going, and
    /// the difference is the whole of this sentence. During the card's **own** run the
    /// promise stays: the button beside it is counting folders off, which explains itself.
    public static func actionNote(
        phase: AppModel.Phase, isCleaningThisCard: Bool, promise: String
    ) -> String {
        if case .scanning = phase { return cleanUpWaitsForScan }
        if case .running = phase, !isCleaningThisCard { return cleanUpWaitsForOtherRun }
        return promise
    }

    /// The eyebrow over a project card's title. A tool card's is its `GroupID.title` — the
    /// technology the rows belong to, which is what tells two cache cards apart at a glance.
    public static let projectEyebrow = "Project"

    /// The eyebrow over one of the user's own large files.
    ///
    /// Both halves are load-bearing and they pull against each other on purpose. "Big"
    /// because that is why the card exists at all; "but yours" because every other card in
    /// the deck is about something a tool made, and a user who has answered nine of those
    /// by reflex has to notice that this one is different before they read anything else.
    public static let bigThingEyebrow = "Big, but yours"

    /// "added 5 months ago" — the line beside a per-item card's location.
    ///
    /// A different verb from `lastChanged`, because it is a different fact. A project's date
    /// answers "have I finished with this?"; a download's answers "how long has this been
    /// sitting here?", and *added* is the word for that — it is also what Finder's own
    /// column calls it, so the user can go and check.
    public static func added(_ date: Date, now: Date) -> String {
        "added " + age(date, now: now)
    }

    public static let skip = "Skip"

    public static func cleanUp(_ totalText: String) -> String { "Clean up \(totalText)" }

    /// The primary button on a card that cannot be undone: "Delete 21.4 GB for good".
    ///
    /// Not "Clean up". Nine cards into a session "Clean up 21.4 GB" is a button the user
    /// has already pressed nine times, and the tenth press would destroy sixteen simulators
    /// with every app installed in them. The verb is the one the engine performs and the
    /// two words at the end are the whole of the difference, so the button cannot be
    /// mistaken for the one above it in muscle memory.
    public static func deleteForGood(_ totalText: String) -> String {
        "Delete \(totalText) for good"
    }

    /// The primary button on one of the user's own files: "Move 7.0 GB to Trash".
    ///
    /// Not "Clean up", for the same reason `deleteForGood` is not: by the time this card is
    /// dealt the user has pressed "Clean up …" a dozen times, and this button is the one
    /// that moves something nothing will bring back. It names the **destination** rather
    /// than the verb, because the destination is the whole of the reassurance — and like
    /// the permanent cards it has no Return shortcut, so it has to be clicked.
    ///
    /// "to Trash", not "to the Trash": it is a button label, and the article reads as
    /// padding at 14 points beside a size.
    public static func moveToTrash(_ totalText: String) -> String {
        "Move \(totalText) to Trash"
    }

    /// The quiet action under a big thing's location line, the item in a row's context menu,
    /// and the tooltip on a checklist row's reveal button.
    ///
    /// The one card in the deck where looking first is the reasonable thing to do. Every
    /// other card is a folder a tool wrote, which the user has never opened and never will;
    /// this one is a file they chose to have, and "is this the archive I still need?" is a
    /// question only Finder can answer.
    ///
    /// One string for all three, deliberately: the button, the menu item it duplicates and
    /// the card-level action all do exactly the same thing, and a user who learns the words in
    /// one place must not have to learn them again in another.
    public static let showInFinder = "Show in Finder"

    /// What a screen reader reads on a checklist row's reveal button: "Show cards.db in
    /// Finder".
    ///
    /// The bare "Show in Finder" is what a sighted user needs, because the row they are
    /// pointing at says which file. Somebody moving through a page of forty buttons by
    /// keyboard hears forty identical labels, and the name is the only thing that tells them
    /// which one they are on.
    public static func showInFinder(_ fileName: String) -> String {
        "Show \(fileName) in Finder"
    }

    /// The caution on one of the user's own files.
    ///
    /// Two sentences, and the second is the reason the first is bearable. "This does not
    /// come back" on its own is the truth and reads as a threat; the Trash is what makes the
    /// decision reversible for as long as the user wants it to be, and saying so is what
    /// lets them answer at all.
    public static let bigThingCaution =
        "This does not come back. It goes to the Trash, where you can still get it back."

    /// The line above the buttons on one of the user's own files.
    ///
    /// **The one promise line in the deck that does not depend on `moveToTrash`**, because
    /// the thing it describes does not either: the executor always trashes an
    /// `.irreplaceable` row, whatever the setting says — see
    /// `CleanupItem.goesToTheTrash(moveToTrash:)`. Running `toolPromise` here would print
    /// "deleted — for good" for a user in permanent mode, about a file that is going to be
    /// sitting in their Trash, which is the worst sentence this app could put on screen.
    public static let bigThingPromise =
        "It goes to the Trash whatever your settings say. "
        + "Your own files are never deleted outright."

    /// The caution on a card holding **several** of the user's own files — the checklist
    /// page, where the card is a list rather than one file.
    ///
    /// `bigThingCaution` word for word in the plural, and kept as a second constant rather
    /// than assembled from a count at the call site: the two readings sit side by side here,
    /// so a change to one is a visible omission in the other, and both are strings a test
    /// can name.
    public static let bigThingsCaution =
        "These do not come back. They go to the Trash, where you can still get them back."

    /// The line above the buttons on that page: `bigThingPromise` in the plural.
    ///
    /// Like the singular it does **not** depend on `moveToTrash`, because the thing it
    /// describes does not either — the executor always trashes an `.irreplaceable` row,
    /// whatever the setting says. See `CleanupItem.goesToTheTrash(moveToTrash:)`.
    public static let bigThingsPromise =
        "They go to the Trash whatever your settings say. "
        + "Your own files are never deleted outright."

    // MARK: the page with the checkboxes

    /// "18 of 56 files" — the line under a checklist page's big number.
    ///
    /// Two figures, because the page's question is which of them to *choose*: the total is
    /// what the scan found, and the first number is what the button above it is about, so a
    /// user ticking their way down the list can watch it climb. It reads "0 of 41 files" on
    /// the page as it is dealt, under a headline saying the same thing in bytes. Every other
    /// card's line here is a count with a promise attached — "in 8 folders that rebuild
    /// themselves", "in 16 items" — and neither shape fits a list the user is editing.
    ///
    /// "files" through `counted`, so a page holding one reads "0 of 1 file".
    public static func checklistCount(ticked: Int, of total: Int) -> String {
        "\(ticked) of " + counted(total, "file")
    }

    /// The small half of a checklist page's headline: "of 41.3 GB" after the ticked figure.
    ///
    /// The word that makes the two numbers one quantity. It is a preposition and it is still
    /// here rather than in the view, for the reason the whole of this file is: a word typed
    /// into a SwiftUI body is a word nothing can check, and this one is load-bearing —
    /// without it "0 41.3 GB" is not a sentence. `SizeHeadline.init(tickedBytes:of:)` is the
    /// only caller and takes `ByteText.short`'s own output, so the unit is spelled once.
    public static func headlineRest(of totalText: String) -> String { "of \(totalText)" }

    /// The primary button on a checklist page with every box clear — which is now the
    /// **first** thing a user sees on it.
    ///
    /// The button is dead in that state, so it cannot name an amount: "Move 0 KB to Trash" is
    /// a title the same formatter really would produce, over a press that would do nothing.
    /// What it says instead is the one move available, in the imperative, because the page as
    /// dealt is not a page with something wrong with it — it is a page waiting to be read.
    /// "Nothing ticked" was the right label while the page opened fully ticked and clearing
    /// boxes was the work; as the opening state it reads as a complaint about the user not
    /// having done anything yet.
    ///
    /// "to the Trash" with its article, unlike `moveToTrash(_:)`, which drops it as padding
    /// beside a size. Here there is no size and the line is a sentence, so the article is
    /// what keeps it from reading as a label.
    public static let nothingTicked = "Tick the files to move to the Trash"

    /// The quiet text button over a checklist page's rows.
    ///
    /// One button whose word follows the ticks rather than two side by side. The page is
    /// dealt with **nothing** ticked, so the bulk move worth offering there is "tick them
    /// all, then clear the two I want to keep"; the moment everything is ticked the move
    /// worth offering is the way back. Either extreme is two presses from anywhere, and there
    /// is one control to read instead of one live and one dead. The word and the effect travel
    /// together in `ProjectCard.ChecklistSelectAll` so they cannot part company.
    public static let selectAll = "Select all"
    public static let selectNone = "Select none"

    /// The Clean up button's title while the run is going: real progress out of
    /// `ExecutionProgress`, never a spinner. The card lists the folders in the order the
    /// engine is working through them, so "2 of 8" names the row the user can watch drain.
    public static func cleaning(completed: Int, total: Int) -> String {
        "Cleaning… \(completed) of \(total)"
    }

    /// The same title, from whatever the engine has reported so far, over the card's own
    /// folder count.
    ///
    /// The total is the card's rather than the report's because the button has to say
    /// something before the first report arrives: `phase` becomes `.running(nil)` the moment
    /// Clean up is pressed, and "Cleaning… 0 of 0" above eight folders waiting to drain is a
    /// button that looks broken. Choosing the fallback **is** the decision, which is why it
    /// is not an `??` in the view.
    public static func cleaning(_ progress: ExecutionProgress?, of total: Int) -> String {
        cleaning(completed: progress?.completed ?? 0, total: total)
    }

    /// The keyboard hints set after the two button titles, in the keys' own glyphs.
    ///
    /// Words the user reads, so they live here — and more than that, they are a promise
    /// about which key does which thing. Return cleans and the right arrow skips; the two
    /// swapped would teach the wrong key for the destructive one, and a glyph typed into a
    /// SwiftUI body is a glyph no test can compare against the shortcut beside it.
    public static let cleanUpKeyHint = "⏎"
    public static let skipKeyHint = "→"

    /// The only button on a card whose clean left something behind. Not "OK": the user is
    /// being told what did not happen, and the button they press next should say where it
    /// takes them.
    public static let nextProject = "Next project"

    // MARK: what the card says once its clean is over

    /// The quiet half of the headline after a run: "8.5 GB →", with what is left set large
    /// after it.
    ///
    /// **The arrow travels with the amount** rather than being typed into the view beside it.
    /// It is the whole of the sentence — "8.5 GB → 0 GB" says the press worked and a bare
    /// "8.5 GB 0 GB" says nothing — and a glyph in a SwiftUI body is a glyph no test can
    /// compare against the number it points at. The same reasoning as `headlineRest(of:)`,
    /// which is the other preposition in this file.
    ///
    /// `ByteText.short`'s own output goes in, so the unit is spelled once and rounded by the
    /// one table. `SizeHeadline.init(before:after:)` is the only caller.
    public static func headlineBefore(_ totalText: String) -> String { "\(totalText) →" }

    /// The line under the headline when a run has just ended: what happened, in the card's
    /// own voice, in the past tense.
    ///
    /// **The user asked for this.** They pressed "Delete 8.5 GB for good", it worked, and
    /// what the card showed them afterwards was the bar full again under a sentence in orange
    /// — so they could not tell a success from a failure. These three say the thing that
    /// happened, and the headline beside them says how much of it.
    ///
    /// Chosen from the run's **record** — which rows were trashed and which were deleted —
    /// never from the setting or from what the button offered: `CleanupItem.goesToTheTrash`
    /// keeps a file of the user's own out of a permanent run, and a card claiming "deleted
    /// for good" over something sitting in the Trash is the one mistake this whole file is
    /// careful about. See `CardRunResult.confirmation(of:)`.
    public static let movedToTheTrash = "Moved to the Trash."
    public static let deletedForGood = "Deleted for good."
    /// One card whose rows did not all land in the same place. Reachable: `avdmanager delete
    /// avd` removes an emulator outright, and the fallback used when the Android command line
    /// tools are missing moves its files to the Trash instead — so one card's two rows can
    /// come back with two outcomes. Neither sentence alone would be true of it.
    public static let movedAndDeleted = "Some moved to the Trash, the rest deleted for good."

    /// Whether a run note is worth stopping the deck for.
    ///
    /// A note is not a failure — see `RunRecord.notes` — but the deck has no summary panel,
    /// so a note the user should read holds the card behind "Next project". That is right for
    /// Xcode having been open, and for a run whose log could not be written. It was wrong for
    /// exactly one note, and wrongly enough to be the reason this whole state exists: after a
    /// successful "Delete 8.5 GB for good" the executor adds
    /// `Executor.Note.devicesWereRemovedPermanently`, and a card held under that sentence in
    /// orange reads as a run that failed. It says nothing the card has not already said
    /// twice — the caution above the button, the button's own "for good", and now
    /// `deletedForGood` under the headline — so it is left in the run log and the deck moves
    /// on.
    ///
    /// Matched against the **engine's own constant**, never against its prose: the sentence is
    /// the executor's to reword, and a copy of it spelled out here would start holding cards
    /// again the day somebody fixed a comma. Every other note holds, including one this build
    /// has never seen — a note from a newer engine is by definition something new to say.
    public static func noteHoldsTheCard(_ note: String) -> Bool {
        note != Executor.Note.devicesWereRemovedPermanently
    }

    // MARK: the card between the two halves of the deck

    /// The interstitial's headline.
    ///
    /// It is the deck telling the user that the promise is about to change. Everything
    /// before this card comes back on its own; nothing after it does. Without the card the
    /// change happens silently between one Return press and the next, and the first
    /// difference the user would meet is a button that no longer answers to the key they
    /// have been using.
    ///
    /// Short enough for the card's two-line title at 26 points. The plan drafted "That's
    /// everything that comes back on its own." and the clause is dropped for width — the
    /// detail line underneath says what the deck is moving on to, in full.
    public static let interstitialHeadline = "That's everything that comes back."

    /// The line under the interstitial's big number.
    ///
    /// It deliberately does **not** repeat the amount: that is set at 96 points two lines
    /// above, and a sentence restating it teaches the user that the two numbers on a card
    /// can be different things. What the sentence adds is the count, whose files they are,
    /// and the one rule that follows — nothing happens unless they say so.
    public static func interstitialDetail(count: Int) -> String {
        let subject = "Next: " + counted(count, "big thing") + " that "
            + (count == 1 ? "is" : "are") + " yours. "
        return count == 1
            ? subject + "It does not come back; it goes to the Trash only if you say so."
            : subject + "They do not come back; they go to the Trash only if you say so."
    }

    /// "Look through them" — the interstitial's primary button.
    ///
    /// It answers to Return, unlike the cards it introduces. Looking costs nothing, and
    /// taking the key away here would make the interstitial itself the thing a keyboard
    /// user cannot get past — while the cards behind it still have to be clicked, which is
    /// where the deliberate friction belongs.
    public static let interstitialPrimary = "Look through them"

    /// "Skip them all" — the way past the whole second half in one press.
    ///
    /// Offered rather than made difficult. A user who has just cleaned twelve caches and
    /// does not want to be asked about their downloads should be able to say so once, and
    /// the alternative is arrow-keying through fourteen cards, which teaches them to
    /// arrow-key without reading.
    public static let interstitialSecondary = "Skip them all"

    /// The line above the interstitial's buttons. Neither button removes anything, and that
    /// is the only thing the user needs to know before pressing either.
    public static let interstitialPromise = "Looking through them decides nothing."

    /// "including 3 big things · 21.0 GB" — the end card's line for the user's own files.
    ///
    /// "Including", because it is a **breakdown** and not a further amount. The Trash line
    /// above it already contains these bytes, and the plan's draft — "3 big things moved to
    /// the Trash · 21.0 GB" — reads as a second sum to be added to the first, which would
    /// make the end card's own lines contradict the number over them.
    ///
    /// It is worth a line of its own all the same: a session that trashed twelve caches and
    /// one 18 GB language model has done two different things, and the model is the one the
    /// user might want back.
    public static func endBigThings(count: Int, bytes: Int64) -> String {
        "including " + counted(count, "big thing") + " · \(ByteText.short(bytes))"
    }

    // MARK: the strip

    /// "3 of 24".
    ///
    /// No noun. It said "Project 3 of 24" while every card was a project; a deck that deals
    /// derived data between two projects cannot, and "Card 3 of 24" would be the window
    /// naming its own furniture. The card itself says what it is — its eyebrow reads
    /// "Project" or "Xcode & iOS" — so the counter only has to count.
    public static func position(index: Int, count: Int) -> String {
        "\(index) of \(count)"
    }

    /// The label over the running session total.
    ///
    /// The distinction the whole app is careful about, now in two parts. A run that trashed
    /// 6.15 GB changed free space by 60 MB on a real dev machine, because the Trash still
    /// held the rest — so "Deleted so far" over a trashing session is a lie the user acts
    /// on by not emptying their Trash. And the deck can now delete for good as well: one
    /// simulator card puts 21.4 GB beyond recovery, and "In the Trash so far" over a total
    /// that includes it would send the user looking for something that is not there.
    ///
    /// So the Trash is claimed only while it is the whole truth. The moment anything has
    /// gone for good the label says "Cleaned so far", which is true of both halves, and the
    /// end card is where the two amounts are told apart by name.
    public static func sessionLabel(moveToTrash: Bool, deletedForGood: Bool) -> String {
        moveToTrash && !deletedForGood ? "In the Trash so far" : "Cleaned so far"
    }

    // MARK: the end of the deck

    /// "That's everything." — the deck covers everything the app can clean, so the sentence
    /// can no longer promise it was only about projects.
    public static let endHeadline = "That's everything."

    /// "4.4 GB moved to the Trash" — one of the end card's amount lines.
    ///
    /// Each amount gets a line of its own, and the line names where it went. A session that
    /// trashed 4.4 GB and destroyed a 17.3 GB runtime has one big number above these lines,
    /// 21.7 GB, and that number is the sum of two completely different promises: one lot is
    /// sitting in the Trash waiting to be emptied, the other is gone. A single line under it
    /// would have to lie about half of it.
    public static func endTrashed(_ sizeText: String) -> String {
        "\(sizeText) moved to the Trash"
    }

    /// "17.3 GB deleted for good" — the other amount line. "For good", not "permanently":
    /// it is the same phrase as the button that did it.
    public static func endDeleted(_ sizeText: String) -> String {
        "\(sizeText) deleted for good"
    }

    /// "from 3 cards" — what the amounts above it came out of.
    public static func endFromCards(_ count: Int) -> String {
        "from " + counted(count, "card")
    }

    /// The end of a deck the user skipped their way through. A bare count would put
    /// "moved to the Trash from 0 cards" on screen, which reads as a failure rather
    /// than as a decision they made twenty-four times.
    public static let endDetailNothingCleaned = "You left everything alone."

    /// Only in Trash mode, and only when something really moved.
    /// `CleanerService.Warning.trashingDoesNotFreeSpaceYet` says the same thing before a
    /// run; this is it afterwards, naming the Trash because there is now a button beside
    /// it that opens one.
    public static let emptyTheTrashNote = "The space comes back when you empty the Trash."

    /// Said on the end card when something this session went into the Trash under a name
    /// Finder will not draw.
    ///
    /// `.build`, `.dart_tool`, `.build-release` — most of what this window removes begins
    /// with a dot, and Finder hides dot-names in the Trash exactly as it does everywhere
    /// else. The first person to clean six projects opened the Trash, saw none of them, and
    /// reasonably concluded the app had deleted 4.4 GB outright. They were all there. The
    /// shortcut is Finder's own switch for hidden files; emptying the Trash removes hidden
    /// items too, so the promise in `emptyTheTrashNote` holds either way.
    public static let hiddenInTrashNote =
        "Folders like .build are hidden in the Trash. Press ⌘⇧. there to see them — "
        + "emptying the Trash removes them either way."

    /// Whether Finder hides an item with this path: its own name begins with a dot.
    public static func isHiddenInFinder(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix(".")
    }

    /// "2 skipped · 3.4 GB".
    public static func skipped(count: Int, bytes: Int64) -> String {
        "\(count) skipped · \(ByteText.short(bytes))"
    }

    public static let reviewSkipped = "Go through skipped again"
    public static let openTrash = "Open the Trash"

    public static let nothingHeadline = "Nothing to clean up."

    /// The floor is printed from `ProjectDeck.minimumCardBytes` rather than typed, so
    /// raising it cannot leave a sentence behind naming the old one.
    ///
    /// It no longer says "no project". The deck deals every scanner now, so a machine that
    /// reaches this card has nothing over the floor anywhere — not one project, not derived
    /// data, not a simulator — and the old sentence would have pointed the user at the one
    /// part of the answer that was never the whole of it.
    public static var nothingDetail: String {
        "Nothing here holds more than \(ByteText.short(ProjectDeck.minimumCardBytes))."
    }

    // MARK: the quiet lines under the end card

    /// "2 pinned projects were left alone · 1.2 GB".
    ///
    /// Named by the reason, and the reason is read off the rows rather than assumed. A pin
    /// is the only thing that still withholds a whole project — recent activity produces a
    /// card now — so on any scan this build took, the line says "pinned", which is also
    /// where the user goes to change their mind.
    ///
    /// A mixed or unfamiliar set drops the claim instead of guessing. That is reachable
    /// through the cache rather than through the scanner: a `cache.json` written before
    /// this change holds protected summary rows carrying `.recentActivity`, it is read back
    /// on the next launch, and calling those "pinned" would be a sentence the settings
    /// window contradicts.
    public static func keptProjects(reasons: [ProtectionReason], bytes: Int64) -> String {
        let count = reasons.count
        let allPinned = !reasons.isEmpty && reasons.allSatisfy { $0 == .pinnedProject }
        let subject: String
        if allPinned {
            subject = count == 1
                ? "1 pinned project was left alone"
                : "\(count) pinned projects were left alone"
        } else {
            subject = count == 1
                ? "1 project was left alone"
                : "\(count) projects were left alone"
        }
        return "\(subject) · \(ByteText.short(bytes))"
    }

    /// "38 small things under 50 MB were not shown · 412 MB".
    ///
    /// The total is here because the count on its own invites the question. Thirty-eight
    /// things sounds like a lot of hidden space; 412 MB says it is not, which is the answer
    /// that lets the user stop wondering.
    ///
    /// "things", because the count now mixes projects with scanners: a tidy machine's
    /// simulator caches and a project holding 12 MB of `.dart_tool` are both a card nobody
    /// would want dealt, and splitting them into two lines would make the end card longer
    /// to say less.
    public static func smallThings(count: Int, bytes: Int64) -> String {
        let floor = ByteText.short(ProjectDeck.minimumCardBytes)
        let subject = count == 1
            ? "1 small thing under \(floor) was not shown"
            : "\(count) small things under \(floor) were not shown"
        return "\(subject) · \(ByteText.short(bytes))"
    }

    /// The quiet line on a tool card: "5 kept because they are in use · 13.5 GB".
    ///
    /// A protected row is not on the card's list and is never handed to the engine — the
    /// tool will not touch it — but leaving it out entirely is what makes a user ask where
    /// their 40 GB went. Derived data is the clearest case: 22 folders are offered and 5 are
    /// kept for projects that are still there, and a card that showed 9.1 GB with no
    /// mention of the rest looks like a measurement that disagrees with `du`.
    ///
    /// The reason's own words when every kept row shares one — "4 kept · used by the
    /// simulator you keep" — and a generic clause when they differ. Naming a shared reason
    /// is worth it because it is usually also where the user goes to change their mind; a
    /// mixed set cannot be named without picking one row's reason and printing it over the
    /// others, which is the guess `keptProjects` refuses for the same reason.
    public static func keptRows(reasons: [ProtectionReason], bytes: Int64) -> String {
        let count = reasons.count
        let clause: String
        if Set(reasons.map(\.description)).count == 1, let one = reasons.first {
            // The reason's own words, set off with the same "·" the rest of these lines
            // use. Not "because they are \(description)": the descriptions are written as
            // labels — "newest installed runtime", "most recently used" — and half of them
            // read as broken English after "are".
            clause = "· \(one.description)"
        } else {
            clause = count == 1 ? "because it is in use" : "because they are in use"
        }
        return "\(count) kept \(clause) · \(ByteText.short(bytes))"
    }

    // MARK: the space this app will not take

    /// The heading over the end card's quietest section: "More space to gain".
    ///
    /// Not "Not cleaned" and not "Left alone", which are about what the app did. This
    /// section is for the user: it answers "is there more?" with yes, here is where, and it
    /// is the only place in the window that does. Two scanners' worth of real gigabytes are
    /// measured every scan and dealt no card at all — see `DeckDealing.mentionOnly` — and a
    /// tool that measured 3.2 GB of Brave and then said nothing about it would be a tool
    /// whose totals the user cannot reconcile with `du`.
    public static let moreToGainTitle = "More space to gain"

    /// One line of it: "Brave browsing cache · 3.2 GB".
    ///
    /// The same "name · size" shape as every other quiet line on the end card, so the
    /// section reads as part of the card rather than as a table dropped into it.
    public static func moreToGain(name: String, bytes: Int64) -> String {
        "\(name) · \(ByteText.short(bytes))"
    }

    /// The last line when there are more than the section shows: "and 3 more · 412 MB".
    ///
    /// Six lines and then this, because the section is a footnote and not a screen. What
    /// the fold has to keep is the **total** — a reader who cannot see the seventh line can
    /// still see that the seventh through tenth come to 412 MB, which is what tells them
    /// whether to go looking.
    public static func moreToGainRest(count: Int, bytes: Int64) -> String {
        "and \(count) more · \(ByteText.short(bytes))"
    }

    /// The sentence under the list, and the reason the list is not a list of buttons.
    ///
    /// It has to be true of a browsing cache **and** of `~/Library/Application
    /// Support/Slack/GPUCache`, which is why it does not promise that each app has a "clear
    /// cache" button: the browsers and Slack and Spotify do, and VS Code does not. What is
    /// true of every row here is whose cache it is, and that is also the honest direction to
    /// point somebody in. `ReportText.mentionOnlyNote` says the same thing to the CLI in
    /// that file's own voice.
    ///
    /// "never removes", present tense and absolute: this is not a setting, not a default and
    /// not a tick the user could find. There is no route in the app that reaches these rows.
    public static let moreToGainNote =
        "DevCleaner never removes these. Each one belongs to the app that wrote it, "
        + "and that app is where to clear it."

    /// The end card's line for a scanner that got no card at all because **everything** it
    /// found is in use: "Left alone because they are in use: Android emulators, Android
    /// system images · 12.0 GB".
    ///
    /// Named by scanner rather than counted by row, because that is the question this line
    /// answers. A user who knows they have two emulators and a system image looks for them
    /// in the deck, finds nothing, and needs to be told they were kept — "3 kept because
    /// they are in use" would not tell them which three.
    public static func keptTools(titles: [String], bytes: Int64) -> String {
        let because = titles.count == 1 ? "it is" : "they are"
        return "Left alone because \(because) in use: \(titles.joined(separator: ", ")) "
            + "· \(ByteText.short(bytes))"
    }

    // MARK: before there is a deck at all

    /// "Measuring everything on this Mac…", not "your projects": the deck deals derived
    /// data, the simulators and every tool cache now, and the scan behind this sentence
    /// always measured all of them.
    public static let scanning = "Measuring everything on this Mac…"
    public static let noScanYet = "Nothing has been measured yet."
    public static let scanNow = "Scan now"

    /// The toolbar button beside Settings. "Again", not "now": by the time the titlebar is
    /// on screen with a deck under it something has already been measured, and the button
    /// the empty state offers is `scanNow`.
    public static let scanAgain = "Scan again"

    /// The window's titlebar subtitle: what the app is doing, or when it last measured.
    ///
    /// The one thing a background scan is allowed to change about a deck the user is
    /// reading. It runs unasked, for about 51 seconds, and the card must stay exactly where
    /// it is — so the subtitle is where the scan is reported and the only place it appears.
    ///
    /// Takes the phase rather than a `Bool`, for the reason `StatusPanelModel` does:
    /// reducing the states to "is this a scan" is the decision, and in `DevCleanerApp` a
    /// view that answered it wrong would leave "Scanned 6h ago" over a scan in progress with
    /// nothing in the window saying otherwise.
    public static func windowSubtitle(phase: AppModel.Phase, scanAge: String?) -> String {
        if case .scanning = phase { return scanning }
        // No age means no scan has ever finished, which is the same sentence the empty card
        // in the middle of the window is showing. Saying it twice is better than a blank
        // subtitle beside a window with nothing in it.
        guard let scanAge else { return noScanYet }
        return "Scanned \(scanAge)"
    }
}

// MARK: - a size set large

/// A size split into its numeral and its unit, because the card sets the two at different
/// sizes.
///
/// The card prints "2.9" at 96 points and "GB" at 40, so something has to decide where one
/// ends and the other begins — and `sizeText.components(separatedBy: " ").first` written
/// into a SwiftUI body is a decision no test can read. `ByteText.short` is the only producer
/// of these strings and always writes exactly one space, so this is that construction read
/// backwards rather than a parser for arbitrary input.
///
/// A string with no space at all keeps the whole of itself as the numeral and has no unit.
/// Nothing produces one today; the alternative is a window that draws an empty headline over
/// a real total.
public struct SizeHeadline: Equatable, Sendable {
    /// "2.9" — or the whole string, when there was no unit to split off. On a checklist page
    /// it is what is **ticked**, which is "0" on the page as it is dealt.
    public let number: String
    /// "GB", or `nil`. Always `nil` when `outOf` carries the unit instead.
    public let unit: String?
    /// "of 41.3 GB" — the rest of the quantity the big numeral is a part of, on a checklist
    /// page. `nil` on every other card, where the numeral is the whole of the amount.
    ///
    /// The **unit lives in here** and `unit` is `nil`, which is the whole point of the
    /// headline: the two figures are one quantity, so they share one unit and it is printed
    /// once, at the end. See `init(tickedBytes:of:)`.
    public let outOf: String?
    /// "8.5 GB →" — what the card was holding **before** the run that has just ended, and the
    /// arrow pointing at what is left of it. `nil` on every headline that is not a result.
    ///
    /// Set small and dimmed, in front of the big numeral, so the loud half of the card stays
    /// the half the user is being told about: what is left. The arrow is in here rather than
    /// in the view for the reason on `ProjectDeckText.headlineBefore`.
    ///
    /// The **unit is spelled on both sides** — "8.5 GB → 0 GB" — unlike the checklist page's
    /// two figures, which share one. These two are not a part and its whole: they are the same
    /// thing measured twice, before and after, and "8.5 → 0 GB" reads as one quantity that
    /// shrank rather than as two readings. Both are written in the **before** scale, so a
    /// card that went from 8.5 GB to nothing says "0 GB" and never "0 KB".
    public let before: String?

    /// Whatever goes after the big numeral, set small: the bare unit, or the whole "of 41.3
    /// GB".
    ///
    /// One property rather than two optionals for the view to choose between, because
    /// choosing is a decision: `headline.outOf ?? headline.unit` written into a SwiftUI body
    /// is a decision no test can read, and the two are never both set.
    public var trailingText: String? { outOf ?? unit }

    /// Splits on the **first** space, so a unit that ever grows one of its own arrives whole
    /// instead of cut in half.
    public init(_ sizeText: String) {
        outOf = nil
        before = nil
        guard let space = sizeText.firstIndex(of: " ") else {
            number = sizeText
            unit = nil
            return
        }
        number = String(sizeText[..<space])
        let rest = sizeText[sizeText.index(after: space)...]
        unit = rest.isEmpty ? nil : String(rest)
    }

    /// **The headline after a run: what the card held, an arrow, and what is left of it.**
    ///
    /// "8.5 GB → 0 GB" for a card whose every row went, "8.5 GB → 1.2 GB" for one where a row
    /// was refused. It is the answer to the question the user actually asked of this window —
    /// *did pressing that button do anything?* — and before it existed the card answered by
    /// going back to exactly what it had said beforehand.
    ///
    /// **`after` is written in `before`'s scale**, through the same
    /// `ByteText.short(_:inTheScaleOf:)` the checklist page uses, and for a sharper reason
    /// here: each written in its own scale a card that went from 8.5 GB to nothing would read
    /// "8.5 GB → 0 KB", and a user who has just deleted a simulator runtime does not need a
    /// new unit to parse. A 400 MB remainder reads "0.4 GB", which is the part of the 8.5 it
    /// is.
    ///
    /// **Zero is a plain "0"**, never "0.0", for the reason `init(tickedBytes:of:)` gives: it
    /// is set at 96 points, and a decimal place there is precision about nothing. Its unit
    /// still comes from `before`'s scale, so the two sides of the arrow agree.
    ///
    /// `before` of zero cannot reach here from the deck — a card holding nothing is never
    /// dealt — and if it ever did, both sides simply read in kilobytes, which is what
    /// `ByteText` says about nothing.
    public init(before beforeBytes: Int64, after afterBytes: Int64) {
        outOf = nil
        before = ProjectDeckText.headlineBefore(ByteText.short(beforeBytes))
        // Both sides in one scale, the before's. Split out of `ByteText`'s own output rather
        // than assembled here, so this cannot come to round differently from the headline the
        // card was showing a moment ago.
        let left = SizeHeadline(ByteText.short(afterBytes, inTheScaleOf: beforeBytes))
        number = afterBytes <= 0 ? "0" : left.number
        unit = left.unit
    }

    /// **The checklist page's headline: what is ticked, out of what there is.**
    ///
    /// "0 of 41.3 GB" on the page as it is dealt, and "3.8 of 41.3 GB" once a film is ticked.
    /// The page starts from nothing ticked — these are the user's own films and lesson videos
    /// — so the number a card normally sets large, the amount the button is about, is zero
    /// here until they say otherwise. A bare "0" over a page holding 41.3 GB would look like
    /// a measurement that had failed, so the headline says both: what you have chosen, and
    /// what there is to choose from.
    ///
    /// **One unit, the total's, printed once at the end.** `ByteText.short` would write 582
    /// MB of a 41.3 GB page as "582 MB", and "582 MB of 41.3 GB" is two facts side by side
    /// rather than a part of a whole — at a glance 582 is the bigger number. In the total's
    /// scale it reads "0.6 of 41.3 GB", which is the thing the user is actually being told.
    /// The decimals follow that scale's own rule, so a page whose total is in MB counts in
    /// whole MB.
    ///
    /// Zero is a plain "0" and never "0.0". It is the first thing a user sees on this page
    /// and it is set at 96 points; a decimal place there is precision about nothing.
    ///
    /// `total` is the sum of **every** row on the page and does not move with the ticks —
    /// which is what makes the second figure a fixed thing to measure the first against.
    public init(tickedBytes ticked: Int64, of total: Int64) {
        number = ticked <= 0
            ? "0"
            : SizeHeadline(ByteText.short(ticked, inTheScaleOf: total)).number
        unit = nil
        outOf = ProjectDeckText.headlineRest(of: ByteText.short(total))
        before = nil
    }
}

// MARK: - one folder on a card

/// A folder the card is offering, ready to draw.
///
/// Everything here is already a string, a `Double` or a `Bool`. The bar in particular is a
/// `fraction` and never two sizes to divide: a view that divides is a view deciding what
/// the bars compare against, and no test can reach it there.
public struct ProjectCardFolder: Identifiable, Equatable, Sendable {
    /// `CleanupItem.id`, so the view can match a folder to the row the engine is reporting
    /// progress for.
    public let id: String
    /// What this row is called.
    ///
    /// On a project card, the path relative to the project — `ios/Pods`, `.build-cows`,
    /// `.claude/worktrees/feature-sync/build`. Relative and not just the last component,
    /// because `ios/Pods` and `macos/Pods` are two different folders and `Pods` twice
    /// would be a card the user cannot read.
    ///
    /// On a tool card, the row's own name as its scanner wrote it — except derived data,
    /// whose folder names carry 28 letters of Xcode hash: see
    /// `ProjectDeckText.derivedDataName`.
    public let name: String
    public let sizeBytes: Int64
    public let sizeText: String
    /// `0...1` against the biggest folder on **this** card.
    ///
    /// Per card, deliberately. Only one card is on screen at a time, so there is no
    /// cross-card comparison for the eye to make; scaled against the whole deck instead, a
    /// tidy project's rows would all be hairlines because some other project has 12 GB in it.
    public let fraction: Double
    /// How this row comes back, in one line beside it.
    ///
    /// On a project card, one of four sentences chosen by the folder's name — see
    /// `ProjectDeckText.restoreHint`. On a tool card, the row's own `detail`, which its
    /// scanner already wrote for `devcleaner scan`: "re-downloaded on the next npm
    /// install", "its project folder is gone", "deleting it destroys the device and every
    /// app installed in it". Those are better than anything this file could invent, because
    /// they are specific to the row rather than to its scanner.
    ///
    /// Empty only for a row whose scanner wrote no detail at all. `""` rather than `nil`
    /// because nothing on the card depends on the difference: the view draws the string it
    /// is given, and an absent hint is an absent hint.
    public let restoreHint: String
    /// It does **not** simply come back from a local rebuild — `risk != .safe`.
    ///
    /// The one thing on the card that changes the answer: a user about to board a plane
    /// minds `ios/Pods` going and does not mind `.build` going. It is what the view paints
    /// the row's bar in the amber token for, and it now covers `.irreplaceable` as well as
    /// `.elevated` — painting one of the user's own files in the blue that means "the next
    /// build remakes it" would be the colour contradicting the sentence beside it.
    public let needsDownload: Bool
    /// Whether this row's box is ticked, or `nil` on a card whose rows have no box.
    ///
    /// Three states rather than two, and the third is why it is optional: a view that drew a
    /// box for `false` would put an empty checkbox beside every folder of every project card
    /// in the deck. `nil` means "this row is not a choice", which is every card but the
    /// checklist page.
    public let isTicked: Bool?
    /// What the row's reveal button and its "Show in Finder" menu item both reveal, or `nil`
    /// when there is nothing to go and look at.
    ///
    /// Only a checklist page's rows carry one. `ProjectCard.revealURL` is the same
    /// affordance on a card that *is* one file; here the card is a list of the user's own
    /// files, so "is this the archive I still need?" is a question asked per row.
    ///
    /// The URL alone. `reveal` below is this plus the words, which is what the two controls
    /// are actually built from.
    public let revealURL: URL?
    /// Which of the run's per-item reports is about this row, or `nil` when the row is not
    /// handed over at all.
    ///
    /// The drain animation's index, stored rather than taken to be the row's position on the
    /// card, because on a checklist page the two part company. `ProjectCard.items` is what
    /// Clean up hands the engine and the executor reports against that list, so row 5 of the
    /// page can be row 2 of the run — and an unticked row is in no run at all, which is
    /// exactly what `nil` says and why such a row never drains.
    public let runIndex: Int?
    /// The reveal button at this row's trailing edge: where it goes and what it is called.
    ///
    /// `nil` on every row with nowhere to go, which is every row of every other card — so the
    /// button appears exactly where `revealURL` does.
    ///
    /// The URL, the tooltip and the accessibility label as one value, the same shape as
    /// `ProjectCard.ChecklistSelectAll` and for the same reason: three things a view could
    /// otherwise assemble separately, where a button labelled for one file and pointed at
    /// another is a mistake nothing downstream could catch.
    ///
    /// **A button as well as the context menu, because the user opens these in Finder a lot.**
    /// It is how the page is answered at all — "is this the lesson video I still need?" is a
    /// question only looking can settle — and a right-click then a menu item is two gestures
    /// for the one thing this page asks the user to do most.
    public var reveal: Reveal? {
        revealURL.map {
            Reveal(url: $0,
                   help: ProjectDeckText.showInFinder,
                   accessibilityLabel: ProjectDeckText.showInFinder(name))
        }
    }

    /// What that button does and what it is called.
    public struct Reveal: Equatable, Sendable {
        /// The file Finder selects — `ProjectCardFolder.revealURL`, built against the home the
        /// rest of the app measured.
        public let url: URL
        /// The tooltip: `ProjectDeckText.showInFinder`, the same words as the menu item it
        /// duplicates.
        public let help: String
        /// "Show cards.db in Finder" — the label for somebody who cannot see which row the
        /// button is on.
        public let accessibilityLabel: String

        public init(url: URL, help: String, accessibilityLabel: String) {
            self.url = url
            self.help = help
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// The whole of this row's one line of explanation, for hovering. `restoreHint` unless
    /// something says otherwise.
    ///
    /// A checklist page overrides it with the file's own path. The row shows the folder the
    /// file sits in, middle-truncated to fit the bar, and what a user hovering wants is the
    /// part that was cut plus the file name — which together are the path.
    public let helpText: String

    public init(
        id: String, name: String, sizeBytes: Int64, sizeText: String,
        fraction: Double, restoreHint: String, needsDownload: Bool, runIndex: Int?,
        isTicked: Bool? = nil, revealURL: URL? = nil, helpText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.sizeText = sizeText
        self.fraction = fraction
        self.restoreHint = restoreHint
        self.needsDownload = needsDownload
        self.runIndex = runIndex
        self.isTicked = isTicked
        self.revealURL = revealURL
        // Defaulted from the hint rather than left empty, so the only rows whose tooltip
        // differs from their visible line are the ones that asked for it.
        self.helpText = helpText ?? restoreHint
    }

    /// From a scanned row, given the biggest row on the same card.
    ///
    /// `widest` travels in one direction and is not stored, so nothing below can recover
    /// it, re-derive it, or quietly scale against something else.
    ///
    /// The kind decides two things and nothing else: what the row is called, and where its
    /// one line of explanation comes from. A project's folder is named by its path inside
    /// the project and explained by a table of four sentences; a tool's row is named by its
    /// scanner and explained by the scanner's own `detail`.
    init(item: CleanupItem, widest: Int64, kind: ProjectCard.Kind, runIndex: Int?) {
        let name: String
        let hint: String
        switch kind {
        case .project:
            name = item.name
            hint = ProjectDeckText.restoreHint(forFolderNamed: item.name)
        // `.interstitial` never reaches here — that card has no rows at all — and shares
        // this branch rather than being given one of its own, because a branch nothing can
        // run is a branch no test can check.
        case .tool, .bigThing, .interstitial:
            name = ProjectDeckText.rowName(of: item)
            hint = item.detail ?? ""
        }
        self.init(
            id: item.id, name: name, sizeBytes: item.sizeBytes,
            sizeText: ByteText.short(item.sizeBytes),
            fraction: Self.fraction(item.sizeBytes, of: widest),
            restoreHint: hint,
            needsDownload: item.risk != .safe,
            runIndex: runIndex)
    }

    /// One file on a checklist page.
    ///
    /// Its own initialiser rather than a flag on the one above, because every one of the
    /// four things it decides differs. The name is the file's own — two rows can share it,
    /// which is the whole reason the line beside it exists. That line is the row's `detail`,
    /// the `~`-abbreviated folder the file sits in, which is what tells a `scan.pdf` in one
    /// project from a `scan.pdf` in another; it is the scanner's own string rather than
    /// anything derived here. The tooltip is the path, and there is a Finder button, because
    /// this is the one kind of row where looking first is the reasonable thing to do.
    init(
        checklistItem item: CleanupItem, widest: Int64, isTicked: Bool, runIndex: Int?,
        reporter: ReportText
    ) {
        let path = item.method.path
        self.init(
            id: item.id, name: item.name, sizeBytes: item.sizeBytes,
            sizeText: ByteText.short(item.sizeBytes),
            fraction: Self.fraction(item.sizeBytes, of: widest),
            restoreHint: item.detail ?? "",
            // Always true on this page — every row is `.irreplaceable` — so the bar is
            // painted in the amber that means "not from here it doesn't". Read off the row's
            // own risk all the same, so the colour cannot disagree with the executor's rule.
            needsDownload: item.risk != .safe,
            runIndex: runIndex,
            isTicked: isTicked,
            revealURL: path.map { URL(fileURLWithPath: $0) },
            // Abbreviated against the same home as every other path in this window, so the
            // tooltip reads as the row's own line with the file name added rather than as a
            // second way of spelling a location. `nil` falls back to the visible line, which
            // is the honest answer for a row with no path at all.
            helpText: path.map { reporter.abbreviate($0) })
    }

    /// `0...1`, and `0` on a card whose biggest folder is zero bytes.
    ///
    /// The guard is reachable: a machine where `du` measured nothing still produces real
    /// rows, all of them 0 bytes. Without it every bar on such a card is `nan`, which
    /// SwiftUI draws at whatever width it likes.
    static func fraction(_ bytes: Int64, of widest: Int64) -> Double {
        guard widest > 0 else { return 0 }
        return Double(bytes) / Double(widest)
    }
}

// MARK: - one card

/// One question the deck asks: a dev project, or one scanner's worth of caches.
///
/// Named `ProjectCard` for its first and still most delicate case. The name is historical
/// — the deck deals derived data and simulators as well now — and renaming it would churn
/// the view, the model and four test files for nothing this pass needs. `kind` is what says
/// which sort of card this is, and every difference between them is already resolved into
/// the strings and flags below.
public struct ProjectCard: Identifiable, Equatable, Sendable {
    /// What this card is about, and the only thing downstream ever branches on.
    ///
    /// A project is grouped by its **directory**; a tool card is one whole scanner, never a
    /// `GroupID`. Grouping by group would mix derived data, which the next build remakes,
    /// with simulators, which `simctl delete` destroys outright — one card, one promise
    /// line, and no way to write it truthfully.
    public enum Kind: Equatable, Sendable {
        case project
        case tool(scannerID: String)
        /// One of the user's own large files: a row of `GroupID.bigThings`.
        ///
        /// Its own case rather than a flag beside `.tool`, because everything about the card
        /// differs — where it sits in the deck, what its button says, whether Return
        /// answers it, what colour its bar in the skyline goes when it is cleaned, and the
        /// promise above the buttons — and a `Bool` that has to be read together with
        /// `.tool` to mean anything is a `Bool` somebody will read on its own.
        case bigThing(scannerID: String)
        /// The card between the two halves of the deck: see
        /// `ProjectDeck.interstitialCardID`.
        ///
        /// It holds no rows and cleans nothing. It is a `ProjectCard` all the same, because
        /// the alternative is a second kind of thing for the window to draw and a second
        /// state machine for the model to advance — and everything the deck already does
        /// for a card is what this one needs: a settle window, a decision recorded so it is
        /// not dealt twice, and the card shell it is drawn in.
        case interstitial

        /// Whether this is one of the user's own files. Read off the case, so there is one
        /// answer to the question.
        public var isBigThing: Bool {
            if case .bigThing = self { return true }
            return false
        }

        public var isInterstitial: Bool { self == .interstitial }
    }

    /// Which of the deck's two colours the primary button asks for.
    ///
    /// Until now every primary button in the window was the same blue, and in this app's
    /// palette that blue has a meaning: it is `DeckStyle.rebuild`, the colour a row's bar
    /// goes when the next build remakes it. So "Delete 21.4 GB for good" and "Move 23.1 GB
    /// to Trash" were being drawn in the colour that says *this comes back by itself*,
    /// beside rows painted amber for saying the opposite. The words on those buttons were
    /// right and the colour was contradicting them.
    public enum PrimaryActionTone: Equatable, Sendable {
        /// `DeckStyle.rebuild` — blue. The press is reversible or free, and the user has
        /// been taught by nine cards in a row that it is.
        case regenerable
        /// `DeckStyle.download` — amber. **Read the card before pressing this.**
        ///
        /// Not "does not come back", although that is what it means on most of these
        /// cards. It also covers the folder in `~/.cache` whose tool the app cannot name,
        /// which probably does come back — what those cards share is not a promise about
        /// the bytes but the fact that the user has to mean it.
        case deliberate
    }

    public let kind: Kind
    /// The project's directory, or the scanner's identifier. The card's identity across
    /// scans, across a prune, and across the session's decisions — which is why a project's
    /// is the path and not a name or an index: two projects can share a name, and an index
    /// changes the moment a row is pruned out from under it. A scanner identifier cannot
    /// collide with a path, so one deck can hold both.
    public let id: String
    /// The small line over the title: "Project", or the group — "Xcode & iOS", "Android".
    ///
    /// It is what lets the position counter drop its noun. A card has to say what sort of
    /// thing it is, because the deck mixes them, and the group is the answer the engine's own
    /// listing has always given for the same rows.
    public let eyebrow: String
    /// The project folder's name as the user knows it ("Sample Game - iOS"), or the
    /// scanner's own title ("Derived data", "iOS simulators").
    public let name: String
    /// Where it is: `~/dev/Sample Game - iOS`, or the directory a tool card's rows sit
    /// in — `~/Library/Developer/Xcode/DerivedData`. Abbreviated here, never in the view, by
    /// `ReportText`, so the window and `devcleaner scan` shorten a path the same way.
    ///
    /// `nil` when there is no one place to name. A simulator card has no path at all —
    /// `simctl` owns the devices — and a card whose rows are scattered across `~/.npm`,
    /// `~/Library/Caches` and `~/.bun` has no common directory worth printing. Saying "~"
    /// there would be a location line that locates nothing.
    public let pathText: String?
    /// "last changed 4 months ago", or `nil` when the scan could not date the project.
    ///
    /// `nil` rather than a guess. `ActivityInspector` answers nothing for a project it can
    /// date neither from a file nor from git, and "last changed today" would be the worst
    /// possible substitute: it is the reading that most strongly says do not clean this.
    ///
    /// Always `nil` on a tool card: a cache's modification date says when a build last ran,
    /// which is not a fact about anything the user recognises.
    public let lastChangedText: String?
    /// Biggest first, ties broken by identifier.
    public let folders: [ProjectCardFolder]
    public let totalBytes: Int64
    public let totalText: String
    /// "in 8 folders that rebuild themselves", or "in 16 items".
    public let folderCountText: String
    /// The lines that make this card's offer honest, none to two of them.
    ///
    /// Three sentences can appear here and they are about different things: the project the
    /// user has been working in this fortnight (`ProjectDeckText.caution(for:)`), the card
    /// that removes something for good (`permanentCaution`), and the rows a normal clean
    /// leaves alone (`untickedCaution`). Two can be true at once — an unticked row on a
    /// card that deletes for good — and collapsing them into one line would drop whichever
    /// was written second.
    ///
    /// Empty rather than a blank line, so the card's heading does not change height between
    /// cards.
    public let cautionLines: [String]
    /// "5 kept · used by the simulator you keep · 13.5 GB", or `nil`.
    ///
    /// The rows this card is **not** offering, because something is holding them back. They
    /// are not in `items` and never reach the engine; they are here because a card showing
    /// 9.1 GB of derived data while `du` says 13.5 GB looks like a measurement that cannot
    /// be trusted.
    public let keptText: String?
    /// The line above the buttons: what the user is promised before they press.
    ///
    /// On the card rather than on the session's summary, because it is now a fact about
    /// **this** card. Three cards in one deck can need three different sentences — a
    /// project's code stays, a tool card only touches what it lists, and a simulator card
    /// is quoting the engine's own warning that nothing comes back — and a summary that
    /// knew only the Trash setting could not tell them apart.
    public let promiseText: String
    /// What the primary button says: "Clean up 9.1 GB", "Delete 21.4 GB for good",
    /// "Move 7.0 GB to Trash", or "Look through them".
    public let primaryActionTitle: String
    /// What the button beside it says. "Skip" on every card but the interstitial, whose
    /// secondary answers for the whole second half of the deck — "Skip them all".
    ///
    /// On the card rather than fixed in the view, for the same reason the primary title is:
    /// a button whose label says it skips one thing and whose press skips fourteen is the
    /// kind of mismatch only the model can be held to.
    public let secondaryActionTitle: String
    /// The glyph after the **secondary** button's title, or `nil` on a card whose secondary
    /// answers to no key.
    ///
    /// Decided here rather than printed by the view, which is what let the bug in: the "→"
    /// was a literal beside a hard-coded `.keyboardShortcut(.rightArrow)`, so both survived
    /// unchanged onto the one card where that button means something else entirely.
    public let secondaryActionKeyHint: String?
    /// Whether the bare right arrow presses the secondary button.
    ///
    /// True on every ordinary card. Skipping one thing costs nothing and the deck is meant
    /// to be flicked through, which is why the arrow carries no modifier.
    ///
    /// **False on the interstitial**, whose secondary is not a skip of one card but of the
    /// whole second half of the deck. With the key bound in the view it kept its binding
    /// while its meaning changed underneath it: a held arrow flicked through the regenerable
    /// half, reached the interstitial and answered "Skip them all" on the next repeat —
    /// every one of the user's own files skipped unread, which is the one set of cards that
    /// exists to be read. The interstitial keeps Return for "Look through them", so it is
    /// still answerable from the keyboard; what it no longer has is a key that can be held
    /// down through it.
    public let secondaryAnswersToArrow: Bool
    /// The glyph after that title, or `nil` on a card with no key bound to it.
    ///
    /// It is a promise about the keyboard, so it is decided with the shortcut rather than
    /// beside it. A "⏎" printed on a button that does not answer to Return teaches the user
    /// a key that does nothing; worse, the same glyph left on every card would teach them
    /// that Return is safe everywhere, which is the habit `answersToReturn` exists to break.
    public let primaryActionKeyHint: String?
    /// Whether Return presses this card's primary button.
    ///
    /// `false` exactly when the card holds a row the engine cannot undo **whatever the
    /// settings say** — a row with no path, which is the simulators, the runtimes and the
    /// emulators. Return is the window's default action, so nine reversible cards in a row
    /// train the user's hand; the tenth card can destroy sixteen simulators with every app
    /// installed in them, and that one has to be clicked.
    ///
    /// A user who turned the Trash off is **not** treated the same way, deliberately. That
    /// setting applies to every card in the deck, so taking the key away would leave the
    /// whole window unanswerable by keyboard for the person who asked for it; it is
    /// reversible in settings; and the card already says what it does — the promise line in
    /// that mode reads "deleted — for good". What this flag is for is the card that ignores
    /// the setting.
    ///
    /// Skip keeps its arrow key everywhere — skipping costs nothing.
    public let answersToReturn: Bool
    /// Exactly what Clean hands to the engine, **in the same order as `folders`**.
    ///
    /// One item per folder, same order, so the view can drain row *i* when
    /// `ExecutionProgress.completed > i`. The executor works through the list it is given
    /// one at a time and reports per item, so the order is what makes the progress on
    /// screen the real progress rather than an animation on a timer.
    ///
    /// A protected row is never in here, whichever kind of card it is.
    ///
    /// **Empty on the interstitial**, which cleans nothing, and **empty on a checklist page
    /// until something is ticked** — the rows it is drawing wait in `checklistItems`.
    /// `AppModel`'s own guard refuses an empty list rather than handing the engine one, so a
    /// press on the page before anything is chosen is refused by the model as well as being
    /// dead in the window.
    public let items: [CleanupItem]
    /// What "Show in Finder" would reveal, or `nil` on a card with no such button.
    ///
    /// Only a big thing has one. Every other card is a folder a tool wrote that the user
    /// has never opened and has no reason to look inside; this one is a file they chose to
    /// have, and "is this the archive I still need?" is a question only Finder answers.
    ///
    /// A `URL` rather than a path, so the decision — which file, built against which home —
    /// is taken here where a test can read it rather than assembled in a SwiftUI body.
    public let revealURL: URL?
    /// Whether this card's rows carry checkboxes: `DeckDealing.checklist`.
    ///
    /// The page `big.largeFiles` is dealt as. It is a **big thing** as well — `kind` is
    /// `.bigThing`, so it sits behind the interstitial, its button is amber, it answers to no
    /// key and its wording always names the Trash — and what this flag adds on top is only
    /// the boxes, plus every number on the card following them.
    ///
    /// One card for fifty unrelated files, because neither alternative works: fifty cards is
    /// a deck nobody finishes, and one all-or-nothing button is a press over somebody's
    /// lesson videos and their test fixtures at once. The user asked for exactly this shape.
    ///
    /// And it opens with **nothing** ticked, which is the one other thing that makes it
    /// different from every card in the deck: those offer something and ask yes or no, where
    /// this one offers nothing and is built up a file at a time. `items`,
    /// `isPrimaryActionEnabled`, `primaryActionTitle`, `folderCountText` and `totalHeadline`
    /// all follow from that.
    public let isChecklist: Bool
    /// Whether the primary button can be pressed at all, leaving aside whatever the app is
    /// busy with.
    ///
    /// `false` only on a checklist page with every box clear — **which is now the state it is
    /// dealt in** — where `primaryActionTitle` reads "Tick the files to move to the Trash"
    /// rather than naming an amount. The two travel together: a live button carrying that
    /// instruction and a dead one saying "Move 0 KB to Trash" are each worse than the pair,
    /// and only this type can keep them in step.
    ///
    /// The window ANDs it with `AppModel.isBusy`, which answers a different question — "can
    /// anything be pressed just now" — and the note above the buttons is what explains that
    /// one.
    public let isPrimaryActionEnabled: Bool
    /// Every row a checklist page could hand over, ticked or not: the list `applyingTicks`
    /// picks from. Empty on every other card, where `items` is that list.
    ///
    /// A second list rather than leaving all the rows in `items`, and the reason is the whole
    /// safety of the page. `items` is **exactly what Clean up hands the engine**, and the
    /// page is now dealt with nothing ticked — so on the dealt card `items` is empty, and the
    /// only way a file gets into it is the user ticking it. Had the dealt card kept every row
    /// in `items` instead, with only the title and the dead button saying otherwise, then any
    /// route that reached the memoised deck without going through `applyingTicks` would be a
    /// press offering to move every film on the disk. This way round the failure mode is a
    /// page that does nothing.
    ///
    /// Biggest first, ties by identifier, in step with `folders` — which is what makes the
    /// filtered list arrive at the executor in the order the user is reading.
    public let checklistItems: [CleanupItem]
    /// The text button over a checklist page's rows, or `nil` on every other card.
    public let checklistSelectAll: ChecklistSelectAll?

    /// What that button says and what it does, as one value.
    ///
    /// Together for the same reason `primaryActionKeyHint` is decided beside
    /// `answersToReturn`: a control labelled "Select none" that ticks everything is a
    /// mismatch nothing downstream could catch.
    public struct ChecklistSelectAll: Equatable, Sendable {
        /// `ProjectDeckText.selectAll` or `ProjectDeckText.selectNone`.
        public let title: String
        /// Whether pressing it ticks every row or clears every row.
        public let ticksEverything: Bool

        public init(title: String, ticksEverything: Bool) {
            self.title = title
            self.ticksEverything = ticksEverything
        }

        /// The button for a page in this state: the way to the extreme the user is **not**
        /// already at.
        ///
        /// An empty page — which is how it is dealt — offers "Select all", because the bulk
        /// move worth having there is "tick them all, then clear the two I want to keep". The
        /// moment everything is ticked it offers "Select none", the way back. So either
        /// extreme is at most two presses from anywhere, with one control to read.
        static func forPage(allTicked: Bool) -> ChecklistSelectAll {
            ChecklistSelectAll(
                title: allTicked ? ProjectDeckText.selectNone : ProjectDeckText.selectAll,
                ticksEverything: !allTicked)
        }
    }

    public init(
        kind: Kind = .project, id: String, eyebrow: String = ProjectDeckText.projectEyebrow,
        name: String, pathText: String?, lastChangedText: String?,
        folders: [ProjectCardFolder], totalBytes: Int64, totalText: String,
        folderCountText: String, cautionLines: [String] = [], keptText: String? = nil,
        promiseText: String, primaryActionTitle: String,
        secondaryActionTitle: String = ProjectDeckText.skip,
        primaryActionKeyHint: String? = ProjectDeckText.cleanUpKeyHint,
        secondaryActionKeyHint: String? = ProjectDeckText.skipKeyHint,
        answersToReturn: Bool = true, secondaryAnswersToArrow: Bool = true,
        items: [CleanupItem], revealURL: URL? = nil,
        isChecklist: Bool = false, isPrimaryActionEnabled: Bool = true,
        checklistItems: [CleanupItem] = [],
        checklistSelectAll: ChecklistSelectAll? = nil
    ) {
        self.kind = kind
        self.id = id
        self.eyebrow = eyebrow
        self.name = name
        self.pathText = pathText
        self.lastChangedText = lastChangedText
        self.folders = folders
        self.totalBytes = totalBytes
        self.totalText = totalText
        self.folderCountText = folderCountText
        self.cautionLines = cautionLines
        self.keptText = keptText
        self.promiseText = promiseText
        self.primaryActionTitle = primaryActionTitle
        self.secondaryActionTitle = secondaryActionTitle
        self.primaryActionKeyHint = primaryActionKeyHint
        self.secondaryActionKeyHint = secondaryActionKeyHint
        self.answersToReturn = answersToReturn
        self.secondaryAnswersToArrow = secondaryAnswersToArrow
        self.items = items
        self.revealURL = revealURL
        self.isChecklist = isChecklist
        self.isPrimaryActionEnabled = isPrimaryActionEnabled
        self.checklistItems = checklistItems
        self.checklistSelectAll = checklistSelectAll
    }

    /// The same card with the user's ticks applied — the card the window really draws.
    ///
    /// **The ticks are deliberately not in the memoised deck.** `AppModel.projectDeck`
    /// builds one deck per applied scan and holds it — a couple of hundred rows grouped,
    /// sorted, sized and phrased — and a tick changes what this card shows without the scan
    /// changing at all. Dropping the memo on every click would rebuild the whole deck each
    /// time a box is pressed, and, worse, it would make the memo's correctness depend on
    /// remembering to clear it from a second place. So the built deck holds the page in the
    /// shape it is dealt in — **nothing ticked**, which is where the user asked it to start —
    /// and this pure function derives every other state of it from `checklistItems`.
    /// `AppModel.sessionCards` is the one caller; `AppModel.deckSlots` deliberately is not,
    /// because a slot remembers what the card was **holding** and the skyline must not be
    /// empty until boxes are ticked.
    ///
    /// **The empty set is the page as dealt**, which is what makes the whole arrangement
    /// fail-safe: the card in the memo hands the engine nothing, and a row only ever gets
    /// into `items` by being named here. When this held the absences instead, a deck read
    /// without them was a deck offering to move every film on the disk.
    ///
    /// `self` unchanged for every other kind of card. Nothing else has boxes, and a set that
    /// somehow named one of their rows must not be able to change the list Clean up hands the
    /// engine — in either direction.
    ///
    /// `totalBytes` is left alone as well, and it is the second figure in the headline: it is
    /// the sum of every row on the page, so it is what the ticked amount is measured against
    /// and it must not move as the ticks do. `fraction` is left alone for the same kind of
    /// reason — the bars stay scaled against the biggest file on the page, so ticking one
    /// does not silently rescale the rest.
    public func applyingTicks(tickedIDs: Set<String>) -> ProjectCard {
        guard isChecklist else { return self }
        let ticked = { (id: String) in tickedIDs.contains(id) }
        // The run index counts only the rows that are handed over, in display order, so it
        // is the position the executor will report each of them at. An unticked row gets
        // `nil` and never drains: it is in no run.
        var runIndex = 0
        let rows = folders.map { folder -> ProjectCardFolder in
            guard ticked(folder.id) else {
                return ProjectCardFolder(
                    id: folder.id, name: folder.name, sizeBytes: folder.sizeBytes,
                    sizeText: folder.sizeText, fraction: folder.fraction,
                    restoreHint: folder.restoreHint, needsDownload: folder.needsDownload,
                    runIndex: nil, isTicked: false, revealURL: folder.revealURL,
                    helpText: folder.helpText)
            }
            defer { runIndex += 1 }
            return ProjectCardFolder(
                id: folder.id, name: folder.name, sizeBytes: folder.sizeBytes,
                sizeText: folder.sizeText, fraction: folder.fraction,
                restoreHint: folder.restoreHint, needsDownload: folder.needsDownload,
                runIndex: runIndex, isTicked: true, revealURL: folder.revealURL,
                helpText: folder.helpText)
        }
        // **In display order, and nothing else.** `checklistItems` is already biggest first
        // and this filter keeps that order, so the executor works through the page top-down
        // and each report names the row the user can watch drain.
        let handedOver = checklistItems.filter { ticked($0.id) }
        // `ScanResult.totalBytes`, like every other total in this app, so the figure over
        // the button is added up by the same rule as the CLI's headline.
        let tickedText = ByteText.short(ScanResult.totalBytes(of: handedOver))
        return ProjectCard(
            kind: kind, id: id, eyebrow: eyebrow, name: name, pathText: pathText,
            lastChangedText: lastChangedText, folders: rows,
            totalBytes: totalBytes, totalText: totalText,
            folderCountText: ProjectDeckText.checklistCount(
                ticked: handedOver.count, of: folders.count),
            cautionLines: cautionLines, keptText: keptText, promiseText: promiseText,
            // The button names what it is about to move — the **ticked** sum, in its own
            // scale, because that is what the press does — and says what to do instead when
            // that is nothing.
            primaryActionTitle: handedOver.isEmpty
                ? ProjectDeckText.nothingTicked
                : ProjectDeckText.moveToTrash(tickedText),
            secondaryActionTitle: secondaryActionTitle,
            primaryActionKeyHint: primaryActionKeyHint,
            secondaryActionKeyHint: secondaryActionKeyHint,
            answersToReturn: answersToReturn,
            secondaryAnswersToArrow: secondaryAnswersToArrow,
            items: handedOver, revealURL: revealURL, isChecklist: true,
            isPrimaryActionEnabled: !handedOver.isEmpty,
            checklistItems: checklistItems,
            checklistSelectAll: ChecklistSelectAll.forPage(
                allTicked: handedOver.count == folders.count))
    }

    /// **Amber exactly when the button has to be clicked**, blue otherwise.
    ///
    /// Derived from `answersToReturn` rather than stored beside it, and that is the whole
    /// design of this property. The two say the same thing about a card — "the user has to
    /// mean this one" — and they are the same thing said to two different senses: the key
    /// is taken away and the colour changes. Stored separately they would be two decisions
    /// to keep in step, and the card that lost its Return key without changing colour would
    /// be the worst of both: a button that looks like the nine safe ones and does not answer
    /// the key the user has been pressing.
    ///
    /// So every card that is click-only today is amber — the permanent deletions, the user's
    /// own files, and the `~/.cache` folder whose tool the app cannot name — and the
    /// interstitial, whose "Look through them" deletes nothing and does answer Return, stays
    /// blue. Any card that is made click-only in future is amber the same day.
    public var primaryActionTone: PrimaryActionTone {
        answersToReturn ? .regenerable : .deliberate
    }

    /// Whether this is one of the user's own files. Forwarded from `kind` so a caller never
    /// has to unwrap a case to ask.
    public var isBigThing: Bool { kind.isBigThing }
    /// Whether this is the card between the two halves of the deck.
    public var isInterstitial: Bool { kind.isInterstitial }

    /// Builds a card from one project's rows.
    ///
    /// The name is the **project directory's** last component, and deliberately not
    /// `CleanupItem.detail`. `detail` is the CLI's own line for the row, so when
    /// something is holding a row back it carries the reason too — "Sample Game · changed in
    /// the last 14 days" — and that whole string would arrive here as a 26-point heading.
    /// The directory is the same name without the freight, and it cannot go stale: it is
    /// the folder the path names.
    init(
        directory: String, rows: [CleanupItem],
        totalBytes: Int64, reporter: ReportText, now: Date, moveToTrash: Bool
    ) {
        // Biggest first, ties broken by identifier — the order every list in this app is
        // sorted in, and `items` is sorted with it rather than separately, because the two
        // being the same order is a promise the view acts on.
        let ordered = rows.sorted(by: ProjectDeck.byDescendingSize)
        let widest = ordered.first?.sizeBytes ?? 0
        let totalText = ByteText.short(totalBytes)
        self.init(
            kind: .project,
            id: directory,
            eyebrow: ProjectDeckText.projectEyebrow,
            name: (directory as NSString).lastPathComponent,
            pathText: reporter.abbreviate(directory),
            lastChangedText: ordered.compactMap(\.lastUsed).max()
                .map { ProjectDeckText.lastChanged($0, now: now) },
            // Every row is handed over, so each one's run index is its place on the card —
            // which is what makes the bars drain top-down as the engine works through them.
            folders: ordered.enumerated().map {
                ProjectCardFolder(
                    item: $1, widest: widest, kind: .project, runIndex: $0)
            },
            totalBytes: totalBytes,
            totalText: totalText,
            // `risk != .safe`, the same test `ProjectCardFolder.needsDownload` makes, so
            // the heading and the rows under it cannot disagree about whether this card's
            // folders rebuild themselves. No project row is ever `.irreplaceable`, so the
            // two spellings pick out the same rows today.
            folderCountText: ProjectDeckText.folderCount(
                ordered.count, needsDownload: ordered.contains { $0.risk != .safe }),
            // The first reason any of the folders carries, in card order. Every folder of
            // one project is held back by the same owner in practice — the reason comes
            // from the directory that covers them — so "the first" is "the project's", and
            // taking the biggest folder's is the one choice that cannot pick a reason the
            // user is not being shown a folder for.
            cautionLines: ordered.compactMap(\.untickedReason).first
                .map { [ProjectDeckText.caution(for: $0)] } ?? [],
            promiseText: ProjectDeckText.promise(moveToTrash: moveToTrash),
            primaryActionTitle: ProjectDeckText.cleanUp(totalText),
            items: ordered)
    }

    /// Builds a card from one scanner's rows.
    ///
    /// Everything that makes this card different from a project's is decided here, in one
    /// place, and every one of those decisions is read off the rows rather than off the
    /// scanner's identifier. A card deletes for good because its rows have no path — which
    /// is exactly the three device cases, and exactly what the executor branches on — never
    /// because this file happens to know that `ios.simulators` is a device scanner. The two
    /// could not drift apart, and the card whose Return key is taken away is the card the
    /// engine really cannot undo.
    ///
    /// `kept` are the rows nothing is offering. They are not in `items`, so nothing can
    /// reach the engine from here.
    init(
        scanner: CleanerService.ScannerInfo?, scannerID: String,
        rows: [CleanupItem], kept: [CleanupItem],
        totalBytes: Int64, reporter: ReportText, moveToTrash: Bool
    ) {
        let ordered = rows.sorted(by: ProjectDeck.byDescendingSize)
        let widest = ordered.first?.sizeBytes ?? 0
        let totalText = ByteText.short(totalBytes)
        // `method.path == nil` is exactly the three device cases — see `DeletionMethod.path`
        // — and `CleanerService.warnings` splits on the same test, so the deck's caution and
        // the engine's warning are about the same rows.
        let deletesForGood = ordered.contains { $0.method.path == nil }
        // Read off the **rows themselves**, never off a list of big-things scanners kept in
        // this file — the same rule as `deletesForGood` above, and for a sharper reason.
        // A `cache.json` a **newer** build wrote can hold a big-things scanner this one has
        // never heard of: `scanner(withID:)` answers `nil` for it, so its `DeckDealing` is
        // unknown and it falls back to one grouped card — and without this test that card
        // would be sorted in among the caches, promised "deleted — for good" in permanent
        // mode about files the executor is going to trash, and answerable by the Return key
        // the user has been pressing.
        //
        // **Either spelling is enough**, and that is the hardening the review asked for. The
        // group is the deck's own filing of a row; `risk == .irreplaceable` is what the
        // executor really keys its always-Trash rule on — see
        // `CleanupItem.goesToTheTrash(moveToTrash:)`. Read from the group alone, an
        // irreplaceable row filed under any other group would get an ordinary blue card with
        // a Return key and a promise that it is deleted for good, about a file that is going
        // to be sitting in the Trash. The two cannot be allowed to disagree, so the card is
        // a big thing if **either** says so.
        let isBigThing = ordered.contains { $0.group == .bigThings || $0.risk == .irreplaceable }
        // One page for the scanner, with a box per row: `DeckDealing.checklist`. Asked of
        // the scanner rather than derived from the rows, because it is the scanner's own
        // declaration and a row does not carry it. A cached scan naming a checklist scanner
        // this build does not know falls back to the ordinary grouped big-thing card above —
        // one all-or-nothing button, still amber, still click-only, still promising the
        // Trash. Less use than the page, and safe.
        let isChecklist = scanner?.dealing == .checklist

        var cautions: [String] = []
        if deletesForGood { cautions.append(ProjectDeckText.permanentCaution) }
        // Permanence first when a card somehow holds both: it is the stronger claim, and
        // both readings take the Return key away, so the card is click-only either way.
        //
        // Singular or plural by the count, because this card can now be a page of fifty
        // files as easily as the one-row fallback: "These do not come back" over a single
        // row would be the card's most important sentence miscounting what it is about.
        if isBigThing, !deletesForGood {
            cautions.append(ordered.count == 1
                ? ProjectDeckText.bigThingCaution
                : ProjectDeckText.bigThingsCaution)
        }
        // **Not on a big thing.** `untickedCaution` says a normal clean leaves the row alone
        // because getting it back is a large download, which is true of the Android NDK and
        // false of everything in `GroupID.bigThings`: every one of those rows is
        // `startsUnticked` by design — that is what keeps them out of every default route —
        // and what they cost to get back is not a download but the file itself. The
        // big-thing caution above already says the stronger and truer thing, and a page of
        // the user's own files carrying "getting it back is a large download" would be the
        // one sentence on it that is simply wrong.
        if !isBigThing, ordered.contains(where: \.startsUnticked) {
            cautions.append(ProjectDeckText.untickedCaution)
        }

        self.init(
            kind: isBigThing
                ? .bigThing(scannerID: scannerID)
                : .tool(scannerID: scannerID),
            id: scannerID,
            // A scanner this build does not know can only arrive out of a cached scan
            // written by a different build. Its rows are still shown, under the identifier
            // and the group the rows themselves carry: hiding gigabytes because a name
            // could not be looked up is the one answer that leaves nothing on screen to
            // explain the missing space.
            eyebrow: isBigThing
                ? ProjectDeckText.bigThingEyebrow
                : ((scanner?.group ?? ordered.first?.group)?.title ?? scannerID),
            name: scanner?.title ?? scannerID,
            pathText: ProjectDeck.location(of: ordered, reporter: reporter),
            // Deliberately nothing. A cache's newest file says when a build last ran, which
            // is not a fact about anything the user recognises — and beside a project's
            // "last changed 4 months ago" it would read as the same kind of statement.
            lastChangedText: nil,
            // **Dealt with nothing ticked**, and that is the user's own reasoning after
            // living with the page: these are their films and their lesson videos, so the
            // page has to start from "nothing goes" and every file that goes is one they
            // ticked. An opening state of everything-ticked put a 41 GB "Move to Trash" under
            // their hand on a card the deck had taught them to answer by reflex, and the one
            // press that page exists to make careful was the easiest press on it.
            //
            // So a row is dealt unticked and in no run — `runIndex: nil` — and
            // `applyingTicks` derives every other state of the page from `checklistItems`.
            folders: ordered.enumerated().map { index, item in
                isChecklist
                    ? ProjectCardFolder(
                        checklistItem: item, widest: widest, isTicked: false,
                        runIndex: nil, reporter: reporter)
                    : ProjectCardFolder(
                        item: item, widest: widest,
                        kind: .tool(scannerID: scannerID), runIndex: index)
            },
            totalBytes: totalBytes,
            totalText: totalText,
            // "0 of 56 files" on the page, because its own question is which of them to
            // choose. Every other card counts what it holds and promises something about it.
            folderCountText: isChecklist
                ? ProjectDeckText.checklistCount(ticked: 0, of: ordered.count)
                : ProjectDeckText.itemCount(ordered.count),
            cautionLines: cautions,
            keptText: kept.isEmpty
                ? nil
                : ProjectDeckText.keptRows(
                    reasons: kept.compactMap(\.protection),
                    bytes: ScanResult.totalBytes(of: kept)),
            // Three sentences, and each one is about what the **engine** will really do.
            // Permanence is the strongest claim, so it wins a card that somehow held both;
            // a big thing's promise is the only one in the deck that does not depend on
            // `moveToTrash`, because the thing it describes does not either.
            promiseText: deletesForGood
                ? ProjectDeckText.permanentPromise(for: ordered, moveToTrash: moveToTrash)
                : (isBigThing
                    ? (ordered.count == 1
                        ? ProjectDeckText.bigThingPromise
                        : ProjectDeckText.bigThingsPromise)
                    : ProjectDeckText.toolPromise(moveToTrash: moveToTrash)),
            // The page's button names no amount, because nothing is ticked yet: it says what
            // to do instead, and `isPrimaryActionEnabled` below keeps it from being pressed.
            primaryActionTitle: isChecklist
                ? ProjectDeckText.nothingTicked
                : (deletesForGood
                    ? ProjectDeckText.deleteForGood(totalText)
                    : (isBigThing
                        ? ProjectDeckText.moveToTrash(totalText)
                        : ProjectDeckText.cleanUp(totalText))),
            // No key, and no glyph promising one, on either kind of card the user has to
            // mean: the one that cannot be undone, and the one that is theirs.
            primaryActionKeyHint: deletesForGood || isBigThing
                ? nil : ProjectDeckText.cleanUpKeyHint,
            answersToReturn: !deletesForGood && !isBigThing,
            // **Nothing on the page is handed over until it is ticked.** `items` is exactly
            // what Clean up gives the engine, so on a page dealt with every box clear it is
            // empty — the rows wait in `checklistItems` for `applyingTicks` to pick them out.
            // Every other card hands over everything it lists.
            items: isChecklist ? [] : ordered,
            isChecklist: isChecklist,
            isPrimaryActionEnabled: !isChecklist,
            checklistItems: isChecklist ? ordered : [],
            // Dealt with nothing ticked, so the button is dead and the one bulk move on offer
            // is the way to the other extreme.
            checklistSelectAll: isChecklist
                ? ChecklistSelectAll.forPage(allTicked: false) : nil)
    }

    /// Builds a card from **one row**, for a scanner whose rows are unrelated to each other.
    ///
    /// `DeckDealing.perItem` is the scanner's own declaration — `other.xdgCache`,
    /// `big.downloads` and `big.aiModels` — and the reason is on that type: a user may want
    /// `~/.cache/uv` gone and `~/.cache/huggingface` kept, and this window has no per-row
    /// ticks, so one card for both would be an all-or-nothing button over two unrelated
    /// things.
    ///
    /// The card's identity is the **row's** identifier rather than the scanner's, because
    /// there are several cards per scanner now. `CleanupItem.id` is `<scannerID>|<path>`,
    /// which cannot collide with a project's directory and is stable across scans and
    /// across a prune.
    ///
    /// Everything that makes a big thing different from an ordinary per-item card is
    /// decided from the **row's own group**, never from a list of scanner identifiers kept
    /// in this file — the same rule the tool card follows for permanence.
    init(
        item: CleanupItem, scanner: CleanerService.ScannerInfo?,
        reporter: ReportText, now: Date, moveToTrash: Bool
    ) {
        // Either spelling, the same hardening as the grouped card above: the group is the
        // deck's filing of the row, `.irreplaceable` is what the executor's always-Trash
        // rule really keys on, and a card that read only one of them could give an
        // irreplaceable row a blue button, a Return key and a promise the run contradicts.
        let isBigThing = item.group == .bigThings || item.risk == .irreplaceable
        let totalText = ByteText.short(item.sizeBytes)
        let scannerID = item.scannerID
        let path = item.method.path
        // A folder in `~/.cache` this app cannot name. The one other thing on a per-item
        // card that takes the Return key away, and the reason is on
        // `ProjectDeckText.unknownToolCaution`: the only grounds for offering it at all are
        // a directory naming convention, and the `huggingface` card is what that convention
        // being wrong once cost.
        let isUnfamiliar = ProjectDeck.isUnfamiliarTool(item)

        self.init(
            kind: isBigThing
                ? .bigThing(scannerID: scannerID)
                : .tool(scannerID: scannerID),
            id: item.id,
            eyebrow: isBigThing
                ? ProjectDeckText.bigThingEyebrow
                : ((scanner?.group ?? item.group).title),
            // The row's own name, which is the folder or the file — "uv",
            // "Xcode_26.1_beta.xip", "lmstudio-community/Qwen3-30B-GGUF". On a card holding
            // one thing the row's name *is* the card's name, and the scanner's title would
            // be the wrong one: "Downloads" tells the user nothing about which download.
            name: ProjectDeckText.rowName(of: item),
            // The folder it sits **in**, not the thing itself: the name above already says
            // which thing, and what is left to answer is where. `~/Downloads`,
            // `~/.lmstudio/models/lmstudio-community`.
            pathText: path
                .map { reporter.abbreviate(($0 as NSString).deletingLastPathComponent) }
                .flatMap { $0 == "~" || $0 == "/" ? nil : $0 },
            // "added 5 months ago". The one place a tool-ish card carries a date, and it is
            // a date about the user rather than about a build: when this arrived.
            lastChangedText: item.lastUsed.map { ProjectDeckText.added($0, now: now) },
            // One row, and it is a bare bar: the name and the size, with no hint. The hint
            // would be the row's `detail`, which on this card is already the line under the
            // big number — printing it twice in two weights reads as two different facts.
            // The row is here at all because it is what drains as the run reports, which is
            // the only progress a one-item card can show.
            folders: [
                ProjectCardFolder(
                    id: item.id, name: ProjectDeckText.rowName(of: item),
                    sizeBytes: item.sizeBytes, sizeText: totalText,
                    fraction: 1, restoreHint: "",
                    needsDownload: item.risk != .safe, runIndex: 0),
            ],
            totalBytes: item.sizeBytes,
            totalText: totalText,
            // The row's own sentence, which its scanner wrote: "An installer. You can
            // usually download it again.", "models are downloaded again when a script next
            // asks for them". Better than a count of one could ever be.
            folderCountText: item.detail ?? ProjectDeckText.itemCount(1),
            // One or the other, never both: a big thing is never an `other.xdgCache` row.
            // The big-thing sentence goes first in the list for the same reason it wins the
            // grouped card — it is the stronger claim.
            cautionLines: isBigThing
                ? [ProjectDeckText.bigThingCaution]
                : (isUnfamiliar ? [ProjectDeckText.unknownToolCaution] : []),
            promiseText: isBigThing
                ? ProjectDeckText.bigThingPromise
                : ProjectDeckText.toolPromise(moveToTrash: moveToTrash),
            // The unfamiliar folder keeps "Clean up 2.4 GB", deliberately. The verb is
            // right — this really is a cache that should rebuild — and the wording is not
            // where the friction belongs: the caution says what is unknown, the missing
            // Return key makes it a click, and `primaryActionTone` paints it amber.
            primaryActionTitle: isBigThing
                ? ProjectDeckText.moveToTrash(totalText)
                : ProjectDeckText.cleanUp(totalText),
            // No Return on a big thing, the same mechanism the permanent cards use and for
            // the same reason: by the time this card is dealt the user's hand has answered
            // a dozen reversible ones, and this is the press that moves something nothing
            // will bring back. And none on a folder whose tool the app cannot name, which
            // is a weaker reason for the same treatment — there, what the user has to mean
            // is a deletion nobody can describe the cost of.
            primaryActionKeyHint: isBigThing || isUnfamiliar
                ? nil : ProjectDeckText.cleanUpKeyHint,
            answersToReturn: !isBigThing && !isUnfamiliar,
            items: [item],
            // Only a big thing offers it, and only when there is a path to reveal.
            revealURL: isBigThing ? path.map { URL(fileURLWithPath: $0) } : nil)
    }

    /// The card between the two halves of the deck.
    ///
    /// Built from the big-thing cards that follow it, so its number and its count cannot
    /// disagree with what the deck is about to deal.
    init(interstitialFor bigThings: [ProjectCard]) {
        let total = bigThings.reduce(into: Int64(0)) { $0 += $1.totalBytes }
        self.init(
            kind: .interstitial,
            id: ProjectDeck.interstitialCardID,
            // The group's own title, which is what every other card's eyebrow is: this card
            // is about the big things, and naming them is what makes the headline above the
            // buttons land.
            eyebrow: GroupID.bigThings.title,
            name: ProjectDeckText.interstitialHeadline,
            pathText: nil,
            lastChangedText: nil,
            // No rows. It is the only card in the deck that offers nothing, which is also
            // why `items` is empty and why `AppModel` answers it without calling the engine.
            folders: [],
            totalBytes: total,
            totalText: ByteText.short(total),
            folderCountText: ProjectDeckText.interstitialDetail(count: bigThings.count),
            promiseText: ProjectDeckText.interstitialPromise,
            primaryActionTitle: ProjectDeckText.interstitialPrimary,
            secondaryActionTitle: ProjectDeckText.interstitialSecondary,
            // **No arrow key, and no glyph promising one.** This secondary answers for the
            // whole second half of the deck, and a bare arrow held down through the
            // regenerable half would press it on the next repeat — see
            // `secondaryAnswersToArrow`. Return still works on "Look through them", which
            // costs nothing and is what keeps the card itself answerable by keyboard.
            secondaryActionKeyHint: nil,
            secondaryAnswersToArrow: false,
            items: [])
    }

    /// The number the card sets large, split for its two type sizes — "2.9" at 96 points,
    /// "GB" at 40.
    ///
    /// **On a checklist page it is two figures**: "0 of 41.3 GB", climbing to "3.8 of 41.3
    /// GB" as films are ticked. The card's own total is not what the button is about there —
    /// nothing goes unless the user ticks it — so the amount set large is what they have
    /// chosen, with what there is to choose from beside it. The reasoning for the wording and
    /// the shared unit is on `SizeHeadline.init(tickedBytes:of:)`.
    ///
    /// One property for both, so the window asks the card for its headline and draws what it
    /// is handed. A view that chose between two properties on `isChecklist` would be a view
    /// deciding which number this card is about.
    ///
    /// The ticked sum is read off `items` — the list that would really be handed over — so
    /// the headline and the button cannot come to disagree about what is going.
    public var totalHeadline: SizeHeadline {
        isChecklist
            ? SizeHeadline(tickedBytes: ScanResult.totalBytes(of: items), of: totalBytes)
            : SizeHeadline(totalText)
    }

    /// The number the card sets large: what it is **offering** before a run, and what the run
    /// **left** once there is one.
    ///
    /// One property for both states, so the window asks the card for its headline and draws
    /// what it is handed. A `result?.headline ?? card.totalHeadline` in a SwiftUI body is the
    /// same choice made where no test can read it — and this is the one number on the card the
    /// user was mistrusting, because for the whole of the deck's life it went back to the
    /// offer the moment the offer had been taken up.
    public func headline(afterRun result: CardRunResult?) -> SizeHeadline {
        result?.headline ?? totalHeadline
    }

    /// How many rows the run this card starts will report on: the length of **`items`**, the
    /// list handed over, and never of `folders`, the list drawn.
    ///
    /// The two are the same on every card but the checklist page, and there they part
    /// company: the rows the user cleared are still drawn and are in no run. Titled from the
    /// drawn list, the button on a page with two of four boxes ticked would read "Cleaning…
    /// 0 of 4", climb to 2 and stop there — a run reported as two-thirds finished when it
    /// had done everything it was asked to.
    ///
    /// Here rather than as `card.items.count` in the window, for the reason the whole
    /// `DevCleanerUI` target exists: which of the two lists the button counts is a decision,
    /// and one taken inside a SwiftUI body is a decision no test can read.
    public var runItemCount: Int { items.count }

    /// Whether the run on screen has finished with the row whose run index this is.
    ///
    /// The rule behind the one piece of motion on the card: the bars drain in order as the
    /// folders really go. `Executor` works through the list it is given one at a time,
    /// reporting per item, so `completed` is exactly how many of them are already gone —
    /// never an animation on a timer.
    ///
    /// The index is the row's place in **`items`**, the list that was handed over, which
    /// `ProjectCardFolder.runIndex` carries. On every card but the checklist page that is
    /// also the row's place on the card; on that page it is not, because the unticked rows
    /// are drawn and not handed over. `nil` — a row in no run at all — never drains, which
    /// is why the parameter is optional rather than the caller's index.
    ///
    /// No report yet drains nothing. A run whose first folder is still being removed has
    /// emptied none of them, and `.running(nil)` is the state the button is pressed into.
    public static func isFolderDrained(at index: Int?, progress: ExecutionProgress?) -> Bool {
        guard let index else { return false }
        return index < (progress?.completed ?? 0)
    }

    /// Whether this row's bar is empty and its name struck through — during the run, and
    /// **after** it.
    ///
    /// Two rules, and the second one is why this exists. While the run is going the report is
    /// the only thing that knows anything, so the bars drain in the order the folders really
    /// go. The moment it ends the report is worthless and the record is everything: a row the
    /// run removed stays drained, and a row it refused goes back to full, which is the truth
    /// about the disk in both directions.
    ///
    /// Before this, draining was the progress rule alone — so every bar on the card refilled
    /// the instant the run ended, over folders that had gone. That is the whole of what the
    /// user was reporting: "that orange background is going from right to left… but then it
    /// comes back, so I'm not sure if it works".
    ///
    /// The row rather than its index, because the two rules ask different questions of it: the
    /// live one wants its place in the list that was handed over, and the record's wants its
    /// identifier. See `CardRunResult.removed(_:)`.
    public static func isFolderDrained(
        _ folder: ProjectCardFolder, progress: ExecutionProgress?, result: CardRunResult?
    ) -> Bool {
        guard let result else {
            return isFolderDrained(at: folder.runIndex, progress: progress)
        }
        return result.removed(folder.id)
    }
}

// MARK: - the deck

/// Everything worth a card, biggest first, plus one line each for the things that get none.
public struct ProjectDeck: Equatable, Sendable {
    /// Biggest total first, ties broken by identifier so the deck is the same on every
    /// scan of the same machine.
    ///
    /// Projects and scanners are **mixed** by size rather than dealt in two runs. The
    /// user's goal is the biggest gains first, and on this Mac that order is device support
    /// 27.0 GB, simulators 21.4 GB, a runtime 17.3 GB, the pub cache 10.0 GB and only then
    /// the largest project — so a deck that dealt all twenty-four projects before the first
    /// cache would ask two dozen small questions before the big one.
    ///
    /// Ordered purely by size, and a project the user is working in is **not** sorted to
    /// the back. On a real dev machine the biggest projects are precisely the ones being
    /// worked on — Sample Game 3.3 GB, Photo Tool 2.8 GB — so pushing them down
    /// would bury the only cards worth reading behind twenty cards of crumbs. What marks
    /// them out is `ProjectCard.cautionLines`, on the card, in words.
    public let cards: [ProjectCard]
    /// "2 pinned projects were left alone · 1.2 GB", or `nil`.
    ///
    /// A **protected** project is not in the deck: the tool will not touch it, so offering
    /// a Clean button over it would be an offer the engine refuses. It still gets this
    /// line, because dropping it altogether answers "where did my 40 GB go?" with silence.
    ///
    /// Only a pin reaches this now. Recent activity stopped protecting a project and
    /// started cautioning a card instead, so the sentence names the reason rather than
    /// covering both with one clause that was false for half of them.
    public let keptProjectsText: String?
    /// "Left alone because they are in use: Android emulators, Android system images ·
    /// 12.0 GB", or `nil`.
    ///
    /// A scanner every one of whose rows is protected gets no card — there would be nothing
    /// on it to press a button about — so it is named here instead. On this Mac that is the
    /// emulator and its system image, 12 GB the user would otherwise go looking for.
    ///
    /// Kept rows of a scanner that **does** have a card are on the card, in
    /// `ProjectCard.keptText`, beside the rows they were held back from.
    public let keptToolsText: String?
    /// "38 small things under 50 MB were not shown · 412 MB", or `nil`.
    ///
    /// A `.mentionOnly` scanner's rows are **not** in this count. They are not "not shown"
    /// — they are shown, in `moreToGain`, with their sizes — and they are not small either.
    /// Folding 4.5 GB of browser cache into a line that says "small things under 50 MB"
    /// would be the one line on the end card that is arithmetically false.
    public let smallThingsText: String?

    /// The quiet section at the bottom of the end card, or `nil` when there is nothing to
    /// say.
    ///
    /// Everything two scanners measured and nothing offers: the browser caches and the
    /// desktop apps' own caches — see `DeckDealing.mentionOnly`. The user asked for exactly
    /// this after seeing the cards: take them out of the deck, "and just mention in the last
    /// page… Something like: more space to gain: list of caches and their size in GB".
    ///
    /// Resolved down to strings here rather than handed over as rows, like everything else
    /// in this file, so the sorting, the per-app summing, the floor, the fold and the
    /// sentence underneath are all decisions a test can read. The view draws three things:
    /// a title, some lines, and a note.
    public let moreToGain: MoreToGain?

    /// The three pieces of that section.
    ///
    /// A small struct rather than the tuple the plan sketched, because `ProjectDeck` is
    /// `Equatable` and a stored tuple does not conform to anything — the synthesised `==`
    /// would not compile. It also gives the section a name to be tested under.
    public struct MoreToGain: Equatable, Sendable {
        /// "More space to gain".
        public let title: String
        /// "Brave browsing cache · 3.2 GB", biggest first, at most
        /// `ProjectDeck.moreToGainLines` of them plus a fold line.
        public let lines: [String]
        /// Why none of it has a button: `ProjectDeckText.moreToGainNote`.
        public let note: String
    }

    /// The one amount the menu bar shows: what a pass through this deck would take if the
    /// user decided nothing.
    ///
    /// Three exclusions, and each one is the difference between a number the deck can keep
    /// and a number it cannot.
    ///
    /// **The cards, not the scan.** `ScanResult.reclaimableBytes` is what the old header
    /// showed, and it totals rows the deck never deals: everything under
    /// `minimumCardBytes`, which is 38 things and 412 MB on a real dev machine, plus every
    /// row `du` could not size. Those are counted in `smallThingsText` and cannot be reached
    /// by pressing anything, so a status item built from the scan promises space no amount
    /// of working through the deck recovers.
    ///
    /// **`selectedByDefault`, not `isDeletable`.** A row a card holds back is on the card —
    /// the Android NDK is 5.6 GB, named, sized and carrying `ProjectDeckText.untickedCaution`
    /// — and pressing Clean up there really does remove it. But the menu bar is one line
    /// with no room for the caution, and a number that included it would advertise a large
    /// network re-download as space waiting to be had.
    ///
    /// **The regenerable half only.** A big thing is one of the user's own files, behind the
    /// interstitial, and nothing brings one back. Counting a 7 GB download here would be the
    /// app recommending the one deletion its own card warns hardest about, in the one place
    /// that cannot carry the warning.
    ///
    /// So this is a **floor** and never a ceiling — which is why the panel prefixes it "at
    /// least" where the old header said "up to".
    ///
    /// Totalled through `ScanResult.totalBytes` over the whole half at once rather than card
    /// by card: it de-duplicates on `DeletionMethod`, so two cards naming one directory
    /// contribute once, exactly as every other total in this app does.
    ///
    /// Computed rather than stored, so it cannot be left describing a `cards` that has since
    /// changed shape.
    public var defaultOfferBytes: Int64 {
        ScanResult.totalBytes(of: cards
            .filter { !$0.isBigThing && !$0.isInterstitial }
            .flatMap(\.items)
            .filter(\.selectedByDefault))
    }

    /// The same number as a string, so the menu bar label and the panel under it are one
    /// value read twice.
    ///
    /// A second `ByteText.short` call at a second call site is how the old header and the
    /// old menu bar came to print totals 19 GB apart on one screen.
    public var defaultOfferText: String { ByteText.short(defaultOfferBytes) }

    /// The floor under a card.
    ///
    /// A real dev machine has 257 projects on it and most of them are holding a few
    /// megabytes of `.dart_tool`. A deck that asked about each of those is a deck nobody
    /// finishes, and the decision it asks for is not worth making: 50 MB is under a
    /// thousandth of the disk. They are counted and totalled in one line instead, so the
    /// space is still accounted for.
    public static let minimumCardBytes: Int64 = 50_000_000

    /// How many lines `moreToGain` prints before folding the rest into one.
    ///
    /// Six. The section is a footnote under two other quiet blocks at the bottom of the end
    /// card, and a real machine has ten or twelve entries over the floor — mostly two or
    /// three rows of Electron cache each. Printing all of them would make the thing that
    /// says "there is more space over here" the tallest part of the card that says what the
    /// session did.
    public static let moreToGainLines = 6

    /// The identity of the card between the two halves of the deck.
    ///
    /// A reserved string rather than a scanner's identifier or a project's directory,
    /// because it is neither: nothing measured it and nothing cleans it. It has to be a
    /// stable identity all the same, so that answering the card records a decision the
    /// session remembers and the deck does not deal it again on the next redraw.
    ///
    /// **It holds no `ProjectDeckSlot`.** That is the decision the plan asked for, and the
    /// reason is that a slot is a thing with bytes: the skyline draws one bar per slot at a
    /// height taken from its total, and "3 of 24" counts them. A zero-byte bar would be a
    /// tower of nothing, and a card that adds one to the count would make the deck read as
    /// longer than the number of decisions in it. So while the interstitial is on screen the
    /// position counter is absent and no bar is `.current` — the card's own headline is what
    /// says where the user is. `AppModel.deckSlots` and `rememberDeckOrder` filter it out,
    /// and `ProjectDeckSummary` counts skips over the slots rather than over the decisions,
    /// so answering it cannot appear as a skipped card either.
    public static let interstitialCardID = "deck.bigThingsInterstitial"

    /// The scanner whose rows become **project** cards.
    ///
    /// The scanner's own constant, not a literal. It used to be a literal here, which was
    /// defensible while the deck was the only reader; the `Executor` now has to recognise
    /// the same rows — it renames them before trashing them — and three spellings of one
    /// identifier is three things to keep in step.
    static let scannerID = ProjectBuildOutputScanner.scannerID

    /// `moveToTrash` is taken rather than read, for the reason the whole `DevCleanerUI`
    /// target exists: the two sentences that differ between the modes — the card's promise
    /// line and the session label — are written here, where a test can read them, instead
    /// of in a view that asked `Settings` for itself.
    public init(result: ScanResult, home: String, now: Date, moveToTrash: Bool) {
        let reporter = ReportText(home: home)

        // Insertion order kept by hand rather than walked out of the dictionary.
        // `Dictionary` promises no order, and a deck that reshuffles between scans deals
        // the user a different card than the one they were reading.
        var order: [String] = []
        var rows: [String: [CleanupItem]] = [:]
        var kept: [CleanupItem] = []
        // The same three, per scanner, for everything that is not a project.
        var toolOrder: [String] = []
        var toolRows: [String: [CleanupItem]] = [:]
        var toolKept: [String: [CleanupItem]] = [:]
        // Every scanner seen, however its rows were filed — including a scanner whose rows
        // were all dropped for being unmeasured, which lands in neither dictionary above.
        // Read off those two instead, a scanner whose first row is unmeasured joins the
        // order again on its second row, and the build below deals its card twice: two
        // cards with one identifier, two slots in the skyline, and a `ForEach` over
        // duplicate identities.
        var seenTools: Set<String> = []
        // The rows of the scanners the app never cleans, on their way to `moreToGain`.
        var mentioned: [CleanupItem] = []

        for item in result.items {
            guard item.scannerID == Self.scannerID else {
                // **Diverted before anything else looks at the row.** A `.mentionOnly`
                // scanner gets no card, no slot, no place in the small-things line, no
                // mention in the kept-tools line, no bar in the skyline, no position in
                // "3 of 24" and nothing in the session totals — so it must not enter
                // `toolOrder`, which is the list the card-building loop walks. Everything
                // downstream of here is about a question the deck is going to ask, and
                // this is a scanner it has decided not to ask about.
                //
                // Protected rows come through here too. Nothing can protect one of these —
                // `ProtectionResolver` speaks about projects and devices — so there is no
                // branch for it rather than a branch no test could run.
                if CleanerService.scanner(withID: item.scannerID)?.dealing == .mentionOnly {
                    mentioned.append(item)
                    continue
                }
                if seenTools.insert(item.scannerID).inserted {
                    toolOrder.append(item.scannerID)
                }
                // Protection first here too, and it is the harder half of the rule: a
                // protected row is a booted simulator, the runtime the kept simulator needs,
                // or the Gradle distribution a project is building with. Nothing may put one
                // in `items`, because `items` is what Clean up hands the engine — and while
                // the executor refuses a protected row itself, a card that listed one would
                // have promised its bytes in the total above the button.
                if item.protection != nil {
                    toolKept[item.scannerID, default: []].append(item)
                    continue
                }
                // Deletable and measured. `startsUnticked` rows are deliberately **in**:
                // the Android NDK is 5.6 GB that a blind clean must never take, and a card
                // that names it, sizes it and carries `untickedCaution` is the opposite of
                // blind. What stays out is a row `du` could not size, which arrives as
                // `sizeBytes == 0` — a card built from one would print "0 KB", add nothing
                // to the total and hand the engine a deletion whose cost the user was never
                // shown.
                guard item.sizeBytes > 0 else { continue }
                toolRows[item.scannerID, default: []].append(item)
                continue
            }
            // Protection first, before anything else on the row is read. A protected row is
            // the summary of a whole project that is not being offered at all; nothing about
            // it belongs on a card, and its total belongs in one line.
            if item.protection != nil {
                kept.append(item)
                continue
            }
            // Ticked by default, **or** unticked for a reason worth telling the user.
            //
            // This is where the deck parts company with the tick rule, and it does not
            // break it — it is what the rule is for. The rule says a *blind*
            // clean must never include a row nothing ticked, and
            // the CLI's `cleanDefault` derives its list from
            // `ScanResult.defaultSelection`, and every row reaching this second clause is
            // still absent from it. What the deck does is the opposite of blind. It puts one
            // project on screen, names it, lists these exact folders with their sizes,
            // prints the reason they are held back, and waits — so pressing Clean up under
            // all that *is* the user asking for them, and `cleanCurrentProject` hands the
            // engine that list by identifier rather than asking it to re-derive one.
            //
            // The rows this still excludes are the ones whose size `du` could not measure.
            // They arrive `startsUnticked` with no reason, which is exactly what "unmeasured"
            // means, and `sizeBytes > 0` below is what keeps them out: a card built from one
            // would print a folder at "0 KB", add nothing to the total, and hand the engine
            // a deletion whose cost the user was never shown. The size rule covers a
            // genuinely empty folder for the same reason — there is nothing there to get
            // back — so the deck needs no third flag to tell the two apart.
            guard item.selectedByDefault || item.untickedReason != nil,
                  item.sizeBytes > 0,
                  item.method.path != nil,
                  let directory = Self.projectDirectory(of: item)
            else { continue }
            if rows[directory] == nil { order.append(directory) }
            rows[directory, default: []].append(item)
        }

        var built: [ProjectCard] = []
        var smallCount = 0
        var smallBytes: Int64 = 0

        for directory in order {
            guard let group = rows[directory] else { continue }
            // `ScanResult.totalBytes`, not `reduce(+)`. It de-duplicates on
            // `DeletionMethod`, so this total is added up by the same rule as the CLI's
            // headline and the menu bar's amount, and it is the last place able to refuse a
            // promise of bytes that exist once.
            let total = ScanResult.totalBytes(of: group)
            guard total >= Self.minimumCardBytes else {
                smallCount += 1
                smallBytes += total
                continue
            }
            built.append(ProjectCard(
                directory: directory, rows: group, totalBytes: total,
                reporter: reporter, now: now, moveToTrash: moveToTrash))
        }

        // One card per scanner, in the order the registry ran them, which only decides
        // ties: the deck below is sorted by size.
        var keptToolTitles: [String] = []
        var keptToolBytes: Int64 = 0

        for scannerID in toolOrder {
            let scanner = CleanerService.scanner(withID: scannerID)
            let group = toolRows[scannerID] ?? []
            let held = toolKept[scannerID] ?? []

            // A scanner whose rows are unrelated to one another gets a card each — see
            // `DeckDealing`. Its kept rows, if it ever had any, cannot sit on any one of
            // those cards, so they are named on the end card the way a card-less scanner's
            // are; nothing produces one today.
            if scanner?.dealing == .perItem {
                for row in group.sorted(by: Self.byDescendingSize) {
                    let total = ScanResult.totalBytes(of: [row])
                    guard total >= Self.minimumCardBytes else {
                        smallCount += 1
                        smallBytes += total
                        continue
                    }
                    built.append(ProjectCard(
                        item: row, scanner: scanner, reporter: reporter, now: now,
                        moveToTrash: moveToTrash))
                }
                if !held.isEmpty {
                    keptToolTitles.append(scanner?.title ?? scannerID)
                    keptToolBytes += ScanResult.totalBytes(of: held)
                }
                continue
            }

            let total = ScanResult.totalBytes(of: group)
            // No card: either nothing was offered at all, or what was is not worth a
            // decision. Both cases have to account for what they were holding — a scanner
            // that simply vanished is how "where did my 12 GB go?" starts — so the offered
            // part joins the small-things line and the kept part is named on the end card.
            guard !group.isEmpty, total >= Self.minimumCardBytes else {
                if !group.isEmpty {
                    smallCount += 1
                    smallBytes += total
                }
                if !held.isEmpty {
                    keptToolTitles.append(scanner?.title ?? scannerID)
                    keptToolBytes += ScanResult.totalBytes(of: held)
                }
                continue
            }
            built.append(ProjectCard(
                scanner: scanner, scannerID: scannerID, rows: group, kept: held,
                totalBytes: total, reporter: reporter, moveToTrash: moveToTrash))
        }

        /// Biggest first, ties by identifier so the deck is the same on every scan of the
        /// same machine.
        func byDescendingTotal(_ left: ProjectCard, _ right: ProjectCard) -> Bool {
            left.totalBytes == right.totalBytes
                ? left.id < right.id
                : left.totalBytes > right.totalBytes
        }

        // **The two halves are never mixed by size**, and this is the one place in the deck
        // where size is not the whole of the order.
        //
        // Everything above the split comes back on its own, so the only question worth
        // asking about it is "how much?" — which is why projects and tool caches are dealt
        // biggest first, together. Nothing below the split comes back at all. Sorting a
        // 7 GB download in between two caches would put the deck's one irreversible
        // decision in the middle of a run of reflex ones, a dozen Return presses deep, and
        // the card's own warnings would be arriving at exactly the moment the user had
        // stopped reading them.
        let regenerable = built.filter { !$0.isBigThing }.sorted(by: byDescendingTotal)
        let bigThings = built.filter(\.isBigThing).sorted(by: byDescendingTotal)
        cards = bigThings.isEmpty
            ? regenerable
            : regenerable + [ProjectCard(interstitialFor: bigThings)] + bigThings
        keptProjectsText = kept.isEmpty
            ? nil
            : ProjectDeckText.keptProjects(
                reasons: kept.compactMap(\.protection),
                bytes: ScanResult.totalBytes(of: kept))
        keptToolsText = keptToolTitles.isEmpty
            ? nil
            : ProjectDeckText.keptTools(titles: keptToolTitles, bytes: keptToolBytes)
        smallThingsText = smallCount == 0
            ? nil
            : ProjectDeckText.smallThings(count: smallCount, bytes: smallBytes)
        moreToGain = Self.moreToGain(mentioned)
    }

    /// The end card's "More space to gain" section, from the rows nothing offers.
    ///
    /// Four rules, and each one is a decision rather than a formatting choice:
    ///
    /// **Electron rows are summed per app.** `other.electronCaches` produces one row per
    /// cache *subfolder* because a `removePath` is one path — six of them for Slack alone —
    /// and six lines reading "Slack – GPUCache", "Slack – Code Cache" tell the user nothing
    /// they can act on. One "Slack · 1.3 GB" does. The app comes from
    /// `ElectronCacheScanner.app(ofRowNamed:)`, the scanner's own rule, so this does not
    /// have to know how a row's name is put together. A browser row is listed under its own
    /// name, which is already the name of the thing.
    ///
    /// **Biggest first, ties by name.** The same order as every other list in this app, and
    /// for the same reason: the section is read top-down by somebody looking for the big
    /// number, and a stable tiebreak means it does not reshuffle between scans.
    ///
    /// **A floor, on the line and not on the row.** `minimumCardBytes`, the deck's own,
    /// because the reason is the same one: under a thousandth of the disk is not worth a
    /// line. It is applied *after* the per-app summing, which is the load-bearing half —
    /// six 40 MB Slack folders are 240 MB the user might want, and a floor applied to each
    /// row first would drop all six and report nothing. Entries under the floor are simply
    /// dropped: they are not in the fold's count either, because "and 9 more · 60 MB" over
    /// nine lines nobody would have read is a worse answer than silence.
    ///
    /// **`nil` for nothing.** No section, no heading, no note — on a machine with no
    /// browser and no Electron app there is no more space to gain, and a heading over
    /// nothing would be furniture.
    static func moreToGain(_ rows: [CleanupItem]) -> MoreToGain? {
        // Insertion order kept by hand, so the tiebreak below is the only thing that
        // decides ties. `Dictionary` promises no order, and a section that reshuffled
        // between two scans of one machine would look like the numbers had changed.
        var order: [String] = []
        var grouped: [String: [CleanupItem]] = [:]
        for row in rows {
            // The app, for a row of the scanner that names rows after apps; otherwise the
            // row's own name. Gated on the scanner rather than on whether the name happens
            // to split, so no other scanner's row can be filed under half of its name.
            let label = row.scannerID == ElectronCacheScanner.scannerID
                ? (ElectronCacheScanner.app(ofRowNamed: row.name) ?? row.name)
                : row.name
            if grouped[label] == nil { order.append(label) }
            grouped[label, default: []].append(row)
        }

        // `ScanResult.totalBytes`, like every other total in this app, so two rows naming
        // one directory contribute once here exactly as they do in the headline.
        var entries: [Mention] = order.map {
            Mention(name: $0, bytes: ScanResult.totalBytes(of: grouped[$0] ?? []))
        }
        entries = entries.filter { $0.bytes >= minimumCardBytes }
        entries.sort { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
        guard !entries.isEmpty else { return nil }

        var lines: [String] = entries.prefix(moreToGainLines).map {
            ProjectDeckText.moreToGain(name: $0.name, bytes: $0.bytes)
        }
        let rest = Array(entries.dropFirst(moreToGainLines))
        if !rest.isEmpty {
            let restBytes = rest.reduce(into: Int64(0)) { $0 += $1.bytes }
            lines.append(ProjectDeckText.moreToGainRest(
                count: rest.count, bytes: restBytes))
        }
        return MoreToGain(
            title: ProjectDeckText.moreToGainTitle,
            lines: lines,
            note: ProjectDeckText.moreToGainNote)
    }

    /// One line of `moreToGain` before it is a string: what it is called, and what it comes
    /// to. A named type rather than a tuple because the chain of `map`/`filter`/`sorted`
    /// over a labelled tuple is more than the type checker will take.
    private struct Mention {
        let name: String
        let bytes: Int64
    }

    /// Whether a row is a folder in `~/.cache` whose tool this app cannot name.
    ///
    /// The scanner's own predicate, asked about the scanner's own row — see
    /// `XDGCacheScanner.knows(childNamed:)` for why the question is put that way round
    /// rather than carried on the row or read off its sentence.
    ///
    /// Gated on the scanner identifier as well as the name, because `knows` is a statement
    /// about children of `~/.cache` and nothing else. Without it, every row in the deck
    /// whose name is not one of nine tool names — every project, every simulator — would
    /// answer `true`.
    static func isUnfamiliarTool(_ item: CleanupItem) -> Bool {
        item.scannerID == XDGCacheScanner.scannerID
            && !XDGCacheScanner.knows(childNamed: item.name)
    }

    /// The one directory a tool card's rows live in, `~`-abbreviated, or `nil`.
    ///
    /// The longest directory that contains every row, which is the answer to the question
    /// the line is asked: *where is this?* Derived data's twenty-two folders all sit in
    /// `~/Library/Developer/Xcode/DerivedData`; device support's four sit in two sibling
    /// folders, so the honest answer is the `~/Library/Developer/Xcode` above them.
    ///
    /// `nil` in the two cases where there is nothing worth printing. A card with a device
    /// row has no path at all — `simctl` owns the devices — and any card whose rows only
    /// meet at the home directory (the JavaScript caches live under `~/.npm`,
    /// `~/Library/Caches`, `~/Library/pnpm` and `~/.bun`) would print "~", which locates
    /// nothing. The rows' own names are then the whole of the answer, and `devcleaner scan`
    /// is where a full path belongs.
    static func location(of rows: [CleanupItem], reporter: ReportText) -> String? {
        let parents = rows.compactMap { $0.method.path }
            .map { ($0 as NSString).deletingLastPathComponent }
        // Every row, not some: a card that mixed devices with paths would otherwise be
        // labelled with the location of the half that has one.
        guard parents.count == rows.count, let first = parents.first else { return nil }
        var common = Self.components(of: first)
        for parent in parents.dropFirst() {
            let theirs = Self.components(of: parent)
            var shared: [String] = []
            // Stops at the first mismatch rather than keeping every component the two
            // happen to share: `/a/b/c` and `/a/x/c` have `/a` in common, not `/a/c`.
            for (mine, other) in zip(common, theirs) {
                guard mine == other else { break }
                shared.append(mine)
            }
            common = shared
            if common.isEmpty { return nil }
        }
        guard !common.isEmpty else { return nil }
        let directory = "/" + common.joined(separator: "/")
        let abbreviated = reporter.abbreviate(directory)
        // "~" and "/" are not locations. Anything outside the home directory keeps its full
        // path, which is right: an Android SDK installed elsewhere is worth naming.
        guard abbreviated != "~", abbreviated != "/" else { return nil }
        return abbreviated
    }

    /// A path's components, with the empty ones that leading and doubled slashes produce
    /// dropped, so `/a//b/` and `/a/b` compare as the same two.
    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// The project directory a row belongs to.
    ///
    /// `ProjectRowPath.projectDirectory` is the rule, and it lives in `CleanerCore` because
    /// the `Executor` now needs the same answer: it names a folder after the project it came
    /// from before moving it to the Trash. Derived in two places, the deck could group a row
    /// under one project while the run named it after another, and the run's name is what
    /// the user reads in the Trash afterwards. All this adds is the unwrapping of
    /// `CleanupItem`, which the engine's copy has no reason to know about.
    static func projectDirectory(of item: CleanupItem) -> String? {
        guard let path = item.method.path else { return nil }
        return ProjectRowPath.projectDirectory(of: path, named: item.name)
    }

    /// The same order as `GroupList.byDescendingSize` and `ReportText.byDescendingSize`:
    /// biggest first, ties broken by identifier so the list is the same on every scan.
    static func byDescendingSize(_ left: CleanupItem, _ right: CleanupItem) -> Bool {
        left.sizeBytes == right.sizeBytes
            ? left.id < right.id
            : left.sizeBytes > right.sizeBytes
    }
}

// MARK: - what the user said about a card

/// The answer a card was given. Absent means the card has not come up yet.
public enum ProjectDecision: Equatable, Sendable {
    case skipped
    /// What really went, **kept apart by where it went**.
    ///
    /// Both numbers come from the run's own record — `RunRecord.trashedBytes` and
    /// `permanentlyDeletedBytes` — and never from what the card offered. A run can be
    /// cancelled, and a folder can be refused; a session total built from the offer would
    /// be a number the disk disagrees with.
    ///
    /// Two numbers rather than one sum, because the deck can now do both and they mean
    /// opposite things. 4.4 GB in the Trash is still on the disk and comes back until the
    /// user empties it; 17.3 GB of deleted runtime is gone. Added together and labelled
    /// once, whichever label was chosen would be a lie about half the figure — and the
    /// half it lies about is the one the user would act on.
    ///
    /// `problems` is one line per entry the run did not finish, in
    /// `RunRecord.unfinishedReasons`' words, followed by the run's own `notes` — Xcode
    /// having been open, a cancelled run, devices removed outright. Empty for the ordinary
    /// case, and while it is empty the deck deals the next card straight away.
    case cleaned(trashedBytes: Int64, deletedBytes: Int64, problems: [String])

    /// Everything this card really removed, wherever it went. The figure over the skyline.
    public var movedBytes: Int64 {
        guard case .cleaned(let trashed, let deleted, _) = self else { return 0 }
        return trashed + deleted
    }
}

/// One card as the session remembers it: its identity and what it was holding when the
/// deck was first worked through.
///
/// The total is kept here as well as on the card because the card goes away. A cleaned
/// project's rows are pruned out of the result, so its card is gone from the next deck —
/// and the skyline still has to draw its bar at the height it had, and "3 of 24" still has
/// to say 24.
public struct ProjectDeckSlot: Identifiable, Equatable, Sendable {
    public let id: String
    public let totalBytes: Int64
    /// Whether this slot was one of the user's own files.
    ///
    /// Remembered here for the same reason the total is: the card goes away. A cleaned big
    /// thing's row is pruned out of the result, so its card is gone from the next deck —
    /// and the skyline still has to draw its bar in the colour that says the promise
    /// changed there, and the end card still has to count it on its own line.
    ///
    /// Defaults to `false`, so every existing construction of this type means what it meant.
    public let isBigThing: Bool

    public init(id: String, totalBytes: Int64, isBigThing: Bool = false) {
        self.id = id
        self.totalBytes = totalBytes
        self.isBigThing = isBigThing
    }
}

/// One bar of the skyline over the card: how big that project is, and where the user got to.
public struct SkylineBar: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case cleaned
        /// One of the user's own files, cleaned. Drawn in the amber token rather than the
        /// blue one, so the strip shows **where the promise changed** — a session that
        /// trashed nine caches and one language model did two different things, and the
        /// skyline is the only place the shape of that is visible at a glance.
        case cleanedBigThing
        case skipped
        /// The card on screen. Takes precedence over the decision, because during the
        /// problems state the card being read has already been cleaned and the bar under
        /// the user's eye should be the one they are looking at.
        ///
        /// No bar is `current` while the interstitial is on screen: it holds no slot. See
        /// `ProjectDeck.interstitialCardID`.
        case current
        case upcoming
    }

    public let id: String
    /// `0...1` of the biggest project in the deck, square-rooted — see
    /// `ProjectDeckSummary.skylineFraction`.
    public let fraction: Double
    public let state: State

    public init(id: String, fraction: Double, state: State) {
        self.id = id
        self.fraction = fraction
        self.state = state
    }
}

// MARK: - the strip above the card, and the card at the end

/// Everything about the session rather than about one card: where the user is, what they
/// have recovered, and what the last card says.
///
/// One value rather than a dozen properties on `AppModel`, so the view reads the session
/// from one place and cannot assemble half of it from `settings`. Every mode-dependent
/// sentence in here is already resolved: nothing downstream branches on
/// `Settings.moveToTrash`. The one sentence that left is the promise above the buttons,
/// which became a property of the **card** when the deck started dealing cards that cannot
/// be undone — see `ProjectCard.promiseText`.
///
/// The end-card fields are filled in whatever state the deck is in. They are only read
/// when there is no card left, and computing them unconditionally keeps the rule about what
/// they say in one place instead of behind a `nil` the view has to interpret.
public struct ProjectDeckSummary: Equatable, Sendable {
    /// "3 of 24", or `nil` when no card is on screen.
    public let positionText: String?
    /// "In the Trash so far" | "Cleaned so far" — see `ProjectDeckText.sessionLabel`. The
    /// Trash is claimed only while it is the whole truth.
    public let sessionLabel: String
    /// Everything this session removed, wherever it went: what the strip counts.
    public let sessionBytes: Int64
    public let sessionBytesText: String
    /// The part of it that is sitting in the Trash, and the part that is gone.
    ///
    /// Kept apart all the way to the end card, because everything that follows from them
    /// differs: the Trash part is what "empty the Trash" would release and what the Open
    /// the Trash button would show, and the deleted part is not there to be looked at.
    public let sessionTrashedBytes: Int64
    public let sessionDeletedBytes: Int64
    /// One bar per card in the session's deck, in the order the deck is worked through.
    public let skyline: [SkylineBar]
    public let cleanedCount: Int
    public let skippedCount: Int
    public let skippedBytes: Int64
    public let skippedBytesText: String
    /// "2 skipped · 3.4 GB", or `nil` when nothing was skipped.
    public let skippedText: String?
    public let endHeadline: String
    /// The end card's big numeral and unit, or `nil` when there is nothing to set large.
    ///
    /// `nil` rather than "0 KB". The gain number is what the user reads from across the
    /// room, and on a deck they skipped their way through — or on a machine that had nothing
    /// worth a card at all — a 96-point zero reads as the app reporting a failure instead of
    /// a decision the user made twenty-four times. The headline and the detail say what
    /// happened in words in both those cases.
    public let endGain: SizeHeadline?
    /// The lines under the big number, one amount each.
    ///
    /// A list rather than a sentence, because a session can have done two different things
    /// and the end card is where they are told apart: "4.4 GB moved to the Trash", "17.3 GB
    /// deleted for good", "from 3 cards". A deck that cleaned nothing says so in one line
    /// instead, and a machine with nothing worth a card says that.
    public let endDetailLines: [String]
    /// "The space comes back when you empty the Trash." — `nil` unless something really is
    /// in the Trash, because there is otherwise no space waiting there.
    public let endNote: String?
    /// `ProjectDeckText.hiddenInTrashNote`, or `nil`. Only beside `endNote` — it explains
    /// what the user will (not) see when they follow that note into the Trash — and only
    /// when a dot-named folder really went there this session.
    public let hiddenInTrashNote: String?
    /// The end card's secondary button, or `nil` when there is nothing to go back to.
    public let reviewSkippedText: String?
    /// The end card's prominent button, or `nil`. Only when something is actually in the
    /// Trash — a button that opens an empty folder is a button that teaches the user the
    /// app is guessing.
    public let openTrashText: String?
    /// Whether Return presses that button. **Always false**, and it is here rather than in
    /// the window for the same reason `ProjectCard.answersToReturn` is.
    ///
    /// It was the window's default action, which put a Finder window at the end of a held
    /// Return: the key that answered the last card of the deck reached the end card on its
    /// next repeat and opened the Trash. Opening a folder is harmless in itself — what is
    /// not harmless is the deck teaching a user that holding Return is a way to get through
    /// it, and the end card is the last place that lesson gets confirmed.
    ///
    /// A constant rather than a condition because there is no state in which this button
    /// should answer a key: it is a detour out of the app, not one of the deck's answers.
    /// Written down all the same, so the decision is one a test can read and not a missing
    /// line in a view.
    public let openTrashAnswersToReturn = false

    public init(
        slots: [ProjectDeckSlot], decisions: [String: ProjectDecision],
        currentCardID: String?, moveToTrash: Bool, trashedHiddenFolders: Bool = false
    ) {
        positionText = currentCardID.flatMap { id in
            slots.firstIndex { $0.id == id }.map {
                ProjectDeckText.position(index: $0 + 1, count: slots.count)
            }
        }

        let trashed = Self.trashedBytes(of: decisions)
        let deleted = Self.deletedBytes(of: decisions)
        let session = trashed + deleted
        sessionTrashedBytes = trashed
        sessionDeletedBytes = deleted
        sessionBytes = session
        sessionBytesText = ByteText.short(session)
        sessionLabel = ProjectDeckText.sessionLabel(
            moveToTrash: moveToTrash, deletedForGood: deleted > 0)

        // The biggest project in the **session's** deck, not in the deck on screen. The
        // bars must not all grow taller because the tallest one has just been cleaned out
        // of the result.
        let biggest = slots.map(\.totalBytes).max() ?? 0
        skyline = slots.map { slot in
            SkylineBar(
                id: slot.id,
                fraction: Self.skylineFraction(slot.totalBytes, of: biggest),
                state: Self.state(of: slot, decisions: decisions, currentCardID: currentCardID))
        }

        // Restricted to the **slots**, like the skip count below and for the same reason.
        // It is a no-op today — the interstitial is the only card without a slot and it can
        // never be `.cleaned`, because `AppModel.cleanCurrentProject` answers it without
        // ever starting a run — so this is symmetry rather than a fix. Counted off the
        // decisions, the next card that holds no slot would be free to appear in "from 4
        // cards" with no bytes anywhere accounting for it, and an answered slot is kept
        // whatever a later scan says, so nothing real is lost here.
        let slotIDs = Set(slots.map(\.id))
        cleanedCount = decisions.filter {
            guard slotIDs.contains($0.key) else { return false }
            if case .cleaned = $0.value { return true }
            return false
        }.count
        // The same restriction, and this is the one where it is load-bearing: it keeps the
        // interstitial out of the skip count. Answering that card — either way — records a
        // `.skipped` decision so the deck does not deal it again, and it holds no slot
        // because it holds no bytes; read straight off the decisions, "Skip them all" would
        // report one more skipped card than the deck ever had, with nothing in
        // `skippedBytes` to account for it.
        let skippedIDs = Set(
            decisions.filter { $0.value == .skipped && slotIDs.contains($0.key) }.keys)
        skippedCount = skippedIDs.count
        // Out of the slots, because a skipped card's total is what the slot remembers and
        // a later scan can change what the project holds without the user having looked at
        // it again.
        let skipped = slots
            .filter { skippedIDs.contains($0.id) }
            .reduce(into: Int64(0)) { $0 += $1.totalBytes }
        skippedBytes = skipped
        skippedBytesText = ByteText.short(skipped)
        skippedText = skippedIDs.isEmpty
            ? nil
            : ProjectDeckText.skipped(count: skippedIDs.count, bytes: skipped)

        let nothingHappened = cleanedCount == 0 && skippedIDs.isEmpty
        endHeadline = nothingHappened
            ? ProjectDeckText.nothingHeadline
            : ProjectDeckText.endHeadline
        endGain = session > 0 ? SizeHeadline(sessionBytesText) : nil
        if nothingHappened {
            endDetailLines = [ProjectDeckText.nothingDetail]
        } else if cleanedCount == 0 {
            endDetailLines = [ProjectDeckText.endDetailNothingCleaned]
        } else {
            // One line per amount, then what they came out of. Each amount is named even
            // when it is the only one, and that is deliberate: the big number above these
            // lines is a **sum**, and the only way it cannot mislead is for every line under
            // it to say where its share went. A run that was cancelled before it moved
            // anything records a `.cleaned` decision with no bytes at all, and then the card
            // count is the whole of the truth.
            var lines: [String] = []
            if trashed > 0 { lines.append(ProjectDeckText.endTrashed(ByteText.short(trashed))) }
            if deleted > 0 { lines.append(ProjectDeckText.endDeleted(ByteText.short(deleted))) }
            // A **breakdown** of the Trash line above, not a further amount: the user's own
            // files always go to the Trash, so their bytes are already inside `trashed`.
            // Worth its own line all the same — a session that trashed twelve caches and one
            // 18 GB language model has done two different things, and the model is the one
            // they might want back. Straight after the amounts it is part of, before the
            // card count, which is about the whole session.
            let bigThings = slots.filter {
                $0.isBigThing && (decisions[$0.id]?.movedBytes ?? 0) > 0
            }
            if !bigThings.isEmpty {
                lines.append(ProjectDeckText.endBigThings(
                    count: bigThings.count,
                    bytes: bigThings.reduce(into: Int64(0)) {
                        $0 += decisions[$1.id]?.movedBytes ?? 0
                    }))
            }
            lines.append(ProjectDeckText.endFromCards(cleanedCount))
            endDetailLines = lines
        }
        // All three follow the **trashed** bytes, not the session total and not the Trash
        // setting. A deck that only destroyed simulators has emptied nothing into the Trash,
        // so a note about emptying it and a button that opens it would both be about a
        // folder this session did not touch; and an emulator that went to the Trash because
        // `avdmanager` was missing really is in there whatever the setting says.
        endNote = trashed > 0 ? ProjectDeckText.emptyTheTrashNote : nil
        hiddenInTrashNote = trashed > 0 && trashedHiddenFolders
            ? ProjectDeckText.hiddenInTrashNote : nil
        openTrashText = trashed > 0 ? ProjectDeckText.openTrash : nil
        reviewSkippedText = skippedIDs.isEmpty ? nil : ProjectDeckText.reviewSkipped
    }

    /// What this session has really removed, wherever it went: the sum of every cleaned
    /// card's `movedBytes`.
    ///
    /// Static and shared with `AppModel.deckSessionBytes`, so the number over the skyline
    /// and the number the end card prints are one number added up once.
    public static func sessionBytes(of decisions: [String: ProjectDecision]) -> Int64 {
        decisions.values.reduce(into: Int64(0)) { $0 += $1.movedBytes }
    }

    /// The part of it that went to the Trash, and the part that is gone for good.
    ///
    /// Two functions rather than one tuple, because two different sentences ask for them
    /// and each should be able to ask for the half it is about.
    public static func trashedBytes(of decisions: [String: ProjectDecision]) -> Int64 {
        decisions.values.reduce(into: Int64(0)) { total, decision in
            if case .cleaned(let trashed, _, _) = decision { total += trashed }
        }
    }

    public static func deletedBytes(of decisions: [String: ProjectDecision]) -> Int64 {
        decisions.values.reduce(into: Int64(0)) { total, decision in
            if case .cleaned(_, let deleted, _) = decision { total += deleted }
        }
    }

    /// Takes the **slot** rather than its identifier, because one of the four readings now
    /// depends on what the slot was: a cleaned big thing is drawn in a different token from
    /// a cleaned cache. The slot is the only thing that still knows — the card is gone once
    /// its rows are pruned.
    static func state(
        of slot: ProjectDeckSlot, decisions: [String: ProjectDecision], currentCardID: String?
    ) -> SkylineBar.State {
        if slot.id == currentCardID { return .current }
        switch decisions[slot.id] {
        case .cleaned: return slot.isBigThing ? .cleanedBigThing : .cleaned
        case .skipped: return .skipped
        case nil:      return .upcoming
        }
    }

    /// `0...1`, square-rooted.
    ///
    /// Linear is unreadable here. The deck is biggest first, so a real one runs from 12 GB
    /// down to 51 MB: every bar after the first few would be a fraction of a pixel in a
    /// 30pt strip, and the skyline would read as one tower beside a flat line — with no
    /// way to see that eleven of those flat bars are already cleaned. The square root
    /// lifts the small ones without reordering anything, because it is monotonic, so the
    /// shape still says "they get smaller from here" and every bar stays tall enough to
    /// show its state.
    static func skylineFraction(_ bytes: Int64, of biggest: Int64) -> Double {
        guard biggest > 0, bytes > 0 else { return 0 }
        return (Double(bytes) / Double(biggest)).squareRoot()
    }
}
