-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Behavior trees of the AI (OpenLF2 extension, docs/ai-plan.md "Decisions"): a tactic is a tree of data tables, so the
-- development view can draw it and a fighter kit can add steps.
--
-- A node: {id (a small number, unique in its tree), name, kind, children, run}. Kinds:
--   selector: runs its children in order until one does not fail;
--   sequence: runs its children in order until one does not succeed;
--   condition: run(context, board) returns true or false;
--   action: run(context, board) returns "success", "failure" or "running".
-- tree.run returns the result and writes the ids of the nodes on the chosen path into `path` (an array of the memory,
-- updated in place).
local tree = {}

function tree.selector(id, name, children) return {id = id, name = name, kind = "selector", children = children} end
function tree.sequence(id, name, children) return {id = id, name = name, kind = "sequence", children = children} end
function tree.condition(id, name, run) return {id = id, name = name, kind = "condition", run = run} end
function tree.action(id, name, run) return {id = id, name = name, kind = "action", run = run} end

local function visit(node, context, board, path)
    path[#path + 1] = node.id
    local kind = node.kind
    if kind == "condition" then return node.run(context, board) and "success" or "failure" end
    if kind == "action" then return node.run(context, board) or "failure" end
    local mark = #path
    for _, child in ipairs(node.children) do
        local result = visit(child, context, board, path)
        if kind == "selector" and result ~= "failure" then return result end
        if kind == "sequence" and result ~= "success" then return result end
        -- A child that did not decide leaves the path.
        for position = #path, mark + 1, -1 do path[position] = nil end
    end
    return kind == "selector" and "failure" or "success"
end

-- Runs `root` and writes the chosen path into `path` (cleared first).
function tree.run(root, context, board, path)
    for position = #path, 1, -1 do path[position] = nil end
    return visit(root, context, board, path)
end

-- The names of the nodes of a tree by id, for the log and the view.
function tree.names(root, names)
    names = names or {}
    names[root.id] = root.name
    for _, child in ipairs(root.children or {}) do tree.names(child, names) end
    return names
end
return tree
