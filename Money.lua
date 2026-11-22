-- VoidAH Money: what selling on the Auction House really costs, what an item is worth to
-- you (AH after costs vs. vendor), and a ledger of what selling actually earned.
--
-- Costs of an AH sale:
--   * deposit: paid when you list, given back if it sells, LOST if it expires or you cancel.
--     Exact from C_AuctionHouse.Calculate*Deposit while the AH is open; elsewhere estimated
--     from the deposit / vendor-price ratio learned from your own listings.
--   * the AH cut: a % of the sale price. Not exposed by any API, and it differs by house
--     (Classic: faction 5%, neutral 15%), so it's LEARNED from your own "Auction successful"
--     mail (GetInboxInvoiceInfo: bid = sale total, deposit, consignment = the cut). Until a
--     house has a sale, 5% is assumed and every place that shows it says so ("5%?").
--   * postage: mailing items to a bank alt (GetSendMailPrice at send time).
--
-- Ledger (per character, per day, in VoidUIAuctionDB.money): sales, AH cut, deposits lost,
-- postage. Net = sale totals - cut - deposits lost - postage (refunded deposits cancel out).
-- Mail is only counted once it really happened: a sale when your gold goes up by exactly
-- that mail's amount, a returned auction when its mail leaves the inbox. Clicking "take"
-- on mail that then fails counts nothing.
--
-- Bound items (soulbound, warbound...) can't go on the AH: their value is the vendor price.
--
-- Shared API (VoidAH_Money, used by VoidQuest's reward advice):
--   VoidAH_Money.Value(itemID, vendorEach, canAuction) -> ahNet, vendor, best, "ah"|"vendor"|nil
--   VoidAH_Money.IsBoundTooltip(lines)                 -> true when tooltip lines say it's bound
VoidUI = VoidUI or {}
local M = {}
VoidAH_Money = M
local ToolKept = (select(2, ...) or {}).ToolKept   -- ForeverTools.lua (WoW Forever; nil on retail / in voidah-test)

local DEFAULT_CUT = 0.05
local PRUNE_DAYS = 120
local PENDING_MAX = 2000

local function AHDB() return VoidUI.AH end

local function DB()
    VoidUIAuctionDB = VoidUIAuctionDB or {}
    local m = VoidUIAuctionDB.money
    if type(m) ~= "table" then m = {}; VoidUIAuctionDB.money = m end
    m.cut = m.cut or {}             -- [sender] = { samples = { rate, ... } }
    m.zoneHouse = m.zoneHouse or {} -- [zone] = sender (the house your listings there sold through)
    m.depRate = m.depRate or {}     -- [duration] = { samples = { deposit / vendor value, ... } }
    m.chars = m.chars or {}         -- [Name-Realm] = { days = { [YYYY-MM-DD] = {...} }, pending = { ... } }
    m.mine = m.mine or {}           -- [house][itemID] = { { t, out, unit, units, posted, lo, hi }, ... } (your own sales)
    m.senderHouse = m.senderHouse or {} -- [mail sender] = house key (learned from your listings' sale mail)
    return m
end

local function CharKey()
    local n = UnitName("player") or "?"
    local r = ((VoidUI.AH and VoidUI.AH.Realm and VoidUI.AH.Realm()) or ""):gsub("%s+", "")
    return n .. "-" .. r
end

local function Char()
    local db = DB()
    local c = db.chars[CharKey()]
    if type(c) ~= "table" then c = {}; db.chars[CharKey()] = c end
    c.days = c.days or {}
    c.pending = c.pending or {}
    return c
end

local function Day()
    local c = Char()
    local key = date("%Y-%m-%d")
    local d = c.days[key]
    if not d then
        d = { gross = 0, cut = 0, depPaid = 0, depBack = 0, depLost = 0, postage = 0, sold = 0, expired = 0, posted = 0 }
        c.days[key] = d
    end
    return d
end

local function Median(samples)
    if not samples or #samples == 0 then return nil end
    local t = {}
    for i, v in ipairs(samples) do t[i] = v end
    table.sort(t)
    return t[math.floor((#t + 1) / 2)]
end

local function AddSample(bucket, v, keep)
    bucket.samples = bucket.samples or {}
    table.insert(bucket.samples, v)
    while #bucket.samples > (keep or 20) do table.remove(bucket.samples, 1) end
end

local function Zone() return (GetRealZoneText and GetRealZoneText()) or "?" end

local function VendorEach(itemOrLink)
    local v = select(11, C_Item.GetItemInfo(itemOrLink))
    return (type(v) == "number" and v > 0) and v or 0
end
M.VendorEach = VendorEach

----------------------------------------------------------------------
-- Cut rate
----------------------------------------------------------------------
-- The cut for the AH you'd post to here: rate, learned (bool), house (mail sender) or nil.
function M.CutRate()
    local db = DB()
    local sender = db.zoneHouse[Zone()]
    local b = sender and db.cut[sender]
    local r = b and Median(b.samples)
    if r then return r, true, sender end
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    for s, bucket in pairs(db.cut) do
        if faction and s:find(faction, 1, true) then
            r = Median(bucket.samples)
            if r then return r, true, s end
        end
    end
    return DEFAULT_CUT, false, nil
end

-- The cut on a sale total, rounded the same way everywhere.
function M.CutOf(gross, rate)
    return math.floor((gross or 0) * (rate or DEFAULT_CUT) + 0.5)
end

local function PctText(rate, learned)
    local p = math.floor(rate * 1000 + 0.5) / 10
    p = (p == math.floor(p)) and tostring(math.floor(p)) or tostring(p)
    return learned and (p .. "%") or (p .. "%?")
end
M.PctText = PctText

----------------------------------------------------------------------
-- Deposit
----------------------------------------------------------------------
-- Exact deposit while the AH is open; also learns the deposit/vendor ratio for estimates.
-- learn=false: compute only (the Sell tab redraws on every keystroke).
function M.Deposit(itemLocation, itemID, duration, qty, isCommodity, learn)
    local dep
    if C_AuctionHouse then
        if isCommodity and C_AuctionHouse.CalculateCommodityDeposit then
            local ok, v = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, duration, qty)
            dep = ok and v or nil
        elseif itemLocation and C_AuctionHouse.CalculateItemDeposit then
            local ok, v = pcall(C_AuctionHouse.CalculateItemDeposit, itemLocation, duration, qty)
            dep = ok and v or nil
        end
    end
    if type(dep) == "number" and dep >= 0 then
        local vend = VendorEach(itemID) * (qty or 1)
        if learn ~= false and vend > 0 then
            local db = DB()
            db.depRate[duration] = db.depRate[duration] or {}
            AddSample(db.depRate[duration], dep / vend)
        end
        return dep, true
    end
    return M.EstimateDeposit(itemID, duration, qty), false
end

function M.EstimateDeposit(itemID, duration, qty)
    local b = DB().depRate[duration or 3]
    local r = b and Median(b.samples)
    if not r then return nil end
    return math.floor(VendorEach(itemID) * (qty or 1) * r + 0.5)
end

----------------------------------------------------------------------
-- What an item is worth
----------------------------------------------------------------------
-- Per unit. vendorEach: the vendor price of THIS copy if known (from its link), else the
-- base item's. canAuction=false (bound copy): the AH doesn't count, only the vendor.
-- Returns ahNet (nil without scan data or when it can't be auctioned), vendor, best, source.
function M.Value(itemID, vendorEach, canAuction)
    if not itemID then return nil end
    local vendor = vendorEach or VendorEach(itemID)
    local ahNet
    if canAuction ~= false then
        local ah = AHDB()
        local p = ah and ah.GetPrice and ah:GetPrice(itemID)
        if p and p > 0 then
            local rate = M.CutRate()
            ahNet = p - M.CutOf(p, rate)
        end
    end
    if ahNet and ahNet > vendor then return ahNet, vendor, ahNet, "ah" end
    if vendor > 0 then return ahNet, vendor, vendor, "vendor" end
    return ahNet, vendor, ahNet, ahNet and "ah" or nil
end

-- Sell-tab breakdown for a listing (all copper). unitPrice: your price each, as it will be
-- posted; deposit: for the whole listing.
-- itemOrLink: the item's link when known (its vendor price can differ from the base item's).
function M.Breakdown(itemOrLink, unitPrice, qty, deposit)
    qty = qty or 1
    local rate, learned = M.CutRate()
    local gross = (unitPrice or 0) * qty
    local cut = M.CutOf(gross, rate)
    local net = gross - cut
    local vendor = VendorEach(itemOrLink) * qty
    return { gross = gross, cut = cut, net = net, vendor = vendor, deposit = deposit,
             rate = rate, learned = learned, gain = net - vendor }
end

----------------------------------------------------------------------
-- Prices read off the Auction House, one rule each (tools/cmd/voidah-test checks these):
--   an item search result / your own auction: buyoutAmount is already PER ITEM; quantity
--   counts identical listings grouped together (VoidAH divided by it from v1.1.0 to 1.8.0:
--   14 listings at 36s read as 2s 57c and the Sell tab priced under it, 2026-11-09);
--   a full-scan (replicate) row: buyoutPrice is for the whole stack of `count`.
----------------------------------------------------------------------
function M.ItemResultUnitPrice(buyoutAmount, quantity)   -- quantity deliberately unused
    if type(buyoutAmount) ~= "number" or buyoutAmount <= 0 then return nil end
    return buyoutAmount
end
function M.ReplicateUnitPrice(buyoutPrice, count)
    if type(buyoutPrice) ~= "number" or buyoutPrice <= 0 then return nil end
    return math.floor(buyoutPrice / math.max(1, count or 1))
end

-- Is this listing price a likely mistake? Returns a reason ("under half its usual 40s",
-- "less than a vendor pays") or nil. median / nDays from AH:GetMarketMean (3+ days of data
-- needed to call a price low); vendorEach = what a vendor pays for one; rate = the AH cut.
-- The Sell tab asks before posting at such a price (the user, 2026-11-09: "we cant make
-- these mistakes, people will be pissed").
function M.PriceWarning(unitPrice, median, nDays, vendorEach, rate)
    if type(unitPrice) ~= "number" or unitPrice <= 0 then return nil end
    if median and nDays and nDays >= 3 and median > 0 and unitPrice < median * 0.5 then
        return "under half its usual price", median
    end
    local net = unitPrice - math.floor(unitPrice * (rate or DEFAULT_CUT) + 0.5)
    if vendorEach and vendorEach > 0 and net < vendorEach then
        return "less than a vendor pays", vendorEach
    end
    return nil
end

local function Money(c) return VoidUI:FormatMoney(math.max(0, math.floor(c or 0))) end

function M.BreakdownText(b, depositExact, durationLabel)
    local lines = {}
    if b.deposit then
        lines[#lines + 1] = ("Deposit (%s): %s%s |cff888888- back if it sells, lost if not|r"):format(
            durationLabel or "48h", Money(b.deposit), depositExact and "" or " (est.)")
    end
    lines[#lines + 1] = ("AH cut %s: -%s  ->  you get |cffffffff%s|r%s"):format(
        PctText(b.rate, b.learned), Money(b.cut), Money(b.net),
        b.learned and "" or " |cff888888(cut learned from your first sale here)|r")
    if b.vendor > 0 then
        if b.gain > 0 then
            lines[#lines + 1] = ("Vendor: %s  ->  |cff3ddc84List it: +%s over vendor|r"):format(Money(b.vendor), Money(b.gain))
        else
            lines[#lines + 1] = ("Vendor: %s  ->  |cffff6b6bVendor it: the AH pays %s less|r"):format(Money(b.vendor), Money(-b.gain))
        end
    else
        lines[#lines + 1] = "|cff888888Vendors won't buy this.|r"
    end
    return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- Item tooltips
----------------------------------------------------------------------
local BOUND_TEXTS
local function BoundTexts()
    if BOUND_TEXTS then return BOUND_TEXTS end
    BOUND_TEXTS = {}
    for _, g in ipairs({ "ITEM_SOULBOUND", "ITEM_BIND_ON_PICKUP", "ITEM_ACCOUNTBOUND", "ITEM_BNETACCOUNTBOUND",
                         "ITEM_ACCOUNTBOUND_UNTIL_EQUIP", "ITEM_BIND_TO_ACCOUNT", "ITEM_BIND_TO_BNETACCOUNT",
                         "ITEM_BIND_QUEST", "ITEM_CONJURED" }) do
        if type(_G[g]) == "string" then BOUND_TEXTS[_G[g]] = true end
    end
    return BOUND_TEXTS
end

-- True when tooltip data lines say this copy can't be traded on the AH.
function M.IsBoundTooltip(lines)
    if type(lines) ~= "table" then return false end
    local bt = BoundTexts()
    for _, line in ipairs(lines) do
        local t = line and line.leftText
        if type(t) == "string" and not (issecretvalue and issecretvalue(t)) and bt[t] then return true end
    end
    return false
end

-- How old the price is, always (the user, 2026-11-10: "we need to have a refreshed time on these
-- tooltips for selling"); orange past 6 hours: it may have changed since
local STALE = 6 * 3600
local function AgeText(sec)
    if not sec then return "" end
    local t
    if sec < 120 then t = "just now"
    elseif sec < 3600 then t = ("%dm ago"):format(math.floor(sec / 60))
    elseif sec < 86400 then
        local h, m = math.floor(sec / 3600), math.floor((sec % 3600) / 60)
        t = m > 0 and ("%dh %dm ago"):format(h, m) or ("%dh ago"):format(h)
    else t = ("%dd ago"):format(math.floor(sec / 86400)) end
    return (sec >= STALE and " |cffff9933· %s|r" or " |cff888888· %s|r"):format(t)
end

-- "· 1 listed" / "· 12 listed": how deep the market was at that scan (unknown after a browse search)
local function ListedText(q)
    if type(q) ~= "number" or q <= 0 then return "" end
    return (q == 1 and " |cffff9933· 1 listed|r" or " |cff888888· %d listed|r"):format(q)
end

local function OnItemTooltip(tt, data)
    if not tt or (tt ~= GameTooltip and tt ~= ItemRefTooltip) then return end
    if VoidUI.GetModuleConfig then
        local cfg = VoidUI:GetModuleConfig("Auction")
        if cfg and cfg.tooltipValue == false then return end
    end
    local itemID = data and data.id
    if type(itemID) ~= "number" or (issecretvalue and issecretvalue(itemID)) then return end
    if M.IsBoundTooltip(data.lines) then return end -- can't be listed: the vendor price is the value
    local ah = AHDB()
    local p = ah and ah.GetPrice and ah:GetPrice(itemID)
    if not p or p <= 0 then return end
    local rate, learned = M.CutRate()
    local net = p - M.CutOf(p, rate)
    local vendor = VendorEach(data.hyperlink or itemID)
    local age = ah.GetPriceAge and ah:GetPriceAge(itemID)
    local listed = ah.GetListed and ah:GetListed(itemID)
    tt:AddLine(("|cff00c7ffVoidAH|r  AH %s each%s%s, you get %s after %s cut"):format(
        Money(p), ListedText(listed), AgeText(age), Money(net), PctText(rate, learned)), 0.85, 0.85, 0.85)
    -- what sells (economy steps 1-2): one line, only when something is known
    local market, mine = M.MarketSalesText(itemID, nil, true), M.MySalesText(M.MySales(itemID), true)
    if market or mine then
        tt:AddLine("  " .. (market and ("Sells: " .. market) or "") .. ((market and mine) and " · " or "")
            .. (mine and ("you " .. mine) or ""), 0.7, 0.8, 0.9)
    end
    -- a profit resting on one listing or an old price: say so where you'd act on it
    local shaky = (age and age >= STALE) or listed == 1
    -- On a merchant's page the question is buy here and resell, not list-or-vendor (the user, 2026-11-10,
    -- Grom'gol: "Worth listing: +39s over vendor (1s 50c)" on a recipe the merchant SELLS: 1s 50c is
    -- what a vendor pays you, not this merchant's price). Gold prices only; the AH deposit is not counted.
    local owner = tt.GetOwner and tt:GetOwner()
    local oname = owner and owner.GetName and owner:GetName()
    if MerchantFrame and MerchantFrame:IsShown() and MerchantFrame.selectedTab == 1 and type(oname) == "string"
        and oname:match("^MerchantItem%d+ItemButton$") and C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, owner:GetID())
        local price = ok and info and info.price
        if type(price) == "number" and not (issecretvalue and issecretvalue(price)) and price > 0 and not info.hasExtendedCost then
            local each = price / math.max(1, info.stackCount or 1)
            local stock = (info.numAvailable or -1) >= 0 and (" |cff888888(%d in stock)|r"):format(info.numAvailable) or ""
            if net > each then
                tt:AddLine(("  Buy here %s, resell on the AH: |cff3ddc84+%s profit each|r%s"):format(Money(each), Money(net - each), stock), 0.85, 0.85, 0.85)
                if shaky then tt:AddLine("  Check the AH before buying: one listing or an old price.", 1, 0.6, 0.2) end
            else
                tt:AddLine(("  Buy here %s: the AH pays %s after the cut, no profit"):format(Money(each), Money(net)), 1, 0.42, 0.42)
            end
        end
        -- on a merchant's page, never the list-or-vendor advice: an item bought with tokens / other
        -- currency (no gold price to compare) just keeps the AH line (Sol review)
        return
    end
    -- a tool / class item this character needs (ForeverTools.lua): no list-or-vendor advice, say it's kept
    -- (the user's fishing pole tooltip said "Worth listing: +91c", 2026-11-10)
    -- the copy you're hovering (bag items only): one per kind is kept, spares get the normal advice
    local keptFor
    if ToolKept and data.guid and C_Item.GetItemLocation then
        local ok, loc = pcall(C_Item.GetItemLocation, data.guid)
        if ok and loc and loc.IsBagAndSlot and loc:IsBagAndSlot() then keptFor = ToolKept(loc:GetBagAndSlot()) end
    end
    if keptFor then
        tt:AddLine(("  Kept: you need it (%s). VoidAH won't list it."):format(keptFor), 0.85, 0.75, 0.55)
        return
    end
    if vendor > 0 then
        if net > vendor then
            tt:AddLine(("  Worth listing: +%s each over vendor (%s)"):format(Money(net - vendor), Money(vendor)), 0.24, 0.86, 0.52)
        else
            tt:AddLine(("  Vendor it: a vendor pays %s, the AH %s"):format(Money(vendor), Money(net)), 1, 0.42, 0.42)
        end
    end
end

----------------------------------------------------------------------
-- Ledger: listings
----------------------------------------------------------------------
-- A listing went up (VoidAH's Sell tab, server-confirmed). info (optional): { id = itemID, unit = price each,
-- dur = 1/2/3 (12/24/48 h), house = AH.HouseKey at the post, aid = auctionID }: what your own sales are read from.
local function plainNum(v)
    if type(v) ~= "number" or (issecretvalue and issecretvalue(v)) then return nil end
    return v
end
function M.RecordPost(itemName, qty, deposit, info)
    if not itemName then return end
    local d = Day()
    d.posted = d.posted + 1
    if deposit and deposit > 0 then d.depPaid = d.depPaid + deposit end
    local c = Char()
    info = type(info) == "table" and info or {}
    table.insert(c.pending, { name = itemName, qty = qty or 1, left = qty or 1, dep = deposit or 0, zone = Zone(), t = time(),
        id = plainNum(info.id), unit = plainNum(info.unit), dur = plainNum(info.dur), house = info.house, aid = plainNum(info.aid) })
    while #c.pending > PENDING_MAX do table.remove(c.pending, 1) end
end

-- `count` units of this item were resolved (sold or returned): settle them against the
-- open listings. Mail carries no auction ID, so a listing of exactly that many units
-- wins (two listings of one item with different sizes stay apart); otherwise oldest
-- first, across as many listings as it takes. unit (a sale's price each) and house (the mail's auction house),
-- both optional, narrow it first: listings at that price and house, then at that price, then at that house, then
-- any; the exact-size rule holds inside each step, so of 20 at 40s and 5 at 60s a sale of 5 at 40s settles part of
-- the 40s listing (Sol 11-22). Returns the first listing touched, the deposit those units carried, every listing
-- touched ({ { p = listing, units = n, done = units of it settled before } }), and the units no listing covered.
local function ResolvePending(itemName, count, unit, house)
    local c = Char()
    local remaining = math.max(1, count or 1)
    local steps = {}
    if unit and house then steps[#steps + 1] = function(p) return p.unit == unit and p.house == house end end
    if unit then steps[#steps + 1] = function(p) return p.unit == unit end end
    if house then steps[#steps + 1] = function(p) return p.house == house end end
    steps[#steps + 1] = function() return true end
    -- a mail from a known house never settles a listing of ANOTHER house (Sol, release gate 11-22: a Horde sale with
    -- no Horde listing took a Booty Bay one at that price); listings of no known house (older ones) still can
    if house then
        for i, fits in ipairs(steps) do
            steps[i] = function(p) return (not p.house or p.house == house) and fits(p) end
        end
    end
    local first, share, touched = nil, 0, {}
    -- settle `units` of listing i; true when that used it up (it left the list)
    local function take(i, p, units)
        p.left = p.left or p.qty or 1
        share = share + ((p.qty and p.qty > 0) and math.floor((p.dep or 0) * units / p.qty + 0.5) or (p.dep or 0))
        touched[#touched + 1] = { p = p, units = units, done = (p.qty or p.left) - p.left }
        p.left = p.left - units
        remaining = remaining - units
        first = first or p
        if p.left <= 0 then table.remove(c.pending, i); return true end
        return false
    end
    for _, fits in ipairs(steps) do
        if remaining <= 0 then break end
        local exact
        for i, p in ipairs(c.pending) do
            if p.name == itemName and (p.left or p.qty or 1) == remaining and fits(p) then exact = i; break end
        end
        if exact then
            take(exact, c.pending[exact], remaining)
        else
            local i = 1
            while i <= #c.pending and remaining > 0 do
                local p = c.pending[i]
                if p.name == itemName and (p.left or p.qty or 1) > 0 and fits(p) then
                    if not take(i, p, math.min(remaining, p.left or p.qty or 1)) then i = i + 1 end
                else
                    i = i + 1
                end
            end
        end
    end
    return first, share, touched, remaining
end

----------------------------------------------------------------------
-- Your own sales (economy step 2, 2026-11-22): what each of your listings did
----------------------------------------------------------------------
-- The user, 2026-11-21: "finding the price that sells the quickest". Step 1 (Sales.lua) reads the whole market from
-- two scans; this is YOUR side: every listing VoidAH posted, at its price, and whether it sold (sale mail: the price
-- really paid), expired or was cancelled (return mail). Kept per auction house, for all your characters.
-- WHEN it sold: Forever's sale mail can't say (every "Auction successful" mail reads exactly 30 days left: VoidDev
-- SaleProbe, 225 mails, 2026-11-10..21), so My Auctions does: each time VoidAH reads your auctions at that house,
-- `seenAt` moves, and each time fewer units of a listing are up (fewer listed, Sold, or gone) a mark
-- { n = units gone so far, by = this read, after = the read before } goes on its timeline. A sale of units k..k+n
-- of the listing happened between the `after` and `by` of the first mark that reaches k+n (a stack bought in parts
-- gets each part's own time: Sol 11-22).
-- Records: { t = resolved, out = "sold"/"expired"/"cancelled", unit, units, posted = post time, lo, hi = seconds from
-- the post to the sale (earliest, latest; nil when the post isn't known) }. No other player's name anywhere.
local MINE_DAYS, MINE_PER_ITEM = 30, 50
local DUR_SECS = { [1] = 12 * 3600, [2] = 24 * 3600, [3] = 48 * 3600 }

local function ItemIDOf(name)
    if type(name) ~= "string" or not (C_Item and C_Item.GetItemInfoInstant) then return nil end
    local ok, id = pcall(C_Item.GetItemInfoInstant, name)
    return ok and plainNum(id) or nil
end

-- the house an auction mail came from, and whether that's sure: by its name ("Horde Auction House", "Alliance
-- Auction House"; "Blackwater Auction House" is the neutral one), else as learned from your own listings' sale mail
-- (per realm: the same sender on another realm is another house key, Sol 11-22), else a guess (the house here).
-- Retail keeps one pool anyway.
local function SenderKey(sender)
    local AH = AHDB()
    local realm = AH and AH.Realm and AH.Realm() or ""
    return realm .. "|" .. sender
end
local function SenderHouse(sender)
    local AH = AHDB()
    if not (AH and AH.HouseKey) then return nil, false end
    if type(sender) == "string" then
        if sender:find("Horde", 1, true) then return AH.HouseKey(nil, "Horde"), true end
        if sender:find("Alliance", 1, true) then return AH.HouseKey(nil, "Alliance"), true end
        if sender:find("Blackwater", 1, true) then return AH.HouseKey(nil, "Neutral"), true end
        local known = DB().senderHouse[SenderKey(sender)]
        if known then return known, true end
    end
    return AH.HouseKey(nil), false
end

local function AddMine(house, itemID, rec)
    if not house or type(itemID) ~= "number" then return end
    local db = DB()
    local per = db.mine[house]
    if not per then per = {}; db.mine[house] = per end
    local list = per[itemID]
    if not list then list = {}; per[itemID] = list end
    list[#list + 1] = rec
    while #list > MINE_PER_ITEM do table.remove(list, 1) end
end

-- seconds from the post to the sale of units done+1..done+units of listing p: earliest (the read before they were
-- seen gone), latest (the read that saw them gone, else now); never past the listing's duration
local function SoldWindow(p, done, units, now)
    if not (p and p.t) then return nil, nil end
    local target = (done or 0) + (units or 1)
    local after, by = p.seenAt or p.t, now
    for _, m in ipairs(p.marks or {}) do
        if m.n >= target then after, by = m.after, m.by; break end
    end
    local lo, hi = math.max(0, after - p.t), math.max(0, by - p.t)
    local cap = DUR_SECS[p.dur or 0]
    if cap and hi > cap then hi = cap end
    if lo > hi then lo = hi end
    return lo, hi
end

-- what was resolved for `touched` listings (ResolvePending): sold at `unit` (the sale mail's price), or returned.
-- left = sold units no listing covered (a listing VoidAH didn't post, or from before this version): the price, no time
local function RecordOutcome(out, touched, unit, sender, itemName, left)
    local now = time()
    local mailHouse, sure = SenderHouse(sender)
    local knownID
    for _, tp in ipairs(touched or {}) do
        local p = tp.p
        local house = p.house or mailHouse
        local id = p.id or ItemIDOf(itemName)
        knownID = knownID or id
        local u = (out == "sold" and unit) or p.unit
        if u then
            local lo, hi
            if out == "sold" then lo, hi = SoldWindow(p, tp.done, tp.units, now) end
            AddMine(house, id, { t = now, out = out, unit = u, units = tp.units, posted = p.t, lo = lo, hi = hi })
        end
        -- a sender the name rules don't know: learn its house from a listing that sold at exactly the mail's price
        if out == "sold" and not sure and p.house and p.unit == unit and type(sender) == "string" then
            DB().senderHouse[SenderKey(sender)] = p.house
        end
    end
    if out == "sold" and unit and (left or 0) > 0 then
        AddMine(mailHouse, ItemIDOf(itemName) or knownID, { t = now, out = out, unit = unit, units = left })
    end
end

-- p was read with q units still up (0 = sold or gone): a mark when fewer are up than at the last mark
local function Mark(p, q, now, gone)
    p.marks = p.marks or {}
    local n = math.max(0, (p.qty or 1) - q)
    local last = p.marks[#p.marks]
    if n > (last and last.n or 0) then
        p.marks[#p.marks + 1] = { n = n, by = now, after = p.seenAt or p.t, gone = gone or nil }
    end
end

-- My Auctions was read (OWNED_AUCTIONS_UPDATED): when did each of your listings still stand / sell / go.
-- Only a complete list, and only your listings of the house that's open (Forever: each house lists its own).
local function WatchOwned()
    if not (C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions and C_AuctionHouse.GetOwnedAuctionInfo) then return end
    if C_AuctionHouse.HasFullOwnedAuctionResults and not C_AuctionHouse.HasFullOwnedAuctionResults() then return end
    local AH = AHDB()
    local here = AH and AH.HouseKey and AH.HouseKey(nil)
    local open = {}
    for _, p in ipairs(Char().pending) do
        if p.aid and (not p.house or not here or p.house == here) then open[p.aid] = p end
    end
    if next(open) == nil then return end
    local now = time()
    local SOLD = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold
    local listed = {}
    for i = 1, plainNum(C_AuctionHouse.GetNumOwnedAuctions()) or 0 do
        local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
        local aid = a and plainNum(a.auctionID)
        if aid then
            listed[aid] = true
            local p = open[aid]
            if p then
                -- listed after all: a "gone" from a read that missed it was wrong
                local last = p.marks and p.marks[#p.marks]
                if last and last.gone then table.remove(p.marks) end
                local status = a.status
                if issecretvalue and issecretvalue(status) then status = nil end
                local q = (SOLD and status == SOLD) and 0 or plainNum(a.quantity) or (p.qty or 1)
                Mark(p, q, now)
                p.seenAt = now
            end
        end
    end
    -- gone from the list: sold, expired or cancelled (the mail says which). Not one posted moments ago: the
    -- list read right after a post can still be the one from before it.
    for aid, p in pairs(open) do
        if not listed[aid] and now - (p.t or now) > 10 then Mark(p, 0, now, true) end
    end
end
M._WatchOwned = WatchOwned   -- vah-mysales-test

-- Your own sales of an item at a house (default: the one open, else your faction's) in the last `days` (14):
-- { sold, soldN, soldMedian, soldLow, soldHigh, expired, expN, expLow, cancelled, within (median latest seconds to
-- sell, of the sales with a known time), withinN }. nil when nothing sold or expired.
function M.MySales(itemID, house, days)
    local AH = AHDB()
    house = house or (AH and AH.HouseKey and AH.HouseKey(nil))
    local per = house and DB().mine[house]
    local list = per and per[itemID]
    if not list or #list == 0 then return nil end
    local cut = time() - (days or 14) * 86400
    local s = { sold = 0, soldN = 0, expired = 0, expN = 0, cancelled = 0, withinN = 0 }
    local prices, times = {}, {}
    for _, r in ipairs(list) do
        if (r.t or 0) >= cut and r.unit then
            local n = r.units or 1
            if r.out == "sold" then
                s.sold, s.soldN = s.sold + n, s.soldN + 1
                s.soldLow = math.min(s.soldLow or r.unit, r.unit)
                s.soldHigh = math.max(s.soldHigh or r.unit, r.unit)
                prices[#prices + 1] = { r.unit, n }
                if r.hi then times[#times + 1] = r.hi end
            elseif r.out == "expired" then
                s.expired, s.expN = s.expired + n, s.expN + 1
                s.expLow = math.min(s.expLow or r.unit, r.unit)
            elseif r.out == "cancelled" then
                s.cancelled = s.cancelled + n
            end
        end
    end
    if s.sold == 0 and s.expired == 0 then return nil end
    if #prices > 0 then
        table.sort(prices, function(a, b) return a[1] < b[1] end)
        local run = 0
        for _, pr in ipairs(prices) do
            run = run + pr[2]
            if run * 2 >= s.sold then s.soldMedian = pr[1]; break end
        end
    end
    if #times > 0 then
        table.sort(times)
        s.within, s.withinN = times[math.floor((#times + 1) / 2)], #times
    end
    return s
end

local function Span(sec)
    if sec < 3600 then return ("%d min"):format(math.max(1, math.floor(sec / 60 + 0.5))) end
    return ("%dh"):format(math.floor(sec / 3600 + 0.5))
end

-- "sold 12 of 15 at 41s (41s-43s), usually within 2h · 3 expired, from 47s" (no colour codes; nil without data)
-- A time is said only when it's known to within half a day (a sale seen after a night away says nothing).
-- short = the tooltip's form: "sold 12 of 15 at 41s"
function M.MySalesText(s, short)
    if not s then return nil end
    local parts = {}
    if s.sold > 0 then
        local t = ("sold %d of %d at %s"):format(s.sold, s.sold + s.expired, Money(s.soldMedian or s.soldLow or 0))
        if short then return t end
        if s.soldHigh and s.soldLow and s.soldHigh > s.soldLow then
            t = t .. (" (%s-%s)"):format(Money(s.soldLow), Money(s.soldHigh))
        end
        if s.within and s.within <= 12 * 3600 then
            t = t .. (s.withinN >= 2 and ", usually within %s" or ", within %s"):format(Span(s.within))
        end
        parts[#parts + 1] = t
    else
        parts[#parts + 1] = ("none of %d sold"):format(s.expired)
        if short then return parts[1] .. (s.expLow and (", from %s"):format(Money(s.expLow)) or "") end
    end
    if s.expired > 0 and s.expLow then
        parts[#parts + 1] = ("%d expired, from %s"):format(s.expired, Money(s.expLow))
    end
    return table.concat(parts, " · ")
end

-- the market's side (Sales.lua, step 1): "240 seen sold in 24h, around 40s" (short: "240 in 24h at ~40s")
function M.MarketSalesText(itemID, house, short)
    local AH = AHDB()
    local s = AH and AH.SoldSummary and AH:SoldSummary(itemID, house, 24)
    if not s or not s.units or s.units <= 0 then return nil end
    return (short and "%d in 24h at ~%s" or "%d seen sold in 24h, around %s"):format(s.units, Money(s.median or 0))
end

----------------------------------------------------------------------
-- Ledger: mail (counted only once it really happened)
----------------------------------------------------------------------
local function SubjectPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    -- escape magic characters except the %s placeholder, then turn %s into a capture
    local pat = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)")
    return "^" .. pat .. "$"
end

-- the item a returned-auction mail is for, and why it came back ("expired" / "cancelled")
local function ReturnedItemName(subject)
    if type(subject) ~= "string" then return nil end
    for _, r in ipairs({ { AUCTION_EXPIRED_MAIL_SUBJECT, "expired" }, { AUCTION_REMOVED_MAIL_SUBJECT, "cancelled" } }) do
        local pat = SubjectPattern(r[1])
        local name = pat and subject:match(pat)
        -- a returned stack's subject ends in its size: "Copper Ore (20)"
        if name then return (name:gsub("%s*%(%d+%)$", "")), r[2] end
    end
    return nil
end

-- "Auction successful: Healing Potion (18)" -> 18 (the invoice's own count when it has none)
local function SubjectCount(subject)
    local n = type(subject) == "string" and tonumber(subject:match("%((%d+)%)%s*$"))
    return n
end

local waitMoney = {}  -- sale mail whose money was asked for: committed when gold rises by exactly that
local waitItems = {}  -- returned auctions whose items were asked for: committed when the mail leaves
local lastMoney

local function CountSubject(subject)
    local n = 0
    for i = 1, (GetInboxNumItems and GetInboxNumItems() or 0) do
        local _, _, _, s, _, _, _, itemCount = GetInboxHeaderInfo(i)
        if s == subject and (itemCount or 0) > 0 then n = n + 1 end
    end
    return n
end

local function OnTakeRequest(index, money, items)
    if not index or not GetInboxHeaderInfo then return end
    local _, _, sender, subject, cash = GetInboxHeaderInfo(index)
    local now = GetTime()
    if money and cash and cash > 0 and GetInboxInvoiceInfo then
        local invoiceType, itemName, _, bid, _, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
        local dup = false -- the same mail clicked again before it arrived
        for _, w in ipairs(waitMoney) do
            if w.index == index and w.amount == cash and w.bid == bid and w.sender == sender and now - w.t < 15 then dup = true end
        end
        if invoiceType == "seller" and type(bid) == "number" and bid > 0 and not dup then
            if not (type(count) == "number" and count > 0) then count = SubjectCount(subject) end
            table.insert(waitMoney, { index = index, amount = cash, sender = sender, item = itemName, bid = bid,
                deposit = deposit or 0, cut = consignment or 0, count = count or 1, t = now })
        end
    end
    if items then
        local name, kind = ReturnedItemName(subject)
        if name then
            local qty = 0
            for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
                local _, _, _, n = GetInboxItem(index, a)
                if n then qty = qty + n end
            end
            table.insert(waitItems, { subject = subject, item = name, qty = math.max(1, qty), kind = kind, sender = sender,
                before = CountSubject(subject), t = now })
        end
    end
end

local function CommitSale(w)
    local d = Day()
    d.gross = d.gross + w.bid
    d.cut = d.cut + w.cut
    d.depBack = d.depBack + w.deposit
    d.sold = d.sold + 1
    local db = DB()
    if w.sender and w.bid > 0 then
        db.cut[w.sender] = db.cut[w.sender] or {}
        AddSample(db.cut[w.sender], w.cut / w.bid)
    end
    -- the price really paid, each: the sale total over the units (bid, not a buyout: a bid can win under it)
    local unit = math.floor(w.bid / math.max(1, w.count or 1) + 0.5)
    local house, sure = SenderHouse(w.sender)
    local p, _, touched, left = ResolvePending(w.item, w.count, unit, sure and house or nil)
    if p and p.zone and w.sender then db.zoneHouse[p.zone] = w.sender end
    RecordOutcome("sold", touched, unit, w.sender, w.item, left)
end

local function OnMoneyChanged()
    local now = GetMoney()
    local delta = lastMoney and (now - lastMoney) or 0
    lastMoney = now
    local t = GetTime()
    for i = #waitMoney, 1, -1 do
        if t - waitMoney[i].t > 15 then table.remove(waitMoney, i) end
    end
    if delta <= 0 then return end
    for i, w in ipairs(waitMoney) do
        if w.amount == delta then
            table.remove(waitMoney, i)
            CommitSale(w)
            return
        end
    end
end

local function OnInboxChanged()
    local t = GetTime()
    local i = 1
    while i <= #waitItems do
        local w = waitItems[i]
        if CountSubject(w.subject) < w.before then
            -- one mail with this subject left the inbox: it settles this (oldest) request
            -- only; later requests for the same subject now expect one fewer.
            table.remove(waitItems, i)
            for _, o in ipairs(waitItems) do
                if o.subject == w.subject then o.before = o.before - 1 end
            end
            local d = Day()
            d.expired = d.expired + 1
            local house, sure = SenderHouse(w.sender)
            local _, share, touched = ResolvePending(w.item, w.qty, nil, sure and house or nil)
            d.depLost = d.depLost + (share or 0)
            RecordOutcome(w.kind or "expired", touched, nil, w.sender, w.item, 0)
        elseif t - w.t > 15 then
            table.remove(waitItems, i)
        else
            i = i + 1
        end
    end
end

local pendingPostage

local function Prune()
    local cutoff = date("%Y-%m-%d", time() - PRUNE_DAYS * 86400)
    for _, c in pairs(DB().chars) do
        if type(c) == "table" and c.days then
            for k in pairs(c.days) do if k < cutoff then c.days[k] = nil end end
        end
    end
    -- your own sales: MINE_DAYS, every house (also one you stopped using)
    local cut = time() - MINE_DAYS * 86400
    local mine = DB().mine
    for house, per in pairs(mine) do
        for id, list in pairs(per) do
            for i = #list, 1, -1 do
                if (list[i].t or 0) < cut then table.remove(list, i) end
            end
            if #list == 0 then per[id] = nil end
        end
        if next(per) == nil then mine[house] = nil end
    end
end
M._Prune = Prune   -- vah-mysales-test

----------------------------------------------------------------------
-- Ledger: totals and display
----------------------------------------------------------------------
function M.Totals(days, allChars)
    local db = DB()
    local cutoff = days and date("%Y-%m-%d", time() - (days - 1) * 86400) or nil
    local t = { gross = 0, cut = 0, depPaid = 0, depBack = 0, depLost = 0, postage = 0, sold = 0, expired = 0, posted = 0, held = 0 }
    for key, c in pairs(db.chars) do
        if type(c) == "table" and (allChars or key == CharKey()) then
            for day, d in pairs(c.days or {}) do
                if not cutoff or day >= cutoff then
                    for k in pairs(t) do if type(d[k]) == "number" then t[k] = t[k] + d[k] end end
                end
            end
            for _, p in ipairs(c.pending or {}) do
                local share = (p.qty and p.qty > 0) and (p.dep or 0) * (p.left or p.qty) / p.qty or (p.dep or 0)
                t.held = t.held + share
            end
        end
    end
    t.net = t.gross - t.cut - t.depLost - t.postage
    return t
end

local function Signed(c)
    c = math.floor(c + 0.5)
    if c >= 0 then return "|cff3ddc84+" .. Money(c) .. "|r" end
    return "|cffff6b6b-" .. Money(-c) .. "|r"
end
M.Signed = Signed

function M.SummaryLine()
    return ("Selling today: %s   7 days: %s"):format(Signed(M.Totals(1).net), Signed(M.Totals(7).net))
end

function M.AddLedgerTooltip(tt)
    local function block(label, t)
        tt:AddLine(label, 1, 0.82, 0)
        tt:AddDoubleLine("Sales (" .. t.sold .. ")", Money(t.gross), 0.8, 0.8, 0.8, 1, 1, 1)
        tt:AddDoubleLine("AH cut", "-" .. Money(t.cut), 0.8, 0.8, 0.8, 1, 0.42, 0.42)
        tt:AddDoubleLine("Deposits lost (" .. t.expired .. " expired/cancelled)", "-" .. Money(t.depLost), 0.8, 0.8, 0.8, 1, 0.42, 0.42)
        tt:AddDoubleLine("Postage (mail to alts)", "-" .. Money(t.postage), 0.8, 0.8, 0.8, 1, 0.42, 0.42)
        tt:AddDoubleLine("Net", Signed(t.net), 1, 1, 1, 1, 1, 1)
    end
    block("Today (this character)", M.Totals(1))
    tt:AddLine(" ")
    block("Last 7 days (this character)", M.Totals(7))
    tt:AddLine(" ")
    local all = M.Totals(nil, true)
    block("All characters, all kept days", all)
    if all.held > 0 then
        tt:AddLine(" ")
        tt:AddLine(("Deposits still riding on listings: %s (back if they sell)"):format(Money(all.held)), 0.6, 0.6, 0.6, true)
    end
    local rate, learned, house = M.CutRate()
    tt:AddLine(" ")
    tt:AddLine(learned and ("AH cut here: %s (learned from %s sales)"):format(PctText(rate, true), house or "your")
        or "AH cut not learned yet: assumed 5% until your first sale here", 0.6, 0.6, 0.6, true)
    tt:AddLine("Counts listings made with VoidAH and mail you take.", 0.5, 0.5, 0.5, true)
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_MONEY")
f:RegisterEvent("MAIL_INBOX_UPDATE")
f:RegisterEvent("MAIL_SEND_SUCCESS")
f:RegisterEvent("MAIL_FAILED")
f:RegisterEvent("OWNED_AUCTIONS_UPDATED")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        lastMoney = GetMoney()
        Prune()
        if TooltipDataProcessor and Enum.TooltipDataType then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
        end
        if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", function(i) OnTakeRequest(i, true, false) end) end
        if TakeInboxItem then hooksecurefunc("TakeInboxItem", function(i) OnTakeRequest(i, false, true) end) end
        if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", function(i) OnTakeRequest(i, true, true) end) end
        if SendMail then
            hooksecurefunc("SendMail", function()
                -- GetSendMailPrice() includes gold attached to the mail: postage is the rest
                local price = GetSendMailPrice and GetSendMailPrice() or nil
                pendingPostage = price and math.max(0, price - (GetSendMailMoney and GetSendMailMoney() or 0)) or nil
            end)
        end
    elseif event == "PLAYER_MONEY" then
        OnMoneyChanged()
    elseif event == "MAIL_INBOX_UPDATE" then
        OnInboxChanged()
    elseif event == "MAIL_SEND_SUCCESS" then
        if pendingPostage and pendingPostage > 0 then
            local d = Day()
            d.postage = d.postage + pendingPostage
        end
        pendingPostage = nil
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        pcall(WatchOwned)   -- timing only: never let it break the ledger
    elseif event == "MAIL_FAILED" then
        pendingPostage = nil
        -- a take that failed must not be matched to later gold of the same amount
        wipe(waitMoney)
    end
end)

SLASH_VOIDAHMONEY1 = "/vahmoney"
SlashCmdList.VOIDAHMONEY = function()
    local function show(label, t)
        print(("|cff00c7ffVoidAH|r %s: sales %s (%d), cut -%s, deposits lost -%s, postage -%s, net %s"):format(
            label, Money(t.gross), t.sold, Money(t.cut), Money(t.depLost), Money(t.postage), Signed(t.net)))
    end
    show("today", M.Totals(1))
    show("7 days", M.Totals(7))
    show("all characters", M.Totals(nil, true))
    local rate, learned = M.CutRate()
    print(("|cff00c7ffVoidAH|r AH cut here: %s%s"):format(PctText(rate, learned), learned and "" or " (not learned yet)"))
end
