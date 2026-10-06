# VoidAH

**A full Auction House replacement with built-in profession leveling plans and shopping lists.**

VoidAH replaces Blizzard's Auction House window with a six-tab panel: Browse, Sell, My Auctions, Deals, Scan, and **Professions**. The Professions tab ships leveling shopping lists for all 9 crafting professions, with one-click Buy buttons that track how many you've bought as you go.

---

## Features

### Browse
- **Category tree and search box**, results sorted by price or item level
- **Secure buy bar** with a quantity box
- **Ctrl-click** any item to preview it in the dressing room, **Shift-click** to link it in chat

### Sell
- Stack-size and total-quantity inputs with a **deposit calculator**
- **Smart undercut** — fills in a price just below the cheapest listing
- Copper-precise pricing; soulbound and warbound items are hidden automatically

### My Auctions
- All your active listings in one view, with a **cancel button** on each row

### Deals
- **Flags listings priced well below** your scanned price history
- One-click buy on bargain commodities

### Scan
- **Full or browse scan** with a progress bar, throttled to stay within Blizzard's limits
- A **per-realm price database** that persists between sessions
- A **shopping list** with a Buy button on every row — survives reloads

### Professions
- **Leveling plans** for Cooking, Alchemy, Jewelcrafting, Blacksmithing, Tailoring, Leatherworking, Engineering, Inscription, and Enchanting
- Each plan shows the **trainer location**, notes, the leveling steps with skill ranges, and the full material list
- **Buy** jumps to Browse with the item selected and shows a banner that tracks your progress (e.g. "47 / 200 in bags")
- **+ List** adds the material to your shopping list on the Scan tab

---

## Slash Commands

| Command | What it does |
|---|---|
| `/vah` | Bring up the VoidAH panel at an Auctioneer if it didn't open on its own |

You rarely need it — VoidAH opens automatically when you talk to an Auctioneer.

---

## Getting Started

1. Install with the CurseForge app, or copy the `VoidAH` folder into `World of Warcraft/_retail_/Interface/AddOns/`.
2. Restart WoW or `/reload`.
3. Talk to any Auctioneer — VoidAH replaces the default window.

---

## Good to Know

- **Profession lists** are adapted from [wow-professions.com](https://www.wow-professions.com/) guides (credit to their authors) and checked against in-game recipes. Quantities include a buffer so you don't run short. Gathering professions are left out — you gather those, not buy them.
- Your price history is shared with **VoidBags**, which uses it to spot items worth selling.

---

## Compatibility

- **WoW 12.1** (Midnight Season 2)
- Standalone — nothing else to install
- Works alongside Auctionator, TSM, and other AH addons (only one can be the active AH window at a time)

---

*Part of the Void addon family by Vede · MIT licensed · free M+ & raid player lookups at [voidscout.io](https://voidscout.io) · more addons & apps at [tinkerline.io](https://tinkerline.io) · [Discord](https://discord.gg/7ZHmx7zMDh)*
