import ArgumentParser
import Foundation

@main
struct StatefulGraphCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "StatefulGraph",
        abstract: "Generates a static graph from a @Stateful type's Action.transition DSL."
    )

    @Option(name: .long, help: "Path to the Swift source file to graph.")
    var input: String

    @Option(name: .customLong("type"), help: "Name of the @Stateful type to graph.")
    var typeName: String?

    @Option(name: .long, help: "Path to write the graph. Prints to stdout when omitted.")
    var output: String?

    mutating func run() throws {
        do {
            let source = try String(contentsOfFile: input, encoding: .utf8)
            let graphs = try StatefulGraphExtractor.extract(from: source)
            let graph = try StatefulGraphExtractor.select(graphs, typeName: typeName)
            let rendered = StatefulGraphRenderer.renderMermaid(graph)

            if let output {
                let outputURL = URL(fileURLWithPath: output)
                if let parent = outputURL.parentDirectoryIfNeeded {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                try rendered.write(to: outputURL, atomically: true, encoding: .utf8)
            } else {
                print(rendered, terminator: "")
            }
        } catch let error as StatefulGraphError {
            throw ValidationError(error.description)
        }
    }
}

private extension URL {
    var parentDirectoryIfNeeded: URL? {
        let parent = deletingLastPathComponent()
        return parent.path == path ? nil : parent
    }
}
