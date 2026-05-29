local parallel = require("mutate4lua.internal.parallel")
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

local function read_file(path)
  local f = io.open(path, "rb")
  if f == nil then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

-- Runs the launcher script synchronously (no `&`) so the sentinel exists by the
-- time dispatch returns. Exercises the real launcher-script generation and the
-- real status/output sentinel handling, just without concurrency timing.
local function sync_launch(recorded_scripts)
  return function(script_path)
    if recorded_scripts then
      recorded_scripts[#recorded_scripts + 1] = read_file(script_path)
    end
    os.execute("sh " .. string.format("%q", script_path))
  end
end

-- Forces exactly one idle scan per job without real concurrency: launch records
-- each job's status sentinel path (parsed from the launcher script) but writes
-- nothing, so the first scan finds no sentinel. The paired completing_sleep then
-- writes the sentinels, so the next scan completes the jobs. This lets a test
-- observe the poll_interval the loop hands to sleep on an idle scan.
local function deferred_launch(state)
  return function(script_path)
    local script = read_file(script_path)
    local status_path = script:match("mv %-f '.-%.part' '(.-)'")
    state.pending[#state.pending + 1] = status_path
  end
end

local function completing_sleep(state)
  return function(seconds)
    state.intervals[#state.intervals + 1] = seconds
    local pending = state.pending
    state.pending = {}
    for _, status_path in ipairs(pending) do
      local f = assert(io.open(status_path, "w"))
      f:write("0\n")
      f:close()
    end
  end
end

describe("parallel.run", function()
  local workspaces

  before_each(function()
    workspaces = { tmp_dir(), tmp_dir(), tmp_dir() }
  end)
  after_each(function()
    for _, ws in ipairs(workspaces) do rm_rf(ws) end
  end)

  it("returns an empty result set for zero jobs", function()
    local results = parallel.run({
      worker_count = 2,
      job_count = 0,
      workspaces = workspaces,
      prepare = function() end,
      command = function() return "true" end,
      launch = sync_launch(),
      sleep = function() end,
    })
    assert.are.equal(0, #results)
  end)

  it("runs every job and maps exit codes to ok / timed_out", function()
    local exit_codes = { 0, 1, 0, 124, 0 }
    local results = parallel.run({
      worker_count = 2,
      job_count = #exit_codes,
      workspaces = workspaces,
      prepare = function() end,
      -- subshell so the exit code is captured by the launcher rather than the
      -- builtin `exit` terminating the launcher before it writes the sentinel.
      command = function(i) return "(exit " .. tostring(exit_codes[i]) .. ")" end,
      timeout = nil,
      launch = sync_launch(),
      sleep = function() end,
    })
    assert.are.equal(#exit_codes, #results)
    for i, code in ipairs(exit_codes) do
      assert.is_not_nil(results[i], "missing result for job " .. i)
      assert.are.equal(code, results[i].code)
      assert.are.equal(code == 0, results[i].ok)
      assert.are.equal(code == 124, results[i].timed_out)
    end
  end)

  it("captures job stdout/stderr into the result output", function()
    local results = parallel.run({
      worker_count = 1,
      job_count = 1,
      workspaces = workspaces,
      prepare = function() end,
      command = function() return "echo hello-from-job" end,
      launch = sync_launch(),
      sleep = function() end,
    })
    assert.is_truthy(results[1].output:find("hello-from-job", 1, true))
  end)

  it("assigns jobs to workspaces drawn from the provided pool", function()
    local seen = {}
    local pool = {}
    for _, ws in ipairs(workspaces) do pool[ws] = true end
    parallel.run({
      worker_count = 2,
      job_count = 4,
      workspaces = workspaces,
      prepare = function(i, ws)
        seen[i] = ws
      end,
      command = function() return "true" end,
      launch = sync_launch(),
      sleep = function() end,
    })
    for i = 1, 4 do
      assert.is_truthy(pool[seen[i]], "job " .. i .. " ran outside the workspace pool")
    end
  end)

  it("fires on_complete exactly once per job", function()
    local completed = {}
    parallel.run({
      worker_count = 3,
      job_count = 5,
      workspaces = workspaces,
      prepare = function() end,
      command = function() return "true" end,
      on_complete = function(i)
        completed[i] = (completed[i] or 0) + 1
      end,
      launch = sync_launch(),
      sleep = function() end,
    })
    for i = 1, 5 do
      assert.are.equal(1, completed[i])
    end
  end)

  it("defaults poll_interval to 0 so the idle wait does not fork a shell", function()
    local state = { pending = {}, intervals = {} }
    parallel.run({
      worker_count = 1,
      job_count = 1,
      workspaces = workspaces,
      prepare = function() end,
      command = function() return "true" end,
      launch = deferred_launch(state),
      sleep = completing_sleep(state),
    })
    assert.are.same({ 0 }, state.intervals)
  end)

  it("forwards an explicit poll_interval to the idle sleep", function()
    local state = { pending = {}, intervals = {} }
    parallel.run({
      worker_count = 1,
      job_count = 1,
      workspaces = workspaces,
      prepare = function() end,
      command = function() return "true" end,
      poll_interval = 0.05,
      launch = deferred_launch(state),
      sleep = completing_sleep(state),
    })
    assert.are.same({ 0.05 }, state.intervals)
  end)

  it("embeds the timeout command and atomic sentinel commit in the launcher", function()
    local scripts = {}
    parallel.run({
      worker_count = 1,
      job_count = 1,
      workspaces = workspaces,
      prepare = function() end,
      command = function() return "run-the-tests" end,
      timeout = 12,
      timeout_command = "timeout",
      launch = sync_launch(scripts),
      sleep = function() end,
    })
    local script = scripts[1]
    assert.is_truthy(script:find("timeout 12 run-the-tests", 1, true), "missing timeout prefix")
    assert.is_truthy(script:find("mv -f", 1, true), "sentinel should be committed via atomic rename")
  end)
end)
