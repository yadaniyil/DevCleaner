import Testing
import Foundation
@testable import CleanerCore

@Test func systemRunnerCapturesStdoutAndExitCode() throws {
    let runner = SystemProcessRunner()
    let result = try runner.run("/bin/echo", ["hello"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

@Test func systemRunnerCapturesFailureExitCode() throws {
    let runner = SystemProcessRunner()
    let result = try runner.run("/bin/sh", ["-c", "exit 3"])
    #expect(result.exitCode == 3)
}

@Test func systemRunnerKeepsStdoutAndStderrSeparate() throws {
    let runner = SystemProcessRunner()
    let result = try runner.run("/bin/sh", ["-c", "echo out; echo err 1>&2"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "out")
    #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "err")
    #expect(!result.stdout.contains("err"))
    #expect(!result.stderr.contains("out"))
}

@Test func systemRunnerDrainsBothPipesPastTheBufferLimit() throws {
    let runner = SystemProcessRunner()
    // 8000 lines of 26 letters plus a newline is 216,000 bytes on each stream,
    // more than three times the 64 KB pipe buffer. A runner that read one pipe
    // to the end before starting the other would block here and never return.
    let result = try runner.run("/bin/sh", [
        "-c",
        "yes abcdefghijklmnopqrstuvwxyz | head -n 8000;"
            + " yes ABCDEFGHIJKLMNOPQRSTUVWXYZ | head -n 8000 1>&2",
    ])
    #expect(result.exitCode == 0)
    #expect(result.stdout.utf8.count == 216_000)
    #expect(result.stderr.utf8.count == 216_000)
}

// The stub below is written as a plain space-joined literal on purpose: that is
// how every stub across this package is written, so this also guards that
// `commandKey` keeps producing keys those literals match.
@Test func fakeRunnerReturnsStubbedResponse() throws {
    let runner = FakeProcessRunner(responses: [
        "/usr/bin/xcrun simctl list devices --json": ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
    ])
    let result = try runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"])
    #expect(result.stdout == "{}")
}

@Test func fakeRunnerFailsLoudlyForUnstubbedCommand() throws {
    let runner = FakeProcessRunner(responses: [:])
    let result = try runner.run("/bin/true", [])
    #expect(result.exitCode != 0)
    #expect(result.stderr.contains("no stub"))
}
