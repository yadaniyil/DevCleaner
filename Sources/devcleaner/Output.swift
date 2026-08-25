import Foundation
#if canImport(Darwin)
import Darwin
#endif
import CleanerCore

/// The only place this tool touches the terminal.
///
/// Every sentence it prints is built by `ReportText`, `CLIText` or `CleanConfirmation` in
/// `CleanerCore`, where a test can ask for the string without running the binary. Nothing
/// in this file decides what to say — it decides only which stream to say it on, and it
/// holds the two calls that cannot be unit tested at all: reading a line from the terminal,
/// and asking whether there is a terminal to read from.
enum Output {
    /// The report, on standard output. This is the thing worth redirecting to a file.
    static func report(_ text: String) { print(text) }

    /// Progress, warnings and errors, on standard error.
    ///
    /// Separate from the report so `devcleaner scan > list.txt` writes a clean list while
    /// the user still watches the scan happen, and so `devcleaner scan | less` is not
    /// interleaved with sixteen progress lines.
    static func status(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Runs the scan, saying what it is doing while it does it.
    ///
    /// A scan is about 50 seconds of `du` on a real dev machine. Without this the terminal sits
    /// silent for a minute and looks hung.
    static func runScan(_ service: CleanerService, now: Date) async -> ScanResult {
        status(CLIText.scanStarting)
        let result = await service.scan(now: now) { status(CLIText.progress($0)) }
        status("Scanned \(result.items.count) rows.")
        status("")
        return result
    }

    /// Whether there is a person at a keyboard to answer the confirmation.
    ///
    /// Checked so that `yes | devcleaner clean` and a cron line cannot satisfy the gate.
    /// There is deliberately no non-interactive way to delete; the dry run is the command
    /// that scripts.
    static var standardInputIsATerminal: Bool {
        isatty(FileHandle.standardInput.fileDescriptor) == 1
    }

    /// Asks for the word and returns whether it was typed. Reads one line and no more.
    static func askToConfirm() -> Bool {
        report(CleanConfirmation.prompt)
        print("> ", terminator: "")
        // Without this the prompt can sit in the buffer while the program waits for input,
        // and the user is asked a question they cannot see.
        fflush(stdout)
        return CleanConfirmation.isConfirmed(readLine())
    }
}
