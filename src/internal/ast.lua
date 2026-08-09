-- Lua AST access via luacheck (runtime dependency, installed through LuaRocks).
-- Provides parsing, function extraction, and format-insensitive normalized
-- serialization for stable semantic hashing (ADR-0001/0004).
local ast = {}

local ok_decoder, decoder = pcall(require, "luacheck.decoder")
local ok_parser, parser = pcall(require, "luacheck.parser")

if not ok_decoder or not ok_parser then
  error("luacheck required: luarocks install luacheck", 0)
end

-- luacheck's decoder is Unicode-aware: when the source contains multi-byte
-- UTF-8 (e.g. Chinese comments/strings), parser node offsets (offset,
-- end_offset, and nested end_range) are codepoint indices, not byte indices.
-- Downstream splicing uses string.sub byte semantics, so convert every offset
-- in the parsed AST to byte offsets right at this boundary.
local function build_codepoint_byte_map(source)
  local map = {}
  local codepoint = 0
  for i = 1, #source do
    local b = source:byte(i)
    -- UTF-8 lead bytes are ASCII (< 0x80) or >= 0xC0; 0x80..0xBF are
    -- continuation bytes. The decoder already validated the source, so no
    -- malformed sequences reach this map.
    if b < 0x80 or b >= 0xC0 then
      codepoint = codepoint + 1
      map[codepoint] = i
    end
  end
  map[codepoint + 1] = #source + 1
  return map
end

local function convert_offsets_to_bytes(node, map)
  if type(node) ~= "table" then
    return
  end
  local offset, end_offset = node.offset, node.end_offset
  if type(offset) == "number" and type(end_offset) == "number"
    and map[offset] and map[end_offset + 1]
  then
    -- end_offset is an inclusive codepoint index; the inclusive byte index is
    -- one byte before the start of the next codepoint.
    node.offset = map[offset]
    node.end_offset = map[end_offset + 1] - 1
  end
  for _, child in pairs(node) do
    convert_offsets_to_bytes(child, map)
  end
end

function ast.parse_source(source)
  local chars = decoder.decode(source)
  local ok, parsed = pcall(parser.parse, chars)
  if not ok then
    return nil, tostring(parsed)
  end
  if not parsed then
    return nil, "parse error"
  end
  -- LatinChars (pure-ASCII or undecodable bytes) already indexes by bytes;
  -- only UnicodeChars needs the conversion.
  if chars:get_length() ~= #source then
    convert_offsets_to_bytes(parsed, build_codepoint_byte_map(source))
  end
  return parsed
end

-- Resolve a target node to its name path (e.g. "M.foo" for Index nodes).
-- Used for named function declarations; never returns nil-anonymous.
local function target_name(target)
  if type(target) ~= "table" then
    return nil
  end
  if target.tag == "Id" then
    return target[1]
  end
  if target.tag == "Index" then
    local left = target_name(target[1])
    local key = target[2]
    local right = nil
    if type(key) == "table" and (key.tag == "Id" or key.tag == "String") then
      right = key[1]
    end
    if left and right then
      return left .. "." .. right
    end
  end
  return nil
end

-- Check whether a Function node's first parameter is implicit self (colon
-- method syntax).  In luacheck AST, `function M:baz(x)` adds an Id node with
-- `implicit = true` for the `self` parameter; `function M.foo(x)` does not.
local function has_implicit_self(func_node)
  local params = func_node[1]
  if type(params) ~= "table" or #params == 0 then
    return false
  end
  local first = params[1]
  return type(first) == "table" and first.tag == "Id" and first.implicit == true
end

-- Resolve the declared name of a Function node.
-- grandparent is the statement node (Localrec, Set, or Local).
-- Returns the dotted/colon name for named functions, nil for anonymous.
local function resolve_name(func_node, grandparent)
  if type(grandparent) ~= "table" then
    return nil
  end
  local tag = grandparent.tag
  if tag ~= "Set" and tag ~= "Localrec" and tag ~= "Local" then
    return nil
  end
  local targets, exprs = grandparent[1], grandparent[2]
  if type(targets) ~= "table" or type(exprs) ~= "table" then
    return nil
  end
  if #targets ~= 1 or #exprs ~= 1 then
    return nil
  end
  if tag == "Local" then
    -- local f = function() ... end  is anonymous
    return nil
  end

  local name = target_name(targets[1])
  if not name then
    return nil
  end

  -- Colon-method syntax: replace the last "." with ":"
  if has_implicit_self(func_node) then
    local last_dot = name:match(".*%.")
    if last_dot then
      name = last_dot:sub(1, -2) .. ":" .. name:sub(#last_dot + 1)
    end
  end

  return name
end

local function walk_functions(node, parent, grandparent, entries)
  if type(node) ~= "table" then
    return
  end
  if node.tag == "Function" then
    local name = resolve_name(node, grandparent)
    local start_line = node.line or 0
    local end_line = (node.end_range and node.end_range.line) or start_line
    entries[#entries + 1] = {
      name = name,
      node = node,
      start_line = start_line,
      end_line = end_line,
      start_pos = node.offset,
      end_pos = node.end_offset,
    }
  end
  for _, child in ipairs(node) do
    if type(child) == "table" then
      walk_functions(child, node, parent, entries)
    end
  end
end

-- Returns an array of { name, node, start_line, end_line, start_pos, end_pos }
-- for every Function node in the chunk (named and anonymous, top-level and
-- nested).  name is nil for anonymous functions.
function ast.extract_functions(chunk)
  local entries = {}
  for _, statement in ipairs(chunk) do
    walk_functions(statement, nil, nil, entries)
  end
  return entries
end

-- Normalize an AST subtree for format-insensitive serialization.
-- Identifiers collapse to {tag="ident"}, literals collapse to their kind,
-- callee expressions become {tag="callee"}, operator tags include the operator
-- string (e.g. "op/add", "op/and").
local LITERAL_KINDS = {
  Number = "number",
  String = "string",
  True  = "boolean",
  False = "boolean",
  Nil   = "nil",
}

local function normalized_tag(node)
  local kind = LITERAL_KINDS[node.tag]
  if kind then
    return "literal/" .. kind
  end
  if node.tag == "Op" then
    return "op/" .. tostring(node[1])
  end
  return node.tag
end

function ast.normalize_node(node)
  if type(node) ~= "table" then
    return node
  end

  local tag = node.tag
  -- AST arrays (statement lists, expression lists, parameter lists) have
  -- no tag and preserve their ordered structure.
  if not tag then
    local normalized = {}
    for index = 1, #node do
      normalized[index] = ast.normalize_node(node[index])
    end
    return normalized
  end

  local normalized = { tag = normalized_tag(node) }

  if tag == "Id" then
    return { tag = "ident" }
  end

  if LITERAL_KINDS[tag] then
    return { tag = normalized.tag }
  end

  if tag == "Op" then
    for index = 2, #node do
      normalized[index - 1] = ast.normalize_node(node[index])
    end
    return normalized
  end

  if tag == "Call" then
    normalized[1] = { tag = "callee" }
    for index = 2, #node do
      normalized[index] = ast.normalize_node(node[index])
    end
    return normalized
  end

  -- Generic: normalize all children for any other tagged node.
  for index = 1, #node do
    normalized[index] = ast.normalize_node(node[index])
  end
  return normalized
end

local function serialize(node, buffer)
  if type(node) ~= "table" then
    buffer[#buffer + 1] = tostring(node)
    return
  end
  if not node.tag then
    buffer[#buffer + 1] = "("
    for index, child in ipairs(node) do
      if index > 1 then
        buffer[#buffer + 1] = " "
      end
      serialize(child, buffer)
    end
    buffer[#buffer + 1] = ")"
    return
  end
  buffer[#buffer + 1] = "("
  buffer[#buffer + 1] = tostring(node.tag)
  for _, child in ipairs(node) do
    buffer[#buffer + 1] = " "
    serialize(child, buffer)
  end
  buffer[#buffer + 1] = ")"
end

function ast.serialize(node)
  local buffer = {}
  serialize(node, buffer)
  return table.concat(buffer)
end

return ast
