local util = require("mutate4lua.util")
local lexer = {}
local keywords = {
  ["and"] = true,
  ["break"] = true,
  ["do"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["end"] = true,
  ["false"] = true,
  ["for"] = true,
  ["function"] = true,
  ["goto"] = true,
  ["if"] = true,
  ["in"] = true,
  ["local"] = true,
  ["nil"] = true,
  ["not"] = true,
  ["or"] = true,
  ["repeat"] = true,
  ["return"] = true,
  ["then"] = true,
  ["true"] = true,
  ["until"] = true,
  ["while"] = true,
}
local function count_newlines(text)
  local _, count = text:gsub("\n", "\n")
  return count
end
local function long_bracket_equals(source, index)
  if source:sub(index, index) ~= "[" then
    return nil
  end
  local cursor = index + 1
  while source:sub(cursor, cursor) == "=" do
    cursor = cursor + 1
  end
  if source:sub(cursor, cursor) ~= "[" then
    return nil
  end
  return cursor - index - 1
end
local function close_long_bracket(source, index, equals_count)
  local closer = "]" .. string.rep("=", equals_count) .. "]"
  return source:find(closer, index, true)
end

local function scan_number(source, index, length)
  local function is_hex(ch)
    return ch:match("[%da-fA-F]") ~= nil
  end
  local function is_bin(ch)
    return ch == "0" or ch == "1"
  end
  local cursor = index
  local prefix = source:sub(index, index + 1)
  if prefix == "0x" or prefix == "0X" then
    cursor = index + 2
    while cursor <= length do
      local ch = source:sub(cursor, cursor)
      if ch == "_" or is_hex(ch) then
        cursor = cursor + 1
      else
        break
      end
    end
    if source:sub(cursor, cursor) == "." then
      cursor = cursor + 1
      while cursor <= length do
        local ch = source:sub(cursor, cursor)
        if ch == "_" or is_hex(ch) then
          cursor = cursor + 1
        else
          break
        end
      end
    end
    local exp = source:sub(cursor, cursor)
    if exp == "p" or exp == "P" then
      cursor = cursor + 1
      local sign = source:sub(cursor, cursor)
      if sign == "+" or sign == "-" then
        cursor = cursor + 1
      end
      while cursor <= length do
        local ch = source:sub(cursor, cursor)
        if ch == "_" or ch:match("%d") then
          cursor = cursor + 1
        else
          break
        end
      end
    end
    return cursor - 1
  end
  if prefix == "0b" or prefix == "0B" then
    cursor = index + 2
    while cursor <= length do
      local ch = source:sub(cursor, cursor)
      if ch == "_" or is_bin(ch) then
        cursor = cursor + 1
      else
        break
      end
    end
    return cursor - 1
  end

  while cursor <= length and source:sub(cursor, cursor):match("[%d_]") do
    cursor = cursor + 1
  end
  if source:sub(cursor, cursor) == "." and source:sub(cursor + 1, cursor + 1) ~= "." then
    cursor = cursor + 1
    while cursor <= length and source:sub(cursor, cursor):match("[%d_]") do
      cursor = cursor + 1
    end
  end
  local exp = source:sub(cursor, cursor)
  if exp == "e" or exp == "E" then
    cursor = cursor + 1
    local sign = source:sub(cursor, cursor)
    if sign == "+" or sign == "-" then
      cursor = cursor + 1
    end
    while cursor <= length and source:sub(cursor, cursor):match("[%d_]") do
      cursor = cursor + 1
    end
  end
  return cursor - 1
end
function lexer.tokenize(source)
  source = util.normalize_newlines(source)
  local tokens = {}
  local index = 1
  local line = 1
  local length = #source
  while index <= length do
    local current = source:sub(index, index)
    local next_char = source:sub(index + 1, index + 1)
    if current == "\n" then
      line = line + 1
      index = index + 1
    elseif current:match("%s") then
      index = index + 1
      elseif current == "-" and next_char == "-" then
        local equals_count = long_bracket_equals(source, index + 2)
        if equals_count then
          local start_index = index + 2
          local close_index = close_long_bracket(source, start_index, equals_count)
          if not close_index then
            local chunk = source:sub(index)
            line = line + count_newlines(chunk)
            index = length + 1
            break
          end
        local chunk_end = close_index + equals_count + 2
        local chunk = source:sub(index, chunk_end)
        line = line + count_newlines(chunk)
        index = chunk_end + 1
      else
        local newline = source:find("\n", index, true)
        if not newline then
          break
        end
        line = line + 1
        index = newline + 1
      end
    elseif current == "'" or current == '"' then
      local delimiter = current
      local cursor = index + 1
      while cursor <= length do
        local ch = source:sub(cursor, cursor)
        if ch == "\\" then
          cursor = cursor + 2
        elseif ch == delimiter then
          break
        else
          cursor = cursor + 1
        end
      end
      if cursor > length then
        cursor = length
      end
      local text = source:sub(index, cursor)
      tokens[#tokens + 1] = {
        type = "string",
        value = text,
        start_pos = index,
        end_pos = cursor,
        line = line,
      }
      line = line + count_newlines(text)
      index = cursor + 1
    elseif current == "[" then
      local equals_count = long_bracket_equals(source, index)
      if equals_count then
        local close_index = close_long_bracket(source, index + 1, equals_count)
        local cursor = close_index and (close_index + equals_count + 2) or length
        local text = source:sub(index, cursor)
        tokens[#tokens + 1] = {
          type = "string",
          value = text,
          start_pos = index,
          end_pos = cursor,
          line = line,
        }
        line = line + count_newlines(text)
        index = cursor + 1
      else
        tokens[#tokens + 1] = {
          type = "symbol",
          value = current,
          start_pos = index,
          end_pos = index,
          line = line,
        }
        index = index + 1
      end
    elseif current:match("[%a_]") then
      local cursor = index
      while source:sub(cursor, cursor):match("[%w_]") do
        cursor = cursor + 1
      end
      cursor = cursor - 1
      local text = source:sub(index, cursor)
      tokens[#tokens + 1] = {
        type = keywords[text] and "keyword" or "identifier",
        value = text,
        start_pos = index,
        end_pos = cursor,
        line = line,
      }
      index = cursor + 1
      elseif current:match("%d") then
        local cursor = scan_number(source, index, length)
        tokens[#tokens + 1] = {
          type = "number",
          value = source:sub(index, cursor),
        start_pos = index,
        end_pos = cursor,
        line = line,
      }
      index = cursor + 1
    else
      local three = source:sub(index, index + 2)
      local two = source:sub(index, index + 1)
      local value
      if three == "..." then
        value = three
      elseif two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." then
        value = two
      else
        value = current
      end
      tokens[#tokens + 1] = {
        type = "symbol",
        value = value,
        start_pos = index,
        end_pos = index + #value - 1,
        line = line,
      }
      index = index + #value
    end
  end
  return tokens
end
return lexer
