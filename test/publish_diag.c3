module lsp::msg_handler::publish_diag @test;

import analyzer::core::diagnostics;

<*
 The mapping was rewritten from LogPriority to DiagnosticLevel during the
 analyzer migration, and nothing else pins it. Getting it wrong turns
 every error in the editor into a hint or the other way round.
*>
fn void to_severity_maps_every_level() {
	test::eq(to_severity(DiagnosticLevel.NOTE), MessageSeverity.HINT);
	test::eq(to_severity(DiagnosticLevel.INFO), MessageSeverity.INFO);
	test::eq(to_severity(DiagnosticLevel.WARN), MessageSeverity.WARNING);
	test::eq(to_severity(DiagnosticLevel.ERROR), MessageSeverity.ERROR);
}

<*
 The wire values are fixed by the LSP specification, not by the order of
 the constants, so they are worth asserting outright.
*>
fn void severity_wire_values_match_the_spec() {
	test::eq((int)MessageSeverity.ERROR, 1);
	test::eq((int)MessageSeverity.WARNING, 2);
	test::eq((int)MessageSeverity.INFO, 3);
	test::eq((int)MessageSeverity.HINT, 4);
}