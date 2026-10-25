-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The servers a player joined before and the favorites (OpenLF2 extension), saved in config.json
-- ("network_servers"), favorites first. The network screens list them; a joined address moves to the front of its
-- group, and the oldest that is not a favorite goes when the list is full.
local server_list = {}

local limit = 8

function server_list.load()
    local document = engine.read_settings()
    local saved = type(document) == "table" and document.network_servers
    local list = {}
    if type(saved) == "table" then
        for _, entry in ipairs(saved) do
            if type(entry) == "table" and type(entry.address) == "string" and #entry.address <= 15
               and entry.address:match("^[%d.]+$") and #list < limit then
                list[#list + 1] = {address = entry.address, favorite = entry.favorite == true}
            end
        end
    end
    return server_list.sort(list)
end

function server_list.save(list)
    local document = engine.read_settings()
    if type(document) ~= "table" then document = {} end
    local saved = {}
    for index, entry in ipairs(list) do saved[index] = {address = entry.address, favorite = entry.favorite} end
    document.network_servers = saved
    engine.write_settings(document)
end

-- Favorites first, then the others, each in their order.
function server_list.sort(list)
    local sorted = {}
    for pass = 1, 2 do
        for _, entry in ipairs(list) do
            if entry.favorite == (pass == 1) then sorted[#sorted + 1] = entry end
        end
    end
    return sorted
end

-- Returns the list with `address` at the front of its group, saved.
function server_list.remember(list, address)
    local favorite = false
    for index = #list, 1, -1 do
        if list[index].address == address then
            favorite = list[index].favorite
            table.remove(list, index)
        end
    end
    table.insert(list, 1, {address = address, favorite = favorite})
    list = server_list.sort(list)
    for index = #list, 1, -1 do
        if #list <= limit then break end
        if not list[index].favorite then table.remove(list, index) end
    end
    server_list.save(list)
    return list
end

return server_list
