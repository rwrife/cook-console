import SwiftUI

struct CookModeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
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

                                if store.notificationAuthorization == .denied,
                                   !activeTimers.isEmpty {
                                    Label(
                                        "Notifications are off. Keep Cook Console open for on-screen timer alerts.",
                                        systemImage: "bell.slash"
                                    )
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .accessibilityIdentifier("Timer notification fallback")
                                }

                                // Issue #5: the timer wall is no longer an
                                // inline section — the same ConsoleWall the
                                // root strip shows is now pinned as a strip
                                // above this content via safeAreaInset, so
                                // timers stay glanceable while steps change.
                            }
                        }

                        HStack(spacing: 16) {
                            Button {
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
                                    end(as: .completed)
                                } label: {
                                    Label("Complete", systemImage: "checkmark")
                                        .frame(maxWidth: .infinity, minHeight: 60)
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button {
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
        // #5 console seam: the wall pins above the cook content itself, so
        // it survives rotation and stays mounted for every layout.
        .safeAreaInset(edge: .bottom) { ConsoleStripView() }
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
                Label(
                    "Start \(TimerDisplayFormatter.string(duration)) timer",
                    systemImage: "timer"
                )
                .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("Start step timer")
        }
    }

    private var activeTimers: [CookTimer] {
        store.timers.filter { $0.status == .running || $0.status == .paused }
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

enum TimerDisplayFormatter {
    static func string(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}
