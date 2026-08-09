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

-- operator tag → source lexeme, used to locate the operator token inside an
-- Op node. luacheck's Op node spans the whole operation expression (operands
-- included), so node.offset/end_offset cannot be spliced directly.
local operator_lexemes = {
  ["eq"] = "==", ["ne"] = "~=", ["lt"] = "<", ["le"] = "<=",
  ["gt"] = ">", ["ge"] = ">=", ["add"] = "+", ["sub"] = "-",
  ["mul"] = "*", ["div"] = "/", ["and"] = "and", ["or"] = "or",
  ["not"] = "not", ["unm"] = "-",
}

-- Names `type()` can return. Table fields keyed by anything else are never
-- hit by a `type()`-driven lookup, so flipping their `true` value is a
-- constructively dead write when the table is a type-name set (ADR-0001).
local TYPE_RETURN_NAMES = {
  ["nil"] = true,
  boolean = true,
  number = true,
  string = true,
  ["function"] = true,
  userdata = true,
  thread = true,
  table = true,
}

-- Common extensions hosts add to type-name sets (Lua has no "integer"/"fixed"
-- type() result; Fixed userdata etc. show up under these keys).
local TYPE_NAME_EXTENSIONS = {
  integer = true,
  float = true,
  double = true,
  fixed = true,
  int = true,
  long = true,
  num = true,
  bool = true,
}

-- Blank out Lua comments in a source slice, preserving byte positions, so a
-- plain find cannot land on operator lookalikes inside comments (e.g. the
-- dashes of a long-comment opener sitting before a binary "-").
local function blank_comments(text)
  text = text:gsub("%-%-%[=*%[.-%]%=*%]", function(comment)
    return (" "):rep(#comment)
  end)
  text = text:gsub("%-%-[^\n]*", function(comment)
    return (" "):rep(#comment)
  end)
  return text
end

-- Locate the operator token of an Op node (byte offsets, inclusive).
-- Unary prefix operators sit at the node start; binary operators sit in the
-- gap between the two operands. Besides whitespace the gap can only contain
-- comments, so after blanking comments the first remaining occurrence of the
-- lexeme is the operator token.
local function operator_range(source, node)
  local op = node[1]
  local lexeme = operator_lexemes[op]
  if not lexeme then
    return nil, nil
  end
  if op == "not" or op == "unm" then
    return node.offset, node.offset + #lexeme - 1
  end
  local left, right = node[2], node[3]
  if type(left) ~= "table" or type(right) ~= "table" then
    return nil, nil
  end
  local gap_start = left.end_offset + 1
  local gap_end = right.offset - 1
  if gap_end < gap_start then
    return nil, nil
  end
  local gap = blank_comments(source:sub(gap_start, gap_end))
  local token_start, token_end = gap:find(lexeme, 1, true)
  if not token_start then
    return nil, nil
  end
  return gap_start + token_start - 1, gap_start + token_end - 1
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

-- ── suppress-when helpers (ADR-0001) ──────────────────────────────────────

local function pair_key_name(key_node)
  if type(key_node) ~= "table" then
    return nil
  end
  if key_node.tag == "String" or key_node.tag == "Id" then
    return key_node[1]
  end
  return nil
end

-- A table used as a type-name set: every Pair value is `true`, every key is
-- either a type() return name or a known numeric-type extension, and at least
-- one extension key is present (distinguishes `{number=true, integer=true}`
-- from a plain feature-flag table that happens to use a type() name).
local function is_type_name_set_table(table_node)
  if type(table_node) ~= "table" or table_node.tag ~= "Table" then
    return false
  end
  local has_pair = false
  local has_extension = false
  for _, child in ipairs(table_node) do
    if type(child) == "table" and child.tag == "Pair" then
      has_pair = true
      local key_name = pair_key_name(child[1])
      local value = child[2]
      if not key_name or type(value) ~= "table" or value.tag ~= "True" then
        return false
      end
      if not TYPE_RETURN_NAMES[key_name] and not TYPE_NAME_EXTENSIONS[key_name] then
        return false
      end
      if TYPE_NAME_EXTENSIONS[key_name] then
        has_extension = true
      end
    end
  end
  return has_pair and has_extension
end

local function is_type_call(node)
  return type(node) == "table"
    and node.tag == "Call"
    and type(node[1]) == "table"
    and node[1].tag == "Id"
    and node[1][1] == "type"
end

-- Callee of `string.sub` / `string.byte` (Index form only; bare globals are
-- out of scope — hosts almost always write the qualified form).
local function string_lib_callee_name(callee)
  if type(callee) ~= "table" or callee.tag ~= "Index" then
    return nil
  end
  local base, key = callee[1], callee[2]
  if type(base) ~= "table" or base.tag ~= "Id" or base[1] ~= "string" then
    return nil
  end
  if type(key) ~= "table" then
    return nil
  end
  if key.tag == "String" or key.tag == "Id" then
    return key[1]
  end
  return nil
end

-- Function body is a pure type-name-set membership check:
--   return <type_name_set_local>[x] == true
local function is_typename_checker_func(func_node, type_name_set_locals)
  if type(func_node) ~= "table" or func_node.tag ~= "Function" then
    return false
  end
  local body = func_node[2]
  if type(body) ~= "table" or #body ~= 1 then
    return false
  end
  local stmt = body[1]
  if type(stmt) ~= "table" or stmt.tag ~= "Return" or #stmt ~= 1 then
    return false
  end
  local expr = stmt[1]
  if type(expr) ~= "table" or expr.tag ~= "Op" or expr[1] ~= "eq" then
    return false
  end
  local left, right = expr[2], expr[3]
  local index_node, true_node
  if type(left) == "table" and left.tag == "Index" and type(right) == "table" and right.tag == "True" then
    index_node, true_node = left, right
  elseif type(right) == "table" and right.tag == "Index" and type(left) == "table" and left.tag == "True" then
    index_node, true_node = right, left
  else
    return false
  end
  if true_node == nil then
    return false
  end
  local base = index_node[1]
  return type(base) == "table" and base.tag == "Id" and type_name_set_locals[base[1]] == true
end

-- Collect module-level facts a suppress-when predicate may need: which locals
-- hold type-name-set tables, which locals are assigned from type(), and which
-- local functions are pure type-name membership checkers.
local function collect_suppress_context(chunk)
  local type_name_set_locals = {}
  local type_result_locals = {}
  local local_funcs = {}
  local typename_checker_funcs = {}

  local function register_assignment(names, values)
    if type(names) ~= "table" or type(values) ~= "table" then
      return
    end
    for i, name_node in ipairs(names) do
      if type(name_node) == "table" and name_node.tag == "Id" then
        local value = values[i]
        if type(value) == "table" then
          if value.tag == "Table" and is_type_name_set_table(value) then
            type_name_set_locals[name_node[1]] = true
          elseif is_type_call(value) then
            type_result_locals[name_node[1]] = true
          elseif value.tag == "Function" then
            local_funcs[name_node[1]] = value
          end
        end
      end
    end
  end

  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    local tag = node.tag
    if tag == "Local" or tag == "Set" then
      register_assignment(node[1], node[2])
    elseif tag == "Localrec" then
      -- local function f() ... end  →  names + function values, mutually recursive
      register_assignment(node[1], node[2])
    end
    for _, child in ipairs(node) do
      walk(child)
    end
  end

  walk(chunk)

  for name, func_node in pairs(local_funcs) do
    if is_typename_checker_func(func_node, type_name_set_locals) then
      typename_checker_funcs[name] = true
    end
  end

  return {
    type_name_set_locals = type_name_set_locals,
    type_result_locals = type_result_locals,
    typename_checker_funcs = typename_checker_funcs,
  }
end

-- True when `node` is `type(<id>)` and <id> names a formal parameter of the
-- function currently being walked (ctx.param_names). Distinguishes the
-- to_integer entry `type(value) == "string"` (F3 #58/#60, value is a param,
-- fallthrough re-parses via tostring) from inner guards like
-- `type(as_text) == "string"` (as_text is a local — killable).
local function is_type_of_param(node, ctx)
  if not is_type_call(node) then
    return false
  end
  local arg = node[2]
  return type(arg) == "table" and arg.tag == "Id"
    and ctx.param_names and ctx.param_names[arg[1]] == true
end

-- suppress-when predicate chain. Each predicate sees node / parent / source /
-- replacement (and the module-level ctx). First match wins; the site is not
-- emitted. Order is irrelevant for correctness but kept stable for review.
local function should_suppress_equivalent(node, parent, source, replacement, ctx)
  if type(node) ~= "table" then
    return false
  end

  -- (1) string.sub / string.byte start argument: 1 → 0 is a Lua 5.4 no-op
  --     (start < 1 normalises to 1). Covers F3 #42.
  if node.tag == "Number" and node[1] == "1" and replacement == "0"
    and type(parent) == "table" and parent.tag == "Call"
  then
    local lib = string_lib_callee_name(parent[1])
    if lib == "sub" or lib == "byte" then
      -- Call layout: [1]=callee, [2]=subject, [3]=start, [4]=stop?
      if parent[3] == node then
        return true
      end
    end
  end

  -- (2) true → false on a field of a type-name-set table. Keys outside
  --     type()'s return set are dead under type()-driven lookup (#3/#4);
  --     keys inside it are still dead when the table also carries extension
  --     keys that mark it as a type-name set rather than a feature flag (#2).
  if node.tag == "True" and replacement == "false"
    and type(parent) == "table" and parent.tag == "Pair" and parent[2] == node
  then
    local table_node = ctx.pair_to_table[parent]
    if table_node and is_type_name_set_table(table_node) then
      return true
    end
  end

  -- (3) true → false on the RHS of `<type_name_set_local>[k] == true`.
  --     Membership flip is masked by the host's numeric fallback (F3 #6).
  if node.tag == "True" and replacement == "false"
    and type(parent) == "table" and parent.tag == "Op"
    and (parent[1] == "eq" or parent[1] == "ne")
  then
    local other = (parent[2] == node) and parent[3] or parent[2]
    if type(other) == "table" and other.tag == "Index" then
      local base = other[1]
      if type(base) == "table" and base.tag == "Id"
        and ctx.type_name_set_locals[base[1]]
      then
        return true
      end
    end
  end

  -- (4a) "nil" → nil against a type() result (call or local). type() returns
  --      the string "nil" for nil values, never the nil value itself, so the
  --      comparison becomes always-false; nil inputs still take the same
  --      fallthrough in the F3 #21 shape (is_numeric-style nil guard).
  -- (4b) any type-name string → nil against type(<param>) only. Narrowed to
  --      params so inner `type(local) == "string"` guards (killable) stay.
  --      Covers F3 #60; deliberately does not cover type-result locals of
  --      the same shape (F3 load-phase killable #26).
  if node.tag == "String" and replacement == "nil"
    and type(parent) == "table" and parent.tag == "Op"
    and (parent[1] == "eq" or parent[1] == "ne")
  then
    local other = (parent[2] == node) and parent[3] or parent[2]
    if node[1] == "nil" then
      if is_type_call(other) then
        return true
      end
      if type(other) == "table" and other.tag == "Id"
        and ctx.type_result_locals[other[1]]
      then
        return true
      end
    elseif TYPE_RETURN_NAMES[node[1]] and is_type_of_param(other, ctx) then
      return true
    end
  end

  -- (5) type(<param>) → nil inside == / ~=. Same always-false shape as (4b)
  --     from the call side (F3 #58). Requires param so `type(local)` in an
  --     inner guard (e.g. after tostring) is not swept up.
  if replacement == "nil" and is_type_of_param(node, ctx)
    and type(parent) == "table" and parent.tag == "Op"
    and (parent[1] == "eq" or parent[1] == "ne")
  then
    return true
  end

  -- (6) Call → nil of a pure type-name-set membership checker. The call only
  --     short-circuits a path the host re-derives via numeric fallback
  --     (F3 #23: `_is_numeric_type_name(value_type)`).
  if replacement == "nil" and type(node) == "table" and node.tag == "Call" then
    local callee = node[1]
    if type(callee) == "table" and callee.tag == "Id"
      and ctx.typename_checker_funcs[callee[1]]
    then
      return true
    end
  end

  return false
end

local function add_site(sites, scopes, source, node, replacement, description, start_pos, end_pos, ctx, parent, counter)
  if ctx and should_suppress_equivalent(node, parent, source, replacement, ctx) then
    counter.suppressed = counter.suppressed + 1
    return
  end
  start_pos = start_pos or node.offset
  end_pos = end_pos or node.end_offset
  local scope = assign_scope(scopes, start_pos, end_pos)
  sites[#sites + 1] = {
    file = scope.file,
    relative_file = scope.relative_file,
    line = node.line or 0,
    start_pos = start_pos,
    end_pos = end_pos,
    original_text = source:sub(start_pos, end_pos),
    replacement_text = replacement,
    description = description,
    scope_id = scope.id,
  }
end

-- Detect call-sugar form `f "x"` / `a:b "x"`: the AST shape is identical to
-- the parenthesized call, but splicing nil for the string yields `f nil`,
-- which is not valid Lua (sugar accepts only string/table literals). The
-- forms are told apart by the absence of "(" between callee and argument.
local function is_call_sugar_string(source, parent, node)
  if type(parent) ~= "table" then
    return false
  end
  local callee
  if parent.tag == "Call" and parent[2] == node then
    callee = parent[1]
  elseif parent.tag == "Invoke" and parent[3] == node then
    callee = parent[2]
  else
    return false
  end
  if type(callee) ~= "table" then
    return false
  end
  local between = source:sub(callee.end_offset + 1, node.offset - 1)
  return not between:find("(", 1, true)
end

-- Walk the AST for mutation sites.
-- `in_expr` tracks whether the current node is in expression context:
--   false → direct child of a statement list (chunk / block body)
--   true  → child of an expression-bearing slot
-- `parent` is the immediate parent node, used to suppress Call→nil sites
-- whose nil would be indexed or called (a syntax error, not a mutant), and
-- by suppress-when predicates that need the parent shape.
-- `ctx.param_names` is the formal-parameter set of the enclosing Function
-- (nil at chunk level); nested functions replace it for their body.
local function walk_mutations(node, in_expr, sites, scopes, source, parent, ctx, counter)
  if type(node) ~= "table" then
    return
  end

  local tag = node.tag

  -- Record Pair→Table so suppress-when can see the enclosing constructor
  -- without threading grandparent through every call.
  if tag == "Table" then
    for _, child in ipairs(node) do
      if type(child) == "table" and child.tag == "Pair" then
        ctx.pair_to_table[child] = node
      end
    end
  end

  -- Entering a Function: swap param_names for the duration of this node so
  -- suppress-when can tell type(<param>) from type(<local>).
  local saved_params = ctx.param_names
  if tag == "Function" then
    local params = {}
    local param_list = node[1]
    if type(param_list) == "table" then
      for _, p in ipairs(param_list) do
        if type(p) == "table" and p.tag == "Id" then
          params[p[1]] = true
        end
      end
    end
    ctx.param_names = params
  end

  -- Literal mutations
  if tag == "True" then
    add_site(sites, scopes, source, node, "false", "replace true with false", nil, nil, ctx, parent, counter)
  elseif tag == "False" then
    add_site(sites, scopes, source, node, "true", "replace false with true", nil, nil, ctx, parent, counter)
  elseif tag == "Nil" then
    -- nil is not mutated
  elseif tag == "Number" then
    -- luacheck stores numeric literals as their source-string form.
    if node[1] == "0" then
      add_site(sites, scopes, source, node, "1", "replace 0 with 1", nil, nil, ctx, parent, counter)
    elseif node[1] == "1" then
      add_site(sites, scopes, source, node, "0", "replace 1 with 0", nil, nil, ctx, parent, counter)
    end
  elseif tag == "String" then
    -- luacheck reuses the String tag for dot-syntax index keys (`a.b`),
    -- method names (`a:b()`), and bare table-constructor keys (`{k = v}`);
    -- those spans hold a bare identifier and splicing nil there yields a
    -- syntax-error mutant that any suite trivially kills. Only genuine
    -- literals (span starts with a quote or long-bracket) are mutated;
    -- bracket-form keys (`a["b"]`, `{["k"] = v}`) keep their quotes in the
    -- span and stay valid mutation targets.
    local first = source:sub(node.offset, node.offset)
    if (first == '"' or first == "'" or first == "[")
      and not is_call_sugar_string(source, parent, node)
    then
      add_site(sites, scopes, source, node, "nil",
        "replace " .. (node[1] or "") .. " with nil", nil, nil, ctx, parent, counter)
    end

  -- Operator mutations
  elseif tag == "Op" then
    local op = node[1]
    if op == "not" then
      local op_start, op_end = operator_range(source, node)
      if op_start then
        add_site(sites, scopes, source, node, "", "replace not with removed not",
          op_start, op_end, ctx, parent, counter)
      end
    elseif op == "unm" then
      -- unary minus: no disambiguation needed (binary minus is "sub")
      local op_start, op_end = operator_range(source, node)
      if op_start then
        add_site(sites, scopes, source, node, "", "replace - with removed -",
          op_start, op_end, ctx, parent, counter)
      end
    else
      local mapping = binary_replacements[op]
      if mapping then
        local op_start, op_end = operator_range(source, node)
        if op_start then
          add_site(sites, scopes, source, node, mapping.replacement, mapping.description,
            op_start, op_end, ctx, parent, counter)
        end
      end
    end

  -- Call expression → nil (expression position only). Skipped when the call
  -- result is immediately indexed, method-called, or called again: replacing
  -- the call with nil there produces `nil.x` / `nil:m()` / `nil()` — a
  -- syntax-error mutant any suite trivially kills, not a real mutant.
  elseif tag == "Call" and in_expr then
    local chained = type(parent) == "table"
      and (parent.tag == "Index" or parent.tag == "Invoke" or parent.tag == "Call")
      and parent[1] == node
    if not chained then
      local original_text = source:sub(node.offset, node.end_offset)
      add_site(sites, scopes, source, node, "nil",
        "replace " .. original_text .. " with nil",
        node.offset, node.end_offset, ctx, parent, counter)
    end
  end

  -- Recurse into children with context-sensitive `in_expr`.
  if not tag then
    -- Tagless array: inherits context from parent. Statement lists
    -- (chunk, block bodies) are entered from `in_expr=false`; expression
    -- lists (inside Local, Set, Return, etc.) are entered from
    -- `in_expr=true`.
    for _, child in ipairs(node) do
      walk_mutations(child, in_expr, sites, scopes, source, node, ctx, counter)
    end
    ctx.param_names = saved_params
    return
  end

  -- Tagged node: determine per-child context.
  for i, child in ipairs(node) do
    if type(child) ~= "table" then
      goto continue_child
    end

    local child_expr = true

    -- Statement-list bodies are always tagless arrays; conditions and
    -- sub-expressions are tagged nodes. (If without this rule misclassified
    -- else blocks — they sit at an odd last index — as expression context,
    -- and Fornum/Repeat wrongly suppressed their bound/condition sites.)
    if tag == "Function" or tag == "If" or tag == "While"
      or tag == "Fornum" or tag == "Repeat" or tag == "Do"
    then
      if child.tag == nil then
        child_expr = false
      end
    elseif tag == "Forin" then
      -- [1] = vars, [2] = iterator exprs, [3] = body (stmt-list, last child);
      -- all three are tagless arrays, so position decides.
      if i == #node then
        child_expr = false
      end
    end

    walk_mutations(child, child_expr, sites, scopes, source, node, ctx, counter)

    ::continue_child::
  end

  ctx.param_names = saved_params
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

  -- Discover mutation sites from the AST (with suppress-when filtering).
  local suppress_ctx = collect_suppress_context(chunk)
  suppress_ctx.pair_to_table = {}
  local counter = {suppressed = 0}
  local sites = {}
  walk_mutations(chunk, false, sites, scopes, source, nil, suppress_ctx, counter)

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
    suppressed_equivalent = counter.suppressed,
  }
end

function scanner.apply_mutation(source, site)
  return source:sub(1, site.start_pos - 1) .. site.replacement_text .. source:sub(site.end_pos + 1)
end

return scanner
