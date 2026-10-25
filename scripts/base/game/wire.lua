-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The encoding of network messages (OpenLF2 extension, docs/netcode.md): nested tables of strings, numbers and
-- booleans as bytes, and back. A table is "{", its key and value pairs, and "}"; a string is "s", its length, ":"
-- and its bytes; a whole number is "i", its digits and ";"; another number "f", 17 digits and ";"; true and false
-- are "T" and "F". The decoder accepts only this form, with limits, because the bytes come from other computers.
local wire = {}

local max_depth, max_items = 12, 65536

local function encode_value(parts, value, depth)
    local kind = type(value)
    if kind == "string" then
        parts[#parts + 1] = "s" .. #value .. ":" .. value
    elseif kind == "number" then
        if value == math.floor(value) and value > -2 ^ 53 and value < 2 ^ 53 then
            parts[#parts + 1] = string.format("i%d;", value)
        else
            parts[#parts + 1] = string.format("f%.17g;", value)
        end
    elseif kind == "boolean" then
        parts[#parts + 1] = value and "T" or "F"
    elseif kind == "table" then
        assert(depth < max_depth, "message nested too deep")
        parts[#parts + 1] = "{"
        for key, entry in pairs(value) do
            local key_kind = type(key)
            if (key_kind == "string" or key_kind == "number") and type(entry) ~= "function" then
                encode_value(parts, key, depth + 1)
                encode_value(parts, entry, depth + 1)
            end
        end
        parts[#parts + 1] = "}"
    else
        error("cannot encode a " .. kind)
    end
end

function wire.encode(value)
    local parts = {}
    encode_value(parts, value, 0)
    return table.concat(parts)
end

-- Returns the value, or nil and a reason.
function wire.decode(bytes)
    if type(bytes) ~= "string" then return nil, "not bytes" end
    local position, items = 1, 0
    local decode_value
    function decode_value(depth)
        items = items + 1
        if items > max_items then error("too many items", 0) end
        local tag = bytes:sub(position, position)
        position = position + 1
        if tag == "s" then
            local digits = bytes:match("^(%d+):", position)
            if not digits or #digits > 6 then error("bad string", 0) end
            local size = tonumber(digits)
            local first = position + #digits + 1
            if first + size - 1 > #bytes then error("short string", 0) end
            position = first + size
            return bytes:sub(first, first + size - 1)
        elseif tag == "i" or tag == "f" then
            local text = bytes:match(tag == "i" and "^(%-?%d+);" or "^([%-%+%.%deEinfa]+);", position)
            local number = text and #text <= 32 and tonumber(text)
            if not number or number ~= number then error("bad number", 0) end
            position = position + #text + 1
            return number
        elseif tag == "T" then
            return true
        elseif tag == "F" then
            return false
        elseif tag == "{" then
            if depth >= max_depth then error("too deep", 0) end
            local result = {}
            while bytes:sub(position, position) ~= "}" do
                if position > #bytes then error("open table", 0) end
                local key = decode_value(depth + 1)
                if type(key) ~= "string" and type(key) ~= "number" then error("bad key", 0) end
                result[key] = decode_value(depth + 1)
            end
            position = position + 1
            return result
        end
        error("bad tag", 0)
    end
    local ok, value = pcall(decode_value, 0)
    if not ok then return nil, value end
    if position ~= #bytes + 1 then return nil, "trailing bytes" end
    return value
end

return wire
