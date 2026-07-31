local lu = require("luaunit")
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
-- writes the sentinels, so the next scan completes the jobs.
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

TestParallel = {}

function TestParallel:setUp()
  self.workspaces = { tmp_dir(), tmp_dir(), tmp_dir() }
end

function TestParallel:tearDown()
  for _, ws in ipairs(self.workspaces) do rm_rf(ws) end
end

function TestParallel:testReturnsEmptyResultSetForZeroJobs()
  local results = parallel.run({
    worker_count = 2,
    job_count = 0,
    workspaces = self.workspaces,
    prepare = function() end,
    command = function() return "true" end,
    launch = sync_launch(),
    sleep = function() end,
  })
  lu.assertEquals(#results, 0)
end

function TestParallel:testRunsEveryJobAndMapsExitCodesToOkAndTimedOut()
  local exit_codes = { 0, 1, 0, 124, 0 }
  local results = parallel.run({
    worker_count = 2,
    job_count = #exit_codes,
    workspaces = self.workspaces,
    prepare = function() end,
    -- subshell so the exit code is captured by the launcher rather than the
    -- builtin `exit` terminating the launcher before it writes the sentinel.
    command = function(i) return "(exit " .. tostring(exit_codes[i]) .. ")" end,
    timeout = nil,
    launch = sync_launch(),
    sleep = function() end,
  })
  lu.assertEquals(#results, #exit_codes)
  for i, code in ipairs(exit_codes) do
    lu.assertNotNil(results[i], "missing result for job " .. i)
    lu.assertEquals(results[i].code, code)
    lu.assertEquals(results[i].ok, code == 0)
    lu.assertEquals(results[i].timed_out, code == 124)
  end
end

function TestParallel:testCapturesJobStdoutStderrIntoResultOutput()
  local results = parallel.run({
    worker_count = 1,
    job_count = 1,
    workspaces = self.workspaces,
    prepare = function() end,
    command = function() return "echo hello-from-job" end,
    launch = sync_launch(),
    sleep = function() end,
  })
  lu.assertNotNil(results[1].output:find("hello-from-job", 1, true))
end

function TestParallel:testAssignsJobsToWorkspacesFromProvidedPool()
  local seen = {}
  local pool = {}
  for _, ws in ipairs(self.workspaces) do pool[ws] = true end
  parallel.run({
    worker_count = 2,
    job_count = 4,
    workspaces = self.workspaces,
    prepare = function(i, ws)
      seen[i] = ws
    end,
    command = function() return "true" end,
    launch = sync_launch(),
    sleep = function() end,
  })
  for i = 1, 4 do
    lu.assertTrue(pool[seen[i]] == true, "job " .. i .. " ran outside the workspace pool")
  end
end

function TestParallel:testFiresOnCompleteExactlyOncePerJob()
  local completed = {}
  parallel.run({
    worker_count = 3,
    job_count = 5,
    workspaces = self.workspaces,
    prepare = function() end,
    command = function() return "true" end,
    on_complete = function(i)
      completed[i] = (completed[i] or 0) + 1
    end,
    launch = sync_launch(),
    sleep = function() end,
  })
  for i = 1, 5 do
    lu.assertEquals(completed[i], 1)
  end
end

function TestParallel:testUsesBusyWaitSoIdleWaitDoesNotForkShell()
  local state = { pending = {}, intervals = {} }
  parallel.run({
    worker_count = 1,
    job_count = 1,
    workspaces = self.workspaces,
    prepare = function() end,
    command = function() return "true" end,
    launch = deferred_launch(state),
    sleep = completing_sleep(state),
  })
  lu.assertEquals(state.intervals, { 0 })
end

function TestParallel:testEmbedsTimeoutCommandAndAtomicSentinelCommitInLauncher()
  local scripts = {}
  parallel.run({
    worker_count = 1,
    job_count = 1,
    workspaces = self.workspaces,
    prepare = function() end,
    command = function() return "run-the-tests" end,
    timeout = 12,
    timeout_command = "timeout",
    launch = sync_launch(scripts),
    sleep = function() end,
  })
  local script = scripts[1]
  lu.assertNotNil(script:find("timeout 12 run-the-tests", 1, true), "missing timeout prefix")
  lu.assertNotNil(script:find("mv -f", 1, true), "sentinel should be committed via atomic rename")
end

return TestParallel
