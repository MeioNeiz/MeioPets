-- MeioPets: for hunters and warlocks. Pet health under a threshold in a fight: a sound and
-- a pulse on the pet frame, once per dip (re-armed REARM points above). Pet died: a sound
-- and one line mid-screen. Pet lost and not back after the fight or a resurrect: a reminder,
-- unless FlareUI's Buff Reminders already shows its pet reminder.
--
-- Pet health is a secret value in combat on this client (UnitHealth SecretReturns, the
-- Combat addon restriction). Lua can't compare a secret, so no sound then: the pulse's
-- alpha comes from UnitHealthPercent through a step curve, which the client evaluates, and
-- it shows for as long as the pet stays under the threshold. Whenever health is readable
-- (out of combat, or if this client ever leaves pet health open) the full alert runs.

local ADDON, ns = ...
local canaccess = canaccessvalue or function() return true end
local issecret = issecretvalue or function() return false end

local REARM = 15
local HOLD = 2 -- seconds a readable low health pulse plays
local TEXT_HOLD = 2.5
local NO_PET_DELAY = 3 -- after a fight or resurrect, leave time to summon by hand
local GLOW_COLOR = { 1, 0.15, 0.1 }

ns.SOUNDS = {
    { key = "raid", name = "Raid warning", kit = 8959 },
    { key = "alarm", name = "Alarm clock", kit = 12889 },
    { key = "ready", name = "Ready check", kit = 8960 },
    { key = "whisper", name = "Whisper", kit = 3081 },
}
local SOUND = {}
for _, s in ipairs(ns.SOUNDS) do SOUND[s.key] = s end

local DEFAULTS = { at = 35, flash = true, sound = true, soundName = "raid", died = true,
    nopet = true }

local HUNTER_SPELLS = { 883, 982 } -- Call Pet, Revive Pet
local WARLOCK_SUMMONS = { 688, 697, 712, 691 } -- Imp, Voidwalker, Succubus, Felhunter
local SACRIFICE_BUFFS = { 18789, 18790, 18791, 18792 }
-- casts that take the pet away on purpose: Dismiss Pet, Demonic Sacrifice, a new summon,
-- Inferno, Ritual of Doom, Enslave Demon
local LET_GO = { [2641] = true, [18788] = true, [883] = true, [1122] = true, [18540] = true,
    [1098] = true, [11725] = true, [11726] = true }
for _, id in ipairs(WARLOCK_SUMMONS) do LET_GO[id] = true end
local ENSLAVE = { [1098] = true, [11725] = true, [11726] = true }

local db, class
local armed = true
local petAlive, petName = false, nil
local lostPet = false
local letGoAt = 0
local enslaveAt, enslaved = 0, false -- the pet out is a demon held by Enslave Demon
local stableOpen = false -- a hunter swapping or stabling pets
local fight -- this fight's { readable, secret }, once a pet was seen in it
ns.fight = nil -- this or the last fight with a pet

local function Say(msg) print("|cffb090ffMeioPets:|r " .. msg) end
ns.Say = Say

local function Readable(v) return v ~= nil and not issecret(v) and canaccess(v) end

local function Number(v)
    if Readable(v) and type(v) == "number" then return v end
end

local function Known(id)
    return C_SpellBook.IsSpellKnown(id) and true or false
end

local function KnowsAny(list)
    for _, id in ipairs(list) do if Known(id) then return true end end
    return false
end

function ns.Active() return class == "HUNTER" or class == "WARLOCK" end

local function InCombat() return InCombatLockdown() or UnitAffectingCombat("player") end

local function PlayAlert()
    if not db.sound then return end
    local s = SOUND[db.soundName] or SOUND[DEFAULTS.soundName]
    PlaySound(s.kit, "Master")
end
ns.PlayAlert = PlayAlert

---------------------------------------------------------------------------
-- The pulse: pulse (animated alpha) > gate (secret alpha in secret mode) > glow
---------------------------------------------------------------------------
local pulse, gate, glow, fallback, pulseAnim, stopTimer
local curve, curveAt

local function Build()
    pulse = CreateFrame("Frame", nil, UIParent)
    pulse:SetAllPoints(UIParent)
    pulse:SetFrameStrata("HIGH")
    pulse:EnableMouse(false)
    pulse:Hide()
    gate = CreateFrame("Frame", nil, pulse)
    gate:SetAllPoints(pulse)

    glow = CreateFrame("Frame", nil, gate)
    local r, g, b = GLOW_COLOR[1], GLOW_COLOR[2], GLOW_COLOR[3]
    local fill = glow:CreateTexture(nil, "ARTWORK")
    fill:SetAllPoints()
    fill:SetColorTexture(r, g, b, 0.3)
    fill:SetBlendMode("ADD")
    local edges = {
        { from = "TOPLEFT", to = "TOPRIGHT", across = true },
        { from = "BOTTOMLEFT", to = "BOTTOMRIGHT", across = true },
        { from = "TOPLEFT", to = "BOTTOMLEFT" }, { from = "TOPRIGHT", to = "BOTTOMRIGHT" },
    }
    for _, e in ipairs(edges) do
        local t = glow:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(r, g, b, 0.95)
        t:SetPoint(e.from)
        t:SetPoint(e.to)
        if e.across then t:SetHeight(3) else t:SetWidth(3) end
    end

    -- no pet frame on screen: a line where the pet frame would draw the eye
    fallback = gate:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    fallback:SetPoint("CENTER", UIParent, "CENTER", 0, -140)
    fallback:SetTextColor(r, g, b)
    fallback:SetText("Pet health low")

    pulseAnim = pulse:CreateAnimationGroup()
    pulseAnim:SetLooping("BOUNCE")
    local a = pulseAnim:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0.25)
    a:SetDuration(0.35)
    a:SetSmoothing("IN_OUT")
end

local function PetFrame()
    for _, name in ipairs({ "FlareUI_UF_Pet", "PetFrame" }) do
        local f = _G[name]
        if f and f.IsVisible and f:IsVisible() then return f end
    end
end

local function Place()
    if not pulse then Build() end
    local f = PetFrame()
    glow:ClearAllPoints()
    if f then
        glow:SetPoint("TOPLEFT", f, "TOPLEFT", -4, 4)
        glow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 4, -4)
        glow:Show()
        fallback:Hide()
    else
        glow:Hide()
        fallback:Show()
    end
end

local function StopPulse()
    if stopTimer then stopTimer:Cancel() stopTimer = nil end
    if pulse then
        pulseAnim:Stop()
        pulse:Hide()
        pulse.secret = nil
    end
end

local function StartPulse(seconds)
    Place()
    pulse:Show()
    if not pulseAnim:IsPlaying() then pulseAnim:Play() end
    if stopTimer then stopTimer:Cancel() stopTimer = nil end
    if seconds then stopTimer = C_Timer.NewTimer(seconds, StopPulse) end
end

local function Curve()
    if curveAt ~= db.at or not curve then
        curve = C_CurveUtil.CreateCurve()
        curve:SetType(Enum.LuaCurveType.Step)
        curve:AddPoint(0, 1)
        curve:AddPoint(db.at / 100, 0)
        curveAt = db.at
    end
    return curve
end

-- health secret: the client turns it into the gate's alpha, 1 under the threshold, else 0
local function SecretPulse()
    if not (db.flash and C_CurveUtil and UnitHealthPercent) then return end
    if not pulse then Build() end
    local ok, alpha = pcall(UnitHealthPercent, "pet", true, Curve())
    if not ok or not pcall(gate.SetAlpha, gate, alpha --[[@as number]]) then
        StopPulse()
        return
    end
    if not pulse.secret then
        pulse.secret = true
        StartPulse()
    end
end

---------------------------------------------------------------------------
-- The text line (pet died, no pet)
---------------------------------------------------------------------------
local textFrame, textLine, textTimer

local function ShowText(msg, r, g, b)
    if not textFrame then
        textFrame = CreateFrame("Frame", nil, UIParent)
        textFrame:SetFrameStrata("HIGH")
        textFrame:SetSize(600, 40)
        -- under UIErrorsFrame's lines, so the two never write over each other
        textFrame:SetPoint("TOP", UIParent, "TOP", 0, -200)
        textLine = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        textLine:SetAllPoints()
        textFrame.fade = textFrame:CreateAnimationGroup()
        local a = textFrame.fade:CreateAnimation("Alpha")
        a:SetFromAlpha(1)
        a:SetToAlpha(0)
        a:SetDuration(0.8)
        textFrame.fade:SetScript("OnFinished", function() textFrame:Hide() end)
    end
    textLine:SetText(msg)
    textLine:SetTextColor(r, g, b)
    textFrame.fade:Stop()
    textFrame:SetAlpha(1)
    textFrame:Show()
    if textTimer then textTimer:Cancel() end
    textTimer = C_Timer.NewTimer(TEXT_HOLD, function() textFrame.fade:Play() end)
end
ns.ShowText = ShowText

---------------------------------------------------------------------------
-- Low health
---------------------------------------------------------------------------
local function Warn()
    PlayAlert()
    if db.flash then
        Place()
        gate:SetAlpha(1)
        pulse.secret = nil
        StartPulse(HOLD)
    end
end
ns.Warn = Warn

-- percent 0..100 when Lua can read it, else nil
local function PetPercent()
    local h, m = Number(UnitHealth("pet")), Number(UnitHealthMax("pet"))
    if h and m then return m > 0 and h / m * 100 or 100 end
    if UnitHealthPercent then
        local ok, p = pcall(UnitHealthPercent, "pet", true)
        p = ok and Number(p)
        if p then return p * 100 end
    end
end

local function CheckHealth()
    if not (ns.Active() and UnitExists("pet")) or UnitIsDead("pet") then
        if pulse and pulse.secret then StopPulse() end
        return
    end
    local combat = InCombat()
    if combat and not fight then
        fight = {}
        ns.fight = fight
    end
    local pct = PetPercent()
    if pct then
        if pulse and pulse.secret then StopPulse() end
        if combat then fight.readable = true end
        if pct >= math.min(db.at + REARM, 100) then
            armed = true
        elseif armed and combat and pct < db.at then
            armed = false
            Warn()
        end
    elseif combat then
        fight.secret = true
        SecretPulse()
    end
end

---------------------------------------------------------------------------
-- Died, lost, reminder
---------------------------------------------------------------------------
local function Died()
    if not db.died then return end
    PlayAlert()
    ShowText((petName or "Your pet") .. " died", 1, 0.25, 0.25)
end
ns.Died = Died

local function Lost(dead)
    petAlive = false
    lostPet = true
    StopPulse()
    if dead then Died() end
end

local function CheckPet()
    if not ns.Active() then return end
    local exists, dead = UnitExists("pet"), UnitIsDead("pet")
    if exists and not dead then
        if not petAlive then
            armed = true
            enslaved = GetTime() - enslaveAt < 3
        end
        petAlive, lostPet = true, false
        local name = UnitName("pet")
        if Readable(name) then petName = name end
        return
    end
    if not petAlive then return end
    if exists and dead then
        Lost(true)
        return
    end
    -- vanished (a warlock's demon leaves no corpse): a death only in a fight, with no cast
    -- that sent it away and the player still up; decided a moment later, as the cast's
    -- event can come after UNIT_PET. An enslaved demon vanishing broke free: not a death.
    petAlive = false
    local combat, wasEnslaved = InCombat(), enslaved
    enslaved = false
    C_Timer.After(0.3, function()
        if UnitExists("pet") then return end
        local onPurpose = stableOpen or GetTime() - letGoAt < 1.5
        if onPurpose then
            StopPulse()
            return
        end
        if wasEnslaved then
            Lost(false)
            if db.died then ShowText((petName or "Your demon") .. " broke free", 1, 0.5, 0.1) end
            return
        end
        Lost(combat and not UnitIsDeadOrGhost("player"))
    end)
end

local function Sacrificed()
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return false end
    for _, id in ipairs(SACRIFICE_BUFFS) do
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
        if ok and aura ~= nil then return true end
    end
    return false
end

-- FlareUI's Buff Reminders would show its pet reminder here and now: the module loaded and
-- still on, the pet reminder not hidden, and its Where (petScope) taking in where you are
local function FlareInScope(mode)
    if not mode or mode == "always" or mode == "mouseover" then return true end
    local inInstance, kind = IsInInstance()
    if mode == "raid" then return inInstance and kind == "raid" or false end
    return inInstance and (kind == "party" or kind == "raid") or false
end

function ns.FlareCovers()
    if not _G.FlareUI_BuffReminders then return false end
    local flare = _G.FlareUI
    local auras = type(flare) == "table" and flare.db and flare.db.profile and flare.db.profile.auras
    if not auras or not auras.reminders then return false end
    local r = auras.reminder or {}
    if r.pets == false or (r.hidden and r.hidden[class .. ":pet"]) then return false end
    return FlareInScope(r.petScope)
end

local function NoPetLine()
    if class == "HUNTER" then
        if UnitExists("pet") and UnitIsDead("pet") then return "Pet is dead - Revive Pet" end
        return "No pet out - Call Pet"
    end
    return "No pet out - summon your demon"
end

local function CheckNoPet()
    if not (ns.Active() and db.nopet and lostPet) or ns.FlareCovers() then return end
    if InCombat() or UnitIsDeadOrGhost("player") or IsMounted() or UnitOnTaxi("player") then
        return
    end
    if UnitExists("pet") and not UnitIsDead("pet") then return end
    if not KnowsAny(class == "HUNTER" and HUNTER_SPELLS or WARLOCK_SUMMONS) then return end
    if class == "WARLOCK" and Sacrificed() then return end
    lostPet = false
    PlayAlert()
    ShowText(NoPetLine(), 1, 0.82, 0)
end
ns.NoPetLine = NoPetLine

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

local function Start()
    class = select(2, UnitClass("player"))
    if not ns.Active() then return end
    for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
        "PLAYER_REGEN_ENABLED", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
        events:RegisterEvent(e)
    end
    events:RegisterUnitEvent("UNIT_PET", "player")
    events:RegisterUnitEvent("UNIT_HEALTH", "pet")
    events:RegisterUnitEvent("UNIT_MAXHEALTH", "pet")
    events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    if class == "HUNTER" then
        events:RegisterEvent("PET_STABLE_SHOW")
        events:RegisterEvent("PET_STABLE_CLOSED")
    end
    if PetDismiss then hooksecurefunc("PetDismiss", function() letGoAt = GetTime() end) end
end

events:SetScript("OnEvent", function(_, event, arg1, _, spellID)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        MeioPetsDB = MeioPetsDB or {}
        db = MeioPetsDB
        for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
        if not SOUND[db.soundName] then db.soundName = DEFAULTS.soundName end
        ns.db = db
    elseif event == "PLAYER_LOGIN" then
        Start()
    elseif event == "PLAYER_ENTERING_WORLD" then
        petAlive = UnitExists("pet") and not UnitIsDead("pet")
        armed = true
        StopPulse()
    elseif event == "PLAYER_REGEN_DISABLED" then
        fight = nil
        CheckHealth()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pulse and pulse.secret then StopPulse() end
        CheckHealth()
        C_Timer.After(NO_PET_DELAY, CheckNoPet)
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        C_Timer.After(NO_PET_DELAY, CheckNoPet)
    elseif event == "UNIT_PET" then
        CheckPet()
        CheckHealth()
    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        CheckPet()
        CheckHealth()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if LET_GO[spellID] then letGoAt = GetTime() end
        if ENSLAVE[spellID] then
            enslaveAt = GetTime()
            if UnitExists("pet") then enslaved = true end
        end
    elseif event == "PET_STABLE_SHOW" then
        stableOpen = true
    elseif event == "PET_STABLE_CLOSED" then
        stableOpen = false
        letGoAt = GetTime()
    end
end)

---------------------------------------------------------------------------
-- Slash
---------------------------------------------------------------------------
local CMD = "|cffffd100/meiopets%s|r"
local function Cmd(sub) return CMD:format(sub and " " .. sub or "") end
local function OnOff(v) return v and "|cff80ff80on|r" or "|cffff8080off|r" end
ns.OnOff = OnOff

ns.TOGGLES = {
    { key = "flash", what = "pulse on the pet frame when its health is low" },
    { key = "sound", what = "sound with each warning" },
    { key = "died", what = "pet died warning" },
    { key = "nopet", what = "no pet reminder after a fight or resurrect" },
}
local TOGGLE = {}
for _, t in ipairs(ns.TOGGLES) do TOGGLE[t.key] = t end

local function SoundKeys()
    local keys = {}
    for _, s in ipairs(ns.SOUNDS) do keys[#keys + 1] = s.key end
    return table.concat(keys, "||")
end

function ns.Help()
    Say("warns when your pet's health runs low, when it dies, and when it isn't back")
    print(("  %s - open the settings"):format(Cmd()))
    print(("  %s - show the warnings now"):format(Cmd("test")))
    print(("  %s - warn under this much pet health, 10 to 80 (now %d%%)"):format(
        Cmd("at <percent>"), db.at))
    for _, t in ipairs(ns.TOGGLES) do
        print(("  %s - %s (now %s)"):format(Cmd(t.key .. " on||off"), t.what, OnOff(db[t.key])))
    end
    print(("  %s - which sound (now %s)"):format(Cmd("sound " .. SoundKeys()),
        SOUND[db.soundName].name:lower()))
    print(("  %s - what MeioPets could read in your last fight"):format(Cmd("status")))
    print(("  Settings: Esc > Options > AddOns > MeioPets (%s)"):format(Cmd("settings")))
end

local function Status()
    if not ns.Active() then
        Say("nothing to watch: only hunters and warlocks have a pet to warn about")
        return
    end
    Say(("warns under %d%% pet health, pulse %s, sound %s (%s), died %s, no pet %s"):format(
        db.at, OnOff(db.flash), OnOff(db.sound), SOUND[db.soundName].name:lower(),
        OnOff(db.died), OnOff(db.nopet)))
    local f = ns.fight
    if not f then
        print("  Last fight: none with a pet out yet this session.")
    elseif f.readable and not f.secret then
        print("  Last fight: pet health was readable - sound and pulse.")
    elseif f.secret and not f.readable then
        print("  Last fight: pet health was secret - pulse while low, no sound.")
    else
        print("  Last fight: pet health was readable at times - sound when it could be read.")
    end
    if ns.FlareCovers() then
        print("  No pet reminder: FlareUI's Buff Reminders shows it here, so MeioPets stays quiet.")
    end
end

local function Test()
    Warn()
    C_Timer.After(HOLD + 0.5, function()
        ShowText((petName or "Your pet") .. " died", 1, 0.25, 0.25)
    end)
end

function ns.OpenSettingsOrHelp()
    if not (ns.OpenSettings and ns.OpenSettings()) then ns.Help() end
end

function MeioPets_OnAddonCompartmentClick() ns.OpenSettingsOrHelp() end

SLASH_MEIOPETS1 = "/meiopets"
SLASH_MEIOPETS2 = "/petalert"
SlashCmdList.MEIOPETS = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    local word, rest = msg:match("^(%S*)%s*(.-)$")
    if msg == "" or msg == "settings" or msg == "options" then
        ns.OpenSettingsOrHelp()
    elseif msg == "help" or msg == "?" then
        ns.Help()
    elseif msg == "status" then
        Status()
    elseif msg == "test" then
        Test()
    elseif word == "at" then
        local n = tonumber((rest:gsub("%%", "")))
        if not n or n < 10 or n > 80 then
            Say(("give a percent from 10 to 80, as in %s (now %d%%)"):format(Cmd("at 35"), db.at))
            return
        end
        db.at = math.floor(n / 5 + 0.5) * 5
        armed = true
        Say(("warns under %d%% pet health"):format(db.at))
    elseif word == "sound" and SOUND[rest] then
        db.soundName = rest
        PlayAlert()
        Say("sound: " .. SOUND[rest].name:lower())
    elseif TOGGLE[word] and (rest == "" or rest == "on" or rest == "off") then
        if rest == "" then db[word] = not db[word] else db[word] = rest == "on" end
        if word == "flash" and not db.flash then StopPulse() end
        Say(TOGGLE[word].what .. " " .. OnOff(db[word]))
    else
        Say(('unknown command "%s"'):format(msg))
        ns.Help()
    end
end
