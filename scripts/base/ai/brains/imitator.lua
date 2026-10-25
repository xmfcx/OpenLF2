-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain `imitator` (docs/ai-plan.md phase 13): it plays like the fighters whose play tools/ai-imitate.py learned
-- from (`--ai-log observe` logs of recorded or arena fights). On each tick where human keys change, it reads its
-- situation (base/ai/features), runs the integer network of base/ai/imitation (base/ai/net), and holds the keys of the
-- action that the network rates highest. A key that the action presses again goes up for one input tick first, so the
-- press is fresh. Without a trained network it stands still.
local actuator = require("base/ai/actuator")
local features = require("base/ai/features")
local net = require("base/ai/net")
local imitation = require("base/ai/imitation")
local imitator = {name = "imitator", version = 1, interface = 2}
local presses = 16 + 32 + 64 -- attack, jump, defend

function imitator.start(state, index, seed)
    local memory = {version = imitator.version, rng = seed, action = 0, actions = 0}
    actuator.start(memory)
    return memory
end

local inputs = {}
function imitator.tick(context)
    local memory, state, me = context.memory, context.state, context.me
    local network = imitation.network
    if network and me and (state.input_phase == 0 or context.row.rate == "fast") and not actuator.busy(memory) then
        local enemy = features.enemy_of(state, context.view, me)
        if enemy then
            features.of(me, enemy, context.self.mp, inputs)
            local action = imitation.actions[net.argmax(net.run(network, inputs))] or 0
            local keys = features.keys_of(action, enemy.x > me.x)
            local repeated = math.floor(keys / 16) % 8 > 0 and math.floor(memory.act_mask / 16) % 8 > 0
            if repeated then
                actuator.program(memory, {keys % 16, keys}, keys - math.floor(keys / 16) % 8 * 16)
            else
                actuator.hold(memory, keys)
            end
            if action ~= memory.action then memory.actions = memory.actions + 1 end
            memory.action = action
        end
    end
    actuator.tick(state, context.self, memory, context.row)
end

function imitator.describe(memory) return string.format("action:%d,changes:%d", memory.action, memory.actions) end
imitator.presses = presses
return imitator
