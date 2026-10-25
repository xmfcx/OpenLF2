-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The player colors of the new fight screen (OpenLF2 extension, docs/fight-screen.md "Colors"): the default colors
-- of Age of Empires II, one for each player slot, in every mode. Stage mode puts all players on one team, so the
-- team colors of the original cannot tell them apart. The colorblind sets of that game are not used.
local colors = {}

colors.slots = {0x3e59f8, 0xeb0000, 0x00fe00, 0xffff01, 0x00ffff, 0xbd2bbb, 0x797979, 0xf99200}

-- The player slot (0 to 7) of item `index`, or nil: a human in slots 0-7, a computer player of the match setup in
-- slots 10-17 (base/game/match).
function colors.slot(index)
    if index >= 0 and index < 8 then return index end
    if index >= 10 and index < 18 then return index - 10 end
    return nil
end

-- 0xRRGGBB of player `slot`.
function colors.of(slot) return colors.slots[slot % 8 + 1] end

function colors.rgb(value) return math.floor(value / 65536) % 256, math.floor(value / 256) % 256, value % 256 end

-- The color a little darker (`factor` 0 to 1), for backgrounds.
function colors.shade(value, factor)
    local r, g, b = colors.rgb(value)
    return math.floor(r * factor) * 65536 + math.floor(g * factor) * 256 + math.floor(b * factor)
end

return colors
