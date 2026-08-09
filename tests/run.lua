-- Test entry point: `lua tests/run.lua [test-file ...]`
-- Delegates to the built-in runner: mutate4lua's own suite follows the same
-- test_*.lua + luaunit convention hosts do (ADR-0005, dogfood). With no
-- arguments the runner discovers tests/test_*.lua itself.

dofile("src/runner.lua")
