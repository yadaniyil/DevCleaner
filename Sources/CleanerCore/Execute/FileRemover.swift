import Foundation

/// How the Executor gets rid of a path.
///
/// A protocol rather than a direct `FileManager` call because `trashItem` moves items
/// into the real `~/.Trash`. If the Executor called it directly, every run of the test
/// suite would fill the developer's own Trash with hundreds of temporary directories.
/// The tests inject a double that records the call and deletes the file, so the "gone
/// from its original path" assertions still mean something.
///
/// `SystemFileRemover` itself is tested directly as well, because a double cannot show
/// that the shipped call leaves a symlink's target alone: `remove` in the ordinary
/// suite, and `trash` behind `DEVCLEANER_REAL_TRASH=1`, which is opt-in because it
/// moves a scratch file into the developer's own `~/.Trash` and takes it out again.
public protocol FileRemoving: Sendable {
    /// Moves the item to the Trash. Returns where it landed, so the run log can
    /// tell the user where to find it. Never follows a symlink — a link is moved
    /// as a link.
    func trash(_ path: String) throws -> String

    /// Removes the item outright. Never follows a symlink.
    func remove(_ path: String) throws
}

public struct SystemFileRemover: FileRemoving {
    public init() {}

    public func trash(_ path: String) throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        // `resultingItemURL` is the Trash location. It is documented as optional, and
        // falling back to the original path keeps the entry readable rather than empty;
        // the item is gone from there either way.
        return (resulting as URL?)?.path ?? path
    }

    public func remove(_ path: String) throws {
        // `removeItem` unlinks a symlink itself and never follows it, which is what
        // keeps a `build` that points at another disk from destroying that disk.
        try FileManager.default.removeItem(atPath: path)
    }
}
