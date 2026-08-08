-- Resident worker pool (ADR-0007): one long-lived runner process per slot,
-- driven by a file-sentinel protocol instead of one cold process per job.
--
-- The pool writes job-<n>.req (temp + rename, atomically) into the slot's
-- sentinel directory; the worker executes one test pass and commits
-- job-<n>.res the same way. Reload semantics live in the runner (chunk cache
-- + replay + package.loaded reset); this module only orchestrates: dispatch,
-- the per-job watchdog, and crash/timeout recovery. A timeout or a crash
-- kills the worker, pays one cold start for a replacement, and records the
-- mutant as a timeout kill, keeping exit-code semantics identical to the
-- fresh-process pool.
--
-- The sentinel directory lives inside the slot's workspace, under tmp/
-- (tmp/.m4l-serve-g<generation>): inside the workspace so engine cleanup of
-- the workspace also reaps a worker whose engine died (the worker's wait loop
-- exits when its directory disappears), and under tmp/ specifically because
-- the workspace is a full copy of the host repo — a sentinel at the root
-- shows up as an untracked root entry and trips host repo-hygiene guards
-- (monopoly's root whitelist guard failed every survivor pass this way).
-- tmp/ is the host's conventional gitignored scratch dir. A restart bumps
-- the generation, giving the replacement worker a fresh directory and
-- resetting the job sequence — stale req/res files from a crashed generation
-- are never re-read.
local util = require("mutate4lua.util")
local parallel = require("mutate4lua.internal.parallel")

local resident = {}

-- Same convention as parallel.lua: 124 means "ended by the watchdog path".
-- Per ADR-0007 a crash is recorded the same way as a timeout.
local TIMEOUT_EXIT_CODE = 124

local function _serialize_request(request)
  local parts = { "return {" }
  parts[#parts + 1] = "root = " .. string.format("%q", request.root) .. ","
  if request.coverage_report then
    parts[#parts + 1] = "coverage_report = " .. string.format("%q", request.coverage_report) .. ","
  else
    parts[#parts + 1] = "no_coverage = true,"
  end
  parts[#parts + 1] = "fail_fast = " .. tostring(request.fail_fast == true) .. ","
  if request.mutated then
    -- Workspace-relative path of the file the engine just mutated; the worker
    -- re-requires exactly this file fresh on the next pass.
    parts[#parts + 1] = "mutated = " .. string.format("%q", request.mutated) .. ","
  end
  if request.files and #request.files > 0 then
    local quoted = {}
    for _, file in ipairs(request.files) do
      quoted[#quoted + 1] = string.format("%q", file)
    end
    parts[#parts + 1] = "files = { " .. table.concat(quoted, ", ") .. " },"
  end
  if request.shutdown then
    parts[#parts + 1] = "shutdown = true,"
  end
  parts[#parts + 1] = "}"
  return table.concat(parts, "\n") .. "\n"
end

-- The spawn command backgrounds the worker and records its PID; the outer
-- shell returns immediately, so os.execute never blocks on the worker. The
-- worker's own output goes to worker.log (job-level output is redirected by
-- the worker into per-job .out files).
local function _spawn_command(slot, runner_path)
  local q = util.shell_quote
  return "mkdir -p " .. q(slot.dir)
    .. " && cd " .. q(slot.workspace)
    .. " && ( lua " .. q(runner_path) .. " --serve " .. q(slot.dir)
    .. " >> " .. q(slot.dir .. "/worker.log") .. " 2>&1 &"
    .. " echo $! > " .. q(slot.dir .. "/worker.pid") .. " )"
end

local function _default_alive(pid)
  if pid == nil then
    return false
  end
  return util.command_succeeds("kill -0 " .. tostring(pid) .. " 2>/dev/null")
end

local function _default_kill(pid)
  if pid == nil then
    return
  end
  os.execute("kill -9 " .. tostring(pid) .. " >/dev/null 2>&1")
end

-- spec fields (mirrors parallel.run where applicable):
--   worker_count    integer >= 1 (clamped)
--   job_count       integer >= 0
--   workspaces      array with at least worker_count workspace paths
--   runner_path     runner.lua the workers are spawned with (required)
--   timeout         per-job watchdog deadline in seconds (optional)
--   prepare(i, ws)  stage job i's inputs into workspace ws
--   params(i)       -> { fail_fast = bool, files = array|nil,
--                        coverage_report = path|nil }
--   on_complete(i, result)  optional callback fired in completion order
--   spawn(slot)     optional worker-spawn override (tests)
--   alive(pid) / kill(pid) / wait(paths, max_wait) / now()  optional
--                     overrides (tests)
--
-- Returns a dense array results[1..job_count]; each entry is
--   { ok = bool, code = int, output = string, elapsed = int, timed_out = bool }
function resident.run(spec)
  local worker_count = math.max(1, math.floor(spec.worker_count or 1))
  local job_count = spec.job_count or 0
  local results = {}
  if job_count <= 0 then
    return results
  end

  local spawn = spec.spawn or function(slot)
    return util.command_succeeds(_spawn_command(slot, spec.runner_path))
  end
  local alive = spec.alive or _default_alive
  local kill = spec.kill or _default_kill
  local wait = spec.wait or parallel._blocking_wait
  local now = spec.now or os.time

  local slots = {}
  for s = 1, worker_count do
    slots[s] = { workspace = spec.workspaces[s], gen = 0, seq = 0, pid = nil, job = nil }
  end

  local function start_worker(slot)
    slot.gen = slot.gen + 1
    slot.seq = 0
    if slot.dir then
      util.remove(slot.dir)
    end
    slot.dir = util.join_path(slot.workspace, "tmp", ".m4l-serve-g" .. tostring(slot.gen))
    spawn(slot)
    slot.pid = tonumber(util.trim(util.read_file(slot.dir .. "/worker.pid") or ""))
  end

  local function restart_worker(slot)
    if alive(slot.pid) then
      kill(slot.pid)
    end
    start_worker(slot)
  end

  local function send_request(slot, request)
    slot.seq = slot.seq + 1
    request.root = slot.workspace
    local base = slot.dir .. "/job-" .. tostring(slot.seq)
    slot.res_path = base .. ".res"
    slot.out_path = base .. ".out"
    util.remove(slot.res_path)
    local req_tmp = base .. ".req.part"
    if util.write_file(req_tmp, _serialize_request(request)) then
      os.rename(req_tmp, base .. ".req")
    end
  end

  local function read_result(slot)
    local content = util.read_file(slot.res_path)
    if content == nil then
      return nil
    end
    local output = util.read_file(slot.out_path) or ""
    local failures = tonumber(content:match("failures%s*=%s*(%d+)"))
    if failures == nil then
      -- The commit is atomic, so an unparseable res means a broken worker;
      -- report a plain failure instead of polling forever.
      return { ok = false, code = 1, output = output, timed_out = false }
    end
    return {
      ok = failures == 0,
      code = failures == 0 and 0 or 1,
      output = output,
      timed_out = false,
    }
  end

  local function timeout_result()
    return { ok = false, code = TIMEOUT_EXIT_CODE, output = "", timed_out = true }
  end

  local function fire_on_complete(job_index)
    if spec.on_complete == nil then
      return
    end
    local ok, err = pcall(spec.on_complete, job_index, results[job_index])
    if not ok then
      error(err, 0)
    end
  end

  local function shutdown_all()
    for s = 1, worker_count do
      local slot = slots[s]
      if slot.pid ~= nil and alive(slot.pid) then
        -- Graceful first: a shutdown request makes the worker commit its res
        -- and exit; SIGKILL is only the fallback for a stuck worker.
        send_request(slot, { shutdown = true })
        for _ = 1, 4 do
          if not alive(slot.pid) then
            break
          end
          wait({ slot.res_path }, 1)
        end
        if alive(slot.pid) then
          kill(slot.pid)
        end
      end
      if slot.dir then
        util.remove(slot.dir)
        slot.dir = nil
      end
    end
  end

  local next_job = 1
  local completed = 0

  local function dispatch()
    for s = 1, worker_count do
      local slot = slots[s]
      if slot.job == nil and next_job <= job_count then
        local job_index = next_job
        next_job = next_job + 1
        -- A raising prepare/params must not strand the pool: it propagates to
        -- the pcall below, and shutdown_all reaps the workers.
        spec.prepare(job_index, slot.workspace)
        local params = spec.params(job_index)
        if not alive(slot.pid) then
          -- First dispatch on this slot, or the worker died between jobs.
          start_worker(slot)
        end
        send_request(slot, params)
        slot.started = now()
        slot.job = job_index
      end
    end
  end

  local function main_loop()
    dispatch()
    while completed < job_count do
      local progressed = false
      for s = 1, worker_count do
        local slot = slots[s]
        if slot.job ~= nil then
          local result = read_result(slot)
          if result == nil then
            if not alive(slot.pid) then
              -- Crash: the worker died before committing a result. ADR-0007
              -- records the mutant as a timeout kill and pays one cold start.
              restart_worker(slot)
              result = timeout_result()
            elseif spec.timeout and os.difftime(now(), slot.started) > spec.timeout then
              restart_worker(slot)
              result = timeout_result()
            end
          end
          if result ~= nil then
            result.elapsed = os.difftime(now(), slot.started)
            results[slot.job] = result
            fire_on_complete(slot.job)
            slot.job = nil
            completed = completed + 1
            progressed = true
          end
        end
      end
      if completed >= job_count then
        break
      end
      dispatch()
      if not progressed then
        local active = {}
        for s = 1, worker_count do
          if slots[s].job ~= nil then
            active[#active + 1] = slots[s].res_path
          end
        end
        -- A 1s wake-up cap keeps crash/timeout detection responsive even
        -- though the blocking waiter exits early on any completed job.
        wait(active, 1)
      end
    end
  end

  local ok, err = pcall(main_loop)
  shutdown_all()
  if not ok then
    error(err, 0)
  end
  return results
end

return resident
