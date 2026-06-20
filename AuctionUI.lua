----------------------------------------------------------------------
-- VoidUI AuctionUI Module
-- Full AH replacement panel: Browse, Sell, My Auctions, Deals, Scan
----------------------------------------------------------------------
local AH = VoidUI.AH

local PANEL_W, PANEL_H = 900, 620
local TAB_NAMES = { "Browse", "Sell", "My Auctions", "Deals", "Scan", "Professions" }
local ROW_HEIGHT = 24
local VISIBLE_ROWS = 16
local LIST_WIDTH = 860

-- State
local panel, tabFrames, tabButtons, statusBar
local activeTab = 1  -- default to Browse tab
local browseResults = {}
local dealResults = {}

-- Shopping list scan state
local shopQueryPending = {}    -- map[itemID] = true during scan
local shopQueryActive = false
local shopAlertResults = {}    -- { {itemID, name, price, threshold}, ... }

-- Buy target — set when user clicks "Buy" on Professions tab. Browse tab shows
-- a banner: "Need 940x Tranquility Bloom (have 0 in bags)". Resets when reached.
local currentBuyTarget = nil  -- { itemName, itemID, qtyNeeded }

-- Global so all tabs and event handlers can refresh the banner.
function VoidAH_UpdateBuyTargetBanner()
    if not tabFrames or not tabFrames[1] or not tabFrames[1]._buyBanner then return end
    local banner = tabFrames[1]._buyBanner
    local t = currentBuyTarget
    if not t then
        banner:Hide()
        return
    end
    local have = 0
    if t.itemID and GetItemCount then
        have = GetItemCount(t.itemID, true) or 0  -- include bank
    end
    local pct = math.min(100, math.floor(have / math.max(1, t.qtyNeeded) * 100))
    local color, status
    if have >= t.qtyNeeded then
        color = "|cff00ff00"
        status = "DONE — clear to remove banner"
    else
        color = "|cffffd200"
        status = string.format("(%d%% — need %d more)", pct, t.qtyNeeded - have)
    end
    banner._text:SetText(string.format(
        "%sTarget:|r %dx %s  —  |cffffffffhave %d|r  %s%s|r",
        color, t.qtyNeeded, t.itemName, have, color, status))
    banner:Show()
end

-- Auto-refresh banner when bags change (any item picked up/bought)
local buyTargetWatcher = CreateFrame("Frame")
buyTargetWatcher:RegisterEvent("BAG_UPDATE_DELAYED")
buyTargetWatcher:SetScript("OnEvent", function()
    if currentBuyTarget then VoidAH_UpdateBuyTargetBanner() end
end)

----------------------------------------------------------------------
-- Profession Recipe Cache
-- When the trade skill window is open we snapshot every learned recipe
-- + its reagents, store in VoidUIAuctionDB.profCache, so the Professions
-- tab can compute cheapest leveling paths against live AH price data.
----------------------------------------------------------------------
local function CaptureTradeSkillSnapshot()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetBaseProfessionInfo then return end
    local prof = C_TradeSkillUI.GetBaseProfessionInfo()
    if not prof or not prof.professionName then return end

    -- 12.0.7 removed GetAllRecipeIDs; GetFilteredRecipeIDs is the replacement
    -- (Blizzard's own Professions UI uses it). With default filters it returns
    -- the full learned set, which we then gate per-recipe on rInfo.learned.
    local recipeIDs = C_TradeSkillUI.GetFilteredRecipeIDs()
    if not recipeIDs or #recipeIDs == 0 then return end

    VoidUIAuctionDB = VoidUIAuctionDB or {}
    VoidUIAuctionDB.profCache = VoidUIAuctionDB.profCache or {}

    local cache = {
        professionID  = prof.professionID,
        skillLine     = prof.skillLine,
        lastSync      = time(),
        skillRank     = 0,
        skillMaxRank  = 0,
        recipes       = {},
        learnedCount  = 0,
    }

    -- Player's current skill. 12.0.7 removed GetTradeSkillLineInfoByID, but
    -- GetBaseProfessionInfo's ProfessionInfo already carries skillLevel/
    -- maxSkillLevel, so read them straight off prof.
    cache.skillRank    = prof.skillLevel or 0
    cache.skillMaxRank = prof.maxSkillLevel or 100

    for _, rID in ipairs(recipeIDs) do
        local rInfo = C_TradeSkillUI.GetRecipeInfo(rID)
        if rInfo and rInfo.learned then
            local reagents = {}
            local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, rID, false)
            if ok and schematic and schematic.reagentSlotSchematics then
                for _, slot in ipairs(schematic.reagentSlotSchematics) do
                    if slot.reagents and slot.reagents[1] and slot.reagents[1].itemID then
                        reagents[#reagents + 1] = {
                            itemID = slot.reagents[1].itemID,
                            qty    = slot.quantityRequired or 1,
                        }
                    end
                end
            end
            cache.recipes[rID] = {
                id         = rID,
                name       = rInfo.name,
                difficulty = rInfo.relativeDifficulty,  -- 1=orange 2=yellow 3=green 4=grey
                categoryID = rInfo.categoryID,
                reagents   = reagents,
            }
            cache.learnedCount = cache.learnedCount + 1
        end
    end

    VoidUIAuctionDB.profCache[prof.professionName] = cache
    -- Notify the Professions tab if it's currently rendering this profession
    if VoidUI._onProfCacheUpdate then VoidUI._onProfCacheUpdate(prof.professionName) end
end

local profCacheFrame = CreateFrame("Frame")
profCacheFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
profCacheFrame:RegisterEvent("TRADE_SKILL_SHOW")
profCacheFrame:SetScript("OnEvent", function(_, event)
    -- TRADE_SKILL_LIST_UPDATE fires after recipes finish loading; that's
    -- when GetFilteredRecipeIDs returns a complete list.
    if event == "TRADE_SKILL_LIST_UPDATE" then
        CaptureTradeSkillSnapshot()
    end
end)

----------------------------------------------------------------------
-- Browse tab state machine
----------------------------------------------------------------------
local BROWSE_VIEW_TREE = 1
local BROWSE_VIEW_RESULTS = 2
local browseView = BROWSE_VIEW_TREE
local selectedClassID = nil
local selectedSubClassID = nil
local expandedCategories = {}
local treeFlatList = {}
local pendingItems = {}
local ilvlCache = {}
local ilvlSortOrder = nil  -- nil / "asc" / "desc"
local pendingRefresh = false
local browseOffset = 0
local BROWSE_VISIBLE = 20

-- Listings view (item detail / buy flow)
local BROWSE_VIEW_LISTINGS = 3
local buyItemKey = nil
local buyItemName = nil
local buyListings = {}
local buyIsCommodity = false
local pendingCommodityPurchase = nil  -- {itemID, quantity} while awaiting price confirmation

local AH_CATEGORIES = {}
local AH_CLASS_ORDER = { 2, 4, 0, 7, 3, 8, 9, 1, 15, 5, 16, 17 }

-- AH session token: bumped on every AH_HOUSE_CLOSED. Long-running C_Timer
-- callbacks capture the value at scheduling and compare at fire time, so
-- stale callbacks from a previous session don't mutate fresh state on
-- rapid close+reopen.
local ahSessionID = 0

local function BuildCategoryData()
    wipe(AH_CATEGORIES)
    for _, classID in ipairs(AH_CLASS_ORDER) do
        local name = GetItemClassInfo(classID)
        if name then
            local subs = C_AuctionHouse.GetAuctionItemSubClasses(classID)
            local subList = {}
            if subs then
                for _, subClassID in ipairs(subs) do
                    local subName = GetItemSubClassInfo(classID, subClassID)
                    if subName then
                        subList[#subList + 1] = { subClassID = subClassID, name = subName }
                    end
                end
            end
            AH_CATEGORIES[#AH_CATEGORIES + 1] = {
                classID = classID,
                name = name,
                subClasses = subList,
            }
        end
    end
end

local function GetBrowseDataCount()
    if browseView == BROWSE_VIEW_TREE then
        return #treeFlatList
    elseif browseView == BROWSE_VIEW_LISTINGS then
        return #buyListings
    else
        return #browseResults
    end
end

-- Forward declarations: these locals are referenced by functions above
-- their definition but must be visible as upvalues
local RefreshBrowseRows
local SortBrowseResults
local SendCategoryBrowseQuery
local BuildSellableBagItems
local RefreshSellItemList

----------------------------------------------------------------------
-- Profession → reagent subclass mappings (mirrors VoidBags' PROF_REAGENT_MAP)
-- Inlined here so VoidAH never touches _G.VoidBags (taint-safety).
----------------------------------------------------------------------
local PROF_REAGENT_MAP = {
    ["Blacksmithing"]  = { "Metal & Stone", "Ore", "Reagent", "Parts", "Optional Reagents", "Finishing Reagents" },
    ["Enchanting"]     = { "Enchanting", "Optional Reagents", "Finishing Reagents" },
    ["Alchemy"]        = { "Herb", "Elemental", "Optional Reagents", "Finishing Reagents" },
    ["Herbalism"]      = { "Herb" },
    ["Mining"]         = { "Metal & Stone", "Ore" },
    ["Skinning"]       = { "Leather", "Cloth" },
    ["Leatherworking"] = { "Leather", "Cloth", "Optional Reagents", "Finishing Reagents" },
    ["Tailoring"]      = { "Cloth", "Optional Reagents", "Finishing Reagents" },
    ["Jewelcrafting"]  = { "Gem", "Metal & Stone", "Jewelcrafting", "Optional Reagents", "Finishing Reagents" },
    ["Inscription"]    = { "Herb", "Inscription", "Optional Reagents", "Finishing Reagents" },
    ["Engineering"]    = { "Parts", "Metal & Stone", "Engineering", "Optional Reagents", "Finishing Reagents" },
    ["Cooking"]        = { "Cooking", "Meat", "Fish" },
    ["Fishing"]        = { "Fish" },
}

local REAGENT_TO_PROF = {}
for prof, subs in pairs(PROF_REAGENT_MAP) do
    for _, sub in ipairs(subs) do
        REAGENT_TO_PROF[sub] = REAGENT_TO_PROF[sub] or {}
        REAGENT_TO_PROF[sub][prof] = true
    end
end

-- Player-profession cache (60s TTL so we don't re-query every bag scan).
local _playerProfCache, _playerProfCacheAt = nil, 0

local function GetPlayerProfs()
    local now = GetTime()
    if _playerProfCache and (now - _playerProfCacheAt) < 60 then
        return _playerProfCache
    end
    local profs = {}
    local p1, p2, _, fishing, cooking = GetProfessions()
    for _, profID in ipairs({ p1, p2, fishing, cooking }) do
        if profID then
            local ok, name = pcall(GetProfessionInfo, profID)
            if ok and name then profs[name] = true end
        end
    end
    _playerProfCache = profs
    _playerProfCacheAt = now
    return profs
end

-- Profitability check — is AH value high enough to cover posting + earn meaningful profit?
local TRASH_PROFIT_MULTIPLIER = 3   -- total must exceed posting cost × 3

-- User-configurable minimum total value floor (persisted in VoidUIAuctionDB.config.Auction.trashMinFloorGold)
local TRASH_MIN_FLOOR_DEFAULT_GOLD = 5

local function GetTrashFloorCopper()
    local cfg = VoidUI and VoidUI.GetModuleConfig and VoidUI:GetModuleConfig("Auction") or nil
    local g = (cfg and cfg.trashMinFloorGold) or TRASH_MIN_FLOOR_DEFAULT_GOLD
    return math.max(0, math.floor(g)) * 10000
end

local function SetTrashFloorGold(gold)
    gold = tonumber(gold) or TRASH_MIN_FLOOR_DEFAULT_GOLD
    gold = math.max(0, math.floor(gold))
    VoidUIAuctionDB = VoidUIAuctionDB or {}
    VoidUIAuctionDB.config = VoidUIAuctionDB.config or {}
    VoidUIAuctionDB.config.Auction = VoidUIAuctionDB.config.Auction or {}
    VoidUIAuctionDB.config.Auction.trashMinFloorGold = gold
end

local function GetPostingCost(itemID, quantity)
    quantity = quantity or 1
    if C_AuctionHouse and C_AuctionHouse.CalculateCommodityDeposit then
        local ok, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, 2, quantity)
        if ok and deposit and deposit > 0 then return deposit end
    end
    local sellPrice = select(11, C_Item.GetItemInfo(itemID)) or 0
    return math.max(100, math.floor(sellPrice * quantity * 0.15))
end

local function IsProfitableOnAH(itemID, quantity, vendorSellPrice)
    local ahPrice = AH and AH.GetPrice and AH:GetPrice(itemID) or nil
    if not ahPrice then return false end
    local q = quantity or 1
    local total = ahPrice * q
    if total < GetTrashFloorCopper() then return false end
    local cost = GetPostingCost(itemID, q)
    if total < cost * TRASH_PROFIT_MULTIPLIER then return false end
    return true
end
local UpdateShoppingList
local LoadShoppingList
local ResolveAndAddItem
local AddShoppingEntry
local RemoveShoppingEntry
local StartShoppingListScan
local OnShoppingSearchResult
local ScanTrashItems
local trashScanState = nil  -- { pending = {[itemID]=true}, total = N, done = 0, started = time }
local FireShoppingAlert
local CheckShoppingScanComplete
local BrowseRowOnClick
local PopulateBuyRow
local ShowConfirmBar
local HideConfirmBar

local function BuildTreeFlatList()
    wipe(treeFlatList)
    for catIndex, cat in ipairs(AH_CATEGORIES) do
        treeFlatList[#treeFlatList + 1] = {
            type = "category",
            catIndex = catIndex,
            classID = cat.classID,
            name = cat.name,
        }
        if expandedCategories[catIndex] then
            -- "All <Category>" entry
            treeFlatList[#treeFlatList + 1] = {
                type = "sub",
                catIndex = catIndex,
                subIndex = 0,
                classID = cat.classID,
                subClassID = nil,
                name = "All " .. cat.name,
            }
            for subIndex, sub in ipairs(cat.subClasses) do
                treeFlatList[#treeFlatList + 1] = {
                    type = "sub",
                    catIndex = catIndex,
                    subIndex = subIndex,
                    classID = cat.classID,
                    subClassID = sub.subClassID,
                    name = sub.name,
                }
            end
        end
    end
end

-- Single shared click handler — reads entry from row._treeEntry, zero closures
local function TreeRowOnClick(self)
    local entry = self._treeEntry
    if not entry then return end
    if entry.type == "category" then
        if expandedCategories[entry.catIndex] then
            expandedCategories[entry.catIndex] = nil
        else
            expandedCategories[entry.catIndex] = true
        end
        BuildTreeFlatList()
        -- Clamp scroll so we don't overrun the shorter/longer list
        local maxOffset = math.max(#treeFlatList - BROWSE_VISIBLE, 0)
        browseOffset = math.min(browseOffset, maxOffset)
        RefreshBrowseRows()
    else
        selectedClassID = entry.classID
        selectedSubClassID = entry.subClassID
        browseView = BROWSE_VIEW_RESULTS
        browseOffset = 0
        SendCategoryBrowseQuery()
        RefreshBrowseRows()
    end
end

local function PopulateTreeRow(row, entry, visualIndex)
    if not entry then row:Hide() return end
    row._itemID = nil
    row._treeEntry = entry
    row._icon:SetTexture(nil)
    row._qty:SetText("")
    row._price:SetText("")
    row._market:SetText("")
    row._deal:SetText("")
    row._extra:SetText("")
    if row._ilvl then row._ilvl:SetText("") end

    local even = (visualIndex % 2 == 0)
    local bgVal = even and 0.14 or 0.10
    row._bgR, row._bgG, row._bgB, row._bgA = bgVal, bgVal, bgVal, 0.9
    row._bg:SetColorTexture(bgVal, bgVal, bgVal, 0.9)

    if entry.type == "category" then
        local prefix = expandedCategories[entry.catIndex] and "[-] " or "[+] "
        row._name:SetText("|cffffffff" .. prefix .. entry.name .. "|r")
        row._name:SetWidth(750)
    else
        row._name:SetText((entry.subIndex == 0 and "|cff00ffff" or "|cffcccccc") .. "      " .. entry.name .. "|r")
        row._name:SetWidth(700)
        row._extra:SetText("|cff666666>|r")
    end

    row:SetScript("OnClick", TreeRowOnClick)
    row:Show()
end


----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function StripColor(text)
    if not text then return "" end
    return text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
end

local function CreateButton(parent, width, height, text, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, height)

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
    btn:SetScript("OnLeave", function() bg:SetColorTexture(0.15, 0.15, 0.15, 1) end)

    return btn
end

local function CreateEditBox(parent, width, height, placeholder)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(width, height)
    box:SetAutoFocus(false)
    box:SetBackdrop({
        bgFile = VoidUI.media.flat,
        edgeFile = VoidUI.media.flat,
        edgeSize = 1,
    })
    box:SetBackdropColor(0.08, 0.08, 0.08, 1)
    box:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    VoidUI:SetFont(box, 10, "")
    box:SetTextInsets(6, 6, 0, 0)

    if placeholder then
        local ph = box:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(ph, 10, "")
        ph:SetPoint("LEFT", 6, 0)
        ph:SetText("|cff555555" .. placeholder .. "|r")
        box._placeholder = ph
        box:SetScript("OnTextChanged", function(self)
            if self:GetText() == "" then
                ph:Show()
            else
                ph:Hide()
            end
        end)
    end

    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

----------------------------------------------------------------------
-- Scroll list helper
----------------------------------------------------------------------
local function CreateScrollList(parent, rowCount, rowHeight, createRowFunc, updateRowFunc)
    local container = CreateFrame("Frame", nil, parent)
    container:SetPoint("TOPLEFT", 10, -40)
    container:SetPoint("BOTTOMRIGHT", -10, 36)

    local scrollFrame = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
    scrollFrame:SetAllPoints()

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(container:GetWidth() or LIST_WIDTH)
    scrollChild:SetHeight(1)  -- adjusted dynamically
    scrollFrame:SetScrollChild(scrollChild)

    -- Style scrollbar
    local sb = scrollFrame.ScrollBar
    if sb then
        sb:ClearAllPoints()
        sb:SetPoint("TOPRIGHT", container, "TOPRIGHT", -2, -18)
        sb:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -2, 18)
    end

    -- Create rows
    local rows = {}
    for i = 1, rowCount do
        local row = createRowFunc(scrollChild, i)
        row:SetSize(LIST_WIDTH - 20, rowHeight)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i - 1) * rowHeight)
        rows[i] = row
    end

    container._rows = rows
    container._scrollChild = scrollChild
    container._updateRow = updateRowFunc
    container._data = {}

    function container:SetData(data)
        self._data = data
        local childHeight = #data * rowHeight
        self._scrollChild:SetHeight(math.max(childHeight, 1))
        self:Refresh()
    end

    function container:Refresh()
        for i, row in ipairs(self._rows) do
            if self._data[i] then
                self._updateRow(row, self._data[i], i)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    return container
end

----------------------------------------------------------------------
-- Build: Row template for item lists
----------------------------------------------------------------------
local function CreateItemRow(parent, index)
    local row = CreateFrame("Button", nil, parent)

    local evenRow = (index % 2 == 0)
    local bgR = evenRow and 0.14 or 0.10
    local bgG = bgR
    local bgB = bgR
    local bgA = 0.9

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(bgR, bgG, bgB, bgA)
    row._bg = bg
    row._bgR, row._bgG, row._bgB, row._bgA = bgR, bgG, bgB, bgA

    row:SetScript("OnEnter", function(self)
        bg:SetColorTexture(0.20, 0.20, 0.28, 1)
        if self._itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            -- Use SetItemKey for AH items so tooltip shows scaled ilvl/stats
            if self._itemKey and self._itemKey.itemLevel and self._itemKey.itemLevel > 0 then
                GameTooltip:SetItemKey(self._itemKey.itemID, self._itemKey.itemLevel, self._itemKey.itemSuffix or 0)
            else
                GameTooltip:SetItemByID(self._itemID)
            end
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        bg:SetColorTexture(self._bgR, self._bgG, self._bgB, self._bgA)
        GameTooltip:Hide()
    end)

    -- Icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 4, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row._icon = icon

    -- Name
    local name = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(name, 10, "")
    name:SetTextColor(1, 1, 1)
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetWidth(220)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row._name = name

    -- Item Level
    local ilvl = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(ilvl, 10, "")
    ilvl:SetTextColor(0.9, 0.8, 0.5)
    ilvl:SetPoint("LEFT", row, "LEFT", 230, 0)
    ilvl:SetWidth(40)
    ilvl:SetJustifyH("CENTER")
    row._ilvl = ilvl

    -- Quantity
    local qty = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(qty, 10, "")
    qty:SetTextColor(0.9, 0.9, 0.9)
    qty:SetPoint("LEFT", row, "LEFT", 275, 0)
    qty:SetWidth(40)
    qty:SetJustifyH("CENTER")
    row._qty = qty

    -- Price
    local price = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(price, 10, "")
    price:SetTextColor(1, 1, 1)
    price:SetPoint("LEFT", row, "LEFT", 320, 0)
    price:SetWidth(140)
    price:SetJustifyH("RIGHT")
    row._price = price

    -- Market comparison
    local market = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(market, 10, "")
    market:SetTextColor(0.7, 0.7, 0.7)
    market:SetPoint("LEFT", row, "LEFT", 470, 0)
    market:SetWidth(120)
    market:SetJustifyH("RIGHT")
    row._market = market

    -- Deal %
    local deal = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(deal, 10, "")
    deal:SetTextColor(1, 1, 1)
    deal:SetPoint("LEFT", row, "LEFT", 600, 0)
    deal:SetWidth(60)
    deal:SetJustifyH("CENTER")
    row._deal = deal

    -- Extra (time left, action, etc.)
    local extra = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(extra, 10, "")
    extra:SetTextColor(1, 1, 1)
    extra:SetPoint("LEFT", row, "LEFT", 670, 0)
    extra:SetWidth(100)
    extra:SetJustifyH("CENTER")
    row._extra = extra

    return row
end

----------------------------------------------------------------------
-- Build Panel
----------------------------------------------------------------------
local function CreatePanel()
    if panel then return panel end

    panel = CreateFrame("Frame", "VoidUI_AuctionPanel", UIParent, "BackdropTemplate")
    panel:SetSize(PANEL_W, PANEL_H)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("HIGH")
    panel:SetFrameLevel(50)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    local P = VoidUI.palette
    local aR, aG, aB = P.accent[1], P.accent[2], P.accent[3]
    VoidUI:CreateBackdrop(panel, 0.08, 0.08, 0.10, 0.97)
    panel:SetBackdropBorderColor(aR, aG, aB, 0.4)
    VoidUI:CreateShadow(panel)
    panel:Hide()

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, panel)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetHeight(30)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() panel:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)

    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(0.06, 0.06, 0.08, 1)

    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFont(STANDARD_TEXT_FONT, 14, "")
    title:SetTextColor(aR, aG, aB)
    title:SetPoint("CENTER")
    title:SetText("Auction House")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    closeBtn:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY")
    closeTxt:SetFont(STANDARD_TEXT_FONT, 16, "")
    closeTxt:SetTextColor(0.8, 0.2, 0.2)
    closeTxt:SetText("X")
    closeTxt:SetAllPoints()
    closeBtn:SetScript("OnClick", function() panel:Hide() end)
    closeBtn:SetScript("OnEnter", function() closeTxt:SetTextColor(1, 0.3, 0.3) end)
    closeBtn:SetScript("OnLeave", function() closeTxt:SetTextColor(0.8, 0.2, 0.2) end)

    -- Tab buttons (below title bar)
    tabButtons = {}
    tabFrames = {}
    local tabW = math.floor(PANEL_W / #TAB_NAMES)
    for i, name in ipairs(TAB_NAMES) do
        local btn = CreateFrame("Button", nil, panel, "BackdropTemplate")
        btn:SetSize(tabW, 26)
        btn:SetPoint("TOPLEFT", panel, "TOPLEFT", (i - 1) * tabW, -30)
        btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        btn:SetBackdropColor(0.06, 0.06, 0.08, 1)
        btn:SetBackdropBorderColor(0.2, 0.2, 0.22, 1)

        local lbl = btn:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(STANDARD_TEXT_FONT, 11, "")
        lbl:SetPoint("CENTER")
        lbl:SetText(name)
        lbl:SetTextColor(P.textDim[1], P.textDim[2], P.textDim[3])
        btn._label = lbl
        btn._bg = nil  -- removed, using backdrop now
        btn._text = lbl -- alias for SetActiveTab compat

        btn:SetScript("OnClick", function() SetActiveTab(i) end)
        btn:SetScript("OnEnter", function(self)
            if activeTab ~= i then self:SetBackdropColor(0.1, 0.1, 0.12, 1) end
        end)
        btn:SetScript("OnLeave", function(self)
            if activeTab ~= i then self:SetBackdropColor(0.06, 0.06, 0.08, 1) end
        end)

        tabButtons[i] = btn

        -- Content frame for this tab
        local content = CreateFrame("Frame", nil, panel)
        content:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -56)
        content:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 28)
        content:Hide()
        tabFrames[i] = content
    end

    -- Status bar at bottom
    statusBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    statusBar:SetPoint("BOTTOMLEFT", 0, 0)
    statusBar:SetPoint("BOTTOMRIGHT", 0, 0)
    statusBar:SetHeight(28)

    local sbBg = statusBar:CreateTexture(nil, "BACKGROUND")
    sbBg:SetAllPoints()
    sbBg:SetColorTexture(0.06, 0.06, 0.06, 1)

    statusBar._throttle = statusBar:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(statusBar._throttle, 9, "")
    statusBar._throttle:SetPoint("LEFT", 10, 0)
    statusBar._throttle:SetText("|cff888888Throttle: Ready|r")

    statusBar._scanInfo = statusBar:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(statusBar._scanInfo, 9, "")
    statusBar._scanInfo:SetPoint("CENTER", 0, 0)

    statusBar._profit = statusBar:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(statusBar._profit, 9, "")
    statusBar._profit:SetPoint("RIGHT", -10, 0)

    -- Build individual tabs
    if VoidSpy and VoidSpy.Log then
        VoidSpy:Log("VoidAH", "building %d tabs, ProfPlans=%s",
            #TAB_NAMES, tostring(VoidUI.ProfessionPlans and #VoidUI.ProfessionPlans or "nil"))
    end
    BuildBrowseTab(tabFrames[1])
    BuildSellTab(tabFrames[2])
    BuildMyAuctionsTab(tabFrames[3])
    BuildDealsTab(tabFrames[4])
    BuildScanTab(tabFrames[5])
    local _ok, _err = pcall(BuildProfessionsTab, tabFrames[6])
    if not _ok then
        print("|cffff5050VoidAH:|r BuildProfessionsTab error: " .. tostring(_err))
    end

    -- When our panel hides, close the AH connection properly
    panel:SetScript("OnHide", function()
        if AH.ahOpen then
            C_AuctionHouse.CloseAuctionHouse()
        end
    end)

    -- Escape to close
    tinsert(UISpecialFrames, "VoidUI_AuctionPanel")

    return panel
end

----------------------------------------------------------------------
-- Tab Switching
----------------------------------------------------------------------
function SetActiveTab(index)
    activeTab = index
    local P = VoidUI.palette
    local aR, aG, aB = P.accent[1], P.accent[2], P.accent[3]
    for i, frame in ipairs(tabFrames) do
        local btn = tabButtons[i]
        local sel = (i == index)
        if sel then
            frame:Show()
        else
            frame:Hide()
        end
        btn:SetBackdropColor(sel and 0.12 or 0.06, sel and 0.12 or 0.06, sel and 0.14 or 0.08, 1)
        btn:SetBackdropBorderColor(
            sel and aR or 0.2, sel and aG or 0.2, sel and aB or 0.22, sel and 0.6 or 1
        )
        btn._label:SetTextColor(
            sel and aR or P.textDim[1], sel and aG or P.textDim[2], sel and aB or P.textDim[3]
        )
    end
    -- Refresh visible rows when switching to Browse tab
    if index == 1 then
        RefreshBrowseRows()
    end
    -- Refresh bag grid when switching to Sell tab
    if index == 2 then
        BuildSellableBagItems()
        RefreshSellItemList()
    end
    -- Auto-query owned auctions when switching to My Auctions tab
    if index == 3 then
        AH:QueryOwnedAuctions()
    end
end

----------------------------------------------------------------------
-- Status Bar Update
----------------------------------------------------------------------
local function UpdateStatusBar()
    if not statusBar then return end

    -- Throttle
    local qSize = AH:GetThrottleQueueSize()
    if qSize > 0 then
        statusBar._throttle:SetText("|cffffaa00Throttle: " .. qSize .. " queued|r")
    else
        statusBar._throttle:SetText("|cff888888Throttle: Ready|r")
    end

    -- Scan info
    local lastFull = AH:GetLastFullScan()
    local lastBrowse = AH:GetLastBrowseScan()
    local fullAge = lastFull > 0 and VoidUI:FormatTime(time() - lastFull) or "never"
    local browseAge = lastBrowse > 0 and VoidUI:FormatTime(time() - lastBrowse) or "never"
    statusBar._scanInfo:SetText("|cff888888Full: " .. fullAge .. " | Browse: " .. browseAge .. " | DB: " .. AH:GetDBStats() .. " items|r")

    -- Profit
    local profit = AH.sessionProfit
    if AH.ahOpen then
        profit = GetMoney() - AH.sessionStartGold
    end
    if profit ~= 0 then
        local color = profit > 0 and "|cff00ff00+" or "|cffff4444"
        statusBar._profit:SetText("Session: " .. color .. VoidUI:FormatMoney(math.abs(profit)) .. "|r")
    else
        statusBar._profit:SetText("|cff888888Session: 0g|r")
    end
end

----------------------------------------------------------------------
-- TAB 1: Browse  (category drill-down + virtual scroll)
----------------------------------------------------------------------
SendCategoryBrowseQuery = function()
    if not AH.ahOpen then return end

    browseResults = {}
    browseOffset = 0

    local classFilters = {}
    if selectedClassID then
        local f = { classID = selectedClassID }
        if selectedSubClassID then
            f.subClassID = selectedSubClassID
        end
        classFilters[1] = f
    end

    local searchText = ""
    if tabFrames and tabFrames[1] and tabFrames[1]._searchBox then
        searchText = tabFrames[1]._searchBox:GetText() or ""
    end

    AH:_Enqueue(function()
        C_AuctionHouse.SendBrowseQuery({
            searchString = searchText,
            sorts = {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }},
            filters = {},
            itemClassFilters = classFilters,
        })
    end)
end

----------------------------------------------------------------------
-- Buy / Purchase Flow
----------------------------------------------------------------------
StaticPopupDialogs["VOIDUI_AH_CONFIRM_BUY"] = {
    text = "Buy %s for %s?",
    button1 = "Buy",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if data and data.auctionID and data.price then
            C_AuctionHouse.PlaceBid(data.auctionID, data.price)
            print("|cff00ff00[VoidUI AH]|r Purchase placed!")
            -- Refresh listings after brief delay
            C_Timer.After(0.5, function()
                if buyItemKey and browseView == BROWSE_VIEW_LISTINGS then
                    AH:_Enqueue(function()
                        C_AuctionHouse.SendSearchQuery(buyItemKey,
                            {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }}, false)
                    end)
                end
            end)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["VOIDUI_AH_BUY_COMMODITY"] = {
    text = "How many %s do you want to buy?\n(Cheapest: %s each)",
    button1 = "Buy",
    button2 = "Cancel",
    hasEditBox = true,
    editBoxWidth = 80,
    OnShow = function(self)
        self.editBox:SetText("1")
        self.editBox:SetFocus()
    end,
    OnAccept = function(self, data)
        local qty = tonumber(self.editBox:GetText()) or 1
        if qty > 0 and data and data.itemID then
            pendingCommodityPurchase = { itemID = data.itemID, quantity = qty }
            C_AuctionHouse.StartCommoditiesPurchase(data.itemID, qty)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["VOIDUI_AH_CONFIRM_COMMODITY_PRICE"] = {
    text = "Confirm purchase:\n%s\nTotal cost: %s",
    button1 = "Confirm",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if data and data.itemID and data.quantity then
            C_AuctionHouse.ConfirmCommoditiesPurchase(data.itemID, data.quantity)
            print("|cff00ff00[VoidUI AH]|r Commodity purchase confirmed!")
        end
    end,
    OnCancel = function()
        C_AuctionHouse.CancelCommoditiesPurchase()
        pendingCommodityPurchase = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local BUY_TIME_LEFT = {
    [0] = "|cffff4444Short|r",
    [1] = "|cffffd700Medium|r",
    [2] = "|cff00ff00Long|r",
    [3] = "|cff00ff00Very Long|r",
}

BrowseRowOnClick = function(self)
    if not self._itemKey then return end
    buyItemKey = self._itemKey
    buyItemName = self._name and self._name:GetText() or ("Item " .. (self._itemID or "?"))
    buyListings = {}
    -- Determine commodity-ness at click time so the listing row populates
    -- correctly on first paint. (Was force-set to false and only flipped
    -- inside the commodity search-result handler — caused commodity rows
    -- to render as items briefly.)
    local keyInfo = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(buyItemKey)
    buyIsCommodity = keyInfo and keyInfo.isCommodity or false
    browseOffset = 0
    browseView = BROWSE_VIEW_LISTINGS

    -- SendSearchQuery handles both items and commodities for a given itemKey
    -- (12.0.7 removed the separate SendCommoditySearchQuery). buyIsCommodity
    -- still routes how results are READ (commodity- vs item-specific getters).
    AH:_Enqueue(function()
        C_AuctionHouse.SendSearchQuery(buyItemKey,
            {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }}, false)
    end)

    RefreshBrowseRows()
end

----------------------------------------------------------------------
-- Inline Confirm Bar (replaces StaticPopup for buy flow)
----------------------------------------------------------------------
ShowConfirmBar = function(opts)
    -- opts = { isCommodity, itemName, unitPrice, auctionID, buyoutAmount, itemID }
    if not tabFrames or not tabFrames[1] then return end
    local bar = tabFrames[1]._confirmBar
    if not bar then return end

    bar._pendingOpts = opts

    if opts.isCommodity then
        -- Commodity: show qty box, confirm triggers StartCommoditiesPurchase
        bar._info:SetText("|cff00c7ff" .. (opts.itemName or "item") .. "|r  —  " ..
            VoidUI.AH.SafeMoney(opts.unitPrice) .. " each")
        bar._qtyLabel:Show()
        bar._qtyBox:Show()
        bar._qtyBox:SetText("1")
        bar._confirmBtn:SetScript("OnClick", function()
            local qty = tonumber(bar._qtyBox:GetText()) or 1
            if qty < 1 then qty = 1 end
            if opts.itemID then
                pendingCommodityPurchase = { itemID = opts.itemID, quantity = qty }
                C_AuctionHouse.StartCommoditiesPurchase(opts.itemID, qty)
                bar._info:SetText("|cffffd700Purchasing...|r")
                bar._confirmBtn:Disable()
            end
        end)
    else
        -- Item: direct PlaceBid on confirm
        local buyoutSafe = VoidUI.AH.SafeNum(opts.buyoutAmount)
        bar._info:SetText("|cff00c7ff" .. (opts.itemName or "item") .. "|r  —  " ..
            (buyoutSafe and VoidUI:FormatMoney(buyoutSafe) or "—"))
        bar._qtyLabel:Hide()
        bar._qtyBox:Hide()
        bar._confirmBtn:SetScript("OnClick", function()
            if opts.auctionID and buyoutSafe then
                -- PlaceBid with bidAmount==buyout works for both bid-only and buyout listings.
                -- (For pure buyouts, this completes the purchase; for bid-only, it places the bid.)
                C_AuctionHouse.PlaceBid(opts.auctionID, buyoutSafe)
                print("|cff00ff00[VoidUI AH]|r Purchase placed!")
                bar:Hide()
                -- Refresh listings
                C_Timer.After(0.5, function()
                    if buyItemKey and browseView == BROWSE_VIEW_LISTINGS then
                        AH:_Enqueue(function()
                            C_AuctionHouse.SendSearchQuery(buyItemKey,
                                {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }}, false)
                        end)
                    end
                end)
            end
        end)
    end

    bar._confirmBtn:Enable()
    bar:Show()
end

HideConfirmBar = function()
    if not tabFrames or not tabFrames[1] then return end
    local bar = tabFrames[1]._confirmBar
    if bar then bar:Hide() end
end

PopulateBuyRow = function(row, listing, visualIndex)
    if not listing then
        row:Hide()
        return
    end

    row._itemID = buyItemKey and buyItemKey.itemID or nil
    row._itemKey = buyItemKey

    -- Icon: cached item texture
    local _, _, _, _, _, _, _, _, _, itemTexture = C_Item.GetItemInfo(row._itemID or 0)
    row._icon:SetTexture(itemTexture or 134400)

    -- Seller name
    local sellerName = "Unknown"
    if listing.owners and #listing.owners > 0 then
        sellerName = listing.owners[1]
    end
    if listing.containsAccountItem then
        sellerName = "|cff00ffffYou|r"
    end
    row._name:SetText(sellerName)
    row._name:SetWidth(220)

    -- iLvl
    if row._ilvl then
        local ilvl = buyItemKey and buyItemKey.itemLevel or 0
        row._ilvl:SetText(ilvl > 0 and tostring(ilvl) or "")
    end

    -- Qty
    local qty = VoidUI.AH.SafeNum(listing.quantity) or 1
    row._qty:SetText(tostring(qty))

    if buyIsCommodity then
        -- Commodity listing
        row._price:SetText(VoidUI.AH.SafeMoney(listing.unitPrice))
        local total = VoidUI.AH.SafeMul(listing.unitPrice, listing.quantity)
        row._market:SetText(total and total > 0 and VoidUI:FormatMoney(total) or "")
        row._deal:SetText("")
        row._extra:SetText("|cff00ff00[BUY]|r")
        row:SetScript("OnClick", function()
            if not buyItemKey then return end
            local unitPriceSafe = VoidUI.AH.SafeNum(listing.unitPrice)
            if not unitPriceSafe then return end
            ShowConfirmBar({
                isCommodity = true,
                itemName = StripColor(buyItemName or "item"),
                unitPrice = unitPriceSafe,
                itemID = buyItemKey.itemID,
            })
        end)
    else
        -- Item listing
        local buyout = VoidUI.AH.SafeNum(listing.buyoutAmount)
        local bid = VoidUI.AH.SafeNum(listing.bidAmount)
        local price = buyout or bid
        row._price:SetText(price and VoidUI:FormatMoney(price) or "N/A")
        row._market:SetText(BUY_TIME_LEFT[listing.timeLeft] or "")
        row._deal:SetText("")
        row._extra:SetText("|cff00ff00[BUY]|r")
        row:SetScript("OnClick", function()
            if not listing.auctionID then return end
            local buyPrice = buyout or bid
            if not buyPrice then return end
            ShowConfirmBar({
                isCommodity = false,
                itemName = StripColor(buyItemName or "item"),
                buyoutAmount = buyPrice,
                auctionID = listing.auctionID,
            })
        end)
    end

    local even = (visualIndex % 2 == 0)
    local bgVal = even and 0.14 or 0.10
    row._bgR, row._bgG, row._bgB, row._bgA = bgVal, bgVal, bgVal, 0.9
    row._bg:SetColorTexture(bgVal, bgVal, bgVal, 0.9)
    row:Show()
end

local function PopulateBrowseRow(row, data, visualIndex)
    if not data then
        row:Hide()
        return
    end
    row:SetScript("OnClick", BrowseRowOnClick)
    row._itemID = data.itemID
    row._itemKey = data.itemKey  -- for tooltip: includes itemLevel for scaled items
    local itemName, _, _, itemLevel, _, _, _, _, _, itemTexture = C_Item.GetItemInfo(data.itemID)

    if not itemName then
        -- Item not cached yet — request async load
        if not pendingItems[data.itemID] then
            pendingItems[data.itemID] = true
            C_Item.RequestLoadItemDataByID(data.itemID)
        end
    else
        -- Cache base ilvl as fallback (don't overwrite itemKey.itemLevel)
        if itemLevel and not ilvlCache[data.itemID] then
            ilvlCache[data.itemID] = itemLevel
        end
        if not data.ilvl and ilvlCache[data.itemID] then
            data.ilvl = ilvlCache[data.itemID]
        end
    end

    row._icon:SetTexture(itemTexture or 134400)
    row._name:SetText(itemName or ("Item " .. data.itemID))
    row._name:SetWidth(220)

    -- iLvl
    if row._ilvl then
        row._ilvl:SetText(data.ilvl and data.ilvl > 0 and tostring(data.ilvl) or "")
    end

    local totalQty = VoidUI.AH.SafeNum(data.totalQuantity) or 0
    row._qty:SetText(totalQty > 0 and totalQty or "")
    row._price:SetText(VoidUI.AH.SafeMoney(data.minPrice))

    local mean = AH:GetMarketMean(data.itemID, 7)
    row._market:SetText(mean and VoidUI:FormatMoney(mean) or "")

    local pct = AH:GetDealPercent(data.itemID)
    if pct then
        local color = pct <= 80 and "|cff00ff00" or (pct <= 100 and "|cffffffff" or "|cffff4444")
        row._deal:SetText(color .. pct .. "%|r")
    else
        row._deal:SetText("")
    end
    row._extra:SetText(data.containsOwnerItem and "|cff00ffffYours|r" or "")

    local even = (visualIndex % 2 == 0)
    local bgVal = even and 0.14 or 0.10
    row._bgR, row._bgG, row._bgB, row._bgA = bgVal, bgVal, bgVal, 0.9
    row._bg:SetColorTexture(bgVal, bgVal, bgVal, 0.9)
    row:Show()
end

RefreshBrowseRows = function()
    if not tabFrames or not tabFrames[1] then return end
    local parent = tabFrames[1]
    if not parent._rows then return end

    local dataCount = GetBrowseDataCount()

    -- Back button visibility + breadcrumb positioning
    if parent._backBtn then
        parent._breadcrumb:ClearAllPoints()
        if browseView == BROWSE_VIEW_RESULTS or browseView == BROWSE_VIEW_LISTINGS then
            parent._backBtn:Show()
            parent._breadcrumb:SetPoint("LEFT", parent._backBtn, "RIGHT", 8, 0)
        else
            parent._backBtn:Hide()
            parent._breadcrumb:SetPoint("LEFT", parent._navBar, "LEFT", 8, 0)
        end
    end

    -- Breadcrumb text
    if parent._breadcrumb then
        local bc = "Categories"
        if (browseView == BROWSE_VIEW_RESULTS or browseView == BROWSE_VIEW_LISTINGS) and selectedClassID then
            for _, cat in ipairs(AH_CATEGORIES) do
                if cat.classID == selectedClassID then
                    bc = bc .. "  |cff666666>|r  " .. cat.name
                    if selectedSubClassID then
                        for _, sub in ipairs(cat.subClasses) do
                            if sub.subClassID == selectedSubClassID then
                                bc = bc .. "  |cff666666>|r  " .. sub.name
                                break
                            end
                        end
                    end
                    break
                end
            end
        end
        if browseView == BROWSE_VIEW_LISTINGS and buyItemName then
            bc = bc .. "  |cff666666>|r  " .. StripColor(buyItemName)
        end
        parent._breadcrumb:SetText("|cffaaaaaa" .. bc .. "|r")
    end

    -- Column headers
    if parent._colHeader then
        if browseView == BROWSE_VIEW_RESULTS then
            parent._colHeader:Show()
        else
            parent._colHeader:Hide()
        end
    end
    if parent._buyColHeader then
        if browseView == BROWSE_VIEW_LISTINGS then
            parent._buyColHeader:Show()
        else
            parent._buyColHeader:Hide()
        end
    end
    -- Hide confirm bar when not in listings view
    if parent._confirmBar and browseView ~= BROWSE_VIEW_LISTINGS then
        parent._confirmBar:Hide()
    end

    -- Populate rows
    for i = 1, BROWSE_VISIBLE do
        local dataIndex = browseOffset + i
        local row = parent._rows[i]
        if not row then break end

        if dataIndex <= dataCount then
            if browseView == BROWSE_VIEW_TREE then
                PopulateTreeRow(row, treeFlatList[dataIndex], i)
            elseif browseView == BROWSE_VIEW_LISTINGS then
                PopulateBuyRow(row, buyListings[dataIndex], i)
            else
                PopulateBrowseRow(row, browseResults[dataIndex], i)
            end
        else
            row:Hide()
        end
    end

    -- Scroll indicator
    if parent._scrollIndicator and dataCount > BROWSE_VISIBLE then
        local maxOffset = math.max(dataCount - BROWSE_VISIBLE, 1)
        local pct = browseOffset / maxOffset
        local trackH = parent._scrollTrack:GetHeight()
        local thumbH = parent._scrollIndicator:GetHeight()
        parent._scrollIndicator:SetPoint("TOP", parent._scrollTrack, "TOP", 0, -pct * (trackH - thumbH))
        parent._scrollIndicator:Show()
        parent._scrollTrack:Show()
    elseif parent._scrollIndicator then
        parent._scrollIndicator:Hide()
        parent._scrollTrack:Hide()
    end

    -- Count label
    if parent._countLabel then
        if (browseView == BROWSE_VIEW_RESULTS or browseView == BROWSE_VIEW_LISTINGS) and dataCount > 0 then
            local first = browseOffset + 1
            local last = math.min(browseOffset + BROWSE_VISIBLE, dataCount)
            local suffix = browseView == BROWSE_VIEW_LISTINGS and " listings" or " results"
            parent._countLabel:SetText("|cffaaaaaa" .. first .. "-" .. last .. " of " .. dataCount .. suffix .. "|r")
        elseif browseView == BROWSE_VIEW_RESULTS then
            parent._countLabel:SetText("|cff666666No results|r")
        elseif browseView == BROWSE_VIEW_LISTINGS then
            parent._countLabel:SetText("|cff666666Loading listings...|r")
        else
            parent._countLabel:SetText("")
        end
    end
end

function BuildBrowseTab(parent)
    -- Navigation bar
    local navBar = CreateFrame("Frame", nil, parent)
    navBar:SetPoint("TOPLEFT", 10, -4)
    navBar:SetPoint("TOPRIGHT", -10, -4)
    navBar:SetHeight(30)
    parent._navBar = navBar

    -- Buy-target banner: "Need 940x Item — have 0 in bags"
    local banner = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    banner:SetPoint("TOPLEFT", navBar, "BOTTOMLEFT", 0, -2)
    banner:SetPoint("TOPRIGHT", navBar, "BOTTOMRIGHT", 0, -2)
    banner:SetHeight(22)
    VoidUI:CreateBackdrop(banner, 0.05, 0.18, 0.10, 0.95)
    banner:Hide()
    parent._buyBanner = banner

    local bnText = banner:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(bnText, 11, "OUTLINE")
    bnText:SetPoint("LEFT", 8, 0)
    banner._text = bnText

    local bnClose = CreateButton(banner, 50, 18, "Clear", function()
        currentBuyTarget = nil
        if VoidAH_UpdateBuyTargetBanner then VoidAH_UpdateBuyTargetBanner() end
    end)
    bnClose:SetPoint("RIGHT", -4, 0)

    local backBtn = CreateButton(navBar, 60, 24, "< Back", function()
        if browseView == BROWSE_VIEW_LISTINGS then
            browseView = BROWSE_VIEW_RESULTS
            browseOffset = 0
            buyListings = {}
            buyItemKey = nil
            buyItemName = nil
            RefreshBrowseRows()
        elseif browseView == BROWSE_VIEW_RESULTS then
            browseView = BROWSE_VIEW_TREE
            browseOffset = 0
            ilvlSortOrder = nil
            if parent._ilvlHeaderText then
                parent._ilvlHeaderText:SetText("iLvl")
                parent._ilvlHeaderText:SetTextColor(0.67, 0.67, 0.67)
            end
            RefreshBrowseRows()
        end
    end)
    backBtn:SetPoint("LEFT", 0, 0)
    backBtn:Hide()
    parent._backBtn = backBtn

    local breadcrumb = navBar:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(breadcrumb, 10, "")
    breadcrumb:SetPoint("LEFT", navBar, "LEFT", 8, 0)
    breadcrumb:SetWidth(450)
    breadcrumb:SetJustifyH("LEFT")
    breadcrumb:SetWordWrap(false)
    parent._breadcrumb = breadcrumb

    local searchBox = CreateEditBox(navBar, 250, 24, "Search items...")
    searchBox:SetPoint("RIGHT", navBar, "RIGHT", 0, 0)
    parent._searchBox = searchBox

    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        BrowseSearch(self:GetText())
    end)

    local countLabel = navBar:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(countLabel, 9, "")
    countLabel:SetTextColor(0.7, 0.7, 0.7)
    countLabel:SetPoint("RIGHT", searchBox, "LEFT", -10, 0)
    parent._countLabel = countLabel

    -- Column headers (results view only)
    local colHeader = CreateFrame("Frame", nil, parent)
    colHeader:SetPoint("TOPLEFT", 10, -36)
    colHeader:SetPoint("TOPRIGHT", -10, -36)
    colHeader:SetHeight(20)
    colHeader:Hide()
    parent._colHeader = colHeader

    local colBg = colHeader:CreateTexture(nil, "BACKGROUND")
    colBg:SetAllPoints()
    colBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    local cols = {
        { "Item", "LEFT", 4, 220 },
        { "Qty", "CENTER", 275, 40 },
        { "Price", "RIGHT", 320, 140 },
        { "Market", "RIGHT", 470, 120 },
        { "Deal", "CENTER", 600, 60 },
        { "Status", "CENTER", 670, 100 },
    }
    for _, col in ipairs(cols) do
        local fs = colHeader:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(fs, 9, "OUTLINE")
        fs:SetTextColor(0.67, 0.67, 0.67)
        fs:SetPoint("LEFT", col[3], 0)
        fs:SetWidth(col[4])
        fs:SetJustifyH(col[2])
        fs:SetText(col[1])
    end

    -- Clickable iLvl sort header
    local ilvlHeader = CreateFrame("Button", nil, colHeader)
    ilvlHeader:SetSize(40, 20)
    ilvlHeader:SetPoint("LEFT", 230, 0)
    local ilvlHeaderText = ilvlHeader:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(ilvlHeaderText, 9, "OUTLINE")
    ilvlHeaderText:SetTextColor(0.67, 0.67, 0.67)
    ilvlHeaderText:SetPoint("CENTER")
    ilvlHeaderText:SetText("iLvl")
    parent._ilvlHeaderText = ilvlHeaderText

    ilvlHeader:SetScript("OnClick", function()
        if ilvlSortOrder == nil or ilvlSortOrder == "asc" then
            ilvlSortOrder = "desc"
        else
            ilvlSortOrder = "asc"
        end
        SortBrowseResults()
        browseOffset = 0
        RefreshBrowseRows()
        -- Update indicator
        local arrow = ilvlSortOrder == "desc" and " v" or " ^"
        ilvlHeaderText:SetText("|cff00ffffiLvl" .. arrow .. "|r")
    end)
    ilvlHeader:SetScript("OnEnter", function()
        ilvlHeaderText:SetTextColor(0, 1, 1)
    end)
    ilvlHeader:SetScript("OnLeave", function()
        if ilvlSortOrder then
            ilvlHeaderText:SetTextColor(0, 1, 1)
        else
            ilvlHeaderText:SetTextColor(0.67, 0.67, 0.67)
        end
    end)

    -- Listing column headers (BROWSE_VIEW_LISTINGS)
    local buyColHeader = CreateFrame("Frame", nil, parent)
    buyColHeader:SetPoint("TOPLEFT", 10, -36)
    buyColHeader:SetPoint("TOPRIGHT", -10, -36)
    buyColHeader:SetHeight(20)
    buyColHeader:Hide()
    parent._buyColHeader = buyColHeader

    local buyColBg = buyColHeader:CreateTexture(nil, "BACKGROUND")
    buyColBg:SetAllPoints()
    buyColBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    local buyCols = {
        { "Seller", "LEFT", 4, 220 },
        { "iLvl", "CENTER", 230, 40 },
        { "Qty", "CENTER", 275, 40 },
        { "Price", "RIGHT", 320, 140 },
        { "Time Left", "RIGHT", 470, 120 },
        { "", "CENTER", 600, 60 },
        { "Action", "CENTER", 670, 100 },
    }
    for _, col in ipairs(buyCols) do
        local fs = buyColHeader:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(fs, 9, "OUTLINE")
        fs:SetTextColor(0.67, 0.67, 0.67)
        fs:SetPoint("LEFT", col[3], 0)
        fs:SetWidth(col[4])
        fs:SetJustifyH(col[2])
        fs:SetText(col[1])
    end

    -- List area
    local listArea = CreateFrame("Frame", nil, parent)
    listArea:SetPoint("TOPLEFT", 10, -58)
    listArea:SetPoint("BOTTOMRIGHT", -14, 4)

    local scrollTrack = CreateFrame("Frame", nil, listArea)
    scrollTrack:SetWidth(4)
    scrollTrack:SetPoint("TOPRIGHT", listArea, "TOPRIGHT", 0, 0)
    scrollTrack:SetPoint("BOTTOMRIGHT", listArea, "BOTTOMRIGHT", 0, 0)
    local trackBg = scrollTrack:CreateTexture(nil, "BACKGROUND")
    trackBg:SetAllPoints()
    trackBg:SetColorTexture(0.15, 0.15, 0.15, 0.5)
    parent._scrollTrack = scrollTrack

    local scrollIndicator = scrollTrack:CreateTexture(nil, "ARTWORK")
    scrollIndicator:SetWidth(4)
    scrollIndicator:SetHeight(40)
    scrollIndicator:SetPoint("TOP", scrollTrack, "TOP", 0, 0)
    scrollIndicator:SetColorTexture(0, 0.55, 0.55, 0.8)
    parent._scrollIndicator = scrollIndicator

    parent._rows = {}
    for i = 1, BROWSE_VISIBLE do
        local row = CreateItemRow(listArea, i)
        row:SetSize(LIST_WIDTH - 24, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", listArea, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:Hide()
        parent._rows[i] = row
    end

    -- Mouse wheel scroll
    listArea:EnableMouseWheel(true)
    listArea:SetScript("OnMouseWheel", function(self, delta)
        local dataCount = GetBrowseDataCount()
        local maxOffset = math.max(dataCount - BROWSE_VISIBLE, 0)
        browseOffset = math.max(0, math.min(browseOffset - delta * 3, maxOffset))
        RefreshBrowseRows()
    end)
    for _, row in ipairs(parent._rows) do
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(self, delta)
            local dataCount = GetBrowseDataCount()
            local maxOffset = math.max(dataCount - BROWSE_VISIBLE, 0)
            browseOffset = math.max(0, math.min(browseOffset - delta * 3, maxOffset))
            RefreshBrowseRows()
        end)
    end

    -- Inline confirmation bar (replaces StaticPopup for buy flow)
    local confirmBar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    confirmBar:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    confirmBar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    confirmBar:SetHeight(44)
    confirmBar:SetFrameLevel(parent:GetFrameLevel() + 20)
    VoidUI:CreateBackdrop(confirmBar, 0.06, 0.06, 0.08, 0.98)
    local P = VoidUI.palette
    confirmBar:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.6)
    confirmBar:Hide()
    parent._confirmBar = confirmBar

    -- Top border accent line
    local confirmAccent = confirmBar:CreateTexture(nil, "OVERLAY")
    confirmAccent:SetPoint("TOPLEFT", 1, -1)
    confirmAccent:SetPoint("TOPRIGHT", -1, -1)
    confirmAccent:SetHeight(1)
    confirmAccent:SetColorTexture(P.accent[1], P.accent[2], P.accent[3], 0.5)

    -- Item info text (left side)
    local confirmInfo = confirmBar:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(confirmInfo, 11, "")
    confirmInfo:SetPoint("LEFT", 14, 0)
    confirmInfo:SetWidth(400)
    confirmInfo:SetJustifyH("LEFT")
    confirmInfo:SetWordWrap(false)
    confirmBar._info = confirmInfo

    -- Qty editbox (for commodities)
    local qtyLabel = confirmBar:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(qtyLabel, 10, "")
    qtyLabel:SetTextColor(0.7, 0.7, 0.7)
    qtyLabel:SetPoint("LEFT", confirmInfo, "RIGHT", 10, 0)
    qtyLabel:SetText("Qty:")
    confirmBar._qtyLabel = qtyLabel

    local qtyBox = CreateFrame("EditBox", nil, confirmBar, "BackdropTemplate")
    qtyBox:SetSize(50, 22)
    qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 4, 0)
    qtyBox:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    qtyBox:SetBackdropColor(0.1, 0.1, 0.12, 1)
    qtyBox:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
    qtyBox:SetAutoFocus(false)
    qtyBox:SetNumeric(true)
    qtyBox:SetMaxLetters(5)
    VoidUI:SetFont(qtyBox, 11, "")
    qtyBox:SetTextColor(1, 1, 1)
    qtyBox:SetTextInsets(6, 6, 0, 0)
    qtyBox:SetText("1")
    qtyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    confirmBar._qtyBox = qtyBox

    -- Confirm button
    local confirmBtn = CreateButton(confirmBar, 100, 26, "|cff00ff00Confirm Buy|r", nil)
    confirmBtn:SetPoint("RIGHT", confirmBar, "RIGHT", -90, 0)
    confirmBar._confirmBtn = confirmBtn

    -- Cancel button
    local cancelBtn = CreateButton(confirmBar, 60, 26, "Cancel", function()
        confirmBar:Hide()
    end)
    cancelBtn:SetPoint("LEFT", confirmBtn, "RIGHT", 6, 0)
    confirmBar._cancelBtn = cancelBtn
end

SortBrowseResults = function()
    if not ilvlSortOrder then return end
    table.sort(browseResults, function(a, b)
        local aLvl = a.ilvl or 0
        local bLvl = b.ilvl or 0
        if ilvlSortOrder == "desc" then
            return aLvl > bLvl
        else
            return aLvl < bLvl
        end
    end)
end

function BrowseSearch(text)
    if not AH.ahOpen then return end
    if not text or text == "" then return end

    browseResults = {}
    browseOffset = 0
    browseView = BROWSE_VIEW_RESULTS

    local classFilters = {}
    if selectedClassID then
        local f = { classID = selectedClassID }
        if selectedSubClassID then
            f.subClassID = selectedSubClassID
        end
        classFilters[1] = f
    end

    AH:_Enqueue(function()
        C_AuctionHouse.SendBrowseQuery({
            searchString = text,
            sorts = {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }},
            filters = {},
            itemClassFilters = classFilters,
        })
    end)
    RefreshBrowseRows()
end

local function UpdateBrowseResults()
    if not tabFrames or not tabFrames[1] then return end
    local parent = tabFrames[1]
    if not parent._rows then return end

    browseResults = {}
    local results = C_AuctionHouse.GetBrowseResults()
    if results and #results > 0 then
        for _, r in ipairs(results) do
            local itemID = r.itemKey.itemID
            -- Two ilvl sources — take the higher (more accurate) one:
            --   itemKey.itemLevel = actual listing ilvl (M+ / raid / etc), 0 for commodities
            --   GetItemInfo = base template ilvl (correct for fixed-ilvl gear, low for variable)
            local keyIlvl = r.itemKey.itemLevel or 0
            local infoIlvl = ilvlCache[itemID]
            if not infoIlvl then
                local _, _, _, itemLevel = C_Item.GetItemInfo(itemID)
                if itemLevel and itemLevel > 0 then
                    ilvlCache[itemID] = itemLevel
                    infoIlvl = itemLevel
                end
            end
            local ilvl = math.max(keyIlvl, infoIlvl or 0)
            if ilvl == 0 then ilvl = nil end

            browseResults[#browseResults + 1] = {
                itemKey = r.itemKey,
                itemID = itemID,
                minPrice = VoidUI.AH.SafeNum(r.minPrice),
                totalQuantity = VoidUI.AH.SafeNum(r.totalQuantity) or 0,
                containsOwnerItem = r.containsOwnerItem,
                ilvl = ilvl,
            }
        end
    end

    -- Apply sort if active
    if ilvlSortOrder then
        SortBrowseResults()
    end

    browseOffset = 0
    RefreshBrowseRows()
end

----------------------------------------------------------------------
-- TAB 2: Sell
----------------------------------------------------------------------
local sellPending = {}  -- {itemLocation, itemID, suggestedPrice, duration, quantity, isCommodity}

-- Sell tab bag grid state
local sellBagItems = {}       -- flat array of {bag, slot, itemID, icon, quality, count, name}
local sellListOffset = 0     -- scroll offset for sell item list
local sellBagSelected = nil  -- {bag=N, slot=N} of selected item
local SELL_LIST_VISIBLE = 20 -- visible rows in sell item list

----------------------------------------------------------------------
-- Sell tab: Bag grid helpers
----------------------------------------------------------------------
local SELL_BAG_SORT_ORDER = { [2] = 1, [4] = 2, [0] = 3, [7] = 4 }

-- Hidden tooltip for binding checks — classic addon technique, works everywhere
local scanTip = CreateFrame("GameTooltip", "VoidUI_SellScanTip", nil, "GameTooltipTemplate")

-- C_Item.IsBound() returns true for Warbound items (TWW account-bound)
-- even though they're AH-sellable. Tooltip scan for "Soulbound" is the
-- only reliable way to distinguish truly unsellable items.
local function IsUnsellable(bag, slot)
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetBagItem(bag, slot)
    for i = 2, math.min(scanTip:NumLines(), 6) do
        local line = _G["VoidUI_SellScanTipTextLeft" .. i]
        if line then
            local text = line:GetText()
            if text then
                if text == ITEM_SOULBOUND          -- "Soulbound"
                or text == ITEM_ACCOUNTBOUND        -- "Account Bound"
                or text == ITEM_BIND_QUEST          -- "Quest Item"
                then
                    return true
                end
            end
        end
    end
    return false
end

BuildSellableBagItems = function()
    wipe(sellBagItems)
    local hasUncached = false
    -- NOTE: Do NOT access _G.VoidBags or any external addon namespace here.
    -- Cross-addon table access can propagate taint into AH POST buttons.
    -- Trash detection is done entirely with inline heuristics below.
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local ok, _ = pcall(function()
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if not info or not info.itemID then return end
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                if not C_Item.DoesItemExist(loc) then return end
                if IsUnsellable(bag, slot) then return end
                local name, _, quality, _, _, _, subClassName, _, _, icon, sellPrice, _, _, _, _, _, isCraftingReagent = C_Item.GetItemInfo(info.itemID)
                if not name then hasUncached = true end
                local _, _, _, _, instIcon, classID = GetItemInfoInstant(info.itemID)

                -- Section membership:
                --   "vt"   = Vendor Trash: quality 0 (grey), OR a scanned non-prof
                --           tradegood that came back below the AH floor.
                --   "ah"   = Auction House: non-prof tradegood/reagent that is
                --           either unscanned (no AH data yet — keep visible for
                --           Scan T) or scanned + above floor.
                --   "main" = items you use (gear, consumables, prof mats, etc.)
                local q = quality or info.quality or 1
                local qty = info.stackCount or 1
                local section = "main"
                local isProfitable = false

                if q == 0 then
                    section = "vt"
                elseif classID == 7 or isCraftingReagent then
                    local profs = GetPlayerProfs()
                    local playerUses = false
                    if subClassName then
                        local profsForSub = REAGENT_TO_PROF[subClassName]
                        if profsForSub then
                            for prof in pairs(profsForSub) do
                                if profs[prof] then
                                    playerUses = true
                                    break
                                end
                            end
                        end
                    end
                    if not playerUses then
                        local ahPrice = AH and AH.GetPrice and AH:GetPrice(info.itemID) or nil
                        if ahPrice then
                            -- We have scan data — classify by profitability.
                            if IsProfitableOnAH(info.itemID, qty, sellPrice) then
                                section = "ah"
                                isProfitable = true
                            else
                                -- Known below the floor: demote to VT so it
                                -- doesn't clutter the Auction House section.
                                section = "vt"
                            end
                        else
                            -- No AH data yet: keep in AH so Scan T picks it up.
                            section = "ah"
                        end
                    end
                end

                sellBagItems[#sellBagItems + 1] = {
                    bag = bag,
                    slot = slot,
                    itemID = info.itemID,
                    icon = icon or instIcon or info.iconFileID or 134400,
                    quality = q,
                    count = qty,
                    name = name or info.itemName or ("Item " .. info.itemID),
                    classID = classID or 99,
                    section = section,
                    isProfitable = isProfitable,
                }
            end)
        end
    end
    -- Sort: section order (main -> ah -> vt). Within AH, profitable first.
    -- Within each sub-group: classID order, then alpha.
    local SECTION_ORDER = { main = 1, ah = 2, vt = 3 }
    table.sort(sellBagItems, function(a, b)
        local sa = SECTION_ORDER[a.section or "main"] or 1
        local sb = SECTION_ORDER[b.section or "main"] or 1
        if sa ~= sb then return sa < sb end
        if a.section == "ah" and b.section == "ah" then
            if (a.isProfitable and 1 or 0) ~= (b.isProfitable and 1 or 0) then
                return a.isProfitable
            end
        end
        local oa = SELL_BAG_SORT_ORDER[a.classID] or 5
        local ob = SELL_BAG_SORT_ORDER[b.classID] or 5
        if oa ~= ob then return oa < ob end
        return a.name < b.name
    end)

    -- Insert visual section dividers: one before first "ah" item, one before first "vt" item
    local firstAH, firstVT
    local ahCount, vtCount, profCount = 0, 0, 0
    for i, item in ipairs(sellBagItems) do
        if item.section == "ah" then
            if not firstAH then firstAH = i end
            ahCount = ahCount + 1
            if item.isProfitable then profCount = profCount + 1 end
        elseif item.section == "vt" then
            if not firstVT then firstVT = i end
            vtCount = vtCount + 1
        end
    end

    -- Insert VT divider first (higher index), then AH divider, so indices don't shift
    if firstVT then
        table.insert(sellBagItems, firstVT, {
            isDivider = true,
            isVTHeader = true,
            name = "-- Vendor Trash — " .. vtCount .. " items --",
        })
    end
    if firstAH then
        local subtitle = ahCount .. " items"
        if profCount > 0 then
            subtitle = subtitle .. " — " .. profCount .. " above floor"
        end
        table.insert(sellBagItems, firstAH, {
            isDivider = true,
            isAHHeader = true,
            name = "-- Auction House — " .. subtitle .. " --",
        })
    end
    -- Deferred retry: if any items had uncached GetItemInfo, rebuild after a short delay
    if hasUncached then
        C_Timer.After(0.5, function()
            if panel and panel:IsShown() then
                BuildSellableBagItems()
                RefreshSellItemList()
            end
        end)
    end
end

local function CreateSellItemRow(parent, index)
    local row = CreateFrame("Button", nil, parent)

    local even = (index % 2 == 0)
    local bgVal = even and 0.14 or 0.10

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(bgVal, bgVal, bgVal, 0.9)
    row._bg = bg
    row._bgR, row._bgG, row._bgB, row._bgA = bgVal, bgVal, bgVal, 0.9

    row:SetScript("OnEnter", function(self)
        if self._isDivider then return end  -- no hover effect on section headers
        bg:SetColorTexture(0.20, 0.20, 0.28, 1)
        if self._bagID and self._slotID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetBagItem(self._bagID, self._slotID)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        bg:SetColorTexture(self._bgR, self._bgG, self._bgB, self._bgA)
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self)
        local bag, slot = self._bagID, self._slotID
        if not bag or not slot then return end
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and C_Item.DoesItemExist(loc) then
            sellBagSelected = { bag = bag, slot = slot }
            SellTab_SetItem(tabFrames[2], loc)
        end
    end)

    -- Icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 4, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row._icon = icon

    -- Name
    local name = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(name, 10, "")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetWidth(220)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row._name = name

    -- Quantity
    local qty = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(qty, 10, "")
    qty:SetTextColor(0.9, 0.9, 0.9)
    qty:SetPoint("LEFT", row, "LEFT", 250, 0)
    qty:SetWidth(40)
    qty:SetJustifyH("CENTER")
    row._qty = qty

    -- Price
    local price = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(price, 10, "")
    price:SetTextColor(1, 1, 1)
    price:SetPoint("LEFT", row, "LEFT", 300, 0)
    price:SetWidth(140)
    price:SetJustifyH("RIGHT")
    row._price = price

    -- Floor EditBox (only shown on the AH/VT divider row)
    local floorLabel = row:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(floorLabel, 10, "OUTLINE")
    floorLabel:SetText("Floor:")
    floorLabel:SetTextColor(1, 0.82, 0.30)
    floorLabel:SetPoint("RIGHT", row, "RIGHT", -140, 0)
    floorLabel:Hide()
    row._floorLabel = floorLabel

    local floorBox = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    floorBox:SetSize(45, 18)
    floorBox:SetPoint("LEFT", floorLabel, "RIGHT", 4, 0)
    floorBox:SetAutoFocus(false)
    floorBox:SetNumeric(true)
    floorBox:SetMaxLetters(6)
    floorBox:SetFontObject("GameFontHighlightSmall")
    floorBox:SetJustifyH("CENTER")
    floorBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    floorBox:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
    floorBox:SetBackdropBorderColor(0.25, 0.60, 0.85, 1)
    local goldSuffix = floorBox:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(goldSuffix, 10, "OUTLINE")
    goldSuffix:SetText("g")
    goldSuffix:SetTextColor(1, 0.84, 0.00)
    goldSuffix:SetPoint("LEFT", floorBox, "RIGHT", 2, 0)
    floorBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    floorBox:SetScript("OnEnterPressed", function(self)
        local txt = self:GetText()
        local g = tonumber(txt) or TRASH_MIN_FLOOR_DEFAULT_GOLD
        SetTrashFloorGold(g)
        self:ClearFocus()
        if panel and panel:IsShown() then
            BuildSellableBagItems()
            RefreshSellItemList()
        end
        print("|cff00c7ff[VoidAH]|r AH/VT floor set to " .. g .. "g.")
    end)
    floorBox:Hide()
    row._floorBox = floorBox

    -- Scan button (only shown on the AH/VT divider row)
    local scanBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    scanBtn:SetSize(60, 18)
    scanBtn:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    scanBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    scanBtn:SetBackdropColor(0.12, 0.40, 0.60, 0.9)
    scanBtn:SetBackdropBorderColor(0.25, 0.70, 0.95, 1)
    local scanText = scanBtn:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(scanText, 10, "OUTLINE")
    scanText:SetPoint("CENTER")
    scanText:SetText("Scan T")
    scanText:SetTextColor(1, 1, 1)
    scanBtn._label = scanText
    scanBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.20, 0.55, 0.80, 0.95)
    end)
    scanBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.12, 0.40, 0.60, 0.9)
    end)
    scanBtn:SetScript("OnClick", function()
        if ScanTrashItems then ScanTrashItems() end
    end)
    scanBtn:Hide()
    row._scanBtn = scanBtn

    row:Hide()
    return row
end

RefreshSellItemList = function()
    if not tabFrames or not tabFrames[2] then return end
    local parent = tabFrames[2]
    local rows = parent._sellItemRows
    if not rows then return end

    local total = #sellBagItems
    local maxOffset = math.max(total - SELL_LIST_VISIBLE, 0)
    sellListOffset = math.max(0, math.min(sellListOffset, maxOffset))

    local cfg = VoidUI:GetModuleConfig("Auction")
    local undercut = cfg.undercutCopper or 100

    for i = 1, SELL_LIST_VISIBLE do
        local row = rows[i]
        if not row then break end
        local dataIdx = sellListOffset + i
        local item = sellBagItems[dataIdx]
        if item and item.isDivider then
            -- Section header row (not clickable/selectable)
            row._bagID = nil
            row._slotID = nil
            row._isDivider = true
            row._icon:SetTexture(nil)
            row._name:SetTextColor(1, 0.55, 0.10)
            row._name:SetText("|cffff8c1a" .. item.name .. "|r")
            row._qty:SetText("")
            row._price:SetText("")
            row._bgR, row._bgG, row._bgB, row._bgA = 0.18, 0.10, 0.05, 0.85
            row._bg:SetColorTexture(0.18, 0.10, 0.05, 0.85)
            -- Show the scan button + floor editbox ONLY on the Auction House header
            if item.isAHHeader and row._scanBtn then
                if trashScanState then
                    local pct = (trashScanState.total > 0)
                        and math.floor((trashScanState.done / trashScanState.total) * 100)
                        or 0
                    row._scanBtn._label:SetText(pct .. "%")
                else
                    row._scanBtn._label:SetText("Scan T")
                end
                row._scanBtn:Show()
                if row._floorBox then
                    local floorGold = math.floor(GetTrashFloorCopper() / 10000)
                    if not row._floorBox:HasFocus() then
                        row._floorBox:SetText(tostring(floorGold))
                    end
                    row._floorBox:Show()
                    row._floorLabel:Show()
                end
            elseif row._scanBtn then
                row._scanBtn:Hide()
                if row._floorBox then
                    row._floorBox:Hide()
                    row._floorLabel:Hide()
                end
            end
            row:Show()
        elseif item then
            if row._scanBtn then row._scanBtn:Hide() end
            if row._floorBox then
                row._floorBox:Hide()
                row._floorLabel:Hide()
            end
            row._bagID = item.bag
            row._slotID = item.slot
            row._isDivider = nil
            row._icon:SetTexture(item.icon)

            -- Name colored by quality (trash items get a prefix tag)
            local r, g, b = C_Item.GetItemQualityColor(item.quality)
            if r then
                row._name:SetTextColor(r, g, b)
            else
                row._name:SetTextColor(1, 1, 1)
            end
            local displayName = item.name
            if item.section == "ah" then
                displayName = "|cff4db8e8[AH]|r " .. item.name
            elseif item.section == "vt" then
                displayName = "|cff888888[VT]|r " .. item.name
            end
            row._name:SetText(displayName)

            -- Quantity
            row._qty:SetText(item.count > 1 and tostring(item.count) or "1")

            -- Price from DB with undercut
            local price = AH:GetPrice(item.itemID)
            if price then
                local sellPrice = math.max(1, price - undercut)
                row._price:SetText(VoidUI:FormatMoney(sellPrice))
            else
                row._price:SetText("|cff666666no data|r")
            end

            -- Selected highlight
            local isSelected = sellBagSelected and sellBagSelected.bag == item.bag and sellBagSelected.slot == item.slot
            if isSelected then
                row._bgR, row._bgG, row._bgB, row._bgA = 0.0, 0.25, 0.30, 0.9
                row._bg:SetColorTexture(0.0, 0.25, 0.30, 0.9)
            else
                local even = (i % 2 == 0)
                local bgVal = even and 0.14 or 0.10
                row._bgR, row._bgG, row._bgB, row._bgA = bgVal, bgVal, bgVal, 0.9
                row._bg:SetColorTexture(bgVal, bgVal, bgVal, 0.9)
            end

            row:Show()
        else
            row._bagID = nil
            row._slotID = nil
            row._isDivider = nil
            if row._scanBtn then row._scanBtn:Hide() end
            if row._floorBox then
                row._floorBox:Hide()
                row._floorLabel:Hide()
            end
            row:Hide()
        end
    end

    -- Scroll indicator
    if parent._sellScrollTrack then
        if total > SELL_LIST_VISIBLE then
            local pct = maxOffset > 0 and (sellListOffset / maxOffset) or 0
            local trackH = parent._sellScrollTrack:GetHeight()
            local thumbH = parent._sellScrollThumb:GetHeight()
            parent._sellScrollThumb:ClearAllPoints()
            parent._sellScrollThumb:SetPoint("TOP", parent._sellScrollTrack, "TOP", 0, -pct * (trackH - thumbH))
            parent._sellScrollTrack:Show()
            parent._sellScrollThumb:Show()
        else
            parent._sellScrollTrack:Hide()
            parent._sellScrollThumb:Hide()
        end
    end

    -- Update count in header (exclude divider rows from the count)
    if parent._sellBagCount then
        local itemCount = 0
        for _, it in ipairs(sellBagItems) do
            if it and not it.isDivider then itemCount = itemCount + 1 end
        end
        parent._sellBagCount:SetText("|cff00ffffSellable Items|r |cff888888(" .. itemCount .. ")|r")
    end
end

function BuildSellTab(parent)
    -- Item display area
    local itemFrame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    itemFrame:SetSize(380, 200)
    itemFrame:SetPoint("TOPLEFT", 20, -10)
    VoidUI:CreateBackdrop(itemFrame, 0.06, 0.06, 0.06, 0.9)
    parent._itemFrame = itemFrame

    local dropLabel = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(dropLabel, 11, "")
    dropLabel:SetPoint("CENTER")
    dropLabel:SetText("|cff555555Click an item in your bags to sell|r")
    parent._dropLabel = dropLabel

    -- Item icon + name
    local sellIcon = itemFrame:CreateTexture(nil, "ARTWORK")
    sellIcon:SetSize(40, 40)
    sellIcon:SetPoint("TOPLEFT", 10, -10)
    sellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    sellIcon:Hide()
    parent._sellIcon = sellIcon

    local sellName = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(sellName, 12, "")
    sellName:SetPoint("TOPLEFT", sellIcon, "TOPRIGHT", 8, -2)
    sellName:SetWidth(300)
    sellName:SetJustifyH("LEFT")
    parent._sellName = sellName

    local sellInfo = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(sellInfo, 10, "")
    sellInfo:SetPoint("TOPLEFT", sellName, "BOTTOMLEFT", 0, -4)
    sellInfo:SetWidth(300)
    sellInfo:SetJustifyH("LEFT")
    parent._sellInfo = sellInfo

    -- Price input area
    local priceLabel = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(priceLabel, 10, "")
    priceLabel:SetPoint("TOPLEFT", itemFrame, "TOPLEFT", 10, -70)
    priceLabel:SetText("Price per unit:")
    parent._priceLabel = priceLabel

    local goldBox = CreateEditBox(itemFrame, 80, 22, "Gold")
    goldBox:SetPoint("LEFT", priceLabel, "RIGHT", 10, 0)
    goldBox:SetNumeric(true)
    parent._goldBox = goldBox

    local goldSuffix = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(goldSuffix, 10, "")
    goldSuffix:SetPoint("LEFT", goldBox, "RIGHT", 2, 0)
    goldSuffix:SetText("|cffffd700g|r")

    local silverBox = CreateEditBox(itemFrame, 40, 22, "Sv")
    silverBox:SetPoint("LEFT", goldSuffix, "RIGHT", 4, 0)
    silverBox:SetNumeric(true)
    parent._silverBox = silverBox

    local silverSuffix = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(silverSuffix, 10, "")
    silverSuffix:SetPoint("LEFT", silverBox, "RIGHT", 2, 0)
    silverSuffix:SetText("|cffc0c0c0s|r")

    local copperBox = CreateEditBox(itemFrame, 40, 22, "Cu")
    copperBox:SetPoint("LEFT", silverSuffix, "RIGHT", 4, 0)
    copperBox:SetNumeric(true)
    parent._copperBox = copperBox

    local copperSuffix = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(copperSuffix, 10, "")
    copperSuffix:SetPoint("LEFT", copperBox, "RIGHT", 2, 0)
    copperSuffix:SetText("|cffeda55fc|r")

    -- % undercut input — recomputes price from current market when changed.
    -- IMPORTANT: build WITHOUT a placeholder arg, because CreateEditBox sets
    -- its own OnTextChanged for placeholder show/hide that would conflict
    -- with our recalc handler.
    local undercutBox = CreateEditBox(itemFrame, 32, 22, nil)
    undercutBox:SetPoint("LEFT", copperSuffix, "RIGHT", 10, 0)
    undercutBox:SetNumeric(false)  -- allow decimal like 2.5
    parent._undercutBox = undercutBox

    local undercutSuffix = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(undercutSuffix, 10, "")
    undercutSuffix:SetPoint("LEFT", undercutBox, "RIGHT", 2, 0)
    undercutSuffix:SetText("|cffffd700% undercut|r")

    -- Initialize cfg.undercutPercent IMMEDIATELY so the very first item
    -- selection uses the % path (not the legacy copper undercut fallback).
    do
        local cfg = VoidUI:GetModuleConfig("Auction")
        if cfg.undercutPercent == nil then cfg.undercutPercent = 5 end
        undercutBox:SetText(tostring(cfg.undercutPercent))
    end

    -- Recalc price boxes when % changes — bound function used by all
    -- commit triggers (typing, Enter, focus-lost) for consistency.
    local function CommitUndercutChange()
        local pct = tonumber(undercutBox:GetText())
        if not pct or pct < 0 then return end
        local cfg = VoidUI:GetModuleConfig("Auction")
        cfg.undercutPercent = pct
        if not sellPending.itemID then return end
        local marketPrice = AH:GetPrice(sellPending.itemID)
        if not marketPrice or marketPrice <= 0 then return end
        local newPrice = math.max(1, math.floor(marketPrice * (1 - pct / 100)))
        parent._goldBox:SetText(tostring(math.floor(newPrice / 10000)))
        parent._silverBox:SetText(tostring(math.floor((newPrice % 10000) / 100)))
        parent._copperBox:SetText(tostring(newPrice % 100))
    end
    undercutBox:SetScript("OnTextChanged",    CommitUndercutChange)
    undercutBox:SetScript("OnEnterPressed",   function(self) self:ClearFocus(); CommitUndercutChange() end)
    undercutBox:SetScript("OnEditFocusLost",  CommitUndercutChange)

    -- Duration buttons
    local durLabel = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(durLabel, 10, "")
    durLabel:SetPoint("TOPLEFT", priceLabel, "BOTTOMLEFT", 0, -10)
    durLabel:SetText("Duration:")
    parent._durLabel = durLabel

    local durations = { { 12, "12h" }, { 24, "24h" }, { 48, "48h" } }
    local durButtons = {}
    sellPending.duration = 2  -- index: 0=12h, 1=24h, 2=48h
    for di, d in ipairs(durations) do
        local dbtn = CreateButton(itemFrame, 50, 22, d[2], function()
            sellPending.duration = di - 1
            for j, b in ipairs(durButtons) do
                if j == di then
                    b._bg:SetColorTexture(0, 0.55, 0.55, 1)
                else
                    b._bg:SetColorTexture(0.15, 0.15, 0.15, 1)
                end
            end
        end)
        dbtn:SetPoint("LEFT", durLabel, "RIGHT", 10 + (di - 1) * 56, 0)
        durButtons[di] = dbtn
    end
    durButtons[3]._bg:SetColorTexture(0, 0.55, 0.55, 1)  -- default 48h
    parent._durButtons = durButtons

    -- Quantity
    local qtyLabel = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(qtyLabel, 10, "")
    qtyLabel:SetPoint("TOPLEFT", durLabel, "BOTTOMLEFT", 0, -10)
    qtyLabel:SetText("Quantity:")

    local qtyBox = CreateEditBox(itemFrame, 60, 22, "1")
    qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 10, 0)
    qtyBox:SetNumeric(true)
    parent._qtyBox = qtyBox

    -- Deposit info
    local depositText = itemFrame:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(depositText, 10, "")
    depositText:SetPoint("TOPLEFT", qtyLabel, "BOTTOMLEFT", 0, -10)
    depositText:SetText("")
    parent._depositText = depositText

    -- POST button (hardware event — calls PostItem/PostCommodity in OnClick)
    local postBtn = CreateFrame("Button", "VoidUI_AH_PostButton", parent)
    postBtn:SetSize(380, 36)
    postBtn:SetPoint("TOPLEFT", itemFrame, "BOTTOMLEFT", 0, -8)

    local postBg = postBtn:CreateTexture(nil, "BACKGROUND")
    postBg:SetAllPoints()
    postBg:SetColorTexture(0.0, 0.4, 0.2, 1)
    postBtn._bg = postBg

    local postText = postBtn:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(postText, 12, "OUTLINE")
    postText:SetPoint("CENTER")
    postText:SetText("|cffffffffPost Auction|r")

    postBtn:SetScript("OnClick", function()
        SellTab_PostAuction(parent)
    end)
    postBtn:SetScript("OnEnter", function() postBg:SetColorTexture(0.0, 0.5, 0.3, 1) end)
    postBtn:SetScript("OnLeave", function() postBg:SetColorTexture(0.0, 0.4, 0.2, 1) end)
    parent._postBtn = postBtn

    -- Recent Posts (below Post button, left side)
    local recentLabel = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(recentLabel, 10, "OUTLINE")
    recentLabel:SetPoint("TOPLEFT", postBtn, "BOTTOMLEFT", 0, -10)
    recentLabel:SetText("|cff00ffffRecent Posts|r")

    parent._recentPosts = {}
    parent._recentLabel = recentLabel

    for i = 1, 3 do
        local fs = parent:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(fs, 9, "")
        fs:SetPoint("TOPLEFT", recentLabel, "BOTTOMLEFT", 0, -2 - (i - 1) * 16)
        fs:SetWidth(370)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:SetText("")
        parent._recentPosts[i] = fs
    end

    -- Sellable Items header (right side)
    local sellBagHeader = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(sellBagHeader, 11, "OUTLINE")
    sellBagHeader:SetPoint("TOPLEFT", 420, -4)
    sellBagHeader:SetText("|cff00ffffSellable Items|r |cff888888(0)|r")
    parent._sellBagCount = sellBagHeader

    -- Column headers
    local sellColHeader = CreateFrame("Frame", nil, parent)
    sellColHeader:SetPoint("TOPLEFT", 420, -20)
    sellColHeader:SetSize(460, 18)
    local sellColBg = sellColHeader:CreateTexture(nil, "BACKGROUND")
    sellColBg:SetAllPoints()
    sellColBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    local sellCols = {
        { "Item", "LEFT", 28, 220 },
        { "Qty", "CENTER", 250, 40 },
        { "Price", "RIGHT", 300, 140 },
    }
    for _, col in ipairs(sellCols) do
        local fs = sellColHeader:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(fs, 9, "OUTLINE")
        fs:SetTextColor(0.67, 0.67, 0.67)
        fs:SetPoint("LEFT", col[3], 0)
        fs:SetWidth(col[4])
        fs:SetJustifyH(col[2])
        fs:SetText(col[1])
    end

    -- List area
    local listArea = CreateFrame("Frame", nil, parent)
    listArea:SetPoint("TOPLEFT", 420, -40)
    listArea:SetPoint("BOTTOMRIGHT", -14, 4)

    -- Create row pool
    parent._sellItemRows = {}
    for i = 1, SELL_LIST_VISIBLE do
        local row = CreateSellItemRow(listArea, i)
        row:SetSize(460, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", listArea, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        parent._sellItemRows[i] = row
    end

    -- Mouse wheel scroll on list
    listArea:EnableMouseWheel(true)
    listArea:SetScript("OnMouseWheel", function(self, delta)
        local total = #sellBagItems
        local maxOffset = math.max(total - SELL_LIST_VISIBLE, 0)
        sellListOffset = math.max(0, math.min(sellListOffset - delta * 3, maxOffset))
        RefreshSellItemList()
    end)
    for _, row in ipairs(parent._sellItemRows) do
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(self, delta)
            local total = #sellBagItems
            local maxOffset = math.max(total - SELL_LIST_VISIBLE, 0)
            sellListOffset = math.max(0, math.min(sellListOffset - delta * 3, maxOffset))
            RefreshSellItemList()
        end)
    end

    -- Scroll indicator (right edge of list)
    local scrollTrack = CreateFrame("Frame", nil, listArea)
    scrollTrack:SetWidth(4)
    scrollTrack:SetPoint("TOPRIGHT", listArea, "TOPRIGHT", 0, 0)
    scrollTrack:SetPoint("BOTTOMRIGHT", listArea, "BOTTOMRIGHT", 0, 0)
    local trackBg = scrollTrack:CreateTexture(nil, "BACKGROUND")
    trackBg:SetAllPoints()
    trackBg:SetColorTexture(0.15, 0.15, 0.15, 0.5)
    scrollTrack:Hide()
    parent._sellScrollTrack = scrollTrack

    local scrollThumb = scrollTrack:CreateTexture(nil, "ARTWORK")
    scrollThumb:SetWidth(4)
    scrollThumb:SetHeight(30)
    scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, 0)
    scrollThumb:SetColorTexture(0, 0.55, 0.55, 0.8)
    scrollThumb:Hide()
    parent._sellScrollThumb = scrollThumb
end

function SellTab_SetItem(parent, itemLocation)
    if not itemLocation or not C_Item.DoesItemExist(itemLocation) then return end

    local itemID = C_Item.GetItemID(itemLocation)
    if not itemID then return end

    local itemName, itemLink, quality, _, _, _, _, _, _, itemTexture = C_Item.GetItemInfo(itemID)
    if not itemName then
        -- Item info not cached yet, retry
        C_Timer.After(0.3, function()
            SellTab_SetItem(parent, itemLocation)
        end)
        return
    end

    local count = C_Item.GetStackCount(itemLocation)
    -- GetItemCommodityStatus can return Unknown if item data isn't loaded yet.
    -- Request load and resolve before allowing post.
    local commodityStatus = C_AuctionHouse.GetItemCommodityStatus(itemLocation)
    local isCommodity = (commodityStatus == Enum.ItemCommodityStatus.Commodity)

    -- Store pending
    sellPending.itemLocation = itemLocation
    sellPending.itemID = itemID
    sellPending.isCommodity = isCommodity
    sellPending.stackCount = count

    -- If commodity status unknown, request data load and re-check
    if commodityStatus == Enum.ItemCommodityStatus.Unknown then
        C_Item.RequestLoadItemData(itemLocation)
        C_Timer.After(0.3, function()
            if not C_Item.DoesItemExist(itemLocation) then return end
            if sellPending.itemID ~= itemID then return end  -- user selected something else
            local status = C_AuctionHouse.GetItemCommodityStatus(itemLocation)
            sellPending.isCommodity = (status == Enum.ItemCommodityStatus.Commodity)
            local label = sellPending.isCommodity and "Commodity" or "Item"
            parent._sellInfo:SetText(label .. " | Stack: " .. count)
        end)
    end

    -- Update display
    parent._dropLabel:Hide()
    parent._sellIcon:SetTexture(itemTexture)
    parent._sellIcon:Show()
    parent._sellName:SetText(itemLink or itemName)
    parent._sellInfo:SetText((isCommodity and "Commodity" or "Item") .. " | Stack: " .. count)
    parent._qtyBox:SetText(tostring(count))

    -- Query current price
    AH:QueryItemPrice(itemID)

    -- Set price from DB as default — apply % undercut if set, else fall back
    -- to copper undercut for backwards compatibility
    local price = AH:GetPrice(itemID)
    if price then
        local cfg = VoidUI:GetModuleConfig("Auction")
        local pct = tonumber(cfg.undercutPercent)
        if pct and pct > 0 then
            price = math.max(1, math.floor(price * (1 - pct / 100)))
        else
            local undercut = cfg.undercutCopper or 100
            price = math.max(1, price - undercut)
        end
    end
    if price then
        parent._goldBox:SetText(tostring(math.floor(price / 10000)))
        parent._silverBox:SetText(tostring(math.floor((price % 10000) / 100)))
        parent._copperBox:SetText(tostring(price % 100))
    else
        parent._goldBox:SetText("")
        parent._silverBox:SetText("")
        parent._copperBox:SetText("")
    end

    -- Update bag grid selection + remember which section this item was in
    local bag, slot = itemLocation:GetBagAndSlot()
    if bag and slot then
        sellBagSelected = { bag = bag, slot = slot }
        -- Look up the item's section in the current sellBagItems so that
        -- after a successful post we can auto-advance to the next item
        -- in the same section (AH keeps selling AH, VT keeps selling VT).
        sellPending._section = "main"
        for _, it in ipairs(sellBagItems) do
            if it and not it.isDivider and it.bag == bag and it.slot == slot then
                sellPending._section = it.section or "main"
                break
            end
        end
    end
    RefreshSellItemList()
end

function SellTab_PostAuction(parent)
    if not sellPending.itemLocation then return end

    if not C_Item.DoesItemExist(sellPending.itemLocation) then
        print("|cffff0000VoidUI AH|r: No item selected or item no longer exists.")
        return
    end

    local gold = tonumber(parent._goldBox:GetText()) or 0
    local silver = tonumber(parent._silverBox:GetText()) or 0
    local copper = tonumber(parent._copperBox:GetText()) or 0
    local totalPrice = gold * 10000 + silver * 100 + copper

    if totalPrice <= 0 then
        print("|cffff0000VoidUI AH|r: Price must be greater than 0.")
        return
    end

    local qty = tonumber(parent._qtyBox:GetText()) or 1
    local duration = sellPending.duration or 2
    local itemName = C_Item.GetItemInfo(sellPending.itemID) or "?"

    local rawStatus = C_AuctionHouse.GetItemCommodityStatus(sellPending.itemLocation)

    local posted = false
    local isCommodity = (rawStatus == 2 or sellPending.isCommodity)

    -- Try PostCommodity first if commodity.
    -- IMPORTANT: PostCommodity silently fails when unitPrice has any copper
    -- component. Round to whole silver before posting commodities.
    if isCommodity then
        local commodityPrice = math.floor(totalPrice / 100) * 100
        if commodityPrice < 100 then commodityPrice = 100 end  -- 1s minimum
        if commodityPrice ~= totalPrice then
            print(("|cffffaa00VoidUI AH|r: Commodity price rounded to %s (PostCommodity rejects copper)."):format(
                VoidUI:FormatMoney(commodityPrice)))
        end
        local ok, ret = pcall(C_AuctionHouse.PostCommodity,
            sellPending.itemLocation, duration, qty, commodityPrice)
        if ok and ret ~= false then posted = true end
    end

    -- Fallback: PostItem with nil bid
    if not posted then
        local ok, ret = pcall(C_AuctionHouse.PostItem,
            sellPending.itemLocation, duration, qty, nil, totalPrice)
        if ok and ret ~= false then posted = true end
    end

    -- Fallback: PostItem with bid = buyout
    if not posted then
        local ok, ret = pcall(C_AuctionHouse.PostItem,
            sellPending.itemLocation, duration, qty, totalPrice, totalPrice)
        if ok and ret ~= false then posted = true end
    end

    if not posted then
        print("|cffff0000VoidUI AH|r: Failed to post " .. itemName .. ".")
        return
    end

    -- Store pending post info for OnAuctionCreated to confirm
    sellPending._lastPostName = itemName
    sellPending._lastPostQty = qty
    sellPending._lastPostPrice = totalPrice
end

----------------------------------------------------------------------
-- TAB 3: My Auctions
----------------------------------------------------------------------
function BuildMyAuctionsTab(parent)
    -- Header
    local refreshBtn = CreateButton(parent, 100, 24, "Refresh", function()
        AH:QueryOwnedAuctions()
    end)
    refreshBtn:SetPoint("TOPLEFT", 10, -4)

    local cancelAllBtn = CreateButton(parent, 100, 24, "|cffff4444Cancel All|r", function()
        -- Confirm before cancelling all
        print("|cff00ffffVoidUI AH|r: Cancel All is not yet implemented for safety.")
    end)
    cancelAllBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)

    -- Column headers
    local colHeader = CreateFrame("Frame", nil, parent)
    colHeader:SetPoint("TOPLEFT", 10, -34)
    colHeader:SetPoint("TOPRIGHT", -10, -34)
    colHeader:SetHeight(20)

    local colBg = colHeader:CreateTexture(nil, "BACKGROUND")
    colBg:SetAllPoints()
    colBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    local cols = {
        { "Item", "LEFT", 4, 220 },
        { "Qty", "CENTER", 275, 40 },
        { "Your Price", "RIGHT", 320, 140 },
        { "Market", "RIGHT", 470, 120 },
        { "Status", "CENTER", 600, 60 },
        { "Time Left", "CENTER", 670, 60 },
        { "", "CENTER", 780, 50 },
    }
    for _, col in ipairs(cols) do
        local fs = colHeader:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(fs, 9, "OUTLINE")
        fs:SetPoint("LEFT", col[3], 0)
        fs:SetWidth(col[4])
        fs:SetJustifyH(col[2])
        fs:SetText("|cffaaaaaa" .. col[1] .. "|r")
    end

    -- Auctions scroll list
    local listContainer = CreateFrame("Frame", nil, parent)
    listContainer:SetPoint("TOPLEFT", 10, -56)
    listContainer:SetPoint("BOTTOMRIGHT", -10, 4)

    local scrollFrame = CreateFrame("ScrollFrame", "VoidUI_AuctionsScroll", listContainer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetAllPoints()

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(LIST_WIDTH - 20)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    parent._scrollChild = scrollChild
    parent._rows = {}

    for i = 1, 30 do
        local row = CreateItemRow(scrollChild, i)
        row:SetSize(LIST_WIDTH - 20, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

        -- Cancel button per row
        local cancelBtn = CreateFrame("Button", nil, row)
        cancelBtn:SetSize(50, 20)
        cancelBtn:SetPoint("LEFT", row, "LEFT", 780, 0)

        local cbg = cancelBtn:CreateTexture(nil, "BACKGROUND")
        cbg:SetAllPoints()
        cbg:SetColorTexture(0.4, 0.1, 0.1, 1)

        local ctext = cancelBtn:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(ctext, 9, "")
        ctext:SetPoint("CENTER")
        ctext:SetText("Cancel")

        cancelBtn:SetScript("OnEnter", function() cbg:SetColorTexture(0.6, 0.15, 0.15, 1) end)
        cancelBtn:SetScript("OnLeave", function() cbg:SetColorTexture(0.4, 0.1, 0.1, 1) end)
        cancelBtn:SetScript("OnClick", function()
            if not row._auctionID then
                print("|cffff6060[VoidUI AH]|r No auction ID on this row.")
                return
            end
            -- Route through throttle queue. Rapid cancel clicks would otherwise
            -- saturate the AH throttle bucket and silently drop after the first
            -- few requests.
            local auctionID = row._auctionID
            AH:_Enqueue(function()
                local ok, err = pcall(C_AuctionHouse.CancelAuction, auctionID)
                if not ok then
                    print("|cffff6060[VoidUI AH]|r Cancel failed: " .. tostring(err))
                end
            end)
            print("|cff00ff00[VoidUI AH]|r Cancelling auction...")
        end)
        row._cancelBtn = cancelBtn

        row:Hide()
        parent._rows[i] = row
    end
end

local function UpdateMyAuctions()
    if not tabFrames or not tabFrames[3] then return end
    local parent = tabFrames[3]
    if not parent._rows then return end

    local numOwned = C_AuctionHouse.GetNumOwnedAuctions()
    local child = parent._scrollChild
    child:SetHeight(math.max(numOwned * ROW_HEIGHT, 1))

    -- Grow row pool if needed
    while #parent._rows < numOwned do
        local i = #parent._rows + 1
        local row = CreateItemRow(child, i)
        row:SetSize(LIST_WIDTH - 20, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

        local cancelBtn = CreateFrame("Button", nil, row)
        cancelBtn:SetSize(50, 20)
        cancelBtn:SetPoint("LEFT", row, "LEFT", 780, 0)
        local cbg = cancelBtn:CreateTexture(nil, "BACKGROUND")
        cbg:SetAllPoints()
        cbg:SetColorTexture(0.4, 0.1, 0.1, 1)
        local ctext = cancelBtn:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(ctext, 9, "")
        ctext:SetPoint("CENTER")
        ctext:SetText("Cancel")
        cancelBtn:SetScript("OnEnter", function() cbg:SetColorTexture(0.6, 0.15, 0.15, 1) end)
        cancelBtn:SetScript("OnLeave", function() cbg:SetColorTexture(0.4, 0.1, 0.1, 1) end)
        cancelBtn:SetScript("OnClick", function()
            if not row._auctionID then
                print("|cffff6060[VoidUI AH]|r No auction ID on this row.")
                return
            end
            -- Route through throttle queue. Rapid cancel clicks would otherwise
            -- saturate the AH throttle bucket and silently drop after the first
            -- few requests.
            local auctionID = row._auctionID
            AH:_Enqueue(function()
                local ok, err = pcall(C_AuctionHouse.CancelAuction, auctionID)
                if not ok then
                    print("|cffff6060[VoidUI AH]|r Cancel failed: " .. tostring(err))
                end
            end)
            print("|cff00ff00[VoidUI AH]|r Cancelling auction...")
        end)
        row._cancelBtn = cancelBtn

        row:Hide()
        parent._rows[i] = row
    end

    local timeLabels = { [0] = "Short", [1] = "Medium", [2] = "Long", [3] = "Very Long" }

    for i = 1, math.max(numOwned, #parent._rows) do
        local row = parent._rows[i]
        if not row then break end

        if i <= numOwned then
            local auction = C_AuctionHouse.GetOwnedAuctionInfo(i)
            if auction then
                local itemID = auction.itemKey and auction.itemKey.itemID
                row._itemID = itemID
                row._auctionID = auction.auctionID

                local itemName, _, _, _, _, _, _, _, _, itemTexture = C_Item.GetItemInfo(itemID or 0)
                row._icon:SetTexture(itemTexture or 134400)
                row._name:SetText(itemName or ("Item " .. (itemID or "?")))
                local qty = VoidUI.AH.SafeNum(auction.quantity) or 1
                local buyout = VoidUI.AH.SafeNum(auction.buyoutAmount)
                row._qty:SetText(qty)
                row._price:SetText(buyout and VoidUI:FormatMoney(buyout) or "Bid")

                -- Undercut detection
                local market = AH:GetPrice(itemID)
                row._market:SetText(market and VoidUI:FormatMoney(market) or "")

                local perUnit = buyout
                if qty > 1 and buyout then
                    perUnit = math.floor(buyout / qty)
                end
                if market and perUnit and market < perUnit then
                    row._deal:SetText("|cffff4444UNDERCUT|r")
                elseif market and perUnit and market == perUnit then
                    row._deal:SetText("|cffffaa00Matched|r")
                else
                    row._deal:SetText("|cff00ff00Lowest|r")
                end

                -- timeLeft is Enum.AuctionHouseTimeLeftBand (0=Short..3=VeryLong).
                -- Was reading `timeLeftSeconds and 3 or 0` (boolean coercion!) which
                -- always showed Long/Short regardless of actual time remaining.
                row._extra:SetText(timeLabels[auction.timeLeft or 0] or "")
                if row._cancelBtn then row._cancelBtn:Show() end
                row:Show()
            else
                row:Hide()
            end
        else
            row:Hide()
        end
    end
end

----------------------------------------------------------------------
-- TAB 4: Deals
----------------------------------------------------------------------
function BuildDealsTab(parent)
    local label = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(label, 11, "OUTLINE")
    label:SetPoint("TOPLEFT", 10, -4)
    label:SetText("|cff00ffffDeals — Items below market value|r")

    local refreshBtn = CreateButton(parent, 120, 24, "Find Deals", function()
        FindDeals()
    end)
    refreshBtn:SetPoint("TOPRIGHT", -10, -4)

    -- Column headers
    local colHeader = CreateFrame("Frame", nil, parent)
    colHeader:SetPoint("TOPLEFT", 10, -34)
    colHeader:SetPoint("TOPRIGHT", -10, -34)
    colHeader:SetHeight(20)

    local colBg = colHeader:CreateTexture(nil, "BACKGROUND")
    colBg:SetAllPoints()
    colBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    local cols = {
        { "Item", "LEFT", 4, 220 },
        { "Qty", "CENTER", 275, 40 },
        { "AH Price", "RIGHT", 320, 140 },
        { "7d Mean", "RIGHT", 470, 120 },
        { "Deal %", "CENTER", 600, 60 },
        { "Savings", "RIGHT", 670, 100 },
    }
    for _, col in ipairs(cols) do
        local fs = colHeader:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(fs, 9, "OUTLINE")
        fs:SetPoint("LEFT", col[3], 0)
        fs:SetWidth(col[4])
        fs:SetJustifyH(col[2])
        fs:SetText("|cffaaaaaa" .. col[1] .. "|r")
    end

    -- Deals list
    local listContainer = CreateFrame("Frame", nil, parent)
    listContainer:SetPoint("TOPLEFT", 10, -56)
    listContainer:SetPoint("BOTTOMRIGHT", -10, 4)

    local scrollFrame = CreateFrame("ScrollFrame", "VoidUI_DealsScroll", listContainer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetAllPoints()

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(LIST_WIDTH - 20)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    parent._scrollChild = scrollChild
    parent._rows = {}

    for i = 1, 50 do
        local row = CreateItemRow(scrollChild, i)
        row:SetSize(LIST_WIDTH - 20, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:Hide()
        parent._rows[i] = row
    end
end

function FindDeals()
    dealResults = {}
    local cfg = VoidUI:GetModuleConfig("Auction")
    local threshold = cfg.dealThreshold or 80
    local db = VoidUIAuctionDB and VoidUIAuctionDB[GetRealmName()]
    if not db then
        print("|cff00ffffVoidUI AH|r: No price data. Run a scan first.")
        return
    end

    for key, entry in pairs(db) do
        local itemID = tonumber(key)
        if itemID and entry.m and entry.m > 0 then
            local mean = AH:GetMarketMean(itemID, 7)
            if mean and mean > 0 then
                local pct = math.floor((entry.m / mean) * 100)
                if pct <= threshold then
                    dealResults[#dealResults + 1] = {
                        itemID = itemID,
                        price = entry.m,
                        mean = mean,
                        pct = pct,
                        savings = mean - entry.m,
                    }
                end
            end
        end
    end

    -- Sort by deal % ascending (best deals first)
    table.sort(dealResults, function(a, b) return a.pct < b.pct end)

    -- Update UI
    local parent = tabFrames[4]
    if not parent or not parent._rows then return end
    local child = parent._scrollChild
    child:SetHeight(math.max(#dealResults * ROW_HEIGHT, 1))

    while #parent._rows < #dealResults do
        local i = #parent._rows + 1
        local row = CreateItemRow(child, i)
        row:SetSize(LIST_WIDTH - 20, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        parent._rows[i] = row
    end

    for i, row in ipairs(parent._rows) do
        local data = dealResults[i]
        if data then
            local itemName, _, _, _, _, _, _, _, _, itemTexture = C_Item.GetItemInfo(data.itemID)
            row._itemID = data.itemID
            row._icon:SetTexture(itemTexture or 134400)
            row._name:SetText(itemName or ("Item " .. data.itemID))
            row._qty:SetText("")
            row._price:SetText(VoidUI:FormatMoney(data.price))
            row._market:SetText(VoidUI:FormatMoney(data.mean))
            row._deal:SetText("|cff00ff00" .. data.pct .. "%|r")
            row._extra:SetText("|cff00ff00-" .. VoidUI:FormatMoney(data.savings) .. "|r")
            row:Show()
        else
            row:Hide()
        end
    end

    print("|cff00ffffVoidUI AH|r: Found " .. #dealResults .. " deals at <=" .. threshold .. "% of market.")
end

----------------------------------------------------------------------
-- TAB 5: Scan
----------------------------------------------------------------------
function BuildScanTab(parent)
    -- Scan buttons
    local fullScanBtn = CreateButton(parent, 160, 32, "Full Scan", function()
        AH:StartFullScan()
    end)
    fullScanBtn:SetPoint("TOPLEFT", 20, -20)
    parent._fullScanBtn = fullScanBtn

    local fullCooldown = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(fullCooldown, 9, "")
    fullCooldown:SetPoint("LEFT", fullScanBtn, "RIGHT", 10, 0)
    parent._fullCooldown = fullCooldown

    local browseScanBtn = CreateButton(parent, 160, 32, "Browse Scan", function()
        AH:StartBrowseScan()
    end)
    browseScanBtn:SetPoint("TOPLEFT", fullScanBtn, "BOTTOMLEFT", 0, -8)
    parent._browseScanBtn = browseScanBtn

    local abortBtn = CreateButton(parent, 100, 32, "|cffff4444Abort|r", function()
        AH:AbortScan()
    end)
    abortBtn:SetPoint("LEFT", browseScanBtn, "RIGHT", 10, 0)

    -- Progress bar
    local progressBg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    progressBg:SetSize(400, 24)
    progressBg:SetPoint("TOPLEFT", browseScanBtn, "BOTTOMLEFT", 0, -16)
    VoidUI:CreateBackdrop(progressBg, 0.08, 0.08, 0.08, 1)

    local progressBar = progressBg:CreateTexture(nil, "ARTWORK")
    progressBar:SetPoint("TOPLEFT", 1, -1)
    progressBar:SetHeight(22)
    progressBar:SetWidth(1)
    progressBar:SetColorTexture(0, 0.6, 0.6, 1)
    parent._progressBar = progressBar
    parent._progressBg = progressBg

    local progressText = progressBg:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(progressText, 10, "OUTLINE")
    progressText:SetPoint("CENTER")
    progressText:SetText("Idle")
    parent._progressText = progressText

    -- DB Stats
    local statsLabel = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(statsLabel, 11, "OUTLINE")
    statsLabel:SetPoint("TOPLEFT", progressBg, "BOTTOMLEFT", 0, -20)
    statsLabel:SetText("|cff00ffffDatabase Stats|r")

    local statsText = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(statsText, 10, "")
    statsText:SetPoint("TOPLEFT", statsLabel, "BOTTOMLEFT", 0, -6)
    statsText:SetWidth(400)
    statsText:SetJustifyH("LEFT")
    parent._statsText = statsText

    -- Shopping Lists section (right side)
    local shopLabel = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(shopLabel, 11, "OUTLINE")
    shopLabel:SetPoint("TOPLEFT", 480, -20)
    shopLabel:SetText("|cff00ffffShopping List|r")

    local shopAddBox = CreateEditBox(parent, 200, 22, "Item name or ID...")
    shopAddBox:SetPoint("TOPLEFT", shopLabel, "BOTTOMLEFT", 0, -6)
    parent._shopAddBox = shopAddBox

    -- Threshold input
    local shopThreshBox = CreateEditBox(parent, 80, 22, "Gold (0=auto)")
    shopThreshBox:SetPoint("LEFT", shopAddBox, "RIGHT", 4, 0)
    shopThreshBox:SetNumeric(false)
    parent._shopThreshBox = shopThreshBox

    local shopAddBtn = CreateButton(parent, 60, 22, "Add", function()
        local text = shopAddBox:GetText()
        if text and text ~= "" then
            local threshText = shopThreshBox:GetText() or "0"
            local threshGold = tonumber(threshText) or 0
            ResolveAndAddItem(text, math.floor(threshGold * 10000), parent)
            shopAddBox:SetText("")
            shopThreshBox:SetText("")
        end
    end)
    shopAddBtn:SetPoint("LEFT", shopThreshBox, "RIGHT", 4, 0)

    shopAddBox:SetScript("OnEnterPressed", function(self)
        shopAddBtn:GetScript("OnClick")(shopAddBtn)
        self:ClearFocus()
    end)

    parent._shopRows = {}
    for i = 1, 10 do
        local row = CreateFrame("Frame", nil, parent)
        row:SetSize(380, 18)
        row:SetPoint("TOPLEFT", 480, -66 - (i - 1) * 20)

        local fs = row:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(fs, 9, "")
        fs:SetPoint("LEFT", 0, 0)
        fs:SetWidth(290)
        fs:SetJustifyH("LEFT")
        row._text = fs

        -- Buy button: jumps to Browse tab and auto-searches this item.
        -- Wired in UpdateShoppingList per-entry so we always read current data.
        local buyBtn = CreateButton(row, 44, 18, "|cff00ff00Buy|r", nil)
        buyBtn:SetPoint("RIGHT", row, "RIGHT", -22, 0)
        row._buyBtn = buyBtn

        local removeBtn = CreateButton(row, 18, 18, "x", function()
            RemoveShoppingEntry(i, parent)
        end)
        removeBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row._removeBtn = removeBtn

        row:Hide()
        parent._shopRows[i] = row
    end
end

----------------------------------------------------------------------
-- Shopping List: persistence + management
----------------------------------------------------------------------
function LoadShoppingList()
    local cfg = VoidUI:GetModuleConfig("Auction")
    return cfg.shoppingList or {}
end

function ResolveAndAddItem(text, thresholdCopper, parent)
    local id = tonumber(text)
    if id then
        -- Direct itemID
        local name = C_Item.GetItemNameByID(id)
        if name then
            AddShoppingEntry(id, name, thresholdCopper, parent)
        else
            -- Item not cached yet, request it
            local item = Item:CreateFromItemID(id)
            item:ContinueOnItemLoad(function()
                local n = C_Item.GetItemNameByID(id) or ("Item " .. id)
                AddShoppingEntry(id, n, thresholdCopper, parent)
            end)
        end
    else
        -- Name search — try GetItemInfoInstant for exact match
        local found = false
        -- Use C_Item.GetItemIDForItemInfo if available, otherwise search DB
        local ok, info1 = pcall(C_Item.GetItemInfoInstant, text)
        if ok and info1 then
            local itemID = info1
            local name = C_Item.GetItemNameByID(itemID) or text
            AddShoppingEntry(itemID, name, thresholdCopper, parent)
            found = true
        end
        if not found then
            -- Fallback: use GetItemInfo (works if item is cached)
            local itemName, itemLink = C_Item.GetItemInfo(text)
            local itemID_out
            if itemLink then
                itemID_out = tonumber(itemLink:match("item:(%d+)"))
            end
            if itemName and itemID_out then
                AddShoppingEntry(itemID_out, itemName, thresholdCopper, parent)
            else
                print("|cff00ffffVoidUI AH|r: Could not resolve '" .. text .. "'. Try an item ID instead.")
            end
        end
    end
end

function AddShoppingEntry(itemID, name, thresholdCopper, parent)
    local cfg = VoidUI:GetModuleConfig("Auction")
    if not cfg.shoppingList then cfg.shoppingList = {} end

    -- Dedup
    for _, entry in ipairs(cfg.shoppingList) do
        if entry.itemID == itemID then
            print("|cff00ffffVoidUI AH|r: " .. name .. " is already on the shopping list.")
            return
        end
    end

    -- Auto threshold: use shopAlertThresholdPct of 7d mean
    if thresholdCopper == 0 then
        local mean = AH:GetMarketMean(itemID, 7)
        if mean and mean > 0 then
            local pct = (cfg.shopAlertThresholdPct or 80) / 100
            thresholdCopper = math.floor(mean * pct)
        end
    end

    cfg.shoppingList[#cfg.shoppingList + 1] = {
        itemID = itemID,
        itemName = name,
        threshold = thresholdCopper,
    }

    local threshStr = thresholdCopper > 0 and VoidUI:FormatMoney(thresholdCopper) or "auto"
    print("|cff00ffffVoidUI AH|r: Added " .. name .. " (threshold: " .. threshStr .. ")")

    if parent then UpdateShoppingList(parent) end
end

function RemoveShoppingEntry(index, parent)
    local cfg = VoidUI:GetModuleConfig("Auction")
    if not cfg.shoppingList then return end
    local entry = cfg.shoppingList[index]
    if entry then
        local name = entry.itemName or "?"
        table.remove(cfg.shoppingList, index)
        print("|cff00ffffVoidUI AH|r: Removed " .. name)
    end
    if parent then UpdateShoppingList(parent) end
end

----------------------------------------------------------------------
-- Scan every T (AH/VT) item currently in the sell list. Populates the
-- price DB, then rebuilds/resorts so profitable items float to the top.
----------------------------------------------------------------------
ScanTrashItems = function()
    if not AH or not AH.ahOpen then
        print("|cff00c7ff[VoidAH]|r AH must be open to scan.")
        return
    end
    if trashScanState then
        print("|cff00c7ff[VoidAH]|r Scan already in progress: " ..
            trashScanState.done .. "/" .. trashScanState.total)
        return
    end

    -- Collect unique itemIDs from the Auction House section
    local ids = {}
    local seen = {}
    for _, it in ipairs(sellBagItems) do
        if it and it.section == "ah" and it.itemID and not it.isDivider and not seen[it.itemID] then
            seen[it.itemID] = true
            ids[#ids + 1] = it.itemID
        end
    end

    if #ids == 0 then
        print("|cff00c7ff[VoidAH]|r No Auction House items to scan.")
        return
    end

    trashScanState = {
        pending = {},
        total   = #ids,
        done    = 0,
        started = GetTime(),
    }
    for _, id in ipairs(ids) do trashScanState.pending[id] = true end

    print("|cff00c7ff[VoidAH]|r Scanning " .. #ids .. " Auction House items...")

    for _, itemID in ipairs(ids) do
        AH:_Enqueue(function()
            local itemKey = C_AuctionHouse.MakeItemKey(itemID)
            if itemKey then
                C_AuctionHouse.SendSearchQuery(itemKey, {}, false)
            end
        end)
    end

    -- Refresh header label to show "0%"
    RefreshSellItemList()

    -- Safety timeout: 60s after which we clean up + rebuild anyway.
    -- Capture sessionID; if AH closes and reopens during the wait, this
    -- callback becomes a no-op against fresh state.
    local mySession = ahSessionID
    C_Timer.After(60, function()
        if mySession ~= ahSessionID then return end
        if trashScanState and (GetTime() - trashScanState.started) >= 59 then
            local done = trashScanState.done
            local total = trashScanState.total
            trashScanState = nil
            print("|cff00c7ff[VoidAH]|r Scan timed out (" .. done .. "/" .. total .. " returned). Rebuilding.")
            if panel and panel:IsShown() then
                BuildSellableBagItems()
                RefreshSellItemList()
            end
        end
    end)
end

-- Called from OnItemSearchResults / OnCommoditySearchResults when we get a
-- price back for an item during a trash scan.
local function OnTrashScanResult(itemID, livePrice)
    if not trashScanState or not trashScanState.pending[itemID] then return end
    trashScanState.pending[itemID] = nil
    trashScanState.done = trashScanState.done + 1
    if livePrice and livePrice > 0 then
        AH:SetPrice(itemID, livePrice)
    end
    -- Update header percentage
    if panel and panel:IsShown() then
        RefreshSellItemList()
    end
    if trashScanState.done >= trashScanState.total then
        local total = trashScanState.total
        trashScanState = nil
        print("|cff00c7ff[VoidAH]|r Scan complete (" .. total .. " items). Re-sorting.")
        if panel and panel:IsShown() then
            BuildSellableBagItems()
            RefreshSellItemList()
        end
    end
end

----------------------------------------------------------------------
-- Shopping List: auto-scan on AH open
----------------------------------------------------------------------
function StartShoppingListScan()
    local cfg = VoidUI:GetModuleConfig("Auction")
    if not cfg.shopAlertOnOpen then return end
    local list = cfg.shoppingList
    if not list or #list == 0 then return end
    if AH.scanning then return end  -- don't interfere with full/browse scans

    wipe(shopQueryPending)
    wipe(shopAlertResults)
    shopQueryActive = true

    local count = 0
    for _, entry in ipairs(list) do
        if entry.itemID then
            shopQueryPending[entry.itemID] = true
            count = count + 1
            AH:_Enqueue(function()
                local itemKey = C_AuctionHouse.MakeItemKey(entry.itemID)
                if itemKey then
                    C_AuctionHouse.SendSearchQuery(itemKey, {}, false)
                end
            end)
        end
    end

    if count > 0 then
        print("|cff00ffffVoidUI AH|r: Checking shopping list (" .. count .. " items)...")
    end

    -- Safety timeout: if results never arrive, clean up after 30s.
    -- Session token guard: no-op if AH closed and reopened.
    local mySession = ahSessionID
    C_Timer.After(30, function()
        if mySession ~= ahSessionID then return end
        if shopQueryActive then
            shopQueryActive = false
            wipe(shopQueryPending)
            print("|cff00ffffVoidUI AH|r: Shopping list scan timed out.")
        end
    end)
end

function OnShoppingSearchResult(itemID, livePrice)
    if not shopQueryPending[itemID] then return end
    shopQueryPending[itemID] = nil

    -- Update price DB
    if livePrice and livePrice > 0 then
        AH:SetPrice(itemID, livePrice)
    end

    -- Find entry in shopping list
    local cfg = VoidUI:GetModuleConfig("Auction")
    local list = cfg.shoppingList or {}
    for _, entry in ipairs(list) do
        if entry.itemID == itemID then
            local threshold = entry.threshold
            -- If threshold is 0 (auto), compute from 7d mean
            if (not threshold or threshold == 0) then
                local mean = AH:GetMarketMean(itemID, 7)
                if mean and mean > 0 then
                    threshold = math.floor(mean * ((cfg.shopAlertThresholdPct or 80) / 100))
                end
            end

            if livePrice and livePrice > 0 and threshold and threshold > 0 and livePrice <= threshold then
                shopAlertResults[#shopAlertResults + 1] = {
                    itemID = itemID,
                    name = entry.itemName,
                    price = livePrice,
                    threshold = threshold,
                }
                FireShoppingAlert(entry.itemName, livePrice, threshold)
            end
            break
        end
    end

    CheckShoppingScanComplete()
end

function FireShoppingAlert(name, price, threshold)
    local pct = threshold > 0 and math.floor((price / threshold) * 100) or 0
    local msg = name .. " is " .. VoidUI:FormatMoney(price) .. " (" .. pct .. "% of threshold)"
    print("|cff00ff00VoidUI AH DEAL|r: " .. msg)

    local cfg = VoidUI:GetModuleConfig("Auction")
    if cfg.shopAlertRaidWarning then
        RaidNotice_AddMessage(RaidWarningFrame, "|cff00ff00AH Deal: " .. name .. " — " .. VoidUI:FormatMoney(price) .. "|r", ChatTypeInfo["RAID_WARNING"])
    end
end

function CheckShoppingScanComplete()
    -- Check if any queries still pending
    for _ in pairs(shopQueryPending) do return end

    shopQueryActive = false
    local count = #shopAlertResults
    if count > 0 then
        print("|cff00ffffVoidUI AH|r: Shopping scan complete — |cff00ff00" .. count .. " deal(s) found!|r")
    else
        print("|cff00ffffVoidUI AH|r: Shopping scan complete — no deals below threshold.")
    end

    -- Refresh UI if scan tab is open
    if tabFrames and tabFrames[5] then
        UpdateShoppingList(tabFrames[5])
    end
end

----------------------------------------------------------------------
-- Shopping List: UI display
----------------------------------------------------------------------
function UpdateShoppingList(parent)
    if not parent._shopRows then return end
    local cfg = VoidUI:GetModuleConfig("Auction")
    local list = cfg.shoppingList or {}

    for i = 1, 10 do
        local row = parent._shopRows[i]
        local entry = list[i]
        if entry then
            local price = AH:GetPrice(entry.itemID)
            local priceStr = price and VoidUI:FormatMoney(price) or "no data"
            local threshStr = (entry.threshold and entry.threshold > 0) and VoidUI:FormatMoney(entry.threshold) or "auto"

            -- Color green if price is at or below threshold
            local color = "|cffffffff"
            if price and entry.threshold and entry.threshold > 0 and price <= entry.threshold then
                color = "|cff00ff00"
            end

            row._text:SetText(color .. entry.itemName .. "|r — " .. priceStr .. "  |cff888888(max: " .. threshStr .. ")|r")
            row._removeBtn:Show()

            -- Wire Buy button: switch to Browse tab and search this item
            local buyName = entry.itemName
            local buyID   = entry.itemID
            row._buyBtn:SetScript("OnClick", function()
                if not AH or not AH.ahOpen then
                    print("|cff00c7ffVoidAH|r: Open the Auction House first.")
                    return
                end
                -- Clear buy target — shopping list doesn't have a known qty
                currentBuyTarget = nil
                if SetActiveTab then SetActiveTab(1) end
                if tabFrames and tabFrames[1] and tabFrames[1]._searchBox then
                    tabFrames[1]._searchBox:SetText(buyName or "")
                end
                if BrowseSearch then
                    BrowseSearch(buyName or "")
                end
                if VoidAH_UpdateBuyTargetBanner then VoidAH_UpdateBuyTargetBanner() end
            end)
            row._buyBtn:Show()
            row:Show()
        else
            row._text:SetText("")
            row._removeBtn:Hide()
            if row._buyBtn then row._buyBtn:Hide() end
            row:Hide()
        end
    end
end

----------------------------------------------------------------------
-- Scan progress update (called via callbacks)
----------------------------------------------------------------------
local function UpdateScanProgress()
    if not tabFrames or not tabFrames[5] then return end
    local parent = tabFrames[5]

    if AH.scanning then
        local pct = math.floor(AH.scanProgress * 100)
        local label
        if AH.scanType == "browse" and AH._browseCatIndex then
            local catName = GetItemClassInfo(AH._browseCatClassID) or ""
            label = "Browse: " .. pct .. "% — " .. AH._browseCatIndex .. "/" .. AH.scanTotal .. " " .. catName .. " (" .. AH.scanProcessed .. " items)"
        else
            label = (AH.scanType or "Scan") .. ": " .. pct .. "% (" .. AH.scanProcessed .. " / " .. AH.scanTotal .. ")"
        end
        parent._progressText:SetText(label)
        local barW = math.max(1, (parent._progressBg:GetWidth() - 2) * AH.scanProgress)
        parent._progressBar:SetWidth(barW)
    else
        parent._progressText:SetText("Idle")
        parent._progressBar:SetWidth(1)
    end

    -- Cooldown display
    if AH:CanFullScan() then
        parent._fullCooldown:SetText("|cff00ff00Ready|r")
    else
        parent._fullCooldown:SetText("|cffff4444Cooldown: " .. VoidUI:FormatTime(AH:FullScanCooldownLeft()) .. "|r")
    end

    -- Stats
    local lastFull = AH:GetLastFullScan()
    local lastBrowse = AH:GetLastBrowseScan()
    local stats = "Items in DB: |cffffffff" .. AH:GetDBStats() .. "|r\n"
    stats = stats .. "Last full scan: |cffffffff" .. (lastFull > 0 and date("%H:%M:%S", lastFull) or "Never") .. "|r\n"
    stats = stats .. "Last browse scan: |cffffffff" .. (lastBrowse > 0 and date("%H:%M:%S", lastBrowse) or "Never") .. "|r\n"
    stats = stats .. "Realm: |cffffffff" .. GetRealmName() .. "|r"
    parent._statsText:SetText(stats)

    UpdateShoppingList(parent)
end

----------------------------------------------------------------------
-- AH Callbacks — wire engine events to UI
----------------------------------------------------------------------
function AH:OnScanStart(scanType)
    UpdateScanProgress()
end

function AH:OnScanProgress(progress)
    UpdateScanProgress()
    UpdateStatusBar()
end

function AH:OnScanComplete(scanType)
    UpdateScanProgress()
    UpdateStatusBar()
end

function AH:OnAHShow()
    CreatePanel()

    -- Hide Blizzard AH so only VoidUI is visible (no timer — immediate to prevent flicker)
    if AuctionHouseFrame then
        AuctionHouseFrame:SetAlpha(0)
        AuctionHouseFrame:EnableMouse(false)
        AuctionHouseFrame:SetFrameStrata("BACKGROUND")
        for _, child in pairs({AuctionHouseFrame:GetChildren()}) do
            pcall(function() child:EnableMouse(false) end)
            pcall(function() child:EnableKeyboard(false) end)
        end
        if not AuctionHouseFrame._voidHooked then
            hooksecurefunc(AuctionHouseFrame, "Show", function(self)
                self:SetAlpha(0)
                self:EnableMouse(false)
                self:SetFrameStrata("BACKGROUND")
                for _, child in pairs({self:GetChildren()}) do
                    pcall(function() child:EnableMouse(false) end)
                    pcall(function() child:EnableKeyboard(false) end)
                end
            end)
            AuctionHouseFrame._voidHooked = true
        end
    end

    BuildCategoryData()
    BuildTreeFlatList()
    browseView = BROWSE_VIEW_TREE
    selectedClassID = nil
    selectedSubClassID = nil
    browseOffset = 0
    ilvlSortOrder = nil
    buyItemKey = nil
    buyItemName = nil
    buyListings = {}
    buyIsCommodity = false
    pendingCommodityPurchase = nil
    wipe(pendingItems)
    BuildSellableBagItems()
    panel:Show()
    SetActiveTab(1)
    UpdateStatusBar()
    UpdateScanProgress()

    -- Auto-scan shopping list after a short delay
    C_Timer.After(1.5, function()
        if AH.ahOpen then
            StartShoppingListScan()
        end
    end)
end

function AH:OnAHClose()
    -- Bump session token so any pending long-running C_Timer callbacks
    -- (60s trash scan timeout, 30s shopping timeout) become no-ops when
    -- they fire post-close, even if the user reopens the AH quickly.
    ahSessionID = ahSessionID + 1
    shopQueryActive = false
    wipe(shopQueryPending)
    trashScanState = nil
    if panel and panel:IsShown() then panel:Hide() end
    UpdateStatusBar()
end

function AH:OnItemSearchResults(itemKey)
    -- Trash scan routing: always check first so the price DB updates even
    -- if this result was also interesting to another flow.
    if trashScanState and itemKey and itemKey.itemID and trashScanState.pending[itemKey.itemID] then
        local searchItemKey = C_AuctionHouse.MakeItemKey(itemKey.itemID)
        local livePrice = nil
        if searchItemKey then
            local numResults = C_AuctionHouse.GetNumItemSearchResults(searchItemKey)
            if numResults and numResults > 0 then
                local result = C_AuctionHouse.GetItemSearchResultInfo(searchItemKey, 1)
                if result then
                    local buyout = VoidUI.AH.SafeNum(result.buyoutAmount)
                    local qty = VoidUI.AH.SafeNum(result.quantity) or 1
                    if buyout then
                        livePrice = (qty > 1) and math.floor(buyout / qty) or buyout
                    end
                end
            end
        end
        OnTrashScanResult(itemKey.itemID, livePrice)
        -- Fall through so other flows (buy listings, sell pending) can still use it
    end

    -- Shopping list routing: if this item is from a shopping scan, handle it there
    if shopQueryActive and itemKey and itemKey.itemID and shopQueryPending[itemKey.itemID] then
        local searchItemKey = C_AuctionHouse.MakeItemKey(itemKey.itemID)
        local livePrice = nil
        if searchItemKey then
            local numResults = C_AuctionHouse.GetNumItemSearchResults(searchItemKey)
            if numResults and numResults > 0 then
                local result = C_AuctionHouse.GetItemSearchResultInfo(searchItemKey, 1)
                if result then
                    local buyout = VoidUI.AH.SafeNum(result.buyoutAmount)
                    local qty = VoidUI.AH.SafeNum(result.quantity) or 1
                    if buyout then
                        livePrice = (qty > 1) and math.floor(buyout / qty) or buyout
                    end
                end
            end
        end
        OnShoppingSearchResult(itemKey.itemID, livePrice)
        return
    end

    -- Buy listing routing: populate listings view
    if browseView == BROWSE_VIEW_LISTINGS and buyItemKey and itemKey
    and itemKey.itemID == buyItemKey.itemID then
        buyListings = {}
        buyIsCommodity = false
        local numBuyResults = C_AuctionHouse.GetNumItemSearchResults(buyItemKey)
        for idx = 1, (numBuyResults or 0) do
            local r = C_AuctionHouse.GetItemSearchResultInfo(buyItemKey, idx)
            if r then
                buyListings[#buyListings + 1] = {
                    auctionID = r.auctionID,
                    buyoutAmount = VoidUI.AH.SafeNum(r.buyoutAmount),
                    bidAmount = VoidUI.AH.SafeNum(r.bidAmount),
                    quantity = VoidUI.AH.SafeNum(r.quantity) or 1,
                    itemKey = r.itemKey,
                    owners = r.owners or {},
                    timeLeft = r.timeLeft,
                    containsAccountItem = r.containsAccountItem,
                    containsOwnerItem = r.containsOwnerItem,
                }
            end
        end
        browseOffset = 0
        RefreshBrowseRows()
        -- Don't return — also let sell tab update if applicable
    end

    -- Update sell tab with results
    if not tabFrames or not tabFrames[2] then return end
    if not sellPending.itemID then return end

    -- Get search results for the pending item
    local searchItemKey = C_AuctionHouse.MakeItemKey(sellPending.itemID)
    if not searchItemKey then return end

    local numResults = C_AuctionHouse.GetNumItemSearchResults(searchItemKey)
    if numResults and numResults > 0 then
        local result = C_AuctionHouse.GetItemSearchResultInfo(searchItemKey, 1)
        local buyout = result and VoidUI.AH.SafeNum(result.buyoutAmount)
        if buyout then
            local qty = VoidUI.AH.SafeNum(result.quantity) or 1
            local perUnit = (qty > 1) and math.floor(buyout / qty) or buyout
            AH:SetPrice(sellPending.itemID, perUnit)

            -- Update sell price with undercut
            local cfg = VoidUI:GetModuleConfig("Auction")
            local undercut = cfg.undercutCopper or 100
            local price = math.max(1, perUnit - undercut)
            local parent = tabFrames[2]
            parent._goldBox:SetText(tostring(math.floor(price / 10000)))
            parent._silverBox:SetText(tostring(math.floor((price % 10000) / 100)))
            parent._copperBox:SetText(tostring(price % 100))
            parent._sellInfo:SetText(parent._sellInfo:GetText() .. " | |cff00ff00Current: " .. VoidUI:FormatMoney(perUnit) .. "|r")
        end
    end
end

function AH:OnCommoditySearchResults(itemID)
    -- Trash scan routing: always check first to populate the price DB.
    if trashScanState and itemID and trashScanState.pending[itemID] then
        local livePrice = nil
        local numResults = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
        if numResults and numResults > 0 then
            local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
            if result then
                livePrice = VoidUI.AH.SafeNum(result.unitPrice)
            end
        end
        OnTrashScanResult(itemID, livePrice)
        -- Fall through so other flows can still use the result
    end

    -- Shopping list routing: if this commodity is from a shopping scan, handle it there
    if shopQueryActive and itemID and shopQueryPending[itemID] then
        local livePrice = nil
        local numResults = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
        if numResults and numResults > 0 then
            local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
            if result then
                livePrice = VoidUI.AH.SafeNum(result.unitPrice)
            end
        end
        OnShoppingSearchResult(itemID, livePrice)
        return
    end

    -- Buy listing routing: populate commodity listings view
    if browseView == BROWSE_VIEW_LISTINGS and buyItemKey and itemID
    and itemID == buyItemKey.itemID then
        buyListings = {}
        buyIsCommodity = true
        local numBuyResults = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
        for idx = 1, (numBuyResults or 0) do
            local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, idx)
            if r then
                buyListings[#buyListings + 1] = {
                    unitPrice = VoidUI.AH.SafeNum(r.unitPrice),
                    quantity = VoidUI.AH.SafeNum(r.quantity) or 1,
                    owners = r.owners or {},
                    numOwnerItems = r.numOwnerItems or 0,
                    containsAccountItem = r.containsAccountItem,
                    containsOwnerItem = r.containsOwnerItem,
                }
            end
        end
        browseOffset = 0
        RefreshBrowseRows()
    end

    if not tabFrames or not tabFrames[2] then return end
    if not sellPending.itemID or sellPending.itemID ~= itemID then return end

    local numResults = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
    if numResults and numResults > 0 then
        local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
        local unitPrice = result and VoidUI.AH.SafeNum(result.unitPrice)
        if unitPrice then
            AH:SetPrice(itemID, unitPrice)

            local cfg = VoidUI:GetModuleConfig("Auction")
            local undercut = cfg.undercutCopper or 100
            local price = math.max(1, unitPrice - undercut)
            local parent = tabFrames[2]
            parent._goldBox:SetText(tostring(math.floor(price / 10000)))
            parent._silverBox:SetText(tostring(math.floor((price % 10000) / 100)))
            parent._copperBox:SetText(tostring(price % 100))
            parent._sellInfo:SetText(parent._sellInfo:GetText() .. " | |cff00ff00Current: " .. VoidUI:FormatMoney(unitPrice) .. "|r")
        end
    end
end

function AH:OnOwnedAuctionsUpdated()
    UpdateMyAuctions()
end

function AH:OnAuctionCreated()
    print("|cff00ff00VoidUI AH|r: Auction posted successfully!")

    -- Update Recent Posts (server-confirmed)
    if tabFrames and tabFrames[2] and sellPending._lastPostName then
        local parent = tabFrames[2]
        local entry = sellPending._lastPostQty .. "x " .. sellPending._lastPostName
            .. " @ " .. VoidUI:FormatMoney(sellPending._lastPostPrice) .. " each"
        for i = 3, 2, -1 do
            parent._recentPosts[i]:SetText(parent._recentPosts[i - 1]:GetText())
        end
        parent._recentPosts[1]:SetText("|cff00ff00" .. entry .. "|r")
        sellPending._lastPostName = nil
    end

    -- Refresh owned auctions + bag grid, then auto-select the next item
    -- in whichever section the user was just selling from.
    local advanceSection = sellPending._section or "ah"
    sellPending._section = nil

    C_Timer.After(0.5, function()
        AH:QueryOwnedAuctions()
        BuildSellableBagItems()
        RefreshSellItemList()

        -- Find first non-divider item in the target section
        local nextItem
        for _, it in ipairs(sellBagItems) do
            if it and not it.isDivider and it.section == advanceSection then
                nextItem = it
                break
            end
        end
        -- Fallback: any AH item
        if not nextItem then
            for _, it in ipairs(sellBagItems) do
                if it and not it.isDivider and it.section == "ah" then
                    nextItem = it
                    break
                end
            end
        end

        if nextItem and nextItem.bag and nextItem.slot then
            local loc = ItemLocation:CreateFromBagAndSlot(nextItem.bag, nextItem.slot)
            if loc and C_Item.DoesItemExist(loc) and tabFrames and tabFrames[2] then
                SellTab_SetItem(tabFrames[2], loc)
            end
        end
    end)
end

----------------------------------------------------------------------
-- Commodity Purchase Callbacks
----------------------------------------------------------------------
function AH:OnCommodityPriceUpdated(unitPrice, totalPrice)
    if not pendingCommodityPurchase then return end
    -- Auto-confirm: user already confirmed via inline bar, just finalize
    C_AuctionHouse.ConfirmCommoditiesPurchase(
        pendingCommodityPurchase.itemID, pendingCommodityPurchase.quantity)
    print("|cff00ff00[VoidUI AH]|r Confirming purchase... (" ..
        VoidUI:FormatMoney(totalPrice or 0) .. ")")
end

function AH:OnCommodityPurchaseSucceeded()
    pendingCommodityPurchase = nil
    HideConfirmBar()
    print("|cff00ff00[VoidUI AH]|r Purchase successful!")
    -- Refresh listings
    if buyItemKey and browseView == BROWSE_VIEW_LISTINGS then
        C_Timer.After(0.5, function()
            AH:_Enqueue(function()
                C_AuctionHouse.SendSearchQuery(buyItemKey,
                    {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }}, false)
            end)
        end)
    end
end

function AH:OnCommodityPurchaseFailed()
    pendingCommodityPurchase = nil
    HideConfirmBar()
    print("|cffff4444[VoidUI AH]|r Purchase failed! Price may have changed.")
end

----------------------------------------------------------------------
-- Bag item click hook for Sell tab
----------------------------------------------------------------------
local function HookBagClicks()
    -- Hook ContainerFrameItemButton_OnModifiedClick if it exists (removed in TWW)
    if ContainerFrameItemButton_OnModifiedClick then
        pcall(function()
            hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function(self, button)
                if not AH.ahOpen or not panel or not panel:IsShown() or activeTab ~= 2 then return end
                if button == "LeftButton" then
                    local bag = self:GetParent():GetID()
                    local slot = self:GetID()
                    local itemLocation = ItemLocation:CreateFromBagAndSlot(bag, slot)
                    if itemLocation and C_Item.DoesItemExist(itemLocation) then
                        SellTab_SetItem(tabFrames[2], itemLocation)
                    end
                end
            end)
        end)
    end

    -- Hook HandleModifiedItemClick for both Blizzard and VoidUI bag clicks
    pcall(function()
        hooksecurefunc("HandleModifiedItemClick", function(itemLink)
            if not AH.ahOpen or not panel or not panel:IsShown() or activeTab ~= 2 then return end
            if not itemLink then return end
            local itemID = C_Item.GetItemInfoInstant(itemLink)
            if not itemID then return end
            for bag = 0, 4 do
                for slot = 1, C_Container.GetContainerNumSlots(bag) do
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    if info and info.itemID == itemID then
                        local itemLocation = ItemLocation:CreateFromBagAndSlot(bag, slot)
                        if itemLocation and C_Item.DoesItemExist(itemLocation) then
                            SellTab_SetItem(tabFrames[2], itemLocation)
                            return
                        end
                    end
                end
            end
        end)
    end)
end

----------------------------------------------------------------------
-- Status bar update ticker
----------------------------------------------------------------------
local function StartStatusTicker()
    C_Timer.NewTicker(1, function()
        if panel and panel:IsShown() then
            UpdateStatusBar()
            if AH.scanning then
                UpdateScanProgress()
            end
        end
    end)
end

----------------------------------------------------------------------
-- Browse results event hook (for non-scan browsing)
----------------------------------------------------------------------
local browseEventFrame = CreateFrame("Frame")
browseEventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
browseEventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
browseEventFrame:RegisterEvent("BAG_UPDATE")
browseEventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        if not AH.scanning and panel and panel:IsShown() and activeTab == 1 and browseView == BROWSE_VIEW_RESULTS then
            UpdateBrowseResults()
        end
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        local itemID, success = ...
        if success and pendingItems[itemID] then
            pendingItems[itemID] = nil
            -- Cache base ilvl (fallback for commodities with no itemKey.itemLevel)
            local _, _, _, itemLevel = C_Item.GetItemInfo(itemID)
            if itemLevel then
                ilvlCache[itemID] = itemLevel
            end
            -- Fill in ilvl on results that don't have one yet (itemKey.itemLevel was 0)
            for _, r in ipairs(browseResults) do
                if r.itemID == itemID and not r.ilvl and ilvlCache[itemID] then
                    r.ilvl = ilvlCache[itemID]
                end
            end
            -- Coalesce refreshes
            if not pendingRefresh then
                pendingRefresh = true
                C_Timer.After(0.1, function()
                    pendingRefresh = false
                    if browseView == BROWSE_VIEW_RESULTS and panel and panel:IsShown() then
                        if ilvlSortOrder then
                            SortBrowseResults()
                        end
                        RefreshBrowseRows()
                    end
                end)
            end
        end
    elseif event == "BAG_UPDATE" then
        if panel and panel:IsShown() and activeTab == 2 then
            BuildSellableBagItems()
            RefreshSellItemList()
        end
    end
end)

----------------------------------------------------------------------
-- Professions Tab — leveling shopping lists from wow-professions.com
----------------------------------------------------------------------
function BuildProfessionsTab(parent)
    local plans = VoidUI.ProfessionPlans or {}

    -- Map profession name → { rank = N, maxRank = M } so we can show
    -- live skill levels in the plan title and color-code each step.
    local function GetActiveProfessionInfo()
        local info = {}
        if not GetProfessions then return info end
        local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
        for _, idx in ipairs({ prof1, prof2, archaeology, fishing, cooking }) do
            if idx then
                local name, _, rank, maxRank = GetProfessionInfo(idx)
                if name then info[name] = { rank = rank or 0, maxRank = maxRank or 100 } end
            end
        end
        return info
    end

    -- Recipe-known check. Three paths in order of reliability:
    --   1. Explicit spellID via IsPlayerSpell (works always once spell is in book)
    --   2. Cached learned-recipe name from C_TradeSkillUI snapshot (most reliable
    --      for profession recipes since they don't all behave like normal spells)
    --   3. Name lookup via C_Spell.GetSpellInfo (only works if spell is cached)
    local function IsRecipeKnown(recipeName, spellID, profSkill)
        if spellID and IsPlayerSpell(spellID) then return true end
        if recipeName and profSkill and VoidUIAuctionDB and VoidUIAuctionDB.profCache then
            local cache = VoidUIAuctionDB.profCache[profSkill]
            if cache and cache.recipes then
                for _, r in pairs(cache.recipes) do
                    if r.name == recipeName then return true end
                end
            end
        end
        if recipeName and C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(recipeName)
            if info and info.spellID and IsPlayerSpell(info.spellID) then
                return true
            end
        end
        return false
    end

    local activeProfs = GetActiveProfessionInfo()
    local function activeSet()
        local s = {}
        for k in pairs(activeProfs) do s[k] = true end
        return s
    end
    local activeProfSet = activeSet()

    local title = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(title, 13, "OUTLINE")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("|cff00c7ffProfession Leveling Plans|r — ★ = your active profession")

    local subtitle = parent:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(subtitle, 9, "")
    subtitle:SetPoint("TOPLEFT", 16, -32)
    subtitle:SetTextColor(0.55, 0.55, 0.6)
    subtitle:SetText("Data from wow-professions.com (Midnight 12.0.5). Click a row to search the AH or add to your Shopping List.")

    local leftPane = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    leftPane:SetPoint("TOPLEFT", 16, -56)
    leftPane:SetPoint("BOTTOMLEFT", 16, 16)
    leftPane:SetWidth(220)
    VoidUI:CreateBackdrop(leftPane, 0.04, 0.04, 0.05, 0.95)

    local leftScroll = CreateFrame("ScrollFrame", nil, leftPane, "UIPanelScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 4, -4)
    leftScroll:SetPoint("BOTTOMRIGHT", -22, 4)
    local leftChild = CreateFrame("Frame", nil, leftScroll)
    leftChild:SetSize(190, 1)
    leftScroll:SetScrollChild(leftChild)

    local rightPane = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    rightPane:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 8, 0)
    rightPane:SetPoint("BOTTOMRIGHT", -16, 16)
    VoidUI:CreateBackdrop(rightPane, 0.04, 0.04, 0.05, 0.95)

    local planTitle = rightPane:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(planTitle, 12, "OUTLINE")
    planTitle:SetPoint("TOPLEFT", 12, -10)
    planTitle:SetText("|cffaaaaaaSelect a profession ←|r")

    -- planNotes lives inside its own container so we can size it dynamically.
    local notesHolder = CreateFrame("Frame", nil, rightPane)
    notesHolder:SetPoint("TOPLEFT", 12, -30)
    notesHolder:SetPoint("RIGHT", rightPane, "RIGHT", -12, 0)
    notesHolder:SetHeight(20)  -- adjusted at render time
    parent._notesHolder = notesHolder

    local planNotes = notesHolder:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(planNotes, 10, "")
    planNotes:SetAllPoints(notesHolder)
    planNotes:SetJustifyH("LEFT")
    planNotes:SetJustifyV("TOP")
    planNotes:SetWordWrap(true)
    planNotes:SetSpacing(2)
    planNotes:SetTextColor(0.75, 0.75, 0.78)

    -- Header for the materials list
    local matsHeader = rightPane:CreateFontString(nil, "OVERLAY")
    VoidUI:SetFont(matsHeader, 11, "OUTLINE")
    matsHeader:SetTextColor(1, 0.82, 0)
    parent._matsHeader = matsHeader

    local matScroll = CreateFrame("ScrollFrame", nil, rightPane, "UIPanelScrollFrameTemplate")
    matScroll:SetPoint("BOTTOMRIGHT", -28, 44)
    parent._matScroll = matScroll
    local matChild = CreateFrame("Frame", nil, matScroll)
    matChild:SetSize(400, 1)
    matScroll:SetScrollChild(matChild)
    parent._matRows = {}

    local addAllBtn = CreateButton(rightPane, 220, 26, "|cff00ff00+ Add All to Shopping List|r", nil)
    addAllBtn:SetPoint("BOTTOMLEFT", 12, 10)
    addAllBtn:Disable()
    addAllBtn:SetAlpha(0.5)

    local searchAllBtn = CreateButton(rightPane, 200, 26, "|cffffd200Search AH for First Item|r", nil)
    searchAllBtn:SetPoint("LEFT", addAllBtn, "RIGHT", 8, 0)
    searchAllBtn:Disable()
    searchAllBtn:SetAlpha(0.5)

    local function RenderMatRows(plan)
        for _, row in ipairs(parent._matRows) do row:Hide() end
        if not plan then
            planTitle:SetText("|cffaaaaaaSelect a profession ←|r")
            planNotes:SetText("")
            addAllBtn:Disable(); addAllBtn:SetAlpha(0.5)
            searchAllBtn:Disable(); searchAllBtn:SetAlpha(0.5)
            return
        end

        local profInfo = activeProfs[plan.skill]
        local rank = profInfo and profInfo.rank or 0
        local maxRank = profInfo and profInfo.maxRank or 100

        -- Use cached skill rank if it's higher (more accurate post-trade-skill-open)
        local cache = VoidUIAuctionDB and VoidUIAuctionDB.profCache and VoidUIAuctionDB.profCache[plan.skill]
        if cache and cache.skillRank and cache.skillRank > rank then
            rank = cache.skillRank
            maxRank = cache.skillMaxRank or maxRank
        end

        local skillSuffix = profInfo and string.format("  |cffffffffYour skill: %d / %d|r", rank, maxRank) or "  |cff888888(not learned)|r"
        local star = profInfo and "|cffffd200★|r " or ""
        local cacheNote = ""
        if cache then
            local mins = math.max(1, math.floor((time() - (cache.lastSync or 0)) / 60))
            cacheNote = string.format("  |cff00ff00[%d recipes synced %dm ago]|r", cache.learnedCount or 0, mins)
        else
            cacheNote = "  |cffff8800[open profession window to sync]|r"
        end
        planTitle:SetText(star .. "|cff00c7ff" .. plan.name .. "|r" .. skillSuffix .. cacheNote)

        -- Build notes block: trainer + general notes + per-step recipe path
        -- with live status for each step (done / current / future) and learned-or-not.
        local notesTxt = ""
        if plan.trainer then
            notesTxt = "|cffffd200Trainer:|r " .. plan.trainer .. "\n"
        end
        if plan.notes then
            notesTxt = notesTxt .. plan.notes .. "\n"
        end
        if plan.steps then
            notesTxt = notesTxt .. "\n|cffffd200Recipe Path:|r"
            for _, step in ipairs(plan.steps) do
                local stepSrc = step.source or plan.trainer or "trainer"
                local rangeStr = step.startSkill .. " → " .. step.endSkill

                -- Step status vs player skill
                local statusIcon, statusColor
                if rank >= step.endSkill then
                    statusIcon = "|cff00ff00✓|r"
                    statusColor = "|cff666666"  -- dim past steps
                elseif rank >= step.startSkill then
                    statusIcon = "|cffffd200▶|r"
                    statusColor = "|cffffffff"  -- bright current step
                else
                    statusIcon = "|cff888888○|r"
                    statusColor = "|cffaaaaaa"  -- normal future step
                end

                -- Recipe known/unknown
                local known = IsRecipeKnown(step.recipe, step.spellID, plan.skill)
                local recipeStatus = known
                    and "|cff00ff00[learned]|r"
                    or  ("|cffff5050[NOT LEARNED — go to: " .. stepSrc .. "]|r")

                notesTxt = notesTxt .. string.format(
                    "\n  %s |cff00c7ff%s|r  %sCraft %dx %s|r %s\n      %sper craft: %s|r",
                    statusIcon, rangeStr, statusColor, step.count, step.recipe, recipeStatus,
                    statusColor, step.per)
            end
        end
        planNotes:SetText(notesTxt)

        -- Resize notes holder to fit the rendered text, then anchor mats below it
        local notesH = planNotes:GetStringHeight() + 10
        if notesH < 30 then notesH = 30 end
        parent._notesHolder:SetHeight(notesH)

        parent._matsHeader:ClearAllPoints()
        parent._matsHeader:SetPoint("TOPLEFT", parent._notesHolder, "BOTTOMLEFT", 0, -8)
        parent._matsHeader:SetText("Total Materials Needed (shop the AH):")

        parent._matScroll:ClearAllPoints()
        parent._matScroll:SetPoint("TOPLEFT", parent._matsHeader, "BOTTOMLEFT", 0, -4)
        parent._matScroll:SetPoint("RIGHT", rightPane, "RIGHT", -28, 0)
        parent._matScroll:SetPoint("BOTTOM", rightPane, "BOTTOM", 0, 44)

        local rowH = 24
        for i, mat in ipairs(plan.mats) do
            local row = parent._matRows[i]
            if not row then
                row = CreateFrame("Frame", nil, matChild, "BackdropTemplate")
                row:SetHeight(rowH)
                local bg = row:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                row._bg = bg

                local qtyLbl = row:CreateFontString(nil, "OVERLAY")
                VoidUI:SetFont(qtyLbl, 11, "OUTLINE")
                qtyLbl:SetPoint("LEFT", 8, 0)
                qtyLbl:SetWidth(50)
                qtyLbl:SetJustifyH("RIGHT")
                qtyLbl:SetTextColor(1, 0.82, 0)
                row._qtyLbl = qtyLbl

                local nameLbl = row:CreateFontString(nil, "OVERLAY")
                VoidUI:SetFont(nameLbl, 10, "")
                nameLbl:SetPoint("LEFT", qtyLbl, "RIGHT", 8, 0)
                nameLbl:SetPoint("RIGHT", -160, 0)
                nameLbl:SetJustifyH("LEFT")
                nameLbl:SetWordWrap(false)
                nameLbl:SetTextColor(0.92, 0.92, 0.95)
                row._nameLbl = nameLbl

                local searchBtn = CreateButton(row, 70, 18, "|cff00ff00Buy|r", nil)
                searchBtn:SetPoint("RIGHT", -82, 0)
                row._searchBtn = searchBtn

                local addBtn = CreateButton(row, 70, 18, "+ List", nil)
                addBtn:SetPoint("RIGHT", -8, 0)
                row._addBtn = addBtn

                parent._matRows[i] = row
            end

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(i - 1) * (rowH + 2))
            row:SetPoint("RIGHT", matChild, "RIGHT", 0, 0)
            local c = (i % 2 == 0) and 0.07 or 0.04
            row._bg:SetColorTexture(c, c, c, 0.7)
            row._qtyLbl:SetText(mat[1] .. "x")
            row._nameLbl:SetText(mat[2])

            local itemName = mat[2]
            local itemID   = mat[3]  -- optional — preferred for shopping list resolution
            local qtyNeeded = mat[1]
            row._searchBtn:SetScript("OnClick", function()
                if not AH or not AH.ahOpen then
                    print("|cff00c7ffVoidAH|r: Open the Auction House first.")
                    return
                end
                -- Set buy target so Browse tab shows a quota banner
                currentBuyTarget = { itemName = itemName, itemID = itemID, qtyNeeded = qtyNeeded }
                if SetActiveTab then SetActiveTab(1) end
                if tabFrames and tabFrames[1] and tabFrames[1]._searchBox then
                    tabFrames[1]._searchBox:SetText(itemName)
                end
                if BrowseSearch then BrowseSearch(itemName) end
                if VoidAH_UpdateBuyTargetBanner then VoidAH_UpdateBuyTargetBanner() end
            end)

            row._addBtn:SetScript("OnClick", function()
                if ResolveAndAddItem then
                    -- Pass itemID as text if available (more reliable than name lookup
                    -- pre-cache); ResolveAndAddItem handles numeric strings as itemIDs.
                    local resolveKey = itemID and tostring(itemID) or itemName
                    ResolveAndAddItem(resolveKey, 0, tabFrames and tabFrames[5])
                    print("|cff00c7ffVoidAH|r: Added " .. itemName .. " to Shopping List.")
                end
            end)

            row:Show()
        end
        for i = #plan.mats + 1, #parent._matRows do
            parent._matRows[i]:Hide()
        end
        matChild:SetHeight(math.max(1, #plan.mats * (rowH + 2)))

        addAllBtn:Enable(); addAllBtn:SetAlpha(1)
        searchAllBtn:Enable(); searchAllBtn:SetAlpha(1)
        addAllBtn:SetScript("OnClick", function()
            if not ResolveAndAddItem then return end
            local count = 0
            for _, mat in ipairs(plan.mats) do
                local resolveKey = mat[3] and tostring(mat[3]) or mat[2]
                ResolveAndAddItem(resolveKey, 0, tabFrames and tabFrames[5])
                count = count + 1
            end
            print(string.format("|cff00c7ffVoidAH|r: Added %d items from %s to your Shopping List.", count, plan.name))
        end)
        searchAllBtn:SetScript("OnClick", function()
            if not AH or not AH.ahOpen then
                print("|cff00c7ffVoidAH|r: Open the Auction House first.")
                return
            end
            local first = plan.mats[1]
            if not first then return end
            if SetActiveTab then SetActiveTab(1) end
            if tabFrames and tabFrames[1] and tabFrames[1]._searchBox then
                tabFrames[1]._searchBox:SetText(first[2])
            end
            if BrowseSearch then BrowseSearch(first[2]) end
        end)
    end

    local rowH = 26
    local profRows = {}
    for i, plan in ipairs(plans) do
        local row = CreateFrame("Button", nil, leftChild, "BackdropTemplate")
        row:SetHeight(rowH)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * (rowH + 2))
        row:SetPoint("RIGHT", leftChild, "RIGHT", 0, 0)
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        local isActive = activeProfs[plan.skill]
        bg:SetColorTexture(isActive and 0.10 or 0.05, isActive and 0.10 or 0.05, isActive and 0.13 or 0.05, 1)

        local lbl = row:CreateFontString(nil, "OVERLAY")
        VoidUI:SetFont(lbl, 11, isActive and "OUTLINE" or "")
        lbl:SetPoint("LEFT", 8, 0)
        lbl:SetPoint("RIGHT", -8, 0)
        lbl:SetJustifyH("LEFT")
        lbl:SetWordWrap(false)
        local star = isActive and "|cffffd200★|r " or "|cff555555○|r "
        lbl:SetText(star .. plan.name)
        lbl:SetTextColor(isActive and 1 or 0.7, isActive and 1 or 0.7, isActive and 1 or 0.75)

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(0, 0.78, 1, 0.15)

        row:SetScript("OnClick", function()
            for _, other in ipairs(profRows) do
                local oa = activeProfs[plans[other._idx].skill]
                other._bg:SetColorTexture(oa and 0.10 or 0.05, oa and 0.10 or 0.05, oa and 0.13 or 0.05, 1)
            end
            bg:SetColorTexture(0, 0.4, 0.6, 0.45)
            RenderMatRows(plan)
        end)

        row._bg = bg
        row._idx = i
        profRows[i] = row
    end
    leftChild:SetHeight(math.max(1, #plans * (rowH + 2)))

    local autoSelect = 1
    for i, plan in ipairs(plans) do
        if activeProfs[plan.skill] then autoSelect = i; break end
    end
    if profRows[autoSelect] then profRows[autoSelect]:Click() end

    -- Hook for live re-render when CaptureTradeSkillSnapshot fires
    VoidUI._onProfCacheUpdate = function(profName)
        -- Refresh active profession data (in case skill rank changed)
        activeProfs = GetActiveProfessionInfo()
        for _, row in ipairs(profRows) do
            local p = plans[row._idx]
            if p and p.skill == profName then row:Click() return end
        end
    end
end

----------------------------------------------------------------------
-- Init on load
----------------------------------------------------------------------
C_Timer.After(0, function()
    HookBagClicks()
    StartStatusTicker()
end)
