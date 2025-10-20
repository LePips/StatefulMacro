import SwiftSyntax

struct StatefulMacroContext {
    let access: String
    let conformances: [String]
    let actionEnumDecl: EnumDeclSyntax
    let isCasePathable: Bool
    let stateActionEnums: [EnumDeclSyntax]
    let backgroundStateTypeName: String
    let backgroundStateEnum: EnumDeclSyntax?
    let stateEnumName: String
    let stateEnum: EnumDeclSyntax
    let hasErrorState: Bool
    let eventTypeName: String
    let eventEnum: EnumDeclSyntax?
    let hasErrorEvent: Bool
    let actionEnumName: String
    let actionEnum: EnumDeclSyntax
    let addFunctionStmts: [String]
    let throwingActions: Set<String>
    let generatedActionFunctions: [FunctionSyntaxPair]
    let hasErrorAction: Bool
}
