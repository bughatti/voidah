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
    return m
end

local function CharKey()
    local n = UnitName("player") or "?"
    local r = (GetRealmName and GetRealmName() or ""):gsub("%s+", "")
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

local function AgeText(sec)
    if not sec or sec < 3600 then return "" end
    if sec < 86400 then return (" |cff888888(%dh old)|r"):format(math.floor(sec / 3600)) end
    return (" |cff888888(%dd old)|r"):format(math.floor(sec / 86400))
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
    tt:AddLine(("|cff00c7ffVoidAH|r  AH %s each%s, you get %s after %s cut"):format(
        Money(p), AgeText(ah.GetPriceAge and ah:GetPriceAge(itemID)), Money(net), PctText(rate, learned)), 0.85, 0.85, 0.85)
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
-- A listing went up (VoidAH's Sell tab, server-confirmed).
function M.RecordPost(itemName, qty, deposit)
    if not itemName then return end
    local d = Day()
    d.posted = d.posted + 1
    if deposit and deposit > 0 then d.depPaid = d.depPaid + deposit end
    local c = Char()
    table.insert(c.pending, { name = itemName, qty = qty or 1, left = qty or 1, dep = deposit or 0, zone = Zone(), t = time() })
    while #c.pending > PENDING_MAX do table.remove(c.pending, 1) end
end

-- `count` units of this item were resolved (sold or returned): settle them against the
-- open listings. Mail carries no auction ID, so a listing of exactly that many units
-- wins (two listings of one item with different sizes stay apart); otherwise oldest
-- first, across as many listings as it takes. Returns the first listing touched and
-- the deposit those units carried.
local function ResolvePending(itemName, count)
    local c = Char()
    local remaining = math.max(1, count or 1)
    for i, p in ipairs(c.pending) do
        if p.name == itemName and (p.left or p.qty or 1) == remaining then
            local share = (p.qty and p.qty > 0) and math.floor((p.dep or 0) * remaining / p.qty + 0.5) or (p.dep or 0)
            table.remove(c.pending, i)
            return p, share
        end
    end
    local first, share = nil, 0
    local i = 1
    while i <= #c.pending and remaining > 0 do
        local p = c.pending[i]
        if p.name == itemName and (p.left or p.qty or 1) > 0 then
            p.left = p.left or p.qty or 1
            local units = math.min(remaining, p.left)
            share = share + ((p.qty and p.qty > 0) and math.floor((p.dep or 0) * units / p.qty + 0.5) or (p.dep or 0))
            p.left = p.left - units
            remaining = remaining - units
            first = first or p
            if p.left <= 0 then table.remove(c.pending, i) else i = i + 1 end
        else
            i = i + 1
        end
    end
    return first, share
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

local function ReturnedItemName(subject)
    if type(subject) ~= "string" then return nil end
    for _, fmt in ipairs({ AUCTION_EXPIRED_MAIL_SUBJECT, AUCTION_REMOVED_MAIL_SUBJECT }) do
        local pat = SubjectPattern(fmt)
        local name = pat and subject:match(pat)
        -- a returned stack's subject ends in its size: "Copper Ore (20)"
        if name then return (name:gsub("%s*%(%d+%)$", "")) end
    end
    return nil
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
            table.insert(waitMoney, { index = index, amount = cash, sender = sender, item = itemName, bid = bid,
                deposit = deposit or 0, cut = consignment or 0, count = count or 1, t = now })
        end
    end
    if items then
        local name = ReturnedItemName(subject)
        if name then
            local qty = 0
            for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
                local _, _, _, n = GetInboxItem(index, a)
                if n then qty = qty + n end
            end
            table.insert(waitItems, { subject = subject, item = name, qty = math.max(1, qty),
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
    local p = ResolvePending(w.item, w.count)
    if p and p.zone and w.sender then db.zoneHouse[p.zone] = w.sender end
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
            local _, share = ResolvePending(w.item, w.qty)
            d.depLost = d.depLost + (share or 0)
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
end

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
