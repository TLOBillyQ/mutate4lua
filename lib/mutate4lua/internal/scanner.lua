local lexer = require("mutate4lua.internal.lexer")
local util = require("mutate4lua.util")

local scanner = {}

local binary_replacements = {
  ["=="] = {replacement = "~=", description = "replace == with ~="},
  ["~="] = {replacement = "==", description = "replace ~= with =="},
  ["<"] = {replacement = "<=", description = "replace < with <="},
  ["<="] = {replacement = "<", description = "replace <= with <"},
  [">"] = {replacement = ">=", description = "replace > with >="},
  [">="] = {replacement = ">", description = "replace >= with >"},
  ["+"] = {replacement = "-", description = "replace + with -"},
  ["-"] = {replacement = "+", description = "replace - with +"},
  ["*"] = {replacement = "/", description = "replace * with /"},
  ["/"] = {replacement = "*", description = "replace / with *"},
  ["and"] = {replacement = "or", description = "replace and with or"},
  ["or"] = {replacement = "and", description = "replace or with and"},
}

local expression_breakers = {
  ["("] = true,
  ["{"] = true,
  ["["] = true,
  [","] = true,
  ["="] = true,
  ["=="] = true,
  ["~="] = true,
  ["<"] = true,
  ["<="] = true,
  [">"] = true,
  [">="] = true,
  ["+"] = true,
  ["-"] = true,
  ["*"] = true,
  ["/"] = true,
  ["%"] = true,
  ["^"] = true,
  ["~"] = true,
  ["#"] = true,
  [".."] = true,
  ["and"] = true,
  ["or"] = true,
  ["not"] = true,
  ["return"] = true,
  ["then"] = true,
  ["do"] = true,
  ["elseif"] = true,
  ["local"] = true,
  ["until"] = true,
  [";"] = true,
}

-- for/while push via their `do`; pushing at the keyword too would double-push.
local block_starters = {
  ["if"] = true,
}

local function previous_token(tokens, index)
  return tokens[index - 1]
end

local function next_token(tokens, index)
  return tokens[index + 1]
end

-- Declaration-based function name: the raw dotted/colon name for named
-- functions, "<anonymous>" for function expressions. Duplicate names are
-- disambiguated by occurrence index later (in source order).
local function function_base_name(tokens, index)
  local token = next_token(tokens, index)
  local parts = {}
  if token and token.value == "(" then
    return "<anonymous>"
  end
  while token do
    if token.value == "(" then
      break
    end
    if token.type == "identifier" or token.value == "." or token.value == ":" then
      parts[#parts + 1] = token.value
    else
      break
    end
    token = next_token(tokens, index + #parts)
  end
  if #parts == 0 then
    return "<anonymous>"
  end
  return table.concat(parts)
end

local function line_count(text)
  local count = 1
  local index = 1
  while true do
    local found = text:find("\n", index, true)
    if not found then
      return count
    end
    count = count + 1
    index = found + 1
  end
end

local function build_scopes(source_file, relative_file, source, tokens)
  local scopes = {
    {
      id = "chunk:" .. relative_file,
      kind = "chunk",
      start_line = 1,
      end_line = line_count(source),
      start_pos = 1,
      end_pos = #source,
    }
  }
  local stack = {}
  local functions = {}
  for index, token in ipairs(tokens) do
    if token.type == "keyword" then
      if token.value == "function" then
        stack[#stack + 1] = {
          kind = "function",
          base_name = function_base_name(tokens, index),
          start_line = token.line,
          start_pos = token.start_pos,
        }
      elseif block_starters[token.value] then
        stack[#stack + 1] = {kind = token.value}
      elseif token.value == "do" then
        stack[#stack + 1] = {kind = "do"}
      elseif token.value == "repeat" then
        stack[#stack + 1] = {kind = "repeat"}
      elseif token.value == "until" then
        for position = #stack, 1, -1 do
          if stack[position].kind == "repeat" then
            table.remove(stack, position)
            break
          end
        end
      elseif token.value == "end" then
        local block = table.remove(stack)
        if block and block.kind == "function" then
          functions[#functions + 1] = {
            base_name = block.base_name,
            start_line = block.start_line,
            end_line = token.line,
            start_pos = block.start_pos,
            end_pos = token.end_pos,
          }
        end
      end
    end
  end
  local name_counts = {}
  for _, fn in ipairs(functions) do
    local count = (name_counts[fn.base_name] or 0) + 1
    name_counts[fn.base_name] = count
    local id
    if count == 1 then
      id = "function:" .. fn.base_name
    else
      id = "function:" .. fn.base_name .. "#" .. count
    end
    scopes[#scopes + 1] = {
      id = id,
      kind = "function",
      start_line = fn.start_line,
      end_line = fn.end_line,
      start_pos = fn.start_pos,
      end_pos = fn.end_pos,
    }
  end
  for _, scope in ipairs(scopes) do
    local parts = {}
    for _, t in ipairs(tokens) do
      if t.start_pos >= scope.start_pos and t.end_pos <= scope.end_pos then
        parts[#parts + 1] = t.value
      end
    end
    scope.semantic_hash = util.fnv1a64(table.concat(parts, " "))
    scope.file = source_file
  end
  return scopes
end

local function assign_scope(scopes, position)
  local winner = scopes[1]
  local best_span = winner.end_pos - winner.start_pos
  for _, scope in ipairs(scopes) do
    if position >= scope.start_pos and position <= scope.end_pos then
      local span = scope.end_pos - scope.start_pos
      if span <= best_span then
        best_span = span
        winner = scope
      end
    end
  end
  return winner
end

local function add_site(sites, scopes, source, token, replacement, description)
  local scope = assign_scope(scopes, token.start_pos)
  sites[#sites + 1] = {
    file = scope.file,
    relative_file = scope.relative_file,
    line = token.line,
    start_pos = token.start_pos,
    end_pos = token.end_pos,
    original_text = source:sub(token.start_pos, token.end_pos),
    replacement_text = replacement,
    description = description,
    scope_id = scope.id,
  }
end

local function is_unary_minus(tokens, index)
  local prev = previous_token(tokens, index)
  if not prev then
    return true
  end
  return expression_breakers[prev.value] == true
end

local function match_call(tokens, index)
  local token = tokens[index]
  if not token or token.type ~= "identifier" then
    return nil
  end
  local start_index = index
  while tokens[start_index - 1]
    and (tokens[start_index - 1].value == "." or tokens[start_index - 1].value == ":")
    and tokens[start_index - 2]
    and tokens[start_index - 2].type == "identifier"
  do
    start_index = start_index - 2
  end
  if start_index ~= index then
    return nil
  end
  local before = tokens[start_index - 1]
  if before and before.value == "function" then
    return nil
  end
  local cursor = index + 1
  while tokens[cursor] and (tokens[cursor].value == "." or tokens[cursor].value == ":") do
    if not tokens[cursor + 1] or tokens[cursor + 1].type ~= "identifier" then
      return nil
    end
    cursor = cursor + 2
  end
  if not tokens[cursor] or tokens[cursor].value ~= "(" then
    return nil
  end
  local depth = 0
  local finish = cursor
  while tokens[finish] do
    if tokens[finish].value == "(" then
      depth = depth + 1
    elseif tokens[finish].value == ")" then
      depth = depth - 1
      if depth == 0 then
        break
      end
    end
    finish = finish + 1
  end
  if not tokens[finish] or tokens[finish].value ~= ")" then
    return nil
  end
  return start_index, finish
end

-- A call in statement position can only be replaced by a statement, so the
-- call -> nil site is only offered when the previous token proves expression
-- position. Statement openers (`then`, `do`, `;`, chunk start) are absent.
local call_expression_preceders = {
  ["("] = true,
  ["{"] = true,
  ["["] = true,
  [","] = true,
  ["="] = true,
  ["=="] = true,
  ["~="] = true,
  ["<"] = true,
  ["<="] = true,
  [">"] = true,
  [">="] = true,
  ["+"] = true,
  ["-"] = true,
  ["*"] = true,
  ["/"] = true,
  ["//"] = true,
  ["<<"] = true,
  [">>"] = true,
  ["%"] = true,
  ["^"] = true,
  ["~"] = true,
  ["#"] = true,
  [".."] = true,
  ["and"] = true,
  ["or"] = true,
  ["not"] = true,
  ["return"] = true,
  ["elseif"] = true,
  ["until"] = true,
}

local function is_expression_call(tokens, index)
  local prev = previous_token(tokens, index)
  if not prev then
    return false
  end
  return call_expression_preceders[prev.value] == true
end

local function add_call_site(sites, scopes, source, tokens, start_index, end_index)
  local start_token = tokens[start_index]
  local end_token = tokens[end_index]
  local scope = assign_scope(scopes, start_token.start_pos)
  local original_text = source:sub(start_token.start_pos, end_token.end_pos)
  sites[#sites + 1] = {
    file = scope.file,
    relative_file = scope.relative_file,
    line = start_token.line,
    start_pos = start_token.start_pos,
    end_pos = end_token.end_pos,
    original_text = original_text,
    replacement_text = "nil",
    description = "replace " .. original_text .. " with nil",
    scope_id = scope.id,
  }
end

function scanner.analyze(source_file, relative_file, source)
  -- analyze normalizes for its own position/slicing logic; lexer.tokenize
  -- normalizes again (idempotent no-op) so tokenize stays self-contained.
  source = util.normalize_newlines(source)
  local tokens = lexer.tokenize(source)
  local scopes = build_scopes(source_file, relative_file, source, tokens)
  for _, scope in ipairs(scopes) do
    scope.relative_file = relative_file
  end
  local sites = {}
  local index = 1
  while index <= #tokens do
    local token = tokens[index]
    if token.type == "keyword" then
      if token.value == "true" then
        add_site(sites, scopes, source, token, "false", "replace true with false")
      elseif token.value == "false" then
        add_site(sites, scopes, source, token, "true", "replace false with true")
      elseif token.value == "and" or token.value == "or" then
        local mutation = binary_replacements[token.value]
        add_site(sites, scopes, source, token, mutation.replacement, mutation.description)
      elseif token.value == "not" then
        add_site(sites, scopes, source, token, "", "replace not with removed not")
      end
    elseif token.type == "symbol" then
      local mutation = binary_replacements[token.value]
      if mutation then
        if token.value == "-" and is_unary_minus(tokens, index) then
          add_site(sites, scopes, source, token, "", "replace - with removed -")
        else
          add_site(sites, scopes, source, token, mutation.replacement, mutation.description)
        end
      end
    elseif token.type == "number" then
      if token.value == "0" then
        add_site(sites, scopes, source, token, "1", "replace 0 with 1")
      elseif token.value == "1" then
        add_site(sites, scopes, source, token, "0", "replace 1 with 0")
      end
    elseif token.type == "string" then
      add_site(sites, scopes, source, token, "nil", "replace " .. token.value .. " with nil")
    elseif token.type == "identifier" then
      local start_index, end_index = match_call(tokens, index)
      if start_index and start_index == index and is_expression_call(tokens, start_index) then
        add_call_site(sites, scopes, source, tokens, start_index, end_index)
        index = end_index
      end
    end
    index = index + 1
  end
  table.sort(sites, function(left, right)
    if left.start_pos == right.start_pos then
      return left.end_pos < right.end_pos
    end
    return left.start_pos < right.start_pos
  end)
  local file_hash = util.fnv1a64(source)
  return {
    file = source_file,
    relative_file = relative_file,
    file_hash = file_hash,
    scopes = scopes,
    sites = sites,
  }
end

function scanner.apply_mutation(source, site)
  return source:sub(1, site.start_pos - 1) .. site.replacement_text .. source:sub(site.end_pos + 1)
end

return scanner
