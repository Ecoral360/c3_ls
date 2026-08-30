module lsp::core;

import std::io;
import std::collections::map;
import std::collections::list;

import std::compression::zip;

import lsp::analysis;
import lsp::msg_handler::publish_diag;
import lsp::core::config;
import dessert;
import derive;
import analyzer::core;
import uri;
import lsp::utils;
import lsp::server;

struct LspFile {
	Uri uri;
	String text;
	int version;
}

fn void LspFile.free(&self) {
	mem::free(self.text);
	self.uri.free();
}

struct QueuedFile {
	String path;
	String text;
	bool from_disk;
}

struct LspProject {
	HashMap{String, LspFile*} files;
	List{QueuedFile} process_queue;
	LspSession session;
	ProjectConfig config;
	HashMap{String, ManifestConfig} manifests;
	Allocator allocator;
}

fn void LspProject.init(&self, Allocator allocator) {
	self.allocator = allocator;
	self.files.init(allocator);
	self.process_queue.init(allocator);
	self.session.init(allocator);
}

fn void LspProject.free(&self) {
	self.session.free();
	self.files.@each(; String uri, LspFile* file) {
		file.free();
		alloc::free(self.allocator, file);
	};
	self.files.free();
	self.process_queue.free();
	self.config.free(self.allocator);
	self.manifests.@each(; name, conf) {
		conf.free(self.allocator);
	};
	self.manifests.free();
}

fn void LspProject.open_file(&self, TextDocumentItem document, bool is_std_lib = false) {
	String raw_uri = document.uri;

	log::debug("Registering document stream via raw tracking token: %s", raw_uri);


	Uri? file_uri = uri::parse(self.allocator, raw_uri);
	if (catch err = file_uri) {
		log::error("Malformed URI received (%s)", raw_uri);
		return;
	}

	String lookup_key = file_uri.path;
	log::warn("Opening file: %s", lookup_key);

	if (self.files.has_key(lookup_key)) {
		log::warn("File %s is already tracking in workspace", lookup_key);
		file_uri.free();
		return;
	}

	LspFile* lsp_file = alloc::new(self.allocator, LspFile);
	*lsp_file = {
		.uri = file_uri,
		.text = document.text.copy(self.allocator),
		.version = 1,
	};

	self.files[lookup_key] = lsp_file;

	QueuedFile queued = {
		.path = lookup_key,
		.text = lsp_file.text,
		.from_disk = is_std_lib,
	};

	self.process_queue.push(queued);
}

fn void LspProject.change_file(&self, DidChangeParams params) {
	String raw_uri = params.document.uri;
	log::debug("Registering document stream via raw tracking token: %s", raw_uri);
	Uri? file_uri = uri::parse(tmem, raw_uri);

	if (catch err = file_uri) {
		log::error("Malformed URI received (%s)", raw_uri);
		return;
	}

	String lookup_key = file_uri.path;

	if (!self.files.has_key(lookup_key)) {
		log::warn("File %s is not already tracking in workspace", lookup_key);
		return;
	}

	LspFile* file = self.files.get(lookup_key) ?? null;
	if (!file) return;

	if (params.document.version <= file.version) return;
	file.version = params.document.version;
	log::info("Reindexing: version = %d", file.version);

	if (file.text) {
		alloc::free(self.allocator, file.text);
	}

	file.text = params.content_changes[0].text.copy(self.allocator);

	// `lookup_key` points into tmem, which is released when the dispatch
	// pool closes, and the queue is not drained until after that. Queue the
	// file's own path instead: it is the same text, owned by the LspFile,
	// and it stays valid until the file is closed.
	self.process_queue.push(
		{
			.path = file.uri.path,
			.text = file.text,
			.from_disk = false,
		}
	);
}

fn void LspProject.close_file(&self, DocumentUri document) {
	String raw_uri = document;
	Uri? query_uri = uri::parse(tmem, raw_uri);
	if (catch query_uri) return;

	String lookup_key = query_uri.path;

	log::debug("Deregistering file: %s", lookup_key);

	if (!self.files.has_key(lookup_key)) {
		log::error("Attempted to drop non-existent file path identifier (%s)", lookup_key);
		return;
	}

	LspFile* file = self.files.get(lookup_key) ?? null;
	if (!file) return;

	file.free();
	alloc::free(self.allocator, file);
	self.files.remove(lookup_key);
	self.session.remove_file(lookup_key);
}

fn void LspProject.update(&self) => @pool() {
	if (self.process_queue.is_empty()) return;

	QueuedFile[] files = self.process_queue.array_view();
	defer self.process_queue.clear();

	self.session.clear_diagnostics();

	List{String} touched;
	touched.tinit();

	// Unindex the whole batch first. set_file resets a file's arena, and
	// every Node* the index holds for that file points into it, so taking
	// the old contribution out has to happen while it is still valid.
	foreach (QueuedFile queued : files) {
		self.session.unindex(queued.path);
	}

	foreach (QueuedFile queued : files) {
		String text = queued.text;

		if (queued.from_disk) {
			String? loaded = (String)file::load(tmem, queued.path);
			if (catch err = loaded) {
				log::error("Failed to load %s (Error: %s)", queued.path, err);
				continue;
			}
			text = loaded;
		}

		self.session.set_file(queued.path, text);
		touched.push(queued.path);
	}

	if (touched.is_empty()) return;

	foreach (String path : touched) {
		self.session.index(path);
	}

	// After indexing: sema resolves imports against ctx.modules.
	foreach (String path : touched) {
		self.session.analyze(path);
	}

	publish_diag::publish(self.allocator, &self.session, touched.array_view());
}

fn void LspProject.initial_process(&self) {
	self.process_stdlib();
	self.process_libs();
	self.process_config();
}

fn void LspProject.process_stdlib(&self) {
	Path? base_path = path::tnew(server::std_path);
	if (catch err = base_path) {
		log::error("Invalid stdlib path %s", err);
		return;
	}
	String[] paths = utils::find_source_files(tmem, base_path);
	foreach (matched : paths) {
		Uri file_uri    = uri::from_file_path(tmem, matched);
		DocumentUri uri = (DocumentUri)file_uri.to_raw_string(tmem);
		self.open_file({ .uri = uri }, true);
	}
}

fn void LspProject.process_config(&self) {
	Path? base_path = path::tnew(self.config.root_path);
	if (catch err = base_path) {
		log::error("Config base path is not valid.");
		return;
	}

	// log::info("base_path: %s", base_path);

	foreach (source_entry : self.config.sources) {
		String entry_str = source_entry;
		bool recursive   = false;
		String mask      = "*.c3";

		if (entry_str.ends_with("/**")) {
			entry_str = entry_str.strip_suffix("/**");
			recursive = true;
		}

		Path? entry_path = base_path.tappend(entry_str);
		if (catch err = entry_path) {
			log::error("'%s' is not a valid directory layout: %s", entry_str, err);
			continue;
		}

		// log::info("Entry: %s", entry_path);

		PathList paths;
		if (catch err = @try(
			paths,
			path::ls(tmem, entry_path, no_dirs: true, mask: mask, recursive: recursive, rebase: entry_path)
		)) {
			log::error("Failed to list directory contents for: %s", entry_str);
			continue;
		}

		foreach (matched : paths) {
			log::info("Found path: %s", matched);
			Uri file_uri    = uri::from_file_path(tmem, matched);
			DocumentUri uri = (DocumentUri)file_uri.to_raw_string(tmem);
			self.open_file({ .uri = uri }, true);
		}
	}
}

fn void LspProject.process_libs(&self) {
	Path? base_path = path::tnew(self.config.root_path);
	if (catch err = base_path) {
		log::error("Config base path is not valid for parsing libraries.");
		return;
	}

	String[] deps         = self.config.dependencies.get() ?? { };
	String[] search_paths = self.config.dependency_search_paths.get() ?? { };

	foreach (search_entry : search_paths) {
		if (search_entry.ends_with("\\")) search_entry = search_entry.strip_suffix("\\");

		if (!search_entry.ends_with("/")) search_entry = string::tformat("/%s/", search_entry);

		Path? search_base = base_path.tappend(search_entry);
		if (catch search_base) continue;

		String[]? libs = libs_installed(search_base);
		if (catch libs) continue;

		foreach (lib : libs) {
			ManifestConfig? config = load_manifest(lib);
			if (catch config) {
				log::warn("Lib without manifest.json (%s)", lib);
				continue;
			}
			String lib_provides = config.provides;
			foreach (dep_name : deps) {
				if (dep_name != lib_provides) continue;

				Path lib_path = (Path) lib;
				Path scan_target   = lib_path;
				bool is_compressed = path::is_file(lib_path);

				if (is_compressed) {
					if (lib_path.has_extension("c3i")) {
						log::debug("Found a declaration file (.c3i) at: %s", lib_path);
					} else {
						log::debug("Found a compressed library archive (.c3l file) at: %s", lib_path);

						Path? cache_root = cache::get_or_create_cache_dir(self.config.root_path);
						if (catch cache_root) continue;
						Path? cache_target_dir = cache_root.tappend(dep_name);
						if (catch cache_target_dir) continue;
						bool outdated = cache::is_library_outdated(dep_name, cache_target_dir, lib_path) ?? true;
						if (outdated) {
							log::info("Cache is stale or missing for %s. Extracting...", dep_name);

							if (path::exists(cache_target_dir)) {
								(void)path::rmtree(cache_target_dir);
							}
							if (catch err = path::mkdir(cache_target_dir, recursive: true)) {
								log::error("Failed to create cache_target dir: %s", err);
								continue;
							}

							if (decompress_library(lib_path, cache_target_dir)) {
								if (catch err = cache::update_library_meta(dep_name, cache_root, lib_path)) {
									log::error("Failed to update meta file: %s", err);
								}
							}
						} else {
							log::info("Cache hit for library %s. No offline modifications detected.", dep_name);
						}

						scan_target = cache_target_dir;
					}
				} else {
					log::info("Found an uncompressed library folder (.c3l folder) at: %s", lib_path);
				}


				String[] paths = utils::find_source_files(tmem, scan_target);

				foreach (matched : paths) {
					log::info("Found internal library source: %s", matched);
					Uri file_uri    = uri::from_file_path(tmem, matched);
					DocumentUri uri = (DocumentUri)file_uri.to_raw_string(tmem);
					self.open_file({ .uri = uri }, true);
				}

				break;
			}
		}
	}
}

<*
 Extracts a zipped library archive to a target cache directory.
 @param source_archive : `Path to the .c3l / .zip file (e.g., "libs/glfw.c3l")`
 @param cache_target_dir : `Path to the destination directory (e.g., ".lsp-cache/glfw")`
*>
fn bool decompress_library(String source_archive, Path cache_target_dir) {
	log::info("Extracting archive %s to %s", source_archive, cache_target_dir);

	ZipArchive? archive = zip::open(tmem, source_archive, "r");
	if (catch err = archive) {
		log::error("Failed to open zip archive: %s", source_archive);
		return false;
	}

	if (catch err = archive.extract(cache_target_dir)) {
		log::error("Extraction failed for %s", source_archive);
		(void)archive.close();
		return false;
	}

	(void)archive.close();
	return true;
}

fn String[]? libs_installed(String dir) @local {
	if (!file::is_dir(dir)) return { };

	PathList entries = path::ls(tmem, path::tnew(dir)!)!;

	List{String} paths;
	paths.tinit();

	foreach (entry : entries) {
		if (!entry.has_extension("c3l")) continue;
		paths.push(string::tformat("%s/%s", dir, entry));
	}

	return paths.to_tarray();
}

<*
 Reads the manifest of an installed lib. Handles both the directory layout and
 the zipped `.c3l` archive layout that c3c accepts.
*>
fn ManifestConfig? load_manifest(String lib_path) @private {
	String data;

	if (file::is_dir(lib_path)) {
		data = (String)file::load_temp(string::tformat("%s/%s", lib_path, config::MANIFEST_CONFIG_NAME))!;
	} else {
		ZipArchive archive = zip::open(tmem, lib_path)!;
		defer (void)archive.close();
		data = (String)archive.read_file_all(tmem, config::MANIFEST_CONFIG_NAME)!;
	}

	return json::tdeserialize{ManifestConfig}(data);
}
