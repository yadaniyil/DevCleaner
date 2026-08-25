import Foundation
import CleanerCore

// devcleaner — the command line front end to `CleanerCore`.
//
// This file is deliberately thin. It cannot be imported by a test, so anything decided
// here is only checkable by running the binary — and the one path that removes data must
// not be run to be checked. Every string, every argument rule and the confirmation itself
// live in `CleanerCore`; what is left here is the order the steps happen in.
//
// Top-level `await` is why the file is named `main.swift`.

// The one clock read in the whole tool. Everything below is handed this value, exactly as
// every scanner is handed `ScanContext.now`, so nothing downstream reads the wall clock.
let now = Date()
let home = FileManager.default.homeDirectoryForCurrentUser.path
let service = CleanerService.makeDefault()
let text = ReportText(home: home)

switch CLIParser.parse(Array(CommandLine.arguments.dropFirst())) {

case .usage:
    Output.report(CLIText.usage)

case .invalid(let message):
    // On standard error, and 64 — `EX_USAGE`. An argument list this tool did not fully
    // understand never becomes a clean.
    Output.status(message)
    Output.status("")
    Output.status(CLIText.usage)
    exit(64)

case .scan:
    let result = await Output.runScan(service, now: now)
    Output.report(text.scan(result, now: now, moveToTrash: service.settings().moveToTrash))

case .protect:
    Output.report(text.protection(await service.protectionSummary(now: now)))

case .dryRun:
    let result = await Output.runScan(service, now: now)
    // The list to *show*. What a real clean removes is decided by
    // `CleanerService.cleanDefault` in the `.clean` branch below, not here — that is a
    // method a test can call, and this file is not.
    let selected = result.defaultSelection
    guard !selected.isEmpty else {
        Output.report("Nothing to clean.")
        exit(0)
    }
    Output.report(text.plan(
        items: selected,
        warnings: service.warnings(for: selected),
        moveToTrash: service.settings().moveToTrash))
    Output.report("")
    Output.report("This was a dry run. \(CleanConfirmation.stopped)")

case .clean:
    let result = await Output.runScan(service, now: now)
    let selected = result.defaultSelection
    guard !selected.isEmpty else {
        Output.report("Nothing to clean.")
        exit(0)
    }

    // The whole list, and the permanence warning, before the question is asked. There is
    // no Trash to look in afterwards for the simulators and emulators in it.
    Output.report(text.plan(
        items: selected,
        warnings: service.warnings(for: selected),
        moveToTrash: service.settings().moveToTrash))
    Output.report("")

    guard Output.standardInputIsATerminal else {
        Output.status(CleanConfirmation.needsATerminal)
        exit(1)
    }
    guard Output.askToConfirm() else {
        Output.report(CleanConfirmation.stopped)
        exit(0)
    }

    // `cleanDefault(result:)`, not `clean(items: selected)`. The two remove the same rows,
    // and the difference is that the first one is a method a test calls with a pinned
    // scan result while this file cannot be imported by a test target at all. The one
    // decision that destroys data does not live here.
    let record = await service.cleanDefault(result, now: now) {
        Output.status(CLIText.progress($0))
    }
    Output.report("")
    Output.report(text.run(record))
    exit(record.failedCount > 0 ? 1 : 0)
}
