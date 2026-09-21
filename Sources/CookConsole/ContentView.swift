import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            switch store.consoleLayout {
            case .compactStrip:
                RecipeLibraryView()
            case .splitView:
                RecipeWorkspaceView()
            }
        }
        .onAppear(perform: syncConsoleLayout)
        .onChange(of: horizontalSizeClass) { _, _ in syncConsoleLayout() }
        .safeAreaInset(edge: .top) { rootConsoleStrip }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reconcileTimers() }
        }
        .timerCompletionAlert(presentedWhile: .outsideCookSurface)
        .alert("Cook Console", isPresented: errorBinding) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    /// The ONLY place the console layout input is derived: horizontal size
    /// class and nothing else (nil falls back to compact, the safe default).
    /// Code review must keep it that way — see `ConsoleLayout` and
    /// docs/dual-screen-migration.md.
    private func syncConsoleLayout() {
        let input: ConsoleLayoutInput =
            horizontalSizeClass == .regular ? .regular : .compact
        store.applyConsoleLayout(input: input)
    }

    /// Root copy of the console strip: mounted ONLY in compact width and
    /// only while the cook cover is down. It pins to the TOP edge on
    /// purpose — a bottom safe-area inset competed with the bottom-anchored
    /// Cook button and pushed its hit point to {-1,-1} (runs
    /// 35513947368/35516090570). The cook cover keeps its own #4 inline
    /// timer wall, so exactly one timer-control surface is ever mounted and
    /// shared identifiers ("Pause timer", …) are never duplicated.
    @ViewBuilder
    private var rootConsoleStrip: some View {
        if store.consoleLayout == .compactStrip, !store.isCookSurfaceActive {
            ConsoleStripView()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}

enum CompletionAlertSurface {
    /// Present only while Cook Mode's cover is NOT mounted (the root alert).
    case outsideCookSurface
    /// Present only while Cook Mode's cover IS mounted.
    case cookSurface
}

private struct TimerCompletionAlertModifier: ViewModifier {
    @EnvironmentObject private var store: AppStore
    let surface: CompletionAlertSurface

    func body(content: Content) -> some View {
        content.alert("Timer Finished", isPresented: isPresented) {
            Button("OK") { store.acknowledgePresentedCompletion() }
        } message: {
            Text(store.completedTimerMessage ?? "")
        }
    }

    private var surfaceOwnsAlert: Bool {
        switch surface {
        case .outsideCookSurface: return !store.isCookSurfaceActive
        case .cookSurface: return store.isCookSurfaceActive
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { surfaceOwnsAlert && store.completedTimerMessage != nil },
            set: { presented in
                guard !presented, surfaceOwnsAlert else { return }
                // SwiftUI writes false only when the alert has actually gone
                // away. Treat it as the dismissal signal: the queue advances
                // from there, never from the OK action itself, so a
                // dismissal write can never acknowledge a second timer and a
                // new alert never races the old alert's dismissal window.
                store.completionAlertDismissed()
            }
        )
    }
}

extension View {
    func timerCompletionAlert(presentedWhile surface: CompletionAlertSurface) -> some View {
        modifier(TimerCompletionAlertModifier(surface: surface))
    }
}
