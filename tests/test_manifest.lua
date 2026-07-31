local lu = require("luaunit")
local manifest = require("mutate4lua.internal.manifest")

local function tmp_path()
  return string.format("/tmp/mutate4lua_manifest_spec_%d_%d.lua", os.time(), math.random(1, 1e9))
end

local function write_file(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local c = f:read("*a")
  f:close()
  return c
end

local function manifest_block(lines)
  return "--[[ mutate4lua-manifest\n" .. table.concat(lines, "\n") .. "\n]]"
end

TestManifest = {}

function TestManifest:setUp()
  self.path = tmp_path()
end

function TestManifest:tearDown()
  os.remove(self.path)
end

-- manifest.read

function TestManifest:testReadReturnsNilWhenFileHasNoManifestTail()
  write_file(self.path, "local m = {}\nreturn m\n")
  lu.assertNil(manifest.read(self.path))
end

function TestManifest:testReadReturnsNilWhenEndMarkerIsMissing()
  write_file(self.path, "return {}\n\n--[[ mutate4lua-manifest\nversion=3\n")
  lu.assertNil(manifest.read(self.path))
end

function TestManifest:testReadParsesVersionProjectHashAndSingleScope()
  write_file(self.path, "return {}\n\n" .. manifest_block({
    "version=3",
    "projectHash=cafebabedeadbeef",
    "scope.0.id=chunk:m.lua",
    "scope.0.kind=chunk",
    "scope.0.startLine=1",
    "scope.0.endLine=1",
    "scope.0.semanticHash=11112222",
  }) .. "\n")
  local data = manifest.read(self.path)
  lu.assertNotNil(data)
  lu.assertEquals(data.version, 3)
  lu.assertEquals(data.project_hash, "cafebabedeadbeef")
  lu.assertEquals(#data.scopes, 1)
  lu.assertEquals(data.scopes[1].id, "chunk:m.lua")
  lu.assertEquals(data.scopes[1].kind, "chunk")
  lu.assertEquals(data.scopes[1].start_line, 1)
  lu.assertEquals(data.scopes[1].end_line, 1)
  lu.assertEquals(data.scopes[1].semantic_hash, "11112222")
end

function TestManifest:testReadDefaultsVersionToOneWhenFieldIsMissing()
  write_file(self.path, "return {}\n\n" .. manifest_block({
    "projectHash=aaaa",
    "scope.0.id=chunk:m.lua",
    "scope.0.kind=chunk",
    "scope.0.startLine=1",
    "scope.0.endLine=1",
    "scope.0.semanticHash=bbbb",
  }) .. "\n")
  lu.assertEquals(manifest.read(self.path).version, 1)
end

function TestManifest:testReadIgnoresLegacyLastMutationFields()
  write_file(self.path, "return {}\n\n" .. manifest_block({
    "version=3",
    "projectHash=aaaa",
    "scope.0.id=chunk:m.lua",
    "scope.0.kind=chunk",
    "scope.0.startLine=1",
    "scope.0.endLine=1",
    "scope.0.semanticHash=bbbb",
    "scope.0.lastMutatedAt=2026-05-21T10:00:00Z",
    "scope.0.lastMutationLane=behavior",
    "scope.0.lastMutationStatus=passed",
    "scope.0.lastMutationSites=3",
    "scope.0.lastMutationKilled=3",
  }) .. "\n")
  local scope = manifest.read(self.path).scopes[1]
  lu.assertNil(scope.last_mutated_at)
  lu.assertNil(scope.last_mutation_lane)
  lu.assertNil(scope.last_mutation_status)
  lu.assertNil(scope.last_mutation_sites)
  lu.assertNil(scope.last_mutation_killed)
end

-- manifest.write

function TestManifest:testWriteRoundTripsMinimalScopeRecord()
  manifest.write(self.path, "return {}\n", {
    version = 3,
    project_hash = "1111",
    scopes = {
      {id = "chunk:m.lua", kind = "chunk", start_line = 1, end_line = 1, semantic_hash = "2222"},
    },
  })
  local data = manifest.read(self.path)
  lu.assertEquals(data.version, 3)
  lu.assertEquals(data.project_hash, "1111")
  lu.assertEquals(data.scopes[1].id, "chunk:m.lua")
  lu.assertEquals(data.scopes[1].semantic_hash, "2222")
end

function TestManifest:testWriteDoesNotWriteLastMutationMetadata()
  manifest.write(self.path, "return {}\n", {
    version = 3,
    project_hash = "1111",
    scopes = {
      {
        id = "chunk:m.lua", kind = "chunk", start_line = 1, end_line = 1, semantic_hash = "2222",
        last_mutated_at = "2026-05-21T10:00:00Z",
        last_mutation_status = "passed",
        last_mutation_sites = 7,
        last_mutation_killed = 5,
      },
    },
  })
  local raw = read_file(self.path)
  lu.assertNil(raw:find("lastMutation", 1, true))
  lu.assertNil(raw:find("lastMutatedAt", 1, true))
end

function TestManifest:testWritePlacesManifestTailAfterSourceSeparatedByBlankLine()
  manifest.write(self.path, "return 1\n", {
    version = 3,
    project_hash = "1111",
    scopes = {
      {id = "chunk:m.lua", kind = "chunk", start_line = 1, end_line = 1, semantic_hash = "2222"},
    },
  })
  local raw = read_file(self.path)
  -- luaunit's assertStrMatches is a FULL match; . matches newlines in Lua patterns
  lu.assertStrMatches(raw, "return 1\n\n%-%-%[%[ mutate4lua%-manifest.*")
  lu.assertStrMatches(raw, ".*%]%]\n")
end

-- manifest.serialize

function TestManifest:testSerializeEmitsVersion4WhenDataVersionIsUnset()
  local out = manifest.serialize({scopes = {}})
  lu.assertStrMatches(out, ".*version=4.*")
end

function TestManifest:testSerializeRespectsExplicitVersionField()
  local out = manifest.serialize({version = 5, scopes = {}})
  lu.assertStrMatches(out, ".*version=5.*")
end

function TestManifest:testSerializeOmitsLastMutationFields()
  local out = manifest.serialize({
    version = 3,
    project_hash = "x",
    scopes = {
      {id = "chunk:m.lua", kind = "chunk", start_line = 1, end_line = 1, semantic_hash = "y"},
    },
  })
  lu.assertNil(out:find("lastMutation"))
  lu.assertNil(out:find("lastMutatedAt"))
end

-- manifest.strip

function TestManifest:testStripRemovesManifestTailAndLeavesSource()
  local source = "local m = {}\nreturn m\n\n--[[ mutate4lua-manifest\nversion=3\nprojectHash=abc\n]]\n"
  lu.assertEquals(manifest.strip(source), "local m = {}\nreturn m\n")
end

function TestManifest:testStripReturnsSourceUnchangedWhenNoTailIsPresent()
  local source = "local m = {}\nreturn m\n"
  lu.assertEquals(manifest.strip(source), source)
end

function TestManifest:testStripNormalizesCrlfToLf()
  local source = "local m = {}\r\nreturn m\r\n"
  lu.assertEquals(manifest.strip(source), "local m = {}\nreturn m\n")
end

return TestManifest
