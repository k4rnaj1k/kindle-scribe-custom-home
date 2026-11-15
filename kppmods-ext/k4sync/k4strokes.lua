--[[
k4strokes: turn decoded nbk fragments (k4ion.decode) into pages of strokes.

Layout (as kfxlib's yj_to_epub_notebook reads it):
  reading order ($169 in `metadata`/`document_data`) → section ids ($170)
  section ($260): nmdl.canvas_width/height (units of nmdl.normalized_ppi,
    2520/inch), page placement $56 w / $57 h / $58 top / $59 left (percent,
    for PDF annotations), page templates $141 → content
  content ($270): children in $146, or a story ($259) named by $176
  nmdl.type = nmdl.stroke_group → more content; nmdl.stroke → one stroke:
    nmdl.stroke_bounds {x0, y0, x1, y1}, nmdl.brush_type, nmdl.thickness,
    nmdl.color, nmdl.stroke_points {nmdl.num_points, nmdl.position_x, ...}

Plain Lua 5.1.
--]]
local M = {}

M.BRUSH = { [0] = "original pen", [1] = "highlighter", [5] = "pencil", [6] = "fountain pen", [7] = "pen" }

local POINT_FIELDS = { "nmdl.position_x", "nmdl.position_y", "nmdl.thickness_adjust_factor",
    "nmdl.density_adjust_factor", "nmdl.pressure", "nmdl.tilt_x", "nmdl.tilt_y" }

-- Point arrays: "\1\1", u32 count, then one 4-bit instruction per value (high
-- nibble first, zero-padded), then the operand bytes. Instruction bits:
-- 0-1 = n, 2 = n is the increment itself (else n operand bytes, LE),
-- 3 = negate. Values are second-order deltas: change += inc; value += change.
function M.decode_values(data, expected)
    assert(data:sub(1, 2) == "\1\1", "bad point-array signature")
    local a, b, c, d = data:byte(3, 6)
    local count = a + b * 256 + c * 65536 + d * 16777216
    if expected and count ~= expected then error(("expected %d values, found %d"):format(expected, count)) end
    local pos, instrs = 7, {}
    while #instrs < count do
        local byte = data:byte(pos)
        pos = pos + 1
        instrs[#instrs + 1] = math.floor(byte / 16)
        instrs[#instrs + 1] = byte % 16
    end
    local values, value, change = {}, 0, 0
    for i = 1, count do
        local instr = instrs[i]
        local n, inc = instr % 4, nil
        if math.floor(instr / 4) % 2 == 1 then
            inc = n
        elseif n == 0 then
            inc = 0
        elseif n == 1 then
            inc = data:byte(pos)
            pos = pos + 1
        elseif n == 2 then
            local lo, hi = data:byte(pos, pos + 1)
            inc = lo + hi * 256
            pos = pos + 2
        else -- kfxlib's guess for n == 3: one byte, then a u16 above it
            local x, lo, hi = data:byte(pos, pos + 2)
            inc = x + (lo + hi * 256) * 256
            pos = pos + 3
        end
        if instr >= 8 then inc = -inc end
        if i == 1 then
            value = inc
        else
            change = change + inc
            value = value + change
        end
        values[i] = value
    end
    return values
end

local function percent(v)
    return type(v) == "table" and tonumber(v["$307"]) or nil
end

local function as_id(v)
    if type(v) == "table" then return v.sym end
    return v
end

local function new_stroke(content)
    local bounds = content["nmdl.stroke_bounds"] or { 0, 0, 0, 0 }
    local pts = content["nmdl.stroke_points"] or {}
    local count = pts["nmdl.num_points"] or 0
    local stroke = {
        brush = content["nmdl.brush_type"],
        brush_name = M.BRUSH[content["nmdl.brush_type"]] or ("unknown " .. tostring(content["nmdl.brush_type"])),
        thickness = tonumber(content["nmdl.thickness"]) or 0,
        color = content["nmdl.color"] or 0,
        bounds = bounds,
        transform = content["$98"],
        count = count,
    }
    local vals = {}
    for _, name in ipairs(POINT_FIELDS) do
        -- Some strokes lack nmdl.num_points; the arrays carry their own count.
        if type(pts[name]) == "string" then vals[name] = M.decode_values(pts[name], count > 0 and count or nil) end
    end
    if count == 0 and vals["nmdl.position_x"] then
        count = #vals["nmdl.position_x"]
        stroke.count = count
    end
    stroke.x, stroke.y = {}, {}
    local px, py = vals["nmdl.position_x"] or {}, vals["nmdl.position_y"] or {}
    for i = 1, count do
        stroke.x[i] = (px[i] or 0) + bounds[1]
        stroke.y[i] = (py[i] or 0) + bounds[2]
    end
    stroke.taf = vals["nmdl.thickness_adjust_factor"]
    stroke.daf = vals["nmdl.density_adjust_factor"]
    stroke.pressure = vals["nmdl.pressure"]
    return stroke
end

-- Collects strokes below `content` into `out`.
local function walk(values, content, out, depth)
    if depth > 64 then return end
    if type(content) ~= "table" or content.sym then
        local id = as_id(content)
        if id and values[id] then walk(values, values[id], out, depth + 1) end
        return
    end
    if content["nmdl.type"] and content["nmdl.type"].sym == "nmdl.stroke" then
        out[#out + 1] = new_stroke(content)
        return
    end
    for _, child in ipairs(content["$146"] or {}) do walk(values, child, out, depth + 1) end
    local story = as_id(content["$176"])
    if story and values[story] and values[story] ~= content then
        for _, child in ipairs(values[story]["$146"] or {}) do walk(values, child, out, depth + 1) end
    end
end

local SECTION_KEYS = { ["nmdl.canvas_width"] = 1, ["nmdl.canvas_height"] = 1, ["nmdl.normalized_ppi"] = 1,
    ["$56"] = 1, ["$57"] = 1, ["$58"] = 1, ["$59"] = 1, ["$141"] = 1, ["$174"] = 1, __ann = 1,
    ["nmdl.template_id"] = 1 }

-- Page templates (lines, grid, dots): a template section (nmdl.template_type)
-- whose story holds a $272 vector drawing: viewbox $66 x $67, shapes $250,
-- each a $273 path ($249 = flat [op, args...]: 0 M x y, 1 L x y, 2 Q x1 y1 x
-- y, 3 C x1 y1 x2 y2 x y, 4 Z) with $75 stroke / $70 fill (ARGB) and $76
-- stroke width, as kfxlib's process_kvg_shape reads them. Returns
-- { w, h, type, shapes = { {path, stroke, fill, width}, ... } } or nil.
local function template(values, id)
    local section = id and values[as_id(id)]
    if type(section) ~= "table" or not section["nmdl.template_type"] then return nil end
    local out = { type = section["nmdl.template_type"], shapes = {} }
    local function drawing(v, depth)
        if depth > 16 then return end
        if type(v) == "string" or (type(v) == "table" and v.sym) then return drawing(values[as_id(v)], depth + 1) end
        if type(v) ~= "table" then return end
        if v["$159"] and v["$159"].sym == "$272" then
            out.w, out.h = tonumber(v["$66"]), tonumber(v["$67"])
            for _, shape in ipairs(v["$250"] or {}) do
                local path = shape["$249"]
                if shape["$159"] and shape["$159"].sym == "$273" and type(path) == "table" and #path > 0 then
                    out.shapes[#out.shapes + 1] = { path = path, stroke = shape["$75"], fill = shape["$70"],
                        width = tonumber(shape["$76"]) or 1 }
                end
            end
            return
        end
        for _, child in ipairs(v["$146"] or {}) do drawing(child, depth + 1) end
        local story = as_id(v["$176"])
        if story and values[story] and values[story] ~= v then drawing(values[story], depth + 1) end
    end
    for _, tpl in ipairs(section["$141"] or {}) do drawing(tpl, 0) end
    if not out.w or #out.shapes == 0 then return nil end
    return out
end

-- Returns { pages = { page, ... } } in reading order; each page has id,
-- canvas_w/h, ppi, placement {w, h, top, left} (percent or nil), strokes,
-- and `extra` (section fields not interpreted here).
function M.pages(values)
    local order, seen = {}, {}
    local default_template
    for _, root in ipairs({ "metadata", "document_data" }) do
        local v = values[root]
        if type(v) == "table" and v["nmdl.template_id"] then default_template = v["nmdl.template_id"] end
        for _, ro in ipairs(type(v) == "table" and v["$169"] or {}) do
            for _, sid in ipairs(ro["$170"] or {}) do
                sid = as_id(sid)
                if sid and not seen[sid] then
                    seen[sid] = true
                    order[#order + 1] = sid
                end
            end
        end
    end
    -- Sections outside any reading order (seen in PDF annotation stores).
    local rest = {}
    for id, v in pairs(values) do
        if type(v) == "table" and v.__ann == "$260" and not seen[id] then rest[#rest + 1] = id end
    end
    -- Template sections are backgrounds, not pages.
    local only_pages = {}
    for _, id in ipairs(order) do
        local s = values[id]
        if not (type(s) == "table" and s["nmdl.template_type"]) then only_pages[#only_pages + 1] = id end
    end
    order = only_pages
    table.sort(rest)
    for _, id in ipairs(rest) do
        if not values[id]["nmdl.template_type"] then order[#order + 1] = id end
    end

    local pages = {}
    for _, id in ipairs(order) do
        local s = values[id]
        if type(s) == "table" then
            local page = {
                id = id,
                canvas_w = s["nmdl.canvas_width"], canvas_h = s["nmdl.canvas_height"],
                ppi = s["nmdl.normalized_ppi"] or 2520,
                placement = { w = percent(s["$56"]), h = percent(s["$57"]), top = percent(s["$58"]), left = percent(s["$59"]) },
                strokes = {}, extra = {},
                template = template(values, s["nmdl.template_id"] or default_template),
            }
            for _, tpl in ipairs(s["$141"] or {}) do walk(values, tpl, page.strokes, 0) end
            for k, v in pairs(s) do
                if not SECTION_KEYS[k] then page.extra[k] = v end
            end
            pages[#pages + 1] = page
        end
    end
    return { pages = pages }
end

return M
