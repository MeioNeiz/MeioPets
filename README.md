# Meio Pets

Know when your pet is in trouble: low health, dead, or not back after the fight.

![A Voidwalker at 22% health in a fight: before, only the pet frame; with Meio Pets, a red
pulse around it](docs/before-after.png)

## What it does

For hunters and warlocks. When your pet's health runs low in a fight, its frame pulses red,
so you heal it or pull it back in time.

- Red pulse around the pet frame (Blizzard's or FlareUI's) under 35% health, or your own
  threshold
- A line with its name and a sound when your pet dies
- A few seconds after the fight, or after you are resurrected, a reminder when your pet
  isn't back: Call Pet, Revive Pet or summon your demon
- A sound with each warning, four to pick from; each warning can be turned off

In a fight the game hides pet health from addons, so low health then pulses without a
sound.

Settings: Esc > Options > AddOns > MeioPets, or `/meiopets`.

- `/meiopets test`: show the warnings now
- `/meiopets at <percent>`: warn under this much pet health, 10 to 80
- `/meiopets status`: what it could read in your last fight
- `/meiopets help`: every command

## Install

Use your addon manager (CurseForge, Wago), or unzip a GitHub release into
`World of Warcraft\_forever_\Interface\AddOns` and restart WoW fully.

## Feedback

Bugs and ideas: [GitHub issues](https://github.com/MeioNeiz/MeioPets/issues)

## More Meio addons

[Meio TrainerCompare](https://www.curseforge.com/wow/addons/trainercompare) | [Meio AutoRank](https://www.curseforge.com/wow/addons/meio-autorank) | [Meio MeterHover](https://www.curseforge.com/wow/addons/meterhover) | [Meio Map](https://addons.wago.io/addons/meiomap) | [Meio Alts](https://addons.wago.io/addons/meioalts) | [Meio DPS](https://addons.wago.io/addons/meiodps) | [Meio Plates](https://addons.wago.io/addons/meioplates)

## Licence

[MIT](LICENSE)
