local cli = {}

local usage_text = [[
Usage:
  mutate4lua <file.lua>                      Mutate one Lua source file
  mutate4lua <file.lua> --scan              Print mutation-site scan without running tests
  mutate4lua <file.lua> --update-manifest   Write embedded manifest without running tests
  mutate4lua <file.lua> --lines 12,18       Restrict mutations to specific source lines
  mutate4lua <file.lua> --since-last-run    Mutate only scopes changed since embedded manifest
  mutate4lua <file.lua> --mutate-all        Ignore embedded manifest and mutate all covered sites
  mutate4lua <file.lua> --mutation-warning 50 Warn when selected mutation count exceeds threshold
  mutate4lua <file.lua> --max-workers 4     Limit parallel worker count
  mutate4lua <file.lua> --timeout-factor 15 Set mutant timeout as baseline multiplier
  mutate4lua <file.lua> --test-command CMD  Override the test command used for baseline and mutants
  mutate4lua <file.lua> --verbose           Print live worker progress
  mutate4lua --help                         Print this help message
]]

function cli.usage()
  return usage_text
end

return cli
