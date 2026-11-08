-- AutoSellMinMax
-- Auto-sells grey items (and items you register) when a vendor window opens.

local ADDON = "AutoSellMinMax"

local defaults = {
    autoSellGrey = true,
    sortBags = true, -- clean up ("Taschen aufräumen") after looting and selling
    block = { [2] = true, [3] = true, [4] = true, [5] = true }, -- green, blue, epic, legendary
    registered = {},                                            -- [itemID] = true
    minimapAngle = 200, -- degrees around the minimap
}

local QUALITY_ROWS = {
    { q = 2, label = "Block selling |cff1eff00Uncommon (green)|r items" },
    { q = 3, label = "Block selling |cff0070ddRare (blue)|r items" },
    { q = 4, label = "Block selling |cffa335eeEpic (purple)|r items" },
    { q = 5, label = "Block selling |cffff8000Legendary (orange)|r items" },
}

local db
local bar, panel
local slotButtons = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. ADDON .. "|r: " .. msg)
end

-- Newer clients moved these into C_Item and removed the globals.
local GetItemInfo = _G.GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

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
            icon = info[9],
            sellPrice = info[10],
        }
    end
    return {
        quality = info[3],
        itemType = info[6],
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
    return itemID and db.registered[itemID] or false
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
    db.registered[itemID] = true
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
    if db.registered[itemID] then
        db.registered[itemID] = nil
    else
        Register(itemID, link)
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

local function SellItems()
    StopSelling()
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
                    queue[#queue + 1] = { bag, slot, link }
                end
            end
        end
    end
    if #queue == 0 then return end

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
local function ToggleFromButton(button)
    local bag, slot = ButtonBagSlot(button)
    if debugClicks then Print("toggle: bag=" .. tostring(bag) .. " slot=" .. tostring(slot) .. " link=" .. tostring((bag and slot) and GetSlotInfo(bag, slot))) end
    if not (bag and slot and bag >= 0 and bag <= 5) then return false end
    local link = GetSlotInfo(bag, slot)
    if not link then return false end
    local id = (C_Container and C_Container.GetContainerItemID and C_Container.GetContainerItemID(bag, slot))
        or (C_Container and C_Container.GetContainerItemInfo and (C_Container.GetContainerItemInfo(bag, slot) or {}).itemID)
        or ItemIDFromLink(link)
    if debugClicks then Print("toggle id=" .. tostring(id) .. " link=" .. tostring(link)) end
    local ok, err = pcall(ToggleRegister, id, link)
    if not ok then Print("|cffff4040error:|r " .. tostring(err)) end
    if UpdateButtonOverlay then UpdateButtonOverlay(button) end
    return true
end

-- Alt+Left-click detection that does not depend on the bag UI's click handlers:
-- on every mouse-down, look at what is under the cursor.
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
    if button ~= "LeftButton" or not IsAltKeyDown()
        or IsControlKeyDown() or IsShiftKeyDown() then return end
    local foci = (GetMouseFoci and GetMouseFoci()) or {}
    if #foci == 0 and GetMouseFocus then foci[1] = GetMouseFocus() end
    for _, focus in ipairs(foci) do
        local f = focus
        for _ = 1, 3 do
            if not f then break end
            if f.GetBagID or (f.GetParent and f:GetParent() and f:GetParent().GetID and f:GetID()
                and f:GetID() > 0 and f:GetParent():GetID() <= 5 and f.GetObjectType
                and f:GetObjectType() == "Button") then
                if ToggleFromButton(f) then return end
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
    local show = false
    if bag and slot then
        local link = GetSlotInfo(bag, slot)
        show = IsRegistered(ItemIDFromLink(link))
    end
    if show and not button.asmmCoin then
        local tex = button:CreateTexture(nil, "OVERLAY", nil, 7)
        tex:SetTexture("Interface/Icons/INV_Misc_Coin_01")
        tex:SetSize(14, 14)
        tex:SetPoint("TOPLEFT", 2, -2)
        button.asmmCoin = tex
    end
    if button.asmmCoin then SetShown(button.asmmCoin, show) end
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

local function CreateCheck(parent, label, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 14, y)
    cb.text = cb:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.text:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.Refresh = function(self) self:SetChecked(get()) end
    return cb
end

local function RegisteredIDs()
    local ids = {}
    for id in pairs(db.registered) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function RefreshPanel()
    if not panel then return end
    for _, cb in ipairs(panel.checks) do cb:Refresh() end
    local ids = RegisteredIDs()
    local perPage = #slotButtons
    local pages = math.max(1, math.ceil(#ids / perPage))
    panel.page = math.min(math.max(panel.page or 1, 1), pages)
    local offset = (panel.page - 1) * perPage
    for i, btn in ipairs(slotButtons) do
        local id = ids[offset + i]
        btn.itemID = id
        if id then
            local icon = GetItemIcon(id)
            btn.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            btn.icon:Show()
        else
            btn.icon:Hide()
        end
    end
    panel.count:SetText(#ids .. " registered")
    panel.clear:SetEnabled(#ids > 0)
    panel.pageText:SetText(pages > 1 and ("Page " .. panel.page .. " / " .. pages) or "")
    SetShown(panel.prev, pages > 1)
    SetShown(panel.next, pages > 1)
    panel.prev:SetEnabled(panel.page > 1)
    panel.next:SetEnabled(panel.page < pages)
end

local function CreatePanel()
    panel = CreateFrame("Frame", "AutoSellMinMaxPanel", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(COLS * CELL + 36, 466)
    panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -220)
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

    panel.checks = {}
    local y = -42
    panel.checks[1] = CreateCheck(panel, "Auto sell all grey items", y,
        function() return db.autoSellGrey end,
        function(v) db.autoSellGrey = v end)
    y = y - 26
    panel.checks[#panel.checks + 1] = CreateCheck(panel, "Clean up bags after looting and selling", y,
        function() return db.sortBags end,
        function(v) db.sortBags = v end)
    y = y - 30
    for _, row in ipairs(QUALITY_ROWS) do
        local q = row.q
        panel.checks[#panel.checks + 1] = CreateCheck(panel, row.label, y,
            function() return db.block[q] end,
            function(v) db.block[q] = v end)
        y = y - 26
    end

    local hdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    hdr:SetPoint("TOPLEFT", 20, y - 8)
    hdr:SetText("Items to auto sell")

    panel.count = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    panel.count:SetPoint("LEFT", hdr, "RIGHT", 8, 0)

    StaticPopupDialogs["AUTOSELLMINMAX_CLEAR"] = {
        text = "Remove all %d items from the AutoSellMinMax auto-sell list?",
        button1 = YES,
        button2 = NO,
        OnAccept = function()
            wipe(db.registered)
            panel.page = 1
            Print("auto-sell list cleared.")
            RefreshOverlays()
            RefreshPanel()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    panel.clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.clear:SetSize(80, 20)
    panel.clear:SetText("Clear all")
    panel.clear:SetPoint("TOPRIGHT", -20, y - 4)
    panel.clear:SetScript("OnClick", function()
        local n = #RegisteredIDs()
        if n > 0 then StaticPopup_Show("AUTOSELLMINMAX_CLEAR", n) end
    end)

    local gridTop = y - 28
    for i = 1, COLS * ROWS do
        local col, r = (i - 1) % COLS, math.floor((i - 1) / COLS)
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(CELL - 2, CELL - 2)
        b:SetPoint("TOPLEFT", 18 + col * CELL, gridTop - r * CELL)
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
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(self)
            local cursorType, id = GetCursorInfo()
            if cursorType == "item" then
                if not db.registered[id] then Register(id) end
                ClearCursor()
                RefreshOverlays(); RefreshPanel()
            elseif self.itemID then
                ToggleRegister(self.itemID, select(2, GetItemInfo(self.itemID)))
            end
        end)
        b:SetScript("OnReceiveDrag", function(self) self:GetScript("OnClick")(self) end)
        b:SetScript("OnEnter", function(self)
            if not self.itemID then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            GameTooltip:AddLine("|cffff4040Click to remove from auto-sell list|r")
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        slotButtons[i] = b
    end

    local pagerY = gridTop - ROWS * CELL - 2
    panel.prev = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.prev:SetSize(28, 22)
    panel.prev:SetText("<")
    panel.prev:SetPoint("TOPLEFT", 18, pagerY)
    panel.prev:SetScript("OnClick", function() panel.page = panel.page - 1; RefreshPanel() end)
    panel.next = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.next:SetSize(28, 22)
    panel.next:SetText(">")
    panel.next:SetPoint("TOPLEFT", 18 + COLS * CELL - 30, pagerY)
    panel.next:SetScript("OnClick", function() panel.page = panel.page + 1; RefreshPanel() end)
    panel.pageText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    panel.pageText:SetPoint("TOP", panel, "TOPLEFT", 18 + COLS * CELL / 2, pagerY - 5)

    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    help:SetPoint("BOTTOMLEFT", 20, 16)
    help:SetWidth(COLS * CELL - 4)
    help:SetJustifyH("LEFT")
    help:SetText("|cffffd100Alt+Left-click|r an item in your bags to add or remove it. You can also drag an item onto the grid. Registered items show a coin in your bags.")

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
        GameTooltip:AddLine("Auto sell grey: " .. (db.autoSellGrey and "|cff00ff00ON|r" or "|cffff0000OFF|r"), 1, 1, 1)
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
        SellItems()
    elseif event == "MERCHANT_CLOSED" then
        StopSelling()
    elseif event == "BAG_UPDATE_DELAYED" then
        RefreshOverlays()
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
