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

-- Default store layout: <project_root>/.mutate4lua/manifest/<relative>.manifest.
-- In these specs the tmp dir has no root marker, so find_root resolves to it.
local function store_root(dir)
  return util.join_path(dir, ".mutate4lua", "manifest")
end

local function read_store(dir, relative)
  return manifest_store.read(store_root(dir), relative)
end

local function store_file_path(dir, relative)
  return manifest_store.store_path(store_root(dir), relative)
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

describe("engine.update_manifest", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  it("writes a v2 store entry with no lastMutation fields and leaves the target untouched", function()
    write_file(target_abs, "return true\n")
    local env = {cwd = dir, stdout = null_buffer(), stderr = null_buffer()}
    local code = engine.update_manifest({target = target_rel}, env)
    assert.are.equal(0, code)
    local data = read_store(dir, target_rel)
    assert.is_not_nil(data)
    assert.are.equal(2, data.version)
    for _, scope in ipairs(data.scopes) do
      assert.is_nil(scope.last_mutated_at)
      assert.is_nil(scope.last_mutation_status)
    end
    -- the business source is never rewritten: no footer, byte-identical
    assert.are.equal("return true\n", read_file(target_abs))
    assert.is_nil(manifest.read(target_abs))
  end)

  it("preserves scope ids and semantic hashes when upgrading a v1 store entry to v2", function()
    write_file(target_abs, "local function f()\n  return 1 == 2\nend\nreturn f\n")
    local env = {cwd = dir, stdout = null_buffer(), stderr = null_buffer()}
    engine.update_manifest({target = target_rel}, env)
    local v2_initial = read_store(dir, target_rel)
    -- Hand-write a v1 store body using the same ids and hashes
    local lines = {"version=1", "projectHash=" .. (v2_initial.project_hash or "x")}
    for i, scope in ipairs(v2_initial.scopes) do
      local prefix = "scope." .. (i - 1) .. "."
      lines[#lines+1] = prefix .. "id=" .. scope.id
      lines[#lines+1] = prefix .. "kind=" .. scope.kind
      lines[#lines+1] = prefix .. "startLine=" .. tostring(scope.start_line)
      lines[#lines+1] = prefix .. "endLine=" .. tostring(scope.end_line)
      lines[#lines+1] = prefix .. "semanticHash=" .. scope.semantic_hash
    end
    write_file(store_file_path(dir, target_rel), table.concat(lines, "\n") .. "\n")
    assert.are.equal(1, read_store(dir, target_rel).version)
    engine.update_manifest({target = target_rel}, env)
    local v2_after = read_store(dir, target_rel)
    assert.are.equal(2, v2_after.version)
    assert.are.equal(#v2_initial.scopes, #v2_after.scopes)
    for i, scope in ipairs(v2_after.scopes) do
      assert.are.equal(v2_initial.scopes[i].id, scope.id)
      assert.are.equal(v2_initial.scopes[i].semantic_hash, scope.semantic_hash)
    end
  end)
end)

describe("engine.mutate write gating", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  it("writes a v2 store entry when all mutants are killed and --lines is unset", function()
    write_file(target_abs, "return true\n")
    local shell = make_shell({{ok = true}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", json = true}, env)
    local data = read_store(dir, target_rel)
    assert.is_not_nil(data)
    assert.are.equal(2, data.version)
    -- the target itself is never modified, even when a manifest is recorded
    assert.are.equal("return true\n", read_file(target_abs))
  end)

  it("leaves the file byte-identical and writes no store entry when the kill score is below the threshold", function()
    -- single site, survives -> 0% kill score, well under the threshold
    write_file(target_abs, "return true\n")
    local before = read_file(target_abs)
    local shell = make_shell({{ok = true}, {ok = true}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", json = true}, env)
    assert.are.equal(before, read_file(target_abs))
    assert.is_nil(read_store(dir, target_rel))
  end)

  -- 10 mutation sites: `1`->0, five `<`->`<=`, four `and`->`or`.
  local ten_site_body = "return 1 < 2 and 3 < 4 and 5 < 6 and 7 < 8 and 9 < 10\n"

  it("records a manifest at the 90% kill threshold despite a residual survivor", function()
    -- baseline + 9 killed; the 10th mutant defaults to a passing test (survives)
    -- -> 9/10 = 90%. A file with irreducible-equivalent mutants must still pin
    -- an empirical baseline instead of staying bootstrap-only.
    write_file(target_abs, ten_site_body)
    local returns = {{ok = true}}
    for _ = 1, 9 do returns[#returns + 1] = {ok = false} end
    local shell = make_shell(returns)
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", json = true, max_workers = 1}, env)
    local data = read_store(dir, target_rel)
    assert.is_not_nil(data)
    assert.are.equal(2, data.version)
    local scope = data.scopes[1]
    assert.are.equal(10, scope.last_mutation_sites)
    assert.are.equal(9, scope.last_mutation_killed)
    -- the residual survivor is recorded honestly, not masked as "passed"
    assert.are.equal("survived", scope.last_mutation_status)
  end)

  it("leaves the file byte-identical and writes no store entry when the kill score is just under the threshold", function()
    -- baseline + 8 killed; two mutants survive -> 8/10 = 80% < 90%, no record.
    write_file(target_abs, ten_site_body)
    local before = read_file(target_abs)
    local returns = {{ok = true}}
    for _ = 1, 8 do returns[#returns + 1] = {ok = false} end
    local shell = make_shell(returns)
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", json = true, max_workers = 1}, env)
    assert.are.equal(before, read_file(target_abs))
    assert.is_nil(read_store(dir, target_rel))
  end)

  it("leaves the file byte-identical and writes no store entry when --lines is set, even with all killed", function()
    write_file(target_abs, "return true\n")
    local before = read_file(target_abs)
    local shell = make_shell({{ok = true}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({
      target = target_rel,
      test_command = "true",
      json = true,
      line_set = {[1] = true},
    }, env)
    assert.are.equal(before, read_file(target_abs))
    assert.is_nil(read_store(dir, target_rel))
  end)
end)

describe("engine.mutate differential filter", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  it("re-run after --update-manifest enumerates 0 sites and leaves the store entry byte-identical", function()
    write_file(target_abs, "return true\n")
    local env = {cwd = dir, stdout = null_buffer(), stderr = null_buffer()}
    engine.update_manifest({target = target_rel}, env)
    local target_before = read_file(target_abs)
    local manifest_before = read_file(store_file_path(dir, target_rel))
    local shell = make_shell({})
    local env2 = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", json = true}, env2)
    assert.are.equal(target_before, read_file(target_abs))
    assert.are.equal(manifest_before, read_file(store_file_path(dir, target_rel)))
    assert.are.equal(0, shell.count())
  end)

  it("--mutate-all bypasses the manifest filter and still runs baseline + mutants", function()
    write_file(target_abs, "return true\n")
    local env = {cwd = dir, stdout = null_buffer(), stderr = null_buffer()}
    engine.update_manifest({target = target_rel}, env)
    local shell = make_shell({{ok = true}, {ok = false}})
    local env2 = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({
      target = target_rel,
      test_command = "true",
      json = true,
      mutate_all = true,
    }, env2)
    assert.is_true(shell.count() >= 2, "mutate-all should drive baseline + at least one mutant")
  end)
end)

describe("engine.mutate parallel path", function()
  local dir
  local target_rel = "m.lua"
  local target_abs
  -- A body with several mutation sites (==, ~=, integer literals) so
  -- worker_count = min(max_workers, #sites) > 1 and the parallel branch runs.
  local multi_site_body = "return (1 == 2) and (3 ~= 4)\n"

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  local function parallel_env(make_results)
    return {
      cwd = dir,
      stdout = null_buffer(),
      stderr = null_buffer(),
      run_shell = make_shell({{ok = true}}).fn, -- baseline passes; mutants go via run_parallel
      create_workspaces = function(_, count)
        local list = {}
        for i = 1, count do list[i] = util.join_path(dir, "ws_" .. i) end
        return list
      end,
      run_parallel = function(spec)
        local results = {}
        for i = 1, spec.job_count do
          results[i] = make_results(i)
        end
        return results
      end,
    }
  end

  local function killed() return {ok = false, code = 1, output = "", elapsed = 0, timed_out = false} end

  it("routes mutants through run_parallel when max_workers > 1", function()
    write_file(target_abs, multi_site_body)
    local captured
    local env = parallel_env(function() return killed() end)
    local base_run_parallel = env.run_parallel
    env.run_parallel = function(spec)
      captured = spec
      return base_run_parallel(spec)
    end
    engine.mutate({
      target = target_rel, test_command = "true", json = true,
      mutate_all = true, max_workers = 4,
    }, env)
    assert.is_not_nil(captured, "parallel runner was not used")
    assert.is_true(captured.job_count >= 2, "expected multiple mutation sites")
    assert.is_true(captured.worker_count >= 2, "expected more than one worker")
  end)

  it("forwards poll_interval into the parallel runner", function()
    write_file(target_abs, multi_site_body)
    local captured
    local env = parallel_env(function() return killed() end)
    local base_run_parallel = env.run_parallel
    env.run_parallel = function(spec)
      captured = spec
      return base_run_parallel(spec)
    end
    engine.mutate({
      target = target_rel, test_command = "true", json = true,
      mutate_all = true, max_workers = 4, poll_interval = 0.05,
    }, env)
    assert.are.equal(0.05, captured.poll_interval)
  end)

  it("writes a v2 store entry when every parallel mutant is killed", function()
    write_file(target_abs, multi_site_body)
    engine.mutate({
      target = target_rel, test_command = "true", json = true,
      mutate_all = true, max_workers = 4,
    }, parallel_env(function() return killed() end))
    local data = read_store(dir, target_rel)
    assert.is_not_nil(data)
    assert.are.equal(2, data.version)
    assert.are.equal(multi_site_body, read_file(target_abs))
  end)

  it("leaves the file byte-identical when a parallel mutant survives", function()
    write_file(target_abs, multi_site_body)
    local before = read_file(target_abs)
    engine.mutate({
      target = target_rel, test_command = "true", json = true,
      mutate_all = true, max_workers = 4,
    }, parallel_env(function(i)
      if i == 1 then
        return {ok = true, code = 0, output = "", elapsed = 0, timed_out = false}
      end
      return killed()
    end))
    assert.are.equal(before, read_file(target_abs))
  end)
end)


describe("engine driver requirement", function()
  local dir

  before_each(function()
    dir = tmp_dir()
    write_file(util.join_path(dir, "m.lua"), "return true\n")
  end)
  after_each(function() rm_rf(dir) end)

  local function capture_buffer(sink)
    return {write = function(_, ...)
      for _, piece in ipairs({...}) do sink[#sink + 1] = tostring(piece) end
    end}
  end

  it("errors clearly when neither a driver script nor --test-command is available", function()
    -- The library ships no default driver path; the host must provide one.
    local err = {}
    local env = {cwd = dir, stdout = null_buffer(), stderr = capture_buffer(err)}
    local code = engine.mutate({target = "m.lua"}, env)
    assert.are.equal(1, code)
    assert.matches("driver script required", table.concat(err))
  end)

  it("errors in --index-suites too when no driver script is available", function()
    local err = {}
    local env = {cwd = dir, stdout = null_buffer(), stderr = capture_buffer(err)}
    local code = engine.index_suites({lane = "behavior"}, env)
    assert.are.equal(1, code)
    assert.matches("driver script required", table.concat(err))
  end)
end)
