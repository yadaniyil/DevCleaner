import Testing
import Foundation
@testable import CleanerCore

private func guardFor(_ temp: TempDir, forbidden: [String] = []) -> PathGuard {
    PathGuard(allowedRoots: [temp.path + "/allowed"], forbiddenTargets: forbidden)
}

/// The temporary directory as `realpath` sees it. On macOS the temporary directory sits
/// under `/var`, which is itself a symlink to `/private/var`, so the guard's canonical
/// form never matches `temp.path` literally.
private func canonical(_ temp: TempDir) -> String {
    PathGuard.canonicalise(temp.path)!
}

@Test func acceptsPathInsideAllowedRoot() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed/caches/build")
    let sut = guardFor(temp)
    let approved = try sut.validate(temp.path + "/allowed/caches/build")
    #expect(approved == canonical(temp) + "/allowed/caches/build")
}

@Test func acceptsPathThatDoesNotExistYet() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed/caches")
    let sut = guardFor(temp)
    let approved = try sut.validate(temp.path + "/allowed/caches/not-there")
    #expect(approved == canonical(temp) + "/allowed/caches/not-there")
}

@Test func rejectsPathOutsideAllowedRoot() throws {
    let temp = TempDir()
    // The allowed root must exist, otherwise it canonicalises to nil, the guard holds no
    // roots at all, and this test would pass without ever comparing the candidate against
    // a root.
    temp.makeDirectory("allowed")
    temp.makeDirectory("elsewhere/build")
    let sut = guardFor(temp)
    #expect(throws: PathGuard.Violation.self) {
        try sut.validate(temp.path + "/elsewhere/build")
    }
}

@Test func rejectsTheAllowedRootItself() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed")
    let sut = guardFor(temp)
    #expect(throws: PathGuard.Violation.self) {
        try sut.validate(temp.path + "/allowed")
    }
}

@Test func rejectsEscapeThroughSymlinkedParent() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed")
    temp.makeDirectory("outside/secrets")
    temp.makeSymlink("allowed/escape", to: temp.path + "/outside")
    let sut = guardFor(temp)
    #expect(throws: PathGuard.Violation.self) {
        try sut.validate(temp.path + "/allowed/escape/secrets")
    }
}

@Test func acceptsSymlinkAtTheLeafSoItIsRemovedAsALink() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed")
    temp.makeDirectory("outside/secrets")
    temp.makeSymlink("allowed/link", to: temp.path + "/outside/secrets")
    let sut = guardFor(temp)
    let approved = try sut.validate(temp.path + "/allowed/link")
    // The link itself, not what it points at. Deleting the resolved form would destroy
    // the target directory instead of the link.
    #expect(approved == canonical(temp) + "/allowed/link")
}

@Test func rejectsRootDirectory() throws {
    let temp = TempDir()
    let sut = PathGuard(allowedRoots: ["/"], forbiddenTargets: [])
    // The exact case, not just `Violation.self`: "/" is refused by two independent rules,
    // and a type-only assertion cannot tell which one fired.
    #expect(throws: PathGuard.Violation.forbiddenTarget("/")) { try sut.validate("/") }
    _ = temp
}

@Test func rejectsExplicitlyForbiddenTarget() throws {
    let temp = TempDir()
    let project = temp.makeDirectory("allowed/my-project")
    let sut = guardFor(temp, forbidden: [project])
    #expect(throws: PathGuard.Violation.self) { try sut.validate(project) }
    // but a build folder inside it is fine
    temp.makeDirectory("allowed/my-project/build")
    let approved = try sut.validate(project + "/build")
    #expect(approved == canonical(temp) + "/allowed/my-project/build")
}

@Test func rejectsForbiddenTargetSpelledInADifferentCase() throws {
    let temp = TempDir()
    let project = temp.makeDirectory("allowed/my-project")
    let sut = guardFor(temp, forbidden: [project])
    // Same directory on a case-insensitive volume, different spelling. The guard
    // re-attaches the final component verbatim, so a case-sensitive set lookup would
    // walk straight past the rule.
    let shouted = temp.path + "/allowed/MY-PROJECT"
    // The exact case, not `Violation.self`: a guard that refused this spelling for some
    // other reason would keep a type-only assertion green while the forbidden rule was
    // still bypassable.
    #expect(throws: PathGuard.Violation.forbiddenTarget(shouted)) {
        try sut.validate(shouted)
    }
}

@Test func refusesForbiddenTargetSuppliedInADifferentUnicodeNormalisation() throws {
    let temp = TempDir()
    // Created and registered with the decomposed spelling of "é" (U+0065 U+0301), which is
    // also the form this volume stores, so that is what `realpath` puts in the forbidden
    // set. Supplied with the composed spelling (U+00E9): same directory, different bytes.
    let project = temp.makeDirectory("allowed/Cafe\u{0301}")
    let sut = guardFor(temp, forbidden: [project])
    let composed = temp.path + "/allowed/Caf\u{00E9}"
    #expect(Array(composed.utf8) != Array(project.utf8))
    #expect(throws: PathGuard.Violation.forbiddenTarget(composed)) {
        try sut.validate(composed)
    }
}

@Test func rejectsPathWhoseParentDoesNotExist() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed")
    let sut = guardFor(temp)
    let candidate = temp.path + "/allowed/missing-parent/child"
    // Asserting the exact case, not just `Violation.self`: an unresolvable parent means
    // the path was never canonicalised, so the allowed-root check would be comparing a raw
    // string. A guard that dropped this rule would still throw `outsideAllowedRoots` here
    // and a type-only assertion would not notice, while
    // `<root>/missing-parent/../../../etc` would slip through the prefix check.
    #expect(throws: PathGuard.Violation.unresolvableParent(candidate)) {
        try sut.validate(candidate)
    }
}

@Test func rejectsDotDotTraversalOutOfRoot() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed/caches")
    temp.makeDirectory("outside")
    let sut = guardFor(temp)
    #expect(throws: PathGuard.Violation.self) {
        try sut.validate(temp.path + "/allowed/caches/../../outside")
    }
}

@Test func rejectsDotDotAsTheFinalComponent() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed/keep-me")
    let sut = guardFor(temp)
    let candidate = temp.path + "/allowed/keep-me/.."
    // This names the allowed root itself. Without the rule it passes the prefix check,
    // because the final component is re-attached verbatim, and the caller would delete
    // the whole root.
    #expect(throws: PathGuard.Violation.unsafeFinalComponent(candidate)) {
        try sut.validate(candidate)
    }
}

@Test func rejectsDotAsTheFinalComponent() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed/caches")
    let sut = guardFor(temp)
    let candidate = temp.path + "/allowed/."
    #expect(throws: PathGuard.Violation.unsafeFinalComponent(candidate)) {
        try sut.validate(candidate)
    }
}

@Test func acceptsDotDotThatStaysInsideTheRoot() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed/caches/build")
    let sut = guardFor(temp)
    let approved = try sut.validate(temp.path + "/allowed/caches/../caches/build")
    // Accepted, and the approved form is the resolved one. This is why `validate` returns
    // a path: the caller must delete this, not the string it supplied.
    #expect(approved == canonical(temp) + "/allowed/caches/build")
}

@Test func rejectsRelativePath() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed/caches")
    let sut = guardFor(temp)
    #expect(throws: PathGuard.Violation.relativePath("allowed/caches")) {
        try sut.validate("allowed/caches")
    }
}

@Test func rejectsEmptyPath() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed")
    let sut = guardFor(temp)
    // "" resolves to the current working directory, so without this rule the verdict
    // would depend on where the process was started.
    #expect(throws: PathGuard.Violation.relativePath("")) {
        try sut.validate("")
    }
}

@Test func rejectsSiblingWhoseNameStartsWithTheRootName() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed")
    temp.makeDirectory("allowed-sibling/build")
    let sut = guardFor(temp)
    // "<temp>/allowed-sibling/build" begins with "<temp>/allowed". Only the trailing
    // slash on the root keeps this out.
    #expect(throws: PathGuard.Violation.outsideAllowedRoots(temp.path + "/allowed-sibling/build")) {
        try sut.validate(temp.path + "/allowed-sibling/build")
    }
}

// MARK: - exact allowances

/// An exact allowance is for the case where the one path a scanner emits has a parent
/// that must stay out of reach — `~/fvm/cache.git` beside `~/fvm/default`. It has to
/// grant that one path and nothing around it: not the parent, not a sibling, not a
/// child, and not a name that merely starts the same.
@Test func anExactlyAllowedPathIsAcceptedAndGrantsNothingAroundIt() throws {
    let temp = TempDir()
    let exact = temp.makeDirectory("fvm/cache.git")
    temp.makeDirectory("fvm/default")
    temp.makeDirectory("fvm/cache.github")
    temp.makeDirectory("fvm/cache.git/objects")
    let sut = PathGuard(allowedRoots: [temp.path + "/allowed"], forbiddenTargets: [],
                        allowedExactPaths: [exact])

    #expect(try sut.validate(exact) == canonical(temp) + "/fvm/cache.git")
    for other in ["fvm", "fvm/default", "fvm/cache.github", "fvm/cache.git/objects"] {
        let path = temp.path + "/" + other
        #expect(throws: PathGuard.Violation.outsideAllowedRoots(path)) {
            _ = try sut.validate(path)
        }
    }
}

/// Order matters: the forbidden set is checked first, so an exact allowance can never
/// re-admit something the run is forbidden to touch. Checking the allowance first would
/// make every forbidden target reachable by naming it twice.
@Test func aForbiddenTargetStaysForbiddenEvenWhenItIsAlsoAnExactAllowance() throws {
    let temp = TempDir()
    let project = temp.makeDirectory("dev/sample-project")
    let sut = PathGuard(allowedRoots: [], forbiddenTargets: [project],
                        allowedExactPaths: [project])
    #expect(throws: PathGuard.Violation.forbiddenTarget(project)) { _ = try sut.validate(project) }
}

/// The default keeps every guard built before exact allowances existed identical: with
/// none given, only the roots decide.
@Test func aGuardWithNoExactAllowancesBehavesExactlyAsBefore() throws {
    let temp = TempDir()
    temp.makeDirectory("allowed/caches")
    let outside = temp.makeDirectory("fvm/cache.git")
    let sut = guardFor(temp)
    #expect(throws: Never.self) { _ = try sut.validate(temp.path + "/allowed/caches") }
    #expect(throws: PathGuard.Violation.outsideAllowedRoots(outside)) {
        _ = try sut.validate(outside)
    }
}
