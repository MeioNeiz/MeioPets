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
        ns.db, Settings.VarType.Boolean, name, ns.DEFAULTS[key])
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
    Checkbox("flash", "Pulse pet frame", "A red pulse around the pet frame (FlareUI's "
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

    Header("Pet mode", "Aggressive pulls extra packs in a dungeon; Passive leaves you to "
        .. "fight alone. Defensive suits most play. Growl on autocast takes aggro from a tank. "
        .. "Right-click a pet button to switch its autocast.")
    Checkbox("mode", "Mode warning", "Your pet on Aggressive in a dungeon or raid "
        .. "(a sound and an orange line), or on Passive while you're not in a group (a gold "
        .. "line, unless FlareUI's Buff Reminders shows its Passive reminder). Once, until "
        .. "the mode or the place changes. /meiopets mode on||off")

    Checkbox("growl", "Growl warning", "Growl (or your Voidwalker's Torment or Suffering) "
        .. "on autocast in a group with a tank, where it pulls aggro off them (a sound and an "
        .. "orange line), or Growl or Torment off autocast while you're alone (a gold line). "
        .. "Once, until it is put right. Off at first. /meiopets growl on||off")
    if select(2, UnitClass("player")) == "WARLOCK" then
        Checkbox("invis", "Invisibility", "Your Succubus's Lesser Invisibility on "
            .. "autocast: on WoW Forever a mob it hits first from invisibility evades, and your "
            .. "opener is lost. A gold line, once, until you right-click it off on the pet bar. "
            .. "/meiopets invis on||off")
        Checkbox("enslave", "Subjugate timer", "A demon you hold with Subjugate "
            .. "(Enslave) Demon: a gold line 15 seconds before it breaks free, and a sound and an "
            .. "orange line 3 seconds before. It can break sooner; then MeioPets says it broke "
            .. "free. /meiopets enslave on||off")
    end

    if select(2, UnitClass("player")) == "HUNTER" then
        Header("Pet happiness and level", "Happy pets do 25% more damage than content "
            .. "ones; unhappy pets do 25% less and may run off.")
        Checkbox("feed", "Feed reminder", "When your pet drops below happy: a gold line "
            .. "after the fight (content), or a sound and an orange line (unhappy). Once per "
            .. "drop, and not while it eats. /meiopets feed on||off")
        Checkbox("feedbutton", "Feed button", "With the feed reminder, a button that feeds "
            .. "your pet the cheapest food it eats well (its tooltip names the food), and a key "
            .. "that does the same any time: Key Bindings > AddOns > MeioPets. Off at first: it "
            .. "can pick food you'd rather keep. /meiopets feedbutton on||off")
        Checkbox("food", "Low food warning", "When you have under 10 pieces left of food "
            .. "your pet eats, or none: a gold line after the fight. Once, until you stock "
            .. "up. /meiopets food on||off")
        Checkbox("petlevel", "Pet level behind", "When you level up and your pet is 2 or "
            .. "more levels behind you: a gold line with its level and how far it is to the "
            .. "next. Pets gain XP from your kills and never pass your level. Once per level. "
            .. "/meiopets petlevel on||off")
    end

    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer("Try it", "Test",
            function() SlashCmdList.MEIOPETS("test") end, "Show the low health pulse, play the "
            .. "sound, then the died line, and for hunters the feed line (same as /meiopets "
            .. "test).", true))
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
