-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- A simulated networked fight in one program (OpenLF2 extension, docs/netcode.md step 2, developer option
-- --net-sim): two clients with prediction and rollback (base/game/rollback_client) and a server
-- (base/game/authority), each with its own copy of the fight, joined by simulated links (base/game/net_link) with
-- delay, jitter and loss. Client A owns player slot 1 and the function keys, and the screen shows its fight. Client B
-- owns the other slots, so a second player on the same keyboard plays through the simulated network too.
local match = require("base/game/match")
local authority = require("base/game/authority")
local rollback_client = require("base/game/rollback_client")
local net_link = require("base/game/net_link")
local ticks = require("base/game/ticks")
local netsim = {}

-- The parameters of --net-sim, or nil when it is off (set by base/ui/flow).
netsim.params = nil

-- "delay=80,jitter=20,loss=5,seed=7": milliseconds, milliseconds, percent, a whole number.
function netsim.parse(text)
    if type(text) ~= "string" then return nil end
    local params = {delay = 0, jitter = 0, loss = 0, seed = 1}
    for name, value in text:gmatch("(%a+)=(%d+%.?%d*)") do
        if params[name] then params[name] = tonumber(value) end
    end
    return params
end

-- Creates the session around `main`, the fight of the screen, which match.create just made from `options`. The other
-- copies start from the same random position, so that all three fights are the same.
-- `make_capture` gives each copy the screen's function that keeps what a tick draws (match.step calls it).
function netsim.create(main, options, start_random, make_capture)
    local after = {engine.random_position()}
    local function copy_fight()
        engine.set_random_position(start_random[1], start_random[2], start_random[3])
        local fight = match.create(options)
        fight.capture = make_capture()
        return fight
    end
    local other, truth = copy_fight(), copy_fight()
    engine.set_random_position(after[1], after[2], after[3])
    local params = netsim.params
    local owned_b = {}
    for slot = 1, 7 do owned_b[slot] = true end
    local session = {now = 0, params = params,
        clients = {
            a = rollback_client.create({id = "a", match = main, random = after, owned = {[0] = true}, owns_functions = true}),
            b = rollback_client.create({id = "b", match = other, random = after, owned = owned_b}),
        },
        server = authority.create({match = truth, random = after, function_owner = "a", clients = {"a", "b"},
            owners = {[0] = "a", "b", "b", "b", "b", "b", "b", "b"}}),
        up = {a = net_link.create(params, params.seed * 4 + 1), b = net_link.create(params, params.seed * 4 + 2)},
        down = {a = net_link.create(params, params.seed * 4 + 3), b = net_link.create(params, params.seed * 4 + 4)}}
    return session
end

-- One frame of 33 ms: messages arrive, the server runs its due ticks, each client takes its keys from `held` and runs.
-- Returns the sounds of client A, the results of its final ticks and the number of new ticks it ran.
function netsim.frame(session, held)
    session.now = session.now + ticks.tick_ms
    local now = session.now
    for id, link in pairs(session.up) do
        for _, message in ipairs(net_link.receive(link, now)) do authority.receive(session.server, message, now) end
    end
    for id, message in pairs(authority.update(session.server, now)) do net_link.send(session.down[id], now, message) end
    local a, b = ticks.empty(), ticks.empty()
    a.slots[0], a.functions, a.function_presses = held[0] or "", held.functions or "", held.function_presses or ""
    for slot = 1, 7 do b.slots[slot] = held[slot] or "" end
    rollback_client.sample(session.clients.a, a)
    rollback_client.sample(session.clients.b, b)
    for id, client in pairs(session.clients) do
        for _, message in ipairs(net_link.receive(session.down[id], now)) do rollback_client.receive(client, message, now) end
        rollback_client.update(client, now)
        net_link.send(session.up[id], now, rollback_client.message(client, now))
    end
    local main = session.clients.a
    -- The rest of the frame (the screens) continues with client A's random position.
    engine.set_random_position(main.random[1], main.random[2], main.random[3])
    rollback_client.take(session.clients.b)
    local played, results = rollback_client.take(main)
    return played, results, main.new_ticks
end

-- The overlays read the newest final state of client A (rollback_client.confirmed_view).
function netsim.confirmed(session)
    return rollback_client.confirmed_view(session.clients.a)
end

-- For headless descriptions: each client's tick, final tick, rollbacks (count, ticks, longest), waits and hash
-- checks; the server's tick and its late and predicted inputs; the round trip of client A.
function netsim.describe(session)
    local parts = {}
    for _, id in ipairs({"a", "b"}) do
        parts[#parts + 1] = id .. ":" .. rollback_client.describe(session.clients[id])
    end
    local server = session.server
    parts[#parts + 1] = string.format("server:tick=%d,late=%d,predicted=%d", server.tick, server.stats.late,
        server.stats.predicted)
    parts[#parts + 1] = string.format("rtt=%.0f", session.clients.a.rtt or -1)
    return "netsim=" .. table.concat(parts, ";")
end

return netsim
