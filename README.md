# Shadow Word: Death Indicator

Know when Shadow Word: Death will finish your target.

When your highest rank of Shadow Word: Death will kill your target, a soft purple glow hugs its health and power bars and its portrait turns into the Shadow Word: Death icon with a pulsing halo. It works with EllesmereUI, ElvUI, Shadowed Unit Frames and Blizzard's target frame without any setup.

## Commands

| Command | Description |
|---|---|
| `/swd test` | Show the effects for 5 seconds |
| `/swd debug` | Show the rank, tooltip and damage being used |
| `/swd border` / `portrait` | Turn the bar glow / portrait icon on or off |
| `/swd intensity <0-1>` | How strong the glow is (default 0.4) |
| `/swd color <r> <g> <b>` | Glow color, 0-1 each |
| `/swd pulse` / `label` | Turn the pulse / "SW:D KILL" text on or off |
| `/swd shape auto` / `round` / `square` | Portrait icon shape |
| `/swd frame mouse` / `portraitframe mouse` | Glow around, or cover, the frame under your mouse (`auto` to reset) |

## Tuning the estimate

The damage comes from the spell's tooltip, and the low end of its range is used by default, so the glow never shows on a target that would survive. If your tooltip leaves out spell power or Shadowform, compare `/swd debug` with your real hits and adjust:

| Command | Description |
|---|---|
| `/swd mode min` / `avg` / `max` | Which end of the damage range to trust |
| `/swd mult <n>` | Multiply the estimate, e.g. `1.15` for Shadowform |
| `/swd sp <coef>` | Add your spell power times this |
| `/swd flat <n>` | Add a flat amount, negative to play it safer |

## How detection works

Forever hides the target's health from addons in combat, so the addon can't compare it with Shadow Word: Death's damage itself. A status bar still accepts the hidden value, so the addon feeds an invisible, very long bar with the target's health as its maximum and the spell's damage as its value. The bar only fills to its end when the hit is lethal, and the glow sits at the end of the fill inside a clipped window, so it's only on screen when Shadow Word: Death will kill.

<!-- portfolio
section: more
name: Shadow Word: Death Indicator
year: 2026
summary: A World of Warcraft addon that makes the target frame glow when Shadow Word: Death will kill it.
-->
