import SwiftSyntax

struct GeneratedActionFunction {
    let declaration: FunctionDeclSyntax
    let backgroundDeclaration: FunctionDeclSyntax?
}

struct StatefulInput {
    let access: String
    let conformances: [String]
    let actionEnum: EnumDeclSyntax?
    let actionEnumIsCasePathable: Bool
    let stateEnum: EnumDeclSyntax?
    let eventEnum: EnumDeclSyntax?
    let backgroundStateEnum: EnumDeclSyntax?
    let existingFunctionNames: Set<String>
    let registeredFunctions: [FunctionRegistration]
    let actionCases: [EnumCaseDeclSyntax]
    let transitionVariable: VariableDeclSyntax?
    let hasErrorAction: Bool
    let hasCancelAction: Bool
}

struct StatefulPlan {
    let access: String
    let conformances: [String]
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
    let addFunctionStmts: [CodeBlockItemSyntax]
    let generatedActionFunctions: [GeneratedActionFunction]
    let hasErrorAction: Bool
}

struct FunctionRegistration {
    let casePathComponent: KeyPathComponentSyntax
    let functionName: String
    let parameterNames: [String]
    let isAsync: Bool
    let isThrowing: Bool
}

struct ActionCase {
    let name: String
    let access: String
    let payloads: [ActionPayload]

    var isBackgroundEligible: Bool {
        access != "private"
    }
}

struct ActionPayload {
    let internalName: String
    let signature: FunctionParameterSyntax
}
