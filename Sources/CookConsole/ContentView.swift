import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RecipeLibraryView()
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
