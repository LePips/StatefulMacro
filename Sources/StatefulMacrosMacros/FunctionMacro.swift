//
//  FunctionMacro.swift
//  StatefulMacros
//
//  Created by Ethan Pippin on 9/19/25.
//

import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

enum FunctionMacroError: String, DiagnosticMessage, Error {
    case mustBePrivate
    case nameCollision
    case requiresFunctionDeclaration
    case missingArgument

    var message: String {
        switch self {
        case .mustBePrivate:
            return "`@Function` can only be applied to private functions"
        case .nameCollision:
            return "Function name cannot be the same as the action case name"
        case .requiresFunctionDeclaration:
            return "`@Function` can only be applied to functions"
        case .missingArgument:
            return "`@Function` requires a case path to an action as an argument"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "com.statefulmacro.functionmacro", id: rawValue)
    }

    var severity: DiagnosticSeverity { .error }
}

/// The `@Function` macro is a marker used to register functions with the state core.
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

        // Requirement 1: Must be private
        let isPrivate = funcDecl.modifiers.contains { $0.name.text == "private" }

        if !isPrivate {
            let diagnostic = Diagnostic(node: Syntax(funcDecl.name), message: FunctionMacroError.mustBePrivate)
            context.diagnose(diagnostic)
        }

        // Requirement 2: Function name must not be the same as the case name
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              let firstArgument = arguments.first,
              let keyPath = firstArgument.expression.as(KeyPathExprSyntax.self),
              let lastComponent = keyPath.components.last,
              let property = lastComponent.component.as(KeyPathPropertyComponentSyntax.self)
        else {
            let diagnostic = Diagnostic(node: Syntax(node), message: FunctionMacroError.missingArgument)
            context.diagnose(diagnostic)
            return []
        }

        let caseName = property.declName.baseName.text
        let funcName = funcDecl.name.text

        if caseName == funcName {
            let diagnostic = Diagnostic(node: Syntax(funcDecl.name), message: FunctionMacroError.nameCollision)
            context.diagnose(diagnostic)
        }

        return []
    }
}
