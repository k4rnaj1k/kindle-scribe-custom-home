--[[
k4ion: read the fragments of a Scribe notebook / PDF-annotation store (nbk).

An nbk is Amazon KDF: an SQLite file with a 1 KiB "fingerprint" record
(signature fa 50 0a 5f) inserted at offset 1024 and again every 1 MiB, which
makes plain sqlite report "malformed database schema". Remove those and it is
ordinary SQLite whose `fragments` table holds one Ion-binary value per row.
Recent edits may live in `local_delta_fragments` (rows override, deleted=1
removes), so both tables are merged.

Plain Lua 5.1 (no bit ops, no C modules): runs on the stock /usr/bin/lua and
on KOReader's LuaJIT. SQLite is read through the stock sqlite3 CLI.

Values: Ion struct -> table keyed by field name ("$N" for shared YJ symbols,
the local name otherwise), list/sexp -> array, symbol -> {sym = name},
string/blob -> Lua string, annotated table -> same table with .__ann.
--]]
local M = {}

local FP_SIG = "\250\080\010\095"
local FP_OFFSET, FP_LEN, FP_STRIDE = 1024, 1024, 1024 * 1024

-- System symbols 1..9; SIDs from 10 on are the YJ_symbols import, then locals.
local SYSTEM = { "$ion", "$ion_1_0", "$ion_symbol_table", "name", "version", "imports", "symbols",
    "max_id", "$ion_shared_symbol_table" }

function M.unwrap(data)
    if data:sub(FP_OFFSET + 1, FP_OFFSET + 4) ~= FP_SIG then return data, 0 end
    local parts, n, pos, kept = {}, 0, FP_OFFSET + 1, 1
    while #data >= pos + FP_LEN - 1 and data:sub(pos, pos + 3) == FP_SIG do
        parts[#parts + 1] = data:sub(kept, pos - 1)
        kept = pos + FP_LEN
        n = n + 1
        pos = kept + FP_STRIDE -- next record: 1 MiB on in the unwrapped data
    end
    parts[#parts + 1] = data:sub(kept)
    return table.concat(parts), n
end

-- ── Ion binary ───────────────────────────────────────────────────────────────

local function varuint(s, pos)
    local value = 0
    while true do
        local byte = s:byte(pos)
        pos = pos + 1
        value = value * 128 + (byte % 128)
        if byte >= 128 then return value, pos end
    end
end

-- Ion VarInt: sign in bit 6 of the first byte, end flag in bit 7 of the last.
local function varint(s, pos)
    local byte = s:byte(pos)
    local negative = math.floor(byte / 64) % 2 == 1
    local value = byte % 64
    pos = pos + 1
    if byte < 128 then
        while true do
            byte = s:byte(pos)
            pos = pos + 1
            value = value * 128 + (byte % 128)
            if byte >= 128 then break end
        end
    end
    return negative and -value or value, pos
end

local function uint_be(s, first, last)
    local v = 0
    for i = first, last do v = v * 256 + s:byte(i) end
    return v
end

local function float_be(s, pos, len)
    if len == 0 then return 0.0 end
    local b = { s:byte(pos, pos + len - 1) }
    local sign = b[1] >= 128 and -1 or 1
    local exp, mant, bias, mbits
    if len == 4 then
        exp = (b[1] % 128) * 2 + math.floor(b[2] / 128)
        mant = ((b[2] % 128) * 256 + b[3]) * 256 + b[4]
        bias, mbits = 127, 23
    else
        exp = (b[1] % 128) * 16 + math.floor(b[2] / 16)
        mant = b[2] % 16
        for i = 3, 8 do mant = mant * 256 + b[i] end
        bias, mbits = 1023, 52
    end
    if exp == 0 then return sign * math.ldexp(mant, 1 - bias - mbits) end
    if exp == (len == 4 and 255 or 2047) then return mant == 0 and sign * math.huge or 0 / 0 end
    return sign * math.ldexp(mant + 2 ^ mbits, exp - bias - mbits)
end

local Reader = {}
Reader.__index = Reader

function M.reader(symbols) return setmetatable({ symbols = symbols }, Reader) end

function Reader:name(sid)
    return self.symbols[sid] or ("$" .. sid)
end

-- Decodes the value at pos; returns value, next position.
function Reader:value(s, pos)
    local td = s:byte(pos)
    pos = pos + 1
    if td == 0xE0 then return self:value(s, pos + 3) end -- version marker
    local t, l = math.floor(td / 16), td % 16
    if l == 15 then return nil, pos end
    if t == 0x1 then return l == 1, pos end
    if t == 0xD and l == 1 then l, pos = varuint(s, pos) -- sorted struct
    elseif l == 14 then l, pos = varuint(s, pos) end
    local finish = pos + l

    if t == 0x0 then return nil, finish end -- padding
    if t == 0x2 or t == 0x3 then
        local v = uint_be(s, pos, finish - 1)
        return t == 0x3 and -v or v, finish
    end
    if t == 0x4 then return float_be(s, pos, l), finish end
    if t == 0x5 then
        if l == 0 then return 0, finish end
        local exponent, p = varint(s, pos)
        local coefficient = 0
        if p < finish then
            local first = s:byte(p)
            coefficient = (first % 128) * 256 ^ (finish - p - 1) + (finish - p > 1 and uint_be(s, p + 1, finish - 1) or 0)
            if first >= 128 then coefficient = -coefficient end
        end
        return coefficient * 10 ^ exponent, finish
    end
    if t == 0x7 then return { sym = self:name(uint_be(s, pos, finish - 1)) }, finish end
    if t >= 0x8 and t <= 0xA then return s:sub(pos, finish - 1), finish end -- string, clob, blob
    if t == 0xB or t == 0xC then
        local out = {}
        while pos < finish do
            local v
            v, pos = self:value(s, pos)
            out[#out + 1] = v
        end
        return out, finish
    end
    if t == 0xD then
        local out = {}
        while pos < finish do
            local sid
            sid, pos = varuint(s, pos)
            out[self:name(sid)], pos = self:value(s, pos)
        end
        return out, finish
    end
    if t == 0xE then
        local alen
        alen, pos = varuint(s, pos)
        local anns, p = {}, pos
        while p < pos + alen do
            local sid
            sid, p = varuint(s, p)
            anns[#anns + 1] = self:name(sid)
        end
        local v = self:value(s, pos + alen)
        if type(v) == "table" and not v.sym then v.__ann = anns[1] end
        return v, finish
    end
    return nil, finish -- timestamps are not needed
end

-- ── nbk → fragments ──────────────────────────────────────────────────────────

local function unhex(h)
    return (h:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end

local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function query(db, sql)
    local p = assert(io.popen("sqlite3 -batch -noheader -separator '|' " .. shell_quote(db) .. " " .. shell_quote(sql)))
    local rows = {}
    for line in p:lines() do rows[#rows + 1] = line end
    p:close()
    return rows
end

-- Returns { [fragment id] = raw Ion bytes } for an nbk at `path`.
-- `tmp` is a scratch path for the unwrapped copy (removed afterwards).
function M.read_fragments(path, tmp)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    local plain = M.unwrap(data)
    data = nil
    assert(plain:sub(1, 16) == "SQLite format 3\0", "not a KDF/SQLite file: " .. path)
    local out = assert(io.open(tmp, "wb"))
    out:write(plain)
    out:close()
    plain = nil

    local frags = {}
    for _, row in ipairs(query(tmp, "select id, hex(payload_value) from fragments where payload_type = 'blob';")) do
        local id, hex = row:match("^(.-)|(%x*)$")
        if id then frags[id] = unhex(hex) end
    end
    local has_delta = #query(tmp, "select 1 from sqlite_master where name = 'local_delta_fragments';") > 0
    if has_delta then
        for _, row in ipairs(query(tmp, "select id, deleted, hex(payload_value) from local_delta_fragments;")) do
            local id, deleted, hex = row:match("^(.-)|(%d*)|(%x*)$")
            if id then frags[id] = (deleted ~= "1") and unhex(hex) or nil end
        end
    end
    os.remove(tmp)
    return frags
end

-- Decodes every fragment; returns { [id] = value }, symbol table.
function M.decode(frags)
    local symbols = {}
    for i, name in ipairs(SYSTEM) do symbols[i] = name end
    local raw_st = frags["$ion_symbol_table"]
    if not raw_st then return {}, symbols end -- a new, still empty store
    local st = M.reader(symbols):value(raw_st, 1)
    local next_sid = #SYSTEM + 1
    for _, imp in ipairs(st.imports or {}) do next_sid = next_sid + (imp.max_id or 0) end
    for _, name in ipairs(st.symbols or {}) do
        symbols[next_sid] = name
        next_sid = next_sid + 1
    end

    local reader, values = M.reader(symbols), {}
    for id, raw in pairs(frags) do
        if id ~= "$ion_symbol_table" and #raw > 4 then
            local ok, v = pcall(reader.value, reader, raw, 1)
            if ok then values[id] = v end
        end
    end
    return values, symbols
end

return M
