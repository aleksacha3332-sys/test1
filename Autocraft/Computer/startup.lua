-- ITERATION 10

local MONITOR_SIDE = "right"
local RECIPES_FILE     = "factory_recipes.json"
local CONFIG_FILE      = "factory_config.json"
local AUTOSTOCK_FILE   = "factory_autostock.json"
local GROUPS_FILE      = "factory_groups.json"
local ALT_RECIPES_FILE = "factory_alt_recipes.json"
local MGMT_FILE           = "factory_mgmt.json"
local MACHINE_LABELS_FILE = "factory_machine_labels.json"
local CUSTOM_MG_FILE      = "factory_custom_mg.json"
local FLUIDS_FILE         = "factory_fluids.json"
local FLUID_ALTS_FILE     = "factory_fluid_alts.json"
local ERROR_LOG_FILE      = "factory_error_log.json"
local ITEM_NAMES_FILE     = "factory_item_names.json"
local errorLog = {}
local errorLogPage = 1
local ItemDisplayNames = {}
local Recipes = {}
local Config = {
    storages = {},
    main_vaults = {},
    buffer = nil,
    fluid_tanks = {},
    train_box = nil,
    project_chest = nil,
    turtles = {},
    autostock_paused = false,
    paired_remotes = {}
}
local wirelessModemSide = nil
local pairingActiveUntil = 0
local remotePopup = false
local networkFilterPopup = false
local networkFilterPage = 1
local expandedGroups = {}
local remoteCraftQueue = {}

function ensureWirelessRednet()
    if wirelessModemSide and rednet.isOpen(wirelessModemSide) then
        return true
    end
    wirelessModemSide = nil

    if peripheral.find then
        local modem = peripheral.find("modem", function(name, m)
            if m.isWireless then return m.isWireless() end
            return (m.open ~= nil and m.transmit ~= nil)
        end)
        if modem then
            for _, name in ipairs(peripheral.getNames()) do
                if peripheral.wrap(name) == modem then
                    wirelessModemSide = name
                    pcall(rednet.open, name)
                    if rednet.isOpen(name) then return true end
                end
            end
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        local m = peripheral.wrap(name)
        if m and ((m.isWireless and m.isWireless()) or (m.open and m.transmit)) then
            wirelessModemSide = name
            pcall(rednet.open, name)
            if rednet.isOpen(name) then return true end
        end
    end
    return false
end
function makeItemKey(name, nbt)
    if not name or name == "" then return "" end
    if nbt and nbt ~= "" then
        return name .. "#" .. nbt
    end
    return name
end

function parseItemKey(key)
    if not key or key == "" then return "", nil end
    local hashIdx = key:find("#", 1, true)
    if hashIdx then
        return key:sub(1, hashIdx - 1), key:sub(hashIdx + 1)
    end
    return key, nil
end

function itemMatches(nameA, nameB)
    if not nameA or not nameB then return false end
    if nameA == nameB then return true end
    return parseItemKey(nameA) == parseItemKey(nameB)
end

function naturalSortCompare(a, b)
    local sA = tostring(a or ""):lower()
    local sB = tostring(b or ""):lower()
    if sA == sB then
        return tostring(a or "") < tostring(b or "")
    end
    local posA, posB = 1, 1
    local lenA, lenB = #sA, #sB
    while posA <= lenA and posB <= lenB do
        local isNumA = sA:sub(posA, posA):match("%d") ~= nil
        local isNumB = sB:sub(posB, posB):match("%d") ~= nil
        if isNumA and isNumB then
            local chunkA, endA = sA:match("^(%d+)()", posA)
            local chunkB, endB = sB:match("^(%d+)()", posB)
            local numA = tonumber(chunkA)
            local numB = tonumber(chunkB)
            if numA ~= numB then
                return numA < numB
            end
            if #chunkA ~= #chunkB then
                return #chunkA < #chunkB
            end
            posA = endA
            posB = endB
        elseif (not isNumA) and (not isNumB) then
            local chunkA, endA = sA:match("^([^%d]+)()", posA)
            local chunkB, endB = sB:match("^([^%d]+)()", posB)
            if chunkA ~= chunkB then
                return chunkA < chunkB
            end
            posA = endA
            posB = endB
        else
            return isNumA
        end
    end
    return lenA < lenB
end

function naturalSortDisplay(a, b)
    local dA = getMachineDisplay and getMachineDisplay(a) or a
    local dB = getMachineDisplay and getMachineDisplay(b) or b
    return naturalSortCompare(dA, dB)
end

local _itemNamesBatchDepth = 0
local _itemNamesDirty = false

function saveItemNames(forceNow)
    if _itemNamesBatchDepth > 0 and not forceNow then
        _itemNamesDirty = true
        return
    end
    _itemNamesDirty = false
    pcall(function()
        local f = fs.open(ITEM_NAMES_FILE, "w")
        if f then
            f.write(textutils.serializeJSON(ItemDisplayNames))
            f.close()
        end
    end)
end

function beginItemNamesBatch()
    _itemNamesBatchDepth = _itemNamesBatchDepth + 1
end

function endItemNamesBatch()
    _itemNamesBatchDepth = math.max(0, _itemNamesBatchDepth - 1)
    if _itemNamesBatchDepth == 0 and _itemNamesDirty then
        saveItemNames(true)
    end
end

local TECH_EFFECT_MAP = {
    ["regeneration"] = "regeneration",
    ["instant_health"] = "healing",
    ["healing"] = "healing",
    ["instant_damage"] = "harming",
    ["harming"] = "harming",
    ["speed"] = "speed",
    ["slowness"] = "slowness",
    ["strength"] = "strength",
    ["weakness"] = "weakness",
    ["invisibility"] = "invisibility",
    ["night_vision"] = "night_vision",
    ["fire_resistance"] = "fire_resistance",
    ["water_breathing"] = "water_breathing",
    ["poison"] = "poison",
    ["slow_falling"] = "slow_falling",
    ["leaping"] = "leaping",
    ["jump_boost"] = "leaping",
    ["luck"] = "luck",
    ["turtle_master"] = "turtle_master",
    ["weaving"] = "weaving",
    ["wind_charged"] = "wind_charged",
    ["oozing"] = "oozing",
    ["infested"] = "infested"
}

function cleanMinecraftString(str)
    if not str or type(str) ~= "string" then return "" end
    local s = str:gsub(string.char(194, 167) .. "[0-9a-fk-orA-FK-OR]", "")
    s = s:gsub(string.char(167) .. "[0-9a-fk-orA-FK-OR]", "")
    s = s:gsub(string.char(195, 151), "x"):gsub(string.char(215), "x")
    s = s:gsub(string.char(194, 160), " "):gsub(string.char(160), " ")
    s = s:match("^%s*(.-)%s*$") or s
    return s
end

local CYRILLIC_MAP = {
    [0x90]="a", [0x91]="b", [0x92]="v", [0x93]="g", [0x94]="d", [0x95]="e",
    [0x96]="zh", [0x97]="z", [0x98]="i", [0x99]="y", [0x9A]="k", [0x9B]="l",
    [0x9C]="m", [0x9D]="n", [0x9E]="o", [0x9F]="p", [0xA0]="r", [0xA1]="s",
    [0xA2]="t", [0xA3]="u", [0xA4]="f", [0xA5]="kh", [0xA6]="ts", [0xA7]="ch",
    [0xA8]="sh", [0xA9]="shch", [0xAA]="", [0xAB]="y", [0xAC]="", [0xAD]="e",
    [0xAE]="yu", [0xAF]="ya",
    [0xB0]="a", [0xB1]="b", [0xB2]="v", [0xB3]="g", [0xB4]="d", [0xB5]="e",
    [0xB6]="zh", [0xB7]="z", [0xB8]="i", [0xB9]="y", [0xBA]="k", [0xBB]="l",
    [0xBC]="m", [0xBD]="n", [0xBE]="o", [0xBF]="p",
    [0x81]="yo"
}
local CYRILLIC_D1_MAP = {
    [0x80]="r", [0x81]="s", [0x82]="t", [0x83]="u", [0x84]="f", [0x85]="kh",
    [0x86]="ts", [0x87]="ch", [0x88]="sh", [0x89]="shch", [0x8A]="", [0x8B]="y",
    [0x8C]="", [0x8D]="e", [0x8E]="yu", [0x8F]="ya",
    [0x91]="yo"
}

local function transliterateCyrillic(str)
    if not str or type(str) ~= "string" then return "" end
    local out = {}
    local i = 1
    local len = #str
    while i <= len do
        local b1 = str:byte(i)
        if b1 == 0xD0 and i < len then
            local b2 = str:byte(i + 1)
            local repl = CYRILLIC_MAP[b2]
            if repl ~= nil then
                table.insert(out, repl)
                i = i + 2
            else
                table.insert(out, string.char(b1))
                i = i + 1
            end
        elseif b1 == 0xD1 and i < len then
            local b2 = str:byte(i + 1)
            local repl = CYRILLIC_D1_MAP[b2]
            if repl ~= nil then
                table.insert(out, repl)
                i = i + 2
            else
                table.insert(out, string.char(b1))
                i = i + 1
            end
        else
            table.insert(out, string.char(b1))
            i = i + 1
        end
    end
    return table.concat(out)
end

function toTechnicalSnake(str)
    if not str or type(str) ~= "string" then return "" end
    local s = transliterateCyrillic(str):lower()
    s = s:gsub("[^%w_]+", "_")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", "")
    s = s:gsub("_+$", "")
    return s
end

local function formatTechEnchPart(ench)
    local enchName = ench.name or ench.id or ""
    local enchRaw = enchName:match(":(.+)$") or enchName
    local lvl = ench.level or 1
    if (enchRaw == "mending" or enchRaw == "infinity" or enchRaw == "silk_touch" or enchRaw == "channeling" or enchRaw == "flame") and lvl == 1 then
        return enchRaw
    end
    return enchRaw .. "_" .. tostring(lvl)
end

local function isValidDisplayName(str)
    return str and type(str) == "string" and not str:find("%?") and not str:find(string.char(167)) and #str > 0
end

local function migrateTechnicalName(v)
    if not v or type(v) ~= "string" then return v end
    if v:find("%[%+%d+%]") or v:find("%(%d+%)$") then return v end
    local s = toTechnicalSnake(v)
    s = s:gsub("^potion_of_", "potion_")
    if v:find("Book$") and not s:find("^book_") then
        s = s:gsub("_book$", "")
        s = "book_" .. s
    end
    s = s:gsub("_iii$", "_3"):gsub("_iii_", "_3_")
    s = s:gsub("_ii$", "_2"):gsub("_ii_", "_2_")
    s = s:gsub("_iv$", "_4"):gsub("_iv_", "_4_")
    s = s:gsub("_v$", "_5"):gsub("_v_", "_5_")
    s = s:gsub("_i$", "_1"):gsub("_i_", "_1_")
    if s:find("turtle") and s:find("crafty") then
        s = "turtle_adv_crafty"
    end
    return s
end

function isGearOrToolId(baseName)
    if not baseName or baseName == "" then return false end
    if isKnownToolItem and isKnownToolItem(baseName) then return true end
    local short = (baseName:match(":(.+)$") or baseName):lower()
    if short:find("_helmet$") or short:find("_chestplate$") or short:find("_leggings$") or short:find("_boots$")
       or short:find("elytra") or short:find("shield") or short:find("bow$") or short:find("crossbow")
       or short:find("trident") or short:find("fishing_rod") or short:find("mace$")
       or short:find("_cap$") or short:find("_tunic$") or short:find("_pants$") then
        return true
    end
    return false
end

function formatItemDetailName(det, itemKey)
    if not det then return nil end
    local baseName, nbtHash = parseItemKey(itemKey or det.name)
    local rawShort = baseName:match(":(.+)$") or baseName
    local rawDisplay = cleanMinecraftString(det.displayName)

    -- 1. Potions & Tipped Arrows (det.potionEffects)
    if det.potionEffects and #det.potionEffects > 0 then
        local eff = det.potionEffects[1]
        local effName = eff.name or eff.id or ""
        local rawEff = effName:match(":(.+)$") or effName
        local effDisp = TECH_EFFECT_MAP[rawEff] or toTechnicalSnake(rawEff)
        local potPrefix = "potion"
        if baseName == "minecraft:splash_potion" then
            potPrefix = "splash_potion"
        elseif baseName == "minecraft:lingering_potion" then
            potPrefix = "lingering_potion"
        elseif baseName == "minecraft:tipped_arrow" then
            potPrefix = "arrow"
        end
        local potency = eff.potency or 1
        if potency > 1 then
            return potPrefix .. "_" .. effDisp .. "_" .. tostring(potency)
        else
            return potPrefix .. "_" .. effDisp
        end
    end

    -- 2. ComputerCraft Turtles
    if baseName == "computercraft:turtle_advanced" or baseName == "computercraft:turtle_normal" then
        local isAdv = baseName == "computercraft:turtle_advanced"
        local prefix = isAdv and "turtle_adv" or "turtle"
        if rawDisplay and rawDisplay:find(":") then
            local suffix = rawDisplay:match(":%s*(.+)$") or ""
            local _, qCount = suffix:gsub("%?", "")
            local lowerSuf = suffix:lower()
            if qCount == 6 or lowerSuf:find("craft") then return prefix .. "_crafty" end
            if qCount == 10 or lowerSuf:find("mine") or lowerSuf:find("mining") then return prefix .. "_mining" end
            if qCount == 8 or lowerSuf:find("dig") or lowerSuf:find("digging") then return prefix .. "_digging" end
            if qCount == 7 or lowerSuf:find("chop") or lowerSuf:find("chopping") then return prefix .. "_chopping" end
            if qCount == 12 or lowerSuf:find("wire") or lowerSuf:find("wireless") then return prefix .. "_wireless" end
        end
        if nbtHash then
            return prefix .. "#" .. nbtHash:sub(1, 4)
        end
        return prefix
    end

    -- 3. Timeless and Classics Zero (TaCZ) / Ammo / Weapons / Attachments
    if baseName:find("^tacz:") or rawShort:find("ammo") or rawShort:find("bullet") or rawShort:find("gun") or rawShort:find("attachment") then
        local isAmmo = rawShort:find("ammo") or rawShort:find("bullet")
        if rawDisplay and #rawDisplay > 0 then
            if isAmmo then
                local cal = rawDisplay:match("(%d+%.?%d*x%d+%.?%d*)")
                if not cal then cal = rawDisplay:match("(%.%d+)") end
                if not cal then cal = rawDisplay:match("(%d+g[a]?)") end
                if not cal then cal = rawDisplay:match("(%d+%.?%d*mm)") end
                if cal then
                    local suffix = ""
                    if cal:find("x") and not cal:find("mm") then
                        suffix = "mm"
                    end
                    local cleanCal = toTechnicalSnake(cal .. suffix)
                    return "ammo_" .. cleanCal
                end
                local s = toTechnicalSnake(rawDisplay)
                if #s > 0 and not s:find("%?") and not s:match("^%d+$") then
                    return "ammo_" .. s:gsub("^ammo_", "")
                end
            else
                local s = toTechnicalSnake(rawDisplay)
                if #s > 0 and not s:find("%?") and not s:match("^%d+$") then
                    return s
                end
                -- Heuristics for Cyrillic weapons replaced with '?' by CC:Tweaked
                if rawDisplay:find("249") then return "m249" end
                if rawDisplay:find("%-7") or rawDisplay:find("%?7") then return "rpg_7" end
                if rawDisplay:find("%-47") or rawDisplay:find("%?47") then return "ak_47" end
                if rawDisplay:find("%-74") or rawDisplay:find("%?74") then return "ak_74" end
                if rawDisplay:find("%-12") or rawDisplay:find("%?12") then return "ak_12" end
                if rawDisplay:find("1911") then return "m1911" end
                if rawDisplay:find("870") then return "remington_870" end
                if rawDisplay:find("15") then return "ar_15" end
                if rawDisplay:find("90") then return "p90" end
                if rawDisplay:find("2000") then return "f2000" end
                if rawDisplay:find("50") then return "deagle_50" end
            end
        end
        -- If attachment, check itemGroups for category (e.g. tacz:extended_mag, tacz:scope)
        if rawShort:find("attachment") and det.itemGroups and det.itemGroups[1] and det.itemGroups[1].id then
            local grpId = det.itemGroups[1].id
            local grpShort = toTechnicalSnake(grpId:match(":(.+)$") or grpId)
            if #grpShort > 0 and not grpShort:find("%?") then
                return grpShort .. (nbtHash and ("#" .. nbtHash:sub(1, 4)) or "")
            end
        end
        if nbtHash then
            return rawShort .. "#" .. nbtHash:sub(1, 4)
        end
        return rawShort
    end

    -- 4. Tools, Weapons, Armor & Enchanted Items:
    -- Format: item_name[_first_enchant] [+X] (remaining_durability)
    local maxD = (det.maxDamage and det.maxDamage > 0) and det.maxDamage
        or (getToolDefaultDurability and getToolDefaultDurability(baseName))
        or nil
    local enchants = det.enchantments or det.storedEnchantments
    if (maxD and maxD > 0) or (enchants and #enchants > 0) or isGearOrToolId(baseName) then
        local resName = rawShort
        if enchants and #enchants > 0 then
            local p1 = formatTechEnchPart(enchants[1])
            local extra = ""
            if #enchants > 1 then
                extra = " [+" .. tostring(#enchants - 1) .. "]"
            end
            if baseName == "minecraft:enchanted_book" then
                resName = "book_" .. p1 .. extra
            else
                resName = rawShort .. "_" .. p1 .. extra
            end
        end
        if maxD and maxD > 0 and baseName ~= "minecraft:enchanted_book" then
            local dmg = (type(det.damage) == "number") and det.damage or 0
            local remDur = math.max(0, maxD - dmg)
            resName = resName .. " (" .. tostring(remDur) .. ")"
        end
        return resName
    end

    -- 5. Generic display name (English or Cyrillic transliterated)
    if rawDisplay and not rawDisplay:find("%?") and not rawDisplay:find(string.char(167)) and #rawDisplay > 0 then
        local s = toTechnicalSnake(rawDisplay)
        s = s:gsub("^potion_of_", "potion_")
        s = s:gsub("^splash_potion_of_", "splash_potion_")
        s = s:gsub("^lingering_potion_of_", "lingering_potion_")
        if s:find("_book$") and not s:find("^book_") then
            s = "book_" .. s:gsub("_book$", "")
        end
        if #s > 0 and not s:match("^%d+$") then
            return s
        end
    end

    -- 6. Final fallback: rawShort with hash
    if nbtHash then
        return rawShort .. "#" .. nbtHash:sub(1, 4)
    end
    return rawShort
end

function resolveItemDisplayName(pOrName, slot, itemKey)
    if not itemKey then return nil end
    if isValidDisplayName(ItemDisplayNames[itemKey]) then
        return ItemDisplayNames[itemKey]
    end
    local p = (type(pOrName) == "string") and peripheral.wrap(pOrName) or pOrName
    if p and p.getItemDetail then
        local ok, det = pcall(p.getItemDetail, slot)
        if ok and det then
            local formatted = formatItemDetailName(det, itemKey)
            if isValidDisplayName(formatted) then
                ItemDisplayNames[itemKey] = formatted
                saveItemNames()
                return formatted
            end
        end
    end
    return nil
end

function getItemDisplayName(key)
    if not key or key == "" then return "" end
    local cached = ItemDisplayNames[key]
    if isValidDisplayName(cached) then
        return cached
    end
    local baseName, nbtHash = parseItemKey(key)
    if nbtHash and StorageIndex and StorageIndex.byItem and StorageIndex.byItem[key] then
        local slots = StorageIndex.byItem[key].slots
        if slots and slots[1] and slots[1].vault and slots[1].slot then
            local resolved = resolveItemDisplayName(slots[1].vault, slots[1].slot, key)
            if isValidDisplayName(resolved) then
                return resolved
            end
        end
    end
    local short = baseName:match(":(.+)$") or baseName
    if nbtHash then
        return short .. "#" .. nbtHash:sub(1, 4)
    end
    return short
end

StorageIndex = {
    byItem = {},      -- [itemName] = { total = N, slots = { {vault=v, slot=s, count=c}, ... } }
    freeSlots = {},   -- [vaultName] = { [slot] = true, ... }
    itemHomes = {},   -- [itemName] = vaultName
    vaultStats = {},  -- [vaultName] = { used=N, max=N, free=N, pct=0.0 }
    itemMaxStacks = {
        ["minecraft:ender_pearl"] = 16,
        ["minecraft:egg"] = 16,
        ["minecraft:snowball"] = 16,
        ["minecraft:bucket"] = 16,
        ["minecraft:honey_bottle"] = 16,
        ["minecraft:sign"] = 16
    },
    totalItems = 0,
    uniqueTypes = 0,
    initialized = false,
    reconcileIdx = 1,
    isDefragging = false
}

function StorageIndex.getMaxStack(itemName, samplePeriph, sampleSlot)
    if not itemName then return 64 end
    if StorageIndex.itemMaxStacks[itemName] then
        return StorageIndex.itemMaxStacks[itemName]
    end
    if samplePeriph and sampleSlot and samplePeriph.getItemDetail then
        local ok, det = pcall(samplePeriph.getItemDetail, sampleSlot)
        if ok and det and det.maxCount and det.maxCount > 0 then
            StorageIndex.itemMaxStacks[itemName] = det.maxCount
            return det.maxCount
        end
    end
    local baseName = parseItemKey(itemName)
    -- Heuristics for tools, armor, potions and 16-stack items
    if baseName:match("_sword$") or baseName:match("_pickaxe$") or baseName:match("_axe$") or
       baseName:match("_shovel$") or baseName:match("_hoe$") or baseName:match("_helmet$") or
       baseName:match("_chestplate$") or baseName:match("_leggings$") or baseName:match("_boots$") or
       baseName:match(":potion$") or baseName:match(":splash_potion$") or baseName:match(":lingering_potion$") or
       baseName:match("_bucket$") or baseName:match("totem_of_undying") or baseName:match("enchanted_book") then
        StorageIndex.itemMaxStacks[itemName] = 1
        return 1
    end
    if baseName:match("_sign$") or baseName:match("_banner$") or baseName:match("ender_pearl") or
       baseName:match("snowball") or baseName:match(":egg$") then
        StorageIndex.itemMaxStacks[itemName] = 16
        return 16
    end
    return 64
end
local FluidRecipes = {}
local FluidAltRecipes = {}
local FluidStock   = {}
local Autostock = {}
local ExcludedMachines = {}
local AltRecipes  = {}
local MgmtGroups     = {}
local MachineLabels       = {}
local CustomMachineGroups = {}
local ITEM_GROUPS = {
["minecraft:oak_planks"] = "planks", ["minecraft:spruce_planks"] = "planks",
["minecraft:birch_planks"] = "planks", ["minecraft:jungle_planks"] = "planks",
["minecraft:acacia_planks"] = "planks", ["minecraft:dark_oak_planks"] = "planks",
["minecraft:mangrove_planks"] = "planks", ["minecraft:cherry_planks"] = "planks",
["minecraft:bamboo_planks"] = "planks",
["minecraft:oak_slab"] = "slabs", ["minecraft:spruce_slab"] = "slabs",
["minecraft:birch_slab"] = "slabs", ["minecraft:jungle_slab"] = "slabs",
["minecraft:acacia_slab"] = "slabs", ["minecraft:dark_oak_slab"] = "slabs",
["minecraft:mangrove_slab"] = "slabs", ["minecraft:cherry_slab"] = "slabs",
["minecraft:bamboo_slab"] = "slabs",
["minecraft:oak_log"] = "logs", ["minecraft:spruce_log"] = "logs",
["minecraft:birch_log"] = "logs", ["minecraft:jungle_log"] = "logs",
["minecraft:acacia_log"] = "logs", ["minecraft:dark_oak_log"] = "logs",
["minecraft:mangrove_log"] = "logs", ["minecraft:cherry_log"] = "logs",
["minecraft:stripped_oak_log"] = "stripped_logs", ["minecraft:stripped_spruce_log"] = "stripped_logs",
["minecraft:stripped_birch_log"] = "stripped_logs", ["minecraft:stripped_jungle_log"] = "stripped_logs",
["minecraft:stripped_acacia_log"] = "stripped_logs", ["minecraft:stripped_dark_oak_log"] = "stripped_logs",
["minecraft:stripped_mangrove_log"] = "stripped_logs", ["minecraft:stripped_cherry_log"] = "stripped_logs"
}
local GROUPS = {
planks = {
"minecraft:oak_planks", "minecraft:spruce_planks", "minecraft:birch_planks",
"minecraft:jungle_planks", "minecraft:acacia_planks", "minecraft:dark_oak_planks",
"minecraft:mangrove_planks", "minecraft:cherry_planks", "minecraft:bamboo_planks"
},
slabs = {
"minecraft:oak_slab", "minecraft:spruce_slab", "minecraft:birch_slab",
"minecraft:jungle_slab", "minecraft:acacia_slab", "minecraft:dark_oak_slab",
"minecraft:mangrove_slab", "minecraft:cherry_slab", "minecraft:bamboo_slab"
},
logs = {
"minecraft:oak_log", "minecraft:spruce_log", "minecraft:birch_log",
"minecraft:jungle_log", "minecraft:acacia_log", "minecraft:dark_oak_log",
"minecraft:mangrove_log", "minecraft:cherry_log"
},
stripped_logs = {
"minecraft:stripped_oak_log", "minecraft:stripped_spruce_log", "minecraft:stripped_birch_log",
"minecraft:stripped_jungle_log", "minecraft:stripped_acacia_log", "minecraft:stripped_dark_oak_log",
"minecraft:stripped_mangrove_log", "minecraft:stripped_cherry_log"
}
}
local WOOD_SPECIES = {
    "oak", "spruce", "birch", "jungle", "acacia", "dark_oak",
    "mangrove", "cherry", "bamboo", "crimson", "warped"
}
local function isWoodSpecificItem(itemName)
    if not itemName or itemName == "" then return false end
    local bKey = parseItemKey(itemName)
    if ITEM_GROUPS[bKey] then return true end
    local short = bKey:match(":(.+)$") or bKey
    for _, sp in ipairs(WOOD_SPECIES) do
        if short:find("^" .. sp .. "_") or short:find("_" .. sp .. "_") or short:find("_" .. sp .. "$") then
            return true
        end
    end
    return false
end
local function itemMatchesOrGroup(actualName, targetKey, allowSub)
    if itemMatches(actualName, targetKey) then return true end
    if allowSub and actualName and targetKey then
        local bAct = parseItemKey(actualName)
        local bTgt = parseItemKey(targetKey)
        local g = ITEM_GROUPS[bTgt]
        if g and ITEM_GROUPS[bAct] == g then return true end
    end
    return false
end
currentTab = "RECIPES"
currentModFilter = "All"
searchFilter = ""
uiMessage = ""
uiMsgTimer = nil
errorClearTimer = nil
craftErrorLines = {}; craftErrorTitle = nil
craftErrorEditItems = {}
autostockCooldowns = {}

function saveErrorLog()
    pcall(function()
        _savedCounts[ERROR_LOG_FILE] = 0
        local f = fs.open(ERROR_LOG_FILE, "w")
        if f then
            f.write(textutils.serializeJSON(errorLog))
            f.close()
        end
        if #errorLog == 0 then
            pcall(fs.delete, ERROR_LOG_FILE .. ".bak")
        else
            local fb = fs.open(ERROR_LOG_FILE .. ".bak", "w")
            if fb then
                fb.write(textutils.serializeJSON(errorLog))
                fb.close()
            end
        end
    end)
end

function logCraftError(title, lines)
    local timeStr = "00:00:00"
    local okD, dRes = pcall(function() return os.date("%H:%M:%S") end)
    if okD and type(dRes) == "string" and #dRes > 0 then
        timeStr = dRes
    else
        local okT, tRes = pcall(function() return textutils.formatTime(os.time(), true) end)
        if okT and type(tRes) == "string" and #tRes > 0 then
            timeStr = tRes
        end
    end

    local entryLines = {}
    if type(lines) == "table" then
        for _, l in ipairs(lines) do
            table.insert(entryLines, tostring(l))
        end
    elseif lines then
        table.insert(entryLines, tostring(lines))
    end

    local errTitle = title or "! ERROR"

    if #errorLog > 0 and errorLog[1].title == errTitle and #errorLog[1].lines == #entryLines then
        local match = true
        for idx, l in ipairs(entryLines) do
            if errorLog[1].lines[idx] ~= l then
                match = false
                break
            end
        end
        if match then
            errorLog[1].time = timeStr
            saveErrorLog()
            return
        end
    end

    local entry = {
        time = timeStr,
        title = errTitle,
        lines = entryLines
    }
    table.insert(errorLog, 1, entry)
    while #errorLog > 10 do
        table.remove(errorLog)
    end
    saveErrorLog()
end

function clearCraftError()
    if errorClearTimer then os.cancelTimer(errorClearTimer); errorClearTimer = nil end
    craftErrorLines = {}
    craftErrorTitle = nil
    craftErrorEditItems = {}
end

function triggerCraftError(title, lines, timeoutSec)
    craftErrorTitle = title or "! NOT ENOUGH RESOURCES"
    craftErrorLines = lines or {}
    logCraftError(craftErrorTitle, craftErrorLines)
    if errorClearTimer then os.cancelTimer(errorClearTimer); errorClearTimer = nil end
    timeoutSec = timeoutSec or 10
    if timeoutSec > 0 then
        errorClearTimer = os.startTimer(timeoutSec)
    end
end
craftQueue = {}
craftQueuePopup = false
craftQueueErrIdx = nil
craftQueueScroll = 0
queueEditIdx = nil
ntfyLastId = nil
craftStageDone = 0
craftStageTotal = 0
selectedCraftType = "turtle"
systemStatus = "IDLE"
altViewItem   = nil
altViewFluid  = nil
learnAsAlt    = false
learnAsAltItem = nil
vaultOpPopup = nil
currentPage = 1
modFilterPage = 1
fluidSubTab = "FLUID"
fluidTankPage = 1
fluidRecipePage = 1
fluidCraftMsg = ""
fluidCraftWaitFluid = nil
fluidRecipePicker = nil
pendingDeleteFluid = nil
fluidKeepName = nil
fluidKeepFilter = "All"
keepThr = 0
keepTgt = 0
keepField = "threshold"
fluidSearchFilter = ""
fluidCraftMode = nil
fluidGoalLabel = ""
fluidStepNum = 0
fluidStepTotal = 1
fluidSubLabel = ""
fluidScanResults = {}
_fpCache = {}
craftSubTab = "TURTLE"
craftDevicePage = 1
selectedOutputDevice = nil
outputPickMode = false
pendingTouches = {}
cancelCrafting = false
craftCleanupMachines = {}
craftLocks = {}
displayCtx = nil
fluidTankClaims = 0
_fluidStoreBusy = false
fluidInlineByCo = {}
craftUsedMachines = {}
function lockOwnerId()
return coroutine.running() or "main"
end
function tryAcquireTokens(tokens)
local me = lockOwnerId()
for _, t in ipairs(tokens) do
local l = craftLocks[t]
if l and l.owner ~= me then return false end
end
for _, t in ipairs(tokens) do
local l = craftLocks[t]
if l then l.count = l.count + 1
else craftLocks[t] = { owner = me, count = 1 } end
end
return true
end
function releaseTokens(tokens)
local me = lockOwnerId()
for _, t in ipairs(tokens) do
local l = craftLocks[t]
if l and l.owner == me then
l.count = l.count - 1
if l.count <= 0 then craftLocks[t] = nil end
end
end
end
craftCancelY  = nil
craftCancelX1 = 2
craftCancelX2 = 20
finishTestEarly = false
craftFinishX1 = nil
craftFinishX2 = nil
pendingDeleteItem    = nil
autostockCurrentItem = ""
idleTimer = nil
autostockIdleSecs = 180
isRequestMode = false
requestMaxQty = 0
pickerMaxCraftable = 0
pickerMaxCapped = false
pickerMaxComputed = true
pickerHeaderSnap = nil
calcNodes = 0
calcBudget = 0
CALC_BUDGET = 100
qtyOriginTab = "RECIPES"
craftCompletePopup = nil
stockSearchFilter  = ""
stockModFilter     = "All"
stockModFilterPage = 1
unloadActive      = false
unloadTimer       = nil
searchInputActive      = false
stockSearchInputActive = false
recipesScanResults = {}
craftInfoPopup     = nil
machineInfoPopup   = nil
qtyTypeActive      = false
craftHistory       = {}
historyPopup       = nil
scanActive         = false
scanTimer          = nil
recipeEditPopup    = nil
mgmtItemSearch       = ""
mgmtItemSearchActive = false
itemToCraft = ""
craftQuantity = 1
isSettingKeepLimit = false
learningState = "IDLE"
learnedResult = nil
learnedIngredients = nil
learnedTools = nil
learnedCraftType = ""
learnedMachineName = ""
learnedOutputDevice = nil
compositeDraft = {
    baseSource = "barrel",
    targetPlatform = nil,
    outputPlatform = nil,
    mode = "normal",
    baseItem = nil,
    baseCount = 1,
    baseIngredients = {},
    actions = {},
    actPage = 1,
    results = {},
    resPage = 1,
    testDone = false,
    editingItem = nil,
    editingAltIdx = nil
}
compositePopup = nil
checkTimer = nil
mgmtPage      = 1
mgmtPopup     = nil
custGrpPopup  = nil
mgmtSyncInfo      = ""
mgmtTickCount     = 0
mgmtActiveBtn     = nil
mgmtSyncFlashTime = nil
local monitor = peripheral.wrap(MONITOR_SIDE)
if not monitor then error("Monitor not found on side: " .. MONITOR_SIDE) end
monitor.setTextScale(0.5)
local SYSTEM_SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
function parseJSON(str)
local result = textutils.unserializeJSON(str)
if result == textutils.empty_json_array then return {} end
return result
end
_savedCounts = {}
dataRestoredFromBak = false
function loadDataFile(path)
if not fs.exists(path) then return nil end
local fh = fs.open(path, "r")
if not fh then return nil end
local raw = fh.readAll() or ""
fh.close()
local parsed = parseJSON(raw)
local bak = path .. ".bak"
if type(parsed) == "table" and (next(parsed) ~= nil or path == ERROR_LOG_FILE) then
local n = 0
for _ in pairs(parsed) do n = n + 1 end
_savedCounts[path] = n
if fs.exists(bak) and fs.getSize(bak) == 0 then pcall(fs.delete, bak) end
if not fs.exists(bak) then
local free = fs.getFreeSpace("/") or 0
if free > #raw + 4096 then
local bh = fs.open(bak, "w")
if bh then bh.write(raw); bh.close() end
end
end
return parsed
end
if #raw > 2 and parsed == nil then
pcall(fs.delete, path .. ".corrupt")
pcall(fs.copy, path, path .. ".corrupt")
end
if fs.exists(bak) then
local bh = fs.open(bak, "r")
if bh then
local bp = parseJSON(bh.readAll() or "")
bh.close()
if type(bp) == "table" and next(bp) ~= nil then
local n = 0
for _ in pairs(bp) do n = n + 1 end
_savedCounts[path] = n
dataRestoredFromBak = true
return bp
end
end
end
if type(parsed) == "table" then _savedCounts[path] = 0 end
return parsed
end
function findDuplicateRecipe(outName, cand)
local function sig(r)
if type(r) ~= "table" or r.type == "fluid" then return nil end
local parts = {}
local nIngs = math.max(9, #(r.ingredients or {}))
for i = 1, nIngs do parts[i] = tostring(r.ingredients and r.ingredients[i] or "nil") end
if r.type ~= "turtle" then table.sort(parts) end
return tostring(r.type) .. "|" .. tostring(r.machine_name) .. "|" .. tostring(r.output_device or "") .. "|" .. table.concat(parts, ",")
end
local target = sig(cand)
if not target then return false end
local ex = Recipes[outName]
if ex and sig(ex) == target then return true end
for _, alt in ipairs(AltRecipes[outName] or {}) do
if sig(alt) == target then return true end
end
return false
end
function initDataFiles()
local defaults = {
{ RECIPES_FILE,        "{}"  },
{ CONFIG_FILE,          textutils.serializeJSON({storages={}, main_vaults={}, buffer=nil, turtles={}, autostock_paused=false}) },
{ AUTOSTOCK_FILE,      "{}"  },
{ GROUPS_FILE,         "{}"  },
{ ALT_RECIPES_FILE,    "{}"  },
{ MGMT_FILE,           "[]"  },
{ MACHINE_LABELS_FILE, "{}"  },
{ CUSTOM_MG_FILE,      "[]"  },
{ FLUIDS_FILE,         "{}"  },
{ FLUID_ALTS_FILE,     "{}"  },
}
for _, entry in ipairs(defaults) do
local path, data = entry[1], entry[2]
if not fs.exists(path) then
local fh = fs.open(path, "w")
if fh then fh.write(data); fh.close() end
end
end
end
function loadData()
if fs.exists(RECIPES_FILE) then
local raw = loadDataFile(RECIPES_FILE) or {}
if raw.recipes and type(raw.recipes) == "table" then
Recipes = raw.recipes
if raw.alt_recipes    and type(raw.alt_recipes)    == "table" then AltRecipes    = raw.alt_recipes    end
if raw.machine_labels and type(raw.machine_labels) == "table" then MachineLabels = raw.machine_labels end
local fMigrate = fs.open(RECIPES_FILE, "w")
if fMigrate then fMigrate.write(textutils.serializeJSON(Recipes)); fMigrate.close() end
else
Recipes = raw
end
end
if fs.exists(CONFIG_FILE) then
Config = loadDataFile(CONFIG_FILE) or {storages={}, train_box=nil, turtles={}, autostock_paused=false}
end
if not Config.main_vaults then Config.main_vaults = {} end
if not Config.storages then Config.storages = {} end
if not Config.fluid_tanks then Config.fluid_tanks = {} end
if not Config.turtles then Config.turtles = {} end
if Config.turtle and Config.turtle ~= "" then
Config.turtles[Config.turtle] = true
Config.turtle = nil
end
if fs.exists(FLUIDS_FILE) then
FluidRecipes = loadDataFile(FLUIDS_FILE) or {}
end
if fs.exists(FLUID_ALTS_FILE) then
FluidAltRecipes = loadDataFile(FLUID_ALTS_FILE) or {}
end
if fs.exists(AUTOSTOCK_FILE) then
Autostock = loadDataFile(AUTOSTOCK_FILE) or {}
end
if fs.exists(GROUPS_FILE) then
local raw = loadDataFile(GROUPS_FILE) or {}
ExcludedMachines = {}
for k, v in pairs(raw) do
if type(k) == "string" and type(v) == "boolean" then
ExcludedMachines[k] = v
end
end
end
if fs.exists(ALT_RECIPES_FILE) then
AltRecipes = loadDataFile(ALT_RECIPES_FILE) or {}
end
if fs.exists(MGMT_FILE) then
MgmtGroups = loadDataFile(MGMT_FILE) or {}
end
if fs.exists(MACHINE_LABELS_FILE) then
MachineLabels = loadDataFile(MACHINE_LABELS_FILE) or {}
end
if fs.exists(CUSTOM_MG_FILE) then
local raw2 = loadDataFile(CUSTOM_MG_FILE) or {}
if type(raw2) == "table" then CustomMachineGroups = raw2 end
end
if fs.exists(ERROR_LOG_FILE) then
    errorLog = loadDataFile(ERROR_LOG_FILE) or {}
end
if fs.exists(ITEM_NAMES_FILE) then
    ItemDisplayNames = loadDataFile(ITEM_NAMES_FILE) or {}
    local changed = false
    for k, v in pairs(ItemDisplayNames) do
        local baseK, nbtK = parseItemKey(k)
        if not isValidDisplayName(v) or (type(v) == "string" and (v:match("^%d+$") or v:find("^modern_kinetic_gun") or v:find("^attachment") or v:find("#"))) then
            ItemDisplayNames[k] = nil
            changed = true
        elseif nbtK and isGearOrToolId(baseK) and type(v) == "string" and not v:find("%(%d+%)$") then
            ItemDisplayNames[k] = nil
            changed = true
        elseif type(v) == "string" and (v:find("%s") or v:find("%u")) and not v:find("%(%d+%)$") and not v:find("%[%+%d+%]") then
            local migrated = migrateTechnicalName(v)
            if migrated and migrated ~= v then
                ItemDisplayNames[k] = migrated
                changed = true
            end
        end
    end
    if changed then saveItemNames() end
end
end
function syncFluidItemStubs()
local itemSrc = {}
for key, rec in pairs(FluidRecipes) do
for _, o in ipairs(rec.item_outputs or {}) do
if not itemSrc[o.name] then itemSrc[o.name] = {count = o.count, key = key, machine = rec.machine_name} end
end
end
for key, alts in pairs(FluidAltRecipes) do
for _, rec in ipairs(alts) do
for _, o in ipairs(rec.item_outputs or {}) do
if not itemSrc[o.name] then itemSrc[o.name] = {count = o.count, key = key, machine = rec.machine_name} end
end
end
end
for itemName, rec in pairs(Recipes) do
if type(rec) == "table" and rec.type == "fluid" and not itemSrc[itemName] then
Recipes[itemName] = nil
end
end
for itemName, src in pairs(itemSrc) do
local existing = Recipes[itemName]
if not existing or (type(existing) == "table" and existing.type == "fluid") then
Recipes[itemName] = {
type = "fluid",
fluid_key = src.key,
machine_name = src.machine,
output_count = src.count,
ingredients = {"nil","nil","nil","nil","nil","nil","nil","nil","nil"},
}
end
end
end
function saveData()
if _fpCache then for k in pairs(_fpCache) do _fpCache[k] = nil end end
local failNote = nil
local function writeFile(path, tbl)
local n = 0
for _ in pairs(tbl) do n = n + 1 end
local prev = _savedCounts[path]
if path ~= ERROR_LOG_FILE and prev and prev >= 5 and n < prev * 0.5 then
failNote = "SAVE BLOCKED: " .. fs.getName(path) .. " " .. prev .. "->" .. n
return
end
local okS, data = pcall(textutils.serializeJSON, tbl)
if not (okS and type(data) == "string") then
failNote = "SERIALIZE FAIL: " .. fs.getName(path)
return
end
local tmp = path .. ".new"
local function tryWrite()
local okT = pcall(function()
local fh = fs.open(tmp, "w")
if not fh then error("open") end
fh.write(data)
fh.close()
end)
return okT and fs.exists(tmp) and fs.getSize(tmp) >= #data
end
local okW = tryWrite()
if not okW then
pcall(fs.delete, tmp)
pcall(fs.delete, path .. ".bak")
okW = tryWrite()
end
if not okW then
pcall(fs.delete, tmp)
failNote = "SAVE FAIL (disk space?): " .. fs.getName(path)
return
end
fs.delete(path)
fs.move(tmp, path)
local free = fs.getFreeSpace("/") or 0
if free > fs.getSize(path) + 4096 then
pcall(fs.delete, path .. ".bak")
pcall(fs.copy, path, path .. ".bak")
end
_savedCounts[path] = n
end
local recipesToSave = {}
for k, v in pairs(Recipes) do
if not (type(v) == "table" and v.type == "fluid") then recipesToSave[k] = v end
end
writeFile(RECIPES_FILE, recipesToSave)
local configToSave = {}
for k, v in pairs(Config) do configToSave[k] = v end
writeFile(CONFIG_FILE, configToSave)
writeFile(AUTOSTOCK_FILE,      Autostock)
writeFile(GROUPS_FILE,         ExcludedMachines)
writeFile(ALT_RECIPES_FILE,    AltRecipes)
writeFile(MGMT_FILE,           MgmtGroups)
writeFile(MACHINE_LABELS_FILE, MachineLabels)
writeFile(CUSTOM_MG_FILE,      CustomMachineGroups)
writeFile(FLUIDS_FILE,         FluidRecipes)
writeFile(FLUID_ALTS_FILE,     FluidAltRecipes)
writeFile(ERROR_LOG_FILE,      errorLog)
writeFile(ITEM_NAMES_FILE,     ItemDisplayNames)
if failNote then
uiMessage = failNote
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(6)
end
end
function providerSources()
local out, seen = {}, {}
for _, g in ipairs(MgmtGroups or {}) do
if g.provider and not g.paused then
for _, src in ipairs(mgmtIOList(g, true)) do
if src and src ~= "" and src ~= "STORAGE"
and not Config.storages[src]
and not (Config.fluid_tanks and Config.fluid_tanks[src])
and not seen[src] then
seen[src] = true
out[#out + 1] = src
end
end
end
end
return out
end
function batchPeripheralScan(names, method, withSize)
local out = {}
if #names == 0 then return out end
while _batchScanBusy do sleep(0.05) end
_batchScanBusy = true
local i = 1
while i <= #names do
local hi = math.min(i + 63, #names)
local tasks = {}
for j = i, hi do
local nm = names[j]
tasks[#tasks + 1] = function()
local p = peripheral.wrap(nm)
if p and p[method] then
local e = {}
local ok, res = pcall(p[method])
if ok then e.data = res end
if withSize and p.size then
local ok2, sz = pcall(p.size)
if ok2 then e.size = sz end
end
out[nm] = e
end
end
end
local okAll, errAll = pcall(parallel.waitForAll, table.unpack(tasks))
if not okAll then
_batchScanBusy = false
error(errAll, 0)
end
i = hi + 1
end
_batchScanBusy = false
return out
end
-- ==========================================
-- STORAGE INDEX & BUFFER INGESTION CORE
-- ==========================================

function StorageIndex.rebuildVault(vName, items, size)
    -- Clear old slot mappings for this vault
    for itemName, data in pairs(StorageIndex.byItem) do
        local newSlots = {}
        for _, entry in ipairs(data.slots) do
            if entry.vault ~= vName then
                table.insert(newSlots, entry)
            end
        end
        data.slots = newSlots
    end

    StorageIndex.freeSlots[vName] = {}
    local usedCount = 0
    local occupied = {}

    if items then
        beginItemNamesBatch()
        for slot, item in pairs(items) do
            if item and item.name and item.count and item.count > 0 then
                occupied[slot] = true
                usedCount = usedCount + 1
                
                local itemKey = makeItemKey(item.name, item.nbt)
                if item.nbt and item.nbt ~= "" and not isValidDisplayName(ItemDisplayNames[itemKey]) then
                    resolveItemDisplayName(vName, slot, itemKey)
                end

                if not StorageIndex.byItem[itemKey] then
                    StorageIndex.byItem[itemKey] = { total = 0, slots = {} }
                end
                table.insert(StorageIndex.byItem[itemKey].slots, {
                    vault = vName,
                    slot = slot,
                    count = item.count
                })
            end
        end
        endItemNamesBatch()
    end

    local maxS = size or 0
    for s = 1, maxS do
        if not occupied[s] then
            StorageIndex.freeSlots[vName][s] = true
        end
    end

    local freeCount = math.max(0, maxS - usedCount)
    local pct = (maxS > 0) and (usedCount / maxS) or 0
    StorageIndex.vaultStats[vName] = { used = usedCount, max = maxS, free = freeCount, pct = pct }

    -- Recalculate totals across storage
    local totItems, uniqTypes = 0, 0
    for itemName, data in pairs(StorageIndex.byItem) do
        local sum = 0
        for _, sl in ipairs(data.slots) do sum = sum + sl.count end
        data.total = sum
        if sum > 0 then
            uniqTypes = uniqTypes + 1
            totItems = totItems + sum
        end
    end
    StorageIndex.totalItems = totItems
    StorageIndex.uniqueTypes = uniqTypes
end

function StorageIndex.deduct(vName, slot, itemName, count)
    local data = StorageIndex.byItem[itemName]
    if not data then return end

    for i = #data.slots, 1, -1 do
        local sl = data.slots[i]
        if sl.vault == vName and sl.slot == slot then
            local actualDeduct = math.min(sl.count, count)
            sl.count = sl.count - actualDeduct
            data.total = math.max(0, data.total - actualDeduct)
            StorageIndex.totalItems = math.max(0, StorageIndex.totalItems - actualDeduct)

            if sl.count <= 0 then
                table.remove(data.slots, i)
                if StorageIndex.freeSlots[vName] then
                    StorageIndex.freeSlots[vName][slot] = true
                end
                local st = StorageIndex.vaultStats[vName]
                if st then
                    st.used = math.max(0, st.used - 1)
                    st.free = math.max(0, st.max - st.used)
                    st.pct = (st.max > 0) and (st.used / st.max) or 0
                end
            end
            break
        end
    end
end

function StorageIndex.add(vName, slot, itemName, count)
    if count <= 0 then return end
    if not StorageIndex.byItem[itemName] then
        StorageIndex.byItem[itemName] = { total = 0, slots = {} }
    end
    local data = StorageIndex.byItem[itemName]
    
    local found = false
    for _, sl in ipairs(data.slots) do
        if sl.vault == vName and sl.slot == slot then
            sl.count = sl.count + count
            found = true
            break
        end
    end

    if not found then
        table.insert(data.slots, { vault = vName, slot = slot, count = count })
        if StorageIndex.freeSlots[vName] then
            StorageIndex.freeSlots[vName][slot] = nil
        end
        local st = StorageIndex.vaultStats[vName]
        if st then
            st.used = st.used + 1
            st.free = math.max(0, st.max - st.used)
            st.pct = (st.max > 0) and (st.used / st.max) or 0
        end
    end

    data.total = data.total + count
    StorageIndex.totalItems = StorageIndex.totalItems + count
end

function StorageIndex.init(pruneOffline)
    local names = {}
    local pruned = {}
    for vName, en in pairs(Config.main_vaults or {}) do
        if en and not SYSTEM_SIDES[vName] then
            local p = peripheral.wrap(vName)
            if not p then
                if pruneOffline then
                    Config.main_vaults[vName] = nil
                    if StorageIndex.vaultStats then StorageIndex.vaultStats[vName] = nil end
                    table.insert(pruned, vName)
                end
            else
                table.insert(names, vName)
            end
        end
    end
    if pruneOffline then
        for sName, en in pairs(Config.storages or {}) do
            if en and not SYSTEM_SIDES[sName] then
                if not peripheral.wrap(sName) then
                    Config.storages[sName] = nil
                    table.insert(pruned, sName)
                end
            end
        end
        if #pruned > 0 then
            saveData()
        end
    end
    if #names == 0 then
        StorageIndex.initialized = true
        return pruned
    end

    local scanned = batchPeripheralScan(names, "list", true)
    for _, nm in ipairs(names) do
        local e = scanned[nm]
        if e and e.size and e.size > 0 then
            StorageIndex.rebuildVault(nm, e.data or {}, e.size or 0)
        elseif pruneOffline then
            local p = peripheral.wrap(nm)
            if not p or not p.size or not p.list then
                Config.main_vaults[nm] = nil
                if StorageIndex.vaultStats then StorageIndex.vaultStats[nm] = nil end
                table.insert(pruned, nm)
            end
        end
    end
    if pruneOffline and #pruned > 0 then
        saveData()
    end
    StorageIndex.initialized = true
    if invalidateStockCache then invalidateStockCache() end
    return pruned
end

function StorageIndex.getTargetSlotFor(targetVault, itemName, maxStack)
    maxStack = maxStack or StorageIndex.getMaxStack(itemName)
    local data = StorageIndex.byItem[itemName]
    -- 1. First look for incomplete existing stack in target vault
    if data and data.slots then
        for _, sl in ipairs(data.slots) do
            if sl.vault == targetVault and sl.count < maxStack then
                return sl.slot, (maxStack - sl.count)
            end
        end
    end
    -- 2. If no incomplete stacks - find first empty slot
    local freeMap = StorageIndex.freeSlots[targetVault]
    if freeMap then
        local firstFree = nil
        for s in pairs(freeMap) do
            if not firstFree or s < firstFree then
                firstFree = s
            end
        end
        if firstFree then
            return firstFree, maxStack
        end
    end
    return nil, 0
end

local function _ingestBufferInner()
    if not Config.buffer or Config.buffer == "" then return 0 end
    local buf = peripheral.wrap(Config.buffer)
    if not (buf and buf.list and buf.pushItems) then return 0 end

    local okL, bList = pcall(buf.list)
    if not (okL and bList and next(bList)) then return 0 end

    local activeMain = {}
    for vName, en in pairs(Config.main_vaults or {}) do
        if en and not SYSTEM_SIDES[vName] then
            table.insert(activeMain, vName)
        end
    end
    if #activeMain == 0 then return 0 end

    local itemsMoved = 0
    beginItemNamesBatch()
    for slot, item in pairs(bList) do
        if item and item.name and item.count and item.count > 0 then
            local itemKey = makeItemKey(item.name, item.nbt)
            if item.nbt and item.nbt ~= "" and not isValidDisplayName(ItemDisplayNames[itemKey]) then
                resolveItemDisplayName(Config.buffer, slot, itemKey)
            end
            local target = StorageIndex.itemHomes[itemKey]

            local st = target and StorageIndex.vaultStats[target]
            if not (target and Config.main_vaults[target] and st and st.free > 0) then
                target = nil
            end

            -- If home is not assigned, look for vault already containing this item
            if not target then
                local itemData = StorageIndex.byItem[itemKey]
                if itemData and itemData.slots and #itemData.slots > 0 then
                    for _, sl in ipairs(itemData.slots) do
                        local vst = StorageIndex.vaultStats[sl.vault]
                        if vst and vst.free > 0 and Config.main_vaults[sl.vault] then
                            target = sl.vault
                            StorageIndex.itemHomes[itemKey] = target
                            break
                        end
                    end
                end
            end

            -- If still none - choose least occupied vault
            if not target then
                local bestV = nil
                local minPct = 2.0
                for _, vName in ipairs(activeMain) do
                    local vst = StorageIndex.vaultStats[vName]
                    if vst and vst.max > 0 and (vst.free > 0 or next(StorageIndex.freeSlots[vName] or {})) then
                        local pct = vst.pct or (vst.used / vst.max)
                        if pct < minPct then
                            minPct = pct
                            bestV = vName
                        end
                    end
                end
                if bestV then
                    target = bestV
                    StorageIndex.itemHomes[itemKey] = target
                end
            end

            -- Perform strictly targeted transfer with slot protection
            if target then
                local maxStack = StorageIndex.getMaxStack(itemKey, buf, slot)
                local remaining = item.count
                local attempts = 0
                while remaining > 0 and attempts < 6 do
                    attempts = attempts + 1
                    local toSlot, space = StorageIndex.getTargetSlotFor(target, itemKey, maxStack)
                    if not toSlot or space <= 0 then break end
                    
                    local toPush = math.min(remaining, space)
                    local okP, mv = pcall(buf.pushItems, target, slot, toPush, toSlot)
                    if okP and type(mv) == "number" and mv > 0 then
                        StorageIndex.add(target, toSlot, itemKey, mv)
                        itemsMoved = itemsMoved + mv
                        remaining = remaining - mv
                        attempts = 0
                        if itemsMoved % 32 == 0 then sleep(0) end
                    else
                        -- Target slot was obstructed (player placed item / occupied)
                        -- Targeted self-healing: register actual item and find another slot
                        if StorageIndex.freeSlots[target] then
                            StorageIndex.freeSlots[target][toSlot] = nil
                        end
                        local tObj = peripheral.wrap(target)
                        if tObj and tObj.getItemDetail then
                            local okD, det = pcall(tObj.getItemDetail, toSlot)
                            if okD and det and det.name and det.count > 0 then
                                local detKey = makeItemKey(det.name, det.nbt)
                                local formatted = formatItemDetailName(det, detKey)
                                if isValidDisplayName(formatted) then
                                    ItemDisplayNames[detKey] = formatted
                                    saveItemNames()
                                end
                                StorageIndex.add(target, toSlot, detKey, det.count)
                            end
                        end
                    end
                end
            end
        end
    end
    endItemNamesBatch()

    if itemsMoved > 0 and invalidateStockCache then
        invalidateStockCache()
    end
    return itemsMoved
end

function StorageIndex.ingestBuffer()
    local waitTicks = 0
    while StorageIndex._ingestBusy and waitTicks < 40 do
        waitTicks = waitTicks + 1
        sleep(0.05)
    end
    if StorageIndex._ingestBusy then return 0 end
    StorageIndex._ingestBusy = true
    local okIng, resIng = pcall(_ingestBufferInner)
    StorageIndex._ingestBusy = false
    if okIng then return resIng or 0 end
    return 0
end

function StorageIndex.reconcileNext()
    local mainList = {}
    for vName, en in pairs(Config.main_vaults or {}) do
        if en and not SYSTEM_SIDES[vName] then
            table.insert(mainList, vName)
        end
    end
    if #mainList == 0 then return end
    if StorageIndex.reconcileIdx > #mainList then StorageIndex.reconcileIdx = 1 end
    local vName = mainList[StorageIndex.reconcileIdx]
    StorageIndex.reconcileIdx = StorageIndex.reconcileIdx + 1

    local v = peripheral.wrap(vName)
    if v and v.list and v.size then
        local okL, lst = pcall(v.list)
        local okS, sz = pcall(v.size)
        if okL and okS and lst and sz then
            StorageIndex.rebuildVault(vName, lst, sz)
        end
    end
end

function StorageIndex.defragment()
    StorageIndex.isDefragging = true
    
    -- 1. First flush buffer
    StorageIndex.ingestBuffer()

    -- 2. Count total stacks of each item in storage
    local itemTotals = {}
    for itemName, data in pairs(StorageIndex.byItem) do
        if data.total and data.total > 0 then
            itemTotals[itemName] = data.total
        end
    end

    local sortedItems = {}
    for n, c in pairs(itemTotals) do
        table.insert(sortedItems, { name = n, stacks = math.ceil(c / 64) })
    end
    table.sort(sortedItems, function(a, b) return a.stacks > b.stacks end)

    local activeMain = {}
    local simSlots = {}
    for vName, en in pairs(Config.main_vaults or {}) do
        if en and not SYSTEM_SIDES[vName] then
            table.insert(activeMain, vName)
            simSlots[vName] = 0
        end
    end
    if #activeMain == 0 then
        StorageIndex.isDefragging = false
        return 0
    end

    -- 3. Bin-Packing: balance item home allocation (itemHomes)
    StorageIndex.itemHomes = {}
    for _, item in ipairs(sortedItems) do
        local bestV = nil
        local minRatio = math.huge

        for _, vName in ipairs(activeMain) do
            local st = StorageIndex.vaultStats[vName]
            if st and st.max > 0 then
                if (simSlots[vName] + item.stacks) <= st.max then
                    local ratio = simSlots[vName] / st.max
                    if ratio < minRatio then
                        minRatio = ratio
                        bestV = vName
                    end
                end
            end
        end

        if not bestV then
            for _, vName in ipairs(activeMain) do
                local st = StorageIndex.vaultStats[vName]
                if st and st.max > 0 then
                    local ratio = simSlots[vName] / st.max
                    if ratio < minRatio then
                        minRatio = ratio
                        bestV = vName
                    end
                end
            end
        end

        if bestV then
            StorageIndex.itemHomes[item.name] = bestV
            simSlots[bestV] = simSlots[bestV] + item.stacks
        end
    end

    -- 4. Physically move items to designated homes (with timeout protection)
    local itemsMoved = 0
    for _, vName in ipairs(activeMain) do
        local p = peripheral.wrap(vName)
        if p and p.list and p.pushItems then
            local okL, vList = pcall(p.list)
            if okL and vList then
                for slot, it in pairs(vList) do
                    if it and it.name and it.count and it.count > 0 then
                        local itemKey = makeItemKey(it.name, it.nbt)
                        local home = StorageIndex.itemHomes[itemKey]
                        if home and home ~= vName and Config.main_vaults[home] then
                            local destStat = StorageIndex.vaultStats[home]
                            if destStat and destStat.free > 0 then
                                local maxStack = StorageIndex.getMaxStack(itemKey)
                                local toSlot, space = StorageIndex.getTargetSlotFor(home, itemKey, maxStack)
                                if toSlot and space > 0 then
                                    local toPush = math.min(it.count, space)
                                    local okP, mv = pcall(p.pushItems, home, slot, toPush, toSlot)
                                    if okP and type(mv) == "number" and mv > 0 then
                                        itemsMoved = itemsMoved + mv
                                        StorageIndex.deduct(vName, slot, itemKey, mv)
                                        StorageIndex.add(home, toSlot, itemKey, mv)
                                        if itemsMoved % 16 == 0 then sleep(0) end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 5. Final buffer flush and cache invalidation
    StorageIndex.ingestBuffer()
    StorageIndex.isDefragging = false
    if invalidateStockCache then invalidateStockCache() end
    return itemsMoved
end

function StorageIndex.clearRoles(p)
    if Config.buffer == p then Config.buffer = nil end
    if Config.main_vaults and Config.main_vaults[p] then
        Config.main_vaults[p] = nil
        StorageIndex.rebuildVault(p, {}, 0)
        StorageIndex.vaultStats[p] = nil
    end
    if Config.storages then Config.storages[p] = nil end
    if Config.train_box == p then Config.train_box = nil end
    if Config.project_chest == p then Config.project_chest = nil end
    if Config.turtles then Config.turtles[p] = nil end
    if Config.fluid_tanks then Config.fluid_tanks[p] = nil end
end

function getStorageInventory()
    local inventory = {}
    local totalItems, vaultsCount = 0, 0
    local totalSlots, usedSlots = 0, 0

    -- 1. Instantly retrieve all items and slots from StorageIndex (MAIN Vaults)
    for itemName, data in pairs(StorageIndex.byItem) do
        if data.total and data.total > 0 then
            inventory[itemName] = (inventory[itemName] or 0) + data.total
        end
    end
    totalItems = StorageIndex.totalItems or 0

    for vName, isEnabled in pairs(Config.main_vaults or {}) do
        if isEnabled and not SYSTEM_SIDES[vName] then
            vaultsCount = vaultsCount + 1
            local st = StorageIndex.vaultStats[vName]
            if st then
                totalSlots = totalSlots + (st.max or 0)
                usedSlots = usedSlots + (st.used or 0)
            end
        end
    end

    -- 2. Add auxiliary [VAULT] storages (if configured)
    local extraNames = {}
    for storageName, isEnabled in pairs(Config.storages or {}) do
        if isEnabled and not SYSTEM_SIDES[storageName] then
            table.insert(extraNames, storageName)
        end
    end

    if #extraNames > 0 then
        local scanned = batchPeripheralScan(extraNames, "list", true)
        for _, nm in ipairs(extraNames) do
            local e = scanned[nm]
            if e then
                vaultsCount = vaultsCount + 1
                if e.size then totalSlots = totalSlots + e.size end
                if e.data then
                    for slot, item in pairs(e.data) do
                        if item and item.name and item.count and item.count > 0 then
                            local itemKey = makeItemKey(item.name, item.nbt)
                            if item.nbt and item.nbt ~= "" and not isValidDisplayName(ItemDisplayNames[itemKey]) then
                                resolveItemDisplayName(nm, slot, itemKey)
                            end
                            inventory[itemKey] = (inventory[itemKey] or 0) + item.count
                            totalItems = totalItems + item.count
                            usedSlots = usedSlots + 1
                        end
                    end
                end
            end
        end
    end

    -- 3. Providers (external chests)
    local provNames = providerSources()
    if #provNames > 0 then
        local pScan = batchPeripheralScan(provNames, "list")
        for _, nm in ipairs(provNames) do
            local e = pScan[nm]
            if e and e.data then
                for slot, item in pairs(e.data) do
                    if item and item.name and item.count and item.count > 0 then
                        local itemKey = makeItemKey(item.name, item.nbt)
                        if item.nbt and item.nbt ~= "" and not isValidDisplayName(ItemDisplayNames[itemKey]) then
                            resolveItemDisplayName(nm, slot, itemKey)
                        end
                        inventory[itemKey] = (inventory[itemKey] or 0) + item.count
                    end
                end
            end
        end
    end

    local freeSlots = math.max(0, totalSlots - usedSlots)
    return inventory, totalItems, vaultsCount, freeSlots, totalSlots
end
local _flInvCache, _flInvCacheT = nil, -100
local _tankStatsCache, _tankStatsT = nil, -100
local _stInvCache, _stInvCacheT = nil, -100
function invalidateStockCache()
_flInvCacheT = -100
_tankStatsT = -100
_stInvCacheT = -100
recipesScanResults = {}
fluidScanResults = {}
autostockCooldowns = {}
end
function getStorageInventoryCached()
local now = os.clock()
if _stInvCache and (now - _stInvCacheT) < 4 then
local c = _stInvCache
return c[1], c[2], c[3], c[4], c[5]
end
local a, b, cc, d, e = getStorageInventory()
_stInvCache = {a, b, cc, d, e}
_stInvCacheT = now
return a, b, cc, d, e
end
function fluidKey(fluidName) return "f:" .. fluidName end
function fluidNameFromKey(key)
if type(key) == "string" and key:sub(1, 2) == "f:" then return key:sub(3) end
return key
end
function primaryRecipeKey(recipe)
if recipe.outputs and recipe.outputs[1] then return fluidKey(recipe.outputs[1].name) end
if recipe.item_outputs and recipe.item_outputs[1] then return "i:" .. recipe.item_outputs[1].name end
return nil
end
local pushFromStorage
local sleepCheckCancel
local runCraftingProcess
local runMgmtTransfers
local ensureItemAvailable
local drawFluidProgress
local simFluidConsume
local crossCraftDepth = 0
function findFluidItemProducer(itemName)
for _, rec in pairs(FluidRecipes) do
for _, o in ipairs(rec.item_outputs or {}) do
if o.name == itemName then return rec, o.count end
end
end
for _, alts in pairs(FluidAltRecipes) do
for _, rec in ipairs(alts) do
for _, o in ipairs(rec.item_outputs or {}) do
if o.name == itemName then return rec, o.count end
end
end
end
return nil
end
function getFluidInventory()
local inventory  = {}
local tankCount  = 0
local totalMb    = 0
local tankDetails = {}
local names = {}
for tankName, isEnabled in pairs(Config.fluid_tanks or {}) do
if isEnabled and not SYSTEM_SIDES[tankName] then names[#names + 1] = tankName end
end
local scanned = batchPeripheralScan(names, "tanks")
for _, nm in ipairs(names) do
local e = scanned[nm]
if e then
tankCount = tankCount + 1
if e.data then
for _, t in pairs(e.data) do
if t and t.name and t.amount and t.amount > 0 then
local k = fluidKey(t.name)
inventory[k] = (inventory[k] or 0) + t.amount
totalMb = totalMb + t.amount
table.insert(tankDetails, {periph = nm, fluid = t.name, amount = t.amount})
end
end
end
end
end
return inventory, tankCount, totalMb, tankDetails
end
function getFluidInventoryCached()
local now = os.clock()
if _flInvCache and (now - _flInvCacheT) < 6 then return _flInvCache end
_flInvCache = (getFluidInventory())
_flInvCacheT = now
return _flInvCache
end
function getTankStats()
local now = os.clock()
if _tankStatsCache and (now - _tankStatsT) < 6 then
return _tankStatsCache.free, _tankStatsCache.total
end
local total, free = 0, 0
local names = {}
for tankName, en in pairs(Config.fluid_tanks or {}) do
if en and not SYSTEM_SIDES[tankName] then names[#names + 1] = tankName end
end
local scanned = batchPeripheralScan(names, "tanks")
for _, nm in ipairs(names) do
local e = scanned[nm]
if e then
total = total + 1
local hasFluid = false
if e.data then
for _, t in pairs(e.data) do
if t and t.amount and t.amount > 0 then hasFluid = true; break end
end
end
if not hasFluid then free = free + 1 end
end
end
_tankStatsCache = {free = free, total = total}
_tankStatsT = now
return free, total
end
function fluidTankList()
local out = {}
for name, en in pairs(Config.fluid_tanks or {}) do
if en and not SYSTEM_SIDES[name] then out[#out + 1] = name end
end
return out
end
function tankContents(periphName)
local res = {}
local t = peripheral.wrap(periphName)
if not (t and t.tanks) then return res end
local ok, list = pcall(t.tanks)
if ok and list then
for _, e in pairs(list) do
if e and e.name and e.amount and e.amount > 0 then
res[e.name] = (res[e.name] or 0) + e.amount
end
end
end
return res
end
function tanksWithFluid(fluidName)
local out = {}
local names = fluidTankList()
local scanned = batchPeripheralScan(names, "tanks")
for _, name in ipairs(names) do
local e = scanned[name]
if e and e.data then
local amt = 0
for _, t in pairs(e.data) do
if t and t.name == fluidName and t.amount then amt = amt + t.amount end
end
if amt > 0 then out[#out + 1] = {periph = name, amount = amt} end
end
end
table.sort(out, function(a, b) return a.amount > b.amount end)
return out
end
function pushFluidToMachine(machineName, fluidName, amount)
local moved = 0
for _, src in ipairs(tanksWithFluid(fluidName)) do
if moved >= amount then break end
local t = peripheral.wrap(src.periph)
if t and t.pushFluid then
while moved < amount do
local ok, m = pcall(t.pushFluid, machineName, amount - moved, fluidName)
if ok and type(m) == "number" and m > 0 then moved = moved + m
else break end
end
end
end
if moved > 0 then invalidateStockCache() end
return moved
end
function fluidTankReservations()
local res = {}
for _, g in ipairs(MgmtGroups or {}) do
local isFluid = g.fluid
if isFluid == nil then
isFluid = (g.input and Config.fluid_tanks and Config.fluid_tanks[g.input])
or (g.output and Config.fluid_tanks and Config.fluid_tanks[g.output]) or false
end
if isFluid then
for _, periph in ipairs({g.output, g.input}) do
if periph and periph ~= "" and periph ~= "STORAGE"
and Config.fluid_tanks and Config.fluid_tanks[periph] then
for _, rule in ipairs(g.rules or {}) do
if rule.item and rule.item ~= "" then
res[periph] = res[periph] or {}
res[periph][rule.item] = true
end
end
end
end
end
end
return res
end
function drainFluidToStorage(machineName, fluidName, limit)
local moved = 0
local machine = peripheral.wrap(machineName)
local reserved = fluidTankReservations()
local function allowed(tname)
local r = reserved[tname]
return (not r) or r[fluidName]
end
local ordered = {}
local seen = {}
local resvFirst = {}
for tname, fl in pairs(reserved) do
if fl[fluidName] and Config.fluid_tanks and Config.fluid_tanks[tname] then resvFirst[#resvFirst + 1] = tname end
end
table.sort(resvFirst)
for _, name in ipairs(resvFirst) do
if not seen[name] then ordered[#ordered + 1] = name; seen[name] = true end
end
for _, t in ipairs(tanksWithFluid(fluidName)) do
if not seen[t.periph] and allowed(t.periph) then ordered[#ordered + 1] = t.periph; seen[t.periph] = true end
end
local rest = {}
for _, name in ipairs(fluidTankList()) do
if not seen[name] and allowed(name) then rest[#rest + 1] = name end
end
table.sort(rest)
for _, name in ipairs(rest) do ordered[#ordered + 1] = name end
local function srcHas()
if not (machine and machine.tanks) then return false end
local ok, list = pcall(machine.tanks)
if not (ok and list) then return false end
for _, e in pairs(list) do
if e and e.name == fluidName and (e.amount or 0) > 1 then return true end
end
return false
end
for _, periphName in ipairs(ordered) do
if moved >= limit then break end
if machine and machine.pushFluid then
for _ = 1, 128 do
if moved >= limit then break end
local ok, m = pcall(machine.pushFluid, periphName, limit - moved, fluidName)
if not (ok and type(m) == "number" and m > 0) then break end
moved = moved + m
end
end
if moved < limit then
local dst = peripheral.wrap(periphName)
if dst and dst.pullFluid then
for _ = 1, 128 do
if moved >= limit then break end
local ok, m = pcall(dst.pullFluid, machineName, limit - moved, fluidName)
if not (ok and type(m) == "number" and m > 0) then break end
moved = moved + m
end
end
end
if moved < limit and not srcHas() then
if moved > 0 then invalidateStockCache() end
return moved
end
end
if moved > 0 then invalidateStockCache() end
return moved
end
function getDeviceFluid(devName, flName)
    local dev = peripheral.wrap(devName)
    if not (dev and dev.tanks) then return 0 end
    local ok, list = pcall(dev.tanks)
    if not (ok and list) then return 0 end
    local total = 0
    for _, t in pairs(list) do
        if t and (not flName or t.name == flName) and (t.amount or 0) > 0 then
            total = total + t.amount
        end
    end
    return total
end
function cleanDeviceWrongFluids(devName, desiredFluid)
    local dev = peripheral.wrap(devName)
    if not (dev and dev.tanks) then return end
    local ok, list = pcall(dev.tanks)
    if not (ok and list) then return end
    for _, t in pairs(list) do
        if t and t.name and (t.amount or 0) > 0 then
            if not desiredFluid or t.name ~= desiredFluid then
                drainFluidToStorage(devName, t.name, t.amount)
            end
        end
    end
end
function getSortedStorages()
    local sorted = {}
    if Config.buffer and Config.buffer ~= "" and not SYSTEM_SIDES[Config.buffer] then
        local pb = peripheral.wrap(Config.buffer)
        if pb and pb.list and pb.pullItems then
            table.insert(sorted, Config.buffer)
        end
    end
    local mainList = {}
    for vName, enabled in pairs(Config.main_vaults or {}) do
        if enabled and not SYSTEM_SIDES[vName] and vName ~= Config.buffer then
            local p = peripheral.wrap(vName)
            if p and p.list and p.pullItems then table.insert(mainList, vName) end
        end
    end
    table.sort(mainList)
    for _, vName in ipairs(mainList) do table.insert(sorted, vName) end

    local auxList = {}
    for sName, enabled in pairs(Config.storages or {}) do
        if enabled and not SYSTEM_SIDES[sName] and sName ~= Config.buffer and not (Config.main_vaults and Config.main_vaults[sName]) then
            local p = peripheral.wrap(sName)
            if p and p.list and p.pullItems then table.insert(auxList, sName) end
        end
    end
    table.sort(auxList)
    for _, sName in ipairs(auxList) do table.insert(sorted, sName) end
    return sorted
end
function sweepCraftMachines()
    -- Build priority dump targets (Buffer -> Main -> Storages)
    local dumpStorages = {}
    if Config.buffer and not SYSTEM_SIDES[Config.buffer] then table.insert(dumpStorages, Config.buffer) end
    for vName, en in pairs(Config.main_vaults or {}) do
        if en and not SYSTEM_SIDES[vName] and vName ~= Config.buffer then table.insert(dumpStorages, vName) end
    end
    for sName, en in pairs(Config.storages or {}) do
        if en and not SYSTEM_SIDES[sName] and sName ~= Config.buffer and not (Config.main_vaults and Config.main_vaults[sName]) then
            table.insert(dumpStorages, sName)
        end
    end

    for mName in pairs(craftUsedMachines or {}) do
        local m = peripheral.wrap(mName)
        if m then
            if m.list and m.pushItems then
                local ok, items = pcall(m.list)
                if ok and items then
                    for slot, it in pairs(items) do
                        if it and it.count and it.count > 0 then
                            local left = it.count
                            for _, sName in ipairs(dumpStorages) do
                                if left <= 0 then break end
                                local okP, mv = pcall(m.pushItems, sName, slot, left)
                                if okP and type(mv) == "number" and mv > 0 then left = left - mv end
                            end
                        end
                    end
                end
            end
            if m.tanks then
                local okT, tl = pcall(m.tanks)
                if okT and tl then
                    for _, tk in pairs(tl) do
                        if tk and tk.name and tk.amount and tk.amount > 0 then
                            drainFluidToStorage(mName, tk.name, tk.amount)
                        end
                    end
                end
            end
        end
    end
    craftUsedMachines = {}
end
function flushCraftBuffer()
    if Config.buffer and Config.buffer ~= "" and StorageIndex and StorageIndex.ingestBuffer then
        local rounds = 0
        while rounds < 50 do
            local moved = StorageIndex.ingestBuffer()
            if not moved or moved <= 0 then break end
            rounds = rounds + 1
            if rounds % 10 == 0 then sleep(0) end
        end
    end
end
function machineFluidSnapshot(machine)
local res = {}
local ok, list = pcall(machine.tanks)
if ok and list then
for _, e in pairs(list) do
if e and e.name and e.amount and e.amount > 0 then
res[e.name] = (res[e.name] or 0) + e.amount
end
end
end
return res
end
function sameFluidMap(a, b)
for k, v in pairs(a) do if b[k] ~= v then return false end end
for k, v in pairs(b) do if a[k] ~= v then return false end end
return true
end
function machineItemSnapshot(machineName)
local res = {}
local m = peripheral.wrap(machineName)
if not (m and m.list) then return res end
local ok, items = pcall(m.list)
if ok and items then
for _, it in pairs(items) do
if it and it.name and it.count and it.count > 0 then
res[it.name] = (res[it.name] or 0) + it.count
end
end
end
return res
end
function waitFluidStable(machine, machineName, timeoutTotal, cancellable, onTick)
local function combo()
local res = {}
for k, v in pairs(machineFluidSnapshot(machine)) do res["f:" .. k] = v end
for k, v in pairs(machineItemSnapshot(machineName)) do res["i:" .. k] = v end
return res
end
local prevC = combo()
local stableCount, sawChange, elapsed = 0, false, 0
while true do
if onTick then onTick() end
if cancellable then
sleepCheckCancel(0.5)
if cancelCrafting then return machineFluidSnapshot(machine), true end
else
sleep(0.5)
end
elapsed = elapsed + 0.5
local curC = combo()
if sameFluidMap(prevC, curC) then
stableCount = stableCount + 1
else
sawChange = true
stableCount = 0
end
prevC = curC
if sawChange and stableCount >= 3 then break end
if not cancellable and elapsed >= timeoutTotal then break end
end
return machineFluidSnapshot(machine), false
end
function drainMachineItems(machineName)
    local m = peripheral.wrap(machineName)
    if not (m and m.list and m.pushItems) then return end
    local ok, items = pcall(m.list)
    if not (ok and items) then return end

    local dumpStorages = {}
    if Config.buffer and not SYSTEM_SIDES[Config.buffer] then table.insert(dumpStorages, Config.buffer) end
    for vName, en in pairs(Config.main_vaults or {}) do
        if en and not SYSTEM_SIDES[vName] and vName ~= Config.buffer then table.insert(dumpStorages, vName) end
    end
    for sName, en in pairs(Config.storages or {}) do
        if en and not SYSTEM_SIDES[sName] and sName ~= Config.buffer and not (Config.main_vaults and Config.main_vaults[sName]) then
            table.insert(dumpStorages, sName)
        end
    end

    for slot, item in pairs(items) do
        if item and item.count and item.count > 0 then
            local left = item.count
            for _, sName in ipairs(dumpStorages) do
                if left <= 0 then break end
                local okP, mv = pcall(m.pushItems, sName, slot, left)
                if okP and type(mv) == "number" and mv > 0 then left = left - mv end
            end
        end
    end
end
function pushItemsToMachine(machineName, itemName, count, allowSub)
return pushFromStorage(itemName, count, machineName, nil, allowSub) or 0
end
function planFluidCraft(recipe, targetName, amount)
if not recipe then return false, nil, {"No recipe"} end
local perOp, isItemTarget = nil, false
for _, o in ipairs(recipe.outputs or {}) do
if o.name == targetName then perOp = o.amount; break end
end
if not perOp then
for _, o in ipairs(recipe.item_outputs or {}) do
if o.name == targetName then perOp = o.count; isItemTarget = true; break end
end
end
if not perOp or perOp <= 0 then return false, nil, {"Bad recipe output amount"} end
local ops = math.ceil(amount / perOp)
local inv = getFluidInventory()
local errLines = {}
for _, inp in ipairs(recipe.inputs or {}) do
local need = ops * inp.amount
local have = inv[fluidKey(inp.name)] or 0
if have < need then
local sn = inp.name:match(":(.+)$") or inp.name
table.insert(errLines, string.format("Need %d mB %s, have %d", need, sn, have))
end
end
if recipe.item_inputs and #recipe.item_inputs > 0 then
local stk = getStorageInventory()
for _, it in ipairs(recipe.item_inputs) do
local need = ops * it.count
local have = stk[it.name] or 0
if have < need then
local sn = it.name:match(":(.+)$") or it.name
table.insert(errLines, string.format("Need %dx %s, have %d", need, sn, have))
end
end
end
if #errLines > 0 then return false, nil, errLines end
return true, {recipe = recipe, ops = ops, perOp = perOp, target = targetName, isItem = isItemTarget}, nil
end
function checkOutputStorage(recipe)
local emptyCount = 0
local held = {}
for _, name in ipairs(fluidTankList()) do
local c = tankContents(name)
if next(c) == nil then emptyCount = emptyCount + 1
else for fn in pairs(c) do held[fn] = true end end
end
local newOuts = {}
for _, o in ipairs(recipe.outputs or {}) do
if not held[o.name] then newOuts[#newOuts + 1] = o.name end
end
if #newOuts > emptyCount - (fluidTankClaims or 0) then
local sn = newOuts[1] and ((newOuts[1]):match(":(.+)$") or newOuts[1]) or "?"
return false, {
"No free [TNK] tank for output: " .. sn,
"Mark an empty tank with [TNK] in NETWORK.",
}
end
return true, nil, #newOuts
end
local getMachinePool
function runFluidCraftInner(plan)
local recipe = plan.recipe
local baseMachine = recipe.machine_name
local splitOut = nil
if recipe.output_device and recipe.output_device ~= "" then
if peripheral.wrap(recipe.output_device) then
splitOut = recipe.output_device
else
return false, {"Output device not found: " .. tostring(recipe.output_device)}, 0
end
end
local itemInDev = nil
if recipe.item_input_device and recipe.item_input_device ~= "" then
if peripheral.wrap(recipe.item_input_device) then
itemInDev = recipe.item_input_device
else
return false, {"Item input device not found: " .. tostring(recipe.item_input_device)}, 0
end
end
local fluidInDev = nil
if recipe.fluid_input_device and recipe.fluid_input_device ~= "" then
if peripheral.wrap(recipe.fluid_input_device) then
fluidInDev = recipe.fluid_input_device
else
return false, {"Fluid input device not found: " .. tostring(recipe.fluid_input_device)}, 0
end
end
local itemOutDev = nil
if recipe.item_output_device and recipe.item_output_device ~= "" then
if peripheral.wrap(recipe.item_output_device) then
itemOutDev = recipe.item_output_device
else
return false, {"Item output device not found: " .. tostring(recipe.item_output_device)}, 0
end
end
local pool = {}
if splitOut or itemInDev or fluidInDev or itemOutDev then
local pp = peripheral.wrap(baseMachine)
if pp and pp.tanks and pp.pushFluid and pp.pullFluid then pool = {baseMachine} end
else
for _, pmName in ipairs(getMachinePool(baseMachine)) do
local pp = peripheral.wrap(pmName)
if pp and pp.tanks and pp.pushFluid and pp.pullFluid then
pool[#pool + 1] = pmName
end
end
end
if #pool == 0 then
return false, {"Machine missing fluid methods: " .. tostring(baseMachine)}, 0
end
for _, pmName in ipairs(pool) do craftUsedMachines[pmName] = true end
if splitOut   then craftUsedMachines[splitOut]   = true end
if itemInDev  then craftUsedMachines[itemInDev]  = true end
if fluidInDev then craftUsedMachines[fluidInDev] = true end
if itemOutDev then craftUsedMachines[itemOutDev] = true end
local targetName = plan.label
local targetIsItem = false
for _, o in ipairs(recipe.item_outputs or {}) do
if o.name == targetName then targetIsItem = true; break end
end
local flAllowSub = not isWoodSpecificItem(targetName)
local inFluidSet, inItemSet = {}, {}
for _, inp in ipairs(recipe.inputs or {}) do inFluidSet[inp.name] = true end
for _, it in ipairs(recipe.item_inputs or {}) do
inItemSet[it.name] = true
if flAllowSub and ITEM_GROUPS[it.name] and GROUPS[ITEM_GROUPS[it.name]] then
for _, alt in ipairs(GROUPS[ITEM_GROUPS[it.name]]) do inItemSet[alt] = true end
end
end
local sortedSto = getSortedStorages()
local itemMaxStack = {}
for _, it in ipairs(recipe.item_inputs or {}) do
local maxS = (StorageIndex and StorageIndex.getMaxStack and StorageIndex.getMaxStack(it.name)) or 64
local iData = StorageIndex and StorageIndex.byItem and StorageIndex.byItem[it.name]
if iData and iData.slots and iData.slots[1] then
local sl = iData.slots[1]
local v = peripheral.wrap(sl.vault)
if v and v.getItemDetail then
local okD, det = pcall(v.getItemDetail, sl.slot)
if okD and det and det.maxCount and det.maxCount > 0 then maxS = det.maxCount end
end
end
itemMaxStack[it.name] = maxS
end
local label = plan.label or baseMachine or "fluid"
fluidStepNum = fluidStepNum + 1
if fluidStepNum > fluidStepTotal then fluidStepTotal = fluidStepNum end
fluidSubLabel = label
local totalOps = plan.ops
local produced = 0
local function pushBatch(mName, wantOps)
local accepted = wantOps
for _, it in ipairs(recipe.item_inputs or {}) do
local maxS = itemMaxStack[it.name] or 64
if maxS >= it.count then
local maxOpsForItem = math.floor(maxS / it.count)
if maxOpsForItem < accepted then accepted = maxOpsForItem end
elseif accepted > 1 then
accepted = 1
end
end
for _, inp in ipairs(recipe.inputs or {}) do
local avail = 0
for _, src in ipairs(tanksWithFluid(inp.name)) do avail = avail + (src.amount or 0) end
local opsForInp = math.floor(avail / inp.amount)
if opsForInp < accepted then accepted = opsForInp end
end
if accepted < 1 then return 0 end
local fDev = fluidInDev or mName
local fPer = peripheral.wrap(fDev)
if fPer and #(recipe.inputs or {}) > 0 then
local seqPour = (splitOut ~= nil or itemInDev ~= nil or fluidInDev ~= nil or itemOutDev ~= nil)
and #(recipe.inputs or {}) > 1
local preF = machineFluidSnapshot(fPer)
for fi, inp in ipairs(recipe.inputs or {}) do
if seqPour and fi > 1 then
local prevName = recipe.inputs[fi - 1].name
local waitC = 0
while waitC < 40 do
local snapW = machineFluidSnapshot(fPer)
if (snapW[prevName] or 0) <= 0 then break end
sleepCheckCancel(0.5)
if cancelCrafting then return 0 end
waitC = waitC + 1
end
preF = machineFluidSnapshot(fPer)
end
local have   = preF[inp.name] or 0
local curOps = math.floor(have / inp.amount)
local needed = (curOps + accepted) * inp.amount - have
local moved  = 0
if needed > 0 then moved = pushFluidToMachine(fDev, inp.name, needed) end
local newOps = math.floor((have + moved) / inp.amount) - curOps
if newOps < accepted then accepted = math.max(0, newOps) end
end
if accepted < 1 then return 0 end
end
local iDev = itemInDev or mName
local preI = {}
if #(recipe.item_inputs or {}) > 0 then
local iPer = peripheral.wrap(iDev)
if iPer and iPer.list then
local okI, its = pcall(iPer.list)
if okI and its then
for _, it2 in pairs(its) do
if it2 then
for _, reqIt in ipairs(recipe.item_inputs or {}) do
if itemMatchesOrGroup(it2.name, reqIt.name, flAllowSub) then
preI[reqIt.name] = (preI[reqIt.name] or 0) + (it2.count or 0)
break
end
end
end
end
end
end
end
for _, it in ipairs(recipe.item_inputs or {}) do
local have   = preI[it.name] or 0
local curOps = math.floor(have / it.count)
local needed = (curOps + accepted) * it.count - have
local moved  = 0
if needed > 0 then moved = pushItemsToMachine(iDev, it.name, needed, flAllowSub) or 0 end
local newOps = math.floor((have + moved) / it.count) - curOps
if newOps < accepted then accepted = math.max(0, newOps) end
end
return accepted
end
local function drainMachine(e)
local targetMoved = 0
local anyOutput = false
local devs = { e.drain, e.name, itemOutDev }
for _ = 1, 8 do
local passMoved = 0
local seenF = {}
for _, dn in ipairs(devs) do
if dn and not seenF[dn] then
seenF[dn] = true
local isDedicatedOut = (splitOut ~= nil and dn == splitOut)
local machine = peripheral.wrap(dn)
if machine and machine.tanks then
local snap = machineFluidSnapshot(machine)
for fname, amt in pairs(snap) do
if amt > 1 and (isDedicatedOut or not inFluidSet[fname]) then
local moved = drainFluidToStorage(dn, fname, 1000000)
if moved and moved > 0 then
passMoved = passMoved + moved; anyOutput = true
if (not targetIsItem) and fname == targetName then targetMoved = targetMoved + moved end
end
end
end
end
end
end
local seenI = {}
for _, dn in ipairs(devs) do
if dn and not seenI[dn] then
seenI[dn] = true
local isDedicatedItemOut = (itemOutDev ~= nil and dn == itemOutDev)
local m = peripheral.wrap(dn)
if m and m.list and m.pushItems then
local ok, items = pcall(m.list)
if ok and items then
for slot, item in pairs(items) do
if item and item.count and item.count > 0 and (isDedicatedItemOut or not inItemSet[item.name]) then
local left = item.count
for _, sName in ipairs(sortedSto) do
if left <= 0 then break end
local okP, mv = pcall(m.pushItems, sName, slot, left)
if okP and type(mv) == "number" and mv > 0 then left = left - mv end
end
if left > 0 then
for _, sName in ipairs(sortedSto) do
if left <= 0 then break end
local sto = peripheral.wrap(sName)
if sto and sto.pullItems then
local okQ, mvQ = pcall(sto.pullItems, dn, slot, left)
if okQ and type(mvQ) == "number" and mvQ > 0 then left = left - mvQ end
end
end
end
local mvd = item.count - left
if mvd > 0 then
passMoved = passMoved + mvd; anyOutput = true
if targetIsItem and item.name == targetName then targetMoved = targetMoved + mvd end
end
end
end
end
end
end
end
if passMoved == 0 then break end
end
return targetMoved, anyOutput
end
local function finalDrain(mName)
local machine = peripheral.wrap(mName)
for pass = 1, 5 do
local snap = machineFluidSnapshot(machine)
local itemSnap = machineItemSnapshot(mName)
if next(snap) == nil and next(itemSnap) == nil then break end
for fname in pairs(snap) do drainFluidToStorage(mName, fname, 1000000) end
drainMachineItems(mName)
end
end
local function availableOps()
if #(recipe.inputs or {}) == 0 then return nil end
local minOps = nil
for _, inp in ipairs(recipe.inputs) do
local avail = 0
for _, src in ipairs(tanksWithFluid(inp.name)) do avail = avail + (src.amount or 0) end
local opsForInp = math.floor(avail / inp.amount)
if minOps == nil or opsForInp < minOps then minOps = opsForInp end
end
return minOps
end
local poolSize = #pool
local base  = math.floor(totalOps / poolSize)
local extra = totalOps % poolSize
local machineData = {}
for idx, mName in ipairs(pool) do
local assigned = base + ((idx <= extra) and 1 or 0)
if assigned > 0 then
machineData[#machineData + 1] = {
name        = mName,
drain       = splitOut or mName,
remainOps   = assigned,
batchTarget = 0,
batchDone   = 0,
idle        = 0,
starve      = 0,
startedOut  = false,
finished    = false,
}
end
end
local function finalDrainEntry(e)
local seen = {}
for _, d in ipairs({e.name, e.drain, itemInDev, fluidInDev, itemOutDev}) do
if d and not seen[d] then seen[d] = true; finalDrain(d) end
end
end
for _, e in ipairs(machineData) do finalDrainEntry(e) end
local totalExpected = totalOps * plan.perOp
local maxWait = math.max(400, totalOps * 30)
local waited  = 0
local function allFinished()
for _, e in ipairs(machineData) do
if not e.finished then return false end
end
return true
end
while (not allFinished()) and produced < totalExpected and waited < maxWait do
sleepCheckCancel(0.5)
if cancelCrafting then
for _, e in ipairs(machineData) do finalDrainEntry(e) end
invalidateStockCache()
return false, {"Cancelled by user."}, produced
end
waited = waited + 1
local refillNeeded = {}
for _, e in ipairs(machineData) do
if not e.finished then
local moved, hadOut = drainMachine(e)
if moved > 0 then
produced = produced + moved
e.batchDone = e.batchDone + moved
end
if hadOut then e.startedOut = true; e.idle = 0 else e.idle = e.idle + 1 end
if e.batchDone >= e.batchTarget and not hadOut then
if e.remainOps > 0 then
refillNeeded[#refillNeeded + 1] = e
else
e.finished = true
end
elseif e.startedOut and e.idle >= 30 then
e.finished = true
end
end
end
if #refillNeeded > 0 then
local avail = availableOps()
local share
if avail == nil then
share = nil
else
share = math.max(1, math.floor(avail / #refillNeeded))
end
for _, e in ipairs(refillNeeded) do
local want = e.remainOps
if share and share < want then want = share end
if want < 1 then want = 1 end
local acc = pushBatch(e.name, want)
if acc > 0 then
e.batchTarget = e.batchTarget + acc * plan.perOp
e.remainOps   = e.remainOps - acc
e.startedOut  = false
e.idle        = 0
e.starve      = 0
else
e.starve = e.starve + 1
if e.starve >= 12 then
e.finished = true
else
sleepCheckCancel(1)
end
end
end
end
if drawFluidProgress then
local doneOpsNow = math.min(totalOps, math.floor(produced / math.max(1, plan.perOp)))
local activeW = 0
for _, e in ipairs(machineData) do if not e.finished then activeW = activeW + 1 end end
drawFluidProgress(label, doneOpsNow, totalOps, activeW)
end
end
for _, e in ipairs(machineData) do finalDrainEntry(e) end
invalidateStockCache()
if produced <= 0 and totalOps > 0 then
return false, {"Could not push inputs to " .. tostring(baseMachine)}, produced
end
if crossCraftDepth == 0 and (craftStageDone or 0) < (craftStageTotal or 0) then
craftStageDone = (craftStageDone or 0) + 1
end
return true, nil, produced
end
runFluidCraft = function(fplan)
local toks = fluidRecipeTokens(fplan.recipe)
local got = false
local waitN = 0
while true do
if tryAcquireTokens(toks) then got = true; break end
if cancelCrafting then return false, {"Cancelled by user."}, 0 end
sleepCheckCancel(0.2)
waitN = waitN + 1
if waitN > 450 then break end
end
while _fluidStoreBusy do
if cancelCrafting then
if got then releaseTokens(toks) end
return false, {"Cancelled by user."}, 0
end
sleepCheckCancel(0.1)
end
_fluidStoreBusy = true
local okStore, storeErr, nOuts = checkOutputStorage(fplan.recipe)
if okStore then fluidTankClaims = fluidTankClaims + (nOuts or 0) end
_fluidStoreBusy = false
if not okStore then
if got then releaseTokens(toks) end
return false, storeErr, 0
end
local okR, errR, producedR = runFluidCraftInner(fplan)
fluidTankClaims = math.max(0, fluidTankClaims - (nOuts or 0))
if got then releaseTokens(toks) end
return okR, errR, producedR
end
optimizeActive = false
optimizeTimer  = nil
allScanActive  = false
function optimizeStorages()
    return StorageIndex.defragment()
end
function optimizeFluidTanks()
local excluded = {}
for _, g in ipairs(MgmtGroups) do
if g.output and g.output ~= "" and g.output ~= "STORAGE" then
excluded[g.output] = true
end
end
local byFluid = {}
for tankName, isEnabled in pairs(Config.fluid_tanks or {}) do
if isEnabled and not SYSTEM_SIDES[tankName] and not excluded[tankName] then
local t = peripheral.wrap(tankName)
if t and t.tanks and t.pushFluid then
for fname, amt in pairs(tankContents(tankName)) do
if amt > 0 then
byFluid[fname] = byFluid[fname] or {}
byFluid[fname][#byFluid[fname] + 1] = {periph = tankName, amount = amt}
end
end
end
end
end
for fluidName, tlist in pairs(byFluid) do
if #tlist > 1 then
table.sort(tlist, function(a, b) return a.amount > b.amount end)
local target = 1
for i = 2, #tlist do
local srcName = tlist[i].periph
local srcP = peripheral.wrap(srcName)
if srcP and srcP.pushFluid then
local guard = 0
while target < i and guard < 128 do
guard = guard + 1
local ok, n = pcall(srcP.pushFluid, tlist[target].periph, 1000000000, fluidName)
local moved = (ok and type(n) == "number") and n or 0
local rem = (tankContents(srcName))[fluidName] or 0
if rem <= 0 then break end
if moved <= 0 then target = target + 1 end
end
end
end
end
end
end
local KNOWN_TOOL_DURABILITY = {
    ["create:sandpaper"] = 8,
    ["create:red_sandpaper"] = 8,
    ["create:diamond_grit_sandpaper"] = 1024,
    ["create:super_glue"] = 99,
    ["minecraft:shears"] = 238,
    ["minecraft:flint_and_steel"] = 64,
    ["minecraft:brush"] = 64,
    ["minecraft:fishing_rod"] = 64,
    ["minecraft:carrot_on_a_stick"] = 25,
    ["minecraft:warped_fungus_on_a_stick"] = 100
}

function getToolDefaultDurability(itemName)
    if not itemName or itemName == "" then return nil end
    local baseName = parseItemKey(itemName)
    if KNOWN_TOOL_DURABILITY[baseName] then
        return KNOWN_TOOL_DURABILITY[baseName]
    end
    local short = baseName:match(":(.+)$") or baseName
    if short:find("sandpaper") then return 8 end
    if short:find("shears") then return 238 end
    if short:find("flint_and_steel") then return 64 end
    local isToolKind = short:match("_axe$") or short:match("_pickaxe$") or short:match("_shovel$")
        or short:match("_hoe$") or short:match("_sword$") or short:match("_knife$")
        or short:match("_saw$") or short:match("_hammer$") or short:match("_paxel$")
    if isToolKind then
        if short:find("^wooden_") then return 59 end
        if short:find("^stone_") then return 131 end
        if short:find("^golden_") or short:find("^gold_") then return 32 end
        if short:find("^iron_") then return 250 end
        if short:find("^copper_") or short:find("^zinc_") then return 190 end
        if short:find("^brass_") or short:find("^rose_quartz_") then return 450 end
        if short:find("^diamond_") then return 1561 end
        if short:find("^netherite_") then return 2031 end
        return 250
    end
    return nil
end

function isKnownToolItem(itemName)
    if not itemName or itemName == "" then return false end
    if getToolDefaultDurability(itemName) ~= nil then return true end
    return false
end

function getWholeToolDurability(itemName, samplePeriph, sampleSlot)
    if samplePeriph and sampleSlot and samplePeriph.getItemDetail then
        local ok, det = pcall(samplePeriph.getItemDetail, sampleSlot)
        if ok and det and det.maxDamage and det.maxDamage > 0 then
            return det.maxDamage
        end
    end
    local baseName = parseItemKey(itemName or "")
    if baseName ~= "" and StorageIndex and StorageIndex.byItem then
        for kItem, kData in pairs(StorageIndex.byItem) do
            if parseItemKey(kItem) == baseName and kData.slots and kData.slots[1] then
                local sl = kData.slots[1]
                local v = peripheral.wrap(sl.vault)
                if v and v.getItemDetail then
                    local okD, detD = pcall(v.getItemDetail, sl.slot)
                    if okD and detD and detD.maxDamage and detD.maxDamage > 0 then
                        return detD.maxDamage
                    end
                end
                break
            end
        end
    end
    return getToolDefaultDurability(baseName) or 250
end

pushFromStorage = function(itemName, amountNeeded, targetMachine, targetSlot, allowGroupSub)
    local moved = 0
    local group = (allowGroupSub ~= false) and ITEM_GROUPS[itemName] or nil
    local altItems = {}
    if group then
        for _, altName in ipairs(GROUPS[group]) do
            if altName ~= itemName then altItems[altName] = true end
        end
    end
    local hasAlts = next(altItems) ~= nil

    local exactSlots = {}
    local altSlots   = {}

    -- 1. Instantly collect slots from StorageIndex (MAIN Vaults without network polling)
    local mainData = StorageIndex.byItem[itemName]
    if mainData and mainData.slots then
        for _, sl in ipairs(mainData.slots) do
            local p = peripheral.wrap(sl.vault)
            if p and p.pushItems then
                table.insert(exactSlots, {
                    storage = p, stoName = sl.vault, slot = sl.slot,
                    count = sl.count, name = itemName, isMain = true
                })
            end
        end
    end
    if not itemName:find("#") then
        for kItem, kData in pairs(StorageIndex.byItem) do
            if kItem ~= itemName and parseItemKey(kItem) == itemName and kData.slots then
                for _, sl in ipairs(kData.slots) do
                    local p = peripheral.wrap(sl.vault)
                    if p and p.pushItems then
                        table.insert(exactSlots, {
                            storage = p, stoName = sl.vault, slot = sl.slot,
                            count = sl.count, name = kItem, isMain = true
                        })
                    end
                end
            end
        end
    end

    if hasAlts then
        for altName in pairs(altItems) do
            local aData = StorageIndex.byItem[altName]
            if aData and aData.slots then
                for _, sl in ipairs(aData.slots) do
                    local p = peripheral.wrap(sl.vault)
                    if p and p.pushItems then
                        table.insert(altSlots, {
                            storage = p, stoName = sl.vault, slot = sl.slot,
                            count = sl.count, name = altName, isMain = true
                        })
                    end
                end
            end
        end
    end

    -- Count available items in MAIN vaults (including substitutes when allowed)
    local mainCount = 0
    for _, sl in ipairs(exactSlots) do mainCount = mainCount + sl.count end
    if hasAlts then
        for _, sl in ipairs(altSlots) do mainCount = mainCount + sl.count end
    end

    -- 2. Poll [VAULT] and providers ONLY if MAIN is insufficient
    if mainCount < amountNeeded then
        local extraNames, seenNm = {}, {}
        for storageName, isEnabled in pairs(Config.storages or {}) do
            if isEnabled and not SYSTEM_SIDES[storageName] and not seenNm[storageName] then
                seenNm[storageName] = true
                table.insert(extraNames, storageName)
            end
        end
        for _, pName in ipairs(providerSources()) do
            if not seenNm[pName] then
                seenNm[pName] = true
                table.insert(extraNames, pName)
            end
        end

        if #extraNames > 0 then
            local scanned = batchPeripheralScan(extraNames, "list")
            for _, stoName in ipairs(extraNames) do
                local e = scanned[stoName]
                if e and e.data then
                    local storage = peripheral.wrap(stoName)
                    if storage and storage.pushItems then
                        for slot, item in pairs(e.data) do
                            if item then
                                local itemKey = makeItemKey(item.name, item.nbt)
                                if itemKey == itemName or (not itemName:find("#") and item.name == itemName) then
                                    table.insert(exactSlots, {storage=storage, stoName=stoName, slot=slot, count=item.count, name=itemKey, isMain=false})
                                elseif hasAlts and altItems[itemKey] then
                                    table.insert(altSlots, {storage=storage, stoName=stoName, slot=slot, count=item.count, name=itemKey, isMain=false})
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local preferDamaged = (not itemName:find("#")) and isKnownToolItem(itemName)
    table.sort(exactSlots, function(a, b)
        if preferDamaged then
            local aDmg = (a.name and a.name:find("#") ~= nil) or false
            local bDmg = (b.name and b.name:find("#") ~= nil) or false
            if aDmg ~= bDmg then return aDmg end
        end
        return a.count > b.count
    end)

    local exactTotal = 0
    for _, sl in ipairs(exactSlots) do exactTotal = exactTotal + sl.count end
    local altTotals = {}
    local bestAltTotal = 0
    for _, sl in ipairs(altSlots) do
        local tot = (altTotals[sl.name] or 0) + sl.count
        altTotals[sl.name] = tot
        if tot > bestAltTotal then bestAltTotal = tot end
    end
    table.sort(altSlots, function(a, b)
        local ta = altTotals[a.name] or 0
        local tb = altTotals[b.name] or 0
        if ta ~= tb then return ta > tb end
        if a.name ~= b.name then return a.name < b.name end
        return a.count > b.count
    end)

    local destFull = false
    local function verifiedPush(entry)
        local toMove = math.min(amountNeeded - moved, entry.count)
        if toMove <= 0 then return end

        local ok, mv = pcall(entry.storage.pushItems, targetMachine, entry.slot, toMove, targetSlot)
        if ok and type(mv) == "number" and mv > 0 then
            moved = moved + mv
            if entry.isMain then
                StorageIndex.deduct(entry.stoName, entry.slot, entry.name, mv)
            end
            return
        end

        -- If pushItems failed, try pullItems from receiver side
        if targetMachine then
            local mPeriph = peripheral.wrap(targetMachine)
            if mPeriph and mPeriph.pullItems then
                local ok2, mv2 = pcall(mPeriph.pullItems, entry.stoName, entry.slot, toMove, targetSlot)
                if ok2 and type(mv2) == "number" and mv2 > 0 then
                    moved = moved + mv2
                    if entry.isMain then
                        StorageIndex.deduct(entry.stoName, entry.slot, entry.name, mv2)
                    end
                    return
                end
            end
        end

        -- BOTH METHODS RETURNED 0: Check if item was taken by player / packer
        if entry.isMain and entry.storage and entry.storage.getItemDetail then
            local okD, det = pcall(entry.storage.getItemDetail, entry.slot)
            local detKey = (okD and det and det.name) and makeItemKey(det.name, det.nbt) or nil
            if not (detKey and detKey == entry.name and (det.count or 0) > 0) then
                -- SELF-HEALING: Item was removed or replaced! Clear index
                StorageIndex.deduct(entry.stoName, entry.slot, entry.name, entry.count)
                if detKey and det.count > 0 then
                    local formatted = formatItemDetailName(det, detKey)
                    if isValidDisplayName(formatted) then
                        ItemDisplayNames[detKey] = formatted
                        saveItemNames()
                    end
                    StorageIndex.add(entry.stoName, entry.slot, detKey, det.count)
                end
                -- DO NOT declare destFull! Proceed to next slot!
                return
            end
        end

        -- Item is actually in slot, meaning destination is full / busy
        destFull = true
    end

    local useAltsFirst = hasAlts and exactTotal < amountNeeded and bestAltTotal > exactTotal
    local firstList  = useAltsFirst and altSlots or exactSlots
    local secondList = useAltsFirst and exactSlots or altSlots

    for _, entry in ipairs(firstList) do
        if moved >= amountNeeded or destFull then break end
        verifiedPush(entry)
    end
    for _, entry in ipairs(secondList) do
        if moved >= amountNeeded or destFull then break end
        verifiedPush(entry)
    end

    return moved
end
function getAvailableMachines()
    local list = {}
    local all = peripheral.getNames()
    for _, p in ipairs(all) do
        if not SYSTEM_SIDES[p] and p ~= MONITOR_SIDE and p ~= Config.train_box
        and not (Config.turtles and Config.turtles[p]) 
        and not (Config.storages and Config.storages[p])
        and not (Config.main_vaults and Config.main_vaults[p]) -- <--- Exclude MAIN
        and p ~= Config.buffer                                -- <--- Exclude BUF
        and not (Config.fluid_tanks and Config.fluid_tanks[p])
        and p ~= Config.project_chest then
            table.insert(list, p)
        end
    end
    table.sort(list, naturalSortDisplay)
    return list
end
function getMachineBaseName(name)
    if not name or name == "" then return "" end
    return name:match("^(.-)_[0-9]+$") or name
end

function groupAvailable(itemName, stock, allowGroupSub)
    local total = stock[itemName] or 0
    if not itemName:find("#") then
        for k, v in pairs(stock) do
            if k ~= itemName and v and v > 0 and parseItemKey(k) == itemName then
                total = total + v
            end
        end
    end
    if allowGroupSub ~= false then
        local group = ITEM_GROUPS[itemName]
        if group then
            for _, altName in ipairs(GROUPS[group]) do
                if altName ~= itemName then
                    total = total + (stock[altName] or 0)
                end
            end
        end
    end
    return total
end

function getRecipeSuccessFrac(recipe)
    if not recipe then return 1.0 end
    if recipe.mode == "chance" or recipe.success_rate or recipe.chance then
        if recipe.mode and recipe.mode ~= "chance" then return 1.0 end
        local pct = tonumber(recipe.success_rate) or (tonumber(recipe.chance) and tonumber(recipe.chance) * 100) or 100
        return math.max(0.01, math.min(1.0, pct / 100))
    end
    return 1.0
end

function getCompositeStationCount(recipe)
    if not recipe or recipe.type ~= "composite" then return 1 end
    local targetName = recipe.machine_name
    if not targetName or targetName == "" then return 1 end
    local matchedCG = nil
    for _, cg in ipairs(CustomMachineGroups or {}) do
        for _, cm in ipairs(cg.machines or {}) do
            if cm == targetName then matchedCG = cg; break end
        end
        if matchedCG then break end
    end
    if not matchedCG then return 1 end
    local cgAvail = {}
    for _, m in ipairs(matchedCG.machines or {}) do
        if not ExcludedMachines[m] then table.insert(cgAvail, m) end
    end
    local targetBase = getMachineBaseName(targetName)
    local numTargets = 0
    for _, m in ipairs(cgAvail) do
        if getMachineBaseName(m) == targetBase then numTargets = numTargets + 1 end
    end
    if numTargets <= 1 then return 1 end
    local numStations = numTargets
    for _, act in ipairs(recipe.actions or {}) do
        if act.device and act.device ~= "" then
            local aBase = getMachineBaseName(act.device)
            local aCnt = 0
            for _, m in ipairs(cgAvail) do
                if getMachineBaseName(m) == aBase then aCnt = aCnt + 1 end
            end
            if aCnt < numStations then numStations = aCnt end
        end
    end
    if recipe.output_device and recipe.output_device ~= "" and recipe.output_device ~= targetName then
        local oBase = getMachineBaseName(recipe.output_device)
        local oCnt = 0
        for _, m in ipairs(cgAvail) do
            if getMachineBaseName(m) == oBase then oCnt = oCnt + 1 end
        end
        if oCnt < numStations then numStations = oCnt end
    end
    return math.max(1, numStations)
end

function isRecipeToolIng(recipe, ingName)
    if not recipe then return false end
    local bKey = parseItemKey(ingName)
    if recipe.tools and (recipe.tools[ingName] ~= nil or recipe.tools[bKey] ~= nil) then
        return true
    end
    if recipe.type == "composite" and recipe.actions then
        for _, act in ipairs(recipe.actions) do
            if act.type == "item" and act.is_tool and act.item and parseItemKey(act.item) == bKey then
                return true
            end
        end
    end
    return false
end

function computeToolsRequired(recipe, ingName, plannedBatches)
    if not recipe or recipe.type ~= "composite" then
        return 1, 0
    end
    local bKey = parseItemKey(ingName)
    local tInfo = recipe.tools and (recipe.tools[ingName] or recipe.tools[bKey])
    local dur = (type(tInfo) == "table" and tonumber(tInfo.durability)) or nil
    if not dur then
        for _, act in ipairs(recipe.actions or {}) do
            if act.type == "item" and act.is_tool and act.item and parseItemKey(act.item) == bKey then
                dur = tonumber(act.durability)
                break
            end
        end
    end
    dur = math.max(1, dur or getToolDefaultDurability(bKey) or 250)
    local numStations = getCompositeStationCount(recipe)
    local batches = math.max(1, plannedBatches or 1)
    local activeW = math.min(batches, numStations)
    local opsPerStation = math.ceil(batches / activeW)
    local toolsPerStation = math.max(1, math.ceil(opsPerStation / dur))
    local totalTools = activeW * toolsPerStation
    local brokenTools = activeW * math.max(0, toolsPerStation - 1)
    return totalTools, brokenTools
end

function clearLearnTurtle()
if learnedCraftType ~= "turtle" then return end
if not (Config.train_box and Config.train_box ~= "") then return end
local tb = peripheral.wrap(Config.train_box)
if not (tb and tb.pullItems) then return end
for slot = 1, 16 do pcall(function() tb.pullItems(learnedMachineName, slot, 64) end) end
end
function calculateCraft(itemName, countNeeded, stock, missing, blocked, craftPlan, visited, allowPartial, allowGroupSub)
calcNodes = calcNodes + 1
if calcBudget > 0 and calcNodes > calcBudget then return end
if calcNodes % 1024 == 0 then sleep(0) end
if countNeeded <= 0 then return end
if visited[itemName] then
missing[itemName] = (missing[itemName] or 0) + countNeeded
return
end
visited[itemName] = true
local group = allowGroupSub and ITEM_GROUPS[itemName] or nil
local itemsToCheck = { itemName }
local seenCheck = { [itemName] = true }
if not itemName:find("#") then
for k, v in pairs(stock) do
if v and v > 0 and not seenCheck[k] and parseItemKey(k) == itemName then
seenCheck[k] = true
table.insert(itemsToCheck, k)
end
end
end
if group then
for _, altName in ipairs(GROUPS[group]) do
if not seenCheck[altName] then
seenCheck[altName] = true
table.insert(itemsToCheck, altName)
end
end
if (stock[itemName] or 0) < countNeeded and #itemsToCheck > 1 then
table.sort(itemsToCheck, function(a, b)
local sa, sb = stock[a] or 0, stock[b] or 0
if sa ~= sb then return sa > sb end
if a == itemName then return true end
if b == itemName then return false end
return a < b
end)
end
end
for _, item in ipairs(itemsToCheck) do
local available = stock[item] or 0
if available >= countNeeded then
stock[item] = available - countNeeded
countNeeded = 0
break
elseif available > 0 then
countNeeded = countNeeded - available
stock[item] = 0
end
end
if countNeeded <= 0 then
visited[itemName] = nil
return
end
local directRec = Recipes[itemName]
if directRec and directRec.type == "fluid" then
local frec, fperOp = findFluidItemProducer(itemName)
if frec and fperOp and fperOp > 0 then
local fops = math.ceil(countNeeded / fperOp)
local flAllowSub = allowGroupSub or (not isWoodSpecificItem(itemName))
for _, it in ipairs(frec.item_inputs or {}) do
calculateCraft(it.name, it.count * fops, stock, missing, blocked, craftPlan, visited, allowPartial, flAllowSub)
end
for _, inp in ipairs(frec.inputs or {}) do
simFluidConsume(inp.name, inp.amount * fops, stock, missing, {}, visited)
end
local surplus = fops * fperOp - countNeeded
if surplus > 0 then stock[itemName] = (stock[itemName] or 0) + surplus end
table.insert(craftPlan, {
item = itemName, count = fops, output_count = fperOp,
fluid_craft = true, fluidRecipe = frec, fluidAmount = fops * fperOp,
})
else
missing[itemName] = (missing[itemName] or 0) + countNeeded
end
visited[itemName] = nil
return
end
local candidates = {}
for _, item in ipairs(itemsToCheck) do
if Recipes[item] then
table.insert(candidates, {recipe = Recipes[item], targetItem = item})
end
end
for _, item in ipairs(itemsToCheck) do
if AltRecipes[item] then
for _, altRec in ipairs(AltRecipes[item]) do
table.insert(candidates, {recipe = altRec, targetItem = item})
end
end
end
if #candidates == 0 then
local frec, fperOp = findFluidItemProducer(itemName)
if frec and fperOp and fperOp > 0 then
local fops = math.ceil(countNeeded / fperOp)
local flAllowSub = allowGroupSub or (not isWoodSpecificItem(itemName))
for _, it in ipairs(frec.item_inputs or {}) do
calculateCraft(it.name, it.count * fops, stock, missing, blocked, craftPlan, visited, allowPartial, flAllowSub)
end
for _, inp in ipairs(frec.inputs or {}) do
simFluidConsume(inp.name, inp.amount * fops, stock, missing, {}, visited)
end
local surplus = fops * fperOp - countNeeded
if surplus > 0 then stock[itemName] = (stock[itemName] or 0) + surplus end
table.insert(craftPlan, {
item = itemName, count = fops, output_count = fperOp,
fluid_craft = true, fluidRecipe = frec, fluidAmount = fops * fperOp,
})
visited[itemName] = nil
return
end
missing[itemName] = (missing[itemName] or 0) + countNeeded
visited[itemName] = nil
return
end
local chosen = nil
local chosenMissingTotal = math.huge
local chosenFullyFeasible = false
if #candidates == 1 then
chosen = candidates[1]
chosenFullyFeasible = true
else
local ownBudget = (calcBudget == 0)
if ownBudget then calcNodes = 0; calcBudget = 6000 end
for _, cand in ipairs(candidates) do
local cRec = cand.recipe
local candAllowSub = allowGroupSub or (not isWoodSpecificItem(cand.targetItem))
local opc = cRec.output_count or 1
local cc  = math.ceil(countNeeded / opc)
local cRate = getRecipeSuccessFrac(cRec)
local cBatches = (cRate < 1.0) and math.ceil(cc / cRate) or cc
local ings = {}
for i = 1, #(cRec.ingredients or {}) do
local ing = cRec.ingredients[i]
if ing and ing ~= "nil" then ings[ing] = (ings[ing] or 0) + 1 end
end
local testStock = {}
for k, v in pairs(stock) do testStock[k] = v end
local testVisited = {}
for k, v in pairs(visited) do testVisited[k] = v end
local testMissing = {}
local testBlocked = {}
local testPlan    = {}
for ingName, perCraft in pairs(ings) do
if isRecipeToolIng(cRec, ingName) then
local tNeed = computeToolsRequired(cRec, ingName, cBatches)
local tAvail = groupAvailable(ingName, testStock, false)
if tAvail < tNeed then
calculateCraft(parseItemKey(ingName), tNeed - tAvail, testStock, testMissing, testBlocked, testPlan, testVisited, false, false)
end
else
calculateCraft(ingName, perCraft * cBatches, testStock, testMissing, testBlocked, testPlan, testVisited, false, candAllowSub)
end
end
for _, finp in ipairs(cRec.fluid_inputs or {}) do
simFluidConsume(finp.name, (finp.amount or 250) * cBatches, testStock, testMissing, {}, testVisited)
end
local missingTotal = 0
for _, v in pairs(testMissing) do missingTotal = missingTotal + v end
if missingTotal == 0 then
chosen = cand
chosenFullyFeasible = true
break
end
if missingTotal < chosenMissingTotal then
chosen = cand
chosenMissingTotal = missingTotal
end
end
if ownBudget then calcNodes = 0; calcBudget = 0 end
end
if not chosen then chosen = candidates[1] end
local recipe     = chosen.recipe
local targetItem = chosen.targetItem
local stepAllowSub = allowGroupSub or (not isWoodSpecificItem(targetItem))
local outputPerCraft = recipe.output_count or 1
local craftsCount = math.ceil(countNeeded / outputPerCraft)
local rateFrac = getRecipeSuccessFrac(recipe)
local ingCounts = {}
for i = 1, #(recipe.ingredients or {}) do
local ing = recipe.ingredients[i]
if ing and ing ~= "nil" then
ingCounts[ing] = (ingCounts[ing] or 0) + 1
end
end
if allowPartial and not chosenFullyFeasible then
local maxPossibleCrafts = craftsCount
for ingName, ingCountPerCraft in pairs(ingCounts) do
if not isRecipeToolIng(recipe, ingName) then
local rawBatches
if stepAllowSub and isWoodSpecificItem(targetItem) and ingCountPerCraft > 1 and ITEM_GROUPS[ingName] then
rawBatches = 0
for _, sp in ipairs(GROUPS[ITEM_GROUPS[ingName]] or {ingName}) do
rawBatches = rawBatches + math.floor((stock[sp] or 0) / ingCountPerCraft)
end
else
local ingAvail = groupAvailable(ingName, stock, stepAllowSub)
rawBatches = math.floor(ingAvail / math.max(1, ingCountPerCraft))
end
local possible = (rateFrac < 1.0) and math.floor(rawBatches * rateFrac) or rawBatches
if possible < maxPossibleCrafts then maxPossibleCrafts = possible end
end
end
if maxPossibleCrafts > 0 then
craftsCount = maxPossibleCrafts
else
missing[itemName] = (missing[itemName] or 0) + countNeeded
visited[itemName] = nil
return
end
end
local plannedBatches = (rateFrac < 1.0) and math.ceil(craftsCount / rateFrac) or craftsCount
local totalProduced = craftsCount * outputPerCraft
for ingName, ingCountPerCraft in pairs(ingCounts) do
if isRecipeToolIng(recipe, ingName) then
local bToolKey = parseItemKey(ingName)
local toolsNeeded, brokenTools = computeToolsRequired(recipe, bToolKey, plannedBatches)
local availTools = groupAvailable(bToolKey, stock, false)
local toDeduct = math.min(availTools, brokenTools)
if toDeduct > 0 then
for k, v in pairs(stock) do
if toDeduct <= 0 then break end
if v and v > 0 and (k == bToolKey or parseItemKey(k) == bToolKey) then
local d = math.min(v, toDeduct)
stock[k] = v - d
toDeduct = toDeduct - d
end
end
end
if availTools < toolsNeeded then
calculateCraft(bToolKey, toolsNeeded - availTools, stock, missing, blocked, craftPlan, visited, allowPartial, false)
end
elseif stepAllowSub and isWoodSpecificItem(targetItem) and ingCountPerCraft > 1 and ITEM_GROUPS[ingName] then
local grpList = GROUPS[ITEM_GROUPS[ingName]] or {ingName}
local spOrder = {}
for _, sp in ipairs(grpList) do spOrder[#spOrder + 1] = sp end
table.sort(spOrder, function(a, b) return (stock[a] or 0) > (stock[b] or 0) end)
local remBatches = plannedBatches
for _, sp in ipairs(spOrder) do
if remBatches <= 0 then break end
local b = math.min(remBatches, math.floor((stock[sp] or 0) / ingCountPerCraft))
if b > 0 then
stock[sp] = (stock[sp] or 0) - b * ingCountPerCraft
remBatches = remBatches - b
end
end
if remBatches > 0 then
local savedRem = {}
for _, sp in ipairs(grpList) do
savedRem[sp] = stock[sp] or 0
stock[sp] = 0
end
calculateCraft(ingName, remBatches * ingCountPerCraft, stock, missing, blocked, craftPlan, visited, allowPartial, stepAllowSub)
for _, sp in ipairs(grpList) do
stock[sp] = (stock[sp] or 0) + (savedRem[sp] or 0)
end
end
else
calculateCraft(ingName, ingCountPerCraft * plannedBatches, stock, missing, blocked, craftPlan, visited, allowPartial, stepAllowSub)
end
end
if recipe.fluid_inputs then
for _, finp in ipairs(recipe.fluid_inputs) do
simFluidConsume(finp.name, (finp.amount or 250) * plannedBatches, stock, missing, {}, visited)
end
end
for ingName in pairs(ingCounts) do
local bKey = parseItemKey(ingName)
if missing[ingName] or missing[bKey] then
blocked[itemName] = true
break
end
end
local surplus = totalProduced - countNeeded
if surplus > 0 then stock[targetItem] = (stock[targetItem] or 0) + surplus end
table.insert(craftPlan, {
item = targetItem,
count = craftsCount,
planned_batches = plannedBatches,
type = recipe.type,
machine_name = recipe.machine_name,
ingredients = recipe.ingredients,
output_count = recipe.output_count or 1,
output_device = recipe.output_device,
tools = recipe.tools,
actions = recipe.actions,
base_ingredient = recipe.base_ingredient,
base_ingredients = recipe.base_ingredients,
fluid_inputs = recipe.fluid_inputs,
mode = recipe.mode,
success_rate = recipe.success_rate,
chance = recipe.chance,
byproducts = recipe.byproducts,
allow_group_sub = stepAllowSub
})
visited[itemName] = nil
end
local ppYieldCounter = 0
function planProduction(itemName, amount, allowPartial, stockSnapshot, allowGroupSub)
ppYieldCounter = ppYieldCounter + 1
if ppYieldCounter >= 150 then ppYieldCounter = 0; sleep(0) end
local topAllowSub = allowGroupSub and true or false
local currentStock
if stockSnapshot then
currentStock = {}
for k, v in pairs(stockSnapshot) do currentStock[k] = v end
else
currentStock = {}
for k, v in pairs(getStorageInventoryCached()) do currentStock[k] = v end
end
local missingItems = {}
local blockedItems = {}
local executionPlan = {}
calculateCraft(itemName, amount, currentStock, missingItems, blockedItems, executionPlan, {}, false, topAllowSub)
local hasMissing = false
for _ in pairs(missingItems) do hasMissing = true break end
if hasMissing then
if allowPartial then
local partialStock
if stockSnapshot then
partialStock = {}
for k, v in pairs(stockSnapshot) do partialStock[k] = v end
else
partialStock = {}
for k, v in pairs(getStorageInventoryCached()) do partialStock[k] = v end
end
local partialPlan = {}
calculateCraft(itemName, amount, partialStock, {}, {}, partialPlan, {}, true, topAllowSub)
return partialPlan, missingItems, blockedItems
else
return {}, missingItems, blockedItems
end
end
return executionPlan, {}, {}
end
function getCategoryFromPeriph(name)
    local id = name:match(":(.+)$") or name
    local cat = id:match("^(.-)_[0-9]+$") or id
    return cat
end
function getMachineDisplay(name)
local label = MachineLabels[name]
local id = name:match(":(.+)$") or name
if label and label ~= "" then
return id .. "_" .. label
end
return id
end
function checkMachineAvailable(recipe)
if not recipe then return true, nil end
local mType = recipe.type or ""
local mName = recipe.machine_name or ""
if mType == "turtle" or recipe.method == "turtle" then
for tName, enabled in pairs(Config.turtles or {}) do
if enabled and peripheral.wrap(tName) then return true, nil end
end
return false, "turtle"
end
if mType == "composite" then
if getCompositeWorkstations then
local sts = getCompositeWorkstations(recipe)
local st = sts and sts[1]
if not st or not st.targetP then return false, (st and st.targetPlatform) or mName end
if not st.outP then return false, (st and st.outputPlatform) or recipe.output_device or mName end
for _, act in ipairs(st.actions or {}) do
if act.device and act.device ~= "" and (ExcludedMachines[act.device] or not peripheral.wrap(act.device)) then
return false, act.device
end
end
return true, nil
end
if mName ~= "" and (ExcludedMachines[mName] or not peripheral.wrap(mName)) then return false, mName end
if recipe.output_device and recipe.output_device ~= "" and (ExcludedMachines[recipe.output_device] or not peripheral.wrap(recipe.output_device)) then
return false, recipe.output_device
end
for _, act in ipairs(recipe.actions or {}) do
if act.device and act.device ~= "" and (ExcludedMachines[act.device] or not peripheral.wrap(act.device)) then
return false, act.device
end
end
return true, nil
end
if recipe.output_device and recipe.output_device ~= "" then
if ExcludedMachines[recipe.output_device] or not peripheral.wrap(recipe.output_device) then
return false, recipe.output_device
end
if mName ~= "" and (ExcludedMachines[mName] or not peripheral.wrap(mName)) then
return false, mName
end
return true, nil
end
if mName == "" then return true, nil end
local available = getAvailableMachines()
for _, cg in ipairs(CustomMachineGroups) do
for _, cm in ipairs(cg.machines) do
if cm == mName then
for _, gm in ipairs(cg.machines) do
for _, am in ipairs(available) do
if am == gm and not ExcludedMachines[am] then return true, nil end
end
end
return false, mName
end
end
end
for _, m in ipairs(available) do
if m == mName and not ExcludedMachines[m] then
return true, nil
end
end
return false, mName
end
function maxCraftableExact(iName, snapCraft)
    local _, quickMiss1 = planProduction(iName, 1, false, snapCraft)
    if next(quickMiss1) then return 0 end

    -- Raw-ingredient ceiling optimization across solid recipe types
    local directMax = 10000
    local rec = Recipes[iName]
    local allowSub = not isWoodSpecificItem(iName)
    local hasSelfAlts = (AltRecipes and AltRecipes[iName] and #AltRecipes[iName] > 0)
    if not hasSelfAlts and allowSub and ITEM_GROUPS[iName] and GROUPS[ITEM_GROUPS[iName]] then
        for _, gAlt in ipairs(GROUPS[ITEM_GROUPS[iName]]) do
            if gAlt ~= iName and (Recipes[gAlt] or (AltRecipes and AltRecipes[gAlt] and #AltRecipes[gAlt] > 0)) then
                hasSelfAlts = true
                break
            end
        end
    end
    if rec and not hasSelfAlts and rec.ingredients and #rec.ingredients > 0 and rec.type ~= "fluid" then
        local ingCounts = {}
        for _, ing in ipairs(rec.ingredients) do
            if ing and ing ~= "nil" and not isRecipeToolIng(rec, ing) then
                ingCounts[ing] = (ingCounts[ing] or 0) + 1
            end
        end
        local rateFrac = getRecipeSuccessFrac(rec)
        local outPerCraft = rec.output_count or 1
        for ing, countPer in pairs(ingCounts) do
            local hasRec = (Recipes[ing] ~= nil) or (AltRecipes and AltRecipes[ing] and #AltRecipes[ing] > 0)
            if not hasRec and findFluidItemProducer then
                local frec = findFluidItemProducer(ing)
                if frec then hasRec = true end
            end
            if not hasRec and allowSub and ITEM_GROUPS[ing] and GROUPS[ITEM_GROUPS[ing]] then
                for _, alt in ipairs(GROUPS[ITEM_GROUPS[ing]]) do
                    if Recipes[alt] or (AltRecipes and AltRecipes[alt] and #AltRecipes[alt] > 0) or (findFluidItemProducer and findFluidItemProducer(alt)) then
                        hasRec = true
                        break
                    end
                end
            end
            if not hasRec then
                local avail = groupAvailable(ing, snapCraft, allowSub)
                local maxBatches = math.floor(avail / countPer)
                local maxCrafts = (rateFrac < 1.0) and math.floor(maxBatches * rateFrac) or maxBatches
                local limit = maxCrafts * outPerCraft
                if limit < directMax then directMax = limit end
            end
        end
    end
    if directMax < 1 then return 0 end
    directMax = math.min(directMax, 10000)

    if directMax <= 100 then
        local _, missDirect = planProduction(iName, directMax, false, snapCraft)
        if not next(missDirect) then return directMax end
        local lo, hi = 1, directMax - 1
        while hi - lo > 1 do
            local mid = math.floor((lo + hi) / 2)
            local _, mm = planProduction(iName, mid, false, snapCraft)
            if not next(mm) then lo = mid else hi = mid end
        end
        return lo
    end

    local _, quickMiss100 = planProduction(iName, 100, false, snapCraft)
    if next(quickMiss100) then
        local lo, hi = 1, 99
        while hi - lo > 1 do
            local mid = math.floor((lo + hi) / 2)
            local _, mm = planProduction(iName, mid, false, snapCraft)
            if not next(mm) then lo = mid else hi = mid end
        end
        return lo
    end

    local _, missDirect = planProduction(iName, directMax, false, snapCraft)
    if not next(missDirect) then return directMax end

    local lo2, hi2 = 100, directMax
    while hi2 - lo2 > 1 do
        local mid2 = math.floor((lo2 + hi2) / 2)
        local _, mm2 = planProduction(iName, mid2, false, snapCraft)
        if not next(mm2) then lo2 = mid2 else hi2 = mid2 end
    end
    return lo2
end
local scanOneFluidFast = nil

function maxCraftableFast(iName, snapCraft, cap)
    return maxCraftableExact(iName, snapCraft)
end

function scanOneRecipeFast(iName, snap)
    if not Recipes[iName] then return end
    snap = snap or getStorageInventoryCached()
    local snapCraft = {}
    for k, v in pairs(snap) do snapCraft[k] = v end
    snapCraft[iName] = 0
    local _, missing, blocked = planProduction(iName, 1, false, snapCraft)
    local maxCraftable = 0
    if not next(missing) then
        maxCraftable = maxCraftableExact(iName, snapCraft)
    end
    local hasMach, missMach = checkMachineAvailable(Recipes[iName])
    recipesScanResults[iName] = {
        missing = missing,
        blocked = blocked,
        blockedDetails = {},
        maxCraftable = maxCraftable,
        noMachine = not hasMach,
        missingMachine = missMach
    }
end

function scanAllRecipesNow()
    recipesScanResults = {}
    local snap = getStorageInventoryCached()
    local scanCounter = 0
    for iName in pairs(Recipes) do
        scanCounter = scanCounter + 1
        if scanCounter % 10 == 0 then sleep(0) end
        pcall(scanOneRecipeFast, iName, snap)
    end
end

function scanKeepItemsNow()
    local snap = getStorageInventoryCached()
    local fstock = nil
    for itemName in pairs(Autostock) do
        if itemName:sub(1, 2) == "f:" then
            local fname = fluidNameFromKey(itemName)
            if not fstock then
                fstock = {}
                for k, v in pairs(getFluidInventory()) do fstock[fluidNameFromKey(k)] = v end
            end
            if scanOneFluidFast then
                pcall(scanOneFluidFast, fname, fstock, snap)
            end
        elseif Recipes[itemName] then
            pcall(scanOneRecipeFast, itemName, snap)
        end
    end
end
local _COLOR_BLIT = {
[colors.white]     = "0", [colors.orange]    = "1",
[colors.magenta]   = "2", [colors.lightBlue] = "3",
[colors.yellow]    = "4", [colors.lime]       = "5",
[colors.pink]      = "6", [colors.gray]       = "7",
[colors.lightGray] = "8", [colors.cyan]       = "9",
[colors.purple]    = "a", [colors.blue]       = "b",
[colors.brown]     = "c", [colors.green]      = "d",
[colors.red]       = "e", [colors.black]      = "f",
}
local _fb     = {}
local _fbLast = {}
local _fbW, _fbH = 0, 0
function _bufInit(w, h)
_fbW, _fbH = w, h
_fb = {}
for y = 1, h do
local t, f, b = {}, {}, {}
for x = 1, w do t[x] = " "; f[x] = "0"; b[x] = "f" end
_fb[y] = {t = t, f = f, b = b}
end
end
function _bufWrite(x, y, text, fg, bg)
local row = _fb[y]; if not row then return end
local fh = _COLOR_BLIT[fg] or "0"
local bh = _COLOR_BLIT[bg] or "f"
for i = 1, #text do
local col = x + i - 1
if col >= 1 and col <= _fbW then
row.t[col] = text:sub(i, i)
row.f[col] = fh
row.b[col] = bh
end
end
end
function _bufClearLine(y, bg)
_bufWrite(1, y, string.rep(" ", _fbW), colors.white, bg)
end
function _bufFillRect(x, y, rw, rh, bg)
local row = string.rep(" ", rw)
for dy = 0, rh - 1 do _bufWrite(x, y + dy, row, colors.white, bg) end
end
function _bufFlush()
for y = 1, _fbH do
local row = _fb[y]
local ts  = table.concat(row.t)
local fs  = table.concat(row.f)
local bs  = table.concat(row.b)
local prev = _fbLast[y]
if not prev or prev[1] ~= ts or prev[2] ~= fs or prev[3] ~= bs then
monitor.setCursorPos(1, y)
monitor.blit(ts, fs, bs)
_fbLast[y] = {ts, fs, bs}
end
end
end
function drawText(x, y, text, fg, bg)
_bufWrite(x, y, text, fg or colors.white, bg or colors.black)
end
function drawProgressBar(x, y, width, current, max, bgColor)
bgColor = bgColor or colors.black
local percent = math.min(1, math.max(0, current / max))
local filledChars = math.floor(percent * (width - 2))
local emptyChars = (width - 2) - filledChars
local barStr = "[" .. string.rep("|", filledChars) .. string.rep(".", emptyChars) .. "]"
drawText(x, y, barStr, colors.lime, bgColor)
drawText(x + width + 1, y, string.format("%d%%", math.floor(percent * 100)), colors.white, bgColor)
end
function timedRead(timeout, initial)
local buf = initial or ""
if buf ~= " more" then term.write(buf) end
local timer = os.startTimer(timeout)
while true do
local ev, a = os.pullEvent()
if ev == "char" then
if timer then os.cancelTimer(timer); timer = nil end
buf = buf .. a
term.write(a)
elseif ev == "key" then
if a == keys.enter or a == keys.numPadEnter then
if timer then os.cancelTimer(timer) end
return buf
elseif a == keys.backspace and #buf > 0 then
buf = buf:sub(1, -2)
local cx, cy = term.getCursorPos()
term.setCursorPos(cx - 1, cy)
term.write(" ")
term.setCursorPos(cx - 1, cy)
end
elseif ev == "timer" and a == timer then
return nil
end
end
end
getMachinePool = function(machineName)
for _, cg in ipairs(CustomMachineGroups or {}) do
for _, cm in ipairs(cg.machines or {}) do
if cm == machineName then
local pool = {}
for _, pm in ipairs(cg.machines or {}) do table.insert(pool, pm) end
table.sort(pool)
return pool
end
end
end
return { machineName }
end
sleepCheckCancel = function(t)
local timer = os.startTimer(t)
local deadline = os.clock() + t + 0.1
while true do
local ev, a, b, c = os.pullEvent()
if ev == "timer" and a == timer then return end
if ev == "monitor_touch" and craftCancelY and c == craftCancelY then
if b >= craftCancelX1 and b <= craftCancelX2 then
cancelCrafting = true
os.cancelTimer(timer)
return
elseif craftFinishX1 and craftFinishX2 and b >= craftFinishX1 and b <= craftFinishX2 then
finishTestEarly = true
os.cancelTimer(timer)
return
end
end
if os.clock() >= deadline then os.cancelTimer(timer); return end
end
end
function findFreeSpaceStorage(names)
for _, stoName in ipairs(names) do
local sto = peripheral.wrap(stoName)
if sto and sto.pullItems and sto.list and sto.size then
local okS, sz = pcall(sto.size)
local okL, lst = pcall(sto.list)
if okS and okL and sz and lst then
local used = 0
for _ in pairs(lst) do used = used + 1 end
if sz - used >= 16 then return sto end
end
end
end
return nil
end
function blindUnloadTurtle(tName, names)
local sto = findFreeSpaceStorage(names)
if not sto then return false end
for slot = 1, 16 do pcall(sto.pullItems, tName, slot, 64) end
return true
end
function cleanupCraftMachines(activeStorages, list)
local cleanList = list or craftCleanupMachines
local stuckMachines = {}
local stuckSeen     = {}
for _, entry in ipairs(cleanList) do
if entry and entry.name then
local p = peripheral.wrap(entry.name)
local anyStuck = false
if p and p.list then
local s, items = pcall(p.list)
if s and items then
for slot, item in pairs(items) do
if item then
if entry.pullNames == nil or entry.pullNames[item.name] then
local remaining = item.count
if p.pushItems then
for _, stoName in ipairs(activeStorages) do
if remaining <= 0 then break end
local ok, mv = pcall(p.pushItems, stoName, slot, remaining)
if ok and mv and mv > 0 then remaining = remaining - mv end
end
end
if remaining > 0 then
for _, stoName in ipairs(activeStorages) do
if remaining <= 0 then break end
local sto = peripheral.wrap(stoName)
if sto and sto.pullItems then
local ok2, mv2 = pcall(sto.pullItems, entry.name, slot, remaining)
if ok2 and mv2 and mv2 > 0 then remaining = remaining - mv2 end
end
end
end
if remaining > 0 then anyStuck = true end
end
end
end
end
else
if not blindUnloadTurtle(entry.name, activeStorages) then
anyStuck = true
end
end
if anyStuck and not stuckSeen[entry.name] then
stuckSeen[entry.name] = true
table.insert(stuckMachines, entry.name)
end
end
end
if not list then craftCleanupMachines = {} end
if #stuckMachines > 0 then
local shortNames = {}
for _, n in ipairs(stuckMachines) do
local disp = n
if getMachineDisplay then disp = getMachineDisplay(n) end
table.insert(shortNames, disp)
end
uiMessage = "CANCEL: stuck in " .. table.concat(shortNames, ", ")
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(4)
end
end
local drawInterface
drawFluidProgress = function(subLabel, current, total, workers)
local co = lockOwnerId()
local ent = fluidInlineByCo[co]
if ent then
local short = tostring(subLabel):match(":(.+)$") or tostring(subLabel)
local line = {
desc = short .. " (fluid)", done = current or 0, total = total or 0,
machines = workers or 0, topup = false,
}
ent.ctx.active[ent.node] = line
if displayCtx and displayCtx ~= ent.ctx then
displayCtx.active["FLUIDNEST:" .. tostring(co)] = line
end
return
end
if drawInterface then drawInterface() end
local w, h = monitor.getSize()
local pW = 46
local pH = 10
local pX = math.max(1, math.floor((w - pW) / 2) + 1)
local pY = math.max(1, math.floor((h - pH) / 2) + 1)
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdr = " MANUFACTURING ACTIVE "
drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.orange)
local stepStr = string.format("Step %d/%d", fluidStepNum, math.max(fluidStepNum, fluidStepTotal))
drawText(pX + 2, pY + 2, stepStr, colors.white, colors.gray)
local fStr = "[FLUID]"
drawText(pX + pW - #fStr - 2, pY + 2, fStr, colors.cyan, colors.gray)
if workers and workers > 1 then
local wStr = "[" .. workers .. "x parallel] "
drawText(pX + pW - #fStr - 2 - #wStr, pY + 2, wStr, colors.cyan, colors.gray)
end
local subShort = (tostring(subLabel):match(":(.+)$") or tostring(subLabel))
local subStr = ("Sub-task: " .. total .. " ops " .. subShort):sub(1, pW - 4)
drawText(pX + 2, pY + 3, subStr, colors.lightGray, colors.gray)
local goal = fluidGoalLabel ~= "" and fluidGoalLabel or subLabel
local cleanGoal = (tostring(goal):match(":(.+)$") or tostring(goal)):upper()
local itemStr = (">> " .. cleanGoal .. " <<"):sub(1, pW - 4)
drawText(pX + math.floor((pW - #itemStr) / 2), pY + 5, itemStr, colors.yellow, colors.gray)
local progStr = string.format("Progress: %d / %d", current, total)
drawText(pX + math.floor((pW - #progStr) / 2), pY + 7, progStr, colors.lime, colors.gray)
local barWidth = math.min(28, pW - 14)
local barX = pX + math.floor((pW - barWidth) / 2)
drawProgressBar(barX, pY + 8, barWidth, current, total, colors.gray)
local cancelStr = " [ CANCEL ] "
local cancelBtnX = pX + math.floor((pW - #cancelStr) / 2)
local cancelBtnY = pY + pH - 1
drawText(cancelBtnX, cancelBtnY, cancelStr, colors.white, colors.red)
craftCancelY  = cancelBtnY
craftCancelX1 = cancelBtnX
craftCancelX2 = cancelBtnX + #cancelStr - 1
_bufFlush()
end
local ensureFluidAvailable
local fluidProducers
function findFluidProducer(fluidName)
local p = fluidProducers(fluidName)[1]
if p then return p.recipe, p.perOp end
return nil
end
function countFluidSteps(fluidName, amount, simStock, visited)
local have = simStock[fluidName] or 0
if have >= amount then simStock[fluidName] = have - amount; return 0 end
local shortfall = amount - have
simStock[fluidName] = 0
if visited[fluidName] then return 0 end
local recipe, perOp = findFluidProducer(fluidName)
if not recipe or not perOp or perOp <= 0 then return 0 end
local ops = math.ceil(shortfall / perOp)
visited[fluidName] = true
local cnt = 0
for _, inp in ipairs(recipe.inputs or {}) do
cnt = cnt + countFluidSteps(inp.name, ops * inp.amount, simStock, visited)
end
visited[fluidName] = nil
simStock[fluidName] = (simStock[fluidName] or 0) + (ops * perOp - shortfall)
return cnt + 1
end
function countTopFluidSteps(recipe, targetName, amount)
local perOp = nil
for _, o in ipairs(recipe.outputs or {}) do if o.name == targetName then perOp = o.amount; break end end
if not perOp then for _, o in ipairs(recipe.item_outputs or {}) do if o.name == targetName then perOp = o.count; break end end end
if not perOp or perOp <= 0 then return 1 end
local ops = math.ceil(amount / perOp)
local simStock = {}
for k, v in pairs(getFluidInventory()) do simStock[fluidNameFromKey(k)] = v end
local cnt = 0
local visited = {}
for _, inp in ipairs(recipe.inputs or {}) do
cnt = cnt + countFluidSteps(inp.name, ops * inp.amount, simStock, visited)
end
return cnt + 1
end
function estimatePlanStages(plan)
local n = 0
for _, step in ipairs(plan) do
if step.count and step.count > 0 then
if step.fluid_craft then
local c = 1
local okC, r = pcall(countTopFluidSteps, step.fluidRecipe, step.item, step.fluidAmount)
if okC and type(r) == "number" and r > 0 then c = r end
n = n + c
else
n = n + 1
end
end
end
return n
end
local FLUID_MAX_CAP = 100000
fluidProducers = function(fluidName)
local cached = _fpCache[fluidName]
if cached then return cached end
local out = {}
local fk = fluidKey(fluidName)
local function tryAdd(rec, key, own, isPrimary, altIdx)
if type(rec) ~= "table" then return end
for _, o in ipairs(rec.outputs or {}) do
if o.name == fluidName and o.amount and o.amount > 0 then
out[#out + 1] = {recipe = rec, perOp = o.amount, key = key,
own = own, isPrimary = isPrimary, altIdx = altIdx}
return
end
end
end
tryAdd(FluidRecipes[fk], fk, true, true, nil)
for i, alt in ipairs(FluidAltRecipes[fk] or {}) do tryAdd(alt, fk, true, false, i) end
for key, rec in pairs(FluidRecipes) do
if key ~= fk then tryAdd(rec, key, false, false, nil) end
end
for key, alts in pairs(FluidAltRecipes) do
if key ~= fk then
for _, alt in ipairs(alts) do tryAdd(alt, key, false, false, nil) end
end
end
_fpCache[fluidName] = out
return out
end
function removeFluidRecipeRef(rec)
for key, r in pairs(FluidRecipes) do
if r == rec then
local alts = FluidAltRecipes[key]
if alts and alts[1] then
FluidRecipes[key] = table.remove(alts, 1)
if #alts == 0 then FluidAltRecipes[key] = nil end
else
FluidRecipes[key] = nil
end
return
end
end
for key, alts in pairs(FluidAltRecipes) do
for i, r in ipairs(alts) do
if r == rec then
table.remove(alts, i)
if #alts == 0 then FluidAltRecipes[key] = nil end
return
end
end
end
end
local maxFluidCraftable
local _mfcMemo, _mfcStock, _mfcIStock = {}, nil, nil
function fluidRecipeMaxOps(recipe, fstock, istock, visited)
local maxOps = math.huge
local tainted = false
for _, inp in ipairs(recipe.inputs or {}) do
local avail, t = maxFluidCraftable(inp.name, fstock, istock, visited)
if t then tainted = true end
local possible = (inp.amount and inp.amount > 0) and math.floor(avail / inp.amount) or 0
if possible < maxOps then maxOps = possible end
end
local allowSub = true
if recipe.item_outputs and recipe.item_outputs[1] and isWoodSpecificItem(recipe.item_outputs[1].name) then
allowSub = false
end
for _, it in ipairs(recipe.item_inputs or {}) do
local availI, tI = maxItemCraftable(it.name, istock, fstock, {}, allowSub)
if tI then tainted = true end
local possible = (it.count and it.count > 0) and math.floor(availI / it.count) or 0
if possible < maxOps then maxOps = possible end
end
if maxOps == math.huge then maxOps = FLUID_MAX_CAP end
return maxOps, tainted
end
maxFluidCraftable = function(fluidName, fstock, istock, visited)
if _mfcStock ~= fstock or _mfcIStock ~= istock then
_mfcMemo = {}; _mfcStock = fstock; _mfcIStock = istock
end
local have = fstock[fluidName] or 0
calcNodes = calcNodes + 1
if calcBudget > 0 and calcNodes > calcBudget then return have, true end
if calcNodes % 1024 == 0 then sleep(0) end
if visited[fluidName] then return have, true end
local cached = _mfcMemo[fluidName]
if cached ~= nil then return cached, false end
local prods = fluidProducers(fluidName)
if #prods == 0 then _mfcMemo[fluidName] = have; return have, false end
visited[fluidName] = true
local best = 0
local tainted = false
for _, pr in ipairs(prods) do
local ops, t = fluidRecipeMaxOps(pr.recipe, fstock, istock, visited)
if t then tainted = true end
local produced = ops * pr.perOp
if produced > best then best = produced end
end
visited[fluidName] = nil
local result = math.min(have + best, have + FLUID_MAX_CAP)
if not tainted then _mfcMemo[fluidName] = result end
return result, tainted
end
simFluidConsume = function(fluidName, amountMb, stock, missing, fvisited, itemVisited)
calcNodes = calcNodes + 1
if calcBudget > 0 and calcNodes > calcBudget then return end
if calcNodes % 1024 == 0 then sleep(0) end
if not amountMb or amountMb <= 0 then return end
if not stock.__fl then
stock.__fl = true
for k, v in pairs(getFluidInventoryCached()) do
if stock[k] == nil then stock[k] = v end
end
end
local key = fluidKey(fluidName)
local have = stock[key] or 0
if have >= amountMb then stock[key] = have - amountMb; return end
local shortfall = amountMb - have
stock[key] = 0
if fvisited[fluidName] then
missing[key] = (missing[key] or 0) + shortfall
return
end
local prods = fluidProducers(fluidName)
if #prods == 0 then
missing[key] = (missing[key] or 0) + shortfall
return
end
fvisited[fluidName] = true
local function consumeVia(p, st, miss)
local fops = math.ceil(shortfall / p.perOp)
for _, inp in ipairs(p.recipe.inputs or {}) do
simFluidConsume(inp.name, inp.amount * fops, st, miss, fvisited, itemVisited)
end
for _, it in ipairs(p.recipe.item_inputs or {}) do
calculateCraft(it.name, it.count * fops, st, miss, {}, {}, itemVisited or {}, false, true)
end
end
local usedP
if #prods == 1 then
consumeVia(prods[1], stock, missing)
usedP = prods[1]
else
for _, p in ipairs(prods) do
local stCopy = {}
for k, v in pairs(stock) do stCopy[k] = v end
local missCopy = {}
consumeVia(p, stCopy, missCopy)
if next(missCopy) == nil then
for k, v in pairs(stCopy) do stock[k] = v end
usedP = p
break
end
end
if not usedP then
consumeVia(prods[1], stock, missing)
usedP = prods[1]
end
end
fvisited[fluidName] = nil
local fops = math.ceil(shortfall / usedP.perOp)
local surplus = fops * usedP.perOp - shortfall
if surplus > 0 then stock[key] = (stock[key] or 0) + surplus end
end
ITEM_MAX_CAP = 10000
local _micMemo, _micStock = {}, nil
function maxItemCraftable(itemName, istock, fstock, visited, allowGroupSub)
if _micStock ~= istock then _micMemo = {}; _micStock = istock end
visited = visited or {}
local allowSub = (allowGroupSub == true)
local have = groupAvailable(itemName, istock, allowSub)
calcNodes = calcNodes + 1
if calcBudget > 0 and calcNodes > calcBudget then return have, true end
if visited[itemName] then return have, true end
local memoKey = itemName .. (allowSub and "|G" or "|E")
local cached = _micMemo[memoKey]
if cached ~= nil then return cached, false end
local recs = {}
local checkItems = { itemName }
if allowSub and ITEM_GROUPS[itemName] and GROUPS[ITEM_GROUPS[itemName]] then
for _, alt in ipairs(GROUPS[ITEM_GROUPS[itemName]]) do
if alt ~= itemName then checkItems[#checkItems + 1] = alt end
end
end
for _, chk in ipairs(checkItems) do
if Recipes[chk] then recs[#recs + 1] = { rec = Recipes[chk], target = chk } end
for _, a in ipairs(AltRecipes[chk] or {}) do recs[#recs + 1] = { rec = a, target = chk } end
end
if #recs == 0 then _micMemo[memoKey] = have; return have, false end
visited[itemName] = true
local best, tainted = 0, false
for _, entry in ipairs(recs) do
local rec = entry.rec
local tgt = entry.target
local stepAllowSub = allowSub or (not isWoodSpecificItem(tgt))
local produced = 0
if rec.type == "fluid" then
local frec, fperOp = findFluidItemProducer(tgt)
if frec and fperOp and fperOp > 0 then
local ops, t = fluidRecipeMaxOps(frec, fstock or {}, istock, {})
if t then tainted = true end
produced = (ops or 0) * fperOp
end
else
local ings = {}
for i = 1, #(rec.ingredients or {}) do
local ing = rec.ingredients[i]
if ing and ing ~= "nil" then ings[ing] = (ings[ing] or 0) + 1 end
end
local opc = rec.output_count or 1
local rRate = getRecipeSuccessFrac(rec)
local maxOps = math.huge
for ing, per in pairs(ings) do
if isRecipeToolIng(rec, ing) then
local bTool = parseItemKey(ing)
local av, t = maxItemCraftable(bTool, istock, fstock, visited, false)
if t then tainted = true end
if av < 1 then
maxOps = 0
else
local tInfo = rec.tools and (rec.tools[ing] or rec.tools[bTool])
local dur = (type(tInfo) == "table" and tonumber(tInfo.durability)) or getToolDefaultDurability(bTool) or 250
local p = av * math.max(1, dur)
if p < maxOps then maxOps = p end
end
else
local av, t = maxItemCraftable(ing, istock, fstock, visited, stepAllowSub)
if t then tainted = true end
local rawOps = math.floor(av / math.max(1, per))
local p = (rRate < 1.0) and math.floor(rawOps * rRate) or rawOps
if p < maxOps then maxOps = p end
end
end
if maxOps == math.huge then maxOps = 0 end
produced = maxOps * opc
end
if produced > best then best = produced end
end
visited[itemName] = nil
local result = math.min(have + best, have + ITEM_MAX_CAP)
if not tainted then _micMemo[memoKey] = result end
return result, tainted
end
scanOneFluidFast = function(fname, fstock, istock)
    if not fname or fname == "" then return end
    if not fstock then
        fstock = {}
        for k, v in pairs(getFluidInventory()) do fstock[fluidNameFromKey(k)] = v end
    end
    istock = istock or getStorageInventoryCached()
    local ok, total = pcall(maxFluidCraftable, fname, fstock, istock, {})
    if ok and type(total) == "number" then
        fluidScanResults[fname] = math.min(9999, math.max(0, total - (fstock[fname] or 0)))
    else
        fluidScanResults[fname] = 0
    end
end

function scanAllFluidsNow()
    fluidScanResults = {}
    local fstock = {}
    for k, v in pairs(getFluidInventory()) do fstock[fluidNameFromKey(k)] = v end
    local istock = getStorageInventoryCached()
    local seen = {}
    local scanCount = 0
    local function scanRec(rec)
        for _, o in ipairs(rec.outputs or {}) do
            if not seen[o.name] then
                seen[o.name] = true
                scanOneFluidFast(o.name, fstock, istock)
                scanCount = scanCount + 1
                if scanCount % 5 == 0 then sleep(0) end
            end
        end
    end
    for _, rec in pairs(FluidRecipes) do scanRec(rec) end
    for _, alts in pairs(FluidAltRecipes) do
        for _, rec in ipairs(alts) do scanRec(rec) end
    end
end
ensureItemAvailable = function(itemName, count, allowGroupSub)
if cancelCrafting then return false, {"Cancelled by user."} end
local allowSub = (allowGroupSub == true)
local function curHave()
return groupAvailable(itemName, getStorageInventoryCached(), allowSub)
end
local have = curHave()
if have >= count then return true, nil end
invalidateStockCache()
have = curHave()
if have >= count then return true, nil end
if crossCraftDepth >= 6 then
return false, {"Recursion too deep: " .. (itemName:match(":(.+)$") or itemName)}
end
crossCraftDepth = crossCraftDepth + 1
local attempts = 0
local lastMissing = nil
while have < count and not cancelCrafting do
attempts = attempts + 1
if attempts > 12 then break end
local plan, miss = planProduction(itemName, count, true, nil, allowSub)
lastMissing = miss
if not (plan and #plan > 0) then break end
local before = have
runCraftingProcess(plan)
have = curHave()
if have <= before then break end
end
crossCraftDepth = crossCraftDepth - 1
if have < count then
local sn = itemName:match(":(.+)$") or itemName
local lines = {string.format("Need %dx %s (have %d)", count, sn, have)}
if lastMissing and next(lastMissing) then
local parts = {}
for mName, mCnt in pairs(lastMissing) do
if not (mName == itemName) then
parts[#parts + 1] = string.format("%dx %s", mCnt, mName:match(":(.+)$") or mName)
end
end
table.sort(parts)
if #parts > 0 then
local shown = {}
for i = 1, math.min(3, #parts) do shown[i] = parts[i] end
local msg = "Need: " .. table.concat(shown, ", ")
if #parts > 3 then msg = msg .. " +" .. (#parts - 3) end
table.insert(lines, msg)
end
end
return false, lines
end
return true, nil
end
function ensureItemInputs(recipe, ops)
local allowSub = true
if recipe.item_outputs and recipe.item_outputs[1] and isWoodSpecificItem(recipe.item_outputs[1].name) then
allowSub = false
end
for _, it in ipairs(recipe.item_inputs or {}) do
local ok, err = ensureItemAvailable(it.name, ops * it.count, allowSub)
if not ok then return false, err end
end
return true, nil
end
function fluidRecipeShortInputs(recipe, ops)
local parts = {}
local fInv = getFluidInventory()
for _, inp in ipairs(recipe.inputs or {}) do
local need = ops * inp.amount
local have = fInv[fluidKey(inp.name)] or 0
if have < need then parts[#parts + 1] = string.format("%d mB %s", need - have, inp.name:match(":(.+)$") or inp.name) end
end
local iInv = getStorageInventory()
for _, it in ipairs(recipe.item_inputs or {}) do
local need = ops * it.count
local have = iInv[it.name] or 0
local grp = ITEM_GROUPS[it.name]
if grp then for _, alt in ipairs(GROUPS[grp]) do have = have + (iInv[alt] or 0) end end
if have < need then parts[#parts + 1] = string.format("%dx %s", need - have, it.name:match(":(.+)$") or it.name) end
end
return parts
end
function appendMissingLine(lines, parts)
if parts and #parts > 0 then
table.sort(parts)
local shown = {}
for i = 1, math.min(3, #parts) do shown[i] = parts[i] end
local msg = "Need: " .. table.concat(shown, ", ")
if #parts > 3 then msg = msg .. " +" .. (#parts - 3) end
table.insert(lines, msg)
end
return lines
end
ensureFluidAvailable = function(fluidName, amount, visited)
if cancelCrafting then return false, {"Cancelled by user."} end
local have = (getFluidInventoryCached())[fluidKey(fluidName)] or 0
if have >= amount then return true, nil end
invalidateStockCache()
have = (getFluidInventoryCached())[fluidKey(fluidName)] or 0
if have >= amount then return true, nil end
if visited[fluidName] then
local sn = fluidName:match(":(.+)$") or fluidName
return false, {"Recursion cycle on " .. sn}
end
local prods = fluidProducers(fluidName)
if #prods == 0 then
local sn = fluidName:match(":(.+)$") or fluidName
return false, {string.format("Need %d mB %s, have %d (no recipe)", amount, sn, have)}
end
visited[fluidName] = true
local attempts = 0
while have < amount do
if cancelCrafting then visited[fluidName] = nil; return false, {"Cancelled by user."} end
attempts = attempts + 1
if attempts > 8 then
visited[fluidName] = nil
local sn = fluidName:match(":(.+)$") or fluidName
local lines = {string.format("Need %d mB %s, made only %d", amount, sn, have)}
local p0 = prods[1]
if p0 then appendMissingLine(lines, fluidRecipeShortInputs(p0.recipe, math.ceil((amount - have) / p0.perOp))) end
return false, lines
end
local shortfall = amount - have
local fstock = {}
for k, v in pairs(getFluidInventoryCached()) do fstock[fluidNameFromKey(k)] = v end
local istock = getStorageInventoryCached()
local chosen, chosenOps
for _, p in ipairs(prods) do
local ops = math.ceil(shortfall / p.perOp)
local okM, maxOps = pcall(fluidRecipeMaxOps, p.recipe, fstock, istock, {})
if okM and type(maxOps) == "number" and maxOps >= ops then
chosen = p; chosenOps = ops; break
end
end
if not chosen then chosen = prods[1]; chosenOps = math.ceil(shortfall / prods[1].perOp) end
local recipe, ops = chosen.recipe, chosenOps
for _, inp in ipairs(recipe.inputs or {}) do
local ok, err = ensureFluidAvailable(inp.name, ops * inp.amount, visited)
if not ok then visited[fluidName] = nil; return false, err end
end
local okItems, itemErr = ensureItemInputs(recipe, ops)
if not okItems then visited[fluidName] = nil; return false, itemErr end
local okRun, errRun = runFluidCraft({recipe = recipe, ops = ops, perOp = chosen.perOp, label = fluidName})
if not okRun then visited[fluidName] = nil; return false, errRun end
invalidateStockCache()
local newHave = (getFluidInventory())[fluidKey(fluidName)] or 0
if newHave <= have then
visited[fluidName] = nil
local sn = fluidName:match(":(.+)$") or fluidName
local lines = {string.format("Need %d mB %s, stuck at %d", amount, sn, newHave)}
appendMissingLine(lines, fluidRecipeShortInputs(recipe, ops))
return false, lines
end
have = newHave
end
visited[fluidName] = nil
return true, nil
end
function produceFluid(recipe, targetName, amount)
if cancelCrafting then return false, {"Cancelled by user."}, 0 end
local prods = fluidProducers(targetName)
if #prods > 1 then
local fstock = {}
for k, v in pairs(getFluidInventoryCached()) do fstock[fluidNameFromKey(k)] = v end
local istock = getStorageInventoryCached()
for _, p in ipairs(prods) do
local ops = math.ceil(amount / p.perOp)
local okM, maxOps = pcall(fluidRecipeMaxOps, p.recipe, fstock, istock, {})
if okM and type(maxOps) == "number" and maxOps >= ops then
recipe = p.recipe; break
end
end
end
local perOp = nil
for _, o in ipairs(recipe.outputs or {}) do
if o.name == targetName then perOp = o.amount; break end
end
if not perOp then
for _, o in ipairs(recipe.item_outputs or {}) do
if o.name == targetName then perOp = o.count; break end
end
end
if not perOp or perOp <= 0 then return false, {"Bad recipe output amount"}, 0 end
local ops = math.ceil(amount / perOp)
local visited = {}
for _, inp in ipairs(recipe.inputs or {}) do
local ok, err = ensureFluidAvailable(inp.name, ops * inp.amount, visited)
if not ok then return false, err, 0 end
end
local okItems, itemErr = ensureItemInputs(recipe, ops)
if not okItems then return false, itemErr, 0 end
return runFluidCraft({recipe = recipe, ops = ops, perOp = perOp, label = targetName})
end
function runFluidCraftAmount(recipe, targetName, amount)
local isItem = false
for _, o in ipairs(recipe.item_outputs or {}) do
if o.name == targetName then isItem = true; break end
end
fluidGoalLabel = targetName
fluidStepNum = 0
fluidStepTotal = countTopFluidSteps(recipe, targetName, amount)
systemStatus = "AUTO_CRAFT"
fluidCraftMsg = "Crafting..."
cancelCrafting = false
craftLocks = {}; fluidTankClaims = 0; _fluidStoreBusy = false; fluidInlineByCo = {}
drawInterface()
local okRun, runErr, produced = produceFluid(recipe, targetName, amount)
systemStatus = "IDLE"
fluidCraftMsg = ""
cancelCrafting = false
if okRun then
local prod = {{name = targetName, amount = produced, unit = isItem and "x" or "mB"}}
craftCompletePopup = {outputs = prod, timer = os.startTimer(10)}
clearCraftError()
else
triggerCraftError("! CANNOT CRAFT", runErr or {"Unknown error"}, 10)
end
return okRun, produced, isItem
end
function doFluidCraftFlow(recipe, targetName)
local isItemTarget = false
for _, o in ipairs(recipe.item_outputs or {}) do
if o.name == targetName then isItemTarget = true; break end
end
fluidRecipePicker = nil
fluidKeepName = nil
fluidCraftMode = {recipe = recipe, target = targetName, isItem = isItemTarget}
itemToCraft = targetName
craftQuantity = isItemTarget and 1 or 1000
isRequestMode = false
isSettingKeepLimit = false
qtyOriginTab = "RECIPES"
pickerMaxCapped = false
pickerMaxCraftable = 0
pickerMaxComputed = false
if Config.autoMaxCalc ~= false then pickerComputeMax() end
currentTab = "QUANTITY_PICKER"
end
function pickerComputeMax()
pickerMaxCraftable = 0
pickerMaxCapped = false
if fluidCraftMode and fluidCraftMode.recipe then
local recipe       = fluidCraftMode.recipe
local targetName   = fluidCraftMode.target
local isItemTarget = fluidCraftMode.isItem
local fstock = {}
for k, v in pairs(getFluidInventory()) do fstock[fluidNameFromKey(k)] = v end
local istock = getStorageInventory()
local perOp = 1
if isItemTarget then
for _, o in ipairs(recipe.item_outputs or {}) do if o.name == targetName then perOp = o.count; break end end
else
for _, o in ipairs(recipe.outputs or {}) do if o.name == targetName then perOp = o.amount; break end end
end
local okM, ops = pcall(fluidRecipeMaxOps, recipe, fstock, istock, {})
if not okM or type(ops) ~= "number" then ops = 0 end
pickerMaxCraftable = math.min(FLUID_MAX_CAP, ops * (perOp > 0 and perOp or 1))
else
local target = itemToCraft
local snap = getStorageInventoryCached()
local snapCraft = {}
for k, v in pairs(snap) do snapCraft[k] = v end
snapCraft[target] = 0
local okMx, mx = pcall(maxCraftableExact, target, snapCraft)
pickerMaxCraftable = (okMx and type(mx) == "number") and mx or 0
local cs = recipesScanResults[target]
if cs then cs.maxCraftable = pickerMaxCraftable end
end
pickerMaxComputed = true
end
function notifyCraftDone(label, qty, isFluid)
local topic = Config.ntfy_topic
if not topic or topic == "" then return end
if not (http and http.request) then return end
local url = topic:find("://") and topic or ("https://ntfy.sh/" .. topic)
local short = label:match(":(.+)$") or label
local body
if qty and qty > 0 then
body = isFluid and (short .. " " .. qty .. " mB") or (qty .. "x " .. short)
else
body = short .. " done"
end
pcall(function()
http.request({url = url, method = "POST", body = body,
headers = {["Title"] = "AEGIS craft done", ["Tags"] = "white_check_mark"}})
end)
end
function notifyCraftFail(label)
local topic = Config.ntfy_topic
if not topic or topic == "" then return end
if not (http and http.request) then return end
local url = topic:find("://") and topic or ("https://ntfy.sh/" .. topic)
local short = label and (label:match(":(.+)$") or label) or "craft"
pcall(function()
http.request({url = url, method = "POST", body = "INTERRUPTED: " .. short,
headers = {["Title"] = "AEGIS craft failed", ["Priority"] = "high", ["Tags"] = "x"}})
end)
end
function ntfyBaseUrl()
local topic = Config.ntfy_topic
if not topic or topic == "" then return nil end
return topic:find("://") and topic or ("https://ntfy.sh/" .. topic)
end
function ntfyPublish(body, title, tags)
local url = ntfyBaseUrl()
if not url then return end
if not (http and http.request) then return end
pcall(function()
http.request({url = url, method = "POST", body = tostring(body),
headers = {["Title"] = title or "AEGIS", ["Tags"] = tags or "robot"}})
end)
end
function buildStatusText()
local ctx = displayCtx
if ctx and (ctx.total or 0) > 0 and not ctx.done then
local sDone  = craftStageDone or 0
local sTotal = math.max(craftStageTotal or 0, sDone, 1)
local pct  = math.floor(sDone / sTotal * 100)
local goal = ctx.finalGoalItem or "?"
goal = goal:match(":(.+)$") or goal
local lines = { goal .. " " .. pct .. "% (" .. sDone .. "/" .. sTotal .. ")" }
local n = 0
for _, a in pairs(ctx.active or {}) do
if n >= 6 then break end
lines[#lines + 1] = "- " .. tostring(a.desc or "?") .. " " .. (a.done or 0) .. "/" .. (a.total or 0)
n = n + 1
end
if n == 0 then lines[#lines + 1] = "(scheduling...)" end
return table.concat(lines, "\n")
end
if systemStatus and systemStatus ~= "IDLE" then
local s = "Busy: " .. tostring(systemStatus)
if fluidGoalLabel and fluidGoalLabel ~= "" then
local g = fluidGoalLabel:match(":(.+)$") or fluidGoalLabel
s = s .. "\n" .. g .. " step " .. (fluidStepNum or 0) .. "/" .. math.max(fluidStepNum or 0, fluidStepTotal or 0)
end
return s
end
local q = #(craftQueue or {})
if q > 0 then return "IDLE. Queue: " .. q .. " waiting." end
return "IDLE. No active craft."
end
function buildQueueText()
local q = craftQueue or {}
if #q == 0 then return "Queue empty." end
local lines = {}
for i = 1, math.min(8, #q) do
local qe = q[i]
local nm = qe.name:match(":(.+)$") or qe.name
local unit = (qe.kind == "fluid" and not qe.isItem) and " mB" or "x"
lines[#lines + 1] = i .. ". " .. nm .. " " .. qe.qty .. unit .. (qe.failed and " [FAIL]" or "")
end
if #q > 8 then lines[#lines + 1] = "... +" .. (#q - 8) .. " more" end
return table.concat(lines, "\n")
end
function ntfyPollCommands()
if Config.ntfy_cmds == false then return end
local url = ntfyBaseUrl()
if not url then return end
if not (http and http.get) then return end
local since = ntfyLastId and ("&since=" .. textutils.urlEncode(ntfyLastId)) or "&since=15s"
local ok, handle = pcall(http.get, url .. "/json?poll=1" .. since)
if not ok or not handle then return end
local body = handle.readAll(); handle.close()
if not body or body == "" then return end
local want = nil
for line in body:gmatch("[^\n]+") do
local okJ, obj = pcall(textutils.unserializeJSON, line)
if okJ and type(obj) == "table" and obj.event == "message" then
if obj.id then ntfyLastId = obj.id end
local title = tostring(obj.title or "")
if title:sub(1, 5) ~= "AEGIS" then
local msg = tostring(obj.message or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
if msg:sub(1, 1) == "/" then msg = msg:sub(2) end
if msg == "status" or msg == "stat" or msg == "s" then want = "status"
elseif msg == "queue" or msg == "q" then want = "queue"
elseif msg == "cancel" or msg == "stop" then want = "cancel" end
end
end
end
if want == "status" then
ntfyPublish(buildStatusText(), "AEGIS status", "bar_chart")
elseif want == "queue" then
ntfyPublish(buildQueueText(), "AEGIS queue", "clipboard")
elseif want == "cancel" then
cancelCrafting = true
ntfyPublish("Cancel requested.", "AEGIS status", "octagonal_sign")
end
end
function queueRunOne(qe)
if qe.kind == "fluid" then
local fOk, fProduced, fIsItem = runFluidCraftAmount(qe.recipe, qe.name, qe.qty)
if fOk then
notifyCraftDone(qe.name, fProduced, not fIsItem)
return true
end
notifyCraftFail(qe.name)
local reason = {}
for li = 1, math.min(4, #craftErrorLines) do reason[li] = craftErrorLines[li] end
if #reason == 0 then reason[1] = "Fluid craft failed" end
return false, reason
end
local preStock = groupAvailable(qe.name, getStorageInventory(), false)
cancelCrafting = false
local plan, missingRes = planProduction(qe.name, qe.qty, true)
if plan and #plan == 0 and not next(missingRes or {}) then return true end
if next(missingRes or {}) then
local reason = {}
for mName, mCnt in pairs(missingRes) do
if #reason >= 4 then break end
reason[#reason + 1] = "Need " .. mCnt .. "x " .. (mName:match(":(.+)$") or mName)
end
if #reason == 0 then reason[1] = "Missing components" end
return false, reason
end
local craftOk = false
if plan and #plan > 0 then
craftOk = runCraftingProcess(plan)
local tlA = 0
while craftOk and not cancelCrafting and tlA < 12 do
flushCraftBuffer()
invalidateStockCache()
local totalNow = groupAvailable(qe.name, getStorageInventory(), false)
if totalNow >= qe.qty then break end
tlA = tlA + 1
local rPlan = planProduction(qe.name, qe.qty, true)
if not (rPlan and #rPlan > 0) then break end
local beforeTL = totalNow
if runCraftingProcess(rPlan) then craftOk = true end
flushCraftBuffer()
invalidateStockCache()
if groupAvailable(qe.name, getStorageInventory(), false) <= beforeTL then break end
end
end
if craftOk then
flushCraftBuffer()
invalidateStockCache()
notifyCraftDone(qe.name, math.max(0, groupAvailable(qe.name, getStorageInventory(), false) - preStock), false)
return true
end
notifyCraftFail(qe.name)
local reason = {}
if craftErrorTitle then reason[#reason + 1] = craftErrorTitle end
for li = 1, #craftErrorLines do
if #reason >= 4 then break end
reason[#reason + 1] = tostring(craftErrorLines[li])
end
for mName, mCnt in pairs(missingRes or {}) do
if #reason >= 4 then break end
reason[#reason + 1] = "Need " .. mCnt .. "x " .. (mName:match(":(.+)$") or mName)
end
if #reason == 0 then reason[1] = "Craft failed" end
return false, reason
end

function handleRemotePacket(senderId, msg)
    if type(msg) ~= "table" or not msg.type then return end
    local mtype = msg.type

    if mtype == "PAIR" then
        local alreadyPaired = Config.paired_remotes and (Config.paired_remotes[senderId] or Config.paired_remotes[tostring(senderId)])
        if alreadyPaired or os.clock() < pairingActiveUntil then
            if not Config.paired_remotes then Config.paired_remotes = {} end
            Config.paired_remotes[tostring(senderId)] = true
            Config.paired_remotes[tonumber(senderId)] = true
            saveData()
            rednet.send(senderId, {
                type = "PAIR_OK",
                serverId = os.getComputerID(),
                serverLabel = os.getComputerLabel() or ("Aegis #" .. os.getComputerID())
            }, "AEGIS_REMOTE")
        else
            rednet.send(senderId, {
                type = "PAIR_DENIED",
                reason = "Pairing not active on server. Press [PAIR REMOTE] in NETWORK tab."
            }, "AEGIS_REMOTE")
        end
        return
    end

    local isPaired = Config.paired_remotes and (Config.paired_remotes[senderId] or Config.paired_remotes[tostring(senderId)])
    if not isPaired then
        rednet.send(senderId, { type = "UNAUTHORIZED", reason = "Remote not paired with server" }, "AEGIS_REMOTE")
        return
    end

    if mtype == "PING" then
        rednet.send(senderId, { type = "PONG", serverId = os.getComputerID() }, "AEGIS_REMOTE")

    elseif mtype == "GET_STATE" then
        local totSlots, usedSlots = 0, 0
        for vName, en in pairs(Config.main_vaults or {}) do
            if en and not SYSTEM_SIDES[vName] then
                local st = StorageIndex.vaultStats[vName]
                if st then
                    totSlots = totSlots + (st.max or 0)
                    usedSlots = usedSlots + (st.used or 0)
                end
            end
        end
        rednet.send(senderId, {
            type = "STATE",
            totSlots = totSlots,
            usedSlots = usedSlots,
            freeSlots = math.max(0, totSlots - usedSlots),
            status = systemStatus or "IDLE",
            crafting = (systemStatus ~= "IDLE"),
            queueCount = #(craftQueue or {}),
            errorCount = #(errorLog or {}),
            autostockPaused = Config.autostock_paused or false
        }, "AEGIS_REMOTE")

    elseif mtype == "GET_RECIPES" then
        local stockInv = getStorageInventoryCached()
        local list = {}
        local sortedNames = {}
        for rName in pairs(Recipes) do table.insert(sortedNames, rName) end
        table.sort(sortedNames)
        for _, rName in ipairs(sortedNames) do
            local sCount = stockInv and (stockInv[rName] or 0) or 0
            if recipesScanResults[rName] == nil and scanOneRecipeFast then
                pcall(scanOneRecipeFast, rName, stockInv)
            end
            local scanRes = recipesScanResults[rName]
            local maxC = scanRes and scanRes.maxCraftable or 0
            local dName = getItemDisplayName(rName)
            local kRule = Autostock[rName]
            table.insert(list, {
                id = rName,
                name = dName,
                stock = sCount,
                maxCraft = maxC,
                isKept = (kRule ~= nil),
                threshold = kRule and (kRule.threshold or kRule.limit) or nil,
                target = kRule and (kRule.target or kRule.limit) or nil
            })
        end
        rednet.send(senderId, { type = "RECIPES", list = list }, "AEGIS_REMOTE")

    elseif mtype == "GET_KEEP" then
        local stockInv = getStorageInventoryCached()
        local list = {}
        for kItem, settings in pairs(Autostock) do
            if kItem:sub(1, 2) ~= "f:" then
                local sCount = stockInv and (stockInv[kItem] or 0) or 0
                local dName = getItemDisplayName(kItem)
                table.insert(list, {
                    id = kItem,
                    name = dName,
                    stock = sCount,
                    threshold = settings.threshold or settings.limit or 1,
                    target = settings.target or settings.limit or 1,
                    paused = settings.paused or false,
                    order = settings.order or 99999
                })
            end
        end
        table.sort(list, function(a, b)
            if a.order ~= b.order then return a.order < b.order end
            return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name))
        end)
        rednet.send(senderId, {
            type = "KEEP",
            list = list,
            pausedAll = Config.autostock_paused or false
        }, "AEGIS_REMOTE")

    elseif mtype == "GET_VAULTS" then
        local totSlots, usedSlots = 0, 0
        local list = {}
        for vName, en in pairs(Config.main_vaults or {}) do
            if en and not SYSTEM_SIDES[vName] then
                local st = StorageIndex.vaultStats[vName] or { used = 0, max = 0, free = 0, pct = 0 }
                totSlots = totSlots + (st.max or 0)
                usedSlots = usedSlots + (st.used or 0)
                local dName = getMachineDisplay(vName) or vName
                table.insert(list, {
                    name = dName,
                    used = st.used or 0,
                    max = st.max or 0,
                    free = math.max(0, (st.max or 0) - (st.used or 0)),
                    pct = (st.max and st.max > 0) and math.floor(((st.used or 0) / st.max) * 100) or 0
                })
            end
        end
        table.sort(list, function(a, b) return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name)) end)
        rednet.send(senderId, {
            type = "VAULTS",
            list = list,
            totSlots = totSlots,
            usedSlots = usedSlots,
            freeSlots = math.max(0, totSlots - usedSlots)
        }, "AEGIS_REMOTE")

    elseif mtype == "GET_ERRORS" then
        rednet.send(senderId, { type = "ERRORS", list = errorLog or {} }, "AEGIS_REMOTE")

    elseif mtype == "CLEAR_ERRORS" then
        errorLog = {}
        saveErrorLog()
        pcall(fs.delete, ERROR_LOG_FILE .. ".bak")
        rednet.send(senderId, { type = "OK", msg = "Errors cleared" }, "AEGIS_REMOTE")

    elseif mtype == "CRAFT_ORDER" then
        local item = msg.item
        local qty = tonumber(msg.qty) or 1
        if item and qty > 0 then
            local qe = { kind = "item", name = item, qty = qty, senderId = senderId }
            table.insert(remoteCraftQueue, qe)
            rednet.send(senderId, { type = "OK", msg = "Ordered " .. getItemDisplayName(item) .. " x" .. qty }, "AEGIS_REMOTE")
        else
            rednet.send(senderId, { type = "ERR", msg = "Invalid craft order" }, "AEGIS_REMOTE")
        end

    elseif mtype == "KEEP_SET" then
        local item = msg.item
        local thr = math.max(1, tonumber(msg.threshold) or 1)
        local tgt = math.max(thr, tonumber(msg.target) or thr)
        if item then
            local existingOrder = Autostock[item] and Autostock[item].order
            local existingPaused = Autostock[item] and Autostock[item].paused or false
            if not existingOrder then
                local maxOrder = 0
                for _, s in pairs(Autostock) do maxOrder = math.max(maxOrder, s.order or 0) end
                existingOrder = maxOrder + 1
            end
            Autostock[item] = { threshold = thr, target = tgt, paused = existingPaused, order = existingOrder }
            saveData()
            rednet.send(senderId, { type = "OK", msg = "Keep rule saved" }, "AEGIS_REMOTE")
        end

    elseif mtype == "KEEP_TOGGLE" then
        local item = msg.item
        if item and Autostock[item] then
            Autostock[item].paused = not Autostock[item].paused
            saveData()
            rednet.send(senderId, { type = "OK", paused = Autostock[item].paused }, "AEGIS_REMOTE")
        end

    elseif mtype == "KEEP_DELETE" then
        local item = msg.item
        if item and Autostock[item] then
            Autostock[item] = nil
            saveData()
            rednet.send(senderId, { type = "OK", msg = "Rule deleted" }, "AEGIS_REMOTE")
        end

    elseif mtype == "KEEP_PAUSE_ALL" then
        Config.autostock_paused = not Config.autostock_paused
        saveData()
        rednet.send(senderId, { type = "OK", paused = Config.autostock_paused }, "AEGIS_REMOTE")

    elseif mtype == "KEEP_TRIGGER" then
        local item = msg.item
        if item and Autostock[item] then
            local kTarget = Autostock[item].target or 1
            local kNeeded = math.max(1, kTarget - groupAvailable(item, getStorageInventory(), false))
            if kNeeded > 0 then
                table.insert(remoteCraftQueue, { kind = "item", name = item, qty = kTarget, senderId = senderId })
                rednet.send(senderId, { type = "OK", msg = "Triggered: " .. getItemDisplayName(item) .. " x" .. kNeeded }, "AEGIS_REMOTE")
            else
                rednet.send(senderId, { type = "OK", msg = "Stock already at target" }, "AEGIS_REMOTE")
            end
        else
            rednet.send(senderId, { type = "ERR", msg = "Rule not found" }, "AEGIS_REMOTE")
        end

    elseif mtype == "KEEP_TRIGGER_ALL" then
        table.insert(remoteCraftQueue, { kind = "check_autostock" })
        rednet.send(senderId, { type = "OK", msg = "Autostock check queued" }, "AEGIS_REMOTE")

    elseif mtype == "GET_QUEUE" then
        rednet.send(senderId, { type = "QUEUE", list = craftQueue or {} }, "AEGIS_REMOTE")

    elseif mtype == "QUEUE_ADD" then
        local item = msg.item
        local qty = tonumber(msg.qty) or 1
        if item and qty > 0 then
            table.insert(craftQueue, { kind = "item", name = item, qty = qty })
            saveData()
            rednet.send(senderId, { type = "OK", msg = "Enqueued " .. getItemDisplayName(item) .. " x" .. qty }, "AEGIS_REMOTE")
        else
            rednet.send(senderId, { type = "ERR", msg = "Invalid item or quantity" }, "AEGIS_REMOTE")
        end

    elseif mtype == "QUEUE_RUN" then
        local idx = tonumber(msg.idx)
        if idx and craftQueue[idx] then
            local qe = table.remove(craftQueue, idx)
            saveData()
            table.insert(remoteCraftQueue, qe)
            rednet.send(senderId, { type = "OK", msg = "Craft started: " .. getItemDisplayName(qe.name) .. " x" .. qe.qty }, "AEGIS_REMOTE")
        else
            rednet.send(senderId, { type = "ERR", msg = "Queue item not found" }, "AEGIS_REMOTE")
        end

    elseif mtype == "QUEUE_RUN_ALL" then
        local count = #craftQueue
        if count > 0 then
            while #craftQueue > 0 do
                table.insert(remoteCraftQueue, table.remove(craftQueue, 1))
            end
            saveData()
            rednet.send(senderId, { type = "OK", msg = "Running all " .. count .. " queued craft(s)" }, "AEGIS_REMOTE")
        else
            rednet.send(senderId, { type = "OK", msg = "Queue is empty" }, "AEGIS_REMOTE")
        end

    elseif mtype == "QUEUE_DELETE" then
        local idx = tonumber(msg.idx)
        if idx and craftQueue[idx] then
            table.remove(craftQueue, idx)
            saveData()
            rednet.send(senderId, { type = "OK", msg = "Removed from queue" }, "AEGIS_REMOTE")
        else
            rednet.send(senderId, { type = "ERR", msg = "Queue item not found" }, "AEGIS_REMOTE")
        end

    elseif mtype == "QUEUE_EDIT" then
        local idx = tonumber(msg.idx)
        local qty = tonumber(msg.qty)
        if idx and craftQueue[idx] and qty and qty > 0 then
            craftQueue[idx].qty = qty
            saveData()
            rednet.send(senderId, { type = "OK", msg = "Queue quantity updated" }, "AEGIS_REMOTE")
        else
            rednet.send(senderId, { type = "ERR", msg = "Invalid edit parameters" }, "AEGIS_REMOTE")
        end

    elseif mtype == "GET_MAX" then
        -- On-demand max craftable calculation for the pocket order screen
        local item = msg.item
        local mx = nil
        if item and Recipes[item] then
            local res = recipesScanResults[item]
            if res == nil and scanOneRecipeFast then
                pcall(scanOneRecipeFast, item, getStorageInventoryCached())
                res = recipesScanResults[item]
            end
            if res then mx = res.maxCraftable end
        end
        rednet.send(senderId, { type = "MAX", item = item, max = mx }, "AEGIS_REMOTE")
    end
end
function groupKeyOf(machineName)
for _, cg in ipairs(CustomMachineGroups or {}) do
for _, cm in ipairs(cg.machines or {}) do
if cm == machineName then return "cg:" .. (cg.name or tostring(cg)) end
end
end
return "m:" .. machineName
end
function pinnedToken(name)
if not name or name == "" then return nil end
for _, cg in ipairs(CustomMachineGroups or {}) do
for _, cm in ipairs(cg.machines or {}) do
if cm == name then return "cg:" .. (cg.name or tostring(cg)) end
end
end
return "m:" .. name
end
function fluidRecipeTokens(fr)
local toks = {}
local seen = {}
local function add(tok)
if tok and not seen[tok] then seen[tok] = true; toks[#toks + 1] = tok end
end
if fr then
local anyDev = (fr.output_device and fr.output_device ~= "")
or (fr.item_input_device and fr.item_input_device ~= "")
or (fr.fluid_input_device and fr.fluid_input_device ~= "")
or (fr.item_output_device and fr.item_output_device ~= "")
if anyDev then
add(pinnedToken(fr.machine_name))
add(pinnedToken(fr.output_device))
add(pinnedToken(fr.item_input_device))
add(pinnedToken(fr.fluid_input_device))
add(pinnedToken(fr.item_output_device))
else
add(groupKeyOf(fr.machine_name))
end
end
if #toks == 0 then toks[1] = "FLUID" end
return toks
end
function stepTokens(step)
if step.fluid_craft then
return fluidRecipeTokens(step.fluidRecipe)
end
if step.type == "turtle" then return { "TURTLE" } end
if step.type == "composite" then
local toks = {}
local seen = {}
local function add(tok)
if tok and not seen[tok] then seen[tok] = true; toks[#toks + 1] = tok end
end
add(pinnedToken(step.machine_name))
if step.output_device and step.output_device ~= "" then
add(pinnedToken(step.output_device))
end
for _, act in ipairs(step.actions or {}) do
if act.device and act.device ~= "" then add(pinnedToken(act.device)) end
end
return toks
end
if step.output_device and step.output_device ~= "" then
local toks = {}
local seen = {}
local function add(tok)
if tok and not seen[tok] then seen[tok] = true; toks[#toks + 1] = tok end
end
add(pinnedToken(step.machine_name))
add(pinnedToken(step.output_device))
return toks
end
return { groupKeyOf(step.machine_name) }
end
function sleepYield(t, ctx)
if cancelCrafting or (ctx and ctx.failed) then sleep(0); return end
local timer = os.startTimer(t)
local deadline = os.clock() + t + 0.1
while true do
if cancelCrafting or (ctx and ctx.failed) then os.cancelTimer(timer); return end
local ev, a = os.pullEvent()
if ev == "timer" and a == timer then return end
if os.clock() >= deadline then os.cancelTimer(timer); return end
if cancelCrafting or (ctx and ctx.failed) then os.cancelTimer(timer); return end
end
end
function getCompositeWorkstations(step)
    local targetName = step.machine_name
    local targetP = (not ExcludedMachines[targetName]) and peripheral.wrap(targetName) or nil
    local outDevName = (step.output_device and step.output_device ~= "") and step.output_device or targetName
    local outP = (not ExcludedMachines[outDevName]) and peripheral.wrap(outDevName) or nil

    local defActions = {}
    for _, act in ipairs(step.actions or {}) do
        local newAct = {}
        for k2, v2 in pairs(act) do newAct[k2] = v2 end
        table.insert(defActions, newAct)
    end

    local defaultStation = {
        targetPlatform = targetName,
        targetP = targetP,
        outputPlatform = outDevName,
        outP = outP,
        actions = defActions
    }

    local matchedCG = nil
    for _, cg in ipairs(CustomMachineGroups or {}) do
        for _, cm in ipairs(cg.machines or {}) do
            if cm == targetName then
                matchedCG = cg
                break
            end
        end
        if matchedCG then break end
    end

    if not matchedCG then
        return { defaultStation }
    end

    local cgAvailable = {}
    for _, m in ipairs(matchedCG.machines or {}) do
        if peripheral.wrap(m) and not ExcludedMachines[m] then
            table.insert(cgAvailable, m)
        end
    end

    local targetBase = getMachineBaseName(targetName)
    local targets = {}
    for _, m in ipairs(cgAvailable) do
        if getMachineBaseName(m) == targetBase then
            table.insert(targets, m)
        end
    end
    table.sort(targets, naturalSortCompare)

    if #targets == 0 then
        return { defaultStation }
    end

    local actionPools = {}
    for aIdx, act in ipairs(step.actions or {}) do
        local aBase = getMachineBaseName(act.device)
        local pool = {}
        for _, m in ipairs(cgAvailable) do
            if getMachineBaseName(m) == aBase then
                table.insert(pool, m)
            end
        end
        table.sort(pool, naturalSortCompare)
        actionPools[aIdx] = pool
    end

    local outputPool = nil
    if step.output_device and step.output_device ~= "" and step.output_device ~= targetName then
        local oBase = getMachineBaseName(step.output_device)
        outputPool = {}
        for _, m in ipairs(cgAvailable) do
            if getMachineBaseName(m) == oBase then
                table.insert(outputPool, m)
            end
        end
        table.sort(outputPool, naturalSortCompare)
    end

    local numStations = #targets
    for aIdx, pool in ipairs(actionPools) do
        if #pool < numStations then
            numStations = #pool
        end
    end
    if outputPool and #outputPool < numStations then
        numStations = #outputPool
    end

    if numStations == 0 then
        return { defaultStation }
    end
    if numStations == 1 and targetP and outP and targets[1] == targetName then
        local allDefOk = true
        for _, act in ipairs(defActions) do
            if act.device and act.device ~= "" and (ExcludedMachines[act.device] or not peripheral.wrap(act.device)) then
                allDefOk = false
                break
            end
        end
        if allDefOk then
            return { defaultStation }
        end
    end

    local stations = {}
    for k = 1, numStations do
        local stTarget = targets[k]
        local stOut = outputPool and outputPool[k] or stTarget
        local stActions = {}
        for aIdx, act in ipairs(step.actions or {}) do
            local newAct = {}
            for k2, v2 in pairs(act) do newAct[k2] = v2 end
            newAct.device = actionPools[aIdx][k]
            table.insert(stActions, newAct)
        end
        table.insert(stations, {
            targetPlatform = stTarget,
            targetP = peripheral.wrap(stTarget),
            outputPlatform = stOut,
            outP = peripheral.wrap(stOut),
            actions = stActions
        })
    end

    return stations
end

function executeCompositeStep(step, ctx, node, drawProgress, desc)
    local sortedStorages = ctx.sortedStorages
    local i = node.idx
    local plan = ctx.plan
    local stations = getCompositeWorkstations(step)
    local numStations = #stations

    if not stations[1].targetP or not stations[1].outP then
        local missingName = not stations[1].targetP and stations[1].targetPlatform or stations[1].outputPlatform
        local mDisp = getMachineDisplay(missingName)
        local itemShort = step.item:match(":(.+)$") or step.item
        craftErrorTitle = "! MACHINE NOT FOUND"
        craftErrorLines = {
            "Machine not found: " .. mDisp,
            "Required for: " .. itemShort,
            "Use [E] in RECIPES to reassign.",
        }
        return false
    end

    local totalOps = step.count
    local outputPerOp = step.output_count or 1
    local totalExpected = totalOps * outputPerOp
    local totalCollected = 0
    local totalStarted = 0
    local baseIngList = {}
    if step.base_ingredients and #step.base_ingredients > 0 then
        for _, bi in ipairs(step.base_ingredients) do
            if bi.item and bi.item ~= "" then
                table.insert(baseIngList, { item = bi.item, count = bi.count or 1 })
            end
        end
    elseif step.base_ingredient and step.base_ingredient.item and step.base_ingredient.item ~= "" then
        table.insert(baseIngList, { item = step.base_ingredient.item, count = step.base_ingredient.count or 1 })
    elseif step.ingredients and step.ingredients[1] then
        table.insert(baseIngList, { item = step.ingredients[1], count = 1 })
    end
    local baseIng = baseIngList[1] or { item = step.item, count = 1 }
    local basePerOp = baseIng.count or 1

    local isChanceMode = (step.mode == "chance") or (step.success_rate and tonumber(step.success_rate) < 100) or (step.chance and tonumber(step.chance) < 1)
    if step.mode and step.mode ~= "chance" then isChanceMode = false end
    local rateFrac = getRecipeSuccessFrac(step)
    local plannedBatches = step.planned_batches or (isChanceMode and math.ceil(totalOps / rateFrac) or totalOps)
    local toolSet = step.tools or {}
    local allowSub = (step.allow_group_sub ~= nil) and step.allow_group_sub or (not isWoodSpecificItem(step.item))

    local function isActionTool(act)
        if not act or act.type ~= "item" or not act.item then return false end
        if act.is_tool then return true end
        local bKey = parseItemKey(act.item)
        return (toolSet[act.item] ~= nil) or (toolSet[bKey] ~= nil)
    end

    local function getActionToolDurability(act)
        local bKey = parseItemKey(act.item)
        if act.durability and tonumber(act.durability) and tonumber(act.durability) > 0 then
            return math.floor(tonumber(act.durability))
        end
        local tEntry = toolSet[act.item] or toolSet[bKey]
        if type(tEntry) == "table" and tonumber(tEntry.durability) and tonumber(tEntry.durability) > 0 then
            return math.floor(tonumber(tEntry.durability))
        end
        return getToolDefaultDurability(bKey) or 250
    end

    local function collectToStorage(fromPeriph, fromName, slot, count)
        local moved = 0
        for _, stoName in ipairs(sortedStorages) do
            if moved >= count then break end
            if fromPeriph.pushItems then
                local sP, mv = pcall(fromPeriph.pushItems, stoName, slot, count - moved)
                if sP and mv and mv > 0 then moved = moved + mv end
            end
            if moved < count then
                local sto = peripheral.wrap(stoName)
                if sto and sto.pullItems then
                    local sQ, mv2 = pcall(sto.pullItems, fromName, slot, count - moved)
                    if sQ and mv2 and mv2 > 0 then moved = moved + mv2 end
                end
            end
        end
        return moved
    end

    local function unloadAllActionDevices()
        for _, st in ipairs(stations) do
            for _, act in ipairs(st.actions or {}) do
                if act.type == "item" and act.device then
                    local actSub = (not isActionTool(act)) and allowSub or false
                    local dev = peripheral.wrap(act.device)
                    if dev and dev.list then
                        local s, its = pcall(dev.list)
                        if s and its then
                            for sl, it in pairs(its) do
                                if it and itemMatchesOrGroup(it.name, act.item, actSub) then
                                    if it.nbt and it.nbt ~= "" then
                                        local iKey = makeItemKey(it.name, it.nbt)
                                        resolveItemDisplayName(dev, sl, iKey)
                                    end
                                    collectToStorage(dev, act.device, sl, it.count)
                                end
                            end
                        end
                    end
                end
            end
        end
        for _, st in ipairs(stations) do
            if st.targetP and st.targetP.list then
                local s, its = pcall(st.targetP.list)
                if s and its then
                    for sl, it in pairs(its) do
                        if it then
                            for _, bEntry in ipairs(baseIngList) do
                                if itemMatchesOrGroup(it.name, bEntry.item, allowSub) then
                                    collectToStorage(st.targetP, st.targetPlatform, sl, it.count)
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
        flushCraftBuffer()
        invalidateStockCache()
    end

    for k, st in ipairs(stations) do
        local targetSize = 1
        if st.targetP and st.targetP.size then
            local okSz, sz = pcall(st.targetP.size)
            if okSz and type(sz) == "number" then targetSize = sz end
        end
        st.isSingleSlotShared = (st.outputPlatform == st.targetPlatform and targetSize <= 1)
        st.assignedOps = math.floor(totalOps / numStations) + (k <= (totalOps % numStations) and 1 or 0)
        st.expectedToolOps = math.floor(plannedBatches / numStations) + (k <= (plannedBatches % numStations) and 1 or 0)
        st.startedOps = 0
        st.fluidPreloadedOps = 0
    end

    if step.count and step.count > 0 and not cancelCrafting then
        local ingNeeds = {}
        for _, bEntry in ipairs(baseIngList) do
            if bEntry.item and bEntry.item ~= "" then
                local bCount = bEntry.count or 1
                ingNeeds[bEntry.item] = (ingNeeds[bEntry.item] or 0) + bCount * plannedBatches
            end
        end
        local hasAnyTool = false
        local initialToolNeeds = {}
        for _, st in ipairs(stations) do
            if st.assignedOps > 0 then
                for _, act in ipairs(st.actions or {}) do
                    if act.type == "item" and act.item and act.item ~= "" then
                        if isActionTool(act) then
                            hasAnyTool = true
                            local bKey = parseItemKey(act.item)
                            local devP = peripheral.wrap(act.device)
                            local devHas = 0
                            if devP and devP.list then
                                local sL, dList = pcall(devP.list)
                                if sL and dList then
                                    for _, it in pairs(dList) do
                                        if it and itemMatches(it.name, bKey) then devHas = devHas + (it.count or 0) end
                                    end
                                end
                            end
                            if devHas < 1 then
                                initialToolNeeds[bKey] = (initialToolNeeds[bKey] or 0) + 1
                            end
                        end
                    end
                end
            end
        end
        for _, act in ipairs(step.actions or {}) do
            if act.type == "item" and act.item and act.item ~= "" and not isActionTool(act) then
                ingNeeds[act.item] = (ingNeeds[act.item] or 0) + (act.count or 1) * plannedBatches
            end
        end
        for bKey, needT in pairs(initialToolNeeds) do
            ingNeeds[bKey] = math.max(ingNeeds[bKey] or 0, needT)
        end
        releaseTokens(node.tokens)
        for ingName, needCnt in pairs(ingNeeds) do
            local subOk = (initialToolNeeds[ingName] == nil) and allowSub or false
            ensureItemAvailable(ingName, needCnt, subOk)
        end
        while not cancelCrafting and not (ctx and ctx.failed) do
            if tryAcquireTokens(node.tokens) then break end
            sleepYield(0.2, ctx)
        end
        if cancelCrafting or (ctx and ctx.failed) then return false end

        -- PRE-FLIGHT TOOL DURABILITY CHECK (Load deployers -> Poll durability -> Auto-craft spares -> Abort if insufficient)
        if hasAnyTool then
            -- Step A: Load 1 tool into each active station's tool deployer
            for _, st in ipairs(stations) do
                if st.assignedOps > 0 then
                    for _, act in ipairs(st.actions or {}) do
                        if isActionTool(act) and act.device then
                            local bKey = parseItemKey(act.item)
                            local devP = peripheral.wrap(act.device)
                            local devHas = 0
                            if devP and devP.list then
                                local sL, dList = pcall(devP.list)
                                if sL and dList then
                                    for _, it in pairs(dList) do
                                        if it and itemMatches(it.name, bKey) then devHas = devHas + (it.count or 0) end
                                    end
                                end
                            end
                            if devHas < 1 then
                                pushFromStorage(bKey, 1, act.device, nil, false)
                            end
                        end
                    end
                end
            end

            -- Step B: Poll deployers via getItemDetail and compute spare tool deficit
            local sparesNeededByTool = {}
            local emptyDevsByTool = {}
            for _, st in ipairs(stations) do
                if st.assignedOps > 0 then
                    local opsForSt = math.max(st.assignedOps, st.expectedToolOps or st.assignedOps)
                    for _, act in ipairs(st.actions or {}) do
                        if isActionTool(act) and act.device then
                            local bKey = parseItemKey(act.item)
                            local wholeDur = getActionToolDurability(act)
                            sparesNeededByTool[bKey] = sparesNeededByTool[bKey] or 0
                            emptyDevsByTool[bKey] = emptyDevsByTool[bKey] or {}

                            local devP = peripheral.wrap(act.device)
                            local foundSlot = nil
                            if devP and devP.list then
                                local sL, dList = pcall(devP.list)
                                if sL and dList then
                                    for sl, it in pairs(dList) do
                                        if it and itemMatches(it.name, bKey) and (it.count or 0) > 0 then
                                            foundSlot = sl
                                            break
                                        end
                                    end
                                end
                            end

                            if foundSlot and devP.getItemDetail then
                                local okD, det = pcall(devP.getItemDetail, foundSlot)
                                local maxD = (okD and det and det.maxDamage and det.maxDamage > 0) and det.maxDamage or wholeDur
                                local dmg = (okD and det and type(det.damage) == "number") and det.damage or 0
                                local remDur = math.max(1, maxD - dmg)
                                if remDur < opsForSt then
                                    local extraTools = math.ceil((opsForSt - remDur) / wholeDur)
                                    sparesNeededByTool[bKey] = sparesNeededByTool[bKey] + extraTools
                                end
                            elseif foundSlot then
                                if wholeDur < opsForSt then
                                    local extraTools = math.ceil((opsForSt - wholeDur) / wholeDur)
                                    sparesNeededByTool[bKey] = sparesNeededByTool[bKey] + extraTools
                                end
                            else
                                table.insert(emptyDevsByTool[bKey], act.device)
                                local totalForSt = math.max(1, math.ceil(opsForSt / wholeDur))
                                sparesNeededByTool[bKey] = sparesNeededByTool[bKey] + totalForSt
                            end
                        end
                    end
                end
            end

            -- Step C: Auto-craft missing spare tools before starting the main craft
            flushCraftBuffer()
            invalidateStockCache()
            local craftErrByTool = {}
            local needSubcraft = false
            for bKey, needSpares in pairs(sparesNeededByTool) do
                if needSpares > 0 then
                    local availSpares = groupAvailable(bKey, getStorageInventoryCached(), false)
                    if availSpares < needSpares then
                        needSubcraft = true
                        break
                    end
                end
            end

            if needSubcraft then
                releaseTokens(node.tokens)
                for bKey, needSpares in pairs(sparesNeededByTool) do
                    if needSpares > 0 then
                        local availSpares = groupAvailable(bKey, getStorageInventoryCached(), false)
                        if availSpares < needSpares then
                            local okT, errT = ensureItemAvailable(bKey, needSpares, false)
                            if not okT then
                                craftErrByTool[bKey] = errT
                            end
                        end
                    end
                end
                while not cancelCrafting and not (ctx and ctx.failed) do
                    if tryAcquireTokens(node.tokens) then break end
                    sleepYield(0.2, ctx)
                end
                if cancelCrafting or (ctx and ctx.failed) then
                    unloadAllActionDevices()
                    return false
                end
            end

            -- Push into any deployers that were empty during Step A
            for bKey, devList in pairs(emptyDevsByTool) do
                for _, devName in ipairs(devList) do
                    local pushed = pushFromStorage(bKey, 1, devName, nil, false)
                    if pushed > 0 then
                        sparesNeededByTool[bKey] = math.max(0, (sparesNeededByTool[bKey] or 0) - 1)
                    end
                end
            end

            -- Step D: Final Pre-Flight Verification (Abort & Log Error if still insufficient)
            flushCraftBuffer()
            invalidateStockCache()
            local failedTool = nil
            local deficitAmount = 0
            for _, st in ipairs(stations) do
                if st.assignedOps > 0 and not failedTool then
                    for _, act in ipairs(st.actions or {}) do
                        if isActionTool(act) and act.device then
                            local bKey = parseItemKey(act.item)
                            local devP = peripheral.wrap(act.device)
                            local hasLoaded = false
                            if devP and devP.list then
                                local sL, dList = pcall(devP.list)
                                if sL and dList then
                                    for _, it in pairs(dList) do
                                        if it and itemMatches(it.name, bKey) and (it.count or 0) > 0 then
                                            hasLoaded = true
                                            break
                                        end
                                    end
                                end
                            end
                            if not hasLoaded then
                                failedTool = bKey
                                deficitAmount = math.max(1, sparesNeededByTool[bKey] or 1)
                                break
                            end
                        end
                    end
                end
            end
            if not failedTool then
                local curSnap = getStorageInventoryCached()
                for bKey, needSpares in pairs(sparesNeededByTool) do
                    if needSpares > 0 then
                        local availNow = groupAvailable(bKey, curSnap, false)
                        if availNow < needSpares then
                            failedTool = bKey
                            deficitAmount = needSpares - availNow
                            break
                        end
                    end
                end
            end

            if failedTool then
                unloadAllActionDevices()
                local tDisp = getItemDisplayName(failedTool)
                local itemDisp = getItemDisplayName(step.item)
                local errLines = {
                    "Craft aborted: " .. itemDisp .. " x" .. tostring(totalExpected),
                    string.format("Tool deficit: %s (missing %dx)", tDisp, deficitAmount),
                }
                local subErr = craftErrByTool[failedTool]
                if subErr and #subErr > 0 then
                    for _, el in ipairs(subErr) do
                        if #errLines < 4 then table.insert(errLines, tostring(el)) end
                    end
                else
                    table.insert(errLines, "Cannot craft required tool.")
                end
                triggerCraftError("! NOT ENOUGH TOOL DURABILITY", errLines, 12)
                return false
            end
        end
    end

    drawProgress(i, #plan, desc, 0, totalExpected, step.item, numStations)

    local function ensureWithTokens(itemName, needCnt, subOk)
        if cancelCrafting or (ctx and ctx.failed) then return false, {"Cancelled"} end
        local have = groupAvailable(itemName, getStorageInventoryCached(), subOk)
        if have >= needCnt then return true, nil end
        if node and node.tokens then releaseTokens(node.tokens) end
        local okE, errE = ensureItemAvailable(itemName, needCnt, subOk)
        if node and node.tokens then
            while not cancelCrafting and not (ctx and ctx.failed) do
                if tryAcquireTokens(node.tokens) then break end
                sleepYield(0.2, ctx)
            end
        end
        return okE, errE
    end

    local function getDeviceCount(devName, itemKey, subOk)
        local devP = peripheral.wrap(devName)
        if not (devP and devP.list) then return 0 end
        local sL, dList = pcall(devP.list)
        if not (sL and dList) then return 0 end
        local cnt = 0
        for _, it in pairs(dList) do
            if it and itemMatchesOrGroup(it.name, itemKey, subOk) then
                cnt = cnt + (it.count or 0)
            end
        end
        return cnt
    end

    local function cleanDeviceWrongItems(devName, allowedItemKey, subOk)
        if not devName then return end
        local devP = peripheral.wrap(devName)
        if not (devP and devP.list) then return end
        local sL, dList = pcall(devP.list)
        if not (sL and dList) then return end
        for sl, it in pairs(dList) do
            if it and (it.count or 0) > 0 and not itemMatchesOrGroup(it.name, allowedItemKey, subOk) then
                collectToStorage(devP, devName, sl, it.count)
            end
        end
    end

    local maxSafetyOps = isChanceMode and math.max(step.count * 10, plannedBatches * 3, 64) or totalOps
    local maxTicks = math.max(120, maxSafetyOps * 60)
    local ticks = 0
    totalCollected = 0

    -- BATCH-PROTECTED CRAFT LOOP:
    -- Runs in discrete batches (e.g. 5 mechanisms). Pushes EXACTLY the base resources
    -- for the current batch, waits until all items exit the machine (success or failure),
    -- registers outcomes, and only then recalculates & crafts ingredients for any deficit!
    while totalCollected < totalExpected and ticks < maxTicks do
        if cancelCrafting or (ctx and ctx.failed) then break end

        local stillNeedOps = math.ceil((totalExpected - totalCollected) / outputPerOp)
        if stillNeedOps <= 0 then break end

        local batchTargetOps = stillNeedOps
        for k, st in ipairs(stations) do
            st.batchOps = math.floor(batchTargetOps / numStations) + (k <= (batchTargetOps % numStations) and 1 or 0)
            st.batchStarted = 0
        end

        -- 1. Ensure resources for this batch
        -- 1a. Base ingredients
        for _, bEntry in ipairs(baseIngList) do
            if bEntry.item and bEntry.item ~= "" then
                local bCount = bEntry.count or 1
                local totalBaseNeed = batchTargetOps * bCount
                local haveBase = groupAvailable(bEntry.item, getStorageInventoryCached(), allowSub)
                if haveBase < totalBaseNeed then
                    local okB, errB = ensureWithTokens(bEntry.item, totalBaseNeed, allowSub)
                    if not okB then
                        triggerCraftError("! CANNOT CRAFT BASE ITEM", errB or {"Missing base item: " .. getItemDisplayName(bEntry.item)}, 10)
                        unloadAllActionDevices()
                        return false
                    end
                end
            end
        end

        -- 1b. Secondary actions (fluids & items in deployers)
        local prepFailed = false
        local prepErr = nil
        for _, st in ipairs(stations) do
            if st.batchOps > 0 then
                for _, act in ipairs(st.actions or {}) do
                    if act.type == "fluid" and act.fluid and act.device then
                        local fNeeded = st.batchOps * (act.amount or 250)
                        pushFluidToMachine(act.device, act.fluid, fNeeded)
                    elseif act.type == "item" and act.item and act.device then
                        if isActionTool(act) then
                            local bKey = parseItemKey(act.item)
                            cleanDeviceWrongItems(act.device, bKey, false)
                            local devHas = getDeviceCount(act.device, bKey, false)
                            if devHas < 1 then
                                pushFromStorage(bKey, 1, act.device, nil, false)
                                devHas = getDeviceCount(act.device, bKey, false)
                            end
                            if devHas < 1 then
                                local okT, errT = ensureWithTokens(bKey, 1, false)
                                if okT then
                                    pushFromStorage(bKey, 1, act.device, nil, false)
                                    devHas = getDeviceCount(act.device, bKey, false)
                                end
                            end
                            if devHas < 1 then
                                prepFailed = true
                                prepErr = {"Missing tool: " .. getItemDisplayName(bKey)}
                                break
                            end
                        else
                            local actPerOp = act.count or 1
                            local actNeeded = st.batchOps * actPerOp
                            cleanDeviceWrongItems(act.device, act.item, allowSub)
                            local devHas = getDeviceCount(act.device, act.item, allowSub)
                            act.batchDelivered = math.min(devHas, actNeeded)
                            act.lastCount = devHas
                            local needDelivery = actNeeded - act.batchDelivered
                            if needDelivery > 0 then
                                local haveStock = groupAvailable(act.item, getStorageInventoryCached(), allowSub)
                                if haveStock < needDelivery then
                                    local okA, errA = ensureWithTokens(act.item, needDelivery, allowSub)
                                    if not okA then
                                        prepFailed = true
                                        prepErr = errA or {"Missing item: " .. getItemDisplayName(act.item)}
                                        break
                                    end
                                end
                                local space = math.max(0, 64 - devHas)
                                if space > 0 then
                                    local toPush = math.min(space, needDelivery)
                                    local pushed = pushFromStorage(act.item, toPush, act.device, nil, allowSub)
                                    if pushed > 0 then
                                        act.batchDelivered = act.batchDelivered + pushed
                                        devHas = getDeviceCount(act.device, act.item, allowSub)
                                        act.lastCount = devHas
                                    end
                                end
                            end
                        end
                    end
                end
                if prepFailed then break end
            end
        end

        if prepFailed then
            triggerCraftError("! MISSING SECONDARY ITEMS", prepErr or {"Cannot prepare machine items"}, 10)
            unloadAllActionDevices()
            return false
        end

        -- 2. Execute this batch and protect from over-feeding!
        -- Track operations finished in this batch (successful mechanisms + failed scraps)
        local batchDoneOps = 0
        local lastActivityTick = ticks

        while (batchDoneOps < batchTargetOps) and (totalCollected < totalExpected) and (ticks < maxTicks) do
            if cancelCrafting or (ctx and ctx.failed) then break end
            ticks = ticks + 1

            -- A. Runtime secondary replenishment (tools hot-swap & consumable top-up)
            for _, st in ipairs(stations) do
                for _, act in ipairs(st.actions or {}) do
                    if act.device then
                        if act.type == "item" and act.item then
                            if isActionTool(act) then
                                local bKey = parseItemKey(act.item)
                                local devHas = getDeviceCount(act.device, bKey, false)
                                if devHas < 1 then
                                    local pushed = pushFromStorage(bKey, 1, act.device, nil, false)
                                    if pushed < 1 then
                                        ensureWithTokens(bKey, 1, false)
                                        pushFromStorage(bKey, 1, act.device, nil, false)
                                    end
                                    if getDeviceCount(act.device, bKey, false) > 0 then
                                        lastActivityTick = ticks
                                    end
                                end
                            else
                                local devHas = getDeviceCount(act.device, act.item, allowSub)
                                if act.lastCount and devHas < act.lastCount then
                                    lastActivityTick = ticks
                                end
                                act.lastCount = devHas

                                local actTotal = st.batchOps * (act.count or 1)
                                local delivered = act.batchDelivered or 0
                                local stillNeeded = math.max(0, actTotal - delivered)
                                if stillNeeded > 0 then
                                    local space = math.max(0, 64 - devHas)
                                    if space > 0 and (devHas <= 48 or space >= stillNeeded) then
                                        local toPush = math.min(space, stillNeeded)
                                        local pushed = pushFromStorage(act.item, toPush, act.device, nil, allowSub)
                                        if pushed < toPush then
                                            local deficit = toPush - pushed
                                            local okA = ensureWithTokens(act.item, deficit, allowSub)
                                            if okA then
                                                local p2 = pushFromStorage(act.item, deficit, act.device, nil, allowSub)
                                                pushed = pushed + (p2 or 0)
                                            end
                                        end
                                        if pushed > 0 then
                                            act.batchDelivered = delivered + pushed
                                            act.lastCount = getDeviceCount(act.device, act.item, allowSub)
                                            lastActivityTick = ticks
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- B. Collect outputs and failure scraps from outP FIRST
            -- (Cleans finished products and byproducts like tree_bark so platforms don't clog)
            for _, st in ipairs(stations) do
                local sList, curItems = pcall(st.outP.list)
                if sList and curItems then
                    for slot, it in pairs(curItems) do
                        if it and (it.count or 0) > 0 then
                            local isBase = false
                            if st.outputPlatform == st.targetPlatform then
                                for _, bEntry in ipairs(baseIngList) do
                                    if itemMatchesOrGroup(it.name, bEntry.item, allowSub) then
                                        isBase = true
                                        break
                                    end
                                end
                            end
                            if not isBase then
                                local toTake = it.count
                                local moved = collectToStorage(st.outP, st.outputPlatform, slot, toTake)
                                if moved > 0 then
                                    lastActivityTick = ticks
                                    if itemMatchesOrGroup(it.name, step.item, allowSub) then
                                        totalCollected = totalCollected + moved
                                        local completedOps = math.max(1, math.floor(moved / outputPerOp))
                                        batchDoneOps = batchDoneOps + completedOps
                                        drawProgress(i, #plan, desc, totalCollected, totalExpected, step.item, numStations)
                                    else
                                        local isByproduct = false
                                        for _, bp in ipairs(step.byproducts or {}) do
                                            if bp.item and itemMatches(it.name, bp.item) then
                                                isByproduct = true
                                                break
                                            end
                                        end
                                        if not isByproduct and step.results then
                                            for _, res in ipairs(step.results) do
                                                if res.role == "byproduct" and res.item and itemMatches(it.name, res.item) then
                                                    isByproduct = true
                                                    break
                                                end
                                            end
                                        end
                                        if not isByproduct then
                                            -- Unknown failure scrap (not a declared byproduct): count as finished attempt
                                            batchDoneOps = batchDoneOps + moved
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- C. Feed base items for this batch ONLY (with accurate pushed accounting & hot-refill)
            if #baseIngList > 0 then
                for _, st in ipairs(stations) do
                    if st.batchStarted < st.batchOps then
                        local hasForeign = false
                        local curBase = 0
                        local sL, tItems = pcall(st.targetP.list)
                        if sL and tItems then
                            for _, it in pairs(tItems) do
                                if it and (it.count or 0) > 0 then
                                    local matchesBase = false
                                    for _, bEntry in ipairs(baseIngList) do
                                        if itemMatchesOrGroup(it.name, bEntry.item, allowSub) then
                                            matchesBase = true
                                            curBase = curBase + it.count
                                            break
                                        end
                                    end
                                    if not matchesBase then
                                        hasForeign = true
                                    end
                                end
                            end
                        end

                        if not hasForeign then
                            if st.isSingleSlotShared then
                                if curBase == 0 then
                                    local allPushedOps = 1
                                    for _, bEntry in ipairs(baseIngList) do
                                        local bCount = bEntry.count or 1
                                        local pushedB = pushFromStorage(bEntry.item, bCount, st.targetPlatform, nil, allowSub) or 0
                                        local opsMoved = math.floor(pushedB / bCount)
                                        if opsMoved < allPushedOps then allPushedOps = opsMoved end
                                    end
                                    if allPushedOps > 0 then
                                        st.batchStarted = st.batchStarted + allPushedOps
                                        lastActivityTick = ticks
                                    end
                                end
                            else
                                local stillNeededOps = st.batchOps - st.batchStarted
                                local maxPossibleOps = stillNeededOps
                                for _, bEntry in ipairs(baseIngList) do
                                    local bPerOp = bEntry.count or 1
                                    local roomOps = math.floor((64 - curBase) / bPerOp)
                                    if roomOps < maxPossibleOps then maxPossibleOps = roomOps end
                                end
                                local opsToPush = math.max(0, maxPossibleOps)
                                -- Hot-refill: push whenever platform is empty or room frees up (curBase <= 48 or all needed fits)
                                if opsToPush > 0 and (curBase <= 48 or opsToPush >= stillNeededOps) then
                                    local actualPushedOps = opsToPush
                                    for _, bEntry in ipairs(baseIngList) do
                                        local bPerOp = bEntry.count or 1
                                        local movedB = pushFromStorage(bEntry.item, opsToPush * bPerOp, st.targetPlatform, nil, allowSub) or 0
                                        local opsMoved = math.floor(movedB / bPerOp)
                                        if opsMoved < actualPushedOps then actualPushedOps = opsMoved end
                                    end
                                    if actualPushedOps > 0 then
                                        st.batchStarted = st.batchStarted + actualPushedOps
                                        lastActivityTick = ticks
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- D. Batch completion / fast safety timeout when platforms are empty
            if batchDoneOps < batchTargetOps then
                local allFed = true
                local allEmpty = true
                for _, st in ipairs(stations) do
                    if st.batchStarted < st.batchOps then allFed = false end
                    local sL, tItems = pcall(st.targetP.list)
                    if sL and tItems and next(tItems) then allEmpty = false break end
                    local sO, oItems = pcall(st.outP.list)
                    if sO and oItems and next(oItems) then allEmpty = false break end
                end
                if allEmpty then
                    if allFed then
                        -- Fast resolution: platforms confirmed empty and all ops fed!
                        if ticks - lastActivityTick >= 2 then
                            batchDoneOps = batchTargetOps
                        end
                    else
                        -- Starvation safety: platforms empty and nothing moving
                        if ticks - lastActivityTick >= 8 then
                            batchDoneOps = batchTargetOps
                        end
                    end
                elseif ticks - lastActivityTick >= 120 then
                    batchDoneOps = batchTargetOps
                end
            end

            if (batchDoneOps < batchTargetOps) and (totalCollected < totalExpected) then
                sleepCheckCancel(0.25)
            end
        end

        -- Batch finished!
        -- If totalCollected < totalExpected, the outer loop continues with deficit recalculation
    end

    -- Cleanup all stations
    for _, st in ipairs(stations) do
        for _, act in ipairs(st.actions or {}) do
            if act.type == "item" and act.device then
                local actSub = (not isActionTool(act)) and allowSub or false
                local dev = peripheral.wrap(act.device)
                if dev and dev.list then
                    local s, its = pcall(dev.list)
                    if s and its then
                        for sl, it in pairs(its) do
                            if it and itemMatchesOrGroup(it.name, act.item, actSub) then
                                collectToStorage(dev, act.device, sl, it.count)
                            end
                        end
                    end
                end
            end
        end
        if (cancelCrafting or isChanceMode) and st.targetP and st.targetP.list then
            local s, its = pcall(st.targetP.list)
            if s and its then
                for sl, it in pairs(its) do
                    if it then
                        for _, bEntry in ipairs(baseIngList) do
                            if itemMatchesOrGroup(it.name, bEntry.item, allowSub) then
                                collectToStorage(st.targetP, st.targetPlatform, sl, it.count)
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    flushCraftBuffer()
    invalidateStockCache()
    if totalCollected >= totalExpected then return true end
    return false
end
function executeStep(step, ctx, node)
local sortedStorages = ctx.sortedStorages
local provSrc        = providerSources()
local firstStorage   = ctx.firstStorage
local finalGoalItem  = ctx.finalGoalItem
local plan           = ctx.plan
local i              = node.idx
local w, h           = monitor.getSize()
local myCleanup      = {}
local nodeTopup      = false
local function drawProgress(stepNum, totalSteps, desc, currentCount, maxCount, activeItemName, workerCount)
ctx.active[node.idx] = { desc = desc, done = currentCount or 0, total = maxCount or 0,
machines = workerCount or 0, topup = nodeTopup }
if displayCtx and displayCtx ~= ctx then
displayCtx.active["NEST:" .. tostring(lockOwnerId())] = {
desc = desc, done = currentCount or 0, total = maxCount or 0,
machines = workerCount or 0, topup = nodeTopup, nest = true,
}
end
end
if step.count and step.count > 0 then
local desc = string.format("%d x %s", step.count * (step.output_count or 1), step.item:match(":(.+)$") or step.item)
if step.fluid_craft then
fluidGoalLabel = finalGoalItem ~= "" and finalGoalItem or step.item
fluidStepNum = 0
fluidStepTotal = countTopFluidSteps(step.fluidRecipe, step.item, step.fluidAmount)
ctx.active[node.idx] = {
desc = (step.item:match(":(.+)$") or step.item) .. " (fluid)",
done = 0, total = step.fluidAmount or 0, machines = 0, topup = false,
}
local coF = lockOwnerId()
local prevEnt = fluidInlineByCo[coF]
fluidInlineByCo[coF] = { ctx = ctx, node = node.idx }
local okF, errF = produceFluid(step.fluidRecipe, step.item, step.fluidAmount)
fluidInlineByCo[coF] = prevEnt
if displayCtx and displayCtx ~= ctx then
displayCtx.active["FLUIDNEST:" .. tostring(coF)] = nil
end
if not okF then
craftErrorTitle = "! FLUID SUBCRAFT FAILED"
craftErrorLines = errF or {"Unknown error"}
cleanupCraftMachines(sortedStorages, myCleanup)
return false
end
elseif step.type == "composite" then
return executeCompositeStep(step, ctx, node, drawProgress, desc)
elseif step.type == "turtle" then
            local turtleSlots = {1, 2, 3, 5, 6, 7, 9, 10, 11}
            local turtlePool = {}
            for tName, enabled in pairs(Config.turtles or {}) do
                if enabled then
                    local tp = peripheral.wrap(tName)
                    if tp then table.insert(turtlePool, tName) end
                end
            end
            table.sort(turtlePool)
            if #turtlePool == 0 then
                if step.machine_name and step.machine_name ~= "" then
                    turtlePool = {step.machine_name}
                else
                    local itemShort = step.item:match(":(.+)$") or step.item
                    craftErrorTitle = "! NO TURTLE ASSIGNED"
                    craftErrorLines = {
                        "No turtle available",
                        "Required for: " .. itemShort,
                        "Assign a turtle in NETWORK tab.",
                    }
                    return false
                end
            end
            if step.tools and next(step.tools) and #turtlePool > 1 then
                turtlePool = { turtlePool[1] }
            end
            myCleanup = {}
            for _, tName in ipairs(turtlePool) do
                table.insert(myCleanup, {name = tName, pullNames = nil})
                craftUsedMachines[tName] = true
            end

            local allowSub = (step.allow_group_sub ~= nil) and step.allow_group_sub or (not isWoodSpecificItem(step.item))

            if step.count and step.count > 0 and not cancelCrafting then
                local ingNeed0 = {}
                for idx0 = 1, 9 do
                    local ing0 = step.ingredients[idx0]
                    if ing0 and ing0 ~= "nil" then ingNeed0[ing0] = (ingNeed0[ing0] or 0) + 1 end
                end
                releaseTokens(node.tokens)
                for ing0, perOp0 in pairs(ingNeed0) do
                    if step.tools and step.tools[ing0] then
                        ensureItemAvailable(ing0, 1, false)
                    else
                        ensureItemAvailable(ing0, perOp0 * step.count, allowSub)
                    end
                end
                while not cancelCrafting and not ctx.failed do
                    if tryAcquireTokens(node.tokens) then break end
                    sleepYield(0.2, ctx)
                end
                if cancelCrafting or ctx.failed then return false end
            end

            local function craftSlotsDirty(tName)
                local tp = peripheral.wrap(tName)
                if not (tp and tp.list) then return nil end
                local ok, its = pcall(tp.list)
                if not (ok and its) then return nil end
                for _, it in pairs(its) do
                    if it and (it.count or 0) > 0 then return true end
                end
                return false
            end

            local function clearTurtleGrid(tName)
                local dirty = craftSlotsDirty(tName)
                if dirty == false then return true end
                if dirty == nil then return blindUnloadTurtle(tName, sortedStorages) end
                for _attempt = 1, 3 do
                    for slot = 1, 16 do
                        for _, stoName in ipairs(sortedStorages) do
                            local sto = peripheral.wrap(stoName)
                            if sto and sto.pullItems then
                                local okp, mv = pcall(sto.pullItems, tName, slot, 64)
                                if okp and mv and mv > 0 then break end
                            end
                        end
                    end
                    if craftSlotsDirty(tName) ~= true then return true end
                end
                return false
            end

            for _, tName in ipairs(turtlePool) do clearTurtleGrid(tName) end

            local poolSize = #turtlePool
            local base  = math.floor(step.count / poolSize)
            local extra = step.count % poolSize
            local assignments = {}
            for ai, tName in ipairs(turtlePool) do
                local cnt = base + (ai <= extra and 1 or 0)
                if cnt > 0 then
                    table.insert(assignments, {name = tName, remaining = cnt})
                end
            end

            local totalDone   = 0
            local totalNeeded = step.count
            local turtleStall = 0
            local outMaxStack = nil

            local function lookupOutMax()
                if outMaxStack then return outMaxStack end
                local iData = StorageIndex and StorageIndex.byItem and StorageIndex.byItem[step.item]
                if iData and iData.slots and iData.slots[1] then
                    local sl = iData.slots[1]
                    local v = peripheral.wrap(sl.vault)
                    if v and v.getItemDetail then
                        local okD, det = pcall(v.getItemDetail, sl.slot)
                        if okD and det and det.maxCount and det.maxCount > 0 then
                            outMaxStack = det.maxCount
                            return outMaxStack
                        end
                    end
                end
                outMaxStack = isKnownToolItem(step.item) and 1 or 64
                return outMaxStack
            end

            local toolSet = step.tools or {}
            local function isTool(n) return toolSet[n] and true or false end

            while totalDone < totalNeeded do
                if cancelCrafting then
                    cleanupCraftMachines(sortedStorages, myCleanup)
                    return false
                end
                drawProgress(i, #plan, desc, totalDone, totalNeeded, step.item, #turtlePool)
                local active = {}
                for _, asgn in ipairs(assignments) do
                    if asgn.remaining > 0 then table.insert(active, asgn) end
                end
                if #active == 0 then break end
                for _, asgn in ipairs(active) do clearTurtleGrid(asgn.name) end

                local ingNeed = {}
                for idx2 = 1, 9 do
                    local ing = step.ingredients[idx2]
                    if ing and ing ~= "nil" then ingNeed[ing] = (ingNeed[ing] or 0) + 1 end
                end

                local tStock = getStorageInventoryCached()

                local feasibleOps = nil
                for ing, need in pairs(ingNeed) do
                    if not isTool(ing) then
                        local f = math.floor(groupAvailable(ing, tStock, allowSub) / need)
                        if feasibleOps == nil or f < feasibleOps then feasibleOps = f end
                    end
                end
                feasibleOps = feasibleOps or 0

                local chosenType   = {}
                local consistentCap = nil
                for ing, need in pairs(ingNeed) do
                    if not isTool(ing) then
                        local best, bestCnt = ing, tStock[ing] or 0
                        if allowSub then
                            local grp = ITEM_GROUPS[ing]
                            if grp then
                                for _, alt in ipairs(GROUPS[grp]) do
                                    local c = tStock[alt] or 0
                                    if c > bestCnt then best, bestCnt = alt, c end
                                end
                            end
                        end
                        chosenType[ing] = best
                        local cap = math.floor(bestCnt / need)
                        if consistentCap == nil or cap < consistentCap then consistentCap = cap end
                    end
                end
                consistentCap = consistentCap or 0
                if isWoodSpecificItem(step.item) and consistentCap < feasibleOps then
                    feasibleOps = consistentCap
                end

                if feasibleOps <= 0 then
                    local itemShort = step.item:match(":(.+)$") or step.item
                    craftErrorTitle = "! NEED"
                    local remaining = totalNeeded - totalDone
                    local parts = {}
                    for ing, perOp in pairs(ingNeed) do
                        local short = perOp * remaining - groupAvailable(ing, tStock, allowSub)
                        if short > 0 then parts[#parts + 1] = string.format("%dx %s", short, ing:match(":(.+)$") or ing) end
                    end
                    local lines = {"Can't make " .. itemShort}
                    appendMissingLine(lines, parts)
                    craftErrorLines = lines
                    logCraftError(craftErrorTitle, craftErrorLines)
                    cleanupCraftMachines(sortedStorages, myCleanup)
                    return false
                end

                local toolMissing = nil
                for ing in pairs(ingNeed) do
                    if isTool(ing) and (tStock[ing] or 0) < 1 then toolMissing = ing; break end
                end

                if toolMissing then
                    releaseTokens(node.tokens)
                    local okTool, toolErr = ensureItemAvailable(toolMissing, 1, false)
                    while not cancelCrafting and not ctx.failed do
                        if tryAcquireTokens(node.tokens) then break end
                        sleepYield(0.2, ctx)
                    end
                    if cancelCrafting or ctx.failed then
                        cleanupCraftMachines(sortedStorages, myCleanup)
                        return false
                    end
                    if not okTool then
                        craftErrorTitle = "! NEED TOOL"
                        craftErrorLines = toolErr or {"Can't make tool: " .. (toolMissing:match(":(.+)$") or toolMissing)}
                        logCraftError(craftErrorTitle, craftErrorLines)
                        cleanupCraftMachines(sortedStorages, myCleanup)
                        return false
                    end
                else
                    local turtleOutputPerOp = step.output_count or 1
                    local outMax = lookupOutMax() or 64
                    local slotCap = math.max(1, math.floor(outMax / math.max(1, turtleOutputPerOp)))

                    local useConsistent = consistentCap >= 1
                    local feasLeft = feasibleOps
                    local round = {}

                    for _, asgn in ipairs(active) do
                        if feasLeft <= 0 then break end
                        local batchSize = math.min(slotCap, asgn.remaining, feasLeft)
                        if useConsistent then
                            if batchSize > consistentCap then batchSize = consistentCap end
                        else
                            batchSize = math.min(batchSize, 1)
                        end
                        if batchSize > 0 and clearTurtleGrid(asgn.name) then
                            asgn.currentBatch = batchSize
                            feasLeft = feasLeft - batchSize
                            for idx2 = 1, 9 do
                                local ing = step.ingredients[idx2]
                                if ing and ing ~= "nil" then
                                    local targetIng = useConsistent and (chosenType[ing] or ing) or ing
                                    if isTool(ing) then
                                        pushFromStorage(ing, 1, asgn.name, turtleSlots[idx2], false)
                                    else
                                        pushFromStorage(targetIng, batchSize, asgn.name, turtleSlots[idx2], allowSub)
                                    end
                                end
                            end
                            round[#round + 1] = asgn
                        end
                    end
                    active = round

                    if #active == 0 then
                        turtleStall = turtleStall + 1
                        if turtleStall > 30 then
                            local itemShort = step.item:match(":(.+)$") or step.item
                            craftErrorTitle = "! TURTLE GRID BLOCKED"
                            craftErrorLines = {
                                "Can't clear turtle grid for " .. itemShort,
                                "Residue stuck (item storage full?).",
                                "Free up storage space and retry.",
                            }
                            cleanupCraftMachines(sortedStorages, myCleanup)
                            return false
                        end
                        sleepCheckCancel(0.3)
                    else
                        turtleStall = 0
                    end

                    local craftResults   = {}
                    local craftTasks   = {}
                    local finishedCount = 0
                    local batchTotal    = #active
                    for ci, asgn in ipairs(active) do
                        local tName = asgn.name
                        local ri    = ci
                        craftTasks[#craftTasks + 1] = function()
                            local crafted = false
                            local so = peripheral.wrap(firstStorage)
                            for _ = 1, 120 do
                                sleepCheckCancel(0.05)
                                if cancelCrafting then break end
                                if so and so.pullItems then
                                    local s, res = pcall(so.pullItems, tName, 16, 64)
                                    if s and res and res > 0 then crafted = true; break end
                                end
                            end
                            if crafted then
                                if so and so.pullItems then
                                    for slot = 1, 15 do pcall(so.pullItems, tName, slot, 64) end
                                end
                            end
                            craftResults[ri] = crafted
                            finishedCount = finishedCount + 1
                        end
                    end
                    craftTasks[#craftTasks + 1] = function()
                        while finishedCount < batchTotal and not cancelCrafting do
                            local t = os.startTimer(0.05)
                            while true do
                                local ev, a, b, c = os.pullEvent()
                                if ev == "timer" and a == t then break end
                                if ev == "monitor_touch" and craftCancelY
                                and c == craftCancelY and b >= craftCancelX1 and b <= craftCancelX2 then
                                    cancelCrafting = true
                                    os.cancelTimer(t)
                                    break
                                end
                            end
                        end
                    end
                    parallel.waitForAll(table.unpack(craftTasks))
                    for ci, asgn in ipairs(active) do
                        if craftResults[ci] then
                            asgn.remaining = asgn.remaining - (asgn.currentBatch or 1)
                            totalDone = totalDone + (asgn.currentBatch or 1)
                        else
                            cleanupCraftMachines(sortedStorages, myCleanup)
                            return false
                        end
                    end
                end
            end
            for _, tName in ipairs(turtlePool) do clearTurtleGrid(tName) end
else
local activePool = {}
for _, mName in ipairs(getMachinePool(step.machine_name)) do
local p = peripheral.wrap(mName)
if p and p.list and p.pushItems then
table.insert(activePool, mName)
end
end
local splitOutName, splitOutPeriph = nil, nil
if step.output_device and step.output_device ~= "" then
splitOutName   = step.output_device
splitOutPeriph = peripheral.wrap(splitOutName)
if not (splitOutPeriph and splitOutPeriph.list) then
craftErrorTitle = "! MACHINE NOT FOUND"
craftErrorLines = {
"Output device not found: " .. getMachineDisplay(splitOutName),
"Required for: " .. (step.item:match(":(.+)$") or step.item),
"Reconnect device or re-learn recipe.",
}
craftErrorEditItems = { [2] = step.item }
return false
end
activePool = {}
local pIn = peripheral.wrap(step.machine_name)
if pIn and pIn.list and pIn.pushItems then
activePool = {step.machine_name}
end
end
if #activePool == 0 then
local mDisplay = getMachineDisplay and getMachineDisplay(step.machine_name or "?") or (step.machine_name or "?")
local itemShort = step.item:match(":(.+)$") or step.item
craftErrorTitle = "! MACHINE NOT FOUND"
craftErrorLines = {
"Machine not found: " .. mDisplay,
"Required for: " .. itemShort,
"Use [E] in RECIPES to reassign machine.",
}
craftErrorEditItems = { [2] = step.item }
return false
end
local allowSub = (step.allow_group_sub ~= nil) and step.allow_group_sub or (not isWoodSpecificItem(step.item))
local ingCounts = {}
local ingSlot   = {}
local ingSlotN  = 0
for ingIdx = 1, #step.ingredients do
local ing = step.ingredients[ingIdx]
if ing and ing ~= "nil" then
ingCounts[ing] = (ingCounts[ing] or 0) + 1
if not ingSlot[ing] then
ingSlotN = ingSlotN + 1
ingSlot[ing] = ingSlotN
end
end
end
if step.count and step.count > 0 and not cancelCrafting then
releaseTokens(node.tokens)
for ingName, ingPerOp in pairs(ingCounts) do
ensureItemAvailable(ingName, ingPerOp * step.count, allowSub)
end
while not cancelCrafting and not ctx.failed do
if tryAcquireTokens(node.tokens) then break end
sleepYield(0.2, ctx)
end
if cancelCrafting or ctx.failed then return false end
end
local ingPullNames = {}
for ingName in pairs(ingCounts) do
ingPullNames[ingName] = true
if allowSub and ITEM_GROUPS[ingName] and GROUPS[ITEM_GROUPS[ingName]] then
for _, alt in ipairs(GROUPS[ITEM_GROUPS[ingName]]) do ingPullNames[alt] = true end
end
end
myCleanup = {}
for _, mName in ipairs(activePool) do
table.insert(myCleanup, {name = mName, pullNames = ingPullNames})
end
if splitOutName then
table.insert(myCleanup, {name = splitOutName, pullNames = ingPullNames})
end
for _, mNameU in ipairs(activePool) do craftUsedMachines[mNameU] = true end
if splitOutName then craftUsedMachines[splitOutName] = true end
local totalOps      = step.count
local outputPerOp   = step.output_count or 1
local totalExpected = totalOps * outputPerOp
local poolSize      = #activePool
local base  = math.floor(totalOps / poolSize)
local extra = totalOps % poolSize
drawProgress(i, #plan, desc, 0, totalExpected, step.item, #activePool)
local ingMaxStack = {}
        for ingName in pairs(ingCounts) do
            local maxS = 64
            -- Fetch exact slot from StorageIndex directly without network polling
            local itemData = StorageIndex.byItem[ingName]
            if itemData and itemData.slots and itemData.slots[1] then
                local sl = itemData.slots[1]
                local v = peripheral.wrap(sl.vault)
                if v and v.getItemDetail then
                    local sDet, det = pcall(v.getItemDetail, sl.slot)
                    if sDet and det and det.maxCount and det.maxCount > 0 then
                        maxS = det.maxCount
                    end
                end
            end
            ingMaxStack[ingName] = maxS
        end
local function pushBatch(mName, opsCount)
local machHas = {}
do
local pm = peripheral.wrap(mName)
if pm and pm.list then
local okM, its = pcall(pm.list)
if okM and its then
for _, it in pairs(its) do
if it then
for ingName in pairs(ingCounts) do
if itemMatchesOrGroup(it.name, ingName, allowSub) then
machHas[ingName] = (machHas[ingName] or 0) + (it.count or 0)
break
end
end
end
end
end
end
end
for ingName, ingPerOp in pairs(ingCounts) do
local maxS = ingMaxStack[ingName] or 64
local curOps = math.floor((machHas[ingName] or 0) / ingPerOp)
local addable
if maxS >= ingPerOp then
addable = math.floor(maxS / ingPerOp) - curOps
else
addable = (curOps > 0) and 0 or 1
end
if addable < opsCount then opsCount = addable end
end
local stockCnt = {}
for ingName in pairs(ingCounts) do
stockCnt[ingName] = 0
if allowSub then
local grp = ITEM_GROUPS[ingName]
if grp then for _, alt in ipairs(GROUPS[grp]) do stockCnt[alt] = stockCnt[alt] or 0 end end
end
end

-- Instantly fetch stock from StorageIndex (MAIN Vaults without network polling!)
for k in pairs(stockCnt) do
    local d = StorageIndex.byItem[k]
    if d and d.total then stockCnt[k] = stockCnt[k] + d.total end
end

-- Poll only external provider chests and auxiliary [VAULT]
local extraSrc = {}
for _, s in ipairs(provSrc or {}) do extraSrc[#extraSrc + 1] = s end
for sName, en in pairs(Config.storages or {}) do
    if en and not SYSTEM_SIDES[sName] and not (Config.main_vaults and Config.main_vaults[sName]) and sName ~= Config.buffer then
        extraSrc[#extraSrc + 1] = sName
    end
end
if #extraSrc > 0 then
    local scanned = batchPeripheralScan(extraSrc, "list")
    for _, stoName in ipairs(extraSrc) do
        local e = scanned[stoName]
        if e and e.data then
            for _, it in pairs(e.data) do
                if it and stockCnt[it.name] ~= nil then
                    stockCnt[it.name] = stockCnt[it.name] + (it.count or 0)
                end
            end
        end
    end
end
for ingName, ingPerOp in pairs(ingCounts) do
local feasOps = math.floor(groupAvailable(ingName, stockCnt, allowSub) / ingPerOp)
if feasOps < opsCount then opsCount = feasOps end
end
if opsCount <= 0 then return 0 end
local accepted = opsCount
for ingName, ingPerOp in pairs(ingCounts) do
local have   = machHas[ingName] or 0
local curOps = math.floor(have / ingPerOp)
local needed = (curOps + opsCount) * ingPerOp - have
local moved  = 0
if needed > 0 then
if ingPerOp <= (ingMaxStack[ingName] or 64) then
moved = pushFromStorage(ingName, needed, mName, ingSlot[ingName], allowSub)
end
if moved < needed then
moved = moved + pushFromStorage(ingName, needed - moved, mName, nil, allowSub)
end
end
local newOps = math.floor((have + moved) / ingPerOp) - curOps
if newOps < accepted then accepted = newOps end
end
return accepted
end
local preUnloadList = {}
for _, mName in ipairs(activePool) do table.insert(preUnloadList, mName) end
if splitOutName then table.insert(preUnloadList, splitOutName) end
local dirtyDrop = {}
for _, mName in ipairs(preUnloadList) do
local mPeriph = peripheral.wrap(mName)
if mPeriph and mPeriph.list then
for _pass = 1, 3 do
local sPre, preItems = pcall(mPeriph.list)
if not (sPre and preItems) then break end
local anyPre = false
for slotPre, itemPre in pairs(preItems) do
if itemPre and itemPre.name and itemPre.count and itemPre.count > 0 then
anyPre = true
local leftPre = itemPre.count
if mPeriph.pushItems then
for _, stoName in ipairs(sortedStorages) do
if leftPre <= 0 then break end
local okP, mvP = pcall(mPeriph.pushItems, stoName, slotPre, leftPre)
if okP and mvP and mvP > 0 then leftPre = leftPre - mvP end
end
end
if leftPre > 0 then
for _, stoName in ipairs(sortedStorages) do
if leftPre <= 0 then break end
local sto = peripheral.wrap(stoName)
if sto and sto.pullItems then
local okQ, mvQ = pcall(sto.pullItems, mName, slotPre, leftPre)
if okQ and mvQ and mvQ > 0 then leftPre = leftPre - mvQ end
end
end
end
end
end
if not anyPre then break end
sleepCheckCancel(0.2)
end
local sChk, chkItems = pcall(mPeriph.list)
if sChk and chkItems then
for _, ci in pairs(chkItems) do
if ci and ci.name == step.item and (ci.count or 0) > 0 then
dirtyDrop[mName] = true
end
end
end
end
if mPeriph and mPeriph.tanks then
local okT, tl = pcall(mPeriph.tanks)
if okT and tl then
for _, tk in pairs(tl) do
if tk and tk.name and tk.amount and tk.amount > 0 then
drainFluidToStorage(mName, tk.name, tk.amount)
end
end
end
end
end
if next(dirtyDrop) and not splitOutName then
local np = {}
for _, mName in ipairs(activePool) do
if not dirtyDrop[mName] then np[#np + 1] = mName end
end
if #np > 0 then
activePool = np
poolSize = #activePool
base  = math.floor(totalOps / poolSize)
extra = totalOps % poolSize
end
end
local machineData = {}
for bIdx = 1, poolSize do
local assignedOps = base + (bIdx <= extra and 1 or 0)
if assignedOps > 0 then
local mName   = activePool[bIdx]
local mPeriph = peripheral.wrap(mName)
if mPeriph then
local collectPeriph = splitOutPeriph or mPeriph
local collectName  = splitOutName  or mName
local excluded = {}
local preSnap  = {}
local sSnap, snapItems = pcall(collectPeriph.list)
if sSnap and snapItems then
for _, si in pairs(snapItems) do
if si then
excluded[si.name] = true
preSnap[si.name] = (preSnap[si.name] or 0) + si.count
end
end
end
for ingName in pairs(ingCounts) do
excluded[ingName] = true
if allowSub and ITEM_GROUPS[ingName] and GROUPS[ITEM_GROUPS[ingName]] then
for _, alt in ipairs(GROUPS[ITEM_GROUPS[ingName]]) do excluded[alt] = true end
end
end
local acceptedOps = pushBatch(mName, assignedOps)
table.insert(machineData, {
periph            = mPeriph,
outPeriph         = collectPeriph,
name              = mName,
outName           = collectName,
excluded          = excluded,
preSnap           = preSnap,
remainOps         = assignedOps - acceptedOps,
pendingItems      = acceptedOps * outputPerOp,
doneItems         = 0,
lastCollectTick   = 0,
exhausted         = false,
hasEverCollected  = false,
collectCount      = 0,
refillCount       = 0,
})
end
end
end
local totalCollected = 0
local maxWait = math.max(600, totalOps * 60)
local waited  = 0
local continueOuter = true
while continueOuter do
continueOuter = false
for _, e in ipairs(machineData) do e.exhausted = false end
while totalCollected < totalExpected and waited < maxWait do
sleepCheckCancel(0.5)
if cancelCrafting then
cleanupCraftMachines(sortedStorages, myCleanup)
return false
end
waited = waited + 1
drawProgress(i, #plan, desc, totalCollected, totalExpected, step.item, #machineData)
for _, entry in ipairs(machineData) do
local hasLeftover = false
local s, mItems = pcall(entry.outPeriph.list)
if s and mItems then
for slot, mItem in pairs(mItems) do
if mItem and not entry.excluded[mItem.name] then
local toTake = mItem.count
local moved = 0
for _, stoName in ipairs(sortedStorages) do
if moved >= toTake then break end
local s2, m = pcall(entry.outPeriph.pushItems, stoName, slot, toTake - moved)
if s2 and m and m > 0 then moved = moved + m end
end
if moved < toTake then
for _, stoName in ipairs(sortedStorages) do
if moved >= toTake then break end
local sto2 = peripheral.wrap(stoName)
if sto2 and sto2.pullItems then
local s3, m3 = pcall(sto2.pullItems, entry.outName, slot, toTake - moved)
if s3 and m3 and m3 > 0 then moved = moved + m3 end
end
end
end
if moved > 0 then
local gap = waited - entry.lastCollectTick
if gap > (entry.maxGap or 0) then entry.maxGap = gap end
entry.lastCollectTick  = waited
entry.hasEverCollected = true
entry.collectCount     = (entry.collectCount or 0) + 1
if itemMatchesOrGroup(mItem.name, step.item, allowSub) then
entry.doneItems = entry.doneItems + moved
totalCollected  = totalCollected + moved
end
end
if moved < toTake then hasLeftover = true end
end
end
end
local hasInput = false
local si2, mI2 = pcall(entry.periph.list)
if si2 and mI2 then
for _, mi2 in pairs(mI2) do
if mi2 and ingPullNames[mi2.name] then
local preC = (entry.preSnap and entry.preSnap[mi2.name]) or 0
if mi2.count > preC then hasInput = true; break end
end
end
end
local runnableOps
if si2 and mI2 then
local ingTotNow = {}
for _, mi2 in pairs(mI2) do
if mi2 then
for ingName in pairs(ingCounts) do
if itemMatchesOrGroup(mi2.name, ingName, allowSub) then
ingTotNow[ingName] = (ingTotNow[ingName] or 0) + mi2.count
break
end
end
end
end
for ingName, ingPerOp in pairs(ingCounts) do
local o = math.floor((ingTotNow[ingName] or 0) / ingPerOp)
if runnableOps == nil or o < runnableOps then runnableOps = o end
end
end
runnableOps = runnableOps or 0
local owes = entry.doneItems < entry.pendingItems
local idleTicks = waited - entry.lastCollectTick
local quietNeed = math.max(4, (entry.maxGap or 0) * 2 + 4)
if owes and hasInput then
if (entry.collectCount or 0) >= 2 then
quietNeed = math.max(10, quietNeed)
else
quietNeed = math.max(30, quietNeed)
end
elseif not hasInput and not hasLeftover then
quietNeed = math.min(quietNeed, 4)
end
if hasInput and runnableOps == 0 and not hasLeftover
and idleTicks >= math.max(6, quietNeed) then
local acc = pushBatch(entry.name, math.max(1, entry.remainOps))
if acc > 0 then
entry.remainOps    = math.max(0, entry.remainOps - acc)
entry.pendingItems = entry.pendingItems + acc * outputPerOp
entry.lastCollectTick = waited
entry.starve = 0
else
entry.starve = (entry.starve or 0) + 1
if entry.starve >= 6 then entry.exhausted = true end
end
elseif entry.remainOps > 0 then
if (not hasInput or runnableOps <= 16) and not hasLeftover then
local acceptedOps = pushBatch(entry.name, entry.remainOps)
if acceptedOps > 0 then
entry.remainOps    = entry.remainOps - acceptedOps
entry.pendingItems = entry.pendingItems + acceptedOps * outputPerOp
entry.lastCollectTick = waited
entry.starve = 0
entry.exhausted = false
elseif not owes or idleTicks >= quietNeed then
entry.starve = (entry.starve or 0) + 1
if entry.starve >= 6 then entry.exhausted = true end
end
end
elseif not entry.exhausted and entry.hasEverCollected and not hasInput
and not hasLeftover and idleTicks >= quietNeed then
local deficit = totalExpected - totalCollected
if deficit > 0 then
local activeCount = 0
for _, e in ipairs(machineData) do if not e.exhausted then activeCount = activeCount + 1 end end
local opsNeeded = math.ceil(deficit / outputPerOp)
local perMachine = math.max(1, math.ceil(opsNeeded / math.max(1, activeCount)))
local accepted  = pushBatch(entry.name, math.min(opsNeeded, perMachine))
if accepted > 0 then
nodeTopup             = true
entry.pendingItems    = entry.pendingItems + accepted * outputPerOp
entry.lastCollectTick = waited
entry.refillCount     = entry.refillCount + 1
entry.starve          = 0
else
entry.starve = (entry.starve or 0) + 1
if entry.starve >= 6 then entry.exhausted = true end
end
else
entry.exhausted = true
end
end
end
local allExhausted = true
for _, entry in ipairs(machineData) do
if not entry.exhausted then allExhausted = false; break end
end
if allExhausted then break end
end
local flushSilence    = 0
local flushMaxSilence = 2
repeat
local hadOutput = false
for _, entry in ipairs(machineData) do
local sp = entry.outPeriph
if sp and sp.list and sp.pushItems then
local sok, curItems = pcall(sp.list)
if sok and curItems then
local flushLeftover = false
for slot2, curItem in pairs(curItems) do
if curItem and not entry.excluded[curItem.name] then
local preCount = (entry.preSnap and entry.preSnap[curItem.name]) or 0
local toPull   = curItem.count - preCount
if toPull > 0 then
local pulled = 0
for _, stoName in ipairs(sortedStorages) do
if pulled >= toPull then break end
local sm, mm = pcall(sp.pushItems, stoName, slot2, toPull - pulled)
if sm and mm and mm > 0 then pulled = pulled + mm end
end
if pulled > 0 then
hadOutput = true
if itemMatchesOrGroup(curItem.name, step.item, allowSub) then
entry.doneItems = entry.doneItems + pulled
totalCollected  = totalCollected  + pulled
end
end
if pulled < toPull then flushLeftover = true end
end
end
end
entry._flushLeftover = flushLeftover
end
end
if entry.remainOps > 0 and not entry._flushLeftover
and totalCollected < totalExpected then
local nextOps     = entry.remainOps
local acceptedOps = pushBatch(entry.name, nextOps)
if acceptedOps > 0 then
entry.remainOps        = nextOps - acceptedOps
entry.pendingItems     = entry.pendingItems + acceptedOps * outputPerOp
entry.exhausted        = false
entry.hasEverCollected = false
entry.lastCollectTick  = waited
continueOuter = true
end
end
end
local flushNeed = flushMaxSilence
for _, entry in ipairs(machineData) do
if entry.doneItems < entry.pendingItems then
local floorQ = ((entry.collectCount or 0) >= 2) and 20 or 120
local q = math.max(floorQ, (entry.maxGap or 0) * 2 + 4)
if q > flushNeed then flushNeed = q end
end
end
if hadOutput then
flushSilence = 0
else
flushSilence = flushSilence + 1
end
if flushSilence < flushNeed and not cancelCrafting then
sleepCheckCancel(0.5)
end
until flushSilence >= flushNeed or cancelCrafting
end
if not cancelCrafting then
cleanupCraftMachines(sortedStorages, myCleanup)
invalidateStockCache()
end
if totalCollected == 0 then invalidateStockCache(); return false end
end
end
ctx.active[node.idx] = nil
return true
end
function mergeCraftPlan(plan)
local merged   = {}
local idxByKey = {}
for _, step in ipairs(plan) do
local key
if step.fluid_craft then
key = (step.item or "?") .. "|F|" .. tostring(step.fluidRecipe)
else
local ings = step.ingredients and table.concat(step.ingredients, ",") or ""
key = (step.item or "?") .. "|" .. tostring(step.type) .. "|" ..
tostring(step.machine_name) .. "|" .. tostring(step.output_count or 1) ..
"|" .. tostring(step.output_device or "") .. "|" .. ings
end
local mi = idxByKey[key]
if mi then
local m = merged[mi]
m.count = (m.count or 0) + (step.count or 0)
if step.planned_batches then
m.planned_batches = (m.planned_batches or 0) + step.planned_batches
end
if step.fluid_craft then
m.fluidAmount = (m.fluidAmount or 0) + (step.fluidAmount or 0)
end
else
merged[#merged + 1] = step
idxByKey[key] = #merged
end
end
return merged
end
function buildCraftDAG(plan)
local nodes = {}
local producerOf = {}
for idx, step in ipairs(plan) do
nodes[idx] = { idx = idx, step = step, deps = {}, tokens = stepTokens(step),
done = false, started = false }
if step.item then producerOf[step.item] = idx end
end
for idx, node in ipairs(nodes) do
local step = node.step
local stepAllowSub = (step.allow_group_sub ~= nil) and step.allow_group_sub or (not isWoodSpecificItem(step.item))
local seen = {}
local function addSingleDep(k)
local p = producerOf[k]
if p and p ~= idx and not seen[p] then
seen[p] = true
node.deps[#node.deps + 1] = p
end
end
local function addDep(ingName)
if not ingName or ingName == "" then return end
addSingleDep(ingName)
local bKey = parseItemKey(ingName)
if bKey ~= ingName then addSingleDep(bKey) end
if stepAllowSub and ITEM_GROUPS[bKey] and GROUPS[ITEM_GROUPS[bKey]] then
for _, alt in ipairs(GROUPS[ITEM_GROUPS[bKey]]) do
addSingleDep(alt)
end
end
end
if step.fluid_craft then
for _, it in ipairs((step.fluidRecipe and step.fluidRecipe.item_inputs) or {}) do
addDep(it.name)
end
for _, inp in ipairs((step.fluidRecipe and step.fluidRecipe.inputs) or {}) do
addDep(inp.name)
end
elseif step.ingredients then
for _, ing in ipairs(step.ingredients) do
if ing and ing ~= "nil" then addDep(ing) end
end
end
if not (step.count and step.count > 0) then node.done = true end
end
return nodes
end
function claimReadyNode(ctx)
for _, node in ipairs(ctx.nodes) do
if not node.done and not node.started then
local ready = true
for _, d in ipairs(node.deps) do
if not ctx.nodes[d].done then ready = false; break end
end
if ready and tryAcquireTokens(node.tokens) then
node.started = true
return node
end
end
end
return nil
end
function drawParallelProgress(ctx)
if drawInterface then drawInterface() end
end
function schedDone(ctx)
return ctx.failed or cancelCrafting or ctx.remaining <= 0
end
function runSequential(ctx)
for _, node in ipairs(ctx.nodes) do
if cancelCrafting then return false end
if not node.done then
while not cancelCrafting do
if tryAcquireTokens(node.tokens) then break end
sleepYield(0.2, ctx)
end
if cancelCrafting then releaseTokens(node.tokens); return false end
local ok, err = executeStep(node.step, ctx, node)
releaseTokens(node.tokens)
ctx.active[node.idx] = nil
if displayCtx and displayCtx ~= ctx then
displayCtx.active["NEST:" .. tostring(lockOwnerId())] = nil
end
if ok then
node.done = true
ctx.doneCount = ctx.doneCount + 1
if crossCraftDepth == 0 and not node.step.fluid_craft then craftStageDone = (craftStageDone or 0) + 1 end
else
if not cancelCrafting then ctx.failed = true; ctx.failErr = err end
return false
end
end
end
return true
end
runCraftingProcess = function(plan)
if #plan == 0 then return false end
if crossCraftDepth == 0 then
cancelCrafting = false; craftLocks = {}; craftUsedMachines = {}
fluidTankClaims = 0; _fluidStoreBusy = false; fluidInlineByCo = {}
end
if cancelCrafting then return false end
local sortedStorages = getSortedStorages()
    local firstStorage = sortedStorages[1]
    if not firstStorage then return false end
plan = mergeCraftPlan(plan)
local nodes = buildCraftDAG(plan)
local finalGoalItem = plan[#plan] and plan[#plan].item or ""
local remaining = 0
for _, n in ipairs(nodes) do if not n.done then remaining = remaining + 1 end end
local ctx = {
plan = plan, nodes = nodes, sortedStorages = sortedStorages,
firstStorage = firstStorage, finalGoalItem = finalGoalItem,
remaining = remaining, total = #nodes, doneCount = 0,
active = {}, failed = false, failErr = nil, done = false, fluidActive = false,
}
if remaining <= 0 then invalidateStockCache(); return true end
if crossCraftDepth > 0 then
local okSeq = runSequential(ctx)
sweepCraftMachines()
flushCraftBuffer()
invalidateStockCache()
if cancelCrafting then return false end
if ctx.failed then return false end
return okSeq
end
displayCtx = ctx
craftStageDone  = 0
craftStageTotal = estimatePlanStages(plan)
local distinct, nDistinct = {}, 0
for _, n in ipairs(nodes) do
for _, t in ipairs(n.tokens) do
if not distinct[t] then distinct[t] = true; nDistinct = nDistinct + 1 end
end
end
local K = math.min(math.max(1, nDistinct), 16)
local function worker()
while not ctx.done do
if schedDone(ctx) then ctx.done = true; return end
local node = claimReadyNode(ctx)
if not node then
local tmW = os.startTimer(0.2)
local evW, aW = os.pullEvent()
if not (evW == "timer" and aW == tmW) then os.cancelTimer(tmW) end
else
local ok, err = executeStep(node.step, ctx, node)
releaseTokens(node.tokens)
ctx.active[node.idx] = nil
if ok then
node.done = true
ctx.remaining = ctx.remaining - 1
ctx.doneCount = ctx.doneCount + 1
if not node.step.fluid_craft then craftStageDone = (craftStageDone or 0) + 1 end
else
node.done = true
ctx.remaining = ctx.remaining - 1
if not cancelCrafting then
ctx.failed = true
ctx.failErr = err
end
end
end
end
end
local function uiLoop()
            while not ctx.done do
                if schedDone(ctx) then ctx.done = true; return end
                drawParallelProgress(ctx)
                local tmU = os.startTimer(0.3)
                local deadline = os.clock() + 0.3
                
                while true do
                    local evU, aU = os.pullEvent()
                    if evU == "timer" and aU == tmU then break end
                    if ctx.done then return end
                    
                    if os.clock() >= deadline then
                        os.cancelTimer(tmU)
                        break
                    end
                end
            end
        end
local function cancelWatch()
while not ctx.done do
local timer = os.startTimer(0.3)
local deadline = os.clock() + 0.4
while true do
local ev, a, b, c = os.pullEvent()
if ev == "timer" and a == timer then break end
if ev == "monitor_touch" and craftCancelY and c == craftCancelY
and b >= craftCancelX1 and b <= craftCancelX2 then
cancelCrafting = true
end
if ctx.done then return end
if os.clock() >= deadline then os.cancelTimer(timer); break end
end
if schedDone(ctx) then ctx.done = true; return end
end
end
local tasks = {}
for _ = 1, K do tasks[#tasks + 1] = worker end
tasks[#tasks + 1] = uiLoop
tasks[#tasks + 1] = cancelWatch
parallel.waitForAll(table.unpack(tasks))
displayCtx = nil
sweepCraftMachines()
flushCraftBuffer()
invalidateStockCache()
if cancelCrafting then return false end
if ctx.failed then return false end
return true
end
function runMachineRecipeSearch()
if not Config.train_box or Config.train_box == "" then
return "ERR: Assign Train Box in NETWORK!"
end
local trainBox = peripheral.wrap(Config.train_box)
if not trainBox or not trainBox.getItemDetail then
return "ERR: Train box offline!"
end
local barrelCenterSlots = {4, 5, 6, 13, 14, 15, 22, 23, 24}
local ingredients = {}
local ingredientCounts = {}
local hasItems = false
local sampleItemName = "Unknown Item"
for i = 1, 9 do
local sourceSlot = barrelCenterSlots[i]
local success, item = pcall(function() return trainBox.getItemDetail(sourceSlot) end)
if success and item then
local key = makeItemKey(item.name, item.nbt)
local formatted = formatItemDetailName(item, key)
if isValidDisplayName(formatted) then
    ItemDisplayNames[key] = formatted
    saveItemNames()
end
ingredients[i] = key
ingredientCounts[i] = item.count or 1
hasItems = true
sampleItemName = key
else
ingredients[i] = "nil"
ingredientCounts[i] = 0
end
end
if not hasItems then return "ERR: Grid empty!" end
learnedResult = nil
learnedOutputs = nil
learnedTools = {}
if selectedCraftType == "turtle" then
learnedIngredients = ingredients
else
local expandedIngredients = {}
for i = 1, 9 do
if ingredients[i] ~= "nil" then
local cnt = ingredientCounts[i] or 1
for _ = 1, cnt do
expandedIngredients[#expandedIngredients + 1] = ingredients[i]
end
end
end
if #expandedIngredients == 0 then expandedIngredients[1] = "nil" end
learnedIngredients = expandedIngredients
end
local function drawTestStage(stageDesc, currentProgress, maxProgress)
local w, h = monitor.getSize()
local pW = math.min(w - 6, 56)
local pH = 11
local pX = math.max(1, math.floor((w - pW) / 2) + 1)
local pY = math.max(1, math.floor((h - pH) / 2))
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdr = " RECIPE INTERACTIVE LEARNING "
drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.orange)
drawText(pX + 1, pY + 1, string.rep("-", pW - 2), colors.lightGray, colors.gray)
local sName = sampleItemName:match(":(.+)$") or sampleItemName
drawText(pX + 2, pY + 3, ("Testing: " .. sName):sub(1, pW - 4), colors.yellow, colors.gray)
drawText(pX + 2, pY + 5, ("STATUS: " .. stageDesc):sub(1, pW - 4), colors.lightGray, colors.gray)
if maxProgress and maxProgress > 0 then
drawProgressBar(pX + 2, pY + 7, pW - 10, currentProgress, maxProgress, colors.gray)
end
local cancStr = " [ CANCEL ] "
local cancX = pX + math.floor((pW - #cancStr) / 2)
drawText(cancX, pY + pH - 2, cancStr, colors.white, colors.red)
craftCancelY  = pY + pH - 2
craftCancelX1 = cancX
craftCancelX2 = cancX + #cancStr - 1
_bufFlush()
end
cancelCrafting = false
local function dumpToBarrel(p, pName)
if not p then return end
local ok, items = pcall(p.list)
if ok and items then
for slot, it in pairs(items) do
if it then
local moved = 0
if p.pushItems then
local o, m = pcall(p.pushItems, Config.train_box, slot, 64)
if o and type(m) == "number" then moved = m end
end
if moved <= 0 and pName then
pcall(trainBox.pullItems, pName, slot, 64)
end
end
end
end
end
if selectedCraftType == "turtle" then
local firstTurtle = nil
local tSorted = {}
for tName, enabled in pairs(Config.turtles or {}) do
if enabled then tSorted[#tSorted + 1] = tName end
end
table.sort(tSorted)
for _, tName in ipairs(tSorted) do
if peripheral.wrap(tName) then firstTurtle = tName; break end
end
if not firstTurtle then
if #tSorted > 0 then return "ERR: Turtle offline: " .. tSorted[1] end
return "ERR: Assign Turtle!"
end
learnedMachineName = firstTurtle
learnedCraftType = "turtle"
learnedOutputDevice = nil
drawTestStage("Clearing worker grid...", 1, 4)
local turtleSlots = {1, 2, 3, 5, 6, 7, 9, 10, 11}
for slot = 1, 16 do pcall(function() trainBox.pullItems(firstTurtle, slot, 64) end) end
drawTestStage("Pushing test ingredients...", 2, 4)
local pushedAny = false
for i = 1, 9 do
if ingredients[i] ~= "nil" then
local okP, mvP = pcall(function() return trainBox.pushItems(firstTurtle, barrelCenterSlots[i], 1, turtleSlots[i]) end)
if okP and type(mvP) == "number" and mvP > 0 then pushedAny = true end
end
end
if not pushedAny then
dumpToBarrel(peripheral.wrap(firstTurtle), firstTurtle)
return "ERR: Cannot push items to " .. firstTurtle
end
drawTestStage("Awaiting turtle processing...", 3, 4)
local learnCraftSlots = {[4]=true,[5]=true,[6]=true,[13]=true,[14]=true,[15]=true,[22]=true,[23]=true,[24]=true}
local learnSafeSlots = {}
for s = 1, 27 do if not learnCraftSlots[s] then table.insert(learnSafeSlots, s) end end
while true do
drawTestStage("Awaiting turtle (cancel to abort)...")
sleepCheckCancel(0.4)
if cancelCrafting then
for slot = 1, 16 do pcall(function() trainBox.pullItems(firstTurtle, slot, 64) end) end
craftCancelY = nil
learningState = "IDLE"
return "Learning cancelled."
end
local moved = 0
local targetSlot = nil
for _, bSlot in ipairs(learnSafeSlots) do
local ok, mv = pcall(function() return trainBox.pullItems(firstTurtle, 16, 64, bSlot) end)
if ok and mv and mv > 0 then
moved = mv
targetSlot = bSlot
break
end
end
if moved > 0 and targetSlot then
local det = trainBox.getItemDetail(targetSlot)
if det then
    local key = makeItemKey(det.name, det.nbt)
    local formatted = formatItemDetailName(det, key)
    if isValidDisplayName(formatted) then
        ItemDisplayNames[key] = formatted
        saveItemNames()
    end
    learnedResult = {name = key, count = det.count}
end
break
end
end
for _, tslot in ipairs({1, 2, 3, 5, 6, 7, 9, 10, 11}) do
for _, bSlot in ipairs(learnSafeSlots) do
local okE, detE = pcall(function() return trainBox.getItemDetail(bSlot) end)
if not (okE and detE) then
local ok, mv = pcall(function() return trainBox.pullItems(firstTurtle, tslot, 64, bSlot) end)
if ok and mv and mv > 0 then
local okD, det = pcall(function() return trainBox.getItemDetail(bSlot) end)
if okD and det and det.name then learnedTools[det.name] = true end
end
break
end
end
end
drawTestStage("Analyzing output data...")
else
learnedMachineName = selectedCraftType
learnedCraftType = "machine"
learnedOutputDevice = nil
if selectedOutputDevice and selectedOutputDevice ~= selectedCraftType then
learnedOutputDevice = selectedOutputDevice
end
local machineObj = peripheral.wrap(learnedMachineName)
if not machineObj or not machineObj.list then return "ERR: Machine offline!" end
local outputObj = machineObj
if learnedOutputDevice then
local oo = peripheral.wrap(learnedOutputDevice)
if not oo or not oo.list then return "ERR: Output device offline!" end
outputObj = oo
end
drawTestStage("Scanning machine state...", 1, 3)
local learnExcluded = {}
local sPre, preItems = pcall(machineObj.list)
if sPre and preItems then
for _, preItem in pairs(preItems) do
if preItem then learnExcluded[preItem.name] = true end
end
end
if learnedOutputDevice then
local sPreO, preItemsO = pcall(outputObj.list)
if sPreO and preItemsO then
for _, preItem in pairs(preItemsO) do
if preItem then learnExcluded[preItem.name] = true end
end
end
end
local learnMachineSize = 9
if machineObj.size then
local okSz, sz = pcall(machineObj.size)
if okSz and type(sz) == "number" then learnMachineSize = sz end
end
for i = 1, 9 do
if ingredients[i] ~= "nil" then
learnExcluded[ingredients[i]] = true
local fromSlot = barrelCenterSlots[i]
local needCount = ingredientCounts[i] or 1
local pushed = false
if machineObj.pullItems then
for mSlot = learnMachineSize, 1, -1 do
local ok1, mv1 = pcall(machineObj.pullItems, Config.train_box, fromSlot, needCount, mSlot)
if ok1 and type(mv1) == "number" and mv1 > 0 then
pushed = true
break
end
end
end
if not pushed then
pcall(trainBox.pushItems, learnedMachineName, fromSlot, needCount)
end
end
end
local prevSig, stableCount = nil, 0
while true do
drawTestStage("Waiting for output (cancel to abort)...")
sleepCheckCancel(0.5)
if cancelCrafting then break end
local present = false
local sig = {}
local sList, mList = pcall(outputObj.list)
if sList and mList then
for _, mItem in pairs(mList) do
if mItem and not learnExcluded[mItem.name] then
present = true
sig[#sig + 1] = mItem.name .. "=" .. (mItem.count or 0)
end
end
end
if present then
table.sort(sig)
local s = table.concat(sig, ",")
if s == prevSig then stableCount = stableCount + 1 else stableCount = 0 end
prevSig = s
if stableCount >= 2 then break end
end
end
if cancelCrafting then
dumpToBarrel(machineObj, learnedMachineName)
if outputObj ~= machineObj then dumpToBarrel(outputObj, learnedOutputDevice) end
craftCancelY = nil
learningState = "IDLE"
return "Learning cancelled."
end
drawTestStage("Collecting outputs...")
local outAgg = {}
local sFin, mFin = pcall(outputObj.list)
if sFin and mFin then
local learnMCraftSlots = {[4]=true,[5]=true,[6]=true,[13]=true,[14]=true,[15]=true,[22]=true,[23]=true,[24]=true}
for slot, mItem in pairs(mFin) do
if mItem and not learnExcluded[mItem.name] then
outAgg[mItem.name] = (outAgg[mItem.name] or 0) + (mItem.count or 0)
for bSlot = 1, 27 do
if not learnMCraftSlots[bSlot] then
local ok2, mv2 = pcall(function() return outputObj.pushItems(Config.train_box, slot, mItem.count, bSlot) end)
if ok2 and mv2 and mv2 > 0 then break end
end
end
end
end
end
learnedOutputs = {}
for nm, cnt in pairs(outAgg) do learnedOutputs[#learnedOutputs + 1] = {name = nm, count = cnt} end
table.sort(learnedOutputs, function(a, b)
if a.count ~= b.count then return a.count > b.count end
return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name))
end)
if learnedOutputs[1] then
learnedResult = {name = learnedOutputs[1].name, count = learnedOutputs[1].count}
end
end
craftCancelY = nil
if learnedResult then
learningState = "AWAITING_DECISION"
local hItem = learnedResult.name
for hi = #craftHistory, 1, -1 do
if craftHistory[hi].item == hItem then table.remove(craftHistory, hi) end
end
table.insert(craftHistory, 1, {item = hItem, qty = learnedResult.count or 1})
if #craftHistory > 30 then table.remove(craftHistory) end
return "Success! Confirm entry."
else
learningState = "IDLE"
return "ERR: Process failed!"
end
end
function runCompositeTestCraft(isBatchMode)
    if not compositeDraft.targetPlatform or compositeDraft.targetPlatform == "" then
        return "ERR: Select Target Platform!"
    end
    local targetP = peripheral.wrap(compositeDraft.targetPlatform)
    if not targetP then return "ERR: Target platform offline!" end

    local outDevName = (compositeDraft.outputPlatform and compositeDraft.outputPlatform ~= "")
        and compositeDraft.outputPlatform or compositeDraft.targetPlatform
    local outP = peripheral.wrap(outDevName)
    if not outP then return "ERR: Output platform offline!" end

    if not Config.train_box or Config.train_box == "" then
        return "ERR: Assign Train Box in NETWORK!"
    end
    local tb = peripheral.wrap(Config.train_box)
    if not tb or not tb.getItemDetail then return "ERR: Train box offline!" end

    local barrelCenterSlots = {4, 5, 6, 13, 14, 15, 22, 23, 24}
    local barrelCenterSet   = {[4]=true,[5]=true,[6]=true,[13]=true,[14]=true,[15]=true,[22]=true,[23]=true,[24]=true}
    local baseInputs = {}
    local baseMapCounts = {}
    local baseOrder = {}

    for _, bs in ipairs(barrelCenterSlots) do
        local d = tb.getItemDetail(bs)
        if d then
            local key = makeItemKey(d.name, d.nbt)
            local formatted = formatItemDetailName(d, key)
            if isValidDisplayName(formatted) then
                ItemDisplayNames[key] = formatted
                saveItemNames()
            end
            table.insert(baseInputs, { slot = bs, item = key, count = d.count })
            if not baseMapCounts[key] then
                table.insert(baseOrder, key)
                baseMapCounts[key] = 0
            end
            baseMapCounts[key] = baseMapCounts[key] + d.count
        end
    end
    if #baseInputs == 0 then
        return "ERR: Train Box center 3x3 empty!"
    end

    for idx, act in ipairs(compositeDraft.actions or {}) do
        if not act.device or not peripheral.wrap(act.device) then
            return "ERR: Action #" .. idx .. " device offline!"
        end
        if act.type == "item" then
            if not act.item or act.item == "" then return "ERR: Action #" .. idx .. " item missing!" end
            local checkKey = act.is_tool and parseItemKey(act.item) or act.item
            local needCnt  = act.is_tool and 1 or (act.count or 1)
            local have = groupAvailable(checkKey, getStorageInventoryCached(), false)
            if have < needCnt then return "ERR: Action #" .. idx .. " item out of stock!" end
        elseif act.type == "fluid" then
            if not act.fluid or act.fluid == "" then return "ERR: Action #" .. idx .. " fluid missing!" end
            local finv = getFluidInventory()
            local have = finv[fluidKey(act.fluid)] or 0
            if have < (act.amount or 1) then return "ERR: Action #" .. idx .. " fluid out of stock!" end
        end
    end

    local storages = getSortedStorages()
    local preItemsOut = {}
    local sOut, outList = pcall(outP.list)
    if sOut and outList then
        for _, it in pairs(outList) do
            if it then preItemsOut[it.name] = (preItemsOut[it.name] or 0) + it.count end
        end
    end

    local firstBaseKey = baseOrder[1]
    local firstBaseCount = baseMapCounts[firstBaseKey] or 1

    local testTransfers = {
        itemActions = {},
        fluidActions = {},
        baseInputs = baseInputs,
        baseMapCounts = baseMapCounts,
        baseOrder = baseOrder,
        baseItem = firstBaseKey,
        baseCount = firstBaseCount,
        targetPlatform = compositeDraft.targetPlatform,
        outputPlatform = outDevName,
    }

    cancelCrafting  = false
    finishTestEarly = false
    local accumulatedOuts = {}

    local function drawStage(statusText)
        local w, h = monitor.getSize()
        local pW = math.min(w - 6, 58)
        local pH = 12
        local pX = math.max(1, math.floor((w - pW) / 2) + 1)
        local pY = math.max(1, math.floor((h - pH) / 2))
        _bufFillRect(pX, pY, pW, pH, colors.gray)
        local hdr = isBatchMode and " COMPOSITE BATCH DISCOVERY TEST " or " COMPOSITE RECIPE TEST "
        drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, isBatchMode and colors.cyan or colors.orange)
        drawText(pX + 1, pY + 1, string.rep("-", pW - 2), colors.lightGray, colors.gray)
        drawText(pX + 2, pY + 3, ("Target: " .. getMachineDisplay(compositeDraft.targetPlatform)):sub(1, pW - 4), colors.yellow, colors.gray)
        drawText(pX + 2, pY + 5, ("STATUS: " .. statusText):sub(1, pW - 4), colors.white, colors.gray)

        local fParts = {}
        for k, v in pairs(accumulatedOuts) do
            table.insert(fParts, getItemDisplayName(k) .. (isBatchMode and "" or (" x" .. v)))
        end
        if #fParts > 0 then
            table.sort(fParts)
            local fTxt = "Found: " .. table.concat(fParts, ", ")
            drawText(pX + 2, pY + 7, fTxt:sub(1, pW - 4), colors.lime, colors.gray)
        else
            drawText(pX + 2, pY + 7, "Tap [FINISH] anytime to stop & open results", colors.lightGray, colors.gray)
        end

        local finStr  = " [ FINISH ] "
        local cancStr = " [ CANCEL ] "
        local totBtnW = #finStr + 4 + #cancStr
        local startBX = pX + math.floor((pW - totBtnW) / 2)
        local btnY    = pY + pH - 2
        drawText(startBX, btnY, finStr, colors.black, colors.lime)
        local cancX = startBX + #finStr + 4
        drawText(cancX, btnY, cancStr, colors.white, colors.red)
        craftCancelY  = btnY
        craftFinishX1 = startBX
        craftFinishX2 = startBX + #finStr - 1
        craftCancelX1 = cancX
        craftCancelX2 = cancX + #cancStr - 1
        _bufFlush()
    end

    local function evacuateOutputSlot(slot, take)
        local moved = 0
        if Config.train_box then
            for bSlot = 1, 27 do
                if moved >= take then break end
                if not barrelCenterSet[bSlot] then
                    local okP, mv = pcall(outP.pushItems, Config.train_box, slot, take - moved, bSlot)
                    if okP and mv and mv > 0 then moved = moved + mv end
                end
            end
            if moved < take then
                local okP2, mv2 = pcall(outP.pushItems, Config.train_box, slot, take - moved)
                if okP2 and mv2 and mv2 > 0 then moved = moved + mv2 end
            end
            if moved < take and tb and tb.pullItems then
                local okQ, mv3 = pcall(tb.pullItems, outDevName, slot, take - moved)
                if okQ and mv3 and mv3 > 0 then moved = moved + mv3 end
            end
        end
        if moved < take then
            for _, stoName in ipairs(storages) do
                if moved >= take then break end
                local sP, mv = pcall(outP.pushItems, stoName, slot, take - moved)
                if sP and mv and mv > 0 then moved = moved + mv end
            end
        end
        if moved < take then
            for _, stoName in ipairs(storages) do
                if moved >= take then break end
                local sto = peripheral.wrap(stoName)
                if sto and sto.pullItems then
                    local sQ, mv2 = pcall(sto.pullItems, outDevName, slot, take - moved)
                    if sQ and mv2 and mv2 > 0 then moved = moved + mv2 end
                end
            end
        end
        return moved
    end

    local function cleanupTest()
        drawStage("Recovering items & cleaning up...")
        for _, act in ipairs(testTransfers.itemActions) do
            local dev = peripheral.wrap(act.device)
            if dev and dev.list then
                local s, its = pcall(dev.list)
                if s and its then
                    for sl, it in pairs(its) do
                        if it and parseItemKey(it.name) == parseItemKey(act.item) then
                            if it.nbt and it.nbt ~= "" then
                                resolveItemDisplayName(dev, sl, makeItemKey(it.name, it.nbt))
                            end
                            local movedA = 0
                            for _, stoName in ipairs(storages) do
                                if movedA >= it.count then break end
                                local s2, m = pcall(dev.pushItems, stoName, sl, it.count - movedA)
                                if s2 and m and m > 0 then movedA = movedA + m end
                            end
                            if movedA < it.count then
                                for _, stoName in ipairs(storages) do
                                    if movedA >= it.count then break end
                                    local sto = peripheral.wrap(stoName)
                                    if sto and sto.pullItems then
                                        local sQ, mv2 = pcall(sto.pullItems, act.device, sl, it.count - movedA)
                                        if sQ and mv2 and mv2 > 0 then movedA = movedA + mv2 end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        for _, act in ipairs(testTransfers.fluidActions) do
            drainFluidToStorage(act.device, act.fluid, act.amount or 10000)
        end
        local tp = peripheral.wrap(testTransfers.targetPlatform)
        if tp and tp.list then
            local s, its = pcall(tp.list)
            if s and its then
                for sl, it in pairs(its) do
                    if it and Config.train_box then
                        local sP, mv = pcall(tp.pushItems, Config.train_box, sl, it.count)
                        if not (sP and mv and mv > 0) then
                            if tb and tb.pullItems then pcall(tb.pullItems, testTransfers.targetPlatform, sl, it.count) end
                        end
                    end
                end
            end
        end
        craftCancelY  = nil
        craftFinishX1 = nil
        craftFinishX2 = nil
        finishTestEarly = false
        flushCraftBuffer()
        invalidateStockCache()
    end

    drawStage("Pushing secondary actions...")
    for _, act in ipairs(compositeDraft.actions or {}) do
        if act.type == "item" then
            if isKnownToolItem(act.item) and act.is_tool == nil then
                act.is_tool = true
            end
            local pushItem = act.is_tool and parseItemKey(act.item) or act.item
            local pushCnt  = act.is_tool and 1 or (act.count or 1)
            local pushed   = pushFromStorage(pushItem, pushCnt, act.device, nil, false)
            if act.is_tool then
                act.item = pushItem
                local devP = peripheral.wrap(act.device)
                local measuredMax = nil
                if devP and devP.list and devP.getItemDetail then
                    local sL, dList = pcall(devP.list)
                    if sL and dList then
                        for sl, it in pairs(dList) do
                            if it and parseItemKey(it.name) == pushItem then
                                local okD, detD = pcall(devP.getItemDetail, sl)
                                if okD and detD and detD.maxDamage and detD.maxDamage > 0 then
                                    measuredMax = detD.maxDamage
                                    break
                                end
                            end
                        end
                    end
                end
                act.durability = measuredMax or act.durability or getWholeToolDurability(pushItem)
            end
            table.insert(testTransfers.itemActions, { device = act.device, item = act.item, count = pushed })
        elseif act.type == "fluid" then
            cleanDeviceWrongFluids(act.device, act.fluid)
            local existing = getDeviceFluid(act.device, act.fluid)
            local need = math.max(0, (act.amount or 250) - existing)
            local pushed = 0
            if need > 0 then
                pushed = pushFluidToMachine(act.device, act.fluid, need)
            end
            table.insert(testTransfers.fluidActions, { device = act.device, fluid = act.fluid, amount = existing + pushed })
        end
        if cancelCrafting then
            cleanupTest()
            return "Test cancelled."
        end
    end

    drawStage("Feeding base ingredients...")
    local totalPushedBase = 0
    for _, binp in ipairs(baseInputs) do
        local okPushB, pushedB = pcall(tb.pushItems, compositeDraft.targetPlatform, binp.slot, binp.count)
        local actualPushed = (okPushB and type(pushedB) == "number" and pushedB > 0) and pushedB or 0
        binp.pushed = actualPushed
        totalPushedBase = totalPushedBase + actualPushed
    end
    if targetP.pullItems then
        for _, binp in ipairs(baseInputs) do
            if (binp.pushed or 0) < binp.count then
                local okPull, mvPull = pcall(targetP.pullItems, Config.train_box, binp.slot, binp.count - (binp.pushed or 0))
                if okPull and type(mvPull) == "number" and mvPull > 0 then
                    binp.pushed = (binp.pushed or 0) + mvPull
                    totalPushedBase = totalPushedBase + mvPull
                end
            end
        end
    end
    if not isBatchMode and totalPushedBase > 0 then
        testTransfers.baseCount = totalPushedBase
    end

    local stableCount = 0
    local prevSig = ""
    local waited = 0
    local lastActivityTick = 0
    local prevBaseInTarget = totalPushedBase
    local baseItemConsumed = false
    local emptyAfterConsumedTicks = 0
    local batchDoneTicks = 0

    local function getDeviceCount(devName, itemName)
        local dev = peripheral.wrap(devName)
        if not (dev and dev.list) then return 0 end
        local s, its = pcall(dev.list)
        if not (s and its) then return 0 end
        local total = 0
        for _, it in pairs(its) do
            if it and itemMatches(it.name, itemName) then
                total = total + (it.count or 0)
            end
        end
        return total
    end

    while (waited - lastActivityTick) < 60 do
        drawStage(isBatchMode and "Batch testing (feeding & scanning)..." or "Waiting for craft to finish...")
        sleepCheckCancel(0.5)
        if cancelCrafting then
            cleanupTest()
            return "Test cancelled."
        end
        if finishTestEarly then
            break
        end
        waited = waited + 1

        -- In Batch Mode: keep feeding remaining base items from barrel & topping up secondary actions
        local remInBarrel = 0
        if isBatchMode then
            for _, binp in ipairs(baseInputs) do
                local detB = tb.getItemDetail(binp.slot)
                if detB and makeItemKey(detB.name, detB.nbt) == binp.item then
                    local rem = detB.count or 0
                    if rem > 0 then
                        remInBarrel = remInBarrel + rem
                        local okM, mvB = pcall(tb.pushItems, compositeDraft.targetPlatform, binp.slot, rem)
                        if not (okM and type(mvB) == "number" and mvB > 0) and targetP.pullItems then
                            local okP, mvP = pcall(targetP.pullItems, Config.train_box, binp.slot, rem)
                            if okP and type(mvP) == "number" and mvP > 0 then mvB = mvP; okM = true end
                        end
                        if okM and type(mvB) == "number" and mvB > 0 then
                            remInBarrel = remInBarrel - mvB
                            lastActivityTick = waited
                        end
                    end
                end
            end
            for _, act in ipairs(compositeDraft.actions or {}) do
                if act.type == "item" and not act.is_tool and act.item and act.device then
                    local curC = getDeviceCount(act.device, act.item)
                    local needC = act.count or 1
                    if curC < needC then
                        local pA = pushFromStorage(act.item, needC - curC, act.device, nil, false)
                        if pA > 0 then lastActivityTick = waited end
                    end
                elseif act.type == "fluid" and act.fluid and act.device then
                    local curF = getDeviceFluid(act.device, act.fluid)
                    local needF = act.amount or 250
                    if curF < needF then
                        local pF = pushFluidToMachine(act.device, act.fluid, needF - curF)
                        if pF > 0 then lastActivityTick = waited end
                    end
                end
            end
        end

        -- Check remaining base items in targetPlatform for activity heartbeat
        local curBaseInTarget = 0
        local sTgt, tgtList = pcall(targetP.list)
        if sTgt and tgtList then
            for _, it in pairs(tgtList) do
                if it then
                    local isBase = false
                    for _, bKey in ipairs(baseOrder) do
                        if itemMatches(it.name, bKey) then
                            isBase = true
                            break
                        end
                    end
                    if isBase then
                        curBaseInTarget = curBaseInTarget + (it.count or 0)
                    end
                end
            end
        end
        if curBaseInTarget ~= prevBaseInTarget then
            lastActivityTick = waited
            prevBaseInTarget = curBaseInTarget
        end
        if curBaseInTarget == 0 then
            baseItemConsumed = true
        end

        -- Scan outP for produced items
        local curOuts = {}
        local sCur, curList = pcall(outP.list)
        if sCur and curList then
            for slot, it in pairs(curList) do
                if it and (it.count or 0) > 0 then
                    local isBaseOnSame = false
                    if outDevName == compositeDraft.targetPlatform then
                        for _, bKey in ipairs(baseOrder) do
                            if itemMatches(it.name, bKey) then
                                isBaseOnSame = true
                                break
                            end
                        end
                    end
                    local isActionOnSame = false
                    for _, a in ipairs(testTransfers.itemActions or {}) do
                        if a.device == outDevName and itemMatches(it.name, a.item) then
                            isActionOnSame = true
                            break
                        end
                    end
                    if not isBaseOnSame and not isActionOnSame then
                        local preCnt = preItemsOut[it.name] or 0
                        local netOut = (it.count or 0) - preCnt
                        if netOut > 0 then
                            if isBatchMode then
                                if it.nbt and it.nbt ~= "" then
                                    resolveItemDisplayName(outP, slot, makeItemKey(it.name, it.nbt))
                                end
                                accumulatedOuts[it.name] = (accumulatedOuts[it.name] or 0) + netOut
                                evacuateOutputSlot(slot, netOut)
                                lastActivityTick = waited
                                curOuts[it.name] = (curOuts[it.name] or 0) + netOut
                            else
                                curOuts[it.name] = (curOuts[it.name] or 0) + netOut
                            end
                        end
                    end
                end
            end
        end

        if isBatchMode then
            if remInBarrel == 0 and curBaseInTarget == 0 and not next(curOuts) then
                batchDoneTicks = batchDoneTicks + 1
                if batchDoneTicks >= 6 then
                    break
                end
            else
                batchDoneTicks = 0
            end
        else
            if next(curOuts) then
                local sigParts = {}
                for k, v in pairs(curOuts) do table.insert(sigParts, k .. "=" .. v) end
                table.sort(sigParts)
                local sig = table.concat(sigParts, ",")
                if sig == prevSig then
                    stableCount = stableCount + 1
                else
                    stableCount = 0
                    lastActivityTick = waited
                end
                prevSig = sig
                if (stableCount >= 2 and curBaseInTarget == 0) or stableCount >= 4 then
                    accumulatedOuts = curOuts
                    break
                end
            else
                stableCount = 0
                prevSig = ""
                if baseItemConsumed and (outDevName == compositeDraft.targetPlatform) then
                    emptyAfterConsumedTicks = emptyAfterConsumedTicks + 1
                    if emptyAfterConsumedTicks >= 8 then
                        break
                    end
                end
            end
        end
    end

    -- Collect any remaining outputs currently in outP
    drawStage("Collecting craft output...")
    local sFin, finList = pcall(outP.list)
    if sFin and finList then
        for slot, it in pairs(finList) do
            if it and (it.count or 0) > 0 then
                local isBaseOnSame = false
                if outDevName == compositeDraft.targetPlatform then
                    for _, bKey in ipairs(baseOrder) do
                        if itemMatches(it.name, bKey) then
                            isBaseOnSame = true
                            break
                        end
                    end
                end
                local isActionOnSame = false
                for _, a in ipairs(testTransfers.itemActions or {}) do
                    if a.device == outDevName and itemMatches(it.name, a.item) then
                        isActionOnSame = true
                        break
                    end
                end
                if not isBaseOnSame and not isActionOnSame then
                    local preCnt = preItemsOut[it.name] or 0
                    local take = (it.count or 0) - preCnt
                    if take > 0 then
                        if it.nbt and it.nbt ~= "" then
                            resolveItemDisplayName(outP, slot, makeItemKey(it.name, it.nbt))
                        end
                        if isBatchMode then
                            accumulatedOuts[it.name] = (accumulatedOuts[it.name] or 0) + take
                        elseif not accumulatedOuts[it.name] then
                            accumulatedOuts[it.name] = take
                        end
                        evacuateOutputSlot(slot, take)
                    end
                end
            end
        end
    end

    -- Clean up secondary items, fluids, and any unconsumed base items in targetPlatform
    cleanupTest()

    local outsList = {}
    for k, v in pairs(accumulatedOuts) do
        table.insert(outsList, { name = k, count = v })
    end
    table.sort(outsList, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name))
    end)

    if #outsList == 0 and compositeDraft.mode ~= "chance" and not finishTestEarly then
        return "ERR: No output detected (timed out)!"
    end

    local prevBase = compositeDraft.baseItem
    compositeDraft.baseIngredients = {}
    for _, bKey in ipairs(baseOrder) do
        local bCnt = isBatchMode and 1 or math.max(1, baseMapCounts[bKey] or 1)
        table.insert(compositeDraft.baseIngredients, { item = bKey, count = bCnt })
    end
    compositeDraft.baseItem  = compositeDraft.baseIngredients[1] and compositeDraft.baseIngredients[1].item or testTransfers.baseItem
    compositeDraft.baseCount = compositeDraft.baseIngredients[1] and compositeDraft.baseIngredients[1].count or 1

    if isBatchMode and compositeDraft.testDone and prevBase == testTransfers.baseItem and #(compositeDraft.results or {}) > 0 then
        for _, r in ipairs(compositeDraft.results) do
            r.count = 1
        end
        for _, o in ipairs(outsList) do
            local exists = false
            for _, r in ipairs(compositeDraft.results) do
                if r.item == o.name then exists = true break end
            end
            if not exists then
                table.insert(compositeDraft.results, {
                    item   = o.name,
                    count  = 1,
                    role   = (#compositeDraft.results == 0) and "recipe" or "byproduct",
                    chance = nil
                })
            end
        end
    else
        compositeDraft.results = {}
        for idx, o in ipairs(outsList) do
            table.insert(compositeDraft.results, {
                item   = o.name,
                count  = isBatchMode and 1 or math.max(1, o.count or 1),
                role   = (idx == 1) and "recipe" or "byproduct",
                chance = nil
            })
        end
    end

    compositeDraft.resPage  = 1
    compositeDraft.testDone = true
    compositePopup = { mode = "results", page = 1 }

    if outsList[1] then
        local hItem = outsList[1].name
        for hi = #craftHistory, 1, -1 do
            if craftHistory[hi].item == hItem then table.remove(craftHistory, hi) end
        end
        table.insert(craftHistory, 1, {item = hItem, qty = outsList[1].count or 1})
        if #craftHistory > 30 then table.remove(craftHistory) end
    end

    if #outsList == 0 then
        return "0 items dropped. Add item or retry."
    end
    return isBatchMode and "Batch complete! Configure results." or "Test complete! Configure results."
end
local TRAINBOX_CRAFT_SLOTS = {[4]=true,[5]=true,[6]=true,[13]=true,[14]=true,[15]=true,[22]=true,[23]=true,[24]=true}
local TRAINBOX_SAFE_SLOTS  = {}
do for s = 1, 27 do if not TRAINBOX_CRAFT_SLOTS[s] then table.insert(TRAINBOX_SAFE_SLOTS, s) end end end
function deliverToTrainBox(itemName, amount)
if not Config.train_box or Config.train_box == "" then return 0 end
local moved = 0
for _, targetSlot in ipairs(TRAINBOX_SAFE_SLOTS) do
if moved >= amount then break end
local got = pushFromStorage(itemName, amount - moved, Config.train_box, targetSlot, false)
moved = moved + got
end
return moved
end
function pullAllFromTrainBox()
    if not Config.train_box or Config.train_box == "" then return 0 end
    local box = peripheral.wrap(Config.train_box)
    if not (box and box.list and box.pushItems) then return 0 end

    local dest = Config.buffer
    if not dest or not peripheral.wrap(dest) then
        for vName, en in pairs(Config.main_vaults or {}) do
            if en and peripheral.wrap(vName) then dest = vName; break end
        end
    end
    if not dest then return 0 end

    local ok, items = pcall(box.list)
    if not (ok and items) then return 0 end

    local totalMoved = 0
    for slot, item in pairs(items) do
        if item and item.count and item.count > 0 then
            local okP, mv = pcall(box.pushItems, dest, slot, item.count)
            if okP and type(mv) == "number" and mv > 0 then
                totalMoved = totalMoved + mv
            end
        end
    end

    if totalMoved > 0 then
        if dest ~= Config.buffer and Config.main_vaults and Config.main_vaults[dest] then
            local dObj = peripheral.wrap(dest)
            if dObj and dObj.list and dObj.size then
                local okL, lData = pcall(dObj.list)
                local okS, sData = pcall(dObj.size)
                if okL and okS then
                    StorageIndex.rebuildVault(dest, lData, sData)
                end
            end
        end
        if invalidateStockCache then invalidateStockCache() end
    end
    return totalMoved
end
function userIsBusy()
    if currentTab == "QUANTITY_PICKER" then return true end
    if mgmtPopup or custGrpPopup or fluidRecipePicker or recipeEditPopup
    or craftInfoPopup or machineInfoPopup or historyPopup or craftCompletePopup
    or pendingDeleteItem or pendingDeleteFluid or outputPickMode
    or fluidCraftWaitFluid or vaultOpPopup then
        return true
    end
    return false
end
function checkAndRunAutostock()
if Config.autostock_paused or systemStatus == "MANUAL_CRAFT" then return end
if userIsBusy() then return end
local maxPasses = 5
    local currentPass = 0
    local needsRecheck = true

    while needsRecheck and currentPass < maxPasses do
        needsRecheck = false
        currentPass = currentPass + 1

        local stockInv = getStorageInventory()
        local queue = {}
        for itemName, settings in pairs(Autostock) do
table.insert(queue, {
name      = itemName,
threshold = settings.threshold or settings.limit or 1,
target    = settings.target or settings.limit or 1,
paused    = settings.paused,
order     = settings.order or 99999,
})
end
table.sort(queue, function(a, b)
if a.order ~= b.order then return a.order < b.order end
return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name))
end)
for _, settings in ipairs(queue) do
local itemName = settings.name
local nowClock = os.clock()
if settings.paused or (autostockCooldowns[itemName] and nowClock < autostockCooldowns[itemName]) then
-- skip paused or cooldown item
elseif itemName:sub(1, 2) == "f:" then
local fname = fluidNameFromKey(itemName)
local fprods = fluidProducers(fname)
if fprods[1] then
local fcur = (getFluidInventory())[itemName] or 0
if fcur < settings.threshold then
local fneed = settings.target - fcur
if fneed > 0 then
systemStatus = "AUTO_CRAFT"
autostockCurrentItem = itemName
uiMessage = "Autostock fluid: " .. (fname:match(":(.+)$") or fname)
craftLocks = {}; fluidTankClaims = 0; _fluidStoreBusy = false; fluidInlineByCo = {}
local s, okRun = pcall(function() return produceFluid(fprods[1].recipe, fname, fneed) end)
if s and okRun then
    needsRecheck = true
    autostockCooldowns[itemName] = nil
else
    autostockCooldowns[itemName] = os.clock() + 30
end
systemStatus = "IDLE"
autostockCurrentItem = ""
if checkTimer then os.cancelTimer(checkTimer) end
checkTimer = os.startTimer(2)
if #craftErrorLines > 0 then
    triggerCraftError(craftErrorTitle or "! NEED", craftErrorLines, 10)
end
if cancelCrafting then return end
stockInv = getStorageInventory()
end
end
end
elseif Recipes[itemName] then
local currentCount = stockInv[itemName] or 0
if currentCount < settings.threshold then
local needed = settings.target - currentCount
local plan, planMiss = nil, nil
if needed > 0 then
plan, planMiss = planProduction(itemName, settings.target, false)
end
local isPartial = false
if needed > 0 and (not plan or #plan == 0 or (planMiss and next(planMiss))) then
plan = nil
local partialPlan = planProduction(itemName, settings.target, true)
if partialPlan and #partialPlan > 0 then
plan = partialPlan
isPartial = true
end
end
if plan and #plan > 0 then
systemStatus = "AUTO_CRAFT"
autostockCurrentItem = itemName
local shortName = itemName:match(":(.+)$") or itemName
if isPartial then
uiMessage = "Partial autostock: " .. shortName
else
uiMessage = "Autostocking " .. shortName
end
local ok = false
local craftOk, craftErr = pcall(function()
ok = runCraftingProcess(plan)
local kAttempts = 0
while ok and not cancelCrafting and kAttempts < 12 do
flushCraftBuffer()
invalidateStockCache()
local totalNow = groupAvailable(itemName, getStorageInventory(), false)
if totalNow >= settings.target then break end
kAttempts = kAttempts + 1
local rPlan = planProduction(itemName, settings.target, true)
if not (rPlan and #rPlan > 0) then break end
local beforeK = totalNow
runCraftingProcess(rPlan)
flushCraftBuffer()
invalidateStockCache()
if groupAvailable(itemName, getStorageInventory(), false) <= beforeK then break end
end
end)
systemStatus = "IDLE"
autostockCurrentItem = ""
if checkTimer then os.cancelTimer(checkTimer) end
checkTimer = os.startTimer(2)
if not craftOk or not ok then
autostockCooldowns[itemName] = os.clock() + 30
if not craftOk then
uiMessage = "ERR: KEEP crashed: " .. tostring(craftErr):sub(1, 40)
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(5)
else
uiMessage = "ERR: KEEP failed for " .. shortName
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(5)
end
if #craftErrorLines > 0 then
triggerCraftError(craftErrorTitle or "! NEED", craftErrorLines, 10)
end
else
autostockCooldowns[itemName] = nil
uiMessage = "KEEP done: " .. shortName
needsRecheck = true
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(3)
end
if cancelCrafting then return end
stockInv = getStorageInventory()
end
end
end
end
end
end
function getRegisteredMods()
local mods = { "All" }
local seen = { All = true }
for itemName in pairs(Recipes) do
local modId = itemName:match("^([^:]+):") or "minecraft"
if not seen[modId] then seen[modId] = true; table.insert(mods, modId) end
end
table.sort(mods, function(a, b)
if a == "All" then return true end
if b == "All" then return false end
if a == "minecraft" then return true end
if b == "minecraft" then return false end
return a < b
end)
return mods
end
function mgmtMoveSlot(srcName, srcSlot, destName, amount)
local srcP = peripheral.wrap(srcName)
if srcP and srcP.pushItems then
local ok, mv = pcall(srcP.pushItems, destName, srcSlot, amount)
if ok and mv and mv > 0 then return mv end
end
local dstP = peripheral.wrap(destName)
if dstP and dstP.pullItems then
local ok2, mv2 = pcall(dstP.pullItems, srcName, srcSlot, amount)
if ok2 and mv2 and mv2 > 0 then return mv2 end
end
return 0
end
function mgmtIsFluidPeriph(name)
if not name or name == "" or name == "STORAGE" then return false end
if Config.fluid_tanks and Config.fluid_tanks[name] then return true end
local w = peripheral.wrap(name)
if w and w.tanks and not w.list then return true end
return false
end
function mgmtGroupIsFluid(g)
if g.fluid ~= nil then return g.fluid end
return mgmtIsFluidPeriph(g.input) or mgmtIsFluidPeriph(g.output)
end
function mgmtMoveFluid(srcName, destName, fluidName, amount)
if not amount or amount <= 0 then return 0 end
local srcP = peripheral.wrap(srcName)
if srcP and srcP.pushFluid then
local ok, mv = pcall(srcP.pushFluid, destName, amount, fluidName)
if ok and type(mv) == "number" and mv > 0 then return mv end
end
local dstP = peripheral.wrap(destName)
if dstP and dstP.pullFluid then
local ok2, mv2 = pcall(dstP.pullFluid, srcName, amount, fluidName)
if ok2 and type(mv2) == "number" and mv2 > 0 then return mv2 end
end
return 0
end
function mgmtFluidStockSnap()
local snap = {}
for k, v in pairs(getFluidInventory()) do
snap[fluidNameFromKey(k)] = v
end
return snap
end
function runMgmtFluidGroup(group)
local moved = 0
local inputIsStg  = (not group.input  or group.input  == "" or group.input  == "STORAGE")
local outputIsStg = (not group.output or group.output == "" or group.output == "STORAGE")
if inputIsStg and outputIsStg then return 0 end
local fsnap = mgmtFluidStockSnap()
local netTanks = fluidTankList()
if group.drain and not inputIsStg then
for fname, amt in pairs(tankContents(group.input)) do
local toMove = amt
if outputIsStg then
for _, tname in ipairs(netTanks) do
if toMove <= 0 then break end
if tname ~= group.input then
local mv = mgmtMoveFluid(group.input, tname, fname, toMove)
if mv > 0 then toMove = toMove - mv; moved = moved + mv end
end
end
else
local mv = mgmtMoveFluid(group.input, group.output, fname, toMove)
if mv > 0 then moved = moved + mv end
end
end
end
for _, rule in ipairs(group.rules or {}) do
local curInOutput = 0
if outputIsStg then
curInOutput = fsnap[rule.item] or 0
else
curInOutput = (tankContents(group.output))[rule.item] or 0
end
local condOk = true
if rule.condition and rule.condition.item and rule.condition.item ~= "" then
local condCount = fsnap[rule.condition.item] or 0
local condVal   = rule.condition.value or 1
local condOp    = rule.condition.op or "<"
if condOp == "<" then condOk = condCount < condVal
elseif condOp == ">" then condOk = condCount > condVal
elseif condOp == "=" then condOk = condCount == condVal
end
end
if condOk and curInOutput < rule.amount then
local needed = rule.amount - curInOutput
if inputIsStg then
for _, src in ipairs(tanksWithFluid(rule.item)) do
if needed <= 0 then break end
if src.periph ~= group.output then
local mv = mgmtMoveFluid(src.periph, group.output, rule.item, needed)
if mv > 0 then
needed = needed - mv
moved  = moved + mv
fsnap[rule.item] = math.max(0, (fsnap[rule.item] or 0) - mv)
end
end
end
elseif outputIsStg then
for _, tname in ipairs(netTanks) do
if needed <= 0 then break end
if tname ~= group.input then
local mv = mgmtMoveFluid(group.input, tname, rule.item, needed)
if mv > 0 then
needed = needed - mv
moved  = moved + mv
fsnap[rule.item] = (fsnap[rule.item] or 0) + mv
end
end
end
else
local mv = mgmtMoveFluid(group.input, group.output, rule.item, needed)
if mv > 0 then needed = needed - mv; moved = moved + mv end
end
end
end
return moved
end
-- ==========================================
-- OPTIMIZED LOGISTICS ENGINE
-- ==========================================

function mgmtIOList(group, isInput)
    local lst = isInput and group.inputs or group.outputs
    if type(lst) == "table" and #lst > 0 then return lst end
    local s = isInput and group.input or group.output
    if not s or s == "" or s == "STORAGE" then return { "STORAGE" } end
    return { s }
end

function mgmtListIsStorage(lst)
    return (#lst == 0) or (lst[1] == "STORAGE")
end

function mgmtIODisplay(group, isInput)
    local lst = mgmtIOList(group, isInput)
    if mgmtListIsStorage(lst) then return "STORAGE" end
    local d = getMachineDisplay(lst[1]) or lst[1]
    if #lst > 1 then d = d .. " +" .. (#lst - 1) end
    return d
end

-- Helper function to get peripheral inventory with 1-tick cache
function mgmtGetCachedList(pName, tickCache)
    if not pName or pName == "" or pName == "STORAGE" then return {} end
    if tickCache[pName] then return tickCache[pName] end
    local p = peripheral.wrap(pName)
    if p and p.list then
        local ok, lst = pcall(p.list)
        if ok and lst then
            tickCache[pName] = lst
            return lst
        end
    end
    tickCache[pName] = {}
    return {}
end

function mgmtCountItem(srcNames, itemName, tickCache)
    local total = 0
    local isWild = not itemName:find("#")
    for _, nm in ipairs(srcNames) do
        local items = tickCache and mgmtGetCachedList(nm, tickCache) or (peripheral.wrap(nm) and peripheral.wrap(nm).list and peripheral.wrap(nm).list() or {})
        for _, si in pairs(items) do
            if si and (makeItemKey(si.name, si.nbt) == itemName or (isWild and si.name == itemName)) then total = total + (si.count or 0) end
        end
    end
    return total
end

-- Dump item from external device into storage (buffer priority)
function mgmtPushToStorage(srcName, srcSlot, amount, storageList)
    local moved = 0
    -- 1. First try dumping into buffer
    if Config.buffer and Config.buffer ~= "" and Config.buffer ~= srcName then
        local mv = mgmtMoveSlot(srcName, srcSlot, Config.buffer, amount)
        if mv > 0 then return mv end
    end
    -- 2. If no buffer or buffer full - dump into Main Vaults / Storages
    for _, sn in ipairs(storageList) do
        if moved >= amount then break end
        if sn ~= srcName then
            local mv = mgmtMoveSlot(srcName, srcSlot, sn, amount - moved)
            if mv > 0 then moved = moved + mv end
        end
    end
    return moved
end

function mgmtMoveFromDev(srcName, dest, itemName, amount, storageList, tickCache)
    if amount <= 0 then return 0 end
    local items = tickCache and mgmtGetCachedList(srcName, tickCache) or (peripheral.wrap(srcName) and peripheral.wrap(srcName).list and peripheral.wrap(srcName).list() or {})
    local moved = 0
    local isWild = not itemName:find("#")

    for sl, si in pairs(items) do
        if moved >= amount then break end
        if si and (makeItemKey(si.name, si.nbt) == itemName or (isWild and si.name == itemName)) and (si.count or 0) > 0 then
            local want = math.min(amount - moved, si.count)
            local mv = 0
            if dest == "STORAGE" then
                mv = mgmtPushToStorage(srcName, sl, want, storageList)
            else
                mv = mgmtMoveSlot(srcName, sl, dest, want)
            end
            if mv > 0 then
                moved = moved + mv
                si.count = si.count - mv
            end
        end
    end
    return moved
end

function mgmtDrawEven(inputs, dest, itemName, amount, storageList, rr, tickCache)
    local moved = 0
    local n = #inputs
    if n == 0 or amount <= 0 then return 0 end
    while moved < amount do
        local cycleMoved = 0
        local chunk = math.max(1, math.ceil((amount - moved) / n))
        for _ = 1, n do
            if moved >= amount then break end
            rr.i = (rr.i % n) + 1
            local mv = mgmtMoveFromDev(inputs[rr.i], dest, itemName, math.min(amount - moved, chunk), storageList, tickCache)
            if mv > 0 then
                moved = moved + mv
                cycleMoved = cycleMoved + mv
            end
        end
        if cycleMoved == 0 then break end
    end
    return moved
end

function runMgmtItemGroup(group, stockSnap, storageList, tickCache)
    local moved   = 0
    local inputs  = mgmtIOList(group, true)
    local outputs = mgmtIOList(group, false)
    local inStg   = mgmtListIsStorage(inputs)
    local outStg  = mgmtListIsStorage(outputs)
    if inStg and outStg then return 0 end

    -- 1. DRAIN mode (empty inputs)
    if group.drain and not inStg then
        local rr = { i = 0 }
        for _, nm in ipairs(inputs) do
            local slots = mgmtGetCachedList(nm, tickCache)
            for sl, si in pairs(slots) do
                if si and (si.count or 0) > 0 then
                    local toMove = si.count
                    if outStg then
                        local mv = mgmtPushToStorage(nm, sl, toMove, storageList)
                        if mv > 0 then
                            si.count = si.count - mv
                            moved = moved + mv
                            stockSnap[si.name] = (stockSnap[si.name] or 0) + mv
                        end
                    else
                        local cnt = #outputs
                        while toMove > 0 do
                            local before = toMove
                            for _ = 1, cnt do
                                if toMove <= 0 then break end
                                rr.i = (rr.i % cnt) + 1
                                local mv = mgmtMoveSlot(nm, sl, outputs[rr.i], toMove)
                                if mv > 0 then
                                    toMove = toMove - mv
                                    si.count = si.count - mv
                                    moved = moved + mv
                                end
                            end
                            if toMove == before then break end
                        end
                    end
                end
            end
        end
    end

    -- 2. Process RULES
    for _, rule in ipairs(group.rules or {}) do
        -- Check condition (IF Condition) via fast StorageIndex
        local condOk = true
        if rule.condition and rule.condition.item and rule.condition.item ~= "" then
            local condItem = rule.condition.item
            local condCount = (StorageIndex.byItem[condItem] and StorageIndex.byItem[condItem].total) or stockSnap[condItem] or 0
            local condVal   = rule.condition.value or 1
            local condOp    = rule.condition.op or "<"
            if condOp == "<" then condOk = condCount < condVal
            elseif condOp == ">" then condOk = condCount > condVal
            elseif condOp == "=" then condOk = condCount == condVal end
        end

        if condOk then
            -- Calculate deficit in target devices
            local targets = {}
            if outStg then
                local cur = (StorageIndex.byItem[rule.item] and StorageIndex.byItem[rule.item].total) or stockSnap[rule.item] or 0
                targets[1] = { dest = "STORAGE", cur = cur, def = math.max(0, rule.amount - cur) }
            else
                for _, oN in ipairs(outputs) do
                    local cur = mgmtCountItem({ oN }, rule.item, tickCache)
                    targets[#targets + 1] = { dest = oN, cur = cur, def = math.max(0, rule.amount - cur) }
                end
            end

            local sumDef = 0
            for _, t in ipairs(targets) do sumDef = sumDef + t.def end

            if sumDef > 0 then
                if inStg then
                    -- SOURCE: STORAGE -> Transfer directly via fast pushFromStorage
                    for _, t in ipairs(targets) do
                        if t.def > 0 and t.dest ~= "STORAGE" then
                            if not (tickCache.blockedDest and tickCache.blockedDest[t.dest]) then
                                local mv = pushFromStorage(rule.item, t.def, t.dest, nil, false)
                                if mv > 0 then
                                    moved = moved + mv
                                    stockSnap[rule.item] = math.max(0, (stockSnap[rule.item] or 0) - mv)
                                else
                                    -- Target device (Depot/Basin) busy/full: do not poll it this tick
                                    tickCache.blockedDest = tickCache.blockedDest or {}
                                    tickCache.blockedDest[t.dest] = true
                                end
                            end
                        end
                    end
                else
                    -- SOURCE: External chests/machines -> Balance across inputs
                    local avail = mgmtCountItem(inputs, rule.item, tickCache)
                    local toDist = math.min(avail, sumDef)

                    -- Optimized bulk distribution instead of item-by-item loop
                    local remainingDist = toDist
                    while remainingDist > 0 do
                        local pick, lvl, secondLvl
                        for ti, t in ipairs(targets) do
                            if t.def > 0 then
                                if not pick or t.cur < lvl then
                                    secondLvl = lvl
                                    pick = ti
                                    lvl = t.cur
                                elseif not secondLvl or t.cur < secondLvl then
                                    secondLvl = t.cur
                                end
                            end
                        end
                        if not pick then break end
                        local maxChunk = targets[pick].def
                        if secondLvl and secondLvl > lvl then
                            maxChunk = math.min(maxChunk, secondLvl - lvl)
                        end
                        local chunk = math.max(1, math.min(remainingDist, maxChunk))
                        targets[pick].cur   = targets[pick].cur + chunk
                        targets[pick].def   = targets[pick].def - chunk
                        targets[pick].alloc = (targets[pick].alloc or 0) + chunk
                        remainingDist = remainingDist - chunk
                    end

                    local rr = { i = 0 }
                    for _, t in ipairs(targets) do
                        local alloc = t.alloc or 0
                        if alloc > 0 then
                            local mv = mgmtDrawEven(inputs, t.dest, rule.item, alloc, storageList, rr, tickCache)
                            if mv > 0 then
                                moved = moved + mv
                                if outStg then
                                    stockSnap[rule.item] = (stockSnap[rule.item] or 0) + mv
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return moved
end

runMgmtTransfers = function()
    local totalMoved = 0
    if #MgmtGroups == 0 then
        mgmtSyncInfo = "no groups"
        return totalMoved
    end

    -- Build reserve storages list
    local storageList = {}
    for vName, isEnabled in pairs(Config.main_vaults or {}) do
        if isEnabled and not SYSTEM_SIDES[vName] then table.insert(storageList, vName) end
    end
    for sName, isEnabled in pairs(Config.storages or {}) do
        if isEnabled and not SYSTEM_SIDES[sName] then table.insert(storageList, sName) end
    end

    local stockSnap = getStorageInventoryCached()
    local tickCache = {} -- Cleared every run for tick isolation

    for _, group in ipairs(MgmtGroups) do
        if group.paused then goto mgmt_continue end
        if group.provider then goto mgmt_continue end

        if mgmtGroupIsFluid(group) then
            totalMoved = totalMoved + runMgmtFluidGroup(group)
            goto mgmt_continue
        end

        totalMoved = totalMoved + runMgmtItemGroup(group, stockSnap, storageList, tickCache)
        ::mgmt_continue::
    end

    if totalMoved > 0 then
        mgmtSyncInfo = "moved: " .. totalMoved
        if invalidateStockCache then invalidateStockCache() end
    else
        mgmtSyncInfo = "ok (0 moved)"
    end
    return totalMoved
end
function drawTabButton(x, y, name, activeTab, zones)
if name == activeTab then
drawText(x, y, " " .. name .. " ", colors.white, colors.gray)
drawText(x, y + 1, string.rep("-", #name + 2), colors.lime, colors.black)
else
drawText(x, y, " " .. name .. " ", colors.gray, colors.black)
end
table.insert(zones, {id="switch_tab", arg=name, x1=x, x2=x + #name + 1, y=y})
return x + #name + 3
end
function drawMgmtCondRow(pX, pW, ruleRowY, rule, ri2, touchZones)
local cond = rule.condition
_bufFillRect(pX + 1, ruleRowY, pW - 2, 1, colors.lightGray)
if cond and cond.item and cond.item ~= "" then
local cItem = getItemDisplayName(cond.item)
local opStr  = "[" .. (cond.op or "<") .. "]"
local cVal   = tostring(cond.value or 1)
local ifDelX  = pX + pW - 7
local ifTypX  = ifDelX - 5
local ifPlusX = ifTypX - 5
local ifValX  = ifPlusX - #cVal
local ifMinX  = ifValX - 5
local ifOpX   = ifMinX - #opStr - 2
local ifNameX = pX + 5
drawText(pX + 2,  ruleRowY, "IF ",  colors.orange,    colors.lightGray)
drawText(ifNameX, ruleRowY, cItem:sub(1, math.max(0, ifOpX - ifNameX)), colors.lime, colors.lightGray)
drawText(ifOpX,   ruleRowY, " " .. opStr .. " ",  colors.black,  colors.yellow)
drawText(ifMinX,  ruleRowY, " [-] ",  colors.white,  colors.lightGray)
drawText(ifValX,  ruleRowY, cVal,   colors.yellow, colors.lightGray)
drawText(ifPlusX, ruleRowY, " [+] ", colors.white,  colors.lightGray)
drawText(ifTypX,  ruleRowY, " [#] ",  colors.black,  colors.orange)
drawText(ifDelX,  ruleRowY, " [X] ",  colors.white,  colors.red)
table.insert(touchZones, {id="mgmt_rule_if_item", arg=ri2,      x1=ifNameX, x2=ifOpX-1, y=ruleRowY})
table.insert(touchZones, {id="mgmt_rule_if_op",   arg=ri2,      x1=ifOpX, x2=ifOpX+#opStr+1, y=ruleRowY})
table.insert(touchZones, {id="mgmt_rule_if_adj",  arg={ri2,-1}, x1=ifMinX, x2=ifMinX+4, y=ruleRowY})
table.insert(touchZones, {id="mgmt_rule_if_adj",  arg={ri2, 1}, x1=ifPlusX, x2=ifPlusX+4, y=ruleRowY})
table.insert(touchZones, {id="mgmt_rule_if_type", arg=ri2,      x1=ifTypX, x2=ifTypX+4, y=ruleRowY})
table.insert(touchZones, {id="mgmt_rule_if_del",  arg=ri2,      x1=ifDelX, x2=ifDelX+4, y=ruleRowY})
else
local addIfS = "[+IF]"
drawText(pX + 2, ruleRowY, addIfS, colors.gray, colors.lightGray)
drawText(pX + 2 + #addIfS + 1, ruleRowY, "add condition", colors.gray, colors.lightGray)
table.insert(touchZones, {id="mgmt_rule_if_add", arg=ri2, x1=pX+2, x2=pX+2+#addIfS-1, y=ruleRowY})
end
end
function _diB1(w, h, touchZones, popupRect)
local newGrpS = " [+ NEW GROUP] "
drawText(2, 9, "MACHINE GROUPS:", colors.white)
drawText(w - #newGrpS + 1, 9, newGrpS, colors.black, colors.lime)
if not custGrpPopup then
    table.insert(touchZones, {id="cgrp_new", x1=w-#newGrpS+1, x2=w, y=9})
end
drawText(2, 10, "Create custom groups for parallel crafting.", colors.gray)
drawText(1, 11, string.rep("-", w), colors.gray)

local rows = {}
for ci, cg in ipairs(CustomMachineGroups or {}) do
    local gKey = "cg:" .. (cg.name or ci)
    local isExp = (expandedGroups[gKey] == true)
    table.insert(rows, {type="custom_header", name=cg.name, idx=ci, count=#(cg.machines or {}), expanded=isExp, key=gKey})
    if isExp then
        local sortedCM = {}
        for _, cm in ipairs(cg.machines or {}) do table.insert(sortedCM, cm) end
        table.sort(sortedCM, naturalSortDisplay)
        for _, cm in ipairs(sortedCM) do
            table.insert(rows, {type="custom_machine", name=cm, groupIdx=ci})
        end
    end
end
local turtleListG = {}
for tName, enabled in pairs(Config.turtles or {}) do
if enabled then table.insert(turtleListG, tName) end
end
table.sort(turtleListG, naturalSortCompare)
if #turtleListG > 0 then
    local tKey = "turtles"
    local isExp = (expandedGroups[tKey] == true)
    table.insert(rows, {type="header", base="TURTLE GROUP", total=#turtleListG, excluded=0, isTurtle=true, expanded=isExp, key=tKey})
    if isExp then
        for _, tName in ipairs(turtleListG) do
            local isOnline = peripheral.wrap(tName) ~= nil
            table.insert(rows, {type="turtle_entry", name=tName, offline=not isOnline})
        end
    end
end
local unassignedTurtles = {}
for _, p in ipairs(peripheral.getNames()) do
if not SYSTEM_SIDES[p] and p ~= MONITOR_SIDE and p ~= Config.train_box
and not (Config.turtles and Config.turtles[p]) and not Config.storages[p] then
local tp = peripheral.wrap(p)
if tp and tp.craft then table.insert(unassignedTurtles, p) end
end
end
table.sort(unassignedTurtles, naturalSortCompare)
if #unassignedTurtles > 0 then
    local ntKey = "new_turtles"
    local isExp = (expandedGroups[ntKey] == true)
    table.insert(rows, {type="header", base="NEW TURTLES", total=#unassignedTurtles, excluded=0, isTurtle=true, expanded=isExp, key=ntKey})
    if isExp then
        for _, tName in ipairs(unassignedTurtles) do
            table.insert(rows, {type="turtle_new", name=tName})
        end
    end
end

if #rows == 0 then
drawText(2, 13, "No custom machine groups configured.", colors.gray)
drawText(2, 14, "Tap [+ NEW GROUP] above to create a group.", colors.gray)
else
local startRowY = 12
local itemsPerPage = h - startRowY - 2
local totalPages = math.max(1, math.ceil(#rows / itemsPerPage))
if currentPage > totalPages then currentPage = totalPages end
local startIdx = ((currentPage - 1) * itemsPerPage) + 1
local endIdx   = math.min(startIdx + itemsPerPage - 1, #rows)
local rowY = startRowY
for idx = startIdx, endIdx do
local row = rows[idx]
if row.type == "custom_header" then
local editS = " [EDIT] "; local delS = " [DEL] "
local delX2  = w - #delS + 1
local editX2 = delX2 - #editS - 1
local arr = row.expanded and "v " or "> "
local hdr2 = string.format(" %s[%s]  %d machines", arr, row.name, row.count)
drawText(1, rowY, string.rep(" ", w), colors.gray, colors.gray)
drawText(2, rowY, hdr2:sub(1, editX2 - 3), colors.orange, colors.gray)
drawText(editX2, rowY, editS, colors.white, colors.gray)
drawText(delX2,  rowY, delS,  colors.white, colors.red)
if not custGrpPopup then
    table.insert(touchZones, {id="cgrp_toggle", arg=row.key, x1=1, x2=editX2-2, y=rowY})
    table.insert(touchZones, {id="cgrp_edit", arg=row.idx, x1=editX2, x2=editX2+#editS-1, y=rowY})
    table.insert(touchZones, {id="cgrp_del",  arg=row.idx, x1=delX2,  x2=delX2+#delS-1,  y=rowY})
end
elseif row.type == "custom_machine" then
_bufClearLine(rowY, colors.black)
local remS = " [REMOVE] "
drawText(4, rowY, getMachineDisplay(row.name):sub(1, w - 4 - #remS), colors.yellow, colors.black)
drawText(w - #remS + 1, rowY, remS, colors.white, colors.gray)
if not custGrpPopup then
    table.insert(touchZones, {id="cgrp_remove", arg={row.groupIdx, row.name}, x1=w-#remS+1, x2=w, y=rowY})
end
elseif row.type == "header" then
local countLabel = row.isTurtle and "turtles" or "machines"
local arr = row.expanded and "v " or "> "
local hdr = string.format(" %s[%s]  %d %s", arr, row.base, row.total, countLabel)
local hdrColor = row.isTurtle and colors.cyan or colors.lime
drawText(1, rowY, string.rep(" ", w), colors.gray, colors.gray)
drawText(2, rowY, hdr, hdrColor, colors.gray)
if not custGrpPopup and row.key then
    table.insert(touchZones, {id="grp_toggle", arg=row.key, x1=1, x2=w, y=rowY})
end
elseif row.type == "turtle_entry" then
_bufClearLine(rowY, colors.black)
if row.offline then
drawText(4, rowY, row.name, colors.red, colors.black)
drawText(w - 19, rowY, "[OFFLINE]", colors.red, colors.black)
drawText(w - 9, rowY, " [REMOVE] ", colors.white, colors.gray)
if not custGrpPopup then
    table.insert(touchZones, {id="turtle_remove", arg=row.name, x1=w-9, x2=w-1, y=rowY})
end
else
drawText(4, rowY, row.name, colors.cyan, colors.black)
drawText(w - 14, rowY, "[parallel craft]", colors.gray, colors.black)
end
elseif row.type == "turtle_new" then
_bufClearLine(rowY, colors.black)
drawText(4, rowY, row.name, colors.orange, colors.black)
drawText(w - 8, rowY, " [+ADD] ", colors.black, colors.orange)
if not custGrpPopup then
    table.insert(touchZones, {id="turtle_add", arg=row.name, x1=w-8, x2=w-1, y=rowY})
end
end
rowY = rowY + 1
end
do
local navY = h - 1
drawText(1, navY - 1, string.rep("-", w), colors.gray)
local pageStr = string.format(" PAGE %d OF %d ", currentPage, math.max(1, totalPages))
local prevStr = " [ PREV ] "; local nextStr = " [ NEXT ] "
local navStartX = math.floor((w - (#prevStr + #pageStr + #nextStr + 4)) / 2)
drawText(navStartX, navY, prevStr, currentPage > 1 and colors.white or colors.lightGray, colors.gray)
drawText(navStartX + #prevStr + 2, navY, pageStr, colors.lime, colors.black)
local nextXPos = navStartX + #prevStr + #pageStr + 4
drawText(nextXPos, navY, nextStr, currentPage < totalPages and colors.white or colors.lightGray, colors.gray)
if not custGrpPopup then
    if currentPage > 1 then
        table.insert(touchZones, {id="prev_page", x1=navStartX, x2=navStartX + #prevStr - 1, y=navY})
    end
    if currentPage < totalPages then
        table.insert(touchZones, {id="next_page", x1=nextXPos, x2=nextXPos + #nextStr - 1, y=navY})
    end
end
end
end
end

function _diCustGrpPopup(w, h, touchZones, popupRect, popupZoneStart)
local allM = getAvailableMachines()
table.sort(allM, naturalSortDisplay)
local pW = math.min(w - 10, 70)
local pX = math.floor((w - pW) / 2) + 1
local pH = math.min(h - 4, 16)
local pY = math.floor((h - pH) / 2) + 1
local cols = 3
local colW = math.floor((pW - 2) / cols)
local listTop = pY + 4
local maxRows = pH - 6
local perPage = cols * maxRows
local cpPage = custGrpPopup.page or 1
local cpTotal = math.max(1, math.ceil(#allM / perPage))
if cpPage > cpTotal then cpPage = cpTotal; custGrpPopup.page = cpPage end
popupZoneStart = #touchZones + 1
popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
_bufFillRect(pX, pY, pW, pH, colors.gray)

local hdrTxt = custGrpPopup.editIdx and " EDIT CUSTOM GROUP " or " NEW CUSTOM GROUP "
drawText(pX + math.floor((pW - #hdrTxt) / 2), pY, hdrTxt, colors.black, colors.cyan)

local nDisp = (custGrpPopup.name and custGrpPopup.name ~= "") and custGrpPopup.name or "(tap to set)"
local setNS = " [SET NAME] "
drawText(pX + 2, pY + 1, ("Name: " .. nDisp):sub(1, pW - #setNS - 4), colors.white, colors.gray)
drawText(pX + pW - #setNS - 2, pY + 1, setNS, colors.black, colors.orange)
table.insert(touchZones, {id="cgrp_popup_name", x1=pX+pW-#setNS-2, x2=pX+pW-3, y=pY+1})

drawText(pX + 1, pY + 2, string.rep("-", pW - 2), colors.lightGray, colors.gray)

local selHdr = " SELECT MACHINES (tap to toggle):"
drawText(pX + 2, pY + 3, selHdr:sub(1, pW - 16), colors.yellow, colors.gray)
if cpTotal > 1 then
    local prevPS = " [<] "; local nextPS = " [>] "
    local pgInfoS = tostring(cpPage) .. "/" .. tostring(cpTotal)
    local pgX2 = pX + pW - #prevPS - #pgInfoS - #nextPS - 2
    local prevCol = cpPage > 1 and colors.white or colors.lightGray
    local nextCol = cpPage < cpTotal and colors.white or colors.lightGray
    drawText(pgX2, pY + 3, prevPS, prevCol, colors.gray)
    drawText(pgX2 + #prevPS, pY + 3, pgInfoS, colors.white, colors.gray)
    drawText(pgX2 + #prevPS + #pgInfoS, pY + 3, nextPS, nextCol, colors.gray)
    if cpPage > 1 then
        table.insert(touchZones, {id="cgrp_popup_prev", x1=pgX2, x2=pgX2+#prevPS-1, y=pY+3})
    end
    if cpPage < cpTotal then
        table.insert(touchZones, {id="cgrp_popup_next", x1=pgX2+#prevPS+#pgInfoS, x2=pgX2+#prevPS+#pgInfoS+#nextPS-1, y=pY+3})
    end
end

for ci = 1, cols - 1 do
    local sepX = pX + 1 + ci * colW
    for ry = 0, maxRows - 1 do
        drawText(sepX, listTop + ry, "|", colors.lightGray, colors.gray)
    end
end

if #allM == 0 then
    drawText(pX + 2, listTop, "No machines connected to network", colors.lightGray, colors.gray)
else
    local mStartIdx = (cpPage - 1) * perPage + 1
    local mEndIdx   = math.min(mStartIdx + perPage - 1, #allM)
    for mi = mStartIdx, mEndIdx do
        local idx0  = mi - mStartIdx
        local colI  = math.floor(idx0 / maxRows)
        local rowI  = idx0 % maxRows
        local cellX = pX + 2 + colI * colW
        local mRowY = listTop + rowI
        local mName2 = allM[mi]
        local isSel  = (custGrpPopup.selected and custGrpPopup.selected[mName2] == true)
        local chk    = isSel and "[x]" or "[ ]"
        local chkFg  = isSel and colors.lime or colors.white
        local mDisp2 = getMachineDisplay(mName2) or mName2
        local maxLen = colW - 2
        local itemText = chk .. " " .. mDisp2
        if #itemText > maxLen then itemText = itemText:sub(1, maxLen) end
        drawText(cellX, mRowY, itemText, chkFg, colors.gray)
        table.insert(touchZones, {id="cgrp_popup_toggle", arg=mName2, x1=cellX, x2=cellX + colW - 2, y=mRowY})
    end
end

drawText(pX + 1, pY + pH - 2, string.rep("-", pW - 2), colors.lightGray, colors.gray)
local canS = " [CANCEL] "; local savS = " [SAVE] "
drawText(pX + 2, pY + pH - 1, canS, colors.white, colors.red)
drawText(pX + pW - #savS - 2, pY + pH - 1, savS, colors.black, colors.lime)
table.insert(touchZones, {id="cgrp_popup_cancel", x1=pX+2, x2=pX+2+#canS-1, y=pY+pH-1})
table.insert(touchZones, {id="cgrp_popup_save",   x1=pX+pW-#savS-2, x2=pX+pW-3, y=pY+pH-1})

return popupRect, popupZoneStart
end
function getMachineGroupInfo(mName)
    if not mName or mName == "" then return nil end
    for _, cg in ipairs(CustomMachineGroups or {}) do
        for _, cm in ipairs(cg.machines or {}) do
            if cm == mName then
                local sameCount = 0
                local base = getMachineBaseName(mName)
                for _, m in ipairs(cg.machines or {}) do
                    if getMachineBaseName(m) == base then sameCount = sameCount + 1 end
                end
                return cg.name, sameCount
            end
        end
    end
    return nil
end

local function compFormatBox(label, totalW)
    local innerW = math.max(1, totalW - 4)
    local s = tostring(label or "")
    if #s > innerW then
        if innerW >= 6 then
            s = s:sub(1, innerW - 2) .. ".."
        else
            s = s:sub(1, innerW)
        end
    elseif #s < innerW then
        s = s .. string.rep(" ", innerW - #s)
    end
    return "[ " .. s .. " ]"
end

local function compCenterPad(str, width)
    local s = tostring(str or "")
    if #s >= width then return s:sub(1, width) end
    local rem = width - #s
    local lPad = math.floor(rem / 2)
    return string.rep(" ", lPad) .. s .. string.rep(" ", rem - lPad)
end

local function drawCompositeActionRow(actIdx, act, actRowY, devW, itemW, touchZones)
    local numStr = string.format("%2d.", actIdx)
    drawText(3, actRowY, numStr, colors.yellow)

    local isItem = (act.type == "item")
    local isTool = isItem and (act.is_tool == true)
    local typeTag = isItem and (isTool and " TOOL  " or " ITEM  ") or " FLUID "
    local tagFg   = isTool and colors.white or colors.black
    local tagCol  = isItem and (isTool and colors.magenta or colors.orange) or colors.cyan
    drawText(7, actRowY, typeTag, tagFg, tagCol)
    if isItem then
        table.insert(touchZones, {id="comp_act_toggle_tool", arg=actIdx, x1=7, x2=13, y=actRowY})
    end

    local devX = 15
    local devDisp = act.device and getMachineDisplay(act.device) or "+ Pick device..."
    local devBox  = compFormatBox(devDisp, devW)
    drawText(devX, actRowY, devBox, act.device and colors.lime or colors.yellow, colors.gray)
    table.insert(touchZones, {id="comp_act_dev", arg=actIdx, x1=devX, x2=devX+devW-1, y=actRowY})

    local arrX = devX + devW + 1
    drawText(arrX, actRowY, "<-", colors.lightGray)

    local itemX = arrX + 3
    local hasRes = isItem and (act.item and act.item ~= "") or (act.fluid and act.fluid ~= "")
    local resDisp = isItem
        and (hasRes and getItemDisplayName(act.item) or "+ Pick item...")
        or (hasRes and (act.fluid:match(":(.+)$") or act.fluid) or "+ Pick fluid...")
    local itemBox = compFormatBox(resDisp, itemW)
    drawText(itemX, actRowY, itemBox, hasRes and (isTool and colors.magenta or colors.cyan) or colors.yellow, colors.gray)
    table.insert(touchZones, {id="comp_act_item", arg=actIdx, x1=itemX, x2=itemX+itemW-1, y=actRowY})

    local cX = itemX + itemW + 2
    local stepVal, rawVal, valCol
    if isTool then
        local durV = act.durability or getWholeToolDurability(act.item)
        stepVal = (durV <= 20) and 1 or 10
        rawVal  = "D:" .. tostring(durV)
        valCol  = colors.magenta
    elseif isItem then
        stepVal = 1
        rawVal  = "x" .. tostring(act.count or 1)
        valCol  = colors.yellow
    else
        stepVal = 50
        rawVal  = tostring(act.amount or 250) .. "mB"
        valCol  = colors.yellow
    end
    local valField = compCenterPad(rawVal, 7)

    drawText(cX, actRowY, "[-]", colors.white, colors.gray)
    table.insert(touchZones, {id="comp_act_adj", arg={actIdx, -stepVal}, x1=cX, x2=cX+2, y=actRowY})
    cX = cX + 3
    drawText(cX, actRowY, valField, valCol)
    cX = cX + 7
    drawText(cX, actRowY, "[+]", colors.white, colors.gray)
    table.insert(touchZones, {id="comp_act_adj", arg={actIdx, stepVal}, x1=cX, x2=cX+2, y=actRowY})
    cX = cX + 4
    drawText(cX, actRowY, "[#]", colors.black, colors.orange)
    table.insert(touchZones, {id="comp_act_num", arg=actIdx, x1=cX, x2=cX+2, y=actRowY})
    cX = cX + 4
    drawText(cX, actRowY, "[X]", colors.white, colors.red)
    table.insert(touchZones, {id="comp_act_del", arg=actIdx, x1=cX, x2=cX+2, y=actRowY})
end

function drawCompositeStudioUI(w, h, touchZones)
    local isChance = (compositeDraft.mode == "chance")
    local roomy    = (h >= 34)
    local topStep  = roomy and 2 or 1
    local lblX     = 3
    local boxX     = (w >= 68) and 13 or 11
    local boxW     = (w >= 68) and 27 or 23
    local infoX    = boxX + boxW + 3

    local modeY   = 12
    local inY     = modeY + topStep
    local outY    = inY + topStep

    -- 1. Mode Row: [ NORMAL ] [ CHANCE ]
    drawText(lblX, modeY, "Mode:", colors.lightGray)
    local nBtn = (boxW >= 27) and "[  NORMAL  ]" or "[ NORMAL ]"
    local cBtn = (boxW >= 27) and "[  CHANCE  ]" or "[ CHANCE ]"
    local mGap = math.max(1, boxW - #nBtn - #cBtn)
    local cBtnX = boxX + #nBtn + mGap
    drawText(boxX, modeY, nBtn, not isChance and colors.black or colors.white, not isChance and colors.lime or colors.gray)
    table.insert(touchZones, {id="comp_mode_normal", x1=boxX, x2=boxX+#nBtn-1, y=modeY})
    drawText(cBtnX, modeY, cBtn, isChance and colors.black or colors.white, isChance and colors.orange or colors.gray)
    table.insert(touchZones, {id="comp_mode_chance", x1=cBtnX, x2=cBtnX+#cBtn-1, y=modeY})

    if infoX < w - 4 then
        local hasTB = (Config.train_box and Config.train_box ~= "")
        local tbTxt = hasTB and ("Box: " .. getMachineDisplay(Config.train_box)) or "! Set Train Box in NETWORK"
        drawText(infoX, modeY, tbTxt:sub(1, w - infoX), hasTB and colors.gray or colors.red)
    end

    -- 2. Input Machine / Platform Row
    drawText(lblX, inY, "Input:", colors.lightGray)
    local tgtName = compositeDraft.targetPlatform
    local hasTgt  = (tgtName and tgtName ~= "")
    local tgtDisp = hasTgt and getMachineDisplay(tgtName) or "+ Select input machine..."
    local tgtBox  = compFormatBox(tgtDisp, boxW)
    drawText(boxX, inY, tgtBox, hasTgt and colors.lime or colors.yellow, colors.gray)
    table.insert(touchZones, {id="comp_change_target", x1=boxX, x2=boxX+boxW-1, y=inY})
    if infoX < w - 4 then
        local grpName, grpCount = getMachineGroupInfo(tgtName)
        if grpName and grpCount and grpCount > 1 then
            drawText(infoX, inY, "Group: ", colors.gray)
            local pill = (" " .. grpName .. " (" .. grpCount .. "x) "):sub(1, math.max(1, w - infoX - 7))
            drawText(infoX + 7, inY, pill, colors.black, colors.cyan)
        elseif hasTgt then
            drawText(infoX, inY, ("Single machine"):sub(1, w - infoX), colors.gray)
        else
            drawText(infoX, inY, ("Depot, Basin, etc."):sub(1, w - infoX), colors.gray)
        end
    end

    -- 3. Output Machine / Platform Row
    drawText(lblX, outY, "Output:", colors.lightGray)
    local outName   = compositeDraft.outputPlatform
    local customOut = (outName and outName ~= "" and outName ~= tgtName)
    local outDisp   = customOut and getMachineDisplay(outName) or "(same as input)"
    local outBox    = compFormatBox(outDisp, boxW)
    drawText(boxX, outY, outBox, customOut and colors.orange or colors.cyan, colors.gray)
    table.insert(touchZones, {id="comp_change_output", x1=boxX, x2=boxX+boxW-1, y=outY})
    if infoX < w - 4 then
        if customOut then
            local sameBtn = " [ SAME ] "
            drawText(infoX, outY, sameBtn, colors.black, colors.cyan)
            table.insert(touchZones, {id="comp_reset_output", x1=infoX, x2=infoX+#sameBtn-1, y=outY})
        else
            drawText(infoX, outY, ("Tap box to override"):sub(1, w - infoX), colors.gray)
        end
    end

    -- 4. Section Divider & Actions Header Bar (with [+ ADD ACTION] right next to Actions:)
    local div1Y   = outY + 1
    local actBarY = div1Y + 1
    local div2Y   = actBarY + 1
    drawText(1, div1Y, string.rep("-", w), colors.gray)

    local actList = compositeDraft.actions or {}
    drawText(lblX, actBarY, "Actions:", colors.yellow)
    local addActBtn = (boxW >= 27) and "[ + ADD ACTION ]" or "[ + ADD ]"
    drawText(boxX, actBarY, addActBtn, colors.black, colors.lime)
    table.insert(touchZones, {id="comp_add_action", x1=boxX, x2=boxX+#addActBtn-1, y=actBarY})

    if #actList > 0 then
        local clrBtn = "[ CLEAR ]"
        local clrX   = boxX + boxW - #clrBtn
        drawText(clrX, actBarY, clrBtn, colors.white, colors.gray)
        table.insert(touchZones, {id="comp_clear_actions", x1=clrX, x2=clrX+#clrBtn-1, y=actBarY})
        if infoX < w - 16 then
            local cntTxt = string.format("%d step%s (tap ITEM/TOOL to toggle)", #actList, (#actList == 1) and "" or "s")
            drawText(infoX, actBarY, cntTxt:sub(1, w - infoX - 14), colors.lightGray)
        end
    else
        local hintX = boxX + #addActBtn + 3
        if hintX < w - 4 then
            drawText(hintX, actBarY, ("Deployers, Spouts, Basins"):sub(1, w - hintX), colors.gray)
        end
    end

    -- Divider separating Actions header bar from the numbered list below
    drawText(1, div2Y, string.rep("-", w), colors.gray)

    -- 5. Numbered Action List & Column Headers
    local tblHdrY    = div2Y + 1
    local listStartY = tblHdrY + 1
    local footDivY   = h - 2
    local footBtnY   = h - 1

    local devW  = math.min(22, math.max(14, math.floor((w - 38) * 0.44)))
    local arrX  = 15 + devW + 1
    local itemX = arrX + 3
    local itemW = math.min(26, math.max(12, w - itemX - 21 - 2))
    local ctrlX = itemX + itemW + 2

    drawText(3,          tblHdrY, " #",           colors.gray)
    drawText(8,          tblHdrY, "TYPE",         colors.gray)
    drawText(15,         tblHdrY, "DEVICE",       colors.gray)
    drawText(arrX,       tblHdrY, "<-",           colors.gray)
    drawText(itemX,      tblHdrY, "ITEM / FLUID", colors.gray)
    drawText(ctrlX + 2,  tblHdrY, "QTY / DUR",    colors.gray)
    drawText(ctrlX + 15, tblHdrY, "#",            colors.gray)
    drawText(ctrlX + 18, tblHdrY, "DEL",          colors.gray)

    local availRows  = math.max(1, footDivY - listStartY)
    local actRowStep = (availRows >= 6 and (#actList <= math.floor((availRows + 1) / 2) or availRows >= 10)) and 2 or 1
    local perPage    = math.max(1, math.floor((availRows + (actRowStep - 1)) / actRowStep))
    local totalPages = math.max(1, math.ceil(#actList / perPage))
    if not compositeDraft.actPage or compositeDraft.actPage < 1 then compositeDraft.actPage = 1 end
    if compositeDraft.actPage > totalPages then compositeDraft.actPage = totalPages end
    local aPage = compositeDraft.actPage

    if totalPages > 1 then
        local pgS  = string.format(" %d/%d ", aPage, totalPages)
        local navW = 3 + #pgS + 3
        local navX = w - navW - 1
        drawText(navX, actBarY, "[<]", aPage > 1 and colors.white or colors.gray, colors.gray)
        if aPage > 1 then
            table.insert(touchZones, {id="comp_act_prev", x1=navX, x2=navX+2, y=actBarY})
        end
        drawText(navX + 3, actBarY, pgS, colors.yellow)
        drawText(navX + 3 + #pgS, actBarY, "[>]", aPage < totalPages and colors.white or colors.gray, colors.gray)
        if aPage < totalPages then
            table.insert(touchZones, {id="comp_act_next", x1=navX+3+#pgS, x2=navX+navW-1, y=actBarY})
        end
    end

    if #actList == 0 then
        local emptyY = math.max(listStartY, math.floor((listStartY + footDivY - 1) / 2))
        local e1 = "No secondary actions configured"
        local e2 = "Tap [+ ADD ACTION] above to add Deployers or Spouts"
        drawText(math.max(2, math.floor((w - #e1) / 2) + 1), emptyY, e1, colors.lightGray)
        if emptyY + 1 < footDivY then
            drawText(math.max(2, math.floor((w - #e2) / 2) + 1), emptyY + 1, e2:sub(1, w - 2), colors.gray)
        end
    else
        local aStart = (aPage - 1) * perPage + 1
        local aEnd   = math.min(aStart + perPage - 1, #actList)
        for actIdx = aStart, aEnd do
            local actRowY = listStartY + (actIdx - aStart) * actRowStep
            if actRowY >= footDivY then break end
            drawCompositeActionRow(actIdx, actList[actIdx], actRowY, devW, itemW, touchZones)
        end
    end

    -- 6. Bottom Divider & Footer Action Buttons
    drawText(1, footDivY, string.rep("-", w), colors.gray)
    if uiMessage ~= "" then
        local banner = "  " .. uiMessage:sub(1, w - 10) .. "  "
        local bX     = math.max(2, math.floor((w - #banner) / 2) + 1)
        drawText(bX, footDivY, banner, colors.yellow, colors.black)
    end

    local isReady = hasTgt
    for _, act in ipairs(actList) do
        if not act.device or act.device == "" then isReady = false end
        if act.type == "item" and (not act.item or act.item == "") then isReady = false end
        if act.type == "fluid" and (not act.fluid or act.fluid == "") then isReady = false end
    end

    local hasResults = (compositeDraft.testDone == true) or (#(compositeDraft.results or {}) > 0)
    local resStr     = " [ RESULTS ] "
    local rstStr     = " [ RESET ] "

    if isChance then
        local t1Str   = " [ TEST 1x ] "
        local batStr  = " [ BATCH TEST ] "
        local bTotalW = #t1Str + 2 + #batStr + 2 + #resStr + 2 + #rstStr
        local curBX   = math.max(2, math.floor((w - bTotalW) / 2) + 1)

        drawText(curBX, footBtnY, t1Str, colors.black, isReady and colors.lime or colors.orange)
        table.insert(touchZones, {id="comp_start_test", x1=curBX, x2=curBX+#t1Str-1, y=footBtnY})
        curBX = curBX + #t1Str + 2

        drawText(curBX, footBtnY, batStr, colors.black, isReady and colors.orange or colors.yellow)
        table.insert(touchZones, {id="comp_start_batch", x1=curBX, x2=curBX+#batStr-1, y=footBtnY})
        curBX = curBX + #batStr + 2

        drawText(curBX, footBtnY, resStr, hasResults and colors.black or colors.lightGray, hasResults and colors.cyan or colors.gray)
        if hasResults then
            table.insert(touchZones, {id="comp_open_results", x1=curBX, x2=curBX+#resStr-1, y=footBtnY})
        end
        curBX = curBX + #resStr + 2

        drawText(curBX, footBtnY, rstStr, colors.white, colors.gray)
        table.insert(touchZones, {id="comp_reset", x1=curBX, x2=curBX+#rstStr-1, y=footBtnY})
    else
        local scanStr = " [ SCAN & TEST ] "
        local bTotalW = #scanStr + 3 + #resStr + 3 + #rstStr
        local curBX   = math.max(2, math.floor((w - bTotalW) / 2) + 1)

        drawText(curBX, footBtnY, scanStr, colors.black, isReady and colors.lime or colors.orange)
        table.insert(touchZones, {id="comp_start_test", x1=curBX, x2=curBX+#scanStr-1, y=footBtnY})
        curBX = curBX + #scanStr + 3

        drawText(curBX, footBtnY, resStr, hasResults and colors.black or colors.lightGray, hasResults and colors.cyan or colors.gray)
        if hasResults then
            table.insert(touchZones, {id="comp_open_results", x1=curBX, x2=curBX+#resStr-1, y=footBtnY})
        end
        curBX = curBX + #resStr + 3

        drawText(curBX, footBtnY, rstStr, colors.white, colors.gray)
        table.insert(touchZones, {id="comp_reset", x1=curBX, x2=curBX+#rstStr-1, y=footBtnY})
    end
end
function drawCompositePopup(w, h, touchZones, popupRect, popupZoneStart)
    if not compositePopup then return popupRect, popupZoneStart end

    if compositePopup.mode == "add_action" then
        local pW = math.min(w - 6, 38)
        local pH = 11
        local pX = math.floor((w - pW) / 2) + 1
        local pY = math.floor((h - pH) / 2) + 1
        popupZoneStart = #touchZones + 1
        popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
        _bufFillRect(pX, pY, pW, pH, colors.gray)
        _bufFillRect(pX, pY, pW, 1, colors.cyan)

        local hdr = " ADD SECONDARY ACTION "
        drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.cyan)

        local prompt = "Select action type to add:"
        drawText(pX + math.floor((pW - #prompt) / 2), pY + 2, prompt, colors.white, colors.gray)

        local btnW   = math.min(pW - 6, 28)
        local btnX   = pX + math.floor((pW - btnW) / 2)
        local itmBtn = "[" .. compCenterPad("+ ITEM (Deployer)", btnW - 2) .. "]"
        local fldBtn = "[" .. compCenterPad("+ FLUID (Spout/Basin)", btnW - 2) .. "]"

        drawText(btnX, pY + 4, itmBtn, colors.black, colors.orange)
        table.insert(touchZones, {id="comp_new_item_action", x1=btnX, x2=btnX+btnW-1, y=pY+4})

        drawText(btnX, pY + 6, fldBtn, colors.black, colors.cyan)
        table.insert(touchZones, {id="comp_new_fluid_action", x1=btnX, x2=btnX+btnW-1, y=pY+6})

        drawText(pX + 2, pY + 8, string.rep("-", pW - 4), colors.lightGray, colors.gray)

        local cBtn = " [ CANCEL ] "
        local cX   = pX + math.floor((pW - #cBtn) / 2)
        drawText(cX, pY + 9, cBtn, colors.white, colors.red)
        table.insert(touchZones, {id="comp_popup_cancel", x1=cX, x2=cX+#cBtn-1, y=pY+9})
        return popupRect, popupZoneStart

    elseif compositePopup.mode == "pick_device" then
        local allM = getAvailableMachines()
        table.sort(allM, naturalSortDisplay)
        local pW = math.min(w - 6, 70)
        local pH = math.min(h - 4, 18)
        local pX = math.floor((w - pW) / 2) + 1
        local pY = math.floor((h - pH) / 2) + 1
        popupZoneStart = #touchZones + 1
        popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
        _bufFillRect(pX, pY, pW, pH, colors.gray)
        _bufFillRect(pX, pY, pW, 1, colors.orange)

        local hdr = " SELECT DEVICE / PLATFORM "
        if compositePopup.target == "target" then
            hdr = " SELECT INPUT PLATFORM "
        elseif compositePopup.target == "output" then
            hdr = " SELECT OUTPUT PLATFORM "
        elseif compositePopup.target == "action_device" then
            hdr = " SELECT ACTION DEVICE "
        end
        drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.orange)

        local curSel = nil
        if compositePopup.target == "target" then
            curSel = compositeDraft.targetPlatform
        elseif compositePopup.target == "output" then
            curSel = compositeDraft.outputPlatform or compositeDraft.targetPlatform
        elseif compositePopup.target == "action_device" then
            local act = compositeDraft.actions and compositeDraft.actions[compositePopup.actionIdx]
            if act then curSel = act.device end
        end

        local cols    = 3
        local colW    = math.floor((pW - 2) / cols)
        local listTop = pY + 2
        local maxRows = pH - 5
        local perPage = cols * maxRows
        local pPage   = compositePopup.page or 1
        local pTotal  = math.max(1, math.ceil(#allM / perPage))
        if pPage > pTotal then pPage = pTotal; compositePopup.page = pPage end
        local pStart  = (pPage - 1) * perPage + 1
        local pEnd    = math.min(pStart + perPage - 1, #allM)

        for ci = 1, cols - 1 do
            local sepX = pX + 1 + ci * colW
            for ry = 0, maxRows - 1 do
                drawText(sepX, listTop + ry, "|", colors.lightGray, colors.gray)
            end
        end

        for mi = pStart, pEnd do
            local idx0  = mi - pStart
            local colI  = math.floor(idx0 / maxRows)
            local rowI  = idx0 % maxRows
            local cellX = pX + 2 + colI * colW
            local mRowY = listTop + rowI
            local mName = allM[mi]
            local isSel = (mName == curSel)
            local mDisp = (isSel and "> " or "") .. getMachineDisplay(mName)
            if #mDisp > colW - 2 then mDisp = mDisp:sub(1, colW - 2) end
            drawText(cellX, mRowY, mDisp, isSel and colors.lime or colors.white, colors.gray)
            table.insert(touchZones, {id="comp_select_device", arg=mName, x1=cellX, x2=cellX+colW-2, y=mRowY})
        end

        drawText(pX + 1, pY + pH - 2, string.rep("-", pW - 2), colors.lightGray, colors.gray)
        local navY = pY + pH - 1
        local arrL = " [ < ] "; local arrR = " [ > ] "
        drawText(pX + 2, navY, arrL, pPage > 1 and colors.white or colors.lightGray, colors.gray)
        if pPage > 1 then
            table.insert(touchZones, {id="comp_popup_prev", x1=pX+2, x2=pX+2+#arrL-1, y=navY})
        end
        local pgInfo = string.format(" %d/%d ", pPage, pTotal)
        drawText(pX + 2 + #arrL, navY, pgInfo, colors.yellow, colors.gray)
        drawText(pX + 2 + #arrL + #pgInfo, navY, arrR, pPage < pTotal and colors.white or colors.lightGray, colors.gray)
        if pPage < pTotal then
            local rx = pX + 2 + #arrL + #pgInfo
            table.insert(touchZones, {id="comp_popup_next", x1=rx, x2=rx+#arrR-1, y=navY})
        end

        if compositePopup.target == "output" then
            local rstSame = " [RESET (SAME)] "
            local rstX = pX + 2 + #arrL + #pgInfo + #arrR + 2
            drawText(rstX, navY, rstSame, colors.black, colors.cyan)
            table.insert(touchZones, {id="comp_select_device", arg="__RESET_SAME__", x1=rstX, x2=rstX+#rstSame-1, y=navY})
        end

        local cBtn = " [ CANCEL ] "
        drawText(pX + pW - #cBtn - 2, navY, cBtn, colors.white, colors.red)
        table.insert(touchZones, {id="comp_popup_cancel", x1=pX+pW-#cBtn-2, x2=pX+pW-3, y=navY})
        return popupRect, popupZoneStart

    elseif compositePopup.mode == "pick_item" then
        local boxName = Config.train_box
        local itemMap = {}
        local boxError = nil

        if not boxName or boxName == "" then
            boxError = "Assign a barrel with [T.BOX] in NETWORK."
        elseif not peripheral.isPresent(boxName) then
            boxError = "The assigned barrel is offline."
        else
            local box = peripheral.wrap(boxName)
            if not box or not box.list then
                boxError = "The assigned barrel cannot be read."
            else
                local okList, contents = pcall(box.list)
                if not okList or type(contents) ~= "table" then
                    boxError = "Failed to read the assigned barrel."
                else
                    for slot, item in pairs(contents) do
                        if item and item.name and (item.count or 0) > 0 then
                            local itemKey = makeItemKey(item.name, item.nbt)
                            if not itemMap[itemKey] then
                                itemMap[itemKey] = {name = itemKey, count = 0, slot = slot}
                            end
                            itemMap[itemKey].count = itemMap[itemKey].count + item.count
                        end
                    end
                end
            end
        end

        local itemList = {}
        for _, item in pairs(itemMap) do
            resolveItemDisplayName(boxName, item.slot, item.name)
            table.insert(itemList, item)
        end
        table.sort(itemList, function(a, b)
            return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name))
        end)

        local pW = math.min(w - 6, 70)
        local pH = math.min(h - 4, 18)
        local pX = math.floor((w - pW) / 2) + 1
        local pY = math.floor((h - pH) / 2) + 1
        popupZoneStart = #touchZones + 1
        popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
        _bufFillRect(pX, pY, pW, pH, colors.gray)
        _bufFillRect(pX, pY, pW, 1, colors.lime)

        local hdr = (compositePopup.target == "result_item")
            and " SELECT RESULT ITEM FROM BARREL "
            or " SELECT ACTION ITEM FROM BARREL "
        drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.lime)

        local cols    = 3
        local colW    = math.floor((pW - 2) / cols)
        local listTop = pY + 2
        local maxRows = pH - 5
        local perPage = cols * maxRows
        local pPage   = compositePopup.page or 1
        local pTotal  = math.max(1, math.ceil(#itemList / perPage))
        if pPage > pTotal then pPage = pTotal; compositePopup.page = pPage end
        local pStart  = (pPage - 1) * perPage + 1
        local pEnd    = math.min(pStart + perPage - 1, #itemList)

        if boxError or #itemList == 0 then
            local emptyM = boxError or "Barrel is empty. Put the desired item inside."
            drawText(pX + math.floor((pW - #emptyM) / 2), pY + math.floor(pH / 2), emptyM:sub(1, pW - 4), colors.lightGray, colors.gray)
        else
            for ci = 1, cols - 1 do
                local sepX = pX + 1 + ci * colW
                for ry = 0, maxRows - 1 do
                    drawText(sepX, listTop + ry, "|", colors.lightGray, colors.gray)
                end
            end

            for ii = pStart, pEnd do
                local idx0  = ii - pStart
                local colI  = math.floor(idx0 / maxRows)
                local rowI  = idx0 % maxRows
                local cellX = pX + 2 + colI * colW
                local mRowY = listTop + rowI
                local it    = itemList[ii]
                local iDisp = getItemDisplayName(it.name)
                local cntS  = tostring(it.count)
                local maxN  = colW - #cntS - 3
                if #iDisp > maxN then iDisp = iDisp:sub(1, maxN) end
                drawText(cellX, mRowY, iDisp, colors.white, colors.gray)
                drawText(cellX + colW - #cntS - 2, mRowY, cntS, colors.yellow, colors.gray)
                table.insert(touchZones, {id="comp_select_item", arg=it.name, x1=cellX, x2=cellX+colW-2, y=mRowY})
            end
        end

        drawText(pX + 1, pY + pH - 2, string.rep("-", pW - 2), colors.lightGray, colors.gray)
        local navY = pY + pH - 1
        local arrL = " [ < ] "; local arrR = " [ > ] "
        drawText(pX + 2, navY, arrL, pPage > 1 and colors.white or colors.lightGray, colors.gray)
        if pPage > 1 then
            table.insert(touchZones, {id="comp_popup_prev", x1=pX+2, x2=pX+2+#arrL-1, y=navY})
        end
        local pgInfo = string.format(" %d/%d ", pPage, pTotal)
        drawText(pX + 2 + #arrL, navY, pgInfo, colors.yellow, colors.gray)
        local rx = pX + 2 + #arrL + #pgInfo
        drawText(rx, navY, arrR, pPage < pTotal and colors.white or colors.lightGray, colors.gray)
        if pPage < pTotal then
            table.insert(touchZones, {id="comp_popup_next", x1=rx, x2=rx+#arrR-1, y=navY})
        end

        local refreshBtn = " [ REFRESH ] "
        local refreshX = rx + #arrR + 2
        drawText(refreshX, navY, refreshBtn, colors.black, colors.cyan)
        table.insert(touchZones, {id="comp_barrel_refresh", x1=refreshX, x2=refreshX+#refreshBtn-1, y=navY})

        local cBtn = " [ CANCEL ] "
        local cBtnX = pX + pW - #cBtn - 2
        drawText(cBtnX, navY, cBtn, colors.white, colors.red)
        table.insert(touchZones, {id="comp_popup_cancel", x1=cBtnX, x2=cBtnX+#cBtn-1, y=navY})
        return popupRect, popupZoneStart

    elseif compositePopup.mode == "pick_fluid" then
        local finv = getFluidInventory()
        local fluidList = {}
        for fK, fC in pairs(finv) do
            local fn = fluidNameFromKey(fK)
            table.insert(fluidList, { name = fn, amount = fC })
        end
        table.sort(fluidList, function(a, b) return naturalSortCompare(a.name, b.name) end)

        local pW = math.min(w - 6, 56)
        local pH = math.min(h - 4, 14)
        local pX = math.floor((w - pW) / 2) + 1
        local pY = math.floor((h - pH) / 2) + 1
        popupZoneStart = #touchZones + 1
        popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
        _bufFillRect(pX, pY, pW, pH, colors.gray)
        _bufFillRect(pX, pY, pW, 1, colors.cyan)

        local hdr = " SELECT FLUID FROM [TNK] "
        drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.cyan)

        local listTop = pY + 2
        if #fluidList == 0 then
            local emptyF = "No fluids found in [TNK] tanks."
            drawText(pX + math.floor((pW - #emptyF) / 2), pY + math.floor(pH / 2), emptyF, colors.lightGray, colors.gray)
        else
            for fi, fl in ipairs(fluidList) do
                if listTop + fi - 1 >= pY + pH - 2 then break end
                local ry = listTop + fi - 1
                local sn = fl.name:match(":(.+)$") or fl.name
                local amtS = tostring(fl.amount) .. "mB"
                drawText(pX + 2, ry, sn, colors.white, colors.gray)
                drawText(pX + pW - #amtS - 3, ry, amtS, colors.cyan, colors.gray)
                table.insert(touchZones, {id="comp_select_fluid", arg=fl.name, x1=pX+2, x2=pX+pW-3, y=ry})
            end
        end

        drawText(pX + 1, pY + pH - 2, string.rep("-", pW - 2), colors.lightGray, colors.gray)
        local cBtn = " [ CANCEL ] "
        local navY = pY + pH - 1
        drawText(pX + pW - #cBtn - 2, navY, cBtn, colors.white, colors.red)
        table.insert(touchZones, {id="comp_popup_cancel", x1=pX+pW-#cBtn-2, x2=pX+pW-3, y=navY})
        return popupRect, popupZoneStart

    elseif compositePopup.mode == "results" then
        local isChance = (compositeDraft.mode == "chance")
        local resList  = compositeDraft.results or {}
        local pW = math.min(w - 4, 74)
        local pH = math.min(h - 4, 18)
        local pX = math.floor((w - pW) / 2) + 1
        local pY = math.floor((h - pH) / 2) + 1
        popupZoneStart = #touchZones + 1
        popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
        _bufFillRect(pX, pY, pW, pH, colors.gray)
        _bufFillRect(pX, pY, pW, 1, isChance and colors.orange or colors.lime)

        local hdr = isChance and " CRAFT RESULTS & BYPRODUCTS (CHANCE MODE) " or " CRAFT RESULTS & BYPRODUCTS "
        drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, isChance and colors.orange or colors.lime)

        -- Row pY+2: Base Ingredient per craft operation
        local baseRowY = pY + 2
        drawText(pX + 2, baseRowY, "Base / op:", colors.lightGray, colors.gray)

        local bIngs = compositeDraft.baseIngredients
        if not bIngs or #bIngs == 0 then
            if compositeDraft.baseItem and compositeDraft.baseItem ~= "" then
                bIngs = { { item = compositeDraft.baseItem, count = compositeDraft.baseCount or 1 } }
                compositeDraft.baseIngredients = bIngs
            else
                bIngs = {}
            end
        end

        if #bIngs > 1 then
            local parts = {}
            for _, bi in ipairs(bIngs) do
                table.insert(parts, getItemDisplayName(bi.item) .. " x" .. tostring(bi.count or 1))
            end
            local multiDisp = table.concat(parts, ", ")
            local bCtrlX = pX + pW - 8
            local maxBW  = math.max(8, bCtrlX - (pX + 13) - 1)
            drawText(pX + 13, baseRowY, multiDisp:sub(1, maxBW), colors.yellow, colors.gray)
            drawText(bCtrlX, baseRowY, "[EDIT]", colors.black, colors.orange)
            table.insert(touchZones, {id="comp_res_base_num", x1=bCtrlX, x2=bCtrlX+5, y=baseRowY})
        else
            local baseDisp = (bIngs[1] and bIngs[1].item and bIngs[1].item ~= "")
                and getItemDisplayName(bIngs[1].item) or (compositeDraft.baseItem and getItemDisplayName(compositeDraft.baseItem) or "<none>")
            local bCtrlX = pX + pW - 18
            local maxBW  = math.max(8, bCtrlX - (pX + 13) - 1)
            drawText(pX + 13, baseRowY, baseDisp:sub(1, maxBW), colors.yellow, colors.gray)

            drawText(bCtrlX, baseRowY, "[-]", colors.white, colors.lightGray)
            table.insert(touchZones, {id="comp_res_base_adj", arg=-1, x1=bCtrlX, x2=bCtrlX+2, y=baseRowY})
            local bValS = compCenterPad("x" .. tostring(compositeDraft.baseCount or 1), 6)
            drawText(bCtrlX + 3, baseRowY, bValS, colors.yellow, colors.gray)
            drawText(bCtrlX + 9, baseRowY, "[+]", colors.white, colors.lightGray)
            table.insert(touchZones, {id="comp_res_base_adj", arg=1, x1=bCtrlX+9, x2=bCtrlX+11, y=baseRowY})
            drawText(bCtrlX + 13, baseRowY, "[#]", colors.black, colors.orange)
            table.insert(touchZones, {id="comp_res_base_num", x1=bCtrlX+13, x2=bCtrlX+15, y=baseRowY})
        end

        drawText(pX + 1, pY + 3, string.rep("-", pW - 2), colors.lightGray, colors.gray)

        -- Column layout
        local roleX = pX + 2
        local delX  = pX + pW - 4
        local chX   = isChance and (delX - 9) or delX
        local qtyX  = (isChance and chX or delX) - 17
        local nameX = roleX + 14
        local nameW = math.max(10, qtyX - nameX - 1)

        local hdrY = pY + 4
        drawText(roleX,     hdrY, "ROLE (TAP)",  colors.lightGray, colors.gray)
        drawText(nameX,     hdrY, "OUTPUT ITEM", colors.lightGray, colors.gray)
        drawText(qtyX + 2,  hdrY, "QTY/OP",      colors.lightGray, colors.gray)
        if isChance then
            drawText(chX + 1, hdrY, "CHANCE",    colors.lightGray, colors.gray)
        end
        drawText(delX,      hdrY, "DEL",         colors.lightGray, colors.gray)

        local listTop = pY + 5
        local maxRows = math.max(1, pH - 9)
        local rPage   = compositePopup.page or compositeDraft.resPage or 1
        local rTotal  = math.max(1, math.ceil(#resList / maxRows))
        if rPage > rTotal then rPage = rTotal end
        if rPage < 1 then rPage = 1 end
        compositePopup.page    = rPage
        compositeDraft.resPage = rPage

        local rStart = (rPage - 1) * maxRows + 1
        local rEnd   = math.min(rStart + maxRows - 1, #resList)

        if #resList == 0 then
            local empMsg = "No output items recorded. Tap [ + ADD ITEM ] below."
            drawText(pX + math.max(2, math.floor((pW - #empMsg) / 2)), listTop + math.floor(maxRows / 2), empMsg, colors.yellow, colors.gray)
        else
            for ri = rStart, rEnd do
                local ry  = listTop + (ri - rStart)
                local res = resList[ri]
                local isRec = (res.role == "recipe")

                -- Equal 13-character role button: "[  RECIPE   ]" vs "[ BYPRODUCT ]"
                local roleBtn = isRec and "[  RECIPE   ]" or "[ BYPRODUCT ]"
                drawText(roleX, ry, roleBtn, colors.black, isRec and colors.lime or colors.cyan)
                table.insert(touchZones, {id="comp_res_toggle_role", arg=ri, x1=roleX, x2=roleX+12, y=ry})

                local iDisp = getItemDisplayName(res.item):sub(1, nameW)
                drawText(nameX, ry, iDisp, isRec and colors.white or colors.lightGray, colors.gray)

                drawText(qtyX, ry, "[-]", colors.white, colors.lightGray)
                table.insert(touchZones, {id="comp_res_qty_adj", arg={ri, -1}, x1=qtyX, x2=qtyX+2, y=ry})
                local qValS = compCenterPad("x" .. tostring(res.count or 1), 6)
                drawText(qtyX + 3, ry, qValS, colors.yellow, colors.gray)
                drawText(qtyX + 9, ry, "[+]", colors.white, colors.lightGray)
                table.insert(touchZones, {id="comp_res_qty_adj", arg={ri, 1}, x1=qtyX+9, x2=qtyX+11, y=ry})
                drawText(qtyX + 13, ry, "[#]", colors.black, colors.orange)
                table.insert(touchZones, {id="comp_res_qty_num", arg=ri, x1=qtyX+13, x2=qtyX+15, y=ry})

                if isChance then
                    local hasCh = (res.chance ~= nil and tonumber(res.chance) and tonumber(res.chance) > 0)
                    local chStr = hasCh and string.format("[%4d%% ]", math.floor(tonumber(res.chance))) or "[ ---% ]"
                    local chFg  = hasCh and colors.black or colors.white
                    local chBg  = hasCh and (isRec and colors.orange or colors.cyan) or colors.lightGray
                    drawText(chX, ry, chStr, chFg, chBg)
                    table.insert(touchZones, {id="comp_res_chance", arg=ri, x1=chX, x2=chX+#chStr-1, y=ry})
                end

                drawText(delX, ry, "[X]", colors.white, colors.red)
                table.insert(touchZones, {id="comp_res_del", arg=ri, x1=delX, x2=delX+2, y=ry})
            end
        end

        -- Action bar above footer divider: [ + ADD ITEM ], counts summary, and page navigation
        local barY = pY + pH - 4
        local addBtn = " [ + ADD ITEM ] "
        drawText(pX + 2, barY, addBtn, colors.black, colors.yellow)
        table.insert(touchZones, {id="comp_res_add_item", x1=pX+2, x2=pX+2+#addBtn-1, y=barY})

        local recCnt, bypCnt = 0, 0
        for _, r in ipairs(resList) do
            if r.role == "recipe" then recCnt = recCnt + 1 else bypCnt = bypCnt + 1 end
        end
        local sumTxt = string.format("%d recipe%s, %d byproduct%s",
            recCnt, (recCnt == 1) and "" or "s",
            bypCnt, (bypCnt == 1) and "" or "s")
        local sumX = pX + 2 + #addBtn + 2
        if sumX + #sumTxt < pX + pW - 14 then
            drawText(sumX, barY, sumTxt, colors.lightGray, colors.gray)
        end

        if rTotal > 1 then
            local pgS  = string.format(" %d/%d ", rPage, rTotal)
            local navW = 3 + #pgS + 3
            local navX = pX + pW - navW - 2
            drawText(navX, barY, "[<]", rPage > 1 and colors.white or colors.lightGray, colors.gray)
            if rPage > 1 then
                table.insert(touchZones, {id="comp_res_prev", x1=navX, x2=navX+2, y=barY})
            end
            drawText(navX + 3, barY, pgS, colors.yellow, colors.gray)
            drawText(navX + 3 + #pgS, barY, "[>]", rPage < rTotal and colors.white or colors.lightGray, colors.gray)
            if rPage < rTotal then
                table.insert(touchZones, {id="comp_res_next", x1=navX+3+#pgS, x2=navX+navW-1, y=barY})
            end
        end

        drawText(pX + 1, pY + pH - 3, string.rep("-", pW - 2), colors.lightGray, colors.gray)

        -- Footer buttons: [ SAVE ] and [ BACK ]
        local footY   = pY + pH - 2
        local hasBase = (compositeDraft.baseIngredients and #compositeDraft.baseIngredients > 0)
            or (compositeDraft.baseItem and compositeDraft.baseItem ~= "")
        local canSave = (recCnt >= 1) and hasBase
        local saveBtn = (recCnt > 1) and string.format(" [ SAVE (%d RECIPES) ] ", recCnt) or " [ SAVE ] "
        local backBtn = " [ BACK ] "
        local totFootW = #saveBtn + 4 + #backBtn
        local startFX  = pX + math.floor((pW - totFootW) / 2)

        drawText(startFX, footY, saveBtn, canSave and colors.black or colors.lightGray, canSave and colors.lime or colors.lightGray)
        if canSave then
            table.insert(touchZones, {id="comp_res_save", x1=startFX, x2=startFX+#saveBtn-1, y=footY})
        end
        local backX = startFX + #saveBtn + 4
        drawText(backX, footY, backBtn, colors.white, colors.red)
        table.insert(touchZones, {id="comp_popup_cancel", x1=backX, x2=backX+#backBtn-1, y=footY})
        return popupRect, popupZoneStart
    end

    return popupRect, popupZoneStart
end
function _diB2(w, h, touchZones)
if learningState == "IDLE" then
local isTurtleTab = (craftSubTab == "TURTLE")
local isMachineTab = (craftSubTab ~= "TURTLE")
local tStr = " [ TURTLE ] "
local mStr = " [ MACHINES ] "
local tabsTotal = #tStr + 4 + #mStr
local tabsX = math.floor((w - tabsTotal) / 2) + 1
local tX = tabsX
local mX = tabsX + #tStr + 4
drawText(tX, 9, tStr, isTurtleTab and colors.white or colors.gray, isTurtleTab and colors.gray or colors.black)
if isTurtleTab then drawText(tX, 10, string.rep("-", #tStr), colors.lime, colors.black) end
table.insert(touchZones, {id="craft_subtab", arg="TURTLE", x1=tX, x2=tX+#tStr-1, y=9})
drawText(mX, 9, mStr, isMachineTab and colors.white or colors.gray, isMachineTab and colors.gray or colors.black)
if isMachineTab then drawText(mX, 10, string.rep("-", #mStr), colors.lime, colors.black) end
table.insert(touchZones, {id="craft_subtab", arg="MACHINES", x1=mX, x2=mX+#mStr-1, y=9})
drawText(1, 11, string.rep("-", w), colors.gray)
if isTurtleTab then
local midY = math.floor((h + 12) / 2)
local d1 = "Place recipe in center 3x3 of barrel,"
local d2 = "then press SCAN."
drawText(math.floor((w - #d1) / 2) + 1, midY - 3, d1, colors.gray)
drawText(math.floor((w - #d2) / 2) + 1, midY - 2, d2, colors.lightGray)
local scanStr = " [ SCAN ] "
local scanX = math.floor((w - #scanStr) / 2) + 1
local btnY = midY
drawText(scanX, btnY, scanStr, colors.black, colors.lime)
table.insert(touchZones, {id="add_recipe_action", x1=scanX, x2=scanX+#scanStr-1, y=btnY})
if uiMessage ~= "" then
local msgX = math.floor((w - #uiMessage) / 2) + 1
drawText(msgX, btnY + 2, uiMessage, colors.white)
end
else
drawCompositeStudioUI(w, h, touchZones)
end
elseif learningState == "AWAITING_DECISION" and learnedResult then
local midY = math.floor(h / 2)
if learnAsAlt then
local shortName = getItemDisplayName(learnedResult.name)
local hdr1 = "ADD ALTERNATIVE RECIPE"
local hdr2 = "Alt for: " .. shortName
drawText(math.floor((w - #hdr1) / 2) + 1, midY - 2, hdr1, colors.lime)
drawText(math.floor((w - #hdr2) / 2) + 1, midY - 1, hdr2, colors.white)
if findDuplicateRecipe(learnedResult.name, {type = learnedCraftType, machine_name = learnedMachineName, ingredients = learnedIngredients}) then
local dubS = shortName .. "  DUB"
drawText(math.floor((w - #dubS) / 2) + 1, midY, dubS, colors.red)
end
local saveS = " [ SAVE ALT ] "
local discS = " [ DISCARD ] "
local totalW = #saveS + 2 + #discS
local curBX = math.floor((w - totalW) / 2) + 1
drawText(curBX, midY + 1, saveS, colors.black, colors.lime)
table.insert(touchZones, {id="learn_save", x1=curBX, x2=curBX+#saveS-1, y=midY+1})
curBX = curBX + #saveS + 2
drawText(curBX, midY + 1, discS, colors.white, colors.gray)
table.insert(touchZones, {id="learn_cancel", x1=curBX, x2=curBX+#discS-1, y=midY+1})
else
local outs = (learnedCraftType ~= "turtle" and learnedOutputs and #learnedOutputs > 0)
and learnedOutputs or {{name = learnedResult.name, count = learnedResult.count}}
local nTools = 0
if learnedTools then for _ in pairs(learnedTools) do nTools = nTools + 1 end end
local hdr1 = "RECIPE SCAN RESULT"
local titleY = midY - math.max(1, #outs) - nTools - 1
if titleY < 11 then titleY = 11 end
drawText(math.floor((w - #hdr1) / 2) + 1, titleY, hdr1, colors.lime)
local ly = titleY + 1
for _, o in ipairs(outs) do
local ex = Recipes[o.name]
local isReal = (type(ex) == "table" and ex.type ~= "fluid")
local isDub = findDuplicateRecipe(o.name, {type = learnedCraftType, machine_name = learnedMachineName, ingredients = learnedIngredients})
local sn = getItemDisplayName(o.name)
local line
if isDub then
line = "x" .. o.count .. " " .. sn .. "  DUB"
else
line = "x" .. o.count .. " " .. sn .. (isReal and "  -> +ALT" or "  -> NEW")
end
local lx = math.floor((w - #line) / 2) + 1
drawText(lx, ly, line, isDub and colors.red or (isReal and colors.yellow or colors.lime))
ly = ly + 1
end
if learnedTools then
for tn, tv in pairs(learnedTools) do
local tsn = getItemDisplayName(tn)
local durS = (type(tv) == "table" and tv.durability) and (" (Dur: " .. tostring(tv.durability) .. ")") or ""
local tline = "tool: " .. tsn .. durS
drawText(math.floor((w - #tline) / 2) + 1, ly, tline, colors.magenta)
ly = ly + 1
end
end
local btnRow = ly + 1
local saveS  = " [ SAVE ] "
local editS  = " [ EDIT ] "
local discS  = " [ DISCARD ] "
local totalW = #saveS + 2 + #editS + 2 + #discS
local curBX  = math.floor((w - totalW) / 2) + 1
drawText(curBX, btnRow, saveS, colors.black, colors.lime)
table.insert(touchZones, {id="learn_save", x1=curBX, x2=curBX+#saveS-1, y=btnRow})
curBX = curBX + #saveS + 2
drawText(curBX, btnRow, editS, colors.black, colors.yellow)
table.insert(touchZones, {id="learn_edit", x1=curBX, x2=curBX+#editS-1, y=btnRow})
curBX = curBX + #editS + 2
drawText(curBX, btnRow, discS, colors.white, colors.gray)
table.insert(touchZones, {id="learn_cancel", x1=curBX, x2=curBX+#discS-1, y=btnRow})
end
end
end
function _diBVaults(w, h, touchZones)
    -- 1. Top control bar
    local defragBtn = " [ RUN DEFRAG ] "
    local rescanBtn = " [ RESCAN ALL ] "
    local startBtnX = 2

    local isDef = (systemStatus == "DEFRAG")
    drawText(startBtnX, 9, defragBtn, isDef and colors.black or colors.white, isDef and colors.yellow or colors.orange)
    table.insert(touchZones, {id="vaults_run_defrag", x1=startBtnX, x2=startBtnX+#defragBtn-1, y=9})

    local rescanX = startBtnX + #defragBtn + 2
    local isRescan = (systemStatus == "RESCAN")
    drawText(rescanX, 9, rescanBtn, isRescan and colors.black or colors.black, isRescan and colors.yellow or colors.cyan)
    table.insert(touchZones, {id="vaults_rescan", x1=rescanX, x2=rescanX+#rescanBtn-1, y=9})

    drawText(1, 10, string.rep("-", w), colors.gray, colors.black)

    -- 2. Info cards
    local halfW = math.floor((w - 3) / 2)
    local cardY = 11

    -- Left card: BUFFER NODE
    local bufName = Config.buffer and getMachineDisplay(Config.buffer) or "<NONE>"
    local bufObj = Config.buffer and peripheral.wrap(Config.buffer)
    local bUsed, bMax, bFree, bPct = 0, 0, 0, 0

    if bufObj and bufObj.list and bufObj.size then
        local okL, lst = pcall(bufObj.list)
        local okS, sz = pcall(bufObj.size)
        if okL and okS and sz and sz > 0 then
            bMax = sz
            for _ in pairs(lst or {}) do bUsed = bUsed + 1 end
            bFree = math.max(0, bMax - bUsed)
            bPct = bUsed / bMax
        end
    end

    drawText(2, cardY, "BUFFER NODE: " .. bufName:sub(1, halfW - 14), colors.magenta, colors.black)
    local bufSlotStr = string.format("Used: %d/%d (%d free)", bUsed, bMax, bFree)
    drawText(2, cardY + 1, bufSlotStr, colors.white, colors.black)
    drawProgressBar(2, cardY + 2, halfW - 8, bUsed, math.max(1, bMax), colors.black)

    for dy = 0, 2 do drawText(halfW + 2, cardY + dy, "|", colors.gray, colors.black) end

    -- Right card: MAIN STORAGE TOTALS (dynamic count across all main_vaults)
    local totSlots, usedSlots = 0, 0
    for vName, en in pairs(Config.main_vaults or {}) do
        if en and not SYSTEM_SIDES[vName] then
            local st = StorageIndex.vaultStats[vName]
            if st then
                totSlots = totSlots + (st.max or 0)
                usedSlots = usedSlots + (st.used or 0)
            end
        end
    end
    local freeSlots = math.max(0, totSlots - usedSlots)
    local totPct = (totSlots > 0) and (usedSlots / totSlots) or 0

    local rightX = halfW + 4
    drawText(rightX, cardY, "MAIN VAULTS CAPACITY", colors.cyan, colors.black)
    local totSlotStr = string.format("Used: %d/%d (%d free)", usedSlots, totSlots, freeSlots)
    drawText(rightX, cardY + 1, totSlotStr, colors.white, colors.black)
    drawProgressBar(rightX, cardY + 2, w - rightX - 6, usedSlots, math.max(1, totSlots), colors.black)

    drawText(1, 14, string.rep("-", w), colors.gray, colors.black)

    -- 3. Main Vaults storage table
    local headY = 15
    drawText(2, headY, "VAULT NAME", colors.gray, colors.black)
    drawText(22, headY, "USED / MAX SLOTS", colors.gray, colors.black)
    drawText(42, headY, "FREE", colors.gray, colors.black)
    drawText(w - 18, headY, "USAGE %", colors.gray, colors.black)
    drawText(1, headY + 1, string.rep("-", w), colors.gray, colors.black)

    local mainList = {}
    for vName, en in pairs(Config.main_vaults or {}) do
        if en and not SYSTEM_SIDES[vName] then
            table.insert(mainList, vName)
        end
    end
    table.sort(mainList, naturalSortDisplay)

    local startRowY = 17
    local rowsPerPage = h - startRowY - 2
    local totalPages = math.max(1, math.ceil(#mainList / rowsPerPage))
    if currentPage > totalPages then currentPage = totalPages end
    local startIdx = ((currentPage - 1) * rowsPerPage) + 1
    local endIdx = math.min(startIdx + rowsPerPage - 1, #mainList)

    if #mainList == 0 then
        local noV = "No [MAIN] vaults configured. Set roles in NETWORK tab."
        drawText(math.floor((w - #noV) / 2) + 1, startRowY + 1, noV, colors.gray, colors.black)
    else
        local rowY = startRowY
        for i = startIdx, endIdx do
            local vName = mainList[i]
            local st = StorageIndex.vaultStats[vName] or { used = 0, max = 0, free = 0, pct = 0 }
            local rowBg = ((i - startIdx) % 2 == 0) and colors.black or colors.gray
            _bufClearLine(rowY, rowBg)

            local dName = getMachineDisplay(vName)
            local isOffline = (not st.max or st.max == 0 or not peripheral.wrap(vName))
            if isOffline then
                drawText(2, rowY, dName:sub(1, 18), colors.lightGray, rowBg)
                drawText(22, rowY, "OFFLINE", colors.red, rowBg)
                drawText(32, rowY, "Tap [RESCAN ALL] to clean", colors.yellow, rowBg)
            else
                drawText(2, rowY, dName:sub(1, 18), colors.white, rowBg)

                local slotStr = string.format("%d / %d", st.used or 0, st.max or 0)
                drawText(22, rowY, slotStr, colors.lightBlue, rowBg)

                local freeStr = tostring(st.free or 0)
                drawText(42, rowY, freeStr, colors.lime, rowBg)

                local barW = math.max(6, w - 74)
                local barX = 50
                if barW >= 6 then
                    drawProgressBar(barX, rowY, barW, st.used or 0, math.max(1, st.max or 1), rowBg)
                end

                local pctInt = math.floor((st.pct or 0) * 100)
                local pctCol = colors.lime
                if pctInt >= 85 then pctCol = colors.red
                elseif pctInt >= 60 then pctCol = colors.yellow end

                local pctStr = string.format("%3d%%", pctInt)
                drawText(w - 10, rowY, pctStr, pctCol, rowBg)
            end

            rowY = rowY + 1
        end
    end

    -- 4. Pagination navigation
    local navY = h - 1
    drawText(1, navY - 1, string.rep("-", w), colors.gray)
    local pageStr = string.format(" PAGE %d OF %d ", currentPage, math.max(1, totalPages))
    local prevStr = " [ PREV ] "
    local nextStr = " [ NEXT ] "
    local navStartX = math.floor((w - (#prevStr + #pageStr + #nextStr + 4)) / 2)
    drawText(navStartX, navY, prevStr, currentPage > 1 and colors.white or colors.lightGray, colors.gray)
    drawText(navStartX + #prevStr + 2, navY, pageStr, colors.lime, colors.black)
    local nextXPos = navStartX + #prevStr + #pageStr + 4
    drawText(nextXPos, navY, nextStr, currentPage < totalPages and colors.white or colors.lightGray, colors.gray)
    if currentPage > 1 then
        table.insert(touchZones, {id="prev_page", x1=navStartX, x2=navStartX+#prevStr-1, y=navY})
    end
    if currentPage < totalPages then
        table.insert(touchZones, {id="next_page", x1=nextXPos, x2=nextXPos+#nextStr-1, y=navY})
    end
end
function _diBVaultOpPopup(w, h, touchZones, popupRect)
    local pW = 46
    local pH = 8
    local pX = math.max(1, math.floor((w - pW) / 2) + 1)
    local pY = math.max(1, math.floor((h - pH) / 2) + 1)
    popupRect = { x1 = pX, x2 = pX + pW - 1, y1 = pY, y2 = pY + pH - 1 }
    _bufFillRect(pX, pY, pW, pH, colors.gray)

    local pop = vaultOpPopup
    local hdrStr = pop.title or " OPERATION "
    local hdrBg = pop.done and colors.lime or colors.cyan
    drawText(pX + math.floor((pW - #hdrStr) / 2), pY, hdrStr, colors.black, hdrBg)

    local stCol = pop.done and colors.lime or colors.yellow
    drawText(pX + 2, pY + 2, (pop.status or ""):sub(1, pW - 4), stCol, colors.gray)

    if pop.message and pop.message ~= "" then
        drawText(pX + 2, pY + 3, pop.message:sub(1, pW - 4), colors.white, colors.gray)
    end

    if pop.done then
        local clsStr = " [ CLOSE ] "
        local clsX = pX + math.floor((pW - #clsStr) / 2)
        local clsY = pY + pH - 2
        drawText(clsX, clsY, clsStr, colors.white, colors.black)
        table.insert(touchZones, 1, { id = "close_vault_popup", x1 = clsX, x2 = clsX + #clsStr - 1, y = clsY })
    else
        local waitStr = "Please wait..."
        drawText(pX + math.floor((pW - #waitStr) / 2), pY + pH - 2, waitStr, colors.lightGray, colors.gray)
    end

    return popupRect
end
function _diB4(w, h, touchZones, popupRect)
local rec
if recipeEditPopup.fluid then
rec = recipeEditPopup.fluidRecipeRef
elseif recipeEditPopup.altIdx then
local alts = AltRecipes[recipeEditPopup.item]
rec = alts and alts[recipeEditPopup.altIdx]
else
rec = Recipes[recipeEditPopup.item]
end
if not rec then
recipeEditPopup = nil
else
local sName = recipeEditPopup.fluid and (recipeEditPopup.fluid:match(":(.+)$") or recipeEditPopup.fluid)
or (recipeEditPopup.item:match(":(.+)$") or recipeEditPopup.item)
local turtleList = {}
for tName, enabled in pairs(Config.turtles or {}) do
if enabled then table.insert(turtleList, tName) end
end
table.sort(turtleList, naturalSortCompare)
local machList = getAvailableMachines()
table.sort(machList, naturalSortDisplay)
local allMachines = {}
for _, t in ipairs(turtleList) do table.insert(allMachines, t) end
for _, m in ipairs(machList)  do table.insert(allMachines, m) end
local pW = math.min(w - 10, 76)
local pH = math.min(h - 4, 19)
local pX = math.max(1, math.floor((w - pW) / 2) + 1)
local pY = math.max(1, math.floor((h - pH) / 2) + 1)
local cols = 3
local colW = math.floor((pW - 2) / cols)
local listTop = pY + 4
local maxRows = pH - 7
local maxVis  = cols * maxRows
local mTotal  = math.max(1, math.ceil(#allMachines / maxVis))
local mPage   = recipeEditPopup.page or 1
if mPage > mTotal then mPage = mTotal; recipeEditPopup.page = mPage end
local mStart  = (mPage - 1) * maxVis + 1
local mEnd    = math.min(mStart + maxVis - 1, #allMachines)
popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdrStr = " EDIT RECIPE: " .. sName:upper():sub(1, pW - 16) .. " "
drawText(pX + math.floor((pW - #hdrStr) / 2), pY, hdrStr, colors.black, colors.orange)
local curMachine = rec.machine_name or "?"
local curShort   = getMachineDisplay(curMachine)
drawText(pX + 2, pY + 2, "Current: " .. curShort, colors.white, colors.gray)
if recipeEditPopup.confirmGlobal then
local newSel   = recipeEditPopup.selected or curMachine
local newShort = getMachineDisplay(newSel)
local count = 0
local function recipeUsesMach(rData, mTarget)
if not rData then return false end
if rData.machine_name == mTarget or rData.output_device == mTarget then return true end
if rData.actions then
for _, act in ipairs(rData.actions) do
if act.device == mTarget then return true end
end
end
return false
end
if recipeEditPopup.isItemScope then
local iRec = Recipes[recipeEditPopup.item]
if recipeUsesMach(iRec, curMachine) then count = count + 1 end
local iAlts = AltRecipes[recipeEditPopup.item]
if iAlts then
for _, rData in ipairs(iAlts) do
if recipeUsesMach(rData, curMachine) then count = count + 1 end
end
end
else
for _, rData in pairs(Recipes) do
if rData.type ~= "fluid" and recipeUsesMach(rData, curMachine) then count = count + 1 end
end
for _, alts in pairs(AltRecipes or {}) do
for _, rData in ipairs(alts) do
if recipeUsesMach(rData, curMachine) then count = count + 1 end
end
end
for _, fr in pairs(FluidRecipes or {}) do
if recipeUsesMach(fr, curMachine) then count = count + 1 end
end
for _, alts in pairs(FluidAltRecipes or {}) do
for _, fr in ipairs(alts) do
if recipeUsesMach(fr, curMachine) then count = count + 1 end
end
end
end
local scopeLabel = recipeEditPopup.isItemScope and "This item only:" or "Replace ALL:"
drawText(pX + 2, pY + 4, scopeLabel .. " " .. curShort, colors.yellow, colors.gray)
drawText(pX + 2, pY + 5, "       -> " .. newShort, colors.lime, colors.gray)
drawText(pX + 2, pY + 6, "Affects " .. count .. " recipes!", colors.red, colors.gray)
local cfmStr = " [ CONFIRM REPLACE ALL ] "
local cnlStr = " [ CANCEL ] "
local cfmX   = pX + math.floor((pW - #cfmStr) / 2)
local cnlX   = pX + math.floor((pW - #cnlStr) / 2)
drawText(cfmX, pY + pH - 3, cfmStr, colors.black, colors.red)
table.insert(touchZones, 1, {id="recipe_edit_confirm_global", x1=cfmX, x2=cfmX+#cfmStr-1, y=pY+pH-3})
drawText(cnlX, pY + pH - 1, cnlStr, colors.white, colors.gray)
table.insert(touchZones, 1, {id="close_recipe_edit", x1=cnlX, x2=cnlX+#cnlStr-1, y=pY+pH-1})
else
drawText(pX + 2, pY + 3, "Select machine:", colors.lightGray, colors.gray)
for ci = 1, cols - 1 do
local sepX = pX + 1 + ci * colW
for ry = 0, maxRows - 1 do
drawText(sepX, listTop + ry, "|", colors.lightGray, colors.gray)
end
end
for i = mStart, mEnd do
local localIdx = i - mStart
local col = math.floor(localIdx / maxRows)
local row = localIdx % maxRows
local cellX = pX + 2 + col * colW
local cellY = listTop + row
local mName  = allMachines[i]
local mShort = getMachineDisplay(mName)
local isSel  = (mName == recipeEditPopup.selected)
local isCur  = (mName == curMachine)
local mColor = isSel and colors.black or (isCur and colors.lime or colors.white)
local mBg    = isSel and colors.lime or colors.gray
if #mShort > colW - 2 then mShort = mShort:sub(1, colW - 2) end
drawText(cellX, cellY, mShort, mColor, mBg)
table.insert(touchZones, 1, {id="recipe_edit_select", arg=mName, x1=cellX, x2=cellX+colW-2, y=cellY})
end
local navY = pY + pH - 2
local arrL = " < "; local arrR = " > "
local lAct = (mPage > 1)
local rAct = (mPage < mTotal)
drawText(pX + 2, navY, arrL, lAct and colors.white or colors.lightGray, colors.gray)
if lAct then
table.insert(touchZones, 1, {id="recipe_edit_prev", x1=pX+2, x2=pX+2+#arrL-1, y=navY})
end
drawText(pX + pW - #arrR - 2, navY, arrR, rAct and colors.white or colors.lightGray, colors.gray)
if rAct then
table.insert(touchZones, 1, {id="recipe_edit_next", x1=pX+pW-#arrR-2, x2=pX+pW-3, y=navY})
end
local btnY      = pY + pH - 1
local applyStr  = " [APPLY] "
local globalStr = " [REPLACE ALL] "
local cnlStr    = " [CANCEL] "
drawText(pX + 2, btnY, applyStr, colors.black, colors.lime)
table.insert(touchZones, 1, {id="recipe_edit_apply", x1=pX+2, x2=pX+2+#applyStr-1, y=btnY})
if not recipeEditPopup.fluid then
drawText(pX + 2 + #applyStr + 1, btnY, globalStr, colors.white, colors.orange)
table.insert(touchZones, 1, {id="recipe_edit_global", x1=pX+2+#applyStr+1, x2=pX+2+#applyStr+#globalStr, y=btnY})
end
local cnlX = pX + pW - #cnlStr - 2
drawText(cnlX, btnY, cnlStr, colors.white, colors.gray)
table.insert(touchZones, 1, {id="close_recipe_edit", x1=cnlX, x2=cnlX+#cnlStr-1, y=btnY})
end
end
return popupRect
end
function _diB5(w, stockInv, touchZones)
local modY = 9
local allMods = {"All"}
local seenMods = {All = true}
for itemName in pairs(stockInv) do
local modId = itemName:match("^([^:]+):") or "minecraft"
if not seenMods[modId] then seenMods[modId] = true; table.insert(allMods, modId) end
end
table.sort(allMods, function(a, b)
if a == "All" then return true end
if b == "All" then return false end
if a == "minecraft" then return true end
if b == "minecraft" then return false end
return a < b
end)
table.insert(allMods, 2, "TANK")
local arrowL = " < "
local arrowR = " > "
local areaX1 = 2 + #arrowL + 1
local areaX2 = w - 1 - #arrowR - 1
local areaW  = areaX2 - areaX1 + 1
local hasTankCat = false
local modsNoAllS = {}
for _, m in ipairs(allMods) do
if m == "TANK" then hasTankCat = true
elseif m ~= "All" then table.insert(modsNoAllS, m) end
end
local allDispS = " All "
local tankDispS = " TANK "
local function frontItemsS()
local f = {}
if hasTankCat then f[#f+1] = {name="TANK", disp=tankDispS} end
f[#f+1] = {name="All", disp=allDispS}
return f
end
local function fitsInRow(items, w_avail)
local total = -1
for _, it in ipairs(items) do total = total + #it.disp + 1 end
return total <= w_avail
end
local sPages = {}
local sStart = 1
while sStart <= #modsNoAllS do
local pageItems = {}
for i = sStart, #modsNoAllS do
table.insert(pageItems, {name=modsNoAllS[i], disp=" " .. modsNoAllS[i] .. " "})
local mid = math.ceil(#pageItems / 2)
local row1 = frontItemsS()
local row2 = {}
for j = 1, mid do table.insert(row1, pageItems[j]) end
for j = mid+1, #pageItems do table.insert(row2, pageItems[j]) end
if not (fitsInRow(row1, areaW) and fitsInRow(row2, areaW)) then
table.remove(pageItems)
break
end
end
if #pageItems == 0 then break end
local mid = math.ceil(#pageItems / 2)
local page = {[1]=frontItemsS(), [2]={}}
for j = 1, mid do table.insert(page[1], pageItems[j]) end
for j = mid+1, #pageItems do table.insert(page[2], pageItems[j]) end
table.insert(sPages, page)
sStart = sStart + #pageItems
end
if #sPages == 0 then
table.insert(sPages, {[1]=frontItemsS(), [2]={}})
end
local sTotalPages = math.max(1, #sPages)
if stockModFilterPage > sTotalPages then stockModFilterPage = sTotalPages end
if stockModFilterPage < 1 then stockModFilterPage = 1 end
local sPage = sPages[stockModFilterPage] or {[1]=frontItemsS(), [2]={}}
local sActModX, sActModW, sActModRow = nil, nil, nil
for ri = 1, 2 do
local ry = modY + (ri - 1)
local items = sPage[ri]
if #items > 0 then
local totalW = -1
for _, item in ipairs(items) do totalW = totalW + #item.disp + 1 end
local rx = math.max(areaX1, areaX1 + math.floor((areaW - totalW) / 2))
for _, item in ipairs(items) do
local isAct = (item.name == stockModFilter)
local fg = (item.name == "TANK") and colors.cyan or (isAct and colors.white or colors.gray)
drawText(rx, ry, item.disp, fg, isAct and colors.gray or colors.black)
if isAct then sActModX = rx; sActModW = #item.disp; sActModRow = ry end
table.insert(touchZones, {id="stock_mod", arg=item.name, x1=rx, x2=rx+#item.disp-1, y=ry})
rx = rx + #item.disp + 1
end
end
end
if sActModX and sActModRow == modY + 1 then
drawText(sActModX, sActModRow + 1, string.rep("-", sActModW), colors.lime, colors.black)
end
if sTotalPages > 1 then
local arrY = modY
local lActive = (stockModFilterPage > 1)
local rActive = (stockModFilterPage < sTotalPages)
drawText(2, arrY, arrowL, lActive and colors.white or colors.gray, lActive and colors.gray or colors.black)
if lActive then
table.insert(touchZones, {id="stock_mod_prev", x1=2, x2=2+#arrowL-1, y=arrY})
table.insert(touchZones, {id="stock_mod_prev", x1=2, x2=2+#arrowL-1, y=arrY+1})
end
local rX = w - #arrowR
drawText(rX, arrY, arrowR, rActive and colors.white or colors.gray, rActive and colors.gray or colors.black)
if rActive then
table.insert(touchZones, {id="stock_mod_next", x1=rX, x2=rX+#arrowR-1, y=arrY})
table.insert(touchZones, {id="stock_mod_next", x1=rX, x2=rX+#arrowR-1, y=arrY+1})
end
end
end
function _diB6(w, h, stockInv, touchZones)
_diB5(w, stockInv, touchZones)
do
local searchY = 12
local dSearch  = (stockSearchFilter == "") and "<type item name...>" or stockSearchFilter
local sColor   = (stockSearchFilter == "") and (stockSearchInputActive and colors.lightGray or colors.gray) or colors.white
local fullSrch = "FIND: [ " .. dSearch .. " ]"
local srchX    = math.max(14, math.floor((w - #fullSrch) / 2) + 1)
drawText(srchX, searchY, "FIND: ", colors.gray, colors.black)
local sBgActive = stockSearchInputActive and colors.gray or colors.black
drawText(srchX + 6, searchY, "[ " .. dSearch .. " ]", sColor, sBgActive)
table.insert(touchZones, {id="stock_search", x1=srchX, x2=srchX+#fullSrch-1, y=searchY})
if stockSearchFilter ~= "" then
local boxStr = "[ " .. dSearch .. " ]"
drawText(srchX + 6, searchY + 1, string.rep("-", #boxStr), colors.lime, colors.black)
drawText(srchX+#fullSrch+1, searchY, "[X]", colors.white, colors.red)
table.insert(touchZones, {id="stock_clear_search", x1=srchX+#fullSrch+1, x2=srchX+#fullSrch+3, y=searchY})
end
if Config.train_box and Config.train_box ~= "" then
local ulStr = " UNLOAD "
drawText(2, searchY, ulStr, colors.white, colors.gray)
if unloadActive then
drawText(2, searchY + 1, string.rep("-", #ulStr), colors.lime, colors.black)
end
table.insert(touchZones, {id="pull_from_box", x1=2, x2=1+#ulStr, y=searchY})
end
local optStr = " OPTIMIZE "
local optX   = w - #optStr + 1
drawText(optX, searchY, optStr, colors.white, colors.gray)
if optimizeActive then
drawText(optX, searchY + 1, string.rep("-", #optStr), colors.lime, colors.black)
end
table.insert(touchZones, {id="stock_optimize", x1=optX, x2=w, y=searchY})
end
local colW  = math.floor((w - 2) / 3)
local sep1X = colW + 1
local sep2X = 2 * colW + 2
local colStarts = {1, colW + 2, 2 * colW + 3}
local isTankCat = (stockModFilter == "TANK")
local headY = 14
if isTankCat then
drawText(2, headY, "T# FLUID NAME", colors.gray, colors.black)
drawText(1, headY + 1, string.rep("-", w), colors.gray)
else
for ci, cx in ipairs(colStarts) do
drawText(cx + 1, headY, "ITEM NAME", colors.gray, colors.black)
end
drawText(sep1X, headY, "|", colors.gray, colors.black)
drawText(sep2X, headY, "|", colors.gray, colors.black)
drawText(1, headY + 1, string.rep("-", w), colors.gray)
end
local totalPages
if isTankCat then
local inv, _ftc, _ftmb, tDetails = getFluidInventory()
local tankCntByKey = {}
do
local seen = {}
for _, d in ipairs(tDetails or {}) do
local k = fluidKey(d.fluid)
seen[k] = seen[k] or {}
if not seen[k][d.periph] then
seen[k][d.periph] = true
tankCntByKey[k] = (tankCntByKey[k] or 0) + 1
end
end
end
local fl = {}
for fk, amt in pairs(inv) do
local fn = fluidNameFromKey(fk)
local sn = fn:match(":(.+)$") or fn
if stockSearchFilter == "" or sn:lower():find(stockSearchFilter:lower(), 1, true) then
fl[#fl + 1] = {name = fn, mb = amt, tanks = tankCntByKey[fk] or 0}
end
end
table.sort(fl, function(a, b) return naturalSortCompare(a.name, b.name) end)
local startRowY = 16
local cols = 2
local rowsPerPage = h - startRowY - 3
if rowsPerPage < 1 then rowsPerPage = 1 end
local perPage = cols * rowsPerPage
totalPages = math.max(1, math.ceil(#fl / perPage))
if currentPage > totalPages then currentPage = totalPages end
local startIdx = ((currentPage - 1) * perPage) + 1
local endIdx = math.min(startIdx + perPage - 1, #fl)
local fColW = math.floor(w / cols)
for ry = 0, rowsPerPage - 1 do
_bufClearLine(startRowY + ry, (ry % 2 == 0) and colors.black or colors.gray)
end
for ci = 1, cols - 1 do
for ry = 0, rowsPerPage - 1 do
drawText(ci * fColW, startRowY + ry, "|", colors.gray, (ry % 2 == 0) and colors.black or colors.gray)
end
end
if #fl == 0 then
local none = "No fluids. Mark tanks with [TNK] in NETWORK."
drawText(math.floor((w - #none) / 2) + 1, startRowY + 1, none, colors.gray)
else
for i = startIdx, endIdx do
local li = i - startIdx
local col = math.floor(li / rowsPerPage)
local row = li % rowsPerPage
local rowY = startRowY + row
local colX = col * fColW + 1
local rowBg = (row % 2 == 0) and colors.black or colors.gray
local f = fl[i]
local mbStr = f.mb > FLUID_MAX_CAP and ">100000 mB" or string.format("%d mB", f.mb)
local tcStr = tostring(f.tanks)
drawText(colX + 1, rowY, tcStr, colors.yellow, rowBg)
local nmX = colX + 1 + #tcStr + 1
local nm = f.name:match(":(.+)$") or f.name
local nameMax = fColW - #mbStr - 4 - #tcStr - 1
if #nm > nameMax then nm = nm:sub(1, nameMax) end
drawText(nmX, rowY, nm, colors.white, rowBg)
drawText(colX + fColW - #mbStr - 2, rowY, mbStr, colors.cyan, rowBg)
end
end
else
local stockList = {}
local srchLow = (stockSearchFilter ~= "") and stockSearchFilter:lower() or nil
for itemName, count in pairs(stockInv) do
local modId = itemName:match("^([^:]+):") or "minecraft"
if stockModFilter == "All" or stockModFilter == modId then
local shortName = getItemDisplayName(itemName)
if not srchLow or shortName:lower():find(srchLow, 1, true) then
table.insert(stockList, {name=itemName, cnt=count, disp=shortName})
end
end
end
table.sort(stockList, function(a, b) return naturalSortCompare(a.disp, b.disp) end)
local startRowY    = 16
local rowsPerPage  = h - startRowY - 3
local itemsPerPage = rowsPerPage * 3
totalPages   = math.max(1, math.ceil(#stockList / itemsPerPage))
if currentPage > totalPages then currentPage = totalPages end
local startIdx = ((currentPage - 1) * itemsPerPage) + 1
local endIdx   = math.min(startIdx + itemsPerPage - 1, #stockList)
for ry = 0, rowsPerPage - 1 do
local rowBg = (ry % 2 == 0) and colors.black or colors.gray
_bufClearLine(startRowY + ry, rowBg)
drawText(sep1X, startRowY + ry, "|", colors.gray, colors.black)
drawText(sep2X, startRowY + ry, "|", colors.gray, colors.black)
end
for i = startIdx, endIdx do
local item    = stockList[i]
local pageIdx = i - startIdx
local col     = math.floor(pageIdx / rowsPerPage)
local row     = pageIdx % rowsPerPage
local colX    = colStarts[col + 1]
local rowY    = startRowY + row
local rowBg   = (row % 2 == 0) and colors.black or colors.gray
local shortName  = getItemDisplayName(item.name)
local nameMaxLen = colW - 9
drawText(colX + 1, rowY, shortName:sub(1, nameMaxLen), colors.white, rowBg)
local cStr = tostring(item.cnt)
local reqX = colX + colW - 5
drawText(reqX - 1 - #cStr, rowY, cStr, colors.cyan, rowBg)
local hasBox   = Config.train_box and Config.train_box ~= ""
local reqColor = hasBox and colors.cyan or colors.gray
drawText(reqX, rowY, "[REQ]", colors.black, reqColor)
if hasBox then
table.insert(touchZones, {id="open_req_picker", arg=item.name, x1=reqX, x2=reqX+4, y=rowY})
end
end
end
local navY = h - 1
drawText(1, navY - 1, string.rep("-", w), colors.gray)
local pageStr    = string.format(" PAGE %d OF %d ", currentPage, math.max(1, totalPages))
local prevStr    = " [ PREV ] "
local nextStr    = " [ NEXT ] "
local navStartX  = math.floor((w - (#prevStr + #pageStr + #nextStr + 4)) / 2)
drawText(navStartX, navY, prevStr, currentPage > 1 and colors.white or colors.lightGray, colors.gray)
drawText(navStartX + #prevStr + 2, navY, pageStr, colors.lime, colors.black)
local nextXPos = navStartX + #prevStr + #pageStr + 4
drawText(nextXPos, navY, nextStr, currentPage < totalPages and colors.white or colors.lightGray, colors.gray)
if currentPage > 1 then
table.insert(touchZones, {id="prev_page", x1=navStartX, x2=navStartX+#prevStr-1, y=navY})
end
if currentPage < totalPages then
table.insert(touchZones, {id="next_page", x1=nextXPos, x2=nextXPos+#nextStr-1, y=navY})
end
end
function _diB7(w, h, stockInv, touchZones)
local haltText = Config.autostock_paused and " [RESUME] " or " [PAUSE ALL] "
local haltColor = Config.autostock_paused and colors.lime or colors.red
drawText(2, 9, haltText, colors.white, haltColor)
table.insert(touchZones, {id="autostock_toggle", x1=2, x2=2+#haltText-1, y=9})
drawText(2 + #haltText + 1, 9, " [RUN NOW] ", colors.black, colors.orange)
table.insert(touchZones, {id="force_autostock", x1=2+#haltText+1, x2=2+#haltText+11, y=9})
if autostockCurrentItem ~= "" then
local asName = autostockCurrentItem:match(":(.+)$") or autostockCurrentItem
drawText(2 + #haltText + 14, 9, ">> " .. asName, colors.lime)
elseif Config.autostock_paused then
drawText(2 + #haltText + 14, 9, "PAUSED", colors.red)
else
drawText(2 + #haltText + 14, 9, "IDLE", colors.gray)
end
local kHasFluid = false
for k in pairs(Autostock) do if k:sub(1, 2) == "f:" then kHasFluid = true break end end
if kHasFluid then
local allStr = " ITEM "
local flStr  = " FLUID "
local aAct = (fluidKeepFilter ~= "FLUID")
local fAct = (fluidKeepFilter == "FLUID")
drawText(2, 10, allStr, aAct and colors.black or colors.gray, aAct and colors.lime or colors.black)
table.insert(touchZones, {id="keep_cat", arg="All", x1=2, x2=2+#allStr-1, y=10})
drawText(2+#allStr+1, 10, flStr, colors.cyan, fAct and colors.gray or colors.black)
table.insert(touchZones, {id="keep_cat", arg="FLUID", x1=2+#allStr+1, x2=2+#allStr+#flStr, y=10})
drawText(2+#allStr+#flStr+3, 10, "top = higher priority", colors.gray)
else
fluidKeepFilter = "All"
drawText(2, 10, "Higher position = higher priority (top runs first).", colors.gray)
end
drawText(1, 11, string.rep("-", w), colors.gray)
local startRowY = 12
local itemsPerPage = h - startRowY - 2
local keepFluidInv = (fluidKeepFilter == "FLUID") and getFluidInventory() or nil
local keepList = {}
for itemName, settings in pairs(Autostock) do
local isFl = (itemName:sub(1, 2) == "f:")
local show = (fluidKeepFilter == "FLUID") and isFl or (fluidKeepFilter ~= "FLUID" and not isFl)
if show then
table.insert(keepList, {
name      = itemName,
threshold = settings.threshold or settings.limit or 1,
target    = settings.target or settings.limit or 1,
paused    = settings.paused,
order     = settings.order or 99999,
fluid     = isFl,
})
end
end
table.sort(keepList, function(a, b)
if a.order ~= b.order then return a.order < b.order end
return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name))
end)
local totalPages = math.max(1, math.ceil(#keepList / itemsPerPage))
if currentPage > totalPages then currentPage = totalPages end
local startIdx = ((currentPage - 1) * itemsPerPage) + 1
local endIdx   = math.min(startIdx + itemsPerPage - 1, #keepList)

-- Auto-scan visible items on current page
local fstock = nil
for idx = startIdx, endIdx do
    local item = keepList[idx]
    if item then
        if item.fluid then
            local fluidRealName = fluidNameFromKey(item.name)
            if fluidScanResults[fluidRealName] == nil then
                if not fstock then
                    fstock = {}
                    for k, v in pairs(getFluidInventory()) do fstock[fluidNameFromKey(k)] = v end
                end
                if scanOneFluidFast then scanOneFluidFast(fluidRealName, fstock, stockInv) end
            end
        else
            if recipesScanResults[item.name] == nil then
                scanOneRecipeFast(item.name, stockInv)
            end
        end
    end
end

local rowY = startRowY
for idx = startIdx, endIdx do
local item = keepList[idx]
local globalIdx = idx
local fluidRealName = item.fluid and fluidNameFromKey(item.name) or item.name
local cleanName = item.fluid and (fluidRealName:match(":(.+)$") or fluidRealName) or getItemDisplayName(item.name)
local curStock
if item.fluid then
curStock = (keepFluidInv and keepFluidInv[item.name]) or 0
else
curStock = stockInv[item.name] or 0
end
local rowBg     = (idx % 2 == 0) and colors.gray or colors.black
_bufClearLine(rowY, rowBg)
local rankStr = string.format("#%d", globalIdx)
drawText(2, rowY, rankStr, colors.orange, rowBg)
local stockDisp  = (item.fluid and curStock > FLUID_MAX_CAP) and ">100000" or tostring(curStock)
local trigStr    = item.fluid
and string.format("%d>%d mB", item.threshold, item.target)
or string.format("%d>%d", item.threshold, item.target)
local nameColor  = item.paused and colors.lightGray or (autostockCurrentItem == item.name and colors.lime or colors.white)
local bx         = w - 38
local craftNowX  = bx - 9
local keepIndX   = craftNowX - 5
local trigW      = (fluidKeepFilter == "FLUID") and 16 or 11
local curStr     = "[" .. stockDisp .. "]"
local trigX      = (keepIndX - 2) - #trigStr + 1
local curX       = (keepIndX - 3 - trigW) - #curStr + 1
local nameMax    = math.max(4, curX - (2 + #rankStr) - 1)
drawText(2 + #rankStr, rowY, (" " .. cleanName):sub(1, nameMax), nameColor, rowBg)
drawText(curX, rowY, curStr, item.paused and colors.gray or ((curStock < item.threshold) and colors.orange or colors.lime), rowBg)
drawText(trigX, rowY, trigStr, item.paused and colors.gray or colors.lightGray, rowBg)
local keepScan = item.fluid and fluidScanResults[fluidRealName] or recipesScanResults[item.name]
if item.fluid then
if keepScan ~= nil then
if keepScan > 0 then
drawText(keepIndX, rowY, keepScan > 99 and ">99" or tostring(keepScan), colors.lime, rowBg)
else
drawText(keepIndX, rowY, "[!]", colors.white, colors.red)
end
else
drawText(keepIndX, rowY, "[~]", colors.lightGray, rowBg)
end
elseif keepScan then
local cMax = keepScan.maxCraftable or 0
if cMax > 0 then
local cStr = cMax > 99 and ">99" or tostring(cMax)
drawText(keepIndX, rowY, cStr, colors.lime, rowBg)
else
drawText(keepIndX, rowY, "[!]", colors.white, colors.red)
table.insert(touchZones, {id="show_craft_info", arg=item.name, x1=keepIndX, x2=keepIndX+2, y=rowY})
end
else
drawText(keepIndX, rowY, "[~]", colors.lightGray, rowBg)
end
drawText(craftNowX, rowY, "[CRAFT]", colors.black, colors.white)
table.insert(touchZones, {id="keep_craft_now", arg=item.name, x1=craftNowX, x2=craftNowX+6, y=rowY})
local topColor = (globalIdx > 1) and colors.white or colors.gray
drawText(bx, rowY, "[TOP]", topColor, colors.gray)
if globalIdx > 1 then
table.insert(touchZones, {id="keep_top", arg=item.name, x1=bx, x2=bx+4, y=rowY})
end
local upColor = (globalIdx > 1) and colors.white or colors.gray
drawText(bx+6, rowY, "[^]", upColor, colors.gray)
if globalIdx > 1 then
table.insert(touchZones, {id="keep_up", arg=item.name, x1=bx+6, x2=bx+8, y=rowY})
end
local dnColor = (globalIdx < #keepList) and colors.white or colors.gray
drawText(bx+10, rowY, "[v]", dnColor, colors.gray)
if globalIdx < #keepList then
table.insert(touchZones, {id="keep_dn", arg=item.name, x1=bx+10, x2=bx+12, y=rowY})
end
drawText(bx+14, rowY, "[EDIT]", colors.white, colors.gray)
table.insert(touchZones, {id="keep_edit", arg=item.name, x1=bx+14, x2=bx+19, y=rowY})
local stateStr   = item.paused and "[RUN]  " or "[PAUSE]"
local stateColor = item.paused and colors.red or colors.gray
drawText(bx+21, rowY, stateStr, colors.white, stateColor)
table.insert(touchZones, {id="toggle_keep_status", arg=item.name, x1=bx+21, x2=bx+27, y=rowY})
drawText(bx+29, rowY, "[DEL]", colors.white, colors.red)
table.insert(touchZones, {id="remove_keep", arg=item.name, x1=bx+29, x2=bx+33, y=rowY})
rowY = rowY + 1
end
do
local navY = h - 1
drawText(1, navY - 1, string.rep("-", w), colors.gray)
local pageStr = string.format(" PAGE %d OF %d ", currentPage, math.max(1, totalPages))
local prevStr = " [ PREV ] "; local nextStr = " [ NEXT ] "
local navStartX = math.floor((w - (#prevStr + #pageStr + #nextStr + 4)) / 2)
drawText(navStartX, navY, prevStr, currentPage > 1 and colors.white or colors.lightGray, colors.gray)
drawText(navStartX + #prevStr + 2, navY, pageStr, colors.lime, colors.black)
local nextXPos = navStartX + #prevStr + #pageStr + 4
drawText(nextXPos, navY, nextStr, currentPage < totalPages and colors.white or colors.lightGray, colors.gray)
if currentPage > 1 then
table.insert(touchZones, {id="prev_page", x1=navStartX, x2=navStartX + #prevStr - 1, y=navY})
end
if currentPage < totalPages then
table.insert(touchZones, {id="next_page", x1=nextXPos, x2=nextXPos + #nextStr - 1, y=navY})
end
end
end
function _diB8(w, touchZones)
local modY = 9
local mods = getRegisteredMods()
table.insert(mods, 2, "FLUID")
local arrowL = " < "
local arrowR = " > "
local areaX1 = 2 + #arrowL + 1
local areaX2 = w - 1 - #arrowR - 1
local areaW  = areaX2 - areaX1 + 1
local hasFluidCat = false
local modsNoAll = {}
for _, m in ipairs(mods) do
if m == "FLUID" then hasFluidCat = true
elseif m ~= "All" then table.insert(modsNoAll, m) end
end
local allDisp = " All "
local fluidDisp = " FLUID "
local function frontItemsR()
local f = {}
if hasFluidCat then f[#f+1] = {name="FLUID", disp=fluidDisp} end
f[#f+1] = {name="All", disp=allDisp}
return f
end
local function fitsInRowR(items, w_avail)
local total = -1
for _, it in ipairs(items) do total = total + #it.disp + 1 end
return total <= w_avail
end
local pages = {}
local rStart = 1
while rStart <= #modsNoAll do
local pageItems = {}
for i = rStart, #modsNoAll do
table.insert(pageItems, {name=modsNoAll[i], disp=" " .. modsNoAll[i] .. " "})
local mid = math.ceil(#pageItems / 2)
local row1 = frontItemsR()
local row2 = {}
for j = 1, mid do table.insert(row1, pageItems[j]) end
for j = mid+1, #pageItems do table.insert(row2, pageItems[j]) end
if not (fitsInRowR(row1, areaW) and fitsInRowR(row2, areaW)) then
table.remove(pageItems)
break
end
end
if #pageItems == 0 then break end
local mid = math.ceil(#pageItems / 2)
local page = {[1]=frontItemsR(), [2]={}}
for j = 1, mid do table.insert(page[1], pageItems[j]) end
for j = mid+1, #pageItems do table.insert(page[2], pageItems[j]) end
table.insert(pages, page)
rStart = rStart + #pageItems
end
if #pages == 0 then
table.insert(pages, {[1]=frontItemsR(), [2]={}})
end
local totalModPages = math.max(1, #pages)
if modFilterPage > totalModPages then modFilterPage = totalModPages end
if modFilterPage < 1 then modFilterPage = 1 end
local page = pages[modFilterPage] or {[1]=frontItemsR(), [2]={}}
local actModX, actModW, actModRow = nil, nil, nil
for ri = 1, 2 do
local ry = modY + (ri - 1)
local items = page[ri]
if #items > 0 then
local totalW = -1
for _, item in ipairs(items) do totalW = totalW + #item.disp + 1 end
local rx = math.max(areaX1, areaX1 + math.floor((areaW - totalW) / 2))
for _, item in ipairs(items) do
local isAct = (item.name == currentModFilter)
local fg = (item.name == "FLUID") and colors.cyan or (isAct and colors.white or colors.gray)
drawText(rx, ry, item.disp, fg, isAct and colors.gray or colors.black)
if isAct then actModX = rx; actModW = #item.disp; actModRow = ry end
table.insert(touchZones, {id="set_mod", arg=item.name, x1=rx, x2=rx+#item.disp-1, y=ry})
rx = rx + #item.disp + 1
end
end
end
if actModX and actModRow == modY + 1 then
drawText(actModX, actModRow + 1, string.rep("-", actModW), colors.lime, colors.black)
end
if totalModPages > 1 then
local arrY = modY
local lActive = (modFilterPage > 1)
local rActive = (modFilterPage < totalModPages)
drawText(2, arrY, arrowL, lActive and colors.white or colors.gray, lActive and colors.gray or colors.black)
if lActive then
table.insert(touchZones, {id="mod_prev", x1=2, x2=2+#arrowL-1, y=arrY})
table.insert(touchZones, {id="mod_prev", x1=2, x2=2+#arrowL-1, y=arrY+1})
end
local rX = w - #arrowR
drawText(rX, arrY, arrowR, rActive and colors.white or colors.gray, rActive and colors.gray or colors.black)
if rActive then
table.insert(touchZones, {id="mod_next", x1=rX, x2=rX+#arrowR-1, y=arrY})
table.insert(touchZones, {id="mod_next", x1=rX, x2=rX+#arrowR-1, y=arrY+1})
end
end
end
function _diB9(w, h, stockInv, touchZones, popupRect)
craftCompletePopup = nil
craftErrorLines = {}; craftErrorTitle = nil
craftInfoPopup = nil
recipeEditPopup = nil
local pW = 54
local pH = 10
local pX = math.max(1, math.floor((w - pW) / 2) + 1)
local pY = math.max(1, math.floor((h - pH) / 2) + 1)
popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
_bufFillRect(pX, pY, pW, pH, colors.gray)
local headerText
local headerColor
if queueEditIdx then
headerText = " EDIT QUEUE AMOUNT "
headerColor = colors.cyan
elseif fluidCraftMode then
headerText = " FLUID PRODUCTION ORDER "
headerColor = colors.cyan
elseif isRequestMode then
headerText = " REQUEST TO TRAIN BOX "
headerColor = colors.cyan
elseif isSettingKeepLimit then
headerText = " KEEP: THRESHOLD -> TARGET "
headerColor = colors.orange
else
headerText = " PRODUCTION INTERACTIVE ORDER "
headerColor = colors.lime
end
drawText(pX + math.floor((pW - #headerText) / 2), pY, headerText, colors.black, headerColor)
local nameLabel = "Item: "
if fluidCraftMode then nameLabel = fluidCraftMode.isItem and "Item: " or "Fluid: " end
if fluidKeepName then nameLabel = "Fluid: " end
local pickName = fluidKeepName and (fluidKeepName:match("([^:]+)$") or fluidKeepName)
or getItemDisplayName(itemToCraft)
drawText(pX + 2, pY + 2, nameLabel .. pickName, colors.white, colors.gray)
local exactStock = isRequestMode and requestMaxQty or (stockInv and (stockInv[itemToCraft] or 0) or 0)
local curStock      = exactStock
local stockColor    = colors.cyan
local unitSuf = ""
if fluidCraftMode then
unitSuf = fluidCraftMode.isItem and "x" or " mB"
if fluidCraftMode.isItem then
curStock = stockInv and (stockInv[itemToCraft] or 0) or 0
else
local fInv = (pickerHeaderSnap and pickerHeaderSnap.fluidInv) or getFluidInventory()
curStock = fInv[fluidKey(itemToCraft)] or 0
end
stockColor = colors.cyan
elseif fluidKeepName then
unitSuf = " mB"
local fInv = (pickerHeaderSnap and pickerHeaderSnap.fluidInv) or getFluidInventory()
curStock = fInv[itemToCraft] or 0
stockColor = colors.cyan
end
if isSettingKeepLimit then
drawText(pX + 2 + #(nameLabel .. pickName) + 2, pY + 2,
"Stock: " .. curStock .. unitSuf, stockColor, colors.gray)
local thrSel = (keepField == "threshold")
local tgtSel = (keepField ~= "threshold")
local thrStr = " THRESHOLD: " .. keepThr .. unitSuf .. " "
local tgtStr = " TARGET: " .. keepTgt .. unitSuf .. " "
drawText(pX + 2, pY + 3, thrStr, thrSel and colors.black or colors.white, thrSel and colors.lime or colors.gray)
table.insert(touchZones, 1, {id="keep_field", arg="threshold", x1=pX+2, x2=pX+2+#thrStr-1, y=pY+3})
local tgtX = pX + 2 + #thrStr + 2
drawText(tgtX, pY + 3, tgtStr, tgtSel and colors.black or colors.white, tgtSel and colors.lime or colors.gray)
table.insert(touchZones, 1, {id="keep_field", arg="target", x1=tgtX, x2=tgtX+#tgtStr-1, y=pY+3})
else
local amtPart = "Amount: " .. craftQuantity .. unitSuf
local stPart  = "  Stock: " .. curStock .. unitSuf
drawText(pX + 2,            pY + 3, amtPart, colors.lime, colors.gray)
drawText(pX + 2 + #amtPart, pY + 3, stPart,  stockColor, colors.gray)
if not isRequestMode then
local mxLabel = "  Max: "
local mxX = pX + 2 + #amtPart + #stPart
drawText(mxX, pY + 3, mxLabel, colors.lime, colors.gray)
local valX = mxX + #mxLabel
local mxVal, mxColor
if not pickerMaxComputed then
mxVal = "?"
mxColor = colors.yellow
else
if fluidCraftMode then
mxVal = pickerMaxCraftable >= FLUID_MAX_CAP and ">100000" or (tostring(pickerMaxCraftable) .. unitSuf)
else
mxVal = pickerMaxCraftable >= ITEM_MAX_CAP and ">9999" or tostring(pickerMaxCraftable)
end
mxColor = pickerMaxCraftable > 0 and colors.lime or colors.red
end
drawText(valX, pY + 3, mxVal, mxColor, colors.gray)
table.insert(touchZones, 1, {id="qty_calc_max", x1=valX, x2=valX + #mxVal - 1, y=pY+3})
local autoOn = (Config.autoMaxCalc ~= false)
local tgStr  = autoOn and " [AUT] " or " [MAN] "
local tgX    = pX + pW - #tgStr - 2
drawText(tgX, pY + 3, tgStr, colors.black, autoOn and colors.lime or colors.orange)
table.insert(touchZones, 1, {id="qty_toggle_automax", x1=tgX, x2=tgX + #tgStr - 1, y=pY+3})
end
end
local addRow = pY + 4
local subRow = pY + 5
local btnRow = pY + 8
local maxStr = " [MAX] "
local typStr = " [123] "
local rightBtnX = pX + pW - #maxStr - 2
local addVals = {1, 8, 16, 32, 64}
local subVals = {-1, -8, -16, -32, -64}
local qeEdit = queueEditIdx and craftQueue[queueEditIdx]
if (fluidCraftMode and not fluidCraftMode.isItem) or fluidKeepName
or (qeEdit and qeEdit.kind == "fluid" and not qeEdit.isItem) then
addVals = {100, 1000, 5000, 10000}
subVals = {-100, -1000, -5000, -10000}
end
local qX = pX + 2
for _, val in ipairs(addVals) do
local str = " [+" .. val .. "] "
drawText(qX, addRow, str, colors.white, colors.gray)
table.insert(touchZones, 1, {id="qty_adj", arg=val, x1=qX, x2=qX+#str-1, y=addRow})
qX = qX + #str + 1
end
if not isSettingKeepLimit then
drawText(rightBtnX, addRow, maxStr, colors.black, colors.lime)
table.insert(touchZones, 1, {id="qty_max", x1=rightBtnX, x2=rightBtnX+#maxStr-1, y=addRow})
end
qX = pX + 2
for _, val in ipairs(subVals) do
local str = " [" .. val .. "] "
drawText(qX, subRow, str, colors.white, colors.gray)
table.insert(touchZones, 1, {id="qty_adj", arg=val, x1=qX, x2=qX+#str-1, y=subRow})
qX = qX + #str + 1
end
drawText(rightBtnX, subRow, typStr, colors.black, colors.cyan)
table.insert(touchZones, 1, {id="qty_type", x1=rightBtnX, x2=rightBtnX+#typStr-1, y=subRow})
if qtyTypeActive then
local opW = 30; local opH = 5
local opX = pX + math.floor((pW - opW) / 2)
local opY = pY + math.floor((pH - opH) / 2)
_bufFillRect(opX, opY, opW, opH, colors.gray)
local ohdr = " ENTER QUANTITY "
drawText(opX + math.floor((opW - #ohdr) / 2), opY, ohdr, colors.black, colors.cyan)
local oHint = "Type number in terminal"
drawText(opX + math.floor((opW - #oHint) / 2), opY + 2, oHint, colors.lightGray, colors.gray)
local oCur = "Current: " .. tostring(craftQuantity)
drawText(opX + math.floor((opW - #oCur) / 2), opY + 3, oCur, colors.lime, colors.gray)
end
local cfmStr = " [ CONFIRM ] "
local cnlStr = " [ CANCEL ] "
drawText(pX + 2,                btnRow, cfmStr, colors.black, colors.lime)
drawText(pX + pW - #cnlStr - 2, btnRow, cnlStr, colors.white, colors.gray)
table.insert(touchZones, 1, {id="qty_confirm", x1=pX+2,                x2=pX+2+#cfmStr-1,            y=btnRow})
table.insert(touchZones, 1, {id="qty_cancel",  x1=pX+pW-#cnlStr-2,    x2=pX+pW-2,                   y=btnRow})
if not isRequestMode and not isSettingKeepLimit and not fluidKeepName and not queueEditIdx then
local aqStr = " [+QUEUE] "
local aqX = pX + 2 + #cfmStr + 1
drawText(aqX, btnRow, aqStr, colors.black, colors.cyan)
table.insert(touchZones, 1, {id="qty_add_queue", x1=aqX, x2=aqX+#aqStr-1, y=btnRow})
end
return popupRect
end
function _diB10(w, h, stockInv, touchZones, popupRect)
local hasBox   = Config.train_box and Config.train_box ~= ""
local pW       = math.min(w - 4, 82)
local hPerPage = math.max(4, h - 18)
local totEnt   = #craftHistory
local totPg    = math.max(1, math.ceil(totEnt / hPerPage))
if (historyPopup.page or 1) > totPg then historyPopup.page = 1 end
local hPage    = historyPopup.page or 1
local pH       = hPerPage + 5
local pX       = math.max(1, math.floor((w - pW) / 2) + 1)
local pY       = math.max(9, math.floor((h - pH) / 2))
popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdrStr = " CRAFT HISTORY "
drawText(pX + math.floor((pW - #hdrStr) / 2), pY, hdrStr, colors.black, colors.orange)
do
local scanStr = " [SCAN] "
local scanHX  = pX + pW - #scanStr - 1
drawText(scanHX, pY, scanStr, colors.black, colors.lime)
table.insert(touchZones, 1, {id="history_scan", x1=scanHX, x2=scanHX+#scanStr-1, y=pY})
end
local reqStr   = "[REQ]"
local craftStr = "[CRAFT]"
local reqX     = pX + pW - #reqStr - 2
local stkEnd   = reqX - 2
local stkW     = 3
local craftEnd = stkEnd - stkW - 1
local craftX   = craftEnd - #craftStr + 1
local maxEnd   = craftX - 2
local maxW     = 3
local maxCache = historyPopup.maxCache or {}
local histFluidInv = getFluidInventoryCached()
local listY  = pY + 2
local startIdx = (hPage - 1) * hPerPage + 1
local endIdx   = math.min(startIdx + hPerPage - 1, totEnt)
for i = startIdx, endIdx do
local entry  = craftHistory[i]
local sName  = entry.item:match(":(.+)$") or entry.item
local stock  = entry.fluid and (histFluidInv[fluidKey(entry.item)] or 0) or (stockInv and (stockInv[entry.item] or 0) or 0)
local maxC   = maxCache[(entry.fluid and "f:" or "") .. entry.item]
local rowBg  = (i % 2 == 0) and colors.gray or colors.black
local maxDisp
if maxC == nil then
maxDisp = "?"
elseif maxC >= 100 then
maxDisp = ">99"
else
maxDisp = tostring(maxC)
end
local maxX = maxEnd - #maxDisp + 1
local stkStr = tostring(stock)
if #stkStr > stkW then stkStr = "+++" end
local stkX = stkEnd - #stkStr + 1
local qtyStr = "x" .. tostring(entry.qty)
local qtyX   = maxEnd - maxW - #qtyStr
local nameW  = math.max(0, qtyX - pX - 2)
_bufFillRect(pX + 1, listY, pW - 2, 1, rowBg)
drawText(pX + 2, listY, sName:sub(1, nameW), colors.white, rowBg)
local qtyColor = (rowBg == colors.lightGray) and colors.black or colors.lightGray
drawText(qtyX, listY, qtyStr, qtyColor, rowBg)
drawText(maxX, listY, maxDisp, colors.lime, rowBg)
drawText(craftX, listY, craftStr, colors.black, colors.white)
table.insert(touchZones, 1, {id=entry.fluid and "history_craft_fluid" or "history_craft", arg=entry.item, x1=craftX, x2=craftX+#craftStr-1, y=listY})
drawText(stkX, listY, stkStr, colors.cyan, rowBg)
if not entry.fluid then
local rColor = hasBox and colors.cyan or colors.gray
drawText(reqX, listY, reqStr, colors.black, rColor)
if hasBox then
table.insert(touchZones, 1, {id="history_req", arg=entry.item, x1=reqX, x2=reqX+#reqStr-1, y=listY})
end
end
listY = listY + 1
end
if totEnt == 0 then
local msg = "No crafts yet."
drawText(pX + math.floor((pW - #msg) / 2), listY + 1, msg, colors.lightGray, colors.gray)
end
local navY = pY + pH - 1
drawText(pX + 1, navY - 1, string.rep("-", pW - 2), colors.lightGray, colors.gray)
if totPg > 1 then
local prevS = "[ PREV ]"; local nextS = "[ NEXT ]"
local pgS   = " PAGE " .. hPage .. " OF " .. totPg .. " "
local navW2 = #prevS + #pgS + #nextS + 2
local navX  = pX + math.floor((pW - navW2) / 2)
drawText(navX, navY, prevS, colors.white, colors.gray)
table.insert(touchZones, 1, {id="history_prev", x1=navX, x2=navX+#prevS-1, y=navY})
drawText(navX + #prevS + 1, navY, pgS, colors.lime, colors.gray)
local nxtX = navX + #prevS + #pgS + 2
drawText(nxtX, navY, nextS, colors.white, colors.gray)
table.insert(touchZones, 1, {id="history_next", x1=nxtX, x2=nxtX+#nextS-1, y=navY})
else
local clsNav = " [ CLOSE ] "
local cnX = pX + math.floor((pW - #clsNav) / 2)
drawText(cnX, navY, clsNav, colors.white, colors.gray)
table.insert(touchZones, 1, {id="close_history", x1=cnX, x2=cnX+#clsNav-1, y=navY})
end
return popupRect
end
function drawMgmtGroupRow(grp, gi, rowY, w, touchZones, mStart, mgmtActiveBtn)
local gName  = (grp.name ~= "" and grp.name or "(unnamed)"):upper()
local gInput  = mgmtIODisplay(grp, true)
local gOutput = mgmtIODisplay(grp, false)
local isPaused = grp.paused or false
local rowBg = ((gi - mStart) % 2 == 0) and colors.black or colors.gray
_bufClearLine(rowY, rowBg)
local delS   = " [DEL] "; local editS = " [EDIT] "; local viewS = " [VIEW] "
local pauseS = isPaused and " [RUN] " or " [PAUSE] "
local delX   = w - #delS + 1
local editX  = delX - #editS - 1
local viewX  = editX - #viewS - 1
local pauseX = viewX - #pauseS - 1
drawText(pauseX, rowY, pauseS, isPaused and colors.black or colors.white, isPaused and colors.orange or (rowBg == colors.gray and colors.lightGray or colors.gray))
drawText(viewX,  rowY, viewS,  colors.white, colors.gray)
drawText(editX,  rowY, editS,  colors.white, colors.gray)
drawText(delX,   rowY, delS,   colors.white, colors.gray)
table.insert(touchZones, {id="mgmt_pause", arg=gi, x1=pauseX, x2=pauseX+#pauseS-1, y=rowY})
table.insert(touchZones, {id="mgmt_del",  arg=gi, x1=delX,  x2=w,              y=rowY})
table.insert(touchZones, {id="mgmt_edit", arg=gi, x1=editX, x2=editX+#editS-1, y=rowY})
table.insert(touchZones, {id="mgmt_view", arg=gi, x1=viewX, x2=viewX+#viewS-1, y=rowY})
local isFluidGrp = mgmtGroupIsFluid(grp)
local nameStr = gName .. "  " .. gInput .. " -> " .. gOutput
local nameMax = pauseX - 3
if #nameStr > nameMax then nameStr = nameStr:sub(1, nameMax) end
drawText(2, rowY, gName, isPaused and colors.gray or colors.white, rowBg)
if isFluidGrp then
drawText(2 + #gName, rowY, " ~", colors.cyan, rowBg)
end
local ioX = 2 + #gName + 2
if ioX < pauseX - 2 then
local ioStr = gInput .. " -> " .. gOutput
drawText(ioX, rowY, ioStr:sub(1, pauseX - ioX - 1), colors.gray, rowBg)
end
if mgmtActiveBtn and mgmtActiveBtn.gi == gi and (os.clock() - mgmtActiveBtn.t) < 2 then
local abx, abw
if     mgmtActiveBtn.btn == "view"  then abx = viewX;  abw = #viewS
elseif mgmtActiveBtn.btn == "edit"  then abx = editX;  abw = #editS
elseif mgmtActiveBtn.btn == "del"   then abx = delX;   abw = #delS
elseif mgmtActiveBtn.btn == "pause" then abx = pauseX; abw = #pauseS
end
if abx then drawText(abx, rowY+1, string.rep("-", abw), colors.lime, rowBg) end
end
_bufClearLine(rowY+1, rowBg)
local ruleDrawX = 4
if grp.provider then
drawText(ruleDrawX, rowY+1, "PROVIDER (pull-only source)", colors.orange, rowBg)
else
if grp.drain then
drawText(ruleDrawX, rowY+1, "EMPTY ALL", colors.lime, rowBg)
ruleDrawX = ruleDrawX + 10
end
local rulesStr = grp.drain and "" or "Rules: "
if #grp.rules == 0 then
if not grp.drain then rulesStr = rulesStr .. "(none)" end
else
if grp.drain then rulesStr = " " end
for ri, rule in ipairs(grp.rules) do
local rn = getItemDisplayName(rule.item)
local piece = isFluidGrp and (rn .. " " .. rule.amount .. "mB") or (rn .. " x" .. rule.amount)
if ri < #grp.rules then piece = piece .. "  " end
if #rulesStr + #piece > w - ruleDrawX - 2 then rulesStr = rulesStr:sub(1, w-ruleDrawX-5) .. "..."; break end
rulesStr = rulesStr .. piece
end
end
if rulesStr ~= "" and rulesStr ~= " " then
drawText(ruleDrawX, rowY+1, rulesStr:sub(1, w - ruleDrawX), colors.cyan, rowBg)
end
end
end
function _diB11(w, h, touchZones)
local newStr   = " [+NEW GROUP] "
local syncBtnS = " [SYNC] "
local totalBW  = #newStr + 2 + #syncBtnS
local btnSX    = math.floor((w - totalBW) / 2) + 1
drawText(btnSX, 9, newStr, colors.black, colors.lime)
table.insert(touchZones, {id="mgmt_new", x1=btnSX, x2=btnSX+#newStr-1, y=9})
local syncBtnX = btnSX + #newStr + 2
local syncMoved = mgmtSyncInfo:find("^moved") ~= nil
local syncBg   = syncMoved and colors.lime  or colors.gray
local syncFg   = syncMoved and colors.black or colors.white
drawText(syncBtnX, 9, syncBtnS, syncFg, syncBg)
table.insert(touchZones, {id="mgmt_sync_now", x1=syncBtnX, x2=syncBtnX+#syncBtnS-1, y=9})
local syncFlashing = mgmtSyncFlashTime and (os.clock() - mgmtSyncFlashTime) < 3
if syncFlashing then
drawText(syncBtnX, 10, string.rep("-", #syncBtnS), colors.lime, colors.black)
else
drawText(1, 10, string.rep("-", w), colors.gray, colors.black)
end
if #MgmtGroups == 0 then
local emptyStr = "No groups. Tap [+NEW GROUP] to create one."
drawText(math.max(1, math.floor((w - #emptyStr) / 2)), 14, emptyStr, colors.gray, colors.black)
else
local rowsPerPage = math.max(1, math.floor((h - 14) / 2))
local totalMPages  = math.max(1, math.ceil(#MgmtGroups / rowsPerPage))
if mgmtPage > totalMPages then mgmtPage = totalMPages end
local mStart = (mgmtPage - 1) * rowsPerPage + 1
local mEnd   = math.min(mStart + rowsPerPage - 1, #MgmtGroups)
local rowY = 11
for gi = mStart, mEnd do
local grp = MgmtGroups[gi]
drawMgmtGroupRow(grp, gi, rowY, w, touchZones, mStart, mgmtActiveBtn)
rowY = rowY + 2
end
do
local navY = h - 1
drawText(1, navY - 1, string.rep("-", w), colors.gray)
local pageStr = string.format(" PAGE %d OF %d ", mgmtPage, math.max(1, totalMPages))
local prevStr = " [ PREV ] "; local nextStr = " [ NEXT ] "
local navStartX = math.floor((w - (#prevStr + #pageStr + #nextStr + 4)) / 2)
drawText(navStartX, navY, prevStr, mgmtPage > 1 and colors.white or colors.lightGray, colors.gray)
drawText(navStartX + #prevStr + 2, navY, pageStr, colors.lime, colors.black)
local nextXPos = navStartX + #prevStr + #pageStr + 4
drawText(nextXPos, navY, nextStr, mgmtPage < totalMPages and colors.white or colors.lightGray, colors.gray)
if mgmtPage > 1 then
table.insert(touchZones, {id="mgmt_list_prev", x1=navStartX, x2=navStartX + #prevStr - 1, y=navY})
end
if mgmtPage < totalMPages then
table.insert(touchZones, {id="mgmt_list_next", x1=nextXPos, x2=nextXPos + #nextStr - 1, y=navY})
end
end
end
end
function _diB12(w, h, touchZones)
local isFluidAlt = (altViewFluid ~= nil)
local fkAlt = isFluidAlt and fluidKey(altViewFluid) or nil
local titleName = isFluidAlt and (altViewFluid:match(":(.+)$") or altViewFluid)
or (altViewItem and (altViewItem:match(":(.+)$") or altViewItem) or "?")
drawText(2, 9, "RECIPE PRIORITY: " .. titleName, colors.lime)
drawText(2, 10, "Top = tried first. Recursion falls back down the list.", colors.gray)
drawText(1, 11, string.rep("-", w), colors.gray)
local primary, alts
if isFluidAlt then
primary = FluidRecipes[fkAlt]
alts    = FluidAltRecipes[fkAlt] or {}
else
primary = altViewItem and Recipes[altViewItem]
alts    = (altViewItem and AltRecipes[altViewItem]) or {}
end
if not isFluidAlt and type(primary) == "table" and primary.type == "fluid" then
primary = nil
end
local entries = {}
if primary then
table.insert(entries, {isPrimary=true, recipe=primary})
end
for i, alt in ipairs(alts) do
table.insert(entries, {isPrimary=false, altIdx=i, recipe=alt})
end
local nSolid = #entries
if not isFluidAlt and altViewItem then
local function addFl(rec)
if type(rec) ~= "table" then return end
for _, o in ipairs(rec.item_outputs or {}) do
if o.name == altViewItem then
table.insert(entries, {isFluid=true, recipe=rec})
return
end
end
end
for _, rec in pairs(FluidRecipes) do addFl(rec) end
for _, fAlts in pairs(FluidAltRecipes) do
for _, rec in ipairs(fAlts) do addFl(rec) end
end
end
local listY = 12
local perPage = h - listY - 4
if #entries == 0 then
drawText(2, listY, "No recipes. Add one via +RECIPES tab.", colors.gray)
else
for eIdx = 1, math.min(#entries, perPage) do
local entry = entries[eIdx]
local rowBg = (eIdx % 2 == 0) and colors.gray or colors.black
_bufClearLine(listY, rowBg)
local rec   = entry.recipe
local mName = tostring(rec.machine_name or rec.method or "?")
mName = mName:match(":(.+)$") or mName
local rankLabel
if entry.isFluid then
rankLabel = "[FLUID]  "
elseif entry.isPrimary then
rankLabel = "[PRIMARY]"
else
rankLabel = "[#" .. eIdx .. "]      "
rankLabel = rankLabel:sub(1, 9)
end
local nameColor = entry.isFluid and colors.cyan or (entry.isPrimary and colors.yellow or colors.white)
local label, ingStr
if isFluidAlt or entry.isFluid then
local inParts = {}
for _, inp in ipairs(rec.inputs or {}) do
inParts[#inParts + 1] = (inp.name:match(":(.+)$") or inp.name) .. " " .. inp.amount
end
for _, it in ipairs(rec.item_inputs or {}) do
inParts[#inParts + 1] = it.count .. "x " .. (it.name:match(":(.+)$") or it.name)
end
local outParts = {}
for _, o in ipairs(rec.outputs or {}) do
outParts[#outParts + 1] = (o.name:match(":(.+)$") or o.name) .. " " .. o.amount
end
for _, o in ipairs(rec.item_outputs or {}) do
outParts[#outParts + 1] = o.count .. "x " .. (o.name:match(":(.+)$") or o.name)
end
label = rankLabel .. " " .. mName
ingStr = table.concat(inParts, " + ") .. " -> " .. table.concat(outParts, " + ")
else
local ingCount = 0
for _, ing in ipairs(rec.ingredients or {}) do
if ing and ing ~= "nil" then ingCount = ingCount + 1 end
end
label = rankLabel .. " " .. mName .. " x" .. (rec.output_count or 1) .. " (" .. ingCount .. " ing)"
local ingSlotCounts = {}
for _, ing in ipairs(rec.ingredients or {}) do
if ing and ing ~= "nil" then
ingSlotCounts[ing] = (ingSlotCounts[ing] or 0) + 1
end
end
local ingParts = {}
for ingName, cnt in pairs(ingSlotCounts) do
local short = ingName:match(":(.+)$") or ingName
table.insert(ingParts, short .. (cnt > 1 and " x"..cnt or ""))
end
table.sort(ingParts)
ingStr = table.concat(ingParts, "  ")
end
drawText(2, listY, label:sub(1, w - 25), nameColor, rowBg)
local labelLen  = math.min(#label, w - 25)
local ingStartX = 2 + labelLen + 2
local ingEndX   = w - 24
if ingEndX - ingStartX > 4 and #ingStr > 0 then
drawText(ingStartX, listY, ingStr:sub(1, ingEndX - ingStartX), colors.lightGray, rowBg)
end
local bx = w - 22
if not entry.isFluid then
if eIdx > 1 then
drawText(bx, listY, "[^]", colors.white, colors.gray)
table.insert(touchZones, {id="combined_up", arg=eIdx, x1=bx, x2=bx+2, y=listY})
end
if eIdx < nSolid then
drawText(bx+4, listY, "[v]", colors.white, colors.gray)
table.insert(touchZones, {id="combined_dn", arg=eIdx, x1=bx+4, x2=bx+6, y=listY})
end
if eIdx > 1 then
drawText(bx+8, listY, "[TOP]", colors.black, colors.lime)
table.insert(touchZones, {id="combined_top", arg=eIdx, x1=bx+8, x2=bx+12, y=listY})
end
if not entry.isPrimary then
drawText(bx+14, listY, "[X]", colors.white, colors.red)
table.insert(touchZones, {id="combined_del", arg=eIdx, x1=bx+14, x2=bx+16, y=listY})
end
if not isFluidAlt then
drawText(bx+18, listY, "[E]", colors.white, colors.gray)
local altIdxForEdit = entry.isPrimary and nil or entry.altIdx
table.insert(touchZones, {id="open_recipe_edit", arg=altViewItem, altIdx=altIdxForEdit, fromAltView=true, x1=bx+18, x2=bx+20, y=listY})
end
end
listY = listY + 1
end
end
local btnY = h - 2
if isFluidAlt then
drawText(2, btnY, "[ BACK ]", colors.white, colors.gray)
table.insert(touchZones, {id="alt_back", x1=2, x2=9, y=btnY})
drawText(2, h-1, "PRIMARY yellow. Add alts via +RECIPES learning.", colors.gray)
else
drawText(2, btnY, "[ + ADD ALT ]", colors.black, colors.lime)
table.insert(touchZones, {id="alt_add", x1=2, x2=14, y=btnY})
drawText(17, btnY, "[ BACK ]", colors.white, colors.gray)
table.insert(touchZones, {id="alt_back", x1=17, x2=24, y=btnY})
drawText(2, h-1, "PRIMARY shown in yellow. [X] only for alt recipes.", colors.gray)
end
end
function _diB13(w, h, touchZones)
    local isPairing = (os.clock() < pairingActiveUntil)
    local rBtnText = isPairing and " REMOTE * " or " REMOTE "
    local rBtnBg   = isPairing and colors.cyan or colors.gray
    local rBtnFg   = isPairing and colors.black or colors.white
    local rBtnX    = math.max(42, w - #rBtnText - 1)
    drawText(rBtnX, 10, rBtnText, rBtnFg, rBtnBg)
    table.insert(touchZones, {id="open_remote_popup", x1=rBtnX, x2=rBtnX+#rBtnText-1, y=10})

    local hasFilters = false
    if Config.hidden_network_types then
        for _, h in pairs(Config.hidden_network_types) do
            if h then hasFilters = true; break end
        end
    end
    local fBtnText = hasFilters and " [ FILTER * ] " or " [ FILTER ] "
    local fBtnBg   = hasFilters and colors.cyan or colors.gray
    local fBtnFg   = hasFilters and colors.black or colors.white
    local fBtnX    = rBtnX - #fBtnText - 1
    drawText(fBtnX, 10, fBtnText, fBtnFg, fBtnBg)
    table.insert(touchZones, {id="open_network_filter", x1=fBtnX, x2=fBtnX+#fBtnText-1, y=10})

    local titleStr = (fBtnX >= 42) and "PERIPHERAL BUS MATRIX (SYSTEM SETUP):" or "PERIPHERAL MATRIX:"
    drawText(2, 10, titleStr, colors.white)

    local peripherals = peripheral.getNames()
    local startRowY = 12
    local itemsPerPage = h - startRowY - 2
    local validPeriphs = {}
    local hiddenMap = Config.hidden_network_types or {}
    local keepActive = (Config.filter_keep_active ~= false)

    local function isPeriphAssigned(p)
        if Config.buffer == p then return true end
        if Config.train_box == p then return true end
        if Config.project_chest == p then return true end
        if Config.main_vaults and Config.main_vaults[p] then return true end
        if Config.storages and Config.storages[p] then return true end
        if Config.turtles and Config.turtles[p] then return true end
        if Config.fluid_tanks and Config.fluid_tanks[p] then return true end
        if MachineLabels and MachineLabels[p] and MachineLabels[p] ~= "" then return true end
        return false
    end

    for _, p in ipairs(peripherals) do
        if not SYSTEM_SIDES[p] and p ~= MONITOR_SIDE then
            local cat = getCategoryFromPeriph(p)
            local isHidden = (hiddenMap[cat] == true)
            if isHidden and keepActive and isPeriphAssigned(p) then
                isHidden = false
            end
            if not isHidden then
                table.insert(validPeriphs, p)
            end
        end
    end
    table.sort(validPeriphs, naturalSortDisplay)
    local totalPages = math.max(1, math.ceil(#validPeriphs / itemsPerPage))
    if currentPage > totalPages then currentPage = totalPages end
    if currentPage < 1 then currentPage = 1 end
    local startIdx = ((currentPage - 1) * itemsPerPage) + 1
    local endIdx = math.min(startIdx + itemsPerPage - 1, #validPeriphs)
    local rowY = startRowY

    if #validPeriphs == 0 then
        local emptyMsg = hasFilters and "All devices hidden by filter. Tap [ FILTER ] to change." or "No peripherals detected on network."
        drawText(math.max(2, math.floor((w - #emptyMsg) / 2) + 1), startRowY + 2, emptyMsg, colors.yellow, colors.black)
    end

    for idx = startIdx, endIdx do
        local p = validPeriphs[idx]
        local pDisplay = getMachineDisplay(p)
        local rowBg = (idx % 2 == 0) and colors.gray or colors.black
        _bufClearLine(rowY, rowBg)
        drawText(2, rowY, pDisplay, colors.white, rowBg)

        -- Role button panel (width ~65 characters)
        local btnX = w - 65
        if btnX < #pDisplay + 3 then btnX = #pDisplay + 3 end
        local inactiveFg = colors.lightGray

        -- 1. [BUF] (Dump buffer)
        local isBuf = (Config.buffer == p)
        drawText(btnX, rowY, " [BUF] ", isBuf and colors.black or inactiveFg, isBuf and colors.magenta or rowBg)
        table.insert(touchZones, {id="toggle_buffer", arg=p, x1=btnX, x2=btnX+6, y=rowY})

        -- 2. [MAIN] (Main vault array 2..9)
        local isMain = Config.main_vaults and Config.main_vaults[p]
        drawText(btnX + 7, rowY, " [MAIN] ", isMain and colors.black or inactiveFg, isMain and colors.lightBlue or rowBg)
        table.insert(touchZones, {id="toggle_main_vault", arg=p, x1=btnX+7, x2=btnX+14, y=rowY})

        -- 3. [VAULT] (Auxiliary storage)
        local isStorage = Config.storages and Config.storages[p]
        drawText(btnX + 15, rowY, " [VAULT] ", isStorage and colors.black or inactiveFg, isStorage and colors.lime or rowBg)
        table.insert(touchZones, {id="toggle_storage", arg=p, x1=btnX+15, x2=btnX+23, y=rowY})

        -- 4. [T.BOX] (Train Box)
        local isTBox = (Config.train_box == p)
        drawText(btnX + 24, rowY, " [T.BOX] ", isTBox and colors.black or inactiveFg, isTBox and colors.orange or rowBg)
        table.insert(touchZones, {id="set_train_box", arg=p, x1=btnX+24, x2=btnX+32, y=rowY})

        -- 5. [TURTLE]
        local isTurtle = Config.turtles and Config.turtles[p]
        drawText(btnX + 33, rowY, " [TURTLE] ", isTurtle and colors.black or inactiveFg, isTurtle and colors.cyan or rowBg)
        table.insert(touchZones, {id="set_turtle", arg=p, x1=btnX+33, x2=btnX+42, y=rowY})

        -- 6. [SUF] (Suffix / Name)
        local hasLabel = MachineLabels[p] and MachineLabels[p] ~= ""
        drawText(btnX + 43, rowY, " [SUF] ", hasLabel and colors.black or inactiveFg, hasLabel and colors.lime or rowBg)
        table.insert(touchZones, {id="machine_label", arg=p, x1=btnX+43, x2=btnX+49, y=rowY})

        -- 7. [TNK] (Fluid tank)
        local isFluidTank = Config.fluid_tanks and Config.fluid_tanks[p]
        local tankObj = peripheral.wrap(p)
        if tankObj and tankObj.tanks ~= nil then
            drawText(btnX + 50, rowY, " [TNK] ", isFluidTank and colors.black or inactiveFg, isFluidTank and colors.lime or rowBg)
            table.insert(touchZones, {id="toggle_fluid_tank", arg=p, x1=btnX+50, x2=btnX+56, y=rowY})
        end

        -- 8. [PROJ] (Dedicated Create Clipboard chest)
        local isProjectChest = (Config.project_chest == p)
        if tankObj and tankObj.list and tankObj.getItemDetail then
            drawText(btnX + 57, rowY, " [PROJ] ", isProjectChest and colors.black or inactiveFg, isProjectChest and colors.yellow or rowBg)
            table.insert(touchZones, {id="set_project_chest", arg=p, x1=btnX+57, x2=btnX+64, y=rowY})
        end

        rowY = rowY + 1
    end

    -- Page navigation
    local navY = h - 1
    drawText(1, navY - 1, string.rep("-", w), colors.gray)
    local pageStr = string.format(" PAGE %d OF %d ", currentPage, math.max(1, totalPages))
    local prevStr = " [ PREV ] "
    local nextStr = " [ NEXT ] "
    local navStartX = math.floor((w - (#prevStr + #pageStr + #nextStr + 4)) / 2)
    drawText(navStartX, navY, prevStr, currentPage > 1 and colors.white or colors.lightGray, colors.gray)
    drawText(navStartX + #prevStr + 2, navY, pageStr, colors.lime, colors.black)
    local nextXPos = navStartX + #prevStr + #pageStr + 4
    drawText(nextXPos, navY, nextStr, currentPage < totalPages and colors.white or colors.lightGray, colors.gray)
    if currentPage > 1 then
        table.insert(touchZones, {id="prev_page", x1=navStartX, x2=navStartX + #prevStr - 1, y=navY})
    end
    if currentPage < totalPages then
        table.insert(touchZones, {id="next_page", x1=nextXPos, x2=nextXPos + #nextStr - 1, y=navY})
    end
end
function _diB14(w, touchZones)
local searchY = 12
local displaySearch = (searchFilter == "") and "<type item name...>" or searchFilter
local searchColor   = (searchFilter == "") and (searchInputActive and colors.lightGray or colors.gray) or colors.white
local fullSearch    = "FIND: [ " .. displaySearch .. " ]"
local searchX       = math.max(14, math.floor((w - #fullSearch) / 2) + 1)
drawText(searchX, searchY, "FIND: ", colors.gray, colors.black)
local srchBoxBg = searchInputActive and colors.gray or colors.black
drawText(searchX + 6, searchY, "[ " .. displaySearch .. " ]", searchColor, srchBoxBg)
table.insert(touchZones, {id="trigger_search", x1=searchX, x2=searchX+#fullSearch-1, y=searchY})
if searchFilter ~= "" then
local boxStr = "[ " .. displaySearch .. " ]"
drawText(searchX + 6, searchY + 1, string.rep("-", #boxStr), colors.lime, colors.black)
drawText(searchX + #fullSearch + 1, searchY, "[X]", colors.white, colors.red)
table.insert(touchZones, {id="clear_search", x1=searchX+#fullSearch+1, x2=searchX+#fullSearch+3, y=searchY})
end
local dtPad = math.max(0, math.floor((w - (w - 15) + 1 - #"DEVICE TYPE") / 2))
local histEnd
if Config.train_box and Config.train_box ~= "" then
local ulStr = " UNLOAD "
local ulX   = 1 + dtPad
drawText(ulX, searchY, ulStr, colors.white, colors.gray)
if unloadActive then
drawText(ulX, searchY + 1, string.rep("-", #ulStr), colors.lime, colors.black)
end
table.insert(touchZones, {id="pull_from_box", x1=ulX, x2=ulX+#ulStr-1, y=searchY})
local histStr = " HISTORY "
local histX = ulX + #ulStr + 1
drawText(histX, searchY, histStr, colors.white, colors.gray)
if historyPopup then
drawText(histX, searchY + 1, string.rep("-", #histStr), colors.lime, colors.black)
end
table.insert(touchZones, {id="open_history", x1=histX, x2=histX+#histStr-1, y=searchY})
histEnd = histX + #histStr
else
local histStr = " HISTORY "
local histX = 1 + dtPad
drawText(histX, searchY, histStr, colors.white, colors.gray)
if historyPopup then
drawText(histX, searchY + 1, string.rep("-", #histStr), colors.lime, colors.black)
end
table.insert(touchZones, {id="open_history", x1=histX, x2=histX+#histStr-1, y=searchY})
histEnd = histX + #histStr
end
local qBtn = " QUEUE "
local qCnt = (#craftQueue > 0) and tostring(#craftQueue) or ""
local qX = histEnd + 1
drawText(qX, searchY, qBtn, colors.white, colors.gray)
if qCnt ~= "" then
drawText(qX + #qBtn, searchY, " " .. qCnt .. " ", colors.lime, colors.gray)
end
local qFullW = #qBtn + (qCnt ~= "" and (#qCnt + 2) or 0)
if craftQueuePopup then
drawText(qX, searchY + 1, string.rep("-", qFullW), colors.lime, colors.black)
end
table.insert(touchZones, {id="open_queue", x1=qX, x2=qX+qFullW-1, y=searchY})
local scanStr = " SCAN "
local allStr  = " ALL "
local dtColStart  = w - 15
local totalBtnW   = #scanStr + 1 + #allStr
local dtColW      = w - dtColStart + 1
local scanX = dtColStart + math.floor((dtColW - totalBtnW) / 2)
local allX  = scanX + #scanStr + 1
drawText(scanX, searchY, scanStr, colors.white, colors.gray)
if scanActive then
drawText(scanX, searchY + 1, string.rep("-", #scanStr), colors.lime, colors.black)
end
table.insert(touchZones, {id="scan_recipes", x1=scanX, x2=scanX+#scanStr-1, y=searchY})
drawText(allX, searchY, allStr, colors.white, colors.gray)
if allScanActive then
drawText(allX, searchY + 1, string.rep("-", #allStr), colors.lime, colors.black)
end
table.insert(touchZones, {id="scan_all_recipes", x1=allX, x2=w, y=searchY})
local headY = 14
local hdrBtnX = w - 60
local dtText = "DEVICE TYPE"
local dtStart = hdrBtnX + 45
local dtPad = math.max(0, math.floor((w - dtStart + 1 - #dtText) / 2))
local dtX = dtStart + dtPad
drawText(dtX, headY, dtText, colors.gray)
local inText = "ITEM NAME"
drawText(1 + dtPad, headY, inText, colors.gray)
drawText(1, headY + 1, string.rep("-", w), colors.gray)
end
function _diQueuePopup(w, h, touchZones, popupRect)
local total = #craftQueue
local maxRows = math.max(4, h - 18)
if craftQueueScroll > math.max(0, total - maxRows) then craftQueueScroll = math.max(0, total - maxRows) end
if craftQueueScroll < 0 then craftQueueScroll = 0 end
local shown = math.min(total, maxRows)
local errActive = craftQueueErrIdx and craftQueue[craftQueueErrIdx] and craftQueue[craftQueueErrIdx].failed
local pW = math.min(w - 4, 72)
local pH = math.max(shown, 1) + (errActive and 8 or 4)
local pX = math.max(1, math.floor((w - pW) / 2) + 1)
local pY = math.max(9, math.floor((h - pH) / 2) + 1)
popupRect = {x1 = pX, x2 = pX + pW - 1, y1 = pY, y2 = pY + pH - 1}
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdr = " CRAFT QUEUE (" .. total .. ") "
drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.lime)
local xDel = pX + pW - 7
local xEd  = xDel - 7
local xDn  = xEd - 4
local xUp  = xDn - 4
local xTop = xUp - 6
local xCr  = xTop - 8
if total == 0 then
drawText(pX + 2, pY + 2, "Queue empty. Use [+QUEUE] in order popup.", colors.lightGray, colors.gray)
end
for ri = 1, shown do
local qi = craftQueueScroll + ri
local qe = craftQueue[qi]
local rowY = pY + 1 + ri
local nm = qe.name:match(":(.+)$") or qe.name
local unit = (qe.kind == "fluid" and not qe.isItem) and " mB" or "x"
local label = string.format("%d. %s  %d%s", qi, nm, qe.qty, unit)
local nameW = xCr - (pX + 2) - (qe.failed and 5 or 2)
drawText(pX + 2, rowY, label:sub(1, nameW), qe.failed and colors.orange or colors.white, colors.gray)
if qe.failed then
local exX = xCr - 4
drawText(exX, rowY, "[!]", colors.white, colors.red)
table.insert(touchZones, 1, {id = "queue_err", arg = qi, x1 = exX, x2 = exX + 2, y = rowY})
end
drawText(xCr, rowY, "[CRAFT]", colors.black, colors.white)
table.insert(touchZones, 1, {id = "queue_craft", arg = qi, x1 = xCr, x2 = xCr + 6, y = rowY})
drawText(xTop, rowY, "[TOP]", (qi > 1) and colors.white or colors.lightGray, colors.gray)
if qi > 1 then
table.insert(touchZones, 1, {id = "queue_top", arg = qi, x1 = xTop, x2 = xTop + 4, y = rowY})
end
drawText(xUp, rowY, "[^]", (qi > 1) and colors.white or colors.lightGray, colors.gray)
if qi > 1 then
table.insert(touchZones, 1, {id = "queue_up", arg = qi, x1 = xUp, x2 = xUp + 2, y = rowY})
end
drawText(xDn, rowY, "[v]", (qi < total) and colors.white or colors.lightGray, colors.gray)
if qi < total then
table.insert(touchZones, 1, {id = "queue_dn", arg = qi, x1 = xDn, x2 = xDn + 2, y = rowY})
end
drawText(xEd, rowY, "[EDIT]", colors.white, colors.gray)
table.insert(touchZones, 1, {id = "queue_edit", arg = qi, x1 = xEd, x2 = xEd + 5, y = rowY})
drawText(xDel, rowY, "[DEL]", colors.white, colors.red)
table.insert(touchZones, 1, {id = "queue_del", arg = qi, x1 = xDel, x2 = xDel + 4, y = rowY})
end
if errActive then
local fl = craftQueue[craftQueueErrIdx].failed
local errY = pY + shown + 2
drawText(pX + 2, errY, ("FAIL #" .. craftQueueErrIdx .. ":"):sub(1, pW - 4), colors.red, colors.gray)
for li = 1, math.min(2, #fl) do
drawText(pX + 4, errY + li, tostring(fl[li]):sub(1, pW - 6), colors.white, colors.gray)
end
end
local btnY = pY + pH - 1
local runStr = " [ RUN ALL ] "
local clsStr = " [ CLOSE ] "
drawText(pX + 2, btnY, runStr, colors.black, (total > 0) and colors.lime or colors.gray)
table.insert(touchZones, 1, {id = "queue_runall", x1 = pX + 2, x2 = pX + 2 + #runStr - 1, y = btnY})
drawText(pX + pW - #clsStr - 2, btnY, clsStr, colors.white, colors.gray)
table.insert(touchZones, 1, {id = "queue_close", x1 = pX + pW - #clsStr - 2, x2 = pX + pW - 2, y = btnY})
if total > maxRows then
local pgL = " < "
local pgR = " > "
local pgX = pX + math.floor(pW / 2) - 4
drawText(pgX, btnY, pgL, colors.black, colors.lightGray)
drawText(pgX + 5, btnY, pgR, colors.black, colors.lightGray)
table.insert(touchZones, 1, {id = "queue_scroll", arg = -maxRows, x1 = pgX, x2 = pgX + 2, y = btnY})
table.insert(touchZones, 1, {id = "queue_scroll", arg = maxRows, x1 = pgX + 5, x2 = pgX + 7, y = btnY})
end
return popupRect
end
function _diB15(w, h, stockInv, touchZones)
_diB8(w, touchZones)
_diB14(w, touchZones)
local isFluidCat = (currentModFilter == "FLUID")
local filteredList = {}
if isFluidCat then
local fluidSet = {}
local function collectOut(rec)
for _, o in ipairs(rec.outputs or {}) do fluidSet[o.name] = true end
end
for _, rec in pairs(FluidRecipes) do collectOut(rec) end
for _, alts in pairs(FluidAltRecipes) do
for _, a in ipairs(alts) do collectOut(a) end
end
local tmp = {}
for fname in pairs(fluidSet) do tmp[#tmp + 1] = {name = fname, producers = fluidProducers(fname)} end
table.sort(tmp, function(a, b) return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name)) end)
for _, e in ipairs(tmp) do
local sn = e.name:match(":(.+)$") or e.name
if searchFilter == "" or sn:lower():find(searchFilter:lower(), 1, true) ~= nil then
table.insert(filteredList, e)
end
end
else
local sortedItems = {}
for itemName in pairs(Recipes) do table.insert(sortedItems, itemName) end
table.sort(sortedItems)
for _, itemName in ipairs(sortedItems) do
local modId = itemName:match("^([^:]+):") or "minecraft"
local shortName = getItemDisplayName(itemName)
if (currentModFilter == "All" or currentModFilter == modId) and (searchFilter == "" or shortName:lower():find(searchFilter:lower(), 1, true) ~= nil) then
table.insert(filteredList, itemName)
end
end
end
local startRowY = 16
local itemsPerPage = h - startRowY - 3
local totalPages = math.max(1, math.ceil(#filteredList / itemsPerPage))
if currentPage > totalPages then currentPage = totalPages end
local startIdx = ((currentPage - 1) * itemsPerPage) + 1
local endIdx = math.min(startIdx + itemsPerPage - 1, #filteredList)

-- Auto-scan visible recipes on current page
if isFluidCat then
    local fstock = nil
    for idx = startIdx, endIdx do
        local r = filteredList[idx]
        if r and fluidScanResults[r.name] == nil then
            if not fstock then
                fstock = {}
                for k, v in pairs(getFluidInventory()) do fstock[fluidNameFromKey(k)] = v end
            end
            if scanOneFluidFast then scanOneFluidFast(r.name, fstock, stockInv) end
        end
    end
else
    for idx = startIdx, endIdx do
        local itemName = filteredList[idx]
        if itemName and recipesScanResults[itemName] == nil then
            scanOneRecipeFast(itemName, stockInv)
        end
    end
end

local fluidInv = isFluidCat and getFluidInventory() or nil
local rowY = startRowY
for idx = startIdx, endIdx do
if isFluidCat then
local r = filteredList[idx]
local rowBg = (idx % 2 == 0) and colors.gray or colors.black
_bufClearLine(rowY, rowBg)
local sn = r.name:match(":(.+)$") or r.name
drawText(1, rowY, sn, colors.white, rowBg)
local btnX = w - 60
if btnX < #sn + 2 then btnX = #sn + 2 end
local nProd = #r.producers
local prim = r.producers[1]
local perOp = prim and prim.perOp or 0
local stockMb = (fluidInv and fluidInv[fluidKey(r.name)]) or 0
local cStr = (stockMb > FLUID_MAX_CAP and ">100000" or tostring(stockMb))
drawText(btnX + 5 - #cStr, rowY, cStr, colors.cyan, rowBg)
local craftRes = fluidScanResults[r.name]
local cs, csFg, csBg = "[~]", colors.lightGray, rowBg
if craftRes ~= nil then
if craftRes > 0 then
cs = craftRes >= 9999 and ">9999" or (">" .. craftRes); csFg = colors.lime
else
cs = "[!]"; csFg = colors.white; csBg = colors.red
end
end
drawText(btnX + 34, rowY, cs, csFg, csBg)
if craftRes ~= nil and craftRes <= 0 then
table.insert(touchZones, {id="show_fluid_info", arg=r.name, x1=btnX+34, x2=btnX+34+#cs-1, y=rowY})
end
local awaiting = (fluidCraftWaitFluid == r.name)
drawText(btnX + 6, rowY, "[CRAFT]", colors.black, awaiting and colors.yellow or colors.white)
table.insert(touchZones, {id="fluid_craft", arg=r.name, x1=btnX+6, x2=btnX+12, y=rowY})
local isKept = Autostock[fluidKey(r.name)] ~= nil
drawText(btnX + 14, rowY, "[+KEEP]", colors.white, isKept and colors.lime or colors.gray)
table.insert(touchZones, {id="open_keep_picker_fluid", arg=r.name, x1=btnX+14, x2=btnX+20, y=rowY})
local altColor = (nProd > 1) and colors.lime or colors.gray
drawText(btnX + 22, rowY, "[ALT]", colors.black, altColor)
table.insert(touchZones, {id="fluid_alt", arg=r.name, x1=btnX+22, x2=btnX+26, y=rowY})
if pendingDeleteFluid == r.name then
drawText(btnX + 28, rowY, "[SURE?]", colors.white, colors.gray)
table.insert(touchZones, 1, {id="fluid_delete_cancel", x1=btnX+28, x2=btnX+34, y=rowY})
drawText(btnX + 36, rowY, "[YES]", colors.black, colors.red)
table.insert(touchZones, 1, {id="fluid_delete_confirm", arg=r.name, x1=btnX+36, x2=btnX+40, y=rowY})
else
drawText(btnX + 28, rowY, "[DEL]", colors.white, colors.gray)
table.insert(touchZones, {id="fluid_delete_ask", arg=r.name, x1=btnX+28, x2=btnX+32, y=rowY})
if prim then
drawText(btnX + 41, rowY, "[E]", colors.black, colors.white)
table.insert(touchZones, {id="open_recipe_edit_fluid", arg=r.name, x1=btnX+41, x2=btnX+43, y=rowY})
end
local mDisp = prim and ((getMachineDisplay(prim.recipe.machine_name) or "?") .. " " .. perOp .. "mB") or ""
drawText(btnX + 45, rowY, mDisp:sub(1, math.max(0, w - (btnX + 45))), colors.lightGray, rowBg)
end
rowY = rowY + 1
else
local itemName = filteredList[idx]
local data = Recipes[itemName]
local shortName = getItemDisplayName(itemName)
local rowBg = (idx % 2 == 0) and colors.gray or colors.black
_bufClearLine(rowY, rowBg)
local maxNameLen = math.max(10, w - 62)
local dispName = #shortName > maxNameLen and shortName:sub(1, maxNameLen) or shortName
drawText(1, rowY, dispName, colors.white, rowBg)
local btnX = w - 60
local stockCount = stockInv and (stockInv[itemName] or 0) or 0
local displayCount = stockCount
local countColor   = colors.cyan
local cStr = tostring(displayCount)
drawText(btnX - #cStr - 1, rowY, cStr, countColor, rowBg)
local scanResult = recipesScanResults[itemName]
local indX = btnX + 37
if scanResult then
local cMax = scanResult.maxCraftable or 0
if scanResult.noMachine then
drawText(indX, rowY, "[?]", colors.black, colors.orange)
table.insert(touchZones, {id="show_machine_info", arg=itemName, x1=indX, x2=indX+2, y=rowY})
elseif cMax > 0 then
local cStr = cMax > 99 and ">99" or tostring(cMax)
drawText(indX, rowY, cStr, colors.lime, rowBg)
else
drawText(indX, rowY, "[!]", colors.white, colors.red)
table.insert(touchZones, {id="show_craft_info", arg=itemName, x1=indX, x2=indX+2, y=rowY})
end
else
drawText(indX, rowY, "[~]", colors.lightGray, rowBg)
end
local hasBox = Config.train_box and Config.train_box ~= ""
local reqColor = hasBox and colors.cyan or colors.gray
drawText(btnX, rowY, "[REQ]", colors.black, reqColor)
if hasBox then
table.insert(touchZones, {id="open_req_picker", arg=itemName, x1=btnX, x2=btnX+4, y=rowY})
end
drawText(btnX + 6, rowY, "[CRAFT]", colors.black, colors.white)
table.insert(touchZones, {id="open_qty_picker", arg=itemName, x1=btnX+6, x2=btnX+12, y=rowY})
local isKept = Autostock[itemName] ~= nil
local keepColor = isKept and colors.lime or colors.gray
drawText(btnX + 14, rowY, "[+KEEP]", colors.white, keepColor)
table.insert(touchZones, {id="open_keep_picker", arg=itemName, x1=btnX+14, x2=btnX+20, y=rowY})
local hasAlts = AltRecipes[itemName] and #AltRecipes[itemName] > 0
local altBtnColor = hasAlts and colors.lime or colors.gray
drawText(btnX + 22, rowY, "[ALT]", colors.black, altBtnColor)
table.insert(touchZones, {id="open_alt_view", arg=itemName, x1=btnX+22, x2=btnX+26, y=rowY})
if pendingDeleteItem == itemName then
drawText(btnX + 28, rowY, "[SURE?]", colors.white, colors.gray)
table.insert(touchZones, 1, {id="delete_cancel", x1=btnX+28, x2=btnX+34, y=rowY})
drawText(btnX + 36, rowY, "[YES]", colors.black, colors.red)
table.insert(touchZones, 1, {id="delete_confirm", arg=itemName, x1=btnX+36, x2=btnX+40, y=rowY})
else
drawText(btnX + 28, rowY, "[DEL]", colors.white, colors.gray)
table.insert(touchZones, {id="delete_ask", arg=itemName, x1=btnX+28, x2=btnX+32, y=rowY})
drawText(btnX + 34, rowY, "x" .. (data.output_count or 1), colors.white, rowBg)
local mRaw = tostring(data.machine_name or data.method or "")
local mDisplay = getMachineDisplay(mRaw)
if data.output_device and data.output_device ~= "" then
mDisplay = mDisplay .. ">" .. getMachineDisplay(data.output_device)
end
drawText(btnX + 41, rowY, "[E]", colors.white, colors.gray)
table.insert(touchZones, {id="open_recipe_edit", arg=itemName, x1=btnX+41, x2=btnX+43, y=rowY})
drawText(btnX + 45, rowY, mDisplay, colors.lightGray, rowBg)
if data.imported and data.type ~= "turtle" then
drawText(btnX + 44, rowY, string.char(7), colors.white, rowBg)
end
end
rowY = rowY + 1
end
end
local navY = h - 1
drawText(1, navY - 1, string.rep("-", w), colors.gray)
local pageStr = string.format(" PAGE %d OF %d ", currentPage, math.max(1, totalPages))
local prevStr = " [ PREV ] " local nextStr = " [ NEXT ] "
local navStartX = math.floor((w - (#prevStr + #pageStr + #nextStr + 4)) / 2)
drawText(navStartX, navY, prevStr, currentPage > 1 and colors.white or colors.lightGray, colors.gray)
drawText(navStartX + #prevStr + 2, navY, pageStr, colors.lime, colors.black)
local nextXPos = navStartX + #prevStr + #pageStr + 4
drawText(nextXPos, navY, nextStr, currentPage < totalPages and colors.white or colors.lightGray, colors.gray)
if currentPage > 1 then
table.insert(touchZones, {id="prev_page", x1=navStartX, x2=navStartX + #prevStr - 1, y=navY})
end
if currentPage < totalPages then
table.insert(touchZones, {id="next_page", x1=nextXPos, x2=nextXPos + #nextStr - 1, y=navY})
end
end
function _diB16(w, stockInv)
local si, totalCount, vaultsCount, freeSlots, totalSlots
local tFree, tTotal
if currentTab == "QUANTITY_PICKER" then
if not pickerHeaderSnap then
local pi, pc, pv, pf, ps = getStorageInventoryCached()
local ptf, ptt = getTankStats()
pickerHeaderSnap = {inv = pi, count = pc, vaults = pv, free = pf, slots = ps, tFree = ptf, tTotal = ptt, fluidInv = getFluidInventory()}
end
local snap = pickerHeaderSnap
si, totalCount, vaultsCount, freeSlots, totalSlots = snap.inv, snap.count, snap.vaults, snap.free, snap.slots
tFree, tTotal = snap.tFree, snap.tTotal
else
pickerHeaderSnap = nil
si, totalCount, vaultsCount, freeSlots, totalSlots = getStorageInventoryCached()
tFree, tTotal = getTankStats()
end
stockInv = si
local totalTypes = 0 for _ in pairs(Recipes) do totalTypes = totalTypes + 1 end
local freeColor = colors.gray
if totalSlots > 0 then
local pct = freeSlots / totalSlots
if pct < 0.1 then freeColor = colors.red
elseif pct < 0.25 then freeColor = colors.orange
else freeColor = colors.lime
end
end
local freeVal = string.format("%d/%d", freeSlots, totalSlots)
local freeX = math.max(1, math.floor((w - #freeVal) / 2) + 1)
drawText(freeX, 3, freeVal, freeColor, colors.black)
local statStr
if tTotal > 0 then
statStr = string.format("Tank: %d/%d | Vaults: %d | Types: %d | Total: %d", tFree, tTotal, vaultsCount, totalTypes, totalCount)
else
statStr = string.format("Vaults: %d | Types: %d | Total: %d", vaultsCount, totalTypes, totalCount)
end
local statX = math.max(1, math.floor((w - #statStr) / 2) + 1)
drawText(statX, 4, statStr, colors.gray, colors.black)
return stockInv
end
function _diB17(w, h, touchZones, popupRect, popupZoneStart)
local pW = math.min(w - 4, 58)
local pX = math.floor((w - pW) / 2) + 1
local rules2   = mgmtPopup.rules or {}
local inIsStgD = (#(mgmtPopup.inputs or {}) == 0)
local headerLines = 7 + (inIsStgD and 0 or 2)
local footerLines = 3
local maxPH = h - 2
local rulesNeeded = math.max(1, #rules2)
local pH = math.min(maxPH, headerLines + rulesNeeded * 3 + footerLines)
local rulesPerPage = math.max(1, math.floor((pH - headerLines - footerLines) / 3))
local totalRulesPages = math.max(1, math.ceil(#rules2 / rulesPerPage))
if not mgmtPopup.rulesPage or mgmtPopup.rulesPage < 1 then mgmtPopup.rulesPage = 1 end
if mgmtPopup.rulesPage > totalRulesPages then mgmtPopup.rulesPage = totalRulesPages end
local rulesPage = mgmtPopup.rulesPage
local rulesStart = (rulesPage - 1) * rulesPerPage + 1
local rulesEnd   = math.min(rulesStart + rulesPerPage - 1, #rules2)
local pY = math.floor((h - pH) / 2) + 1
popupZoneStart = #touchZones + 1
popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdr = mgmtPopup.groupIdx and " EDIT GROUP " or " NEW GROUP "
drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.cyan)
local nameDisp = mgmtPopup.name ~= "" and mgmtPopup.name or "(tap to set)"
drawText(pX + 1, pY + 2, (" Name: [ " .. nameDisp .. " ]"):sub(1, pW - 2), colors.white, colors.gray)
table.insert(touchZones, {id="mgmt_edit_name", x1=pX+1, x2=pX+pW-2, y=pY+2})
local inputDisp = mgmtIODisplay({inputs=mgmtPopup.inputs}, true)
drawText(pX + 1, pY + 3, (" Input:  " .. inputDisp):sub(1, pW - 13),
inIsStgD and colors.lime or colors.white, colors.gray)
local chgIS = " [CHANGE] "
drawText(pX + pW - #chgIS - 1, pY + 3, chgIS, colors.black, colors.orange)
table.insert(touchZones, {id="mgmt_pick_input", x1=pX+pW-#chgIS-1, x2=pX+pW-2, y=pY+3})
local outIsStgD = (#(mgmtPopup.outputs or {}) == 0)
local outputDisp = mgmtIODisplay({outputs=mgmtPopup.outputs}, false)
drawText(pX + 1, pY + 4, (" Output: " .. outputDisp):sub(1, pW - 13),
outIsStgD and colors.lime or colors.cyan, colors.gray)
local chgOS = " [CHANGE] "
drawText(pX + pW - #chgOS - 1, pY + 4, chgOS, colors.black, colors.orange)
table.insert(touchZones, {id="mgmt_pick_output", x1=pX+pW-#chgOS-1, x2=pX+pW-2, y=pY+4})
drawText(pX + 1, pY + 5, string.rep("-", pW - 2), colors.lightGray, colors.gray)
drawText(pX + 1, pY + 6, mgmtPopup.fluid and " RULES (keep mB in output):" or " RULES (input->output):", colors.yellow, colors.gray)
local addRS = " [+ADD] "
drawText(pX + pW - #addRS - 1, pY + 6, addRS, colors.black, colors.lime)
table.insert(touchZones, {id="mgmt_pick_item", x1=pX+pW-#addRS-1, x2=pX+pW-2, y=pY+6})
local ruleRowY = pY + 7
if not inIsStgD then
local drainOn = mgmtPopup.drain or false
local drainLbl = drainOn and " [EMPTY ALL]  ON  " or " [EMPTY ALL]  OFF "
local drainBg  = drainOn and colors.lime   or colors.gray
local drainFg  = drainOn and colors.black  or colors.lightGray
drawText(pX + 1, ruleRowY, drainLbl:sub(1, pW - 2), drainFg, drainBg)
table.insert(touchZones, {id="mgmt_toggle_drain", x1=pX+1, x2=pX+pW-2, y=ruleRowY})
ruleRowY = ruleRowY + 1
end
if not inIsStgD then
local provOn = mgmtPopup.provider or false
drawText(pX + 1, ruleRowY,
(provOn and " [PROVIDER] ON (pull-only src) " or " [PROVIDER] OFF"):sub(1, pW - 2),
provOn and colors.black or colors.lightGray,
provOn and colors.orange or colors.gray)
table.insert(touchZones, {id="mgmt_toggle_provider", x1=pX+1, x2=pX+pW-2, y=ruleRowY})
ruleRowY = ruleRowY + 1
end
if #rules2 == 0 then
drawText(pX + 2, ruleRowY, "(none)", colors.lightGray, colors.gray)
ruleRowY = ruleRowY + 1
else
for ri2 = rulesStart, rulesEnd do
local rule = rules2[ri2]
local rName2 = getItemDisplayName(rule.item)
local delR = " [X] "; local plusR = " [+] "; local minR = " [-] "; local typR = " [#] "
local amtR = tostring(rule.amount)
local ctrlW2 = #minR + #amtR + #plusR + #typR + #delR
local ctrlX2 = pX + pW - ctrlW2 - 2
drawText(pX + 2,   ruleRowY, rName2:sub(1, ctrlX2 - pX - 3), colors.white,  colors.gray)
drawText(ctrlX2,                                    ruleRowY, minR, colors.white,  colors.gray)
drawText(ctrlX2 + #minR,                            ruleRowY, amtR, colors.yellow, colors.gray)
drawText(ctrlX2 + #minR + #amtR,                    ruleRowY, plusR,colors.white,  colors.gray)
drawText(ctrlX2 + #minR + #amtR + #plusR,           ruleRowY, typR, colors.black,  colors.orange)
drawText(ctrlX2 + #minR + #amtR + #plusR + #typR,   ruleRowY, delR, colors.white,  colors.red)
table.insert(touchZones, {id="mgmt_rule_adj",  arg={ri2,-1}, x1=ctrlX2, x2=ctrlX2+#minR-1, y=ruleRowY})
table.insert(touchZones, {id="mgmt_rule_adj",  arg={ri2, 1}, x1=ctrlX2+#minR+#amtR, x2=ctrlX2+#minR+#amtR+#plusR-1, y=ruleRowY})
table.insert(touchZones, {id="mgmt_rule_type", arg=ri2,      x1=ctrlX2+#minR+#amtR+#plusR, x2=ctrlX2+#minR+#amtR+#plusR+#typR-1, y=ruleRowY})
table.insert(touchZones, {id="mgmt_rule_del",  arg=ri2,      x1=ctrlX2+#minR+#amtR+#plusR+#typR, x2=ctrlX2+ctrlW2-1, y=ruleRowY})
ruleRowY = ruleRowY + 1
drawText(pX + 1, ruleRowY, string.rep("-", pW - 2), colors.lightGray, colors.gray)
ruleRowY = ruleRowY + 1
drawMgmtCondRow(pX, pW, ruleRowY, rule, ri2, touchZones)
ruleRowY = ruleRowY + 1
end
end
local footY2 = pY + pH - 2
if totalRulesPages > 1 then
local pagerY = footY2 - 1
local prevS3 = " < PREV "; local nextS3 = " NEXT > "
local pgStr3 = string.format("Page %d/%d", rulesPage, totalRulesPages)
local pgX3   = pX + math.floor((pW - #pgStr3) / 2)
local pPrev3 = pX + 2
local pNext3 = pX + pW - #nextS3 - 2
drawText(pPrev3, pagerY, prevS3, rulesPage > 1            and colors.white or colors.gray, colors.gray)
drawText(pgX3,   pagerY, pgStr3, colors.lightGray, colors.gray)
drawText(pNext3, pagerY, nextS3, rulesPage < totalRulesPages and colors.white or colors.gray, colors.gray)
if rulesPage > 1 then
table.insert(touchZones, {id="mgmt_rules_prev", x1=pPrev3, x2=pPrev3+#prevS3-1, y=pagerY})
end
if rulesPage < totalRulesPages then
table.insert(touchZones, {id="mgmt_rules_next", x1=pNext3, x2=pNext3+#nextS3-1, y=pagerY})
end
end
local saveS2 = " [SAVE] "; local cancelS2 = " [CANCEL] "
drawText(pX + 2,                  footY2 + 1, saveS2,   colors.black, colors.lime)
drawText(pX + pW - #cancelS2 - 2, footY2 + 1, cancelS2, colors.white, colors.gray)
table.insert(touchZones, {id="mgmt_save",   x1=pX+2,               x2=pX+2+#saveS2-1,  y=footY2+1})
table.insert(touchZones, {id="mgmt_cancel", x1=pX+pW-#cancelS2-2,  x2=pX+pW-2,         y=footY2+1})
return popupRect, popupZoneStart
end
function _diB18(w, h, touchZones, popupRect, popupZoneStart)
local allPeri2 = {"STORAGE"}
local tmpP2 = {}
for _, pn in ipairs(peripheral.getNames()) do
if not SYSTEM_SIDES[pn] and pn ~= MONITOR_SIDE and pn ~= Config.train_box then
table.insert(tmpP2, pn)
end
end
table.sort(tmpP2, naturalSortDisplay)
for _, v in ipairs(tmpP2) do table.insert(allPeri2, v) end
local pW2 = math.min(w - 10, 70)
local pX2 = math.floor((w - pW2) / 2) + 1
local pH2 = math.min(h - 4, 16)
local pY2 = math.floor((h - pH2) / 2) + 1
local cols2 = 3
local colW2 = math.floor((pW2 - 2) / cols2)
local listTop2 = pY2 + 2
local maxRows2 = pH2 - 5
local perPage2 = cols2 * maxRows2
local pPage2  = mgmtPopup.periPage or 1
local pTotal2 = math.max(1, math.ceil(#allPeri2 / perPage2))
if pPage2 > pTotal2 then pPage2 = pTotal2; mgmtPopup.periPage = pPage2 end
local pStart2 = (pPage2 - 1) * perPage2 + 1
local pEnd2   = math.min(pStart2 + perPage2 - 1, #allPeri2)
popupZoneStart = #touchZones + 1
popupRect = {x1=pX2, x2=pX2+pW2-1, y1=pY2, y2=pY2+pH2-1}
_bufFillRect(pX2, pY2, pW2, pH2, colors.gray)
local hdr2 = " SELECT INPUTS (tap to toggle) "
drawText(pX2 + math.floor((pW2 - #hdr2) / 2), pY2, hdr2, colors.black, colors.orange)
for ci = 1, cols2 - 1 do
local sepX = pX2 + 1 + ci * colW2
for ry = 0, maxRows2 - 1 do
drawText(sepX, listTop2 + ry, "|", colors.lightGray, colors.gray)
end
end
local selIn2 = mgmtPopup.inputs or {}
local selSet2 = {}
for _, nm in ipairs(selIn2) do selSet2[nm] = true end
local inStgSel2 = (#selIn2 == 0)
for pi2 = pStart2, pEnd2 do
local localIdx = pi2 - pStart2
local col = math.floor(localIdx / maxRows2)
local row = localIdx % maxRows2
local cellX = pX2 + 2 + col * colW2
local cellY = listTop2 + row
local pn2 = allPeri2[pi2]
local isStg2  = (pn2 == "STORAGE")
local isSel2  = (isStg2 and inStgSel2) or (not isStg2 and selSet2[pn2] == true)
local bgC2 = isSel2 and colors.cyan or (isStg2 and colors.lime or colors.gray)
local fgC2 = (isSel2 or isStg2) and colors.black or colors.white
local pn2Disp = isStg2 and pn2 or getMachineDisplay(pn2)
if #pn2Disp > colW2 - 2 then pn2Disp = pn2Disp:sub(1, colW2 - 2) end
drawText(cellX, cellY, pn2Disp, fgC2, bgC2)
table.insert(touchZones, {id="mgmt_set_input", arg=pn2, x1=cellX, x2=cellX+colW2-2, y=cellY})
end
local navY2 = pY2 + pH2 - 2
local arrL = " < "; local arrR = " > "
local lAct2 = (pPage2 > 1)
local rAct2 = (pPage2 < pTotal2)
drawText(pX2 + 2, navY2, arrL, lAct2 and colors.white or colors.gray, colors.gray)
if lAct2 then
table.insert(touchZones, {id="mgmt_peri_prev", x1=pX2+2, x2=pX2+2+#arrL-1, y=navY2})
end
drawText(pX2 + pW2 - #arrR - 2, navY2, arrR, rAct2 and colors.white or colors.gray, colors.gray)
if rAct2 then
table.insert(touchZones, {id="mgmt_peri_next", x1=pX2+pW2-#arrR-2, x2=pX2+pW2-3, y=navY2})
end
local canS2 = " [DONE] "
drawText(pX2 + math.floor((pW2 - #canS2) / 2), pY2 + pH2 - 1, canS2, colors.black, colors.lime)
table.insert(touchZones, {id="mgmt_peri_cancel", x1=pX2+math.floor((pW2 - #canS2)/2), x2=pX2+math.floor((pW2 - #canS2)/2)+#canS2-1, y=pY2+pH2-1})
return popupRect, popupZoneStart
end
function _diB19(w, h, touchZones, popupRect, popupZoneStart)
local allPeri6 = {"STORAGE"}
local tmpP6 = {}
for _, pn6 in ipairs(peripheral.getNames()) do
if not SYSTEM_SIDES[pn6] and pn6 ~= MONITOR_SIDE and pn6 ~= Config.train_box then
table.insert(tmpP6, pn6)
end
end
table.sort(tmpP6, naturalSortDisplay)
for _, v in ipairs(tmpP6) do table.insert(allPeri6, v) end
local pW6 = math.min(w - 10, 70)
local pX6 = math.floor((w - pW6) / 2) + 1
local pH6 = math.min(h - 4, 16)
local pY6 = math.floor((h - pH6) / 2) + 1
local cols6 = 3
local colW6 = math.floor((pW6 - 2) / cols6)
local listTop6 = pY6 + 2
local maxRows6 = pH6 - 5
local perPage6 = cols6 * maxRows6
local opPage  = mgmtPopup.outPeriPage or 1
local opTotal = math.max(1, math.ceil(#allPeri6 / perPage6))
if opPage > opTotal then opPage = opTotal; mgmtPopup.outPeriPage = opPage end
local opStart = (opPage - 1) * perPage6 + 1
local opEnd   = math.min(opStart + perPage6 - 1, #allPeri6)
popupZoneStart = #touchZones + 1
popupRect = {x1=pX6, x2=pX6+pW6-1, y1=pY6, y2=pY6+pH6-1}
_bufFillRect(pX6, pY6, pW6, pH6, colors.gray)
local hdr6 = " SELECT OUTPUTS (tap to toggle) "
drawText(pX6 + math.floor((pW6 - #hdr6) / 2), pY6, hdr6, colors.black, colors.cyan)
for ci = 1, cols6 - 1 do
local sepX = pX6 + 1 + ci * colW6
for ry = 0, maxRows6 - 1 do
drawText(sepX, listTop6 + ry, "|", colors.lightGray, colors.gray)
end
end
local selOut6 = mgmtPopup.outputs or {}
local selSet6 = {}
for _, nm in ipairs(selOut6) do selSet6[nm] = true end
local outStgSel6 = (#selOut6 == 0)
for op2 = opStart, opEnd do
local localIdx = op2 - opStart
local col = math.floor(localIdx / maxRows6)
local row = localIdx % maxRows6
local cellX = pX6 + 2 + col * colW6
local cellY = listTop6 + row
local pn6b = allPeri6[op2]
local isStg6  = (pn6b == "STORAGE")
local isSel6  = (isStg6 and outStgSel6) or (not isStg6 and selSet6[pn6b] == true)
local bgC6 = isSel6 and colors.cyan or (isStg6 and colors.lime or colors.gray)
local fgC6 = (isSel6 or isStg6) and colors.black or colors.white
local pn6bDisp = isStg6 and pn6b or getMachineDisplay(pn6b)
if #pn6bDisp > colW6 - 2 then pn6bDisp = pn6bDisp:sub(1, colW6 - 2) end
drawText(cellX, cellY, pn6bDisp, fgC6, bgC6)
table.insert(touchZones, {id="mgmt_set_output", arg=pn6b, x1=cellX, x2=cellX+colW6-2, y=cellY})
end
local navY6 = pY6 + pH6 - 2
local arrL6 = " < "; local arrR6 = " > "
local lAct6 = (opPage > 1)
local rAct6 = (opPage < opTotal)
drawText(pX6 + 2, navY6, arrL6, lAct6 and colors.white or colors.gray, colors.gray)
if lAct6 then
table.insert(touchZones, {id="mgmt_outperi_prev", x1=pX6+2, x2=pX6+2+#arrL6-1, y=navY6})
end
drawText(pX6 + pW6 - #arrR6 - 2, navY6, arrR6, rAct6 and colors.white or colors.gray, colors.gray)
if rAct6 then
table.insert(touchZones, {id="mgmt_outperi_next", x1=pX6+pW6-#arrR6-2, x2=pX6+pW6-3, y=navY6})
end
local canS6 = " [DONE] "
drawText(pX6 + math.floor((pW6 - #canS6) / 2), pY6 + pH6 - 1, canS6, colors.black, colors.lime)
table.insert(touchZones, {id="mgmt_outperi_cancel", x1=pX6+math.floor((pW6 - #canS6)/2), x2=pX6+math.floor((pW6 - #canS6)/2)+#canS6-1, y=pY6+pH6-1})
return popupRect, popupZoneStart
end
function _diParallelProgressPopup(w, h, touchZones, popupRect, ctx)
    local pW = 46
    local pH = 14
    local pX = math.max(1, math.floor((w - pW) / 2) + 1)
    local pY = math.max(1, math.floor((h - pH) / 2) + 1)
    popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
    _bufFillRect(pX, pY, pW, pH, colors.gray)

    local hdr = " MANUFACTURING ACTIVE "
    drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.orange)

    local activeList = {}
    for _, a in pairs(ctx.active or {}) do activeList[#activeList + 1] = a end
    local sDone  = craftStageDone or 0
    local sTotal = math.max(craftStageTotal or 0, sDone, 1)
    local stepStr = string.format("Sub-task %d/%d", sDone, sTotal)
    drawText(pX + 2, pY + 2, stepStr, colors.white, colors.gray)
    local wStr = "[" .. #activeList .. "x parallel]"
    drawText(pX + pW - #wStr - 2, pY + 2, wStr, colors.cyan, colors.gray)

    local finalGoal = ctx.finalGoalItem or ""
    local cleanFinal = (finalGoal:match(":(.+)$") or finalGoal):upper()
    local itemStr = (">> " .. cleanFinal .. " <<"):sub(1, pW - 4)
    drawText(pX + math.floor((pW - #itemStr) / 2), pY + 3, itemStr, colors.yellow, colors.gray)

    local row = pY + 5
    local shown = 0
    for _, a in ipairs(activeList) do
        if shown >= 5 then break end
        local prog  = string.format("%d/%d", a.done or 0, a.total or 0)
        local pre   = a.nest and "+" or (a.topup and string.char(7) or "-")
        local pmStr = "pm" .. (a.machines or 0)
        drawText(pX + 2, row, pre, colors.lightGray, colors.gray)
        drawText(pX + 4, row, pmStr, colors.lightBlue, colors.gray)
        local nameX   = pX + 4 + #pmStr + 1
        local nameMax = math.max(1, (pX + pW - #prog - 2) - nameX)
        drawText(nameX, row, tostring(a.desc):sub(1, nameMax), colors.lightGray, colors.gray)
        drawText(pX + pW - #prog - 2, row, prog, colors.lime, colors.gray)
        row = row + 1
        shown = shown + 1
    end
    if #activeList == 0 then
        drawText(pX + 2, row, "scheduling...", colors.lightGray, colors.gray)
    end

    local barWidth = math.min(28, pW - 14)
    local barX = pX + math.floor((pW - barWidth) / 2)
    drawProgressBar(barX, pY + pH - 3, barWidth, sDone, sTotal, colors.gray)

    local cancelStr = " [ CANCEL ] "
    local cbx = pX + math.floor((pW - #cancelStr) / 2)
    local cby = pY + pH - 1
    drawText(cbx, cby, cancelStr, colors.white, colors.red)
    craftCancelY  = cby
    craftCancelX1 = cbx
    craftCancelX2 = cbx + #cancelStr - 1
    table.insert(touchZones, 1, {id="craft_cancel", x1=cbx, x2=cbx+#cancelStr-1, y=cby})

    return popupRect
end
function _diRemotePopup(w, h, touchZones, popupRect)
    local pW = math.min(w - 4, 52)
    local pH = 12
    local pX = math.floor((w - pW) / 2) + 1
    local pY = math.floor((h - pH) / 2) + 1
    popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
    _bufFillRect(pX, pY, pW, pH, colors.gray)

    local hdr = " REMOTE CONTROL SETUP "
    drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.cyan)

    local isPairing = (os.clock() < pairingActiveUntil)
    if isPairing then
        local remSec = math.ceil(pairingActiveUntil - os.clock())
        drawText(pX + 2, pY + 2, ("Pairing: ACTIVE (" .. remSec .. "s remaining)"):sub(1, pW - 4), colors.lime, colors.gray)
        local btnPair = " [ CANCEL PAIRING ] "
        local bx = pX + math.floor((pW - #btnPair) / 2)
        drawText(bx, pY + 4, btnPair, colors.white, colors.red)
        table.insert(touchZones, 1, {id="remote_toggle_pair", x1=bx, x2=bx+#btnPair-1, y=pY+4})
    else
        drawText(pX + 2, pY + 2, "Pairing: INACTIVE (press below to pair)", colors.lightGray, colors.gray)
        local btnPair = " [ START PAIRING (60s) ] "
        local bx = pX + math.floor((pW - #btnPair) / 2)
        drawText(bx, pY + 4, btnPair, colors.black, colors.lime)
        table.insert(touchZones, 1, {id="remote_toggle_pair", x1=bx, x2=bx+#btnPair-1, y=pY+4})
    end

    drawText(pX + 2, pY + 6, "Connected / Paired Devices:", colors.yellow, colors.gray)
    local remotes = {}
    if Config.paired_remotes then
        for k, _ in pairs(Config.paired_remotes) do
            local num = tonumber(k)
            if num and not remotes[num] then remotes[num] = true end
        end
    end
    local rList = {}
    for id, _ in pairs(remotes) do rList[#rList + 1] = id end
    table.sort(rList)

    if #rList == 0 then
        drawText(pX + 4, pY + 7, "No paired tablets yet.", colors.lightGray, colors.gray)
    else
        local devStr = ""
        for _, id in ipairs(rList) do
            devStr = devStr .. (devStr == "" and "" or ", ") .. "Pocket #" .. id
        end
        drawText(pX + 4, pY + 7, devStr:sub(1, pW - 6), colors.white, colors.gray)
        local unp = "[UNPAIR ALL]"
        drawText(pX + 4, pY + 8, unp, colors.red, colors.gray)
        table.insert(touchZones, 1, {id="remote_unpair_all", x1=pX+4, x2=pX+4+#unp-1, y=pY+8})
    end

    local cls = " [ CLOSE ] "
    local cx = pX + math.floor((pW - #cls) / 2)
    drawText(cx, pY + pH - 1, cls, colors.white, colors.black)
    table.insert(touchZones, 1, {id="close_remote_popup", x1=cx, x2=cx+#cls-1, y=pY+pH-1})

    return popupRect
end
function _diNetworkFilterPopup(w, h, touchZones, popupRect)
    local pW = math.min(w - 4, 52)
    local pH = 15
    local pX = math.floor((w - pW) / 2) + 1
    local pY = math.floor((h - pH) / 2) + 1
    popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
    _bufFillRect(pX, pY, pW, pH, colors.gray)

    local hdr = " NETWORK DEVICE FILTER "
    drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.cyan)

    -- Checkbox row: Always keep active/assigned visible
    local keepActive = (Config.filter_keep_active ~= false)
    local chkStr = keepActive and "[X]" or "[ ]"
    local chkCol = keepActive and colors.lime or colors.lightGray
    drawText(pX + 2, pY + 2, chkStr, chkCol, colors.gray)
    local lblText = "Keep active / assigned visible"
    drawText(pX + 6, pY + 2, lblText, colors.white, colors.gray)
    table.insert(touchZones, 1, {id="filter_toggle_keep_active", x1=pX+2, x2=pX+6+#lblText, y=pY+2})

    drawText(pX + 1, pY + 3, string.rep("-", pW - 2), colors.lightGray, colors.gray)

    -- Discover all peripheral categories currently attached to the bus
    local catCounts = {}
    for _, p in ipairs(peripheral.getNames()) do
        if not SYSTEM_SIDES[p] and p ~= MONITOR_SIDE then
            local cat = getCategoryFromPeriph(p)
            catCounts[cat] = (catCounts[cat] or 0) + 1
        end
    end
    local catList = {}
    for cat, cnt in pairs(catCounts) do
        table.insert(catList, { name = cat, count = cnt })
    end
    table.sort(catList, function(a, b) return naturalSortCompare(a.name, b.name) end)

    local rowsPerPage = 6
    local totalPages = math.max(1, math.ceil(#catList / rowsPerPage))
    if not networkFilterPage or networkFilterPage < 1 then networkFilterPage = 1 end
    if networkFilterPage > totalPages then networkFilterPage = totalPages end
    local startIdx = (networkFilterPage - 1) * rowsPerPage + 1
    local endIdx = math.min(startIdx + rowsPerPage - 1, #catList)

    local rowY = pY + 4
    if #catList == 0 then
        drawText(pX + 2, rowY + 1, "No peripherals detected on network.", colors.lightGray, colors.gray)
    else
        for i = startIdx, endIdx do
            local item = catList[i]
            local isHidden = Config.hidden_network_types and Config.hidden_network_types[item.name]
            local tagStr = isHidden and " [HIDE] " or " [SHOW] "
            local tagFg  = isHidden and colors.white or colors.black
            local tagBg  = isHidden and colors.red or colors.lime
            drawText(pX + 2, rowY, tagStr, tagFg, tagBg)

            local infoStr = string.format("%s (%d)", item.name, item.count)
            drawText(pX + 11, rowY, infoStr:sub(1, pW - 13), isHidden and colors.lightGray or colors.white, colors.gray)
            table.insert(touchZones, 1, {id="filter_toggle_cat", arg=item.name, x1=pX+2, x2=pX+pW-3, y=rowY})
            rowY = rowY + 1
        end
    end

    -- Pagination controls
    local navY = pY + pH - 3
    if totalPages > 1 then
        local arrL = " < "
        local arrR = " > "
        local lAct = (networkFilterPage > 1)
        local rAct = (networkFilterPage < totalPages)
        drawText(pX + 2, navY, arrL, lAct and colors.white or colors.gray, lAct and colors.black or colors.gray)
        if lAct then
            table.insert(touchZones, 1, {id="filter_page_prev", x1=pX+2, x2=pX+2+#arrL-1, y=navY})
        end

        local pStr = string.format("Page %d of %d", networkFilterPage, totalPages)
        drawText(pX + math.floor((pW - #pStr) / 2), navY, pStr, colors.lightGray, colors.gray)

        local rX = pX + pW - #arrR - 2
        drawText(rX, navY, arrR, rAct and colors.white or colors.gray, rAct and colors.black or colors.gray)
        if rAct then
            table.insert(touchZones, 1, {id="filter_page_next", x1=rX, x2=rX+#arrR-1, y=navY})
        end
    end

    -- Bottom action buttons
    local bY = pY + pH - 1
    local btnShowAll = " [SHOW ALL] "
    drawText(pX + 3, bY, btnShowAll, colors.black, colors.lime)
    table.insert(touchZones, 1, {id="filter_show_all", x1=pX+3, x2=pX+3+#btnShowAll-1, y=bY})

    local btnClose = " [ CLOSE ] "
    local clsX = pX + pW - #btnClose - 3
    drawText(clsX, bY, btnClose, colors.white, colors.black)
    table.insert(touchZones, 1, {id="close_network_filter", x1=clsX, x2=clsX+#btnClose-1, y=bY})

    return popupRect
end
function _diB20(w, h, touchZones, popupRect)
craftErrorLines = {}; craftErrorTitle = nil
local fp = fluidRecipePicker
local sName = fp.fluid:match(":(.+)$") or fp.fluid
local rows = fp.producers
local pW = math.min(w - 4, 76)
local pH = math.min(#rows + 6, h - 4)
local pX = math.max(1, math.floor((w - pW) / 2) + 1)
local pY = math.max(1, math.floor((h - pH) / 2) + 1)
popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdr = " RECIPE PRIORITY: " .. sName:upper() .. " "
drawText(pX + math.floor((pW - #hdr) / 2), pY, hdr, colors.black, colors.lime)
drawText(pX + 2, pY + 1, "[*]=make primary  [X]=delete  top=tried first", colors.gray, colors.gray)
local awaiting = (fluidCraftWaitFluid == fp.fluid)
local lineY = pY + 3
for idx, p in ipairs(rows) do
if lineY >= pY + pH - 1 then break end
local mDisp = getMachineDisplay(p.recipe.machine_name) or p.recipe.machine_name or "?"
local inParts = {}
for _, inp in ipairs(p.recipe.inputs or {}) do
local sn = inp.name:match(":(.+)$") or inp.name
inParts[#inParts + 1] = string.format("%s %d", sn, inp.amount)
end
for _, it in ipairs(p.recipe.item_inputs or {}) do
local sn = it.name:match(":(.+)$") or it.name
inParts[#inParts + 1] = string.format("%dx %s", it.count, sn)
end
local outParts = {}
for _, o in ipairs(p.recipe.outputs or {}) do
local sn = o.name:match(":(.+)$") or o.name
outParts[#outParts + 1] = string.format("%s %d", sn, o.amount)
end
for _, o in ipairs(p.recipe.item_outputs or {}) do
local sn = o.name:match(":(.+)$") or o.name
outParts[#outParts + 1] = string.format("%dx %s", o.count, sn)
end
local rank
if p.isPrimary then rank = "[PRIMARY] "
elseif p.own then rank = "[#" .. idx .. "] "
else rank = "[~] " end
local desc = rank .. string.format("%s: %s -> %s", mDisp, table.concat(inParts, " + "), table.concat(outParts, " + "))
local crfStr = "[CRAFT]"
local delStr = "[X]"
local starStr = "[*]"
local delX = pX + pW - 2 - #delStr
local crfX = delX - 1 - #crfStr
local starX = crfX - 1 - #starStr
local maxDesc = starX - 1 - (pX + 2)
drawText(pX + 2, lineY, desc:sub(1, math.max(1, maxDesc)), p.isPrimary and colors.yellow or colors.white, colors.gray)
if p.own and not p.isPrimary then
drawText(starX, lineY, starStr, colors.black, colors.cyan)
table.insert(touchZones, 1, {id="fluid_make_primary", arg=idx, x1=starX, x2=starX+#starStr-1, y=lineY})
end
if awaiting then
drawText(crfX - 1, lineY, "-", colors.lime, colors.gray)
drawText(crfX + #crfStr, lineY, "-", colors.lime, colors.gray)
end
drawText(crfX, lineY, crfStr, colors.black, awaiting and colors.yellow or colors.lime)
table.insert(touchZones, 1, {id="fluid_pick_recipe", arg=idx, x1=crfX, x2=crfX+#crfStr-1, y=lineY})
if p.own then
drawText(delX, lineY, delStr, colors.black, colors.red)
table.insert(touchZones, 1, {id="fluid_picker_delete", arg=idx, x1=delX, x2=delX+#delStr-1, y=lineY})
end
lineY = lineY + 1
end
local clsStr = " [ CLOSE ] "
local clsX = pX + math.floor((pW - #clsStr) / 2)
local clsY = pY + pH - 1
drawText(clsX, clsY, clsStr, colors.white, colors.gray)
table.insert(touchZones, 1, {id="fluid_picker_close", x1=clsX, x2=clsX+#clsStr-1, y=clsY})
return popupRect
end
function _diB21(w, h, touchZones, popupRect, data)
local sName = getItemDisplayName(craftInfoPopup.item)
local contentLines = {}
local blockedFull = {}
for bItem in pairs(data.blocked or {}) do
table.insert(blockedFull, bItem)
end
table.sort(blockedFull)
if #blockedFull > 0 then
for _, bFull in ipairs(blockedFull) do
local bShort = getItemDisplayName(bFull)
table.insert(contentLines, {text = bShort .. ":", color = colors.red})
local details = data.blockedDetails and data.blockedDetails[bFull]
if details and details.missing and next(details.missing) then
local mList = {}
for mItem, mCount in pairs(details.missing) do
table.insert(mList, {name = getItemDisplayName(mItem), count = mCount})
end
table.sort(mList, function(a, b) return naturalSortCompare(a.name, b.name) end)
for _, m in ipairs(mList) do
table.insert(contentLines, {text = "  " .. m.name .. "  x" .. m.count, color = colors.white})
end
end
table.insert(contentLines, {text = "", color = colors.gray})
end
else
local mList = {}
for mItem, mCount in pairs(data.missing or {}) do
table.insert(mList, {name = getItemDisplayName(mItem), count = mCount})
end
table.sort(mList, function(a, b) return naturalSortCompare(a.name, b.name) end)
for _, m in ipairs(mList) do
table.insert(contentLines, {text = m.name .. "  x" .. m.count, color = colors.white})
end
end
if #contentLines == 0 then
table.insert(contentLines, {text = "Craftable from stock (no shortage).", color = colors.lime})
end
local pW  = 44
local pH  = math.min(#contentLines + 5, h - 8)
local pX  = math.max(1, math.floor((w - pW) / 2) + 1)
local pY  = math.max(1, math.floor((h - pH) / 2) + 1)
popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdrStr = " ANALYSIS: " .. sName:upper():sub(1, pW - 13) .. " "
drawText(pX + math.floor((pW - #hdrStr) / 2), pY, hdrStr, colors.black, colors.red)
local lineY = pY + 2
for _, line in ipairs(contentLines) do
if lineY >= pY + pH - 2 then break end
if line.text ~= "" then
drawText(pX + 2, lineY, line.text:sub(1, pW - 4), line.color, colors.gray)
end
lineY = lineY + 1
end
local clsStr = " [ CLOSE ] "
local clsX   = pX + math.floor((pW - #clsStr) / 2)
local clsY   = pY + pH - 1
drawText(clsX, clsY, clsStr, colors.white, colors.gray)
table.insert(touchZones, 1, {id="close_craft_info", x1=clsX, x2=clsX+#clsStr-1, y=clsY})
return popupRect
end
function _diB22(w, h, touchZones, popupRect)
craftErrorLines = {}; craftErrorTitle = nil
craftInfoPopup = nil
recipeEditPopup = nil
local popup = craftCompletePopup
local outs = popup.outputs
local bodyLines = outs and #outs or 1
local pW = 40
local pH = math.max(7, bodyLines + 5)
local pX = math.max(1, math.floor((w - pW) / 2) + 1)
local pY = math.max(9, math.floor((h - pH) / 2) + 1)
popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdrStr = popup.learned and " RECIPE LEARNED " or " CRAFT COMPLETE "
drawText(pX + math.floor((pW - #hdrStr) / 2), pY, hdrStr, colors.black, colors.lime)
local clsStr = " [CLOSE] "
local btnY = pY + pH - 2
local clsX = pX + pW - #clsStr - 2
if outs then
drawText(pX + 2, pY + 2, "Output:", colors.white, colors.gray)
local ly = pY + 3
for _, o in ipairs(outs) do
local on = o.name:match(":(.+)$") or o.name
local unit = o.unit or "mB"
local txt = (unit == "x") and (on .. ": " .. o.amount .. "x") or (on .. ": " .. o.amount .. " mB")
drawText(pX + 4, ly, txt:sub(1, pW - 6), colors.lime, colors.gray)
ly = ly + 1
end
elseif popup.isFluid then
local sName = popup.item:match(":(.+)$") or popup.item
drawText(pX + 2, pY + 2, ("Fluid: " .. sName):sub(1, pW - 4), colors.white, colors.gray)
drawText(pX + 2, pY + 3, "Made: " .. popup.count .. " mB", colors.lime, colors.gray)
else
local sName = popup.item:match(":(.+)$") or popup.item
drawText(pX + 2, pY + 2, ("Item: " .. sName):sub(1, pW - 4), colors.white, colors.gray)
drawText(pX + 2, pY + 3, "Stock: " .. popup.count .. " pcs.", colors.lime, colors.gray)
local reqStr = " [REQUEST] "
local reqX = pX + 2
drawText(reqX, btnY, reqStr, colors.black, colors.cyan)
table.insert(touchZones, 1, {id="popup_request", x1=reqX, x2=reqX+#reqStr-1, y=btnY})
end
drawText(clsX, btnY, clsStr, colors.white, colors.black)
table.insert(touchZones, 1, {id="popup_close", x1=clsX, x2=clsX+#clsStr-1, y=btnY})
return popupRect
end
function _diB24(w, h, touchZones, popupRect)
local sName = fluidCraftInfo.name:match(":(.+)$") or fluidCraftInfo.name
local mList = {}
for mKey, mAmt in pairs(fluidCraftInfo.missing or {}) do
if mKey ~= "__fl" and type(mAmt) == "number" and mAmt > 0 then
local isFl = (type(mKey) == "string" and mKey:sub(1, 2) == "f:")
local nm = isFl and fluidNameFromKey(mKey) or mKey
nm = nm:match(":(.+)$") or nm
mList[#mList + 1] = {name = nm, amt = mAmt, isFl = isFl}
end
end
table.sort(mList, function(a, b) return naturalSortCompare(a.name, b.name) end)
local contentLines = {}
for _, m in ipairs(mList) do
local suf = m.isFl and (" x" .. m.amt .. " mB") or ("  x" .. m.amt)
contentLines[#contentLines + 1] = {text = m.name .. suf, color = m.isFl and colors.cyan or colors.white}
end
if #contentLines == 0 then
contentLines[#contentLines + 1] = {text = "Craftable from stock (no shortage).", color = colors.lime}
end
local pW = 44
local pH = math.min(#contentLines + 5, h - 8)
local pX = math.max(1, math.floor((w - pW) / 2) + 1)
local pY = math.max(1, math.floor((h - pH) / 2) + 1)
popupRect = {x1=pX, x2=pX+pW-1, y1=pY, y2=pY+pH-1}
_bufFillRect(pX, pY, pW, pH, colors.gray)
local hdrStr = " MISSING: " .. sName:upper():sub(1, pW - 12) .. " "
drawText(pX + math.floor((pW - #hdrStr) / 2), pY, hdrStr, colors.black, colors.red)
local lineY = pY + 2
for _, line in ipairs(contentLines) do
if lineY >= pY + pH - 2 then break end
drawText(pX + 2, lineY, line.text:sub(1, pW - 4), line.color, colors.gray)
lineY = lineY + 1
end
local clsStr = " [ CLOSE ] "
local clsX = pX + math.floor((pW - #clsStr) / 2)
local clsY = pY + pH - 1
drawText(clsX, clsY, clsStr, colors.white, colors.gray)
table.insert(touchZones, 1, {id="close_fluid_info", x1=clsX, x2=clsX+#clsStr-1, y=clsY})
return popupRect
end
function _diB26(w, grp2, h, touchZones, popupRect, popupZoneStart)
local pW = math.min(w - 4, 58)
local pX = math.floor((w - pW) / 2) + 1
local inIsStgV  = (not grp2.input  or grp2.input  == "" or grp2.input  == "STORAGE")
local outIsStgV = (not grp2.output or grp2.output == "" or grp2.output == "STORAGE")
local viewItems = {}
for _, rule in ipairs(grp2.rules or {}) do
table.insert(viewItems, {name=rule.item, amount=rule.amount, condition=rule.condition})
end
table.sort(viewItems, function(a,b) return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name)) end)
local isFluidV = mgmtGroupIsFluid(grp2)
local stgSnapV = isFluidV and mgmtFluidStockSnap() or getStorageInventoryCached()
local inputCounts = {}
if inIsStgV then
for _, vi in ipairs(viewItems) do
inputCounts[vi.name] = stgSnapV[vi.name] or 0
end
elseif isFluidV then
inputCounts = tankContents(grp2.input)
else
local inP4 = peripheral.wrap(grp2.input)
if inP4 and inP4.list then
local ok4, items4 = pcall(inP4.list)
if ok4 and items4 then
for _, it4 in pairs(items4) do
if it4 then
local k4 = makeItemKey(it4.name, it4.nbt)
inputCounts[k4] = (inputCounts[k4] or 0) + it4.count
if it4.name ~= k4 then inputCounts[it4.name] = (inputCounts[it4.name] or 0) + it4.count end
end
end
end
end
end
local outCounts = {}
if outIsStgV then
outCounts = stgSnapV
elseif isFluidV then
outCounts = tankContents(grp2.output)
else
local outP4 = peripheral.wrap(grp2.output)
if outP4 and outP4.list then
local ok5, outIt4 = pcall(outP4.list)
if ok5 and outIt4 then
for _, oi4 in pairs(outIt4) do
if oi4 then
local k5 = makeItemKey(oi4.name, oi4.nbt)
outCounts[k5] = (outCounts[k5] or 0) + oi4.count
if oi4.name ~= k5 then outCounts[oi4.name] = (outCounts[oi4.name] or 0) + oi4.count end
end
end
end
end
end
local viPP    = 5
local viPage  = mgmtPopup.page or 1
local viTotal = math.max(1, math.ceil(#viewItems / viPP))
if viPage > viTotal then viPage = viTotal; mgmtPopup.page = viPage end
local viStart = (viPage - 1) * viPP + 1
local viEnd   = math.min(viStart + viPP - 1, #viewItems)
local visRows = 0
for vi2 = viStart, viEnd do
visRows = visRows + 1
local itm2 = viewItems[vi2]
if itm2.condition and itm2.condition.item and itm2.condition.item ~= "" then
visRows = visRows + 1
end
end
if visRows == 0 then visRows = 1 end
local pH4 = math.max(10, math.min(visRows + 6, h - 2))
local pY4 = math.floor((h - pH4) / 2) + 1
popupZoneStart = #touchZones + 1
popupRect = {x1=pX, x2=pX+pW-1, y1=pY4, y2=pY4+pH4-1}
_bufFillRect(pX, pY4, pW, pH4, colors.gray)
local gName2 = (grp2.name ~= "" and grp2.name or "(unnamed)"):upper()
local hdr4   = " VIEW: " .. gName2:sub(1, pW - 11) .. " "
drawText(pX + math.floor((pW - #hdr4) / 2), pY4, hdr4, colors.black, colors.orange)
local C_RULE   = pX + pW - 20
local C_INPUT  = pX + pW - 13
local C_OUTPUT = pX + pW - 6
local nameMax  = pW - 23
local inLbl  = inIsStgV  and "STORAGE" or (grp2.input:match(":(.+)$")  or grp2.input):sub(1,10)
local outLbl = outIsStgV and "STORAGE" or (grp2.output:match(":(.+)$") or grp2.output):sub(1,10)
local ioLbl4 = ("In: " .. inLbl .. " -> Out: " .. outLbl):sub(1, nameMax + 1)
drawText(pX + 2,   pY4 + 1, ioLbl4, colors.lightGray, colors.gray)
drawText(C_RULE,   pY4 + 1, "  RULE", colors.yellow,  colors.gray)
drawText(C_INPUT,  pY4 + 1, " INPUT", colors.cyan,    colors.gray)
drawText(C_OUTPUT, pY4 + 1, "OUTPUT", colors.lime,    colors.gray)
if #viewItems == 0 then
drawText(pX + 2, pY4 + 2, "(no rules defined)", colors.lightGray, colors.gray)
else
local curViY = pY4 + 2
for vi = viStart, viEnd do
local itm3   = viewItems[vi]
local iShort = getItemDisplayName(itm3.name):sub(1, nameMax)
drawText(pX + 2, curViY, iShort, colors.white, colors.gray)
local rS = tostring(itm3.amount)
drawText(C_RULE  + math.max(0, 6-#rS), curViY, rS:sub(1,6), colors.yellow, colors.gray)
local iS = tostring(inputCounts[itm3.name] or 0)
drawText(C_INPUT + math.max(0, 6-#iS), curViY, iS:sub(1,6), colors.cyan,   colors.gray)
local oS = tostring(outCounts[itm3.name] or 0)
drawText(C_OUTPUT + math.max(0, 6-#oS), curViY, oS:sub(1,6), colors.lime,  colors.gray)
curViY = curViY + 1
local cond3 = itm3.condition
if cond3 and cond3.item and cond3.item ~= "" then
local cItemShort = getItemDisplayName(cond3.item)
local opStr3  = cond3.op or "<"
local cVal3   = cond3.value or 1
local condStock = stgSnapV[cond3.item] or 0
local condMet = false
if opStr3 == "<" then condMet = condStock < cVal3
elseif opStr3 == ">" then condMet = condStock > cVal3
elseif opStr3 == "=" then condMet = condStock == cVal3
end
local stockColor = condMet and colors.lime or colors.orange
local ifDetail = "-- IF " .. cItemShort:sub(1, nameMax - 6) .. " " .. opStr3 .. " " .. tostring(cVal3)
drawText(pX + 2, curViY, ifDetail:sub(1, nameMax + 2), colors.cyan, colors.gray)
local cStockStr = tostring(condStock)
drawText(C_OUTPUT + math.max(0, 6-#cStockStr), curViY, cStockStr:sub(1,6), stockColor, colors.gray)
curViY = curViY + 1
end
end
end
local navY4 = pY4 + pH4 - 3
if viTotal > 1 then
if viPage > 1 then
drawText(pX + 2, navY4, " [<] ", colors.white, colors.black)
table.insert(touchZones, {id="mgmt_vinput_prev", x1=pX+2, x2=pX+6, y=navY4})
end
local pgStr4 = viPage .. "/" .. viTotal
drawText(pX + math.floor((pW - #pgStr4) / 2), navY4, pgStr4, colors.lightGray, colors.gray)
if viPage < viTotal then
drawText(pX + pW - 7, navY4, " [>] ", colors.white, colors.black)
table.insert(touchZones, {id="mgmt_vinput_next", x1=pX+pW-7, x2=pX+pW-3, y=navY4})
end
end
local clsS2 = " [CLOSE] "
drawText(pX + math.floor((pW - #clsS2) / 2), pY4 + pH4 - 1, clsS2, colors.white, colors.gray)
table.insert(touchZones, {id="mgmt_close_view",
x1=pX+math.floor((pW-#clsS2)/2), x2=pX+math.floor((pW-#clsS2)/2)+#clsS2-1, y=pY4+pH4-1})
return popupRect, popupZoneStart
end
function drawErrorsTab(w, h, touchZones)
    local topY = 9
    local titleStr = "ERROR JOURNAL (LAST 10 ENTRIES)"
    drawText(2, topY, titleStr, colors.yellow, colors.black)
    
    local clearStr = " [CLEAR] "
    local clearX = w - #clearStr
    drawText(clearX, topY, clearStr, colors.white, colors.red)
    table.insert(touchZones, {id="clear_error_log", x1=clearX, x2=clearX+#clearStr-1, y=topY})
    
    drawText(1, topY + 1, string.rep("-", w), colors.gray)
    
    local startRowY = topY + 2
    local entriesPerPage = 5
    local totalEntries = #errorLog
    local totalPages = math.max(1, math.ceil(totalEntries / entriesPerPage))
    if errorLogPage > totalPages then errorLogPage = totalPages end
    if errorLogPage < 1 then errorLogPage = 1 end
    
    if totalEntries == 0 then
        local emptyMsg = "No errors recorded. System running smoothly."
        drawText(math.max(2, math.floor((w - #emptyMsg) / 2)), startRowY + 3, emptyMsg, colors.lime, colors.black)
    else
        local startIdx = (errorLogPage - 1) * entriesPerPage + 1
        local endIdx = math.min(startIdx + entriesPerPage - 1, totalEntries)
        local curY = startRowY
        
        for i = startIdx, endIdx do
            if curY >= h - 3 then break end
            local entry = errorLog[i]
            local timePrefix = string.format("#%d [%s] ", i, entry.time or "--:--:--")
            drawText(2, curY, timePrefix, colors.cyan, colors.black)
            
            local titleColor = (entry.title == "! NEED") and colors.yellow or colors.red
            local titleX = 2 + #timePrefix
            local maxTitleW = w - titleX - 1
            local tStr = entry.title or "! ERROR"
            if #tStr > maxTitleW then tStr = tStr:sub(1, maxTitleW) end
            drawText(titleX, curY, tStr, titleColor, colors.black)
            curY = curY + 1
            
            if entry.lines and #entry.lines > 0 then
                for _, l in ipairs(entry.lines) do
                    if curY >= h - 3 then break end
                    local lineStr = "    " .. tostring(l)
                    if #lineStr > w - 2 then lineStr = lineStr:sub(1, w - 2) end
                    drawText(2, curY, lineStr, colors.lightGray, colors.black)
                    curY = curY + 1
                end
            end
            
            if i < endIdx and curY < h - 3 then
                drawText(2, curY, string.rep(".", math.min(40, w - 4)), colors.gray, colors.black)
                curY = curY + 1
            end
        end
    end
    
    local navY = h - 1
    drawText(1, navY - 1, string.rep("-", w), colors.gray)
    local pageStr = string.format(" PAGE %d OF %d ", errorLogPage, totalPages)
    local prevStr = " [ PREV ] "
    local nextStr = " [ NEXT ] "
    local navStartX = math.floor((w - (#prevStr + #pageStr + #nextStr + 4)) / 2)
    if navStartX < 2 then navStartX = 2 end
    
    drawText(navStartX, navY, prevStr, errorLogPage > 1 and colors.white or colors.lightGray, colors.gray)
    drawText(navStartX + #prevStr + 2, navY, pageStr, colors.lime, colors.black)
    local nextXPos = navStartX + #prevStr + #pageStr + 4
    drawText(nextXPos, navY, nextStr, errorLogPage < totalPages and colors.white or colors.lightGray, colors.gray)
    
    if errorLogPage > 1 then
        table.insert(touchZones, {id="error_prev_page", x1=navStartX, x2=navStartX+#prevStr-1, y=navY})
    end
    if errorLogPage < totalPages then
        table.insert(touchZones, {id="error_next_page", x1=nextXPos, x2=nextXPos+#nextStr-1, y=navY})
    end
end

local ProjectState = {
    subTab = "CHECKLIST",
    sortMode = "STATUS",
    page = 1,
    selectedDest = nil,
    pickerMode = nil,
    pickerPage = 1,
    rawClipboardItems = {},
    rawClipboardPages = {},
    clipboardSlot = nil,
    items = {},
    missingRecipes = {},
    rawDeficits = {},
    totalTypes = 0,
    totalPieces = 0,
    readyTypes = 0,
    lastScanMsg = "Assign a chest with [PROJ] in NETWORK, then scan its Clipboard.",
    lastScanColor = colors.lightGray,
    hasScanned = false,
}

function clearProjectData(message)
    ProjectState.hasScanned = false
    ProjectState.rawClipboardItems = {}
    ProjectState.rawClipboardPages = {}
    ProjectState.clipboardSlot = nil
    ProjectState.items = {}
    ProjectState.missingRecipes = {}
    ProjectState.rawDeficits = {}
    ProjectState.totalTypes = 0
    ProjectState.totalPieces = 0
    ProjectState.readyTypes = 0
    ProjectState.page = 1
    ProjectState.lastScanMsg = message or "Project cleared. Scan the Clipboard in the assigned chest."
    ProjectState.lastScanColor = colors.lightGray
end

local function getClipboardPages(detail)
    if type(detail) ~= "table" or detail.name ~= "create:clipboard" then return nil end
    if type(detail.clipboard) ~= "table" or type(detail.clipboard.pages) ~= "table" then
        return nil
    end
    return detail.clipboard.pages
end

local function getSortedNumericKeys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        if type(key) == "number" then table.insert(keys, key) end
    end
    table.sort(keys)
    return keys
end

function readProjectClipboard()
    local chestName = Config.project_chest
    if not chestName or chestName == "" then
        return nil, "Assign a Clipboard chest with [PROJ] in NETWORK."
    end
    if not peripheral.isPresent(chestName) then
        return nil, "Assigned project chest is offline: " .. tostring(chestName)
    end

    local chest = peripheral.wrap(chestName)
    if not chest or not chest.list or not chest.getItemDetail then
        return nil, "Assigned peripheral does not support inventory item details."
    end

    local okList, contents = pcall(chest.list)
    if not okList or type(contents) ~= "table" then
        return nil, "Failed to list the assigned project chest."
    end

    for _, slot in ipairs(getSortedNumericKeys(contents)) do
        local okDetail, detail = pcall(chest.getItemDetail, slot)
        if okDetail then
            local pages = getClipboardPages(detail)
            if pages then
                return {
                    source = chestName,
                    slot = slot,
                    detail = detail,
                    pages = pages,
                }
            end
        end
    end

    return nil, "No Create Clipboard found in the assigned project chest."
end

function getProjectDestinations()
    local list = {}
    local seen = {}
    if Config.train_box and Config.train_box ~= "" and peripheral.isPresent(Config.train_box) then
        table.insert(list, Config.train_box)
        seen[Config.train_box] = true
    end
    for sName, en in pairs(Config.storages or {}) do
        if en and not seen[sName] and peripheral.isPresent(sName) then
            table.insert(list, sName)
            seen[sName] = true
        end
    end
    for _, name in ipairs(peripheral.getNames()) do
        if not seen[name] and name ~= Config.buffer and name ~= Config.project_chest
        and not (Config.main_vaults and Config.main_vaults[name])
        and not (Config.turtles and Config.turtles[name])
        and not SYSTEM_SIDES[name] then
            if peripheral.hasType and peripheral.hasType(name, "inventory") then
                local low = name:lower()
                if low:find("chest") or low:find("barrel") or low:find("vault")
                or low:find("shulker") or low:find("crate") or low:find("drawer") or low:find("box") then
                    table.insert(list, name)
                    seen[name] = true
                end
            end
        end
    end
    if #list == 0 then
        ProjectState.selectedDest = nil
    else
        if not ProjectState.selectedDest and Config.project_dest then
            ProjectState.selectedDest = Config.project_dest
        end
        local found = false
        for _, n in ipairs(list) do
            if n == ProjectState.selectedDest then found = true; break end
        end
        if not found then ProjectState.selectedDest = list[1] end
    end
    return list
end

function sortProjectItems()
    local mode = ProjectState.sortMode or "STATUS"
    table.sort(ProjectState.items, function(a, b)
        if mode == "STATUS" then
            if a.statusPrio ~= b.statusPrio then return a.statusPrio < b.statusPrio end
            if a.deficit ~= b.deficit then return a.deficit > b.deficit end
            return a.name < b.name
        elseif mode == "STATUS_REV" then
            if a.statusPrio ~= b.statusPrio then return a.statusPrio > b.statusPrio end
            if a.deficit ~= b.deficit then return a.deficit > b.deficit end
            return a.name < b.name
        elseif mode == "DEFICIT" then
            if a.deficit ~= b.deficit then return a.deficit > b.deficit end
            if a.statusPrio ~= b.statusPrio then return a.statusPrio < b.statusPrio end
            return a.name < b.name
        else
            if a.name ~= b.name then return a.name < b.name end
            return a.id < b.id
        end
    end)
end

function refreshProjectAnalysis(stockInv)
    stockInv = stockInv or getStorageInventoryCached()
    ProjectState.items = {}
    ProjectState.missingRecipes = {}
    ProjectState.rawDeficits = {}
    ProjectState.totalTypes = #ProjectState.rawClipboardItems
    ProjectState.totalPieces = 0
    ProjectState.readyTypes = 0

    local simStock = {}
    for k, v in pairs(stockInv) do simStock[k] = v end

    for _, raw in ipairs(ProjectState.rawClipboardItems) do
        local id = raw.id
        local need = raw.need or 0
        ProjectState.totalPieces = ProjectState.totalPieces + need
        local have = groupAvailable(id, stockInv, false)
        local deficit = math.max(0, need - have)
        local hasRec = (Recipes[id] ~= nil)
            or (AltRecipes and AltRecipes[id] and #AltRecipes[id] > 0)
            or (findFluidItemProducer and findFluidItemProducer(id) ~= nil)

        local status, statusLabel, statusColor, statusPrio
        if deficit == 0 then
            status = "READY"
            statusLabel = "OK READY"
            statusColor = colors.lime
            statusPrio = 4
            ProjectState.readyTypes = ProjectState.readyTypes + 1
        elseif not hasRec then
            status = "NO_RECIPE"
            statusLabel = "! NO RECIPE"
            statusColor = colors.red
            statusPrio = 1
        else
            local _, miss = planProduction(id, need, false, stockInv, not isWoodSpecificItem(id))
            if not next(miss) then
                status = "CRAFTABLE"
                statusLabel = "+ CRAFTABLE"
                statusColor = colors.yellow
                statusPrio = 3
            else
                status = "NEED_RAW"
                statusLabel = "~ NEED RAW"
                statusColor = colors.orange
                statusPrio = 2
            end
        end

        local entry = {
            id = id,
            name = getItemDisplayName(id),
            need = need,
            stock = have,
            deficit = deficit,
            checked = raw.checked or false,
            hasRecipe = hasRec,
            status = status,
            statusLabel = statusLabel,
            statusColor = statusColor,
            statusPrio = statusPrio,
        }
        table.insert(ProjectState.items, entry)
        if status == "NO_RECIPE" then
            table.insert(ProjectState.missingRecipes, entry)
        end

        local simAvail = simStock[id] or 0
        local reserve = math.min(simAvail, need)
        simStock[id] = simAvail - reserve
        entry._remSimNeed = need - reserve
    end

    local rawMiss = {}
    local rawBlock = {}
    local simPlan = {}
    for _, entry in ipairs(ProjectState.items) do
        if entry._remSimNeed and entry._remSimNeed > 0 and entry.hasRecipe then
            calcNodes = 0
            calculateCraft(entry.id, entry._remSimNeed, simStock, rawMiss, rawBlock, simPlan, {}, false, not isWoodSpecificItem(entry.id))
        end
    end

    for mId, mShortage in pairs(rawMiss) do
        if mShortage and mShortage > 0 then
            local mStock = groupAvailable(mId, stockInv, false)
            table.insert(ProjectState.rawDeficits, {
                id = mId,
                name = getItemDisplayName(mId),
                stock = mStock,
                deficit = mShortage,
                need = mStock + mShortage,
            })
        end
    end
    table.sort(ProjectState.rawDeficits, function(a, b)
        if a.deficit ~= b.deficit then return a.deficit > b.deficit end
        return a.name < b.name
    end)
    table.sort(ProjectState.missingRecipes, function(a, b)
        if a.deficit ~= b.deficit then return a.deficit > b.deficit end
        return a.name < b.name
    end)
    sortProjectItems()
end

function scanProjectClipboard()
    local found, readError = readProjectClipboard()
    if not found then
        ProjectState.lastScanMsg = "ERR: " .. tostring(readError)
        ProjectState.lastScanColor = colors.red
        return false
    end

    local byId = {}
    local order = {}
    for _, pageIndex in ipairs(getSortedNumericKeys(found.pages)) do
        local page = found.pages[pageIndex]
        if type(page) == "table" then
            for _, lineIndex in ipairs(getSortedNumericKeys(page)) do
                local entry = page[lineIndex]
                if type(entry) == "table" then
                    local amount = tonumber(entry.amount) or 0
                    local itemId = nil
                    if type(entry.item) == "string" then
                        itemId = entry.item
                    elseif type(entry.item) == "table" then
                        itemId = entry.item.id or entry.item.name
                    end
                    local checked = entry.checked == true or entry.checked == 1
                        or entry.checked == "1" or entry.checked == "true"
                    local text = type(entry.text) == "string" and entry.text or ""

                    if amount > 0 and itemId and itemId ~= "" then
                        if not byId[itemId] then
                            byId[itemId] = {
                                id = itemId,
                                need = 0,
                                checked = checked,
                                text = text,
                            }
                            table.insert(order, itemId)
                        else
                            byId[itemId].checked = byId[itemId].checked and checked
                            if text ~= "" and text ~= byId[itemId].text then
                                byId[itemId].text = byId[itemId].text .. " | " .. text
                            end
                        end
                        byId[itemId].need = byId[itemId].need + amount
                    end
                end
            end
        end
    end

    ProjectState.rawClipboardItems = {}
    ProjectState.rawClipboardPages = found.pages
    ProjectState.clipboardSlot = found.slot
    for _, itemId in ipairs(order) do
        table.insert(ProjectState.rawClipboardItems, byId[itemId])
    end

    if #ProjectState.rawClipboardItems == 0 then
        ProjectState.hasScanned = false
        ProjectState.lastScanMsg = "Clipboard is empty (0 material entries)."
        ProjectState.lastScanColor = colors.yellow
        return false
    end

    ProjectState.hasScanned = true
    ProjectState.page = 1
    invalidateStockCache()
    refreshProjectAnalysis(getStorageInventoryCached())
    ProjectState.lastScanMsg = string.format("Scanned %d types (%d pcs) | Ready: %d/%d",
        ProjectState.totalTypes, ProjectState.totalPieces, ProjectState.readyTypes, ProjectState.totalTypes)
    ProjectState.lastScanColor = (ProjectState.readyTypes == ProjectState.totalTypes) and colors.lime or colors.cyan
    return true
end

function exportProjectToDest()
    if not ProjectState.hasScanned or #ProjectState.items == 0 then
        ProjectState.lastScanMsg = "Scan a clipboard first before exporting!"
        ProjectState.lastScanColor = colors.yellow
        return 0
    end
    getProjectDestinations()
    local dest = ProjectState.selectedDest
    if not dest or not peripheral.isPresent(dest) then
        ProjectState.lastScanMsg = "ERR: Destination storage not available!"
        ProjectState.lastScanColor = colors.red
        return 0
    end
    local destP = peripheral.wrap(dest)
    local destCounts = {}
    if destP and destP.list then
        local okL, listData = pcall(destP.list)
        if okL and type(listData) == "table" then
            for _, it in pairs(listData) do
                if it and it.name and it.count then
                    destCounts[it.name] = (destCounts[it.name] or 0) + it.count
                end
            end
        end
    end

    local totalMoved = 0
    local typesMoved = 0
    for _, entry in ipairs(ProjectState.items) do
        local alreadyInDest = destCounts[entry.id] or 0
        local toExport = math.max(0, entry.need - alreadyInDest)
        if toExport > 0 then
            local moved = 0
            if dest == Config.train_box then
                moved = deliverToTrainBox(entry.id, toExport)
            else
                moved = pushFromStorage(entry.id, toExport, dest, nil, false)
            end
            if moved > 0 then
                totalMoved = totalMoved + moved
                typesMoved = typesMoved + 1
            end
        end
    end

    if totalMoved > 0 then
        invalidateStockCache()
        refreshProjectAnalysis(getStorageInventoryCached())
        ProjectState.lastScanMsg = string.format("Exported %d pcs (%d types) -> %s",
            totalMoved, typesMoved, getMachineDisplay(dest))
        ProjectState.lastScanColor = colors.lime
    else
        ProjectState.lastScanMsg = "Nothing exported (already in DEST or 0 in stock)."
        ProjectState.lastScanColor = colors.yellow
    end
    return totalMoved
end

function drawProjectPickerPopup(w, h, touchZones, dests)
    if not ProjectState.pickerMode then return end

    for i = #touchZones, 1, -1 do
        local zid = touchZones[i].id or ""
        if zid:sub(1, 5) == "proj_" then
            table.remove(touchZones, i)
        end
    end

    local list = dests
    local curSel = ProjectState.selectedDest
    local titleStr = " SELECT DESTINATION STORAGE "

    local pW = math.min(w - 6, 62)
    local maxRows = math.max(4, math.min(10, h - 16))
    local pH = maxRows + 6
    local pX = math.max(2, math.floor((w - pW) / 2) + 1)
    local pY = math.max(9, math.floor((h - pH) / 2) + 1)

    for bgY = 9, h do
        table.insert(touchZones, 1, {id="proj_picker_close", x1=1, x2=w, y=bgY})
    end
    for sy = pY, pY + pH - 1 do
        table.insert(touchZones, 1, {id="popup_bg", x1=pX, x2=pX+pW-1, y=sy})
    end

    _bufFillRect(pX, pY, pW, pH, colors.gray)
    drawText(pX, pY, string.rep(" ", pW), colors.black, colors.cyan)
    drawText(pX + math.max(1, math.floor((pW - #titleStr) / 2)), pY, titleStr, colors.black, colors.cyan)

    local totalPages = math.max(1, math.ceil(#list / maxRows))
    if ProjectState.pickerPage > totalPages then ProjectState.pickerPage = totalPages end
    if ProjectState.pickerPage < 1 then ProjectState.pickerPage = 1 end

    local listTop = pY + 2
    if #list == 0 then
        local emptyMsg = "(No destination storages found)"
        drawText(pX + math.max(2, math.floor((pW - #emptyMsg) / 2)), listTop + 1, emptyMsg:sub(1, pW - 4), colors.lightGray, colors.gray)
    else
        local sIdx = (ProjectState.pickerPage - 1) * maxRows + 1
        local eIdx = math.min(#list, sIdx + maxRows - 1)
        for i = sIdx, eIdx do
            local rY = listTop + (i - sIdx)
            local pName = list[i]
            local isSel = (pName == curSel)
            local rowBg = isSel and colors.black or colors.gray
            if isSel then
                drawText(pX + 1, rY, string.rep(" ", pW - 2), colors.white, colors.black)
            end
            local mark = isSel and "(*) " or "( ) "
            local disp = getMachineDisplay(pName)
            local rightTag = pName == Config.train_box and "[TRAIN BOX]" or "[STORAGE]"
            local rightCol = pName == Config.train_box and colors.yellow or colors.cyan
            local maxDispW = math.max(8, pW - 6 - #mark - #rightTag)
            drawText(pX + 2, rY, mark, isSel and colors.lime or colors.lightGray, rowBg)
            drawText(pX + 2 + #mark, rY, disp:sub(1, maxDispW), isSel and colors.lime or colors.white, rowBg)
            drawText(pX + pW - 2 - #rightTag, rY, rightTag, rightCol, rowBg)
            table.insert(touchZones, 1, {id="proj_pick_dest", arg=pName, x1=pX+1, x2=pX+pW-2, y=rY})
        end
    end

    local navY = pY + pH - 2
    local prevS = " < "
    local nextS = " > "
    local pgS = string.format(" Page %d/%d ", ProjectState.pickerPage, totalPages)
    drawText(pX + 2, navY, prevS, ProjectState.pickerPage > 1 and colors.white or colors.gray, colors.lightGray)
    if ProjectState.pickerPage > 1 then
        table.insert(touchZones, 1, {id="proj_picker_prev", x1=pX+2, x2=pX+2+#prevS-1, y=navY})
    end
    drawText(pX + 2 + #prevS + 1, navY, pgS, colors.yellow, colors.gray)
    local nxX = pX + 2 + #prevS + 1 + #pgS + 1
    drawText(nxX, navY, nextS, ProjectState.pickerPage < totalPages and colors.white or colors.gray, colors.lightGray)
    if ProjectState.pickerPage < totalPages then
        table.insert(touchZones, 1, {id="proj_picker_next", x1=nxX, x2=nxX+#nextS-1, y=navY})
    end

    local canBtn = " [ CANCEL ] "
    local canX = pX + pW - #canBtn - 2
    drawText(canX, navY, canBtn, colors.white, colors.red)
    table.insert(touchZones, 1, {id="proj_picker_close", x1=canX, x2=canX+#canBtn-1, y=navY})
end

function drawProjectTab(w, h, stockInv, touchZones)
    local dests = getProjectDestinations()

    if not Config.project_chest or Config.project_chest == "" then
        ProjectState.pickerMode = nil
        local boxW = math.min(w - 6, 70)
        local boxH = 11
        local boxX = math.max(2, math.floor((w - boxW) / 2) + 1)
        local boxY = math.max(10, math.floor((h - boxH) / 2))
        _bufFillRect(boxX, boxY, boxW, boxH, colors.gray)
        drawText(boxX, boxY, "+" .. string.rep("-", boxW - 2) .. "+", colors.red, colors.gray)
        drawText(boxX, boxY + boxH - 1, "+" .. string.rep("-", boxW - 2) .. "+", colors.red, colors.gray)
        for ry = boxY + 1, boxY + boxH - 2 do
            drawText(boxX, ry, "|", colors.red, colors.gray)
            drawText(boxX + boxW - 1, ry, "|", colors.red, colors.gray)
        end

        local t1 = "[!] PROJECT CLIPBOARD CHEST NOT ASSIGNED"
        local t2 = "Project reads a Create Clipboard only from the assigned chest."
        local t3 = "1. Connect a chest to the wired modem network."
        local t4 = "2. In NETWORK, mark that chest with [PROJ]."
        drawText(boxX + math.max(2, math.floor((boxW - #t1) / 2)), boxY + 2, t1, colors.red, colors.gray)
        drawText(boxX + math.max(2, math.floor((boxW - #t2) / 2)), boxY + 4, t2:sub(1, boxW - 4), colors.white, colors.gray)
        drawText(boxX + math.max(2, math.floor((boxW - #t3) / 2)), boxY + 6, t3:sub(1, boxW - 4), colors.lightGray, colors.gray)
        drawText(boxX + math.max(2, math.floor((boxW - #t4) / 2)), boxY + 7, t4:sub(1, boxW - 4), colors.lightGray, colors.gray)

        local networkBtn = " [ OPEN NETWORK ] "
        local networkX = boxX + math.floor((boxW - #networkBtn) / 2)
        drawText(networkX, boxY + 9, networkBtn, colors.black, colors.lime)
        table.insert(touchZones, {id="proj_open_network", x1=networkX, x2=networkX+#networkBtn-1, y=boxY+9})
        return
    end

    if ProjectState.hasScanned and stockInv then
        local readyCnt = 0
        for _, it in ipairs(ProjectState.items) do
            local curHave = groupAvailable(it.id, stockInv, false)
            it.stock = curHave
            it.deficit = math.max(0, it.need - curHave)
            if it.deficit == 0 then
                it.status = "READY"
                it.statusLabel = "OK READY"
                it.statusColor = colors.lime
                it.statusPrio = 4
                readyCnt = readyCnt + 1
            elseif it.status == "READY" then
                if not it.hasRecipe then
                    it.status = "NO_RECIPE"
                    it.statusLabel = "! NO RECIPE"
                    it.statusColor = colors.red
                    it.statusPrio = 1
                else
                    it.status = "CRAFTABLE"
                    it.statusLabel = "+ CRAFTABLE"
                    it.statusColor = colors.yellow
                    it.statusPrio = 3
                end
            end
        end
        ProjectState.readyTypes = readyCnt
    end

    local row1Y = 9
    local scanBtn = " [ SCAN CLIPBOARD ] "
    drawText(2, row1Y, scanBtn, colors.black, colors.lime)
    table.insert(touchZones, {id="proj_scan", x1=2, x2=2+#scanBtn-1, y=row1Y})

    local srcDisp = getMachineDisplay(Config.project_chest)
    if #srcDisp > 14 then srcDisp = srcDisp:sub(1, 14) end
    local srcBtn = " [ " .. srcDisp .. " ] "
    local destDisp = ProjectState.selectedDest and getMachineDisplay(ProjectState.selectedDest) or "none"
    if #destDisp > 14 then destDisp = destDisp:sub(1, 14) end
    local destBtn = " [ " .. destDisp .. " ] "

    local rightBlockW = 5 + #srcBtn + 2 + 6 + #destBtn
    local srcLblX = w - rightBlockW
    local srcColor = peripheral.isPresent(Config.project_chest) and colors.lime or colors.red
    drawText(srcLblX, row1Y, "SRC: ", colors.gray, colors.black)
    drawText(srcLblX + 5, row1Y, srcBtn, srcColor, colors.gray)

    local destLblX = srcLblX + 5 + #srcBtn + 2
    drawText(destLblX, row1Y, "DEST: ", colors.gray, colors.black)
    drawText(destLblX + 6, row1Y, destBtn, colors.black, colors.cyan)
    table.insert(touchZones, {id="proj_open_dest_picker", x1=destLblX, x2=w, y=row1Y})

    local msgX = 2 + #scanBtn + 1
    local maxMsgW = math.max(0, srcLblX - msgX - 2)
    if maxMsgW > 4 and ProjectState.lastScanMsg then
        drawText(msgX, row1Y, ProjectState.lastScanMsg:sub(1, maxMsgW), ProjectState.lastScanColor or colors.lightGray, colors.black)
    end

    local actY = 11
    local hasCraftableMissing = false
    for _, it in ipairs(ProjectState.items) do
        if it.deficit > 0 and it.hasRecipe then hasCraftableMissing = true; break end
    end

    local qAllBtn = " [ +QUEUE MISSING ] "
    local cAllBtn = " [ CRAFT MISSING ] "
    local expBtn  = " [ EXPORT READY -> DEST ] "
    local clrBtn  = " [ CLEAR PROJECT ] "

    local ax = 2
    drawText(ax, actY, qAllBtn, hasCraftableMissing and colors.black or colors.lightGray, hasCraftableMissing and colors.yellow or colors.gray)
    if hasCraftableMissing then
        table.insert(touchZones, {id="proj_queue_all", x1=ax, x2=ax+#qAllBtn-1, y=actY})
    end
    ax = ax + #qAllBtn + 2

    drawText(ax, actY, cAllBtn, hasCraftableMissing and colors.black or colors.lightGray, hasCraftableMissing and colors.lime or colors.gray)
    if hasCraftableMissing then
        table.insert(touchZones, {id="proj_craft_all", x1=ax, x2=ax+#cAllBtn-1, y=actY})
    end
    ax = ax + #cAllBtn + 2

    local canExp = ProjectState.hasScanned and ProjectState.selectedDest ~= nil
    drawText(ax, actY, expBtn, canExp and colors.black or colors.lightGray, canExp and colors.cyan or colors.gray)
    if canExp then
        table.insert(touchZones, {id="proj_export_dest", x1=ax, x2=ax+#expBtn-1, y=actY})
    end
    ax = ax + #expBtn + 2

    if ProjectState.hasScanned then
        local clrX = math.max(ax, w - #clrBtn)
        drawText(clrX, actY, clrBtn, colors.white, colors.red)
        table.insert(touchZones, {id="proj_clear", x1=clrX, x2=clrX+#clrBtn-1, y=actY})
    end

    drawText(1, 12, string.rep("-", w), colors.gray)

    local row2Y = 13
    local st = ProjectState.subTab or "CHECKLIST"
    local tab1 = string.format(" CHECKLIST (%d) ", #ProjectState.items)
    local tab2 = string.format(" NO RECIPE (%d) ", #ProjectState.missingRecipes)
    local tab3 = string.format(" RAW DEFICIT (%d) ", #ProjectState.rawDeficits)

    local tx = 2
    drawText(tx, row2Y, tab1, st == "CHECKLIST" and colors.black or colors.white, st == "CHECKLIST" and colors.lime or colors.gray)
    table.insert(touchZones, {id="proj_subtab", arg="CHECKLIST", x1=tx, x2=tx+#tab1-1, y=row2Y})
    tx = tx + #tab1 + 2

    local t2Bg = (st == "NO_RECIPE") and colors.red or (#ProjectState.missingRecipes > 0 and colors.orange or colors.gray)
    local t2Fg = (st == "NO_RECIPE") and colors.white or colors.black
    if #ProjectState.missingRecipes == 0 and st ~= "NO_RECIPE" then t2Fg = colors.white end
    drawText(tx, row2Y, tab2, t2Fg, t2Bg)
    table.insert(touchZones, {id="proj_subtab", arg="NO_RECIPE", x1=tx, x2=tx+#tab2-1, y=row2Y})
    tx = tx + #tab2 + 2

    local t3Bg = (st == "RAW_DEFICIT") and colors.orange or colors.gray
    local t3Fg = (st == "RAW_DEFICIT") and colors.black or colors.white
    drawText(tx, row2Y, tab3, t3Fg, t3Bg)
    table.insert(touchZones, {id="proj_subtab", arg="RAW_DEFICIT", x1=tx, x2=tx+#tab3-1, y=row2Y})

    if st == "CHECKLIST" then
        local sortLabels = {
            STATUS = "STATUS (PROBLEM)",
            STATUS_REV = "STATUS (READY)",
            DEFICIT = "DEFICIT (HIGH)",
            NAME = "ITEM NAME (A-Z)",
        }
        local sLbl = sortLabels[ProjectState.sortMode] or "STATUS"
        local sortBtn = " " .. sLbl .. " "
        local sortX = w - #sortBtn - 6
        drawText(sortX, row2Y, "SORT: ", colors.gray, colors.black)
        drawText(sortX + 6, row2Y, sortBtn, colors.black, colors.yellow)
        table.insert(touchZones, {id="proj_cycle_sort", x1=sortX, x2=w, y=row2Y})
    end

    drawText(1, 14, string.rep("-", w), colors.gray)

    local hdrY = 15
    local colNeed = w - 46
    local colStock = w - 37
    local colDef = w - 28
    local colStat = w - 19
    local colAct = w - 6

    if st == "CHECKLIST" then
        drawText(2, hdrY, "ITEM NAME", colors.gray)
        drawText(colNeed, hdrY, "NEED", colors.gray)
        drawText(colStock, hdrY, "STOCK", colors.gray)
        drawText(colDef, hdrY, "DEFICIT", colors.gray)
        drawText(colStat, hdrY, "STATUS", colors.gray)
        drawText(colAct, hdrY, "ACTION", colors.gray)
    elseif st == "NO_RECIPE" then
        drawText(2, hdrY, "UNCRAFTABLE ITEM", colors.gray)
        drawText(math.min(34, colNeed - 20), hdrY, "ITEM ID", colors.gray)
        drawText(colNeed, hdrY, "NEED", colors.gray)
        drawText(colStock, hdrY, "STOCK", colors.gray)
        drawText(colDef, hdrY, "MISSING", colors.gray)
        drawText(colStat, hdrY, "NOTE", colors.gray)
    else
        drawText(2, hdrY, "BASE RAW MATERIAL", colors.gray)
        drawText(math.min(34, colStock - 20), hdrY, "ITEM ID", colors.gray)
        drawText(colStock, hdrY, "IN STOCK", colors.gray)
        drawText(colDef, hdrY, "SHORTAGE", colors.gray)
        drawText(colStat, hdrY, "STATUS", colors.gray)
    end
    drawText(1, 16, string.rep("-", w), colors.gray)

    local listStartY = 17
    local listEndY = h - 3
    local maxRows = math.max(1, listEndY - listStartY + 1)

    local activeList = ProjectState.items
    if st == "NO_RECIPE" then
        activeList = ProjectState.missingRecipes
    elseif st == "RAW_DEFICIT" then
        activeList = ProjectState.rawDeficits
    end

    local totalPages = math.max(1, math.ceil(#activeList / maxRows))
    if ProjectState.page > totalPages then ProjectState.page = totalPages end
    if ProjectState.page < 1 then ProjectState.page = 1 end

    if not ProjectState.hasScanned then
        local msg = "No clipboard scanned yet. Put a Create Clipboard in the assigned chest and tap [SCAN CLIPBOARD]."
        drawText(math.max(2, math.floor((w - #msg) / 2)), listStartY + 3, msg:sub(1, w - 4), colors.lightGray, colors.black)
    elseif #activeList == 0 then
        local emptyMsg = "No items in this view."
        if st == "NO_RECIPE" then
            emptyMsg = "All required schematic items have known recipes or are already in stock!"
        elseif st == "RAW_DEFICIT" then
            emptyMsg = "No raw material shortage! Warehouse has enough base resources."
        end
        drawText(math.max(2, math.floor((w - #emptyMsg) / 2)), listStartY + 3, emptyMsg:sub(1, w - 4), colors.lime, colors.black)
    else
        local startIdx = (ProjectState.page - 1) * maxRows + 1
        local endIdx = math.min(#activeList, startIdx + maxRows - 1)
        for idx = startIdx, endIdx do
            local rowY = listStartY + (idx - startIdx)
            local rowBg = (idx % 2 == 0) and colors.gray or colors.black
            if rowBg == colors.gray then
                drawText(1, rowY, string.rep(" ", w), colors.white, colors.gray)
            end
            local it = activeList[idx]
            if st == "CHECKLIST" then
                local maxNameW = math.max(10, colNeed - 4)
                local checkPrefix = it.checked and "[x] " or "[ ] "
                local dispName = (checkPrefix .. it.name):sub(1, maxNameW)
                local nameCol = (it.deficit == 0 or it.checked) and colors.lime or colors.white
                drawText(2, rowY, dispName, nameCol, rowBg)
                drawText(colNeed, rowY, string.format("%4d", it.need), colors.white, rowBg)
                drawText(colStock, rowY, string.format("%5d", it.stock), colors.cyan, rowBg)
                drawText(colDef, rowY, string.format("%7d", it.deficit), it.deficit > 0 and colors.yellow or colors.lightGray, rowBg)
                drawText(colStat, rowY, it.statusLabel, it.statusColor, rowBg)
                if it.deficit == 0 then
                    drawText(colAct, rowY, "[DONE]", colors.lime, rowBg)
                elseif it.hasRecipe then
                    drawText(colAct, rowY, "[CRAFT]", colors.black, colors.white)
                    table.insert(touchZones, {id="proj_craft_one", arg=it.id, x1=colAct, x2=colAct+6, y=rowY})
                else
                    drawText(colAct, rowY, "  --  ", colors.lightGray, rowBg)
                end
            elseif st == "NO_RECIPE" then
                local idColX = math.min(34, colNeed - 20)
                drawText(2, rowY, it.name:sub(1, idColX - 3), colors.white, rowBg)
                drawText(idColX, rowY, it.id:sub(1, colNeed - idColX - 2), colors.lightGray, rowBg)
                drawText(colNeed, rowY, string.format("%4d", it.need), colors.white, rowBg)
                drawText(colStock, rowY, string.format("%5d", it.stock), colors.cyan, rowBg)
                drawText(colDef, rowY, string.format("%7d", it.deficit), colors.red, rowBg)
                drawText(colStat, rowY, "Add manually", colors.orange, rowBg)
            else
                local idColX = math.min(34, colStock - 20)
                drawText(2, rowY, it.name:sub(1, idColX - 3), colors.white, rowBg)
                drawText(idColX, rowY, it.id:sub(1, colStock - idColX - 2), colors.lightGray, rowBg)
                drawText(colStock, rowY, string.format("%8d", it.stock), colors.cyan, rowBg)
                drawText(colDef, rowY, string.format("%8d", it.deficit), colors.orange, rowBg)
                drawText(colStat, rowY, "! SHORTAGE", colors.red, rowBg)
            end
        end
    end

    local navY = h - 1
    drawText(1, navY - 1, string.rep("-", w), colors.gray)
    local pageStr = string.format(" PAGE %d OF %d ", ProjectState.page, totalPages)
    local prevStr = " [ PREV ] "
    local nextStr = " [ NEXT ] "
    local navStartX = math.max(2, math.floor((w - (#prevStr + #pageStr + #nextStr + 4)) / 2))
    drawText(navStartX, navY, prevStr, ProjectState.page > 1 and colors.white or colors.lightGray, colors.gray)
    drawText(navStartX + #prevStr + 2, navY, pageStr, colors.lime, colors.black)
    local nextXPos = navStartX + #prevStr + #pageStr + 4
    drawText(nextXPos, navY, nextStr, ProjectState.page < totalPages and colors.white or colors.lightGray, colors.gray)
    if ProjectState.page > 1 then
        table.insert(touchZones, {id="proj_prev_page", x1=navStartX, x2=navStartX+#prevStr-1, y=navY})
    end
    if ProjectState.page < totalPages then
        table.insert(touchZones, {id="proj_next_page", x1=nextXPos, x2=nextXPos+#nextStr-1, y=navY})
    end

    if ProjectState.pickerMode then
        drawProjectPickerPopup(w, h, touchZones, dests)
    end
end

function handleProjectTouchZone(zone)
    if zone.id == "proj_open_network" then
        currentTab = "NETWORK"
        currentPage = 1
    elseif zone.id == "proj_open_dest_picker" then
        ProjectState.pickerMode = "DEST"
        ProjectState.pickerPage = 1
    elseif zone.id == "proj_picker_close" then
        ProjectState.pickerMode = nil
    elseif zone.id == "proj_picker_prev" then
        ProjectState.pickerPage = math.max(1, ProjectState.pickerPage - 1)
    elseif zone.id == "proj_picker_next" then
        ProjectState.pickerPage = ProjectState.pickerPage + 1
    elseif zone.id == "proj_pick_dest" then
        ProjectState.selectedDest = zone.arg
        Config.project_dest = zone.arg
        saveData()
        ProjectState.pickerMode = nil
        ProjectState.lastScanMsg = "Destination: " .. getMachineDisplay(zone.arg)
        ProjectState.lastScanColor = colors.cyan
    elseif zone.id == "proj_clear" then
        clearProjectData()
    elseif zone.id == "proj_scan" then
        scanProjectClipboard()
    elseif zone.id == "proj_subtab" then
        ProjectState.subTab = zone.arg
        ProjectState.page = 1
    elseif zone.id == "proj_cycle_sort" then
        local order = { "STATUS", "STATUS_REV", "DEFICIT", "NAME" }
        local cur = 1
        for i, m in ipairs(order) do
            if m == ProjectState.sortMode then cur = i; break end
        end
        ProjectState.sortMode = order[(cur % #order) + 1]
        sortProjectItems()
        ProjectState.page = 1
    elseif zone.id == "proj_prev_page" then
        ProjectState.page = math.max(1, ProjectState.page - 1)
    elseif zone.id == "proj_next_page" then
        ProjectState.page = ProjectState.page + 1
    elseif zone.id == "proj_export_dest" then
        exportProjectToDest()
    elseif zone.id == "proj_queue_all" then
        local added = 0
        for _, it in ipairs(ProjectState.items) do
            if it.deficit > 0 and it.hasRecipe then
                local foundQ = false
                for _, qe in ipairs(craftQueue) do
                    if qe.name == it.id and qe.kind == "item" then
                        qe.qty = math.max(qe.qty, it.need)
                        qe.failed = nil
                        foundQ = true
                        break
                    end
                end
                if not foundQ then
                    if Recipes[it.id] or (AltRecipes and AltRecipes[it.id] and #AltRecipes[it.id] > 0) then
                        table.insert(craftQueue, { kind = "item", name = it.id, qty = it.need })
                        added = added + 1
                    elseif findFluidItemProducer then
                        local frec = findFluidItemProducer(it.id)
                        if frec then
                            table.insert(craftQueue, { kind = "fluid", name = it.id, qty = it.deficit, recipe = frec, isItem = true })
                            added = added + 1
                        end
                    end
                else
                    added = added + 1
                end
            end
        end
        ProjectState.lastScanMsg = string.format("Added %d project items to Craft Queue!", added)
        ProjectState.lastScanColor = colors.lime
    elseif zone.id == "proj_craft_one" then
        local targetId = zone.arg
        local targetEntry = nil
        for _, it in ipairs(ProjectState.items) do
            if it.id == targetId then targetEntry = it; break end
        end
        if targetEntry and targetEntry.deficit > 0 and targetEntry.hasRecipe then
            systemStatus = "MANUAL_CRAFT"
            drawInterface()
            local qe
            if Recipes[targetId] or (AltRecipes and AltRecipes[targetId] and #AltRecipes[targetId] > 0) then
                qe = { kind = "item", name = targetId, qty = targetEntry.need }
            elseif findFluidItemProducer then
                local frec = findFluidItemProducer(targetId)
                if frec then
                    qe = { kind = "fluid", name = targetId, qty = targetEntry.deficit, recipe = frec, isItem = true }
                end
            end
            if qe then
                local okC, reason = queueRunOne(qe)
                systemStatus = "IDLE"
                invalidateStockCache()
                refreshProjectAnalysis(getStorageInventoryCached())
                if okC then
                    ProjectState.lastScanMsg = "Crafted: " .. targetEntry.name
                    ProjectState.lastScanColor = colors.lime
                else
                    local rMsg = (type(reason) == "table" and reason[1]) or "Craft failed"
                    ProjectState.lastScanMsg = "FAIL " .. targetEntry.name .. ": " .. tostring(rMsg)
                    ProjectState.lastScanColor = colors.red
                end
            else
                systemStatus = "IDLE"
            end
        end
    elseif zone.id == "proj_craft_all" then
        local toCraft = {}
        for _, it in ipairs(ProjectState.items) do
            if it.deficit > 0 and it.hasRecipe then
                table.insert(toCraft, { id = it.id, name = it.name, need = it.need, deficit = it.deficit })
            end
        end
        if #toCraft > 0 then
            systemStatus = "MANUAL_CRAFT"
            cancelCrafting = false
            local okCount = 0
            local failCount = 0
            for idx, job in ipairs(toCraft) do
                if cancelCrafting then break end
                ProjectState.lastScanMsg = string.format("Crafting (%d/%d): %s...", idx, #toCraft, job.name)
                ProjectState.lastScanColor = colors.yellow
                drawInterface()
                local qe
                if Recipes[job.id] or (AltRecipes and AltRecipes[job.id] and #AltRecipes[job.id] > 0) then
                    qe = { kind = "item", name = job.id, qty = job.need }
                elseif findFluidItemProducer then
                    local frec = findFluidItemProducer(job.id)
                    if frec then
                        qe = { kind = "fluid", name = job.id, qty = job.deficit, recipe = frec, isItem = true }
                    end
                end
                if qe then
                    local okC = queueRunOne(qe)
                    if okC then okCount = okCount + 1 else failCount = failCount + 1 end
                end
                invalidateStockCache()
                refreshProjectAnalysis(getStorageInventoryCached())
                drawInterface()
            end
            systemStatus = "IDLE"
            craftErrorLines = {}; craftErrorTitle = nil
            ProjectState.lastScanMsg = string.format("Batch done: %d crafted, %d failed | Ready: %d/%d",
                okCount, failCount, ProjectState.readyTypes, ProjectState.totalTypes)
            ProjectState.lastScanColor = (failCount == 0) and colors.lime or colors.orange
        end
    end
end

drawInterface = function()
    local w, h = monitor.getSize()
    _bufInit(w, h)
    local popupRect = nil
    local popupZoneStart = 1

    -- Credit / watermark
    local creditStr = "Modified by Mstr_Max"
    drawText(math.max(1, w - #creditStr), 1, creditStr, colors.gray, colors.black)

    -- Render logo
    do
        local logoStr = ">>[ A . E . G . I . S ]<<"
        local logoX = math.floor((w - #logoStr) / 2) + 1
        if logoX < 1 then logoX = 1 end
        drawText(logoX, 2, ">>[ ", colors.lime, colors.black)
        drawText(logoX + 4, 2, "A . E . G . I . S", colors.white, colors.black)
        drawText(logoX + 21, 2, " ]<<", colors.lime, colors.black)
    end

    local stockInv
    stockInv = _diB16(w, stockInv)
    drawText(1, 5, string.rep("-", w), colors.gray)

    -- Tabs
    local tabY = 6
    local touchZones = {}
    local displayTab = (currentTab == "QUANTITY_PICKER") and qtyOriginTab or currentTab

    do
        local totalTabsW = 93
        local nextX = math.max(1, math.floor((w - totalTabsW) / 2) + 1)
        nextX = drawTabButton(nextX, tabY, "RECIPES",  displayTab, touchZones)
        nextX = drawTabButton(nextX, tabY, "STOCK",    displayTab, touchZones)
        nextX = drawTabButton(nextX, tabY, "PROJECT",  displayTab, touchZones)
        nextX = drawTabButton(nextX, tabY, "LOGISTIC", displayTab, touchZones)
        nextX = drawTabButton(nextX, tabY, "KEEP",     displayTab, touchZones)
        nextX = drawTabButton(nextX, tabY, "+RECIPES", displayTab, touchZones)
        nextX = drawTabButton(nextX, tabY, "GROUPS",   displayTab, touchZones)
        nextX = drawTabButton(nextX, tabY, "VAULTS",   displayTab, touchZones)
        nextX = drawTabButton(nextX, tabY, "NETWORK",  displayTab, touchZones)
        nextX = drawTabButton(nextX, tabY, "ERRORS",   displayTab, touchZones)
    end
    drawText(1, tabY + 2, string.rep("-", w), colors.gray)

    -- Bottom status bar
    if Config.autostock_paused then
        drawText(2, h, "[AUTOSTOCK PAUSED]", colors.white, colors.red)
    else
        if autostockCurrentItem ~= "" then
            local asName = autostockCurrentItem:match(":(.+)$") or autostockCurrentItem
            local asStr = "[AS> " .. asName .. "]"
            drawText(2, h, asStr:sub(1, math.floor(w / 2) - 2), colors.lime, colors.black)
        end
        local statusStr = "[SYS IDLE]"
        local statusColor = colors.gray
        if systemStatus == "MANUAL_CRAFT" then
            statusStr = "[MANUAL CRAFTING...]"
            statusColor = colors.yellow
        elseif systemStatus == "AUTO_CRAFT" then
            statusStr = "[AUTOCRAFT ACTIVE]"
            statusColor = colors.lime
        elseif systemStatus == "DEFRAG" then
            statusStr = "[DEFRAGGING...]"
            statusColor = colors.orange
        elseif systemStatus == "RESCAN" then
            statusStr = "[RESCANNING...]"
            statusColor = colors.cyan
        end
        drawText(w - #statusStr - 1, h, statusStr, statusColor, colors.black)
    end

    -- Render active tab
    if displayTab == "RECIPES" then
        _diB15(w, h, stockInv, touchZones)
    elseif displayTab == "ALT_VIEW" then
        _diB12(w, h, touchZones)
    elseif displayTab == "KEEP" then
        _diB7(w, h, stockInv, touchZones)
    elseif displayTab == "STOCK" then
        _diB6(w, h, stockInv, touchZones)
    elseif displayTab == "PROJECT" then
        drawProjectTab(w, h, stockInv, touchZones)
    elseif displayTab == "+RECIPES" then
        _diB2(w, h, touchZones)
    elseif displayTab == "GROUPS" then
        _diB1(w, h, touchZones)
    elseif displayTab == "NETWORK" then
        _diB13(w, h, touchZones)
    elseif displayTab == "LOGISTIC" then
        _diB11(w, h, touchZones)
    elseif displayTab == "VAULTS" then
        _diBVaults(w, h, touchZones)
    elseif displayTab == "ERRORS" then
        drawErrorsTab(w, h, touchZones)
    end

    -- Render popup windows
    if mgmtPopup then
        if mgmtPopup.mode == "edit" then
            local step = mgmtPopup.step or "main"
            if step == "main" then
                popupRect, popupZoneStart = _diB17(w, h, touchZones, popupRect, popupZoneStart)
            elseif step == "input_select" then
                popupRect, popupZoneStart = _diB18(w, h, touchZones, popupRect, popupZoneStart)
            elseif step == "item_select" then
                local inIsStg3 = (mgmtPopup.condPickRuleIdx ~= nil) or (#(mgmtPopup.inputs or {}) == 0)
                local inputItemsList = {}
                if mgmtPopup.fluid then
                    if inIsStg3 then
                        for fN3, fC3 in pairs(mgmtFluidStockSnap()) do
                            table.insert(inputItemsList, {name=fN3, count=fC3})
                        end
                    else
                        for fN3, fC3 in pairs(tankContents(mgmtPopup.input)) do
                            table.insert(inputItemsList, {name=fN3, count=fC3})
                        end
                    end
                    table.sort(inputItemsList, function(a,b) return naturalSortCompare(a.name, b.name) end)
                elseif inIsStg3 then
                    local snap3 = getStorageInventoryCached()
                    for iN3, iC3 in pairs(snap3) do
                        table.insert(inputItemsList, {name=iN3, count=iC3})
                    end
                    table.sort(inputItemsList, function(a,b) return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name)) end)
                else
                    local byName2 = {}
                    for _, inNm in ipairs(mgmtPopup.inputs or {}) do
                        local inputPeri2 = peripheral.wrap(inNm)
                        if inputPeri2 and inputPeri2.list then
                            local ok2b, items2 = pcall(inputPeri2.list)
                            if ok2b and items2 then
                                for slot2, it2 in pairs(items2) do
                                    if it2 then
                                        local iKey2 = makeItemKey(it2.name, it2.nbt)
                                        byName2[iKey2] = (byName2[iKey2] or 0) + it2.count
                                        if it2.nbt and it2.nbt ~= "" and not isValidDisplayName(ItemDisplayNames[iKey2]) then
                                            resolveItemDisplayName(inputPeri2, slot2, iKey2)
                                        end
                                    end
                                end
                            end
                        end
                    end
                    for iName2, iCnt2 in pairs(byName2) do
                        table.insert(inputItemsList, {name=iName2, count=iCnt2})
                    end
                    table.sort(inputItemsList, function(a,b) return naturalSortCompare(getItemDisplayName(a.name), getItemDisplayName(b.name)) end)
                end

                local srch3 = mgmtItemSearch:lower()
                local filteredItems = {}
                for _, itF in ipairs(inputItemsList) do
                    local dispF = (getItemDisplayName(itF.name) or ""):lower()
                    local rawF  = (itF.name or ""):lower()
                    if srch3 == "" or dispF:find(srch3, 1, true) or rawF:find(srch3, 1, true) then
                        table.insert(filteredItems, itF)
                    end
                end

                local pW3 = math.min(w - 6, 70)
                local pH3 = math.min(h - 4, 18)
                local pX3 = math.floor((w - pW3) / 2) + 1
                local pY3 = math.floor((h - pH3) / 2) + 1
                local cols3 = 3
                local colW3 = math.floor((pW3 - 2) / cols3)
                local listTop3 = pY3 + 2
                local maxRows3 = pH3 - 5
                local perPage3 = cols3 * maxRows3
                local iPage2  = mgmtPopup.itemPage or 1
                local iTotal2 = math.max(1, math.ceil(#filteredItems / perPage3))
                if iPage2 > iTotal2 then iPage2 = iTotal2; mgmtPopup.itemPage = iPage2 end
                local iStart2 = (iPage2 - 1) * perPage3 + 1
                local iEnd2   = math.min(iStart2 + perPage3 - 1, #filteredItems)

                popupZoneStart = #touchZones + 1
                popupRect = {x1=pX3, x2=pX3+pW3-1, y1=pY3, y2=pY3+pH3-1}
                _bufFillRect(pX3, pY3, pW3, pH3, colors.gray)
                _bufFillRect(pX3, pY3, pW3, 1, colors.lime)

                local inpShort2 = inIsStg3 and "STORAGE" or getMachineDisplay(mgmtPopup.input)
                local hdr3
                if mgmtPopup.condPickRuleIdx then
                    hdr3 = mgmtPopup.fluid and " PICK CONDITION FLUID " or " PICK CONDITION ITEM "
                elseif mgmtPopup.fluid then
                    hdr3 = " ADD FLUID FROM: " .. inpShort2:upper():sub(1, pW3 - 20) .. " "
                else
                    hdr3 = " ADD ITEM FROM: " .. inpShort2:upper():sub(1, pW3 - 20) .. " "
                end
                drawText(pX3 + math.floor((pW3 - #hdr3) / 2), pY3, hdr3, colors.black, colors.lime)

                for ci = 1, cols3 - 1 do
                    local sepX = pX3 + 1 + ci * colW3
                    for ry = 0, maxRows3 - 1 do
                        drawText(sepX, listTop3 + ry, "|", colors.lightGray, colors.gray)
                    end
                end

                if #filteredItems == 0 then
                    local emptyMsg = (srch3 ~= "") and "(no matches)" or "(input empty or unavailable)"
                    drawText(pX3 + math.floor((pW3 - #emptyMsg) / 2), pY3 + math.floor(pH3 / 2), emptyMsg, colors.lightGray, colors.gray)
                else
                    for ii2 = iStart2, iEnd2 do
                        local localIdx = ii2 - iStart2
                        local col = math.floor(localIdx / maxRows3)
                        local row = localIdx % maxRows3
                        local cellX = pX3 + 2 + col * colW3
                        local cellY = listTop3 + row
                        local itm2 = filteredItems[ii2]
                        local cntS2 = tostring(itm2.count)
                        local nameMax = colW3 - #cntS2 - 3
                        local iShort2 = getItemDisplayName(itm2.name)
                        if #iShort2 > nameMax then iShort2 = iShort2:sub(1, nameMax) end
                        local hasRule2 = false
                        if not mgmtPopup.condPickRuleIdx then
                            for _, r2 in ipairs(mgmtPopup.rules or {}) do
                                if r2.item == itm2.name then hasRule2 = true; break end
                            end
                        end
                        local nameColor = hasRule2 and colors.orange or colors.white
                        drawText(cellX, cellY, iShort2, nameColor, colors.gray)
                        drawText(cellX + colW3 - #cntS2 - 2, cellY, cntS2, colors.yellow, colors.gray)
                        if not hasRule2 then
                            table.insert(touchZones, {id="mgmt_add_rule", arg=itm2.name, x1=cellX, x2=cellX+colW3-2, y=cellY})
                        end
                    end
                end

                drawText(pX3 + 1, pY3 + pH3 - 2, string.rep("-", pW3 - 2), colors.lightGray, colors.gray)
                local navY3 = pY3 + pH3 - 1

                local arrL3 = " [ < ] "; local arrR3 = " [ > ] "
                drawText(pX3 + 2, navY3, arrL3, iPage2 > 1 and colors.white or colors.lightGray, colors.gray)
                if iPage2 > 1 then
                    table.insert(touchZones, {id="mgmt_item_prev", x1=pX3+2, x2=pX3+2+#arrL3-1, y=navY3})
                end
                local pgInfo3 = string.format(" %d/%d ", iPage2, iTotal2)
                drawText(pX3 + 2 + #arrL3, navY3, pgInfo3, colors.yellow, colors.gray)
                local rx3 = pX3 + 2 + #arrL3 + #pgInfo3
                drawText(rx3, navY3, arrR3, iPage2 < iTotal2 and colors.white or colors.lightGray, colors.gray)
                if iPage2 < iTotal2 then
                    table.insert(touchZones, {id="mgmt_item_next", x1=rx3, x2=rx3+#arrR3-1, y=navY3})
                end
                local navEnd3 = rx3 + #arrR3

                local cBtn3 = " [ CANCEL ] "
                local cBtnX3 = pX3 + pW3 - #cBtn3 - 2
                drawText(cBtnX3, navY3, cBtn3, colors.white, colors.red)
                table.insert(touchZones, {id="mgmt_item_cancel", x1=cBtnX3, x2=cBtnX3+#cBtn3-1, y=navY3})

                local srchCur3 = mgmtItemSearch or ""
                local hasClr3 = (srchCur3 ~= "")
                local availW3 = (cBtnX3 - 1) - (navEnd3 + 1)
                local maxBoxW3 = math.max(6, availW3 - 10 - (hasClr3 and 4 or 0))
                local srchDisp3 = (srchCur3 == "") and "<type name...>" or srchCur3
                if #srchDisp3 > maxBoxW3 then srchDisp3 = srchDisp3:sub(1, maxBoxW3) end
                local srchBox3 = "[ " .. srchDisp3 .. " ]"
                local srchFullW3 = 6 + #srchBox3 + (hasClr3 and 4 or 0)
                local srchX3 = navEnd3 + math.max(1, math.floor((availW3 - srchFullW3) / 2))
                local sFg3 = mgmtItemSearchActive and colors.black or (srchCur3 == "" and colors.gray or colors.white)
                local sBg3 = mgmtItemSearchActive and colors.white or colors.lightGray
                drawText(srchX3, navY3, "FIND: ", colors.lightGray, colors.gray)
                drawText(srchX3 + 6, navY3, srchBox3, sFg3, sBg3)
                table.insert(touchZones, {id="mgmt_search_focus", x1=srchX3, x2=srchX3+6+#srchBox3-1, y=navY3})
                if hasClr3 then
                    local clrBtn3 = " [X]"
                    drawText(srchX3 + 6 + #srchBox3, navY3, clrBtn3, colors.white, colors.red)
                    table.insert(touchZones, {id="mgmt_search_clear", x1=srchX3+6+#srchBox3, x2=srchX3+6+#srchBox3+#clrBtn3-1, y=navY3})
                end
            elseif step == "output_select" then
                popupRect, popupZoneStart = _diB19(w, h, touchZones, popupRect, popupZoneStart)
            end
        elseif mgmtPopup.mode == "view_input" then
            local grp2 = MgmtGroups[mgmtPopup.groupIdx]
            if grp2 then
                popupRect, popupZoneStart = _diB26(w, grp2, h, touchZones, popupRect, popupZoneStart)
            end
        end
    elseif currentTab == "QUANTITY_PICKER" then
        popupRect = _diB9(w, h, stockInv, touchZones, popupRect)
    elseif craftQueuePopup then
        popupRect = _diQueuePopup(w, h, touchZones, popupRect)
    elseif historyPopup then
        popupRect = _diB10(w, h, stockInv, touchZones, popupRect)
    elseif craftCompletePopup then
        popupRect = _diB22(w, h, touchZones, popupRect)
    elseif recipeEditPopup then
        popupRect = _diB4(w, h, touchZones, popupRect)
    elseif vaultOpPopup then
        popupRect = _diBVaultOpPopup(w, h, touchZones, popupRect)
    elseif fluidRecipePicker then
        popupRect = _diB20(w, h, touchZones, popupRect)
    elseif displayCtx and not displayCtx.done then
        popupRect = _diParallelProgressPopup(w, h, touchZones, popupRect, displayCtx)
    elseif remotePopup then
        popupRect = _diRemotePopup(w, h, touchZones, popupRect)
    elseif networkFilterPopup then
        popupRect = _diNetworkFilterPopup(w, h, touchZones, popupRect)
    elseif custGrpPopup then
        popupRect, popupZoneStart = _diCustGrpPopup(w, h, touchZones, popupRect, popupZoneStart)
    elseif machineInfoPopup then
        local miItem  = machineInfoPopup.item
        local miMach  = machineInfoPopup.machineName or "?"
        local sName   = miItem:match(":(.+)$") or miItem
        local pW2 = math.min(w - 4, 50)
        local pX2 = math.floor((w - pW2) / 2) + 1
        local pH2 = 7
        local pY2 = math.floor((h - pH2) / 2) + 1
        popupRect = {x1=pX2, x2=pX2+pW2-1, y1=pY2, y2=pY2+pH2-1}
        _bufFillRect(pX2, pY2, pW2, pH2, colors.gray)
        local hdrM = " MACHINE NOT FOUND "
        drawText(pX2 + math.floor((pW2 - #hdrM) / 2), pY2, hdrM, colors.black, colors.orange)
        drawText(pX2 + 2, pY2 + 2, ("Recipe:  " .. sName):sub(1, pW2 - 4),       colors.white,     colors.gray)
        drawText(pX2 + 2, pY2 + 3, ("Machine: " .. getMachineDisplay(miMach)):sub(1, pW2 - 4),  colors.orange, colors.gray)
        drawText(pX2 + 2, pY2 + 4, "Not connected to the network.",             colors.lightGray, colors.gray)
        local clsM = " [ CLOSE ] "
        local clsMX = pX2 + math.floor((pW2 - #clsM) / 2)
        drawText(clsMX, pY2 + pH2 - 1, clsM, colors.white, colors.gray)
        table.insert(touchZones, 1, {id="close_machine_info", x1=clsMX, x2=clsMX+#clsM-1, y=pY2+pH2-1})
    elseif craftInfoPopup then
        local data = recipesScanResults[craftInfoPopup.item]
        if not data then
            craftInfoPopup = nil
        else
            popupRect = _diB21(w, h, touchZones, popupRect, data)
        end
    elseif fluidCraftInfo then
        popupRect = _diB24(w, h, touchZones, popupRect)
    elseif compositePopup then
        popupRect, popupZoneStart = drawCompositePopup(w, h, touchZones, popupRect, popupZoneStart)
    elseif #craftErrorLines > 0 then
        local panelH   = #craftErrorLines + 1
        local panelTop = h - panelH + 1
        if panelTop < 9 then panelTop = 9 end
        local hdr = craftErrorTitle or "! NOT ENOUGH RESOURCES"
        if hdr == "! NEED" then
            _bufClearLine(panelTop, colors.yellow)
            drawText(2, panelTop, hdr:sub(1, w - 8), colors.black, colors.yellow)
        else
            _bufClearLine(panelTop, colors.red)
            drawText(2, panelTop, hdr:sub(1, w - 8), colors.white, colors.red)
        end
        local closeStr = " [X] "
        local closeX = w - #closeStr + 1
        drawText(closeX, panelTop, closeStr, colors.white, colors.black)
        for py = panelTop, h do
            table.insert(touchZones, 1, {id="error_panel_bg", x1=1, x2=w, y=py})
        end
        for li, line in ipairs(craftErrorLines) do
            local ly = panelTop + li
            if ly <= h then
                _bufClearLine(ly, colors.gray)
                local editItem = (craftErrorTitle == "! MACHINE NOT FOUND") and craftErrorEditItems[li]
                if editItem and Recipes[editItem] then
                    drawText(2, ly, line:sub(1, w - 9), colors.white, colors.gray)
                    drawText(w - 6, ly, " [E] ", colors.black, colors.orange)
                    table.insert(touchZones, 1, {id="error_edit_machine", arg=editItem, x1=w-6, x2=w-2, y=ly})
                else
                    drawText(2, ly, line:sub(1, w - 2), colors.white, colors.gray)
                end
            end
        end
        table.insert(touchZones, 1, {id="close_craft_err", x1=closeX, x2=w, y=panelTop})
    end

    -- Protect popup background from click-through
    if popupRect then
        if popupZoneStart and popupZoneStart > 1 then
            local filtered = {}
            for i = popupZoneStart, #touchZones do
                table.insert(filtered, touchZones[i])
            end
            touchZones = filtered
        end
        for shieldY = popupRect.y1, popupRect.y2 do
            table.insert(touchZones, {id="popup_bg", x1=popupRect.x1, x2=popupRect.x2, y=shieldY})
        end
    end
    for bgRow = 1, h do
        table.insert(touchZones, {id="bg_click", x1=1, x2=w, y=bgRow})
    end

    _bufFlush()
    return touchZones
end
function mainLoop()
checkTimer = os.startTimer(6)
idleTimer   = os.startTimer(autostockIdleSecs)
while true do
local touchZones = drawInterface()
term.clear() term.setCursorPos(1,1)
print("==========================================")
print(" STATUS: MONITOR DISPLAY ACTIVE (NX-UI)   ")
print("==========================================")
local searchTabActive = (currentTab == "RECIPES" or currentTab == "STOCK")
or (currentTab == "FLUID" and (fluidSubTab == "FLUID" or fluidSubTab == "FITEM") and not fluidRecipePicker and not fluidCraftWaitFluid)
if searchTabActive then
local sf, label
if currentTab == "RECIPES" then sf, label = searchFilter, "RECIPES"
elseif currentTab == "STOCK" then sf, label = stockSearchFilter, "STOCK"
else sf, label = fluidSearchFilter, "FLUID" end
print(" more")
print(" [" .. label .. " SEARCH]")
if sf == "" then
print(" > _  (type to search)")
else
print(" > " .. sf .. "_")
end
end
local event, param1, param2, param3
if #pendingTouches > 0 then
local t = table.remove(pendingTouches, 1)
event, param1, param2, param3 = t[1], t[2], t[3], t[4]
else
event, param1, param2, param3 = os.pullEvent()
if event == "monitor_touch" and #pendingTouches > 0 then
local t = table.remove(pendingTouches, 1)
event, param1, param2, param3 = t[1], t[2], t[3], t[4]
end
end
if event == "timer" and param1 == checkTimer then
checkTimer = os.startTimer(6)
elseif event == "timer" and param1 == uiMsgTimer then
uiMessage = ""
uiMsgTimer = nil
elseif event == "timer" and errorClearTimer and param1 == errorClearTimer then
clearCraftError()
elseif event == "timer" and craftCompletePopup and param1 == craftCompletePopup.timer then
craftCompletePopup = nil
elseif event == "timer" and unloadTimer and param1 == unloadTimer then
unloadActive = false
unloadTimer = nil
elseif event == "timer" and optimizeTimer and param1 == optimizeTimer then
optimizeActive = false
optimizeTimer = nil
elseif event == "timer" and scanTimer and param1 == scanTimer then
scanActive = false
scanTimer = nil
elseif event == "timer" and vaultOpPopup and param1 == vaultOpPopup.timer then
vaultOpPopup = nil
elseif event == "timer" and param1 == idleTimer then
if not Config.autostock_paused then
checkAndRunAutostock()
end
idleTimer = os.startTimer(autostockIdleSecs)
elseif event == "monitor_touch" then
local x, y = param2, param3
uiMessage = ""
if uiMsgTimer then os.cancelTimer(uiMsgTimer); uiMsgTimer = nil end
pendingDeleteItem = nil
pendingDeleteFluid = nil
if idleTimer then os.cancelTimer(idleTimer) end
idleTimer = os.startTimer(autostockIdleSecs)
for _, zone in ipairs(touchZones) do
if zone.id and x >= zone.x1 and x <= zone.x2 and y == zone.y then
if zone.id == "close_craft_err" or zone.id == "error_panel_bg" then
clearCraftError()
break
end
if craftCompletePopup and zone.id ~= "popup_close" and zone.id ~= "popup_request" and zone.id ~= "popup_bg" then
if craftCompletePopup.timer then os.cancelTimer(craftCompletePopup.timer) end
craftCompletePopup = nil
break
end
if fluidRecipePicker and zone.id ~= "fluid_pick_recipe" and zone.id ~= "fluid_make_primary"
and zone.id ~= "fluid_picker_delete" and zone.id ~= "fluid_picker_close" then
break
end
if remotePopup and zone.id ~= "open_remote_popup" and zone.id ~= "close_remote_popup" and zone.id ~= "remote_toggle_pair" and zone.id ~= "remote_unpair_all" and zone.id ~= "popup_bg" then
remotePopup = false
break
end
if networkFilterPopup and zone.id ~= "open_network_filter" and zone.id ~= "close_network_filter" and zone.id ~= "filter_toggle_keep_active" and zone.id ~= "filter_toggle_cat" and zone.id ~= "filter_show_all" and zone.id ~= "filter_page_prev" and zone.id ~= "filter_page_next" and zone.id ~= "popup_bg" then
networkFilterPopup = false
break
end
if machineInfoPopup and zone.id ~= "close_machine_info" and zone.id ~= "show_machine_info" and zone.id ~= "popup_bg" then
machineInfoPopup = nil
break
end
if craftInfoPopup and zone.id ~= "close_craft_info" and zone.id ~= "show_craft_info" and zone.id ~= "popup_bg" then
craftInfoPopup = nil
break
end
if fluidCraftInfo and zone.id ~= "close_fluid_info" and zone.id ~= "show_fluid_info" and zone.id ~= "popup_bg" then
fluidCraftInfo = nil
break
end
if historyPopup and zone.id ~= "open_history" and zone.id ~= "close_history" and zone.id ~= "history_craft" and zone.id ~= "history_craft_fluid" and zone.id ~= "history_req" and zone.id ~= "history_prev" and zone.id ~= "history_next" and zone.id ~= "history_scan" and zone.id ~= "popup_bg" then
historyPopup = nil
break
end
if recipeEditPopup and zone.id ~= "close_recipe_edit" and zone.id ~= "recipe_edit_select" and zone.id ~= "recipe_edit_apply" and zone.id ~= "recipe_edit_global" and zone.id ~= "recipe_edit_confirm_global" and zone.id ~= "recipe_edit_prev" and zone.id ~= "recipe_edit_next" and zone.id ~= "popup_bg" then
recipeEditPopup = nil
break
end
if custGrpPopup and zone.id ~= "cgrp_popup_name" and zone.id ~= "cgrp_popup_toggle" and zone.id ~= "cgrp_popup_prev" and zone.id ~= "cgrp_popup_next" and zone.id ~= "cgrp_popup_cancel" and zone.id ~= "cgrp_popup_save" and zone.id ~= "popup_bg" then
custGrpPopup = nil
break
end
if currentTab == "QUANTITY_PICKER" then
local isQtyZone = zone.id == "qty_adj" or zone.id == "qty_confirm" or zone.id == "qty_cancel" or zone.id == "qty_max" or zone.id == "qty_type" or zone.id == "keep_field" or zone.id == "popup_bg" or zone.id == "qty_calc_max" or zone.id == "qty_toggle_automax" or zone.id == "qty_add_queue"
if not isQtyZone then
isRequestMode = false
isSettingKeepLimit = false
if queueEditIdx then queueEditIdx = nil; craftQueuePopup = true end
currentTab = qtyOriginTab or "RECIPES"
break
end
end
if craftQueuePopup and zone.id == "bg_click" then
craftQueuePopup = false
craftQueueErrIdx = nil
break
end
if mgmtPopup and zone.id == "bg_click" then
mgmtPopup = nil
break
end
if custGrpPopup and zone.id == "bg_click" then
custGrpPopup = nil
break
end
if compositePopup and zone.id == "bg_click" then
if compositePopup.target == "result_item" then
compositePopup = { mode = "results", page = compositePopup.returnPage or 1 }
else
compositePopup = nil
end
break
end
if zone.id == "popup_bg" then break end
if zone.id == "switch_tab" then
clearCraftError()
currentTab = zone.arg; currentPage = 1
mgmtPopup = nil
custGrpPopup = nil
compositePopup = nil
if zone.arg == "STOCK" then stockSearchFilter = ""; stockModFilter = "All"; stockModFilterPage = 1 end
if zone.arg == "KEEP" then scanKeepItemsNow() end
if zone.arg == "PROJECT" and ProjectState.hasScanned then refreshProjectAnalysis(getStorageInventoryCached()) end
elseif zone.id:sub(1, 5) == "proj_" then
handleProjectTouchZone(zone)
elseif zone.id == "set_mod" then currentModFilter = zone.arg; currentPage = 1
elseif zone.id == "mod_prev" then modFilterPage = math.max(1, modFilterPage - 1)
elseif zone.id == "mod_next" then modFilterPage = modFilterPage + 1
elseif zone.id == "craft_subtab" then
craftSubTab = zone.arg
craftDevicePage = 1
compositePopup = nil
if zone.arg == "TURTLE" then
selectedCraftType = "turtle"
selectedOutputDevice = nil
outputPickMode = false
end
elseif zone.id == "craft_dev_prev" then craftDevicePage = math.max(1, craftDevicePage - 1)
elseif zone.id == "craft_dev_next" then craftDevicePage = craftDevicePage + 1
elseif zone.id == "fluid_subtab" then
fluidSubTab = zone.arg
fluidTankPage = 1
fluidRecipePage = 1
elseif zone.id == "fluid_tank_prev" then fluidTankPage = math.max(1, fluidTankPage - 1)
elseif zone.id == "fluid_tank_next" then fluidTankPage = fluidTankPage + 1
elseif zone.id == "fluid_recipe_prev" then fluidRecipePage = math.max(1, fluidRecipePage - 1)
elseif zone.id == "fluid_recipe_next" then fluidRecipePage = fluidRecipePage + 1
elseif zone.id == "clear_error_log" then
errorLog = {}
saveErrorLog()
elseif zone.id == "error_prev_page" then
errorLogPage = math.max(1, errorLogPage - 1)
elseif zone.id == "error_next_page" then
errorLogPage = errorLogPage + 1
elseif zone.id == "fluid_delete_ask" then
pendingDeleteFluid = zone.arg
elseif zone.id == "fluid_delete_cancel" then
pendingDeleteFluid = nil
elseif zone.id == "fluid_delete_confirm" then
local prods = fluidProducers(zone.arg)
if prods[1] then removeFluidRecipeRef(prods[1].recipe) end
pendingDeleteFluid = nil
syncFluidItemStubs()
saveData()
elseif zone.id == "open_keep_picker_fluid" then
local fk = fluidKey(zone.arg)
if Autostock[fk] then
Autostock[fk] = nil
saveData()
else
fluidCraftMode = nil
fluidKeepName = zone.arg
itemToCraft = fk
keepThr = 1000
keepTgt = 2000
keepField = "threshold"
isSettingKeepLimit = true
isRequestMode = false
qtyOriginTab = "RECIPES"
currentTab = "QUANTITY_PICKER"
end
elseif zone.id == "open_recipe_edit_fluid" then
local prods = fluidProducers(zone.arg)
local p = prods[1]
if p then
recipeEditPopup = {
fluid = zone.arg, fluidRecipeRef = p.recipe,
origMachine = p.recipe.machine_name, selected = p.recipe.machine_name,
confirmGlobal = false, page = 1,
}
end
elseif zone.id == "fluid_craft" then
local prods = fluidProducers(zone.arg)
if prods[1] then doFluidCraftFlow(prods[1].recipe, zone.arg) end
elseif zone.id == "fluid_alt" then
altViewFluid = zone.arg
altViewItem = nil
currentTab = "ALT_VIEW"
elseif zone.id == "fluid_pick_recipe" then
if fluidRecipePicker then
local p = fluidRecipePicker.producers[zone.arg]
local fname = fluidRecipePicker.fluid
if p then doFluidCraftFlow(p.recipe, fname) end
end
elseif zone.id == "fluid_make_primary" then
if fluidRecipePicker then
local p = fluidRecipePicker.producers[zone.arg]
if p and p.own and not p.isPrimary and p.altIdx then
local fk = p.key
local alts = FluidAltRecipes[fk] or {}
local chosen = table.remove(alts, p.altIdx)
local old = FluidRecipes[fk]
FluidRecipes[fk] = chosen
if old then table.insert(alts, 1, old) end
FluidAltRecipes[fk] = (#alts > 0) and alts or nil
syncFluidItemStubs()
saveData()
fluidRecipePicker.producers = fluidProducers(fluidRecipePicker.fluid)
end
end
elseif zone.id == "fluid_picker_delete" then
if fluidRecipePicker then
local p = fluidRecipePicker.producers[zone.arg]
if p and p.own then
local fk = p.key
if p.isPrimary then
local alts = FluidAltRecipes[fk]
if alts and alts[1] then
FluidRecipes[fk] = table.remove(alts, 1)
if #alts == 0 then FluidAltRecipes[fk] = nil end
else
FluidRecipes[fk] = nil
end
elseif p.altIdx then
local alts = FluidAltRecipes[fk]
if alts then
table.remove(alts, p.altIdx)
if #alts == 0 then FluidAltRecipes[fk] = nil end
end
end
syncFluidItemStubs()
saveData()
local prods = fluidProducers(fluidRecipePicker.fluid)
if #prods == 0 then fluidRecipePicker = nil
else fluidRecipePicker.producers = prods end
end
end
elseif zone.id == "fluid_picker_close" then
fluidRecipePicker = nil
elseif zone.id == "fluid_trigger_search" then
searchInputActive = true
drawInterface()
term.clear() term.setCursorPos(1, 1)
write("Enter fluid search: ")
local srInput = timedRead(5)
searchInputActive = false
if srInput ~= nil then fluidSearchFilter = srInput end
fluidRecipePage = 1
elseif zone.id == "fluid_clear_search" then
fluidSearchFilter = ""
fluidRecipePage = 1
elseif zone.id == "craft_out_change" then
if outputPickMode then
outputPickMode = false
elseif selectedOutputDevice then
selectedOutputDevice = nil
else
outputPickMode = true
end
elseif zone.id == "delete_ask" then
pendingDeleteItem = zone.arg
elseif zone.id == "delete_confirm" then
local delRec = Recipes[zone.arg]
if type(delRec) == "table" and delRec.type == "fluid" then
local frec = findFluidItemProducer(zone.arg)
if frec then removeFluidRecipeRef(frec) end
end
Recipes[zone.arg] = nil
AltRecipes[zone.arg] = nil
Autostock[zone.arg] = nil
syncFluidItemStubs()
saveData()
pendingDeleteItem = nil
elseif zone.id == "delete_cancel" then
pendingDeleteItem = nil
elseif zone.id == "open_alt_view" then
altViewItem = zone.arg
altViewFluid = nil
currentTab = "ALT_VIEW"
elseif zone.id == "alt_back" then
currentTab = "RECIPES"
if altViewFluid then currentModFilter = "FLUID" end
altViewFluid = nil
learnAsAlt = false
learnAsAltItem = nil
elseif zone.id == "alt_add" then
learnAsAlt = true
learnAsAltItem = altViewItem
currentTab = "+RECIPES"
learningState = "IDLE"
uiMessage = "Scan alt recipe, then [SAVE] to add as alt."
elseif zone.id == "combined_up" or zone.id == "combined_dn" or zone.id == "combined_top" or zone.id == "combined_del" then
local fkA = altViewFluid and fluidKey(altViewFluid) or nil
local getPrimary = function()
if fkA then return FluidRecipes[fkA] else return Recipes[altViewItem] end
end
local setPrimary = function(v)
if fkA then FluidRecipes[fkA] = v else Recipes[altViewItem] = v end
end
if altViewItem or altViewFluid then
local hasPrimary = getPrimary() ~= nil
local alts = (fkA and FluidAltRecipes[fkA] or (altViewItem and AltRecipes[altViewItem])) or {}
local eIdx = zone.arg
local function swapEntries(a, b)
local aIsPrimary = hasPrimary and (a == 1)
local bIsPrimary = hasPrimary and (b == 1)
if aIsPrimary and not bIsPrimary then
local altPos = b - (hasPrimary and 1 or 0)
local oldPrimary = getPrimary()
setPrimary(alts[altPos])
alts[altPos] = oldPrimary
elseif bIsPrimary and not aIsPrimary then
local altPos = a - (hasPrimary and 1 or 0)
local oldPrimary = getPrimary()
setPrimary(alts[altPos])
alts[altPos] = oldPrimary
else
local aAlt = a - (hasPrimary and 1 or 0)
local bAlt = b - (hasPrimary and 1 or 0)
alts[aAlt], alts[bAlt] = alts[bAlt], alts[aAlt]
end
end
if zone.id == "combined_up" and eIdx > 1 then
swapEntries(eIdx, eIdx - 1)
elseif zone.id == "combined_dn" then
local total = (hasPrimary and 1 or 0) + #alts
if eIdx < total then swapEntries(eIdx, eIdx + 1) end
elseif zone.id == "combined_top" and eIdx > 1 then
for i = eIdx, 2, -1 do swapEntries(i, i - 1) end
elseif zone.id == "combined_del" then
local altPos = eIdx - (hasPrimary and 1 or 0)
if altPos >= 1 and altPos <= #alts then
table.remove(alts, altPos)
end
end
if fkA then
FluidAltRecipes[fkA] = (#alts > 0) and alts or nil
syncFluidItemStubs()
elseif #alts == 0 then
AltRecipes[altViewItem] = nil
else
AltRecipes[altViewItem] = alts
end
saveData()
end
elseif zone.id == "craft_cancel" then
    cancelCrafting = true
elseif zone.id == "open_remote_popup" then
    remotePopup = true
elseif zone.id == "close_remote_popup" then
    remotePopup = false
elseif zone.id == "remote_toggle_pair" then
    if os.clock() < pairingActiveUntil then
        pairingActiveUntil = 0
    else
        pairingActiveUntil = os.clock() + 60
    end
elseif zone.id == "remote_unpair_all" then
    Config.paired_remotes = {}
    saveData()
elseif zone.id == "open_network_filter" then
    networkFilterPopup = true
    networkFilterPage = 1
elseif zone.id == "close_network_filter" then
    networkFilterPopup = false
elseif zone.id == "filter_toggle_keep_active" then
    Config.filter_keep_active = not (Config.filter_keep_active ~= false)
    saveData()
elseif zone.id == "filter_toggle_cat" then
    local cat = zone.arg
    if not Config.hidden_network_types then Config.hidden_network_types = {} end
    if Config.hidden_network_types[cat] then
        Config.hidden_network_types[cat] = nil
    else
        Config.hidden_network_types[cat] = true
    end
    saveData()
elseif zone.id == "filter_show_all" then
    Config.hidden_network_types = {}
    saveData()
elseif zone.id == "filter_page_prev" then
    networkFilterPage = math.max(1, (networkFilterPage or 1) - 1)
elseif zone.id == "filter_page_next" then
    networkFilterPage = (networkFilterPage or 1) + 1
elseif zone.id == "toggle_buffer" then
    local p = zone.arg
    if Config.buffer == p then
        Config.buffer = nil
    else
        StorageIndex.clearRoles(p)
        Config.buffer = p
    end
    invalidateStockCache()
    saveData()
elseif zone.id == "toggle_main_vault" then
    local p = zone.arg
    if not Config.main_vaults then Config.main_vaults = {} end
    if Config.main_vaults[p] then
        Config.main_vaults[p] = nil
        StorageIndex.rebuildVault(p, {}, 0)
        StorageIndex.vaultStats[p] = nil
    else
        StorageIndex.clearRoles(p)
        Config.main_vaults[p] = true
        local obj = peripheral.wrap(p)
        if obj and obj.list and obj.size then
            local okL, lst = pcall(obj.list)
            local okS, sz = pcall(obj.size)
            if okL and okS then
                StorageIndex.rebuildVault(p, lst or {}, sz or 0)
            end
        end
    end
    invalidateStockCache()
    saveData()
elseif zone.id == "toggle_storage" then
    local p = zone.arg
    if not Config.storages then Config.storages = {} end
    if Config.storages[p] then
        Config.storages[p] = nil
    else
        StorageIndex.clearRoles(p)
        Config.storages[p] = true
    end
    invalidateStockCache()
    saveData()
elseif zone.id == "set_train_box" then
    local p = zone.arg
    if Config.train_box == p then
        Config.train_box = nil
    else
        StorageIndex.clearRoles(p)
        Config.train_box = p
    end
    invalidateStockCache()
    saveData()
elseif zone.id == "set_project_chest" then
    local p = zone.arg
    if Config.project_chest == p then
        Config.project_chest = nil
        clearProjectData("Project chest unassigned. Select another chest with [PROJ] in NETWORK.")
    else
        StorageIndex.clearRoles(p)
        Config.project_chest = p
        clearProjectData("Project chest assigned. Put a Create Clipboard inside and scan it.")
    end
    invalidateStockCache()
    saveData()
elseif zone.id == "set_turtle" then
    local p = zone.arg
    if not Config.turtles then Config.turtles = {} end
    if Config.turtles[p] then
        Config.turtles[p] = nil
    else
        StorageIndex.clearRoles(p)
        Config.turtles[p] = true
    end
    invalidateStockCache()
    saveData()
elseif zone.id == "toggle_fluid_tank" then
    local p = zone.arg
    if not Config.fluid_tanks then Config.fluid_tanks = {} end
    if Config.fluid_tanks[p] then
        Config.fluid_tanks[p] = nil
    else
        StorageIndex.clearRoles(p)
        Config.fluid_tanks[p] = true
    end
    invalidateStockCache()
    saveData()
elseif zone.id == "autostock_toggle" then
Config.autostock_paused = not Config.autostock_paused
saveData()
elseif zone.id == "keep_cat" then
fluidKeepFilter = zone.arg
currentPage = 1
elseif zone.id == "force_autostock" then
if not Config.autostock_paused then
checkAndRunAutostock()
end
elseif zone.id == "keep_craft_now" then
local kItem = zone.arg
local kSet  = Autostock[kItem]
if kSet and kItem:sub(1, 2) == "f:" then
local fname = fluidNameFromKey(kItem)
local cur   = (getFluidInventory())[kItem] or 0
local need  = (kSet.target or kSet.limit) - cur
local kShort = fname:match(":(.+)$") or fname
if need > 0 then
local prods = fluidProducers(fname)
if prods[1] then
local fOk, fProd, fIsIt = runFluidCraftAmount(prods[1].recipe, fname, need)
if fOk then
uiMessage = "Crafted: " .. kShort
autostockCooldowns[kItem] = nil
else
uiMessage = "ERR: fluid craft failed"
end
else
uiMessage = "ERR: no recipe for " .. kShort
triggerCraftError("! NO RECIPE", {"No fluid recipe for " .. kShort}, 10)
end
else
uiMessage = kShort .. " already at target"
end
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(3)
scanKeepItemsNow()
elseif kSet and Recipes[kItem] then
local kInv    = getStorageInventory()
local kStock  = kInv[kItem] or 0
local kTarget = kSet.target or kSet.limit or 1
local kNeeded = kTarget - kStock
local kShort  = getItemDisplayName(kItem)
if kNeeded > 0 then
systemStatus = "MANUAL_CRAFT"
drawInterface()
local kPlan, kMiss, _ = planProduction(kItem, kTarget, true)
if kPlan and #kPlan > 0 then
local craftOk = false
local kOk, kErr = pcall(function()
craftOk = runCraftingProcess(kPlan)
local kAtt = 0
while not cancelCrafting and kAtt < 12 do
flushCraftBuffer()
invalidateStockCache()
local tNow = groupAvailable(kItem, getStorageInventory(), false)
if tNow >= kTarget then break end
kAtt = kAtt + 1
local rP = planProduction(kItem, kTarget, true)
if not (rP and #rP > 0) then break end
local bK = tNow
if runCraftingProcess(rP) then craftOk = true end
flushCraftBuffer()
invalidateStockCache()
if groupAvailable(kItem, getStorageInventory(), false) <= bK then break end
end
end)
systemStatus = "IDLE"
if kOk and craftOk then
uiMessage = "Crafted: " .. kShort
autostockCooldowns[kItem] = nil
clearCraftError()
else
if not kOk then
uiMessage = "ERR: " .. tostring(kErr):sub(1, 30)
else
uiMessage = "ERR: craft failed for " .. kShort
end
triggerCraftError(craftErrorTitle or "! NEED", craftErrorLines, 10)
end
else
systemStatus = "IDLE"
uiMessage = "ERR: no resources for " .. kShort
local missLines = {}
for mName, mCnt in pairs(kMiss or {}) do
if #missLines < 4 then
missLines[#missLines + 1] = "Need " .. mCnt .. "x " .. getItemDisplayName(mName)
end
end
if #missLines == 0 then missLines[1] = "Missing components to craft " .. kShort end
triggerCraftError("! NEED", missLines, 10)
end
else
uiMessage = kShort .. " already at target"
end
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(3)
scanKeepItemsNow()
end
elseif zone.id == "keep_top" or zone.id == "keep_up" or zone.id == "keep_dn" then
local fname = zone.arg
local isFl = (fname:sub(1, 2) == "f:")
local list = {}
for iName, s in pairs(Autostock) do
if (iName:sub(1, 2) == "f:") == isFl then
table.insert(list, {name=iName, order=s.order or 99999})
end
end
table.sort(list, function(a,b) return a.order < b.order end)
local idx
for i, e in ipairs(list) do if e.name == fname then idx = i; break end end
if idx then
if zone.id == "keep_top" then
local moved = table.remove(list, idx)
table.insert(list, 1, moved)
elseif zone.id == "keep_up" and idx > 1 then
list[idx], list[idx-1] = list[idx-1], list[idx]
elseif zone.id == "keep_dn" and idx < #list then
list[idx], list[idx+1] = list[idx+1], list[idx]
end
local slots = {}
for _, e in ipairs(list) do slots[#slots + 1] = e.order end
table.sort(slots)
for i, e in ipairs(list) do
if Autostock[e.name] then Autostock[e.name].order = slots[i] end
end
saveData()
end
elseif zone.id == "turtle_remove" then
if Config.turtles then Config.turtles[zone.arg] = nil end
invalidateStockCache()
saveData()
elseif zone.id == "turtle_add" then
if not Config.turtles then Config.turtles = {} end
StorageIndex.clearRoles(zone.arg)
Config.turtles[zone.arg] = true
invalidateStockCache()
saveData()
elseif zone.id == "toggle_keep_status" then
if Autostock[zone.arg] then
Autostock[zone.arg].paused = not Autostock[zone.arg].paused
saveData()
end
elseif zone.id == "remove_keep" then
Autostock[zone.arg] = nil
local remaining = {}
for iName, s in pairs(Autostock) do
table.insert(remaining, {name=iName, order=s.order or 99999})
end
table.sort(remaining, function(a,b) return a.order < b.order end)
for ni, ri in ipairs(remaining) do Autostock[ri.name].order = ni end
saveData()
elseif zone.id == "prev_page" then
currentPage = math.max(1, currentPage - 1)
elseif zone.id == "next_page" then
currentPage = currentPage + 1
elseif zone.id == "scan_recipes" then
scanActive = true
recipesScanResults = {}
fluidScanResults = {}
drawInterface()
if scanTimer then os.cancelTimer(scanTimer) end
scanTimer = os.startTimer(3)
elseif zone.id == "scan_all_recipes" then
allScanActive = true
drawInterface()
scanAllRecipesNow()
scanAllFluidsNow()
allScanActive = false
scanActive = true
if scanTimer then os.cancelTimer(scanTimer) end
scanTimer = os.startTimer(3)
drawInterface()
elseif zone.id == "show_machine_info" then
local sr = recipesScanResults[zone.arg]
machineInfoPopup = {item = zone.arg, machineName = sr and sr.missingMachine or "?"}
elseif zone.id == "close_machine_info" then
machineInfoPopup = nil
elseif zone.id == "show_craft_info" then
local ciSnap = getStorageInventory()
local _, ciMiss, ciBlock = planProduction(zone.arg, 1, false, ciSnap)
local ciDetails = {}
for bItem in pairs(ciBlock) do
local ciDetailSnap = {}
for k, v in pairs(ciSnap) do ciDetailSnap[k] = v end
ciDetailSnap[bItem] = 0
local _, bm, _ = planProduction(bItem, 1, false, ciDetailSnap)
ciDetails[bItem] = {missing = bm}
end
if not next(ciMiss) and not next(ciBlock) then
local ciDirect = groupAvailable(zone.arg, ciSnap, false)
local _, beyMiss, beyBlock = planProduction(zone.arg, ciDirect + 1, false, ciSnap)
if next(beyMiss) or next(beyBlock) then
ciMiss  = beyMiss
ciBlock = beyBlock
ciDetails = {}
for bItem in pairs(beyBlock) do
local ciDetailSnap = {}
for k, v in pairs(ciSnap) do ciDetailSnap[k] = v end
ciDetailSnap[bItem] = 0
local _, bm, _ = planProduction(bItem, 1, false, ciDetailSnap)
ciDetails[bItem] = {missing = bm}
end
end
end
if recipesScanResults[zone.arg] then
recipesScanResults[zone.arg].missing       = ciMiss
recipesScanResults[zone.arg].blocked       = ciBlock
recipesScanResults[zone.arg].blockedDetails = ciDetails
else
recipesScanResults[zone.arg] = {missing=ciMiss, blocked=ciBlock, blockedDetails=ciDetails, maxCraftable=0}
end
craftInfoPopup = {item = zone.arg}
elseif zone.id == "close_craft_info" then
craftInfoPopup = nil
elseif zone.id == "show_fluid_info" then
local prods = fluidProducers(zone.arg)
local perOp = (prods[1] and prods[1].perOp) or 1
local fStock = {}
for k, v in pairs(getStorageInventory()) do fStock[k] = v end
fStock[fluidKey(zone.arg)] = 0
local fMiss = {}
pcall(simFluidConsume, zone.arg, perOp, fStock, fMiss, {}, {})
fluidCraftInfo = {name = zone.arg, missing = fMiss}
elseif zone.id == "close_fluid_info" then
fluidCraftInfo = nil
elseif zone.id == "open_history" then
if historyPopup then
historyPopup = nil
else
historyPopup = {page = 1, maxCache = {}}
end
elseif zone.id == "history_scan" then
if historyPopup then
local hSnap = getStorageInventory()
local histFstock = {}
for k, v in pairs(getFluidInventoryCached()) do histFstock[fluidNameFromKey(k)] = v end
local hCache = {}
for _, hEntry in ipairs(craftHistory) do
local hItem = hEntry.item
if hEntry.fluid then
local fck = "f:" .. hItem
if hCache[fck] == nil then
local okm, mx = pcall(maxFluidCraftable, hItem, histFstock, hSnap, {})
hCache[fck] = (okm and type(mx) == "number") and math.max(0, mx - (histFstock[hItem] or 0)) or 0
end
elseif hCache[hItem] == nil and Recipes[hItem] then
local hSnapC = {}
for k, v in pairs(hSnap) do hSnapC[k] = v end
hSnapC[hItem] = 0
local _, hm1, _ = planProduction(hItem, 1, false, hSnapC)
if next(hm1) then
hCache[hItem] = 0
else
local _, hm100, _ = planProduction(hItem, 100, false, hSnapC)
if not next(hm100) then
hCache[hItem] = 100
else
local lo, hi = 1, 99
while hi - lo > 1 do
local mid = math.floor((lo + hi) / 2)
local _, hmm, _ = planProduction(hItem, mid, false, hSnapC)
if not next(hmm) then lo = mid else hi = mid end
end
hCache[hItem] = lo
end
end
elseif hCache[hItem] == nil then
hCache[hItem] = 0
end
end
historyPopup.maxCache = hCache
end
elseif zone.id == "close_history" then
historyPopup = nil
elseif zone.id == "history_prev" then
if historyPopup then
historyPopup.page = math.max(1, (historyPopup.page or 1) - 1)
end
elseif zone.id == "history_next" then
if historyPopup then
local _, mH = monitor.getSize()
local hPerPage2 = math.max(4, (mH or 24) - 20)
local totPg2 = math.max(1, math.ceil(#craftHistory / hPerPage2))
historyPopup.page = math.min(totPg2, (historyPopup.page or 1) + 1)
end
elseif zone.id == "history_craft" then
historyPopup = nil
itemToCraft = zone.arg
fluidCraftMode = nil
fluidKeepName = nil
isSettingKeepLimit = false
isRequestMode = false
qtyOriginTab = "RECIPES"
local pickerSnap = getStorageInventoryCached()
craftQuantity = pickerSnap[zone.arg] or 0
pickerMaxCraftable = 0
pickerMaxCapped = false
pickerMaxComputed = false
if Config.autoMaxCalc ~= false then pickerComputeMax() end
currentTab = "QUANTITY_PICKER"
elseif zone.id == "history_craft_fluid" then
historyPopup = nil
local hprods = fluidProducers(zone.arg)
if hprods[1] then doFluidCraftFlow(hprods[1].recipe, zone.arg) end
elseif zone.id == "history_req" then
historyPopup = nil
itemToCraft = zone.arg
fluidCraftMode = nil
fluidKeepName = nil
local inv = getStorageInventoryCached()
requestMaxQty = inv[zone.arg] or 0
craftQuantity = math.min(1, requestMaxQty)
isSettingKeepLimit = false
isRequestMode = true
qtyOriginTab = "RECIPES"
currentTab = "QUANTITY_PICKER"
elseif zone.id == "error_edit_machine" then
craftErrorLines = {}; craftErrorTitle = nil
craftErrorEditItems = {}
local rec = Recipes[zone.arg]
if rec then
currentTab = "RECIPES"
recipeEditPopup = {
item          = zone.arg,
altIdx        = nil,
isItemScope   = false,
origMachine   = rec.machine_name,
selected      = rec.machine_name,
confirmGlobal = false,
page          = 1
}
end
elseif zone.id == "open_recipe_edit" then
local altIdx = zone.altIdx
local rec
if altIdx then
local alts = AltRecipes[zone.arg]
rec = alts and alts[altIdx]
else
rec = Recipes[zone.arg]
end
if rec and rec.type == "composite" then
local loadedResults = {}
if rec.results and #rec.results > 0 then
for _, r in ipairs(rec.results) do
table.insert(loadedResults, {
item   = r.item,
count  = r.count or 1,
role   = (r.item == zone.arg) and "recipe" or (r.role or "byproduct"),
chance = r.chance
})
end
else
local mainCh = rec.success_rate or (rec.chance and math.floor(rec.chance * 100 + 0.5)) or nil
table.insert(loadedResults, {
item   = zone.arg,
count  = rec.output_count or 1,
role   = "recipe",
chance = mainCh
})
for _, bp in ipairs(rec.byproducts or {}) do
if bp.item and bp.item ~= zone.arg then
table.insert(loadedResults, {
item   = bp.item,
count  = bp.count or 1,
role   = "byproduct",
chance = bp.chance
})
end
end
end
local hasAnyChance = (rec.studio_mode == "chance") or (rec.mode == "chance") or (rec.success_rate ~= nil) or (rec.chance ~= nil)
for _, r in ipairs(loadedResults) do
if r.chance ~= nil then hasAnyChance = true end
end
local loadedBaseIngs = {}
if rec.base_ingredients and #rec.base_ingredients > 0 then
for _, bi in ipairs(rec.base_ingredients) do
table.insert(loadedBaseIngs, { item = bi.item, count = bi.count or 1 })
end
elseif rec.base_ingredient and rec.base_ingredient.item then
table.insert(loadedBaseIngs, { item = rec.base_ingredient.item, count = rec.base_ingredient.count or 1 })
end

compositeDraft = {
baseSource = "barrel",
targetPlatform = rec.machine_name,
outputPlatform = (rec.output_device and rec.output_device ~= rec.machine_name) and rec.output_device or nil,
baseIngredients = loadedBaseIngs,
baseItem = loadedBaseIngs[1] and loadedBaseIngs[1].item or (rec.base_ingredient and rec.base_ingredient.item),
baseCount = loadedBaseIngs[1] and loadedBaseIngs[1].count or (rec.base_ingredient and rec.base_ingredient.count or 1),
mode = hasAnyChance and "chance" or "normal",
actions = {},
actPage = 1,
results = loadedResults,
resPage = 1,
testDone = true,
editingItem = zone.arg,
editingAltIdx = altIdx
}
for _, act in ipairs(rec.actions or {}) do
local bKey = act.item and parseItemKey(act.item) or nil
local isT = act.is_tool or (rec.tools and bKey and (rec.tools[act.item] ~= nil or rec.tools[bKey] ~= nil)) or false
local tEntry = rec.tools and bKey and (rec.tools[act.item] or rec.tools[bKey])
local dur = act.durability or (type(tEntry) == "table" and tEntry.durability) or (isT and getWholeToolDurability(bKey) or nil)
table.insert(compositeDraft.actions, {
type = act.type,
device = act.device,
item = isT and bKey or act.item,
fluid = act.fluid,
count = act.count,
amount = act.amount,
is_tool = isT,
durability = dur
})
end
compositePopup = nil
craftSubTab = "MACHINES"
currentTab = "+RECIPES"
uiMessage = "Editing " .. (zone.arg:match(":(.+)$") or zone.arg) .. " (tap [RESULTS] to edit outputs)"
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(4)
elseif rec then
recipeEditPopup = {
item          = zone.arg,
altIdx        = altIdx,
isItemScope   = zone.fromAltView == true,
origMachine   = rec.machine_name,
selected      = rec.machine_name,
confirmGlobal = false,
page          = 1
}
end
elseif zone.id == "recipe_edit_select" then
if recipeEditPopup then
recipeEditPopup.selected = zone.arg
end
elseif zone.id == "recipe_edit_apply" then
if recipeEditPopup and recipeEditPopup.selected then
local rec
if recipeEditPopup.fluid then
rec = recipeEditPopup.fluidRecipeRef
if rec then
rec.machine_name = recipeEditPopup.selected
syncFluidItemStubs()
saveData()
end
recipeEditPopup = nil
else
if recipeEditPopup.altIdx then
local alts = AltRecipes[recipeEditPopup.item]
rec = alts and alts[recipeEditPopup.altIdx]
else
rec = Recipes[recipeEditPopup.item]
end
if rec then
rec.machine_name = recipeEditPopup.selected
rec.imported = nil
if rec.type == "fluid" and rec.fluid_key then
local fr = FluidRecipes[rec.fluid_key]
if fr then fr.machine_name = recipeEditPopup.selected; fr.imported = nil end
syncFluidItemStubs()
end
saveData()
end
recipeEditPopup = nil
end
end
elseif zone.id == "recipe_edit_global" then
if recipeEditPopup then
recipeEditPopup.confirmGlobal = true
end
elseif zone.id == "recipe_edit_confirm_global" then
if recipeEditPopup and recipeEditPopup.selected then
local oldMachine = recipeEditPopup.origMachine
local newMachine = recipeEditPopup.selected
local function replaceMachInRec(rData)
if not rData then return end
local chg = false
if rData.machine_name == oldMachine then rData.machine_name = newMachine; chg = true end
if rData.output_device == oldMachine then rData.output_device = newMachine; chg = true end
if rData.actions then
for _, act in ipairs(rData.actions) do
if act.device == oldMachine then act.device = newMachine; chg = true end
end
end
if chg then rData.imported = nil end
end
if recipeEditPopup.isItemScope then
local iRec = Recipes[recipeEditPopup.item]
replaceMachInRec(iRec)
if iRec and iRec.type == "fluid" and iRec.fluid_key then
replaceMachInRec(FluidRecipes[iRec.fluid_key])
end
for _, rData in ipairs(AltRecipes[recipeEditPopup.item] or {}) do
replaceMachInRec(rData)
end
else
for _, rData in pairs(Recipes) do replaceMachInRec(rData) end
for _, alts in pairs(AltRecipes or {}) do
for _, rData in ipairs(alts) do replaceMachInRec(rData) end
end
for _, fr in pairs(FluidRecipes or {}) do replaceMachInRec(fr) end
for _, alts in pairs(FluidAltRecipes or {}) do
for _, fr in ipairs(alts) do replaceMachInRec(fr) end
end
end
syncFluidItemStubs()
saveData()
recipeEditPopup = nil
end
elseif zone.id == "close_recipe_edit" then
if recipeEditPopup then
if recipeEditPopup.confirmGlobal then
recipeEditPopup.confirmGlobal = false
else
recipeEditPopup = nil
end
end
elseif zone.id == "recipe_edit_prev" then
if recipeEditPopup then
recipeEditPopup.page = math.max(1, (recipeEditPopup.page or 1) - 1)
end
elseif zone.id == "recipe_edit_next" then
if recipeEditPopup then
recipeEditPopup.page = (recipeEditPopup.page or 1) + 1
end
elseif zone.id == "trigger_search" then
searchInputActive = true
drawInterface()
term.clear() term.setCursorPos(1,1)
write("Enter Search query: ")
local srInput = timedRead(5)
searchInputActive = false
if srInput ~= nil and srInput ~= "" then searchFilter = srInput end
currentPage = 1
elseif zone.id == "clear_search" then
searchFilter = ""
currentPage = 1
elseif zone.id == "stock_mod" then
stockModFilter = zone.arg
currentPage = 1
elseif zone.id == "stock_mod_prev" then
stockModFilterPage = math.max(1, stockModFilterPage - 1)
elseif zone.id == "stock_mod_next" then
stockModFilterPage = stockModFilterPage + 1
elseif zone.id == "stock_search" then
stockSearchInputActive = true
drawInterface()
term.clear() term.setCursorPos(1,1)
write("Stock search: ")
local stInput = timedRead(5)
stockSearchInputActive = false
if stInput ~= nil and stInput ~= "" then stockSearchFilter = stInput end
currentPage = 1
elseif zone.id == "stock_clear_search" then
stockSearchFilter = ""
currentPage = 1
elseif zone.id == "pull_from_box" then
local moved = pullAllFromTrainBox()
if moved > 0 then
invalidateStockCache()
uiMessage = "Unloaded " .. moved .. " items from train box"
else
uiMessage = "Train box is empty or not reachable"
end
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(3)
unloadActive = true
if unloadTimer then os.cancelTimer(unloadTimer) end
unloadTimer = os.startTimer(4)
elseif zone.id == "stock_optimize" then
local isTankOpt = (stockModFilter == "TANK")
uiMessage = isTankOpt and "Optimizing tanks..." or "Optimizing storage..."
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(1)
optimizeActive = true
if optimizeTimer then os.cancelTimer(optimizeTimer) end
drawInterface()
if isTankOpt then optimizeFluidTanks() else optimizeStorages() end
invalidateStockCache()
uiMessage = isTankOpt and "Tanks optimized!" or "Storage optimized!"
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(3)
optimizeTimer = os.startTimer(3)
elseif zone.id == "vaults_run_defrag" then
    systemStatus = "DEFRAG"
    vaultOpPopup = {
        title = " STORAGE DEFRAGMENTATION ",
        status = "Balancing vaults and buffer...",
        message = "Sorting items into assigned homes...",
        done = false
    }
    drawInterface()
    sleep(0.05)

    local moved = StorageIndex.defragment()

    systemStatus = "IDLE"
    vaultOpPopup.status = "Defragmentation complete!"
    vaultOpPopup.message = "Items moved / balanced: " .. moved
    vaultOpPopup.done = true
    vaultOpPopup.timer = os.startTimer(3)
    drawInterface()

elseif zone.id == "vaults_rescan" then
    systemStatus = "RESCAN"
    vaultOpPopup = {
        title = " STORAGE RESCAN ",
        status = "Scanning all connected vaults...",
        message = "Rebuilding memory index...",
        done = false
    }
    drawInterface()
    sleep(0.05)

    local pruned = StorageIndex.init(true)

    local vCount = 0
    for vName, en in pairs(Config.main_vaults or {}) do
        if en and not SYSTEM_SIDES[vName] then vCount = vCount + 1 end
    end

    systemStatus = "IDLE"
    vaultOpPopup.status = "Rescan complete!"
    if pruned and #pruned > 0 then
        local pNames = {}
        for _, pn in ipairs(pruned) do
            table.insert(pNames, getMachineDisplay(pn))
        end
        local pStr = table.concat(pNames, ", ")
        if #pStr > 22 then pStr = pStr:sub(1, 20) .. ".." end
        vaultOpPopup.message = string.format("Indexed %d vaults. Cleaned: %s", vCount, pStr)
    else
        vaultOpPopup.message = string.format("Indexed %d vaults (%d total items)", vCount, StorageIndex.totalItems or 0)
    end
    vaultOpPopup.done = true
    vaultOpPopup.timer = os.startTimer(4)
    drawInterface()

elseif zone.id == "close_vault_popup" then
    if vaultOpPopup and vaultOpPopup.timer then os.cancelTimer(vaultOpPopup.timer) end
    vaultOpPopup = nil
elseif zone.id == "open_qty_picker" then
itemToCraft = zone.arg
fluidCraftMode = nil
fluidKeepName = nil
isSettingKeepLimit = false
isRequestMode = false
qtyOriginTab = currentTab
local pickerSnap = getStorageInventoryCached()
craftQuantity = pickerSnap[zone.arg] or 0
pickerMaxCraftable = 0
pickerMaxCapped = false
pickerMaxComputed = false
if Config.autoMaxCalc ~= false then pickerComputeMax() end
currentTab = "QUANTITY_PICKER"
elseif zone.id == "open_keep_picker" then
itemToCraft = zone.arg
fluidCraftMode = nil
fluidKeepName = nil
local ex = Autostock[zone.arg]
keepThr = (ex and (ex.threshold or ex.limit)) or 64
keepTgt = (ex and (ex.target or ex.limit)) or (keepThr * 2)
keepField = "threshold"
isSettingKeepLimit = true
isRequestMode = false
qtyOriginTab = "RECIPES"
currentTab = "QUANTITY_PICKER"
elseif zone.id == "keep_edit" then
itemToCraft = zone.arg
local ex = Autostock[zone.arg]
keepThr = (ex and (ex.threshold or ex.limit)) or 64
keepTgt = (ex and (ex.target or ex.limit)) or (keepThr * 2)
keepField = "threshold"
isSettingKeepLimit = true
isRequestMode = false
fluidKeepName = (zone.arg:sub(1, 2) == "f:") and fluidNameFromKey(zone.arg) or nil
qtyOriginTab = "KEEP"
currentTab = "QUANTITY_PICKER"
elseif zone.id == "open_req_picker" then
itemToCraft = zone.arg
fluidCraftMode = nil
fluidKeepName = nil
local inv = getStorageInventoryCached()
requestMaxQty = inv[zone.arg] or 0
craftQuantity = math.min(1, requestMaxQty)
isSettingKeepLimit = false
isRequestMode = true
qtyOriginTab = currentTab
currentTab = "QUANTITY_PICKER"
elseif zone.id == "qty_adj" then
if isSettingKeepLimit then
if keepField == "threshold" then
keepThr = math.max(1, keepThr + zone.arg)
else
keepTgt = math.max(1, keepTgt + zone.arg)
end
else
if isRequestMode then
craftQuantity = math.max(1, math.min(craftQuantity + zone.arg, requestMaxQty))
elseif fluidCraftMode then
craftQuantity = math.max(0, craftQuantity + zone.arg)
if pickerMaxComputed and pickerMaxCraftable < FLUID_MAX_CAP then
craftQuantity = math.min(craftQuantity, pickerMaxCraftable)
end
else
local curStock = (itemToCraft and (getStorageInventoryCached())[itemToCraft]) or 0
craftQuantity = math.max(curStock, craftQuantity + zone.arg)
if pickerMaxComputed and pickerMaxCraftable < ITEM_MAX_CAP then
craftQuantity = math.min(craftQuantity, curStock + pickerMaxCraftable)
end
end
end
elseif zone.id == "qty_calc_max" then
if not pickerMaxComputed then pickerComputeMax() end
elseif zone.id == "qty_toggle_automax" then
Config.autoMaxCalc = (Config.autoMaxCalc == false)
saveData()
if Config.autoMaxCalc then
pickerComputeMax()
else
pickerMaxComputed = false
pickerMaxCraftable = 0
end
elseif zone.id == "qty_max" then
if isRequestMode then
craftQuantity = requestMaxQty
else
if not pickerMaxComputed then pickerComputeMax() end
if fluidCraftMode then
craftQuantity = pickerMaxCraftable
else
local curStock = (itemToCraft and (getStorageInventoryCached())[itemToCraft]) or 0
craftQuantity = curStock + pickerMaxCraftable
end
end
elseif zone.id == "qty_cancel" then
isRequestMode = false
isSettingKeepLimit = false
fluidCraftMode = nil
fluidKeepName = nil
if queueEditIdx then queueEditIdx = nil; craftQueuePopup = true end
currentTab = qtyOriginTab or "RECIPES"
elseif zone.id == "qty_add_queue" then
local qe = nil
if fluidCraftMode then
if craftQuantity > 0 then
qe = {kind = "fluid", name = fluidCraftMode.target, qty = craftQuantity,
recipe = fluidCraftMode.recipe, isItem = fluidCraftMode.isItem}
end
fluidCraftMode = nil
elseif not isRequestMode and not isSettingKeepLimit and craftQuantity > 0 then
qe = {kind = "item", name = itemToCraft, qty = craftQuantity}
end
if qe then
craftQueue[#craftQueue + 1] = qe
uiMessage = "Queued: " .. (qe.name:match(":(.+)$") or qe.name) .. " x" .. qe.qty
end
currentTab = qtyOriginTab or "RECIPES"
elseif zone.id == "keep_field" then
keepField = zone.arg
elseif zone.id == "qty_type" then
qtyTypeActive = true
drawInterface()
term.clear(); term.setCursorPos(1, 1)
write("Enter quantity: ")
local input = timedRead(30)
qtyTypeActive = false
local num = tonumber(input)
if num then
if isSettingKeepLimit then
local v = math.max(1, math.floor(num))
if keepField == "threshold" then keepThr = v else keepTgt = v end
else
if isRequestMode then
craftQuantity = math.max(1, math.min(math.floor(num), requestMaxQty))
elseif fluidCraftMode then
craftQuantity = math.max(0, math.floor(num))
if pickerMaxComputed and pickerMaxCraftable < FLUID_MAX_CAP then
craftQuantity = math.min(craftQuantity, pickerMaxCraftable)
end
else
local curStock = (itemToCraft and (getStorageInventoryCached())[itemToCraft]) or 0
craftQuantity = math.max(curStock, math.floor(num))
if pickerMaxComputed and pickerMaxCraftable < ITEM_MAX_CAP then
craftQuantity = math.min(craftQuantity, curStock + pickerMaxCraftable)
end
end
end
end
elseif zone.id == "open_queue" then
craftQueuePopup = not craftQueuePopup
craftQueueErrIdx = nil
elseif zone.id == "queue_close" then
craftQueuePopup = false
craftQueueErrIdx = nil
elseif zone.id == "queue_top" then
local qi = zone.arg
if qi > 1 and craftQueue[qi] then
local qe = table.remove(craftQueue, qi)
table.insert(craftQueue, 1, qe)
craftQueueErrIdx = nil
craftQueueScroll = 0
end
elseif zone.id == "queue_up" then
local qi = zone.arg
if qi > 1 and craftQueue[qi] then
craftQueue[qi], craftQueue[qi - 1] = craftQueue[qi - 1], craftQueue[qi]
if craftQueueErrIdx == qi then craftQueueErrIdx = qi - 1
elseif craftQueueErrIdx == qi - 1 then craftQueueErrIdx = qi end
end
elseif zone.id == "queue_dn" then
local qi = zone.arg
if craftQueue[qi] and craftQueue[qi + 1] then
craftQueue[qi], craftQueue[qi + 1] = craftQueue[qi + 1], craftQueue[qi]
if craftQueueErrIdx == qi then craftQueueErrIdx = qi + 1
elseif craftQueueErrIdx == qi + 1 then craftQueueErrIdx = qi end
end
elseif zone.id == "queue_del" then
if craftQueue[zone.arg] then
table.remove(craftQueue, zone.arg)
craftQueueErrIdx = nil
end
elseif zone.id == "queue_err" then
if craftQueueErrIdx == zone.arg then craftQueueErrIdx = nil
else craftQueueErrIdx = zone.arg end
elseif zone.id == "queue_scroll" then
craftQueueScroll = math.max(0, craftQueueScroll + zone.arg)
elseif zone.id == "queue_edit" then
local qe = craftQueue[zone.arg]
if qe then
queueEditIdx = zone.arg
craftQueuePopup = false
craftQueueErrIdx = nil
itemToCraft = qe.name
craftQuantity = qe.qty
isSettingKeepLimit = false
isRequestMode = false
fluidCraftMode = nil
fluidKeepName = nil
pickerMaxCraftable = 0
pickerMaxCapped = false
pickerMaxComputed = false
if qe.kind ~= "fluid" and Config.autoMaxCalc ~= false then pickerComputeMax() end
qtyOriginTab = (currentTab ~= "QUANTITY_PICKER") and currentTab or "RECIPES"
currentTab = "QUANTITY_PICKER"
end
elseif zone.id == "queue_craft" then
local qe = craftQueue[zone.arg]
if qe then
craftQueuePopup = false
craftQueueErrIdx = nil
drawInterface()
systemStatus = "MANUAL_CRAFT"
craftErrorLines = {}; craftErrorTitle = nil
local okQ, reason = queueRunOne(qe)
if okQ then
table.remove(craftQueue, zone.arg)
else
qe.failed = reason
end
systemStatus = "IDLE"
craftErrorLines = {}; craftErrorTitle = nil
craftQueuePopup = true
end
elseif zone.id == "queue_runall" then
if #craftQueue > 0 then
craftQueuePopup = false
craftQueueErrIdx = nil
drawInterface()
systemStatus = "MANUAL_CRAFT"
local qi = 1
while qi <= #craftQueue do
cancelCrafting = false
craftErrorLines = {}; craftErrorTitle = nil
local qe = craftQueue[qi]
local okQ, reason = queueRunOne(qe)
if okQ then
table.remove(craftQueue, qi)
else
qe.failed = reason
qi = qi + 1
end
if cancelCrafting then break end
drawInterface()
end
systemStatus = "IDLE"
craftErrorLines = {}; craftErrorTitle = nil
craftQueuePopup = true
end
elseif zone.id == "popup_close" then
if craftCompletePopup and craftCompletePopup.timer then os.cancelTimer(craftCompletePopup.timer) end
craftCompletePopup = nil
elseif zone.id == "popup_request" then
local popItem = craftCompletePopup and craftCompletePopup.item
if craftCompletePopup and craftCompletePopup.timer then os.cancelTimer(craftCompletePopup.timer) end
craftCompletePopup = nil
if popItem and Config.train_box and Config.train_box ~= "" then
local inv = getStorageInventoryCached()
requestMaxQty = inv[popItem] or 0
itemToCraft = popItem
fluidCraftMode = nil
fluidKeepName = nil
craftQuantity = math.max(1, requestMaxQty)
isSettingKeepLimit = false
isRequestMode = true
qtyOriginTab = "RECIPES"
currentTab = "QUANTITY_PICKER"
end
elseif zone.id == "select_device" then
if outputPickMode then
if zone.arg == selectedCraftType then
selectedOutputDevice = nil
else
selectedOutputDevice = zone.arg
end
outputPickMode = false
else
selectedCraftType = zone.arg
selectedOutputDevice = nil
if zone.arg ~= "turtle" then craftSubTab = "MACHINES" end
end
elseif zone.id == "qty_confirm" then
if queueEditIdx then
local qe = craftQueue[queueEditIdx]
if qe and craftQuantity > 0 then
qe.qty = craftQuantity
qe.failed = nil
end
queueEditIdx = nil
craftQueueErrIdx = nil
currentTab = qtyOriginTab or "RECIPES"
craftQueuePopup = true
elseif fluidCraftMode then
local fcm = fluidCraftMode
fluidCraftMode = nil
currentTab = qtyOriginTab or "RECIPES"
if craftQuantity > 0 then
local isFl = not fcm.isItem
for hi = #craftHistory, 1, -1 do
local he = craftHistory[hi]
if he.item == fcm.target and (he.fluid or false) == isFl then
table.remove(craftHistory, hi)
end
end
table.insert(craftHistory, 1, {item = fcm.target, qty = craftQuantity, fluid = isFl})
if #craftHistory > 30 then table.remove(craftHistory) end
local fOk, fProduced, fIsItem = runFluidCraftAmount(fcm.recipe, fcm.target, craftQuantity)
if fOk then notifyCraftDone(fcm.target, fProduced, not fIsItem) else notifyCraftFail(fcm.target) end
end
elseif isRequestMode then
local qty = math.min(craftQuantity, requestMaxQty)
if qty > 0 then
local moved = deliverToTrainBox(itemToCraft, qty)
local name  = itemToCraft:match(":(.+)$") or itemToCraft
if moved > 0 then
invalidateStockCache()
uiMessage = "Delivered " .. moved .. "x " .. name .. " to train box."
else
uiMessage = "ERR: nothing moved. Check train box."
end
end
isRequestMode = false
currentTab = qtyOriginTab or "RECIPES"
elseif isSettingKeepLimit then
local existingOrder  = Autostock[itemToCraft] and Autostock[itemToCraft].order
local existingPaused = Autostock[itemToCraft] and Autostock[itemToCraft].paused or false
if not existingOrder then
local maxOrder = 0
for _, s in pairs(Autostock) do
maxOrder = math.max(maxOrder, s.order or 0)
end
existingOrder = maxOrder + 1
end
local thr = math.max(1, keepThr)
local tgt = math.max(thr, keepTgt)
Autostock[itemToCraft] = { threshold = thr, target = tgt, paused = existingPaused, order = existingOrder }
saveData()
isSettingKeepLimit = false
fluidKeepName = nil
currentTab = qtyOriginTab or "RECIPES"
else
currentTab = qtyOriginTab or "RECIPES"
local preSnapH  = getStorageInventory()
local preStockH = groupAvailable(itemToCraft, preSnapH, false)
for hi = #craftHistory, 1, -1 do
if craftHistory[hi].item == itemToCraft then
table.remove(craftHistory, hi)
end
end
table.insert(craftHistory, 1, {item=itemToCraft, qty=craftQuantity})
if #craftHistory > 30 then table.remove(craftHistory) end
drawInterface()
systemStatus = "MANUAL_CRAFT"
cancelCrafting = false
invalidateStockCache()
local plan, missingRes, blockedComps = planProduction(itemToCraft, craftQuantity, true)
local missingMachines = {}
local missingMachineSteps = {}
if plan and #plan > 0 then
local seen = {}
for _, step in ipairs(plan) do
if step.type ~= "turtle" and step.machine_name and step.machine_name ~= ""
and step.count and step.count > 0 then
local mOk, mMiss = checkMachineAvailable(step)
if not mOk then
local missDev = mMiss or step.machine_name
if not seen[missDev] then
seen[missDev] = true
table.insert(missingMachines, missDev)
table.insert(missingMachineSteps, step.item)
end
end
end
end
end
if #missingMachines > 0 then
craftErrorTitle = "! MACHINE NOT FOUND"
craftErrorLines = {}
craftErrorEditItems = {}
for mi, mName in ipairs(missingMachines) do
if mi <= 4 then
local mDisp = getMachineDisplay(mName)
local itemShort = missingMachineSteps[mi]:match(":(.+)$") or missingMachineSteps[mi]
table.insert(craftErrorLines, mDisp .. "  ->  " .. itemShort)
craftErrorEditItems[#craftErrorLines] = missingMachineSteps[mi]
end
end
if #missingMachines > 4 then
table.insert(craftErrorLines, "... and " .. (#missingMachines - 4) .. " more")
end
table.insert(craftErrorLines, "Use [E] in RECIPES to reassign.")
systemStatus = "IDLE"
craftHistory[1].qty = 0
triggerCraftError("! MACHINE NOT FOUND", craftErrorLines, 10)
elseif next(missingRes) then
craftHistory[1].qty = 0
systemStatus = "IDLE"
craftErrorTitle = "! NEED"
craftErrorLines = {}
local shownCount = 0
local totalMissing = 0
for _ in pairs(missingRes) do totalMissing = totalMissing + 1 end
for missingItem, countMissing in pairs(missingRes) do
if shownCount < 6 then
local mName = getItemDisplayName(missingItem)
table.insert(craftErrorLines, mName .. ": x" .. countMissing)
shownCount = shownCount + 1
end
end
if totalMissing > shownCount then
table.insert(craftErrorLines, "... and " .. (totalMissing - shownCount) .. " more")
end
local blockedList = {}
for bItem in pairs(blockedComps) do
table.insert(blockedList, getItemDisplayName(bItem))
end
table.sort(blockedList)
if #blockedList > 0 then
local joined = table.concat(blockedList, ", ")
if #joined > 30 then
table.insert(craftErrorLines, "Can't craft:")
table.insert(craftErrorLines, "  " .. joined)
else
table.insert(craftErrorLines, "Can't craft: " .. joined)
end
end
triggerCraftError("! NEED", craftErrorLines, 10)
elseif plan and #plan == 0 then
craftHistory[1].qty = 0
local inv = getStorageInventory()
local curAmt = inv[itemToCraft] or 0
if craftCompletePopup and craftCompletePopup.timer then os.cancelTimer(craftCompletePopup.timer) end
craftCompletePopup = {item=itemToCraft, count=curAmt, timer=os.startTimer(10)}
systemStatus = "IDLE"
else
if plan and #plan > 0 then
local craftOk = runCraftingProcess(plan)
local tlAttempts = 0
while craftOk and not cancelCrafting and tlAttempts < 12 do
flushCraftBuffer()
invalidateStockCache()
local totalNow = groupAvailable(itemToCraft, getStorageInventory(), false)
if totalNow >= craftQuantity then break end
tlAttempts = tlAttempts + 1
local rPlan = planProduction(itemToCraft, craftQuantity, true)
if not (rPlan and #rPlan > 0) then break end
local beforeTL = totalNow
if runCraftingProcess(rPlan) then craftOk = true end
flushCraftBuffer()
invalidateStockCache()
if groupAvailable(itemToCraft, getStorageInventory(), false) <= beforeTL then break end
end
flushCraftBuffer()
invalidateStockCache()
local inv = getStorageInventory()
local curAmt = inv[itemToCraft] or 0
local postStockH = groupAvailable(itemToCraft, inv, false)
craftHistory[1].qty = math.max(0, postStockH - preStockH)
if craftOk then
if craftCompletePopup and craftCompletePopup.timer then os.cancelTimer(craftCompletePopup.timer) end
craftCompletePopup = {item=itemToCraft, count=curAmt, timer=os.startTimer(10)}
notifyCraftDone(itemToCraft, craftHistory[1].qty, false)
clearCraftError()
else
notifyCraftFail(itemToCraft)
triggerCraftError(craftErrorTitle or "! CANNOT CRAFT", craftErrorLines, 10)
end
else
craftHistory[1].qty = 0
end
systemStatus = "IDLE"
end
end
elseif zone.id == "add_recipe_action" then
systemStatus = "MANUAL_CRAFT"
uiMessage = runMachineRecipeSearch()
systemStatus = "IDLE"
pendingTouches = {}
elseif zone.id == "learn_save_as_alt" then
if learnedResult then
local mName = (learnedCraftType == "turtle") and "turtle" or learnedMachineName
local toolsCopy = nil
if learnedTools and next(learnedTools) then
toolsCopy = {}
for tn in pairs(learnedTools) do toolsCopy[tn] = true end
end
local recipeData = {
type = learnedCraftType, machine_name = learnedMachineName,
output_count = learnedResult.count, method = mName,
ingredients = learnedIngredients,
output_device = learnedOutputDevice,
tools = toolsCopy
}
local targetName = learnedResult.name
if not AltRecipes[targetName] then AltRecipes[targetName] = {} end
table.insert(AltRecipes[targetName], recipeData)
saveData()
uiMessage = "Alt added: " .. (targetName:match(":(.+)$") or targetName)
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(3)
end
clearLearnTurtle()
learningState = "IDLE"
elseif zone.id == "comp_mode_normal" then
compositeDraft.mode = "normal"
elseif zone.id == "comp_mode_chance" then
compositeDraft.mode = "chance"
elseif zone.id == "comp_change_target" then
compositePopup = { mode = "pick_device", target = "target", page = 1 }
elseif zone.id == "comp_change_output" then
compositePopup = { mode = "pick_device", target = "output", page = 1 }
elseif zone.id == "comp_reset_output" then
compositeDraft.outputPlatform = nil
elseif zone.id == "comp_clear_actions" then
compositeDraft.actions = {}
compositeDraft.actPage = 1
elseif zone.id == "comp_act_prev" then
compositeDraft.actPage = math.max(1, (compositeDraft.actPage or 1) - 1)
elseif zone.id == "comp_act_next" then
compositeDraft.actPage = (compositeDraft.actPage or 1) + 1
elseif zone.id == "comp_add_action" then
compositePopup = { mode = "add_action" }
elseif zone.id == "comp_new_item_action" then
table.insert(compositeDraft.actions, { type = "item", device = nil, item = nil, count = 1, is_tool = false })
compositeDraft.actPage = #compositeDraft.actions
compositePopup = { mode = "pick_device", target = "action_device", actionIdx = #compositeDraft.actions, page = 1 }
elseif zone.id == "comp_new_fluid_action" then
table.insert(compositeDraft.actions, { type = "fluid", device = nil, fluid = nil, amount = 250 })
compositeDraft.actPage = #compositeDraft.actions
compositePopup = { mode = "pick_device", target = "action_device", actionIdx = #compositeDraft.actions, page = 1 }
elseif zone.id == "comp_act_toggle_tool" then
local act = compositeDraft.actions[zone.arg]
if act and act.type == "item" then
act.is_tool = not (act.is_tool == true)
if act.is_tool then
if act.item and act.item ~= "" then
act.item = parseItemKey(act.item)
act.durability = act.durability or getWholeToolDurability(act.item)
else
act.durability = act.durability or 250
end
end
end
elseif zone.id == "comp_act_dev" then
compositePopup = { mode = "pick_device", target = "action_device", actionIdx = zone.arg, page = 1 }
elseif zone.id == "comp_act_item" then
local act = compositeDraft.actions[zone.arg]
if act then
if act.type == "item" then
compositePopup = { mode = "pick_item", target = "action_item", actionIdx = zone.arg, page = 1 }
else
compositePopup = { mode = "pick_fluid", target = "action_fluid", actionIdx = zone.arg, page = 1 }
end
end
elseif zone.id == "comp_act_del" then
table.remove(compositeDraft.actions, zone.arg)
elseif zone.id == "comp_act_adj" then
local act = compositeDraft.actions[zone.arg[1]]
if act then
if act.type == "item" and act.is_tool then
act.durability = math.max(1, (act.durability or getWholeToolDurability(act.item)) + zone.arg[2])
elseif act.type == "item" then
act.count = math.max(1, (act.count or 1) + zone.arg[2])
else
act.amount = math.max(50, (act.amount or 250) + zone.arg[2])
end
end
elseif zone.id == "comp_act_num" then
local act = compositeDraft.actions[zone.arg]
if act then
drawInterface()
term.clear(); term.setCursorPos(1,1)
if act.type == "item" and act.is_tool then
write("Whole tool durability: ")
local inp = read()
local n = tonumber(inp)
if n and n >= 1 then act.durability = math.floor(n) end
elseif act.type == "item" then
write("Action count: ")
local inp = read()
local n = tonumber(inp)
if n and n >= 1 then act.count = math.floor(n) end
else
write("Fluid amount (mB): ")
local inp = read()
local n = tonumber(inp)
if n and n >= 1 then act.amount = math.floor(n) end
end
end
elseif zone.id == "comp_start_test" then
systemStatus = "MANUAL_CRAFT"
uiMessage = runCompositeTestCraft(false)
systemStatus = "IDLE"
pendingTouches = {}
if uiMessage ~= "" then
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(4)
end
elseif zone.id == "comp_start_batch" then
systemStatus = "MANUAL_CRAFT"
uiMessage = runCompositeTestCraft(true)
systemStatus = "IDLE"
pendingTouches = {}
if uiMessage ~= "" then
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(4)
end
elseif zone.id == "comp_open_results" then
if compositeDraft.testDone or (#(compositeDraft.results or {}) > 0) then
compositePopup = { mode = "results", page = compositeDraft.resPage or 1 }
end
elseif zone.id == "comp_res_toggle_role" then
local res = compositeDraft.results and compositeDraft.results[zone.arg]
if res then
res.role = (res.role == "recipe") and "byproduct" or "recipe"
end
elseif zone.id == "comp_res_qty_adj" then
local res = compositeDraft.results and compositeDraft.results[zone.arg[1]]
if res then
res.count = math.max(1, (res.count or 1) + zone.arg[2])
end
elseif zone.id == "comp_res_qty_num" then
local res = compositeDraft.results and compositeDraft.results[zone.arg]
if res then
drawInterface()
term.clear(); term.setCursorPos(1,1)
write("Output count per craft: ")
local inp = read()
local n = tonumber(inp)
if n and n >= 1 then res.count = math.floor(n) end
end
elseif zone.id == "comp_res_chance" then
local res = compositeDraft.results and compositeDraft.results[zone.arg]
if res then
drawInterface()
term.clear(); term.setCursorPos(1,1)
write("Drop chance % (1-100, or '-' to reset): ")
local inp = read()
if inp then
local trimmed = inp:match("^%s*(.-)%s*$")
if trimmed == "-" then
res.chance = nil
else
local n = tonumber(trimmed)
if n and n >= 1 then
res.chance = math.max(1, math.min(100, math.floor(n)))
end
end
end
end
elseif zone.id == "comp_res_del" then
if compositeDraft.results and compositeDraft.results[zone.arg] then
table.remove(compositeDraft.results, zone.arg)
end
elseif zone.id == "comp_res_add_item" then
local retP = (compositePopup and compositePopup.page) or compositeDraft.resPage or 1
compositePopup = { mode = "pick_item", target = "result_item", page = 1, returnPage = retP }
elseif zone.id == "comp_res_base_adj" then
compositeDraft.baseCount = math.max(1, (compositeDraft.baseCount or 1) + zone.arg)
if compositeDraft.baseIngredients and compositeDraft.baseIngredients[1] then
    compositeDraft.baseIngredients[1].count = compositeDraft.baseCount
end
elseif zone.id == "comp_res_base_num" then
drawInterface()
term.clear(); term.setCursorPos(1,1)
if compositeDraft.baseIngredients and #compositeDraft.baseIngredients > 1 then
    print("Base ingredients per operation:")
    for bi_i, bi in ipairs(compositeDraft.baseIngredients) do
        print(string.format("[%d] %s x%d", bi_i, getItemDisplayName(bi.item), bi.count or 1))
    end
    print("Select ingredient (1-" .. #compositeDraft.baseIngredients .. "), or press Enter for #1:")
    local sel = read()
    local selIdx = tonumber(sel) or 1
    if selIdx >= 1 and selIdx <= #compositeDraft.baseIngredients then
        write("Enter count for " .. getItemDisplayName(compositeDraft.baseIngredients[selIdx].item) .. ": ")
        local n = tonumber(read())
        if n and n >= 1 then
            compositeDraft.baseIngredients[selIdx].count = math.floor(n)
            if selIdx == 1 then compositeDraft.baseCount = math.floor(n) end
        end
    end
else
    write("Base ingredient count per craft: ")
    local inp = read()
    local n = tonumber(inp)
    if n and n >= 1 then
        compositeDraft.baseCount = math.floor(n)
        if compositeDraft.baseIngredients and compositeDraft.baseIngredients[1] then
            compositeDraft.baseIngredients[1].count = math.floor(n)
        end
    end
end
elseif zone.id == "comp_res_prev" then
if compositePopup then
compositePopup.page = math.max(1, (compositePopup.page or 1) - 1)
compositeDraft.resPage = compositePopup.page
end
elseif zone.id == "comp_res_next" then
if compositePopup then
compositePopup.page = (compositePopup.page or 1) + 1
compositeDraft.resPage = compositePopup.page
end
elseif zone.id == "comp_res_save" then
local resList = compositeDraft.results or {}
local bIngs = compositeDraft.baseIngredients or {}
if #bIngs == 0 and compositeDraft.baseItem and compositeDraft.baseItem ~= "" then
    bIngs = { { item = compositeDraft.baseItem, count = compositeDraft.baseCount or 1 } }
end
local baseItem = bIngs[1] and bIngs[1].item or compositeDraft.baseItem
local baseCount = bIngs[1] and bIngs[1].count or (compositeDraft.baseCount or 1)
if baseItem and baseItem ~= "" and #resList > 0 then
local flatIngs = {}
for _, bi in ipairs(bIngs) do
    local bCnt = math.max(1, math.floor(tonumber(bi.count) or 1))
    for _ = 1, bCnt do flatIngs[#flatIngs + 1] = bi.item end
end
local flatFluids = {}
local toolsMap = {}
local actionsCopy = {}
for _, act in ipairs(compositeDraft.actions or {}) do
if act.type == "item" and act.item and act.item ~= "" then
if act.is_tool then
local bKey = parseItemKey(act.item)
local dur = math.max(1, math.floor(tonumber(act.durability) or getWholeToolDurability(bKey)))
act.item = bKey
act.durability = dur
toolsMap[bKey] = { durability = dur }
flatIngs[#flatIngs + 1] = bKey
table.insert(actionsCopy, {
type = "item", device = act.device, item = bKey,
count = 1, is_tool = true, durability = dur
})
else
local cnt = math.max(1, math.floor(tonumber(act.count) or 1))
for _ = 1, cnt do flatIngs[#flatIngs + 1] = act.item end
table.insert(actionsCopy, {
type = "item", device = act.device, item = act.item,
count = cnt, is_tool = false
})
end
elseif act.type == "fluid" and act.fluid and act.fluid ~= "" then
local amt = math.max(1, math.floor(tonumber(act.amount) or 250))
table.insert(flatFluids, { name = act.fluid, amount = amt })
table.insert(actionsCopy, {
type = "fluid", device = act.device, fluid = act.fluid, amount = amt
})
end
end

local resultsSnap = {}
for _, o in ipairs(resList) do
local oCh = (compositeDraft.mode == "chance" and o.chance and tonumber(o.chance) and tonumber(o.chance) > 0)
and math.max(1, math.min(100, math.floor(tonumber(o.chance)))) or nil
table.insert(resultsSnap, {
item   = o.item,
count  = math.max(1, math.floor(tonumber(o.count) or 1)),
role   = o.role,
chance = oCh
})
end

local outDev = (compositeDraft.outputPlatform and compositeDraft.outputPlatform ~= "" and compositeDraft.outputPlatform ~= compositeDraft.targetPlatform)
and compositeDraft.outputPlatform or nil
local savedNames = {}
local altRedirect = nil

local baseIngsCopy = {}
for _, bi in ipairs(bIngs) do
    table.insert(baseIngsCopy, {
        item = bi.item,
        count = math.max(1, math.floor(tonumber(bi.count) or 1))
    })
end

local function baseIngredientsMatch(r1, r2BaseItem, r2BaseIngs)
    if not r1 then return false end
    if r1.base_ingredients and #r1.base_ingredients > 0 and r2BaseIngs and #r2BaseIngs > 0 then
        if #r1.base_ingredients ~= #r2BaseIngs then return false end
        for idx = 1, #r1.base_ingredients do
            if r1.base_ingredients[idx].item ~= r2BaseIngs[idx].item then return false end
        end
        return true
    end
    return (r1.base_ingredient and r1.base_ingredient.item == r2BaseItem)
end

for _, res in ipairs(resultsSnap) do
if res.role == "recipe" and res.item and res.item ~= "" then
local targetName = res.item
local byproductsList = {}
for _, o in ipairs(resultsSnap) do
if o.item ~= targetName then
table.insert(byproductsList, {
item   = o.item,
count  = o.count,
chance = o.chance
})
end
end
local sRate = (compositeDraft.mode == "chance" and res.chance) and res.chance or nil
local ingCopy = {}
for ii = 1, #flatIngs do ingCopy[ii] = flatIngs[ii] end
local rd = {
type = "composite",
machine_name = compositeDraft.targetPlatform,
output_device = outDev,
base_source = "barrel",
base_ingredients = baseIngsCopy,
base_ingredient = {
item = baseItem,
count = baseCount
},
actions = actionsCopy,
ingredients = ingCopy,
fluid_inputs = (#flatFluids > 0) and flatFluids or nil,
tools = next(toolsMap) and toolsMap or nil,
mode = (sRate and sRate < 100) and "chance" or "normal",
studio_mode = compositeDraft.mode or "normal",
success_rate = sRate,
chance = sRate and (sRate / 100) or nil,
output_count = res.count,
method = compositeDraft.targetPlatform,
byproducts = (#byproductsList > 0) and byproductsList or nil,
results = resultsSnap
}

local updatedInPlace = false
if compositeDraft.editingItem == targetName then
if compositeDraft.editingAltIdx and AltRecipes[targetName] and AltRecipes[targetName][compositeDraft.editingAltIdx] then
AltRecipes[targetName][compositeDraft.editingAltIdx] = rd
updatedInPlace = true
elseif Recipes[targetName] then
Recipes[targetName] = rd
updatedInPlace = true
end
end
if not updatedInPlace then
local ex = Recipes[targetName]
if type(ex) == "table" and ex.type == "composite" and ex.machine_name == rd.machine_name
and baseIngredientsMatch(ex, baseItem, baseIngsCopy) then
Recipes[targetName] = rd
updatedInPlace = true
elseif AltRecipes[targetName] then
for ai, aRec in ipairs(AltRecipes[targetName]) do
if type(aRec) == "table" and aRec.type == "composite" and aRec.machine_name == rd.machine_name
and baseIngredientsMatch(aRec, baseItem, baseIngsCopy) then
AltRecipes[targetName][ai] = rd
updatedInPlace = true
break
end
end
end
end
if not updatedInPlace then
local ex = Recipes[targetName]
if learnAsAlt or (type(ex) == "table" and ex.type ~= "fluid") then
AltRecipes[targetName] = AltRecipes[targetName] or {}
table.insert(AltRecipes[targetName], rd)
if not altRedirect then altRedirect = targetName end
else
Recipes[targetName] = rd
end
end
table.insert(savedNames, getItemDisplayName(targetName))
end
end

if #savedNames > 0 then
saveData()
compositePopup = nil
if learnAsAlt then
learnAsAlt = false
learnAsAltItem = nil
end
if altRedirect then
altViewItem = altRedirect
currentTab = "ALT_VIEW"
end
uiMessage = "Saved: " .. table.concat(savedNames, ", ")
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(4)
drawInterface()
end
end
elseif zone.id == "comp_reset" then
compositeDraft = {
baseSource = "barrel",
targetPlatform = nil,
outputPlatform = nil,
mode = "normal",
baseItem = nil,
baseCount = 1,
baseIngredients = {},
actions = {},
actPage = 1,
results = {},
resPage = 1,
testDone = false,
editingItem = nil,
editingAltIdx = nil
}
compositePopup = nil
uiMessage = "Studio reset."
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(3)
elseif zone.id == "comp_popup_cancel" then
if compositePopup and compositePopup.target == "result_item" then
compositePopup = { mode = "results", page = compositePopup.returnPage or 1 }
else
compositePopup = nil
end
elseif zone.id == "comp_popup_prev" then
if compositePopup then compositePopup.page = math.max(1, (compositePopup.page or 1) - 1) end
elseif zone.id == "comp_popup_next" then
if compositePopup then compositePopup.page = (compositePopup.page or 1) + 1 end
elseif zone.id == "comp_barrel_refresh" then
if compositePopup then compositePopup.page = 1 end
elseif zone.id == "comp_search_focus" then
if compositePopup then
compositePopup.searchActive = true
drawInterface()
term.clear() term.setCursorPos(1, 1)
write("Search item: ")
local srInput = timedRead(5)
compositePopup.searchActive = false
if srInput ~= nil then
compositePopup.search = srInput
end
compositePopup.page = 1
end
elseif zone.id == "comp_search_clear" then
if compositePopup then
compositePopup.search = ""
compositePopup.page = 1
end
elseif zone.id == "comp_select_device" then
if compositePopup then
if compositePopup.target == "target" then
compositeDraft.targetPlatform = zone.arg
compositePopup = nil
elseif compositePopup.target == "output" then
if zone.arg == "__RESET_SAME__" then
compositeDraft.outputPlatform = nil
else
compositeDraft.outputPlatform = zone.arg
end
compositePopup = nil
elseif compositePopup.target == "action_device" then
local act = compositeDraft.actions[compositePopup.actionIdx]
if act then
act.device = zone.arg
if act.type == "item" then
compositePopup = { mode = "pick_item", target = "action_item", actionIdx = compositePopup.actionIdx, page = 1 }
else
compositePopup = { mode = "pick_fluid", target = "action_fluid", actionIdx = compositePopup.actionIdx, page = 1 }
end
else
compositePopup = nil
end
end
end
elseif zone.id == "comp_select_item" then
if compositePopup then
if compositePopup.target == "action_item" then
local act = compositeDraft.actions[compositePopup.actionIdx]
if act then
local picked = zone.arg
if isKnownToolItem(picked) then
act.is_tool = true
act.item = parseItemKey(picked)
act.durability = getWholeToolDurability(act.item)
else
act.item = picked
if act.is_tool then
act.item = parseItemKey(picked)
act.durability = act.durability or getWholeToolDurability(act.item)
end
end
end
compositePopup = nil
elseif compositePopup.target == "result_item" then
local picked = zone.arg
local retP = compositePopup.returnPage or 1
compositeDraft.results = compositeDraft.results or {}
local exists = false
for _, r in ipairs(compositeDraft.results) do
if r.item == picked then exists = true break end
end
if not exists then
table.insert(compositeDraft.results, {
item   = picked,
count  = 1,
role   = (#compositeDraft.results == 0) and "recipe" or "byproduct",
chance = nil
})
compositeDraft.testDone = true
end
compositePopup = { mode = "results", page = retP }
end
end
elseif zone.id == "comp_select_fluid" then
if compositePopup then
local act = compositeDraft.actions[compositePopup.actionIdx]
if act then act.fluid = zone.arg end
compositePopup = nil
end
elseif zone.id == "learn_edit" then
learningState = "IDLE"
learnedResult = nil
learnedOutputs = nil
uiMessage = "Returned to editor with setup intact."
if uiMsgTimer then os.cancelTimer(uiMsgTimer) end
uiMsgTimer = os.startTimer(3)
drawInterface()
elseif zone.id == "learn_save" then
if learnedResult then
local mName = (learnedCraftType == "turtle") and "turtle" or learnedMachineName
local toolsCopy = nil
if learnedTools and next(learnedTools) then
toolsCopy = {}
for tn in pairs(learnedTools) do toolsCopy[tn] = true end
end
local recipeData = {
type = learnedCraftType, machine_name = learnedMachineName,
output_count = learnedResult.count, method = mName,
ingredients = learnedIngredients,
output_device = learnedOutputDevice,
tools = toolsCopy
}
if learnAsAlt then
local targetName = learnedResult.name
if not AltRecipes[targetName] then AltRecipes[targetName] = {} end
table.insert(AltRecipes[targetName], recipeData)
saveData()
altViewItem = targetName
currentTab = "ALT_VIEW"
learnAsAlt = false
learnAsAltItem = nil
else
local outs = (learnedCraftType ~= "turtle" and learnedOutputs and #learnedOutputs > 0)
and learnedOutputs or {{name = learnedResult.name, count = learnedResult.count}}
local altSaved = nil
for _, o in ipairs(outs) do
local ingCopy = {}
for ii = 1, #learnedIngredients do ingCopy[ii] = learnedIngredients[ii] end
local toolCopy2 = nil
if learnedTools and next(learnedTools) then
toolCopy2 = {}
for tn in pairs(learnedTools) do toolCopy2[tn] = true end
end
local rd = {
type = learnedCraftType, machine_name = learnedMachineName,
output_count = o.count, method = mName,
ingredients = ingCopy,
output_device = learnedOutputDevice,
tools = toolCopy2
}
local ex = Recipes[o.name]
if type(ex) == "table" and ex.type ~= "fluid" then
AltRecipes[o.name] = AltRecipes[o.name] or {}
table.insert(AltRecipes[o.name], rd)
if not altSaved then altSaved = o.name end
else
Recipes[o.name] = rd
end
end
saveData()
if altSaved then
altViewItem = altSaved
currentTab = "ALT_VIEW"
end
end
end
clearLearnTurtle()
learnedResult = nil
learnedOutputs = nil
learningState = "IDLE"
drawInterface()
elseif zone.id == "learn_cancel" then
clearLearnTurtle()
learnedResult = nil
learnedOutputs = nil
learningState = "IDLE"
if learnAsAlt then
currentTab = "ALT_VIEW"
learnAsAlt = false
learnAsAltItem = nil
end
drawInterface()
elseif zone.id == "machine_label" then
local mName = zone.arg
local cur = MachineLabels[mName] or ""
drawInterface()
term.clear(); term.setCursorPos(1,1)
local mId = mName:match(":(.+)$") or mName
write(mId .. " label (Enter=clear): ")
local lbl = timedRead(15)
if lbl ~= nil then
if lbl == "" then
MachineLabels[mName] = nil
else
MachineLabels[mName] = lbl
end
saveData()
end
elseif zone.id == "group_exclude" then
ExcludedMachines[zone.arg] = true
saveData()
elseif zone.id == "group_include" then
ExcludedMachines[zone.arg] = nil
saveData()
elseif zone.id == "cgrp_new" then
custGrpPopup = {editIdx=nil, name="", selected={}, page=1}
elseif zone.id == "cgrp_edit" then
local cg = CustomMachineGroups[zone.arg]
if cg then
local sel = {}
for _, m in ipairs(cg.machines) do sel[m] = true end
custGrpPopup = {editIdx=zone.arg, name=cg.name, selected=sel, page=1}
end
elseif zone.id == "cgrp_del" then
table.remove(CustomMachineGroups, zone.arg)
saveData()
elseif zone.id == "cgrp_remove" then
local gIdx2 = zone.arg[1]
local mDel  = zone.arg[2]
local cg2   = CustomMachineGroups[gIdx2]
if cg2 then
for mi2, mc in ipairs(cg2.machines) do
if mc == mDel then table.remove(cg2.machines, mi2); break end
end
if #cg2.machines == 0 then
table.remove(CustomMachineGroups, gIdx2)
end
saveData()
end
elseif zone.id == "cgrp_toggle" or zone.id == "grp_toggle" then
    local key = zone.arg
    if key then expandedGroups[key] = not expandedGroups[key] end
elseif zone.id == "cgrp_popup_name" then
if custGrpPopup then
drawInterface()
term.clear(); term.setCursorPos(1,1)
write("Group name: ")
local inp = read()
if inp and inp ~= "" then custGrpPopup.name = inp end
end
elseif zone.id == "cgrp_popup_toggle" then
if custGrpPopup then
local mn = zone.arg
if custGrpPopup.selected[mn] then
custGrpPopup.selected[mn] = nil
else
custGrpPopup.selected[mn] = true
end
end
elseif zone.id == "cgrp_popup_prev" then
if custGrpPopup then
custGrpPopup.page = math.max(1, (custGrpPopup.page or 1) - 1)
end
elseif zone.id == "cgrp_popup_next" then
if custGrpPopup then
custGrpPopup.page = (custGrpPopup.page or 1) + 1
end
elseif zone.id == "cgrp_popup_cancel" then
custGrpPopup = nil
elseif zone.id == "cgrp_popup_save" then
if custGrpPopup then
local gName3 = custGrpPopup.name
if gName3 == "" then gName3 = "Group " .. (#CustomMachineGroups + 1) end
local machList = {}
for mn, _ in pairs(custGrpPopup.selected) do
table.insert(machList, mn)
end
table.sort(machList)
local newCG = {name=gName3, machines=machList}
if custGrpPopup.editIdx then
CustomMachineGroups[custGrpPopup.editIdx] = newCG
else
table.insert(CustomMachineGroups, newCG)
end
custGrpPopup = nil
saveData()
end
elseif zone.id == "mgmt_sync_now" then
mgmtSyncFlashTime = os.clock()
runMgmtTransfers()
elseif zone.id == "mgmt_new" then
mgmtPopup = {
mode="edit", groupIdx=nil,
name="", input="STORAGE", output="STORAGE", rules={},
inputs={}, outputs={},
drain=false, provider=false,
step="main", periPage=1, outPeriPage=1, itemPage=1,
}
elseif zone.id == "mgmt_edit" then
local g = MgmtGroups[zone.arg]
if g then
mgmtActiveBtn = nil
local rc = {}
for _, r in ipairs(g.rules or {}) do
local rcond = nil
if r.condition then
rcond = {item=r.condition.item, op=r.condition.op, value=r.condition.value}
end
table.insert(rc, {item=r.item, amount=r.amount, condition=rcond})
end
local inl, outl = {}, {}
for _, nm in ipairs(mgmtIOList(g, true))  do if nm ~= "STORAGE" then inl[#inl+1]  = nm end end
for _, nm in ipairs(mgmtIOList(g, false)) do if nm ~= "STORAGE" then outl[#outl+1] = nm end end
mgmtPopup = {
mode="edit", groupIdx=zone.arg,
name=g.name,
input  = g.input  or "STORAGE",
output = g.output or "STORAGE",
inputs = inl, outputs = outl,
rules=rc,
drain  = g.drain  or false,
provider = g.provider or false,
fluid  = mgmtGroupIsFluid(g),
step="main", periPage=1, outPeriPage=1, itemPage=1,
openerGi=zone.arg, openerBtn="edit",
}
end
elseif zone.id == "mgmt_pause" then
local g = MgmtGroups[zone.arg]
if g then
g.paused = not (g.paused or false)
mgmtActiveBtn = {gi=zone.arg, btn="pause", t=os.clock()}
saveData()
end
elseif zone.id == "mgmt_del" then
mgmtActiveBtn = nil
table.remove(MgmtGroups, zone.arg)
saveData()
elseif zone.id == "mgmt_view" then
local g = MgmtGroups[zone.arg]
if g then
mgmtActiveBtn = nil
mgmtPopup = {mode="view_input", groupIdx=zone.arg, page=1,
openerGi=zone.arg, openerBtn="view"}
end
elseif zone.id == "mgmt_list_prev" then mgmtPage = math.max(1, mgmtPage - 1)
elseif zone.id == "mgmt_list_next" then mgmtPage = mgmtPage + 1
elseif zone.id == "mgmt_edit_name" then
if mgmtPopup then
drawInterface()
term.clear(); term.setCursorPos(1,1)
write("Group name: ")
local inp = read()
if inp and inp ~= "" then mgmtPopup.name = inp end
end
elseif zone.id == "mgmt_rule_type" then
if mgmtPopup then
local ri3t = zone.arg
local rule = mgmtPopup.rules[ri3t]
if rule then
drawInterface()
term.clear(); term.setCursorPos(1,1)
write("Amount for " .. (rule.item:match(":(.+)$") or rule.item) .. ": ")
local inp = read()
local n = tonumber(inp)
if n and n >= 1 then rule.amount = math.floor(n) end
end
end
elseif zone.id == "mgmt_pick_input" then
if mgmtPopup then mgmtPopup.step = "input_select"; mgmtPopup.periPage = 1 end
elseif zone.id == "mgmt_set_input" then
if mgmtPopup then
local lst = mgmtPopup.inputs or {}
if zone.arg == "STORAGE" then
lst = {}
else
local found
for i, nm in ipairs(lst) do if nm == zone.arg then found = i; break end end
if found then table.remove(lst, found) else lst[#lst + 1] = zone.arg end
end
mgmtPopup.inputs = lst
mgmtPopup.input  = lst[1] or "STORAGE"
mgmtPopup.fluid = mgmtIsFluidPeriph(mgmtPopup.input) or mgmtIsFluidPeriph(mgmtPopup.output)
end
elseif zone.id == "mgmt_peri_prev" then
if mgmtPopup then mgmtPopup.periPage = math.max(1, mgmtPopup.periPage - 1) end
elseif zone.id == "mgmt_peri_next" then
if mgmtPopup then mgmtPopup.periPage = mgmtPopup.periPage + 1 end
elseif zone.id == "mgmt_peri_cancel" then
if mgmtPopup then mgmtPopup.step = "main" end
elseif zone.id == "mgmt_pick_output" then
if mgmtPopup then mgmtPopup.step = "output_select"; mgmtPopup.outPeriPage = 1 end
elseif zone.id == "mgmt_set_output" then
if mgmtPopup then
local lst = mgmtPopup.outputs or {}
if zone.arg == "STORAGE" then
lst = {}
else
local found
for i, nm in ipairs(lst) do if nm == zone.arg then found = i; break end end
if found then table.remove(lst, found) else lst[#lst + 1] = zone.arg end
end
mgmtPopup.outputs = lst
mgmtPopup.output  = lst[1] or "STORAGE"
mgmtPopup.fluid = mgmtIsFluidPeriph(mgmtPopup.input) or mgmtIsFluidPeriph(mgmtPopup.output)
end
elseif zone.id == "mgmt_pick_item" then
if mgmtPopup then
mgmtPopup.step = "item_select"; mgmtPopup.itemPage = 1
mgmtItemSearch = ""; mgmtItemSearchActive = false
end
elseif zone.id == "mgmt_add_rule" then
if mgmtPopup then
local condIdx = mgmtPopup.condPickRuleIdx
if condIdx then
local rule = mgmtPopup.rules[condIdx]
if rule then
if not rule.condition then rule.condition = {op="<", value=1} end
rule.condition.item = zone.arg
end
mgmtPopup.condPickRuleIdx = nil
else
local exists = false
for _, r in ipairs(mgmtPopup.rules) do
if r.item == zone.arg then exists = true; break end
end
if not exists then
table.insert(mgmtPopup.rules, {item=zone.arg, amount=(mgmtPopup.fluid and 1000 or 64)})
end
end
mgmtPopup.step = "main"
end
elseif zone.id == "mgmt_item_prev" then
if mgmtPopup then mgmtPopup.itemPage = math.max(1, mgmtPopup.itemPage - 1) end
elseif zone.id == "mgmt_item_next" then
if mgmtPopup then mgmtPopup.itemPage = mgmtPopup.itemPage + 1 end
elseif zone.id == "mgmt_rules_prev" then
if mgmtPopup then mgmtPopup.rulesPage = math.max(1, (mgmtPopup.rulesPage or 1) - 1) end
elseif zone.id == "mgmt_rules_next" then
if mgmtPopup then mgmtPopup.rulesPage = (mgmtPopup.rulesPage or 1) + 1 end
elseif zone.id == "mgmt_item_cancel" then
if mgmtPopup then
mgmtPopup.condPickRuleIdx = nil
mgmtPopup.step = "main"
end
elseif zone.id == "mgmt_rule_adj" then
if mgmtPopup then
local ri3  = zone.arg[1]
local delta = zone.arg[2]
local rule = mgmtPopup.rules[ri3]
if rule then
local stepU = mgmtPopup.fluid and 100 or 1
local capU  = mgmtPopup.fluid and 1000000 or 9999
rule.amount = math.max(1, math.min(capU, rule.amount + delta * stepU))
end
end
elseif zone.id == "mgmt_rule_del" then
if mgmtPopup then table.remove(mgmtPopup.rules, zone.arg) end
elseif zone.id == "mgmt_toggle_drain" then
if mgmtPopup then
mgmtPopup.drain = not (mgmtPopup.drain or false)
if mgmtPopup.drain then mgmtPopup.provider = false end
end
elseif zone.id == "mgmt_toggle_provider" then
if mgmtPopup then
mgmtPopup.provider = not (mgmtPopup.provider or false)
if mgmtPopup.provider then mgmtPopup.drain = false end
end
elseif zone.id == "mgmt_rule_if_add" then
if mgmtPopup then
local ri = zone.arg
local rule = mgmtPopup.rules[ri]
if rule then
rule.condition = {item = "", op = "<", value = 1}
mgmtPopup.condPickRuleIdx = ri
mgmtPopup.step = "item_select"
mgmtPopup.itemPage = 1
mgmtItemSearch = ""
mgmtItemSearchActive = false
end
end
elseif zone.id == "mgmt_rule_if_item" then
if mgmtPopup then
mgmtPopup.condPickRuleIdx = zone.arg
mgmtPopup.step = "item_select"
mgmtPopup.itemPage = 1
mgmtItemSearch = ""
mgmtItemSearchActive = false
end
elseif zone.id == "mgmt_rule_if_op" then
if mgmtPopup then
local rule = mgmtPopup.rules[zone.arg]
if rule and rule.condition then
local ops = {"<", "=", ">"}
local cur = rule.condition.op or "<"
for i, op in ipairs(ops) do
if op == cur then
rule.condition.op = ops[(i % #ops) + 1]
break
end
end
end
end
elseif zone.id == "mgmt_rule_if_adj" then
if mgmtPopup then
local rule = mgmtPopup.rules[zone.arg[1]]
if rule and rule.condition then
local stepC = mgmtPopup.fluid and 100 or 1
local capC  = mgmtPopup.fluid and 1000000 or 99999
rule.condition.value = math.max(1, math.min(capC,
(rule.condition.value or 1) + zone.arg[2] * stepC))
end
end
elseif zone.id == "mgmt_rule_if_type" then
if mgmtPopup then
local rule = mgmtPopup.rules[zone.arg]
if rule and rule.condition then
local cName = rule.condition.item:match(":(.+)$") or rule.condition.item
drawInterface()
term.clear(); term.setCursorPos(1,1)
write("IF value for " .. cName .. ": ")
local inp = read()
local n = tonumber(inp)
if n and n >= 1 then rule.condition.value = math.floor(n) end
end
end
elseif zone.id == "mgmt_rule_if_del" then
if mgmtPopup then
local rule = mgmtPopup.rules[zone.arg]
if rule then rule.condition = nil end
end
elseif zone.id == "mgmt_outperi_prev" then
if mgmtPopup then mgmtPopup.outPeriPage = math.max(1, (mgmtPopup.outPeriPage or 1) - 1) end
elseif zone.id == "mgmt_outperi_next" then
if mgmtPopup then mgmtPopup.outPeriPage = (mgmtPopup.outPeriPage or 1) + 1 end
elseif zone.id == "mgmt_outperi_cancel" then
if mgmtPopup then mgmtPopup.step = "main" end
elseif zone.id == "mgmt_save" then
if mgmtPopup then
if mgmtPopup.name == "" then
uiMessage = "Enter a group name first!"
uiMsgTimer = os.startTimer(2)
else
local inl  = mgmtPopup.inputs  or {}
local outl = mgmtPopup.outputs or {}
local newG = {
name   = mgmtPopup.name,
inputs = inl,
outputs = outl,
input  = inl[1]  or "STORAGE",
output = outl[1] or "STORAGE",
rules  = mgmtPopup.rules  or {},
drain  = mgmtPopup.drain  or false,
provider = mgmtPopup.provider or false,
fluid  = mgmtPopup.fluid or mgmtGroupIsFluid({input=inl[1] or "STORAGE", output=outl[1] or "STORAGE"}),
paused = mgmtPopup.groupIdx and (MgmtGroups[mgmtPopup.groupIdx] and MgmtGroups[mgmtPopup.groupIdx].paused or false) or false,
}
if mgmtPopup.groupIdx then
MgmtGroups[mgmtPopup.groupIdx] = newG
else
table.insert(MgmtGroups, newG)
end
saveData()
if mgmtPopup.openerGi and mgmtPopup.openerBtn then
mgmtActiveBtn = {gi=mgmtPopup.openerGi, btn=mgmtPopup.openerBtn, t=os.clock()}
end
mgmtPopup = nil
end
end
elseif zone.id == "mgmt_cancel" then
if mgmtPopup and mgmtPopup.openerGi and mgmtPopup.openerBtn then
mgmtActiveBtn = {gi=mgmtPopup.openerGi, btn=mgmtPopup.openerBtn, t=os.clock()}
end
mgmtPopup = nil
elseif zone.id == "mgmt_close_view" then
if mgmtPopup and mgmtPopup.openerGi and mgmtPopup.openerBtn then
mgmtActiveBtn = {gi=mgmtPopup.openerGi, btn=mgmtPopup.openerBtn, t=os.clock()}
end
mgmtPopup = nil
elseif zone.id == "mgmt_vinput_prev" then
if mgmtPopup then mgmtPopup.page = math.max(1, mgmtPopup.page - 1) end
elseif zone.id == "mgmt_vinput_next" then
if mgmtPopup then mgmtPopup.page = mgmtPopup.page + 1 end
elseif zone.id == "mgmt_search_focus" then
mgmtItemSearchActive = true
drawInterface()
term.clear() term.setCursorPos(1,1)
write("> ")
local srInput = timedRead(5)
mgmtItemSearchActive = false
if srInput ~= nil then
mgmtItemSearch = srInput
end
if mgmtPopup then mgmtPopup.itemPage = 1 end
elseif zone.id == "mgmt_search_clear" then
mgmtItemSearch = ""
if mgmtPopup then mgmtPopup.itemPage = 1 end
end
break
end
end
end
end
end
function runMain()
    initDataFiles()
    loadData()
    syncFluidItemStubs()
    StorageIndex.init() -- <--- Initialization call
    parallel.waitForAny(
        function()
            while true do
                local ev, p1, p2, p3 = os.pullEvent("monitor_touch")
                if systemStatus == "IDLE" then
                    pendingTouches[#pendingTouches + 1] = {ev, p1, p2, p3}
                    if #pendingTouches > 5 then table.remove(pendingTouches, 1) end
                end
            end
        end,
        function()
            while true do
                local ev, ch = os.pullEvent()
                local noPopup = not custGrpPopup and not mgmtPopup
                and craftInfoPopup == nil and machineInfoPopup == nil
                and historyPopup == nil and recipeEditPopup == nil
                and craftCompletePopup == nil and pendingDeleteItem == nil
                and not remotePopup and not networkFilterPopup
                local fluidSearchable = currentTab == "FLUID" and (fluidSubTab == "FLUID" or fluidSubTab == "FITEM")
                and not fluidRecipePicker and not fluidCraftWaitFluid
                if ev == "char" and noPopup then
                    if currentTab == "RECIPES" then
                        searchFilter = searchFilter .. ch
                        currentPage = 1
                    elseif currentTab == "STOCK" then
                        stockSearchFilter = stockSearchFilter .. ch
                        currentPage = 1
                    elseif fluidSearchable then
                        fluidSearchFilter = fluidSearchFilter .. ch
                        fluidRecipePage = 1
                    end
                elseif ev == "key" and noPopup and ch == keys.backspace then
                    if currentTab == "RECIPES" and #searchFilter > 0 then
                        searchFilter = searchFilter:sub(1, -2)
                        currentPage = 1
                    elseif currentTab == "STOCK" and #stockSearchFilter > 0 then
                        stockSearchFilter = stockSearchFilter:sub(1, -2)
                        currentPage = 1
                    elseif fluidSearchable and #fluidSearchFilter > 0 then
                        fluidSearchFilter = fluidSearchFilter:sub(1, -2)
                        fluidRecipePage = 1
                    end
                end
            end
        end,
        mainLoop,
        -- Background buffer flush
        function()
            while true do
                sleep(1.5)
                if not StorageIndex._ingestBusy and not StorageIndex.isDefragging then
                    pcall(StorageIndex.ingestBuffer)
                end
            end
        end,
        -- Logistics
        function()
            while true do
                sleep(3)
                if not StorageIndex.isDefragging and systemStatus ~= "RESCAN" then
                    pcall(runMgmtTransfers)
                end
            end
        end,
        -- Background reconciliation (when IDLE and not defragging/ingesting)
        function()
            while true do
                sleep(3)
                if systemStatus == "IDLE" and not StorageIndex.isDefragging and not StorageIndex._ingestBusy then
                    pcall(StorageIndex.reconcileNext)
                end
            end
        end,
        -- Ntfy commands
        function()
            while true do
                sleep(5)
                pcall(ntfyPollCommands)
            end
        end,
        -- Remote pocket computer server
        function()
            while true do
                if not ensureWirelessRednet() then
                    sleep(4)
                else
                    local senderId, msg, proto = rednet.receive("AEGIS_REMOTE", 0.5)
                    if senderId and type(msg) == "table" then
                        pcall(handleRemotePacket, senderId, msg)
                    end
                end
            end
        end,
        -- Remote craft queue worker
        function()
            while true do
                if #remoteCraftQueue > 0 and systemStatus == "IDLE" then
                    local task = table.remove(remoteCraftQueue, 1)
                    if task.kind == "item" then
                        systemStatus = "MANUAL_CRAFT"
                        pcall(queueRunOne, task)
                        systemStatus = "IDLE"
                    elseif task.kind == "check_autostock" then
                        pcall(checkAndRunAutostock)
                    end
                else
                    sleep(0.5)
                end
            end
        end
    )
end
while true do
local ok, err = pcall(runMain)
if not ok then
print("[AUTOCRAFT] Crashed: " .. tostring(err))
print("[AUTOCRAFT] Restarting in 3s...")
sleep(3)
end
end
