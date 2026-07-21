local function parse_args(argv)
  local args = {root = ".", coverage_file = nil, tool_root = ".", quiet = false}
  local index = 1
  while index <= #argv do
    local token = argv[index]
    if token == "--root" then
      index = index + 1
      if argv[index] == nil then
        error("--root requires a value")
      end
      args.root = argv[index]
    elseif token == "--coverage-file" then
      index = index + 1
      if argv[index] == nil then
        error("--coverage-file requires a value")
      end
      args.coverage_file = argv[index]
    elseif token == "--tool-root" then
      index = index + 1
      if argv[index] == nil then
        error("--tool-root requires a value")
      end
      args.tool_root = argv[index]
    elseif token == "--no-coverage" then
      args.coverage_file = nil
    elseif token == "--quiet" then
      -- accepted for compatibility with the engine; this driver has no extra output to suppress
      args.quiet = true
    else
      error("Unknown test driver option: " .. tostring(token))
    end
    index = index + 1
  end
  return args
end
local function run()
  local args = parse_args(arg)
  package.path = table.concat({
    args.tool_root .. "/lib/?.lua",
    args.tool_root .. "/lib/?/init.lua",
    "lib/?.lua",
    "lib/?/init.lua",
    "?.lua",
    package.path,
  }, ";")
  local project = require("mutate4lua.driver.project")
  local util = require("mutate4lua.util")
  local root = util.absolute_path(args.root)
  local files = project.discover_test_files(root)
  if #files == 0 then
    io.stderr:write("No test files found.\n")
    return 1
  end
  local coverage = {}
  if args.coverage_file then
    local prefix = (root == "/") and "/" or (root .. "/")
    local source_cache = {}
    -- note: the hook only covers the current coroutine; lines executed
    -- inside coroutines spawned by the tests are not recorded
    debug.sethook(function()
      local info = debug.getinfo(2, "Sl")
      if not info or not info.source then
        return
      end
      local key = source_cache[info.source]
      if key == nil then
        key = false
        if info.source:sub(1, 1) == "@" then
          local path = util.absolute_path(info.source:sub(2))
          if util.starts_with(path, prefix) and util.ends_with(path, ".lua") then
            key = util.relative_path(root, path):gsub("\\", "/") .. ":"
          end
        end
        source_cache[info.source] = key
      end
      if key then
        coverage[key .. info.currentline] = true
      end
    end, "l")
  end
  local ok, message = xpcall(function()
    for _, file in ipairs(files) do
      dofile(file)
    end
  end, debug.traceback)
  debug.sethook()
  if args.coverage_file then
    local lines = {}
    for key in pairs(coverage) do
      lines[#lines + 1] = key
    end
    table.sort(lines)
    assert(util.write_file(args.coverage_file, table.concat(lines, "\n") .. "\n"))
  end
  if not ok then
    io.stderr:write(tostring(message), "\n")
    return 1
  end
  return 0
end
os.exit(run())
