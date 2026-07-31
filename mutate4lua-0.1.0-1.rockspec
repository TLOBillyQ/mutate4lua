rockspec_format = "3.0"
package = "mutate4lua"
version = "0.1.0-1"
source = {
   url = "git+http://lzxsvn:3000/qinyuanj/mutate4lua.git",
   branch = "main",
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
   "luacheck >= 1.1.0",
   "luacov >= 0.17.0",
   "luaunit >= 3.4",
}
build = {
   type = "builtin",
   modules = {
      ["mutate4lua"] = "lib/mutate4lua/init.lua",
      ["mutate4lua.cli"] = "lib/mutate4lua/cli.lua",
      ["mutate4lua.engine"] = "lib/mutate4lua/engine.lua",
      ["mutate4lua.util"] = "lib/mutate4lua/util.lua",
      ["mutate4lua.runner"] = "lib/mutate4lua/runner.lua",
      ["mutate4lua.internal.manifest"] = "lib/mutate4lua/internal/manifest.lua",
      ["mutate4lua.internal.project"] = "lib/mutate4lua/internal/project.lua",
      ["mutate4lua.internal.scanner"] = "lib/mutate4lua/internal/scanner.lua",
      ["mutate4lua.internal.ast"] = "lib/mutate4lua/internal/ast.lua",
      ["mutate4lua.internal.parallel"] = "lib/mutate4lua/internal/parallel.lua",
   },
}
