import SwiftUI
import UIKit

struct CookModeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AccessibilityFocusState private var instructionFocused: Bool
    // ponytail: one foreground cook surface; add scene arbitration if multiwindow is enabled.
    let recipe: Recipe
    var initialServings: Double? = nil

    @State private var session: CookSession?
    @State private var progress: CookProgress?
    @State private var showingAbandonConfirmation = false
    @State private var showingIngredients = false

    var body: some View {
        NavigationStack {
            Group {
                if let progress {
                    HStack(spacing: 0) {
                        if horizontalSizeClass == .regular, prep?.swapped == true {
                            prepPane
                            Divider()
                        }
                    VStack(spacing: 28) {
                        Text("Step \(progress.currentStepIndex + 1) of \(progress.stepCount)")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                Text(recipe.steps[progress.currentStepIndex].instruction)
                                    .font(.largeTitle)
                                    .fontWeight(.semibold)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical)
                                    .accessibilityIdentifier("Current instruction")
                                    .accessibilityFocused($instructionFocused)

                                if progress.currentStepIndex + 1 < progress.stepCount {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Next Step Preview")
                                            .font(.caption.bold())
                                            .foregroundStyle(.secondary)
                                        Text(recipe.steps[progress.currentStepIndex + 1].instruction)
                                            .font(.body)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("Next step preview")
                                }

                                currentStepTimerControls(progress: progress)

                                if let message = NotificationPermissionGuidance.message(
                                    for: store.notificationAuthorization
                                ), !activeTimers.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Label(message, systemImage: "bell.slash")
                                            .font(.callout)
                                            .foregroundStyle(.primary)
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

                                Button("Ingredients", systemImage: "list.bullet") {
                                    showingIngredients = true
                                }
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("Ingredients")

                                Toggle("Keep screen awake while cooking", isOn: Binding(
                                    get: { store.keepScreenAwakeWhileCooking },
                                    set: { store.setKeepScreenAwakeWhileCooking($0) }
                                ))
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("Keep screen awake while cooking")
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if horizontalSizeClass == .regular, prep?.swapped != true {
                            Divider()
                            prepPane
                        }
                    }
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
        .safeAreaInset(edge: .top) {
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-report-idle-timer") {
                Text(store.idleTimerDisabled ? "Idle timer disabled" : "Idle timer enabled")
                    .font(.caption2)
                    .accessibilityIdentifier("Idle timer state")
            }
        }
        .sheet(isPresented: $showingIngredients) {
            NavigationStack {
                prepPane
                    .navigationTitle("Prep")
                    .toolbar { Button("Done") { showingIngredients = false } }
            }
        }
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

    private var prep: CookPrep? {
        guard let session else { return nil }
        return store.cookPrepBySession[session.id]
    }

    private func changePrep(_ change: (inout CookPrep) -> Void) {
        guard let session, var value = prep else { return }
        change(&value)
        store.saveCookPrep(value, sessionID: session.id)
    }

    private var prepPane: some View {
        List {
            Section("Prep") {
                Text("Servings: \(RecipeAmountFormatter.string(prep?.servings ?? recipe.servings))")
                    .accessibilityIdentifier("Prep servings")
                HStack {
                    Button("Fewer servings") {
                        changePrep { $0.servings = max(0.5, $0.servings - 0.5) }
                    }
                    .disabled((prep?.servings ?? recipe.servings) <= 0.5)
                    Spacer()
                    Button("More servings") { changePrep { $0.servings += 0.5 } }
                }
                .buttonStyle(.borderless)
                if horizontalSizeClass == .regular {
                    Button("Swap Steps and Prep") { changePrep { $0.swapped.toggle() } }
                        .accessibilityIdentifier("Swap Steps and Prep")
                }
            }
            Section("Ingredients to prepare") {
                ForEach(recipe.ingredients) { ingredient in
                    let scaled = try? ScalingEngine.scaled(
                        ingredient, ratio: (prep?.servings ?? recipe.servings) / recipe.servings
                    )
                    Toggle(isOn: Binding(
                        get: { prep?.checkedIngredientIDs.contains(ingredient.id) ?? false },
                        set: { checked in
                            changePrep {
                                if checked { $0.checkedIngredientIDs.insert(ingredient.id) }
                                else { $0.checkedIngredientIDs.remove(ingredient.id) }
                            }
                        }
                    )) {
                        Text("\(scaled.map { KitchenQuantityFormatter.string($0.displayAmount) } ?? "?") \(ingredient.unit.symbol) \(ingredient.name)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityLabel("\(scaled.map { KitchenQuantityFormatter.string($0.displayAmount) } ?? "?") \(ingredient.unit.symbol) \(ingredient.name)")
                    .accessibilityIdentifier("Cook ingredient \(ingredient.id.uuidString)")
                }
            }
            Section("Equipment") {
                TextField("Equipment (optional)", text: Binding(
                    get: { prep?.equipment ?? "" },
                    set: { equipment in changePrep { $0.equipment = equipment } }
                ), axis: .vertical)
                .accessibilityIdentifier("Prep equipment")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            try store.loadCookPrep(sessionID: active.id, initialServings: initialServings ?? recipe.servings)
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
            instructionFocused = true
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                Text(state.accessibilityWord.capitalized)
                    .font(.subheadline)
                let controls = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 8))
                controls {
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
