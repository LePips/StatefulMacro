@_exported import StatefulMacrosCore

@attached(member, names: arbitrary)
public macro Stateful(conformances: [Any] = []) = #externalMacro(module: "StatefulMacrosMacros", type: "StatefulMacro")

@attached(peer)
public macro Function(_ action: Any) = #externalMacro(module: "StatefulMacrosMacros", type: "FunctionMacro")
