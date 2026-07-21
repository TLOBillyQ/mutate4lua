-- Minimal test harness replacing busted + luassert.
-- Provides the globals `describe`, `it`, `before_each`, `after_each` and a
-- luassert-compatible `assert` table. Use `lua spec/run.lua` to execute.

local builtin_assert = assert

local M = { suites = {}, stack = {} }

-- ---------------------------------------------------------------------------
-- value formatting / comparison
-- ---------------------------------------------------------------------------

local function fmt(v, seen)
  if type(v) == "string" then
    local s = v
    if #s > 80 then s = s:sub(1, 77) .. "..." end
    return string.format("%q", s)
  elseif type(v) == "table" then
    seen = seen or {}
    if seen[v] then return "<cycle>" end
    seen[v] = true
    local parts = {}
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = "[" .. tostring(k) .. "]=" .. fmt(v[k], seen)
    end
    seen[v] = nil
    local s = "{" .. table.concat(parts, ", ") .. "}"
    if #s > 120 then s = s:sub(1, 117) .. "..." end
    return s
  end
  return tostring(v)
end

local function deep_equal(a, b, seen)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  seen = seen or {}
  if seen[a] == b then return true end
  seen[a] = b
  for k, v in pairs(a) do
    if not deep_equal(v, b[k], seen) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function fail(msg)
  error(msg, 3)
end

-- ---------------------------------------------------------------------------
-- assert: callable like the builtin, plus luassert-style helpers
-- ---------------------------------------------------------------------------

local a = setmetatable({}, {
  __call = function(_, ...) return builtin_assert(...) end,
})

local function expect(cond, default_msg, msg)
  if not cond then fail(msg or default_msg) end
end

a.are = {
  equal = function(expected, actual, msg)
    expect(expected == actual,
      "expected " .. fmt(actual) .. " to equal " .. fmt(expected), msg)
  end,
  same = function(expected, actual, msg)
    expect(deep_equal(expected, actual),
      "expected " .. fmt(actual) .. " to deep-equal " .. fmt(expected), msg)
  end,
}

a.are_not = {
  equal = function(expected, actual, msg)
    expect(expected ~= actual,
      "expected " .. fmt(actual) .. " to not equal " .. fmt(expected), msg)
  end,
  same = function(expected, actual, msg)
    expect(not deep_equal(expected, actual),
      "expected " .. fmt(actual) .. " to not deep-equal " .. fmt(expected), msg)
  end,
}

function a.is_nil(v, msg)
  expect(v == nil, "expected nil, got " .. fmt(v), msg)
end

function a.is_not_nil(v, msg)
  expect(v ~= nil, "expected non-nil value, got nil", msg)
end

function a.is_true(v, msg)
  expect(v == true, "expected true, got " .. fmt(v), msg)
end

function a.is_false(v, msg)
  expect(v == false, "expected false, got " .. fmt(v), msg)
end

function a.is_truthy(v, msg)
  expect(v ~= nil and v ~= false, "expected truthy value, got " .. fmt(v), msg)
end

function a.is_falsy(v, msg)
  expect(v == nil or v == false, "expected falsy value, got " .. fmt(v), msg)
end

function a.matches(pattern, s, msg)
  expect(type(s) == "string" and s:match(pattern) ~= nil,
    "expected " .. fmt(s) .. " to match pattern " .. fmt(pattern), msg)
end

_G.assert = a

-- ---------------------------------------------------------------------------
-- suite registration
-- ---------------------------------------------------------------------------

local function current_suite()
  local suite = M.stack[#M.stack]
  builtin_assert(suite, "describe/it must be called inside describe")
  return suite
end

function _G.describe(name, fn)
  local suite = { name = name, suites = {}, cases = {}, befores = {}, afters = {} }
  local parent = M.stack[#M.stack]
  if parent then
    parent.suites[#parent.suites + 1] = suite
  else
    M.suites[#M.suites + 1] = suite
  end
  M.stack[#M.stack + 1] = suite
  fn()
  M.stack[#M.stack] = nil
end

function _G.it(name, fn)
  local cases = current_suite().cases
  cases[#cases + 1] = { name = name, fn = fn }
end

function _G.before_each(fn)
  local befores = current_suite().befores
  befores[#befores + 1] = fn
end

function _G.after_each(fn)
  local afters = current_suite().afters
  afters[#afters + 1] = fn
end

-- ---------------------------------------------------------------------------
-- runner
-- ---------------------------------------------------------------------------

-- Runs every registered suite. Returns true when all tests pass.
function M.run()
  local passed, failed = 0, 0

  local function run_case(case, hooks, label)
    local err
    for _, fn in ipairs(hooks.befores) do
      local ok, e = xpcall(fn, debug.traceback)
      if not ok then err = e break end
    end
    if err == nil then
      local ok, e = xpcall(case.fn, debug.traceback)
      if not ok then err = e end
    end
    for _, fn in ipairs(hooks.afters) do
      local ok, e = xpcall(fn, debug.traceback)
      if not ok and err == nil then err = e end
    end
    if err == nil then
      passed = passed + 1
      io.write("PASS ", label, "\n")
    else
      failed = failed + 1
      io.write("FAIL ", label, "\n", tostring(err), "\n")
    end
  end

  local function run_suite(suite, hooks, prefix)
    local label_prefix = prefix .. suite.name
    local h = {
      befores = {},
      afters = {},
    }
    for _, fn in ipairs(hooks.befores) do h.befores[#h.befores + 1] = fn end
    for _, fn in ipairs(suite.befores) do h.befores[#h.befores + 1] = fn end
    -- outermost after_each runs last
    for _, fn in ipairs(suite.afters) do h.afters[#h.afters + 1] = fn end
    for _, fn in ipairs(hooks.afters) do h.afters[#h.afters + 1] = fn end
    for _, case in ipairs(suite.cases) do
      run_case(case, h, label_prefix .. " > " .. case.name)
    end
    for _, child in ipairs(suite.suites) do
      run_suite(child, h, label_prefix .. " > ")
    end
  end

  local empty = { befores = {}, afters = {} }
  for _, suite in ipairs(M.suites) do
    run_suite(suite, empty, "")
  end

  io.write(string.format("\n%d passed, %d failed\n", passed, failed))
  return failed == 0
end

return M
