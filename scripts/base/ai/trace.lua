-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The debug trace of the AI (OpenLF2 extension, docs/ai-plan.md "Logs for agents"): a side channel that the brains
-- write and the AI log and the development view read. It lives outside the match table on purpose: a brain never
-- reads it, so it cannot change a fight. It follows one fight (the one that the screen shows). A tick that runs again
-- after a rollback drops the entries of that tick and of later ones, so the log writes each tick once.
local trace = {on = false, capture = false, frames_log = false, observe = false}
-- The development view's store (base/ui/ai_view), filled while `capture` is on: the last brain frame of each fighter,
-- its last 30 events, and its intent on each of the last 300 ticks.
trace.frames, trace.recent, trace.timeline = {}, {}, {}
local timeline_ticks, recent_count = 300, 30
trace.timeline_ticks = timeline_ticks
local line_limit = 500 -- an engine log line holds at most 512 bytes ("log " and the text)

local filter     -- nil for all fighters, or a set of item indices (--ai-log 11,12)
local watched    -- the match table of the fight that the trace follows
local margin = 0 -- ticks that can still run again (a rollback), so they wait before the log writes them
local entries, ready = {}, {}
local last_tick = -1

-- `text`: the value of --ai-log, "all" or item indices like "11,12", and "frames" for the brain frames (a line for each
-- think); nil turns the log off.
function trace.configure(text)
    trace.on = type(text) == "string" and text ~= ""
    trace.frames_log = trace.on and text:find("frames", 1, true) ~= nil
    -- `observe`: the situation and the keys of every fighter (base/ai/features), the data of imitation.
    trace.observe = trace.on and text:find("observe", 1, true) ~= nil
    filter = nil
    if trace.on and text:find("%d") then
        filter = {}
        for number in text:gmatch("%d+") do filter[tonumber(number)] = true end
    end
end

-- Starts to follow `match`. `rollback` is true when the fight can run ticks again (a network fight, --net-sim,
-- --rollback-check). The entries of the previous fight go to the log on the next flush.
function trace.watch(match, rollback)
    for _, entry in ipairs(entries) do ready[#ready + 1] = entry.line end
    entries, last_tick = {}, -1
    trace.frames, trace.recent, trace.timeline = {}, {}, {}
    watched = match
    -- More than a client runs ahead of its newest final tick (base/game/rollback_client) and than a rollback check
    -- runs again.
    margin = rollback and 32 or 0
end

-- Whether `match` is the fight that the trace follows.
function trace.watching(match) return match == watched end

-- Whether the brain of item `index` in `match` writes to the trace (the log, or the store of the view).
function trace.active(match, index)
    if match ~= watched then return false end
    return trace.capture or (trace.on and (filter == nil or filter[index] == true))
end

-- Called once per tick before the brains run: a tick that is not newer than the last one runs again.
function trace.begin_tick(match)
    if match ~= watched then return end
    local tick = match.frame_number
    if tick <= last_tick then
        local kept = {}
        for _, entry in ipairs(entries) do
            if entry.tick < tick then kept[#kept + 1] = entry end
        end
        entries = kept
    end
    last_tick = tick
end

-- One event of item `index`: `text` holds "key=value" pairs, for example "ev=target to=0".
function trace.add(match, index, text)
    local line = string.format("ai t=%d i=%d %s", match.frame_number, index, text)
    -- The engine accepts printable ASCII only.
    line = line:gsub("[^\32-\126]", "?")
    if #line > line_limit then line = line:sub(1, line_limit) end
    if trace.on and (filter == nil or filter[index] == true) then entries[#entries + 1] = {tick = match.frame_number, line = line} end
    if trace.capture then
        local list = trace.recent[index] or {}
        trace.recent[index] = list
        list[#list + 1] = line
        if #list > recent_count then table.remove(list, 1) end
    end
end

-- A brain frame of item `index` (base/ai/brains/tactician): a table {intent, intent_name, path, target, candidates,
-- ...}. The view keeps the last one; `frames` in --ai-log writes `text` as a log line too.
function trace.frame(match, index, frame, text)
    if match ~= watched then return end
    if trace.capture then
        trace.frames[index] = frame
        local line = trace.timeline[index] or {}
        trace.timeline[index] = line
        line[match.frame_number % timeline_ticks + 1] = frame.intent or 0
        line.last = match.frame_number
    end
    if trace.frames_log and text then trace.add(match, index, "ev=frame " .. text) end
end

-- Writes the entries that no rollback can change any more as engine log lines; `final` writes all of them (the fight
-- ended or the screen changed). Call it after the network exchange, because a frame that waits for the server loses
-- its commands.
function trace.flush(context, final)
    if not trace.on then return end
    for _, line in ipairs(ready) do context.action("log " .. line) end
    ready = {}
    local limit = final and math.huge or last_tick - margin
    local kept = {}
    for _, entry in ipairs(entries) do
        if entry.tick <= limit then context.action("log " .. entry.line) else kept[#kept + 1] = entry end
    end
    entries = kept
end
return trace
