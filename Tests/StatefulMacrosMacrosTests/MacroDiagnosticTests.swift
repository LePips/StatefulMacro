import MacroTesting
@testable import StatefulMacrosMacros
import SwiftDiagnostics
import Testing

@Suite(
    .macros([
        "Stateful": StatefulMacro.self,
        "Function": FunctionMacro.self,
    ])
)
struct MacroDiagnosticTests {

    @Test
    func actionFunctionConflictErrorExposesExpectedDiagnosticMetadata() {
        let error = ActionFunctionConflictError(functionName: "refresh")

        #expect(error.message == "A function with the same name as the action case 'refresh' already exists.")
        #expect(error.diagnosticID == MessageID(domain: "com.statefulmacro", id: "actionFunctionConflict"))
        #expect(error.severity == .error)
    }

    @Test
    func missingActionDiagnostic() {
        assertMacro {
            """
            @Stateful
            final class MissingAction: ObservableObject {}
            """
        } diagnostics: {
            """
            @Stateful
            ┬────────
            ├─ 🛑 `@Stateful` requires a nested enum named `Action`.
            ╰─ 🛑 `@Stateful` requires a nested enum named `Action`.
            final class MissingAction: ObservableObject {}
            """
        }
    }

    @Test
    func qualifiedObservableObjectAllowsStatefulValidationToContinue() {
        assertMacro {
            """
            @Stateful
            final class QualifiedObservableObject: Combine.ObservableObject, Sendable {}
            """
        } diagnostics: {
            """
            @Stateful
            ┬────────
            ├─ 🛑 `@Stateful` requires a nested enum named `Action`.
            ╰─ 🛑 `@Stateful` requires a nested enum named `Action`.
            final class QualifiedObservableObject: Combine.ObservableObject, Sendable {}
            """
        }
    }

    @Test
    func missingCasePathableDiagnostic() {
        assertMacro {
            """
            @Stateful
            final class MissingCasePathable: ObservableObject {
                enum Action {
                    case refresh
                }
            }
            """
        } diagnostics: {
            """
            @Stateful
            ┬────────
            ╰─ 🛑 The `Action` enum must be marked with `@CasePathable`.
            final class MissingCasePathable: ObservableObject {
                enum Action {
                     ┬─────
                     ╰─ 🛑 The `Action` enum must be marked with `@CasePathable`.
                    case refresh
                }
            }
            """
        }
    }

    @Test
    func missingInitialStateDiagnostic() {
        assertMacro {
            """
            @Stateful
            final class MissingInitial: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                }

                enum State {
                    case loading
                }
            }
            """
        } diagnostics: {
            """
            @Stateful
            ┬────────
            ╰─ 🛑 A `State` enum, if provided, must have an `initial` case.
            final class MissingInitial: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                }

                enum State {
                     ┬────
                     ╰─ 🛑 A `State` enum, if provided, must have an `initial` case.
                    case loading
                }
            }
            """
        }
    }

    @Test
    func nonClassStatefulDiagnostic() {
        assertMacro {
            """
            @Stateful
            struct NotAClass {}
            """
        } diagnostics: {
            """
            @Stateful
            ┬────────
            ├─ 🛑 `@Stateful` can only be applied to classes.
            ╰─ 🛑 `@Stateful` can only be applied to classes.
            struct NotAClass {}
            """
        }
    }

    @Test
    func actionFunctionConflictDiagnostic() {
        assertMacro {
            """
            @Stateful
            final class ActionConflictViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                }

                func refresh() {}
            }
            """
        } diagnostics: {
            """
            @Stateful
            final class ActionConflictViewModel: ObservableObject {
                @CasePathable
                enum Action {
                    case refresh
                         ┬──────
                         ╰─ 🛑 A function with the same name as the action case 'refresh' already exists.
                }

                func refresh() {}
            }
            """
        }
    }

    @Test
    func functionOnNonFunctionDiagnostic() {
        assertMacro {
            """
            @Function
            var value: Int
            """
        } diagnostics: {
            """
            @Function
            ╰─ 🛑 `@Function` can only be applied to functions
            var value: Int
            """
        }
    }

    @Test
    func functionWithoutCasePathIsAllowed() {
        assertMacro {
            """
            @Function
            func load() {}
            """
        } expansion: {
            """
            func load() {}
            """
        }
    }

    @Test
    func functionNameCollisionDiagnostic() {
        assertMacro {
            """
            @Function(\\Action.Cases.load)
            func load() {}
            """
        } diagnostics: {
            #"""
            @Function(\Action.Cases.load)
            func load() {}
                 ┬───
                 ╰─ 🛑 Function name cannot be the same as the action case name
            """#
        }
    }

    @Test
    func nonUnderscoredParameterDiagnostic() {
        assertMacro {
            """
            @Function(\\Action.Cases.load)
            func perform(value: Int) {}
            """
        } diagnostics: {
            #"""
            @Function(\Action.Cases.load)
            func perform(value: Int) {}
                         ┬─────────
                         ╰─ 🛑 All parameters of a `@Function` must have underscored names
            """#
        }
    }

    @Test
    func underscoredFunctionParametersAreAllowed() {
        assertMacro {
            """
            @Function(\\Action.Cases.load)
            func perform(_ value: Int) {}
            """
        } expansion: {
            """
            func perform(_ value: Int) {}
            """
        }
    }
}
