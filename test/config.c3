module lsp::core::config @test;

import lsp::core;

import dessert::format::json;

import std::collections::list;

const String TWO_TARGETS = `{
	"langrev": "1",
	"sources": [ "src/**" ],
	"features": [ "GLOBAL" ],
	"targets": {
		"first": { "type": "executable" },
		"second": { "type": "executable", "features": [ "SECOND" ] }
	}
}`;

const String LSP_TARGET_SECOND = `{
	"sources": [ "src/**" ],
	"targets": {
		"first": { "type": "executable", "features": [ "FIRST" ] },
		"second": { "type": "executable", "features": [ "SECOND", "LSP_TARGET" ] }
	}
}`;

<*
 A target is a key of the targets object, and only that.

 The parsed targets live in a hash map, which has no order, so the order
 has to come back out of the text - without mistaking a nested key, a
 value or a brace inside a string for a target.
*>
fn void target_names_keep_the_order_the_config_writes() {
	String[] names = target_names_in_order(TWO_TARGETS);

	test::eq(names.len, 2);
	test::eq(names[0], "first");
	test::eq(names[1], "second");

	// Keys of a nested object are not targets, and neither is anything
	// written inside a string.
	String nested = `{"targets":{"a":{"dependencies":["x"],"link_args":["{\"b\":"]},"b":{}}}`;
	String[] deep = target_names_in_order(nested);

	test::eq(deep.len, 2);
	test::eq(deep[0], "a");
	test::eq(deep[1], "b");

	// A config with no targets at all answers with nothing.
	test::eq(target_names_in_order(`{"sources":["src/**"]}`).len, 0);
}

<*
 Features are per target, so the server has to settle on one of them.
*>
fn void enabled_features_come_from_one_target() => @pool() {
	LspProject project;
	project.init(tmem);
	defer project.free();

	ProjectConfig? conf = json::deserialize{ProjectConfig}(tmem, TWO_TARGETS);
	test::@check(@ok(conf), "the config did not parse");
	project.config = conf!!;

	populate_enabled_features(&project, TWO_TARGETS);

	// No target asked for the server, so it is the first one written - and
	// the project wide features are on whichever target answers.
	test::@check(project.enabled_features.contains("GLOBAL"), "a project wide feature was left off");
	test::@check(!project.enabled_features.contains("SECOND"), "features of a target that was not picked leaked in");
	test::eq(project.enabled_features.len(), 1);
}

<*
 A target claims the server by listing LSP_TARGET, wherever it is written.
*>
fn void lsp_target_feature_picks_the_target() => @pool() {
	LspProject project;
	project.init(tmem);
	defer project.free();

	ProjectConfig? conf = json::deserialize{ProjectConfig}(tmem, LSP_TARGET_SECOND);
	test::@check(@ok(conf), "the config did not parse");
	project.config = conf!!;

	populate_enabled_features(&project, LSP_TARGET_SECOND);

	test::@check(project.enabled_features.contains("SECOND"), "the target that asked for the server was not picked");
	test::@check(project.enabled_features.contains("LSP_TARGET"), "the feature that picked the target was left off");
	test::@check(!project.enabled_features.contains("FIRST"), "the first target's features leaked in");
}
