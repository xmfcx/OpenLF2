-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Trusted runtime implementation. The host prepends the validated declarations table.
local compile = loadstring or load
local read_resource = openlf2_read_resource
local read_object_data = openlf2_read_object_data
local read_background_data = openlf2_read_background_data
local read_stage_data = openlf2_read_stage_data
local random = openlf2_random
local crt_random = openlf2_crt_random
local read_settings = openlf2_read_settings
local write_settings = openlf2_write_settings
local random_state, set_random_state = openlf2_random_state, openlf2_set_random_state
local reset_random_sequence = openlf2_reset_random_sequence
local save_recording, take_recording = openlf2_save_recording, openlf2_take_recording
local local_time = openlf2_local_time
local build_label = openlf2_build_label
local new_table = jit and require("table.new")
local function new_array(capacity)
    if new_table then return new_table(capacity, 0) end
    return {}
end
local network, network_time = openlf2_network, openlf2_network_time
local set_environment = setfenv
local unpack_values = unpack or table.unpack
local traceback = debug.traceback
local protected_call = xpcall
-- The declarations this runtime runs: the host's at start, another network host's after replace_scripts.
local current_declarations = declarations
local replace_scripts

local function copy_library(library)
    local copy = {}
    for key, value in pairs(library) do copy[key] = value end
    return copy
end

-- Script sharing in a network game (base/game/network): a copy of the running declarations, to send them.
local function script_declarations()
    local copy = {}
    for index, declaration in ipairs(current_declarations) do
        copy[index] = {declaration[1], declaration[2], declaration[3], declaration[4]}
    end
    return copy
end

-- `require_module`: the loader of the declarations the module belongs to.
local function evaluate(declaration, previous, require_module)
    local environment = {
        assert = assert, error = error, ipairs = ipairs, pairs = pairs,
        next = next, select = select, tonumber = tonumber, tostring = tostring,
        type = type, unpack = unpack_values, pcall = pcall,
        math = copy_library(math), string = copy_library(string), table = copy_library(table),
        require = require_module,
        engine = {read_resource = read_resource, read_object_data = read_object_data,
            read_background_data = read_background_data, read_stage_data = read_stage_data,
            random = random, crt_random = crt_random, new_array = new_array,
            read_settings = read_settings, write_settings = write_settings,
            random_state = random_state, set_random_state = set_random_state,
            reset_random_sequence = reset_random_sequence, save_recording = save_recording,
            take_recording = take_recording, local_time = local_time, build_label = build_label,
            network = network, network_time = network_time, scripts = script_declarations,
            -- The most commands one frame may hold (MAX_FRAME_COMMANDS below; older runtimes allow 4096).
            frame_command_limit = 1048576,
            replace_scripts = function(list, changes) return replace_scripts(list, changes) end},
    }
    environment.math.random = nil
    environment.math.randomseed = nil
    environment.string.dump = nil
    local chunk, message
    if set_environment then
        chunk, message = compile(declaration[4], "@" .. declaration[3])
    else
        chunk, message = compile(declaration[4], "@" .. declaration[3], "t", environment)
    end
    assert(chunk, message)
    if set_environment then set_environment(chunk, environment) end
    local exported = chunk()
    if declaration[1] == "extend" then
        assert(type(exported) == "function", declaration[3] .. ": extension must return a decorator")
        exported = exported(previous)
    end
    assert(type(exported) == "table", declaration[3] .. ": module must export a table")
    return exported
end

-- A loader for one set of declarations, with its own module cache, so the modules of shared scripts never mix
-- with the running ones.
local function make_loader(list)
    local module_definitions, module_cache, loading = {}, {}, {}
    for _, declaration in ipairs(list) do
        local target = declaration[2]
        local chain = module_definitions[target] or {}
        if declaration[1] == "replace" then
            -- Replacement substitutes the base; explicit extensions still decorate the result.
            chain[1] = declaration
        elseif declaration[1] == "module" then
            assert(#chain == 0, "duplicate module: " .. target)
            chain[1] = declaration
        else
            chain[#chain + 1] = declaration
        end
        module_definitions[target] = chain
    end
    local load_module
    load_module = function(name)
        assert(type(name) == "string", "require expects a module name")
        if module_cache[name] then return module_cache[name] end
        assert(not loading[name], "cyclic module import: " .. name)
        local chain = assert(module_definitions[name], "module not declared: " .. name)
        loading[name] = true
        local exported
        for _, declaration in ipairs(chain) do exported = evaluate(declaration, exported, load_module) end
        loading[name] = nil
        module_cache[name] = exported
        return exported
    end
    return load_module
end

local load_module = make_loader(declarations)
local screen = load_module("base/ui/flow")
local i18n = load_module("base/i18n/i18n")
local state = screen.create(runtime_settings or {menu_seed = 0})
-- Another network host's declarations replace the running ones in memory (nothing is written): they are checked like
-- the host's own, run in the same sandbox with their own loader, and their screens start at the start of the next
-- frame, with the settings `changes` (network keys only) over the runtime settings. On an error the running
-- scripts stay.
local operations = {module = true, replace = true, extend = true}
local network_settings = {network_role = true, network_address = true, network_port = true, network_profile = true,
    network_retry = true}
local pending_swap
replace_scripts = function(list, changes)
    if type(list) ~= "table" or #list == 0 or #list > 4096 then return false, "invalid scripts" end
    local checked = {}
    for index, declaration in ipairs(list) do
        if type(declaration) ~= "table" or not operations[declaration[1]] or type(declaration[2]) ~= "string"
           or type(declaration[3]) ~= "string" or type(declaration[4]) ~= "string" then
            return false, "invalid script declaration"
        end
        checked[index] = {declaration[1], declaration[2], declaration[3], declaration[4]}
    end
    local settings = {}
    for key, value in pairs(runtime_settings or {menu_seed = 0}) do settings[key] = value end
    for key, value in pairs(type(changes) == "table" and changes or {}) do
        if network_settings[key] then settings[key] = value end
    end
    local success, result = protected_call(function()
        local next_load = make_loader(checked)
        local next_screen = next_load("base/ui/flow")
        return {next_screen, next_load("base/i18n/i18n"), next_screen.create(settings)}
    end, traceback)
    if not success then return false, result end
    current_declarations, pending_swap = checked, result
    return true
end
-- Private frame protocol: fixed-size numeric opcodes, matching FrameOpcode in
-- the Lua adapter. Reuse one flat buffer; the host validates each field once.
local FrameOpcode = {
    viewport = 1, sprite = 2, fill = 3, overlay = 4, render_area = 5,
    clip = 6, sound = 7, rumble = 8, music = 9, speed = 10,
    render_filter = 11, text_input = 12, replay_drop = 13, fullscreen = 14, action = 15, text = 16, file_dialog = 17, world_sprite = 18,
}
local RumbleTarget = {gamepad = 0, phone = 1}
local MusicKind = {play = 0, stop = 1, resume = 2, volume = 3}
local RenderFilter = {nearest = 0, linear = 1, xbrz = 2}
local TextAlign = {left = 0, center = 1, right = 2}
local INVALID_ENUM = -1
local MAX_FRAME_COMMANDS = 1048576
local frame_batch, previous_size = {}, 0
local function render(input)
    if pending_swap then
        screen, i18n, state = pending_swap[1], pending_swap[2], pending_swap[3]
        pending_swap = nil
    end
    local size, count = 0, 0
    local function command(opcode, ...)
        assert(count < MAX_FRAME_COMMANDS, "frame command limit exceeded")
        local fields = select("#", ...)
        frame_batch[size + 1] = opcode
        for index = 1, fields do frame_batch[size + index + 1] = select(index, ...) end
        size, count = size + fields + 1, count + 1
    end
    local context = {}
    -- What the frame has drawn that translated text must be able to restore (see i18n.paint_baked).
    local scene = {}
    function context.viewport(w, h, r, g, b)
        command(FrameOpcode.viewport, w, h, r, g, b)
        scene.red, scene.green, scene.blue = r, g, b
    end
    function context.sprite(resource, source, x, y, keyed, mirrored, flipped, tint, scale_x, translate_x)
        -- A translated language replaces the text baked into the sheet (only for unmirrored, unscaled sprites).
        local translated = i18n.active() and not (mirrored or flipped or (translate_x and translate_x ~= 0)
            or (scale_x and scale_x ~= 1))
        local solo = translated and i18n.solo(resource, source)
        if solo then
            local keep = solo.keep
            if keep then
                command(FrameOpcode.sprite, resource, keep[1], keep[2], keep[3], keep[4], x + keep[1] - source[1],
                    y + keep[2] - source[2], not not keyed, false, false, tint or 0xffffff, 1, 0)
            end
        else
            command(FrameOpcode.sprite, resource, source[1], source[2], source[3], source[4], x, y,
                not not keyed, not not mirrored, not not flipped, tint or 0xffffff, scale_x or 1, translate_x or 0)
        end
        if translated then i18n.paint_baked(context, scene, resource, source, x, y, keyed) end
    end
    function context.world_sprite(resource, source, x, y, mirrored, ground_y, azimuth, elevation, character, casts_shadow, shadow_blur, shadow_opacity)
        command(FrameOpcode.world_sprite, resource, source[1], source[2], source[3], source[4], x, y,
            true, not not mirrored, false, 0xffffff, 1, 0,
            ground_y, azimuth, elevation, not not character, not not casts_shadow, shadow_blur or 2, shadow_opacity or 0.275)
    end
    function context.fill(x, y, w, h, r, g, b, alpha) command(FrameOpcode.fill, x, y, w, h, r, g, b, alpha or 255) end
    function context.overlay(active) command(FrameOpcode.overlay, active) end
    function context.render_area(x, y, w, h) command(FrameOpcode.render_area, x, y, w, h) end
    function context.clip(x, y, w, h) command(FrameOpcode.clip, x ~= nil, x or 0, y or 0, w or 0, h or 0) end
    function context.sound(resource, volume, pan) command(FrameOpcode.sound, resource, volume, pan) end
    function context.rumble(kind, index, strength)
        command(FrameOpcode.rumble, RumbleTarget[kind] or INVALID_ENUM, index, strength)
    end
    function context.music(kind, value)
        command(FrameOpcode.music, MusicKind[kind] or INVALID_ENUM, value or false)
    end
    function context.speed(fast) command(FrameOpcode.speed, fast) end
    function context.render_filter(filter)
        command(FrameOpcode.render_filter, RenderFilter[filter] or INVALID_ENUM)
    end
    function context.text_input(active) command(FrameOpcode.text_input, active) end
    function context.replay_drop(active) command(FrameOpcode.replay_drop, active) end
    function context.fullscreen(active) command(FrameOpcode.fullscreen, active) end
    function context.action(name)
        -- The system's file dialog shows these texts in a translated language; empty ones leave its defaults.
        if name == "replay" then
            local translated = i18n.active()
            command(FrameOpcode.file_dialog, translated and i18n.tr("Open a recording") or "",
                translated and i18n.tr("LF2 recording files (*.lfr)") or "", translated and i18n.tr("Open") or "")
        end
        command(FrameOpcode.action, name)
    end
    -- TrueType text (see i18n): `outline` and `background` are 0xRRGGBB or nil for none.
    function context.text(text, x, y, align, size, color, outline, background, antialias)
        command(FrameOpcode.text, text, x, y, TextAlign[align] or INVALID_ENUM, size, color, outline or -1,
            background or -1, not not antialias)
    end
    function context.image(resource, x, y, keyed)
        local translated = i18n.active()
        if not (translated and i18n.solo(resource, nil)) then
            command(FrameOpcode.sprite, resource, 0, 0, 0, 0, x, y, not not keyed, false, false, 0xffffff, 1, 0)
        end
        if translated then
            if resource:find("^pe/menu_back") then scene.backdrop, scene.backdrop_x, scene.backdrop_y = resource, x, y end
            i18n.paint_baked(context, scene, resource, nil, x, y, keyed)
        end
    end
    if screen.update(state, input, context) == false then return false end
    screen.draw(state, context)
    for index = size + 1, previous_size do frame_batch[index] = nil end
    previous_size = size
    return frame_batch, size
end

function openlf2_describe()
    local success, output = protected_call(function()
        return screen.describe and screen.describe(state) or "no description"
    end, traceback)
    if not success then error(output) end
    return output
end

function openlf2_frame(input)
    local success, output, size = protected_call(function() return render(input) end, traceback)
    if not success then error(output) end
    return output, size
end
return "ready"
