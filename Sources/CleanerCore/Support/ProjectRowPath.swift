import Foundation

/// Two questions about one of `ProjectBuildOutputScanner`'s rows: which project it belongs
/// to, and what it should be called once it is in the Trash.
///
/// They live together because the second is built out of the first, and because the first
/// has two callers who must never disagree. `ProjectDeck` groups rows into cards by project
/// directory; the `Executor` names a folder after the project it came from. Derived twice,
/// the two could come to different answers about the same row, and the interesting case is
/// not hypothetical: `PathGuard` returns a path whose parent components are resolved, so a
/// project whose `ios` is a symlink produces a path that no longer ends in `ios/Pods`.
public enum ProjectRowPath {
    /// The project directory a row belongs to: its path with `"/" + name` taken off the end.
    ///
    /// `ProjectBuildOutputScanner` builds every row as `path = project.path + "/" +
    /// relative` with `name = relative`, so this is that construction read backwards. It
    /// recovers the directory exactly for a nested name — `ios/Pods`,
    /// `.claude/worktrees/feature-sync/build` — where a `deletingLastPathComponent` would
    /// hand back the `ios` or the worktree.
    ///
    /// Never `CleanupItem.detail`, which is the project's **name** and now carries the
    /// reason a row is held back as well. Two projects can share a name:
    /// `~/dev/workspace-one/shared-project-name` and
    /// `~/dev/workspace-two/client-app/shared-project-name` both exist on a real dev
    /// machine, so a name is not an identity.
    ///
    /// `nil` when the path does not end in `/<name>`, which is the only honest answer: the
    /// caller asked where the project is, and this does not know. Both callers fall back to
    /// doing nothing rather than to a guess — the deck drops the row, and the executor
    /// trashes the folder under its own name.
    public static func projectDirectory(of path: String, named name: String) -> String? {
        let suffix = "/" + name
        guard path.hasSuffix(suffix), path.count > suffix.count else { return nil }
        return String(path.dropLast(suffix.count))
    }

    /// Between the project and the folder: an en dash with a space either side.
    ///
    /// Not a hyphen. Projects put hyphens in their own names — `Sample Game - iOS`,
    /// `sample-flutter-002` — so a hyphen here would vanish into the name in exactly the
    /// case this is for. The en dash also survives every filesystem this app runs on and is
    /// not a character any build tool writes.
    public static let separator = " – "

    /// The filename limit, in **bytes**, on every volume this app runs on.
    ///
    /// Bytes rather than characters, so a project named in Japanese reaches it three times
    /// sooner than one named in English and a name cut by character count would still be
    /// refused by the filesystem.
    public static let maximumNameBytes = 255

    /// What a project's build folder should land in the Trash under: the project, then the
    /// folder. "Photo Tool iOS – .build".
    ///
    /// The first person to use the deck cleaned six projects, moved 4.4 GB, opened the
    /// Trash and saw nothing — every folder was called `.build` or `.dart_tool`, and Finder
    /// hides a name beginning with a dot in the Trash exactly as it does everywhere else.
    /// They concluded the app had deleted the lot. So the name has two jobs: **be visible**,
    /// which is why it can never begin with a dot, and **say where it came from**, because
    /// five folders called `build` in one Trash are five things the user cannot tell apart
    /// or put back.
    ///
    /// `nil` means "no visible name", and every `nil` here is a fall back to today's
    /// behaviour rather than a failure. The rename is cosmetic and must never be the reason
    /// a clean does less than it said it would.
    ///
    /// `name` is the row's own relative path, never its `detail`.
    public static func trashName(of path: String, named name: String) -> String? {
        guard let directory = projectDirectory(of: path, named: name) else { return nil }
        let folder = sanitised(name)
        guard !folder.isEmpty else { return nil }

        // Leading dots come off the project, and only the project. A project directory
        // called `.config` is itself hidden in Finder, but the item in the **Trash** must
        // not be — so it leads with "config", which is still the name the user knows it by.
        // The folder keeps its dot: it is not at the front, and `.build` is what the user
        // is looking for.
        let project = sanitised((directory as NSString).lastPathComponent)
            .drop(while: { $0 == "." })
        // The folder is what says what the thing is, and it is short, so the project end is
        // what gets cut. Two truncated projects sharing a Trash are still told apart by it.
        let budget = maximumNameBytes - (separator + folder).utf8.count
        let head = truncated(String(project), toFitBytes: budget)
        // Nothing left to lead with — a project named only in dots, or a folder long enough
        // to fill the limit by itself. A name that is only a separator would be worse than
        // none.
        guard !head.isEmpty else { return nil }
        return head + separator + folder
    }

    /// Replaces the two characters a filename cannot carry honestly.
    ///
    /// "/" cannot appear in a filename at all, which is what turns `ios/Pods` into one
    /// component. ":" can, and Finder draws it as a "/" — so a project called
    /// `9:16 renders` would appear in the Trash as `9/16 renders – .build`, which reads as
    /// a path and is not one. Both become "-", in both halves of the name: a project
    /// directory cannot contain a "/", but sanitising it anyway costs nothing and means the
    /// rule does not depend on that staying true.
    static func sanitised(_ component: String) -> String {
        String(component.map { $0 == "/" || $0 == ":" ? "-" : $0 })
    }

    /// The longest prefix of `text` that fits `bytes` bytes of UTF-8, cut between
    /// characters.
    ///
    /// By grapheme cluster, so the result is always valid text: twelve emoji are twelve
    /// characters and forty-eight bytes, and a cut made by counting bytes into the middle
    /// of one would leave a filename with a replacement character in it.
    static func truncated(_ text: String, toFitBytes bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let cost = String(character).utf8.count
            guard used + cost <= bytes else { break }
            result.append(character)
            used += cost
        }
        return result
    }
}
