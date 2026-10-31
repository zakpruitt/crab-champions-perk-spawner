--[[
    PerkSpawner - in-game menu for giving yourself any perk (or mod/relic).

    F6            open / close the menu
    Mouse         click a tab to switch category, click an item to select it,
                  click it again (or GIVE) to give it
    Typing        filters the list (Backspace erases, Delete clears)
    Up / Down     move selection          (PageUp / PageDown flips pages)
    Left / Right  switch category (Perks, Weapon Mods, Ability Mods, Melee Mods, Relics)
    + / -         change the level to give
    Enter         give the selected item (giving one you own adds levels)

    The host writes items straight into the player's inventory. Clients send
    a request over the chat RPC that the host's copy of the mod fulfils, so
    everyone in the lobby needs the mod installed.

--]]

local MOD = "[PerkSpawner] "
local TOGGLE_KEY = Key.F6

-- array/field/slots: where ACrabPS keeps these items (FCrabPerk.PerkDA etc.)
local CATEGORIES = {
    { label = "Perks",        class = "CrabPerkDA",       array = "Perks",       field = "PerkDA",       slots = "NumPerkSlots" },
    { label = "Weapon Mods",  class = "CrabWeaponModDA",  array = "WeaponMods",  field = "WeaponModDA",  slots = "NumWeaponModSlots" },
    { label = "Ability Mods", class = "CrabAbilityModDA", array = "AbilityMods", field = "AbilityModDA", slots = "NumAbilityModSlots" },
    { label = "Melee Mods",   class = "CrabMeleeModDA",   array = "MeleeMods",   field = "MeleeModDA",   slots = "NumMeleeModSlots" },
    { label = "Relics",       class = "CrabRelicDA",      array = "Relics",      field = "RelicDA" },
}

-- ECrabRarity: 1 Common, 2 Epic, 3 Legendary, 4 Greed
local RARITY = {
    [1] = { name = "Common",    order = 1, color = { R = 0.85, G = 0.85, B = 0.85, A = 1 } },
    [2] = { name = "Epic",      order = 2, color = { R = 0.75, G = 0.45, B = 1.00, A = 1 } },
    [3] = { name = "Legendary", order = 3, color = { R = 1.00, G = 0.75, B = 0.20, A = 1 } },
    [4] = { name = "Greed",     order = 4, color = { R = 1.00, G = 0.35, B = 0.45, A = 1 } },
}
local OTHER_RARITY = { name = "?", order = 9, color = { R = 0.6, G = 0.6, B = 0.6, A = 1 } }

local state = {
    open = false,
    category = 1,
    selected = 1,
    level = 1,
    status = "",
    search = "",
    lists = {},
}

local ui = nil
local nameCounter = 0

local function log(msg)
    print(MOD .. msg .. "\n")
end

------------------------------------------------------------------------
-- Item lists
------------------------------------------------------------------------

local function safeString(prop)
    local ok, s = pcall(function() return prop:ToString() end)
    if ok and s then return s end
    return ""
end

local function scanCategory(index)
    local cat = CATEGORIES[index]
    local items = {}
    for _, da in ipairs(FindAllOf(cat.class) or {}) do
        local path = da:GetFullName()
        if da:IsValid() and path:find("/Game/") and not path:find("Default__") then
            local name = safeString(da.Name)
            if name == "" then name = da:GetFName():ToString() end
            local rarity = RARITY[da.Rarity] or OTHER_RARITY
            table.insert(items, {
                da = da,
                name = name,
                rarity = rarity,
                description = safeString(da.Description),
            })
        end
    end
    table.sort(items, function(a, b)
        if a.rarity.order ~= b.rarity.order then return a.rarity.order < b.rarity.order end
        return a.name < b.name
    end)
    state.lists[index] = items
    log(string.format("found %d %s", #items, cat.label))
    return items
end

local function currentItems()
    local items = state.lists[state.category]
    if not items or #items == 0 or not items[1].da:IsValid() then
        items = scanCategory(state.category)
    end
    return items
end

------------------------------------------------------------------------
-- Spawning
------------------------------------------------------------------------

local function getLocalPlayer()
    for _, pc in ipairs(FindAllOf("CrabPC") or {}) do
        if pc:IsValid() and pc:IsLocalController() then
            local pawn = pc.Pawn
            if pawn and pawn:IsValid() then return pc, pawn end
            return pc, nil
        end
    end
    return nil, nil
end

-- UE4SS sometimes raises non-string errors, so record which step we were on.
local grantStep = ""

-- Server side: write the item straight into the player state's inventory
-- array. The arrays replicate, so clients see the change on their own.
local function grantOnServer(ps, cat, da, level)
    grantStep = "read array"
    local arr = ps[cat.array]
    local count = #arr
    local address = da:GetAddress()

    grantStep = "scan existing"
    for i = 1, count do
        local entry = arr[i]
        local existing = entry[cat.field]
        if existing and existing:IsValid() and existing:GetAddress() == address then
            grantStep = "upgrade level"
            local info = entry.InventoryInfo
            info.Level = math.min(255, info.Level + level)
            grantStep = "OnRep_Inventory"
            ps:OnRep_Inventory()
            return string.format("upgraded to Lv %d", info.Level)
        end
    end

    -- UE4SS 3.0.1 only grows a TArray when indexed *two* past the end (or when
    -- it is empty); indexing one past the end writes out of bounds instead.
    -- So touch Num+2 to grow by exactly one zeroed element, then fill in Num+1.
    grantStep = "grow array"
    local _ = arr[count > 0 and count + 2 or 1]
    arr = ps[cat.array]
    if #arr ~= count + 1 then
        error(string.format("array did not grow (%d -> %d)", count, #arr))
    end
    grantStep = "set item"
    local entry = arr[count + 1]
    entry[cat.field] = da
    grantStep = "set level"
    entry.InventoryInfo.Level = level

    grantStep = "verify"
    local stored = ps[cat.array][count + 1][cat.field]
    if not stored:IsValid() or stored:GetAddress() ~= address then
        error("item did not stick")
    end

    grantStep = "slots"
    if cat.slots and ps[cat.slots] < count + 1 then
        ps[cat.slots] = count + 1
    end
    grantStep = "OnRep_Inventory"
    ps:OnRep_Inventory()
    return string.format("added at Lv %d", level)
end

local function describeError(err)
    local text = type(err) == "string" and err or (type(err) .. " error")
    local trace = (debug and debug.traceback) and debug.traceback("", 2) or ""
    return string.format("%s (step: %s)%s", text, grantStep, trace)
end

-- Clients can't touch the inventory, so they ask the host through the chat
-- RPC; the host's copy of this mod picks the request up (see hook below).
local REQUEST_PATTERN = "^%[PerkSpawner%] .- Lv(%d+) {(.-)}$"

local function requestFromHost(pc, item, level)
    local message = string.format("[PerkSpawner] %s Lv%d {%s}", item.name, level, item.da:GetFName():ToString())
    pc:ServerSendChatMessage(message)
end

local function findItemByAssetName(assetName)
    for i, cat in ipairs(CATEGORIES) do
        for _, item in ipairs(state.lists[i] or scanCategory(i)) do
            if item.da:IsValid() and item.da:GetFName():ToString() == assetName then
                return cat, item
            end
        end
    end
    return nil, nil
end

local function giveItem(item, level)
    local pc = getLocalPlayer()
    if not pc then
        return "no local player found"
    end
    local cat = CATEGORIES[state.category]

    if pc:HasAuthority() then
        local ps = pc.PlayerState
        if not ps or not ps:IsValid() then return "no player state yet" end
        local ok, result = xpcall(grantOnServer, describeError, ps, cat, item.da, level)
        if not ok then
            log("grant failed: " .. result)
            return "failed, see UE4SS.log"
        end
        log(string.format("%s %s", item.name, result))
        return string.format("%s %s", item.name, result)
    end

    local ok, err = pcall(requestFromHost, pc, item, level)
    if not ok then
        log("request failed: " .. tostring(err))
        return "failed, see UE4SS.log"
    end
    log(string.format("requested %s Lv %d from host", item.name, level))
    return string.format("Asked host for %s Lv %d (host needs the mod too)", item.name, level)
end

local function onChatMessage(context, message)
    local pc = context:get()
    if not pc:IsValid() or not pc:HasAuthority() then return end

    local text = message:get():ToString()
    local level, assetName = text:match(REQUEST_PATTERN)
    if not assetName then return end

    local ps = pc.PlayerState
    local cat, item = findItemByAssetName(assetName)
    if not cat or not ps or not ps:IsValid() then
        log("could not handle request: " .. text)
        return
    end
    local result = grantOnServer(ps, cat, item.da, tonumber(level))
    log(string.format("granted client request: %s %s", item.name, result))
end

local hookOk, hookErr = pcall(RegisterHook, "/Script/CrabChampions.CrabPC:ServerSendChatMessage", function(context, message)
    local ok, err = xpcall(onChatMessage, describeError, context, message)
    if not ok then log("chat hook error: " .. err) end
end)
if not hookOk then log("could not hook chat RPC: " .. tostring(hookErr)) end


------------------------------------------------------------------------
-- UI (built from plain UMG widgets at runtime)
------------------------------------------------------------------------

local Visibility = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }
local HAlign = { Fill = 0, Left = 1, Center = 2, Right = 3 }
local VAlign = { Fill = 0, Top = 1, Center = 2, Bottom = 3 }
local SIZE_AUTO = { SizeRule = 0, Value = 1.0 }
local SIZE_FILL = { SizeRule = 1, Value = 1.0 }
local CLIP_TO_BOUNDS = 1
local JUSTIFY_CENTER = 1

local COLORS = {
    panel       = { R = 0.03, G = 0.04, B = 0.07, A = 0.95 },
    section     = { R = 0.07, G = 0.09, B = 0.14, A = 1 },
    tab         = { R = 0.12, G = 0.14, B = 0.21, A = 1 },
    tabActive   = { R = 0.93, G = 0.42, B = 0.22, A = 1 },
    field       = { R = 0.10, G = 0.12, B = 0.18, A = 1 },
    button      = { R = 0.18, G = 0.21, B = 0.30, A = 1 },
    give        = { R = 0.18, G = 0.58, B = 0.30, A = 1 },
    rowSelected = { R = 0.93, G = 0.42, B = 0.22, A = 0.28 },
    clear       = { R = 0, G = 0, B = 0, A = 0 },
}

local TEXT = {
    white  = { R = 1, G = 1, B = 1, A = 1 },
    dim    = { R = 0.55, G = 0.58, B = 0.66, A = 1 },
    accent = { R = 1.00, G = 0.55, B = 0.30, A = 1 },
    green  = { R = 0.45, G = 1.00, B = 0.55, A = 1 },
}

-- Sizes are in Slate units (pixels at 1080p before DPI scaling).
local LAYOUT = {
    width = 920,
    listWidth = 480,
    rowHeight = 38,
    iconSize = 30,
    detailIconSize = 96,
    chrome = 300,  -- header, tabs, search, pager, two footer lines and padding
    minRows = 6,
    maxRows = 16,
}

local function uniqueName(base)
    nameCounter = nameCounter + 1
    return FName(string.format("PerkSpawner_%s_%d", base, nameCounter))
end

local function newWidget(className, outer, base)
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. className), outer, uniqueName(base))
end

local function margin(left, top, right, bottom)
    top = top or left
    return { Left = left, Top = top, Right = right or left, Bottom = bottom or top }
end

local FONT_PATHS = {
    "/Game/UI/Font/Bold_Font.Bold_Font",
    "/Engine/EngineFonts/Roboto.Roboto",
}

local function findFont()
    for _, path in ipairs(FONT_PATHS) do
        local font = StaticFindObject(path)
        if font and font:IsValid() then return font end
    end
    return nil
end

-- Written straight into the widget's Font property before it is first drawn;
-- round-tripping the struct through SetFont() loses the font object.
local function setFontSize(textBlock, size)
    local ok, err = pcall(function()
        local font = findFont()
        if font then textBlock.Font.FontObject = font end
        textBlock.Font.Size = size
    end)
    if not ok then log("font setup failed: " .. tostring(err)) end
end

-- Every label is a TextBlock inside its own Border. Colors go through the
-- Border (plain FLinearColor params) because UE4SS mangles TextBlock's FSlateColor.
local function setColor(label, color)
    label.frame:SetContentColorAndOpacity(color)
end

local function setText(label, text)
    label.text:SetText(FText(text))
end

local function makeLabel(tree, size, color)
    local frame = newWidget("Border", tree, "LabelFrame")
    frame:SetBrushColor(COLORS.clear)
    frame:SetPadding(margin(0))
    local tb = newWidget("TextBlock", tree, "Label")
    setFontSize(tb, size)
    frame:SetContent(tb)
    local label = { frame = frame, text = tb }
    setColor(label, color or TEXT.white)
    return label
end

local function makeBox(tree, color, padding, content)
    local box = newWidget("Border", tree, "Box")
    box:SetBrushColor(color)
    box:SetPadding(padding)
    if content then box:SetContent(content) end
    return box
end

local function makeButton(tree, text, size, color, padding)
    local label = makeLabel(tree, size)
    setText(label, text)
    local frame = makeBox(tree, color, padding or margin(12, 6), label.frame)
    frame:SetHorizontalAlignment(HAlign.Center)
    frame:SetVerticalAlignment(VAlign.Center)
    return { frame = frame, label = label }
end

local function makeIcon(tree, size)
    local box = newWidget("SizeBox", tree, "IconBox")
    box:SetWidthOverride(size)
    box:SetHeightOverride(size)
    local image = newWidget("Image", tree, "Icon")
    box:SetContent(image)
    return { box = box, image = image }
end

local function setIcon(icon, texture)
    if texture and texture:IsValid() then
        icon.image:SetBrushFromTexture(texture, false)
        icon.image:SetVisibility(Visibility.HitTestInvisible)
    else
        icon.image:SetVisibility(Visibility.Hidden)
    end
end

local function addV(box, widget, padding, hAlign)
    local slot = box:AddChildToVerticalBox(widget)
    if padding then slot:SetPadding(padding) end
    if hAlign then slot:SetHorizontalAlignment(hAlign) end
    return slot
end

local function addH(box, widget, size, padding, vAlign)
    local slot = box:AddChildToHorizontalBox(widget)
    slot:SetSize(size or SIZE_AUTO)
    if padding then slot:SetPadding(padding) end
    slot:SetVerticalAlignment(vAlign or VAlign.Center)
    return slot
end

local function computeRowCount()
    local rows = LAYOUT.maxRows
    pcall(function()
        local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local pc = getLocalPlayer()
        local size = lib:GetViewportSize(pc)
        local scale = lib:GetViewportScale(pc)
        if scale > 0 and size.Y > 0 then
            rows = math.floor((size.Y / scale * 0.88 - LAYOUT.chrome) / LAYOUT.rowHeight)
        end
    end)
    return math.max(LAYOUT.minRows, math.min(LAYOUT.maxRows, rows))
end

-- Actions wired up by the input section below.
local actions = {}

local function buildUI(rowCount)
    local gameInstance = FindFirstOf("GameInstance")
    if not gameInstance or not gameInstance:IsValid() then
        log("no GameInstance yet")
        return nil
    end

    local root = newWidget("UserWidget", gameInstance, "Menu")
    local tree = newWidget("WidgetTree", root, "Tree")
    root.WidgetTree = tree
    root.bIsFocusable = true

    local canvas = newWidget("CanvasPanel", tree, "Canvas")
    tree.RootWidget = canvas

    local built = { root = root, rowCount = rowCount, rows = {}, tabs = {}, clickables = {}, rowIndex = {} }
    local function clickable(widget, action)
        table.insert(built.clickables, { widget = widget, action = action })
    end

    local panel = makeBox(tree, COLORS.panel, margin(20, 16))
    panel:SetVisibility(Visibility.Visible)
    panel:SetClipping(CLIP_TO_BOUNDS)
    -- Centered on screen. Written straight into LayoutData before the widget is
    -- first drawn: SetAnchors() gets its nested FAnchors struct mangled by UE4SS.
    local panelSlot = canvas:AddChildToCanvas(panel)
    local layout = panelSlot.LayoutData
    layout.Anchors.Minimum.X = 0.5
    layout.Anchors.Minimum.Y = 0.5
    layout.Anchors.Maximum.X = 0.5
    layout.Anchors.Maximum.Y = 0.5
    layout.Alignment.X = 0.5
    layout.Alignment.Y = 0.5
    layout.Offsets.Left = 0.0
    layout.Offsets.Top = 0.0
    layout.Offsets.Right = LAYOUT.width
    layout.Offsets.Bottom = LAYOUT.chrome + rowCount * LAYOUT.rowHeight

    local main = newWidget("VerticalBox", tree, "Main")
    panel:SetContent(main)

    -- Header
    local header = newWidget("HorizontalBox", tree, "Header")
    local title = makeLabel(tree, 24, TEXT.accent)
    setText(title, "PERK SPAWNER")
    addH(header, title.frame, SIZE_FILL)
    local close = makeButton(tree, "Close  (F6)", 13, COLORS.button, margin(12, 5))
    addH(header, close.frame)
    clickable(close.frame, function() actions.close() end)
    addV(main, header, margin(0, 0, 0, 10))

    -- Category tabs
    local tabs = newWidget("HorizontalBox", tree, "Tabs")
    for i, cat in ipairs(CATEGORIES) do
        local tab = makeButton(tree, cat.label, 14, COLORS.tab, margin(10, 7))
        addH(tabs, tab.frame, SIZE_FILL, margin(0, 0, i < #CATEGORIES and 6 or 0, 0), VAlign.Fill)
        built.tabs[i] = tab
        clickable(tab.frame, function() actions.setCategory(i) end)
    end
    addV(main, tabs, margin(0, 0, 0, 10))

    -- Search line
    local searchRow = newWidget("HorizontalBox", tree, "SearchRow")
    built.search = makeLabel(tree, 15)
    addH(searchRow, makeBox(tree, COLORS.field, margin(10, 6), built.search.frame), SIZE_FILL)
    built.count = makeLabel(tree, 13, TEXT.dim)
    addH(searchRow, built.count.frame, SIZE_AUTO, margin(14, 0, 4, 0))
    addV(main, searchRow, margin(0, 0, 0, 10))

    -- Body: item list on the left, details on the right
    local body = newWidget("HorizontalBox", tree, "Body")
    local listSize = newWidget("SizeBox", tree, "ListSize")
    listSize:SetWidthOverride(LAYOUT.listWidth)
    local list = newWidget("VerticalBox", tree, "List")
    listSize:SetContent(list)

    for i = 1, rowCount do
        local rowLine = newWidget("HorizontalBox", tree, "RowLine")
        local icon = makeIcon(tree, LAYOUT.iconSize)
        addH(rowLine, icon.box, SIZE_AUTO, margin(0, 0, 10, 0))
        local name = makeLabel(tree, 15)
        addH(rowLine, name.frame, SIZE_FILL)
        local tag = makeLabel(tree, 12, TEXT.dim)
        addH(rowLine, tag.frame, SIZE_AUTO, margin(8, 0, 0, 0))

        local frame = makeBox(tree, COLORS.clear, margin(8, 3), rowLine)
        frame:SetVisibility(Visibility.Visible)
        local rowSize = newWidget("SizeBox", tree, "RowSize")
        rowSize:SetHeightOverride(LAYOUT.rowHeight)
        rowSize:SetContent(frame)
        addV(list, rowSize)

        built.rows[i] = { frame = frame, icon = icon, name = name, tag = tag }
        clickable(frame, function() actions.clickRow(i) end)
    end

    local pager = newWidget("HorizontalBox", tree, "Pager")
    local prev = makeButton(tree, "< Prev", 13, COLORS.button, margin(12, 5))
    addH(pager, prev.frame)
    clickable(prev.frame, function() actions.page(-1) end)
    built.page = makeLabel(tree, 13, TEXT.dim)
    built.page.text:SetJustification(JUSTIFY_CENTER)
    addH(pager, built.page.frame, SIZE_FILL)
    local nextButton = makeButton(tree, "Next >", 13, COLORS.button, margin(12, 5))
    addH(pager, nextButton.frame)
    clickable(nextButton.frame, function() actions.page(1) end)
    addV(list, pager, margin(0, 8, 0, 0))

    addH(body, listSize, SIZE_AUTO, nil, VAlign.Top)

    local detailBox = newWidget("VerticalBox", tree, "Detail")
    local detail = makeBox(tree, COLORS.section, margin(16, 14), detailBox)
    detail:SetClipping(CLIP_TO_BOUNDS)

    built.detailIcon = makeIcon(tree, LAYOUT.detailIconSize)
    addV(detailBox, built.detailIcon.box, margin(0, 0, 0, 10), HAlign.Center)
    built.detailName = makeLabel(tree, 22)
    built.detailName.text:SetJustification(JUSTIFY_CENTER)
    built.detailName.text:SetAutoWrapText(true)
    addV(detailBox, built.detailName.frame, nil, HAlign.Fill)
    built.detailRarity = makeLabel(tree, 13, TEXT.dim)
    addV(detailBox, built.detailRarity.frame, margin(0, 2, 0, 4), HAlign.Center)
    built.detailOwned = makeLabel(tree, 13, TEXT.green)
    addV(detailBox, built.detailOwned.frame, margin(0, 0, 0, 10), HAlign.Center)
    built.detailText = makeLabel(tree, 14)
    built.detailText.text:SetJustification(JUSTIFY_CENTER)
    built.detailText.text:SetAutoWrapText(true)
    addV(detailBox, built.detailText.frame, nil, HAlign.Fill)

    local spacer = newWidget("Spacer", tree, "Spacer")
    addV(detailBox, spacer):SetSize(SIZE_FILL)

    local levelRow = newWidget("HorizontalBox", tree, "LevelRow")
    local minus = makeButton(tree, "-", 18, COLORS.button, margin(16, 4))
    addH(levelRow, minus.frame, SIZE_AUTO, nil, VAlign.Fill)
    clickable(minus.frame, function() actions.level(-1) end)
    built.level = makeLabel(tree, 17)
    built.level.text:SetJustification(JUSTIFY_CENTER)
    addH(levelRow, built.level.frame, SIZE_FILL)
    local plus = makeButton(tree, "+", 18, COLORS.button, margin(16, 4))
    addH(levelRow, plus.frame, SIZE_AUTO, nil, VAlign.Fill)
    clickable(plus.frame, function() actions.level(1) end)
    addV(detailBox, levelRow, margin(0, 8, 0, 8), HAlign.Fill)

    local give = makeButton(tree, "GIVE", 18, COLORS.give, margin(12, 9))
    addV(detailBox, give.frame, nil, HAlign.Fill)
    clickable(give.frame, function() actions.give() end)

    built.status = makeLabel(tree, 13, TEXT.green)
    built.status.text:SetJustification(JUSTIFY_CENTER)
    built.status.text:SetAutoWrapText(true)
    addV(detailBox, built.status.frame, margin(0, 8, 0, 0), HAlign.Fill)

    addH(body, detail, SIZE_FILL, margin(14, 0, 0, 0), VAlign.Fill)
    addV(main, body):SetSize(SIZE_FILL)

    -- Footer
    local hints = {
        "Click an item to select it, click again to give  |  Type to search, Backspace erases",
        "Up/Down select  |  PgUp/PgDn page  |  Left/Right category  |  +/- level  |  Enter give",
    }
    for i, line in ipairs(hints) do
        local hint = makeLabel(tree, 12, TEXT.dim)
        setText(hint, line)
        addV(main, hint.frame, margin(0, i == 1 and 10 or 2, 0, 0), HAlign.Center)
    end

    root:AddToViewport(1000)
    pcall(function()
        log(string.format("menu built (%d rows), anchor %.2f,%.2f align %.2f,%.2f size %.0fx%.0f", rowCount,
            layout.Anchors.Minimum.X, layout.Anchors.Minimum.Y, layout.Alignment.X, layout.Alignment.Y,
            layout.Offsets.Right, layout.Offsets.Bottom))
    end)
    return built
end

local function ensureUI()
    local rowCount = computeRowCount()
    if ui and ui.root:IsValid() and ui.root:IsInViewport() then
        if ui.rowCount == rowCount then return ui end
        ui.root:RemoveFromParent()
    end
    ui = buildUI(rowCount)
    return ui
end

------------------------------------------------------------------------
-- Menu state -> widgets
------------------------------------------------------------------------

local function filteredItems()
    local items = currentItems()
    if state.search == "" then return items end
    local query = state.search:lower()
    local matches = {}
    for _, item in ipairs(items) do
        if item.name:lower():find(query, 1, true) then
            table.insert(matches, item)
        end
    end
    return matches
end

-- Levels of the items the local player already has in this category, keyed
-- by data asset address. The inventory replicates, so this works on clients.
local function ownedLevels(cat)
    local owned = {}
    pcall(function()
        local pc = getLocalPlayer()
        local ps = pc and pc.PlayerState
        if not ps or not ps:IsValid() then return end
        local arr = ps[cat.array]
        for i = 1, #arr do
            local entry = arr[i]
            local da = entry[cat.field]
            if da and da:IsValid() then
                owned[da:GetAddress()] = entry.InventoryInfo.Level
            end
        end
    end)
    return owned
end

local function cleanDescription(text)
    return (text:gsub("<%/?[%w_]*>", ""))
end

local function refreshUI()
    if not ui or not ui.root:IsValid() then return end
    local cat = CATEGORIES[state.category]
    local items = filteredItems()
    local owned = ownedLevels(cat)
    local rowCount = ui.rowCount

    state.selected = math.max(1, math.min(state.selected, #items))

    for i, tab in ipairs(ui.tabs) do
        tab.frame:SetBrushColor(i == state.category and COLORS.tabActive or COLORS.tab)
    end

    if state.search == "" then
        setText(ui.search, "Type to search...")
        setColor(ui.search, TEXT.dim)
    else
        setText(ui.search, state.search .. "_")
        setColor(ui.search, TEXT.white)
    end
    setText(ui.count, string.format("%d %s", #items, #items == 1 and "item" or "items"))

    local pageCount = math.max(1, math.ceil(#items / rowCount))
    local page = math.floor((state.selected - 1) / rowCount)
    local first = page * rowCount + 1
    setText(ui.page, string.format("Page %d / %d", page + 1, pageCount))

    for i, row in ipairs(ui.rows) do
        local index = first + i - 1
        local item = items[index]
        ui.rowIndex[i] = item and index or nil
        if item then
            local level = owned[item.da:GetAddress()]
            setText(row.name, item.name)
            setColor(row.name, item.rarity.color)
            setText(row.tag, level and string.format("OWNED  Lv %d", level) or item.rarity.name)
            setColor(row.tag, level and TEXT.green or TEXT.dim)
            setIcon(row.icon, item.da.Icon)
            row.frame:SetBrushColor(index == state.selected and COLORS.rowSelected or COLORS.clear)
        else
            setText(row.name, (i == 1 and #items == 0) and "Nothing matches" or "")
            setColor(row.name, TEXT.dim)
            setText(row.tag, "")
            setIcon(row.icon, nil)
            row.frame:SetBrushColor(COLORS.clear)
        end
    end

    local item = items[state.selected]
    if item then
        local level = owned[item.da:GetAddress()]
        setIcon(ui.detailIcon, item.da.Icon)
        setText(ui.detailName, item.name)
        setColor(ui.detailName, item.rarity.color)
        setText(ui.detailRarity, string.format("%s  %s", item.rarity.name, (cat.label:gsub("s$", ""))))
        setText(ui.detailOwned, level and string.format("You have it at Lv %d", level) or "")
        setText(ui.detailText, cleanDescription(item.description))
    else
        setIcon(ui.detailIcon, nil)
        setText(ui.detailName, "")
        setText(ui.detailRarity, "")
        setText(ui.detailOwned, "")
        setText(ui.detailText, "")
    end
    setText(ui.level, string.format("Level %d", state.level))
    setText(ui.status, state.status)
end

------------------------------------------------------------------------
-- Opening, closing and handing input back to the game
------------------------------------------------------------------------

local function widgetLibrary()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
end

local function captureInput()
    local pc = getLocalPlayer()
    if not pc then return end
    pcall(function() pc:ClientSetIsCharacterInputEnabled(false) end)
    pcall(function() widgetLibrary():SetInputMode_UIOnlyEx(pc, ui.root, 0) end)
    pcall(function() pc.bShowMouseCursor = true end)
end

local function releaseInput()
    local pc = getLocalPlayer()
    if not pc then return end
    pcall(function() pc.bShowMouseCursor = false end)
    pcall(function() widgetLibrary():SetInputMode_GameOnly(pc) end)
    pcall(function() pc:ClientSetIsCharacterInputEnabled(true) end)
end

local function isOpen()
    return state.open and ui and ui.root:IsValid() and ui.root:IsInViewport()
end

local function setOpen(open)
    if open then
        if not ensureUI() then return end
        ui.root:SetVisibility(Visibility.SelfHitTestInvisible)
        state.open = true
        state.status = ""
        refreshUI()
        captureInput()
    else
        local wasOpen = state.open
        state.open = false
        if ui and ui.root:IsValid() then
            ui.root:SetVisibility(Visibility.Collapsed)
        end
        if wasOpen then releaseInput() end
    end
end

------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------

local function onGameThread(fn)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log("error: " .. tostring(err)) end
        end)
    end
end

local function whenOpen(fn)
    return onGameThread(function()
        if not isOpen() then return end
        fn()
        refreshUI()
    end)
end

local function moveSelection(delta)
    state.selected = state.selected + delta
    state.status = ""
end

function actions.setCategory(index)
    state.category = index
    state.selected = 1
    state.status = ""
end

local function changeCategory(delta)
    actions.setCategory((state.category - 1 + delta) % #CATEGORIES + 1)
end

function actions.level(delta)
    state.level = math.max(1, math.min(50, state.level + delta))
end

function actions.page(delta)
    moveSelection(delta * ui.rowCount)
end

function actions.give()
    local item = filteredItems()[state.selected]
    if not item then return end
    state.status = giveItem(item, state.level)
end

function actions.clickRow(i)
    local index = ui.rowIndex[i]
    if not index then return end
    if index == state.selected then
        actions.give()
    else
        state.selected = index
        state.status = ""
    end
end

function actions.close()
    setOpen(false)
end

local function setSearch(text)
    state.search = text
    state.selected = 1
    state.status = ""
end

local function handleClick()
    for _, target in ipairs(ui.clickables) do
        if target.widget:IsHovered() then
            target.action()
            return
        end
    end
end

RegisterKeyBind(TOGGLE_KEY, onGameThread(function() setOpen(not isOpen()) end))
RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, whenOpen(handleClick))
RegisterKeyBind(Key.UP_ARROW, whenOpen(function() moveSelection(-1) end))
RegisterKeyBind(Key.DOWN_ARROW, whenOpen(function() moveSelection(1) end))
RegisterKeyBind(Key.PAGE_UP, whenOpen(function() actions.page(-1) end))
RegisterKeyBind(Key.PAGE_DOWN, whenOpen(function() actions.page(1) end))
RegisterKeyBind(Key.LEFT_ARROW, whenOpen(function() changeCategory(-1) end))
RegisterKeyBind(Key.RIGHT_ARROW, whenOpen(function() changeCategory(1) end))
RegisterKeyBind(Key.OEM_PLUS, whenOpen(function() actions.level(1) end))
RegisterKeyBind(Key.ADD, whenOpen(function() actions.level(1) end))
RegisterKeyBind(Key.OEM_MINUS, whenOpen(function() actions.level(-1) end))
RegisterKeyBind(Key.SUBTRACT, whenOpen(function() actions.level(-1) end))
RegisterKeyBind(Key.RETURN, whenOpen(actions.give))
RegisterKeyBind(Key.BACKSPACE, whenOpen(function() setSearch(state.search:sub(1, -2)) end))
RegisterKeyBind(Key.DEL, whenOpen(function() setSearch("") end))
RegisterKeyBind(Key.SPACE, whenOpen(function()
    if state.search ~= "" then setSearch(state.search .. " ") end
end))
for letter in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do
    local char = letter:lower()
    RegisterKeyBind(Key[letter], whenOpen(function() setSearch(state.search .. char) end))
end

log("loaded - press F6 in game")
