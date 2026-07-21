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
-- 124 means "ended by the timeout path" (the `timeout` command or the
-- watchdog below). The launcher's `cd` guard also reports 124 when the
-- workspace is missing — a known misclassification, kept because telling it
-- apart from a real timeout needs a new result field, which would change the
-- engine/spec contract.
local TIMEOUT_EXIT_CODE = 124
-- The launcher script itself could not be staged, so the job never ran.
-- Distinct from 124, which stays reserved for the timeout path.
local LAUNCHER_WRITE_EXIT_CODE = 126

local function _build_launcher_script(workspace, command, timeout_seconds, timeout_command, output_path, status_path, pid_path)
  local status_tmp = status_path .. ".part"
  local q = util.shell_quote
  local timeout_prefix = ""
  if timeout_seconds and timeout_seconds > 0 and timeout_command then
    timeout_prefix = timeout_command .. " " .. tostring(math.ceil(timeout_seconds)) .. " "
  end
  local commit_status = "mv -f " .. q(status_tmp) .. " " .. q(status_path)
  -- A failed `cd` is reported as 124 even though nothing ran (see the note at
  -- TIMEOUT_EXIT_CODE); that misclassification is deliberately left as-is.
  local cd_guard = "cd " .. q(workspace)
    .. " || { printf '%s\\n' '" .. tostring(TIMEOUT_EXIT_CODE) .. "' > " .. q(status_tmp)
    .. "; " .. commit_status .. "; exit 0; }"
  if timeout_prefix ~= "" or not (timeout_seconds and timeout_seconds > 0) then
    return table.concat({
      "#!/bin/sh",
      cd_guard,
      timeout_prefix .. command .. " > " .. q(output_path) .. " 2>&1",
      "code=$?",
      "printf '%s\\n' \"$code\" > " .. q(status_tmp),
      commit_status,
      "exit 0",
    }, "\n")
  end
  -- A timeout was requested but no `timeout` command exists: run the job in
  -- the background and record its PID so the pool-side watchdog can kill it
  -- on overrun. The watchdog commits the 124 sentinel itself, so after `wait`
  -- this script must not overwrite a sentinel that is already there.
  return table.concat({
    "#!/bin/sh",
    cd_guard,
    "( " .. command .. " ) > " .. q(output_path) .. " 2>&1 &",
    "pid=$!",
    "printf '%s\\n' \"$pid\" > " .. q(pid_path),
    "wait $pid",
    "code=$?",
    "if [ ! -e " .. q(status_path) .. " ]; then",
    "  printf '%s\\n' \"$code\" > " .. q(status_tmp),
    "  " .. commit_status,
    "fi",
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

-- Parses a sentinel body already read by the poll loop. The launcher commits
-- the sentinel atomically (temp + mv), so a readable file always holds the
-- full exit code; unparseable content means a broken launcher, reported as a
-- plain failure (code 1) instead of being polled forever.
local function _parse_exit_code(content)
  return tonumber((tostring(content):gsub("%s+", ""))) or 1
end

-- Fallback timeout for hosts without a `timeout` command: the launcher
-- records the child PID (see _build_launcher_script); once the job overruns
-- its budget we kill that PID and commit the 124 sentinel ourselves. `>`
-- (not `>=`) keeps the 1-second os.time granularity from killing early.
local function _reap_if_timed_out(slot, timeout_seconds)
  if slot.pid_path == nil or not (timeout_seconds and timeout_seconds > 0) then
    return
  end
  if os.difftime(os.time(), slot.started) <= timeout_seconds then
    return
  end
  local pid = tonumber(util.trim(util.read_file(slot.pid_path) or ""))
  if pid == nil then
    -- The launcher has not committed the PID file yet; retry on the next poll.
    return
  end
  os.execute("kill " .. tostring(pid) .. " >/dev/null 2>&1")
  util.write_file(slot.status_path, tostring(TIMEOUT_EXIT_CODE) .. "\n")
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

  -- Best-effort removal of a slot's temp files; used after a normal
  -- completion and before re-raising a callback error.
  local function cleanup_slot(slot)
    for _, key in ipairs({ "status_path", "output_path", "launcher_path", "pid_path" }) do
      if slot[key] ~= nil then
        util.remove(slot[key])
        slot[key] = nil
      end
    end
    slot.job = nil
  end

  local function fire_on_complete(slot, job_index)
    if spec.on_complete == nil then
      return
    end
    local ok, err = pcall(spec.on_complete, job_index, results[job_index])
    if not ok then
      cleanup_slot(slot)
      error(err, 0)
    end
  end

  local function dispatch()
    for s = 1, worker_count do
      local slot = slots[s]
      if slot.job == nil and next_job <= job_count then
        local job_index = next_job
        next_job = next_job + 1
        -- A raising prepare/command callback must not leak the slot's temp
        -- files; clean up before the error propagates.
        local ok, command_or_err = pcall(spec.prepare, job_index, slot.workspace)
        if ok then
          ok, command_or_err = pcall(spec.command, job_index, slot.workspace)
        end
        if not ok then
          cleanup_slot(slot)
          error(command_or_err, 0)
        end
        slot.status_path = util.tmp_path("_m4l_status")
        slot.output_path = util.tmp_path("_m4l_out")
        slot.launcher_path = util.tmp_path("_m4l_sh")
        if spec.timeout and spec.timeout > 0 and not spec.timeout_command then
          slot.pid_path = util.tmp_path("_m4l_pid")
          util.remove(slot.pid_path)
        end
        util.remove(slot.status_path)
        if not util.write_file(slot.launcher_path, _build_launcher_script(
            slot.workspace, command_or_err, spec.timeout, spec.timeout_command,
            slot.output_path, slot.status_path, slot.pid_path)) then
          -- Could not even stage the launcher: finish the job immediately
          -- with the dedicated launcher-error code (never 124).
          results[job_index] = {
            ok = false,
            code = LAUNCHER_WRITE_EXIT_CODE,
            output = "",
            elapsed = 0,
            timed_out = false,
          }
          fire_on_complete(slot, job_index)
          cleanup_slot(slot)
          completed = completed + 1
        else
          slot.started = os.time()
          slot.job = job_index
          launch(slot.launcher_path)
        end
      end
    end
  end

  dispatch()
  while completed < job_count do
    local progressed = false
    for s = 1, worker_count do
      local slot = slots[s]
      if slot.job ~= nil then
        -- Pure-Lua poll: a missing sentinel means "still running", so the
        -- busy-wait scans without forking a shell per poll (see header).
        local content = util.read_file(slot.status_path)
        if content == nil then
          _reap_if_timed_out(slot, spec.timeout)
          content = util.read_file(slot.status_path)
        end
        if content ~= nil then
          local code = _parse_exit_code(content)
          local output = util.read_file(slot.output_path) or ""
          results[slot.job] = {
            ok = code == 0,
            code = code,
            output = output,
            elapsed = os.difftime(os.time(), slot.started),
            timed_out = code == TIMEOUT_EXIT_CODE,
          }
          fire_on_complete(slot, slot.job)
          cleanup_slot(slot)
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
      sleep(poll_interval)
    end
  end

  return results
end

return parallel
