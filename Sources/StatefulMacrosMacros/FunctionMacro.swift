import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Function` marker macro to register functions with the state core.
public struct FunctionMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            let diagnostic = Diagnostic(node: Syntax(declaration), message: FunctionMacroError.requiresFunctionDeclaration)
            context.diagnose(diagnostic)
            return []
        }

        if let caseName = StatefulMacro.actionCaseProperty(in: node)?.declName.baseName.text,
           caseName == funcDecl.name.text
        {
            let diagnostic = Diagnostic(node: Syntax(funcDecl.name), message: FunctionMacroError.nameCollision)
            context.diagnose(diagnostic)
        }

        for param in funcDecl.signature.parameterClause.parameters {
            let firstName = param.firstName
            if firstName.text != "_" && !firstName.text.starts(with: "_") {
                let diagnostic = Diagnostic(node: Syntax(param), message: FunctionMacroError.parameterNamesMustBeUnderscored)
                context.diagnose(diagnostic)
            }
        }

        return []
    }
}
