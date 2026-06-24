# VoidAH

**Full Auction House replacement panel with bundled profession leveling plans and shopping lists.**

Replaces Blizzard's stock AH window with a six-tab panel: Browse, Sell, My Auctions, Deals, Scan, and **Professions**. The Professions tab ships with curated 1→100 leveling shopping lists for all 9 crafting professions (sourced from wow-professions.com), one-click Buy buttons that route to Browse + set a buy-target banner with live bag-count tracking, and "+ List" buttons that add items to a persistent shopping list by itemID.

---

## Features

### Browse tab
- Category tree + search box
- Results sorted by price/ilvl
- Item-key filtering
- Secure buy bar with quantity input

### Sell tab
- Stack and total-quantity inputs
- Deposit calculator
- Smart undercut button (auto-fills price below cheapest listing)
- Copper-precision pricing

### My Auctions tab
- All your active listings in one view
- Cancel buttons per row

### Deals tab
- Auto-flags listings underpriced versus your scanned price database
- One-click buy on bargain commodities

### Scan tab
- Full or browse scan engine with progress bar
- Throttled API queries to avoid CF rate limits
- Persistent per-realm price database
- **Shopping List** with per-row Buy button — survives reloads

### Professions tab ⭐
- Bundled leveling guides for **Cooking, Alchemy, Jewelcrafting, Blacksmithing, Tailoring, Leatherworking, Engineering, Inscription, Enchanting**
- Each plan shows: trainer location, notes, leveling steps with skill ranges, and total material lists
- **[Buy]** button per material → routes to Browse with item pre-selected, sets a buy-target banner that tracks bag-count progress (e.g. "47 / 200 Spiced Biscuits in bags")
- **[+ List]** button → adds itemID to the Shopping List on the Scan tab
- Trainer location prompts so you don't have to alt-tab to a wiki

---

## Slash commands

| Command | Action |
|---|---|
| `/vah` | Toggle the AH panel (also works while AH is open as the replacement) |

The panel auto-attaches when you talk to an Auctioneer. Press the close button or interact with the auctioneer to dismiss.

---

## Installation

1. Download and extract to `Interface/AddOns/VoidAH/`
2. Reload your UI (`/reload`)
3. Visit any Auctioneer NPC — VoidAH replaces the default panel automatically

---

## Storage

- **`VoidUIAuctionDB`** (account-wide): per-realm price database, shopping list, scan history, profession plan progress

The DB is shared with other Void* addons that benefit from price data (e.g. VoidBags reads it for AH threshold checks).

---

## Professions data

Bundled material lists were captured from **wow-professions.com** for Midnight 12.0.7 and verified against in-game recipe data. Quantities account for variance from Inspiration procs and skill-point yellow/green ranges so you won't run short. Gathering professions (Mining, Herbalism, Skinning) are intentionally excluded — you collect those, you don't buy them.

If a profession's recipe data changes in a future Midnight patch, the bundled lists will be refreshed in addon updates.

---

## Compatibility

- **WoW Interface 12.0.7** (Midnight Season 1)
- Works alongside Auctionator, TSM, and other AH addons (only one can be the active AH frame at a time — `/vah` toggles)
- No taint in normal usage — uses public `C_AuctionHouse` APIs only

---

## Credits

Built for Vede on Elune. Part of the Void* addon family.

Profession leveling material lists adapted from [wow-professions.com](https://www.wow-professions.com/) guides — credit to their authors for the underlying research.
