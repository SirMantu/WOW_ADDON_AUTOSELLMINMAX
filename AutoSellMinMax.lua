-- AutoSellMinMax
-- Auto-sells grey items (and items you register) when a vendor window opens,
-- and buys items from your auto-buy list until you carry the amount you set.

local ADDON = "AutoSellMinMax"

local defaults = {
    autoSellGrey = true,
    autoBuy = true,       -- top up the auto-buy list at vendors
    -- items sold in packs: "down" = never above the amount, "up" = never below it,
    -- "exact" = round up, then sell the surplus back (costs gold, not recommended)
    buyRounding = "down",
    perCharacter = true,  -- keep separate auto-sell / auto-buy lists for each character
    characters = {},      -- ["Name-Realm"] = { registered = {}, buy = {} }
    buy = {},             -- [itemID] = number of items to keep in the bags
    sortBags = true, -- clean up ("Taschen aufräumen") after looting and selling
    autoRepair = true,       -- repair all gear at vendors that can repair
    repairGuildFunds = false, -- pay repairs from the guild bank first, when allowed
    block = { [2] = true, [3] = true, [4] = true, [5] = true }, -- green, blue, epic, legendary
    registered = {},                                            -- [itemID] = true
    minimapAngle = 200, -- degrees around the minimap
}

local BUY_ICON = "Interface\\GossipFrame\\VendorGossipIcon" -- marks auto-buy items in the bags

local QUALITY_ROWS = {
    { q = 2, label = "Block selling |cff1eff00Uncommon (green)|r items" },
    { q = 3, label = "Block selling |cff0070ddRare (blue)|r items" },
    { q = 4, label = "Block selling |cffa335eeEpic (purple)|r items" },
    { q = 5, label = "Block selling |cffff8000Legendary (orange)|r items" },
}

local db
local bar, panel

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function OnOff(v)
    return v and "|cff00ff00ON|r" or "|cffff0000OFF|r"
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. ADDON .. "|r: " .. msg)
end

-- Newer clients moved these into C_Item and removed the globals.
local GetItemInfo = _G.GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local function CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
end

-- This character's own lists. Each list starts as a copy of the account-wide
-- list the first time it is used.
local function CharData()
    local key = CharKey()
    local c = db.characters[key]
    if not c then
        c = {}
        db.characters[key] = c
    end
    if not c.registered then
        c.registered = {}
        for id in pairs(db.registered) do c.registered[id] = true end
    end
    if not c.buy then
        c.buy = {}
        for id, n in pairs(db.buy) do c.buy[id] = n end
    end
    return c
end

-- The active auto-sell list: the account-wide one, or this character's own list.
local function Registered()
    if not db.perCharacter then return db.registered end
    return CharData().registered
end

-- The active auto-buy list ([itemID] = amount to keep).
local function BuyList()
    if not db.perCharacter then return db.buy end
    return CharData().buy
end

local function Pack(...)
    return { n = select("#", ...), ... }
end

local function GetItemInfoFields(item)
    local info = Pack(GetItemInfo(item))
    if not info[1] then return nil end

    if type(info[5]) == "string" then
        return {
            quality = info[3],
            itemType = info[5],
            maxStack = info[7],
            icon = info[9],
            sellPrice = info[10],
        }
    end
    return {
        quality = info[3],
        itemType = info[6],
        maxStack = info[8],
        icon = info[10],
        sellPrice = info[11],
        classID = info[12],
        bindType = info[14],
    }
end

local function GetItemIcon(itemID)
    if GetItemInfoInstant then
        local icon = select(5, GetItemInfoInstant(itemID))
        if icon then return icon end
    end
    local info = GetItemInfoFields(itemID)
    return info and info.icon
end

local function SetShown(frame, shown)
    if frame.SetShown then
        frame:SetShown(shown)
    elseif shown then
        frame:Show()
    else
        frame:Hide()
    end
end

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function GetNumSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bag)
    end
    return GetContainerNumSlots(bag)
end

local function GetSlotInfo(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then
            local link = info.hyperlink
            if not (link and link:find("item:", 1, true)) then
                -- some clients return only the item name here; fall back to a real link / the item ID
                link = (C_Container.GetContainerItemLink and C_Container.GetContainerItemLink(bag, slot))
                    or (GetContainerItemLink and GetContainerItemLink(bag, slot))
                if not (link and link:find("item:", 1, true)) then
                    link = info.itemID and ("item:" .. info.itemID) or link
                end
            end
            return link, info.stackCount, info.quality, info.hasNoValue
        end
        return nil
    end
    local _, count, _, quality, _, _, link, _, noValue = GetContainerItemInfo(bag, slot)
    link = link or (GetContainerItemLink and GetContainerItemLink(bag, slot))
    return link, count, quality, noValue
end

local function UseSlot(bag, slot)
    if C_Container and C_Container.UseContainerItem then
        C_Container.UseContainerItem(bag, slot)
    else
        UseContainerItem(bag, slot)
    end
end

local function ItemIDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

local function Money(copper)
    return GetCoinTextureString and GetCoinTextureString(copper) or (copper .. "c")
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

local RefreshOverlays, RefreshPanel

local function IsRegistered(itemID)
    return itemID and Registered()[itemID] or false
end

local QUALITY_LABELS = {
    [2] = "Uncommon (green)",
    [3] = "Rare (blue)",
    [4] = "Epic (purple)",
    [5] = "Legendary (orange)",
}

local function BlockedLabel(quality)
    if quality and quality >= 2 and db.block[quality] then
        return QUALITY_LABELS[quality]
    end
end

local function WarnBlocked(link, label)
    Print(link .. " is |cffff4040blocked|r: " .. label .. " items are protected, so it will NOT be sold.")
    Print("To unblock: open the options (minimap coin or /asmm) and untick |cffffd100Block selling " .. label .. " items|r.")
end

-- Number of stacks and total items of itemID across the player's bags.
local function CountStacks(itemID)
    local stacks, items = 0, 0
    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local link, count = GetSlotInfo(bag, slot)
            if link and ItemIDFromLink(link) == itemID then
                stacks = stacks + 1
                items = items + (count or 1)
            end
        end
    end
    return stacks, items
end

local QUEST_CLASS_ID = 12 -- Enum.ItemClass.Questitem
local BIND_QUEST = 4

local function IsQuestItem(itemID)
    local info = GetItemInfoFields(itemID)
    return info and (info.classID == QUEST_CLASS_ID or info.itemType == "Quest" or info.bindType == BIND_QUEST) or false
end

local function Register(itemID, link)
    if not (link and link:find("|H", 1, true)) then
        link = select(2, GetItemInfo(itemID)) or ("item " .. itemID)
    end
    if IsQuestItem(itemID) then
        Print(link .. " is a |cffff4040quest item|r and cannot be added to the auto-sell list.")
        return
    end
    if BuyList()[itemID] then
        BuyList()[itemID] = nil
        Print(link .. " was removed from the auto-buy list, because it is now on the auto-sell list.")
    end
    Registered()[itemID] = true
    local info = GetItemInfoFields(itemID)
    local label = BlockedLabel(info and info.quality)
    if label then WarnBlocked(link, label) end

    local stacks, items = CountStacks(itemID)
    if stacks > 1 then
        Print(string.format("|cffff4040Warning:|r you have %d stacks of %s (%d items). |cffffd100ALL stacks|r will be sold at the vendor, not just this one. Alt+Left-click it again to unregister.",
            stacks, link, items))
    end
end

local function ToggleRegister(itemID, link)
    if not itemID then return end
    local reg = Registered()
    if reg[itemID] then
        reg[itemID] = nil
    else
        Register(itemID, link)
    end
    RefreshOverlays()
    RefreshPanel()
end

local function ItemLink(itemID, link)
    if link and link:find("|H", 1, true) then return link end
    return select(2, GetItemInfo(itemID)) or ("item " .. itemID)
end

-- New auto-buy entries start with one full stack (1 for items that do not stack).
local function DefaultBuyAmount(itemID)
    local info = GetItemInfoFields(itemID)
    return math.max(1, info and info.maxStack or 1)
end

local function RegisterBuy(itemID, link)
    link = ItemLink(itemID, link)
    if Registered()[itemID] then
        Registered()[itemID] = nil
        Print(link .. " was removed from the auto-sell list, because it is now on the auto-buy list.")
    end
    local n = DefaultBuyAmount(itemID)
    BuyList()[itemID] = n
    Print(string.format("%s added to the auto-buy list: keeping |cffffd100%d|r in your bags. Change the amount in the options (minimap coin or /asmm).",
        link, n))
end

local function ToggleBuy(itemID, link)
    if not itemID then return end
    local list = BuyList()
    if list[itemID] then
        list[itemID] = nil
        Print(ItemLink(itemID, link) .. " removed from the auto-buy list.")
    else
        RegisterBuy(itemID, link)
    end
    RefreshOverlays()
    RefreshPanel()
end

---------------------------------------------------------------------------
-- Selling
---------------------------------------------------------------------------

local function ShouldSell(link, quality, hasNoValue)
    if not link or hasNoValue then return false end
    local itemID = ItemIDFromLink(link)
    if IsQuestItem(itemID) then return false end -- never sell quest items
    if itemID and BuyList()[itemID] then return false end -- never sell what we keep stocked
    local registered = IsRegistered(itemID)

    if quality == 0 then
        return db.autoSellGrey or registered
    end
    if registered then
        -- Registered items are sold unless their quality is protected.
        return not (quality and db.block[quality])
    end
    return false
end

local QUALITY_NAMES = {
    [0] = "|cff9d9d9dPoor (grey)|r",
    [1] = "|cffffffffCommon (white)|r",
    [2] = "|cff1eff00Uncommon (green)|r",
    [3] = "|cff0070ddRare (blue)|r",
    [4] = "|cffa335eeEpic (purple)|r",
    [5] = "|cffff8000Legendary (orange)|r",
}

local SELL_INTERVAL = 0.1-- seconds between sales; selling too fast makes the server drop requests
local sellTicker

local function NewTicker(interval, callback)
    if C_Timer and C_Timer.NewTicker then
        return C_Timer.NewTicker(interval, callback)
    end

    local ticker = { elapsed = 0, cancelled = false }
    local frame = CreateFrame("Frame")
    function ticker:Cancel()
        self.cancelled = true
        frame:SetScript("OnUpdate", nil)
    end
    frame:SetScript("OnUpdate", function(_, elapsed)
        if ticker.cancelled then return end
        ticker.elapsed = ticker.elapsed + elapsed
        if ticker.elapsed >= interval then
            ticker.elapsed = ticker.elapsed - interval
            callback()
        end
    end)
    return ticker
end

---------------------------------------------------------------------------
-- Bag clean-up ("Taschen aufräumen" / Sort Bags)
---------------------------------------------------------------------------

local sortPending = false
local sortTimer

local function SortBagsNow()
    if InCombatLockdown and InCombatLockdown() then
        sortPending = true -- retried when combat ends
        return
    end
    local fn = (C_Container and C_Container.SortBags) or _G.SortBags
    if fn then pcall(fn) end
end

-- Debounced: many loot messages in a row (e.g. AoE looting) lead to one clean-up.
local function RequestSort(delay)
    if not (db and db.sortBags) then return end
    if sortTimer then sortTimer:Cancel() end
    if C_Timer and C_Timer.NewTimer then
        sortTimer = C_Timer.NewTimer(delay or 0.5, function()
            sortTimer = nil
            if sellTicker then return end -- the end of selling triggers its own clean-up
            SortBagsNow()
        end)
    else
        SortBagsNow()
    end
end

local function StopSelling()
    if sellTicker then
        sellTicker:Cancel()
        sellTicker = nil
    end
end

-- The game's own "Sell All Junk Items" (newer clients); nil on clients without it.
local function GetSellAllJunk()
    local m = C_MerchantFrame
    if m and type(m.SellAllJunkItems) == "function" then return m.SellAllJunkItems end
end

---------------------------------------------------------------------------
-- Repairing
---------------------------------------------------------------------------

local merchantOpen = false

-- Can the guild bank pay `cost` for this player right now?
local function GuildCanPay(cost)
    if not (IsInGuild and IsInGuild()) then return false end
    if not (CanGuildBankRepair and CanGuildBankRepair()) then return false end
    local limit = GetGuildBankWithdrawMoney and GetGuildBankWithdrawMoney()
    local bank = GetGuildBankMoney and GetGuildBankMoney()
    -- a limit of -1 means "unlimited" (guild master)
    if limit and limit ~= -1 and limit < cost then return false end
    if bank and bank > 0 and bank < cost then return false end
    return true
end

-- Returns how much of the player's own gold was spent.
local function RepairItems()
    if not (db.autoRepair and merchantOpen) then return 0 end
    if not (CanMerchantRepair and CanMerchantRepair() and GetRepairAllCost and RepairAllItems) then return 0 end
    local cost, canRepair = GetRepairAllCost()
    if not (canRepair and cost and cost > 0) then return 0 end

    if db.repairGuildFunds and GuildCanPay(cost) then
        if pcall(RepairAllItems, true) then
            Print("Repaired all items for " .. Money(cost) .. " |cff40ff40(guild bank)|r.")
            return 0
        end
    end

    if GetMoney() < cost then
        Print(string.format("|cffff4040Not enough gold to repair:|r costs %s, you have %s.",
            Money(cost), Money(GetMoney())))
        return 0
    end
    RepairAllItems()
    Print("Repaired all items for " .. Money(cost) .. ".")
    return cost
end

local function After(delay, fn)
    if C_Timer and C_Timer.After then C_Timer.After(delay, fn) else fn() end
end

-- onDone runs once selling is finished (immediately if there was nothing to sell).
local function SellItems(onDone)
    StopSelling()
    local function Done(sold)
        if not onDone then return end
        -- after a sale give the server a moment so the earned gold counts for repairs
        if sold then After(0.5, onDone) else onDone() end
    end
    local sellJunk = db.autoSellGrey and GetSellAllJunk()
    local junkCount = 0
    local total = 0
    local items, gold = {}, {} -- indexed by quality
    local warned = {}
    local queue = {}
    for bag = 0, 4 do
        for slot = 1, GetNumSlots(bag) do
            local link, stack, quality, noValue = GetSlotInfo(bag, slot)
            local label = link and not noValue and IsRegistered(ItemIDFromLink(link)) and BlockedLabel(quality)
            if label and not warned[link] then
                warned[link] = true
                WarnBlocked(link, label)
            end
            if ShouldSell(link, quality, noValue) then
                local info = GetItemInfoFields(link)
                local sellPrice = info and info.sellPrice or 0
                if sellPrice > 0 then
                    local q, n = quality or 0, stack or 1
                    items[q] = (items[q] or 0) + n
                    gold[q] = (gold[q] or 0) + sellPrice * n
                    total = total + sellPrice * n
                    if sellJunk and quality == 0 then
                        junkCount = junkCount + 1 -- sold in one go by "Sell All Junk Items"
                    else
                        queue[#queue + 1] = { bag, slot, link }
                    end
                end
            end
        end
    end
    if #queue == 0 and junkCount == 0 then
        Done(false)
        return
    end

    local function Report()
        Print("sold items:")
        for q = 0, 5 do
            if items[q] then
                Print(string.format("  %s: %d item%s for %s", QUALITY_NAMES[q], items[q],
                    items[q] == 1 and "" or "s", Money(gold[q])))
            end
        end
        Print("Total earned: " .. Money(total))
    end
    local function Finish()
        Report()
        RequestSort(0.5)
        Done(true)
    end

    if junkCount > 0 then
        if not pcall(sellJunk) then
            -- fall back to selling the grey items one by one
            for bag = 0, 4 do
                for slot = 1, GetNumSlots(bag) do
                    local link, _, quality, noValue = GetSlotInfo(bag, slot)
                    if link and quality == 0 and not noValue and not IsQuestItem(ItemIDFromLink(link)) then
                        queue[#queue + 1] = { bag, slot, link }
                    end
                end
            end
        end
    end
    if #queue == 0 then
        Finish()
        return
    end

    local i = 0
    sellTicker = NewTicker(SELL_INTERVAL, function()
        i = i + 1
        local entry = queue[i]
        if not entry then
            StopSelling()
            Finish()
            return
        end
        local bag, slot, link = entry[1], entry[2], entry[3]
        local cur = GetSlotInfo(bag, slot)
        if cur == link then
            UseSlot(bag, slot)
        end
    end)
end

---------------------------------------------------------------------------
-- Buying (keep items from the auto-buy list stocked)
---------------------------------------------------------------------------

local GetItemCount = _G.GetItemCount or (C_Item and C_Item.GetItemCount)
local BUY_INTERVAL = 0.2 -- seconds between purchases
local buyTicker

local function StopBuying()
    if buyTicker then
        buyTicker:Cancel()
        buyTicker = nil
    end
end

-- Free slots in normal bags (special bags such as quivers or soul bags are not counted).
local function GetFreeSlots()
    local free = 0
    for bag = 0, 4 do
        local n, bagType
        if C_Container and C_Container.GetContainerNumFreeSlots then
            n, bagType = C_Container.GetContainerNumFreeSlots(bag)
        elseif GetContainerNumFreeSlots then
            n, bagType = GetContainerNumFreeSlots(bag)
        end
        if n and (bagType == nil or bagType == 0) then free = free + n end
    end
    return free
end

-- price per purchase, items per purchase, purchases left at this vendor (-1 = unlimited)
local function MerchantItemInfo(index)
    if C_MerchantFrame and type(C_MerchantFrame.GetItemInfo) == "function" then
        local i = C_MerchantFrame.GetItemInfo(index)
        if i then return i.price or 0, math.max(1, i.stackCount or 1), i.numAvailable or -1 end
    end
    local _, _, price, quantity, numAvailable = GetMerchantItemInfo(index)
    return price or 0, math.max(1, quantity or 1), numAvailable or -1
end

-- [itemID] = merchant index, for everything this vendor sells for gold.
local function MerchantItems()
    local byID = {}
    for index = 1, (GetMerchantNumItems and GetMerchantNumItems() or 0) do
        local id = ItemIDFromLink(GetMerchantItemLink(index))
        local tokens = GetMerchantItemCostInfo and GetMerchantItemCostInfo(index) or 0
        if id and not byID[id] and tokens == 0 then byID[id] = index end
    end
    return byID
end

local function SplitSlot(bag, slot, n)
    if C_Container and C_Container.SplitContainerItem then
        C_Container.SplitContainerItem(bag, slot, n)
    elseif SplitContainerItem then
        SplitContainerItem(bag, slot, n)
    end
end

local function PickupSlot(bag, slot)
    if C_Container and C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bag, slot)
    else
        PickupContainerItem(bag, slot)
    end
end

-- An empty slot in a normal bag (not a quiver, soul bag, ...).
local function FindEmptySlot()
    for bag = 0, 4 do
        local _, bagType
        if C_Container and C_Container.GetContainerNumFreeSlots then
            _, bagType = C_Container.GetContainerNumFreeSlots(bag)
        elseif GetContainerNumFreeSlots then
            _, bagType = GetContainerNumFreeSlots(bag)
        end
        if bagType == nil or bagType == 0 then
            for slot = 1, GetNumSlots(bag) do
                if not GetSlotInfo(bag, slot) then return bag, slot end
            end
        end
    end
end

-- "exact" mode: sell back everything above the amount you set.
-- items = { [itemID] = { target, index (merchant index), unitPrice } }
local function TrimSurplus(items)
    if not merchantOpen then return end
    local actions, report = {}, {}
    local lost = 0
    for id, e in pairs(items) do
        local surplus = (GetItemCount(id) or 0) - e.target
        local info = GetItemInfoFields(id)
        local sellPrice = info and info.sellPrice or 0
        if surplus > 0 and sellPrice > 0 then
            report[#report + 1] = { id = id, count = surplus, gold = sellPrice * surplus }
            lost = lost + math.max(0, e.unitPrice - sellPrice) * surplus
            -- smallest stacks first, so leftover partial stacks go before a full stack is split
            local slots = {}
            for bag = 0, 4 do
                for slot = 1, GetNumSlots(bag) do
                    local link, count = GetSlotInfo(bag, slot)
                    if link and ItemIDFromLink(link) == id then
                        slots[#slots + 1] = { bag = bag, slot = slot, count = count or 1 }
                    end
                end
            end
            table.sort(slots, function(a, b) return a.count < b.count end)
            for _, s in ipairs(slots) do
                if surplus <= 0 then break end
                local n = math.min(surplus, s.count)
                actions[#actions + 1] = { id = id, bag = s.bag, slot = s.slot, n = n, count = s.count, index = e.index }
                surplus = surplus - n
            end
        elseif surplus > 0 then
            Print(ItemLink(id) .. " cannot be sold to vendors, so the surplus is kept.")
        end
    end
    if #actions == 0 then
        RequestSort(0.5)
        return
    end

    local function Done()
        StopBuying()
        Print("|cffff8000exact amount:|r sold back the surplus:")
        for _, r in ipairs(report) do
            Print(string.format("  %dx %s for %s", r.count, ItemLink(r.id), Money(r.gold)))
        end
        if lost > 0 then
            Print("|cffff4040Lost to rounding:|r " .. Money(math.floor(lost + 0.5))
                .. " (bought price minus sell price). Switch to round down or up in the options to avoid this.")
        end
        -- tell the player if anything is still above the amount
        After(1.5, function()
            for id, e in pairs(items) do
                local have = GetItemCount(id) or 0
                if have > e.target then
                    Print(string.format("|cffff4040Could not sell all surplus|r of %s: you have %d, your amount is %d.",
                        ItemLink(id), have, e.target))
                end
            end
        end)
        RequestSort(0.5)
    end

    local MAX_TRIES = 10 -- ticks to wait for a locked slot (items are locked briefly after a purchase)
    local i, tries = 1, 0
    local pending -- surplus that was split into an empty slot and still has to be sold
    buyTicker = NewTicker(SELL_INTERVAL * 3, function()
        -- step 2 of a split: sell the slot the surplus was put into
        if pending then
            local link, count = GetSlotInfo(pending.bag, pending.slot)
            if link and ItemIDFromLink(link) == pending.id and (count or 1) == pending.n then
                UseSlot(pending.bag, pending.slot)
                pending = nil
            else
                pending.tries = pending.tries + 1
                if pending.tries > MAX_TRIES then pending = nil end
            end
            return
        end

        local a = actions[i]
        if not a then
            Done()
            return
        end
        local function Next() i, tries = i + 1, 0 end
        local function Retry()
            tries = tries + 1
            if tries > MAX_TRIES then Next() end
        end

        local link, count = GetSlotInfo(a.bag, a.slot)
        count = count or 1
        if not link or ItemIDFromLink(link) ~= a.id or count < a.n then return Retry() end
        if a.n >= count then
            UseSlot(a.bag, a.slot) -- sell the whole stack
            return Next()
        end

        -- split off the surplus: into an empty bag slot, then sell that slot (same way as normal selling)
        if CursorHasItem and CursorHasItem() then return Retry() end -- do not disturb what the player holds
        SplitSlot(a.bag, a.slot, a.n)
        if not (CursorHasItem and CursorHasItem()) then return Retry() end -- slot still locked
        local eb, es = FindEmptySlot()
        if eb then
            PickupSlot(eb, es)
            pending = { bag = eb, slot = es, n = a.n, id = a.id, tries = 0 }
        else
            PickupMerchantItem(a.index) -- no empty slot: drop it on the vendor instead
            if CursorHasItem and CursorHasItem() then ClearCursor() end
        end
        Next()
    end)
end

local function BuyItems(budget)
    StopBuying()
    if not (db.autoBuy and merchantOpen and GetItemCount) then return end
    local list = BuyList()
    if not next(list) then return end

    local sold = MerchantItems()
    local free = GetFreeSlots()
    local queue, bought, short, total = {}, {}, {}, 0
    local bagsFull = false
    local mode = db.buyRounding
    local roundUp = mode == "up" or mode == "exact"
    local exact = {} -- items to trim back to the exact amount afterwards ("exact" mode)

    local ids = {}
    for id in pairs(list) do ids[#ids + 1] = id end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local index = sold[id]
        local have = GetItemCount(id) or 0
        local need = list[id] - have
        if index and mode == "exact" then
            local price, bundle = MerchantItemInfo(index)
            exact[id] = { target = list[id], index = index, unitPrice = price / bundle }
        end
        if index and need > 0 then
            local price, bundle, available = MerchantItemInfo(index)
            local info = GetItemInfoFields(id)
            local maxStack = math.max(1, info and info.maxStack or 1)

            -- room: the rest of the last partial stack, then whole free bag slots
            local room = (have % maxStack == 0) and 0 or (maxStack - have % maxStack)
            if need > room then
                local slots = math.min(free, math.ceil((need - room) / maxStack))
                free = free - slots
                room = room + slots * maxStack
            end
            -- items sold in packs (e.g. 5 water) cannot hit every amount exactly:
            -- round down (default, never above the amount) or up (never below it)
            local purchases
            if need <= room then
                purchases = roundUp and math.ceil(need / bundle) or math.floor(need / bundle)
            else
                purchases = math.floor(room / bundle)
                bagsFull = true
            end
            if available >= 0 then purchases = math.min(purchases, available) end
            if price > 0 then
                local affordable = math.floor(math.max(0, budget) / price)
                if affordable < purchases then
                    purchases = affordable
                    short[#short + 1] = ItemLink(id)
                end
            end

            if purchases > 0 then
                local count = purchases * bundle
                budget = budget - purchases * price
                total = total + purchases * price
                bought[#bought + 1] = { id = id, count = count, cost = purchases * price }
                if bundle == 1 then
                    -- items sold one by one: buy up to a full stack per click
                    local perCall = math.max(1, (GetMerchantItemMaxStack and GetMerchantItemMaxStack(index)) or maxStack)
                    local left = count
                    while left > 0 do
                        local n = math.min(left, perCall)
                        queue[#queue + 1] = { index, id, n, list[id] }
                        left = left - n
                    end
                else
                    -- items sold in bundles: buy one bundle per click
                    for _ = 1, purchases do queue[#queue + 1] = { index, id, nil, list[id], bundle } end
                end
            end
        end
    end

    local function Finish()
        if #bought > 0 then
            Print("bought items:")
            for _, b in ipairs(bought) do
                Print(string.format("  %dx %s for %s", b.count, ItemLink(b.id), Money(b.cost)))
            end
            Print("Total spent: " .. Money(total))
        end
        for _, link in ipairs(short) do
            Print("|cffff4040Not enough gold|r to buy all of " .. link .. ".")
        end
        if bagsFull then
            Print("|cffff4040Bags full:|r could not buy everything on the auto-buy list.")
        end
        if next(exact) then
            -- wait until the bought items have arrived in the bags, then sell the surplus
            -- (bag clean-up runs after that, so it does not move items while we sell)
            After(1, function() TrimSurplus(exact) end)
        elseif #bought > 0 then
            RequestSort(0.5)
        end
    end

    if #queue == 0 then
        Finish()
        return
    end

    local i = 0
    buyTicker = NewTicker(BUY_INTERVAL, function()
        i = i + 1
        local entry = queue[i]
        if not entry then
            StopBuying()
            Finish()
            return
        end
        local index, id, n, target, bundle = entry[1], entry[2], entry[3], entry[4], entry[5]
        -- the vendor list can change (limited stock); only buy if the slot still holds our item
        if ItemIDFromLink(GetMerchantItemLink(index)) ~= id then return end
        -- check the bags again before every purchase, so we stop once the target is reached
        local have = GetItemCount(id) or 0
        if n then
            n = math.min(n, target - have)
            if n > 0 then BuyMerchantItem(index, n) end
        elseif (roundUp and have < target) or have + bundle <= target then
            BuyMerchantItem(index)
        end
    end)
end

---------------------------------------------------------------------------
-- Bag overlays (small coin on registered items)
---------------------------------------------------------------------------

local function ButtonBagSlot(button)
    local parent = button:GetParent()
    local bag = (button.GetBagID and button:GetBagID()) or (parent and parent.GetID and parent:GetID())
    local slot = button.GetID and button:GetID()
    return bag, slot
end

local debugClicks = false
local UpdateButtonOverlay
local function ToggleFromButton(button, buy)
    local bag, slot = ButtonBagSlot(button)
    if debugClicks then Print("toggle: bag=" .. tostring(bag) .. " slot=" .. tostring(slot) .. " link=" .. tostring((bag and slot) and GetSlotInfo(bag, slot))) end
    if not (bag and slot and bag >= 0 and bag <= 5) then return false end
    local link = GetSlotInfo(bag, slot)
    if not link then return false end
    local id = (C_Container and C_Container.GetContainerItemID and C_Container.GetContainerItemID(bag, slot))
        or (C_Container and C_Container.GetContainerItemInfo and (C_Container.GetContainerItemInfo(bag, slot) or {}).itemID)
        or ItemIDFromLink(link)
    if debugClicks then Print("toggle id=" .. tostring(id) .. " link=" .. tostring(link)) end
    local ok, err = pcall(buy and ToggleBuy or ToggleRegister, id, link)
    if not ok then Print("|cffff4040error:|r " .. tostring(err)) end
    if UpdateButtonOverlay then UpdateButtonOverlay(button) end
    return true
end

-- Alt+Left-click (auto-sell) and Ctrl+Alt+Left-click (auto-buy) detection that does not
-- depend on the bag UI's click handlers: on every mouse-down, look at what is under the cursor.
local function DebugFocus(button)
    Print("mouse-down: " .. tostring(button) .. " alt=" .. tostring(IsAltKeyDown()))
    local foci = (GetMouseFoci and GetMouseFoci()) or {}
    if #foci == 0 and GetMouseFocus then foci[1] = GetMouseFocus() end
    for i, focus in ipairs(foci) do
        local f = focus
        for depth = 1, 4 do
            if not f then break end
            local bagID = f.GetBagID and f:GetBagID()
            Print(string.format("  [%d.%d] name=%s type=%s id=%s bagID=%s", i, depth,
                tostring(f.GetName and f:GetName()), tostring(f.GetObjectType and f:GetObjectType()),
                tostring(f.GetID and f:GetID()), tostring(bagID)))
            f = f.GetParent and f:GetParent()
        end
    end
end

local function OnGlobalMouseDown(button)
    if debugClicks then DebugFocus(button) end
    if button ~= "LeftButton" or not IsAltKeyDown() or IsShiftKeyDown() then return end
    local buy = IsControlKeyDown() -- Ctrl+Alt (AltGr on many keyboards) = auto-buy list
    local foci = (GetMouseFoci and GetMouseFoci()) or {}
    if #foci == 0 and GetMouseFocus then foci[1] = GetMouseFocus() end
    for _, focus in ipairs(foci) do
        local f = focus
        for _ = 1, 3 do
            if not f then break end
            if f.GetBagID or (f.GetParent and f:GetParent() and f:GetParent().GetID and f:GetID()
                and f:GetID() > 0 and f:GetParent():GetID() <= 5 and f.GetObjectType
                and f:GetObjectType() == "Button") then
                if ToggleFromButton(f, buy) then return end
            end
            f = f.GetParent and f:GetParent()
        end
    end
end

local function HookButton() end

function UpdateButtonOverlay(button)
    if not button or not button.GetID then return end
    HookButton(button)
    local bag, slot = ButtonBagSlot(button)
    local show, buy = false, false
    if bag and slot then
        local id = ItemIDFromLink((GetSlotInfo(bag, slot)))
        show = IsRegistered(id)
        buy = id and BuyList()[id] and true or false
    end
    if show and not button.asmmCoin then
        local tex = button:CreateTexture(nil, "OVERLAY", nil, 7)
        tex:SetTexture("Interface/Icons/INV_Misc_Coin_01")
        tex:SetSize(14, 14)
        tex:SetPoint("TOPLEFT", 2, -2)
        button.asmmCoin = tex
    end
    if button.asmmCoin then SetShown(button.asmmCoin, show) end
    if buy and not button.asmmBuy then
        local tex = button:CreateTexture(nil, "OVERLAY", nil, 7)
        tex:SetTexture(BUY_ICON)
        tex:SetSize(14, 14)
        tex:SetPoint("TOPRIGHT", -2, -2)
        button.asmmBuy = tex
    end
    if button.asmmBuy then SetShown(button.asmmBuy, buy) end
end

local hookedFrames = {}

local function ProcessFrame(frame)
    if not frame then return end
    if not hookedFrames[frame] then
        hookedFrames[frame] = true
        if frame.HookScript then
            frame:HookScript("OnShow", function()
                if C_Timer and C_Timer.After then C_Timer.After(0, RefreshOverlays) else RefreshOverlays() end
            end)
        end
        if frame.UpdateItems then
            hooksecurefunc(frame, "UpdateItems", function() RefreshOverlays() end)
        end
    end
    if not frame:IsShown() then return end
    if frame.EnumerateValidItems then
        for _, button in frame:EnumerateValidItems() do UpdateButtonOverlay(button) end
    else
        local name = frame:GetName()
        for j = 1, (frame.size or 0) do
            UpdateButtonOverlay(name and _G[name .. "Item" .. j])
        end
    end
end

function RefreshOverlays()
    if debugClicks then
        local cb = _G.ContainerFrameCombinedBags
        Print("refresh: combined=" .. tostring(cb ~= nil) .. " shown=" .. tostring(cb and cb:IsShown())
            .. " enum=" .. tostring(cb and cb.EnumerateValidItems ~= nil))
    end
    for i = 1, (NUM_CONTAINER_FRAMES or 13) do
        ProcessFrame(_G["ContainerFrame" .. i])
    end
    ProcessFrame(_G.ContainerFrameCombinedBags)
end

---------------------------------------------------------------------------
-- Options panel
---------------------------------------------------------------------------

local COLS, ROWS, CELL = 8, 4, 36
local GRID_W = COLS * CELL
local COL1_X = 18                    -- auto-sell column
local COL2_X = COL1_X + GRID_W + 30  -- auto-buy column

local sellGrid, buyGrid

local function CreateCheck(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb.text = cb:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.text:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.Refresh = function(self) self:SetChecked(get()) end
    return cb
end

local function SortedIDs(list)
    local ids = {}
    for id in pairs(list) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- Re-draw a grid button's tooltip if the mouse is still over it.
local function UpdateTooltip(btn)
    if GameTooltip:IsOwned(btn) then btn:GetScript("OnEnter")(btn) end
end

-- A paged grid of item icons with a header, a "Clear all" button and a pager.
-- opts: x, y, title, countWord, popup, list(), onDrop(cursorType, a), onClick(btn, mouseButton),
--       tooltip(btn), label(id, value) optional, onWheel(btn, delta) optional
local function CreateItemGrid(opts)
    local g = { page = 1, buttons = {} }

    local hdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    hdr:SetPoint("TOPLEFT", opts.x + 2, opts.y - 8)
    hdr:SetText(opts.title)

    g.count = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    g.count:SetPoint("LEFT", hdr, "RIGHT", 8, 0)

    g.clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    g.clear:SetSize(80, 20)
    g.clear:SetText("Clear all")
    g.clear:SetPoint("TOPLEFT", opts.x + GRID_W - 82, opts.y - 4)
    g.clear:SetScript("OnClick", function()
        local n = #SortedIDs(opts.list())
        if n > 0 then StaticPopup_Show(opts.popup, n) end
    end)

    local gridTop = opts.y - 28
    for i = 1, COLS * ROWS do
        local col, r = (i - 1) % COLS, math.floor((i - 1) / COLS)
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(CELL - 2, CELL - 2)
        b:SetPoint("TOPLEFT", opts.x + col * CELL, gridTop - r * CELL)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        if b.bg.SetColorTexture then
            b.bg:SetColorTexture(0, 0, 0, 0.5)
        else
            b.bg:SetTexture(0, 0, 0, 0.5)
        end
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 1, -1)
        b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        b.label = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        b.label:SetPoint("BOTTOMRIGHT", -2, 2)
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(self, mouseButton)
            local cursorType, a = GetCursorInfo()
            if cursorType then
                opts.onDrop(cursorType, a)
                ClearCursor()
                RefreshOverlays(); RefreshPanel()
            elseif self.itemID then
                opts.onClick(self, mouseButton or "LeftButton")
            end
        end)
        b:SetScript("OnReceiveDrag", function(self) self:GetScript("OnClick")(self, "LeftButton") end)
        if opts.onWheel then
            b:EnableMouseWheel(true)
            b:SetScript("OnMouseWheel", function(self, delta)
                if self.itemID then opts.onWheel(self, delta) end
            end)
        end
        b:SetScript("OnEnter", function(self)
            if not self.itemID then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            opts.tooltip(self)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        g.buttons[i] = b
    end

    local pagerY = gridTop - ROWS * CELL - 2
    g.prev = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    g.prev:SetSize(28, 22)
    g.prev:SetText("<")
    g.prev:SetPoint("TOPLEFT", opts.x, pagerY)
    g.prev:SetScript("OnClick", function() g.page = g.page - 1; RefreshPanel() end)
    g.next = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    g.next:SetSize(28, 22)
    g.next:SetText(">")
    g.next:SetPoint("TOPLEFT", opts.x + GRID_W - 30, pagerY)
    g.next:SetScript("OnClick", function() g.page = g.page + 1; RefreshPanel() end)
    g.pageText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    g.pageText:SetPoint("TOP", panel, "TOPLEFT", opts.x + GRID_W / 2, pagerY - 5)

    function g:Refresh()
        local list = opts.list()
        local ids = SortedIDs(list)
        local perPage = #self.buttons
        local pages = math.max(1, math.ceil(#ids / perPage))
        self.page = math.min(math.max(self.page or 1, 1), pages)
        local offset = (self.page - 1) * perPage
        for i, btn in ipairs(self.buttons) do
            local id = ids[offset + i]
            btn.itemID = id
            if id then
                btn.icon:SetTexture(GetItemIcon(id) or "Interface\\Icons\\INV_Misc_QuestionMark")
                btn.icon:Show()
            else
                btn.icon:Hide()
            end
            btn.label:SetText(id and opts.label and opts.label(id, list[id]) or "")
        end
        self.count:SetText(#ids .. " " .. opts.countWord)
        self.clear:SetEnabled(#ids > 0)
        self.pageText:SetText(pages > 1 and ("Page " .. self.page .. " / " .. pages) or "")
        SetShown(self.prev, pages > 1)
        SetShown(self.next, pages > 1)
        self.prev:SetEnabled(self.page > 1)
        self.next:SetEnabled(self.page < pages)
    end

    return g
end

---------------------------------------------------------------------------
-- Auto-buy amount dialog
---------------------------------------------------------------------------

local function PopupEditBox(dialog)
    return dialog.editBox or dialog.EditBox
        or (dialog.GetName and dialog:GetName() and _G[dialog:GetName() .. "EditBox"])
end

local function ApplyBuyAmount(dialog)
    local eb = PopupEditBox(dialog)
    local id = dialog.data
    local n = eb and tonumber(eb:GetText())
    if not (id and n) then return end
    n = math.floor(n)
    if n <= 0 then
        BuyList()[id] = nil
        Print(ItemLink(id) .. " removed from the auto-buy list.")
    else
        BuyList()[id] = n
    end
    RefreshOverlays()
    RefreshPanel()
end

local function AskBuyAmount(id)
    local dialog = StaticPopup_Show("AUTOSELLMINMAX_BUYAMOUNT", ItemLink(id))
    if not dialog then return end
    dialog.data = id
    local eb = PopupEditBox(dialog)
    if eb then
        eb:SetText(tostring(BuyList()[id] or 1))
        eb:HighlightText()
    end
end

function RefreshPanel()
    if not panel then return end
    for _, cb in ipairs(panel.checks) do cb:Refresh() end
    sellGrid:Refresh()
    buyGrid:Refresh()
end

local function CreatePanel()
    panel = CreateFrame("Frame", "AutoSellMinMaxPanel", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(COL2_X + GRID_W + 18, 560)
    panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -200)
    if panel.SetClampedToScreen then panel:SetClampedToScreen(true) end
    panel:SetFrameStrata("DIALOG")
    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end
    panel:Hide()
    tinsert(UISpecialFrames, "AutoSellMinMaxPanel")

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("AutoSellMinMax")

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    -- left column: general and auto-sell options
    local x = COL1_X - 4
    panel.checks = {}
    local y = -42
    local function Check(label, get, set, cx, cy)
        panel.checks[#panel.checks + 1] = CreateCheck(panel, label, cx or x, cy or y, get, set)
    end
    Check("Auto sell all grey items",
        function() return db.autoSellGrey end,
        function(v) db.autoSellGrey = v end)
    y = y - 26
    Check("Separate sell/buy lists per character",
        function() return db.perCharacter end,
        function(v)
            db.perCharacter = v
            sellGrid.page, buyGrid.page = 1, 1
            RefreshOverlays()
            RefreshPanel()
            Print("auto-sell and auto-buy lists: " .. (v and "|cffffd100this character only|r" or "|cffffd100shared by all characters|r") .. ".")
        end)
    y = y - 26
    Check("Clean up bags after looting and selling",
        function() return db.sortBags end,
        function(v) db.sortBags = v end)
    y = y - 26
    Check("Auto repair all items at vendors",
        function() return db.autoRepair end,
        function(v) db.autoRepair = v end)
    y = y - 26
    Check("Use guild funds for repairs first",
        function() return db.repairGuildFunds end,
        function(v) db.repairGuildFunds = v end)
    y = y - 30
    for _, row in ipairs(QUALITY_ROWS) do
        local q = row.q
        Check(row.label,
            function() return db.block[q] end,
            function(v) db.block[q] = v end)
        y = y - 26
    end

    StaticPopupDialogs["AUTOSELLMINMAX_CLEAR"] = {
        text = "Remove all %d items from the AutoSellMinMax auto-sell list?",
        button1 = YES,
        button2 = NO,
        OnAccept = function()
            wipe(Registered())
            sellGrid.page = 1
            Print("auto-sell list cleared.")
            RefreshOverlays()
            RefreshPanel()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopupDialogs["AUTOSELLMINMAX_CLEARBUY"] = {
        text = "Remove all %d items from the AutoSellMinMax auto-buy list?",
        button1 = YES,
        button2 = NO,
        OnAccept = function()
            wipe(BuyList())
            buyGrid.page = 1
            Print("auto-buy list cleared.")
            RefreshOverlays()
            RefreshPanel()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopupDialogs["AUTOSELLMINMAX_BUYAMOUNT"] = {
        text = "How many %s should be kept in your bags?\n(0 removes it from the auto-buy list)",
        button1 = OKAY,
        button2 = CANCEL,
        hasEditBox = true,
        OnAccept = function(self) ApplyBuyAmount(self) end,
        EditBoxOnEnterPressed = function(self)
            local dialog = self:GetParent()
            ApplyBuyAmount(dialog)
            dialog:Hide()
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    sellGrid = CreateItemGrid({
        x = COL1_X, y = y, title = "Items to auto sell", countWord = "registered",
        popup = "AUTOSELLMINMAX_CLEAR",
        list = Registered,
        onDrop = function(cursorType, id)
            if cursorType == "item" and id and not Registered()[id] then Register(id) end
        end,
        onClick = function(btn)
            ToggleRegister(btn.itemID, select(2, GetItemInfo(btn.itemID)))
        end,
        tooltip = function()
            GameTooltip:AddLine("|cffff4040Click to remove from auto-sell list|r")
        end,
    })

    -- right column: auto-buy
    Check("Auto buy items at vendors",
        function() return db.autoBuy end,
        function(v) db.autoBuy = v end,
        COL2_X - 4, -42)
    -- rounding for items sold in packs: three check boxes that act like radio buttons
    local packs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    packs:SetPoint("TOPLEFT", COL2_X + 2, -74)
    packs:SetText("Items sold in packs (e.g. 5 water):")

    local ROUNDING_MSG = {
        down = "|cffffd100round down|r (never above your amount, up to one pack less)",
        up = "|cffffd100round up|r (never below your amount, up to one pack more)",
        exact = "|cffff8000exact amount|r (round up, then sell the surplus back; |cffff4040costs gold, not recommended|r)",
    }
    local function SetRounding(mode)
        db.buyRounding = mode
        Print("auto-buy packs: " .. ROUNDING_MSG[mode] .. ".")
        RefreshPanel()
    end
    StaticPopupDialogs["AUTOSELLMINMAX_EXACT"] = {
        text = "|cffff4040Not recommended!|r\n\nExact amount buys whole packs and sells the surplus back to the vendor. "
            .. "Vendors pay much less than they charge, so you lose gold on every visit.\n\n"
            .. "It also sells items above your amount that you looted.\n\nUse exact amount anyway?",
        button1 = YES,
        button2 = NO,
        OnAccept = function() SetRounding("exact") end,
        OnCancel = function() RefreshPanel() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        showAlert = true,
    }
    local roundingRows = {
        { mode = "down", label = "Round down (never above the amount)", y = -86 },
        { mode = "up", label = "Round up (never below the amount)", y = -110 },
        { mode = "exact", label = "Exact amount |cffff4040(not recommended)|r", y = -134 },
    }
    for _, row in ipairs(roundingRows) do
        local mode = row.mode
        Check(row.label,
            function() return db.buyRounding == mode end,
            function(v)
                if not v or db.buyRounding == mode then
                    RefreshPanel() -- one mode is always selected
                elseif mode == "exact" then
                    RefreshPanel() -- wait for the confirmation
                    StaticPopup_Show("AUTOSELLMINMAX_EXACT")
                else
                    SetRounding(mode)
                end
            end,
            COL2_X + 4, row.y)
    end

    local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    about:SetPoint("TOPLEFT", COL2_X + 2, -170)
    about:SetWidth(GRID_W - 4)
    about:SetJustifyH("LEFT")
    about:SetText("Keeps the amount you set of each item in your bags, e.g. water or food. "
        .. "At a vendor that sells it, the missing amount is bought after selling and repairing. "
        .. "Purchases stop when you run out of gold or bag space.")

    buyGrid = CreateItemGrid({
        x = COL2_X, y = y, title = "Items to auto buy", countWord = "items",
        popup = "AUTOSELLMINMAX_CLEARBUY",
        list = BuyList,
        label = function(_, n) return n end,
        onDrop = function(cursorType, a)
            local id
            if cursorType == "item" then
                id = a
            elseif cursorType == "merchant" then
                id = ItemIDFromLink(GetMerchantItemLink(a))
            end
            if id and not BuyList()[id] then RegisterBuy(id) end
        end,
        onClick = function(btn, mouseButton)
            if mouseButton == "RightButton" then
                ToggleBuy(btn.itemID)
                GameTooltip_Hide()
            else
                AskBuyAmount(btn.itemID)
            end
        end,
        onWheel = function(btn, delta)
            local id = btn.itemID
            local step = IsShiftKeyDown() and DefaultBuyAmount(id) or 1
            BuyList()[id] = math.max(1, (BuyList()[id] or 1) + delta * step)
            RefreshPanel()
            UpdateTooltip(btn)
        end,
        tooltip = function(btn)
            local want = BuyList()[btn.itemID] or 0
            local have = GetItemCount and GetItemCount(btn.itemID) or 0
            GameTooltip:AddLine(string.format("Keep |cffffd100%d|r in your bags (you have %d)", want, have), 1, 1, 1)
            GameTooltip:AddLine("Left-click: set amount", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Mouse wheel: +/- 1 (Shift: one stack)", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("|cffff4040Right-click: remove from auto-buy list|r")
        end,
    })

    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    help:SetPoint("BOTTOMLEFT", COL1_X + 2, 16)
    help:SetWidth(GRID_W - 4)
    help:SetJustifyH("LEFT")
    help:SetText("|cffffd100Alt+Left-click|r an item in your bags to add or remove it. You can also drag an item onto the grid. Registered items show a coin in your bags.")

    local buyHelp = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    buyHelp:SetPoint("BOTTOMLEFT", COL2_X + 2, 16)
    buyHelp:SetWidth(GRID_W - 4)
    buyHelp:SetJustifyH("LEFT")
    buyHelp:SetText("|cffffd100Ctrl+Alt+Left-click|r an item in your bags to add or remove it, or drag items from your bags or the vendor onto the grid. They show a bag icon in your bags.")

    panel:SetScript("OnShow", RefreshPanel)
end

local function TogglePanel()
    if panel:IsShown() then panel:Hide() else panel:Show() end
end

---------------------------------------------------------------------------
-- Entry in Esc -> Options -> AddOns
---------------------------------------------------------------------------

local function Metadata(field)
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return get(ADDON, field) or "?"
end

local function CreateInfoPanel()
    local info = CreateFrame("Frame", "AutoSellMinMaxInfoPanel")
    info.name = ADDON

    local title = info:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(ADDON)

    local notes = info:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    notes:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    notes:SetWidth(520)
    notes:SetJustifyH("LEFT")
    notes:SetText(Metadata("Notes"))

    local lines = {
        { "Author", Metadata("Author") },
        { "Version", Metadata("Version") },
    }
    local last = notes
    for _, l in ipairs(lines) do
        local fs = info:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -12)
        fs:SetText("|cffffd100" .. l[1] .. ":|r " .. l[2])
        last = fs
    end

    local links = {
        { "GitHub", Metadata("X-Source") },
        { "CurseForge", Metadata("X-Website") },
    }
    for _, l in ipairs(links) do
        local label = info:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -14)
        label:SetText(l[1] .. " (Ctrl+C to copy):")
        local box = CreateFrame("EditBox", nil, info, "InputBoxTemplate")
        box:SetSize(480, 20)
        box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -4)
        box:SetAutoFocus(false)
        box:SetText(l[2])
        box:SetCursorPosition(0)
        box:SetScript("OnEditFocusLost", function(self) self:SetText(l[2]); self:HighlightText(0, 0) end)
        box:SetScript("OnEscapePressed", box.ClearFocus)
        last = box
    end

    local open = CreateFrame("Button", nil, info, "UIPanelButtonTemplate")
    open:SetSize(160, 24)
    open:SetPoint("TOPLEFT", last, "BOTTOMLEFT", -6, -20)
    open:SetText("Open item list")
    open:SetScript("OnClick", function()
        if HideUIPanel and GameMenuFrame then HideUIPanel(GameMenuFrame) end
        if InterfaceOptionsFrame then InterfaceOptionsFrame:Hide() end
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        panel:Show()
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(info, ADDON)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(info)
    end
end

---------------------------------------------------------------------------
-- Top-right bar
---------------------------------------------------------------------------

local function CreateBar()
    -- Keep the button outside the minimap; WoW Forever clips minimap child frames.
    bar = CreateFrame("Button", "AutoSellMinMaxMinimapButton", UIParent)
    bar:SetSize(31, 31)
    bar:SetFrameStrata("MEDIUM")
    bar:SetFrameLevel(8)
    bar:RegisterForClicks("LeftButtonUp")
    bar:RegisterForDrag("LeftButton")

    -- circular gold border, same look as the other minimap buttons
    local border = bar:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    local icon = bar:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 6, -5)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    bar.icon = icon

    bar:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local function UpdatePosition()
        local angle = math.rad(db.minimapAngle)
        local radius = (Minimap:GetWidth() / 2) + 5
        bar:ClearAllPoints()
        bar:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
    end
    UpdatePosition()

    bar:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            UpdatePosition()
        end)
    end)
    bar:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    bar:SetScript("OnClick", TogglePanel)
    bar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("AutoSellMinMax")
        GameTooltip:AddLine("Auto sell grey: " .. OnOff(db.autoSellGrey), 1, 1, 1)
        GameTooltip:AddLine("Sell/buy lists: " .. (db.perCharacter and "this character" or "all characters"), 1, 1, 1)
        local nBuy = 0
        for _ in pairs(BuyList()) do nBuy = nBuy + 1 end
        GameTooltip:AddLine("Auto buy: " .. OnOff(db.autoBuy) .. " (" .. nBuy .. " item" .. (nBuy == 1 and "" or "s") .. ")", 1, 1, 1)
        GameTooltip:AddLine("Clean up bags after looting/selling: " .. OnOff(db.sortBags), 1, 1, 1)
        GameTooltip:AddLine("Auto repair: " .. OnOff(db.autoRepair)
            .. (db.autoRepair and db.repairGuildFunds and " (guild funds first)" or ""), 1, 1, 1)
        GameTooltip:AddLine("Click for options. Drag to move around the minimap.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", GameTooltip_Hide)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        AutoSellMinMaxDB = AutoSellMinMaxDB or {}
        db = AutoSellMinMaxDB
        CopyDefaults(defaults, db)

        CreateBar()
        CreatePanel()
        CreateInfoPanel()

        -- Alt+Left-click handling is hooked per bag button in RefreshOverlays.
        RefreshOverlays()

        if ContainerFrame_Update then
            hooksecurefunc("ContainerFrame_Update", RefreshOverlays)
        end

        Print("loaded. |cffffd100Alt+Left-click|r any item in your bags to register it for auto-selling (click again to unregister).")
        Print("|cffffd100Ctrl+Alt+Left-click|r an item to keep it stocked: it is bought at vendors until you have the amount you set. Auto buy: " .. OnOff(db.autoBuy) .. ".")
        Print("Auto-sell and auto-buy lists: " .. (db.perCharacter and "|cffffd100this character only|r" or "|cffffd100shared by all characters|r") .. ".")
        Print("Auto clean up bags after looting and selling: " .. OnOff(db.sortBags) .. " (change it in the options).")
        Print("Auto repair at vendors: " .. OnOff(db.autoRepair)
            .. (db.autoRepair and db.repairGuildFunds and " (guild funds first)" or "") .. ".")
        Print("Registered items are marked with a coin and sold automatically at the next vendor. Click the minimap coin or type /asmm for options.")

        f:UnregisterEvent("ADDON_LOADED")
        pcall(f.RegisterEvent, f, "GLOBAL_MOUSE_DOWN")
        f:RegisterEvent("CHAT_MSG_LOOT")
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
        f:RegisterEvent("MERCHANT_SHOW")
        f:RegisterEvent("MERCHANT_CLOSED")
        f:RegisterEvent("BAG_UPDATE_DELAYED")
    elseif event == "GLOBAL_MOUSE_DOWN" then
        OnGlobalMouseDown(arg1)
    elseif event == "CHAT_MSG_LOOT" then
        -- Only our own loot (arg12 = GUID of the looter).
        local guid = select(11, ...) -- arg12 overall; arg1 is already split off
        if guid == UnitGUID("player") then RequestSort(0.5) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if sortPending then
            sortPending = false
            RequestSort(0.5)
        end
    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true
        -- sell first, then repair and buy, so the earned gold can pay for both
        SellItems(function()
            local spent = RepairItems()
            BuyItems(GetMoney() - spent)
        end)
    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false
        StopSelling()
        StopBuying()
    elseif event == "BAG_UPDATE_DELAYED" then
        RefreshOverlays()
        if panel and panel:IsShown() then RefreshPanel() end
    end
end)

SLASH_AUTOSELLMINMAX1 = "/asmm"
SLASH_AUTOSELLMINMAX2 = "/autosellminmax"
SlashCmdList["AUTOSELLMINMAX"] = function(msg)
    if msg and msg:lower():match("^%s*debug") then
        debugClicks = not debugClicks
        Print("click debug " .. (debugClicks and "ON" or "OFF"))
        return
    end
    if panel then TogglePanel() end
end
