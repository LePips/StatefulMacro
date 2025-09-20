import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct StatefulMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        StatefulMacro.self,
        FunctionMacro.self,
    ]
}
