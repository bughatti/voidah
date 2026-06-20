----------------------------------------------------------------------
-- VoidUI Auction Module — Engine
-- Price database, scan logic, throttle queue, public API
----------------------------------------------------------------------
local mod = VoidUI:NewModule("Auction")

-- Public API namespace
VoidUI.AH = {}
local AH = VoidUI.AH

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
        print("|cffff0000VoidUI AH callback error:|r " .. tostring(err))
    end
end

----------------------------------------------------------------------
-- Database helpers
----------------------------------------------------------------------
local function GetRealmDB()
    local realm = GetRealmName()
    if not VoidUIAuctionDB then VoidUIAuctionDB = {} end
    if not VoidUIAuctionDB[realm] then VoidUIAuctionDB[realm] = {} end
    return VoidUIAuctionDB[realm]
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
function AH:GetPrice(itemID)
    local db = GetRealmDB()
    local entry = db[tostring(itemID)]
    if entry then return entry.m end
    return nil
end

function AH:SetPrice(itemID, minBuyout)
    if not itemID or not minBuyout or minBuyout <= 0 then return end
    local db = GetRealmDB()
    local key = tostring(itemID)
    if not db[key] then
        db[key] = { m = 0, t = 0, h = {} }
    end
    local entry = db[key]
    entry.m = minBuyout
    entry.t = time()

    -- Update history
    if not entry.h then entry.h = {} end
    local day = DayIndex()
    local hist = entry.h[day]
    if hist then
        hist[1] = math.min(hist[1], minBuyout)
        hist[2] = math.max(hist[2], minBuyout)
    else
        entry.h[day] = { minBuyout, minBuyout }
    end
    PruneHistory(entry)
end

function AH:GetPriceAge(itemID)
    local db = GetRealmDB()
    local entry = db[tostring(itemID)]
    if entry and entry.t and entry.t > 0 then
        return time() - entry.t
    end
    return nil
end

function AH:GetMarketMean(itemID, days)
    days = days or 7
    local db = GetRealmDB()
    local entry = db[tostring(itemID)]
    if not entry or not entry.h then return nil end

    local today = math.floor(time() / DAY_SECONDS)
    local total, count = 0, 0
    for i = 0, days - 1 do
        local day = tostring(today - i)
        if entry.h[day] then
            total = total + entry.h[day][1]  -- use low price
            count = count + 1
        end
    end
    if count == 0 then return entry.m end  -- fallback to last known
    return math.floor(total / count)
end

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

function AH:GetLastFullScan()
    if not VoidUIAuctionDB then return 0 end
    return VoidUIAuctionDB._lastFullScan or 0
end

function AH:GetLastBrowseScan()
    if not VoidUIAuctionDB then return 0 end
    return VoidUIAuctionDB._lastBrowseScan or 0
end

function AH:CanFullScan()
    return (time() - self:GetLastFullScan()) >= FULL_SCAN_COOLDOWN
end

function AH:FullScanCooldownLeft()
    local elapsed = time() - self:GetLastFullScan()
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
        throttleReady = false
        local func = table.remove(throttleQueue, 1)
        local ok, err = pcall(func)
        if not ok then
            print("|cffff0000VoidUI AH|r: Throttle error: " .. tostring(err))
            throttleReady = true
            -- continue loop to try the next item
        else
            break  -- wait for throttle event before next dequeue
        end
    end
end

function AH:_OnThrottleReady()
    throttleReady = true
    self:_TryDequeue()
end

-- Throttle-drop event handlers. Without these, queries silently disappear
-- when the AH throttle buffer fills (e.g., full scan + shopping scan overlap).
function AH:_OnThrottleDropped()
    -- The previously-dispatched query was dropped server-side. Re-flag ready
    -- so the next dequeue can fire and re-attempt.
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
        print("|cff00ffffVoidUI AH|r: Auction house not open.")
        return false
    end
    if not self:CanFullScan() then
        local left = self:FullScanCooldownLeft()
        print("|cff00ffffVoidUI AH|r: Full scan on cooldown (" .. VoidUI:FormatTime(left) .. " left).")
        return false
    end
    if self.scanning then
        print("|cff00ffffVoidUI AH|r: Scan already in progress.")
        return false
    end

    self.scanning = true
    self.scanType = "full"
    self.scanProgress = 0
    self.scanTotal = 0
    self.scanProcessed = 0

    self:_Enqueue(function()
        C_AuctionHouse.ReplicateItems()
        -- ReplicateItems does NOT use a throttle slot or fire
        -- _SYSTEM_READY. Without this, any work queued after it would
        -- sit dead until the full scan completed (~minutes).
        throttleReady = true
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
            }
        end)
        if ok and data and data.itemID and data.buyout and data.buyout > 0 then
            local perUnit = math.floor(data.buyout / data.count)
            local current = self:GetPrice(data.itemID)
            if not current or perUnit < current then
                self:SetPrice(data.itemID, perUnit)
            end
        end
    end

    self.scanProcessed = endIndex + 1
    self.scanProgress = self.scanProcessed / totalCount

    -- Wrap UI callback in pcall so errors don't break the batch chain
    if AH.OnScanProgress then SafeCall(AH.OnScanProgress, AH, self.scanProgress) end

    if endIndex < totalCount - 1 then
        C_Timer.After(BATCH_INTERVAL, function()
            self:_ProcessReplicateBatch(endIndex + 1, totalCount)
        end)
    else
        self:_FinishFullScan()
    end
end

function AH:_FinishFullScan()
    self.scanning = false
    self.scanType = nil
    self.scanProgress = 1
    self._processingBatch = false
    -- ReplicateItems doesn't go through the AH throttle system,
    -- so THROTTLED_SYSTEM_READY may never fire — unstick the queue
    throttleReady = true
    if not VoidUIAuctionDB then VoidUIAuctionDB = {} end
    VoidUIAuctionDB._lastFullScan = time()
    print("|cff00ffffVoidUI AH|r: Full scan complete. " .. self.scanProcessed .. " listings processed, " .. self:GetDBStats() .. " items in DB.")
    if AH.OnScanComplete then SafeCall(AH.OnScanComplete, AH, "full") end
end

----------------------------------------------------------------------
-- Browse Scan — per-category chunked scan with delays
----------------------------------------------------------------------
local BROWSE_SCAN_CATEGORIES = { 2, 4, 0, 7, 3, 8, 9, 1, 15, 5, 16, 17 }

function AH:StartBrowseScan()
    if not self.ahOpen then
        print("|cff00ffffVoidUI AH|r: Auction house not open.")
        return false
    end
    if self.scanning then
        print("|cff00ffffVoidUI AH|r: Scan already in progress.")
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

    print("|cff00ffffVoidUI AH|r: Scanning " .. self._browseCatIndex .. "/" .. self.scanTotal .. ": " .. catName)

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

    for _, result in ipairs(results) do
        if result.itemKey and result.minPrice then
            local itemID = AH.SafeNum(result.itemKey.itemID)
            local price = AH.SafeNum(result.minPrice)
            if itemID and price and price > 0 then
                self:SetPrice(itemID, price)
            end
        end
    end

    self._browseCatItems = #results
    self._browsePageCount = (self._browsePageCount or 0) + 1

    if not C_AuctionHouse.HasFullBrowseResults() then
        -- Extra delay between pages to avoid rate limiting
        C_Timer.After(PAGE_DELAY, function()
            if not self.scanning then return end
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
                if not self.scanning then return end
                self:_ScanNextCategory()
            end)
        else
            self:_FinishBrowseScan()
        end
    end
end

function AH:_FinishBrowseScan()
    local totalItems = self.scanProcessed
    self.scanning = false
    self.scanType = nil
    self.scanProgress = 1
    throttleReady = true
    if not VoidUIAuctionDB then VoidUIAuctionDB = {} end
    VoidUIAuctionDB._lastBrowseScan = time()
    print("|cff00ffffVoidUI AH|r: Browse scan complete. " .. totalItems .. " items across " .. #BROWSE_SCAN_CATEGORIES .. " categories, " .. self:GetDBStats() .. " items in DB.")
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
        C_AuctionHouse.SendSearchQuery(itemKey, {}, false)
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
        self:ClearThrottleQueue()
        print("|cff00ffffVoidUI AH|r: Scan aborted.")
        if AH.OnScanComplete then SafeCall(AH.OnScanComplete, AH, "aborted") end
    end
end

----------------------------------------------------------------------
-- Deal detection
----------------------------------------------------------------------
function AH:GetDealPercent(itemID)
    local price = self:GetPrice(itemID)
    local mean = self:GetMarketMean(itemID, 7)
    if not price or not mean or mean == 0 then return nil end
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

    -- Register events
    eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
    eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
    eventFrame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    eventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
    eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
    eventFrame:RegisterEvent("OWNED_AUCTIONS_UPDATED")
    eventFrame:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
    eventFrame:RegisterEvent("COMMODITY_PRICE_UPDATED")
    eventFrame:RegisterEvent("COMMODITY_PURCHASED")
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
        AH.sessionStartGold = GetMoney()
        AH:ClearThrottleQueue()
        throttleReady = true

        local cfg = VoidUI:GetModuleConfig("Auction")
        if cfg.autoScanOnOpen and AH:CanFullScan() then
            C_Timer.After(0.5, function()
                AH:StartFullScan()
            end)
        end
        if AH.OnAHShow then SafeCall(AH.OnAHShow, AH) end

    elseif event == "AUCTION_HOUSE_CLOSED" then
        AH.ahOpen = false
        AH:AbortScan()
        -- Calculate session profit
        local currentGold = GetMoney()
        AH.sessionProfit = currentGold - AH.sessionStartGold
        if AH.OnAHClose then SafeCall(AH.OnAHClose, AH) end

    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        if AH.scanning and AH.scanType == "full" and not AH._processingBatch then
            AH._processingBatch = true
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

    elseif event == "COMMODITY_PURCHASED" then
        if AH.OnCommodityPurchaseSucceeded then AH:OnCommodityPurchaseSucceeded() end

    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        -- Modern partial-fill-aware success event (paired with COMMODITY_PURCHASE_FAILED).
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
