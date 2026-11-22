----------------------------------------------------------------------
-- VoidAH: which price for which goal, and how long it takes to sell (economy step 3, 2026-11-22).
--
-- The user, 2026-11-21: "push up, push down, finding the price that sells the quickest, almost like a financial
-- planner". Step 1 (Sales.lua) sees what the market buys, step 2 (Money.lua) what YOUR listings did. This turns them
-- into a choice on the Sell tab:
--   * Sell fast: the usual undercut, and how long it should take.
--   * Best price: the highest price that should still sell within BEST_HOURS.
-- The model: buyers take the cheapest listings first (seen in the step-1 data: units gone above a price that stayed
-- up were cancels, not sales), so a listing at price P sells after every unit listed at or under P. Time = (units at
-- or under P + yours) / the pace this item sells at here (units seen sold / hours the scans watched).
-- Never above what's been seen selling (90th percentile of sold prices, or your own sales): a gap up to a troll
-- listing isn't demand. Never at or above a price your own listings expired at (step 2).
----------------------------------------------------------------------
local AH = VoidUI and VoidUI.AH
if not AH then return end

local P = {
    BEST_HOURS = 12,      -- "best price" must sell within this (a quarter of 48 h: others undercut you meanwhile)
    MIN_SALES = 3,        -- sale records before a pace or a ceiling is trusted
    MIN_WATCH = 0.25,     -- hours of scan comparisons before a pace is trusted
    DAYS = 7,             -- pace and prices from the last week
    HOLD_RATIO = 0.7,     -- the market under this share of what it usually sells for: "cheap today"
    CEIL_PCT = 0.9,       -- the ceiling: this share of units sold at or under it
}
AH.PLAN = P

-- The hours of market the scan comparisons watched at a house since `cut` (Sales.lua keeps the windows).
local function Watched(house, cut)
    local obs = VoidUIAuctionDB and VoidUIAuctionDB._obs and VoidUIAuctionDB._obs[house]
    local h = 0
    for _, w in ipairs(obs or {}) do
        if w[2] > cut then h = h + (w[2] - math.max(w[1], cut)) / 3600 end
    end
    return h
end

-- How fast an item sells at a house: units per hour, and what that's based on
-- { units, sales (records), hours (watched), median, ceiling (CEIL_PCT of units sold at or under), few = true when
-- too little to trust }. nil when the scans haven't watched this house long enough.
function AH:SellPace(itemID, house, days)
    house = house or AH.HouseKey(nil)
    local cut = time() - (days or P.DAYS) * 86400
    local hours = Watched(house, cut)
    if hours < P.MIN_WATCH then return nil end
    local sold = VoidUIAuctionDB._sold and VoidUIAuctionDB._sold[house] and VoidUIAuctionDB._sold[house][itemID]
    local obs = VoidUIAuctionDB._obs[house]
    -- only sales inside a watched stretch: sales kept from before the stretches were recorded (VoidAH 1.12.0) would
    -- be divided by the new hours only and make the pace far too fast (Sol 11-22)
    local function watched(t)
        for _, w in ipairs(obs) do if t >= w[1] and t <= w[2] then return true end end
        return false
    end
    local units, sales, prices = 0, 0, {}
    for _, s in ipairs(sold or {}) do
        if s[1] >= cut and watched(s[1]) then
            units, sales = units + s[3], sales + 1
            prices[#prices + 1] = { s[2], s[3] }
        end
    end
    local info = { units = units, sales = sales, hours = hours, few = sales < P.MIN_SALES }
    if #prices > 0 then
        table.sort(prices, function(a, b) return a[1] < b[1] end)
        local run = 0
        for _, p in ipairs(prices) do
            run = run + p[2]
            if not info.median and run * 2 >= units then info.median = p[1] end
            if not info.ceiling and run >= units * P.CEIL_PCT then info.ceiling = p[1] end
        end
        info.high = prices[#prices][1]   -- the most anyone was seen paying
    end
    return units / hours, info
end

-- units listed at or under a price (a new listing at that price waits behind them)
local function Ahead(rows, price)
    local n = 0
    for _, r in ipairs(rows) do
        if r[1] <= price then n = n + r[2] else break end
    end
    return n
end

-- The plan for listing `qty` units. rows = what's listed now, { { unit, qty }, ... } sorted cheapest first
-- (AH.MarketPrice's third return: everything, dumps included, they sell first); fast = the Sell tab's undercut price;
-- rate, pace = AH:SellPace; opts = { step = the next price under a listing (1c; whole silver: 100), round = function
-- to a price the AH takes, hours = the listing's duration, ownHigh = the most your own listings sold at,
-- ownExpired = the cheapest price your own listings expired at }.
-- Returns { fast = { price, eta (hours, nil = unknown), ahead }, best = { price, eta, ahead } or nil,
--           slow = { fits = units that sell within the duration } or nil, hold = { usual } or nil,
--           above = the most anyone was seen paying, when the fast price is over it (no time then) }.
function AH.SellPlan(rows, qty, fast, rate, pace, opts)
    opts = opts or {}
    rows = rows or {}
    qty = math.max(1, qty or 1)
    local round = opts.round or function(p) return math.floor(p) end
    local known = rate and pace and not pace.few
    local function eta(price, ahead)
        if not known then return nil end
        if rate <= 0 then return math.huge end
        return (ahead + qty) / rate
    end
    local plan = {}
    local a = Ahead(rows, fast)
    plan.fast = { price = fast, ahead = a, eta = eta(fast, a) }
    -- the market now lists above everything seen selling (the cheap ones sold out, Horde AH 11-22: sold at 38c-65c,
    -- the cheapest left 99c): no buyer has been seen paying that, so no time for it, and say so
    local high = pace and pace.high
    if opts.ownHigh and (not high or opts.ownHigh > high) then high = opts.ownHigh end
    if known and high and fast > high then
        plan.above = high
        plan.fast.eta = nil
        return plan
    end
    -- won't all sell in time at this pace: how many would
    local hours = opts.hours
    if known and hours and plan.fast.eta and plan.fast.eta > hours then
        plan.slow = { fits = math.max(0, math.floor(rate * hours) - a) }
    end
    -- cheap today: the market well under what it usually sells for
    if known and pace.median and fast < pace.median * P.HOLD_RATIO then
        plan.hold = { usual = pace.median }
    end
    if not known or rate <= 0 then return plan end
    -- the ceiling: what's been seen selling (the market's 90th percentile, or more if you sold higher yourself),
    -- and never at or above a price your own listings expired at
    local ceiling = pace.ceiling
    if opts.ownHigh and (not ceiling or opts.ownHigh > ceiling) then ceiling = opts.ownHigh end
    if not ceiling then return plan end
    local step = opts.step or 1
    local best, why
    -- the most this may ask: what's been seen selling, and under a price your own listing expired at
    local cap = ceiling
    if opts.ownExpired and opts.ownExpired - step < cap then cap = opts.ownExpired - step end
    -- a price inside the gap under the next listing: the cap itself, when it still sells in time (Sol, release gate
    -- 11-22: listings at 40s and 1g, sales seen to 60s: 60s, not 39s 99c)
    local function tryCap()
        local p = round(cap)
        if p <= (best and best.price or fast) then return end
        local ah = Ahead(rows, p)
        local e = eta(p, ah)
        if e <= P.BEST_HOURS then best = { price = p, eta = e, ahead = ah } end
    end
    local lastLevel
    local stopped = false
    for _, r in ipairs(rows) do
        if r[1] ~= lastLevel then
            lastLevel = r[1]
            local c = round(r[1] - step)
            if c > fast then
                if c > ceiling then why = "ceiling"; stopped = true; tryCap(); break end
                if opts.ownExpired and c >= opts.ownExpired then why = "expired"; stopped = true; tryCap(); break end
                local ah = Ahead(rows, c)
                local e = eta(c, ah)
                if e > P.BEST_HOURS then why = "slow"; stopped = true; break end
                best = { price = c, eta = e, ahead = ah }
            end
        end
    end
    if not stopped then tryCap() end   -- nothing listed higher: up to the cap
    plan.best = best
    -- why there's nothing better than the fast price: "ceiling" (nothing seen selling higher), "expired" (your own
    -- listing expired there), "slow" (a higher price wouldn't sell within BEST_HOURS), "top" (nothing listed higher)
    if not best then plan.why, plan.ceiling = why or "top", ceiling end
    return plan
end

-- "~40 min", "~6h", "48h+" for an ETA in hours
function AH.EtaText(h)
    if not h then return nil end
    if h == math.huge or h > 48 then return "48h+" end
    if h < 1 then return ("~%d min"):format(math.max(5, math.floor(h * 60 / 5 + 0.5) * 5)) end
    return ("~%dh"):format(math.floor(h + 0.5))
end
