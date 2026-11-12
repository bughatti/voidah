----------------------------------------------------------------------
-- DealModes.lua — the Deals tab's type picker and the deal types beside
-- "Below market" (the old Deals list, built in AuctionUI.lua):
--
--   Vendor -> AH   (WoW Forever, with VoidGPS) things vendors sell for less than the
--                  AH pays: recipes, pets, gear, reagents... Limited stock flagged.
--                  Opens on Recipes. Click a row for a route to the vendor.
--   AH -> Vendor   listings cheaper than what a merchant pays for them: buy, then
--                  sell to any vendor. Click a row to look it up in Browse.
--
-- The vendor lists live in VoidGPS (VoidGPS.Goods, from NorgannonDB + Blizzard's
-- Forever item data). Prices are VoidAH's own scans; profit is after the AH cut
-- VoidAH learned from your sales (Money.lua), 5% until it has.
----------------------------------------------------------------------
local FOREVER = (select(4, GetBuildInfo()) or 0) < 100000

local PROF = { [171] = "Alchemy", [164] = "Blacksmithing", [185] = "Cooking", [333] = "Enchanting",
    [202] = "Engineering", [129] = "First Aid", [356] = "Fishing", [165] = "Leatherworking", [197] = "Tailoring" }
local KIND = { r = "Recipe", p = "Pet", g = "Gear", t = "Reagent", c = "Consumable", o = "Other" }
local ROWS, ROW_H = 17, 24   -- what fits between the headers and the hint line (19 ran over it)

local function cutRate()
    local M = VoidAH_Money
    local r = M and M.CutRate and M.CutRate()
    return r or 0.05
end

local function money(c)
    if not c then return "|cff666666—|r" end
    return VoidUI:FormatMoney(c)
end

local function zoneName(map)
    local i = map and C_Map.GetMapInfo(map)
    return i and i.name or "?"
end

local function config()
    return VoidUI:GetModuleConfig("Auction")
end

----------------------------------------------------------------------
-- Shared bits: buttons, a virtual list
----------------------------------------------------------------------
local function makeButton(parent, w, h, text, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w, h)
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.15, 0.15, 0.15, 1)
    btn._bg = bg
    local fs = btn:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(fs, 10, "")
    fs:SetPoint("CENTER")
    fs:SetText(text)
    btn._text = fs
    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function() bg:SetColorTexture(0.25, 0.25, 0.25, 1) end)
    btn:SetScript("OnLeave", function() bg:SetColorTexture(btn._on and 0.12 or 0.15, btn._on and 0.30 or 0.15, btn._on and 0.36 or 0.15, 1) end)
    return btn
end

local function setOn(btn, on)
    btn._on = on
    btn._bg:SetColorTexture(on and 0.12 or 0.15, on and 0.30 or 0.15, on and 0.36 or 0.15, 1)
    btn._text:SetTextColor(on and 1 or 0.7, on and 1 or 0.7, on and 1 or 0.7)
end

local function cell(row, x, w, justify)
    local fs = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(fs, 10, "")
    fs:SetPoint("LEFT", row, "LEFT", x, 0)
    fs:SetWidth(w)
    fs:SetJustifyH(justify)
    fs:SetWordWrap(false)
    fs:SetTextColor(0.9, 0.9, 0.9)
    return fs
end

-- A list with column headers and ROWS virtual rows. cols = { { title, x, w, justify }, ... };
-- paintRow(row, data) fills row._c[i]; the frame gets :SetData(list).
local function makeList(parent, top, cols, paintRow, onClick)
    local head = CreateFrame("Frame", nil, parent)
    head:SetPoint("TOPLEFT", 10, top)
    head:SetPoint("TOPRIGHT", -10, top)
    head:SetHeight(20)
    local hb = head:CreateTexture(nil, "BACKGROUND")
    hb:SetAllPoints()
    hb:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    for _, c in ipairs(cols) do
        local fs = head:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(fs, 9, "OUTLINE")
        fs:SetPoint("LEFT", c[2], 0)
        fs:SetWidth(c[3])
        fs:SetJustifyH(c[4])
        fs:SetText("|cffaaaaaa" .. c[1] .. "|r")
    end

    local L = CreateFrame("Frame", nil, parent)
    L:SetPoint("TOPLEFT", 10, top - 22)
    L:SetPoint("BOTTOMRIGHT", -10, 22)
    L:EnableMouseWheel(true)
    L.data, L.offset, L.rows = {}, 0, {}

    local count = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(count, 9, "")
    count:SetPoint("BOTTOMRIGHT", -12, 6)
    count:SetTextColor(0.6, 0.6, 0.65)

    function L:Paint()
        local maxOff = math.max(0, #self.data - ROWS)
        if self.offset > maxOff then self.offset = maxOff end
        for i = 1, ROWS do
            local row, d = self.rows[i], self.data[self.offset + i]
            row._d = d
            if d then paintRow(row, d); row:Show() else row:Hide() end
            -- scrolled under the mouse: the tooltip follows the row's new item
            if GameTooltip:IsOwned(row) then
                if d and d.item then
                    if VoidUI.AH.ListTooltip then VoidUI.AH.ListTooltip(row) else GameTooltip:SetOwner(row, "ANCHOR_RIGHT") end
                    GameTooltip:SetItemByID(d.item)
                    GameTooltip:Show()
                else
                    GameTooltip:Hide()
                end
            end
        end
        count:SetText(#self.data == 0 and "" or ("%d–%d of %d"):format(self.offset + 1, math.min(#self.data, self.offset + ROWS), #self.data))
    end
    function L:SetData(list) self.data, self.offset = list, 0; self:Paint() end
    L:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, self.offset - delta * 3)
        self:Paint()
    end)

    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, L)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetPoint("RIGHT")
        row:RegisterForClicks("LeftButtonUp")
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        local shade = (i % 2 == 0) and 0.14 or 0.10
        bg:SetColorTexture(shade, shade, shade, 0.9)
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetPoint("LEFT", 4, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row._icon = icon
        row._c = {}
        for k, c in ipairs(cols) do row._c[k] = cell(row, c[2], c[3], c[4]) end
        row._vahDealRow = true
        row:SetScript("OnEnter", function(self)
            bg:SetColorTexture(0.20, 0.20, 0.28, 1)
            if not (self._d and self._d.item) then return end
            if VoidUI.AH.ListTooltip then VoidUI.AH.ListTooltip(self) else GameTooltip:SetOwner(self, "ANCHOR_RIGHT") end
            GameTooltip:SetItemByID(self._d.item)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() bg:SetColorTexture(shade, shade, shade, 0.9); GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if not self._d then return end
            if IsModifiedClick("CHATLINK") then
                local _, link = C_Item.GetItemInfo(self._d.item)
                -- ChatFrameUtil.InsertLink is current; ChatEdit_InsertLink only exists with the
                -- deprecation fallbacks on (Sol review)
                local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
                if link and insert then insert(link) end
                return
            end
            onClick(self._d)
        end)
        row:Hide()
        L.rows[i] = row
    end
    return L
end

-- item icon + quality-colored name into row._icon / a cell
local function itemCell(row, fs, item, fallback)
    local name, _, quality, _, _, _, _, _, _, tex = C_Item.GetItemInfo(item)
    if not name then C_Item.RequestLoadItemDataByID(item) end
    row._icon:SetTexture(tex or select(5, C_Item.GetItemInfoInstant(item)) or 134400)
    fs:SetText(name or fallback or ("Item " .. item))
    local r, g, b = 1, 1, 1
    if quality then r, g, b = C_Item.GetItemQualityColor(quality) end
    fs:SetTextColor(r, g, b)
end

----------------------------------------------------------------------
-- Vendor -> AH
----------------------------------------------------------------------
local V = { kind = "r", limitedOnly = false, pricedOnly = false }

local function goodsApi() return VoidGPS and VoidGPS.Goods end

-- VoidGPS 0.3.2+ tags offers that cost Merchant's Favor / reputation / a currency
-- (v.cost) and sets e.gold when some vendor takes plain gold. Those others aren't a
-- gold buy, so they never count as one here (older VoidGPS: everything is gold).
local function soldForGold(e)
    if not (VoidGPS and VoidGPS.Costs) then return true end
    return e.gold and true or false
end
local function goldVendor(e)
    for _, v in ipairs(e.vendors) do if not v.cost then return v end end
    return e.vendors[1]
end
local function costTag(v)
    local c = v and v.cost
    if not c then return (v and v.rep) and (" |cffff9f40(" .. v.rep .. ")|r") or "" end   -- gold, needs reputation
    if c.favor then
        return " |cffff9f40(" .. (type(c.favor) == "number" and (c.favor .. " ") or "") .. "Merchant's Favor"
            .. (c.rep and (", " .. c.rep) or "") .. ")|r"
    end
    if c.other then return " |cffff9f40(" .. c.other .. ")|r" end
    if c.rep then return " |cffff9f40(" .. c.rep .. ")|r" end
    return ""
end

local function vendorData()
    local Goods = goodsApi()
    if not Goods then return {} end
    local AH = VoidUI.AH
    local cut = cutRate()
    local out = {}
    for _, e in ipairs(Goods:All(V.kind)) do
        -- (no gold price: bought with tokens or currency, so a "profit" would be made up)
        if (e.buy or 0) > 0 and soldForGold(e) and (not V.limitedOnly or e.limited) then
            local ah = AH and AH.GetPrice and AH:GetPrice(e.item)
            if ah and ah <= 0 then ah = nil end
            if not V.pricedOnly or ah then
                local each = (e.buy or 0) / math.max(1, e.qty or 1)
                out[#out + 1] = { item = e.item, e = e, each = each, ah = ah,
                    profit = ah and math.floor(ah * (1 - cut) - each) or nil }
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.profit ~= nil) ~= (b.profit ~= nil) then return a.profit ~= nil end
        if a.profit and b.profit and a.profit ~= b.profit then return a.profit > b.profit end
        return a.e.name < b.e.name
    end)
    return out
end

local VCOLS = {
    { "Item", 30, 215, "LEFT" }, { "Type", 250, 105, "LEFT" }, { "Nearest vendor", 360, 215, "LEFT" },
    { "Stock", 578, 52, "CENTER" }, { "Vendor", 632, 62, "RIGHT" }, { "AH", 698, 70, "RIGHT" },
    { "Profit", 770, 66, "RIGHT" },
}

local function paintVendorRow(row, d)
    local e, c = d.e, row._c
    itemCell(row, c[1], e.item, e.name)
    c[2]:SetText(e.kind == "r" and ((PROF[e.line] or "Recipe") .. (e.skill and e.skill > 0 and (" " .. e.skill) or "")) or (KIND[e.kind] or ""))
    local v = goldVendor(e)
    c[3]:SetText(v and (v.name .. " |cff888888· " .. zoneName(v.map) .. "|r"
        .. (#e.vendors > 1 and (" |cff888888+" .. (#e.vendors - 1) .. "|r") or "")) or "?")
    c[4]:SetText(e.limited and "|cffffd200Limited|r" or "")
    c[5]:SetText(money(math.floor(d.each + 0.5)))
    c[6]:SetText(money(d.ah))
    if d.profit then
        c[7]:SetText((d.profit >= 0 and "|cff33ff33" or "|cffff5050-") .. VoidUI:FormatMoney(math.abs(d.profit)) .. "|r")
    else
        c[7]:SetText("|cff666666no scan|r")
    end
end

local function buildVendor(f)
    local chips = {}
    local function refresh() f.list:SetData(vendorData()) end
    local x = 10
    for _, k in ipairs({ { "r", "Recipes" }, { "p", "Pets" }, { "g", "Gear" }, { "t", "Reagents" }, { "c", "Consumables" }, { false, "All" } }) do
        local b = makeButton(f, 84, 22, k[2], nil)
        b:SetPoint("TOPLEFT", x, -32)
        b:SetScript("OnClick", function()
            V.kind = k[1] or nil
            for _, o in ipairs(chips) do setOn(o, o._kind == (V.kind or false)) end
            refresh()
        end)
        b._kind = k[1]
        chips[#chips + 1] = b
        x = x + 88
    end
    local lim, priced
    lim = makeButton(f, 100, 22, "Limited only", function()
        V.limitedOnly = not V.limitedOnly; setOn(lim, V.limitedOnly); refresh()
    end)
    lim:SetPoint("TOPRIGHT", -126, -32)
    priced = makeButton(f, 110, 22, "With AH price", function()
        V.pricedOnly = not V.pricedOnly; setOn(priced, V.pricedOnly); refresh()
    end)
    priced:SetPoint("TOPRIGHT", -10, -32)
    for _, o in ipairs(chips) do setOn(o, o._kind == (V.kind or false)) end
    setOn(lim, false); setOn(priced, false)

    f.list = makeList(f, -60, VCOLS, paintVendorRow, function(d)
        local Goods = goodsApi()
        if not Goods then return end
        local ok, vendor, map, yd = Goods:Go(d.item)
        if ok then
            print(("|cff00ffffVoidAH|r: heading to |cffffffff%s|r, %s%s."):format(vendor, zoneName(map),
                yd and (" (" .. math.floor(yd) .. " yd)") or ""))
        end
    end)

    local hint = f:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(hint, 9, "")
    hint:SetPoint("BOTTOMLEFT", 12, 6)
    hint:SetTextColor(0.6, 0.6, 0.65)
    hint:SetText("Click: the way to the nearest vendor · Shift-click: link · Wheel: scroll. Limited stock comes back after a while.")

    local empty = f:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(empty, 11, "")
    empty:SetPoint("CENTER")
    f.empty = empty
    function f:Refresh()
        if not goodsApi() then
            empty:SetText("Install |cff00c7ffVoidGPS|r (free, same author): it holds what every vendor sells and where.")
            empty:Show()
        else
            empty:Hide()
        end
        refresh()
    end
end

----------------------------------------------------------------------
-- AH -> Vendor
----------------------------------------------------------------------
local TCOLS = {
    { "Item", 30, 300, "LEFT" }, { "Lowest on AH", 340, 110, "RIGHT" }, { "Vendor pays", 460, 110, "RIGHT" },
    { "Profit each", 580, 110, "RIGHT" }, { "Scanned", 700, 130, "RIGHT" },
}

local function ago(sec)
    if not sec then return "" end
    if sec < 3600 then return math.floor(sec / 60) .. " min ago" end
    if sec < 86400 then return math.floor(sec / 3600) .. " h ago" end
    return math.floor(sec / 86400) .. " d ago"
end

local function toVendorData()
    local db = VoidUIAuctionDB and VoidUIAuctionDB[GetRealmName()]
    local out, pending = {}, 0
    if not db then return out, 0 end
    local AH = VoidUI.AH
    for key, entry in pairs(db) do
        local item = tonumber(key)
        local m = entry and entry.m
        if item and m and m > 0 then
            local name, _, _, _, _, _, _, _, _, _, sell = C_Item.GetItemInfo(item)
            if not name then
                pending = pending + 1
                if pending <= 150 then C_Item.RequestLoadItemDataByID(item) end
            elseif sell and sell > m then
                out[#out + 1] = { item = item, ah = m, sell = sell, profit = sell - m,
                    age = AH and AH.GetPriceAge and AH:GetPriceAge(item) }
            end
        end
    end
    table.sort(out, function(a, b) return a.profit > b.profit end)
    return out, pending
end

local function paintToVendorRow(row, d)
    local c = row._c
    itemCell(row, c[1], d.item)
    c[2]:SetText(money(d.ah))
    c[3]:SetText(money(d.sell))
    c[4]:SetText("|cff33ff33" .. VoidUI:FormatMoney(d.profit) .. "|r")
    c[5]:SetText("|cff888888" .. ago(d.age) .. "|r")
end

local function buildToVendor(f)
    local note = f:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(note, 10, "")
    note:SetPoint("TOPLEFT", 12, -36)
    note:SetPoint("RIGHT", -140, 0)
    note:SetJustifyH("LEFT")
    note:SetTextColor(0.7, 0.7, 0.75)
    local again = makeButton(f, 120, 22, "Check again", function() f:Refresh() end)
    again:SetPoint("TOPRIGHT", -10, -32)
    f.list = makeList(f, -60, TCOLS, paintToVendorRow, function(d)
        local name = C_Item.GetItemInfo(d.item)
        if name and VoidAH_SearchItem then VoidAH_SearchItem(name) end
    end)
    local hint = f:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(hint, 9, "")
    hint:SetPoint("BOTTOMLEFT", 12, 6)
    hint:SetTextColor(0.6, 0.6, 0.65)
    hint:SetText("Click: look it up in Browse (the listing may be gone since your scan) · Shift-click: link.")
    function f:Refresh()
        local list, pending = toVendorData()
        note:SetText(("Listings cheaper than a merchant pays: buy, then sell to any vendor. From your last scans%s.")
            :format(pending > 0 and (" (|cffffd200" .. pending .. " items still loading: Check again|r)") or ""))
        f.list:SetData(list)
    end
end

----------------------------------------------------------------------
-- Prices for materials: your AH scans or a merchant you visited (Pricing.lua),
-- else what a vendor charges (VoidGPS), else unknown
----------------------------------------------------------------------
local function unitPrice(item)
    local p = VoidAH_Price and VoidAH_Price(item)
    if p and p > 0 then return p end
    local Goods = goodsApi()
    local e = Goods and Goods:Get(item)
    if e and e.buy and e.buy > 0 and soldForGold(e) then return e.buy / math.max(1, e.qty or 1) end
    return nil
end

local function itemName(item)
    return (C_Item.GetItemInfo(item)) or ("item " .. item)
end

----------------------------------------------------------------------
-- Crafting: what your recipes cost to make vs what they sell for
----------------------------------------------------------------------
local DIFF = { [0] = "ff8040", [1] = "ffff00", [2] = "40c040", [3] = "808080" }

local function profCaches()
    if VoidProf and VoidProf.ProfCache then return VoidProf:ProfCache() end
    return VoidUIAuctionDB and VoidUIAuctionDB.profCache or {}
end

local function craftData()
    local AH = VoidUI.AH
    local cut = cutRate()
    local out, noOutput = {}, 0
    for prof, cache in pairs(profCaches()) do
        for _, r in pairs(cache.recipes or {}) do
            if r.output then
                local cost, missing, mats = 0, 0, {}
                for _, g in ipairs(r.reagents or {}) do
                  -- only what the craft needs: optional / finishing slots cost nothing unless
                  -- you add them (older caches have no `required`: then only basic reagents)
                  local needed = g.required == true or (g.required == nil and (g.reagentType == nil or g.reagentType == 1))
                  if needed then
                    local p = g.itemID and unitPrice(g.itemID)
                    if p then cost = cost + p * (g.qty or 1) else missing = missing + 1 end
                    mats[#mats + 1] = { item = g.itemID, qty = g.qty or 1, price = p }
                  end
                end
                local n = ((r.outMin or 1) + (r.outMax or r.outMin or 1)) / 2
                local ah = AH and AH.GetPrice and AH:GetPrice(r.output)
                if ah and ah <= 0 then ah = nil end
                local sell = ah and math.floor(ah * n * (1 - cut)) or nil
                out[#out + 1] = { item = r.output, prof = prof, diff = r.difficulty, mats = mats, n = n,
                    cost = math.floor(cost + 0.5), missing = missing, sell = sell,
                    profit = (sell and missing == 0) and (sell - math.floor(cost + 0.5)) or nil }
            else
                noOutput = noOutput + 1
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.profit ~= nil) ~= (b.profit ~= nil) then return a.profit ~= nil end
        if a.profit and b.profit and a.profit ~= b.profit then return a.profit > b.profit end
        return (a.sell or 0) > (b.sell or 0)
    end)
    return out, noOutput
end

local CCOLS = {
    { "Makes", 30, 250, "LEFT" }, { "Profession", 285, 130, "LEFT" }, { "Materials", 420, 100, "RIGHT" },
    { "Sells for", 525, 100, "RIGHT" }, { "Profit", 630, 100, "RIGHT" }, { "", 735, 100, "RIGHT" },
}

local function paintCraftRow(row, d)
    local c = row._c
    itemCell(row, c[1], d.item)
    if d.n > 1 then c[1]:SetText(c[1]:GetText() .. " |cff888888x" .. (d.n % 1 == 0 and d.n or ("%.1f"):format(d.n)) .. "|r") end
    c[2]:SetText((DIFF[d.diff] and ("|cff" .. DIFF[d.diff] .. "•|r ") or "") .. d.prof)
    c[3]:SetText(d.missing > 0 and ("|cffff9900" .. money(d.cost) .. "+?|r") or money(d.cost))
    c[4]:SetText(d.sell and money(d.sell) or "|cff666666no scan|r")
    if d.profit then
        c[5]:SetText((d.profit >= 0 and "|cff33ff33" or "|cffff5050-") .. VoidUI:FormatMoney(math.abs(d.profit)) .. "|r")
    else
        c[5]:SetText("")
    end
    c[6]:SetText(d.missing > 0 and ("|cffff9900" .. d.missing .. " price" .. (d.missing > 1 and "s" or "") .. " missing|r") or "")
end

local function buildCraft(f)
    local note = f:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(note, 10, "")
    note:SetPoint("TOPLEFT", 12, -36)
    note:SetPoint("RIGHT", -140, 0)
    note:SetJustifyH("LEFT")
    note:SetTextColor(0.7, 0.7, 0.75)
    local again = makeButton(f, 120, 22, "Check again", function() f:Refresh() end)
    again:SetPoint("TOPRIGHT", -10, -32)
    f.list = makeList(f, -60, CCOLS, paintCraftRow, function(d)
        local name = C_Item.GetItemInfo(d.item)
        if name and VoidAH_SearchItem then VoidAH_SearchItem(name) end
    end)
    local hint = f:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(hint, 9, "")
    hint:SetPoint("BOTTOMLEFT", 12, 6)
    hint:SetTextColor(0.6, 0.6, 0.65)
    hint:SetText("The dot is the recipe's skill color. Hover for the materials · Click: see it in Browse · Shift-click: link.")
    function f:Refresh()
        local list, noOutput = craftData()
        if #list == 0 then
            note:SetText(next(profCaches()) and "Open each profession window once (VoidProf 1.2.1 or newer) so VoidAH knows what your recipes make."
                or "Install |cff00c7ffVoidProf|r and open your profession windows: VoidAH then knows your recipes.")
        else
            note:SetText("What your recipes cost to make (your scans, merchants, vendors) and what they sell for here, after the AH cut.")
        end
        f.list:SetData(list)
    end
end

----------------------------------------------------------------------
-- Disenchant (enchanters): greens and blues cheaper than what they break into.
-- Classic's odds per item level; dust / essence / shard prices from your scans.
----------------------------------------------------------------------
-- { max item level, dust id, dust min, max, essence id, min, max, shard id, rare shard id, skill }
local DE = {
    { 15, 10940, 1, 2, 10938, 1, 2, 10978, 10978, 1 },
    { 20, 10940, 2, 3, 10939, 1, 2, 10978, 10978, 1 },
    { 25, 10940, 4, 6, 10998, 1, 2, 10978, 10978, 25 },
    { 30, 11083, 1, 2, 11082, 1, 2, 11084, 11084, 50 },
    { 35, 11083, 2, 5, 11134, 1, 2, 11138, 11138, 75 },
    { 40, 11137, 1, 2, 11135, 1, 2, 11139, 11139, 100 },
    { 45, 11137, 2, 5, 11174, 1, 2, 11177, 11177, 125 },
    { 50, 11176, 1, 2, 11175, 1, 2, 11178, 11178, 150 },
    { 55, 11176, 2, 5, 16202, 1, 2, 14343, 14343, 175 },
    { 60, 16204, 1, 2, 16203, 1, 2, 14344, 14344, 200 },
    { 65, 16204, 2, 5, 16203, 2, 3, 14344, 14344, 225 },
}

local function deRow(ilvl)
    for _, r in ipairs(DE) do if ilvl <= r[1] then return r end end
    return nil
end

local function enchantingSkill()
    if not (GetProfessions and GetProfessionInfo) then return nil end
    for _, idx in pairs({ GetProfessions() }) do   -- pairs: the list has nil gaps
        local name, _, rank, _, _, _, line = GetProfessionInfo(idx)
        if line == 333 or name == "Enchanting" then return rank or 0 end
    end
    return nil
end

-- expected value of breaking one item, or nil when a needed price is unknown; plus what it gives
local function deValue(quality, ilvl, classID)
    local r = deRow(ilvl or 0)
    if not r then return nil end
    local AH = VoidUI.AH
    local function p(id) local v = AH and AH.GetPrice and AH:GetPrice(id); return (v and v > 0) and v or nil end
    if quality == 3 then
        local s = p(r[9])
        return s, { { r[9], 1 } }, r[10]
    end
    local weapon = classID == 2
    local pd, pe, ps = weapon and 0.20 or 0.75, weapon and 0.75 or 0.20, 0.05
    local d, e, s = p(r[2]), p(r[5]), p(r[8])
    if not (d and e and s) then return nil, nil, r[10] end
    local v = pd * (r[3] + r[4]) / 2 * d + pe * (r[6] + r[7]) / 2 * e + ps * s
    return v, { { r[2], (r[3] + r[4]) / 2, pd }, { r[5], (r[6] + r[7]) / 2, pe }, { r[8], 1, ps } }, r[10]
end

local function deData()
    local db = VoidUIAuctionDB and VoidUIAuctionDB[GetRealmName()]
    local out, pending = {}, 0
    if not db then return out, 0 end
    local cut = cutRate()
    for key, entry in pairs(db) do
        local item = tonumber(key)
        local m = entry and entry.m
        if item and m and m > 0 then
            local name, _, quality, ilvl, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(item)
            if not name then
                pending = pending + 1
                if pending <= 150 then C_Item.RequestLoadItemDataByID(item) end
            elseif (quality == 2 or quality == 3) and (classID == 2 or classID == 4) then
                local v, gives, skill = deValue(quality, ilvl, classID)
                if v then
                    local net = math.floor(v * (1 - cut))
                    if net > m then
                        out[#out + 1] = { item = item, ah = m, value = net, profit = net - m, gives = gives, skill = skill }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.profit > b.profit end)
    return out, pending
end

local DCOLS = {
    { "Item", 30, 300, "LEFT" }, { "Lowest on AH", 340, 110, "RIGHT" }, { "Breaks into", 460, 110, "RIGHT" },
    { "Profit", 580, 110, "RIGHT" }, { "Needs", 700, 130, "RIGHT" },
}

local function paintDeRow(row, d)
    local c = row._c
    itemCell(row, c[1], d.item)
    c[2]:SetText(money(d.ah))
    c[3]:SetText(money(d.value))
    c[4]:SetText("|cff33ff33" .. VoidUI:FormatMoney(d.profit) .. "|r")
    local have = enchantingSkill() or 0
    c[5]:SetText((have >= (d.skill or 1)) and ("|cff888888Enchanting " .. d.skill .. "|r") or ("|cffff5050Enchanting " .. d.skill .. "|r"))
end

local function buildDisenchant(f)
    local note = f:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(note, 10, "")
    note:SetPoint("TOPLEFT", 12, -36)
    note:SetPoint("RIGHT", -140, 0)
    note:SetJustifyH("LEFT")
    note:SetTextColor(0.7, 0.7, 0.75)
    local again = makeButton(f, 120, 22, "Check again", function() f:Refresh() end)
    again:SetPoint("TOPRIGHT", -10, -32)
    f.list = makeList(f, -60, DCOLS, paintDeRow, function(d)
        local name = C_Item.GetItemInfo(d.item)
        if name and VoidAH_SearchItem then VoidAH_SearchItem(name) end
    end)
    local hint = f:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(hint, 9, "")
    hint:SetPoint("BOTTOMLEFT", 12, 6)
    hint:SetTextColor(0.6, 0.6, 0.65)
    hint:SetText("A rough estimate from Classic's disenchant odds (Forever may differ), after the AH cut. Hover for what it gives · Click: see it in Browse.")
    function f:Refresh()
        local list, pending = deData()
        local skill = enchantingSkill()
        note:SetText((skill and "" or "|cffff9900For enchanters (you don't have Enchanting).|r ")
            .. "Greens and blues that break into more than they cost. Needs your scans of dust, essences and shards"
            .. (pending > 0 and (" (|cffffd200" .. pending .. " items still loading: Check again|r)") or "") .. ".")
        f.list:SetData(list)
    end
end

----------------------------------------------------------------------
-- The picker
----------------------------------------------------------------------
local MODES = {
    { key = "below",    label = "Below market" },
    { key = "vendor",   label = "Vendor -> AH", forever = true },
    { key = "tovendor", label = "AH -> Vendor" },
    { key = "craft",    label = "Crafting" },
    { key = "de",       label = "Disenchant", forever = true },   -- Classic odds
}
local BUILD = { vendor = buildVendor, tovendor = buildToVendor, craft = buildCraft, de = buildDisenchant }

function VoidAH_BuildDealModes(parent, below)
    local frames = { below = below }
    for _, m in ipairs(MODES) do
        if m.key ~= "below" and (FOREVER or not m.forever) then
            local f = CreateFrame("Frame", nil, parent)
            f:SetAllPoints()
            f:Hide()
            BUILD[m.key](f)
            frames[m.key] = f
        end
    end

    local picker = makeButton(parent, 170, 24, "", nil)
    picker:SetPoint("TOPLEFT", 10, -4)
    picker:SetFrameLevel(parent:GetFrameLevel() + 20)
    local arrow = picker:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    arrow:SetSize(12, 12)
    arrow:SetPoint("RIGHT", -6, -3)
    picker._text:ClearAllPoints()
    picker._text:SetPoint("LEFT", 8, 0)

    local function show(key)
        if not frames[key] then key = "below" end
        config().dealMode = key
        for k, f in pairs(frames) do f:SetShown(k == key) end
        for _, m in ipairs(MODES) do
            if m.key == key then picker._text:SetText("|cff00ffff" .. m.label .. "|r") end
        end
        if frames[key].Refresh then frames[key]:Refresh() end
    end
    parent._showDealMode = show

    picker:SetScript("OnClick", function(self)
        local cur = config().dealMode or "below"
        if not (MenuUtil and MenuUtil.CreateContextMenu) then
            -- no menus: cycle
            local i = 1
            for k, m in ipairs(MODES) do if m.key == cur then i = k end end
            local nxt
            repeat i = i % #MODES + 1; nxt = MODES[i].key until frames[nxt]
            show(nxt)
            return
        end
        MenuUtil.CreateContextMenu(self, function(_, root)
            root:CreateTitle("Deal type")
            for _, m in ipairs(MODES) do
                if frames[m.key] then
                    root:CreateRadio(m.label, function(k) return k == (config().dealMode or "below") end,
                        function(k) show(k) end, m.key)
                end
            end
        end)
    end)

    -- Vendor -> AH opens on Recipes the first time on Forever (the user levels Cooking)
    local start = config().dealMode or (frames.vendor and "vendor" or "below")
    show(start)
    parent:HookScript("OnShow", function()
        local k = config().dealMode or "below"
        if frames[k] and frames[k].Refresh then frames[k]:Refresh() end
    end)

    -- item names arrive late: repaint the visible list
    local ev = CreateFrame("Frame", nil, parent)
    ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    ev:SetScript("OnEvent", function()
        if ev._pending or not parent:IsShown() then return end
        ev._pending = true
        C_Timer.After(0.4, function()
            ev._pending = nil
            local f = frames[config().dealMode or "below"]
            if f and f.list then f.list:Paint() end
        end)
    end)
end

----------------------------------------------------------------------
-- "Sold by" in a Vendor -> AH row's tooltip. From the tooltip hook: a recipe's tooltip
-- is built again when the item it teaches loads, which wiped lines added once.
----------------------------------------------------------------------
if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt)
        if tt ~= GameTooltip then return end
        local owner = tt:GetOwner()
        local d = owner and owner._vahDealRow and owner._d
        if not d then return end
        if d.mats then   -- Crafting: the materials and what each costs
            tt:AddLine(" ")
            tt:AddLine("Materials:", 0, 0.78, 1)
            for _, g in ipairs(d.mats) do
                tt:AddDoubleLine(g.qty .. "x " .. itemName(g.item),
                    g.price and money(math.floor(g.price * g.qty + 0.5)) or "|cffff9900no price|r", 1, 1, 1, 1, 1, 1)
            end
            return
        end
        if d.gives then   -- Disenchant: what it breaks into, on average
            tt:AddLine(" ")
            tt:AddLine("Breaks into (on average):", 0, 0.78, 1)
            for _, g in ipairs(d.gives) do
                tt:AddDoubleLine(((g[2] % 1 == 0) and g[2] or ("%.1f"):format(g[2])) .. "x " .. itemName(g[1]),
                    g[3] and (math.floor(g[3] * 100) .. "% of the time") or "", 1, 1, 1, 0.7, 0.7, 0.7)
            end
            return
        end
        local e = d.e
        if not e then return end
        tt:AddLine(" ")
        tt:AddLine("Sold by:", 0, 0.78, 1)
        for k, v in ipairs(e.vendors) do
            if k > 6 then tt:AddLine(("... and %d more"):format(#e.vendors - 6), 0.6, 0.6, 0.6); break end
            tt:AddDoubleLine(v.name .. (v.limited and " |cffffd200(limited)|r" or "") .. costTag(v),
                zoneName(v.map) .. (v.yards and (" · " .. math.floor(v.yards) .. " yd") or ""), 1, 1, 1, 0.7, 0.7, 0.7)
        end
        tt:AddLine("Click: the way to the nearest one for gold · Shift-click: link", 0.5, 0.8, 0.5)
    end)
end
