--[[
k4sync: turn a Scribe notebook, or a Send-to-Kindle PDF and its handwriting,
into a PDF.

    lua k4sync.lua render NBK OUT.pdf [--title TITLE]
        notebook: vector strokes only (stock /usr/bin/lua is enough)
    luajit k4sync.lua render NBK|- OUT.pdf --kfx DOC.kfx [--yjr DOC.yjr] [--require-strokes]
        article: the whole original PDF (extracted from the KFX). Pages with
        handwriting get it as /Ink annotations in an incremental update, so
        the original pages stay as they are. The reader's .yjr sidecar says
        which page each handwriting section belongs to. Without strokes the
        PDF is written unchanged (pure Lua); with strokes, KOReader's MuPDF
        first re-saves it with a plain xref, so run from the KOReader
        directory. NBK "-" = no handwriting store.

Exit codes: 0 written, 3 nothing to write (no strokes and none required),
4 the KFX holds no PDF (web article or book), 1 error.
--]]
local dir = (arg[0]:match("^(.*)/") or ".")
package.path = dir .. "/?.lua;" .. package.path
local k4ion = require("k4ion")
local k4strokes = require("k4strokes")
local k4pdf = require("k4pdf")
local k4pdfedit = require("k4pdfedit")

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

-- KOReader's MuPDF binding, when running under its luajit.
local function mupdf()
    if not jit then return nil end
    local ok = pcall(require, "setupkoenv")
    if not ok then return nil end
    return require("ffi/mupdf")
end

local function u32(s, p) local a, b, c, d = s:byte(p, p + 3) return a + b * 256 + c * 65536 + d * 16777216 end
local function u64(s, p) return u32(s, p) + u32(s, p + 4) * 4294967296 end

-- KFX container (CONT) entities, as cover-maker's k4covers.lua walks them:
-- calls fn(id, type, payload) for each; ids/types are symbol ids.
local function kfx_entities(data, fn)
    assert(data:sub(1, 4) == "CONT", "not an unencrypted KFX container")
    local header_len = u32(data, 7)
    local info_offset, info_length = u32(data, 11), u32(data, 15)
    local info = k4ion.reader({}):value(data:sub(info_offset + 1, info_offset + info_length), 1)
    local first = info["$413"]
    assert(first, "no entity index")
    for row = first, first + info["$414"] - 1, 24 do
        local start = header_len + u64(data, row + 9) + 1
        local length = u64(data, row + 17)
        local payload = start + u32(data, start + 6)
        if fn(u32(data, row + 1), u32(data, row + 5), data:sub(payload, start + length - 1)) then return end
    end
end

local function embedded_pdf(data)
    local pdf
    kfx_entities(data, function(_, etype, payload)
        if etype == 417 and payload:sub(1, 4) == "%PDF" then -- raw media
            pdf = payload
            return true
        end
    end)
    return pdf
end

-- Print-replica pages: each page story holds a full-page element ($155 eid)
-- whose $175 names a $164 resource with $564 = 0-based PDF page index.
-- Returns { [eid] = 1-based PDF page }. No document symbol table is needed:
-- local symbols are compared by id ("$<sid>") on both sides.
local function kfx_page_map(data)
    local reader, resources, stories = k4ion.reader({}), {}, {}
    kfx_entities(data, function(id, etype, payload)
        if etype == 164 or etype == 259 then
            local ok, v = pcall(reader.value, reader, payload, 1)
            if ok and type(v) == "table" then
                if etype == 164 and v["$564"] then resources["$" .. id] = v["$564"] + 1 end
                if etype == 259 then stories[#stories + 1] = v end
            end
        end
    end)
    local map = {}
    local function walk(v, depth)
        if type(v) ~= "table" or depth > 32 then return end
        local res = type(v["$175"]) == "table" and v["$175"].sym
        if v["$155"] and res and resources[res] then map[v["$155"]] = resources[res] end
        for _, child in ipairs(v["$146"] or {}) do walk(child, depth + 1) end
    end
    for _, s in ipairs(stories) do walk(s, 0) end
    return map
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64decode(s)
    local bits, out = 0, {}
    local acc = 0
    for i = 1, #s do
        local c = B64:find(s:sub(i, i), 1, true)
        if c then
            acc = acc * 64 + (c - 1)
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local byte = math.floor(acc / 2 ^ bits)
                out[#out + 1] = string.char(byte)
                acc = acc - byte * 2 ^ bits
            end
        end
    end
    return table.concat(out)
end

-- The reader's sidecar (.yjr, KRDS) has one annotation.personal.handwritten_note
-- record per handwriting section: strings (03 00 <u16 len>) for start and end
-- position, two timestamps, a template, then the section id. A position is
-- "<base64>:<offset>", the base64 being 01 + the element id as LE u64.
-- Returns { [section id] = eid }.
local function yjr_notes(path)
    local f = io.open(path, "rb")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    local notes, from = {}, 1
    local marker = "annotation.personal.handwritten_note"
    while true do
        local _, e = data:find(marker, from, true)
        if not e then break end
        local pos, strings = e + 1, {}
        while pos <= #data do
            local t = data:byte(pos)
            if t == 3 then
                local len = data:byte(pos + 2) * 256 + data:byte(pos + 3)
                strings[#strings + 1] = data:sub(pos + 4, pos + 3 + len)
                pos = pos + 4 + len
            elseif t == 2 then pos = pos + 9
            elseif t == 1 then pos = pos + 5
            else break end
        end
        local position, section = strings[1], strings[#strings]
        if position and section then
            local raw = b64decode(position:match("^([^:]*)"))
            if raw:byte(1) == 1 and #raw >= 9 then notes[section] = u64(raw, 2) end
        end
        from = e + 1
    end
    return notes
end

-- zlib compress2 through LuaJIT's FFI (stock lua: nil, streams stay uncompressed).
local function deflater()
    if not jit then return nil end
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
        unsigned long compressBound(unsigned long sourceLen);
        int compress2(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen, int level);
    ]])
    local z
    for _, name in ipairs({ "libz.so.1", "libs/libz.so.1", "z" }) do
        local ok, lib = pcall(ffi.load, name)
        if ok then z = lib break end
    end
    if not z then return nil end
    return function(s)
        local size = ffi.new("unsigned long[1]", z.compressBound(#s))
        local buf = ffi.new("uint8_t[?]", size[0])
        assert(z.compress2(buf, size, s, #s, 6) == 0, "compress2 failed")
        return ffi.string(buf, size[0])
    end
end

local function stroke_pages(nbk)
    if nbk == "-" then return {} end
    return k4strokes.pages(k4ion.decode(k4ion.read_fragments(nbk, os.tmpname()))).pages
end

-- Every page (blank ones too, so numbering matches the Kindle) on its
-- template, once the notebook has any ink at all.
local function render_notebook(nbk, out, opts)
    local pages, ink = {}, false
    for _, page in ipairs(stroke_pages(nbk)) do
        if page.canvas_w and page.canvas_h then
            local w, h = k4pdf.notebook_size(page)
            pages[#pages + 1] = { w = w, h = h, ops = k4pdf.template_ops(page, w, h) .. "\n" .. k4pdf.stroke_ops(page, w, h) }
            ink = ink or #page.strokes > 0
        end
    end
    if not ink then return nil end
    k4pdf.write(out, pages, { title = opts.title, deflate = deflater() })
    return ("%d notebook page(s)"):format(#pages)
end

-- Ink annotation for one handwriting section on a PDF page box.
local function ink_annotation(page, box)
    local x0, y0 = box[1], box[2]
    local w, h = box[3] - box[1], box[4] - box[2]
    local map, scale = k4pdf.transform(page, w, h)
    local inklist, maxw = {}, 0
    local bx0, by0, bx1, by1 = math.huge, math.huge, -math.huge, -math.huge
    for _, s in ipairs(page.strokes) do
        local pts = {}
        for i = 1, s.count do
            local x, y = map(s.x[i], s.y[i])
            x, y = x + x0, y + y0
            pts[#pts + 1], pts[#pts + 2] = x, y
            if x < bx0 then bx0 = x end
            if x > bx1 then bx1 = x end
            if y < by0 then by0 = y end
            if y > by1 then by1 = y end
        end
        if #pts > 0 then inklist[#inklist + 1] = pts end
        local width = s.thickness * scale * (s.brush == 1 and 1 or 1.5)
        if width > maxw then maxw = width end
    end
    local pad = maxw / 2 + 1
    return {
        ops = ("q 1 0 0 1 %.2f %.2f cm\n%s\nQ"):format(x0, y0, k4pdf.stroke_ops(page, w, h)),
        inklist = inklist,
        rect = { bx0 - pad, by0 - pad, bx1 + pad, by1 + pad },
        width = maxw,
    }
end

local function merge(a, b)
    if not a then return b end
    a.ops = a.ops .. "\n" .. b.ops
    for _, pts in ipairs(b.inklist) do a.inklist[#a.inklist + 1] = pts end
    a.rect = { math.min(a.rect[1], b.rect[1]), math.min(a.rect[2], b.rect[2]),
        math.max(a.rect[3], b.rect[3]), math.max(a.rect[4], b.rect[4]) }
    a.width = math.max(a.width, b.width)
    return a
end

local function render_article(nbk, out, opts)
    local kfx = read_file(opts.kfx)
    local pdf = embedded_pdf(kfx)
    if not pdf then return false end -- web article or book: not a PDF
    local eid_page, notes = kfx_page_map(kfx), yjr_notes(opts.yjr or "")
    kfx = nil

    local sections = {} -- { {page = stroke page, index = PDF page} }
    for _, page in ipairs(stroke_pages(nbk)) do
        if #page.strokes > 0 then
            local eid = notes[page.id]
            local index = eid and eid_page[eid]
            if index then
                sections[#sections + 1] = { page = page, index = index }
            else
                io.stderr:write(("warning: no PDF page for section %s, skipped\n"):format(page.id))
            end
        end
    end
    if #sections == 0 then
        if opts.require_strokes then return nil end
        write_file(out, pdf)
        return "original PDF, no handwriting"
    end

    -- MuPDF re-save: plain objects + classic xref, which k4pdfedit appends to.
    local Mupdf = assert(mupdf(), "handwriting on PDFs needs KOReader's luajit (run from the KOReader directory)")
    local raw, norm = os.tmpname() .. ".pdf", os.tmpname() .. ".pdf"
    write_file(raw, pdf)
    pdf = nil
    local ok, err = pcall(function()
        local doc = Mupdf.openDocument(raw)
        doc:writeDocument(norm)
        doc:close()
    end)
    os.remove(raw)
    if not ok then os.remove(norm) error(err) end
    local data = read_file(norm)
    os.remove(norm)

    local editor = k4pdfedit.open(data)
    local boxes = editor:pages()
    local annots = {}
    for _, sec in ipairs(sections) do
        local p = assert(boxes[sec.index], "PDF has no page " .. sec.index)
        if p.rotate % 360 ~= 0 then
            io.stderr:write(("warning: page %d is rotated %d degrees; ink may be misplaced\n"):format(sec.index, p.rotate))
        end
        annots[sec.index] = merge(annots[sec.index], ink_annotation(sec.page, p.box))
    end
    write_file(out, editor:add_ink(annots))
    local n = 0
    for _ in pairs(annots) do n = n + 1 end
    return ("original PDF, handwriting on %d page(s)"):format(n)
end

local cmd = arg[1]
if cmd ~= "render" or not arg[2] or not arg[3] then
    io.stderr:write("usage: k4sync.lua render NBK|- OUT.pdf [--kfx DOC.kfx [--yjr DOC.yjr] [--require-strokes]] [--title TITLE]\n")
    os.exit(1)
end
local opts, i = {}, 4
while arg[i] do
    if arg[i] == "--kfx" then opts.kfx = arg[i + 1] i = i + 2
    elseif arg[i] == "--yjr" then opts.yjr = arg[i + 1] i = i + 2
    elseif arg[i] == "--title" then opts.title = arg[i + 1] i = i + 2
    elseif arg[i] == "--require-strokes" then opts.require_strokes = true i = i + 1
    else io.stderr:write("unknown option " .. arg[i] .. "\n") os.exit(1) end
end
local ok, result = pcall(opts.kfx and render_article or render_notebook, arg[2], arg[3], opts)
if not ok then
    io.stderr:write("error: " .. tostring(result) .. "\n")
    os.exit(1)
end
if result == false then
    print("no embedded PDF (web article or book)")
    os.exit(4)
end
if not result then
    print("no strokes")
    os.exit(3)
end
print(("wrote %s (%s)"):format(arg[3], result))
os.exit(0)
