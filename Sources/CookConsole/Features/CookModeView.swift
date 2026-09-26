import SwiftUI
import UIKit

struct CookModeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let recipe: Recipe

    @State private var session: CookSession?
    @State private var progress: CookProgress?
    @State private var showingAbandonConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if let progress {
                    VStack(spacing: 28) {
                        Text("Step \(progress.currentStepIndex + 1) of \(progress.stepCount)")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                Text(recipe.steps[progress.currentStepIndex].instruction)
                                    .font(.largeTitle)
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical)

                                currentStepTimerControls(progress: progress)

                                if let message = NotificationPermissionGuidance.message(
                                    for: store.notificationAuthorization
                                ), !activeTimers.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Label(message, systemImage: "bell.slash")
                                            .font(.callout)
                                            .foregroundStyle(.orange)
                                            .accessibilityIdentifier("Timer notification fallback")

                                        if NotificationPermissionGuidance.showsSettingsLink(
                                            for: store.notificationAuthorization
                                        ) {
                                            Button(NotificationPermissionGuidance.settingsLinkLabel) {
                                                openNotificationSettings()
                                            }
                                            .font(.callout)
                                            .accessibilityIdentifier(NotificationPermissionGuidance.settingsLinkLabel)
                                        }
                                    }
                                }

                                if !activeTimers.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Timers")
                                            .font(.title2.bold())
                                        ForEach(activeTimers) { timer in
                                            TimerTile(timer: timer)
                                        }
                                    }
                                }
                            }
                        }

                        HStack(spacing: 16) {
                            Button {
                                CookHaptics.stepAdvanced()
                                moveBack()
                            } label: {
                                Label("Back", systemImage: "chevron.backward")
                                    .frame(maxWidth: .infinity, minHeight: 60)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Previous step")
                            .disabled(progress.currentStepIndex == 0)

                            if progress.currentStepIndex + 1 == progress.stepCount {
                                Button {
                                    CookHaptics.cookCompleted()
                                    end(as: .completed)
                                } label: {
                                    Label("Complete", systemImage: "checkmark")
                                        .frame(maxWidth: .infinity, minHeight: 60)
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("Complete recipe")
                            } else {
                                Button {
                                    CookHaptics.stepAdvanced()
                                    moveNext()
                                } label: {
                                    Label("Next", systemImage: "chevron.forward")
                                        .frame(maxWidth: .infinity, minHeight: 60)
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel("Next step")
                            }
                        }
                    }
                    .padding(24)
                } else {
                    ProgressView("Starting cook…")
                }
            }
            .navigationTitle(recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Full recipe") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Abandon", role: .destructive) {
                        showingAbandonConfirmation = true
                    }
                }
            }
            .confirmationDialog("Abandon this cook?", isPresented: $showingAbandonConfirmation) {
                Button("Keep Cooking", role: .cancel) {}
                Button("Abandon Cook", role: .destructive) { end(as: .abandoned) }
            } message: {
                Text("The session will be saved as abandoned in local history.")
            }
            .onAppear(perform: begin)
        }
        .onDisappear { store.isCookSurfaceActive = false }
        .interactiveDismissDisabled()
        // Cook-mode-scoped completion alert. A root-level alert bound to the
        // same shared state would race this presentation and *replace* the
        // fullScreenCover — both coordinators present whenever the message is
        // set, and a root presentation displaces the modal — visibly dumping
        // cook mode back onto the detail page. The root copy in ContentView is
        // gated off while `isCookSurfaceActive`, so exactly one coordinator
        // presents at a time and the cover stays mounted.
        .timerCompletionAlert(presentedWhile: .cookSurface)
    }

    private func begin() {
        guard session == nil else { return }
        do {
            let active = try store.beginCook(for: recipe.id)
            session = active
            progress = try CookProgress(
                stepCount: recipe.steps.count,
                currentStepIndex: min(active.currentStepIndex, recipe.steps.count - 1)
            )
            store.loadTimers(cookSessionID: active.id)
        } catch {
            store.present(error)
            dismiss()
        }
    }

    @ViewBuilder
    private func currentStepTimerControls(progress: CookProgress) -> some View {
        let step = recipe.steps[progress.currentStepIndex]
        if let duration = step.timerDuration,
           !activeTimers.contains(where: { $0.stepID == step.id }) {
            Button {
                guard let session else { return }
                do {
                    try store.startTimer(
                        recipeID: recipe.id,
                        step: step,
                        stepNumber: progress.currentStepIndex + 1,
                        cookSessionID: session.id
                    )
                } catch {
                    store.present(error)
                }
            } label: {
                // VoiceOver reads the spoken duration, not "20:00". The
                // visible text keeps the compact mm:ss form; the spoken
                // label overrides for screen readers only.
                Label(
                    "Start \(TimerDisplayFormatter.string(duration)) timer",
                    systemImage: "timer"
                )
                .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Start step timer, \(TimerNarration.durationLabel(duration))")
            .accessibilityIdentifier("Start step timer")
        }
    }

    private var activeTimers: [CookTimer] {
        store.timers.filter { $0.status == .running || $0.status == .paused }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func moveNext() {
        guard var next = progress, next.moveNext() else { return }
        persist(next)
    }

    private func moveBack() {
        guard var next = progress, next.moveBack() else { return }
        persist(next)
    }

    private func persist(_ next: CookProgress) {
        guard let session else { return }
        do {
            try store.updateCookPosition(
                sessionID: session.id,
                to: next.currentStepIndex
            )
            progress = next
        } catch {
            store.present(error)
        }
    }

    private func end(as status: CookSessionStatus) {
        guard let session else { return }
        do {
            try store.endCook(sessionID: session.id, as: status)
            dismiss()
        } catch {
            store.present(error)
        }
    }
}

private struct TimerTile: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    let timer: CookTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timer.remaining(at: context.date)
            let state = TimerNarration.visualState(status: timer.status, remaining: remaining)
            VStack(alignment: .leading, spacing: 10) {
                Text(timer.stepName)
                    .font(.headline)
                    .lineLimit(2)
                Text(TimerDisplayFormatter.string(remaining))
                    .font(.system(.title, design: .monospaced).bold())
                    .foregroundStyle(timerColor(for: state))
                    // VoiceOver gets the spoken form ("1 minute 20 seconds
                    // remaining, running") plus the state word, so timer
                    // state changes are meaningful — not just a digit
                    // string re-read on every tick.
                    .accessibilityLabel("\(timer.stepName) timer")
                    .accessibilityValue("\(TimerNarration.remaining(remaining)), \(state.accessibilityWord)")
                    .accessibilityIdentifier("Timer remaining \(timer.id.uuidString)")
                HStack {
                    if timer.status == .running {
                        Button { store.pauseTimer(id: timer.id) } label: {
                            Text("Pause").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityIdentifier("Pause timer")
                    } else {
                        Button { store.resumeTimer(id: timer.id) } label: {
                            Text("Resume").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityIdentifier("Resume timer")
                    }
                    Button { store.extendTimer(id: timer.id, seconds: 120) } label: {
                        Text("+2").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Extend timer by 2 minutes")
                    Button { store.extendTimer(id: timer.id, seconds: 300) } label: {
                        Text("+5").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Extend timer by 5 minutes")
                    Button(role: .destructive) { store.cancelTimer(id: timer.id) } label: {
                        Text("Cancel").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("Cancel timer")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Timer \(timer.id.uuidString)")
        }
    }

    /// WCAG-AA measured state colors (see TimerStatePalette). Running and
    /// paused ride the primary label color — the state is spoken in the
    /// accessibility value, so color is never the only carrier.
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

enum TimerDisplayFormatter {
    static func string(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}
