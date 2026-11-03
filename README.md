# VoidAH

**A full Auction House replacement with built-in profession leveling plans and shopping lists.**

VoidAH replaces Blizzard's Auction House window with a six-tab panel: Browse, Sell, My Auctions, Deals, Scan, and **Professions**. The Professions tab ships leveling shopping lists for all 9 crafting professions, with one-click Buy buttons that track how many you've bought as you go.

---

## Features

### Browse
- **Category tree and search box**, results sorted by price or item level
- **Filters menu**: Usable only, Upgrades only, Uncollected only, Midnight only, item quality, and **primary stat** (Any / your spec / Agility / Strength / Intellect)
- **Max price** box — hide anything above your budget
- **Upgrade arrows**: gear that beats what you're wearing in that slot gets an arrow and "+N ilvl". **Green** = it has your spec's two best secondary stats, **orange** = it's an upgrade but carries a weaker one, **grey** = an upgrade whose stats can't be read (hover to check). Stat priorities come from what the top Mythic+ players of each spec actually wear (Blizzard's own data)
- **"Midnight only"** (on by default at max level, off while leveling) hides older-expansion items, so you never buy an old enchant or gem that won't work on current gear
- **Secure buy bar** with a quantity box
- **Ctrl-click** any item to preview it in the dressing room, **Shift-click** to link it in chat

### Sell
- Stack-size and total-quantity inputs with a **deposit calculator**
- **Smart undercut** — fills in a price just below the cheapest listing
- Prices in whole silver (the auction house's own rule); soulbound and warbound items are hidden automatically

### My Auctions
- All your active listings in one view, with a **cancel button** on each row

### Deals
- **Flags listings priced well below** your scanned price history
- One-click buy on bargain commodities

### Scan
- **Full or browse scan** with a progress bar, throttled to stay within Blizzard's limits
- A **per-realm price database** that persists between sessions; a full scan sets each item to today's lowest price, up or down
- **Prices stay fresh on their own** — if your last full scan is over 12 hours old, opening the AH runs one in the background while you browse
- A **shopping list** with a Buy button on every row — survives reloads

### Professions
- **The cheapest leveling path from your own skill** for Cooking, Alchemy, Jewelcrafting, Blacksmithing, Tailoring, Leatherworking, Engineering, Inscription and Enchanting, worked out live when you pick one
- **Built from the game's own recipe data**: when each recipe turns yellow and grey and how many points it gives. Each craft is the recipe with the lowest cost per expected skill point, using the odds of a skill-up as recipes fade from yellow to grey
- **Your prices**: your Auction House scan, vendor prices from merchants you've visited, else the game's listed price (marked "est.")
- **Recipes you know come first.** Where none of them gives skill, it picks the cheapest one you don't know yet and flags it NOT LEARNED
- **Reads your real skill** for each expansion's tier (Midnight Alchemy, not your old Legion Alchemy). Open the profession window once and it remembers your recipes
- The steps with skill ranges and craft counts, and the full material list with prices
- **Buy** jumps to Browse with the item selected and shows a banner that tracks your progress (e.g. "47 / 200 in bags")
- **+ List** adds the material to your shopping list on the Scan tab

### VoidGear suggestions (optional)
- With **VoidGear** installed, the shopping list on the Scan tab gets a **"VoidGear suggestions"** section: the enchants, gems and consumables VoidGear's Prep tab says you need, each with a price and a Buy button
- **It keeps itself current**: buy it, put it on, and the row drops off by itself. It waits for a scan to finish instead of flickering while prices come in
- VoidGear's own **Search AH** button searches right here in VoidAH's Browse tab
- Without VoidGear, VoidAH works exactly the same; the section just isn't there

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

- **Settings are per character.** Each character keeps its own VoidAH settings, and a new character starts with the settings of the one you played last, so nothing resets when you update. Right-click the Void hub icon by your minimap and pick **Copy settings from...** to take another character's settings for one Void addon or all of them. That includes your shopping list, undercut and Browse filters. Price scans stay shared.
- **Profession plans** come from the game's own recipe tables and your own prices. Skill-ups past yellow are a chance, so counts are what you can expect, not a guarantee. Gathering professions are left out: you gather those, not buy them (VoidGather shows where your skill-up nodes are).
- **For the best prices,** run a full scan first, and open each profession window once so VoidAH knows your recipes.
- Your price history is shared with **VoidBags**, which uses it to spot items worth selling.

---

## Compatibility

- **WoW 12.1.5** (Midnight Season 2)
- **WoW Forever** supported too
- Standalone — nothing else to install
- Works alongside Auctionator, TSM, and other AH addons (only one can be the active AH window at a time)

---

*Part of the Void addon family by Vede · MIT licensed · [Source & bug reports](https://github.com/bughatti/voidah) · [All Void addons](https://www.curseforge.com/members/bughatti/projects) · free M+ & raid player lookups at [voidscout.io](https://voidscout.io) · more at [tinkerline.io](https://tinkerline.io) · [Discord](https://discord.gg/7ZHmx7zMDh)*
