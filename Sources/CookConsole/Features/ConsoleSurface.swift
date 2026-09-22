import SwiftUI

/// The console wall pinned as a strip above the root library/detail content
/// (compact width, cook cover down). Renders nothing (zero inset) while no
/// cook session is active, so idle screens keep the pre-#5 layout exactly.
///
/// Cook Mode deliberately keeps its own inline timer wall (see
/// CookModeView): mounting this strip inside the cover changed the step
/// pager's safe-area geometry in hosted simulators and turned taps on the
/// pager into {-1,-1} hit points (run 35513947368 — three UI regressions,
/// all "step never advances after Next"). One control surface per screen
/// also keeps the timer identifiers unique.
struct ConsoleStripView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if store.consoleSnapshot.status != .idle {
            ConsoleWall()
                .background(.regularMaterial)
                .accessibilityIdentifier("Console strip")
        }
    }
}

/// Regular-width console pane: the leading column of the split layout —
/// the surface `docs/dual-screen-migration.md` names as the future iPhone
/// Duo secondary-display binding. While Cook Mode's full-screen cover is
/// mounted it shows a progress hint instead of the wall: the cover carries
/// its own #4 inline timer wall, and a second mounted copy of the same
/// timer-control identifiers behind it would duplicate them in the
/// hierarchy.
struct ConsoleSplitPane: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.consoleSnapshot.status == .idle {
                ContentUnavailableView(
                    "No active cook",
                    systemImage: "timer",
                    description: Text("Start cooking to see the step and timer wall here.")
                )
                .accessibilityIdentifier("Console idle hint")
            } else if store.isCookSurfaceActive {
                ContentUnavailableView(
                    "Cook in progress",
                    systemImage: "flame",
                    description: Text("The cook surface is showing the timer wall.")
                )
                .accessibilityIdentifier("Console cooking hint")
            } else {
                ConsoleWall()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The split-pane identifier rides on a dedicated Color layer, NOT
        // on the Group above: a bare-group `.accessibilityIdentifier` never
        // resolves in the AX tree (proven in run 6 — the iPad hierarchy
        // showed every console element carrying the workspace id instead),
        // and identifiers attached to ContentUnavailableView never resolve
        // either (run 5). A Color with `.accessibilityElement()` is always
        // an AX element, so the id resolves in every pane state (idle hint,
        // cooking hint, wall) without shadowing child elements (clear +
        // contain semantics leave children in the tree).
        .background(
            Color.clear
                .accessibilityElement()
                .accessibilityLabel("Console split pane")
                .accessibilityIdentifier("Console split pane")
        )
        .background(.fill.quaternary)
    }
}

/// Glanceable wall: Now/Next step cards, one full-width timer row per
/// active timer, and the session's recipe title. The wall sizes to its
/// content (a handful of concurrent timers is the MVP bound), so every
/// control has an on-screen hit target in both layouts. Every action
/// routes through `AppStore`, so a timer paused from the wall behaves
/// exactly like one paused from Cook Mode's inline section — the handlers
/// are literally the same store methods.
private struct ConsoleWall: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if case let .cooking(recipeTitle, currentStep, nextStep) = store.consoleSnapshot.status {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    ConsoleStepCard(step: currentStep, isCurrent: true)
                    if let nextStep {
                        ConsoleStepCard(step: nextStep, isCurrent: false)
                    }
                }
                ForEach(store.consoleSnapshot.activeTimers) { timer in
                    ConsoleTimerTile(timer: timer)
                }
                Text(recipeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("Console recipe title")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Console")
            .accessibilityIdentifier("Console wall")
        }
    }
}

private struct ConsoleStepCard: View {
    let step: ConsoleSnapshot.ActiveStep
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isCurrent ? "Now" : "Next")
                .font(.caption.bold())
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text("Step \(step.number)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(step.instruction)
                .font(isCurrent ? .headline : .subheadline)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isCurrent ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.fill.tertiary),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isCurrent ? "Console current step" : "Console next step")
    }
}

/// Console-local timer row. Cook Mode keeps its own inline section
/// (#4) while its cover is up, so exactly one of the two is ever mounted;
/// the identifiers match the #4 suite's on purpose — the controls route to
/// the same `AppStore` methods, making the two surfaces behaviorally
/// equivalent ("Pause timer", "Resume timer", "Extend timer by 2 minutes",
/// "Cancel timer", "Timer remaining <id>", "Timer <id>").
private struct ConsoleTimerTile: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    let timer: CookTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timer.remaining(at: context.date)
            let state = TimerNarration.visualState(status: timer.status, remaining: remaining)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.stepName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(TimerDisplayFormatter.string(remaining))
                        .font(.system(.title3, design: .monospaced).bold())
                        .foregroundStyle(timerColor(for: state))
                        .accessibilityLabel("\(timer.stepName) timer")
                        .accessibilityValue("\(TimerNarration.remaining(remaining)), \(state.accessibilityWord)")
                        .accessibilityIdentifier("Timer remaining \(timer.id.uuidString)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    if timer.status == .running {
                        Button("Pause") { store.pauseTimer(id: timer.id) }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("Pause timer")
                    } else {
                        Button("Resume") { store.resumeTimer(id: timer.id) }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("Resume timer")
                    }
                    Button("+2") { store.extendTimer(id: timer.id, seconds: 120) }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Extend timer by 2 minutes")
                    Button("+5") { store.extendTimer(id: timer.id, seconds: 300) }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Extend timer by 5 minutes")
                    Button("Cancel", role: .destructive) { store.cancelTimer(id: timer.id) }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("Cancel timer")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Timer \(timer.id.uuidString)")
        }
    }

    /// Same WCAG-AA state tokens as CookModeView's TimerTile; both console
    /// surfaces must speak and look the same for state changes.
    private func timerColor(for state: TimerVisualState) -> Color {
        let isDark = colorScheme == .dark
        switch state {
        case .nearZero:
            return TimerStatePalette.nearZeroText(isDark: isDark)
        case .done:
            return TimerStatePalette.doneText(isDark: isDark)
        case .running, .paused, .cancelled:
            return TimerStatePalette.runningText(isDark: isDark)
        }
    }
}
