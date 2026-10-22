# Changelog

## [1.2.11] — 2026-10-22

### Fixed
- **Prices only ever went down.** A full scan compared each listing to the price you already had, so an item kept its all-time low forever, and a price that went up was never corrected. A full scan now sets every listed item to today's lowest price, up or down.

### Added
- **Prices refresh on their own.** If your last full scan is more than 12 hours old, opening the Auction House starts one in the background while you browse. Your old setting to scan on every visit still works.

## [1.2.10] — 2026-10-21

### Fixed
- **Posting an auction** no longer triggers "VoidAH tried to call the protected function" errors. A successful post was being mistaken for a failure, so VoidAH retried it from the same click, and the game blocked the retries.
- **Posts that need confirmation**, like Blizzard's price warning, now show a "Post this?" box. Before, they were silently never posted.

## [1.2.9] — 2026-10-19

### Added
- **"Midnight only" checkbox on the Browse tab** (on by default). Hides items from older expansions, so you don't buy an old enchant, gem or consumable that won't work on current-season gear. Untick it to see everything.

## [1.2.8] — 2026-10-14

### Changed
- Updated for WoW 12.1.5 — no longer shows as out of date.
- **Works in WoW Forever** — the auction house window, scans and prices.

## [1.2.7] — 2026-10-06

### Fixed
- The "How many do you want to buy?" popup no longer errors (patch 12.x renamed the popup's text box).
- Last-scan age reads "5m / 3h / 12d ago" instead of a huge number of minutes.
- `/vah` away from an Auctioneer tells you to go to one instead of opening an empty panel.
- The Void addons info panel (`/vhub info`) now lists only the addons you can actually get, with up-to-date descriptions.

## [1.2.6] — 2026-08-11

### Changed
- Compatibility with patch 12.1 "Curse of Ula'tek" (TOC interface bump to 12.1).

## [1.2.5] — 2026-07-20

### Added
- **Ctrl-click any item to preview its appearance** in the dressing room (and
  Shift-click to link it to chat) — works across the browse results and the
  individual listings. Respects your own modified-click bindings.

### Fixed
- **Soulbound and Warbound items no longer clutter the Sell tab.** The filter was
  matching the old "Account Bound" tooltip text, which 12.0 renamed to "Warbound",
  so warbound items slipped through. It now uses the reliable bound-state check and
  hides everything you can't actually post.

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
