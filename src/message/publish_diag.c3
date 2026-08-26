module lsp::msg_handler::publish_diag;

import std::collections::list;
import std::collections::set;

import analyzer::core;
import analyzer::core::diagnostics;
import lsp::core;
import lsp::io_handler;
import lsp::translator;
import dessert;

import uri;

$expand(dessert::@derive(MessageSeverity));
constdef MessageSeverity : inline int
{
	ERROR = 1,
	WARNING = 2,
	INFO = 3,
	HINT = 4,
}

$expand(dessert::@derive(LspDiagnostic));
struct LspDiagnostic 
{
	LspRange range;
	MessageSeverity severity;
	String message;
	String source;
}

fn MessageSeverity to_severity(DiagnosticLevel level)
{
	switch (level)
	{
		case DiagnosticLevel.NOTE:
			return MessageSeverity.HINT;
		case DiagnosticLevel.INFO:
			return MessageSeverity.INFO;
		case DiagnosticLevel.WARN:
			return MessageSeverity.WARNING;
		case DiagnosticLevel.ERROR:
			return MessageSeverity.ERROR;
	}
}

<*
 Send diagnostics for every path touched by the last update batch.

 Paths with nothing collected still get an empty array, which is how a
 client is told the file is clean now.
*>
fn void publish(Allocator allocator, LspSession* session, String[] touched_paths)
{
	foreach (String file_path : touched_paths)
	{
		List{SessionDiagnostic} collected = session.diagnostics_for(file_path);

		List{LspDiagnostic} diags;
		diags.tinit();

		foreach (SessionDiagnostic diag : collected)
		{
			diags.push({
				.range = {
					.start = { .line = (uint)diag.range.start.line, .character = (uint)diag.range.start.column },
					.end = { .line = (uint)diag.range.end.line, .character = (uint)diag.range.end.column },
				},
				.severity = to_severity(diag.level),
				.message = diag.message,
				.source = "c3-analyzer"
			});
		}

		Uri file_uri = uri::from_file_path(tmem, file_path);
		DocumentUri formatted_uri = (DocumentUri)file_uri.to_raw_string(tmem);

		LspMessage res = {
			.rpc = "2.0",
			.method = PUB_DIAG,
			.params.pub_diag = {
				.uri = formatted_uri,
				.diagnostics = diags.to_tarray(),
			}
		};

		String response_json = translator::encode(res, allocator);
		log::debug("Sending diagnostics for %s: %s", file_path, response_json);
		io_handler::write(response_json);
	}
}
