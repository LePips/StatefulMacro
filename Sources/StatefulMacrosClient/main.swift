import CasePaths
import Combine
import Foundation
import StatefulMacros

struct Project: Identifiable, Equatable {
    let id: UUID
    var name: String
    var unreadActivity: Int
    var latestDraft: String?
}

struct DashboardSnapshot {
    var projects: [Project]
    var selectedProjectID: Project.ID?
}

struct DraftNote {
    let projectID: Project.ID
    let body: String
}

struct DashboardService {
    var fetchDashboard: @Sendable () async throws -> DashboardSnapshot
    var fetchProject: @Sendable (Project.ID) async throws -> Project
    var refreshActivity: @Sendable ([Project]) async throws -> [Project]
    var saveDraft: @Sendable (DraftNote) async throws -> Void

    static let preview = DashboardService(
        fetchDashboard: {
            try await Task.sleep(for: .milliseconds(150))
            let design = Project(
                id: UUID(uuidString: "9A835DBA-7260-472B-9F4B-F68C845AB2E0")!,
                name: "Design System",
                unreadActivity: 4
            )
            let billing = Project(
                id: UUID(uuidString: "D7D9C0B3-E52E-4972-A7C1-A80A1F43B8C4")!,
                name: "Billing Portal",
                unreadActivity: 1
            )
            return DashboardSnapshot(
                projects: [design, billing],
                selectedProjectID: design.id
            )
        },
        fetchProject: { id in
            try await Task.sleep(for: .milliseconds(120))
            return Project(
                id: id,
                name: "Billing Portal",
                unreadActivity: 0
            )
        },
        refreshActivity: { projects in
            try await Task.sleep(for: .milliseconds(100))
            return projects.map { project in
                var updated = project
                updated.unreadActivity += 1
                return updated
            }
        },
        saveDraft: { _ in
            try await Task.sleep(for: .milliseconds(80))
        }
    )
}

@MainActor
@Stateful
final class ProjectDashboardViewModel: ObservableObject {

    enum DashboardError: Error {
        case projectNotFound(Project.ID)
    }

    @CasePathable
    enum Action {
        case openDashboard
        case selectProject(id: Project.ID)
        case refreshActivity
        case saveDraft(DraftNote)
        case cancel

        var transition: Transition {
            switch self {
            case .openDashboard:
                .to(.loadingDashboard, then: .ready)
                    .whenBackground(.syncingDashboard)
                    .onRepeat(.cancel)
            case .selectProject:
                .to(.loadingProject, then: .ready)
                    .whenBackground(.syncingDashboard)
                    .required(.ready)
            case .refreshActivity:
                .loop(.refreshingActivity)
                    .whenBackground(.syncingActivity)
                    .required(.ready)
                    .onRepeat(.cancel)
            case .saveDraft:
                .background(.savingDraft)
                    .required(.ready)
            case .cancel:
                .to(.initial)
            }
        }
    }

    enum BackgroundState {
        case syncingDashboard
        case syncingActivity
        case savingDraft
    }

    enum Event {
        case dashboardLoaded(projectCount: Int)
        case projectSelected(Project.ID)
        case draftSaved(Project.ID)
    }

    enum State {
        case initial
        case loadingDashboard
        case loadingProject
        case refreshingActivity
        case ready
        case error
    }

    @Published
    private(set) var projects: [Project] = []
    @Published
    private(set) var selectedProjectID: Project.ID?

    private let service: DashboardService

    init(service: DashboardService = .preview) {
        self.service = service
    }

    @Function(\Action.Cases.openDashboard)
    func loadDashboard() async throws {
        let snapshot = try await service.fetchDashboard()
        projects = snapshot.projects
        selectedProjectID = snapshot.selectedProjectID
        core.eventPublisher.send(.dashboardLoaded(projectCount: snapshot.projects.count))
    }

    @Function(\Action.Cases.selectProject)
    func loadProject(_ id: Project.ID) async throws {
        let project = try await service.fetchProject(id)

        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw DashboardError.projectNotFound(id)
        }

        projects[index] = project
        selectedProjectID = id
        core.eventPublisher.send(.projectSelected(id))
    }

    @Function(\Action.Cases.refreshActivity)
    func refreshProjectActivity() async throws {
        projects = try await service.refreshActivity(projects)
    }

    @Function(\Action.Cases.saveDraft)
    func persistDraft(_ draft: DraftNote) async throws {
        try await service.saveDraft(draft)

        guard let index = projects.firstIndex(where: { $0.id == draft.projectID }) else {
            throw DashboardError.projectNotFound(draft.projectID)
        }

        projects[index].latestDraft = draft.body
        core.eventPublisher.send(.draftSaved(draft.projectID))
    }
}

asyncMain {
    let dashboard = ProjectDashboardViewModel()

    let stateSubscription = dashboard.$state.sink { state in
        print("state:", state)
    }
    let backgroundSubscription = dashboard.$background.sink { background in
        print("background:", background.states)
    }
    let actionSubscription = dashboard.actions.sink { action in
        print("action:", action)
    }
    let eventSubscription = dashboard.events.sink { event in
        print("event:", event)
    }

    await dashboard.openDashboard()

    if let selectedProjectID = dashboard.selectedProjectID {
        await dashboard.background.refreshActivity()
        await dashboard.background.saveDraft(DraftNote(
            projectID: selectedProjectID,
            body: "Follow up with design review notes."
        ))
    }

    try await Task.sleep(for: .milliseconds(250))

    stateSubscription.cancel()
    backgroundSubscription.cancel()
    actionSubscription.cancel()
    eventSubscription.cancel()
}
