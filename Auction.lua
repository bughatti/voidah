----------------------------------------------------------------------
-- VoidUI Auction Module — Engine
-- Price database, scan logic, throttle queue, public API
----------------------------------------------------------------------
local mod = VoidUI:NewModule("Auction")

-- Public API namespace
VoidUI.AH = {}
local AH = VoidUI.AH

-- VoidAH is built on the modern auction house (C_AuctionHouse). A client
-- with the classic auction house (no C_AuctionHouse) would error on its
-- events and lose Blizzard's window under ours — so there we stand down.
AH.supported = C_AuctionHouse ~= nil and C_AuctionHouse.SendBrowseQuery ~= nil

-- WoW Forever's client drops the old global item functions (retail still
-- aliases them) — use the C_Item versions where they exist.
local GetItemClassInfo = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo

----------------------------------------------------------------------
-- 12.0.5 secret-value safety (delegates to VoidLib.Secrets)
--
-- AH price/quantity fields (minPrice, unitPrice, bidAmount, buyoutAmount,
-- quantity, totalQuantity) can come back as opaque "secret values" in
-- tainted contexts (combat, M+ run, encounter, arena). Any arithmetic,
-- comparison, or tostring() on a secret value throws a hard Lua error.
--
-- Helpers are sourced from VoidLib (## Dependencies: VoidLib). The
-- AH.<name> aliases are preserved for backwards compat with the 39
-- existing call sites in Auction.lua / AuctionUI.lua. New code should
-- call VoidLib.Secrets.<name> directly.
----------------------------------------------------------------------
local VLSecrets = VoidLib and VoidLib.Secrets
if not VLSecrets then
    error("VoidAH: VoidLib not loaded. Check '## Dependencies: VoidLib' in VoidAH.toc and that the VoidLib addon is installed.")
end

AH.AreSecretsDisabled = VLSecrets.AreSecretsDisabled
AH.SafeNum            = VLSecrets.SafeNum
AH.SafeMoney          = VLSecrets.SafeMoney
AH.SafeMul            = VLSecrets.SafeMul

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local FULL_SCAN_COOLDOWN   = 900          -- 15 min
local BATCH_SIZE           = 500          -- items per tick in full scan
local BATCH_INTERVAL       = 0.01         -- seconds between batches
local HISTORY_DAYS         = 14
local DAY_SECONDS          = 86400
local CATEGORY_DELAY       = 3            -- seconds between category scans
local PAGE_DELAY           = 0.8          -- extra delay between page requests

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
AH.scanning       = false
AH.scanType       = nil        -- "full" | "browse"
AH.scanProgress   = 0          -- 0-1
AH.scanTotal      = 0
AH.scanProcessed  = 0
AH.ahOpen         = false
AH.sessionProfit  = 0
AH.sessionStartGold = 0
AH._processingBatch = false    -- guard against overlapping batch chains

-- Throttle queue
local throttleQueue = {}
local throttleReady = true

----------------------------------------------------------------------
-- Safe callback helper (prints errors instead of swallowing them)
----------------------------------------------------------------------
local function SafeCall(func, ...)
    local ok, err = pcall(func, ...)
    if not ok then
        print("|cffff0000VoidAH callback error:|r " .. tostring(err))
    end
end

----------------------------------------------------------------------
-- Database helpers
----------------------------------------------------------------------
-- WoW Forever has THREE auction houses per realm, each its own market: your faction's, the other faction's, and the
-- neutral one (Booty Bay, Gadgetzan and Everlook share one, both factions trade there, and its cut is ~15%). The
-- user, 2026-11-20: "the bootybay ah is a shared one and prices are different so really we should have 3 pricings".
-- So prices are kept per house: the one you have open, else your faction's (tooltips, VoidProf plans, deals away
-- from an auction house). Retail keeps one pool per realm.
local IS_FOREVER = (select(4, GetBuildInfo()) or 0) < 100000
local NEUTRAL_ZONES = { [1434] = true, [1446] = true, [1452] = true }   -- Stranglethorn Vale, Tanaris, Winterspring
AH.openHouse = nil   -- "Neutral" / "Horde" / "Alliance" while an auction house is open (Forever)

-- the zone you're in (a city or sub-map walks up to its zone)
local function ZoneMap()
    local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    for _ = 1, 6 do
        if not m or NEUTRAL_ZONES[m] then return m end
        local info = C_Map.GetMapInfo(m)
        if not info or (info.mapType or 9) <= 3 then return m end   -- 3 = Zone
        m = info.parentMapID
    end
    return m
end

-- the auction house in front of you: the neutral one in those three zones (none of them has a faction house)
function AH:HouseHere()
    local faction = UnitFactionGroup("player") or "Horde"
    if IS_FOREVER and NEUTRAL_ZONES[ZoneMap() or 0] then return "Neutral" end
    return faction
end

-- the house prices are read and written for: the open one, else your faction's
function AH:House()
    return self.openHouse or (UnitFactionGroup("player") or "Horde")
end
function AH:HouseName(house)
    house = house or self:House()
    return house == "Neutral" and "Booty Bay / Gadgetzan / Everlook" or (house .. " auction house")
end

-- The realm the prices are saved under. WoW Forever, 2026-11-21: GetRealmName() turned blank on the PC client
-- overnight (the laptop's already was), and every bag tooltip lost its AH line: 7,281 prices sat under the old
-- name. So the name the game gave before stays the key: remembered per realm (UnitFullName still names it).
-- The first blank day falls back to the one named realm the house table (_base) knows. A client never seen
-- with a name (the laptop) keeps "" as before.
local function plain(v)
    if (issecretvalue and issecretvalue(v)) or type(v) ~= "string" then return nil end
    return v
end
function AH.Realm()
    local r = plain(GetRealmName and GetRealmName()) or ""
    local db = VoidUIAuctionDB
    if type(db) ~= "table" then return r end
    local full = plain(UnitFullName and select(2, UnitFullName("player")))
    if full == "" then full = nil end
    if r ~= "" then
        if full then
            db._realmName = db._realmName or {}
            db._realmName[full] = r
        end
        return r
    end
    local known = full and db._realmName and db._realmName[full]
    if known then return known end
    local only, n = nil, 0
    for k in pairs(type(db._base) == "table" and db._base or {}) do
        if type(k) == "string" and k ~= "" then only, n = k, n + 1 end
    end
    if n ~= 1 then return r end
    if full then
        db._realmName = db._realmName or {}
        db._realmName[full] = only
    end
    return only
end

-- The one-pool data from before stays where it was: it belongs to the faction that has been using it (a Forever
-- PvP realm allows one faction per account), so the first faction house used here keeps the plain realm key.
local function HouseKey(house)
    local realm = AH.Realm()
    if not IS_FOREVER then return realm end
    house = house or AH:House()
    VoidUIAuctionDB._base = VoidUIAuctionDB._base or {}
    local base = VoidUIAuctionDB._base[realm]
    -- only YOUR faction claims the old pool: a lookup by name for the other faction must not take it (Sol)
    if not base and house ~= "Neutral" and house == UnitFactionGroup("player") then
        base = house
        VoidUIAuctionDB._base[realm] = base
    end
    if house == base then return realm end
    return realm .. " [" .. house .. "]"
end
AH.HouseKey = function(_, house)
    if not VoidUIAuctionDB then VoidUIAuctionDB = {} end
    return HouseKey(house)
end

local function GetRealmDB(house)
    if not VoidUIAuctionDB then VoidUIAuctionDB = {} end
    local key = HouseKey(house)
    if not VoidUIAuctionDB[key] then VoidUIAuctionDB[key] = {} end
    return VoidUIAuctionDB[key]
end

local function DayIndex()
    return tostring(math.floor(time() / DAY_SECONDS))
end

local function PruneHistory(entry)
    if not entry.h then return end
    local cutoff = math.floor(time() / DAY_SECONDS) - HISTORY_DAYS
    for k in pairs(entry.h) do
        if tonumber(k) and tonumber(k) < cutoff then
            entry.h[k] = nil
        end
    end
end

----------------------------------------------------------------------
-- Price DB API
----------------------------------------------------------------------
-- house (optional): another house's price ("Neutral" / "Horde" / "Alliance"); default = the current house
function AH:GetPrice(itemID, house)
    local db = GetRealmDB(house)
    local entry = db[tostring(itemID)]
    if entry then return entry.m end
    return nil
end

-- qty / auctions / name (optional): how many were listed, in how many auctions, and the item's
-- name, for the "Auction House anywhere" window; a call without them keeps the last values.
-- rawLow (optional): the cheapest listing when the price left dumps out; the daily history keeps the plain
-- cheapest (GetMarketMean judges dumps by it, so it must not learn from its own calls).
function AH:SetPrice(itemID, minBuyout, qty, auctions, name, rawLow)
    if not itemID or not minBuyout or minBuyout <= 0 then return end
    local db = GetRealmDB()
    local key = tostring(itemID)
    if not db[key] then
        db[key] = { m = 0, t = 0, h = {} }
    end
    local entry = db[key]
    entry.m = minBuyout
    entry.t = time()
    -- a quantity without an auction count (a browse search) clears the old count: "2 in 50"
    -- would mix two different scans (Sol review)
    -- qt: the scan the count is from; a price-only update drops it (two updates can share a second, Sol)
    if qty then entry.q, entry.n, entry.qt = qty, auctions, entry.t else entry.qt = nil end
    if type(name) == "string" and name ~= "" then entry.nm = name end

    -- Update history
    if not entry.h then entry.h = {} end
    local day = DayIndex()
    local hist = entry.h[day]
    if not rawLow and AH._pendingLow and AH._pendingLow[itemID] then   -- AH:NoteLow before the entry existed
        rawLow = AH._pendingLow[itemID]
        AH._pendingLow[itemID] = nil
    end
    local low = (rawLow and rawLow > 0 and rawLow < minBuyout) and rawLow or minBuyout
    if hist then
        hist[1] = math.min(hist[1], low)
        hist[2] = math.max(hist[2], minBuyout)
    else
        entry.h[day] = { low, minBuyout }
    end
    PruneHistory(entry)
end

-- Every item this realm's scans have seen: { ["itemID"] = { m, t, h, q, n, nm }, ... } (read-only use)
function AH:AllPrices()
    return GetRealmDB()
end

-- how many were listed at the scan that set the price (nil after a browse search, which has no count)
function AH:GetListed(itemID)
    local entry = GetRealmDB()[tostring(itemID)]
    -- only when the count is from the same scan as the price (a later price-only update keeps an old count)
    if entry and entry.q and entry.qt and entry.qt == entry.t then return entry.q end
    return nil
end

-- The plain cheapest listing seen for an item (a search that left dumps out of its price): today's history low
-- keeps it (see SetPrice's rawLow). An item not in the database yet is left to SetPrice.
function AH:NoteLow(itemID, low)
    if not (itemID and type(low) == "number" and low > 0) then return end
    local entry = GetRealmDB()[tostring(itemID)]
    if not entry then   -- not in the database yet: SetPrice puts it in today's history (Sol 11-21)
        AH._pendingLow = AH._pendingLow or {}
        AH._pendingLow[itemID] = low
        return
    end
    entry.h = entry.h or {}
    local day = DayIndex()
    local hist = entry.h[day]
    if hist then hist[1] = math.min(hist[1], low) else entry.h[day] = { low, low } end
end

function AH:GetPriceAge(itemID)
    local db = GetRealmDB()
    local entry = db[tostring(itemID)]
    if entry and entry.t and entry.t > 0 then
        return time() - entry.t
    end
    return nil
end

-- The price of an item from what's listed right now: list = { { per-unit buyout, how many }, ... }.
-- Not the first row (Forever doesn't sort them: Scroll: UPDOG read 30g from a troll listing on top), and not a
-- few listings dumped far UNDER the rest (the user, 2026-11-21: "if we have say 17 listings that range from 11g
-- to 15g and 3 listings at 30s to 1 gold someone could lose a lot of money on an item").
-- Only the cheap end decides. The real market sits at the bottom: overpriced listings pile up because nobody buys
-- them (a first try took the middle of everything listed and raised 1,130 of 6,784 prices 2x or more, e.g. Red
-- Fireworks Rocket 29c -> 14s with 332 listed). So: walking up from the cheapest, a jump to DUMP_JUMP x the price
-- below it, with at most DUMP_MAX_UNITS units and DUMP_SHARE of everything listed under the jump, marks what's under it as
-- dumps; the price is
-- the listing at the jump. No such jump: the cheapest listing, as always. Under MARKET_MIN_UNITS: the cheapest.
-- usual (optional): the item's usual daily low (GetMarketMean, 3+ days). Cheap listings that have sat there for days
-- are the market, not a dump (nobody buys them: Red Fireworks Rocket at 29c for 6 days), so with a history they
-- count as dumps only when they're also under half of it.
-- Returns price, info { lowN = units left out as dumps, low = the cheapest dump, min = the cheapest listing }, rows.
-- A dump is a HANDFUL (the user's example: 3 listings). Measured on the laptop's scan 11-21: with only "a quarter of
-- what's listed" the rule cut real supply (173 units at 25c, 26 at 1s, 13 at 27s-28s) because the long tail of hopeful
-- prices makes the total huge; at most 5 units kept 108 of its 147 calls, all small groups (3 at 2g vs 13 at 10g 60s).
local DUMP_SHARE, DUMP_JUMP, DUMP_MAX_UNITS, MARKET_MIN_UNITS = 0.2, 2, 5, 3
AH.MARKET_RULE = { share = DUMP_SHARE, jump = DUMP_JUMP, maxUnits = DUMP_MAX_UNITS, min = MARKET_MIN_UNITS }   -- for the scan log
function AH.MarketPrice(list, usual)
    local rows, total = {}, 0
    for _, l in ipairs(list or {}) do
        local u, q = l[1], math.max(1, tonumber(l[2]) or 1)
        if type(u) == "number" and u > 0 then
            rows[#rows + 1] = { u, q }
            total = total + q
        end
    end
    if #rows == 0 then return nil end
    table.sort(rows, function(a, b) return a[1] < b[1] end)
    local info = { lowN = 0, min = rows[1][1] }
    if total < MARKET_MIN_UNITS then return rows[1][1], info, rows end
    local under, cut = 0, nil
    for k = 2, #rows do
        under = under + rows[k - 1][2]
        if under > total * DUMP_SHARE or under > DUMP_MAX_UNITS then break end
        if rows[k][1] >= rows[k - 1][1] * DUMP_JUMP and not (usual and usual > 0 and rows[k - 1][1] >= usual * 0.5) then
            cut = k   -- the highest jump that qualifies (Sol 11-21: a later one that fails mustn't erase it)
        end
    end
    if not cut then return rows[1][1], info, rows end
    for i = 1, cut - 1 do info.lowN = info.lowN + rows[i][2] end
    info.low = rows[1][1]
    return rows[cut][1], info, rows
end

function AH:GetMarketMean(itemID, days)
    days = days or 7
    local db = GetRealmDB()
    local entry = db[tostring(itemID)]
    if not entry or not entry.h then return nil end

    -- MEDIAN of the daily lows, not the average: one day with a troll/sole
    -- listing (seen live: Skinning Knife 765g one day, 1g the next) dragged the
    -- average up 100x and turned 1,245 items into fake "0%" deals. With only two
    -- days there's no middle, so take the lower one (never invents a deal).
    -- Second return = how many days of data back it; callers that flag deals
    -- should want >= 3.
    local today = math.floor(time() / DAY_SECONDS)
    local lows = {}
    for i = 0, days - 1 do
        local hist = entry.h[tostring(today - i)]
        if hist then lows[#lows + 1] = hist[1] end  -- use low price
    end
    local n = #lows
    if n == 0 then return entry.m, 0 end  -- fallback to last known
    table.sort(lows)
    if n == 2 then return lows[1], 2 end
    if n % 2 == 1 then return lows[(n + 1) / 2], n end
    return math.floor((lows[n / 2] + lows[n / 2 + 1]) / 2), n
end

-- Days of history required before an item can be called a deal.
AH.MIN_DEAL_DAYS = 3

function AH:GetHistory(itemID)
    local db = GetRealmDB()
    local entry = db[tostring(itemID)]
    if entry and entry.h then return entry.h end
    return nil
end

function AH:GetDBStats()
    local db = GetRealmDB()
    local count = 0
    for _ in pairs(db) do count = count + 1 end
    return count
end

-- when THIS house's prices were last fully scanned (Forever: per house; before houses there was one time, which
-- belongs to the plain realm key)
function AH:GetLastFullScan()
    if not VoidUIAuctionDB then return 0 end
    local key = HouseKey()
    local by = VoidUIAuctionDB._lastScanBy
    -- once per-house times exist, a house without one was never fully scanned (Sol: falling back to the one
    -- global time let another realm's or house's scan make it look fresh)
    if by then return by[key] or 0 end
    if key == AH.Realm() then return VoidUIAuctionDB._lastFullScan or 0 end
    return 0
end
-- the server's limit on full scans is one timer for the whole client, whatever house
local function LastFullScanAny()
    return VoidUIAuctionDB and VoidUIAuctionDB._lastFullScan or 0
end

function AH:GetLastBrowseScan()
    if not VoidUIAuctionDB then return 0 end
    return VoidUIAuctionDB._lastBrowseScan or 0
end

-- Blizzard serves ReplicateItems (the full AH list) once per 15 min. A request
-- made inside that window is silently ignored, so the cooldown has to run from
-- the last REQUEST -- including scans that were aborted (AH closed / reload) --
-- not just the last finished scan. Otherwise a re-open asks again, nothing ever
-- arrives, and the scan hangs at 0% (0/0) forever.
local function LastReplicateRequest()
    return (VoidUIAuctionDB and VoidUIAuctionDB._lastReplicateCall) or 0
end

function AH:CanFullScan()
    local since = time() - math.max(LastFullScanAny(), LastReplicateRequest())
    return since >= FULL_SCAN_COOLDOWN
end

function AH:FullScanCooldownLeft()
    local elapsed = time() - math.max(LastFullScanAny(), LastReplicateRequest())
    return math.max(0, FULL_SCAN_COOLDOWN - elapsed)
end

----------------------------------------------------------------------
-- Throttle Queue
----------------------------------------------------------------------
function AH:_Enqueue(func)
    throttleQueue[#throttleQueue + 1] = func
    self:_TryDequeue()
end

function AH:_TryDequeue()
    -- Loop, not recursive — many queued items recursing depth-first can blow
    -- the C-stack. Each successful dequeue sets throttleReady=false and
    -- breaks out; the throttle event flips it back to true.
    while throttleReady and #throttleQueue > 0 do
        -- Our flag is only a guess: our own Post/Bid calls and Blizzard's hidden
        -- AH frame share the server throttle. Ask the real one first; if it's
        -- busy, AUCTION_HOUSE_THROTTLED_SYSTEM_READY will call us back.
        if C_AuctionHouse.IsThrottledMessageSystemReady
           and not C_AuctionHouse.IsThrottledMessageSystemReady() then
            break
        end
        throttleReady = false
        local func = table.remove(throttleQueue, 1)
        self._inFlight = func
        local ok, err = pcall(func)
        if not ok then
            print("|cffff0000VoidAH|r: Throttle error: " .. tostring(err))
            throttleReady = true
            -- continue loop to try the next item
        elseif not throttleReady then
            break  -- wait for throttle event before next dequeue
        end
        -- (A func that uses no throttle slot -- ReplicateItems -- sets throttleReady
        -- back itself; no event will follow, so keep draining.)
    end
end

function AH:_OnThrottleReady()
    throttleReady = true
    self:_TryDequeue()
end

-- Throttle-drop event handlers. Without these, queries silently disappear
-- when the AH throttle buffer fills (e.g., full scan + shopping scan overlap).
function AH:_OnThrottleDropped()
    -- The previously-dispatched query was dropped server-side. Put it back at
    -- the front (up to 3 tries) -- moving on lost it for good, leaving buy
    -- listings stuck on "Loading..." and sell prices that never arrived.
    local func = self._inFlight
    self._inFlight = nil
    if func then
        self._dropRetries = self._dropRetries or setmetatable({}, { __mode = "k" })
        local n = (self._dropRetries[func] or 0) + 1
        self._dropRetries[func] = n
        if n <= 3 then table.insert(throttleQueue, 1, func) end
    end
    throttleReady = true
    self:_TryDequeue()
end

function AH:_OnThrottleQueued()
    -- Query was queued by the server (will succeed eventually). No action.
end

function AH:GetThrottleQueueSize()
    return #throttleQueue
end

function AH:ClearThrottleQueue()
    wipe(throttleQueue)
    throttleReady = true
end

----------------------------------------------------------------------
-- Full Scan (ReplicateItems)
----------------------------------------------------------------------
function AH:StartFullScan()
    if not self.ahOpen then
        print("|cff00ffffVoidAH|r: Auction house not open.")
        return false
    end
    if not self:CanFullScan() then
        local left = self:FullScanCooldownLeft()
        print("|cff00ffffVoidAH|r: Full scan on cooldown (" .. VoidUI:FormatTime(left) .. " left).")
        return false
    end
    if self.scanning then
        print("|cff00ffffVoidAH|r: Scan already in progress.")
        return false
    end

    self.scanning = true
    self.scanType = "full"
    self.scanProgress = 0
    self.scanTotal = 0
    self.scanProcessed = 0
    self._scanMin = {}   -- this scan's listings per item: { {per-unit buyout, count}, ... } (priced at finish)
    self._scanDataAt = nil   -- set when this scan's data arrives (Sales.lua times the sales by it)
    -- and its listing counts / names: fresh every scan, so a cancelled one can't add to the
    -- next one's totals (Sol review)
    self._scanQty, self._scanN, self._scanName = {}, {}, {}
    self._scanGen = (self._scanGen or 0) + 1   -- delayed callbacks of an older scan check this

    self:_Enqueue(function()
        VoidUIAuctionDB._lastReplicateCall = time()
        C_AuctionHouse.ReplicateItems()
        -- ReplicateItems does NOT use a throttle slot or fire
        -- _SYSTEM_READY. Without this, any work queued after it would
        -- sit dead until the full scan completed (~minutes).
        throttleReady = true
        -- Watchdog: if Blizzard never answers (request inside its 15-min window,
        -- or the AH hiccuped), give up cleanly instead of hanging at 0% forever
        -- with AH.scanning blocking everything that waits on it.
        C_Timer.After(60, function()
            if self.scanning and self.scanType == "full" and (self.scanTotal or 0) == 0
               and not self._processingBatch then
                self.scanning = false
                self.scanType = nil
                self._scanMin, self._scanQty, self._scanN, self._scanName = nil, nil, nil, nil
                print("|cff00ffffVoidAH|r: Full scan got no data from Blizzard (it allows one every 15 min). Try again later.")
                if AH.OnScanComplete then SafeCall(AH.OnScanComplete, AH, "full") end
            end
        end)
    end)

    if AH.OnScanStart then SafeCall(AH.OnScanStart, AH, "full") end
    return true
end

function AH:_ProcessReplicateBatch(startIndex, totalCount)
    -- Abort if scan was cancelled
    if not self.scanning then
        self._processingBatch = false
        return
    end

    local endIndex = math.min(startIndex + BATCH_SIZE - 1, totalCount - 1)

    for i = startIndex, endIndex do
        local ok, data = pcall(function()
            -- GetReplicateItemInfo returns 18 values (0-indexed)
            local name, texture, count, qualityID, usable, level, levelType,
                  minBid, minIncrement, buyoutPrice, bidAmount, highBidder,
                  bidderFullName, owner, ownerFullName, saleStatus, itemID, hasAllInfo =
                  C_AuctionHouse.GetReplicateItemInfo(i)
            return {
                itemID = itemID,
                buyout = buyoutPrice,
                count = count or 1,
                name = name,
                -- time-left band (0-3): tells a sale from an expiry between two scans (Sales.lua)
                band = C_AuctionHouse.GetReplicateItemTimeLeft and C_AuctionHouse.GetReplicateItemTimeLeft(i),
            }
        end)
        -- every listing, also bid-only ones: how many are up and in how many auctions, and
        -- the name, for VoidAH's "Auction House anywhere" window (2026-11-09)
        if ok and data and data.itemID then
            self._scanQty = self._scanQty or {}
            self._scanN = self._scanN or {}
            self._scanName = self._scanName or {}
            self._scanQty[data.itemID] = (self._scanQty[data.itemID] or 0) + (data.count or 1)
            self._scanN[data.itemID] = (self._scanN[data.itemID] or 0) + 1
            if type(data.name) == "string" and data.name ~= "" then self._scanName[data.itemID] = data.name end
        end
        if ok and data and data.itemID and data.buyout and data.buyout > 0 then
            -- Every listing seen THIS scan (never the stored price: a price could only ever go DOWN).
            -- Priced at the finish by AH.MarketPrice: not simply the lowest one (2026-11-21).
            local perUnit = VoidAH_Money and VoidAH_Money.ReplicateUnitPrice(data.buyout, data.count)
                or math.floor(data.buyout / math.max(1, data.count or 1))
            self._scanMin = self._scanMin or {}
            local list = self._scanMin[data.itemID]
            if not list then list = {}; self._scanMin[data.itemID] = list end
            list[#list + 1] = { perUnit, data.count or 1, VoidLib.Secrets.SafeNum(data.band), data.buyout }
        end
    end

    self.scanProcessed = endIndex + 1
    self.scanProgress = self.scanProcessed / totalCount

    -- Wrap UI callback in pcall so errors don't break the batch chain
    if AH.OnScanProgress then SafeCall(AH.OnScanProgress, AH, self.scanProgress) end

    if endIndex < totalCount - 1 then
        local gen = self._scanGen
        C_Timer.After(BATCH_INTERVAL, function()
            if self._scanGen ~= gen then return end   -- that scan was aborted/replaced
            self:_ProcessReplicateBatch(endIndex + 1, totalCount)
        end)
    else
        self:_FinishFullScan()
    end
end

function AH:_FinishFullScan()
    -- Every item listed right now gets today's market price (up OR down), dumps left out (AH.MarketPrice).
    local qty, n, names = self._scanQty or {}, self._scanN or {}, self._scanName or {}
    -- the last scan's dump calls, to check the rule against real listings (2026-11-21): itemID -> "price|levels"
    -- with the cheapest 12 price levels as "unit:qty"; replaced every full scan, at most 400 items
    local log, logged = {}, 0
    for itemID, list in pairs(self._scanMin or {}) do
        local usual, nDays = self:GetMarketMean(itemID, 7)
        local price, info, rows = AH.MarketPrice(list, (nDays or 0) >= 3 and usual or nil)
        if price then
            self:SetPrice(itemID, price, qty[itemID], n[itemID], names[itemID], info and info.min)
            if info and info.lowN > 0 and logged < 400 and rows then
                local levels, last = {}, nil
                for _, r in ipairs(rows) do
                    if r[1] == last then
                        levels[#levels] = r[1] .. ":" .. (tonumber(levels[#levels]:match(":(%d+)$")) + r[2])
                    elseif #levels < 12 then
                        levels[#levels + 1] = r[1] .. ":" .. r[2]
                        last = r[1]
                    else
                        break
                    end
                end
                log[itemID] = price .. "|" .. table.concat(levels, ",")
                logged = logged + 1
            end
        end
    end
    if type(VoidUIAuctionDB) == "table" and self._scanMin then
        VoidUIAuctionDB._marketLog = { t = time(), rule = AH.MARKET_RULE, items = log }
    end
    -- what sold since this house's last scan (Sales.lua: listings gone while they still had time left)
    self._salesFound = nil
    if self._scanMin and AH.SalesFromScan then
        -- timed when the data ARRIVED (the bands were read then), not when processing finished (Sol)
        local ok, found = pcall(AH.SalesFromScan, HouseKey(), self._scanMin, self._scanDataAt or time())
        if ok then self._salesFound = found end
    end
    self._scanMin, self._scanQty, self._scanN, self._scanName = nil, nil, nil, nil
    self.scanning = false
    self.scanType = nil
    self.scanProgress = 1
    self._processingBatch = false
    -- ReplicateItems doesn't go through the AH throttle system,
    -- so THROTTLED_SYSTEM_READY may never fire — unstick the queue
    throttleReady = true
    if not VoidUIAuctionDB then VoidUIAuctionDB = {} end
    if not VoidUIAuctionDB._lastScanBy then
        -- first per-house scan: the one old time belongs to the plain pool, before it's overwritten below
        -- (else a Booty Bay scan made the faction house look freshly scanned; voidah-house-test)
        -- (0 = never: nil would fall back to the global time set just below, Sol)
        VoidUIAuctionDB._lastScanBy = { [AH.Realm()] = VoidUIAuctionDB._lastFullScan or 0 }
    end
    VoidUIAuctionDB._lastFullScan = time()
    VoidUIAuctionDB._lastScanBy[HouseKey()] = time()
    print("|cff00ffffVoidAH|r: Full scan complete. " .. self.scanProcessed .. " listings processed, " .. self:GetDBStats() .. " items in DB"
        .. (IS_FOREVER and (" (" .. self:HouseName() .. ")") or "") .. ".")
    if self._salesFound then
        print(("|cff00ffffVoidAH|r: %d units sold since this auction house's last scan."):format(self._salesFound))
    end
    if AH.OnScanComplete then SafeCall(AH.OnScanComplete, AH, "full") end
    self:_TryDequeue()   -- anything queued meanwhile would otherwise wait for an event that may not come
end

----------------------------------------------------------------------
-- Browse Scan — per-category chunked scan with delays
----------------------------------------------------------------------
local BROWSE_SCAN_CATEGORIES = { 2, 4, 0, 7, 3, 8, 9, 1, 15, 5, 16, 17 }

function AH:StartBrowseScan()
    if not self.ahOpen then
        print("|cff00ffffVoidAH|r: Auction house not open.")
        return false
    end
    if self.scanning then
        print("|cff00ffffVoidAH|r: Scan already in progress.")
        return false
    end

    self.scanning = true
    self.scanType = "browse"
    self.scanProgress = 0
    self.scanTotal = #BROWSE_SCAN_CATEGORIES
    self.scanProcessed = 0
    self._browseCatIndex = 0
    self._browseCatItems = 0
    self._browsePageCount = 0
    self._scanGen = (self._scanGen or 0) + 1   -- delayed callbacks of an older scan check this

    if AH.OnScanStart then SafeCall(AH.OnScanStart, AH, "browse") end
    self:_ScanNextCategory()
    return true
end

function AH:_ScanNextCategory()
    if not self.scanning then return end

    self._browseCatIndex = self._browseCatIndex + 1
    if self._browseCatIndex > #BROWSE_SCAN_CATEGORIES then
        self:_FinishBrowseScan()
        return
    end

    local classID = BROWSE_SCAN_CATEGORIES[self._browseCatIndex]
    local catName = GetItemClassInfo(classID) or ("Class " .. classID)
    self._browseCatClassID = classID

    self.scanProgress = (self._browseCatIndex - 1) / self.scanTotal
    if AH.OnScanProgress then SafeCall(AH.OnScanProgress, AH, self.scanProgress) end

    print("|cff00ffffVoidAH|r: Scanning " .. self._browseCatIndex .. "/" .. self.scanTotal .. ": " .. catName)

    self:_Enqueue(function()
        C_AuctionHouse.SendBrowseQuery({
            searchString = "",
            sorts = {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }},
            filters = {},
            itemClassFilters = {{ classID = classID }},
        })
    end)
end

function AH:_ProcessBrowseResults()
    local results = C_AuctionHouse.GetBrowseResults()
    if not results then return end

    -- One itemID can have several result rows (item levels, variants); the price
    -- is the cheapest of them, not whichever row came last.
    local cheapest, qty = {}, {}
    for _, result in ipairs(results) do
        if result.itemKey and result.minPrice then
            local itemID = AH.SafeNum(result.itemKey.itemID)
            local price = AH.SafeNum(result.minPrice)
            if itemID and price and price > 0 and (not cheapest[itemID] or price < cheapest[itemID]) then
                cheapest[itemID] = price
            end
            local q = AH.SafeNum(result.totalQuantity)
            if itemID and q then qty[itemID] = (qty[itemID] or 0) + q end
        end
    end
    for itemID, price in pairs(cheapest) do
        -- a browse result only has the lowest listing, no spread to judge it by (AH.MarketPrice): one far
        -- under the item's 7-day price (3+ days of data) is a dump; keep the price we had (2026-11-21)
        local mean, nDays = self:GetMarketMean(itemID, 7)
        if mean and nDays and nDays >= 3 and price < mean * 0.5 then
            self:NoteLow(itemID, price)   -- the price stays; the history still sees it (Sol 11-21)
        else
            self:SetPrice(itemID, price, qty[itemID], nil, C_Item.GetItemNameByID(itemID))
        end
    end

    self._browseCatItems = #results
    self._browsePageCount = (self._browsePageCount or 0) + 1

    local gen = self._scanGen
    if not C_AuctionHouse.HasFullBrowseResults() then
        -- Extra delay between pages to avoid rate limiting
        C_Timer.After(PAGE_DELAY, function()
            if not self.scanning or self._scanGen ~= gen then return end
            self:_Enqueue(function()
                C_AuctionHouse.RequestMoreBrowseResults()
            end)
        end)
    else
        -- This category is done — update totals
        self.scanProcessed = self.scanProcessed + self._browseCatItems
        self.scanProgress = self._browseCatIndex / self.scanTotal

        if AH.OnScanProgress then SafeCall(AH.OnScanProgress, AH, self.scanProgress) end

        if self._browseCatIndex < #BROWSE_SCAN_CATEGORIES then
            -- Delay before next category
            C_Timer.After(CATEGORY_DELAY, function()
                if not self.scanning or self._scanGen ~= gen then return end
                self:_ScanNextCategory()
            end)
        else
            self:_FinishBrowseScan()
        end
    end
end

-- A failed category query delivers no results, so nothing would advance the scan
-- and AH.scanning would block every later scan. Move on to the next category.
function AH:_OnBrowseScanFailure()
    local gen = self._scanGen
    C_Timer.After(CATEGORY_DELAY, function()
        if not self.scanning or self.scanType ~= "browse" or self._scanGen ~= gen then return end
        self:_ScanNextCategory()
    end)
end

function AH:_FinishBrowseScan()
    local totalItems = self.scanProcessed
    self.scanning = false
    self.scanType = nil
    self.scanProgress = 1
    throttleReady = true
    if not VoidUIAuctionDB then VoidUIAuctionDB = {} end
    VoidUIAuctionDB._lastBrowseScan = time()
    print("|cff00ffffVoidAH|r: Browse scan complete. " .. totalItems .. " items across " .. #BROWSE_SCAN_CATEGORIES .. " categories, " .. self:GetDBStats() .. " items in DB.")
    if AH.OnScanComplete then SafeCall(AH.OnScanComplete, AH, "browse") end
end

----------------------------------------------------------------------
-- Targeted item price query (for sell tab)
----------------------------------------------------------------------
function AH:QueryItemPrice(itemID)
    if not self.ahOpen or not itemID then return end
    local itemKey = C_AuctionHouse.MakeItemKey(itemID)
    if not itemKey then return end

    -- Use plain SendSearchQuery — the audit-commit "optimization" to
    -- SendSellSearchQuery silently broke price scanning on click in 12.0.5
    -- (function exists but doesn't deliver to our sell-tab handler).
    -- SendSearchQuery is the proven-working call for this flow.
    self:_Enqueue(function()
        -- Price sort: item (non-commodity) results aren't price-ordered by default,
        -- and the reader takes result #1 as the lowest.
        C_AuctionHouse.SendSearchQuery(itemKey,
            {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }}, false)
    end)
end

----------------------------------------------------------------------
-- Owned Auctions query
----------------------------------------------------------------------
function AH:QueryOwnedAuctions()
    if not self.ahOpen then return end
    self:_Enqueue(function()
        C_AuctionHouse.QueryOwnedAuctions({
            { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
        })
    end)
end

----------------------------------------------------------------------
-- Abort scan
----------------------------------------------------------------------
function AH:AbortScan()
    if self.scanning then
        self.scanning = false
        self.scanType = nil
        self._processingBatch = false
        self._scanGen = (self._scanGen or 0) + 1   -- orphan this scan's pending timers
        self._scanQty, self._scanN, self._scanName = nil, nil, nil
        self:ClearThrottleQueue()
        print("|cff00ffffVoidAH|r: Scan aborted.")
        if AH.OnScanComplete then SafeCall(AH.OnScanComplete, AH, "aborted") end
    end
end

----------------------------------------------------------------------
-- Deal detection
----------------------------------------------------------------------
function AH:GetDealPercent(itemID)
    local price = self:GetPrice(itemID)
    local mean, nDays = self:GetMarketMean(itemID, 7)
    if not price or not mean or mean == 0 or nDays < self.MIN_DEAL_DAYS then return nil end
    return math.floor((price / mean) * 100)
end

function AH:IsDeal(itemID)
    local cfg = VoidUI:GetModuleConfig("Auction")
    local pct = self:GetDealPercent(itemID)
    if not pct then return false end
    return pct <= (cfg.dealThreshold or 80)
end

----------------------------------------------------------------------
-- Event Frame
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")

function mod:Init()
    -- Initialize saved variables
    if not VoidUIAuctionDB then VoidUIAuctionDB = {} end

    if not AH.supported then
        -- classic auction house: leave Blizzard's window alone, say why once
        eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
        eventFrame:SetScript("OnEvent", function()
            if AH.warned then return end
            AH.warned = true
            print("|cff00c7ffVoidAH|r: this game uses the classic auction house, which VoidAH doesn't support yet — using Blizzard's.")
        end)
        return
    end

    -- Register events
    eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
    eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
    eventFrame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
    eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    eventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
    eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
    eventFrame:RegisterEvent("OWNED_AUCTIONS_UPDATED")
    eventFrame:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
    eventFrame:RegisterEvent("COMMODITY_PRICE_UPDATED")
    eventFrame:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
    -- The server's reasons a post/buy/cancel failed. Blizzard's (hidden) AH frame
    -- shows these as mid-screen red text that's easy to miss; echo them to chat.
    eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW_ERROR")
    eventFrame:RegisterEvent("AUCTION_HOUSE_POST_ERROR")
    eventFrame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
    eventFrame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
    -- Throttle backpressure events — without these, dropped queries
    -- silently disappear when the AH buffer fills.
    eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED")
    eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED")

    eventFrame:SetScript("OnEvent", function(self, event, ...)
        mod:OnEvent(event, ...)
    end)
end

function mod:Enable()
    -- Module is active
end

----------------------------------------------------------------------
-- Event Handler
----------------------------------------------------------------------
function mod:OnEvent(event, ...)
    if event == "AUCTION_HOUSE_SHOW" then
        AH.ahOpen = true
        AH.openHouse = IS_FOREVER and AH:HouseHere() or nil   -- prices read and written for THIS house until it closes
        AH.sessionStartGold = GetMoney()
        AH:ClearThrottleQueue()
        throttleReady = true

        local cfg = VoidUI:GetModuleConfig("Auction")
        local stale = cfg.autoScanWhenStale ~= false
            and (time() - (AH:GetLastFullScan() or 0)) > 12 * 3600
        if (cfg.autoScanOnOpen or stale) and AH:CanFullScan() then
            C_Timer.After(0.5, function()
                AH:StartFullScan()
            end)
        end
        if AH.OnAHShow then SafeCall(AH.OnAHShow, AH) end

    elseif event == "AUCTION_HOUSE_CLOSED" then
        AH.ahOpen = false
        AH:AbortScan()
        AH.openHouse = nil   -- after the scan stopped: nothing more is written for that house
        -- Calculate session profit
        local currentGold = GetMoney()
        AH.sessionProfit = currentGold - AH.sessionStartGold
        if AH.OnAHClose then SafeCall(AH.OnAHClose, AH) end

    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        if AH.scanning and AH.scanType == "full" and not AH._processingBatch then
            AH._processingBatch = true
            AH._scanDataAt = time()   -- the moment the listings (and their time-left bands) were read
            local count = C_AuctionHouse.GetNumReplicateItems()
            if count and count > 0 then
                AH.scanTotal = count
                AH:_ProcessReplicateBatch(0, count)
            else
                AH:_FinishFullScan()
            end
        end

    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
        or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        if AH.scanning and AH.scanType == "browse" then
            AH:_ProcessBrowseResults()
        end

    elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
        if AH.scanning and AH.scanType == "browse" then
            AH:_OnBrowseScanFailure()
        end

    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        AH:_OnThrottleReady()

    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        if AH.OnItemSearchResults then AH:OnItemSearchResults(...) end

    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        if AH.OnCommoditySearchResults then AH:OnCommoditySearchResults(...) end

    elseif event == "OWNED_AUCTIONS_UPDATED" then
        if AH.OnOwnedAuctionsUpdated then AH:OnOwnedAuctionsUpdated() end

    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
        if AH.OnAuctionCreated then AH:OnAuctionCreated() end

    elseif event == "COMMODITY_PRICE_UPDATED" then
        if AH.OnCommodityPriceUpdated then AH:OnCommodityPriceUpdated(...) end

    elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
        local err = ...
        local text = AuctionHouseUtil and AuctionHouseUtil.GetErrorText
            and AuctionHouseUtil.GetErrorText(err) or ("error " .. tostring(err))
        print("|cffff4444VoidAH|r: The auction house said: " .. tostring(text))

    elseif event == "AUCTION_HOUSE_POST_ERROR" then
        print("|cffff4444VoidAH|r: The auction house rejected that post" ..
            (AUCTION_POSTING_ERROR_TEXT and (": " .. AUCTION_POSTING_ERROR_TEXT) or "."))

    elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
        if AH.OnCommodityPriceUnavailable then AH:OnCommodityPriceUnavailable() end

    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        -- The one success event Blizzard's buy frames use. COMMODITY_PURCHASED also
        -- fires on the same buy, so handling both printed/refreshed twice.
        if AH.OnCommodityPurchaseSucceeded then AH:OnCommodityPurchaseSucceeded() end

    elseif event == "COMMODITY_PURCHASE_FAILED" then
        if AH.OnCommodityPurchaseFailed then AH:OnCommodityPurchaseFailed() end

    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
        AH:_OnThrottleDropped()

    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED" then
        AH:_OnThrottleQueued()

    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED" then
        -- Server processed a queued message — equivalent to SYSTEM_READY for queue draining.
        AH:_OnThrottleReady()
    end
end
