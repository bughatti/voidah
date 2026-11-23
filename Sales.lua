----------------------------------------------------------------------
-- VoidAH: what actually SELLS, read from two full scans (step 1 of the economy work, 2026-11-21).
--
-- The user, 2026-11-21: "are you looking at this from a full economy perspective, how to do it right, push up, push
-- down, finding the price that sells the quickest" -> "yes start step 1". A listing is what someone hopes to get; a
-- sale is what the market pays. Every full scan sees the whole auction house, so two scans of the same house a little
-- apart show which listings disappeared. Each listing carries its time-left band (C_AuctionHouse
-- .GetReplicateItemTimeLeft: 0 = under 30 min, 1 = 30 min-2 h, 2 = 2-12 h, 3 = over 12 h). One that vanished while it
-- still had more time than passed between the two scans can't have expired: it SOLD (or, rarely, its seller cancelled
-- it). Of the ones gone, the shortest time left is counted first (those may simply have expired) and never as sales.
--   * same house only (Horde / Alliance / the neutral one: AH.HouseKey), scans at most MAX_GAP apart
--   * no seller names anywhere: a listing is item, unit price, stack size, band
--   * VoidUIAuctionDB._snap[house] = { t, items = { [itemID] = "unit:count:band:n;..." } } (the last scan only)
--   * VoidUIAuctionDB._sold[house][itemID] = { { t, unit, units }, ... } (the newest MAX_PER_ITEM, KEEP_DAYS days)
--   * VoidUIAuctionDB._obs[house] = { { from, to, offset }, ... }: the stretches the comparisons watched (SellPlan.lua's
--     pace; Times.lua's best time to sell, with the server clock offset of the time, 1.15.0 on)
-- Counted as UNITS gone at each unit price (goods here are a quantity at a price, bought in part: see group()). What
-- it doesn't know: a cancelled listing looks like a sale; new listings at the same price hide sales (never invent one).
----------------------------------------------------------------------
local AH = VoidUI and VoidUI.AH
if not AH then return end

local SALES_VER = 4   -- bump when the counting changes: older sales data is dropped (3: not above a price that stayed up;
                      -- 4: not when as many new units came up cheaper, a reprice)
local MAX_GAP = 3 * 3600
local MARGIN = 5 * 60   -- slack on the gap: when the data was read vs. when the scan was timed (Sol)
local KEEP_DAYS = 14
local MAX_PER_ITEM = 60
AH.SALES_MAX_PER_ITEM = MAX_PER_ITEM   -- Times.lua: when an item's list is full, its older stretches lost their sales
-- the least time a listing in each band still had when it was seen
local BAND_MIN = { [0] = 0, [1] = 30 * 60, [2] = 2 * 3600, [3] = 12 * 3600 }

-- { { unit, count, band, buyout }, ... } -> { [price key] = { [band] = QUANTITY } }: how many units are listed at each
-- unit price. Not listing by listing: on this AH goods are a quantity at a price that buyers take part of (live
-- 2026-11-21, laptop: one Refreshing Spring Water listing of 886 changed size and all 886 counted as sold; the first
-- version reported 15,946 sales in 16 min). The price key is the unit price in hundredths of a copper (whole numbers:
-- 21c for 2 = 1050), so a fractional unit price can't break it (Sol).
local function group(list)
    local g = {}
    for _, l in ipairs(list or {}) do
        local c, b = math.floor(tonumber(l[2]) or 1), l[3]
        local buy = tonumber(l[4]) or (tonumber(l[1]) and l[1] * c)
        if buy and buy > 0 and c > 0 and type(b) == "number" and BAND_MIN[b] then
            local key = tostring(math.floor(buy * 100 / c + 0.5))
            local bands = g[key]
            if not bands then bands = {}; g[key] = bands end
            bands[b] = (bands[b] or 0) + c
        end
    end
    return g
end

local function encode(g)
    local parts = {}
    for key, bands in pairs(g) do
        for b, n in pairs(bands) do parts[#parts + 1] = key .. ":" .. b .. ":" .. n end
    end
    return table.concat(parts, ";")
end

local function decode(s)
    local g = {}
    for key, b, n in (s or ""):gmatch("(%d+):(%d):(%d+)") do
        local bands = g[key]
        if not bands then bands = {}; g[key] = bands end
        bands[tonumber(b)] = (bands[tonumber(b)] or 0) + tonumber(n)
    end
    return g
end

local function total(bands)
    local n = 0
    for _, v in pairs(bands or {}) do n = n + v end
    return n
end

local function record(house, itemID, t, unit, units, auctions)
    local db = VoidUIAuctionDB
    db._sold = db._sold or {}
    db._sold[house] = db._sold[house] or {}
    local list = db._sold[house][itemID]
    if not list then list = {}; db._sold[house][itemID] = list end
    list[#list + 1] = { t, unit, units, auctions }   -- auctions: how many listings that was (Sol)
    while #list > MAX_PER_ITEM do table.remove(list, 1) end
end

-- every house, every scan: a house you stop scanning still loses its old sales (Sol)
local MAX_OBS = 500
local function prune(now)
    local cut = now - KEEP_DAYS * 86400
    for house, per in pairs(VoidUIAuctionDB._sold or {}) do
        for id, list in pairs(per) do
            while list[1] and list[1][1] < cut do table.remove(list, 1) end
            if #list == 0 then per[id] = nil end
        end
        if next(per) == nil then VoidUIAuctionDB._sold[house] = nil end
    end
    for house, obs in pairs(VoidUIAuctionDB._obs or {}) do
        while obs[1] and (obs[1][2] < cut or #obs > MAX_OBS) do table.remove(obs, 1) end
        if #obs == 0 then VoidUIAuctionDB._obs[house] = nil end
    end
end

-- A full scan finished: lists = { [itemID] = { { unit, count, band }, ... } }. Compares with this house's last scan,
-- records what sold, keeps this scan as the new last one. Returns units sold, or nil when there was
-- nothing to compare with (first scan, another house's, or too long ago).
function AH.SalesFromScan(house, lists, now)
    if type(VoidUIAuctionDB) ~= "table" or not house or type(lists) ~= "table" then return nil end
    now = now or time()
    local db = VoidUIAuctionDB
    -- version 1 (2026-11-21, a few hours) counted a pile bought in part as all of it sold: drop its data once
    if db._salesVer ~= SALES_VER then db._sold, db._snap, db._obs, db._salesVer = nil, nil, nil, SALES_VER end
    db._snap = db._snap or {}
    local cur = {}
    for itemID, list in pairs(lists) do cur[itemID] = group(list) end
    local prev = db._snap[house]
    local found
    if prev and prev.t and now > prev.t and now - prev.t <= MAX_GAP and type(prev.items) == "table" then
        found = 0
        -- the stretch of time this comparison watched (step 3: how fast an item sells = units seen sold / hours watched)
        db._obs = db._obs or {}
        db._obs[house] = db._obs[house] or {}
        -- 3rd: the server clock offset then (Times.lua: when it sells best, by server time; daylight saving moves it)
        table.insert(db._obs[house], { prev.t, now, AH.Times and AH.Times.Offset() or nil })
        local gap, mid = now - prev.t, math.floor((prev.t + now) / 2)
        for idKey, s in pairs(prev.items) do
            local itemID = tonumber(idKey) or idKey
            local after = cur[itemID] or {}
            local before = decode(s)
            -- the cheapest price still listed in BOTH scans: buyers take the cheapest first, so units gone ABOVE a price
            -- that stayed up the whole time were cancelled or repriced, not bought (live 2026-11-21, laptop run 2:
            -- Glorious Breastplate of the Owl "sold" at 300g while it listed at 30g)
            local kept
            for key in pairs(before) do
                if total(after[key]) > 0 then
                    local k = tonumber(key)
                    if not kept or k < kept then kept = k end
                end
            end
            -- units listed since at a LOWER price: a stack cancelled and put back up cheaper (an undercut war) is gone at
            -- its old price but was never bought (laptop 11-22: Thick Leather "sold" ~2,400 at 6s74 with the market at
            -- 4s17 after). So units gone at a price count as sold only beyond the new units under it. Cheapest gone
            -- price first, each new unit used once. It can hide a real sale; it never invents one.
            local keys = {}
            for key in pairs(before) do keys[#keys + 1] = key end
            table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
            local fresh = {}
            for key, bands in pairs(after) do
                local n = total(bands) - total(before[key])
                if n > 0 then fresh[#fresh + 1] = { tonumber(key), n } end
            end
            table.sort(fresh, function(a, b) return a[1] < b[1] end)
            local fi, pool = 1, 0
            for _, key in ipairs(keys) do
                local bands = before[key]
                while fresh[fi] and fresh[fi][1] < tonumber(key) do pool = pool + fresh[fi][2]; fi = fi + 1 end
                -- units gone at this price (more listed since by others only hides sales: never invents one)
                local gone = total(bands) - total(after[key])
                if gone > 0 and kept and tonumber(key) > kept then gone = 0 end
                if gone > 0 and pool > 0 then
                    local use = math.min(gone, pool)   -- repriced down, not bought (assumed the longest-lived ones)
                    gone, pool = gone - use, pool - use
                end
                if gone > 0 then
                    local unit = math.floor(tonumber(key) / 100 + 0.5)
                    local sold = 0
                    -- shortest time left first: those may have expired, so they're never counted as sold
                    for b = 0, 3 do
                        local take = math.min(gone, bands[b] or 0)
                        if take > 0 then
                            gone = gone - take
                            if BAND_MIN[b] > gap + MARGIN then sold = sold + take end
                        end
                        if gone == 0 then break end
                    end
                    if sold > 0 then
                        record(house, itemID, mid, unit, sold)
                        found = found + sold
                    end
                end
            end
        end
    end
    prune(now)
    local items = {}
    for itemID, g in pairs(cur) do
        local s = encode(g)
        if s ~= "" then items[itemID] = s end
    end
    db._snap[house] = { t = now, items = items }
    return found
end

-- What sold of an item at a house in the last `hours` (default 24): units, auctions, the median unit price (by units),
-- the newest sale's time. nil when nothing is known.
function AH:SoldSummary(itemID, house, hours)
    local per = VoidUIAuctionDB and VoidUIAuctionDB._sold and VoidUIAuctionDB._sold[house or AH.HouseKey(nil)]
    local list = per and per[itemID]
    if not list or #list == 0 then return nil end
    local cut = time() - (hours or 24) * 3600
    local rows, units, auctions, last = {}, 0, 0, 0
    for _, s in ipairs(list) do
        if s[1] >= cut then
            rows[#rows + 1] = s
            units = units + s[3]
            auctions = auctions + (s[4] or 1)
            if s[1] > last then last = s[1] end
        end
    end
    if auctions == 0 then return nil end
    table.sort(rows, function(a, b) return a[2] < b[2] end)
    local half, run, median = units / 2, 0, rows[#rows][2]
    for _, s in ipairs(rows) do
        run = run + s[3]
        if run >= half then median = s[2]; break end
    end
    return { units = units, auctions = auctions, median = median, last = last }
end
