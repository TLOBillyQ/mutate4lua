local scanner = require("mutate4lua.internal.scanner")

local function analyze(source)
  return scanner.analyze("m.lua", "m.lua", source)
end

local function find_scope(result, id)
  for _, scope in ipairs(result.scopes) do
    if scope.id == id then return scope end
  end
  return nil
end

describe("scanner.analyze scope detection", function()
  it("emits a chunk scope for every file", function()
    local result = analyze("return {}\n")
    assert.is_not_nil(find_scope(result, "chunk:m.lua"))
  end)

  it("detects `local function name` syntax", function()
    local result = analyze("local function bar()\n  return 1\nend\nreturn bar\n")
    assert.is_not_nil(find_scope(result, "function:bar:1"))
  end)

  it("detects `function M.foo` syntax", function()
    local result = analyze("local M = {}\nfunction M.foo(x)\n  return x\nend\nreturn M\n")
    assert.is_not_nil(find_scope(result, "function:M.foo:2"))
  end)

  it("detects `function M:foo` colon-method syntax", function()
    local result = analyze("local M = {}\nfunction M:baz(x)\n  return x\nend\nreturn M\n")
    assert.is_not_nil(find_scope(result, "function:M:baz:2"))
  end)

  it("emits `function:anonymous@<line>:<line>` for unnamed function expressions", function()
    local result = analyze("local f = function(x)\n  return x\nend\nreturn f\n")
    assert.is_not_nil(find_scope(result, "function:anonymous@1:1"))
  end)

  it("records each function's start and end lines", function()
    local result = analyze("local function a()\n  return 1\nend\n\nlocal function b()\n  return 2\nend\n")
    local scope_a = find_scope(result, "function:a:1")
    local scope_b = find_scope(result, "function:b:5")
    assert.are.equal(1, scope_a.start_line)
    assert.are.equal(3, scope_a.end_line)
    assert.are.equal(5, scope_b.start_line)
    assert.are.equal(7, scope_b.end_line)
  end)
end)

describe("scanner.analyze hash stability", function()
  it("produces identical hashes when only whitespace differs", function()
    local source_a = "local function f()\n  return 1\nend\nreturn f\n"
    local source_b = "local function f()\n\n  return 1\nend\nreturn f\n"
    local fa = find_scope(analyze(source_a), "function:f:1")
    local fb = find_scope(analyze(source_b), "function:f:1")
    assert.are.equal(fa.semantic_hash, fb.semantic_hash)
  end)

  it("produces identical hashes when only comments differ", function()
    local source_a = "local function f()\n  return 1\nend\nreturn f\n"
    local source_b = "local function f()\n  -- explanation\n  return 1 -- inline\nend\nreturn f\n"
    local fa = find_scope(analyze(source_a), "function:f:1")
    local fb = find_scope(analyze(source_b), "function:f:1")
    assert.are.equal(fa.semantic_hash, fb.semantic_hash)
  end)

  it("changes the chunk hash on a single-token semantic edit", function()
    local before = analyze("if a == b then return 1 end\n")
    local after = analyze("if a ~= b then return 1 end\n")
    assert.are_not.equal(before.scopes[1].semantic_hash, after.scopes[1].semantic_hash)
  end)

  it("isolates function-scope hash changes to the edited function", function()
    local source_a = "local function a()\n  return 1\nend\nlocal function b()\n  return 2 == 3\nend\n"
    local source_b = "local function a()\n  return 1\nend\nlocal function b()\n  return 2 ~= 3\nend\n"
    local result_a = analyze(source_a)
    local result_b = analyze(source_b)
    local a1 = find_scope(result_a, "function:a:1")
    local a2 = find_scope(result_b, "function:a:1")
    local b1 = find_scope(result_a, "function:b:4")
    local b2 = find_scope(result_b, "function:b:4")
    assert.are.equal(a1.semantic_hash, a2.semantic_hash)
    assert.are_not.equal(b1.semantic_hash, b2.semantic_hash)
  end)

  it("also bumps the chunk-scope hash when any contained scope changes", function()
    -- The chunk scope spans the entire file and therefore covers tokens
    -- inside every function. Any semantic edit anywhere flips the chunk hash,
    -- which conservatively forces re-mutation of top-level sites.
    local before = analyze("local function f()\n  return 1\nend\nreturn f\n")
    local after = analyze("local function f()\n  return 1 + 1\nend\nreturn f\n")
    assert.are_not.equal(before.scopes[1].semantic_hash, after.scopes[1].semantic_hash)
  end)
end)

describe("scanner.analyze scope set drift", function()
  it("adds a new scope when a function is added", function()
    local before = analyze("local function a() return 1 end\n")
    local after = analyze("local function a() return 1 end\nlocal function b() return 2 end\n")
    assert.is_nil(find_scope(before, "function:b:2"))
    assert.is_not_nil(find_scope(after, "function:b:2"))
  end)

  it("drops the scope when its function is deleted", function()
    local before = analyze("local function a() return 1 end\nlocal function b() return 2 end\n")
    local after = analyze("local function a() return 1 end\n")
    assert.is_not_nil(find_scope(before, "function:b:2"))
    assert.is_nil(find_scope(after, "function:b:2"))
  end)
end)

describe("scanner.analyze mutation sites", function()
  it("assigns sites inside a function to that function's scope id", function()
    local result = analyze("local function f()\n  return 1 == 2\nend\nreturn f\n")
    local fn_scope = find_scope(result, "function:f:1")
    local found = false
    for _, site in ipairs(result.sites) do
      if site.description == "replace == with ~=" then
        assert.are.equal(fn_scope.id, site.scope_id)
        found = true
      end
    end
    assert.is_true(found, "expected an == site")
  end)

  it("assigns top-level sites to the chunk scope id", function()
    local result = analyze("local x = 1\nreturn x\n")
    local chunk_scope = find_scope(result, "chunk:m.lua")
    local found = false
    for _, site in ipairs(result.sites) do
      if site.description == "replace 1 with 0" then
        assert.are.equal(chunk_scope.id, site.scope_id)
        found = true
      end
    end
    assert.is_true(found, "expected a numeric-literal site")
  end)
end)
