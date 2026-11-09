----------------------------------------------------------------------
-- Anywhere.lua — the Auction House, anywhere: look things up from your last visit.
--
-- The user, 2026-11-09: in old vanilla an AH addon "stayed open anywhere you went, it cached
-- all the data so you could open it anywhere ... to look things up based on last time
-- opened at AH data". VoidAH already keeps, per realm, every item's lowest buyout, when it
-- was seen and a daily low/high; scans now also keep how many were listed, in how many
-- auctions, and the name (Auction.lua). This window shows that, read-only, wherever you are:
-- search, categories, sort, a trend against the 7-day average, and a + to put an item on
-- VoidAH's shopping list, which is checked by itself the next time you open the AH.
-- Open: /vah away from an Auctioneer, or the VoidAH icon on the Void hub.
----------------------------------------------------------------------
VoidUI = VoidUI or {}
local W = {}
VoidUI.AHAnywhere = W

local A = { 0, 0.78, 1 }
local ROWS, ROW_H = 18, 20
local CATS = {
    { "All" },
    { "Trade Goods", 7 }, { "Consumables", 0 }, { "Recipes", 9 },
    { "Armor", 4 }, { "Weapons", 2 }, { "Other", "other" },
}
local KNOWN_CLASS = { [7] = true, [0] = true, [9] = true, [4] = true, [2] = true }

local frame, rows, scroll, search, catBtns, onlyList, sumText
local state = { cat = 1, sort = "name", desc = false, offset = 0, list = {}, onlyList = false }

local function AH() return VoidUI.AH end

local function ago(t)
    if not t or t <= 0 then return "?" end
    local s = time() - t
    if s < 3600 then return math.max(1, math.floor(s / 60)) .. "m" end
    if s < 86400 then return math.floor(s / 3600) .. "h" end
    return math.floor(s / 86400) .. "d"
end

local function money(c) return VoidUI.FormatMoney and VoidUI:FormatMoney(c) or tostring(c) end

-- the rows to show, filtered and sorted
local function build()
    local db = AH() and AH():AllPrices() or {}
    local q = search and search:GetText():lower() or ""
    local want = CATS[state.cat][2]
    local out, nameless = {}, 0
    for key, e in pairs(db) do
        local id = tonumber(key)
        if id and type(e) == "table" and (e.m or 0) > 0 then
            -- The list is your last scan and never changes while the window is open (the user:
            -- "it shouldn't blink, it's only used away from the AH"). An item whose name isn't
            -- known yet is left out; the name learner (end of file) fills those in quietly,
            -- after login and after each AH visit, for the next time.
            local name = e.nm or C_Item.GetItemNameByID(id)
            if name and not e.nm then e.nm = name end
            if not name then nameless = nameless + 1 end
            local okName = name and (q == "" or name:lower():find(q, 1, true))
            local okCat = true
            if want ~= nil then
                local classID = select(6, C_Item.GetItemInfoInstant(id))
                if want == "other" then okCat = not KNOWN_CLASS[classID] else okCat = classID == want end
            end
            local okList = not state.onlyList or (AH().ShoppingIndex and AH():ShoppingIndex(id))
            if okName and okCat and okList then
                out[#out + 1] = { id = id, name = name, m = e.m, t = e.t or 0, q = e.q, n = e.n }
            end
        end
    end
    local key, desc = state.sort, state.desc
    table.sort(out, function(a, b)
        local x, y = a[key], b[key]
        if key == "name" then x, y = a.name:lower(), b.name:lower() end
        if x == y or x == nil or y == nil then
            if (x == nil) ~= (y == nil) then return y == nil end
            if a.name ~= b.name then return a.name < b.name end
            return a.id < b.id
        end
        if desc then return x > y end
        return x < y
    end)
    state.list, state.nameless = out, nameless
    state.offset = math.max(0, math.min(state.offset, #out - ROWS))
end

local function paint()
    local list = state.list
    for i, r in ipairs(rows) do
        local d = list[state.offset + i]
        r.d = d
        if d then
            local q = C_Item.GetItemQualityByID(d.id)
            local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
            r.icon:SetTexture(C_Item.GetItemIconByID(d.id))
            r.name:SetText((c and c.hex or "|cffffffff") .. d.name .. "|r")
            -- trend against the 7-day average: green = cheaper than usual, red = dearer
            local mean = AH():GetMarketMean(d.id, 7)
            local arrow = ""
            if mean and mean > 0 then
                if d.m < mean * 0.9 then arrow = " |cff33ff33v|r" elseif d.m > mean * 1.1 then arrow = " |cffff5555^|r" end
            end
            r.price:SetText(money(d.m) .. arrow)
            r.listed:SetText(d.q and (d.n and ("%d in %d"):format(d.q, d.n) or tostring(d.q)) or "|cff666666-|r")
            r.age:SetText(ago(d.t))
            local on = AH().ShoppingIndex and AH():ShoppingIndex(d.id)
            r.add.text:SetText(on and "|cff33ff33On list|r" or "|cff00c7ff+ List|r")
            r:Show()
        else
            r:Hide()
        end
    end
    local newest = 0
    for _, e in pairs(AH():AllPrices() or {}) do
        if type(e) == "table" and (e.t or 0) > newest then newest = e.t end
    end
    local nameless = state.nameless or 0
    sumText:SetText(("%d items  ·  last price seen %s ago  ·  read-only: buy at the Auction House%s"):format(
        #list, ago(newest), nameless > 0 and ("  ·  |cff888888%d more next time (names still loading)|r"):format(nameless) or ""))
end

local function paintTabs()
    if not catBtns then return end
    local function on(b, yes) b:SetBackdropColor(0, yes and 0.25 or 0.05, yes and 0.35 or 0.07, 0.9) end
    for i, b in ipairs(catBtns) do on(b, i == state.cat) end
    on(onlyList, state.onlyList)
end

local function refresh()
    if not (frame and frame:IsShown()) then return end
    build()
    paint()
    paintTabs()
end

local function button(parent, w, h, label, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, h)
    if VoidUI.CreateBackdrop then VoidUI:CreateBackdrop(b, "transparent") end
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(A[1], A[2], A[3], 1) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(A[1], A[2], A[3], 0.5) end)
    return b
end

local function header(parent, label, key, x, w, justify)
    local h = CreateFrame("Button", nil, parent)
    h:SetSize(w, 16)
    h:SetPoint("TOPLEFT", x, -86)
    h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h.text:SetAllPoints()
    h.text:SetJustifyH(justify or "LEFT")
    h.text:SetText(label)
    h.text:SetTextColor(A[1], A[2], A[3])
    h:SetScript("OnClick", function()
        if state.sort == key then state.desc = not state.desc else state.sort, state.desc = key, key ~= "name" end
        state.offset = 0
        refresh()
    end)
    return h
end

local function create()
    frame = CreateFrame("Frame", "VoidAHAnywhereFrame", UIParent, "BackdropTemplate")
    frame:SetSize(620, 120 + ROWS * ROW_H)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    if VoidUI.CreateBackdrop then VoidUI:CreateBackdrop(frame, "transparent") end
    frame:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
    tinsert(UISpecialFrames, "VoidAHAnywhereFrame")   -- Esc closes it

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff00c7ffVoidAH|r  Auction House, from your last visit")
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    search:SetSize(180, 20)
    search:SetPoint("TOPLEFT", 18, -38)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function() state.offset = 0; refresh() end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 4, 0)
    hint:SetText("Search")
    search:HookScript("OnTextChanged", function(self) hint:SetShown(self:GetText() == "") end)

    -- row 1: search + "My list only"; row 2: the categories (on one row with the search they ran
    -- past the window's right edge; the user, 2026-11-09)
    onlyList = button(frame, 90, 18, "My list only", function()
        state.onlyList = not state.onlyList
        state.offset = 0
        refresh()
    end)
    onlyList:SetPoint("LEFT", search, "RIGHT", 10, 0)
    catBtns = {}
    local prev
    for i, c in ipairs(CATS) do
        local b = button(frame, 0, 18, c[1], function() state.cat = i; state.offset = 0; refresh() end)
        b:SetWidth(b.text:GetStringWidth() + 16)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -62) end
        catBtns[i] = b
        prev = b
    end

    header(frame, "Item", "name", 40, 240)
    header(frame, "Price", "m", 286, 120, "RIGHT")
    header(frame, "Listed", "q", 414, 80, "RIGHT")
    header(frame, "Seen", "t", 500, 40, "RIGHT")

    rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, frame)
        r:SetSize(596, ROW_H)
        r:SetPoint("TOPLEFT", 12, -102 - (i - 1) * ROW_H)
        r:RegisterForClicks("LeftButtonUp")
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(A[1], A[2], A[3], 0.10)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetPoint("LEFT", 6, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.name:SetPoint("LEFT", 28, 0)
        r.name:SetWidth(240)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)
        r.price = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.price:SetPoint("RIGHT", r, "LEFT", 394, 0)
        r.price:SetJustifyH("RIGHT")
        r.listed = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.listed:SetPoint("RIGHT", r, "LEFT", 482, 0)
        r.listed:SetJustifyH("RIGHT")
        r.age = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.age:SetPoint("RIGHT", r, "LEFT", 528, 0)
        r.age:SetJustifyH("RIGHT")
        r.add = button(r, 56, 16, "+ List", function()
            local d = r.d
            if d then
                AH():ToggleShopping(d.id, d.name)
                -- with "My list only" a removed item has to leave the list (Sol review)
                if state.onlyList then refresh() else paint() end
            end
        end)
        r.add:SetPoint("RIGHT", -2, 0)
        r.add:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(A[1], A[2], A[3], 1)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Shopping list")
            GameTooltip:AddLine("VoidAH checks your shopping list by itself the next time you open the Auction House, and tells you what's cheap.", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        r.add:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(A[1], A[2], A[3], 0.5)
            GameTooltip:Hide()
        end)
        r:SetScript("OnClick", function(self)
            if self.d and IsModifiedClick("CHATLINK") then
                local _, link = C_Item.GetItemInfo(self.d.id)
                if link then ChatEdit_InsertLink(link) end
            end
        end)
        r:SetScript("OnEnter", function(self)
            local d = self.d
            if not d then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(d.id)
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("|cff00c7ffVoidAH|r lowest buyout", money(d.m), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("seen", ago(d.t) .. " ago", 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
            local mean = AH():GetMarketMean(d.id, 7)
            if mean and mean > 0 then
                GameTooltip:AddDoubleLine("7-day average", money(math.floor(mean)), 0.8, 0.8, 0.8, 1, 1, 1)
            end
            if d.q then
                GameTooltip:AddDoubleLine("listed", d.n and ("%d in %d auctions"):format(d.q, d.n) or tostring(d.q), 0.8, 0.8, 0.8, 1, 1, 1)
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = r
    end
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        state.offset = math.max(0, math.min(#state.list - ROWS, state.offset - delta * 3))
        paint()
    end)

    sumText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sumText:SetPoint("BOTTOMLEFT", 14, 10)

    -- built once when it opens; after that only your own search / sort / category clicks
    -- change it (no events, no timers: the user, "it shouldn't blink")
    frame:SetScript("OnShow", function() refresh() end)
    frame:Hide()
end

function W:Toggle()
    if not frame then create() end
    frame:SetShown(not frame:IsShown())   -- OnShow refreshes
end

----------------------------------------------------------------------
-- Name learner: scans before 2026-11-09 kept no item names. Quietly, outside the window:
-- 20 s after login and 5 s after each AH visit, ask the game for the names still missing,
-- a few dozen at a time, and save each one on its item (entry.nm), so it's asked once ever.
----------------------------------------------------------------------
do
    local BATCH, EVERY = 30, 0.25
    local queue, at, ticker = nil, 0, nil
    local asked = {}   -- itemID -> true until its answer is saved (answers can come late; Sol review)

    local function step()
        if not queue or at >= #queue then
            if ticker then ticker:Cancel(); ticker = nil end
            queue = nil
            return
        end
        for i = at + 1, math.min(#queue, at + BATCH) do
            asked[queue[i]] = true
            C_Item.RequestLoadItemDataByID(queue[i])
        end
        at = math.min(#queue, at + BATCH)
    end

    local function start()
        if ticker or not AH() then return end
        local q = {}
        for key, e in pairs(AH():AllPrices() or {}) do
            local id = tonumber(key)
            if id and type(e) == "table" and not e.nm then
                local name = C_Item.GetItemNameByID(id)
                if name then e.nm = name else q[#q + 1] = id end
            end
        end
        if #q == 0 then return end
        queue, at = q, 0
        ticker = C_Timer.NewTicker(EVERY, step)
    end

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_LOGIN")
    ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
    ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    pcall(ev.RegisterEvent, ev, "ITEM_DATA_LOAD_RESULT")   -- RequestLoadItemDataByID's own answer
    ev:SetScript("OnEvent", function(_, event, itemID)
        if event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
            if not (itemID and asked[itemID]) then return end
            local name = C_Item.GetItemNameByID(itemID)
            if not name then return end
            asked[itemID] = nil
            local e = AH() and AH():AllPrices()[tostring(itemID)]
            if e and not e.nm then e.nm = name end
        elseif event == "PLAYER_LOGIN" then
            C_Timer.After(20, start)
        else
            C_Timer.After(5, start)
        end
    end)
end

-- the Void hub's icon ring: VoidAH has no minimap button of its own
VoidHubLaunchers = VoidHubLaunchers or {}
VoidHubLaunchers.VoidAH = {
    icon = "Interface\\Icons\\INV_Misc_Coin_02",
    onClick = function() W:Toggle() end,
}
