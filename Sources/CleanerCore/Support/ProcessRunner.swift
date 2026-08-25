import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

public protocol ProcessRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult
}

/// Holds the bytes read from a process's two pipes while both are being
/// drained at once. The lock is what makes the concurrent writes safe.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func store(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout { stdout = data } else { stderr = data }
    }

    var values: (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Give the child an immediate EOF on stdin. Inheriting the parent's
        // stdin would let a tool that prompts, such as some avdmanager
        // subcommands, block on the user's terminal instead of failing.
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Both pipes are drained concurrently. Draining one fully before the
        // other deadlocks as soon as the undrained pipe's 64 KB buffer fills,
        // and simctl JSON is far larger than that.
        let captured = CapturedOutput()
        let group = DispatchGroup()

        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            DispatchQueue.global().async(group: group) {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                captured.store(data, isStdout: isStdout)
            }
        }

        group.wait()
        process.waitUntilExit()

        let (outData, errData) = captured.values
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
