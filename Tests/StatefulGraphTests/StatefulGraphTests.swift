import Foundation
import Testing

struct StatefulGraphTests {
    @Test
    func extractsRecognizedTransitionDSL() throws {
        let source = """
        @Stateful
        final class ExampleModel {
            @CasePathable
            enum Action {
                case load
                case requireLoaded
                case requireEither
                case invalidWhenLoaded
                case backgroundLoad
                case loop
                case repeated
                case debounced
                case catching
                case dynamic

                var transition: Transition {
                    switch self {
                    case .load:
                        .to(.loading, then: .loaded)
                            .whenBackground(.syncing)
                    case .requireLoaded:
                        .to(.loaded).required(.loaded)
                    case .requireEither:
                        .to(.loaded).required([.initial, .loaded])
                    case .invalidWhenLoaded:
                        .to(.loading).invalid([.loading, .loaded])
                    case .backgroundLoad:
                        .background(.syncing)
                    case .loop:
                        .loop(.loading)
                    case .repeated:
                        .to(.loading, then: .loaded)
                            .onRepeat(.cancel)
                    case .debounced:
                        .none._debounce(0.05)
                    case .catching:
                        .to(.loading, then: .loaded)
                            .catch { _ in }
                    case .dynamic:
                        makeTransition()
                    }
                }
            }

            enum BackgroundState {
                case syncing
            }

            enum State {
                case initial
                case loading
                case loaded
            }

            @Function(\\Action.Cases.load)
            func runLoad() {}
        }
        """

        let output = try renderGraph(source: source, typeName: "ExampleModel")

        #expect(output.contains("# ExampleModel Stateful Graph"))
        #expect(output.contains("state_initial([\"initial\"])"))
        #expect(output.contains("state_loading([\"loading\"])"))
        #expect(output.contains("state_loaded([\"loaded\"])"))
        #expect(output.contains("background_syncing[[\"background: syncing\"]]"))
        #expect(output.contains("action_load{{\"load<br/>runLoad()\"}}"))
        #expect(output.contains("action_load -->|\"start\"| state_loading"))
        #expect(output.contains("state_loading -->|\"load completes\"| state_loaded"))
        #expect(output.contains("action_load -.-> background_syncing"))
        #expect(output.contains("state_loaded -->|\"requireLoaded\"| action_requireLoaded"))
        #expect(output.contains("state_initial -->|\"requireEither\"| action_requireEither"))
        #expect(output.contains("source_any_except_loading_loaded[\"Any except loading, loaded\"]"))
        #expect(output.contains("action_backgroundLoad -.-> background_syncing"))
        #expect(output.contains("action_loop -->|\"loop start\"| state_loading"))
        #expect(output.contains("action_repeated{{\"repeated<br/>repeat: cancel\"}}"))
        #expect(output.contains("action_debounced{{\"debounced<br/>debounce: 0.05\"}}"))
        #expect(output.contains("action_catching{{\"catching<br/>catch\"}}"))
        #expect(output.contains("unresolved_dynamic[\"unresolved: makeTransition()\"]"))
    }

    @Test
    func rendersMermaidForClientSample() throws {
        let sourceURL = packageRoot.appending(path: "Sources/StatefulMacrosClient/main.swift")
        let markdown = try runGraph(arguments: [
            "--input", sourceURL.path,
            "--type", "ProjectDashboardViewModel",
        ]).standardOutput

        #expect(markdown.contains("# ProjectDashboardViewModel Stateful Graph"))
        #expect(markdown.contains("flowchart LR"))
        #expect(markdown.contains("action_openDashboard{{\"openDashboard<br/>loadDashboard()<br/>repeat: cancel\"}}"))
        #expect(markdown.contains("action_openDashboard -->|\"start\"| state_loadingDashboard"))
        #expect(markdown.contains("state_loadingDashboard -->|\"openDashboard completes\"| state_ready"))
        #expect(markdown.contains("action_refreshActivity -.-> background_syncingActivity"))
        #expect(markdown.contains("action_saveDraft -.-> background_savingDraft"))
    }

    private func renderGraph(
        source: String,
        typeName: String,
        format: String = "mermaid"
    ) throws -> String {
        let sourceURL = temporaryDirectory.appending(path: "\(typeName).swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        return try runGraph(arguments: [
            "--input", sourceURL.path,
            "--type", typeName,
            "--format", format,
        ]).standardOutput
    }

    private func runGraph(arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = graphExecutableURL
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let output = ProcessOutput(
            status: process.terminationStatus,
            standardOutput: String(data: standardOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            standardError: String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )

        #expect(output.status == 0, Comment(rawValue: output.standardError))
        return output
    }

    private var temporaryDirectory: URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StatefulGraphTests")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var graphExecutableURL: URL {
        let siblingExecutable = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appending(path: "StatefulGraph")
        if FileManager.default.isExecutableFile(atPath: siblingExecutable.path) {
            return siblingExecutable
        }

        return packageRoot.appending(path: ".build/debug/StatefulGraph")
    }
}

private struct ProcessOutput {
    var status: Int32
    var standardOutput: String
    var standardError: String
}
