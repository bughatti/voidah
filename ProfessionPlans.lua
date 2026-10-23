----------------------------------------------------------------------
-- VoidUI ProfessionPlans
--
-- Bundled leveling material lists for Midnight professions (checked
-- against the live guides 2026-10-23, patch 12.1.5 -- unchanged since 12.0.5),
-- sourced from wow-professions.com leveling guides. Each plan is a
-- list of { qty, name } pairs that the AuctionUI Professions tab
-- can load into the Shopping List or buy directly from the AH.
----------------------------------------------------------------------

VoidUI = VoidUI or {}

VoidUI.ProfessionPlans = {
    {
        id   = "cooking",
        name = "Cooking 1-100",
        skill = "Cooking",
        trainer = "Sylann (Silvermoon City inn)",
        notes = "Vendor mats: Butter & Spices (Cooking supply vendor near trainer). AH mats: Plant Protein, Ripened Veg, Mana-Wyrm Essence.",
        steps = {
            { startSkill = 1,  endSkill = 25,  recipe = "Spiced Biscuits", spellID = 1226200, count = 50,  per = "1x Butter, 3x Spices" },
            { startSkill = 25, endSkill = 35,  recipe = "Felberry Figs",   spellID = 1226190, count = 10,  per = "10x Plant Protein, 4x Ripened Veg, 1x Butter, 1x Mana-Wyrm Essence" },
            { startSkill = 35, endSkill = 100, recipe = "Spiced Biscuits", spellID = 1226200, count = 200, per = "1x Butter, 3x Spices (also feeds Hearty Food; alternate the two)" },
            { startSkill = 35, endSkill = 100, recipe = "Hearty Food",     spellID = 1226167, count = 30,  per = "uses crafted Spiced Biscuits; repeat until 100" },
        },
        mats = {
            { 260, "A Big Ol' Stick of Butter" },
            { 750, "Pouch of Spices" },
            { 100, "Plant Protein" },
            {  40, "Ripened Vegetable Assortment" },
            {  10, "Mana-Wyrm Essence" },
        },
    },
    {
        id   = "alchemy",
        name = "Alchemy 1-100",
        skill = "Alchemy",
        notes = "Light's Potential crafting path for 50-100. Variable upper-end material counts.",
        -- Mat format: { qty, name, itemID } — itemID lets us add to shopping list
        -- without depending on the local item cache being warm.
        mats = {
            { 940, "Tranquility Bloom",     236761 },
            { 640, "Sunglass Vial",         240991 },  -- 400 + 240 for the 1-50 steps (vendor item)
            { 244, "Argentleaf",            236777 },
            { 240, "Azeroot",               236774 },
            {  92, "Mote of Light"                 },  -- often cached from drops
            {  15, "Sanguithorn"                   },
            {   4, "Mote of Primal Energy"         },
            {   3, "Mana Lily",             236778 },
        },
    },
    {
        id   = "jewelcrafting",
        name = "Jewelcrafting 1-100",
        skill = "Jewelcrafting",
        notes = "Top-end recipes drop from world content; AH availability varies for rare gems.",
        mats = {
            { 180, "Crystalline Glass" },
            {  65, "Refulgent Copper Ore" },
            {  31, "Glimmering Gemdust" },
            {   7, "Duskshrouded Stone" },
            {   5, "Umbral Tin Ore" },
            {   5, "Sanguine Garnet" },
            {   4, "Tenebrous Amethyst" },
            {   4, "Harandar Peridot" },
            {   4, "Amani Lapis" },
            {   1, "Flawless Sanguine Garnet" },
            {   1, "Flawless Tenebrous Amethyst" },
            {   1, "Flawless Harandar Peridot" },
            {   1, "Flawless Amani Lapis" },
        },
    },
    {
        id   = "blacksmithing",
        name = "Blacksmithing 1-100",
        skill = "Blacksmithing",
        notes = "70-100 varies based on specialization. Mining is a great companion gathering profession.",
        mats = {
            { 306, "Brilliant Silver Ore" },
            { 250, "Refulgent Copper Ingot" },
            { 200, "Luminant Flux" },
            { 125, "Refulgent Copper Ore" },
            {   6, "Umbral Tin Ore" },
            {   1, "Duskshrouded Stone" },
        },
    },
    {
        id   = "tailoring",
        name = "Tailoring 1-100",
        skill = "Tailoring",
        notes = "65-90 uses Sunfire Silk Lining (or swap in 168 Arcanoweave + 56 Arcanoweave Bolt for the Arcanoweave lining -- pick one, not both). Cloth drops from humanoid mobs.",
        -- The 2026-05 scrape added up BOTH alternative 65-90 linings, doubling the buy.
        mats = {
            { 168, "Sunfire Silk" },
            { 163, "Sunfire Silk Bolt" },
            {  74, "Eversinging Dust" },
            {  67, "Mote of Light" },
            {  66, "Bright Linen" },
            {  60, "Imbued Bright Linen Bolt" },
            {  40, "Radiant Shard" },
        },
    },
    {
        id   = "leatherworking",
        name = "Leatherworking 1-100",
        skill = "Leatherworking",
        notes = "Skinning is the natural gathering pair. Most mats farmed off mobs.",
        mats = {
            { 690, "Void-Tempered Leather" },
            { 610, "Void-Tempered Scales" },
            {  75, "Silverleaf Thread" },
            {  10, "Tranquility Bloom" },
            {   4, "Mote of Light" },
            {   4, "Peerless Plumage" },
            {   4, "Fantastic Fur" },
            {   3, "Void-Tempered Hide" },
            {   3, "Carving Canine" },
            {   2, "Void-Tempered Plating" },
            {   1, "Mote of Pure Void" },
        },
    },
    {
        id   = "engineering",
        name = "Engineering 1-100",
        skill = "Engineering",
        notes = "Mining synergizes well. Some mats only obtainable from quests/world drops.",
        mats = {
            { 700, "Thalassian Lumber" },
            { 335, "Pile of Junk" },
            { 155, "Umbral Tin Ore" },         -- was double-counted (295)
            { 145, "Refulgent Copper Ore" },   -- was double-counted (275)
            { 135, "Powder Pigment" },
            { 100, "Evercore" },               -- +5 for the 16-25 first crafts the guide's list omits
            {  81, "Malleable Wireframe" },    -- 21 vendor + 60 Quel'dorei Guards
            {  70, "Song Gear" },
            {  70, "Soul Sprocket" },
            {  35, "Aetherlume" },
            {   1, "Mote of Light" },
            {   1, "Mote of Primal Energy" },
            {   1, "Mote of Wild Magic" },
            {   1, "Mote of Pure Void" },
        },
    },
    {
        id   = "inscription",
        name = "Inscription 1-100",
        skill = "Inscription",
        notes = "Herbalism is the natural gathering pair. Mill herbs for pigments to skip part of the AH cost.",
        mats = {
            { 360, "Tranquility Bloom" },
            { 100, "Argentleaf" },
            {  90, "Mana Lily" },
            {  90, "Sanguithorn" },
            {  65, "Azeroot" },
            {   7, "Mote of Wild Magic" },
            {   4, "Mote of Primal Energy" },
            {   4, "Mote of Pure Void" },
            {   1, "Duskshrouded Stone" },
            {   1, "Mote of Light" },
        },
    },
    {
        id   = "enchanting",
        name = "Enchanting 1-100",
        skill = "Enchanting",
        notes = "Covers 1-62 plus the Gleeful Glamours; 62-100 is Worldsoul Aegis from the trainer until it turns grey. Disenchant your own gear to skip most costs.",
        mats = {
            { 460, "Eversinging Dust" },        -- guide: ~412 (1-62) + 48 Glamours
            {  27, "Radiant Shard" },
            {  30, "Refulgent Copper Rod" },    -- vendor
            {  10, "Mote of Light" },
            {  10, "Mote of Wild Magic" },
            {   8, "Mote of Primal Energy" },
            {   2, "Mote of Pure Void" },
            {   1, "Sunglass Vial" },
        },
    },
}
