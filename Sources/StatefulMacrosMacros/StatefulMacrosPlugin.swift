//
//  StatefulMacrosPlugin.swift
//  StatefulMacros
//
//  Created by Ethan Pippin on 9/19/25.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct StatefulMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        StatefulMacro.self,
        FunctionMacro.self,
    ]
}
