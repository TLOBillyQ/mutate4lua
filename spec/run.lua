-- Test entry point: `lua spec/run.lua [test-file ...]`
-- Delegates to the built-in runner: mutate4lua's own suite follows the same
-- test_*.lua + luaunit convention hosts do (ADR-0005, dogfood). With no
-- arguments the runner discovers spec/test_*.lua itself.

dofile("lib/mutate4lua/runner.lua")
