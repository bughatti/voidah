# Changelog

## [1.10.1] — 2026-11-12

- **The Auction House window and the Auction House anywhere window can be dragged** (by the title bar) and stay where you put them, even after a restart.
- **Void hub button:** left-click opens one panel with all your Void addons by name, grouped, each with its own on/off switches (it replaces the ring of icons), with a background slider. The hub's info window now stays where you put it.

## [1.10.0] — 2026-11-10

### Added (WoW Forever)
- **Your tools stay off the Sell list.** Profession tools, your fishing pole, cooking-fire items and class items (rogue poisons and powders, other classes' reagents) aren't offered for sale, so a run of listings can't post your Mining Pick. One copy of each tool is kept; a spare can be listed.
- **Drop box on the Sell tab:** drag any item onto the item box to sell it, including a kept tool you really want to sell (a better pole came along).
- **Tooltip:** "Kept: you need it (Fishing). VoidAH won't list it." on those items.

## [1.9.1] — 2026-11-10

### Changed
- **Price tooltips say how fresh the price is:** "AH 43s each · 1 listed · 1h 27m ago". The age is always shown and turns orange after 6 hours, when the price may have changed; "1 listed" (from your last full scan) warns when one listing sets the price.
- **At a merchant, the real profit of buying to resell:** hovering an item a vendor sells now shows "Buy here 14s 40c, resell on the AH: +26s 47c profit each", with the vendor's stock when it's limited. Before, it compared the AH with what a vendor *pays you* for the item ("+39s over vendor"), which isn't the deal when you're buying it. When the profit rests on one listing or an old price, it says to check the AH first.

### Fixed
- **Auction House anywhere** no longer errors when the old VoidUI addon is enabled at the same time.

## [1.9.0] — 2026-11-10

### Added (WoW Forever)
- **Professions tab plans with Forever's own recipes** for every profession, First Aid included (it was missing), from VoidProf. Vendor-sold materials show the nearest vendor that sells them for gold, with a **Go** button that shows the way (VoidGPS). **Vendor stops to errands** puts them on VoidGPS's errands list so you don't have to come back to the Auction House.
- **Your materials stay off the sell list:** a material a Forever recipe of one of your professions uses (Tigerseye for a blacksmith, vials and thread for First Aid) is never vendor trash.

### Fixed (WoW Forever)
- **Browse at level 60:** the "current expansion only" filter could hide every item (Forever items are all Classic). It's off and hidden there.
- **Upgrade arrows on Classic gear** no longer come out grey ("unknown"): Midnight's stat priorities don't load on Forever.

## [1.8.1] — 2026-11-09

### Fixed
- **The Sell tab suggested prices that were far too low** when several identical listings were up. The auction house groups them into one row with a count, and VoidAH divided the price by that count: 14 listings at 36s read as "Current: 2s 57c", and the suggested price was under that. Your own listings on **My Auctions** were misjudged the same way. Fixed everywhere; prices you typed yourself were never changed. Sorry about this one.

### Added
- **One dumped listing doesn't drag your price down.** If the cheapest listing is under half the item's usual price (its 7-day median, with at least 3 days of scans), the Sell tab prices you near the usual and says why. Buying the cheap one to relist can pay.
- **A second look before a bad price.** Posting at under half an item's usual price, or for less than a vendor would pay you, asks you to confirm first.

## [1.8.0] — 2026-11-09

- **The Auction House, anywhere.** Away from an Auctioneer, `/vah` (or the VoidAH icon on the Void hub) opens the auction house as it was on your last visit: every item VoidAH has seen with its lowest buyout, how many were listed and in how many auctions, how long ago, and a trend arrow against its 7-day average (green = cheaper than usual, red = dearer). Search, categories, click a column to sort. Read-only: it's for looking things up while you farm or plan.
- **Plan away, buy there:** **+ List** puts an item on VoidAH's shopping list, which VoidAH checks by itself the next time you open the Auction House. **My list only** shows just those.
- Full scans now also remember how many of each item were listed.

## [1.7.2] — 2026-11-09

- **Fixed: box borders missing a side.** Depending on where a window sat on screen, its left, right or bottom line could vanish. Borders are now exactly one screen pixel and can't round away.

## [1.7.1] — 2026-11-07

### Fixed
- **Vendor -> AH only lists what vendors sell for gold.** Recipes bought with Merchant's Favor (WoW Forever's Azeroth Commerce Authority) aren't a gold flip, so they're left out, and the vendor shown is the nearest one that takes gold. The "Sold by" tooltip marks Merchant's Favor vendors. (Needs VoidGPS 0.3.2.)

## [1.7.0] — 2026-11-07

### Added
- **Deals has a type picker.** The button at the top left of Deals switches between kinds of money-makers instead of adding more tabs:
  - **Below market**: the old Deals list, listings under their usual price.
  - **Vendor -> AH** (WoW Forever, with VoidGPS): everything vendors sell all year, with the nearest vendor, the vendor price, the AH price and your profit after the AH cut, biggest first. Pick **Recipes**, **Pets** (Cat Carriers, Parrot Cages...), **Gear**, **Reagents**, **Consumables** or **All**; **Limited only** shows the limited-stock goods people buy up and resell. Hover for every vendor that has it; click for a route to the nearest one.
  - **AH -> Vendor**: listings cheaper than what a merchant pays for them. Buy, then sell to any vendor. Click to look it up in Browse.
  - **Crafting**: every recipe you know, what its materials cost (your scans, merchants, vendors) and what it sells for here after the AH cut, most profit first, with the recipe's skill color. Hover for the materials. Needs VoidProf 1.2.1 and each profession window opened once.
  - **Disenchant** (WoW Forever, for enchanters): greens and blues that break into more than they cost, a rough estimate from Classic's disenchant odds (Forever's may differ) and your scans of dust, essences and shards, with the Enchanting skill each needs.
- Profit uses the AH cut VoidAH learned from your own sales (5% until it has).

## [1.6.0] — 2026-11-06

### Added
- **What selling costs you, before you post.** The Sell tab now shows the deposit (back if it sells, lost if not), the AH's cut, what you'll actually get, and how that compares to the vendor: "List it: +2s 10c over vendor" or "Vendor it: the AH pays 30c less".
- **Selling ledger.** My Auctions shows "Selling today" and "7 days": what selling earned you after the AH's cut, deposits lost on expired or cancelled auctions, and postage. Hover it for the breakdown for this character and for all your characters, or type `/vahmoney`.
- **AH value in item tooltips.** Items you can sell show their AH price, what you'd get after the cut, and whether listing beats the vendor. Soulbound items are skipped. Prices come from your own scans, with their age.
- **The AH's cut is learned from your sales,** per auction house (sale mail shows it). Until your first sale it assumes 5% and marks it "5%?".
- **VoidQuest** uses these values for its "worth the most gold" quest reward marker.

### Fixed
- **Sell tab layout:** the price boxes overlapped the duration buttons and "% undercut" ran past the panel's edge. The form is on an even grid now and fits.

## [1.5.2] — 2026-11-06

### Fixed
- **WoW Forever: single items post again.** Forever's Auction House takes copper prices only for stackable goods; a single item (gear, the big catfish) with copper in its price failed with "Internal auction error" since 1.5.1. Single items now list in whole silver, rounded up so you never drop more than your % undercut, and never above the lowest listing: at 19s you list at 19s, not 18s. Stackables keep their copper prices. Retail is unchanged.

## [1.5.1] — 2026-11-06

### Fixed
- **WoW Forever: Sell tab prices.** The price list took a flat 1 silver off every item, so anything selling under 1s (most of Forever's market) showed 1c. The list now uses your % undercut, the same as the price box.
- **WoW Forever: copper prices.** Forever's Auction House takes copper, so VoidAH no longer rounds your price up to whole silver there (an 8c item posted at 1s). Retail still rounds to whole silver, as it must.

## [1.5.0] — 2026-11-03

### Changed
- **Profession plans now come from VoidProf.** VoidProf works out the leveling path; VoidAH's Professions tab shows what's left to buy, with your Auction House prices and the Buy buttons. Install VoidProf to keep using the tab.
- **Profession leveling uses what you already have.** The Professions tab's leveling path now counts the materials you own (this character's bags and bank and the warband bank, plus your other characters with VoidGather installed) and picks recipes that use them up. The materials list shows only what's left to buy, and the notes list what to take from which character ("423x Eversinging Dust: warband bank 20, your gatherer 398") and what it's worth on the AH. The plan still won't burn expensive materials to save a little gold.
- **Makes materials when that's cheaper.** The leveling path can craft a material with a recipe you know instead of buying it, and for Inscription it mills herbs into pigments for your inks. A "Make first" list says what to mill and craft ("Mill 1590 Tranquility Bloom (159 mills) for ~1908 Powder Pigment", "Craft 49x Sienna Ink"). It counts whole crafts and whole mills, and inks from earlier steps go to later ones. Milling yields are learned from your own milling; until you've milled some they're an estimate.

### Fixed
- **VoidGear suggestions:** after you put on a new item, the gem it needs could be missing from the list until you closed and reopened the Auction House. The list now updates on its own once your gear has loaded.

## [1.4.3] — 2026-11-02

### Changed
- **Settings are per character.** Each character keeps its own VoidAH settings, and a new character starts with the settings of the one you played last, so nothing resets when you update. Right-click the Void hub icon by your minimap and pick **Copy settings from...** to take another character's settings for one Void addon or all of them. That includes your shopping list, undercut and Browse filters. Price scans stay shared.

## [1.4.2] — 2026-11-02

### Changed
- **Void hub icon:** your Void addons now pop out in rings around the hub icon, fanning away from the minimap, instead of one long column. The pop-up also works while another addon moves or fades the minimap.

## [1.4.1] — 2026-11-01

### Changed
- **Void hub icon:** the list of Void addons is up to date (adds VoidGather and VoidSweep, refreshed descriptions).

## [1.4.0] — 2026-10-30

### Changed
- **Professions tab rebuilt.** Each plan is now the cheapest leveling path from your own skill, worked out live from the game's recipe data and your own prices (your AH scan, vendor prices from merchants you visited, else the listed price marked "est."). Recipes you know come first; when none of them gives skill, the cheapest one you don't know yet is shown and flagged NOT LEARNED. Skill-up odds past yellow are counted in.
- **Your real skill per expansion.** The plan reads Midnight Alchemy, not your old Legion Alchemy, and remembers your recipes once you open the profession window.

### Added
- **VoidGear suggestions** on the Scan tab's shopping list (when VoidGear is installed): the enchants, gems and consumables VoidGear's Prep tab says you need, with prices and Buy. It waits for scans to finish and drops a row by itself once you've bought and applied it. VoidAH works the same without VoidGear.
- VoidGear's **Search AH** button searches in VoidAH's Browse tab.

## [1.3.1] — 2026-10-27

### Added
- **Buy several at once from a grouped row.** Rows like "Qty 15" of a bag are separate auctions. The buy bar now asks how many, then Confirm Buy steps through them one click each (the game allows one auction per click), never above the price you started at and only the same version of the item (same sockets, stats or pet level). It reports how many went through.

### Fixed
- **Market price** is the cheapest listing again, so the Sell tab's undercut starts from the real low price.
- **Scans.** Aborting a scan can't make the next one skip ahead, a category that fails moves on instead of stalling, and queued requests no longer get stuck.
- **Sell tab.** A price you type is kept. A 0% undercut posts at market everywhere. Similar sell rows are re-checked after merging.
- **Shopping list** scans once per click, and Back works after buying a commodity.
- **Professions tab** stars Cooking when you know it, not just your two main professions.
- **Caged battle pets** show their real name and icon.
- Chat messages say "VoidAH" instead of the old "VoidUI AH".

## [1.3.0] — 2026-10-24

### Added
- **Filters menu on Browse.** Usable only, Upgrades only, Uncollected only, Midnight only, item quality, and primary stat (Any / your spec / Agility / Strength / Intellect). The button shows how many filters are on, and Reset clears them.
- **Max price.** Type a gold amount and anything whose cheapest listing costs more is hidden.
- **Upgrade arrows.** Gear that beats what you're wearing in that slot shows an arrow and "+N ilvl". Rings, trinkets and one-handers are compared with the lower of your pair, and the off hand only counts if you can dual wield.
  - **Green:** both of its secondary stats are your spec's two best.
  - **Orange:** it's an upgrade, but it carries a weaker stat.
  - **Grey:** its stats can't be read. Hover it to check.
- **Stat priorities from real players.** For every spec, the secondary stats the top Mythic+ players actually wear, taken from Blizzard's own data.

### Fixed
- **Posting could list the wrong item.** If you sorted your bags after picking an item to sell, the post went to whatever moved into that slot, at the first item's price. It now stops and asks you to pick the item again.
- **Blizzard's filters (usable, current expansion) returned nothing.** The search left out the item-quality filters, which the auction house needs as well.
- **Searching after going Back to Categories** stayed limited to the category you'd just left.
- **"Midnight only" no longer hides gear while you're leveling.** You need older-expansion gear until max level.

## [1.2.13] — 2026-10-23

### Fixed
- **Gear, decor and other single items wouldn't post.** The auction house only takes prices in whole silver, and a % undercut nearly always leaves copper, so the post was silently dropped. Prices now fill in whole silver, and any copper you type is rounded off. Commodities were already rounded, which is why they still worked.
- **"48h" posted a 24-hour auction, and "24h" posted 12 hours.** Each button now posts the duration it says. Checked live: the old 48h left 86,399 seconds.
- **My Auctions showed "Short" for every auction.** It now shows the real time left.
- **Commodity buys now show the real total before you pay.** Buying a stack used to complete with only the cheapest per-unit price shown, so a big quantity could climb into pricier listings unseen. Click "Get Price" for the total, then "Buy Now". Cancel now really cancels.
- **Cancel on My Auctions** works every time. Before, it could be blocked by the game if anything else was queued.
- **Full scan stuck at "0% (0 / 0)".** Blizzard only answers one full scan every 15 minutes. A scan that gets no answer now stops after a minute instead of hanging.
- **Browse showed nothing while a background price scan was running.**
- **"Midnight only" let some old-expansion items through** when their data hadn't loaded yet.
- **Deals.** One odd day of prices could turn hundreds of items into fake 0% deals. The market price is now the middle of the last 7 days, and an item needs 3 days of scans before it counts as a deal. Savings show as a positive amount, missing item names fill in, and clicking a deal opens its listings.
- **The Deal % column on Browse** always read 100%. It now compares the live price to the 7-day market.
- **Sell price ignored your % undercut** and could overwrite a price you'd typed.
- **Gear could show the wrong lowest price.**
- **Shopping-list alerts** didn't fire on the first visit after prices went stale.
- **Bid-only listings** couldn't be bid on, and your own listings could be clicked to buy.
- **Requests the AH drops are retried** instead of lost, so listings don't hang on "Loading...".
- Commodity purchases no longer say "Purchase successful!" twice.
- Scroll bars no longer stick out past the right edge of the lists.
- The Professions tab drew boxes where its symbols should be.

### Changed
- **Profession plans rechecked against the current guides for 12.1.5.** No guide changed since launch, but four lists were wrong from the start. Tailoring counted both 65-90 linings, so it told you to buy twice the cloth. Engineering double-counted its ore. Enchanting overstated dust, shards and motes. Alchemy was 240 Sunglass Vials short. Cooking's skill ranges are corrected too.
- **Posting now says what happened.** You see a "Posting..." line in chat, and if the auction house rejects a post or purchase, its reason shows in chat.
- **Sell list:** a stackable item (mats, flasks) split across bag slots shows as one row with your total, and posting defaults to all of it. Gear and other single items still post one at a time.
- **My Auctions:** sold auctions show "Sold" and no Cancel button.

## [1.2.12] — 2026-10-22

### Fixed
- **Warbound items in the Sell list.** "Warbound until equipped" items showed up for selling even though the Auction House won't take them. The Sell list now leaves out anything the AH refuses.

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
- **Professions** tab: bundled leveling shopping lists for 9 crafting professions (Cooking, Alchemy, JC, BS, Tailoring, LW, Engineering, Inscription, Enchanting) with [Buy] buttons routing to Browse + buy-target banner with live bag-count tracking, [+ List] buttons that add itemIDs to the Shopping List

### WoW 12.0.5 (Midnight) compatibility
- Uses public `C_AuctionHouse` APIs throughout
- Profession leveling data verified against current Midnight Season 1 recipes
- Shares `VoidUIAuctionDB` price cache with VoidBags for AH threshold awareness
