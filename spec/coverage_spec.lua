local engine = require("mutate4lua.engine")
local util = require("mutate4lua.util")

describe("engine._parse_luacov_report", function()
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

  local function report_with(target_rel, hits)
    -- hits is an array where each entry is either a number, "miss", or "blank".
    local lines = {
      "==============================================================================",
      target_rel,
      "==============================================================================",
    }
    for i, kind in ipairs(hits) do
      if kind == "blank" then
        lines[#lines + 1] = "        -- non-executable"
      elseif kind == "miss" then
        lines[#lines + 1] = "  ***0    print(" .. tostring(i) .. ")"
      else
        lines[#lines + 1] = string.format("%6d    print(%d)", kind, i)
      end
    end
    lines[#lines + 1] = "=============================================================================="
    lines[#lines + 1] = "other.lua"
    lines[#lines + 1] = "=============================================================================="
    lines[#lines + 1] = "    99    print('other')"
    return table.concat(lines, "\n") .. "\n"
  end

  local dir
  before_each(function() dir = tmp_dir() end)
  after_each(function() rm_rf(dir) end)

  it("marks lines with a positive hit count as covered", function()
    local path = util.join_path(dir, "luacov.report.out")
    write_file(path, report_with("m.lua", {1, "miss", 3, "blank", 5}))
    local covered = engine._parse_luacov_report(path, dir, "m.lua")
    assert.is_true(covered[1])
    assert.is_nil(covered[2])
    assert.is_true(covered[3])
    assert.is_nil(covered[4])
    assert.is_true(covered[5])
  end)

  it("returns nil when the report file is missing", function()
    local covered = engine._parse_luacov_report(util.join_path(dir, "missing.out"), dir, "m.lua")
    assert.is_nil(covered)
  end)

  it("matches the target by absolute filename under the workspace root", function()
    local path = util.join_path(dir, "luacov.report.out")
    write_file(path, report_with(util.join_path(dir, "src/m.lua"), {1, 2}))
    local covered = engine._parse_luacov_report(path, dir, "src/m.lua")
    assert.is_true(covered[1])
    assert.is_true(covered[2])
  end)

  it("ignores sections for other files", function()
    local path = util.join_path(dir, "luacov.report.out")
    -- First section is for m.lua (missed), second for other.lua (covered).
    write_file(path, report_with("m.lua", {"miss", "miss"}))
    local covered = engine._parse_luacov_report(path, dir, "other.lua")
    assert.is_true(covered[1])
  end)

  it("handles reports with non-executable lines and ***0 markers", function()
    local path = util.join_path(dir, "luacov.report.out")
    write_file(path, report_with("m.lua", {"blank", "miss", "blank", 4, "blank"}))
    local covered = engine._parse_luacov_report(path, dir, "m.lua")
    assert.is_nil(covered[1])
    assert.is_nil(covered[2])
    assert.is_nil(covered[3])
    assert.is_true(covered[4])
    assert.is_nil(covered[5])
  end)
end)
