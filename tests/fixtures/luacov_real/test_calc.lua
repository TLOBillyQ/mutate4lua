local calc = require("src.calc")

assert(calc.add(1, 2) == 3)
assert(calc.sub(5, 3) == 2)
assert(calc.mul(2, 3) == 6)
assert(calc.div(6, 2) == 3)
-- Intentionally never test calc.div(x, 0) — the zero-check branch is uncovered.
