rockspec_format = "3.0"
package = "mutate4lua"
version = "0.2.1-1"
source = {
   url = "git+http://lzxsvn:3000/qinyuanj/mutate4lua.git",
   tag = "v0.2.1",
}
description = {
   summary = "Mutation testing library for Lua",
   detailed = [[
      mutate4lua performs mutation testing for Lua projects using luacheck's
      AST, semantic-hash based incremental mutation, and luacov coverage
      filtering. It is the Lua port of unclebob's clj-mutate / mutate4go /
      mutate4java tools.
   ]],
   homepage = "http://lzxsvn:3000/qinyuanj/mutate4lua",
   license = "MIT",
}
dependencies = {
   "lua >= 5.4",
   "luacheck == 1.2.0-1",
   "luacov == 0.17.0-1",
   "luaunit == 3.5-1",
}
build = {
   type = "builtin",
   modules = {
      ["mutate4lua"] = "src/init.lua",
      ["mutate4lua.cli"] = "src/cli.lua",
      ["mutate4lua.engine"] = "src/engine.lua",
      ["mutate4lua.runner"] = "src/runner.lua",
      ["mutate4lua.util"] = "src/util.lua",
      ["mutate4lua.internal.ast"] = "src/internal/ast.lua",
      ["mutate4lua.internal.attribution"] = "src/internal/attribution.lua",
      ["mutate4lua.internal.manifest"] = "src/internal/manifest.lua",
      ["mutate4lua.internal.overlay"] = "src/internal/overlay.lua",
      ["mutate4lua.internal.parallel"] = "src/internal/parallel.lua",
      ["mutate4lua.internal.project"] = "src/internal/project.lua",
      ["mutate4lua.internal.resident"] = "src/internal/resident.lua",
      ["mutate4lua.internal.scanner"] = "src/internal/scanner.lua",
   },
}
