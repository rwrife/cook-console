import Foundation

enum CookSessionError: Error, Equatable, LocalizedError, Sendable {
    case invalidStep
    case notActive

    var errorDescription: String? {
        switch self {
        case .invalidStep: "The cook step is outside this recipe."
        case .notActive: "The cook session is not active."
        }
    }
}

enum CookSessionStatus: String, Equatable, Sendable {
    case active
    case completed
    case abandoned
}

struct CookSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let recipeID: UUID
    let startedAt: Date
    let endedAt: Date?
    let status: CookSessionStatus
    let currentStepIndex: Int
}

struct CookProgress: Equatable, Sendable {
    let stepCount: Int
    private(set) var currentStepIndex: Int

    init(stepCount: Int, currentStepIndex: Int) throws {
        guard stepCount > 0,
              currentStepIndex >= 0,
              currentStepIndex < stepCount
        else { throw CookSessionError.invalidStep }
        self.stepCount = stepCount
        self.currentStepIndex = currentStepIndex
    }

    @discardableResult
    mutating func moveNext() -> Bool {
        guard currentStepIndex + 1 < stepCount else { return false }
        currentStepIndex += 1
        return true
    }

    @discardableResult
    mutating func moveBack() -> Bool {
        guard currentStepIndex > 0 else { return false }
        currentStepIndex -= 1
        return true
    }
}
