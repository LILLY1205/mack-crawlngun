# mack-crawlngun

Keyboard-only RedM client resource that lets you crawl (prone) and dive while keeping the
ability to aim and fire. Framework-agnostic - it only manipulates your own local ped, so it
works alongside RSG-Core without needing any of its exports.

## Install
1. Copy this folder into your server's `resources` directory (keep the folder name `mack-crawlngun`).
2. Add `ensure mack-crawlngun` to your `server.cfg`.
3. Restart the resource / server.

## What it does
- **Crawl + shoot**: RDR2/RedM has no native prone state, so this resource adds one. Press **X**
  (`Config.Keys.CrawlToggle`) to enter/exit a real prone animation (`mech_crawl@base`), with
  W/A/S/D driving forward/backward crawl and left/right turn clips. Press X again to stand back up.
  Animation names come directly from a reference Lua file bundled with the original
  "Dive - Crawl N' Gun" mod, so they're the real, verified clips rather than a guess.
  Because the crawl clips are full-body, **firing is only unlocked while stationary/prone-idle** -
  as soon as you press a movement key the crawl-walk animation takes over the whole skeleton and
  Attack/Aim are explicitly disabled, then re-enabled the instant you stop moving. This matches how
  the original mod's own author framed it ("shoot while prone" really means "stop and shoot").
  A weapon-specific "lying prone holding rifle/pistol" pose (from the base game's own weapon-dive
  assets) was tried for the stationary idle stance, but that clip carries its own baked root
  motion and kept sinking the ped into the ground, so it was reverted - the idle stance is back to
  plain `mech_crawl@base` 'idle', matching the original reference script exactly.
  Since the stand-up on aim can't be eliminated (confirmed - RDR2's aim/fire task and a custom
  animation task can't run at once, even with the player-controllable flag), `Config.Crawl` masks
  it with a quick screen fade to black. This works well for the *release* direction (fades out,
  drops back into the prone pose, fades back in - fully hidden). The *aim-in* direction only
  partially helps: even a confirmed pitch-black screen held for a full 2 seconds still didn't hide
  the stand-up before a scope engaged, which strongly suggests the scope-engage sequence doesn't
  progress at all while the screen is faded out - it only starts once you can see again, so no
  amount of hidden waiting beforehand can cover it. `HiddenHoldAimMs` is therefore kept modest (it
  softens the initial pop rather than chasing full coverage); a brief glimpse of standing before
  aiming/scoping fully engages is an accepted, currently-unresolved limitation. Fully configurable
  (timings, or `MaskStandUpWithFade = false` to disable entirely) in `config.lua`.
- **Dive + shoot**: The vanilla "Dive" is a short fixed engine animation that takes control away
  from you while it plays - there's no supported way to fire literally mid-vanilla-dive. When
  `Config.OverrideDefaultCombatDive = true`, this resource disables the vanilla dive and instead
  reads the same key press underneath it (`IsDisabledControlPressed`) to trigger a scripted dodge:
  a directional physics push (`ApplyForceToEntity`) plus, optionally, a secondary/upper-body
  animation, so your normal aim-and-fire control loop keeps running through it.
- **Stealth toggle**: `Config.Keys.StealthToggle` (default Left Alt) toggles `SetPedStealthMovement`.
- **Switch to sit**: `Config.Keys.SwitchToSit` (default `Z`) plays an optional recovery pose after
  a backward dodge, if you've configured `Config.Dive.SitAnimDict`/`SitAnimName`.

### How the keybinds work
RedM has no working `RegisterKeyMapping` (FiveM-only native), so this resource does **not** use
that, and does **not** use RSG-Core's `RSGShared.Keybinds` control-hash table either (an earlier
version of this file did, but that approach wasn't reliable here). Instead, Crawl toggle, Stealth
toggle, and Switch-to-sit each read the **physical key state directly** via the raw-key native
(`IS_RAW_KEY_DOWN`, invoked by hash), using plain Windows virtual-key codes. Dive still separately
reuses the game's own "Dive" control directly, so it always follows whatever the player has Dive
bound to. Trade-offs of this approach:
- These three keys are **not rebindable from RedM's in-game settings menu** - to change them, edit
  the virtual-key code values in `Config.Keys` in `config.lua` and restart the resource. A list of
  common codes is in the comment above `Config.Keys`.
- Because this reads the raw key, it fires regardless of what RDR2 input context is active (menus,
  vehicles, etc.) unless `Config.DisableInputsIfMissionDisablesThem` blocks it - unlike control-hash
  or native-control based inputs, which only fire within their proper context.

## Known limitations (please read before reporting a bug)
- **Crawling turns, it doesn't strafe/aim-lock.** `walk_turn_l4`/`walk_turn_r4` are timed turn clips
  (1.5s), matching the reference script; there's no dedicated left/right strafe clip in
  `mech_crawl@base`, so turning is the only way to change direction while crawling.
- **No baked-in dive/sit animation.** I did not have a verified, confirmed-correct RDR2 animation
  dictionary/clip name for a "dive dodge while armed" or "sit down" pose, and shipping a guessed
  one risked silently doing the wrong thing in-game. By default the dive is a pure physics push
  with no animation (still fully functional for keeping fire control), and the sit transition is a
  no-op. To add the polish, find a clip you like (e.g. with an in-game anim browser/trainer),
  then set `Config.Dive.AnimDict`/`AnimName` (keep bit 16 "upper body" in `AnimFlag`) and/or
  `Config.Dive.SitAnimDict`/`SitAnimName` in `config.lua`.
- **`Config.DivingOnly` and `Config.NoRagdollWithGetUpAnim`** are kept in `config.lua` for parity
  with the original mod's option list, but aren't wired up yet: diving does not currently
  auto-transition you into the crawl state afterward (you'd need to press Crawl toggle separately), and the
  custom dive never ragdolls in the first place (it uses a physics push + optional secondary
  animation instead), so there's no ragdoll-recovery behavior to toggle.
- **Compatibility**: if another resource keeps calling `DisableControlAction` on Attack/Aim every
  frame for its own reasons (e.g. while a menu is open), this resource can't reliably out-race it.
  If firing still gets blocked in a specific situation, that other resource is the one to check.

## Manual test checklist
- Press X: confirm you drop into a prone crawl animation.
- While stationary and prone, confirm you can aim and fire normally, and that aiming now briefly
  fades the screen to black (instead of just visibly popping up) before you're aiming.
- Press W/A/S/D while prone: confirm the crawl/turn animations play, and that firing is blocked
  until you stop moving again.
- Press X again: confirm the ped stands back up cleanly (no stuck animation).
- Toggle stealth walk with Left Alt, confirm the walk changes and toggles back off.
- With `OverrideDefaultCombatDive = true`, aim and press your Dive key: you should move/dodge and
  be able to fire immediately, instead of losing control during a vanilla dive animation.
- With `OverrideDefaultCombatDive = false`, confirm the vanilla dive still plays as normal.
- Check the client console/F8 log on resource start for any errors.
