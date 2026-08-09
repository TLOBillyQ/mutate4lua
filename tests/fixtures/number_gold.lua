local number_utils = {}

local _tointeger = math and math.tointeger
local _numeric_type_names = {
  number = true,
  integer = true,
  fixed = true,
}

local function _is_numeric_type_name(value_type)
  return _numeric_type_names[value_type] == true
end

-- Returns nil when `convert` is absent or raises, so callers can chain fallbacks.
local function _try_convert(convert, value)
  if convert == nil then
    return nil
  end
  local ok, converted = pcall(convert, value)
  if ok and converted ~= nil then
    return converted
  end
  return nil
end

local function _to_integer_safe(value)
  if value == nil then
    return nil
  end
  local as_int = _try_convert(_tointeger, value)
  if as_int ~= nil then
    return as_int
  end
  return _try_convert(math and math.floor, value)
end

local function _truncate_number(value)
  if not number_utils.is_numeric(value) then
    return nil
  end
  return _to_integer_safe(value)
end

function number_utils.is_numeric(value)
  local value_type = type(value)
  if value_type == "nil" then
    return false
  end
  if _is_numeric_type_name(value_type) then
    return true
  end
  if value_type == "string" then
    return false
  end
  return _to_integer_safe(value) ~= nil
end

local function _digits_to_number(value, first_index)
  local num = 0
  for idx = first_index, #value do
    local digit = string.byte(value, idx) - 48
    num = num * 10 + digit
  end
  return num
end

local function _parse_integer_string(value)
  if value == nil then
    return nil
  end
  if not string.match(value, "^-?%d+$") then
    return nil
  end
  local sign = 1
  local first_index = 1
  if string.sub(value, 1, 1) == "-" then
    sign = -1
    first_index = 2
  end
  local num = sign * _digits_to_number(value, first_index)
  if _tointeger then
    return _tointeger(num)
  end
  return num
end

-- Last resort for host values (userdata/Fixed) that only reveal digits via tostring.
local function _parse_via_tostring(value)
  if value == nil then
    return nil
  end
  local ok, as_text = pcall(tostring, value)
  if ok and type(as_text) == "string" then
    return _parse_integer_string(as_text)
  end
  return nil
end

function number_utils.to_integer(value)
  if type(value) == "string" then
    return _parse_integer_string(value)
  end
  if number_utils.is_numeric(value) then
    local parsed = _to_integer_safe(value)
    if parsed ~= nil then
      return parsed
    end
  end
  return _parse_via_tostring(value)
end

function number_utils.clamp(value, min, max)
  if value == nil or value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

function number_utils.page_count(item_count, page_size)
  return math.max(1, math.floor((item_count + page_size - 1) / page_size))
end

function number_utils.format_integer_part(value)
  local as_int = _truncate_number(value)
  if as_int ~= nil then
    return string.format("%d", as_int)
  end
  return tostring(value)
end

function number_utils.resolve_numeric(value, fallback)
  if number_utils.is_numeric(value) then
    return value + 0
  end
  if number_utils.is_numeric(fallback) then
    return fallback + 0
  end
  return nil
end

function number_utils.diff_or_zero(timestamp_1, timestamp_2)
  if number_utils.is_numeric(timestamp_1) and number_utils.is_numeric(timestamp_2) then
    return timestamp_1 - timestamp_2
  end
  return 0
end

return number_utils

