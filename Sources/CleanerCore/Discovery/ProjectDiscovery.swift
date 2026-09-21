import Foundation

public struct DiscoveredProject: Sendable, Equatable, Hashable {
    public let path: String
    public let name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

// @unchecked because of the stored FileManager — see Global Constraints.
public struct ProjectDiscovery: @unchecked Sendable {
    /// Directories that never contain a project we care about and can be huge.
    ///
    /// `.build` is listed although the walk already skips every dot-entry below, and the
    /// duplication is deliberate: SwiftPM checks its dependencies out into
    /// `.build/checkouts`, each with a `Package.swift` of its own, so the moment that
    /// marker was added this became the directory with the most false projects inside it.
    /// Naming it here means the answer does not depend on the dot rule outliving it.
    static let skipped: Set<String> = [
        "node_modules", "build", ".build", ".dart_tool", "Pods", "DerivedData", "Carthage",
        ".git", ".gradle", ".symlinks", "vendor", "target",
    ]

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discover(roots: [String], maxDepth: Int = 4) -> [DiscoveredProject] {
        var results: [DiscoveredProject] = []
        for root in roots {
            walk(root, depth: 0, maxDepth: maxDepth, into: &results)
        }
        return results
    }

    private func walk(_ path: String, depth: Int, maxDepth: Int, into results: inout [DiscoveredProject]) {
        guard depth <= maxDepth else { return }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return }

        if Self.isProject(entries) {
            results.append(DiscoveredProject(
                path: path,
                name: (path as NSString).lastPathComponent))
            return  // a project is one unit; its subfolders are not separate projects
        }

        for entry in entries {
            guard !entry.hasPrefix("."), !Self.skipped.contains(entry) else { continue }
            let child = (path as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            walk(child, depth: depth + 1, maxDepth: maxDepth, into: &results)
        }
    }

    /// Whether a directory holding these entries is a project.
    ///
    /// This used to return which **kinds** of project it was, as a `Set<ProjectKind>`
    /// stored on every `DiscoveredProject`. Nothing outside this file ever read it —
    /// computed for all 257 projects on a real dev machine and consulted nowhere — and a
    /// `public` type carried for no reader is a type the next person has to keep working.
    /// What the walk actually needs is the one bit below.
    /// `Package.swift` is the newest marker, and the one whose absence cost the most: a
    /// Swift package with no `.xcodeproj` beside it — which is most of them, this
    /// repository included — matched nothing here, so the walk never reported it and no
    /// scanner ever saw its `.build`. That is 946 MB in one project on a real dev
    /// machine, before its ten `.build-…` siblings.
    static func isProject(_ entries: [String]) -> Bool {
        entries.contains { entry in
            switch entry {
            case "pubspec.yaml", "package.json", "build.gradle", "build.gradle.kts",
                 "Cargo.toml", "go.mod", "Package.swift":
                return true
            default:
                return entry.hasSuffix(".xcodeproj") || entry.hasSuffix(".xcworkspace")
            }
        }
    }
}
