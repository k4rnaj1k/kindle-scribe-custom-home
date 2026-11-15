--[[
k4pdf: write a PDF of handwriting pages in plain Lua 5.1.

Each page may carry a background JPEG (the original PDF page rendered by
MuPDF) with the strokes drawn on top as vector paths. Page geometry:

  notebook page:   page = canvas, 1 canvas unit = 72 / ppi pt
  annotated page:  the canvas covers placement.w/h percent of the page,
                   offset by placement.left/top percent (both from k4strokes)

Content streams are uncompressed unless a `deflate(string) -> string`
function is given (KOReader's zlib), which roughly quarters the size.
--]]
local M = {}

local function fmt(n)
    local s = ("%.2f"):format(n):gsub("%.?0+$", "")
    if s == "-0" or s == "" then s = "0" end
    return s
end

-- Maps canvas units to page points (PDF y grows upwards).
function M.transform(page, page_w, page_h)
    local cw, ch = page.canvas_w, page.canvas_h
    local p = page.placement or {}
    if p.w and p.h then
        local sx = page_w * p.w / 100 / cw
        local sy = page_h * p.h / 100 / ch
        local ox, oy = page_w * (p.left or 0) / 100, page_h * (p.top or 0) / 100
        return function(x, y) return ox + x * sx, page_h - (oy + y * sy) end, (sx + sy) / 2
    end
    local s = 72 / (page.ppi or 2520)
    return function(x, y) return x * s, page_h - y * s end, s
end

function M.notebook_size(page)
    local s = 72 / (page.ppi or 2520)
    return page.canvas_w * s, page.canvas_h * s
end

-- PDF colour operator for an ARGB integer (alpha ignored); stroke → G/RG, fill → g/rg.
local function color_op(c, stroke)
    c = tonumber(c) or 0xFF000000
    local r, g, b = math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
    if r == g and g == b then return fmt(r / 255) .. (stroke and " G" or " g") end
    return ("%s %s %s %s"):format(fmt(r / 255), fmt(g / 255), fmt(b / 255), stroke and "RG" or "rg")
end

-- The page template (lines, grid, dots) under the ink: its viewbox is
-- stretched over the whole page.
function M.template_ops(page, page_w, page_h)
    local t = page.template
    if not t then return "" end
    local sx, sy = page_w / t.w, page_h / t.h
    local function xy(x, y) return fmt(x * sx) .. " " .. fmt(page_h - y * sy) end
    local out = { "q 1 J 1 j" }
    for _, s in ipairs(t.shapes) do
        local p, i, seg = s.path, 1, {}
        local cx, cy = 0, 0
        while i <= #p do
            local op = p[i]
            if op == 0 or op == 1 then
                cx, cy = p[i + 1], p[i + 2]
                seg[#seg + 1] = xy(cx, cy) .. (op == 0 and " m" or " l")
                i = i + 3
            elseif op == 2 then -- quadratic → cubic
                local qx, qy, x, y = p[i + 1], p[i + 2], p[i + 3], p[i + 4]
                seg[#seg + 1] = ("%s %s %s c"):format(xy(cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy)),
                    xy(x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y)), xy(x, y))
                cx, cy = x, y
                i = i + 5
            elseif op == 3 then
                seg[#seg + 1] = ("%s %s %s c"):format(xy(p[i + 1], p[i + 2]), xy(p[i + 3], p[i + 4]), xy(p[i + 5], p[i + 6]))
                cx, cy = p[i + 5], p[i + 6]
                i = i + 7
            elseif op == 4 then
                seg[#seg + 1] = "h"
                i = i + 1
            else
                break -- unknown instruction: keep what we have
            end
        end
        if #seg > 0 then
            local paint
            if s.fill and s.stroke then paint = "B" elseif s.fill then paint = "f" else paint = "S" end
            if s.stroke or not s.fill then
                out[#out + 1] = color_op(s.stroke, true)
                out[#out + 1] = fmt(math.max(s.width * (sx + sy) / 2, 0.1)) .. " w"
            end
            if s.fill then out[#out + 1] = color_op(s.fill, false) end
            out[#out + 1] = table.concat(seg, " ") .. " " .. paint
        end
    end
    out[#out + 1] = "Q"
    return table.concat(out, "\n")
end

-- Stroke paths for one page; `gs_highlight` names the ExtGState used for
-- translucent highlighter strokes.
function M.stroke_ops(page, page_w, page_h, gs_highlight)
    gs_highlight = gs_highlight or "GSh"
    local map, scale = M.transform(page, page_w, page_h)
    local out = { "q 1 J 1 j" }
    for _, s in ipairs(page.strokes) do
        if s.count > 0 then
            local gray = 0
            if s.daf then -- pencil: lighter for low density
                local sum = 0
                for i = 1, s.count do sum = sum + s.daf[i] end
                gray = math.max(0, math.min(0.6, 1 - sum / s.count / 100))
            end
            if s.color ~= 0 and s.color then
                local r, g, b = math.floor(s.color / 65536) % 256, math.floor(s.color / 256) % 256, s.color % 256
                out[#out + 1] = ("%s %s %s RG"):format(fmt(r / 255), fmt(g / 255), fmt(b / 255))
            else
                out[#out + 1] = fmt(gray) .. " G"
            end
            out[#out + 1] = s.brush == 1 and ("/" .. gs_highlight .. " gs") or "/GSn gs"
            -- Split where the thickness-adjust factor changes (quantised to 10 %),
            -- overlapping one segment so joins stay smooth, as kfxlib does.
            local function width_at(i)
                local taf = s.taf and s.taf[i] or 100
                return s.thickness * (math.floor(taf / 10) * 10) / 100
            end
            local i, last_w = 1, nil
            while i <= s.count do
                local w = width_at(i)
                local j = i
                while j < s.count and width_at(j + 1) == w do j = j + 1 end
                local from = math.max(1, i - 1)
                if w ~= last_w then out[#out + 1] = fmt(math.max(w * scale, 0.1)) .. " w" end
                last_w = w
                local x, y = map(s.x[from], s.y[from])
                local seg = { fmt(x) .. " " .. fmt(y) .. " m" }
                if from == j then seg[#seg + 1] = fmt(x) .. " " .. fmt(y) .. " l" end -- a dot
                for k = from + 1, j do
                    x, y = map(s.x[k], s.y[k])
                    seg[#seg + 1] = fmt(x) .. " " .. fmt(y) .. " l"
                end
                seg[#seg + 1] = "S"
                out[#out + 1] = table.concat(seg, " ")
                i = j + 1
            end
        end
    end
    out[#out + 1] = "Q"
    return table.concat(out, "\n")
end

-- pages: { {w = pt, h = pt, ops = string, jpeg = bytes|nil, jpeg_w = px, jpeg_h = px, gray = bool}, ... }
function M.write(path, pages, opts)
    opts = opts or {}
    local objs = {}
    local function add(body) objs[#objs + 1] = body return #objs end
    local function stream(dict, data)
        if opts.deflate and not dict:find("/Filter") then
            data = opts.deflate(data)
            dict = dict .. " /Filter /FlateDecode"
        end
        return ("<< %s /Length %d >>\nstream\n%s\nendstream"):format(dict, #data, data)
    end

    local catalog = add(false)
    local pages_id = add(false)
    local gs = add("<< /Type /ExtGState /CA 0.25 /ca 0.25 >>")
    local gs_normal = add("<< /Type /ExtGState /CA 1 /ca 1 >>")
    local kids = {}
    for _, p in ipairs(pages) do
        local res = ("/ExtGState << /GSh %d 0 R /GSn %d 0 R >>"):format(gs, gs_normal)
        local content = {}
        if p.jpeg then
            local img = add(stream(("/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /%s /BitsPerComponent 8 /Filter /DCTDecode")
                :format(p.jpeg_w, p.jpeg_h, p.gray and "DeviceGray" or "DeviceRGB"), p.jpeg))
            res = res .. (" /XObject << /Bg %d 0 R >>"):format(img)
            content[#content + 1] = ("q %s 0 0 %s 0 0 cm /Bg Do Q"):format(fmt(p.w), fmt(p.h))
        end
        content[#content + 1] = p.ops or ""
        local c = add(stream("", table.concat(content, "\n")))
        kids[#kids + 1] = add(("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %s %s] /Resources << %s >> /Contents %d 0 R >>")
            :format(pages_id, fmt(p.w), fmt(p.h), res, c))
    end
    local refs = {}
    for i, k in ipairs(kids) do refs[i] = k .. " 0 R" end
    objs[pages_id] = ("<< /Type /Pages /Kids [%s] /Count %d >>"):format(table.concat(refs, " "), #kids)
    local info = ""
    if opts.title then
        info = add(("<< /Title (%s) /Producer (k4sync) >>"):format(opts.title:gsub("[\\()]", "\\%0")))
    end
    objs[catalog] = ("<< /Type /Catalog /Pages %d 0 R >>"):format(pages_id)

    local f = assert(io.open(path, "wb"))
    local offset = 0
    local function w(s) f:write(s) offset = offset + #s end
    w("%PDF-1.4\n%\226\227\207\211\n")
    local xref = {}
    for i, body in ipairs(objs) do
        xref[i] = offset
        w(("%d 0 obj\n%s\nendobj\n"):format(i, body))
    end
    local xref_at = offset
    w(("xref\n0 %d\n0000000000 65535 f \n"):format(#objs + 1))
    for i = 1, #objs do w(("%010d 00000 n \n"):format(xref[i])) end
    w(("trailer\n<< /Size %d /Root %d 0 R%s >>\nstartxref\n%d\n%%%%EOF\n"):format(
        #objs + 1, catalog, info ~= "" and (" /Info " .. info .. " 0 R") or "", xref_at))
    f:close()
end

return M
