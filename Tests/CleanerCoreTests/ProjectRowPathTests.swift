import Testing
import Foundation
@testable import CleanerCore

// Where a project build-output row's project is, and what that row is called once it is in
// the Trash.
//
// The second of those exists because of what happened the first time somebody used the
// deck: six projects cleaned, 4.4 GB moved, and `~/.Trash` looking empty — because every
// one of them was called `.build`, `.build 12-22-29-584`, `.dart_tool`, and Finder hides a
// name beginning with a dot in the Trash exactly as it does anywhere else. The user
// concluded the app had deleted the lot. Renaming the folder before it goes means the Trash
// shows "Photo Tool iOS – .build", which is both visible and says which project it
// came from — five folders called `build` are otherwise indistinguishable.

/// Shorthand, because every test below asks the same question twice over.
private func name(of path: String, named folder: String) -> String? {
    ProjectRowPath.trashName(of: path, named: folder)
}

// MARK: - which directory a row belongs to

@Test func theProjectDirectoryIsThePathWithoutTheRowsOwnName() {
    #expect(ProjectRowPath.projectDirectory(
        of: "/Users/x/dev/app/.build", named: ".build") == "/Users/x/dev/app")
    // A nested relative name comes off whole, which a `deletingLastPathComponent` would
    // not manage: that would hand back `<project>/ios`.
    #expect(ProjectRowPath.projectDirectory(
        of: "/Users/x/dev/app/ios/Pods", named: "ios/Pods") == "/Users/x/dev/app")
    #expect(ProjectRowPath.projectDirectory(
        of: "/Users/x/dev/app/.claude/worktrees/w/build",
        named: ".claude/worktrees/w/build") == "/Users/x/dev/app")
}

/// A path that does not end in the row's name is dropped rather than guessed at.
///
/// Nothing `ProjectBuildOutputScanner` builds can be shaped that way — it writes
/// `path = project.path + "/" + relative` with `name = relative` — so this is the check
/// that says so out loud. It is also reachable for real: `PathGuard` hands back a path
/// whose parent components are resolved, so a project whose `ios` is a symlink to
/// `platforms/ios-app` produces an approved path ending in `/platforms/ios-app/Pods`, and
/// the only honest answer is that we do not know where the project is.
@Test func aPathThatDoesNotEndInTheRowsNameHasNoProjectDirectory() {
    #expect(ProjectRowPath.projectDirectory(
        of: "/Users/x/dev/app/somewhere-else", named: "build") == nil)
    #expect(ProjectRowPath.projectDirectory(
        of: "/Users/x/dev/app/platforms/ios-app/Pods", named: "ios/Pods") == nil)
    // The whole path being the name leaves no directory to name.
    #expect(ProjectRowPath.projectDirectory(of: "/build", named: "build") == nil)
    #expect(ProjectRowPath.projectDirectory(of: "", named: "") == nil)
}

// MARK: - the name it lands under

@Test func theTrashNameIsTheProjectThenTheFolder() {
    #expect(name(of: "/Users/x/dev/Photo Tool iOS/.build", named: ".build")
        == "Photo Tool iOS – .build")
    #expect(name(of: "/Users/x/dev/sample_app/build", named: "build")
        == "sample_app – build")
}

/// The separator is an en dash with spaces, which is how the user asked for it and which
/// no build folder or project name is likely to contain.
@Test func theSeparatorIsAnEnDashWithSpacesAroundIt() {
    let assembled = try? #require(
        name(of: "/Users/x/dev/app/.build", named: ".build"))
    #expect(assembled == "app – .build")
    #expect(assembled?.contains(" \u{2013} ") == true)
    // Not a hyphen, which projects use in their own names — "Sample Game - iOS" — and
    // which would make the separator invisible in exactly the case this is for.
    #expect(ProjectRowPath.separator == " – ")
}

/// A relative folder keeps every component, with the slashes turned into hyphens: the whole
/// path is what tells `ios/Pods` from `macos/Pods`, and `Pods` twice in one Trash is the
/// problem this is solving.
@Test func slashesInTheFolderBecomeHyphensSoEveryComponentSurvives() {
    #expect(name(of: "/Users/x/dev/sample_app/ios/Pods", named: "ios/Pods")
        == "sample_app – ios-Pods")
    #expect(name(of: "/Users/x/dev/App/.claude/worktrees/w/build",
                 named: ".claude/worktrees/w/build")
        == "App – .claude-worktrees-w-build")
}

/// The one thing the name must never do, since being seen is the whole point.
@Test func theNameNeverBeginsWithADotHoweverTheProjectIsSpelled() throws {
    let hidden = try #require(name(of: "/Users/x/dev/.config/.build", named: ".build"))
    #expect(!hidden.hasPrefix("."))
    #expect(hidden == "config – .build")
    // A project whose name is nothing but dots leaves nothing visible to lead with, so
    // there is no name to give and the folder goes under its own.
    #expect(name(of: "/Users/x/dev/.../.build", named: ".build") == nil)
}

/// A filename cannot hold a "/" at all, and a ":" is what Finder draws as one — so a
/// project called `9:16 renders` would appear in the Trash as `9/16 renders – .build`.
/// Both are replaced wherever they appear.
@Test func neitherASlashNorAColonSurvivesIntoTheName() throws {
    let assembled = try #require(
        name(of: "/Users/x/dev/9:16 renders/ios/Pods", named: "ios/Pods"))
    #expect(assembled == "9-16 renders – ios-Pods")
    #expect(!assembled.contains("/"))
    #expect(!assembled.contains(":"))
}

/// 255 **bytes**, which is the filename limit on every volume this app runs on — and a
/// limit in bytes rather than characters, so a project named in Japanese reaches it three
/// times sooner.
///
/// The project end is what gets cut. The folder is the part that says what the thing is,
/// it is short, and two truncated projects sharing a Trash are still told apart by it.
@Test func aNameTooLongForAFilenameIsCutAtTheProjectEnd() throws {
    let long = String(repeating: "p", count: 300)
    let assembled = try #require(
        name(of: "/Users/x/dev/\(long)/.build-release", named: ".build-release"))

    #expect(assembled.utf8.count <= 255)
    #expect(assembled.hasSuffix(" – .build-release"))
    #expect(assembled.hasPrefix("ppp"))
}

/// The same limit, counted in bytes rather than characters. Twelve emoji are twelve
/// characters and forty-eight bytes, and a name cut by character count would be well over
/// the limit — or, cut by bytes without regard for where a character ends, invalid UTF-8.
@Test func theByteLimitIsCountedInBytesAndNeverSplitsACharacter() throws {
    let long = String(repeating: "🧹", count: 100)      // 400 bytes
    let assembled = try #require(
        name(of: "/Users/x/dev/\(long)/.build", named: ".build"))

    #expect(assembled.utf8.count <= 255)
    #expect(assembled.hasSuffix(" – .build"))
    // Every character is whole: a byte-wise cut would leave a replacement character here.
    #expect(!assembled.contains("\u{FFFD}"))
    #expect(assembled.hasPrefix("🧹"))
}

/// A folder name so long that nothing is left for the project is no name at all, rather
/// than a name that is only a separator. Unreachable from the scanner's fixed list; a
/// worktree is named by whoever made it.
@Test func aFolderNameThatFillsTheLimitByItselfGetsNoVisibleName() {
    let worktree = String(repeating: "w", count: 260)
    #expect(name(of: "/Users/x/dev/app/.claude/worktrees/\(worktree)/build",
                 named: ".claude/worktrees/\(worktree)/build") == nil)
}

@Test func aRowWhosePathDoesNotEndInItsNameGetsNoVisibleName() {
    #expect(name(of: "/Users/x/dev/app/somewhere-else", named: "build") == nil)
    #expect(name(of: "/build", named: "build") == nil)
}
