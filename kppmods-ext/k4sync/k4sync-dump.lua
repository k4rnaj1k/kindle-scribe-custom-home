--[[
k4sync-dump: print what an nbk contains (pages, placement, strokes, and any
section fields k4strokes does not interpret). For exploring new firmware.

    lua k4sync-dump.lua /mnt/us/.notebooks/<id>/nbk [--raw]
--]]
local dir = (arg[0]:match("^(.*)/") or ".")
package.path = dir .. "/?.lua;" .. package.path
local k4ion = require("k4ion")
local k4strokes = require("k4strokes")

local function show(v, depth)
    depth = depth or 0
    if type(v) == "string" then
        if v:find("[%z\1-\8\14-\31\127-\255]") then return ("<%d bytes>"):format(#v) end
        return ("%q"):format(v)
    end
    if type(v) ~= "table" then return tostring(v) end
    if v.sym then return v.sym end
    if depth > 4 then return "{...}" end
    local parts = {}
    for i, x in ipairs(v) do
        if i > 8 then parts[#parts + 1] = ("...+%d"):format(#v - 8) break end
        parts[#parts + 1] = show(x, depth + 1)
    end
    local keys = {}
    for k in pairs(v) do
        if type(k) ~= "number" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. show(v[k], depth + 1) end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local path, raw = arg[1], arg[2] == "--raw"
assert(path, "usage: lua k4sync-dump.lua NBK [--raw]")
local frags = k4ion.read_fragments(path, os.tmpname())
local values = k4ion.decode(frags)

if raw then
    local ids = {}
    for id in pairs(values) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do print(("== %s\n%s"):format(id, show(values[id]))) end
end

local doc = k4strokes.pages(values)
print(("%d page(s)"):format(#doc.pages))
for n, page in ipairs(doc.pages) do
    local points = 0
    for _, s in ipairs(page.strokes) do points = points + s.count end
    local p = page.placement
    print(("page %d  id=%s  canvas=%sx%s@%s  placement w=%s h=%s top=%s left=%s  strokes=%d points=%d"):format(
        n, page.id, tostring(page.canvas_w), tostring(page.canvas_h), tostring(page.ppi),
        tostring(p.w), tostring(p.h), tostring(p.top), tostring(p.left), #page.strokes, points))
    if next(page.extra) then print("  extra: " .. show(page.extra)) end
    if page.template then
        print(("  template %s %sx%s, %d shapes"):format(tostring(page.template.type), tostring(page.template.w),
            tostring(page.template.h), #page.template.shapes))
    end
    for i, s in ipairs(page.strokes) do
        if i > 3 then print(("  ... %d more strokes"):format(#page.strokes - 3)) break end
        print(("  stroke %d: %s t=%.1f color=%d bounds=%s pts=%d first=(%d,%d)"):format(
            i, s.brush_name, s.thickness, s.color, show(s.bounds), s.count, s.x[1] or -1, s.y[1] or -1))
    end
end
