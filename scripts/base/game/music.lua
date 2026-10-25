-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Music controls and host requests follow the original game's music routines.
local constants = require("base/game/constants")
local music_volume = constants.music_volume
local music = {enabled = true, selected = nil, master = music_volume.maximum, queue = {}, sent_volume = nil,
    choice = 0, effects = music_volume.maximum}

music.tracks = {"bgm/main.wma", "bgm/stage1.wma", "bgm/stage2.wma", "bgm/stage3.wma", "bgm/stage4.wma",
    "bgm/stage5.wma", "bgm/boss1.wma", "bgm/boss2.wma"}

local function canonical(path) return (path:gsub("\\", "/"):lower()) end

function music.play(path)
    if not music.enabled then return end
    music.queue[#music.queue + 1] = {"play", canonical(path)}
    music.stopped = false
end
-- The music of each computer (OpenLF2 extension, docs/pregame-ui-redesign.md "Sound and music on each computer"):
-- `choice` is the VS track of this computer's configuration, -1 off, 0 random, 1 to 8 a track, and `effects` the
-- volume of the sound effects. A random track comes from a small generator of this computer, never from the shared
-- random numbers of the game.
local local_random = 1
function music.seed(value) local_random = math.floor(value or 1) % 2147483647 + 1 end
local function random_track()
    local_random = local_random * 16807 % 2147483647
    return local_random % #music.tracks + 1
end
function music.configure(values)
    music.choice = values.music_track or 0
    music.enabled = music.choice ~= -1
    music.master = values.music_volume or music.master
    music.effects = values.sound_volume or music.effects
end
-- The VS track of this computer: its choice, or a random one.
function music.play_selected()
    if music.choice == -1 then return end
    music.selected = music.tracks[music.choice > 0 and music.choice or random_track()]
    music.play(music.selected)
end

function music.stop()
    if music.stopped then return end
    music.queue[#music.queue + 1] = {"stop"}
    music.stopped = true
end
function music.resume()
    music.queue[#music.queue + 1] = {"resume"}
    music.stopped = false
end

function music.change_volume(step)
    music.master = math.max(0, math.min(music_volume.maximum, music.master + step))
end

function music.flush(context)
    local volume = music.master == 0 and music_volume.muted or music.master * music_volume.gain - music_volume.offset
    if volume ~= music.sent_volume then
        context.music("volume", volume)
        music.sent_volume = volume
    end
    for _, request in ipairs(music.queue) do context.music(request[1], request[2]) end
    music.queue = {}
end
return music
