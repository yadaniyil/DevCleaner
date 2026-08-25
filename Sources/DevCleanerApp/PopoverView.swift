import SwiftUI
import AppKit
import DevCleanerUI
import CleanerCore

struct PopoverView: View {
    private enum Sheet: String, Identifiable {
        case cleanupReview
        var id: String { rawValue }
    }

    @Bindable var model: AppModel
    /// Carried down to the footer so Rescan goes through the scheduler. Handing the loop
    /// down is the only way the button and the background interval can share one countdown.
    let scans: BackgroundScanLoop
    @Environment(\.openSettings) private var openSettings
    @State private var sheet: Sheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `model.header`, not a `HeaderModel` built here: the age it shows is a number,
            // and it is measured against the model's own injected clock rather than a
            // second one in this target that no test could pin.
            if let header = model.header {
                HeaderView(model: header)
            } else {
                Text(PopoverText.noScanYet)
                    .font(.callout)
                    .padding(12)
            }
            if let cacheError = model.lastCacheError {
                Text(cacheError).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12)
            }
            // Each branch draws its own rule above itself, so the middle section can be
            // empty without leaving two rules stacked against each other with a gap
            // between them — which is exactly what the popover looks like before the
            // first scan.
            //
            // `showsGroupList`, not `model.result != nil`: whether the list belongs on
            // screen depends on the phase, the scan and the run summary at once, and that
            // choice is `AppModel`'s. A stand-in empty `ScanResult` here would be this view
            // inventing data, and it would draw five empty group headers under the "no scan
            // yet" line that says there are none.
            if model.showsGroupList {
                Divider()
                BodyView(model: model)
            }
            switch model.phase {
            case .idle:
                EmptyView()
            case .scanning(let progress):
                Divider()
                ProgressLine(text: PopoverText.scanning(progress))
            case .running(let progress):
                Divider()
                ProgressLine(text: PopoverText.running(progress))
            }
            // Outside the phase switch, because a finished run is not a phase: the run ends
            // by asking for a fresh scan, and the user goes on reading this while that scan
            // runs in the background. Below the phase switch, so the progress line for that
            // scan sits above the panel rather than pushing it up the popover as it appears
            // and goes away.
            if let summary = model.summary {
                Divider()
                SummaryView(summary: summary) { model.dismissSummary() }
            }

            Divider()
            FooterView(
                model: model,
                scans: scans,
                openSettings: { openSettings() },
                review: { sheet = .cleanupReview })
        }
        .frame(width: PopoverMetrics.width)
        .frame(maxHeight: PopoverMetrics.maxHeight)
        .background(.background)
        .sheet(item: $sheet) { destination in
            switch destination {
            case .cleanupReview:
                CleanupReviewView(model: model, surface: .popover)
            }
        }
        // Reports the event and decides nothing about it. What closing this surface means
        // for the run summary is `AppModel.surfaceClosed`, in the library, where a test can
        // read it — this view cannot even be imported by one. The one fact contributed here
        // is which surface this is, which is the one fact only this view has.
        .onDisappear { model.surfaceClosed(.popover) }
    }
}

extension View {
    /// Wrap onto as many lines as the sentence needs, instead of truncating to one.
    ///
    /// The popover is a fixed 380 points wide and every sentence in it is a whole sentence,
    /// written to be read. Without this the enclosing stack sizes each `Text` at its ideal
    /// width — one line, however long — and what the user gets is
    /// `Simulators, runtimes and emulators are normally removed permanently.…`, with the
    /// part that says there is no undo cut off. Truncation here does not shorten a label;
    /// it removes the warning.
    func wrapped() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}

struct HeaderView: View {
    let model: HeaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(PopoverText.productName, systemImage: "internaldrive")
                .font(.headline)
                .foregroundStyle(.primary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.amountPrefix).font(.callout).foregroundStyle(.secondary)
                Text(model.amountText).font(.system(size: 30, weight: .semibold, design: .rounded))
            }
            if let range = model.rangeText {
                Text(range).font(.caption).foregroundStyle(.secondary).wrapped()
            }
            Text("\(model.freeSpaceText) · \(model.scanAgeText)")
                .font(.caption).foregroundStyle(.secondary).wrapped()
            if let unticked = model.untickedText {
                Text(unticked).font(.caption).foregroundStyle(.secondary).wrapped()
            }
            StackedBar(segments: model.segments)
            ForEach(model.problems, id: \.self) { problem in
                Text(problem).font(.caption).foregroundStyle(.orange).wrapped()
            }
        }
        .help(model.headlineHelp)
        .padding(16)
    }
}

struct StackedBar: View {
    let segments: [BarSegment]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35 + 0.5 * segment.fraction))
                        .frame(width: max(1, geometry.size.width * segment.fraction))
                        .help(segment.helpText)
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct ProgressLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
        .padding(12)
    }
}

/// The expandable body: five groups, each opening onto its rows.
///
/// Every group arrives with its box, its headline, its chevron and — only when it is open —
/// its rows, each row's own tick already resolved. Nothing below this line reads the scan
/// or the selection, so nothing below this line can decide anything about them.
private struct ListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct BodyView: View {
    @Bindable var model: AppModel
    @State private var contentHeight: CGFloat = PopoverMetrics.listMinHeight

    var body: some View {
        ScrollView {
            // `VStack`, not `LazyVStack`: the measurement below is the height of what is
            // laid out, and a lazy stack lays out only what is already visible. Told it has
            // 44 points it would report 44, get 44 back, and stay one row tall for ever.
            // Every group collapsed is five rows; every group open is 97, which is nothing
            // to lay out at once.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(PopoverBodyModel.groups(from: model)) { group in
                    GroupSectionView(model: model, group: group)
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ListHeight.self, value: proxy.size.height)
            })
        }
        // As tall as the list, within bounds — so five collapsed groups do not leave a void
        // above the warnings, and opening one does not push the Clean button off screen.
        .frame(height: min(
            max(contentHeight, PopoverMetrics.listMinHeight), PopoverMetrics.listMaxHeight))
        .onPreferenceChange(ListHeight.self) { contentHeight = $0 }
    }
}

struct GroupSectionView: View {
    @Bindable var model: AppModel
    let group: PopoverGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                CheckBox(state: group.tick) { on in
                    model.setGroup(group.id, ticked: on)
                }
                // A `Button`, not a tap gesture: it takes keyboard focus and VoiceOver
                // reads it as an action rather than as three unrelated labels. The
                // checkbox stays **outside** it — a button nested in another button's
                // label never receives the click, so ticking a group would stop working.
                Button {
                    model.toggleExpanded(group.id)
                } label: {
                    HStack(spacing: 6) {
                        // The chevron is a picture of the state; the whole row is the
                        // target, so there is no second, smaller one beside the title.
                        Image(systemName: group.chevronSymbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: group.symbolName)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(group.title).font(.headline)
                        Spacer()
                        Text(group.headline).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            if let emptyText = group.emptyText {
                Text(emptyText)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 52).padding(.bottom, 8)
            }
            // Empty while the group is closed, so `LazyVStack` builds five views instead of
            // a hundred on every redraw.
            ForEach(group.rows) { row in
                RowView(model: model, row: row)
            }
        }
    }
}

struct RowView: View {
    @Bindable var model: AppModel
    let row: PopoverRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckBox(state: row.tick) { on in
                model.setTicked(on, for: row.id)
            }
            .disabled(!row.isEnabled)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(row.name).font(.body)
                    ForEach(row.tags, id: \.self) { tag in
                        Text(tag.text)
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
                            .help(tag.help)
                    }
                }
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).wrapped()
                }
                // Always shown. Two representative protected projects are both named
                // `shared-project-name`, both 13.6 MB, with the same detail text.
                Text(row.target)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(row.sizeText).font(.caption).monospacedDigit()
        }
        .opacity(row.isEnabled ? 1 : 0.55)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// One control for both a row's box and a group's, so the mixed state is drawn in exactly
/// one place. SwiftUI's `Toggle` has two states and cannot show the third.
struct CheckBox: View {
    let state: GroupTick
    let action: (Bool) -> Void

    var body: some View {
        Button {
            action(state.ticksOnClick)
        } label: {
            Image(systemName: state.symbolName)
        }
        .buttonStyle(.plain)
    }
}

struct SummaryView: View {
    let summary: RunSummaryModel
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.trashedText)
                Text(summary.permanentText)
                Text(summary.freeSpaceText)
                Text(summary.threeNumbersNote).font(.caption).foregroundStyle(.secondary)
                if let note = summary.emptyTrashNote {
                    Text(note).font(.caption)
                }
                ForEach(summary.unfinished, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.orange)
                }
                ForEach(summary.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let url = summary.logURL {
                        Button(PopoverText.openRunLog) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Button(PopoverText.done, action: done)
                }
            }
            .padding(12)
        }
    }
}

struct FooterView: View {
    @Bindable var model: AppModel
    let scans: BackgroundScanLoop
    let openSettings: () -> Void
    let review: () -> Void

    var body: some View {
        let footer = FooterModel(
            selection: model.selection, moveToTrash: model.settings.moveToTrash)
        VStack(alignment: .leading, spacing: 10) {
            if !footer.warnings.isEmpty {
                WarningCallout(warnings: footer.warnings)
            }
            Text(footer.splitText).font(.caption).foregroundStyle(.secondary).wrapped()
            HStack(spacing: 8) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(PopoverText.settings)
                // Through the loop, not straight to the model: the scheduler holds the
                // countdown, and a manual scan it never hears about leaves the background
                // interval due a minute later. `BackgroundScanLoop.rescan` says the rest.
                Button {
                    Task { await scans.rescan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                    .disabled(model.isBusy)
                .help(PopoverText.rescan)
                Button(PopoverText.quit) { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                Spacer(minLength: 12)
                if model.isBusy {
                    Button(PopoverText.cancel) { model.cancel() }
                        .help(PopoverText.cancelHelp(phase: model.phase))
                } else {
                    Button(footer.cleanTitle, action: review)
                        .buttonStyle(.borderedProminent)
                        .disabled(!footer.isCleanEnabled)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
    }
}

struct WarningCallout: View {
    let warnings: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { warning in
                    Text(warning).font(.caption).wrapped()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.orange.opacity(0.22), lineWidth: 1)
        }
    }
}

struct CleanupReviewView: View {
    @Bindable var model: AppModel
    /// The surface this sheet was opened from, handed on to `startClean` so the summary of
    /// the run belongs to the surface the user is watching it on.
    let surface: AppModel.Surface
    @Environment(\.dismiss) private var dismiss

    private var selectedItems: [CleanupItem] { model.selection?.selectedItems ?? [] }
    private var footer: FooterModel {
        FooterModel(selection: model.selection, moveToTrash: model.settings.moveToTrash)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PopoverText.reviewCleanup).font(.title2.weight(.semibold))
                Text(PopoverText.selectedItemCount(selectedItems.count))
                    .foregroundStyle(.secondary)
            }

            if !footer.warnings.isEmpty {
                WarningCallout(warnings: footer.warnings)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(selectedItems) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.method.path == nil
                                  ? "exclamationmark.triangle" : "trash")
                                .foregroundStyle(item.method.path == nil ? .orange : .secondary)
                                .frame(width: 18)
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Text(ByteText.short(item.sizeBytes))
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 260)

            Text(footer.splitText).font(.callout).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(PopoverText.cancel) { dismiss() }
                Button(PopoverText.confirmationTitle(
                    bytes: model.selection?.selectedBytes ?? 0), role: .destructive) {
                    if model.startClean(from: surface) { dismiss() }
                }
                .disabled(selectedItems.isEmpty || model.isBusy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
