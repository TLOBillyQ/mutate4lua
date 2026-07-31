local ast = require("mutate4lua.internal.ast")
local util = require("mutate4lua.util")

local scanner = {}

-- binary operator → replacement mapping (operator string → {replacement, description})
local binary_replacements = {
  ["eq"] = {replacement = "~=", description = "replace == with ~="},
  ["ne"] = {replacement = "==", description = "replace ~= with =="},
  ["lt"] = {replacement = "<=", description = "replace < with <="},
  ["le"] = {replacement = "<", description = "replace <= with <"},
  ["gt"] = {replacement = ">=", description = "replace > with >="},
  ["ge"] = {replacement = ">", description = "replace >= with >"},
  ["add"] = {replacement = "-", description = "replace + with -"},
  ["sub"] = {replacement = "+", description = "replace - with +"},
  ["mul"] = {replacement = "/", description = "replace * with /"},
  ["div"] = {replacement = "*", description = "replace / with *"},
  ["and"] = {replacement = "or", description = "replace and with or"},
  ["or"] = {replacement = "and", description = "replace or with and"},
}

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

-- Build scope entries from AST function nodes.
-- Declaration-based identity: stable id independent of line numbers;
-- duplicate names disambiguated by occurrence order.
local function build_scopes(source_file, relative_file, source, func_entries, chunk_node)
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

  -- Annotate each function entry with its resolved scope id (disambiguating
  -- duplicates by occurrence index).
  local name_counts = {}
  for _, entry in ipairs(func_entries) do
    local base_name = entry.name or "<anonymous>"
    local count = (name_counts[base_name] or 0) + 1
    name_counts[base_name] = count
    local id
    if count == 1 then
      id = "function:" .. base_name
    else
      id = "function:" .. base_name .. "#" .. count
    end
    entry.scope_id = id
  end

  -- Add function scopes (the chunk scope is always first).
  for _, entry in ipairs(func_entries) do
    scopes[#scopes + 1] = {
      id = entry.scope_id,
      kind = "function",
      start_line = entry.start_line,
      end_line = entry.end_line,
      start_pos = entry.start_pos,
      end_pos = entry.end_pos,
    }
  end

  -- Compute semantic hashes from normalized AST serialization.
  -- Scope hash = FNV-1a over format-insensitive normalized AST (ADR-0004).
  for _, scope in ipairs(scopes) do
    scope.file = source_file
    scope.relative_file = relative_file
    scope.semantic_hash = util.fnv1a64(ast.serialize(ast.normalize_node(scope._ast_subtree)))
  end

  return scopes
end

-- Assign a mutation site to the tightest enclosing scope by position.
local function assign_scope(scopes, start_pos, end_pos)
  local winner = scopes[1]
  local best_span = winner.end_pos - winner.start_pos
  for _, scope in ipairs(scopes) do
    if start_pos >= scope.start_pos and end_pos <= scope.end_pos then
      local span = scope.end_pos - scope.start_pos
      if span <= best_span then
        best_span = span
        winner = scope
      end
    end
  end
  return winner
end

local function add_site(sites, scopes, source, node, replacement, description)
  local scope = assign_scope(scopes, node.offset, node.end_offset)
  sites[#sites + 1] = {
    file = scope.file,
    relative_file = scope.relative_file,
    line = node.line or 0,
    start_pos = node.offset,
    end_pos = node.end_offset,
    original_text = source:sub(node.offset, node.end_offset),
    replacement_text = replacement,
    description = description,
    scope_id = scope.id,
  }
end

-- Walk the AST for mutation sites.
-- `in_expr` tracks whether the current node is in expression context:
--   false → direct child of a statement list (chunk / block body)
--   true  → child of an expression-bearing slot
local function walk_mutations(node, in_expr, sites, scopes, source)
  if type(node) ~= "table" then
    return
  end

  local tag = node.tag

  -- Literal mutations
  if tag == "True" then
    add_site(sites, scopes, source, node, "false", "replace true with false")
  elseif tag == "False" then
    add_site(sites, scopes, source, node, "true", "replace false with true")
  elseif tag == "Nil" then
    -- nil is not mutated
  elseif tag == "Number" then
    -- luacheck stores numeric literals as their source-string form.
    if node[1] == "0" then
      add_site(sites, scopes, source, node, "1", "replace 0 with 1")
    elseif node[1] == "1" then
      add_site(sites, scopes, source, node, "0", "replace 1 with 0")
    end
  elseif tag == "String" then
    add_site(sites, scopes, source, node, "nil", "replace " .. (node[1] or "") .. " with nil")

  -- Operator mutations
  elseif tag == "Op" then
    local op = node[1]
    if op == "not" then
      add_site(sites, scopes, source, node, "", "replace not with removed not")
    elseif op == "unm" then
      -- unary minus: no disambiguation needed (binary minus is "sub")
      add_site(sites, scopes, source, node, "", "replace - with removed -")
    else
      local mapping = binary_replacements[op]
      if mapping then
        add_site(sites, scopes, source, node, mapping.replacement, mapping.description)
      end
    end

  -- Call expression → nil (expression position only)
  elseif tag == "Call" and in_expr then
    local scope = assign_scope(scopes, node.offset, node.end_offset)
    local original_text = source:sub(node.offset, node.end_offset)
    sites[#sites + 1] = {
      file = scope.file,
      relative_file = scope.relative_file,
      line = node.line or 0,
      start_pos = node.offset,
      end_pos = node.end_offset,
      original_text = original_text,
      replacement_text = "nil",
      description = "replace " .. original_text .. " with nil",
      scope_id = scope.id,
    }
  end

  -- Recurse into children with context-sensitive `in_expr`.
  if not tag then
    -- Tagless array: inherits context from parent. Statement lists
    -- (chunk, block bodies) are entered from `in_expr=false`; expression
    -- lists (inside Local, Set, Return, etc.) are entered from
    -- `in_expr=true`.
    for _, child in ipairs(node) do
      walk_mutations(child, in_expr, sites, scopes, source)
    end
    return
  end

  -- Tagged node: determine per-child context.
  for i, child in ipairs(node) do
    if type(child) ~= "table" then
      goto continue_child
    end

    local child_expr = true

    if tag == "Function" then
      -- [1] = params (expr), [2+] = body (stmt-list)
      if i == 2 then
        child_expr = false
      end
    elseif tag == "If" then
      -- even-indexed children are blocks; odd are conditions
      if i % 2 == 0 then
        child_expr = false
      end
    elseif tag == "While" or tag == "Fornum" or tag == "Forin" or tag == "Repeat" then
      -- [1] = condition/expr, [2+] = body (stmt-list)
      if i >= 2 then
        child_expr = false
      end
    elseif tag == "Do" then
      -- [1] = body (stmt-list)
      child_expr = false
    end

    walk_mutations(child, child_expr, sites, scopes, source)

    ::continue_child::
  end
end

function scanner.analyze(source_file, relative_file, source)
  source = util.normalize_newlines(source)
  local chunk, err = ast.parse_source(source)
  if not chunk then
    error("parse error in " .. relative_file .. ": " .. tostring(err), 2)
  end

  local func_entries = ast.extract_functions(chunk)

  -- Build scopes with AST subtrees attached for hash computation.
  -- The chunk scope's subtree is the entire chunk AST.
  local scopes = {
    {
      id = "chunk:" .. relative_file,
      kind = "chunk",
      start_line = 1,
      end_line = line_count(source),
      start_pos = 1,
      end_pos = #source,
      file = source_file,
      relative_file = relative_file,
      _ast_subtree = chunk,
    }
  }

  local name_counts = {}
  for _, entry in ipairs(func_entries) do
    local base_name = entry.name or "<anonymous>"
    local count = (name_counts[base_name] or 0) + 1
    name_counts[base_name] = count
    local id
    if count == 1 then
      id = "function:" .. base_name
    else
      id = "function:" .. base_name .. "#" .. count
    end
    scopes[#scopes + 1] = {
      id = id,
      kind = "function",
      start_line = entry.start_line,
      end_line = entry.end_line,
      start_pos = entry.start_pos,
      end_pos = entry.end_pos,
      file = source_file,
      relative_file = relative_file,
      _ast_subtree = entry.node,
    }
  end

  -- Compute semantic hashes
  for _, scope in ipairs(scopes) do
    scope.semantic_hash = util.fnv1a64(ast.serialize(ast.normalize_node(scope._ast_subtree)))
    scope._ast_subtree = nil  -- not needed after hashing
  end

  -- Discover mutation sites from the AST
  local sites = {}
  walk_mutations(chunk, false, sites, scopes, source)

  -- Sort sites by position (consistent with the original lexer-based order)
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
