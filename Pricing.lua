----------------------------------------------------------------------
-- VoidAH Pricing -- what VoidAH knows a material costs, for VoidProf.
--
-- VoidProf works out profession plans (what to craft, what to make, what's
-- missing); VoidAH supplies the prices and shows what to buy (the user's
-- split, 2026-11-03). VoidAH_Price(itemID) answers with:
--   1. your Auction House scan price, else
--   2. the price a merchant you visited charges (gold only), else nil.
-- Merchant prices are recorded for the materials VoidProf's recipes use.
----------------------------------------------------------------------

VoidUI = VoidUI or {}

local function VendorPrices()
    VoidUIAuctionDB = VoidUIAuctionDB or {}
    VoidUIAuctionDB.vendorPrices = VoidUIAuctionDB.vendorPrices or {}
    return VoidUIAuctionDB.vendorPrices
end

local merchantWatch = CreateFrame("Frame")
merchantWatch:RegisterEvent("MERCHANT_SHOW")
merchantWatch:RegisterEvent("MERCHANT_UPDATE")
merchantWatch:SetScript("OnEvent", function()
    local items = VoidProf and VoidProf.ProfessionData and VoidProf.ProfessionData.items
    if not (items and C_MerchantFrame and C_MerchantFrame.GetItemInfo and GetMerchantNumItems) then return end
    local prices = VendorPrices()
    for i = 1, GetMerchantNumItems() or 0 do
        local link = GetMerchantItemLink(i)
        local id = link and tonumber(link:match("item:(%d+)"))
        if id and items[id] then
            local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
            -- gold only: a price in currency or items isn't comparable
            if ok and info and info.price and info.price > 0 and not info.hasExtendedCost then
                prices[id] = math.floor(info.price / math.max(info.stackCount or 1, 1))
            end
        end
    end
end)

-- What a merchant you visited charges for one (copper), or nil: VoidProf
-- counts those as on hand for "craft now" (Songwater, Vellum).
function VoidAH_VendorPrice(itemID)
    local v = VendorPrices()[itemID]
    return (v and v > 0) and v or nil
end

-- Copper for one of `itemID` and where it's from ("ah" / "vendor"), or nil.
function VoidAH_Price(itemID)
    local AH = VoidUI.AH
    local p = AH and AH.GetPrice and AH:GetPrice(itemID)
    if p and p > 0 then return p, "ah" end
    local v = VendorPrices()[itemID]
    if v and v > 0 then return v, "vendor" end
    return nil
end
