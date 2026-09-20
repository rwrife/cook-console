import SwiftUI

/// The timer/step wall pinned as a strip above mounted content (Cook Mode,
/// or the root library in compact width). Renders nothing (zero inset)
/// while no cook session is active, so idle screens keep the pre-#5
/// layout. The wall is self-sizing with no internal scrolling, so no
/// control can ever be clipped off-screen. Callers own layout/surface
/// gating: the root strip only mounts in compact width with the cook cover
/// down; Cook Mode always pins it.
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
/// mounted it shows a progress hint instead of the wall: the cover pins
/// its own strip, and mounting a second copy of the same timer-control
/// identifiers behind the cover would duplicate them in the hierarchy.
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
        .background(.fill.quaternary)
        .accessibilityIdentifier("Console split pane")
    }
}

/// Glanceable wall: the Now/Next step cards on one row, then one full-width
/// timer row per active timer, then the session's recipe title. The wall
/// sizes to its content (a handful of concurrent timers is the MVP bound),
/// so every control has an on-screen hit target in both layouts. Every
/// action routes through `AppStore`, so a timer paused from the wall
/// behaves exactly like one paused from Cook Mode — the wall replaced Cook
/// Mode's inline timer section outright: one control surface, no duplicate
/// handlers or identifiers.
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

/// Console-local timer row. Cook Mode's own inline timer section (#4) was
/// removed in #5 — this row is the app's only timer-wall control surface —
/// and it reuses the exact accessibility identifiers the #4 UI suite
/// asserts on ("Pause timer", "Resume timer", "Extend timer by 2 minutes",
/// "Cancel timer", "Timer remaining <id>", "Timer <id>") so console
/// controls are provably equivalent to the ones they replaced.
private struct ConsoleTimerTile: View {
    @EnvironmentObject private var store: AppStore
    let timer: CookTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.stepName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(TimerDisplayFormatter.string(timer.remaining(at: context.date)))
                        .font(.system(.title3, design: .monospaced).bold())
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
}
