# VoidAH — Auction House replacement

**CurseForge Project ID:** 1512422
**Status:** Published, v1.2.0 (May 2026 — VoidLib dependency adoption).
**Public repo:** `bughatti/voidah`
**Dependencies:** `VoidLib` (sibling addon — declared in TOC)

## File layout

| File | Role |
|---|---|
| `VoidAH.toc` | Load order: Core → Auction → AuctionUI → ProfessionPlans → VoidHubBundle |
| `Core.lua` | Module shim (creates `VoidUI.NewModule` placeholder, auto-fires `Init`+`Enable` via `C_Timer.After(0, ...)`), persists config to `VoidUIAuctionDB.config`, `/vah` force-show, prints load status at PLAYER_LOGIN |
| `Auction.lua` | AH session logic — registers `AUCTION_HOUSE_SHOW`, calls `AH:OnAHShow()` |
| `AuctionUI.lua` | Browse/Sell/MyAuctions/Deals/Scan tabs + detail list sell tab. Hides Blizzard's AH via `SetAlpha(0)` + `EnableMouse(false)` + `hooksecurefunc` on Show |
| `ProfessionPlans.lua` | Profession crafting planner |

## Architecture

Standalone addon namespace was extracted from `VoidUI/Modules/Auction.lua` + `AuctionUI.lua` specifically to **avoid VoidBags taint**. AH posting from inside VoidBags' SecureActionButton context triggered taint propagation; isolating into VoidAH solved it.

## Secret-value safety pattern

**Layered defense** — see [[voidah-secret-values-pattern]] memory for the pattern's history.

```lua
local VL = VoidLib
local S  = VL.Secrets

-- Early-exit at function level
if AH.AreSecretsDisabled() then return end   -- aliased to S.AreSecretsDisabled

-- Field-level guards
local price = AH.SafeMoney(info.minPrice)
local qty = AH.SafeNum(info.quantity)
local total = AH.SafeMul(price, qty)
```

**v1.2.0 migration (May 2026):** helpers now sourced from `VoidLib.Secrets`. `AH.<name>` aliases preserved at top of `Auction.lua` for backwards compat with the 39 existing call sites. New code should call `VoidLib.Secrets.<name>` directly. See `wow-addons/VoidLib/CLAUDE.md`.

## Critical API gotchas

- **Sell-tab scan:** use `C_AuctionHouse.SendSearchQuery`, NOT `SendSellSearchQuery`. The audit commit incorrectly swapped these; the latter doesn't deliver results to the sell-flow handler. REVERTED.
- **Core.lua syntax:** earlier version had a stray `end` at line 107 → silent file load failure → no `NewModule` → AuctionUI never hooked. Always verify block structure compiles.

## Key flow

```
[AUCTION_HOUSE_SHOW]
    ↓
[Auction.lua AH:OnAHShow()]
    ↓
[AuctionUI.lua creates+shows panel]
    ↓
[hooksecurefunc on Blizzard AH frame Show → SetAlpha(0) + EnableMouse(false)]
```

## SavedVariables
- `VoidUIAuctionDB.config` — per-realm settings
- Realm AH prices cache (separate)

## Slash
- `/vah` — force-show the panel (debugging)

## Audit reference
See `VoidAH/AUDIT.md` if it exists for the May 2026 12.0.5 audit findings.
