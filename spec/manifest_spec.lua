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

describe("manifest.read", function()
  local path
  before_each(function() path = tmp_path() end)
  after_each(function() os.remove(path) end)

  it("returns nil when the file has no manifest tail", function()
    write_file(path, "local m = {}\nreturn m\n")
    assert.is_nil(manifest.read(path))
  end)

  it("returns nil when the end marker ]] is missing", function()
    write_file(path, "return {}\n\n--[[ mutate4lua-manifest\nversion=2\n")
    assert.is_nil(manifest.read(path))
  end)

  it("parses version, projectHash, and a single scope", function()
    write_file(path, "return {}\n\n" .. manifest_block({
      "version=2",
      "projectHash=cafebabedeadbeef",
      "scope.0.id=chunk:m.lua",
      "scope.0.kind=chunk",
      "scope.0.startLine=1",
      "scope.0.endLine=1",
      "scope.0.semanticHash=11112222",
    }) .. "\n")
    local data = manifest.read(path)
    assert.is_not_nil(data)
    assert.are.equal(2, data.version)
    assert.are.equal("cafebabedeadbeef", data.project_hash)
    assert.are.equal(1, #data.scopes)
    assert.are.equal("chunk:m.lua", data.scopes[1].id)
    assert.are.equal("chunk", data.scopes[1].kind)
    assert.are.equal(1, data.scopes[1].start_line)
    assert.are.equal(1, data.scopes[1].end_line)
    assert.are.equal("11112222", data.scopes[1].semantic_hash)
  end)

  it("defaults version to 1 when the field is missing", function()
    write_file(path, "return {}\n\n" .. manifest_block({
      "projectHash=aaaa",
      "scope.0.id=chunk:m.lua",
      "scope.0.kind=chunk",
      "scope.0.startLine=1",
      "scope.0.endLine=1",
      "scope.0.semanticHash=bbbb",
    }) .. "\n")
    assert.are.equal(1, manifest.read(path).version)
  end)

  it("preserves lastMutation fields when present", function()
    write_file(path, "return {}\n\n" .. manifest_block({
      "version=2",
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
    local scope = manifest.read(path).scopes[1]
    assert.are.equal("2026-05-21T10:00:00Z", scope.last_mutated_at)
    assert.are.equal("behavior", scope.last_mutation_lane)
    assert.are.equal("passed", scope.last_mutation_status)
    assert.are.equal(3, scope.last_mutation_sites)
    assert.are.equal(3, scope.last_mutation_killed)
  end)
end)

describe("manifest.write", function()
  local path
  before_each(function() path = tmp_path() end)
  after_each(function() os.remove(path) end)

  it("round-trips a minimal scope record", function()
    manifest.write(path, "return {}\n", {
      version = 2,
      project_hash = "1111",
      scopes = {
        {id = "chunk:m.lua", kind = "chunk", start_line = 1, end_line = 1, semantic_hash = "2222"},
      },
    })
    local data = manifest.read(path)
    assert.are.equal(2, data.version)
    assert.are.equal("1111", data.project_hash)
    assert.are.equal("chunk:m.lua", data.scopes[1].id)
    assert.are.equal("2222", data.scopes[1].semantic_hash)
  end)

  it("round-trips lastMutation metadata", function()
    manifest.write(path, "return {}\n", {
      version = 2,
      project_hash = "1111",
      scopes = {
        {
          id = "chunk:m.lua", kind = "chunk", start_line = 1, end_line = 1, semantic_hash = "2222",
          last_mutated_at = "2026-05-21T10:00:00Z",
          last_mutation_lane = "behavior",
          last_mutation_status = "passed",
          last_mutation_sites = 7,
          last_mutation_killed = 5,
        },
      },
    })
    local scope = manifest.read(path).scopes[1]
    assert.are.equal("2026-05-21T10:00:00Z", scope.last_mutated_at)
    assert.are.equal(5, scope.last_mutation_killed)
    assert.are.equal(7, scope.last_mutation_sites)
  end)

  it("places the manifest tail after the source, separated by a blank line", function()
    manifest.write(path, "return 1\n", {
      version = 2,
      project_hash = "1111",
      scopes = {
        {id = "chunk:m.lua", kind = "chunk", start_line = 1, end_line = 1, semantic_hash = "2222"},
      },
    })
    local raw = read_file(path)
    assert.matches("^return 1\n\n%-%-%[%[ mutate4lua%-manifest", raw)
    assert.matches("%]%]\n$", raw)
  end)
end)

describe("manifest.serialize", function()
  it("emits version=2 when data.version is unset", function()
    local out = manifest.serialize({scopes = {}})
    assert.matches("version=2", out)
  end)

  it("respects an explicit version field", function()
    local out = manifest.serialize({version = 5, scopes = {}})
    assert.matches("version=5", out)
  end)

  it("omits lastMutation fields when nil", function()
    local out = manifest.serialize({
      version = 2,
      project_hash = "x",
      scopes = {
        {id = "chunk:m.lua", kind = "chunk", start_line = 1, end_line = 1, semantic_hash = "y"},
      },
    })
    assert.is_nil(out:find("lastMutation"))
    assert.is_nil(out:find("lastMutatedAt"))
  end)
end)

describe("manifest.strip", function()
  it("removes the manifest tail and leaves the source", function()
    local source = "local m = {}\nreturn m\n\n--[[ mutate4lua-manifest\nversion=2\nprojectHash=abc\n]]\n"
    assert.are.equal("local m = {}\nreturn m\n", manifest.strip(source))
  end)

  it("returns the source unchanged when no tail is present", function()
    local source = "local m = {}\nreturn m\n"
    assert.are.equal(source, manifest.strip(source))
  end)

  it("normalizes CRLF to LF", function()
    local source = "local m = {}\r\nreturn m\r\n"
    assert.are.equal("local m = {}\nreturn m\n", manifest.strip(source))
  end)
end)
