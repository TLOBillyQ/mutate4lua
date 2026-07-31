local manifest = require("mutate4lua.internal.manifest")
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
  local f = io.open(path, "rb")
  if f == nil then return nil end
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

describe("engine.update_manifest", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  it("writes a v4 footer and does not require a driver", function()
    write_file(target_abs, "return true\n")
    local out = {}
    local code = engine.update_manifest({target = target_rel}, {
      cwd = dir, stdout = capture_buffer(out), stderr = null_buffer(),
    })
    assert.are.equal(0, code)
    assert.matches("manifest updated: m%.lua", table.concat(out))
    local data = manifest.read(target_abs)
    assert.is_not_nil(data)
    assert.are.equal(4, data.version)
    for _, scope in ipairs(data.scopes) do
      assert.is_nil(scope.last_mutated_at)
      assert.is_nil(scope.last_mutation_status)
    end
  end)

  it("succeeds even when the target test suite would fail", function()
    write_file(target_abs, "return true\n")
    local code = engine.update_manifest({target = target_rel}, {
      cwd = dir, stdout = null_buffer(), stderr = null_buffer(),
    })
    assert.are.equal(0, code)
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

  it("writes a v4 footer when all mutants are killed and --lines is unset", function()
    write_file(target_abs, "return 1 == 2\n")
    local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", max_workers = 1}, env)
    local data = manifest.read(target_abs)
    assert.is_not_nil(data)
    assert.are.equal(4, data.version)
  end)

  it("does not write a footer when a mutant survives", function()
    write_file(target_abs, "return 1 == 2\n")
    local shell = make_shell({{ok = true}, {ok = true}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", max_workers = 1}, env)
    assert.is_nil(manifest.read(target_abs))
  end)

  it("suppresses the footer when --lines is used", function()
    write_file(target_abs, "return 1 == 2\n")
    local shell = make_shell({{ok = true}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({
      target = target_rel,
      test_command = "true",
      line_set = {[1] = true},
      max_workers = 1,
    }, env)
    assert.is_nil(manifest.read(target_abs))
  end)
end)

describe("engine.mutate exit codes", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  it("returns 2 when the baseline fails", function()
    write_file(target_abs, "return 1 == 2\n")
    local shell = make_shell({{ok = false, code = 1}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    local code = engine.mutate({target = target_rel, test_command = "false", max_workers = 1}, env)
    assert.are.equal(2, code)
  end)

  it("returns 3 when a mutant survives", function()
    write_file(target_abs, "return 1 == 2\n")
    local shell = make_shell({{ok = true}, {ok = true}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    local code = engine.mutate({target = target_rel, test_command = "true", max_workers = 1}, env)
    assert.are.equal(3, code)
  end)

  it("returns 0 when every mutant is killed", function()
    write_file(target_abs, "return 1 == 2\n")
    local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    local code = engine.mutate({target = target_rel, test_command = "true", max_workers = 1}, env)
    assert.are.equal(0, code)
  end)
end)

describe("engine.mutate differential selection", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  local function rewrite_preserving_footer(transform)
    local content = assert(read_file(target_abs))
    local stripped = manifest.strip(content)
    local new_stripped = transform(stripped)
    if not new_stripped:match("\n$") then
      new_stripped = new_stripped .. "\n"
    end
    local footer = content:sub(#stripped + 1)
    write_file(target_abs, new_stripped .. footer)
  end

  it("runs no sites and does not run a baseline when the manifest is unchanged", function()
    write_file(target_abs, "local function f() return 1 == 2 end\nreturn f\n")
    engine.update_manifest({target = target_rel}, {cwd = dir, stdout = null_buffer(), stderr = null_buffer()})
    rewrite_preserving_footer(function(s) return s end)
    local shell = make_shell({})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    local code = engine.mutate({target = target_rel, test_command = "true", max_workers = 1}, env)
    assert.are.equal(0, code)
    assert.are.equal(0, shell.count())
  end)

  it("selects all covered sites when no manifest exists", function()
    write_file(target_abs, "return 1 == 2\n")
    local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", max_workers = 1}, env)
    assert.is_true(shell.count() >= 2, "expected baseline + at least one mutant")
  end)

  it("selects only sites in changed scopes when the module hash changes", function()
    write_file(target_abs, "local function f() return 1 == 2 end\nlocal function g() return 3 == 4 end\nreturn f\n")
    engine.update_manifest({target = target_rel}, {cwd = dir, stdout = null_buffer(), stderr = null_buffer()})
    rewrite_preserving_footer(function(s)
      return s:gsub("return 1 == 2", "return 2 ~= 3")
    end)
    local shell = make_shell({{ok = true}, {ok = false}})
    local out = {}
    local env = {cwd = dir, run_shell = shell.fn, stdout = capture_buffer(out), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", max_workers = 1}, env)
    -- f is changed (now one site); g is unchanged. Baseline + 1 mutant ran.
    assert.are.equal(2, shell.count())
  end)

  it("--mutate-all bypasses the manifest filter", function()
    write_file(target_abs, "return 1 == 2\n")
    engine.update_manifest({target = target_rel}, {cwd = dir, stdout = null_buffer(), stderr = null_buffer()})
    local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", mutate_all = true, max_workers = 1}, env)
    assert.is_true(shell.count() >= 2)
  end)

  it("--since-last-run restricts to changed scopes even when the module hash is unchanged", function()
    write_file(target_abs, "local function f() return 1 == 2 end\nreturn f\n")
    engine.update_manifest({target = target_rel}, {cwd = dir, stdout = null_buffer(), stderr = null_buffer()})
    rewrite_preserving_footer(function(s) return s end)
    local shell = make_shell({})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    local code = engine.mutate({target = target_rel, test_command = "true", since_last_run = true, max_workers = 1}, env)
    assert.are.equal(0, code)
    assert.are.equal(0, shell.count())
  end)
end)

describe("engine.mutate coverage handling", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  local function make_luacov_report(hits)
    -- hits is an array indexed by source line: true/numeric = covered,
    -- false = uncovered executable, nil = non-executable.
    local lines = {
      "==============================================================================",
      target_rel,
      "==============================================================================",
    }
    for i = 1, #hits do
      local kind = hits[i]
      if kind == nil then
        lines[#lines + 1] = "        -- non-executable"
      elseif kind == false then
        lines[#lines + 1] = "  *0    print(" .. i .. ")"
      else
        lines[#lines + 1] = string.format("%6d    print(%d)", (tonumber(kind) or 1), i)
      end
    end
    return table.concat(lines, "\n") .. "\n"
  end

  it("warns and treats all sites as covered when --test-command is used", function()
    write_file(target_abs, "return 1 == 2\n")
    local err = {}
    local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = capture_buffer(err)}
    engine.mutate({target = target_rel, test_command = "true", max_workers = 1}, env)
    assert.matches("test%-command disables coverage filtering", table.concat(err))
  end)

  it("reuses an existing luacov report with --reuse-coverage", function()
    write_file(target_abs, "local x = 1\nlocal y = 2\nreturn x == y\n")
    -- Line 1 has the only mutation site in this file; mark it uncovered.
    write_file(util.join_path(dir, "luacov.report.out"), make_luacov_report({false, false, false}))
    local shell = make_shell({{ok = true}})
    local out = {}
    local env = {cwd = dir, run_shell = shell.fn, stdout = capture_buffer(out), stderr = null_buffer()}
    local code = engine.mutate({
      target = target_rel, reuse_coverage = true, max_workers = 1,
      driver_script = "driver.lua",
    }, env)
    assert.are.equal(0, code)
    local output = table.concat(out)
    assert.matches("no covered mutation sites", output)
    assert.matches("uncovered mutation sites: ", output)
  end)

  it("warns and continues without filtering when --reuse-coverage has no report", function()
    write_file(target_abs, "return 1 == 2\n")
    local err = {}
    local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = capture_buffer(err)}
    engine.mutate({
      target = target_rel, reuse_coverage = true, max_workers = 1,
      driver_script = "driver.lua",
    }, env)
    assert.matches("reuse%-coverage requested but", table.concat(err))
  end)

  it("succeeds when all discovered sites are uncovered", function()
    write_file(target_abs, "local y = 2\nreturn y == 3\n")
    -- The mutation site is on line 2 (the == comparison).
    write_file(util.join_path(dir, "luacov.report.out"), make_luacov_report({nil, false}))
    local shell = make_shell({{ok = true}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = null_buffer()}
    local code = engine.mutate({
      target = target_rel, reuse_coverage = true, max_workers = 1,
      driver_script = "driver.lua",
    }, env)
    assert.are.equal(0, code)
  end)
end)

describe("engine.mutate diagnostics block", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  it("prints the pre-worker diagnostics block", function()
    write_file(target_abs, "return 1 == 2\n")
    local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
    local out = {}
    local env = {cwd = dir, run_shell = shell.fn, stdout = capture_buffer(out), stderr = null_buffer()}
    engine.mutate({target = target_rel, test_command = "true", max_workers = 1}, env)
    local output = table.concat(out)
    assert.matches("total mutation sites:", output)
    assert.matches("covered mutation sites:", output)
    assert.matches("uncovered mutation sites:", output)
    assert.matches("changed mutation sites:", output)
    assert.matches("manifest exists:", output)
    assert.matches("module hash changed:", output)
    assert.matches("differential surface area:", output)
    assert.matches("manifest%-violating surface area:", output)
  end)
end)

describe("engine.mutate mutation warning", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  it("warns when the selected count exceeds the threshold", function()
    write_file(target_abs, "return 1 == 2\n")
    local err = {}
    local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
    local env = {cwd = dir, run_shell = shell.fn, stdout = null_buffer(), stderr = capture_buffer(err)}
    engine.mutate({target = target_rel, test_command = "true", mutation_warning = 0, max_workers = 1}, env)
    assert.matches("warning:.*mutations exceed threshold 0", table.concat(err))
  end)
end)

describe("engine.scan", function()
  local dir
  local target_rel = "m.lua"
  local target_abs

  before_each(function()
    dir = tmp_dir()
    target_abs = util.join_path(dir, target_rel)
  end)
  after_each(function() rm_rf(dir) end)

  it("marks sites whose scopes differ from the manifest with *", function()
    write_file(target_abs, "local function f() return 1 == 2 end\nreturn f\n")
    engine.update_manifest({target = target_rel}, {cwd = dir, stdout = null_buffer(), stderr = null_buffer()})
    local content = read_file(target_abs)
    local stripped = manifest.strip(content)
    local modified = stripped:gsub("return 1 == 2", "return 2 ~= 3")
    local footer = content:sub(#stripped + 1)
    write_file(target_abs, modified .. footer)
    local out = {}
    local code = engine.scan({target = target_rel}, {cwd = dir, stdout = capture_buffer(out), stderr = null_buffer()})
    assert.are.equal(0, code)
    local output = table.concat(out)
    assert.matches("^file: m%.lua", output)
    assert.matches("sites: %d+", output)
    assert.matches("%* L%d+", output)
  end)
end)

describe("engine.mutate parallel path", function()
  local dir
  local target_rel = "m.lua"
  local target_abs
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
      run_shell = make_shell({{ok = true}}).fn,
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
      target = target_rel, test_command = "true",
      mutate_all = true, max_workers = 4,
    }, env)
    assert.is_not_nil(captured, "parallel runner was not used")
    assert.is_true(captured.job_count >= 2, "expected multiple mutation sites")
    assert.is_true(captured.worker_count >= 2, "expected more than one worker")
  end)

  it("does not forward a poll_interval", function()
    write_file(target_abs, multi_site_body)
    local captured
    local env = parallel_env(function() return killed() end)
    env.run_parallel = function(spec)
      captured = spec
      local results = {}
      for i = 1, spec.job_count do
        results[i] = killed()
      end
      return results
    end
    engine.mutate({
      target = target_rel, test_command = "true",
      mutate_all = true, max_workers = 4,
    }, env)
    assert.is_nil(captured.poll_interval)
  end)

  it("writes a v4 footer when every parallel mutant is killed", function()
    write_file(target_abs, multi_site_body)
    engine.mutate({
      target = target_rel, test_command = "true",
      mutate_all = true, max_workers = 4,
    }, parallel_env(function() return killed() end))
    local data = manifest.read(target_abs)
    assert.is_not_nil(data)
    assert.are.equal(4, data.version)
  end)
end)

describe("engine driver requirement", function()
  local dir

  before_each(function()
    dir = tmp_dir()
    write_file(util.join_path(dir, "m.lua"), "return true\n")
  end)
  after_each(function() rm_rf(dir) end)

  it("errors clearly when neither a driver script nor --test-command is available", function()
    local err = {}
    local env = {cwd = dir, stdout = null_buffer(), stderr = capture_buffer(err)}
    local code = engine.mutate({target = "m.lua"}, env)
    assert.are.equal(1, code)
    assert.matches("driver script required", table.concat(err))
  end)
end)
