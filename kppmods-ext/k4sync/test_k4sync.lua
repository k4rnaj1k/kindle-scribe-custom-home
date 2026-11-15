-- Unit tests for k4ion / k4strokes. Plain Lua 5.1:  lua test_k4sync.lua
local dir = (arg[0]:match("^(.*)/") or ".")
package.path = dir .. "/?.lua;" .. package.path
local k4ion = require("k4ion")
local k4strokes = require("k4strokes")

local failures = 0
local function check(name, cond, detail)
    if cond then print("ok   " .. name) else
        failures = failures + 1
        print("FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function bytes(...) return string.char(...) end

-- Point arrays: 100, 102, 105 → inc 100 (1 operand byte), +2 inline, +1 inline.
local v = k4strokes.decode_values(bytes(1, 1, 3, 0, 0, 0, 0x16, 0x50, 100), 3)
check("decode_values second-order deltas", same(v, { 100, 102, 105 }), table.concat(v, ","))
-- 10, 8 → inc 10, then change -2 (instr 8|4|2).
v = k4strokes.decode_values(bytes(1, 1, 2, 0, 0, 0, 0x1E, 10), 2)
check("decode_values negative inline", same(v, { 10, 8 }), table.concat(v, ","))
-- u16 operand: 300, 300 (instr 2 = two LE bytes, then 0).
v = k4strokes.decode_values(bytes(1, 1, 2, 0, 0, 0, 0x20, 0x2C, 0x01), 2)
check("decode_values u16 operand", same(v, { 300, 300 }), table.concat(v, ","))
check("decode_values count mismatch", not pcall(k4strokes.decode_values, bytes(1, 1, 2, 0, 0, 0, 0x55), 3))

-- Fingerprint records at 1024 and 1 MiB later (in unwrapped coordinates).
local fp = "\250\080\010\095" .. string.rep("F", 1020)
local a, b, c = string.rep("a", 1024), string.rep("b", 1024 * 1024), string.rep("c", 10)
local plain, n = k4ion.unwrap(a .. fp .. b .. fp .. c)
check("unwrap removes 2 fingerprints", n == 2 and plain == a .. b .. c, ("n=%d len=%d"):format(n, #plain))
plain, n = k4ion.unwrap(a .. "xxxx" .. c)
check("unwrap leaves plain sqlite alone", n == 0 and plain == a .. "xxxx" .. c)

-- Ion: struct {$10: 5, $11: "hi", $12: [true, false, null], $13: 1.5f, $14: -3}
local r = k4ion.reader({})
local ion = bytes(0xDE, 0x92,                -- struct, varuint length 18
    0x8A, 0x21, 0x05,                        -- $10: int 5
    0x8B, 0x82, 0x68, 0x69,                  -- $11: "hi"
    0x8C, 0xB3, 0x11, 0x10, 0x1F,            -- $12: [true, false, null.bool]
    0x8D, 0x44, 0x3F, 0xC0, 0x00, 0x00)      -- $13: float32 1.5
local val = r:value(ion, 1)
check("ion int", val["$10"] == 5)
check("ion string", val["$11"] == "hi")
check("ion bools", val["$12"][1] == true and val["$12"][2] == false and val["$12"][3] == nil)
check("ion float32", val["$13"] == 1.5, tostring(val["$13"]))
check("ion negint", r:value(bytes(0x31, 0x03), 1) == -3)
check("ion float64", r:value(bytes(0x48, 0xC0, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18), 1) == -3.141592653589793)
check("ion annotation", r:value(bytes(0xE3, 0x81, 0x8A, 0xD0), 1).__ann == "$10")
check("ion symbol", r:value(bytes(0x71, 0x0B), 1).sym == "$11")

print(failures == 0 and "all tests passed" or (failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
