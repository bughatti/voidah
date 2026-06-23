# Changelog

## [1.2.4] — 2026-06-23

### Fixed
- Cancelled auctions now leave your auctions list immediately instead of lingering until you
  close and reopen the Auction House. After a cancel, the owned-auctions list re-queries (the
  same way it does after posting), so the row disappears within about half a second.

## [1.2.3] — 2026-06-22

### Changed
- Quieter startup — removed the load-banner chat messages that printed on login.

## [1.2.2] — 2026-06-20

### Fixed
- **12.0.7 API breakage.** Three profession/AH calls Blizzard removed:
  - `GetAllRecipeIDs` -> `GetFilteredRecipeIDs` (the profession snapshot was erroring outright)
  - `SendCommoditySearchQuery` -> `SendSearchQuery` (commodity buying had silently stopped working)
  - `GetTradeSkillLineInfoByID` -> skill level now read straight off `GetBaseProfessionInfo`


## [1.2.1] — 2026-06-03

### Bug fixes
- **Embedded VoidLib.** Previous releases declared `## Dependencies: VoidLib`
  but VoidLib was never published to CurseForge as a standalone addon, so
  installs from CurseForge would fail to load with "Dependency: VoidLib is
  missing." VoidLib is now bundled under `Libs/VoidLib/` — no separate
  addon required.

## [1.0.1] — 2026-05-19

### Bug fixes
- **Money formatting** — `FormatMoney()` was truncating copper whenever gold or silver was present (e.g. `1g 50s 30c` displayed as `1g 50s`, dropping the copper). Now shows all three units when they have value. Copper is auto-suppressed only when gold ≥ 100g where copper precision becomes noise.
- **Thousands separators on large gold values** — gold values now use `BreakUpLargeNumbers` for locale-appropriate separators (e.g. `12,345g` instead of `12345g`). Improves readability on Browse / Sell / My Auctions / Deals / Scan / Professions tabs.

## [1.0.0] — 2026-05-16

Initial CurseForge release.

### Features
- Six-tab AH replacement panel: Browse, Sell, My Auctions, Deals, Scan, Professions
- **Browse**: category tree + search, price/ilvl sort, item-key filtering, secure buy bar
- **Sell**: stack/quantity inputs, deposit calc, smart undercut, copper-precision pricing
- **My Auctions**: active listings with cancel buttons
- **Deals**: auto-flags underpriced listings vs your scanned price database
- **Scan**: full/browse scan engine with throttle + progress bar, persistent realm price DB, Shopping List with per-row Buy button
- **Professions** tab: bundled wow-professions.com leveling shopping lists for 9 crafting professions (Cooking, Alchemy, JC, BS, Tailoring, LW, Engineering, Inscription, Enchanting) with [Buy] buttons routing to Browse + buy-target banner with live bag-count tracking, [+ List] buttons that add itemIDs to the Shopping List

### WoW 12.0.5 (Midnight) compatibility
- Uses public `C_AuctionHouse` APIs throughout
- Profession leveling data verified against current Midnight Season 1 recipes
- Shares `VoidUIAuctionDB` price cache with VoidBags for AH threshold awareness
