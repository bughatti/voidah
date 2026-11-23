----------------------------------------------------------------------
-- VoidAH: when is an item cheapest, by SERVER time (2-hour blocks). The user, 2026-11-23: "a time section, for
-- example i want this thing and through our scans we found it to be cheapest around 11pm server time" -> "yes build
-- both" (watched items from their price log, AND every item from the full scans).
--   * watched items (Watch.lua log): per block the typical cheapest (median), how often at or under your max, how
--     many scans; weekdays vs weekends
--   * every item: VoidUIAuctionDB._timeAgg[house][itemID] = "block:sum:n;" (only blocks with data). Each full scan
--     adds the cheapest one up as a share of the item's usual price (the 7-day median of daily lows, x1000), so a
--     price drifting over weeks doesn't look like a time of day. At MAX_N a block halves (the recent weeks count).
--   * a best time is named only with enough data: MIN_SCANS scans in a block, MIN_BLOCKS such blocks, and the best
--     clearly cheaper than the rest (MIN_GAIN). Otherwise it says which times still need scans (watched) or nothing.
-- Scans only happen when someone opens the AH: hours nobody visits stay empty and are never guessed.
----------------------------------------------------------------------
local AH = VoidUI and VoidUI.AH
if not AH then return end

local T = {}
AH.Times = T

local BLOCK_H = 2
local NBLOCKS = 24 / BLOCK_H
local MIN_SCANS, MIN_BLOCKS = 3, 3
local MIN_GAIN = 0.05   -- the best block at least 5% under the others
local MAX_N = 30

local function money(c) return VoidUI.FormatMoney and VoidUI:FormatMoney(c) or (tostring(c) .. "c") end

-- server time = UTC + this many minutes (from the realm clock, GetGameTime), read again every 10 minutes (daylight
-- saving moves it; Sol 11-23). Watched sightings keep the offset they were seen with (Watch.lua 4th field).
local offsetMin, offsetAt
function T.Offset()
    if offsetMin and time() - offsetAt < 600 and time() >= offsetAt then return offsetMin end
    if not GetGameTime then return 0 end   -- no realm clock: UTC (not cached, try again later)
    local gh, gm = GetGameTime()   -- (not "GetGameTime and GetGameTime()": an "and" keeps only the hour)
    if type(gh) ~= "number" then return 0 end
    local u = date("!*t", time())
    local d = (gh * 60 + (gm or 0)) - (u.hour * 60 + u.min)
    if d > 720 then d = d - 1440 elseif d < -720 then d = d + 1440 end
    offsetMin = math.floor(d / 15 + 0.5) * 15
    offsetAt = time()
    return offsetMin
end
function T._ResetOffset() offsetMin = nil end

-- the 2-hour block (0 = midnight-2 AM ... 11 = 10 PM-midnight) of a time, in server time
function T.Block(t, off)
    local s = (t + (off or T.Offset()) * 60) % 86400
    return math.floor(s / (BLOCK_H * 3600))
end

-- Saturday or Sunday, server time
function T.Weekend(t, off)
    local w = date("!*t", t + (off or T.Offset()) * 60).wday   -- 1 = Sunday
    return w == 1 or w == 7
end

local function hourName(h)
    h = h % 24
    if h == 0 then return "12 AM" elseif h == 12 then return "12 PM" end
    return (h < 12) and (h .. " AM") or ((h - 12) .. " PM")
end
function T.Label(b)
    return hourName(b * BLOCK_H) .. "-" .. hourName((b + 1) * BLOCK_H)
end

local function median(list)
    local n = #list
    if n == 0 then return nil end
    table.sort(list)
    if n % 2 == 1 then return list[(n + 1) / 2] end
    return (list[n / 2] + list[n / 2 + 1]) / 2   -- no rounding: the every-item shares are fractions
end

-- pick the best block of { [b] = { v = value, n = scans } } (lower = cheaper): nil unless enough data and a clear win.
-- Second value: the other times' median, or "flat" when there is enough data but no time is clearly cheaper.
local function best(blocks)
    local q = {}
    for b, r in pairs(blocks) do
        if r.n >= MIN_SCANS and r.v then q[#q + 1] = b end
    end
    if #q < MIN_BLOCKS then return nil end
    table.sort(q, function(a, c)
        if blocks[a].v ~= blocks[c].v then return blocks[a].v < blocks[c].v end
        return a < c
    end)
    local top = q[1]
    local others = {}
    for i = 2, #q do others[#others + 1] = blocks[q[i]].v end
    local rest = median(others)
    if not rest or rest <= 0 or blocks[top].v > rest * (1 - MIN_GAIN) then return nil, "flat" end
    return top, rest
end

----------------------------------------------------------------------
-- Watched items (from Watch.lua's log)
----------------------------------------------------------------------
-- { [block] = { v = median cheapest, n = scans with a price, none = scans with none up, under = at or under max } },
-- weekday median, weekend median
function T.WatchBlocks(itemID)
    local W = AH.Watch
    if not W then return {} end
    local max = W.Max(itemID)
    local per, wd, we = {}, {}, {}
    for _, r in ipairs(W.Log(itemID)) do
      if r[4] then   -- a sighting without its offset (before 11-23) can't be placed safely: left out (Sol)
        local b = T.Block(r[1], r[4])
        local e = per[b]
        if not e then e = { prices = {}, n = 0, none = 0, under = 0 }; per[b] = e end
        if r[2] > 0 then
            e.prices[#e.prices + 1] = r[2]
            e.n = e.n + 1
            if max and r[2] <= max then e.under = e.under + 1 end
            local side = T.Weekend(r[1], r[4]) and we or wd
            side[#side + 1] = r[2]
        else
            e.none = e.none + 1
        end
      end
    end
    local function copper(l) local m = median(l) return m and math.floor(m) end
    for _, e in pairs(per) do e.v = copper(e.prices); e.prices = nil end
    return per, copper(wd), copper(we)
end

-- one tooltip line for a watched item: the best time, or which times still need scans
function T.WatchText(itemID)
    local per = T.WatchBlocks(itemID)
    local b, rest = best(per)
    if b then
        return ("Cheapest around %s server time (usually %s, %d scans) · other times ~%s"):format(
            T.Label(b), money(per[b].v), per[b].n, money(math.floor(rest)))
    end
    if rest == "flat" then
        return "Best time: none, about the same price at every time of day scanned so far"
    end
    local have, nb = {}, 0
    for blk, e in pairs(per) do
        if e.n + e.none > 0 then nb = nb + 1; have[#have + 1] = blk end
    end
    if nb == 0 then return nil end
    table.sort(have, function(a, c) return (per[a].n + per[a].none) > (per[c].n + per[c].none) end)
    local parts = {}
    for i = 1, math.min(3, #have) do
        parts[#parts + 1] = ("%s (%d)"):format(T.Label(have[i]), per[have[i]].n + per[have[i]].none)
    end
    return ("Best time: not enough scans yet. Scanned at %s%s; %d of %d times not yet"):format(
        table.concat(parts, ", "), #have > 3 and ", ..." or "", NBLOCKS - nb, NBLOCKS)
end

-- the Scan tab's hover table: { "label", "right text" } rows, header first
function T.WatchRows(itemID)
    local per, wd, we = T.WatchBlocks(itemID)
    local rows = {}
    local bestB = best(per)
    for b = 0, NBLOCKS - 1 do
        local e = per[b]
        if e then
            local right
            if e.n > 0 then
                right = ("%s · %d scan%s%s%s"):format(money(e.v), e.n, e.n == 1 and "" or "s",
                    e.under > 0 and (" · " .. e.under .. " under your max") or "",
                    e.none > 0 and (" · none up " .. e.none .. "x") or "")
            else
                right = ("none up (%d scan%s)"):format(e.none, e.none == 1 and "" or "s")
            end
            rows[#rows + 1] = { (b == bestB and "|cff00ff00" or "") .. T.Label(b) .. (b == bestB and " (best)|r" or ""), right }
        end
    end
    if wd or we then
        rows[#rows + 1] = { "Weekdays / weekends", (wd and money(wd) or "-") .. " / " .. (we and money(we) or "-") }
    end
    return rows
end

----------------------------------------------------------------------
-- Every item (from each full scan)
----------------------------------------------------------------------
local function aggOf(house, create)
    VoidUIAuctionDB = VoidUIAuctionDB or {}
    local all = VoidUIAuctionDB._timeAgg
    if not all then
        if not create then return nil end
        all = {}
        VoidUIAuctionDB._timeAgg = all
    end
    local h = all[house]
    if not h and create then h = {}; all[house] = h end
    return h
end

-- { [block] = { s = sum of shares x1000, n = scans } }
local function parseAgg(s)
    local out = {}
    if type(s) ~= "string" then return out end
    for b, sum, n in s:gmatch("(%d+):(%d+):(%d+);") do
        out[tonumber(b)] = { s = tonumber(sum), n = tonumber(n) }
    end
    return out
end

local function writeAgg(blocks)
    local parts = {}
    for b = 0, NBLOCKS - 1 do
        local e = blocks[b]
        if e and e.n > 0 then parts[#parts + 1] = b .. ":" .. e.s .. ":" .. e.n .. ";" end
    end
    return #parts > 0 and table.concat(parts) or nil
end

-- a full scan saw itemID with its cheapest at `share` of its usual price (1 = usual), at time t (default now)
function T.AddScan(itemID, share, t, house)
    if type(share) ~= "number" or share <= 0 or share ~= share then return end
    if share > 5 then share = 5 end   -- one silly listing alone mustn't swamp a block
    t = t or time()
    house = house or AH:HouseKey()
    local h = aggOf(house, true)
    local blocks = parseAgg(h[itemID])
    local b = T.Block(t)
    local e = blocks[b]
    if not e then e = { s = 0, n = 0 }; blocks[b] = e end
    e.s = e.s + math.floor(share * 1000 + 0.5)
    e.n = e.n + 1
    if e.n >= MAX_N then e.s, e.n = math.floor(e.s / 2), math.floor(e.n / 2) end
    h[itemID] = writeAgg(blocks)
end

-- after a full scan: every listed item's cheapest vs its usual price (AH._scanMin: itemID -> { {unit, count}, ... })
function T.FullScan(scan, usualOf, t)
    if not scan then return end
    t = t or time()
    local house = AH:HouseKey()
    for itemID, rows in pairs(scan) do
        local usual = usualOf(itemID)
        if usual and usual > 0 then
            local lo
            for _, r in ipairs(rows) do
                if r[1] and r[1] > 0 and (not lo or r[1] < lo) then lo = r[1] end
            end
            if lo then T.AddScan(itemID, lo / usual, t, house) end
        end
    end
end

-- { [block] = { v = average share (1 = usual), n = scans } }
function T.AggBlocks(itemID, house)
    local h = aggOf(house or AH:HouseKey(), false)
    local out = {}
    for b, e in pairs(parseAgg(h and h[itemID])) do
        out[b] = { v = e.s / e.n / 1000, n = e.n }
    end
    return out
end

-- one tooltip line for any item, nil without a clear best time
function T.AggText(itemID)
    local per = T.AggBlocks(itemID)
    local b, rest = best(per)
    if not b then return nil end   -- also "flat": nothing worth a line on any item
    local pct = math.floor((1 - per[b].v / rest) * 100 + 0.5)
    return ("Usually cheapest around %s server time (%d%% under other times, %d scans)"):format(T.Label(b), pct, per[b].n)
end

-- the tooltip's time line: a watched item's own log first, else every-item data
function T.TooltipText(itemID)
    local watched = AH.Watch and AH.Watch.Entry(itemID)
    if watched then
        local per = T.WatchBlocks(itemID)
        if best(per) then return T.WatchText(itemID) end
        return T.AggText(itemID) or T.WatchText(itemID)
    end
    return T.AggText(itemID)
end
