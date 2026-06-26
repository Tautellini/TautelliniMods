-- modmenu / SharedModMenu bridge. Copy this ONE file into your mod's Scripts/ to integrate.
-- API VERSION 2  (a plain integer, +1 on each additive spec change: v1 = original, v2 = item `desc`).
--
-- Cross-mod menu bridge over UE4SS shared variables (the SharedModMenu integration file).
--
-- Every UE4SS Lua mod runs in its OWN isolated state, so a consumer's get/set callbacks can
-- never reach the menu mod directly. This module bridges them through UE4SS's shared-variable
-- store (ModRef:Set/GetSharedVariable), which carries scalars only. A consumer's register()
-- keeps its callbacks local and publishes a SERIALIZED spec + live values; the SharedModMenu mod
-- reads those and writes edits back, which a poll applies through the local set(). Generic: no
-- mod-domain literals, and a no-op when SharedModMenu isn't installed.
--
-- A spec is a list of SECTIONS, each { title, items }, so one mod can present several sub-tabs.
-- A bare item list is accepted too and wrapped as one untitled section. Item:
-- { name, kind = "bool"|"num"|"action", get, set, min, max, step, desc }. `desc` is an optional
-- one-line hint shown beside the value; it rides as a trailing schema field, so a menu that does
-- not know it simply ignores it (older builds keep working, the description just does not show).

local rawget, rawset = rawget, rawset
local type, tostring, tonumber, pcall = type, tostring, tonumber, pcall
local ipairs, pairs = ipairs, pairs
local tconcat = table.concat
local sfind, ssub, sgsub = string.find, string.sub, string.gsub

local M = {}

-- Bridge API version (see the banner up top): a plain integer, bumped by 1 on every additive change
-- to the item/spec format. Vendored copies expose it as `modmenu.VERSION`, so a consumer can log or
-- assert which bridge it has, e.g. local apiVer = (modmenu.VERSION or 1). Keep in sync with the banner.
M.VERSION = 2

-- shared-variable store (guarded; ModRef is a UE4SS per-mod global)
local function modRef() return rawget(_G, "ModRef") end
function M.available() return modRef() ~= nil end
local function sset(key, val)
    local mr = modRef(); if not mr then return false end
    return (pcall(function() mr:SetSharedVariable(key, val) end))
end
local function sget(key)
    local mr = modRef(); if not mr then return nil end
    local v; if pcall(function() v = mr:GetSharedVariable(key) end) then return v end
    return nil
end

local PFX = "SMM:"
local K_INDEX = PFX .. "index"
local function kSchema(n) return PFX .. "schema:" .. n end
local function kValues(n) return PFX .. "values:" .. n end
local function kCmd(n)    return PFX .. "cmd:" .. n end

-- serialization: GS between sections, RS between records, FS between fields. Values and edit
-- commands address items by a FLAT index (sections concatenated in order).
local GS, RS, FS = "\29", "\30", "\31"

local function split(s, sep)
    local out, start = {}, 1
    if s == nil or s == "" then return out end
    while true do
        local i = sfind(s, sep, start, true)
        if not i then out[#out + 1] = ssub(s, start); return out end
        out[#out + 1] = ssub(s, start, i - 1); start = i + 1
    end
end

local function valTok(v, kind)
    if kind == "bool" then return v and "b1" or "b0" end
    if kind == "num" then return "n" .. tostring(tonumber(v) or 0) end
    if kind == "action" then return "x" end
    if type(v) == "boolean" then return v and "b1" or "b0" end
    if type(v) == "number" then return "n" .. tostring(v) end
    return v == nil and "x" or ("s" .. tostring(v))
end
local function unTok(t)
    if t == nil or t == "" then return nil end
    local tag = ssub(t, 1, 1)
    if tag == "b" then return ssub(t, 2) == "1" end
    if tag == "n" then return tonumber(ssub(t, 2)) end
    if tag == "s" then return ssub(t, 2) end
    return nil
end

local function itemGet(it)
    if it.get then local ok, v = pcall(it.get); if ok then return v end end
    return it.val
end

-- a spec -> ordered sections (each { title, items }) + a flat item list that owns the closures
local function normalize(spec)
    local sectioned = type(spec[1]) == "table" and type(spec[1].items) == "table"
    local src = sectioned and spec or { { items = spec } }
    local sections, flat = {}, {}
    for _, s in ipairs(src) do
        local items = {}
        for _, it in ipairs(s.items or {}) do flat[#flat + 1] = it; items[#items + 1] = it end
        sections[#sections + 1] = { title = s.title, items = items }
    end
    return sections, flat
end

local function numOrEmpty(v) return type(v) == "number" and tostring(v) or "" end
-- strip the GS/RS/FS framing bytes so a free-text description can never corrupt a record
local function sanitize(s) return (sgsub(tostring(s), "[\29\30\31]", "")) end

local function serializeSchema(sections)
    local secs = {}
    for _, s in ipairs(sections) do
        local parts = { s.title or "" }
        for _, it in ipairs(s.items) do
            local f = { tostring(it.name or "?"), tostring(it.kind or "num"),
                numOrEmpty(it.min), numOrEmpty(it.max), numOrEmpty(it.step) }
            -- desc is appended only when present, so the wire stays unchanged for mods that omit it
            local d = type(it.desc) == "string" and sanitize(it.desc) or ""
            if d ~= "" then f[6] = d end
            parts[#parts + 1] = tconcat(f, FS)
        end
        secs[#secs + 1] = tconcat(parts, RS)
    end
    return tconcat(secs, GS)
end

local function deserializeSchema(str)
    local sections = {}
    for _, secStr in ipairs(split(str, GS)) do
        local parts = split(secStr, RS)
        local items = {}
        for i = 2, #parts do
            local f = split(parts[i], FS)
            items[#items + 1] = { name = f[1] or "?", kind = f[2] or "num",
                min = tonumber(f[3]), max = tonumber(f[4]), step = tonumber(f[5]),
                desc = (f[6] ~= nil and f[6] ~= "") and f[6] or nil }
        end
        sections[#sections + 1] = { title = (parts[1] ~= "" and parts[1] or nil), items = items }
    end
    return sections
end

local function serializeValues(flat)
    local toks = {}
    for _, it in ipairs(flat) do toks[#toks + 1] = valTok(itemGet(it), it.kind) end
    return tconcat(toks, RS)
end

-- ------------------------------------------------- consumer side (publish) --
local registry = {} -- name -> flat item list (local; holds the get/set closures)
local started = false
-- Prefer the game-thread Delayed Action System (no nested deferral, RE-UE4SS #1180-safe),
-- fall back to LoopAsync + ExecuteInGameThread on older builds. This file also ships
-- standalone as modmenu.lua, so the fallback stays inline here instead of via kit.async.
local LoopInGameThreadWithDelay = rawget(_G, "LoopInGameThreadWithDelay")
local CancelDelayedAction       = rawget(_G, "CancelDelayedAction")
local LoopAsync                 = rawget(_G, "LoopAsync")
local ExecuteInGameThread       = rawget(_G, "ExecuteInGameThread")

local function nameList(s)
    local out = {}
    for _, n in ipairs(split(s or "", ",")) do if n ~= "" then out[#out + 1] = n end end
    return out
end
local function hasName(s, name)
    for _, n in ipairs(nameList(s)) do if n == name then return true end end
    return false
end

local function applyCmds(name, flat)
    local str = sget(kCmd(name))
    if not str or str == "" then return end
    sset(kCmd(name), "") -- clear first so a failing set() can't re-apply in a loop
    for _, rec in ipairs(split(str, RS)) do
        local f = split(rec, FS)
        local it = flat[tonumber(f[1])]
        if it and it.set then
            if it.kind == "action" then pcall(it.set, true) else pcall(it.set, unTok(f[2])) end
        end
    end
end

-- one game-thread pass: apply queued edits, then republish current values (unconditionally, so
-- the store is always fresh, including values the mod changed via its own hotkeys).
function M.pump()
    for name, flat in pairs(registry) do
        applyCmds(name, flat)
        sset(kValues(name), serializeValues(flat))
    end
end

local function startPoll()
    if started then return end
    started = true
    local gen = (tonumber(rawget(_G, "__modMenuGen")) or 0) + 1
    rawset(_G, "__modMenuGen", gen)
    local function stale() return rawget(_G, "__modMenuGen") ~= gen end

    if type(LoopInGameThreadWithDelay) == "function" then
        -- fast path: the pump runs ON the game thread, no nested ExecuteInGameThread
        local handle
        handle = LoopInGameThreadWithDelay(250, function()
            if stale() then
                if type(CancelDelayedAction) == "function" and handle ~= nil then
                    pcall(CancelDelayedAction, handle)
                end
                return
            end
            pcall(M.pump)
        end)
        return
    end

    if type(LoopAsync) ~= "function" then return end
    local ticking = false
    LoopAsync(250, function()
        if stale() then return true end -- a newer reload won
        if ticking then return false end
        ticking = true
        local function work() pcall(M.pump); ticking = false end
        if ExecuteInGameThread then ExecuteInGameThread(work) else work() end
        return false
    end)
end

function M.register(name, spec)
    if type(name) ~= "string" or type(spec) ~= "table" then return end
    local sections, flat = normalize(spec)
    registry[name] = flat
    local idx = sget(K_INDEX) or ""
    if not hasName(idx, name) then sset(K_INDEX, idx == "" and name or (idx .. "," .. name)) end
    sset(kSchema(name), serializeSchema(sections))
    sset(kValues(name), serializeValues(flat))
    startPoll()
end

-- ---------------------------------------------------- menu side (consume) --
-- every registered mod's sections + current values, each item tagged with its flat index.
function M.readAll()
    local out = {}
    for _, name in ipairs(nameList(sget(K_INDEX))) do
        local schema = sget(kSchema(name))
        if type(schema) == "string" and schema ~= "" then
            local sections = deserializeSchema(schema)
            local vals = split(sget(kValues(name)) or "", RS)
            local flat = 0
            for _, s in ipairs(sections) do
                for _, it in ipairs(s.items) do flat = flat + 1; it.flat = flat; it.value = unTok(vals[flat]) end
            end
            out[#out + 1] = { name = name, sections = sections }
        end
    end
    return out
end

-- queue an edit for a mod's item (by flat index). The consumer's pump() applies it.
function M.sendEdit(name, flatIndex, kind, value)
    local rec = tostring(flatIndex) .. FS .. valTok(value, kind)
    local cur = sget(kCmd(name))
    if type(cur) == "string" and cur ~= "" then rec = cur .. RS .. rec end
    sset(kCmd(name), rec)
end

return M
