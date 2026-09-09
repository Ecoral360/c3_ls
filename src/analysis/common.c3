module lsp;

enum CompletionContextKind {
	NONE,
	IMPORT,
	GLOBAL,
	PARAMETER,
	CONTAINER,       // Inside struct, union, bitstruct fields
	ENUM,
	EXECUTION,       // Inside a function body or macro body
	VAR_DECL,        // Naming a declaration, right after its type (e.g., Point )
	TYPE_ASSIGNMENT, // Explicit right-hand side matching (e.g., Var = )
	ATTRIBUTE,
	CONTRACT,
}

enum LspAccessKind {
	NONE,
	INSTANCE, // Triggered by '.'
	STATIC    // Triggered by '::'
}
