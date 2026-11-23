----------------------------------------------------------------------
-- VoidAH: watched items = the shopping list. Every time VoidAH sees one of them on the auction house (a full scan,
-- the shopping-list check when you open the AH, any search, the buy view) it logs the cheapest price and how many
-- were up, and a price at or under your max alerts you (chat line + sound).
--
-- The user, 2026-11-22: the Dire Maul rogue book was 25g in the morning scan and 40g when they came back; "how do we
-- determine if listings change by time of day and when best to buy something" -> "yes build 1 and 2" (1 = a watch
-- with a target price that alerts, 2 = a price log per scan for watched items: the time-of-day data we didn't keep).
--   * the list and the max price: config shoppingList { itemID, itemName, threshold } (0 = auto: 80% of the 7-day
--     average, shopAlertThresholdPct)
--   * VoidUIAuctionDB._watchLog[house][itemID] = "t:cheapest:units;..." (cheapest 0 = none listed; units "" = not
--     known). Sightings within MERGE seconds are one (the lower price, the later count). KEEP_DAYS days, at most
--     MAX_PER_ITEM per item. No seller names.
--   * VoidUIAuctionDB._watchNow["house|itemID"] = { t, p, u }: the latest sighting (what is up NOW; the log row keeps
--     the lowest of a visit, which may have sold since)
--   * an alert per item at most once per ALERT_AGAIN, unless the price dropped further
----------------------------------------------------------------------
local AH = VoidUI and VoidUI.AH
if not AH then return end

local W = {}
AH.Watch = W

local KEEP_DAYS = 30
local MAX_PER_ITEM = 400
local MERGE = 10 * 60
local ALERT_AGAIN = 15 * 60

local function cfg() return VoidUI:GetModuleConfig("Auction") end
local function money(c) return VoidUI.FormatMoney and VoidUI:FormatMoney(c) or (tostring(c) .. "c") end

-- the shopping-list entry of an item (nil = not watched)
function W.Entry(itemID)
    if not itemID then return nil end
    local list = cfg().shoppingList
    if not list then return nil end
    for _, e in ipairs(list) do
        if e.itemID == itemID then return e end
    end
end

-- the most you'd pay: your own max, else auto (a share of the 7-day average). Second value true = auto.
function W.Max(itemID, e)
    e = e or W.Entry(itemID)
    if not e then return nil end
    if e.threshold and e.threshold > 0 then return e.threshold, false end
    local mean = AH.GetMarketMean and AH:GetMarketMean(itemID, 7)
    if mean and mean > 0 then
        return math.floor(mean * ((cfg().shopAlertThresholdPct or 80) / 100)), true
    end
end

local function logOf(house, create)
    VoidUIAuctionDB = VoidUIAuctionDB or {}
    local all = VoidUIAuctionDB._watchLog
    if not all then
        if not create then return nil end
        all = {}
        VoidUIAuctionDB._watchLog = all
    end
    local l = all[house]
    if not l and create then l = {}; all[house] = l end
    return l
end

-- one item's log, oldest first: { { t, cheapest (0 = none listed), units or nil }, ... }
function W.Log(itemID, house)
    local l = logOf(house or AH:HouseKey(), false)
    local s = l and l[itemID]
    local out = {}
    if type(s) ~= "string" then return out end
    -- 4th field (11-23): the server clock offset in minutes when it was seen (Times.lua; daylight saving moves it)
    for t, p, u, o in s:gmatch("(%d+):(%d+):(%d*):?(%-?%d*);") do
        out[#out + 1] = { tonumber(t), tonumber(p), tonumber(u), tonumber(o) }
    end
    return out
end

local function store(itemID, house, rows)
    local cutoff = time() - KEEP_DAYS * 86400
    local first = 1
    while rows[first] and rows[first][1] < cutoff do first = first + 1 end
    first = math.max(first, #rows - MAX_PER_ITEM + 1)
    local parts = {}
    for i = first, #rows do
        local r = rows[i]
        parts[#parts + 1] = r[1] .. ":" .. r[2] .. ":" .. (r[3] or "") .. (r[4] and (":" .. r[4]) or "") .. ";"
    end
    logOf(house, true)[itemID] = #parts > 0 and table.concat(parts) or nil
end

-- the alert: chat line + sound (+ a raid warning when that's on). Returns true when it fired.
W._alerted = {}
function W.Alert(itemID, name, price, max, units)
    local now = time()
    local last = W._alerted[itemID]
    if last and now - last.t < ALERT_AGAIN and price >= last.p then return false end
    W._alerted[itemID] = { t = now, p = price }
    local c = cfg()
    local up = (units and units > 0) and ((" (%d up)"):format(units)) or ""
    print(("|cff00ff00VoidAH WATCH|r: %s at |cff00ff00%s|r, your max %s%s"):format(name or ("item " .. itemID),
        money(price), money(max), up))
    if c.watchSound ~= false and PlaySound then
        pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master")
    end
    if c.shopAlertRaidWarning and RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, "|cff00ff00AH: " .. (name or "?") .. " " .. money(price) .. "|r",
            ChatTypeInfo and ChatTypeInfo["RAID_WARNING"])
    end
    return true
end

-- VoidAH saw a watched item: cheapest = the cheapest buyout per unit (nil / 0 = none listed), units = how many were
-- up (nil = not known). Logs it and alerts when it's at or under your max. Returns true when it alerted.
function W.Seen(itemID, cheapest, units)
    local e = W.Entry(itemID)
    if not e then return false end
    local house = AH:HouseKey()
    cheapest = (type(cheapest) == "number" and cheapest > 0) and math.floor(cheapest) or 0
    if type(units) ~= "number" then units = nil end
    if cheapest == 0 and units == nil then units = 0 end
    local rows = W.Log(itemID, house)
    local now = time()
    -- what's up RIGHT NOW (the log row below keeps the lowest of the visit, which may have sold since; Sol 11-22)
    local now_ = W.Now()
    local cur = now_[house .. "|" .. itemID]
    now_[house .. "|" .. itemID] = { t = now, p = cheapest, u = units or (cur and cur.u) }
    for k, v in pairs(now_) do   -- a few rows (watched items x houses): drop ones not seen in KEEP_DAYS
        if type(v) ~= "table" or (v.t or 0) < now - KEEP_DAYS * 86400 then now_[k] = nil end
    end
    local last = rows[#rows]
    if last and now - last[1] < MERGE and now >= last[1] then
        -- the same visit (timed from its FIRST sighting, so a row never stretches): the lower price, the later
        -- count; "none listed" only when nothing was seen at all
        if cheapest > 0 and (last[2] == 0 or cheapest < last[2]) then last[2] = cheapest end
        if units then last[3] = units end
    else
        rows[#rows + 1] = { now, cheapest, units, AH.Times and AH.Times.Offset() or nil }
    end
    store(itemID, house, rows)
    if cheapest == 0 then return false end
    local max = W.Max(itemID, e)
    if max and max > 0 and cheapest <= max then
        return W.Alert(itemID, e.itemName, cheapest, max, units)
    end
    return false
end

-- the latest sighting per house + item: { t, p (0 = none up), u }, SAVED (VoidUIAuctionDB._watchNow), so a reload
-- right after a copy sold doesn't bring it back from the merged log row (Sol 11-22, 2nd pass). Old data without it:
-- the last log row.
function W.Now()
    VoidUIAuctionDB = VoidUIAuctionDB or {}
    VoidUIAuctionDB._watchNow = VoidUIAuctionDB._watchNow or {}
    return VoidUIAuctionDB._watchNow
end
local function latest(itemID)
    local house = AH:HouseKey()
    local cur = W.Now()[house .. "|" .. itemID]
    if cur then return cur.t, cur.p, cur.u end
    local rows = W.Log(itemID, house)
    local last = rows[#rows]
    if last then return last[1], last[2], last[3] end
end

-- the cheapest one up at the latest sighting, when that's under `within` seconds old (nil = none up / too old)
function W.Cheapest(itemID, within)
    local t, p = latest(itemID)
    if t and p and p > 0 and time() - t <= (within or MERGE) then return p end
end

-- after a full scan: every watched item, also the ones with none up (scan = AH._scanMin: itemID -> listings
-- { unit price, count, band, buyout })
function W.FullScan(scan)
    local list = cfg().shoppingList
    if not list or not scan then return end
    for _, e in ipairs(list) do
        local rows = e.itemID and scan[e.itemID]
        local lo, units = nil, 0
        for _, r in ipairs(rows or {}) do
            if r[1] and r[1] > 0 and (not lo or r[1] < lo) then lo = r[1] end
            units = units + (r[2] or 1)
        end
        if e.itemID then W.Seen(e.itemID, lo, units) end
    end
end

local function ago(s)
    if s < 3600 then return math.max(1, math.floor(s / 60)) .. "m ago" end
    if s < 86400 then return math.floor(s / 3600) .. "h ago" end
    return math.floor(s / 86400) .. "d ago"
end

-- one tooltip line for a watched item, nil when it isn't watched:
-- "Watching (max 25g): last seen 40g 2h ago · at or under your max at 3 of 12 checks"
function W.TooltipText(itemID)
    local e = W.Entry(itemID)
    if not e then return nil end
    local max, auto = W.Max(itemID, e)
    local head = max and ("Watching (max %s%s)"):format(money(max), auto and ", auto" or "") or "Watching"
    local rows = W.Log(itemID)
    local lt, lp = latest(itemID)
    if not lt then return head .. ": not seen on the AH yet" end
    local seen = lp > 0 and ("last seen %s %s"):format(money(lp), ago(time() - lt))
        or ("none up %s"):format(ago(time() - lt))
    local under, checks = 0, 0
    for _, r in ipairs(rows) do
        checks = checks + 1
        if max and r[2] > 0 and r[2] <= max then under = under + 1 end
    end
    local tail = (max and checks > 1) and (" · at or under your max at %d of %d checks"):format(under, checks) or ""
    return head .. ": " .. seen .. tail
end
