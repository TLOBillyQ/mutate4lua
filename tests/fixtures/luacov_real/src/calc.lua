local calc = {}

function calc.add(a, b)
  return a + b
end

function calc.sub(a, b)
  return a - b
end

function calc.mul(a, b)
  return a * b
end

function calc.div(a, b)
  if b == 0 then
    return nil
  end
  return a / b
end

return calc
