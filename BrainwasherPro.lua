-- BrainwasherPro: named, iconed talent specs at the Goblin Brainwashing Device,
-- with an optional ActionBarProfiles profile per spec. By Fostercare5988, based
-- on Horyoshi's original BrainwasherPro. WoW 1.12.1 with ClassicAPI
-- 1.16.0+ (ClassicAPIRequirement.lua).
local addonName, ns = ...
if ns.unsupported then return end
local UI = ns.UI

BrainwasherPro = {}

-- The device is recognised by its menu, not its name. Option texts read in
-- play (2026-10-21):
--   "Reset my talents. (1g0s0c)"
--   "Activate 1st Specialization  (41/10/0)"
--   "Save 1st Specialization."
--   "Buy 4th Specialization tab for 200 gold."
local PATTERN_SAVE = "Save (%d+).. Specialization"
local PATTERN_ACTIVATE = "Activate (%d+).. Specialization"
local PATTERN_SPLIT = "%((%d+)/(%d+)/(%d+)%)"
local PATTERN_BUY = "Buy (%d+).. Specialization.* (%d+) gold"
local PATTERN_RESET = "Reset my talents"
local PATTERN_RESET_PRICE = "%((%d+)g(%d+)s(%d+)c%)"
local MAX_SLOTS = 8
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local TEXT_WIDTH = 146         -- row text stops before the Edit button
local ICON_COLUMNS, ICON_ROWS = 8, 5
local ICONS_PER_PAGE = ICON_COLUMNS * ICON_ROWS
local BAR_SETTLE = 1.5       -- seconds without talent/spell events before bars load
local BAR_TIMEOUT = 60       -- give up waiting for the talent swap

local mainFrame, editFrame = nil, nil
local rows = {}
local menu = nil             -- options of the device menu on screen; nil when none
local session = 0            -- bumps on every menu, so stale popups and clicks do nothing
local hiddenGossip = nil     -- GossipFrame scale/alpha we changed, to restore
local pendingBars = nil      -- { profile, token, deadline } while a spec swap is under way
local barToken = 0         -- the settle timer that may load the bars
local editSlot, editIcon, editProfile, iconPage = nil, nil, nil, 1
local eventFrame = CreateFrame("Frame")
local SWAP_EVENTS = { "CHARACTER_POINTS_CHANGED", "SPELLS_CHANGED", "PLAYER_REGEN_ENABLED" }

local function Print(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00BrainwasherPro:|r " .. text)
end

local function Spec(slot)
    return BrainwasherProDB.specs[slot]
end

local function EnsureSpec(slot)
    local spec = BrainwasherProDB.specs[slot]
    if not spec then
        spec = { name = "Spec " .. slot, icon = DEFAULT_ICON, t1 = 0, t2 = 0, t3 = 0 }
        BrainwasherProDB.specs[slot] = spec
    end
    return spec
end

local function ColorTalentSummary(t1, t2, t3)
    local largest = math.max(t1, t2, t3)
    local smallest = math.min(t1, t2, t3)
    local function getColor(value)
        if value == largest then
            return "|cff00ff00"
        elseif value == smallest then
            return "|cff0077ff"
        end
        return "|cffffff00"
    end
    return getColor(t1) .. t1 .. "|r/" .. getColor(t2) .. t2 .. "|r/" .. getColor(t3) .. t3 .. "|r"
end

-- "1g", "1g 50s", "75s": copper as the device's price, without zero parts.
local function FormatPrice(copper)
    local gold, silver, rest = math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
    local parts = {}
    if gold > 0 then table.insert(parts, gold .. "g") end
    if silver > 0 then table.insert(parts, silver .. "s") end
    if rest > 0 then table.insert(parts, rest .. "c") end
    return table.concat(parts, " ")
end

local function GetTalentCounts()
    local _, _, t1 = GetTalentTabInfo(1)
    local _, _, t2 = GetTalentTabInfo(2)
    local _, _, t3 = GetTalentTabInfo(3)
    return t1 or 0, t2 or 0, t3 or 0
end

-- ActionBarProfiles ------------------------------------------------------------

local function BarsAvailable()
    return type(ABP_GetProfileNames) == "function" and type(ABP_LoadProfileByName) == "function"
end

-- false when ActionBarProfiles no longer has the profile; nil when it cannot
-- tell yet (not installed or not loaded).
local function ProfileExists(profile)
    local names = BarsAvailable() and ABP_GetProfileNames()
    if not names then return nil end
    for _, name in ipairs(names) do
        if name == profile then return true end
    end
    return false
end

-- Talent and spell events matter only while a swap is being watched.
local function ListenForSwap(on)
    for _, name in ipairs(SWAP_EVENTS) do
        if on then eventFrame:RegisterEvent(name) else eventFrame:UnregisterEvent(name) end
    end
end

local function StopWatchingBars()
    pendingBars = nil
    ListenForSwap(false)
end

local function LoadPendingBars(token)
    if not (pendingBars and pendingBars.token == token) then return end
    if UnitAffectingCombat("player") then
        pendingBars.afterCombat = true
        return
    end
    local profile = pendingBars.profile
    StopWatchingBars()
    ABP_LoadProfileByName(profile)
end

-- A talent change starts a short settle timer and later talent or spell
-- events restart it; the profile loads once they stop, so it places the new
-- spec's spells. A swap keeps the number of points, so CHARACTER_POINTS_CHANGED
-- may not come (seen in play, 2026-10-22: only spells were unlearned and
-- learned); a talent split that differs from the one at Activate counts too.
local function SettleBars(pointsChanged)
    if not pendingBars then return end
    if not (pendingBars.changed or pointsChanged) then
        local t1, t2, t3 = GetTalentCounts()
        local before = pendingBars.before
        if t1 == before[1] and t2 == before[2] and t3 == before[3] then return end
    end
    pendingBars.changed = true
    barToken = barToken + 1
    pendingBars.token = barToken
    local token = barToken
    C_Timer.After(BAR_SETTLE, function() LoadPendingBars(token) end)
end

local function WatchBars(profile)
    local watch = { profile = profile, before = { GetTalentCounts() } }
    pendingBars = watch
    ListenForSwap(true)
    C_Timer.After(BAR_TIMEOUT, function()
        if pendingBars == watch and not watch.changed then
            StopWatchingBars()
            Print("Talents did not change, so action bars were left as they are.")
        end
    end)
end

-- Gossip -----------------------------------------------------------------------

-- Reads the device menu by option ID. Returns nil for any other NPC.
local function ReadMenu()
    local found = { save = {}, activate = {}, split = {}, buy = {}, slots = 0 }
    local isDevice = false
    for _, option in ipairs(C_GossipInfo.GetOptions()) do
        local text = option.name or ""
        local _, _, save = string.find(text, PATTERN_SAVE)
        local _, _, activate = string.find(text, PATTERN_ACTIVATE)
        local _, _, buy, price = string.find(text, PATTERN_BUY)
        local slot = tonumber(save or activate or buy)
        if slot and slot >= 1 and slot <= MAX_SLOTS then
            isDevice = true
            if slot > found.slots then found.slots = slot end
            if save then
                found.save[slot] = option
            elseif activate then
                found.activate[slot] = option
                local _, _, t1, t2, t3 = string.find(text, PATTERN_SPLIT)
                if t1 then found.split[slot] = { tonumber(t1), tonumber(t2), tonumber(t3) } end
            else
                found.buy[slot] = { option = option, price = tonumber(price) or 0 }
            end
        elseif string.find(text, PATTERN_RESET) then
            local _, _, g, s, c = string.find(text, PATTERN_RESET_PRICE)
            local copper = g and (tonumber(g) * 10000 + tonumber(s) * 100 + tonumber(c)) or 0
            found.reset = { option = option, price = copper > 0 and FormatPrice(copper) or nil }
        end
    end
    return isDevice and found or nil
end

-- The native window stays open (closing it ends the conversation) but is
-- shrunk as well as faded, so its invisible buttons cannot be clicked.
local function HideGossip()
    if hiddenGossip then return end
    hiddenGossip = { alpha = GossipFrame:GetAlpha(), scale = GossipFrame:GetScale() }
    GossipFrame:SetAlpha(0)
    GossipFrame:SetScale(0.01)
end

local function RestoreGossip()
    if not hiddenGossip then return end
    GossipFrame:SetScale(hiddenGossip.scale)
    GossipFrame:SetAlpha(hiddenGossip.alpha)
    hiddenGossip = nil
end

function BrainwasherPro:EndGossipSession()
    menu = nil
    session = session + 1
    RestoreGossip()
    StaticPopup_Hide("BRAINWASHERPRO_LOAD_SPEC")
    StaticPopup_Hide("BRAINWASHERPRO_SAVE_SPEC")
    StaticPopup_Hide("BRAINWASHERPRO_BUY_SLOT")
    StaticPopup_Hide("BRAINWASHERPRO_RESET_TALENTS")
end

-- Picks an option of the menu that was current when the action started.
local function Choose(option, owner)
    if menu and owner == session and option then
        C_GossipInfo.SelectOption(option.gossipOptionID)
        return true
    end
end

-- Options the server confirms itself (boxCoded) skip our popup. Each popup
-- carries its own action and the menu it belongs to.
local function Confirm(which, option, a1, a2, action)
    local owner = session
    if (option.flags or 0) % 2 == 1 then
        action(owner)
        return
    end
    local dialog = StaticPopup_Show(which, a1, a2)
    if dialog then dialog.data = { owner = owner, action = action } end
end

-- The slot whose split matches the talents you have now. The device lists
-- Activate for every slot, including the one in use.
local function SlotSplit(slot)
    local split = menu.split[slot]
    if split then return split[1], split[2], split[3] end
    local spec = Spec(slot)
    if spec then return spec.t1 or 0, spec.t2 or 0, spec.t3 or 0 end
    return 0, 0, 0
end

local function IsActive(slot)
    if not menu.activate[slot] then return false end
    local t1, t2, t3 = SlotSplit(slot)
    local c1, c2, c3 = GetTalentCounts()
    return t1 + t2 + t3 > 0 and t1 == c1 and t2 == c2 and t3 == c3
end

local function SpecName(slot)
    return Spec(slot) and Spec(slot).name or ("Spec " .. slot)
end

-- Actions ----------------------------------------------------------------------

function BrainwasherPro:ActivateSlot(slot)
    if not menu then return end
    local buy = menu.buy[slot]
    if buy then
        Confirm("BRAINWASHERPRO_BUY_SLOT", buy.option, slot, buy.price, function(owner)
            Choose(buy.option, owner)
        end)
        return
    end
    local option = menu.activate[slot]
    if not option then return end
    if IsActive(slot) then return Print(SpecName(slot) .. " is already active.") end
    Confirm("BRAINWASHERPRO_LOAD_SPEC", option, SpecName(slot), nil, function(owner)
        local profile = Spec(slot) and Spec(slot).actionProfile
        if not (Choose(option, owner) and profile and BarsAvailable()) then return end
        if ProfileExists(profile) == false then
            Print("Action bar profile \"" .. profile .. "\" no longer exists, so bars were left as they are.")
        else
            WatchBars(profile)
        end
    end)
end

function BrainwasherPro:SaveSlot(slot)
    local option = menu and menu.save[slot]
    if not option then return end
    local target = menu.activate[slot] and (SpecName(slot) .. ", replacing what it holds") or ("slot " .. slot)
    Confirm("BRAINWASHERPRO_SAVE_SPEC", option, target, nil, function(owner)
        if not Choose(option, owner) then return end
        local spec = EnsureSpec(slot)
        spec.t1, spec.t2, spec.t3 = GetTalentCounts()
    end)
end

function BrainwasherPro:ResetTalents()
    local reset = menu and menu.reset
    if not reset then return end
    local price = reset.price and (" for " .. reset.price) or ""
    Confirm("BRAINWASHERPRO_RESET_TALENTS", reset.option, price, nil, function(owner)
        Choose(reset.option, owner)
    end)
end

-- Main window ------------------------------------------------------------------

-- Sets text, cutting it with "..." when it is wider than the row has room for.
-- The first `keep` characters (colour codes) are never cut.
local function FitText(font, text, keep, width)
    width = width or TEXT_WIDTH
    font:SetText(text)
    if font:GetStringWidth() <= width then return end
    for n = string.len(text) - 1, (keep or 0) + 1, -1 do
        font:SetText(string.sub(text, 1, n) .. "...")
        if font:GetStringWidth() <= width then return end
    end
end

local function ShowRowTooltip()
    local tip = this.tip
    if not tip then return end
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText(tip.name, 1, 1, 1)
    if tip.active then GameTooltip:AddLine("Active now", 0.3, 1, 0.3) end
    if tip.split then GameTooltip:AddLine("Talents: " .. tip.split, 1, 1, 1) end
    if tip.missing then
        GameTooltip:AddLine("Action bars: " .. tip.bars .. " (no longer in ActionBarProfiles)", 1, 0.3, 0.3)
    else
        GameTooltip:AddLine("Action bars: " .. (tip.bars or "none"), 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

local function UpdateRow(slot)
    local row = rows[slot]
    local spec = Spec(slot)
    local buy = menu.buy[slot]
    local owned = menu.activate[slot] or menu.save[slot]
    local split = menu.split[slot]
    local summary, keep = "", 0
    local active = IsActive(slot)
    row.tip = nil
    if active then row.active:Show() else row.active:Hide() end

    -- The device's own split is the truth; keep it for when it is not shown.
    if split and spec then spec.t1, spec.t2, spec.t3 = split[1], split[2], split[3] end

    if buy then
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        row.name:SetText("Buy slot " .. slot .. " (" .. buy.price .. "g)")
        row.name:SetTextColor(1, 0.8, 0)
    elseif owned and (spec or split) then
        row.icon:SetTexture(spec and spec.icon or DEFAULT_ICON)
        local specName = spec and spec.name or ("Spec " .. slot)
        FitText(row.name, specName, 0, active and TEXT_WIDTH - 40 or TEXT_WIDTH)
        UI.Color(row.name, "text")
        local t1, t2, t3 = SlotSplit(slot)
        local hasSplit = t1 + t2 + t3 > 0
        if hasSplit then summary = ColorTalentSummary(t1, t2, t3) end
        local bars = spec and spec.actionProfile
        local missing = bars and ProfileExists(bars) == false
        if bars then
            -- A missing profile shows as such; its name is in the tooltip.
            summary = summary .. (hasSplit and "  " or "") .. "Bars: "
            keep = string.len(summary)
            summary = summary .. (missing and "|cffff4d4dmissing|r" or bars)
        end
        row.tip = { name = specName, split = hasSplit and (t1 .. "/" .. t2 .. "/" .. t3) or nil,
            bars = bars, missing = missing, active = active }
    else
        row.icon:SetTexture(DEFAULT_ICON)
        row.name:SetText("Empty talent slot")
        UI.Color(row.name, "hint")
    end
    FitText(row.summary, summary, keep)
    if owned then row.edit:Show() else row.edit:Hide() end
    if menu.save[slot] then row.save:Show() else row.save:Hide() end
    if buy or menu.activate[slot] then row.iconButton:Enable() else row.iconButton:Disable() end
    row:Show()
end

function BrainwasherPro:UpdateAllDisplays()
    if not (mainFrame and menu) then return end
    for slot = 1, MAX_SLOTS do
        if rows[slot] then
            if slot <= menu.slots then UpdateRow(slot) else rows[slot]:Hide() end
        end
    end
    if menu.reset then
        mainFrame.reset:SetText(menu.reset.price and ("Reset talents (" .. menu.reset.price .. ")") or "Reset talents")
        mainFrame.reset:Show()
    else
        mainFrame.reset:Hide()
    end
    mainFrame:SetHeight(56 + menu.slots * 42 + 56)
end

local function CreateRow(slot)
    local name = "BrainwasherProSlot" .. slot
    local row = UI.Row(name, mainFrame, 28, -56 - (slot - 1) * 42, 304)
    row:SetHeight(36)
    -- Hovering the row shows the full name and action bar profile.
    row:EnableMouse(true)
    row:SetScript("OnEnter", ShowRowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local iconButton = CreateFrame("Button", "BrainwasherProIcon" .. slot, row)
    iconButton:SetWidth(28); iconButton:SetHeight(28)
    iconButton:SetPoint("LEFT", row, "LEFT", 4, 0)
    iconButton:RegisterForClicks("LeftButtonUp")
    iconButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    iconButton:SetScript("OnClick", function() BrainwasherPro:ActivateSlot(slot) end)
    UI.Tooltip(iconButton, "Click to activate this spec, or buy the slot.")
    row.icon = iconButton:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints(iconButton)
    row.iconButton = iconButton

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", iconButton, "TOPRIGHT", 8, -2)
    row.name:SetWidth(TEXT_WIDTH)
    row.name:SetJustifyH("LEFT")
    row.active = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.active:SetPoint("TOPRIGHT", iconButton, "TOPRIGHT", 8 + TEXT_WIDTH, -2)
    row.active:SetText("Active")
    row.active:SetTextColor(0.3, 1, 0.3)
    row.summary = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.summary:SetPoint("BOTTOMLEFT", iconButton, "BOTTOMRIGHT", 8, 2)
    row.summary:SetWidth(TEXT_WIDTH)
    row.summary:SetJustifyH("LEFT")
    UI.Color(row.summary, "hint")

    row.save = UI.Button(name .. "Save", row, "Save", 0, 0, 48, function() BrainwasherPro:SaveSlot(slot) end, { height = 20 })
    row.save:ClearAllPoints()
    row.save:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.edit = UI.Button(name .. "Edit", row, "Edit", 0, 0, 48, function() BrainwasherPro:OnEditClicked(slot) end, { height = 20 })
    row.edit:ClearAllPoints()
    row.edit:SetPoint("RIGHT", row.save, "LEFT", -6, 0)

    rows[slot] = row
end

function BrainwasherPro:CreateMainFrame()
    if mainFrame then return end
    mainFrame = UI.Window("BrainwasherProFrame", "Brainwasher Pro", 360, 280, GetAddOnMetadata(addonName, "Version"))
    for slot = 1, MAX_SLOTS do CreateRow(slot); rows[slot]:Hide() end

    mainFrame.reset = UI.Button("BrainwasherProReset", mainFrame, "Reset talents", 0, 0, 148, function()
        BrainwasherPro:ResetTalents()
    end, { font = "GameFontHighlight" })
    mainFrame.reset:ClearAllPoints()
    mainFrame.reset:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 28, 18)
    local original = UI.Button("BrainwasherProOriginal", mainFrame, "Show original", 0, 0, 148, function()
        mainFrame:Hide()
    end, { font = "GameFontHighlight" })
    original:ClearAllPoints()
    original:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -28, 18)
    UI.Tooltip(original, "Show the device's own menu.")

    -- The close glyph also ends the conversation; Escape and Show original
    -- only bring the device's own menu back.
    BrainwasherProFrameClose:SetScript("OnClick", function()
        mainFrame:Hide()
        CloseGossip()
    end)
    mainFrame:SetScript("OnHide", function()
        BrainwasherPro:EndGossipSession()
        if editFrame then editFrame:Hide() end
    end)
end

-- Edit window ------------------------------------------------------------------

local function ShowIconPage()
    local count = GetNumMacroIcons()
    local pages = math.max(1, math.ceil(count / ICONS_PER_PAGE))
    iconPage = math.max(1, math.min(pages, iconPage))
    local first = (iconPage - 1) * ICONS_PER_PAGE
    for i = 1, ICONS_PER_PAGE do
        local button = editFrame.icons[i]
        local index = first + i
        if index <= count then
            button.texture:SetTexture(GetMacroIconInfo(index))
            button.index = index
            button:Show()
        else
            button:Hide()
        end
    end
    editFrame.page:SetText(iconPage .. " / " .. pages)
end

local function ShowBarsChoice()
    if not BarsAvailable() then
        editFrame.bars:Hide()
        return
    end
    editFrame.bars:SetText("Action bars: " .. (editProfile or "none"))
    editFrame.bars:Show()
end

-- Steps through None and every profile ActionBarProfiles has for this character.
local function CycleBars(step)
    local names = ABP_GetProfileNames() or {}
    local position = 0
    for i, profile in ipairs(names) do
        if profile == editProfile then position = i end
    end
    position = (position + step + #names + 1) % (#names + 1)
    editProfile = names[position]
    ShowBarsChoice()
end

local function ConfirmEdit()
    local spec = EnsureSpec(editSlot)
    local text = editFrame.nameEdit:GetText()
    if text and text ~= "" then spec.name = text end
    spec.icon = editIcon
    spec.actionProfile = editProfile
    editFrame:Hide()
    BrainwasherPro:UpdateAllDisplays()
end

function BrainwasherPro:CreateEditFrame()
    if editFrame then return end
    editFrame = UI.Window("BrainwasherProEditFrame", "Edit talent spec", 360, 432)

    UI.Heading(editFrame, "Name", 28, -56)
    editFrame.preview = editFrame:CreateTexture(nil, "OVERLAY")
    editFrame.preview:SetWidth(28); editFrame.preview:SetHeight(28)
    editFrame.preview:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 28, -72)

    local nameEdit = CreateFrame("EditBox", "BrainwasherProEditName", editFrame)
    nameEdit:SetWidth(260); nameEdit:SetHeight(24)
    nameEdit:SetPoint("LEFT", editFrame.preview, "RIGHT", 10, 0)
    nameEdit:SetFontObject(GameFontHighlight)
    nameEdit:SetTextInsets(8, 8, 0, 0)
    nameEdit:SetAutoFocus(false)
    nameEdit:SetMaxLetters(20)
    UI.Rounded(nameEdit, "BACKGROUND", 10, UI.track)
    nameEdit:SetScript("OnEnterPressed", ConfirmEdit)
    nameEdit:SetScript("OnEscapePressed", function() editFrame:Hide() end)
    editFrame.nameEdit = nameEdit

    UI.Heading(editFrame, "Icon", 28, -112)
    local grid = CreateFrame("Frame", nil, editFrame)
    grid:SetWidth(ICON_COLUMNS * 38); grid:SetHeight(ICON_ROWS * 38)
    grid:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 28, -128)
    grid:EnableMouseWheel(true)
    grid:SetScript("OnMouseWheel", function()
        iconPage = iconPage - (arg1 or 0)
        ShowIconPage()
    end)
    editFrame.icons = {}
    for i = 1, ICONS_PER_PAGE do
        local button = CreateFrame("Button", nil, grid)
        button:SetWidth(34); button:SetHeight(34)
        local column, rowIndex = (i - 1) % ICON_COLUMNS, math.floor((i - 1) / ICON_COLUMNS)
        button:SetPoint("TOPLEFT", grid, "TOPLEFT", column * 38, -rowIndex * 38)
        button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        button.texture = button:CreateTexture(nil, "ARTWORK")
        button.texture:SetAllPoints(button)
        button:SetScript("OnClick", function()
            editIcon = GetMacroIconInfo(button.index)
            editFrame.preview:SetTexture(editIcon)
        end)
        editFrame.icons[i] = button
    end

    local y = -128 - ICON_ROWS * 38 - 6
    UI.Button("BrainwasherProEditPrev", editFrame, "<", 28, y, 36, function()
        iconPage = iconPage - 1; ShowIconPage()
    end)
    editFrame.page = UI.Label(editFrame, "", 74, y - 5, "GameFontHighlightSmall")
    editFrame.page:SetWidth(76)
    editFrame.page:SetJustifyH("CENTER")
    UI.Button("BrainwasherProEditNext", editFrame, ">", 160, y, 36, function()
        iconPage = iconPage + 1; ShowIconPage()
    end)

    editFrame.bars = UI.Button("BrainwasherProEditBars", editFrame, "", 28, y - 34, 304, function()
        CycleBars(arg1 == "RightButton" and -1 or 1)
    end)
    editFrame.bars:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    UI.Tooltip(editFrame.bars, "ActionBarProfiles profile to load after this spec is activated. Click for the next, right-click for the previous.")

    local confirm = UI.Button("BrainwasherProEditConfirm", editFrame, "Confirm", 0, 0, 148, ConfirmEdit, { font = "GameFontHighlight" })
    confirm:ClearAllPoints()
    confirm:SetPoint("BOTTOMLEFT", editFrame, "BOTTOMLEFT", 28, 18)
    UI.Select(confirm, true)
    local cancel = UI.Button("BrainwasherProEditCancel", editFrame, "Cancel", 0, 0, 148, function()
        editFrame:Hide()
    end, { font = "GameFontHighlight" })
    cancel:ClearAllPoints()
    cancel:SetPoint("BOTTOMRIGHT", editFrame, "BOTTOMRIGHT", -28, 18)
end

function BrainwasherPro:OnEditClicked(slot)
    self:CreateEditFrame()
    local spec = EnsureSpec(slot)
    editSlot, editIcon, editProfile = slot, spec.icon or DEFAULT_ICON, spec.actionProfile
    editFrame.nameEdit:SetText(spec.name or ("Spec " .. slot))
    editFrame.preview:SetTexture(editIcon)
    ShowIconPage()
    ShowBarsChoice()
    editFrame:Show()
end

-- Gossip events ----------------------------------------------------------------

function BrainwasherPro:OnGossipShow()
    self:OnGossipClosed()
    local found = ReadMenu()
    if not found then return end
    menu = found
    for slot in pairs(found.activate) do EnsureSpec(slot) end
    self:CreateMainFrame()
    HideGossip()
    mainFrame:Show()
    self:UpdateAllDisplays()
end

function BrainwasherPro:OnGossipClosed()
    if mainFrame and mainFrame:IsShown() then
        mainFrame:Hide()
    else
        self:EndGossipSession()
    end
end

-- Static popups ----------------------------------------------------------------

local function Popup(text)
    return {
        text = text,
        button1 = YES,
        button2 = NO,
        OnAccept = function(data) if data then data.action(data.owner) end end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
    }
end
StaticPopupDialogs["BRAINWASHERPRO_LOAD_SPEC"] = Popup("Activate %s? This causes a brainwasher debuff.")
StaticPopupDialogs["BRAINWASHERPRO_SAVE_SPEC"] = Popup("Save your current talents to %s?")
StaticPopupDialogs["BRAINWASHERPRO_BUY_SLOT"] = Popup("Buy talent slot %s for %s gold?")
StaticPopupDialogs["BRAINWASHERPRO_RESET_TALENTS"] = Popup("Reset all your talents%s? This causes a debuff.")

-- Events -----------------------------------------------------------------------

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("GOSSIP_SHOW")
eventFrame:RegisterEvent("GOSSIP_CLOSED")

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == addonName then
        BrainwasherProDB = BrainwasherProDB or {}
        BrainwasherProDB.specs = BrainwasherProDB.specs or {}
        -- 1.5 saved every talent of each spec but never read it back.
        for _, spec in pairs(BrainwasherProDB.specs) do spec.talents = nil end
    elseif event == "GOSSIP_SHOW" then
        BrainwasherPro:OnGossipShow()
    elseif event == "GOSSIP_CLOSED" then
        BrainwasherPro:OnGossipClosed()
    elseif event == "CHARACTER_POINTS_CHANGED" or event == "SPELLS_CHANGED" then
        SettleBars(event == "CHARACTER_POINTS_CHANGED")
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingBars and pendingBars.afterCombat then LoadPendingBars(pendingBars.token) end
    end
end)
