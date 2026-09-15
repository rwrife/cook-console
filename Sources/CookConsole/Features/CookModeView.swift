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
                            Text(recipe.steps[progress.currentStepIndex].instruction)
                                .font(.largeTitle)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical)
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
            .alert("Abandon this cook?", isPresented: $showingAbandonConfirmation) {
                Button("Keep Cooking", role: .cancel) {}
                Button("Abandon Cook", role: .destructive) { end(as: .abandoned) }
            } message: {
                Text("The session will be saved as abandoned in local history.")
            }
            .onAppear(perform: begin)
        }
        .interactiveDismissDisabled()
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
        } catch {
            store.present(error)
            dismiss()
        }
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
