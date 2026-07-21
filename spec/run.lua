-- Test entry point: `lua spec/run.lua [spec-file ...]`
-- With no arguments, runs every spec/*_spec.lua file.

package.path = "./lib/?.lua;./lib/?/init.lua;./?.lua;" .. package.path

local harness = require("spec.harness")

local files = {}
for _, a in ipairs(arg) do
  files[#files + 1] = a
end

if #files == 0 then
  local p = io.popen("ls spec/*_spec.lua 2>/dev/null")
  for line in p:lines() do
    files[#files + 1] = line
  end
  p:close()
end

if #files == 0 then
  io.stderr:write("no spec files found\n")
  os.exit(1)
end

table.sort(files)

for _, file in ipairs(files) do
  local chunk, err = loadfile(file)
  if chunk == nil then
    io.stderr:write(file .. ": " .. tostring(err) .. "\n")
    os.exit(1)
  end
  local ok, e = xpcall(chunk, debug.traceback)
  if not ok then
    io.stderr:write(file .. ": " .. tostring(e) .. "\n")
    os.exit(1)
  end
end

os.exit(harness.run() and 0 or 1)
