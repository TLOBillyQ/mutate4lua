local lu = require("luaunit")
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

TestScanner = {}

-- scope detection

function TestScanner:testEmitsChunkScopeForEveryFile()
  local result = analyze("return {}\n")
  lu.assertNotNil(find_scope(result, "chunk:m.lua"))
end

function TestScanner:testDetectsLocalFunctionNameSyntax()
  local result = analyze("local function bar()\n  return 1\nend\nreturn bar\n")
  lu.assertNotNil(find_scope(result, "function:bar"))
end

function TestScanner:testDetectsFunctionMDotFooSyntax()
  local result = analyze("local M = {}\nfunction M.foo(x)\n  return x\nend\nreturn M\n")
  lu.assertNotNil(find_scope(result, "function:M.foo"))
end

function TestScanner:testDetectsColonMethodSyntax()
  local result = analyze("local M = {}\nfunction M:baz(x)\n  return x\nend\nreturn M\n")
  lu.assertNotNil(find_scope(result, "function:M:baz"))
end

function TestScanner:testEmitsAnonymousScopeForUnnamedFunctionExpressions()
  local result = analyze("local f = function(x)\n  return x\nend\nreturn f\n")
  lu.assertNotNil(find_scope(result, "function:<anonymous>"))
end

function TestScanner:testDisambiguatesDuplicateFunctionNamesWithOccurrenceIndex()
  local result = analyze("local function foo() return 1 end\nlocal function foo() return 2 end\n")
  lu.assertNotNil(find_scope(result, "function:foo"))
  lu.assertNotNil(find_scope(result, "function:foo#2"))
end

function TestScanner:testDisambiguatesDuplicateAnonymousFunctionsWithOccurrenceIndex()
  local result = analyze("local a = function() return 1 end\nlocal b = function() return 2 end\n")
  lu.assertNotNil(find_scope(result, "function:<anonymous>"))
  lu.assertNotNil(find_scope(result, "function:<anonymous>#2"))
end

function TestScanner:testRecordsEachFunctionsStartAndEndLines()
  local result = analyze("local function a()\n  return 1\nend\n\nlocal function b()\n  return 2\nend\n")
  local scope_a = find_scope(result, "function:a")
  local scope_b = find_scope(result, "function:b")
  lu.assertEquals(scope_a.start_line, 1)
  lu.assertEquals(scope_a.end_line, 3)
  lu.assertEquals(scope_b.start_line, 5)
  lu.assertEquals(scope_b.end_line, 7)
end

-- scope identity stability

function TestScanner:testKeepsSameIdWhenFunctionMovesToDifferentLine()
  local source_a = "local function f()\n  return 1\nend\nreturn f\n"
  local source_b = "\nlocal function f()\n  return 1\nend\nreturn f\n"
  local a = find_scope(analyze(source_a), "function:f")
  local b = find_scope(analyze(source_b), "function:f")
  lu.assertNotNil(a)
  lu.assertNotNil(b)
  lu.assertEquals(a.id, b.id)
end

function TestScanner:testChangesIdWhenFunctionIsRenamed()
  local a = find_scope(analyze("local function f() return 1 end\n"), "function:f")
  local b = find_scope(analyze("local function g() return 1 end\n"), "function:g")
  lu.assertNotNil(a)
  lu.assertNotNil(b)
  lu.assertNotEquals(a.id, b.id)
end

-- hash stability

function TestScanner:testIdenticalHashesWhenOnlyWhitespaceDiffers()
  local source_a = "local function f()\n  return 1\nend\nreturn f\n"
  local source_b = "local function f()\n\n  return 1\nend\nreturn f\n"
  local fa = find_scope(analyze(source_a), "function:f")
  local fb = find_scope(analyze(source_b), "function:f")
  lu.assertEquals(fa.semantic_hash, fb.semantic_hash)
end

function TestScanner:testIdenticalHashesWhenOnlyCommentsDiffer()
  local source_a = "local function f()\n  return 1\nend\nreturn f\n"
  local source_b = "local function f()\n  -- explanation\n  return 1 -- inline\nend\nreturn f\n"
  local fa = find_scope(analyze(source_a), "function:f")
  local fb = find_scope(analyze(source_b), "function:f")
  lu.assertEquals(fa.semantic_hash, fb.semantic_hash)
end

function TestScanner:testChangesChunkHashOnSingleTokenSemanticEdit()
  local before = analyze("if a == b then return 1 end\n")
  local after = analyze("if a ~= b then return 1 end\n")
  lu.assertNotEquals(before.scopes[1].semantic_hash, after.scopes[1].semantic_hash)
end

function TestScanner:testIsolatesFunctionScopeHashChangesToEditedFunction()
  local source_a = "local function a()\n  return 1\nend\nlocal function b()\n  return 2 == 3\nend\n"
  local source_b = "local function a()\n  return 1\nend\nlocal function b()\n  return 2 ~= 3\nend\n"
  local result_a = analyze(source_a)
  local result_b = analyze(source_b)
  local a1 = find_scope(result_a, "function:a")
  local a2 = find_scope(result_b, "function:a")
  local b1 = find_scope(result_a, "function:b")
  local b2 = find_scope(result_b, "function:b")
  lu.assertEquals(a1.semantic_hash, a2.semantic_hash)
  lu.assertNotEquals(b1.semantic_hash, b2.semantic_hash)
end

function TestScanner:testAlsoBumpsChunkScopeHashWhenContainedScopeChanges()
  local before = analyze("local function f()\n  return 1\nend\nreturn f\n")
  local after = analyze("local function f()\n  return 1 + 1\nend\nreturn f\n")
  lu.assertNotEquals(before.scopes[1].semantic_hash, after.scopes[1].semantic_hash)
end

-- scope set drift

function TestScanner:testAddsNewScopeWhenFunctionIsAdded()
  local before = analyze("local function a() return 1 end\n")
  local after = analyze("local function a() return 1 end\nlocal function b() return 2 end\n")
  lu.assertNil(find_scope(before, "function:b"))
  lu.assertNotNil(find_scope(after, "function:b"))
end

function TestScanner:testDropsScopeWhenFunctionIsDeleted()
  local before = analyze("local function a() return 1 end\nlocal function b() return 2 end\n")
  local after = analyze("local function a() return 1 end\n")
  lu.assertNotNil(find_scope(before, "function:b"))
  lu.assertNil(find_scope(after, "function:b"))
end

-- mutation sites

function TestScanner:testAssignsSitesInsideFunctionToThatFunctionsScopeId()
  local result = analyze("local function f()\n  return 1 == 2\nend\nreturn f\n")
  local fn_scope = find_scope(result, "function:f")
  local found = false
  for _, site in ipairs(result.sites) do
    if site.description == "replace == with ~=" then
      lu.assertEquals(site.scope_id, fn_scope.id)
      found = true
    end
  end
  lu.assertTrue(found, "expected an == site")
end

function TestScanner:testAssignsTopLevelSitesToChunkScopeId()
  local result = analyze("local x = 1\nreturn x\n")
  local chunk_scope = find_scope(result, "chunk:m.lua")
  local found = false
  for _, site in ipairs(result.sites) do
    if site.description == "replace 1 with 0" then
      lu.assertEquals(site.scope_id, chunk_scope.id)
      found = true
    end
  end
  lu.assertTrue(found, "expected a numeric-literal site")
end

-- multi-byte (UTF-8) offset handling: luacheck's decoder switches to
-- codepoint indexing when the source contains multi-byte characters;
-- scanner must expose byte offsets so apply_mutation splices correctly.

local function find_site(result, description)
  for _, site in ipairs(result.sites) do
    if site.description == description then return site end
  end
  return nil
end

function TestScanner:testAsciiSourceSitePositionsAreByteOffsets()
  local source = "local x = 1 == 2\nreturn x\n"
  local site = find_site(analyze(source), "replace == with ~=")
  lu.assertNotNil(site)
  local byte_start, byte_end = source:find("==", 1, true)
  lu.assertEquals(site.start_pos, byte_start)
  lu.assertEquals(site.end_pos, byte_end)
  lu.assertEquals(site.original_text, "==")
end

function TestScanner:testSitePositionsAreByteOffsetsWithMultibyteCommentBeforeSite()
  local source = "-- 中文注释\nlocal x = 1 == 2\nreturn x\n"
  local site = find_site(analyze(source), "replace == with ~=")
  lu.assertNotNil(site)
  local byte_start, byte_end = source:find("==", 1, true)
  lu.assertEquals(site.start_pos, byte_start)
  lu.assertEquals(site.end_pos, byte_end)
  lu.assertEquals(site.original_text, "==")
end

function TestScanner:testSitePositionsAreByteOffsetsWithMultibyteStringBeforeSite()
  local source = "local s = \"道具\"\nlocal x = true\nreturn x\n"
  local site = find_site(analyze(source), "replace true with false")
  lu.assertNotNil(site)
  local byte_start, byte_end = source:find("true", 1, true)
  lu.assertEquals(site.start_pos, byte_start)
  lu.assertEquals(site.end_pos, byte_end)
  lu.assertEquals(site.original_text, "true")
end

function TestScanner:testApplyMutationSplicesAtByteOffsetsInMultibyteSource()
  local source = "-- 中文注释\nlocal x = 1 == 2\nreturn x\n"
  local site = find_site(analyze(source), "replace == with ~=")
  local mutated = scanner.apply_mutation(source, site)
  lu.assertEquals(mutated, "-- 中文注释\nlocal x = 1 ~= 2\nreturn x\n")
  lu.assertNotNil(load(mutated))
end

function TestScanner:testFunctionScopePositionsAreByteOffsetsWithMultibyteContent()
  local source = "-- 注释\nlocal function f()\n  return 1\nend\nreturn f\n"
  local scope = find_scope(analyze(source), "function:f")
  lu.assertNotNil(scope)
  lu.assertEquals(source:sub(scope.start_pos, scope.end_pos), "function f()\n  return 1\nend")
end

-- operator site spans: luacheck's Op node covers the whole operation
-- expression, but the mutation must splice only the operator token itself
-- (regression guard: expression-span splices produce syntax-error mutants
-- that any test suite trivially "kills").

function TestScanner:testUnaryNotSiteSpansOnlyTheKeyword()
  local source = "local x = not y\nreturn x\n"
  local site = find_site(analyze(source), "replace not with removed not")
  lu.assertNotNil(site)
  lu.assertEquals(site.original_text, "not")
  local mutated = scanner.apply_mutation(source, site)
  lu.assertEquals(mutated, "local x =  y\nreturn x\n")
  lu.assertNotNil(load(mutated))
end

function TestScanner:testUnaryMinusSiteSpansOnlyTheMinusSign()
  local source = "local x = -y\nreturn x\n"
  local site = find_site(analyze(source), "replace - with removed -")
  lu.assertNotNil(site)
  lu.assertEquals(site.original_text, "-")
  local mutated = scanner.apply_mutation(source, site)
  lu.assertEquals(mutated, "local x = y\nreturn x\n")
  lu.assertNotNil(load(mutated))
end

function TestScanner:testBinaryOperatorSiteIgnoresCommentLookalikesInGap()
  local source = "local x = a --[[n-1]] - b\nreturn x\n"
  local site = find_site(analyze(source), "replace - with +")
  lu.assertNotNil(site)
  lu.assertEquals(site.original_text, "-")
  local mutated = scanner.apply_mutation(source, site)
  lu.assertEquals(mutated, "local x = a --[[n-1]] + b\nreturn x\n")
  lu.assertNotNil(load(mutated))
end

function TestScanner:testWordOperatorSiteSpansOnlyTheKeyword()
  local source = "local x = a and b\nreturn x\n"
  local site = find_site(analyze(source), "replace and with or")
  lu.assertNotNil(site)
  lu.assertEquals(site.original_text, "and")
  local mutated = scanner.apply_mutation(source, site)
  lu.assertEquals(mutated, "local x = a or b\nreturn x\n")
  lu.assertNotNil(load(mutated))
end

function TestScanner:testBinaryOperatorSiteWithMultibyteCommentBeforeSite()
  local source = "-- 注释\nlocal x = a + b\nreturn x\n"
  local site = find_site(analyze(source), "replace + with -")
  lu.assertNotNil(site)
  lu.assertEquals(site.original_text, "+")
  local mutated = scanner.apply_mutation(source, site)
  lu.assertEquals(mutated, "-- 注释\nlocal x = a - b\nreturn x\n")
  lu.assertNotNil(load(mutated))
end

return TestScanner
