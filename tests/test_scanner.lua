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

-- String-tag discrimination: luacheck uses the String tag both for real
-- literals and for dot-sugar keys; only real literals may be mutated.

local function count_sites(result, description)
  local count = 0
  for _, site in ipairs(result.sites) do
    if site.description == description then count = count + 1 end
  end
  return count
end

function TestScanner:testSkipsDotSyntaxIndexKeys()
  local result = analyze("local t = a.b\nreturn t\n")
  lu.assertEquals(count_sites(result, "replace b with nil"), 0)
end

function TestScanner:testSkipsMethodNamesInInvoke()
  local result = analyze("a:b(c)\n")
  lu.assertEquals(count_sites(result, "replace b with nil"), 0)
end

function TestScanner:testSkipsBareTableConstructorKeys()
  local result = analyze("local t = { id = 1 }\nreturn t\n")
  lu.assertEquals(count_sites(result, "replace id with nil"), 0)
end

function TestScanner:testKeepsBracketFormStringKeysAsMutationTargets()
  local result = analyze("local t = a[\"b\"]\nreturn t\n")
  lu.assertEquals(count_sites(result, "replace b with nil"), 1)
  local site = find_site(result, "replace b with nil")
  lu.assertEquals(site.original_text, "\"b\"")
  local source = "local t = a[\"b\"]\nreturn t\n"
  lu.assertNotNil(load(scanner.apply_mutation(source, site)))
end

function TestScanner:testKeepsRealStringLiteralsAsMutationTargets()
  local result = analyze("local t = { \"lit\" }\nreturn t\n")
  lu.assertEquals(count_sites(result, "replace lit with nil"), 1)
end

-- expression-context classification: statement-list bodies must not yield
-- Call→nil sites, and loop/repeat sub-expressions must keep theirs.

function TestScanner:testSkipsCallToNilInsideElseBlock()
  local result = analyze("if c then b() else d() end\n")
  lu.assertEquals(count_sites(result, "replace d() with nil"), 0)
  lu.assertEquals(count_sites(result, "replace b() with nil"), 0)
end

function TestScanner:testSkipsCallToNilInsideElseifElseBlock()
  local result = analyze("if c1 then b1() elseif c2 then b2() else b3() end\n")
  lu.assertEquals(count_sites(result, "replace b3() with nil"), 0)
end

function TestScanner:testKeepsCallToNilInWhileBodyCondition()
  local result = analyze("while f() do b() end\n")
  lu.assertEquals(count_sites(result, "replace f() with nil"), 1)
  lu.assertEquals(count_sites(result, "replace b() with nil"), 0)
end

function TestScanner:testKeepsFornumBoundAndRepeatConditionSites()
  local result = analyze("for i = 1, 10 do b() end\nrepeat r() until c == 1\n")
  lu.assertEquals(count_sites(result, "replace 1 with 0"), 2)
  lu.assertEquals(count_sites(result, "replace == with ~="), 1)
  lu.assertEquals(count_sites(result, "replace r() with nil"), 0)
  lu.assertEquals(count_sites(result, "replace b() with nil"), 0)
end

function TestScanner:testKeepsForinIteratorExpressionSites()
  local result = analyze("for k, v in pairs(t) do b() end\n")
  lu.assertEquals(count_sites(result, "replace pairs(t) with nil"), 1)
  lu.assertEquals(count_sites(result, "replace b() with nil"), 0)
end

-- chained calls: nil cannot be indexed or called, so those Call→nil sites
-- would be syntax-error mutants and are suppressed.

function TestScanner:testSkipsCallToNilWhenResultIsIndexed()
  local result = analyze("local push = require(\"x\").push\nreturn push\n")
  lu.assertEquals(count_sites(result, "replace require(\"x\") with nil"), 0)
end

function TestScanner:testSkipsCallToNilWhenResultIsMethodCalled()
  local result = analyze("local v = f():g()\nreturn v\n")
  lu.assertEquals(count_sites(result, "replace f() with nil"), 0)
end

function TestScanner:testSkipsCallToNilWhenResultIsCalled()
  local result = analyze("local v = f()(1)\nreturn v\n")
  lu.assertEquals(count_sites(result, "replace f() with nil"), 0)
end

function TestScanner:testKeepsCallToNilAsIndexKey()
  local result = analyze("local v = a[f()]\nreturn v\n")
  lu.assertEquals(count_sites(result, "replace f() with nil"), 1)
end

-- call-sugar strings: `f "x"` shares the AST shape of `f("x")`, but splicing
-- nil there yields `f nil`, which is not valid Lua.

function TestScanner:testSkipsStringToNilInCallSugarForm()
  local result = analyze("require \"src.rules.endgame\"\n")
  lu.assertEquals(count_sites(result, "replace src.rules.endgame with nil"), 0)
end

function TestScanner:testKeepsStringToNilInParenthesizedCall()
  local result = analyze("require(\"src.rules.endgame\")\n")
  lu.assertEquals(count_sites(result, "replace src.rules.endgame with nil"), 1)
end

function TestScanner:testSkipsStringToNilInMethodCallSugarForm()
  local result = analyze("a:b \"x\"\n")
  lu.assertEquals(count_sites(result, "replace x with nil"), 0)
end

-- ── suppress-when (ADR-0001 / equivalent mutation suppression) ───────────
-- Each predicate has a positive case (must suppress) and a counterexample
-- (must not suppress). The monopoly number.lua gold standard is checked
-- separately below.

function TestScanner:testSuppressesStringSubStartOneToZero()
  local result = analyze("local function f(s)\n  return string.sub(s, 1, 1)\nend\n")
  -- start arg suppressed; stop arg kept
  local ones = 0
  for _, site in ipairs(result.sites) do
    if site.description == "replace 1 with 0" then ones = ones + 1 end
  end
  lu.assertEquals(ones, 1, "only the stop arg 1→0 should remain")
  lu.assertEquals(result.suppressed_equivalent, 1)
end

function TestScanner:testDoesNotSuppressStringSubStopOneToZero()
  local source = "local function f(s)\n  return string.sub(s, 2, 1)\nend\n"
  local result = analyze(source)
  local site = find_site(result, "replace 1 with 0")
  lu.assertNotNil(site)
  lu.assertEquals(site.original_text, "1")
end

function TestScanner:testSuppressesStringByteStartOneToZero()
  local result = analyze("local function f(s)\n  return string.byte(s, 1)\nend\n")
  lu.assertEquals(count_sites(result, "replace 1 with 0"), 0)
  lu.assertTrue(result.suppressed_equivalent >= 1)
end

function TestScanner:testDoesNotSuppressBareOneToZeroOutsideStringLib()
  local result = analyze("local function f()\n  local x = 1\n  return x\nend\n")
  lu.assertEquals(count_sites(result, "replace 1 with 0"), 1)
end

function TestScanner:testSuppressesTrueToFalseOnTypeNameSetExtensionKeys()
  local source = table.concat({
    "local names = {\n",
    "  number = true,\n",
    "  integer = true,\n",
    "  fixed = true,\n",
    "}\n",
    "return names\n",
  })
  local result = analyze(source)
  lu.assertEquals(count_sites(result, "replace true with false"), 0)
  lu.assertEquals(result.suppressed_equivalent, 3)
end

function TestScanner:testDoesNotSuppressTrueToFalseOnFeatureFlagTable()
  -- debug is not a type-name extension, so the table is not a type-name set
  local source = "local flags = { number = true, debug = true }\nreturn flags\n"
  local result = analyze(source)
  lu.assertEquals(count_sites(result, "replace true with false"), 2)
end

function TestScanner:testDoesNotSuppressReturnTrue()
  local source = "local function f()\n  return true\nend\n"
  local result = analyze(source)
  lu.assertEquals(count_sites(result, "replace true with false"), 1)
end

function TestScanner:testSuppressesTrueToFalseOnTypeNameSetIndexEqTrue()
  local source = table.concat({
    "local names = { number = true, integer = true }\n",
    "local function is_num(t)\n",
    "  return names[t] == true\n",
    "end\n",
    "return is_num\n",
  })
  local result = analyze(source)
  -- table fields (2) + eq-true literal (1) all suppressed
  lu.assertEquals(count_sites(result, "replace true with false"), 0)
  lu.assertTrue(result.suppressed_equivalent >= 3)
end

function TestScanner:testDoesNotSuppressEqTrueOnOrdinaryTable()
  local source = table.concat({
    "local flags = { debug = true, verbose = true }\n",
    "local function on(k)\n",
    "  return flags[k] == true\n",
    "end\n",
    "return on\n",
  })
  local result = analyze(source)
  -- three true→false sites remain (2 fields + 1 eq literal)
  lu.assertEquals(count_sites(result, "replace true with false"), 3)
end

function TestScanner:testSuppressesNilStringAgainstTypeResultLocal()
  local source = table.concat({
    "local function f(v)\n",
    "  local vt = type(v)\n",
    "  if vt == \"nil\" then return false end\n",
    "  return true\n",
    "end\n",
  })
  local result = analyze(source)
  lu.assertEquals(count_sites(result, "replace nil with nil"), 0)
  lu.assertTrue(result.suppressed_equivalent >= 1)
end

function TestScanner:testDoesNotSuppressNilStringAgainstOrdinaryLocal()
  local source = table.concat({
    "local function f(name)\n",
    "  if name == \"nil\" then return true end\n",
    "  return false\n",
    "end\n",
  })
  local result = analyze(source)
  lu.assertEquals(count_sites(result, "replace nil with nil"), 1)
end

function TestScanner:testSuppressesTypeOfParamStringCompare()
  local source = table.concat({
    "local function f(value)\n",
    "  if type(value) == \"string\" then return 1 end\n",
    "  return 0\n",
    "end\n",
  })
  local result = analyze(source)
  -- both type(value)→nil and "string"→nil suppressed
  lu.assertEquals(count_sites(result, "replace type(value) with nil"), 0)
  lu.assertEquals(count_sites(result, "replace string with nil"), 0)
  lu.assertTrue(result.suppressed_equivalent >= 2)
end

function TestScanner:testDoesNotSuppressTypeOfLocalStringCompare()
  local source = table.concat({
    "local function f(value)\n",
    "  local ok, as_text = pcall(tostring, value)\n",
    "  if ok and type(as_text) == \"string\" then return as_text end\n",
    "  return nil\n",
    "end\n",
  })
  local result = analyze(source)
  lu.assertEquals(count_sites(result, "replace type(as_text) with nil"), 1)
  lu.assertEquals(count_sites(result, "replace string with nil"), 1)
end

function TestScanner:testSuppressesTypenameCheckerCallToNil()
  local source = table.concat({
    "local names = { number = true, integer = true }\n",
    "local function is_num_name(t)\n",
    "  return names[t] == true\n",
    "end\n",
    "local function f(t)\n",
    "  if is_num_name(t) then return true end\n",
    "  return false\n",
    "end\n",
  })
  local result = analyze(source)
  lu.assertEquals(count_sites(result, "replace is_num_name(t) with nil"), 0)
  lu.assertTrue(result.suppressed_equivalent >= 1)
end

function TestScanner:testDoesNotSuppressOrdinaryCallToNil()
  local source = table.concat({
    "local function is_ready(x)\n",
    "  return x ~= nil\n",
    "end\n",
    "local function f(x)\n",
    "  if is_ready(x) then return true end\n",
    "  return false\n",
    "end\n",
  })
  local result = analyze(source)
  lu.assertEquals(count_sites(result, "replace is_ready(x) with nil"), 1)
end

function TestScanner:testReportsSuppressedEquivalentCount()
  local result = analyze("local x = 1\nreturn x\n")
  lu.assertEquals(result.suppressed_equivalent, 0)
  lu.assertNotNil(result.suppressed_equivalent)
end

-- Gold standard: monopoly number.lua must suppress exactly the 9 F3
-- equivalents and must not suppress the 26 load-phase killables. Source is
-- vendored under tests/fixtures/ so the suite stays hermetic (no host tree).
local function load_number_gold()
  local path = "tests/fixtures/number_gold.lua"
  local f = assert(io.open(path, "rb"), "missing " .. path)
  local src = f:read("*a")
  f:close()
  return src
end

function TestScanner:testNumberLuaGoldStandardSuppressesNineEquivalents()
  local result = analyze(load_number_gold())
  -- Pre-suppress baseline is 92 sites; exactly the 9 F3 equivalents drop out.
  lu.assertEquals(result.suppressed_equivalent, 9)
  lu.assertEquals(#result.sites, 83)

  local function has(line, original, replacement)
    for _, site in ipairs(result.sites) do
      if site.line == line and site.original_text == original
        and site.replacement_text == replacement
      then
        return true
      end
    end
    return false
  end

  -- 9 equivalents must be gone
  lu.assertFalse(has(5, "true", "false"), "#2 number=true")
  lu.assertFalse(has(6, "true", "false"), "#3 integer=true")
  lu.assertFalse(has(7, "true", "false"), "#4 fixed=true")
  lu.assertFalse(has(11, "true", "false"), "#6 == true")
  lu.assertFalse(has(46, '"nil"', "nil"), "#21")
  lu.assertFalse(has(49, "_is_numeric_type_name(value_type)", "nil"), "#23")
  -- L76: start 1→0 gone, stop 1→0 remains (exactly one)
  local l76_ones = 0
  for _, site in ipairs(result.sites) do
    if site.line == 76 and site.original_text == "1" and site.replacement_text == "0" then
      l76_ones = l76_ones + 1
    end
  end
  lu.assertEquals(l76_ones, 1, "#42 start suppressed, stop kept")
  lu.assertFalse(has(100, "type(value)", "nil"), "#58")
  lu.assertFalse(has(100, '"string"', "nil"), "#60")

  -- Representative load-phase killables must remain
  lu.assertTrue(has(3, "and", "or"), "#1")
  lu.assertTrue(has(45, "type(value)", "nil"), "#19")
  lu.assertTrue(has(47, "false", "true"), "#22")
  lu.assertTrue(has(50, "true", "false"), "#24 return true")
  lu.assertTrue(has(52, '"string"', "nil"), "#26")
  lu.assertTrue(has(93, '"string"', "nil"), "inner type(as_text) string")
end

return TestScanner
