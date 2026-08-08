local lu = require("luaunit")
local overlay = require("mutate4lua.internal.overlay")
local util = require("mutate4lua.util")

local function tmp_dir()
  local base = os.tmpname()
  os.remove(base)
  util.mkdir_p(base)
  return base
end

local function rm_rf(path)
  os.execute("rm -rf " .. string.format("%q", path))
end

local function write_file(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function is_symlink(path)
  return util.command_succeeds("test -L " .. util.shell_quote(path))
end

TestOverlay = {}

function TestOverlay:setUp()
  self.source = tmp_dir()
end

function TestOverlay:tearDown()
  rm_rf(self.source)
end

function TestOverlay:testCopiesTargetAndSharesSiblings()
  util.mkdir_p(util.join_path(self.source, "src"))
  util.mkdir_p(util.join_path(self.source, "lib"))
  util.mkdir_p(util.join_path(self.source, "test"))
  write_file(util.join_path(self.source, "src", "target.lua"), "return 42\n")
  write_file(util.join_path(self.source, "src", "other.lua"), "return 0\n")
  write_file(util.join_path(self.source, "lib", "util.lua"), "local M = {}\nreturn M\n")
  write_file(util.join_path(self.source, "test", "test_1.lua"), "return {}\n")

  local ws, err = overlay.create(self.source, "src/target.lua")
  lu.assertNotNil(ws, err)

  -- Mutation target is a real copy (and matches the source content).
  lu.assertTrue(util.is_file(util.join_path(ws, "src", "target.lua")))
  lu.assertEquals(read_file(util.join_path(ws, "src", "target.lua")), "return 42\n")

  -- Directories are real directories so git and tree-walking tools work.
  lu.assertFalse(is_symlink(util.join_path(ws, "lib")))
  lu.assertFalse(is_symlink(util.join_path(ws, "test")))
  lu.assertTrue(util.is_directory(util.join_path(ws, "lib")))
  lu.assertTrue(util.is_directory(util.join_path(ws, "test")))

  -- Sibling files share data with the source but are regular files, so tools
  -- like `find -type f` and `git ls-files` behave normally.
  lu.assertTrue(util.is_file(util.join_path(ws, "src", "other.lua")))
  lu.assertFalse(is_symlink(util.join_path(ws, "src", "other.lua")))
  lu.assertEquals(read_file(util.join_path(ws, "src", "other.lua")), "return 0\n")

  lu.assertTrue(util.is_file(util.join_path(ws, "test", "test_1.lua")))
  lu.assertFalse(is_symlink(util.join_path(ws, "test", "test_1.lua")))
  lu.assertTrue(util.is_file(util.join_path(ws, "lib", "util.lua")))
  lu.assertFalse(is_symlink(util.join_path(ws, "lib", "util.lua")))

  rm_rf(ws)
end

function TestOverlay:testCopiesRootWriteablesInsteadOfSymlinking()
  write_file(util.join_path(self.source, "m.lua"), "return 1\n")
  write_file(util.join_path(self.source, "luacov.report.out"), "report\n")
  write_file(util.join_path(self.source, "luacov.stats.out"), "stats\n")

  local ws, err = overlay.create(self.source, "m.lua")
  lu.assertNotNil(ws, err)

  lu.assertTrue(util.is_file(util.join_path(ws, "luacov.report.out")))
  lu.assertFalse(is_symlink(util.join_path(ws, "luacov.report.out")))
  lu.assertEquals(read_file(util.join_path(ws, "luacov.report.out")), "report\n")

  lu.assertTrue(util.is_file(util.join_path(ws, "luacov.stats.out")))
  lu.assertFalse(is_symlink(util.join_path(ws, "luacov.stats.out")))

  rm_rf(ws)
end

function TestOverlay:testTargetAtRoot()
  write_file(util.join_path(self.source, "app.lua"), "return {}\n")
  util.mkdir_p(util.join_path(self.source, "lib"))

  local ws, err = overlay.create(self.source, "app.lua")
  lu.assertNotNil(ws, err)

  lu.assertTrue(util.is_file(util.join_path(ws, "app.lua")))
  lu.assertFalse(is_symlink(util.join_path(ws, "app.lua")))
  lu.assertFalse(is_symlink(util.join_path(ws, "lib")))
  lu.assertTrue(util.is_directory(util.join_path(ws, "lib")))

  rm_rf(ws)
end

function TestOverlay:testCleanupRemovesWorkspaceFilesNotSource()
  write_file(util.join_path(self.source, "m.lua"), "return 1\n")
  util.mkdir_p(util.join_path(self.source, "lib"))
  write_file(util.join_path(self.source, "lib", "keep.lua"), "keep me\n")

  local ws, err = overlay.create(self.source, "m.lua")
  lu.assertNotNil(ws, err)

  -- Verify the shared file is readable before mutation/removal.
  lu.assertEquals(read_file(util.join_path(ws, "lib", "keep.lua")), "keep me\n")

  -- Mutating the workspace copy must not leak back to the source.
  write_file(util.join_path(ws, "lib", "keep.lua"), "mutated\n")
  lu.assertEquals(read_file(util.join_path(self.source, "lib", "keep.lua")), "keep me\n")

  -- Remove without trailing slash (same util.remove the engine uses).
  util.remove(ws)

  -- Real project must remain intact.
  lu.assertTrue(util.is_file(util.join_path(self.source, "lib", "keep.lua")))
  lu.assertEquals(read_file(util.join_path(self.source, "lib", "keep.lua")), "keep me\n")
end

function TestOverlay:testReportsErrorForMissingTarget()
  local ws, err = overlay.create(self.source, "missing.lua")
  lu.assertNil(ws)
  lu.assertNotNil(err)
end

function TestOverlay:testPopulateManyCreatesIndependentWorkspaces()
  util.mkdir_p(util.join_path(self.source, "src"))
  write_file(util.join_path(self.source, "src", "a.lua"), "return 1\n")
  write_file(util.join_path(self.source, "src", "b.lua"), "return 2\n")

  -- Workspaces must live outside the source tree; the fast overlay path uses
  -- recursive copy semantics that would loop if the destination were inside
  -- the source tree.
  local ws1 = util.tmp_path("_ws")
  local ws2 = util.tmp_path("_ws")
  local ws3 = util.tmp_path("_ws")
  local ok, err = overlay.populate_many(self.source, "src/a.lua", {ws1, ws2, ws3})
  lu.assertTrue(ok, err)

  for _, ws in ipairs({ws1, ws2, ws3}) do
    lu.assertTrue(util.is_file(util.join_path(ws, "src", "a.lua")))
    lu.assertFalse(is_symlink(util.join_path(ws, "src", "a.lua")))
    -- Sibling files are regular (copy-on-write shared) files, not symlinks.
    lu.assertTrue(util.is_file(util.join_path(ws, "src", "b.lua")))
    lu.assertFalse(is_symlink(util.join_path(ws, "src", "b.lua")))
    lu.assertEquals(read_file(util.join_path(ws, "src", "a.lua")), "return 1\n")
    -- Mutations in one workspace must not leak to another or back to source.
    write_file(util.join_path(ws, "src", "b.lua"), "mutated\n")
    lu.assertEquals(read_file(util.join_path(self.source, "src", "b.lua")), "return 2\n")
    rm_rf(ws)
  end
end

return TestOverlay
