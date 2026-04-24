import Foundation

public enum StatefulGraphRenderer {

    static func renderMermaid(_ graph: StatefulTypeGraph) -> String {
        var lines = [
            "# \(graph.typeName) Stateful Graph",
            "",
            "```mermaid",
            "flowchart LR",
        ]

        for state in graph.states {
            lines.append("  \(nodeID("state", state))([\"\(escapeMermaid(state))\"])")
        }

        for backgroundState in graph.backgroundStates {
            lines.append("  \(nodeID("background", backgroundState))[[\"background: \(escapeMermaid(backgroundState))\"]]")
        }

        for transition in graph.transitions {
            let actionID = nodeID("action", transition.action)
            lines.append("  \(actionID){{\"\(escapeMermaid(actionLabel(for: transition, in: graph)))\"}}")

            for sourceID in sourceNodeIDs(for: transition.source, lines: &lines) {
                lines.append("  \(sourceID) -->|\"\(escapeMermaid(transition.action))\"| \(actionID)")
            }

            switch transition.effect {
            case .none:
                let noneID = nodeID("none", transition.action)
                lines.append("  \(noneID)[\"no state change\"]")
                lines.append("  \(actionID) -.-> \(noneID)")
            case let .to(destination):
                lines.append("  \(actionID) -->|\"to\"| \(nodeID("state", destination))")
            case let .through(intermediate, destination):
                lines.append("  \(actionID) -->|\"start\"| \(nodeID("state", intermediate))")
                lines
                    .append(
                        "  \(nodeID("state", intermediate)) -->|\"\(escapeMermaid(transition.action)) completes\"| \(nodeID("state", destination))"
                    )
            case let .loop(intermediate):
                lines.append("  \(actionID) -->|\"loop start\"| \(nodeID("state", intermediate))")
                for sourceID in completionNodeIDs(for: transition.source) {
                    lines.append("  \(nodeID("state", intermediate)) -->|\"loop complete\"| \(sourceID)")
                }
            case let .background(backgroundState):
                lines.append("  \(actionID) -.-> \(nodeID("background", backgroundState))")
            case let .unresolved(expression):
                let unresolvedID = nodeID("unresolved", transition.action)
                lines.append("  \(unresolvedID)[\"unresolved: \(escapeMermaid(expression))\"]")
                lines.append("  \(actionID) -.-> \(unresolvedID)")
            }

            if let backgroundState = transition.backgroundState {
                lines.append("  \(actionID) -.-> \(nodeID("background", backgroundState))")
            }
        }

        lines.append("```")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func actionLabel(for transition: StatefulActionTransition, in graph: StatefulTypeGraph) -> String {
        var parts = [transition.action]
        if let functions = graph.functionRegistrations[transition.action], !functions.isEmpty {
            parts.append(functions.map { "\($0)()" }.joined(separator: ", "))
        }
        if let repeatBehavior = transition.repeatBehavior {
            parts.append("repeat: \(repeatBehavior)")
        }
        if let debounce = transition.debounce {
            parts.append("debounce: \(debounce)")
        }
        if transition.catchesErrors {
            parts.append("catch")
        }
        return parts.joined(separator: "<br/>")
    }

    private static func sourceNodeIDs(
        for source: StatefulTransitionSource,
        lines: inout [String]
    ) -> [String] {
        switch source {
        case .anyAllowed:
            let id = "source_any_allowed"
            appendPseudoNode(id: id, label: "Any allowed state", lines: &lines)
            return [id]
        case let .required(states):
            return states.map { nodeID("state", $0) }
        case let .invalid(states):
            let id = nodeID("source_any_except", states.joined(separator: "_"))
            appendPseudoNode(id: id, label: "Any except \(states.joined(separator: ", "))", lines: &lines)
            return [id]
        }
    }

    private static func completionNodeIDs(for source: StatefulTransitionSource) -> [String] {
        switch source {
        case .anyAllowed:
            return ["source_any_allowed"]
        case let .required(states):
            return states.map { nodeID("state", $0) }
        case let .invalid(states):
            return [nodeID("source_any_except", states.joined(separator: "_"))]
        }
    }

    private static func appendPseudoNode(id: String, label: String, lines: inout [String]) {
        let definition = "  \(id)[\"\(escapeMermaid(label))\"]"
        if !lines.contains(definition) {
            lines.append(definition)
        }
    }

    private static func nodeID(_ prefix: String, _ value: String) -> String {
        let sanitized = value
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0).description : "_" }
            .joined()
        return "\(prefix)_\(sanitized.isEmpty ? "unnamed" : sanitized)"
    }

    private static func escapeMermaid(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "#quot;")
            .replacingOccurrences(of: "\n", with: "<br/>")
    }
}
