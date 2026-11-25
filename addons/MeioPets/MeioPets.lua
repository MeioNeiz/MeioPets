-- MeioPets: for hunters and warlocks. Pet health under a threshold in a fight: a sound and
-- a pulse on the pet frame, once per dip (re-armed REARM points above). Pet died: a sound
-- and one line mid-screen. Pet lost and not back after the fight or a resurrect: a reminder,
-- unless FlareUI's Buff Reminders already shows its pet reminder. A hunter's pet that drops
-- below happy: a feed reminder after the fight, once per drop. A pet on Aggressive in a
-- dungeon or Passive while solo: one line, until the mode or the place changes. Growl (or a
-- Voidwalker's Torment) on autocast in a group with a tank, or off while solo: the same.
-- A demon held by Subjugate (Enslave) Demon: a line 15 s and 3 s before it breaks free. A
-- hunter levels with the pet out and it lags 2 or more behind: one line saying so.
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
    nopet = true, feed = true, feedbutton = false, food = false, mode = true,
    growl = false, invis = true, enslave = true, petlevel = true }
ns.DEFAULTS = DEFAULTS

local HUNTER_SPELLS = { 883, 982 } -- Call Pet, Revive Pet
local WARLOCK_SUMMONS = { 688, 697, 712, 691 } -- Imp, Voidwalker, Succubus, Felhunter
local SACRIFICE_BUFFS = { 18789, 18790, 18791, 18792 }
-- casts that take the pet away on purpose: Dismiss Pet, Demonic Sacrifice, a new summon,
-- Inferno, Ritual of Doom, Enslave Demon
local LET_GO = { [2641] = true, [18788] = true, [883] = true, [1122] = true, [18540] = true,
    [1098] = true, [11725] = true, [11726] = true }
for _, id in ipairs(WARLOCK_SUMMONS) do LET_GO[id] = true end
-- Forever names it Subjugate Demon (client spell data); 300 s at most, it can break sooner
local ENSLAVE = { [1098] = true, [11725] = true, [11726] = true }
local ENSLAVE_TIME = 300
local ENSLAVE_SAY = { 15, 3 }
local LEVEL_BEHIND = 2
local FEED_EFFECT = 1539 -- the pet's buff while it eats
local FEED_PET = 6991
local FOOD_LOW = 10 -- pieces left that the pet eats, about a day of feeding
local FEED_SHOW = 12 -- seconds the feed button stays up with the reminder
local HAPPY = 3 -- GetPetHappiness: 1 unhappy, 2 content, 3 happy
-- every rank of Growl and of the Voidwalker's Torment
local TAUNTS = { [2649] = true, [14916] = true, [14917] = true, [14918] = true, [14919] = true,
    [14920] = true, [14921] = true, [3716] = true, [7809] = true, [7810] = true, [7811] = true,
    [11774] = true, [11775] = true }
-- the Voidwalker's Suffering (taunts all around it), and the Succubus's Lesser Invisibility:
-- on Forever a mob it hits first from invisibility evades, so your opener is lost
local SUFFERING = { [17735] = true, [17750] = true, [17751] = true, [17752] = true }
local INVIS = { [7870] = true }
-- Forever's own pet UI (gamepad flyout) names Assist and Defensive with the retail tokens;
-- the classic ones may still come from the server. Assist only attacks your target: no warning.
local MODE_TOKENS = { PET_MODE_AGGRESSIVE = "aggressive", PET_ACTION_MODE_AGGRESSIVE = "aggressive",
    PET_MODE_PASSIVE = "passive", PET_ACTION_MODE_PASSIVE = "passive",
    PET_MODE_DEFENSIVE = "defensive", PET_MODE_DEFENSIVEASSIST = "defensive",
    PET_MODE_ASSIST = "assist" }

local db, class
local armed = true
local petAlive, petName = false, nil
local lostPet = false
local letGoAt = 0
local enslaveAt, enslaved = 0, false -- the pet out is a demon held by Enslave Demon
local enslaveEnd, enslaveSaid, enslaveTicker -- GetTime() it breaks free; lines said
local levelWarned = {} -- pet name -> player level last warned at
local stableOpen = false -- a hunter swapping or stabling pets
local fed = {} -- { name, level }: the lowest happiness warned about for this pet
local foodWarned -- the pet the low food line last went to, until stocked up again
local modeWarned -- the wrong mode last warned about, until it is put right
local modeTimer
local castWarned = {} -- kind ("taunt", "aoe", "invis") -> "on" or "off" as last warned about
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
            if enslaved then ns.StartEnslave() end
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
-- Feed reminder (hunters)
---------------------------------------------------------------------------
-- level 1 unhappy .. 3 happy, and the damage it does then in percent (125 happy)
local function Happiness()
    local get = C_PetInfo and C_PetInfo.GetPetHappiness or GetPetHappiness
    if not get then return end
    local ok, h, dmg = pcall(get)
    if not ok then return end
    return Number(h), Number(dmg)
end

local function Eating()
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(FEED_EFFECT)
    if not (name and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return false end
    local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "pet", name, "HELPFUL")
    return ok and aura ~= nil
end

local function FeedLine(level, name, dmg)
    if level == 1 then
        return ("%s is unhappy - Feed Pet (%d%% damage, may run off)"):format(name, dmg or 75),
            1, 0.45, 0.1
    end
    local more = dmg and dmg > 0 and math.floor(125 / dmg * 100 - 100 + 0.5) or 25
    return ("%s is content - Feed Pet for %d%% more damage"):format(name, more), 1, 0.82, 0
end
ns.FeedLine = FeedLine

-- the food in your bags this pet eats: the piece to feed and the total count (nil: unknown).
-- Food at least as high as the pet's level less 10 makes it happiest; the lowest of those is
-- the cheapest.
local function PetFood()
    local canEat = C_PetInfo and C_PetInfo.CanPetEatItem
    if not (canEat and C_Container and UnitExists("pet")) then return end
    local floor = (Number(UnitLevel("pet")) or 1) - 10
    local best, bestLevel, total = nil, nil, 0
    local seen = {}
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and info.itemID
            if id then
                if seen[id] == nil then
                    local ok, yes = pcall(canEat, id)
                    seen[id] = ok and yes and true or false
                end
                if seen[id] then
                    total = total + (info.stackCount or 1)
                    local level = select(4, C_Item.GetItemInfo(id)) or 0
                    local better = not best
                        or level >= floor and (bestLevel < floor or level < bestLevel)
                        or level < floor and bestLevel < floor and level > bestLevel
                    if better then best, bestLevel = id, level end
                end
            end
        end
    end
    return best, total
end
ns.PetFood = PetFood

-- a click (or the key in Key Bindings > AddOns) casts Feed Pet on the chosen food. A secure
-- button: set and shown only out of combat.
local feedButton, feedHide
local function FeedButton()
    if feedButton then return feedButton end
    local b = CreateFrame("Button", "MeioPetsFeedButton", UIParent, "SecureActionButtonTemplate")
    b:SetSize(36, 36)
    b:SetFrameStrata("HIGH")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "macro")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.label:SetPoint("LEFT", b, "RIGHT", 8, 0)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b:SetScript("OnEnter", function(self)
        if not self.food then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.food)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    feedButton = b
    return b
end

local function HideFeedButton()
    if feedHide then feedHide:Cancel() feedHide = nil end
    if feedButton and feedButton:IsShown() and not InCombatLockdown() then feedButton:Hide() end
end
ns.HideFeedButton = HideFeedButton

-- point the button (and its key) at the food to feed now; true when there is some
local function ArmFeed()
    if class ~= "HUNTER" or InCombatLockdown() then return end
    if not db.feedbutton then
        if feedButton then
            feedButton:Hide()
            feedButton:SetAttribute("macrotext", nil)
        end
        return
    end
    local b = FeedButton()
    local id, total = PetFood()
    b.food = id
    if not id then
        b:SetAttribute("macrotext", nil)
        return false, total
    end
    local spell = C_Spell.GetSpellName(FEED_PET) or "Feed Pet"
    b:SetAttribute("macrotext", ("/cast %s\n/use item:%d"):format(spell, id))
    b.icon:SetTexture(C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
        or select(10, C_Item.GetItemInfo(id)))
    b.count:SetText(total)
    b.label:SetText("Click to feed " .. (C_Item.GetItemInfo(id) or "food"))
    b:ClearAllPoints()
    b:SetPoint("TOP", UIParent, "TOP", -(b.label:GetStringWidth() + 8) / 2, -244)
    return true, total
end

local function ShowFeedButton()
    if not ArmFeed() then return end
    feedButton:Show()
    if feedHide then feedHide:Cancel() end
    feedHide = C_Timer.NewTimer(FEED_SHOW, HideFeedButton)
end

local function CheckFood()
    if class ~= "HUNTER" or not db.food then return end
    if not UnitExists("pet") or UnitIsDead("pet") or InCombat() then return end
    local _, total = PetFood()
    if not total then return end
    local name = UnitName("pet")
    name = Readable(name) and name or petName or "your pet"
    if total >= FOOD_LOW then
        foodWarned = nil
        return
    end
    if foodWarned == name then return end
    foodWarned = name
    if total == 0 then
        ShowText("No food " .. name .. " eats in your bags", 1, 0.82, 0)
    else
        ShowText(("Food for %s: %d left"):format(name, total), 1, 0.82, 0)
    end
end
ns.CheckFood = CheckFood

local function CheckFeed()
    if class ~= "HUNTER" or not db.feed then return end
    if not UnitExists("pet") or UnitIsDead("pet") then return end
    local level, dmg = Happiness()
    if not level then return end
    local name = UnitName("pet")
    if Readable(name) then petName = name else name = petName or "Your pet" end
    if fed.name ~= name then fed = { name = name } end
    if level >= HAPPY then
        fed.level = nil
        return
    end
    if fed.level and level >= fed.level then return end
    if InCombat() or UnitIsDeadOrGhost("player") or UnitOnTaxi("player") or Eating() then
        return
    end
    fed.level = level
    if level == 1 then PlayAlert() end
    local line, r, g, b = FeedLine(level, name, dmg)
    local total = select(2, PetFood())
    if total == 0 then line = line .. " (no food it eats in your bags)" end
    -- this line (or the button's count) already says the food is short
    if total and total < FOOD_LOW then foodWarned = name end
    ShowText(line, r, g, b)
    ShowFeedButton()
    return true
end

---------------------------------------------------------------------------
-- Wrong pet mode
---------------------------------------------------------------------------
-- the active mode, and its bar token for /meiopets status (an unknown token: mode nil)
local function PetMode()
    if not GetPetActionInfo then return end
    for i = 1, NUM_PET_ACTION_SLOTS or 10 do
        local ok, token, _, isToken, active = pcall(GetPetActionInfo, i)
        if ok and Readable(token) and Readable(active) and active and isToken
            and type(token) == "string" and token:find("^PET_") and token ~= "PET_ACTION_ATTACK"
            and token ~= "PET_ACTION_FOLLOW" and token ~= "PET_ACTION_WAIT"
            and token ~= "PET_ACTION_MOVE_TO" then
            return MODE_TOKENS[token], token
        end
    end
end
ns.PetMode = PetMode

local function InDungeon()
    local inInstance, kind = IsInInstance()
    return inInstance and (kind == "party" or kind == "raid") or false
end

-- Aggressive pulls packs in a dungeon; Passive alone leaves you fighting by yourself. Passive
-- in a group is often on purpose (attack on command only), so that stays quiet.
local function WrongMode()
    -- an enslaved demon stays Passive on Forever whatever mode is set
    if enslaved then return end
    local mode = PetMode()
    if mode == "aggressive" and InDungeon() then return mode end
    if mode == "passive" and not IsInGroup() and not ns.FlareCovers() then return mode end
end

local function ModeLine(mode, name)
    if mode == "aggressive" then
        return name .. " is on Aggressive - it pulls in dungeons. Set Defensive", 1, 0.45, 0.1
    end
    return name .. " is on Passive - it won't fight back. Set Defensive", 1, 0.82, 0
end
ns.ModeLine = ModeLine

local function CheckMode()
    modeTimer = nil
    if not (ns.Active() and db.mode) then return end
    if not UnitExists("pet") or UnitIsDead("pet") then return end
    local wrong = WrongMode()
    if not wrong then
        modeWarned = nil
        return
    end
    if wrong == modeWarned then return end
    if InCombat() or UnitIsDeadOrGhost("player") or IsMounted() or UnitOnTaxi("player") then
        return
    end
    modeWarned = wrong
    if wrong == "aggressive" then PlayAlert() end
    local name = UnitName("pet")
    ShowText(ModeLine(wrong, Readable(name) and name or petName or "Your pet"))
    return true
end

---------------------------------------------------------------------------
-- Growl autocast
---------------------------------------------------------------------------
local KINDS = { { key = "taunt", ids = TAUNTS, base = { 2649, 3716 } },
    { key = "aoe", ids = SUFFERING, base = { 17735 } },
    { key = "invis", ids = INVIS, base = { 7870 } } }

local kindNames -- spell name -> kind, in case this client's pet bar reports other spell IDs
local function KindOf(name, spellID)
    if Readable(spellID) then
        for _, k in ipairs(KINDS) do if k.ids[spellID] then return k.key end end
    end
    if not kindNames then
        kindNames = {}
        local get = C_Spell and C_Spell.GetSpellName or GetSpellInfo
        for _, k in ipairs(KINDS) do
            for _, id in ipairs(k.base) do
                local n = get and get(id)
                if n then kindNames[n] = k.key end
            end
        end
    end
    return Readable(name) and kindNames[name] or nil
end

-- the pet's autocast spells we watch, on its bar: kind -> { name, auto }
local function PetCasts()
    local found = {}
    if not GetPetActionInfo then return found end
    for i = 1, NUM_PET_ACTION_SLOTS or 10 do
        local ok, name, _, _, _, _, enabled, spellID = pcall(GetPetActionInfo, i)
        local kind = ok and KindOf(name, spellID)
        if kind and not found[kind] and Readable(enabled) then
            found[kind] = { name = Readable(name) and name or kind, auto = enabled and true or false }
        end
    end
    return found
end
ns.PetCasts = PetCasts

local function Taunt()
    local t = PetCasts().taunt
    if t then return t.name, t.auto end
end
ns.Taunt = Taunt

-- by group role or main tank; invite groups have no roles, so in a dungeon any group counts
local function IsTank(unit)
    local ok, role = pcall(UnitGroupRolesAssigned, unit)
    if canaccessvalue and not canaccessvalue(role) then role = nil end
    if ok and role == "TANK" then return true end
    if GetPartyAssignment then
        local okA, main = pcall(GetPartyAssignment, "MAINTANK", unit)
        if okA and Readable(main) and main then return true end
    end
    return false
end

local function GroupHasTank()
    if not IsInGroup() then return false end
    if InDungeon() then return true end
    local raid = IsInRaid()
    for i = 1, raid and GetNumGroupMembers() or 4 do
        local unit = (raid and "raid" or "party") .. i
        local me = UnitIsUnit(unit, "player")
        if canaccessvalue and not canaccessvalue(me) then me = false end
        if UnitExists(unit) and not me and IsTank(unit) then
            return true
        end
    end
    return false
end

-- each watched spell in the wrong state: kind -> "on" or "off". Taunts on with a tank pull
-- aggro off them; Growl or Torment off alone and the pet won't hold aggro.
local function WrongCasts(casts)
    local wrong, tank = {}, nil
    local function Tank()
        if tank == nil then tank = GroupHasTank() end
        return tank
    end
    local t, a, v = casts.taunt, casts.aoe, casts.invis
    if db.growl and t and t.auto and Tank() then wrong.taunt = "on" end
    if db.growl and t and not t.auto and not IsInGroup() then wrong.taunt = "off" end
    if db.growl and a and a.auto and Tank() then wrong.aoe = "on" end
    if db.invis and v and v.auto then wrong.invis = "on" end
    return wrong
end

local function CastLine(kind, state, spell, pet)
    if kind == "invis" then
        return spell .. " is on autocast - mobs evade its first hit", 1, 0.82, 0
    end
    if state == "on" then
        return spell .. " is on autocast - it pulls aggro off your tank", 1, 0.45, 0.1
    end
    return spell .. " is off autocast - " .. pet .. " won't hold aggro", 1, 0.82, 0
end
ns.CastLine = CastLine
function ns.TauntLine(state, spell, pet) return CastLine("taunt", state, spell, pet) end

local function CheckTaunt()
    if not ns.Active() or not (db.growl or db.invis) then return end
    if not UnitExists("pet") or UnitIsDead("pet") then return end
    local casts = PetCasts()
    local wrong = WrongCasts(casts)
    for _, k in ipairs(KINDS) do
        if not wrong[k.key] then castWarned[k.key] = nil end
    end
    if InCombat() or UnitIsDeadOrGhost("player") or IsMounted() or UnitOnTaxi("player") then
        return
    end
    local name = UnitName("pet")
    name = Readable(name) and name or petName or "your pet"
    local delay = 0
    for _, k in ipairs(KINDS) do
        local state = wrong[k.key]
        if state and castWarned[k.key] ~= state then
            castWarned[k.key] = state
            local line = { CastLine(k.key, state, casts[k.key].name, name) }
            local loud = state == "on" and k.key ~= "invis"
            local function Show()
                if loud then PlayAlert() end
                ShowText(unpack(line))
            end
            if delay == 0 then Show() else C_Timer.After(delay, Show) end
            delay = delay + TEXT_HOLD + 1
        end
    end
end

-- the pet bar reads Passive for a moment after a dismount or a new pet: check once it settles.
-- Mode first: when both are wrong the taunt line follows it.
local function SoonCheckMode()
    if modeTimer then modeTimer:Cancel() end
    modeTimer = C_Timer.NewTimer(NO_PET_DELAY, function()
        if CheckMode() then C_Timer.After(TEXT_HOLD + 1, CheckTaunt) else CheckTaunt() end
    end)
end

-- feed line first (it names missing food itself), else the low food line
local function FeedOrFood()
    if not CheckFeed() then CheckFood() end
    ArmFeed()
end

---------------------------------------------------------------------------
-- Subjugate Demon countdown (warlocks)
---------------------------------------------------------------------------
local function EnslaveName() return C_Spell.GetSpellName(1098) or "Subjugate Demon" end

-- when the pet's Subjugate aura runs out, if the client lets us read it (not in a fight:
-- auras are secret then)
local function EnslaveAuraEnd()
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return end
    for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "pet", EnslaveName(), filter)
        local t = ok and type(aura) == "table" and Number(aura.expirationTime)
        if t and t > 0 then return t end
    end
end

local function StopEnslave()
    if enslaveTicker then enslaveTicker:Cancel() enslaveTicker = nil end
    enslaveEnd = nil
end

local function EnslaveTick()
    if not enslaved then
        -- the cast's event can come before UNIT_PET: wait for the pet a moment
        if GetTime() - enslaveAt > 3 then StopEnslave() end
        return
    end
    enslaveEnd = EnslaveAuraEnd() or enslaveEnd
    if not (db.enslave and enslaveEnd) then return end
    local left = enslaveEnd - GetTime()
    if left <= 0 then return end
    for i, at in ipairs(ENSLAVE_SAY) do
        local next = ENSLAVE_SAY[i + 1]
        if left <= at and not enslaveSaid[at] and not (next and left <= next) then
            enslaveSaid[at] = true
            local name = UnitName("pet")
            name = Readable(name) and name or petName or "Your demon"
            if at == ENSLAVE_SAY[#ENSLAVE_SAY] then
                PlayAlert()
                ShowText(("%s breaks free in %d s"):format(name, at), 1, 0.45, 0.1)
            else
                ShowText(("%s breaks free in %d s - %s again"):format(name, at, EnslaveName()),
                    1, 0.82, 0)
            end
        elseif left <= at then
            enslaveSaid[at] = true
        end
    end
end

function ns.StartEnslave()
    enslaveEnd, enslaveSaid = GetTime() + ENSLAVE_TIME, {}
    if not enslaveTicker then enslaveTicker = C_Timer.NewTicker(0.5, EnslaveTick) end
end

---------------------------------------------------------------------------
-- Pet level behind (hunters)
---------------------------------------------------------------------------
-- percent of the way to the pet's next level, when readable
local function PetXP()
    if not GetPetExperience then return end
    local ok, cur, need = pcall(GetPetExperience)
    cur, need = ok and Number(cur), ok and Number(need)
    if cur and need and need > 0 then return math.floor(cur / need * 100) end
end

local function LevelLine(name, pet, behind)
    local xp = PetXP()
    return ("%s is level %d, %d behind you%s"):format(name, pet, behind,
        xp and (" (%d%% to %d)"):format(xp, pet + 1) or "")
end
ns.LevelLine = LevelLine

local function CheckPetLevel(level)
    if class ~= "HUNTER" or not db.petlevel then return end
    if not UnitExists("pet") or UnitIsDead("pet") then return end
    local pet = Number(UnitLevel("pet"))
    level = Number(level) or Number(UnitLevel("player"))
    if not (pet and level) or level - pet < LEVEL_BEHIND then return end
    local name = UnitName("pet")
    name = Readable(name) and name or petName or "Your pet"
    if levelWarned[name] == level then return end
    levelWarned[name] = level
    ShowText(LevelLine(name, pet, level - pet), 1, 0.82, 0)
end

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
    if class == "HUNTER" then
        pcall(events.RegisterEvent, events, "UNIT_HAPPINESS")
        events:RegisterEvent("BAG_UPDATE_DELAYED")
        events:RegisterUnitEvent("UNIT_AURA", "pet")
    end
    events:RegisterEvent("PET_BAR_UPDATE")
    events:RegisterEvent("GROUP_ROSTER_UPDATE")
    if class == "HUNTER" then events:RegisterEvent("PLAYER_LEVEL_UP") end
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
        -- after a reload the cast is gone: a readable Subjugate aura still says enslaved
        if petAlive and class == "WARLOCK" and not enslaved and EnslaveAuraEnd() then
            enslaved = true
            ns.StartEnslave()
        end
        StopPulse()
        C_Timer.After(NO_PET_DELAY, FeedOrFood)
        SoonCheckMode()
    elseif event == "PLAYER_REGEN_DISABLED" then
        fight = nil
        -- the last moment a secure button can be hidden before the fight locks it
        if feedButton then feedButton:Hide() end
        CheckHealth()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pulse and pulse.secret then StopPulse() end
        CheckHealth()
        C_Timer.After(NO_PET_DELAY, CheckNoPet)
        C_Timer.After(NO_PET_DELAY, FeedOrFood)
        SoonCheckMode()
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        C_Timer.After(NO_PET_DELAY, CheckNoPet)
    elseif event == "UNIT_PET" then
        CheckPet()
        CheckHealth()
        C_Timer.After(NO_PET_DELAY, FeedOrFood)
        SoonCheckMode()
    elseif event == "UNIT_HAPPINESS" then
        CheckFeed()
        if (Happiness() or 0) >= HAPPY then HideFeedButton() end
    elseif event == "UNIT_AURA" then
        if feedButton and feedButton:IsShown() and Eating() then HideFeedButton() end
    elseif event == "BAG_UPDATE_DELAYED" then
        if not InCombatLockdown() then ArmFeed() end
    elseif event == "PET_BAR_UPDATE" or event == "GROUP_ROSTER_UPDATE" then
        SoonCheckMode()
    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        CheckPet()
        CheckHealth()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- secret while spell casts are restricted: a secret can't index a table
        if not Readable(spellID) then return end
        if LET_GO[spellID] then letGoAt = GetTime() end
        if ENSLAVE[spellID] then
            enslaveAt = GetTime()
            if UnitExists("pet") then enslaved = true end
            ns.StartEnslave()
        end
    elseif event == "PLAYER_LEVEL_UP" then
        -- after the level-up lines; the pet's own level may tick over in the same moment
        C_Timer.After(TEXT_HOLD + 1, function() CheckPetLevel(arg1) end)
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
    { key = "mode", what = "warns when your pet is on Aggressive in a dungeon or Passive alone" },
    { key = "growl", what = "warns when Growl, Torment or Suffering autocasts in a group "
        .. "with a tank, or Growl or Torment is off alone" },
    { key = "invis", what = "warns when your Succubus's Lesser Invisibility autocasts "
        .. "(mobs evade its first hit on Forever)", warlock = true },
    { key = "enslave", what = "says 15 s and 3 s before your subjugated demon breaks free",
        warlock = true },
    { key = "feed", what = "feed reminder when your pet isn't happy", hunter = true },
    { key = "feedbutton", what = "feed button with the reminder, and the feed key",
        hunter = true },
    { key = "food", what = "warns when you have under 10 food your pet eats", hunter = true },
    { key = "petlevel", what = "says when you level and your pet is 2 or more behind you",
        hunter = true },
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
        if not (t.hunter and class ~= "HUNTER" or t.warlock and class ~= "WARLOCK") then
            print(("  %s - %s (now %s)"):format(Cmd(t.key .. " on||off"), t.what,
                OnOff(db[t.key])))
        end
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
    local mode, token = PetMode()
    local shown = mode and (mode:gsub("^%l", string.upper))
        or token and ("an unknown mode (" .. token .. ")") or "no mode the bar shows"
    print(("  Pet mode warning %s; pet is on %s now."):format(OnOff(db.mode), shown))
    local casts = PetCasts()
    local now = {}
    for _, kind in ipairs({ "taunt", "aoe", "invis" }) do
        local c = casts[kind]
        if c then now[#now + 1] = c.name .. " is " .. (c.auto and "on" or "off") .. " autocast" end
    end
    print(("  Growl warning %s%s; %s now."):format(OnOff(db.growl), class == "WARLOCK"
        and (", Invisibility warning " .. OnOff(db.invis)) or "",
        #now > 0 and table.concat(now, ", ") or "no Growl, Torment, Suffering or Invisibility on the pet bar"))
    if class == "HUNTER" then
        local level, dmg = Happiness()
        local mood = ({ "unhappy", "content", "happy" })[level or 0] or "unknown"
        if dmg then mood = ("%s (%d%% damage)"):format(mood, dmg) end
        print(("  Feed reminder %s; pet is %s now."):format(OnOff(db.feed), mood))
        local food, total = PetFood()
        local what = food and ("%d (feeds %s first)"):format(total, C_Item.GetItemInfo(food)
            or "item " .. food) or total and "none" or "unknown"
        print(("  Low food warning %s; food it eats in your bags: %s."):format(OnOff(db.food),
            what))
        local key = GetBindingKey and GetBindingKey("CLICK MeioPetsFeedButton:LeftButton")
        print(("  Feed button %s; feed key: %s."):format(OnOff(db.feedbutton),
            key or "none (Esc > Options > Key Bindings > AddOns)"))
        local pet, xp = UnitExists("pet") and Number(UnitLevel("pet")), PetXP()
        print(("  Level behind warning %s; pet is %s now."):format(OnOff(db.petlevel), pet
            and ("level %d%s"):format(pet, xp and (", %d%% to %d"):format(xp, pet + 1) or "")
            or "not out"))
    else
        local left = enslaved and enslaveEnd and math.max(0, enslaveEnd - GetTime())
        print(("  %s countdown %s%s."):format(EnslaveName(), OnOff(db.enslave), left
            and ("; your demon is held about %d s more"):format(left) or ""))
    end
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
    if class == "HUNTER" and db.feed then
        C_Timer.After(HOLD + TEXT_HOLD + 2, function()
            ShowText(FeedLine(1, petName or "Your pet"))
        end)
    end
end

function ns.OpenSettingsOrHelp()
    if not (ns.OpenSettings and ns.OpenSettings()) then ns.Help() end
end

function MeioPets_OnAddonCompartmentClick() ns.OpenSettingsOrHelp() end

BINDING_HEADER_MEIOPETS = "MeioPets"
_G["BINDING_NAME_CLICK MeioPetsFeedButton:LeftButton"] = "Feed your pet"

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
        if word == "feed" and not db.feed then HideFeedButton() end
        if word == "feedbutton" then ArmFeed() end
        Say(TOGGLE[word].what .. " " .. OnOff(db[word]))
    else
        Say(('unknown command "%s"'):format(msg))
        ns.Help()
    end
end
