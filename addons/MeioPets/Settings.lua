-- Options panel: Esc > Options > AddOns > MeioPets, or /meiopets. Writes into MeioPetsDB.
local _, ns = ...

local category, layout

local function Header(title, tip)
    if layout and CreateSettingsListSectionHeaderInitializer then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title, tip))
    end
end

local function Checkbox(key, name, tip)
    local setting = Settings.RegisterAddOnSetting(category, "MEIOPETS_" .. key:upper(), key,
        ns.db, Settings.VarType.Boolean, name, true)
    Settings.CreateCheckbox(category, setting, tip)
end

local function Register()
    if category or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
    category, layout = Settings.RegisterVerticalLayoutCategory("MeioPets")
    local db = ns.db

    Header("Low pet health", "In a fight, when your pet's health drops under the threshold. "
        .. "Once per dip: it warns again after the pet heals 15% above it.")
    local at = Settings.RegisterAddOnSetting(category, "MEIOPETS_AT", "at", db,
        Settings.VarType.Number, "Warn under", 35)
    local options = Settings.CreateSliderOptions(10, 80, 5)
    if MinimalSliderWithSteppersMixin then
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
            function(v) return ("%d%%"):format(v) end)
    end
    Settings.CreateSlider(category, at, options, "Pet health, in percent, under which "
        .. "MeioPets warns. /meiopets at <percent> does the same.")
    Checkbox("flash", "Pulse the pet frame", "A red pulse around the pet frame (FlareUI's "
        .. "or Blizzard's) when your pet's health is low. In a fight the game hides pet health "
        .. "from addons, so the pulse then stays on for as long as the pet is low. "
        .. "/meiopets flash on||off")

    Header("Sound", "Played with each warning. In a fight pet health is hidden from addons, "
        .. "so low health then pulses without a sound; died and no pet still sound.")
    Checkbox("sound", "Play a sound", "Play a sound with the low health, died "
        .. "and no pet warnings. /meiopets sound on||off")
    local sound = Settings.RegisterAddOnSetting(category, "MEIOPETS_SOUND_NAME", "soundName",
        db, Settings.VarType.String, "Which sound", "raid")
    Settings.CreateDropdown(category, sound, function()
        local c = Settings.CreateControlTextContainer()
        for _, s in ipairs(ns.SOUNDS) do c:Add(s.key, s.name) end
        return c:GetData()
    end, "Which sound plays. Picking one plays it. /meiopets sound <name>")
    if Settings.SetOnValueChangedCallback then
        Settings.SetOnValueChangedCallback("MEIOPETS_SOUND_NAME", function() ns.PlayAlert() end)
    end

    Header("Pet died and no pet", "A line in the middle of the screen, under the game's "
        .. "error messages.")
    Checkbox("died", "Pet died warning", "When your pet dies: a sound and a red line with its "
        .. "name. /meiopets died on||off")
    Checkbox("nopet", "No pet reminder", "When your pet died or "
        .. "vanished and isn't back a few seconds after the fight (or after you are "
        .. "resurrected): a sound and a gold line. Quiet while FlareUI's Buff Reminders shows "
        .. "its own pet reminder. /meiopets nopet on||off")

    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer("Try it", "Test",
            function() SlashCmdList.MEIOPETS("test") end, "Show the low health pulse, play the "
            .. "sound, then the died line (same as /meiopets test).", true))
    end
    Settings.RegisterAddOnCategory(category)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    local ok, err = pcall(Register)
    if not ok then geterrorhandler()(err) end
end)

function ns.OpenSettings()
    if not category then return false end
    Settings.OpenToCategory(category:GetID())
    return true
end
