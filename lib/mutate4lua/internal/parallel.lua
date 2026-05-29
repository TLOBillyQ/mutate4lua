-- Bounded worker pool for running independent jobs concurrently.
--
-- Each worker owns one workspace and runs its jobs one at a time; up to
-- `worker_count` workers run in parallel. Jobs are launched as detached `sh`
-- processes that write their exit code to a sentinel file (atomically, via a
-- temp + `mv`), and the pool polls those sentinels to refill free workers.
--
-- This keeps one OS process per job (full isolation between jobs); parallelism
-- is across jobs in separate workspaces, never within a single process.
local util = require("mutate4lua.util")

local parallel = {}

-- 0 means busy-wait: keep re-scanning the sentinels with no sleep at all. With
-- lazy-loaded suites each mutant runs in well under a second, so a coarse sleep
-- between polls leaves workers idle far longer than the work itself. Busy-wait
-- forks no shell and gives the tightest refill; a positive --poll-interval is
-- the escape hatch for machines without a spare core (see _sleep).
local DEFAULT_POLL_INTERVAL = 0
local TIMEOUT_EXIT_CODE = 124

local function _build_launcher_script(workspace, command, timeout_seconds, timeout_command, output_path, status_path)
  local status_tmp = status_path .. ".part"
  local q = util.shell_quote
  local timeout_prefix = ""
  if timeout_seconds and timeout_seconds > 0 and timeout_command then
    timeout_prefix = timeout_command .. " " .. tostring(math.ceil(timeout_seconds)) .. " "
  end
  local commit_status = "mv -f " .. q(status_tmp) .. " " .. q(status_path)
  return table.concat({
    "#!/bin/sh",
    "cd " .. q(workspace)
      .. " || { printf '%s\\n' '" .. tostring(TIMEOUT_EXIT_CODE) .. "' > " .. q(status_tmp)
      .. "; " .. commit_status .. "; exit 0; }",
    timeout_prefix .. command .. " > " .. q(output_path) .. " 2>&1",
    "code=$?",
    "printf '%s\\n' \"$code\" > " .. q(status_tmp),
    commit_status,
    "exit 0",
  }, "\n")
end

local function _sleep(seconds)
  -- A non-positive interval means busy-wait: do not fork a shell at all. Only a
  -- positive interval throttles the poll loop by sleeping (one `sh` per idle
  -- scan), trading a little wall-clock for an idle CPU on constrained machines.
  if not (seconds and seconds > 0) then
    return
  end
  os.execute("sleep " .. tostring(seconds) .. " >/dev/null 2>&1")
end

local function _read_exit_code(path)
  local content = util.read_file(path)
  if content == nil then
    return nil
  end
  return tonumber((tostring(content):gsub("%s+", "")))
end

-- spec fields:
--   worker_count    integer >= 1 (clamped)
--   job_count       integer >= 0
--   workspaces      array with at least worker_count workspace paths
--   prepare(i, ws)  parent-side hook: stage job i's inputs into workspace ws
--   command(i, ws)  -> shell command string for job i, run inside workspace ws
--   timeout         seconds before a job is force-killed (optional)
--   timeout_command "timeout" / "gtimeout" / false (optional)
--   on_complete(i, result)  optional callback fired in completion order
--   poll_interval   seconds to sleep when no job finished (default 0 = busy-wait)
--   launch(script)  optional override for launching a detached job (tests)
--   sleep(seconds)  optional override for the poll sleep (tests)
--
-- Returns a dense array results[1..job_count]; each entry is
--   { ok = bool, code = int, output = string, elapsed = int, timed_out = bool }
function parallel.run(spec)
  local worker_count = math.max(1, math.floor(spec.worker_count or 1))
  local job_count = spec.job_count or 0
  local poll_interval = spec.poll_interval or DEFAULT_POLL_INTERVAL
  local results = {}
  if job_count <= 0 then
    return results
  end

  local launch = spec.launch or function(script_path)
    os.execute("sh " .. util.shell_quote(script_path) .. " >/dev/null 2>&1 &")
  end
  local sleep = spec.sleep or _sleep

  local slots = {}
  for s = 1, worker_count do
    slots[s] = { workspace = spec.workspaces[s], job = nil }
  end

  local next_job = 1
  local completed = 0

  local function dispatch()
    for s = 1, worker_count do
      local slot = slots[s]
      if slot.job == nil and next_job <= job_count then
        local job_index = next_job
        next_job = next_job + 1
        spec.prepare(job_index, slot.workspace)
        local command = spec.command(job_index, slot.workspace)
        slot.status_path = util.tmp_path("_m4l_status")
        slot.output_path = util.tmp_path("_m4l_out")
        slot.launcher_path = util.tmp_path("_m4l_sh")
        util.remove(slot.status_path)
        util.write_file(slot.launcher_path, _build_launcher_script(
          slot.workspace, command, spec.timeout, spec.timeout_command,
          slot.output_path, slot.status_path))
        slot.started = os.time()
        slot.job = job_index
        launch(slot.launcher_path)
      end
    end
  end

  dispatch()
  while completed < job_count do
    local progressed = false
    for s = 1, worker_count do
      local slot = slots[s]
      if slot.job ~= nil and util.path_exists(slot.status_path) == true then
        local code = _read_exit_code(slot.status_path) or 1
        local output = util.read_file(slot.output_path) or ""
        results[slot.job] = {
          ok = code == 0,
          code = code,
          output = output,
          elapsed = os.difftime(os.time(), slot.started or os.time()),
          timed_out = code == TIMEOUT_EXIT_CODE,
        }
        if spec.on_complete then
          spec.on_complete(slot.job, results[slot.job])
        end
        util.remove(slot.status_path)
        util.remove(slot.output_path)
        util.remove(slot.launcher_path)
        slot.job = nil
        completed = completed + 1
        progressed = true
      end
    end
    if completed >= job_count then
      break
    end
    dispatch()
    if not progressed then
      sleep(poll_interval)
    end
  end

  return results
end

return parallel
