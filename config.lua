Config = {}

-- ==========================================================
-- General toggles
-- ==========================================================
Config.StealthModeEnabled = true               -- allow the stealth-walk toggle at all
Config.DivingOnly = false                      -- kept for parity with the original mod; diving does not yet auto-transition into crawling (see README), so this has no effect yet - pressing Config.Keys.CrawlToggle always works regardless
Config.NoRagdollWithGetUpAnim = true           -- kept for parity with the original mod; our custom dive never ragdolls, so this has no extra effect right now
Config.DivingBackwardToSit = true              -- when dodging backward, try to settle into a seated position afterwards (needs Config.Dive.SitAnimDict/SitAnimName set)
Config.DivingBackwardToOnBack = false          -- when true, skip the sit transition and just let the ped land on its back
Config.DisableInputsIfMissionDisablesThem = true -- don't fight the game's own control locks during missions/cutscenes/menus/interaction UIs
Config.EnableDiveOnlyWhenAiming = true         -- only allow the custom dive while the player is holding Aim
Config.OverrideDefaultCombatDive = true        -- true = replace the vanilla "Dive" control behaviour with the custom dive-and-shoot dodge below

-- ==========================================================
-- Keyboard-only keybinds
-- ==========================================================
-- RedM has no working RegisterKeyMapping (FiveM-only native), so these are read directly from
-- the physical keyboard via IS_RAW_KEY_DOWN (Windows virtual-key codes), independent of whatever
-- RDR2 input context is currently active. Not rebindable in-game - edit the values below and
-- restart the resource. Common codes: letters 'A'-'Z' = 0x41-0x5A, Left Alt = 0xA4, Left Ctrl = 0xA2.
Config.Keys = {
    CrawlToggle = 0x58,   -- 'X': press to enter/exit the scripted prone/crawl state
    StealthToggle = 0xA4, -- Left Alt: toggles the custom stealth-walk
    SwitchToSit = 0x5A,   -- 'Z': manually switch into a seated position after a backward dodge
}

-- Prints to the F8/client console confirming the resource loaded and when keys are detected,
-- to make it easy to verify things are working. Set to false once you've confirmed it works.
Config.Debug = false

-- Hold-time tuning (milliseconds)
Config.DiveHoldTimeMs = 1     -- how long "Dive" must be held before the custom dodge triggers (1 ~= trigger on tap, matches keyboard play)

-- ==========================================================
-- Dive dodge tuning
-- ==========================================================
Config.Dive = {
    -- Optional cosmetic animation played as a secondary/upper-body task while dodging, so aim/fire control is preserved.
    -- Leave AnimDict/AnimName nil to skip the animation and use a pure physical dodge (still fully functional without it).
    -- If you set these, keep bit 16 (upper body) in AnimFlag so the animation doesn't take over full ped control.
    AnimDict = nil,
    AnimName = nil,
    AnimFlag = 48, -- 16 (upper body) + 32 (secondary task) - adjust once you've picked/tested a clip

    -- Optional cosmetic animation for the "switch to sit" recovery pose after a backward dodge (see DivingBackwardToSit above).
    SitAnimDict = nil,
    SitAnimName = nil,

    -- REVERTED: a weapon-specific "lying prone holding weapon" pose (mech_weapons_core@base@dive@
    -- .../prone) was tried here for a nicer idle visual, but its own baked root motion kept
    -- sinking the ped into the ground. The stationary crawl-idle pose now just uses plain
    -- mech_crawl@base 'idle' (see client/main.lua), matching the original working reference script.

    ForceMultiplier = 4.5,  -- strength of the directional push applied when dodging
    RecoveryTimeMs = 550,   -- how long the fire-unlock window stays open after the dodge starts
}

-- Ped config flag(s) cleared while crawling/diving so nothing blocks blind/prone firing
Config.PedConfigFlags = {
    DisableBlindFiringInShotReactions = 96, -- PCF_DisableBlindFiringInShotReactions
}

-- ==========================================================
-- Crawl aim transition masking
-- ==========================================================
-- The stand-up that happens when you aim while crawling (see README) can't be eliminated, but it
-- can be masked with a very quick screen fade so it happens off-screen, then fades back in with
-- the ped already aiming (and scoped, for scope weapons). This briefly blacks out the screen on
-- every aim-press while crawling, so it's a trade-off, not a free fix - tune or disable to taste.
Config.Crawl = {
    MaskStandUpWithFade = true,
    -- FadeOutMs kept short/snappy: there's an unavoidable one-frame-ish gap between the player
    -- releasing Aim and this resource reacting to it (the game's own scope/aim view disengages
    -- instantly on that same frame, before our fade even starts), so a faster fade-out onset
    -- minimizes - but can't fully eliminate - that brief glimpse on release.
    FadeOutMs = 80,    -- how long the screen takes to go black
    FadeInMs = 150,    -- how long the screen takes to fade back in

    -- Separate hidden-hold durations because the two transitions settle at different speeds:
    -- lying back down uses our own fast-blending pose (see UpdateCrawlMovement) so it's quick and
    -- fully hidden by this. Standing up to aim/scope is NOT fully fixable this way: testing up to
    -- a full 2000ms (confirmed pitch black the whole time) still didn't hide the stand-up before
    -- the scope engaged, which strongly suggests the scope-engage sequence doesn't even begin
    -- until the screen becomes visible again - i.e. no amount of hidden waiting beforehand can
    -- cover it. Rolled back to a modest value that just softens the initial pop rather than
    -- chasing full coverage, since longer values only added a pointless delay with no benefit.
    HiddenHoldAimMs = 650,  -- extra time spent fully black after standing up to aim/scope
    HiddenHoldMs = 350,     -- extra time spent fully black after lying back down into crawl

    -- DISABLED: this was meant to simulate holding Duck while aiming from crawl, on the theory
    -- that holding Duck decides crouched/kneeling vs standing aim. A screenshot showed the ped
    -- fully standing despite this being on, and manually holding the real Duck key + Aim together
    -- was then tested and *also* produced standing, not kneeling - so the theory itself was wrong,
    -- not just this simulation. Left in place (harmless, no-op'd) in case it's useful groundwork
    -- for a different theory later.
    SimulateDuckForKneelingAim = false,
}
