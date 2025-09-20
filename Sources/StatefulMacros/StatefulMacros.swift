import CasePaths

@attached(member, names: arbitrary)
public macro Stateful() = #externalMacro(module: "StatefulMacrosMacros", type: "StatefulMacro")

@attached(peer)
public macro Function<T, P>(_ action: KeyPath<Case<T>, Case<P>>) = #externalMacro(module: "StatefulMacrosMacros", type: "FunctionMacro")
