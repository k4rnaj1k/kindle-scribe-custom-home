--[[
k4covers: render a cover for a print-replica KFX document.

Send-to-Kindle stores converted PDFs as unencrypted KFX containers ("CONT")
that keep the original PDF as one raw-media entity ($417). This extracts that
PDF, renders page 1 with KOReader's MuPDF and writes a grayscale JPEG.

Run from the KOReader directory (for setupkoenv / ffi):
    ./luajit k4covers.lua IN.kfx OUT.jpg [WIDTH]
Exit codes: 0 written, 2 no embedded PDF (e.g. web articles), 1 error.

KFX layout (CONT v2): magic, u16 version, u32 header_len, u32 info_offset,
u32 info_length. The container info is an Ion struct whose fields $413/$414
give the entity index table: 24-byte rows of u32 id, u32 type, u64 offset,
u64 length (offsets relative to header_len). Each entity is "ENTY", u16
version, u32 entity header length, then its payload.
--]]
require("setupkoenv")
local ffi = require("ffi")

local RAW_MEDIA = 417
local INDEX_OFFSET, INDEX_LENGTH = 413, 414
-- turbojpeg: TJPF_GRAY, TJSAMP_GRAY.
local TJPF_GRAY, TJSAMP_GRAY = 6, 3

local function u16(s, pos)
    local a, b = s:byte(pos, pos + 1)
    return a + b * 256
end

local function u32(s, pos)
    local a, b, c, d = s:byte(pos, pos + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u64(s, pos)
    return u32(s, pos) + u32(s, pos + 4) * 4294967296
end

-- Minimal Ion binary reader: enough for the container info struct (ints and
-- values to skip). pos is 1-based; returns value, next position.
local function varuint(s, pos)
    local value = 0
    while true do
        local byte = s:byte(pos)
        pos = pos + 1
        value = value * 128 + (byte % 128)
        if byte >= 128 then return value, pos end
    end
end

local function ion_value(s, pos)
    local td = s:byte(pos)
    pos = pos + 1
    if td == 0xE0 then return ion_value(s, pos + 3) end -- version marker
    local t, l = math.floor(td / 16), td % 16
    if l == 14 and t ~= 0x0 and t ~= 0x1 then l, pos = varuint(s, pos) end
    if l == 15 then return nil, pos end
    if t == 0x2 then
        local value = 0
        for i = pos, pos + l - 1 do value = value * 256 + s:byte(i) end
        return value, pos + l
    end
    if t == 0xD then
        local out, finish = {}, pos + l
        if l == 1 then -- sorted struct
            l, pos = varuint(s, pos)
            finish = pos + l
        end
        while pos < finish do
            local field
            field, pos = varuint(s, pos)
            out[field], pos = ion_value(s, pos)
        end
        return out, finish
    end
    if t == 0xE then -- annotation wrapper
        local alen, p2 = varuint(s, pos)
        local value = ion_value(s, p2 + alen)
        return value, pos + l
    end
    return nil, pos + l -- other types are skipped
end

-- Returns the embedded PDF bytes, or nil if the container has none.
local function embedded_pdf(data)
    assert(data:sub(1, 4) == "CONT", "not an unencrypted KFX container")
    local header_len = u32(data, 7)
    local info_offset, info_length = u32(data, 11), u32(data, 15)
    local info = ion_value(data:sub(info_offset + 1, info_offset + info_length), 1)
    assert(type(info) == "table" and info[INDEX_OFFSET], "no entity index")
    local first, last = info[INDEX_OFFSET], info[INDEX_OFFSET] + info[INDEX_LENGTH] - 1
    for row = first, last, 24 do
        local etype = u32(data, row + 5)
        if etype == RAW_MEDIA then
            local start = header_len + u64(data, row + 9) + 1
            local length = u64(data, row + 17)
            assert(data:sub(start, start + 3) == "ENTY", "bad entity header")
            local payload_start = start + u32(data, start + 6)
            if data:sub(payload_start, payload_start + 3) == "%PDF" then
                return data:sub(payload_start, start + length - 1)
            end
        end
    end
    return nil
end

local function render_jpeg(pdf_path, out_path, width)
    local Mupdf = require("ffi/mupdf")
    local DrawContext = require("ffi/drawcontext")
    local Jpeg = require("ffi/jpeg")
    local doc = Mupdf.openDocument(pdf_path)
    local page = doc:openPage(1)
    local dc = DrawContext.new()
    local w = page:getSize(dc)
    dc:setZoom(width / w)
    local pw, ph = page:getSize(dc)
    pw, ph = math.floor(pw + 0.5), math.floor(ph + 0.5)
    local bb = page:draw_new(dc, pw, ph, 0, 0)
    Jpeg.encodeToFile(out_path, ffi.cast("unsigned char*", bb.data), pw, bb.stride, ph, 85, TJPF_GRAY, TJSAMP_GRAY)
    bb:free()
    page:close()
    doc:close()
    return pw, ph
end

local input, output, width = arg[1], arg[2], tonumber(arg[3] or "360")
local ok, err = pcall(function()
    local file = assert(io.open(input, "rb"))
    local data = file:read("*a")
    file:close()
    local pdf = embedded_pdf(data)
    data = nil
    if not pdf then
        print("no embedded PDF")
        os.exit(2)
    end
    local tmp = os.tmpname()
    local out = assert(io.open(tmp, "wb"))
    out:write(pdf)
    out:close()
    pdf = nil
    local ok_render, w, h = pcall(render_jpeg, tmp, output, width)
    os.remove(tmp)
    assert(ok_render, w)
    print(string.format("wrote %s (%dx%d)", output, w, h))
end)
if not ok then
    io.stderr:write("error: " .. tostring(err) .. "\n")
    os.exit(1)
end
os.exit(0)
