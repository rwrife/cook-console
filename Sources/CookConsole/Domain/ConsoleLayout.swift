import Foundation

/// The single seam through which the app decides how the console/detail
/// split is presented (PLAN.md "iPhone Duo migration path").
///
/// Layout selection must derive ONLY from the console layout input below —
/// never from device model, screen geometry, posture, or any other topology
/// assumption. Today the input is produced by the SwiftUI layer purely from
/// the horizontal size class. When Apple ships fold/split-display APIs, that
/// layer will derive the same input from the display partition instead; no
/// domain or view code above this seam changes (see
/// docs/dual-screen-migration.md).
enum ConsoleLayout: String, Equatable, Sendable {
    /// Pinned console strip above the main content (current behavior on
    /// compact-width screens, e.g. iPhone portrait).
    case compactStrip
    /// Console as the leading pane beside the detail surface — the layout
    /// the iPhone Duo's secondary display will bind to.
    case splitView
}

/// The only value the SwiftUI layer may feed into `ConsoleLayout.init`.
/// It intentionally carries just the horizontal size class signal, so a
/// code reviewer can prove no other topology information reaches layout
/// selection.
enum ConsoleLayoutInput: Equatable, Sendable {
    /// The console surface is presented in a compact-width container.
    case compact
    /// The console surface is presented in a regular-width container.
    case regular
}

extension ConsoleLayout {
    /// Total function from the size-class-derived input to the layout.
    init(input: ConsoleLayoutInput) {
        switch input {
        case .compact: self = .compactStrip
        case .regular: self = .splitView
        }
    }
}

/// Glanceable snapshot of the active cook shown by `ConsoleView` — computed
/// from already-published `AppStore` state so it needs no repository access.
struct ConsoleSnapshot: Equatable, Sendable {
    struct ActiveStep: Equatable, Sendable {
        let number: Int
        let instruction: String
    }

    enum Status: Equatable, Sendable {
        /// No active cook session; the console strip is not shown.
        case idle
        case cooking(recipeTitle: String, currentStep: ActiveStep, nextStep: ActiveStep?)
    }

    var status: Status
    var activeTimers: [CookTimer]

    static let idle = ConsoleSnapshot(status: .idle, activeTimers: [])

    /// Builds the console snapshot from store state.
    ///
    /// `currentStepIndex` is clamped into the recipe's step range the same
    /// way `CookModeView.begin` clamps it, so a recipe edited while cooking
    /// (steps removed) can never trap the console in a trapping subscript.
    /// A step count of zero renders `.idle`.
    static func snapshot(
        recipe: Recipe?,
        session: CookSession?,
        timers: [CookTimer]
    ) -> ConsoleSnapshot {
        let active = timers.filter { $0.status == .running || $0.status == .paused }
        guard let recipe,
              let session,
              session.status == .active,
              !recipe.steps.isEmpty
        else {
            return ConsoleSnapshot(status: .idle, activeTimers: active)
        }
        let index = min(max(session.currentStepIndex, 0), recipe.steps.count - 1)
        let current = ActiveStep(number: index + 1, instruction: recipe.steps[index].instruction)
        let next: ActiveStep? =
            index + 1 < recipe.steps.count
            ? ActiveStep(number: index + 2, instruction: recipe.steps[index + 1].instruction)
            : nil
        return ConsoleSnapshot(
            status: .cooking(recipeTitle: recipe.title, currentStep: current, nextStep: next),
            activeTimers: active
        )
    }
}
