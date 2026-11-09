# Shadow Word: Death Indicator

A World of Warcraft: Forever addon for Shadow Priests. It shows when your highest rank of Shadow Word: Death will kill your target.

- **Bar glow**: a soft purple glow hugs the target's health and power bars.
- **Portrait**: the target's portrait turns into the Shadow Word: Death icon with a pulsing halo.
- **Unit frames**: finds EllesmereUI's, ElvUI's, Shadowed Unit Frames' and Blizzard's target frames on its own.

## Installation

In WoWUp, go to **Get Addons → Install from URL** and paste:

```
https://github.com/zakpruitt/ShadowWordDeathIndicator
```

## Commands

| Command | Description |
|---|---|
| `/swd test` | Show the effects for 5 seconds |
| `/swd debug` | Show the rank, tooltip and damage being used |
| `/swd border` / `portrait` | Turn the bar glow / portrait icon on or off |
| `/swd intensity <0-1>` | How strong the glow is (default 0.4) |
| `/swd color <r> <g> <b>` | Glow color, 0-1 each |
| `/swd pulse` / `label` | Turn the pulse / "SW:D KILL" text on or off |
| `/swd shape auto\|round\|square` | Portrait icon shape |
| `/swd frame mouse` / `portraitframe mouse` | Glow around, or cover, the frame under the mouse (`auto` to reset) |

## Tuning the estimate

The damage comes from the spell's tooltip, and the low end of its range is used by default, so the glow never shows on a target that would live. If your tooltip leaves out spell power or Shadowform, compare `/swd debug` with your real hits and adjust:

| Command | Description |
|---|---|
| `/swd mode min\|avg\|max` | Which end of the damage range to trust |
| `/swd mult <n>` | Multiply the estimate, e.g. `1.15` for Shadowform |
| `/swd sp <coef>` | Add spell power times this |
| `/swd flat <n>` | Add a flat amount, negative to play it safer |

## How detection works

Forever hides the target's health from addons in combat, so Lua can't compare it with the spell's damage. A StatusBar still accepts the hidden value, so the addon feeds an invisible, very long bar with max = target health and value = SW:D damage. The bar only fills to its end when the hit is lethal, and the glow rides the fill's end inside a clipped window there, so it's only on screen when SW:D will kill.

## Develop

```
python tools/make_textures.py Textures   # regenerate the glow textures
```

<!-- portfolio
section: more
name: Shadow Word: Death Indicator
year: 2026
summary: A World of Warcraft addon that makes the target frame glow when Shadow Word: Death will kill it.
-->
