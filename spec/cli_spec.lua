local cli = require("mutate4lua.cli")

local function null_buffer()
  return { write = function() end }
end

local function stub_env(capture)
  return {
    stdout = null_buffer(),
    stderr = null_buffer(),
    engine = {
      mutate = function(options)
        capture.options = options
        return 0
      end,
    },
  }
end

describe("cli --poll-interval", function()
  it("parses --poll-interval into the mutate options", function()
    local capture = {}
    cli.run({ "target.lua", "--mutate-all", "--poll-interval", "0.05" }, stub_env(capture))
    assert.are.equal(0.05, capture.options.poll_interval)
  end)

  it("leaves poll_interval unset when the flag is absent", function()
    local capture = {}
    cli.run({ "target.lua", "--mutate-all" }, stub_env(capture))
    assert.is_nil(capture.options.poll_interval)
  end)
end)
