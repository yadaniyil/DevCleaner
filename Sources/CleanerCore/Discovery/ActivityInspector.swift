import Foundation

// @unchecked because of the stored FileManager — see Global Constraints.
public struct ActivityInspector: @unchecked Sendable {
    /// Directories whose timestamps say nothing about whether a human is
    /// working on the project. A build folder is touched by the build, not by you.
    static let ignoredDirectories: Set<String> = [
        "build", ".build", "Build", ".dart_tool", "node_modules", "Pods", ".gradle",
        "DerivedData", ".git", ".symlinks", ".fvm", "target", ".idea", ".vscode",
        "Carthage",
    ]

    private let runner: any ProcessRunner
    private let fileManager: FileManager

    public init(runner: any ProcessRunner, fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func lastActivity(of project: DiscoveredProject) -> Date? {
        let fileDate = newestSourceDate(in: project.path)
        let gitDate = gitHeadDate(in: project.path)
        switch (fileDate, gitDate) {
        case (nil, nil):              return nil
        case (let date?, nil):        return date
        case (nil, let date?):        return date
        case (let a?, let b?):        return max(a, b)
        }
    }

    private func newestSourceDate(in root: String) -> Date? {
        var newest: Date?
        var stack = [root]
        while let current = stack.popLast() {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: current) else { continue }
            for entry in entries {
                let child = (current as NSString).appendingPathComponent(entry)
                // `attributesOfItem` does not resolve symlinks, and a link is neither
                // followed nor dated. Following them is what made a scan take an hour:
                // every fvm project's `.fvm/flutter_sdk` points at a complete Flutter
                // SDK, so each project walk re-stat()ed the whole SDK — and a link
                // pointing at an ancestor would keep this stack growing forever.
                guard let attributes = try? fileManager.attributesOfItem(atPath: child),
                      let type = attributes[.type] as? FileAttributeType else { continue }
                switch type {
                case .typeDirectory:
                    guard !Self.ignoredDirectories.contains(entry) else { continue }
                    stack.append(child)
                case .typeRegular:
                    guard let modified = attributes[.modificationDate] as? Date else { continue }
                    if newest == nil || modified > newest! { newest = modified }
                default:
                    continue
                }
            }
        }
        return newest
    }

    private func gitHeadDate(in root: String) -> Date? {
        let gitDirectory = (root as NSString).appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: gitDirectory) else { return nil }
        guard let result = try? runner.run("/usr/bin/git", ["-C", root, "log", "-1", "--format=%ct"]),
              result.succeeded,
              let epoch = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
