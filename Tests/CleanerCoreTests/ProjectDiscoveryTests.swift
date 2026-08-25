import Testing
import Foundation
@testable import CleanerCore

@Test func findsFlutterProjectByPubspec() throws {
    let temp = TempDir()
    temp.makeFile("dev/sample-project/pubspec.yaml")
    let found = ProjectDiscovery().discover(roots: [temp.path + "/dev"])
    #expect(found.count == 1)
    let project = try #require(found.first)
    #expect(project.name == "sample-project")
    // Task 16 feeds this string to PathGuard, so it has to be the absolute path with the
    // components joined by single slashes and no trailing slash — not the parent, not a
    // relative string. Nothing else in the suite reads `path`.
    #expect(project.path == temp.path + "/dev/sample-project")
}

@Test func recognisesSeveralMarkersInOneDirectoryAsOneProject() throws {
    let temp = TempDir()
    temp.makeFile("dev/hybrid/pubspec.yaml")
    temp.makeFile("dev/hybrid/package.json")
    let found = ProjectDiscovery().discover(roots: [temp.path + "/dev"])
    // One row, not one per marker. `DiscoveredProject` used to carry a `Set<ProjectKind>`
    // saying which markers matched; nothing outside `ProjectDiscovery` ever read it, so
    // the type is gone and this asserts what the walk actually has to get right.
    #expect(found.count == 1)
    let project = try #require(found.first)
    #expect(project.name == "hybrid")
}

@Test func recognisesXcodeProjectByBundleDirectory() throws {
    let temp = TempDir()
    temp.makeDirectory("dev/Example/Example.xcodeproj")
    let found = ProjectDiscovery().discover(roots: [temp.path + "/dev"])
    #expect(found.count == 1)
    let project = try #require(found.first)
    #expect(project.name == "Example")
}

/// Every marker the walk recognises, and one directory listing that must not match.
///
/// Standing rule 4: a fixture of only matching entries cannot test a filter. Without the
/// negative case a `isProject` that answered `true` for everything would pass, and
/// `ProjectDiscovery` would report every folder under `~/dev` as a project.
@Test func everyProjectMarkerIsRecognisedAndAnOrdinaryFolderIsNot() {
    for marker in ["pubspec.yaml", "package.json", "build.gradle", "build.gradle.kts",
                   "Cargo.toml", "go.mod", "Example.xcodeproj", "Example.xcworkspace"] {
        #expect(ProjectDiscovery.isProject(["README.md", marker]), "\(marker) not recognised")
    }
    #expect(!ProjectDiscovery.isProject(["README.md", "src", "Makefile", "pubspec.lock"]))
    #expect(!ProjectDiscovery.isProject([]))
}

@Test func doesNotDescendIntoARecognisedProject() throws {
    let temp = TempDir()
    temp.makeFile("dev/sample-project/pubspec.yaml")
    temp.makeFile("dev/sample-project/android/build.gradle")
    temp.makeDirectory("dev/sample-project/ios/Runner.xcodeproj")
    let found = ProjectDiscovery().discover(roots: [temp.path + "/dev"])
    #expect(found.count == 1)
    let project = try #require(found.first)
    #expect(project.name == "sample-project")
}

@Test func findsNestedProjectsUnderAGroupingFolder() {
    let temp = TempDir()
    temp.makeFile("dev/pet-projects/one/pubspec.yaml")
    temp.makeFile("dev/pet-projects/two/package.json")
    let found = ProjectDiscovery().discover(roots: [temp.path + "/dev"])
        .sorted { $0.name < $1.name }
    #expect(found.map(\.name) == ["one", "two"])
}

@Test func stopsAtMaxDepth() {
    let temp = TempDir()
    temp.makeFile("dev/a/b/c/d/e/pubspec.yaml")
    let found = ProjectDiscovery().discover(roots: [temp.path + "/dev"], maxDepth: 3)
    #expect(found.isEmpty)
}

@Test func findsAProjectAtExactlyMaxDepthButNotOneDeeper() {
    let temp = TempDir()
    temp.makeFile("dev/group/atLimit/pubspec.yaml")         // 2 levels below the root
    temp.makeFile("dev/group/nested/tooDeep/pubspec.yaml")  // 3 levels below
    let found = ProjectDiscovery().discover(roots: [temp.path + "/dev"], maxDepth: 2)
    #expect(found.map(\.name) == ["atLimit"])
}

@Test func skipsNodeModulesAndBuildDirectories() {
    let temp = TempDir()
    temp.makeFile("dev/app/package.json")
    temp.makeFile("dev/other/node_modules/leftpad/package.json")
    temp.makeFile("dev/other/build/inner/pubspec.yaml")
    let found = ProjectDiscovery().discover(roots: [temp.path + "/dev"])
    #expect(found.map(\.name) == ["app"])
}

@Test func missingRootIsIgnoredWithoutThrowing() {
    let temp = TempDir()
    let found = ProjectDiscovery().discover(roots: [temp.path + "/does-not-exist"])
    #expect(found.isEmpty)
}
