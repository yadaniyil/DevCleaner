import Foundation

public struct PathGuard: Sendable {
    public enum Violation: Error, Equatable, CustomStringConvertible {
        case outsideAllowedRoots(String)
        case forbiddenTarget(String)
        case unresolvableParent(String)
        case relativePath(String)
        case unsafeFinalComponent(String)

        public var description: String {
            switch self {
            case .outsideAllowedRoots(let path):
                return "refused: \(path) is not inside an allowed root"
            case .forbiddenTarget(let path):
                return "refused: \(path) is a protected target"
            case .unresolvableParent(let path):
                return "refused: the parent directory of \(path) does not exist"
            case .relativePath(let path):
                return "refused: \(path) is not an absolute path"
            case .unsafeFinalComponent(let path):
                return "refused: \(path) ends in '.' or '..', which names a directory "
                    + "other than the one it appears to name"
            }
        }
    }

    private let canonicalRoots: [String]
    /// Lower-cased canonical paths, **each forbidden target registered under both of its
    /// spellings**. macOS volumes are case-insensitive by default, so
    /// `<root>/MY-PROJECT` and `<root>/my-project` are the same directory and both have
    /// to be refused. `realpath` case-corrects whatever it resolves, but `validate`
    /// re-attaches the final component verbatim, so the comparison has to ignore case.
    ///
    /// Both spellings, because `validate` compares `canonicaliseKeepingLeaf` and a
    /// forbidden target whose **own last component is a symlink** canonicalises to its
    /// destination — so registering only that would store the rule under a path the guard
    /// never asks about. Two real layouts reach it. `~/dev/current -> ~/dev/app-v3`:
    /// `ProjectDiscovery` follows the link and reports `~/dev/current` as a project, which
    /// `forRun` lists as a forbidden target, while `validate("~/dev/current")` keeps the
    /// leaf and would find nothing but the `~/dev` root, which admits it. And
    /// `~/.cache/huggingface` moved to an external disk by symlink: a forbidden target
    /// sitting inside the allowed `.cache` root, where the forbidden set is the only thing
    /// standing between the run and the model store the dictation-app incident was about.
    /// `aForbiddenTargetThatIsASymlinkInsideAnAllowedRootIsStillRefused` is what holds it.
    private let forbidden: Set<String>
    /// Single paths that are allowed without their parent becoming a root.
    ///
    /// A root is a licence to delete everything under it, and there are locations where
    /// the one path a scanner emits has a parent holding things no scanner should ever
    /// reach: `~/fvm/cache.git` sits beside `~/fvm/default`, the symlink the `flutter`
    /// command on PATH resolves through. Allowing `~/fvm` would cover both. This allows
    /// exactly one path and grants nothing about its parent or its siblings.
    ///
    /// Canonicalised the way `validate` canonicalises what it is asked about — parent
    /// resolved, final component left verbatim — so the two strings are comparable.
    /// Checked **after** the forbidden set, so an exact allowance can never re-admit a
    /// forbidden target.
    private let exactPaths: Set<String>

    public init(allowedRoots: [String], forbiddenTargets: [String],
                allowedExactPaths: [String] = []) {
        self.canonicalRoots = allowedRoots.compactMap(PathGuard.canonicalise)
        self.exactPaths = Set(allowedExactPaths.compactMap(PathGuard.canonicaliseKeepingLeaf))
        // Both spellings of every target — fully resolved, and resolved except for the
        // leaf — for the reason on `forbidden` above. The two are the same string for
        // anything that is not a symlink, so this only ever adds the entry that was
        // missing.
        var targets = Set(forbiddenTargets.flatMap {
            [PathGuard.canonicalise($0), PathGuard.canonicaliseKeepingLeaf($0)]
        }.compactMap { $0?.lowercased() })
        targets.insert("/")
        targets.insert(FileManager.default.homeDirectoryForCurrentUser.path.lowercased())
        if let home = PathGuard.canonicalise(FileManager.default.homeDirectoryForCurrentUser.path) {
            targets.insert(home.lowercased())
        }
        self.forbidden = targets
    }

    /// Returns the canonical, leaf-attached path that was actually checked.
    ///
    /// Callers must act on the returned string and never on the string they passed in.
    /// The guard resolves the parent to decide, so the approved path and the supplied
    /// path can name the same item through different strings; deleting the supplied one
    /// would be acting on something the guard never checked. Deliberately not
    /// `@discardableResult`, so ignoring the verdict is a compiler warning.
    public func validate(_ path: String) throws -> String {
        // A relative path (including "") resolves against the current working directory,
        // so the verdict would depend on where the process happens to be running.
        guard path.hasPrefix("/") else {
            throw Violation.relativePath(path)
        }
        // "." and ".." as the final component name a directory further up the tree than
        // the path appears to name, and `NSString.appendingPathComponent` keeps them
        // verbatim, so "<root>/anything/.." would pass the allowed-root check while
        // actually pointing at the root. Refuse the form outright rather than collapsing
        // it: collapsing would also resolve a symlink at the leaf.
        let leaf = PathGuard.finalComponent(of: path)
        guard leaf != ".", leaf != ".." else {
            throw Violation.unsafeFinalComponent(path)
        }
        guard let target = PathGuard.canonicaliseKeepingLeaf(path) else {
            throw Violation.unresolvableParent(path)
        }
        // Lower-cased on both sides because macOS volumes are case-insensitive by default,
        // so `<root>/MY-PROJECT` and `<root>/my-project` are one directory. Removing
        // `lowercased()` from either side reopens that hole and is killed by
        // `rejectsForbiddenTargetSpelledInADifferentCase`.
        //
        // Two independent properties keep the NFC/NFD spellings of a name matching here,
        // and no explicit normalisation call is needed:
        //   1. Swift's `String` comparison and hashing use canonical equivalence, so both
        //      spellings are one key in this `Set`, and `lowercased()` preserves that.
        //   2. `canonicaliseKeepingLeaf` rebuilds the leaf through `URL`, which decomposes
        //      it, so both sides also happen to agree byte for byte.
        // Either alone is sufficient today, so `refuses…InADifferentUnicodeNormalisation`
        // pins the refusal behaviour but does NOT fail if only one is broken — verified.
        // Breaking both together (comparing bytes or `[UInt8]` here AND reading the leaf
        // off the raw string in `canonicaliseKeepingLeaf`) opens a real bypass with no
        // test standing in the way. Change either with the other in view.
        if forbidden.contains(target.lowercased()) {
            throw Violation.forbiddenTarget(path)
        }
        let isInsideRoot = canonicalRoots.contains { root in
            // Case-sensitive on purpose: a spelling that differs only by case fails this
            // check and is refused, which is the safe direction.
            let prefix = root.hasSuffix("/") ? root : root + "/"
            // `target != root` is defence in depth only. It is load-bearing solely when a
            // canonical root ends in "/", which `realpath` produces only for "/", and the
            // forbidden set already refuses "/" above. For every other root the trailing
            // slash in `prefix` is what excludes the root itself.
            return target != root && target.hasPrefix(prefix)
        }
        // Case-sensitive here too, for the same reason as the root test above: a
        // spelling that differs only by case fails and is refused, which is the safe
        // direction. This can only ever add the exact strings the caller listed — never
        // a sibling, never a child, never the parent.
        guard isInsideRoot || exactPaths.contains(target) else {
            throw Violation.outsideAllowedRoots(path)
        }
        return target
    }

    /// The last component of a path, read from the string itself rather than through
    /// `URL`, so that "." and ".." are still visible here whatever `URL` does with them.
    /// Returns "" for "/".
    static func finalComponent(of path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed = trimmed.dropLast()
        }
        guard let slash = trimmed.lastIndex(of: "/") else { return String(trimmed) }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Fully resolved absolute path. Returns nil when the path does not exist.
    static func canonicalise(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Resolves the parent directory but leaves the final component untouched,
    /// so a symlink at the leaf keeps its own identity.
    static func canonicaliseKeepingLeaf(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let leaf = url.lastPathComponent
        guard !leaf.isEmpty, leaf != "/" else { return canonicalise(path) }
        guard let parent = canonicalise(url.deletingLastPathComponent().path) else { return nil }
        return (parent as NSString).appendingPathComponent(leaf)
    }
}
