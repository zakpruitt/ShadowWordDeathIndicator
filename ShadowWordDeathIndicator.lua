-- Shadow Word: Death Indicator
-- When your highest known rank of Shadow Word: Death will kill the target, a soft glow hugs the target's health
-- and power bars and its portrait turns into the SW:D icon.
--
-- On WoW: Forever the target's health is a "secret" value in combat: Lua can't compare it with anything. A
-- StatusBar still accepts it, so the widget does the comparison:
--   * a very long invisible StatusBar with max = target health and value = SW:D damage, whose fill only reaches
--     the bar's right end when damage >= health;
--   * the effect rides the fill's right end inside a clipping window at the bar's right end, so it's on screen
--     only when SW:D is lethal.
--
-- SW:D's damage comes from its tooltip ("X to Y Shadow damage"), cached whenever the tooltip is readable.

local ADDON_NAME = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local TEXTURES = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\"
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local FALLBACK_ICON = "Interface\\Icons\\Spell_Shadow_DemonicFortitude" -- SW:D's icon

-- Glow.tga is a 9-slice: 24-texel corners of 64, with the outlined edge 16 texels in from the outside. Halo.tga
-- is round, with the outlined edge at radius 24 of 32. Both come from tools/make_textures.py.
local GLOW_SIZE, GLOW_CORNER_TEXELS, GLOW_EDGE_TEXELS = 64, 24, 16
local HALO_EDGE_RATIO = 24 / 32

local BAR_LENGTH = 100000 -- px; longer = the effect appears closer to exactly lethal (see feed)
local BAR_GLOW_CORNER = 18 -- px on screen of a Glow.tga corner around the bars
local NO_PORTRAIT_SIZE = 40
local FALLBACK_WIDTH, FALLBACK_HEIGHT = 260, 100
local PULSE_SECONDS = 1.6
local UPDATE_INTERVAL = 0.05
local REFRESH_INTERVAL = 2 -- seconds between re-reading the spell

-- Shadow Word: Death: TBC/Wrath ranks, then Season of Discovery's rune. The name lookup in candidateIds() adds
-- any ID missing here; the known one with the most damage is used.
local SWD_IDS = { 48158, 48157, 32996, 32379, 401955 }

-- Target frames tried in order (the first that's shown is used), with their bars' keys.
local AUTO_FRAMES = {
    { frame = "EllesmereUIUnitFrames_Target", health = "Health", power = "Power" },
    { frame = "ElvUF_Target", health = "Health", power = "Power" },
    { frame = "SUFUnittarget", health = "healthBar", power = "powerBar" },
    { frame = "TargetFrame", health = "healthbar", power = "manabar" },
}

-- Portraits tried in order (the first that's visible is used). Blizzard's are round.
local AUTO_PORTRAITS = {
    { path = "EllesmereUIUnitFrames_Target.Portrait" },
    { path = "ElvUF_Target.Portrait" },
    { path = "TargetFrame.TargetFrameContainer.Portrait", round = true },
    { path = "TargetFrame.portrait", round = true },
    { path = "TargetFramePortrait", round = true },
}

local DEFAULTS = {
    mode = "min",        -- part of the damage range to trust: min (never a false glow), avg, max
    mult = 1.0,          -- multiplier on the estimate (e.g. 1.15 if Shadowform isn't in the tooltip)
    flat = 0,            -- flat amount added (negative to be safer)
    spCoef = 0,          -- adds spell power * this, for tooltips that leave spell power out (0 = off)
    color = { 0.75, 0.35, 1.0 },
    intensity = 0.4,     -- 0-1
    pulse = true,
    label = false,       -- "SW:D KILL" above the bars
    border = true,       -- glow around the bars
    portrait = true,     -- SW:D icon over the portrait
    shape = "auto",      -- portrait icon: auto (round on Blizzard's frame), round, square
    framePath = "",      -- "" = automatic; else the region to glow around
    portraitPath = "",   -- "" = automatic
}

local db

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function isSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, r = pcall(issecretvalue, v)
    return ok and r or false
end

-- fn(...)'s first result if it runs and isn't secret, else nil.
local function plain(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok and not isSecret(v) then return v end
end

-- A region's left, bottom, right, top, or nil if it has no rectangle or any of it is secret.
local function plainRect(region)
    local ok, left, bottom, width, height = pcall(region.GetRect, region)
    if not ok then return nil end
    for _, v in ipairs({ left, bottom, width, height }) do
        if type(v) ~= "number" or isSecret(v) then return nil end
    end
    return left, bottom, left + width, bottom + height
end

local function isVisible(region)
    return region ~= nil and plain(region.IsVisible, region) ~= false
end

local function say(msg)
    print("|cffb266ffSW:D Indicator|r: " .. msg)
end

local function onOff(v)
    return v and "on" or "off"
end

-- "Frame.child.key" -> that region, or nil.
local function resolvePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, object = pcall(function()
        local object
        for part in path:gmatch("[^%.]+") do
            if object == nil then
                object = _G[part]
            elseif type(object) == "table" then
                object = object[part]
            else
                return nil
            end
        end
        return object
    end)
    if ok and type(object) == "table" and type(object.GetObjectType) == "function" then return object end
end

---------------------------------------------------------------------------
-- The spell: highest known rank and its damage
---------------------------------------------------------------------------

local spell = {}  -- id, name, lo, hi, desc: last readable values; empty when SW:D isn't known
local spellPower  -- last readable Shadow spell power

local function spellName(id)
    if C_Spell and C_Spell.GetSpellName then return plain(C_Spell.GetSpellName, id) end
    return plain(GetSpellInfo, id)
end

local function spellDescription(id)
    return plain((C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription, id)
end

local function spellIcon(id)
    return (C_Spell and plain(C_Spell.GetSpellTexture, id)) or plain(GetSpellTexture, id)
end

local function isKnown(id)
    return plain(IsPlayerSpell, id) == true or plain(IsSpellKnown, id) == true
end

-- "inflicts 450 to 522 Shadow damage" -> 450, 522. Thousands separators are allowed.
local function parseDamage(desc)
    if type(desc) ~= "string" then return nil end
    desc = desc:gsub("(%d),(%d)", "%1%2")
    local lo, hi = desc:match("(%d+) to (%d+)[%a ]-[Ss]hadow damage")
    if not lo then
        lo = desc:match("(%d+)[%a ]-[Ss]hadow damage")
        hi = lo
    end
    if not lo then lo, hi = desc:match("(%d+)%s*%-%s*(%d+)") end -- other languages: "450 - 522"
    lo, hi = tonumber(lo), tonumber(hi)
    if not lo then return nil end
    return lo, math.max(hi or lo, lo)
end

-- SWD_IDS plus whatever the name lookup gives (Classic clients answer a name with the highest known rank).
local function candidateIds()
    local ids, seen = {}, {}
    local function add(id)
        if type(id) == "number" and not isSecret(id) and not seen[id] then
            seen[id] = true
            table.insert(ids, id)
        end
    end
    for _, id in ipairs(SWD_IDS) do add(id) end
    local name = spellName(32379) or "Shadow Word: Death"
    local info = C_Spell and plain(C_Spell.GetSpellInfo, name)
    if type(info) == "table" then add(info.spellID) end
    if GetSpellInfo then
        local ok, _, _, _, _, _, _, id = pcall(GetSpellInfo, name)
        if ok then add(id) end
    end
    return ids
end

local function refreshSpell()
    local best, anyKnown = nil, false
    for _, id in ipairs(candidateIds()) do
        if isKnown(id) then
            anyKnown = true
            local desc = spellDescription(id)
            local lo, hi = parseDamage(desc)
            if lo and (not best or lo > best.lo) then
                best = { id = id, name = spellName(id), lo = lo, hi = hi, desc = desc }
            end
        end
    end
    if best then
        spell = best
    elseif not anyKnown and not InCombatLockdown() then
        spell = {} -- out of combat nothing is hidden, so the spell really isn't known (respec, low level)
    end
    local sp = plain(GetSpellBonusDamage, 6) -- 6 = Shadow
    if type(sp) == "number" then spellPower = sp end
end

-- The damage the effects are based on, or nil if unknown.
local function estimate()
    if not spell.lo then return nil end
    local base = spell.lo
    if db.mode == "max" then
        base = spell.hi
    elseif db.mode == "avg" then
        base = (spell.lo + spell.hi) / 2
    end
    return math.max((base + (spellPower or 0) * db.spCoef) * db.mult + db.flat, 0)
end

---------------------------------------------------------------------------
-- Lethal windows
---------------------------------------------------------------------------

-- A clipping window whose `content` (same size as the window) is on screen only when SW:D is lethal.
local function makeLethalWindow(name, level)
    local L = { width = FALLBACK_WIDTH }

    local window = CreateFrame("Frame", name, UIParent)
    window:SetClipsChildren(true)
    window:SetFrameStrata("HIGH")
    window:SetFrameLevel(level)
    window:SetSize(FALLBACK_WIDTH, FALLBACK_HEIGHT)
    window:Hide()

    local bar = CreateFrame("StatusBar", nil, window)
    bar:SetPoint("TOPRIGHT")
    bar:SetPoint("BOTTOMRIGHT")
    bar:SetWidth(BAR_LENGTH)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0, 0, 0, 0)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local fill = bar:GetStatusBarTexture()
    local content = CreateFrame("Frame", nil, bar)
    content:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
    content:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
    content:SetWidth(FALLBACK_WIDTH)

    window:SetScript("OnSizeChanged", function()
        local w = plain(window.GetWidth, window)
        if type(w) ~= "number" or w <= 0 then w = FALLBACK_WIDTH end
        L.width = w
        content:SetWidth(w)
    end)

    -- The content starts sliding into view at value/max >= 1 - width / BAR_LENGTH. Scaling damage by that
    -- moves the start to exactly damage >= health, so any of it showing means lethal.
    local function feed(damage)
        bar:SetMinMaxValues(0, UnitHealth("target")) -- secret in combat; the StatusBar takes it anyway
        bar:SetValue(damage * (1 - L.width / BAR_LENGTH))
    end

    -- damage = nil hides the window; testing shows the content regardless.
    function L.show(enabled, damage, testing)
        if not enabled or not (damage or testing) then
            window:Hide()
        elseif testing then
            bar:SetMinMaxValues(0, 1)
            bar:SetValue(1)
            window:Show()
        else
            window:SetShown((pcall(feed, damage)))
        end
    end

    L.window, L.content = window, content
    return L
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------

local pulses = {}

local function addPulse(region, from, to)
    local group = region:CreateAnimationGroup()
    group:SetLooping("BOUNCE")
    local a = group:CreateAnimation("Alpha")
    a:SetFromAlpha(from)
    a:SetToAlpha(to)
    a:SetDuration(PULSE_SECONDS)
    a:SetSmoothing("IN_OUT")
    table.insert(pulses, group)
end

-- Px a 9-slice glow with this corner size reaches outside the edge it outlines.
local function glowReach(corner)
    return corner * GLOW_EDGE_TEXELS / GLOW_CORNER_TEXELS
end

-- Glow.tga as a 9-slice filling `parent`: fixed corners, stretched edges, empty middle.
-- Returns the pieces and a function that sets the on-screen corner size.
local NINE_SLICE_CORNERS = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
local function makeNineSlice(parent, layer)
    local c = GLOW_CORNER_TEXELS / GLOW_SIZE
    local texCoords = {
        TOPLEFT = { 0, c, 0, c },
        TOPRIGHT = { 1 - c, 1, 0, c },
        BOTTOMLEFT = { 0, c, 1 - c, 1 },
        BOTTOMRIGHT = { 1 - c, 1, 1 - c, 1 },
        TOP = { c, 1 - c, 0, c },
        BOTTOM = { c, 1 - c, 1 - c, 1 },
        LEFT = { 0, c, c, 1 - c },
        RIGHT = { 1 - c, 1, c, 1 - c },
    }
    local p = {}
    for name, coords in pairs(texCoords) do
        local t = parent:CreateTexture(nil, layer)
        t:SetTexture(TEXTURES .. "Glow")
        t:SetTexCoord(unpack(coords))
        t:SetBlendMode("ADD")
        p[name] = t
    end

    -- Corners sit in the parent's corners; each edge spans between its two corners.
    for _, corner in ipairs(NINE_SLICE_CORNERS) do p[corner]:SetPoint(corner) end
    local function span(edge, a, aPoint, b, bPoint)
        p[edge]:SetPoint("TOPLEFT", p[a], aPoint)
        p[edge]:SetPoint("BOTTOMRIGHT", p[b], bPoint)
    end
    span("TOP", "TOPLEFT", "TOPRIGHT", "TOPRIGHT", "BOTTOMLEFT")
    span("BOTTOM", "BOTTOMLEFT", "TOPRIGHT", "BOTTOMRIGHT", "BOTTOMLEFT")
    span("LEFT", "TOPLEFT", "BOTTOMLEFT", "BOTTOMLEFT", "TOPRIGHT")
    span("RIGHT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT", "TOPRIGHT")

    local function setCorner(size)
        for _, corner in ipairs(NINE_SLICE_CORNERS) do p[corner]:SetSize(size, size) end
    end
    return p, setCorner
end

---------------------------------------------------------------------------
-- Bar glow: a soft rounded glow hugging the health and power bars, and a faint wash over them
---------------------------------------------------------------------------

local BAR_PAD = glowReach(BAR_GLOW_CORNER)
local barGlow = makeLethalWindow("ShadowWordDeathIndicatorBars", 10)
local barLook = {}
do
    local c = barGlow.content
    local setCorner
    barLook.glow, setCorner = makeNineSlice(c, "ARTWORK")
    setCorner(BAR_GLOW_CORNER)

    barLook.wash = c:CreateTexture(nil, "BACKGROUND")
    barLook.wash:SetTexture(WHITE)
    barLook.wash:SetBlendMode("ADD")
    barLook.wash:SetPoint("TOPLEFT", BAR_PAD, -BAR_PAD)
    barLook.wash:SetPoint("BOTTOMRIGHT", -BAR_PAD, BAR_PAD)

    barLook.label = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    barLook.label:SetPoint("BOTTOM", c, "TOP", 0, -BAR_PAD + 2)
    barLook.label:SetText("SW:D KILL")

    addPulse(c, 1, 0.7)
end

---------------------------------------------------------------------------
-- Portrait: the SW:D icon over the portrait with a soft halo around it (round or square)
---------------------------------------------------------------------------

local portraitGlow = makeLethalWindow("ShadowWordDeathIndicatorPortrait", 30)
local portraitLook = {}
do
    local c = portraitGlow.content
    local look = portraitLook

    look.halo = c:CreateTexture(nil, "BACKGROUND")
    look.halo:SetTexture(TEXTURES .. "Halo")
    look.halo:SetBlendMode("ADD")
    look.halo:SetAllPoints()
    addPulse(look.halo, 1, 0.5)

    look.squareGlow, look.setSquareCorner = makeNineSlice(c, "BACKGROUND")
    for _, piece in pairs(look.squareGlow) do addPulse(piece, 1, 0.5) end

    look.icon = c:CreateTexture(nil, "ARTWORK")
    look.icon:SetTexture(FALLBACK_ICON)

    local ok, mask = pcall(c.CreateMaskTexture, c)
    if ok and mask then
        mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(look.icon)
        look.mask = mask
    end
end

function portraitLook.setIcon(id)
    if id == portraitLook.iconFor then return end
    portraitLook.iconFor = id
    portraitLook.icon:SetTexture((id and spellIcon(id)) or FALLBACK_ICON)
end

-- Lays out the icon `pad` px inside the window: round (halo, masked icon) or square (9-slice glow).
function portraitLook.layout(round, pad)
    local look = portraitLook
    look.round = round
    look.icon:ClearAllPoints()
    look.icon:SetPoint("TOPLEFT", pad, -pad)
    look.icon:SetPoint("BOTTOMRIGHT", -pad, pad)
    if look.mask then
        pcall(round and look.icon.AddMaskTexture or look.icon.RemoveMaskTexture, look.icon, look.mask)
    end
    local inset = round and 0 or 0.08 -- trims the icon's built-in border when square
    look.icon:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
    look.halo:SetShown(round)
    look.setSquareCorner(pad * GLOW_CORNER_TEXELS / GLOW_EDGE_TEXELS)
    for _, piece in pairs(look.squareGlow) do piece:SetShown(not round) end
end

local function applyLook()
    local r, g, b = unpack(db.color)
    local a = db.intensity
    local halo = math.min(1, a * 1.5)

    for _, piece in pairs(barLook.glow) do piece:SetVertexColor(r, g, b, a) end
    barLook.wash:SetVertexColor(r, g, b, a * 0.12)
    barLook.label:SetTextColor(r, g, b, math.min(1, a * 2))
    barLook.label:SetShown(db.label)

    portraitLook.halo:SetVertexColor(r, g, b, halo)
    for _, piece in pairs(portraitLook.squareGlow) do piece:SetVertexColor(r, g, b, halo) end

    for _, group in ipairs(pulses) do
        if db.pulse then group:Play() else group:Stop() end
    end
end

---------------------------------------------------------------------------
-- Attaching to the target's bars and portrait
---------------------------------------------------------------------------

-- What to glow around: the set region, else the first shown known frame's health bar (and power bar).
local function findBars()
    local custom = resolvePath(db.framePath)
    if custom then return custom end
    for _, known in ipairs(AUTO_FRAMES) do
        local frame = resolvePath(known.frame)
        if frame and plain(frame.IsShown, frame) ~= false then
            local health = resolvePath(known.frame .. "." .. known.health)
            if not health then return frame end
            local power = resolvePath(known.frame .. "." .. known.power)
            return health, isVisible(power) and power or nil
        end
    end
    return _G.TargetFrame
end

-- The portrait to cover and whether it's round, or nil.
local function findPortrait()
    local custom = resolvePath(db.portraitPath)
    if custom then return custom, false end
    for _, known in ipairs(AUTO_PORTRAITS) do
        local p = resolvePath(known.path)
        if isVisible(p) then return p, known.round == true end
    end
end

-- Offsets from `main`'s TOPLEFT (left, top) and BOTTOMRIGHT (right, bottom) to the box around `main` and
-- `extra`, grown by `pad`. Just the pad without `extra` or when a rectangle can't be read.
local function boxOffsets(main, extra, pad)
    local ml, mb, mr, mt = plainRect(main)
    local el, eb, er, et
    if extra and ml then el, eb, er, et = plainRect(extra) end
    if not el then return -pad, pad, pad, -pad end
    return math.min(el, ml) - ml - pad, math.max(et, mt) - mt + pad,
        math.max(er, mr) - mr + pad, math.min(eb, mb) - mb - pad
end

local attached = {} -- what each window is anchored to now, so it's re-anchored only on changes

local function attachBars()
    local main, extra = findBars()
    local l, t, r, b = boxOffsets(main, extra, BAR_PAD)
    local key = table.concat({ tostring(main), tostring(extra), l, t, r, b }, ",")
    if key == attached.bars then return end
    attached.bars = key

    local w = barGlow.window
    w:ClearAllPoints()
    local ok = main and pcall(function()
        w:SetPoint("TOPLEFT", main, "TOPLEFT", l, t)
        w:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", r, b)
    end)
    if not ok then
        w:ClearAllPoints()
        w:SetSize(FALLBACK_WIDTH, FALLBACK_HEIGHT)
        w:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    end
end

local function attachPortrait()
    local portrait, round = findPortrait()
    if db.shape ~= "auto" then round = db.shape == "round" end
    local size = portrait and plain(portrait.GetHeight, portrait)
    if type(size) ~= "number" or size <= 0 then size = NO_PORTRAIT_SIZE end
    -- Room for the halo, whose outlined edge is HALO_EDGE_RATIO of the way out (the square glow reaches as far).
    local pad = math.floor(size / 2 * (1 / HALO_EDGE_RATIO - 1) + 0.5)
    local key = table.concat({ tostring(portrait), tostring(round), pad }, ",")
    if key == attached.portrait then return end
    attached.portrait = key

    local w = portraitGlow.window
    w:ClearAllPoints()
    local ok = portrait and pcall(function()
        w:SetPoint("TOPLEFT", portrait, "TOPLEFT", -pad, pad)
        w:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", pad, -pad)
    end)
    if not ok then -- no portrait: the icon goes just left of the bars
        w:ClearAllPoints()
        w:SetSize(size + 2 * pad, size + 2 * pad)
        w:SetPoint("RIGHT", barGlow.window, "LEFT", 2 * BAR_PAD, 0)
    end
    portraitLook.layout(round, pad)
end

local function attach()
    attachBars()
    attachPortrait()
end

local function reattach()
    wipe(attached)
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

local testUntil

local function targetIsValid()
    return UnitExists("target")
        and plain(UnitIsDead, "target") ~= true
        and plain(UnitCanAttack, "player", "target") ~= false
end

local function update()
    attach()
    portraitLook.setIcon(spell.id)

    local testing = testUntil ~= nil and GetTime() < testUntil
    if not testing then testUntil = nil end
    local damage = estimate()
    if damage and (damage <= 0 or not targetIsValid()) then damage = nil end

    barGlow.show(db.border, damage, testing)
    portraitGlow.show(db.portrait, damage, testing)
end

local function loadSettings()
    ShadowWordDeathIndicatorDB = ShadowWordDeathIndicatorDB or {}
    db = ShadowWordDeathIndicatorDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
end

local driver = CreateFrame("Frame")
local sinceUpdate, sinceRefresh = 0, REFRESH_INTERVAL
driver:SetScript("OnUpdate", function(_, elapsed)
    if not db then return end
    sinceRefresh = sinceRefresh + elapsed
    if sinceRefresh >= REFRESH_INTERVAL then
        sinceRefresh = 0
        refreshSpell()
    end
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate >= UPDATE_INTERVAL then
        sinceUpdate = 0
        update()
    end
end)

for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "SPELLS_CHANGED", "PLAYER_REGEN_ENABLED",
    "PLAYER_EQUIPMENT_CHANGED", "PLAYER_TARGET_CHANGED" }) do
    driver:RegisterEvent(event)
end
driver:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            loadSettings()
            applyLook()
        end
    elseif not db then
        return
    elseif event == "PLAYER_TARGET_CHANGED" then
        reattach() -- some unit frame addons build or swap their frames late
        update()
    else
        refreshSpell()
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

-- Name of the first named frame under the mouse (or its closest named ancestor).
local function frameUnderMouse()
    local f
    if GetMouseFoci then
        local foci = GetMouseFoci()
        f = foci and foci[1]
    elseif GetMouseFocus then
        f = GetMouseFocus()
    end
    for _ = 1, 15 do
        if not f or f == UIParent or f == WorldFrame then return nil end
        local name = plain(f.GetName, f)
        if type(name) == "string" and _G[name] == f then return name end
        f = plain(f.GetParent, f)
    end
end

local function pathText(path)
    return path ~= "" and path or "auto"
end

local function help()
    say("when Shadow Word: Death will kill your target, its bars glow and its portrait turns into SW:D.")
    for _, line in ipairs({
        "/swd test - show the effects for 5 sec",
        "/swd debug - show the rank, tooltip and damage being used",
        "/swd border - toggle the bar glow (now: " .. onOff(db.border) .. ")",
        "/swd portrait - toggle the SW:D icon on the portrait (now: " .. onOff(db.portrait) .. ")",
        "/swd shape auto|round|square - portrait icon shape (now: " .. db.shape .. ")",
        "/swd intensity <0-1> - how strong the glow is (now: " .. db.intensity .. ")",
        "/swd color <r> <g> <b> - color, 0-1 each",
        "/swd pulse | label - toggle the pulse / the 'SW:D KILL' text",
        "/swd mode min|avg|max - which end of the damage range to trust (now: " .. db.mode .. ")",
        "/swd mult <n> - multiply the estimate, e.g. 1.15 (now: " .. db.mult .. ")",
        "/swd flat <n> - add a flat amount, negative to be safer (now: " .. db.flat .. ")",
        "/swd sp <coef> - add spell power x coef if the tooltip leaves it out, 0 = off (now: " .. db.spCoef .. ")",
        "/swd frame <name>|mouse|auto - what to glow around (now: " .. pathText(db.framePath) .. ")",
        "/swd portraitframe <name>|mouse|auto - portrait to cover (now: " .. pathText(db.portraitPath) .. ")",
    }) do
        print("  " .. line)
    end
end

local function debugInfo()
    refreshSpell()
    reattach()
    attach()
    say(string.format("rank ID %s (%s), damage %s-%s, spell power %s, estimate %s (mode %s, x%s, +%s, sp coef %s)",
        tostring(spell.id), tostring(spell.name), tostring(spell.lo), tostring(spell.hi), tostring(spellPower),
        tostring(estimate()), db.mode, db.mult, db.flat, db.spCoef))
    print("  tooltip: " .. tostring(spell.desc))
    local main, extra = findBars()
    print(string.format("  glow around: %s%s, portrait: %s, round: %s, in combat: %s",
        main and tostring(plain(main.GetDebugName, main) or plain(main.GetName, main)) or "none",
        extra and " + power bar" or "",
        findPortrait() and "found" or "none (icon beside the bars)",
        tostring(portraitLook.round), tostring(InCombatLockdown())))
end

-- /swd frame and /swd portraitframe: `value` is a frame path (case-sensitive), "mouse" or "auto".
local function setPath(key, value, what)
    local lower = value:lower()
    if lower == "" or lower == "auto" then
        db[key] = ""
    elseif lower == "mouse" then
        local name = frameUnderMouse()
        if not name then return say("no named frame under the mouse. Hover it and type the command again.") end
        db[key] = name
    else
        db[key] = value
    end
    reattach()
    attach()
    local found = db[key] == "" or resolvePath(db[key]) ~= nil
    say(what .. ": " .. pathText(db[key]) .. (found and "" or " (not found)"))
end

local TOGGLES = { pulse = true, label = true, border = true, portrait = true }
local NUMBERS = { mult = "mult", flat = "flat", sp = "spCoef" } -- command -> setting
local CHOICES = { -- setting -> allowed values
    mode = { min = true, avg = true, max = true },
    shape = { auto = true, round = true, square = true },
}
local PATHS = { frame = { "framePath", "frame" }, portraitframe = { "portraitPath", "portrait" } }

SLASH_SHADOWWORDDEATHINDICATOR1 = "/swd"
SlashCmdList.SHADOWWORDDEATHINDICATOR = function(msg)
    if not db then return end
    local cmd, value = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local arg = value:lower()
    local number = tonumber(arg)

    if cmd == "test" then
        reattach()
        testUntil = GetTime() + 5
        say("test for 5 seconds.")
    elseif cmd == "debug" then
        debugInfo()
    elseif TOGGLES[cmd] then
        db[cmd] = not db[cmd]
        applyLook()
        say(cmd .. " " .. onOff(db[cmd]))
    elseif NUMBERS[cmd] and number then
        db[NUMBERS[cmd]] = number
        say(cmd .. " = " .. number)
    elseif CHOICES[cmd] and CHOICES[cmd][arg] then
        db[cmd] = arg
        reattach()
        say(cmd .. " " .. arg)
    elseif cmd == "intensity" and number then
        db.intensity = math.max(0.05, math.min(1, number))
        applyLook()
        say("intensity " .. db.intensity)
    elseif cmd == "color" then
        local r, g, b = arg:match("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
        if not r then return say("usage: /swd color 0.75 0.35 1") end
        db.color = { tonumber(r), tonumber(g), tonumber(b) }
        applyLook()
        say("color set.")
    elseif PATHS[cmd] then
        setPath(PATHS[cmd][1], value, PATHS[cmd][2])
    else
        help()
    end
end
