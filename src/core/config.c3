module lsp::core::config;

import lsp::msg_handler::log_message;
import lsp::analysis;

import std::collections::list;
import std::collections::map;
import std::collections::maybe;
import std::io;

import dessert;
import uri;

const String PROJECT_CONFIG_NAME  = "project.json";
const String MANIFEST_CONFIG_NAME = "manifest.json";

$expand(dessert::@derive(ProjectConfig));
struct ProjectConfig {
	String root_path @DField({ .skip = true });
	String[] sources;
	Maybe{String[]} dependency_search_paths @DField({ .rename = "dependency-search-paths" });
	Maybe{String[]} dependencies;
	Maybe{String[]} features;
	HashMap{String, TargetConfig} targets;
}

fn void ProjectConfig.free(&self, Allocator allocator) {
	if (self.root_path) self.root_path.free(allocator);
	if (self.sources) alloc::free(allocator, self.sources);
	if (try val = self.dependency_search_paths.get()) {
		alloc::free(allocator, val);
	}
	if (try val = self.dependencies.get()) {
		alloc::free(allocator, val);
	}
	if (try val = self.features.get()) {
		alloc::free(allocator, val);
	}
	if (self.targets.is_initialized()) {
		self.targets.@each(; name, conf) {
			conf.free(allocator);
		};
	}

	self.targets.free();
}

$expand(dessert::@derive(ManifestConfig));
struct ManifestConfig {
	String provides;
	String[] sources;
	HashMap{String, TargetConfig} targets;
}

fn void ManifestConfig.free(&self, Allocator alloc) {
	if (self.sources) {
		alloc::free(alloc, self.sources);
	}

	self.targets.@each(; name, conf) {
		conf.free(alloc);
	};

	self.targets.free();
}

$expand(dessert::@derive(TargetConfig));
struct TargetConfig {
	Maybe{String[]} link_args;
	Maybe{String[]} dependencies;
	Maybe{String[]} features;
	Maybe{String[]} linked_libraries @DField({ .rename = "linked-libraries" });
}

fn void TargetConfig.free(&self, Allocator allocator) {
	if (try val = self.link_args.get()) {
		alloc::free(allocator, val);
	}
	if (try val = self.dependencies.get()) {
		alloc::free(allocator, val);
	}
	if (try val = self.features.get()) {
		alloc::free(allocator, val);
	}
	if (try val = self.linked_libraries.get()) {
		alloc::free(allocator, val);
	}
}

<*
 The feature a target lists to claim the server for itself.
*>
const String LSP_TARGET_FEATURE = "LSP_TARGET";

<*
 Turn on the features the workspace is compiled with.

 c3c builds one target at a time, and features are per target, so the
 server has to settle on one: the first that asks for it by listing
 LSP_TARGET, and the first one written otherwise. The project wide
 features come on top, the way c3c applies them to every target.
*>
fn void populate_enabled_features(LspProject* lsp_project, String json_content) {
	if (try String[] features = lsp_project.config.features.get()) {
		foreach (String feature : features) {
			lsp_project.enabled_features.add(feature);
		}
	}

	String[] names = target_names_in_order(json_content);
	if (names.len == 0) return;

	String chosen = names[0];
	foreach (String name : names) {
		if (!target_lists(lsp_project, name, LSP_TARGET_FEATURE)) continue;

		chosen = name;
		break;
	}

	log::info("Taking features from target '%s'", chosen);

	TargetConfig? target = lsp_project.config.targets.get(chosen);
	if (catch target) return;

	if (try String[] features = target.features.get()) {
		foreach (String feature : features) {
			lsp_project.enabled_features.add(feature);
		}
	}
}

fn bool target_lists(LspProject* lsp_project, String name, String feature) @local {
	TargetConfig? target = lsp_project.config.targets.get(name);
	if (catch target) return false;

	String[]? features = target.features.get();
	if (catch features) return false;

	foreach (String listed : features) {
		if (listed == feature) return true;
	}

	return false;
}

<*
 The targets in the order the config writes them.

 They are parsed into a hash map, which keeps no order at all, so which
 one comes first has to be read back out of the text they came from.

 @return "names pointing into `json_content`, so they live as long as it does"
*>
fn String[] target_names_in_order(String json_content) {
	List{String} names;
	names.tinit();

	sz? key = json_content.index_of("\"targets\"");
	if (catch key) return { };

	usz i = (usz)key;
	while (i < json_content.len && json_content[i] != '{') i++;

	int depth = 0;
	for (; i < json_content.len; i++) {
		char c = json_content[i];

		if (c == '"') {
			usz start = i + 1;
			i = string_end(json_content, i);

			// A target is a key of the targets object, and a key is a
			// string with a colon after it - the rest are values.
			if (depth == 1 && i > start && colon_follows(json_content, i)) {
				names.push(json_content[start..i - 1]);
			}
			continue;
		}

		switch (c) {
			case '{':
			case '[':
				depth++;
			case '}':
			case ']':
				depth--;
				if (depth == 0) return names.array_view();
			default:
		}
	}

	return names.array_view();
}

<*
 Index of the quote closing the string that opens at `open`, or the end of
 the text when nothing closes it.
*>
fn usz string_end(String json_content, usz open) @local {
	for (usz i = open + 1; i < json_content.len; i++) {
		if (json_content[i] == '\\') {
			i++;
			continue;
		}
		if (json_content[i] == '"') return i;
	}

	return json_content.len;
}

fn bool colon_follows(String json_content, usz close) @local {
	for (usz i = close + 1; i < json_content.len; i++) {
		char c = json_content[i];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;

		return c == ':';
	}

	return false;
}

fn void load(LspProject* lsp_project, WorkspaceFolder wf, Allocator allocator) {
	Uri? uri = uri::parse(allocator, wf.uri);
	if (catch uri) {
		log::error("Failed to parse uri: (%s)", wf.uri);
		return;
	}
	defer {
		uri.free();
	}

	Path? root_path = path::tnew(uri.path);
	if (catch err = root_path) {
		log::error("Unknown workspace uri");
		return;
	}
	Path found_config;

	PathList? entries = path::ls(tmem, root_path, recursive: false, relative: true);
	if (catch entries) {
		log::error("Failed to list files in workspace root");
		return;
	}

	bool found_project  = false;
	bool found_manifest = false;

	foreach (path : entries) {
		String name = path.basename();
		if (name == PROJECT_CONFIG_NAME) found_project = true;
		if (name == MANIFEST_CONFIG_NAME) found_manifest = true;
	}
	if (!found_project && !found_manifest) {
		log::error("No project.json or manifest.json found in root.");
		return;
	}

	String filename   = found_project ? PROJECT_CONFIG_NAME : MANIFEST_CONFIG_NAME;
	Path? config_path = root_path.tappend(filename);
	if (catch err = config_path) {
		log::error("Failed to append root_path with filename: %s", err);
		return;
	}
	String? json_content = (String)file::load_temp(config_path);
	if (catch err = json_content) {
		log::error("Failed to load file: %s", err);
		return;
	}
	log::debug("%s", json_content);
	if (found_project) {
		log::info("Found project.json at (%s)", config_path);
		ProjectConfig? conf = json::deserialize{ProjectConfig}(allocator, json_content);
		if (catch err = conf) {
			log::error("Failed to deserialize project.json - %s", err);
			return;
		}
		lsp_project.config = conf;
	} else {
		log::info("Found manifest in root.");
		ManifestConfig? conf = json::deserialize{ManifestConfig}(allocator, json_content);
		if (catch err = conf) {
			log::error("Failed to deserialize project.json - %s", err);
			return;
		}
		lsp_project.config.sources = conf.sources;
		lsp_project.config.targets = conf.targets;
	}

	lsp_project.config.root_path = root_path.copy(allocator);
	log::info("Set config.root_path: %s", lsp_project.config.root_path);

	populate_enabled_features(lsp_project, json_content);
}
