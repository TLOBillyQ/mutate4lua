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

function TestOverlay:testSharedGitSupportsLinkedWorktreeGitFile()
  -- Linked worktree source: its .git is a `gitdir:` pointer file, not a
  -- directory (regression test for the shared-git copy treating it as one).
  local main_repo = tmp_dir()
  local function sh(command)
    assert(util.command_succeeds(command .. " 2>/dev/null"), command)
  end

  sh("git init -q " .. util.shell_quote(main_repo))
  sh("git -C " .. util.shell_quote(main_repo) .. " config user.email t@example.com")
  sh("git -C " .. util.shell_quote(main_repo) .. " config user.name tester")
  util.mkdir_p(util.join_path(main_repo, "src"))
  write_file(util.join_path(main_repo, "src", "a.lua"), "return 1\n")
  sh("git -C " .. util.shell_quote(main_repo) .. " add -A")
  sh("git -C " .. util.shell_quote(main_repo) .. " commit -qm init")
  -- worktree add creates the directory itself.
  rm_rf(self.source)
  sh("git -C " .. util.shell_quote(main_repo) .. " worktree add -q "
    .. util.shell_quote(self.source) .. " -b wt-branch")
  write_file(util.join_path(self.source, "src", "b.lua"), "return 2\n")
  sh("git -C " .. util.shell_quote(self.source) .. " add -A")
  sh("git -C " .. util.shell_quote(self.source) .. " commit -qm wt-commit")
  lu.assertTrue(util.is_file(util.join_path(self.source, ".git")))

  -- Engine flow: the shared git dir stays alive while the workspace is used.
  local shared_git, git_err = overlay.prepare_shared_git(self.source)
  lu.assertNotNil(shared_git, git_err)
  lu.assertTrue(util.is_directory(shared_git))
  local ws = util.tmp_path("_ws")
  util.remove(ws)
  local ok, err = overlay.populate(self.source, "src/a.lua", ws, shared_git)
  lu.assertTrue(ok, err)
  local ws_q = util.shell_quote(ws)

  -- Git resolves inside the workspace, using the worktree's index and HEAD.
  local files = util.capture("git -C " .. ws_q .. " ls-files")
  lu.assertNotNil(files, "git ls-files failed in workspace")
  lu.assertStrContains(files, "src/a.lua")
  lu.assertStrContains(files, "src/b.lua")
  local branch = util.trim(assert(util.capture("git -C " .. ws_q .. " rev-parse --abbrev-ref HEAD")))
  lu.assertEquals(branch, "wt-branch")
  -- The commondir redirect is the core of the fix: the common dir must be the
  -- copy inside shared_git, never the real repository's admin directory.
  -- (Match by basename: git may resolve the /tmp symlink to /private/tmp.)
  local common_dir = util.trim(assert(util.capture("git -C " .. ws_q .. " rev-parse --git-common-dir")))
  lu.assertStrContains(common_dir, util.basename(shared_git))

  -- Git writes in the workspace must not reach the real repository.
  write_file(util.join_path(ws, "src", "a.lua"), "return 99\n")
  sh("git -C " .. ws_q .. " add src/a.lua")
  sh("git -C " .. ws_q .. " commit -qm workspace-commit")
  local real_status = assert(util.capture("git -C " .. util.shell_quote(self.source) .. " status --porcelain"))
  lu.assertEquals(real_status, "")
  local real_head = util.trim(assert(util.capture("git -C " .. util.shell_quote(main_repo) .. " rev-parse wt-branch")))
  local ws_head = util.trim(assert(util.capture("git -C " .. ws_q .. " rev-parse HEAD")))
  lu.assertNotEquals(real_head, ws_head)

  rm_rf(ws)
  util.remove(shared_git)
  rm_rf(main_repo)
end

return TestOverlay
