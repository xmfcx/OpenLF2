-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- `fast`: F5 fast mode. `tenths`: the game speed menu's fight speed (base/ui/speed_menu), 0 (stopped) to 10
-- (normal); never recorded, and sent only by a network game's host. `network_tenths`: the host's speed in a network
-- game (base/game/network), nil outside one.
local speed = {fast = false, tenths = 10, network_tenths = nil}
return speed
