-- Attribution matrix: the per-test-file "test file → covered lines of the
-- target source file" mapping that test subsetting prunes with (map #1, #7).
--
-- luacov aggregates coverage per process, so it has no test-file dimension.
-- The runner builds this matrix itself (see runner.lua's --attribution-matrix
-- mode) by snapshotting and clearing luacov's public `runner.data` table at
-- test-file boundaries in a single coverage pass; this module owns the matrix
-- as data: its on-disk cache, the freshness key, and the line lookup.
--
-- Cache location: `<project_root>/.mutate4lua/attribution/<target>.matrix`.
-- It must live outside the mutation workspace, which is an overlay that gets
-- `rm -rf`'d after every run; project_hash already ignores `/.mutate4lua/`, so
-- caching there cannot perturb manifest semantics.
--
-- Freshness key = suite hash + target source hash (CONTEXT.md). The suite hash
-- covers every discovered test file, so editing any test rebuilds the matrix;
-- the target hash is taken over the manifest-stripped source, so writing a
-- manifest footer does not invalidate it.
local util = require("mutate4lua.util")

local attribution = {}

-- Bump when the matrix body's semantics change (a stored matrix from an older
-- version is treated as absent, forcing a rebuild).
local CURRENT_MATRIX_VERSION = 1
attribution.CURRENT_MATRIX_VERSION = CURRENT_MATRIX_VERSION

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Mirrors runner.lua's discovery exactly (test_*.lua under spec/, test/ or
-- tests/, fixtures pruned, `find -L` so symlinked overlay trees resolve): the
-- suite hash is only a valid freshness key if it covers the same file set the
-- runner will actually load.
function attribution.discover_test_files(project_root)
  local files = {}
  for _, dirname in ipairs({"spec", "test", "tests"}) do
    local dir = util.join_path(project_root, dirname)
    if util.is_directory(dir) then
      local command = "find -L " .. shell_quote(dir)
        .. " -name 'test_*.lua' -type f -not -path '*/fixtures/*' 2>/dev/null"
      local output = util.capture(command) or ""
      for line in output:gmatch("[^\n]+") do
        if line ~= "" then
          files[#files + 1] = line
        end
      end
    end
  end
  table.sort(files)
  return files
end

-- Hash of the whole test suite: root-relative path plus content of every test
-- file, in discovery order. Deliberately narrower than project_hash, which
-- also digests src/ — a dev-loop edit to unrelated source must not evict the
-- matrix (CONTEXT.md, 套件 hash).
function attribution.suite_hash(project_root, test_files)
  test_files = test_files or attribution.discover_test_files(project_root)
  local parts = {}
  for _, path in ipairs(test_files) do
    local content, read_err = util.read_file(path)
    if content == nil then
      return nil, "cannot read test file " .. path .. ": " .. tostring(read_err)
    end
    parts[#parts + 1] = util.relative_path(project_root, path):gsub("\\", "/")
    parts[#parts + 1] = "\n"
    parts[#parts + 1] = util.normalize_newlines(content)
    parts[#parts + 1] = "\n\0\n"
  end
  return util.fnv1a64(table.concat(parts))
end

function attribution.target_hash(stripped_source)
  return util.fnv1a64(util.normalize_newlines(stripped_source))
end

function attribution.cache_path(project_root, target_relative)
  local relative = util.normalize_relative_path(target_relative)
  return util.join_path(project_root, ".mutate4lua", "attribution", relative .. ".matrix")
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Deterministic serialization: a loadable Lua chunk, sorted so a rebuilt
-- matrix over unchanged input is byte-identical.
function attribution.encode(matrix)
  local out = {"return {\n"}
  out[#out + 1] = "  version = " .. tostring(matrix.version or CURRENT_MATRIX_VERSION) .. ",\n"
  out[#out + 1] = "  target = " .. util.escape_lua_string(tostring(matrix.target)) .. ",\n"
  if matrix.suite_hash then
    out[#out + 1] = "  suite_hash = " .. util.escape_lua_string(tostring(matrix.suite_hash)) .. ",\n"
  end
  if matrix.target_hash then
    out[#out + 1] = "  target_hash = " .. util.escape_lua_string(tostring(matrix.target_hash)) .. ",\n"
  end
  out[#out + 1] = "  load_lines_known = " .. tostring(matrix.load_lines_known and true or false) .. ",\n"
  out[#out + 1] = "  load_lines = {"
  out[#out + 1] = table.concat(matrix.load_lines or {}, ", ")
  out[#out + 1] = "},\n"
  out[#out + 1] = "  failing_files = {\n"
  local failing = {}
  for _, name in ipairs(matrix.failing_files or {}) do
    failing[#failing + 1] = name
  end
  table.sort(failing)
  for _, name in ipairs(failing) do
    out[#out + 1] = "    " .. util.escape_lua_string(name) .. ",\n"
  end
  out[#out + 1] = "  },\n"
  out[#out + 1] = "  files = {\n"
  for _, path in ipairs(sorted_keys(matrix.files or {})) do
    out[#out + 1] = "    [" .. util.escape_lua_string(path) .. "] = {"
    out[#out + 1] = table.concat(matrix.files[path], ", ")
    out[#out + 1] = "},\n"
  end
  out[#out + 1] = "  },\n}\n"
  return table.concat(out)
end

-- Loaded in an empty environment: the matrix is data, and a cache file must
-- never be able to reach globals.
function attribution.decode(text)
  if type(text) ~= "string" or text == "" then
    return nil, "empty attribution matrix"
  end
  local chunk, load_err = load(text, "=attribution-matrix", "t", {})
  if chunk == nil then
    return nil, tostring(load_err)
  end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= "table" then
    return nil, "attribution matrix must evaluate to a table"
  end
  if type(value.files) ~= "table" then
    return nil, "attribution matrix has no files map"
  end
  value.load_lines = value.load_lines or {}
  value.failing_files = value.failing_files or {}
  return value
end

function attribution.load(project_root, target_relative)
  local path = attribution.cache_path(project_root, target_relative)
  local content = util.read_file(path)
  if content == nil then
    return nil
  end
  local matrix = attribution.decode(content)
  if matrix == nil then
    return nil
  end
  -- An older format was written with different semantics; treat it as absent
  -- rather than trusting it (same rule as the manifest version gate).
  if matrix.version == nil or matrix.version < CURRENT_MATRIX_VERSION then
    return nil
  end
  return matrix
end

function attribution.save(project_root, target_relative, matrix)
  local path = attribution.cache_path(project_root, target_relative)
  local parent = util.parent_dir(path)
  if parent and parent ~= "" then
    util.mkdir_p(parent)
  end
  return util.write_file(path, attribution.encode(matrix))
end

function attribution.is_fresh(matrix, suite_hash, target_hash)
  if matrix == nil then return false end
  if matrix.version ~= CURRENT_MATRIX_VERSION then return false end
  if suite_hash == nil or target_hash == nil then return false end
  return matrix.suite_hash == suite_hash and matrix.target_hash == target_hash
end

function attribution.file_count(matrix)
  local count = 0
  for _ in pairs((matrix or {}).files or {}) do
    count = count + 1
  end
  return count
end

-- Inverts the matrix into the lookup pruning needs: line → test files that
-- executed it.
--
-- `load_lines` are the target's load-time lines, recorded separately by the
-- builder. In a real mutant run the whole suite shares one process, so the
-- target module loads exactly once — whichever test file happens to require it
-- first. A mutation on a load-time line is therefore visible to every test
-- that uses the module, not just to that first file, and per-file attribution
-- cannot name the killers. Such lines are reported as unattributable so the
-- engine falls back to the full suite (空集回退): over-running is correct,
-- under-running would drift the kill set.
-- When the builder could not determine the load-time lines at all
-- (`load_lines_known = false`, e.g. a target that needs host bootstrap to load
-- standalone), no line can be pruned safely: any of them might be load-time.
-- The index then reports every line as unattributable rather than risk
-- under-running.
--
-- `failing_files` are test files that failed during the build — typically ones
-- that only pass as part of the full suite (shared fixtures, ordering). A
-- failed file may have stopped early, so its row can be short; those rows are
-- always kept (a killer must not be dropped from a prune set) but the files are
-- also reported so callers can see how much of the matrix is uncertain.
function attribution.index(matrix)
  local by_line = {}
  local load_lines = {}
  local load_lines_known = (matrix or {}).load_lines_known ~= false
  for _, line in ipairs((matrix or {}).load_lines or {}) do
    load_lines[line] = true
  end
  local failing = {}
  for _, name in ipairs((matrix or {}).failing_files or {}) do
    failing[name] = true
  end
  for path, lines in pairs((matrix or {}).files or {}) do
    for _, line in ipairs(lines) do
      local bucket = by_line[line]
      if bucket == nil then
        bucket = {}
        by_line[line] = bucket
      end
      bucket[#bucket + 1] = path
    end
  end
  for _, bucket in pairs(by_line) do
    table.sort(bucket)
  end
  return {
    by_line = by_line,
    load_lines = load_lines,
    load_lines_known = load_lines_known,
    failing_files = failing,
  }
end

-- Returns the test files that cover `line`, or nil when the line is not
-- attributable (load-time line, or no test file covered it) — nil means "run
-- the full suite".
function attribution.files_for_line(index, line)
  if index == nil then return nil end
  if not index.load_lines_known then return nil end
  if index.load_lines[line] then return nil end
  local bucket = index.by_line[line]
  if bucket == nil or #bucket == 0 then return nil end
  return bucket
end

return attribution
