-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The fighter kits of the AI (OpenLF2 extension, docs/ai-plan.md "Personas, difficulty and fighter kits"): what the
-- frames do not say about a fighter, and its personas. One table for each fighter id, in one module, so a mod can
-- replace or extend it (a module extension of base/ai/kits). docs/ai-moves.md lists the start frames.
--
-- A kit: {heal = the start frame of a self heal, personas = {persona...}}. A persona is the generic persona of the
-- tactician (base/ai/brains/tactician) with some numbers changed: aggression, risk, mp_thrift, combo_greed, mobility,
-- defense, teamwork (0 to 100), spacing and range (pixels: the distance to a free enemy, and a zoner's distance),
-- depth_offset, and `prefer` = {[start frame] = percent}: the value of a move rises (or falls, below 0) by that much.
-- Fighters without a kit, or a mod's new fighters, play the generic persona.
local kits = {}

local function persona(name, numbers)
    numbers.name = name
    return numbers
end

kits.by_id = {
    -- Deep
    [1] = {personas = {
        persona("swordsman", {aggression = 85, combo_greed = 80, prefer = {[260] = 40, [266] = 30}}),
        persona("dasher", {aggression = 75, mobility = 60, prefer = {[290] = 60, [235] = 20}}),
    }},
    -- John
    [2] = {heal = 250, personas = {
        persona("medic", {aggression = 55, teamwork = 90, defense = 80, prefer = {[270] = 30}}),
        persona("disc", {aggression = 60, range = 200, spacing = 120, prefer = {[235] = 60, [300] = 40}}),
    }},
    -- Henry
    [4] = {personas = {
        persona("sniper", {aggression = 70, range = 260, spacing = 160, mobility = 10, prefer = {[270] = 60, [280] = 40}}),
        persona("bard", {aggression = 75, prefer = {[250] = 60, [235] = 30}}),
    }},
    -- Rudolf
    [5] = {personas = {
        persona("assassin", {aggression = 70, mobility = 50, prefer = {[250] = 30, [260] = 40}}),
        persona("duelist", {aggression = 85, prefer = {[273] = 50, [285] = 30}}),
    }},
    -- Louis
    [6] = {personas = {
        persona("bruiser", {aggression = 85, combo_greed = 80, prefer = {[247] = 50, [275] = 30}}),
        persona("armored", {aggression = 70, defense = 80, risk = 60, prefer = {[235] = 30}}),
    }},
    -- Firen
    [7] = {personas = {
        persona("pyro", {aggression = 85, mobility = 40, prefer = {[255] = 50, [267] = 40}}),
        persona("zoner", {aggression = 65, range = 220, spacing = 140, prefer = {[235] = 60}}),
        persona("bomber", {aggression = 70, risk = 70, prefer = {[285] = 80}}),
    }},
    -- Freeze
    [8] = {personas = {
        persona("controller", {aggression = 75, prefer = {[260] = 60, [245] = 30}}),
        persona("glacier", {aggression = 65, defense = 80, prefer = {[270] = 40}}),
        persona("zoner", {aggression = 65, range = 220, spacing = 140, prefer = {[235] = 60}}),
    }},
    -- Dennis
    [9] = {personas = {
        persona("kicker", {aggression = 90, combo_greed = 80, prefer = {[280] = 50, [265] = 40}}),
        persona("chaser", {aggression = 70, range = 200, spacing = 120, prefer = {[295] = 60, [235] = 40}}),
    }},
    -- Woody
    [10] = {personas = {
        persona("tiger", {aggression = 85, mobility = 60, prefer = {[250] = 50, [260] = 30}}),
        persona("teleporter", {aggression = 75, mobility = 40, prefer = {[275] = 40, [70] = 40}}),
    }},
    -- Davis
    [11] = {personas = {
        persona("brawler", {aggression = 90, combo_greed = 90, prefer = {[270] = 110, [300] = 70, [60] = 30, [240] = -60}}),
        persona("shoto", {aggression = 70, range = 200, spacing = 110, prefer = {[240] = 140, [300] = 40, [60] = -40}}),
        persona("wild", {aggression = 85, mobility = 90, risk = 70, prefer = {[300] = 60, [290] = 40}}),
    }},
    -- Bandit, Hunter: no special moves.
    [30] = {personas = {persona("grunt", {aggression = 70}), persona("elite", {aggression = 85, mobility = 40})}},
    [31] = {personas = {persona("grunt", {aggression = 65, range = 200, spacing = 140}),
        persona("elite", {aggression = 80, mobility = 40})}},
    -- Mark, Jack, Sorcerer, Monk, Jan, Knight, Bat, Justin
    [32] = {personas = {persona("grunt", {aggression = 75, prefer = {[240] = 30}}),
        persona("elite", {aggression = 90, mobility = 40, prefer = {[240] = 50}})}},
    [33] = {personas = {persona("grunt", {aggression = 70, prefer = {[240] = 30}}),
        persona("elite", {aggression = 85, prefer = {[300] = 40, [240] = 40}})}},
    [34] = {heal = 250, personas = {persona("grunt", {aggression = 65, range = 200, spacing = 130, prefer = {[235] = 40}}),
        persona("elite", {aggression = 80, prefer = {[270] = 40, [235] = 40}})}},
    [35] = {personas = {persona("grunt", {aggression = 70, prefer = {[240] = 30}}),
        persona("elite", {aggression = 85, prefer = {[240] = 50}})}},
    [36] = {personas = {persona("grunt", {aggression = 60, prefer = {[260] = 30}}),
        persona("elite", {aggression = 80, prefer = {[260] = 50}})}},
    [37] = {personas = {persona("grunt", {aggression = 75, prefer = {[240] = 30}}),
        persona("elite", {aggression = 90, prefer = {[240] = 50}})}},
    [38] = {personas = {persona("grunt", {aggression = 70, prefer = {[270] = 30}}),
        persona("elite", {aggression = 85, mobility = 40, prefer = {[240] = 40, [270] = 40}})}},
    [39] = {personas = {persona("grunt", {aggression = 70, prefer = {[240] = 30}}),
        persona("elite", {aggression = 85, prefer = {[250] = 40, [240] = 40}})}},
    -- Louis EX, Firzen, Julian
    [50] = {personas = {persona("boss", {aggression = 90, risk = 60, prefer = {[240] = 50}}),
        persona("pusher", {aggression = 75, range = 200, spacing = 120, prefer = {[260] = 60}})}},
    [51] = {personas = {persona("boss", {aggression = 90, risk = 60, prefer = {[240] = 50, [249] = 40}}),
        persona("zoner", {aggression = 70, range = 240, spacing = 150, prefer = {[265] = 60}})}},
    [52] = {personas = {persona("boss", {aggression = 90, risk = 60, prefer = {[235] = 50, [310] = 40}}),
        persona("zoner", {aggression = 70, range = 240, spacing = 150, prefer = {[280] = 60, [260] = 40}})}},
}

-- The kit of a fighter id, or nil.
function kits.of(id) return kits.by_id[id] end

-- The persona of a kit: `choice` is a number (1 for the first persona) or a name; nil when there is none.
function kits.persona(kit, choice)
    if not kit or not choice then return nil end
    if type(choice) == "number" then return kit.personas[choice] end
    for _, entry in ipairs(kit.personas) do
        if entry.name == choice then return entry end
    end
    return nil
end
return kits
