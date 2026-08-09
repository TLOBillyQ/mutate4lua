local lu = require("luaunit")
local engine = require("mutate4lua.engine")
local resident = require("mutate4lua.internal.resident")
local parallel = require("mutate4lua.internal.parallel")
local util = require("mutate4lua.util")

local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
-- Absolute repo root: workers are spawned with cwd inside a fixture, so a
-- relative runner path would not resolve there.
local repo_root = test_file:match("^(.*)/tests/[^/]+$")
if repo_root == nil then
  local pipe = io.popen("pwd")
  repo_root = util.trim(pipe:read("*l"))
  pipe:close()
end
local runner_path = repo_root .. "/src/runner.lua"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function tmp_dir()
  local base = os.tmpname()
  os.remove(base)
  util.mkdir_p(base)
  return base
end

local function rm_rf(path)
  os.execute("rm -rf " .. shell_quote(path))
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

local function pid_alive(pid)
  return util.command_succeeds("kill -0 " .. tostring(pid) .. " 2>/dev/null")
end

-- A shell double for the resident worker: speaks the req/res sentinel
-- protocol without running any tests. Behaviour knobs via environment:
--   FAILURES=n     failure count written into every res (default 0)
--   CRASH_JOB=n    SIGKILL itself when job-<n>.req arrives (once per
--                  workspace, tracked by a marker next to the sentinel dir)
--   HANG=1         sleep before answering every job (watchdog bait)
--   EXIT_AFTER=n   exit cleanly after answering job n
local FAKE_WORKER_SCRIPT = [[
#!/bin/sh
dir="$1"
n=1
while :; do
  req="$dir/job-$n.req"
  if [ -e "$req" ]; then
    if grep -q "shutdown = true" "$req"; then
      printf 'return { failures = 0 }\n' > "$dir/job-$n.res"
      exit 0
    fi
    if [ -n "$CRASH_JOB" ] && [ "$n" = "$CRASH_JOB" ] && [ ! -e "$dir/../.crashed" ]; then
      touch "$dir/../.crashed"
      kill -9 $$
    fi
    if [ -n "$HANG" ]; then
      sleep 5
    fi
    printf 'fake output %s\n' "$n" > "$dir/job-$n.out"
    printf 'return { failures = %s }\n' "${FAILURES:-0}" > "$dir/job-$n.res"
    n=$((n+1))
    if [ "$n" -gt "${EXIT_AFTER:-999999}" ]; then
      exit 0
    fi
  fi
  sleep 0.01 2>/dev/null || sleep 1
done
]]

TestResident = {}

function TestResident:setUp()
  self.dir = tmp_dir()
  self.workspaces = {}
  self.pids = {}
  self.spawns = 0
  self.fake_worker = util.join_path(self.dir, "fake_worker.sh")
  write_file(self.fake_worker, FAKE_WORKER_SCRIPT)
end

function TestResident:tearDown()
  for _, pid in ipairs(self.pids) do
    os.execute("kill -9 " .. tostring(pid) .. " >/dev/null 2>&1")
  end
  rm_rf(self.dir)
  for _, ws in ipairs(self.workspaces) do
    rm_rf(ws)
  end
end

function TestResident:workspace()
  local ws = tmp_dir()
  self.workspaces[#self.workspaces + 1] = ws
  return ws
end

-- Spawn override that runs the shell double as the "worker". Mimics the real
-- spawn command: the outer shell records the background PID synchronously, so
-- the pid file is there when resident.run reads it.
function TestResident:fake_spawn(env_prefix)
  return function(slot)
    self.spawns = self.spawns + 1
    local cmd = "mkdir -p " .. shell_quote(slot.dir)
      .. " && ( " .. (env_prefix or "") .. "sh " .. shell_quote(self.fake_worker)
      .. " " .. shell_quote(slot.dir) .. " >/dev/null 2>&1 &"
      .. " echo $! > " .. shell_quote(slot.dir .. "/worker.pid") .. " )"
    return util.command_succeeds(cmd)
  end
end

function TestResident:run_pool(spec)
  spec.runner_path = runner_path
  local completed = {}
  spec.on_complete = function(i, result)
    completed[#completed + 1] = {i, result.timed_out == true}
  end
  local results = resident.run(spec)
  return results, completed
end

function TestResident:testHappyPathMultipleWorkers()
  local results, completed = self:run_pool({
    worker_count = 2,
    job_count = 5,
    workspaces = { self:workspace(), self:workspace() },
    spawn = self:fake_spawn(),
    prepare = function() end,
    params = function() return { fail_fast = true } end,
  })
  lu.assertEquals(#results, 5)
  for i = 1, 5 do
    lu.assertTrue(results[i].ok)
    lu.assertEquals(results[i].code, 0)
    lu.assertFalse(results[i].timed_out)
    lu.assertStrMatches(results[i].output, "fake output %d+\n")
  end
  lu.assertEquals(#completed, 5)
  lu.assertEquals(self.spawns, 2)
  -- Workers were shut down gracefully: sentinel dirs removed, processes gone.
  for _, ws in ipairs(self.workspaces) do
    lu.assertEquals(util.capture("find " .. shell_quote(ws) .. " -name '.m4l-serve-*'"), "")
  end
end

function TestResident:testFailuresMapToKilled()
  local results = self:run_pool({
    worker_count = 1,
    job_count = 2,
    workspaces = { self:workspace() },
    spawn = self:fake_spawn("FAILURES=3 "),
    prepare = function() end,
    params = function() return { fail_fast = true } end,
  })
  lu.assertFalse(results[1].ok)
  lu.assertEquals(results[1].code, 1)
  lu.assertFalse(results[1].timed_out)
end

function TestResident:testCrashDuringJobRecordsTimeoutAndRestarts()
  local results = self:run_pool({
    worker_count = 1,
    job_count = 4,
    workspaces = { self:workspace() },
    spawn = self:fake_spawn("CRASH_JOB=2 "),
    prepare = function() end,
    params = function() return { fail_fast = true } end,
  })
  lu.assertTrue(results[1].ok)
  -- ADR-0007: a crash is recorded as a timeout kill, and the pool pays one
  -- cold start for a replacement worker (a second spawn).
  lu.assertFalse(results[2].ok)
  lu.assertTrue(results[2].timed_out)
  lu.assertEquals(results[2].code, 124)
  lu.assertTrue(results[3].ok)
  lu.assertTrue(results[4].ok)
  lu.assertEquals(self.spawns, 2)
end

function TestResident:testWorkerDeathBetweenJobsTriggersRestartNotTimeout()
  local results = self:run_pool({
    worker_count = 1,
    job_count = 3,
    workspaces = { self:workspace() },
    spawn = self:fake_spawn("EXIT_AFTER=1 "),
    prepare = function() end,
    params = function() return { fail_fast = true } end,
  })
  for i = 1, 3 do
    lu.assertTrue(results[i].ok)
  end
  lu.assertEquals(self.spawns, 3)
end

function TestResident:testWatchdogKillsOverrunningJobAndRestarts()
  local clock = { 1000 }
  local results = self:run_pool({
    worker_count = 1,
    job_count = 2,
    workspaces = { self:workspace() },
    timeout = 5,
    spawn = self:fake_spawn("HANG=1 "),
    now = function() return clock[1] end,
    wait = function() clock[1] = clock[1] + 10 end,
    prepare = function() end,
    params = function() return { fail_fast = true } end,
  })
  for i = 1, 2 do
    lu.assertFalse(results[i].ok)
    lu.assertTrue(results[i].timed_out)
    lu.assertEquals(results[i].code, 124)
  end
  -- initial spawn + one restart per timed-out job
  lu.assertEquals(self.spawns, 3)
end

function TestResident:testPrepareErrorPropagatesAndReapsWorkers()
  local ws = self:workspace()
  local ok, err = pcall(function()
    self:run_pool({
      worker_count = 1,
      job_count = 2,
      workspaces = { ws },
      spawn = self:fake_spawn(),
      prepare = function(i)
        if i == 2 then error("boom") end
      end,
      params = function() return { fail_fast = true } end,
    })
  end)
  lu.assertFalse(ok)
  lu.assertStrMatches(tostring(err), ".*boom.*")
  lu.assertEquals(util.capture("find " .. shell_quote(ws) .. " -name '.m4l-serve-*'"), "")
end

-- ---- end-to-end against the real runner serve mode ----

function TestResident:make_fixture()
  local fix = util.join_path(self.dir, "fixture")
  util.mkdir_p(util.join_path(fix, "src"))
  util.mkdir_p(util.join_path(fix, "test"))
  write_file(util.join_path(fix, "src/target.lua"), "return { value = 1 }\n")
  write_file(util.join_path(fix, "test/test_target.lua"), [[
local target = require("target")
return {
  testValue = function()
    assert(target.value == 1, "expected 1, got " .. tostring(target.value))
  end,
}
]])
  return fix
end

function TestResident:spawn_real_worker(dir, workspace)
  util.mkdir_p(dir)
  -- Same interpreter as the test process (arg[-1]); the suite may run under
  -- a non-default lua (e.g. lua5.4) and the worker must load the same rocks.
  local lua_bin = (arg and arg[-1]) or "lua"
  local cmd = "cd " .. shell_quote(workspace)
    .. " && ( " .. shell_quote(lua_bin) .. " " .. shell_quote(runner_path) .. " --serve " .. shell_quote(dir)
    .. " >> " .. shell_quote(dir .. "/worker.log") .. " 2>&1 &"
    .. " echo $! > " .. shell_quote(dir .. "/worker.pid") .. " )"
  lu.assertTrue(util.command_succeeds(cmd))
  local pid = tonumber(util.trim(read_file(dir .. "/worker.pid") or ""))
  lu.assertNotNil(pid)
  self.pids[#self.pids + 1] = pid
  return pid
end

function TestResident:send_req(dir, n, body)
  local tmp = dir .. "/job-" .. n .. ".req.part"
  write_file(tmp, body)
  lu.assertTrue(os.rename(tmp, dir .. "/job-" .. n .. ".req"))
end

function TestResident:await_failures(dir, n)
  local res = dir .. "/job-" .. n .. ".res"
  parallel._blocking_wait({ res }, 10)
  local content = read_file(res)
  lu.assertNotNil(content, "no result committed for job " .. n)
  return tonumber(content:match("failures%s*=%s*(%d+)"))
end

function TestResident:shutdown_worker(dir, n, pid)
  self:send_req(dir, n, "return { shutdown = true }\n")
  lu.assertEquals(self:await_failures(dir, n), 0)
  for _ = 1, 50 do
    if not pid_alive(pid) then return end
    os.execute("sleep 0.05 2>/dev/null || sleep 1")
  end
  lu.assertFalse(pid_alive(pid), "worker did not exit after shutdown request")
end

function TestResident:testServeReloadSeesMutatedTargetAcrossJobs()
  local fix = self:make_fixture()
  local dir = util.join_path(fix, ".serve")
  local pid = self:spawn_real_worker(dir, fix)
  local req = "return { root = " .. string.format("%q", fix)
    .. ", no_coverage = true, fail_fast = true, files = {}, mutated = \"src/target.lua\" }\n"

  self:send_req(dir, 1, req)
  lu.assertEquals(self:await_failures(dir, 1), 0)

  -- Mutate the target: the next job must see it (package.loaded reset), even
  -- though the worker process and its chunk cache survive.
  write_file(util.join_path(fix, "src/target.lua"), "return { value = 2 }\n")
  self:send_req(dir, 2, req)
  lu.assertEquals(self:await_failures(dir, 2), 1)
  local out = read_file(dir .. "/job-2.out")
  lu.assertNotNil(out)
  lu.assertStrMatches(out, ".*expected 1, got 2.*")

  write_file(util.join_path(fix, "src/target.lua"), "return { value = 1 }\n")
  self:send_req(dir, 3, req)
  lu.assertEquals(self:await_failures(dir, 3), 0)

  self:shutdown_worker(dir, 4, pid)
end

function TestResident:testServeDiscoveryIsFrozenPerWorker()
  local fix = self:make_fixture()
  local dir = util.join_path(fix, ".serve")
  local pid = self:spawn_real_worker(dir, fix)
  local req = "return { root = " .. string.format("%q", fix)
    .. ", no_coverage = true, fail_fast = true, files = {} }\n"

  self:send_req(dir, 1, req)
  lu.assertEquals(self:await_failures(dir, 1), 0)

  -- The engine only ever mutates the target source file, so discovery is
  -- cached per worker: a test file added mid-run is deliberately not picked
  -- up (this also guards the per-job find(1) cost).
  write_file(util.join_path(fix, "test/test_extra.lua"),
    "return { testBoom = function() error('must not run') end }\n")
  self:send_req(dir, 2, req)
  lu.assertEquals(self:await_failures(dir, 2), 0)

  self:shutdown_worker(dir, 3, pid)
end

function TestResident:testServeSurvivesUnloadableJobFiles()
  local fix = self:make_fixture()
  local dir = util.join_path(fix, ".serve")
  local pid = self:spawn_real_worker(dir, fix)

  self:send_req(dir, 1, "return { root = " .. string.format("%q", fix)
    .. ", no_coverage = true, fail_fast = true, files = { "
    .. string.format("%q", util.join_path(fix, "test/test_target.lua")) .. " } }\n")
  lu.assertEquals(self:await_failures(dir, 1), 0)

  -- A job whose file cannot load mirrors the one-shot exit-1 (killed)
  -- semantics and must not take the worker down (syntax-killer analogue).
  self:send_req(dir, 2, "return { root = " .. string.format("%q", fix)
    .. ", no_coverage = true, fail_fast = true, files = { "
    .. string.format("%q", util.join_path(fix, "test/does_not_exist.lua")) .. " } }\n")
  lu.assertEquals(self:await_failures(dir, 2), 1)

  self:send_req(dir, 3, "return { root = " .. string.format("%q", fix)
    .. ", no_coverage = true, fail_fast = true, files = {} }\n")
  lu.assertEquals(self:await_failures(dir, 3), 0)

  self:shutdown_worker(dir, 4, pid)
end

function TestResident:testServeCoverageDoesNotAccumulateAcrossJobs()
  local fix = self:make_fixture()
  local dir = util.join_path(fix, ".serve")
  local pid = self:spawn_real_worker(dir, fix)

  -- Warm-up pass: the first job snapshots package.loaded and runs discovery,
  -- so its executed-line set differs from later jobs. The two coverage jobs
  -- below it run byte-identical code paths and must produce byte-identical
  -- reports; accumulated stats would double every hit count.
  self:send_req(dir, 1, "return { root = " .. string.format("%q", fix)
    .. ", no_coverage = true, fail_fast = false, files = {} }\n")
  lu.assertEquals(self:await_failures(dir, 1), 0)

  for n = 2, 3 do
    self:send_req(dir, n, "return { root = " .. string.format("%q", fix)
      .. ", coverage_report = " .. string.format("%q", util.join_path(fix, "cov" .. n .. ".out"))
      .. ", fail_fast = false, files = {} }\n")
    lu.assertEquals(self:await_failures(dir, n), 0)
  end
  self:shutdown_worker(dir, 4, pid)

  local cov2 = read_file(util.join_path(fix, "cov2.out"))
  local cov3 = read_file(util.join_path(fix, "cov3.out"))
  lu.assertNotNil(cov2)
  lu.assertNotNil(cov3)
  lu.assertStrMatches(cov2, ".*target%.lua.*")
  lu.assertEquals(cov2, cov3)
end

function TestResident:testEngineEndToEndThroughResidentPool()
  local fix = util.join_path(self.dir, "e2e")
  util.mkdir_p(util.join_path(fix, "src"))
  util.mkdir_p(util.join_path(fix, "test"))
  write_file(util.join_path(fix, "src/calc.lua"), [[
local calc = {}
function calc.add(a, b)
  return a + b
end
function calc.mul(a, b)
  return a * b
end
return calc
]])
  write_file(util.join_path(fix, "test/test_calc.lua"), [[
local calc = require("calc")
return {
  testAdd = function() assert(calc.add(1, 2) == 3) end,
  testMul = function() assert(calc.mul(2, 3) == 6) end,
}
]])

  local out = {}
  local capture = {write = function(_, ...)
    for _, piece in ipairs({...}) do out[#out + 1] = tostring(piece) end
  end}
  local code = engine.mutate({
    target = "src/calc.lua", mutate_all = true, max_workers = 2,
  }, {cwd = fix, stdout = capture, stderr = capture})
  lu.assertEquals(code, 0)
  local text = table.concat(out)
  lu.assertStrMatches(text, ".*workers: 2 %(parallel%).*")
  lu.assertStrMatches(text, ".*score: 100%.0%%.*")
  -- No worker may outlive the run: sentinel dirs are inside the (removed)
  -- workspaces, and every worker got a shutdown request.
  local leftovers = util.capture("ps -eo pid,args | grep 'mutate4lua/runner.lua --serve' | grep -v grep | wc -l")
  lu.assertEquals(util.trim(leftovers), "0")
end

return TestResident
