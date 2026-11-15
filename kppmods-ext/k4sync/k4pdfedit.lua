--[[
k4pdfedit: add ink annotations to an existing PDF by appending an
incremental update, so the original pages (text, links) stay untouched.

The input must use a classic xref table with plain (not object-stream)
objects, which is what MuPDF writes when it re-saves a document; k4sync.lua
normalises the Send-to-Kindle PDF that way first. Each annotated page gets
one /Ink annotation whose appearance stream holds the vector strokes, and a
new revision of the page object listing it in /Annots.

Plain Lua 5.1.
--]]
local M = {}

-- ── Minimal PDF object parser (no streams) ───────────────────────────────────

local DELIM = "[%s%[%]<>%(%)/%%{}]"

local function skip_ws(s, pos)
    while true do
        local _, e = s:find("^%s+", pos)
        if e then pos = e + 1 end
        if s:sub(pos, pos) == "%" then
            local nl = s:find("[\r\n]", pos) or #s
            pos = nl + 1
        else
            return pos
        end
    end
end

local parse_value

local function parse_string(s, pos) -- at "("
    local depth, i = 0, pos
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" then i = i + 1
        elseif c == "(" then depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then return { str = s:sub(pos + 1, i - 1) }, i + 1 end
        end
        i = i + 1
    end
    error("unterminated string")
end

-- Returns value, next position. Dicts/arrays record where they end (__e,
-- just past the closing delimiter) and, for dicts, where each top-level
-- value starts/ends (__at[key] = {start, end}).
parse_value = function(s, pos)
    pos = skip_ws(s, pos)
    local two, one = s:sub(pos, pos + 1), s:sub(pos, pos)
    if two == "<<" then
        local d, at = { __dict = true, __s = pos }, {}
        pos = pos + 2
        while true do
            pos = skip_ws(s, pos)
            if s:sub(pos, pos + 1) == ">>" then
                d.__e, d.__at = pos + 2, at
                return d, pos + 2
            end
            local key
            key, pos = parse_value(s, pos)
            assert(type(key) == "table" and key.name, "dict key is not a name")
            local vstart = skip_ws(s, pos)
            d[key.name], pos = parse_value(s, vstart)
            at[key.name] = { vstart, pos }
        end
    elseif one == "<" then
        local e = assert(s:find(">", pos, true), "unterminated hex string")
        return { hex = s:sub(pos + 1, e - 1) }, e + 1
    elseif one == "[" then
        local a = { __array = true, __s = pos }
        pos = pos + 1
        while true do
            pos = skip_ws(s, pos)
            if s:sub(pos, pos) == "]" then
                a.__e = pos + 1
                return a, pos + 1
            end
            a[#a + 1], pos = parse_value(s, pos)
        end
    elseif one == "(" then
        return parse_string(s, pos)
    elseif one == "/" then
        local e = (s:find(DELIM, pos + 1) or #s + 1) - 1
        return { name = s:sub(pos + 1, e) }, e + 1
    end
    -- number, possibly the start of "num gen R"
    local num, e = s:match("^([%+%-]?[%d%.]+)()", pos)
    if num then
        local gen, e2 = s:match("^%s+(%d+)%s+R()", e)
        if gen and not num:find("[%.%+%-]") then return { ref = tonumber(num), gen = tonumber(gen) }, e2 end
        return tonumber(num), e
    end
    local word, e3 = s:match("^(%a+)()", pos)
    if word == "true" then return true, e3 end
    if word == "false" then return false, e3 end
    if word == "null" then return nil, e3 end
    error(("unexpected token at %d: %q"):format(pos, s:sub(pos, pos + 20)))
end

M.parse_value = parse_value

-- ── Document ─────────────────────────────────────────────────────────────────

local Doc = {}
Doc.__index = Doc

function M.open(data)
    local self = setmetatable({ data = data, offsets = {} }, Doc)
    local xref_at = tonumber(data:match("startxref%s+(%d+)%s*%%%%EOF%s*$"))
    assert(xref_at, "no startxref")
    self.xref_at = xref_at
    local pos = xref_at + 1
    while pos do
        assert(data:sub(pos, pos + 3) == "xref", "not a classic xref table (re-save the PDF with MuPDF first)")
        pos = pos + 4
        while true do
            local first, count, p = data:match("^%s*(%d+)%s+(%d+)%s*()", pos)
            if not first then break end
            first, count, pos = tonumber(first), tonumber(count), p
            for i = 0, count - 1 do
                local off, _, kind = data:match("^(%d+)%s+(%d+)%s+([nf])", pos)
                if kind == "n" and not self.offsets[first + i] then self.offsets[first + i] = tonumber(off) end
                pos = pos + 20
            end
        end
        local tpos = assert(data:find("trailer", pos, true), "no trailer")
        local trailer = parse_value(data, tpos + 7)
        self.trailer = self.trailer or trailer
        pos = trailer.Prev and (trailer.Prev + 1) or nil
    end
    self.size = self.trailer.Size
    return self
end

-- Returns parsed object, body start, body end (1-based, around the value).
function Doc:object(num)
    local off = assert(self.offsets[num], "object not in xref: " .. num)
    local p = self.data:match("^%s*%d+%s+%d+%s+obj()", off + 1)
    assert(p, "bad object header for " .. num)
    local start = skip_ws(self.data, p)
    local v, e = parse_value(self.data, start)
    return v, start, e
end

function Doc:resolve(v)
    if type(v) == "table" and v.ref then return (self:object(v.ref)) end
    return v
end

-- Page object numbers in order, with inherited MediaBox/CropBox/Rotate.
function Doc:pages()
    local out = {}
    local function walk(ref, inherited, depth)
        assert(depth < 64, "page tree too deep")
        local node = self:object(ref.ref)
        local inh = {
            MediaBox = node.MediaBox or inherited.MediaBox,
            CropBox = node.CropBox or inherited.CropBox,
            Rotate = node.Rotate or inherited.Rotate,
        }
        if node.Type and node.Type.name == "Pages" or node.Kids then
            for _, kid in ipairs(self:resolve(node.Kids)) do walk(kid, inh, depth + 1) end
        else
            local box = self:resolve(inh.CropBox or inh.MediaBox)
            out[#out + 1] = { num = ref.ref, box = { box[1], box[2], box[3], box[4] }, rotate = inh.Rotate or 0 }
        end
    end
    local root = self:resolve(self.trailer.Root)
    walk(root.Pages, {}, 0)
    return out
end

-- ── Incremental update with ink annotations ──────────────────────────────────

local function fmt(n)
    local s = ("%.2f"):format(n):gsub("%.?0+$", "")
    if s == "-0" or s == "" then s = "0" end
    return s
end

-- annots: { [page number (1-based)] = { ops = content stream (page space),
--   inklist = { {x1, y1, x2, y2, ...}, ... }, rect = {x0, y0, x1, y1}, width = pt } }
-- Returns the updated PDF bytes.
function Doc:add_ink(annots)
    local pages = self:pages()
    local data = self.data
    local next_num = self.size
    local objs = {} -- { num, body }
    local function new_obj(body)
        local n = next_num
        next_num = next_num + 1
        objs[#objs + 1] = { n, body }
        return n
    end

    local resources = "<< /ExtGState << /GSh << /Type /ExtGState /CA 0.25 /ca 0.25 >> /GSn << /Type /ExtGState /CA 1 /ca 1 >> >> >>"
    local page_numbers = {}
    for index in pairs(annots) do page_numbers[#page_numbers + 1] = index end
    table.sort(page_numbers)

    for _, index in ipairs(page_numbers) do
        local a = annots[index]
        local page = assert(pages[index], "PDF has no page " .. index)
        local r = a.rect
        local rect = ("[%s %s %s %s]"):format(fmt(r[1]), fmt(r[2]), fmt(r[3]), fmt(r[4]))
        local form = new_obj(("<< /Type /XObject /Subtype /Form /BBox %s /Resources %s /Length %d >>\nstream\n%s\nendstream")
            :format(rect, resources, #a.ops, a.ops))
        local ink = {}
        for i, pts in ipairs(a.inklist) do
            local f = {}
            for k, v in ipairs(pts) do f[k] = fmt(v) end
            ink[i] = "[" .. table.concat(f, " ") .. "]"
        end
        local annot = new_obj(("<< /Type /Annot /Subtype /Ink /Rect %s /InkList [%s] /C [0 0 0] /BS << /W %s >> /F 4 /P %d 0 R /NM (k4sync-%d) /T (Kindle) /AP << /N %d 0 R >> >>")
            :format(rect, table.concat(ink, " "), fmt(a.width or 1), page.num, index, form))

        -- New revision of the page object with the annotation in /Annots.
        local pv, ps, pe = self:object(page.num)
        local body = data:sub(ps, pe - 1)
        local entry = (" %d 0 R"):format(annot)
        local annots_v = pv.Annots
        if annots_v == nil then
            body = "<< /Annots [" .. entry .. " ]" .. body:sub(3)
        elseif annots_v.__array then
            local close = annots_v.__e - ps -- offset of "]" + 1 within body
            body = body:sub(1, close - 1) .. entry .. " " .. body:sub(close)
        else -- indirect array: write a new revision of it
            local arr = self:resolve(annots_v)
            local refs = {}
            for i, v in ipairs(arr) do refs[i] = ("%d %d R"):format(v.ref, v.gen) end
            refs[#refs + 1] = entry
            objs[#objs + 1] = { annots_v.ref, "[" .. table.concat(refs, " ") .. "]" }
        end
        objs[#objs + 1] = { page.num, body }
    end

    -- Append objects, xref (one subsection per object), trailer.
    local out = { data }
    if data:sub(-1) ~= "\n" then out[#out + 1] = "\n" end
    local offset = #data + (data:sub(-1) ~= "\n" and 1 or 0)
    local xref = {}
    for _, o in ipairs(objs) do
        local text = ("%d 0 obj\n%s\nendobj\n"):format(o[1], o[2])
        xref[#xref + 1] = { o[1], offset }
        out[#out + 1] = text
        offset = offset + #text
    end
    table.sort(xref, function(x, y) return x[1] < y[1] end)
    local xref_at = offset
    local lines = { "xref\n" }
    for _, x in ipairs(xref) do lines[#lines + 1] = ("%d 1\n%010d 00000 n \n"):format(x[1], x[2]) end
    local t = self.trailer
    local extra = ""
    if t.Info then extra = extra .. (" /Info %d %d R"):format(t.Info.ref, t.Info.gen) end
    if t.ID and t.ID.__array then extra = extra .. " /ID " .. data:sub(t.ID.__s, t.ID.__e - 1) end
    lines[#lines + 1] = ("trailer\n<< /Size %d /Root %d %d R /Prev %d%s >>\nstartxref\n%d\n%%%%EOF\n")
        :format(next_num, t.Root.ref, t.Root.gen, self.xref_at, extra, xref_at)
    out[#out + 1] = table.concat(lines)
    return table.concat(out)
end

return M
