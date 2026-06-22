-- VoidSpy hook: enable with /vspy enable VoidAH  (no-op if VoidSpy missing/disabled)
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidAH", fmt, ...) end end

----------------------------------------------------------------------
-- VoidAH Core — shim providing VoidUI-compatible API for standalone use
----------------------------------------------------------------------

-- If main VoidUI addon already loaded, we don't need to shim anything
if not VoidUI or not VoidUI.NewModule then
    VoidUI = VoidUI or {}

    VoidUI.palette = VoidUI.palette or {
        accent  = { 0.00, 0.78, 1.00 },
        text    = { 0.92, 0.92, 0.95 },
        textDim = { 0.55, 0.55, 0.62 },
        textDark = { 0.40, 0.40, 0.45 },
        green   = { 0.10, 0.80, 0.35 },
    }
    VoidUI.accentR = 0.00
    VoidUI.accentG = 0.78
    VoidUI.accentB = 1.00

    VoidUI.media = VoidUI.media or {
        flat = "Interface\\Buttons\\WHITE8X8",
    }

    local modules = {}
    VoidUI._modules = modules

    local configs = {
        Auction = {
            enabled         = true,
            autoScanOnOpen  = false,
            undercutCopper  = 100,
            showBagValues   = true,
        },
    }

    function VoidUI:NewModule(name)
        local mod = { name = name }
        modules[name] = mod
        -- Default no-op methods; modules override these
        function mod:Init() end
        function mod:Enable() end

        -- Auto-fire lifecycle once WoW finishes loading the addon scripts.
        -- We defer via PLAYER_LOGIN so Auction.lua has a chance to replace Init/Enable.
        -- (If PLAYER_LOGIN already fired for a /reload, a 0-tick timer is a safe fallback.)
        C_Timer.After(0, function()
            local ok, err = pcall(function()
                if mod.Init then mod:Init() end
                if mod.Enable then mod:Enable() end
            end)
            if not ok then
                print("|cffff4444[VoidAH]|r init error in " .. name .. ": " .. tostring(err))
            end
        end)

        return mod
    end

    function VoidUI:GetModuleConfig(name)
        VoidUIAuctionDB = VoidUIAuctionDB or {}
        VoidUIAuctionDB.config = VoidUIAuctionDB.config or {}
        VoidUIAuctionDB.config[name] = VoidUIAuctionDB.config[name] or {}
        -- Merge defaults into saved config
        local defaults = configs[name] or {}
        for k, v in pairs(defaults) do
            if VoidUIAuctionDB.config[name][k] == nil then
                VoidUIAuctionDB.config[name][k] = v
            end
        end
        return VoidUIAuctionDB.config[name]
    end

    function VoidUI:SetFont(fs, size, flags)
        if not fs or not fs.SetFont then return end
        fs:SetFont("Fonts\\FRIZQT__.TTF", size or 11, flags or "")
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 0.8)
    end

    function VoidUI:FormatMoney(copper)
        if not copper or copper == 0 then return "0" end
        copper = math.floor(copper)
        local gold   = math.floor(copper / 10000)
        local silver = math.floor((copper % 10000) / 100)
        local cop    = copper % 100
        -- BreakUpLargeNumbers adds locale-appropriate thousands separators
        -- (e.g. 12345g -> "12,345g") so large gold values render readably.
        local goldStr = (BreakUpLargeNumbers and BreakUpLargeNumbers(gold)) or tostring(gold)
        local parts = {}
        if gold > 0 then
            parts[#parts + 1] = "|cffffd700" .. goldStr .. "g|r"
        end
        if silver > 0 or gold > 0 then
            -- Show silver even at 0 when gold is present so "1g 0s 5c" reads cleanly
            parts[#parts + 1] = "|cffc0c0c0" .. silver .. "s|r"
        end
        -- Always include copper when it's nonzero — previous version dropped
        -- copper whenever gold/silver were present, which read as truncation.
        -- Skip it only when gold is very large (>=100) where copper precision
        -- isn't meaningful (and tighter columns benefit).
        if cop > 0 and gold < 100 then
            parts[#parts + 1] = "|cffeda55f" .. cop .. "c|r"
        end
        if #parts == 0 then
            return "|cffeda55f0c|r"
        end
        return table.concat(parts, " ")
    end

    function VoidUI:FormatTime(seconds)
        if not seconds then return "0s" end
        local m = math.floor(seconds / 60)
        local s = math.floor(seconds % 60)
        if m > 0 then return m .. "m " .. s .. "s" end
        return s .. "s"
    end

    function VoidUI:FormatNumber(n)
        if not n then return "0" end
        if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
        if n >= 1000 then return string.format("%.1fK", n / 1000) end
        return tostring(math.floor(n))
    end

    function VoidUI:CreateBackdrop(frame, style)
        if not frame or not frame.SetBackdrop then return end
        frame:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        if style == "transparent" then
            frame:SetBackdropColor(0.05, 0.05, 0.07, 0.85)
            frame:SetBackdropBorderColor(0, 0.78, 1, 0.5)
        else
            frame:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
            frame:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)
        end
    end

    function VoidUI:CreateShadow(frame)
        -- no-op in standalone
    end
end

-- Log + slash command — makes the load state visible
SLASH_VOIDAH1 = "/vah"
SlashCmdList.VOIDAH = function(msg)
    if not VoidUI or not VoidUI.AH then
        print("|cffff4444[VoidAH]|r VoidUI.AH not available — addon failed to initialize. Check for Lua errors.")
        return
    end
    if VoidUI.AH.OnAHShow then
        print("|cff00c7ff[VoidAH]|r Forcing panel show.")
        VoidUI.AH.ahOpen = true
        VoidUI.AH:OnAHShow()
    else
        print("|cffff4444[VoidAH]|r VoidUI.AH.OnAHShow not defined — AuctionUI.lua may have failed to load.")
    end
end

local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("PLAYER_LOGIN")
loadFrame:SetScript("OnEvent", function()
    local status = {}
    status[#status+1] = "modules=" .. (VoidUI._modules and "ok" or "missing")
    status[#status+1] = "AH=" .. (VoidUI.AH and "ok" or "missing")
    status[#status+1] = "OnAHShow=" .. (VoidUI.AH and VoidUI.AH.OnAHShow and "ok" or "missing")
end)

