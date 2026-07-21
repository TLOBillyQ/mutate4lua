local manifest = require("mutate4lua.internal.manifest")
local manifest_store = require("mutate4lua.manifest_store")
local engine = require("mutate4lua.engine")
local util = require("mutate4lua.util")

local function tmp_dir()
  local base = os.tmpname()
  os.remove(base)
  util.mkdir_p(base)
  return base
end

local function rm_rf(path)
  os.execute("rm -rf " .. string.format("%q", path))
end

local function write_file(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local c = f:read("*a")
  f:close()
  return c
end

local function null_buffer()
  return {write = function() end}
end

local function capture_buffer(sink)
  return {write = function(_, ...)
    for _, piece in ipairs({...}) do sink[#sink + 1] = tostring(piece) end
  end}
end

local function make_shell(returns)
  local n = 0
  local self = {}
  function self.fn(_cmd, _cwd, _timeout)
    n = n + 1
    local r = returns[n] or {ok = true}
    return {
      ok = r.ok,
      code = r.code or (r.ok and 0 or 1),
      output = r.output or "",
      elapsed = r.elapsed or 0,
    }
  end
  function self.count() return n end
  return self
end

-- Default store layout inside a tmp dir with no root marker.
local function store_root(dir)
  return util.join_path(dir, ".mutate4lua", "manifest")
end

local sample_data = {
  version = 2,
  project_hash = "cafebabedeadbeef",
  scopes = {
    {
      id = "chunk:player.lua", kind = "chunk", start_line = 1, end_line = 3,
      semantic_hash = "11112222",
      last_mutated_at = "2026-05-21T10:00:00Z",
      last_mutation_lane = "behavior",
      last_mutation_status = "passed",
      last_mutation_sites = 3,
      last_mutation_killed = 3,
    },
    {
      id = "func:player.lua:2", kind = "function", start_line = 2, end_line = 3,
      semantic_hash = "33334444",
    },
  },
}

describe("manifest_store.store_path", function()
  it("maps a forward-slash relative path to <store_root>/<relative>.manifest", function()
    assert.are.equal("/store/src/player.lua.manifest",
      manifest_store.store_path("/store", "src/player.lua"))
  end)

  it("normalizes ./-prefixed relatives", function()
    assert.are.equal("/store/m.lua.manifest",
      manifest_store.store_path("/store", "./m.lua"))
  end)
end)

describe("manifest_store write/read", function()
  local dir
  before_each(function() dir = tmp_dir() end)
  after_each(function() rm_rf(dir) end)

  it("round-trips every field including lastMutation metadata", function()
    manifest_store.write(dir, "m.lua", sample_data)
    local data = manifest_store.read(dir, "m.lua")
    assert.are.equal(2, data.version)
    assert.are.equal("cafebabedeadbeef", data.project_hash)
    assert.are.equal(2, #data.scopes)
    local first = data.scopes[1]
    assert.are.equal("chunk:player.lua", first.id)
    assert.are.equal("2026-05-21T10:00:00Z", first.last_mutated_at)
    assert.are.equal("behavior", first.last_mutation_lane)
    assert.are.equal("passed", first.last_mutation_status)
    assert.are.equal(3, first.last_mutation_sites)
    assert.are.equal(3, first.last_mutation_killed)
    assert.are.equal("func:player.lua:2", data.scopes[2].id)
    assert.is_nil(data.scopes[2].last_mutation_status)
  end)

  it("creates nested store directories for nested relatives", function()
    manifest_store.write(dir, "src/player.lua", sample_data)
    assert.is_true(util.is_file(util.join_path(dir, "src", "player.lua.manifest")))
    local data = manifest_store.read(dir, "src/player.lua")
    assert.are.equal("cafebabedeadbeef", data.project_hash)
  end)

  it("writes no comment markers, only the bare key=value body", function()
    manifest_store.write(dir, "m.lua", sample_data)
    local raw = read_file(manifest_store.store_path(dir, "m.lua"))
    assert.is_nil(raw:find("mutate4lua-manifest", 1, true))
    assert.matches("^version=2\nprojectHash=cafebabedeadbeef\n", raw)
  end)

  it("returns nil when the entry does not exist", function()
    assert.is_nil(manifest_store.read(dir, "missing.lua"))
  end)

  it("returns nil when the entry is not parseable", function()
    local path = manifest_store.store_path(dir, "junk.lua")
    write_file(path, "this is not a manifest\n")
    assert.is_nil(manifest_store.read(dir, "junk.lua"))
  end)

  it("shares the body format with the legacy footer reader", function()
    -- A body serialized for the store parses identically when wrapped in the
    -- legacy footer markers, and vice versa.
    manifest_store.write(dir, "m.lua", sample_data)
    local body = read_file(manifest_store.store_path(dir, "m.lua"))
    write_file(util.join_path(dir, "legacy.lua"),
      "return {}\n\n--[[ mutate4lua-manifest\n" .. body .. "]]\n")
    local from_footer = manifest.read(util.join_path(dir, "legacy.lua"))
    assert.are.same(manifest_store.read(dir, "m.lua"), from_footer)
  end)
end)

describe("engine manifest fallback", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  it("falls back to a legacy footer manifest when the store has no entry", function()
    -- Unmigrated project: footer present, store empty. The footer matches the
    -- current source, so a re-run enumerates 0 sites and runs nothing.
    write_file(target_abs, "return true\n")
    local env = {cwd = dir, stdout = null_buffer(), stderr = null_buffer()}
    engine.update_manifest({target = target_rel}, env) -- store entry for reference data
    local reference = manifest_store.read(store_root(dir), target_rel)
    manifest.write(target_abs, "return true\n", reference) -- legacy footer
    rm_rf(store_root(dir)) -- simulate an unmigrated project: no store
    assert.is_nil(manifest_store.read(store_root(dir), target_rel))

    local shell = make_shell({})
    local env2 = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    local code = engine.mutate({target = target_rel, test_command = "true", json = true}, env2)
    assert.are.equal(0, code)
    assert.are.equal(0, shell.count())
    -- the fallback never rewrites the target, footer included
    assert.is_not_nil(manifest.read(target_abs))
  end)

  it("prefers the store entry over a stale legacy footer", function()
    write_file(target_abs, "return true\n")
    -- Store entry with a bogus hash: all scopes count as changed -> sites run.
    manifest_store.write(store_root(dir), target_rel, {
      version = 2, project_hash = "bogus", scopes = {},
    })
    -- Footer with no scopes either; the store must win, so an empty-scope
    -- footer cannot suppress the run.
    manifest.write(target_abs, "return true\n", {version = 2, project_hash = "footer", scopes = {}})
    local shell = make_shell({{ok = true}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", json = true}, env)
    assert.is_true(shell.count() >= 2, "store entry should win over the footer and run baseline + mutant")
  end)
end)

describe("engine.migrate_manifest", function()
  local dir
  local target_rel = "src/m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
    util.mkdir_p(util.parent_dir(target_abs))
  end)
  after_each(function() rm_rf(dir) end)

  local function write_target_with_footer()
    write_file(target_abs, "return true\n")
    manifest.write(target_abs, "return true\n", sample_data)
    return read_file(target_abs)
  end

  it("moves a legacy footer into the store and strips the target", function()
    local before = write_target_with_footer()
    local out = {}
    local env = {cwd = dir, stdout = capture_buffer(out), stderr = null_buffer()}
    local code = engine.migrate_manifest({target = target_rel}, env)
    assert.are.equal(0, code)
    assert.matches("manifest migrated: src/m%.lua", table.concat(out))

    -- store holds every field of the former footer
    local data = manifest_store.read(store_root(dir), target_rel)
    assert.are.same({
      version = sample_data.version,
      project_hash = sample_data.project_hash,
      scopes = sample_data.scopes,
    }, data)

    -- target is rewritten to exactly the strip() output, with no footer left
    assert.are.equal(manifest.strip(before), read_file(target_abs))
    assert.is_nil(manifest.read(target_abs))
  end)

  it("is idempotent: a second run reports the manifest as already migrated", function()
    write_target_with_footer()
    local env = {cwd = dir, stdout = null_buffer(), stderr = null_buffer()}
    engine.migrate_manifest({target = target_rel}, env)
    local store_bytes = read_file(manifest_store.store_path(store_root(dir), target_rel))
    local target_bytes = read_file(target_abs)

    local out = {}
    local env2 = {cwd = dir, stdout = capture_buffer(out), stderr = null_buffer()}
    local code = engine.migrate_manifest({target = target_rel}, env2)
    assert.are.equal(0, code)
    assert.matches("manifest already migrated: src/m%.lua", table.concat(out))
    assert.are.equal(store_bytes, read_file(manifest_store.store_path(store_root(dir), target_rel)))
    assert.are.equal(target_bytes, read_file(target_abs))
  end)

  it("reports when there is nothing to migrate", function()
    write_file(target_abs, "return true\n")
    local out = {}
    local env = {cwd = dir, stdout = capture_buffer(out), stderr = null_buffer()}
    local code = engine.migrate_manifest({target = target_rel}, env)
    assert.are.equal(0, code)
    assert.matches("no manifest to migrate: src/m%.lua", table.concat(out))
  end)

  it("emits JSON with migrated=true when --json is set", function()
    write_target_with_footer()
    local out = {}
    local env = {cwd = dir, stdout = capture_buffer(out), stderr = null_buffer()}
    local code = engine.migrate_manifest({target = target_rel, json = true}, env)
    assert.are.equal(0, code)
    local decoded = util.decode_json(table.concat(out))
    assert.are.equal("src/m.lua", decoded.file)
    assert.is_true(decoded.migrated)
  end)

  it("honors env.manifest_dir as a store override", function()
    write_target_with_footer()
    local override = util.join_path(dir, "custom_store")
    local env = {cwd = dir, stdout = null_buffer(), stderr = null_buffer(), manifest_dir = override}
    local code = engine.migrate_manifest({target = target_rel}, env)
    assert.are.equal(0, code)
    assert.is_not_nil(manifest_store.read(override, target_rel))
    assert.is_nil(manifest_store.read(store_root(dir), target_rel))
  end)

  it("resolves a relative env.manifest_dir against the workspace root", function()
    write_target_with_footer()
    local env = {cwd = dir, stdout = null_buffer(), stderr = null_buffer(), manifest_dir = "rel_store"}
    local code = engine.migrate_manifest({target = target_rel}, env)
    assert.are.equal(0, code)
    assert.is_not_nil(manifest_store.read(util.join_path(dir, "rel_store"), target_rel))
  end)
end)
