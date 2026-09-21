import SwiftUI
import DevCleanerUI
import CleanerCore

@main
struct DevCleanerApp: App {
    @State private var model: AppModel
    /// Held in `@State` rather than built inside the `.task` below, so the scan schedule
    /// survives whatever SwiftUI decides to do with the label view. A loop rebuilt on the
    /// spot would come with a new `ScanScheduler`, and a new scheduler always agrees to a
    /// launch scan — another full 51 seconds and four more `du` processes, every time.
    @State private var scans: BackgroundScanLoop

    /// Both are built here because the loop needs the model. `@State` initial values cannot
    /// see each other.
    init() {
        let model = AppModel(
            engine: LiveCleanerEngine(),
            cache: ScanCache(directory: ScanCache.defaultDirectory()))
        _model = State(initialValue: model)
        _scans = State(initialValue: BackgroundScanLoop(model: model))
    }

    var body: some Scene {
        // The primary scene, and the only one that cleans: a regular desktop window, opened
        // centred at launch like any other app. First in the body so it, not the menu bar
        // item, is what launching the app means. The menu bar item below is a status
        // item — a glance at the same model, and a button that opens this window.
        //
        // `MainWindowMetrics.sceneID` rather than a literal, because the panel's primary
        // button passes the same string to `openWindow(id:)` and `openWindow` fails
        // silently on an identifier that matches no scene. That constant says why the
        // identifier is `deck`.
        Window(ChromeText.productName, id: MainWindowMetrics.sceneID) {
            MainWindowView(model: model, scans: scans)
        }
        .defaultSize(
            width: MainWindowMetrics.defaultWidth, height: MainWindowMetrics.defaultHeight)
        .defaultPosition(.center)

        MenuBarExtra {
            StatusPanelView(model: model, scans: scans)
        } label: {
            // Every word here comes from `MenuBarLabel`, including the accessibility name:
            // a string a user can read is a string a test must be able to reach, and a test
            // target cannot import this executable.
            Image(systemName: MenuBarLabel.symbolName)
                .accessibilityLabel(MenuBarLabel.accessibilityTitle)
                // On the label, because the label is on screen from the moment the app
                // launches while the panel's content view does not exist until somebody
                // clicks the icon. A `.task` on the content would mean the launch scan
                // never ran for a user who never opened the panel — which is every user
                // who leaves it running in the background, the case this app is for.
                //
                // The loop itself decides nothing here: when to scan is `ScanScheduler`,
                // and how long to wait is `BackgroundScanLoop`, both in the library where
                // tests can reach them.
                .task { await scans.run() }
            // The deck's own default offer, which is also the number the panel under this
            // label prints: `ProjectDeck.defaultOfferBytes` says why it is that total and
            // not the scan's.
            if let text = MenuBarLabel.text(
                deck: model.projectDeck, showsAmount: model.settings.menuBarShowsAmount) {
                Text(text)
            }
        }
        // `.window`, not the default `.menu`: the panel sets a size in large type, draws a
        // spinner beside a progress line and puts a filled primary button under a rule,
        // none of which a menu can do.
        .menuBarExtraStyle(.window)

        // The standard settings window, filled in by Task 11. Declared here so
        // `openSettings` in the footer has a scene to open.
        Settings {
            SettingsWindowView(model: model)
        }
    }
}
