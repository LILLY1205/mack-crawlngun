-- mack-crawlngun / client/main.lua
-- Keyboard-only crawl + dive + keep-shooting patch for RedM.
-- Framework-agnostic: only touches the local player ped, so it works alongside RSG-Core
-- without needing any of its exports.
--
-- The prone/crawl animation dictionary and clip names (mech_crawl@base: idle, walk,
-- walk_turn_l4, walk_turn_r4, onfront_bwd) are taken from a reference Lua companion
-- script bundled with the original "Dive - Crawl N' Gun" mod, since RDR2/RedM has no
-- native prone state of its own.

-- Confirmed RDR3 control hashes (CitizenFX "for CitizenFX usage" control list)
local CONTROL_DUCK        = 0xDB096B85 -- Duck / hold to crawl
local CONTROL_DIVE        = 0x06052D11 -- Dive / evasive dodge
local CONTROL_ATTACK      = 0x07CE1E61 -- Fire weapon
local CONTROL_AIM         = 0xF84FA74F -- Aim weapon
local CONTROL_RELOAD      = 0xE30CD707 -- Reload weapon
local CONTROL_MOVE_LR     = 0x4D8FB4C1 -- Move left/right axis (used for dive direction)
local CONTROL_MOVE_UD     = 0xFDA83190 -- Move forward/back axis (used for dive direction)
local CONTROL_MOVE_UP     = 0x8FD015D8 -- W - crawl forward
local CONTROL_MOVE_DOWN   = 0xD27782E3 -- S - crawl backward
local CONTROL_MOVE_LEFT   = 0x7065027D -- A - crawl turn left
local CONTROL_MOVE_RIGHT  = 0xB4E465B4 -- D - crawl turn right

local CRAWL_DICT = 'mech_crawl@base'

local stealthOn = false
local diveActive = false
local diveEndAt = 0
local diveHeldSince = nil

local crawling = false
local crawlAnimTarget = nil
local aimingWhileCrawling = false
local aimSessionUsedFade = false
local pedPositionFrozen = false

-- FreezeEntityPosition is idempotent-guarded here purely to avoid redundant native calls every
-- tick; it's always safe to call regardless. Used to stop the stationary prone-hold pose's own
-- baked root motion from slowly sinking the ped into the ground (locking the anim's own axes
-- instead was tried and crashed the client on this clip, so this freezes the entity instead).
local function SetPedPositionFrozen(ped, frozen)
    if pedPositionFrozen == frozen then return end
    FreezeEntityPosition(ped, frozen)
    pedPositionFrozen = frozen
end

-- Reads the physical key directly (Windows virtual-key code) via the raw-key native, invoked by
-- hash since there is no auto-generated named wrapper for it. This is independent of whatever
-- RDR2 input context/control is currently active, unlike IsControlPressed/IsControlJustPressed.
local function IsRawKeyDown(vk)
    local result = Citizen.InvokeNative(0xD95A7387, vk)
    return result == true or result == 1
end

local prevCrawlKeyDown = false
local prevStealthKeyDown = false
local prevSitKeyDown = false

local function DebugPrint(msg)
    if Config.Debug then
        print('[mack-crawlngun] ' .. msg)
    end
end

-- Calls fn only if it's actually a function, catching any error inside it too, so a missing or
-- misbehaving native (e.g. one that doesn't exist as a named global on this build) can't take
-- down the whole resource - it just falls back to nil/default behaviour instead.
local function SafeCall(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

-- Wrapped so a missing/renamed fade native on some builds just silently no-ops instead of
-- crashing the resource (see SafeCall above).
local function TryFadeOut(ms)
    return SafeCall(DoScreenFadeOut, ms)
end

local function TryFadeIn(ms)
    return SafeCall(DoScreenFadeIn, ms)
end

-- EXPERIMENTAL: fakes the Duck control being held for the current frame so the game's own aim
-- logic considers the player "ducking" and picks a crouched/kneeling aim stance. Wrapped in
-- SafeCall so a missing/misbehaving native just no-ops instead of erroring. Gated by
-- Config.Crawl.SimulateDuckForKneelingAim - see config.lua for how to instantly disable this.
local function TrySimulateDuck()
    if Config.Crawl.SimulateDuckForKneelingAim then
        SafeCall(SetControlNormal, 0, CONTROL_DUCK, 1.0)
    end
end

-- Like Wait(ms), but keeps simulating Duck every frame throughout (a single SetControlNormal call
-- only affects the frame it's called on, so a plain Wait(ms) wouldn't keep it "held" during the
-- fade-out/hidden-hold sequence, which spans multiple frames).
local function WaitSimulatingDuck(ms)
    local endTime = GetGameTimer() + ms
    while GetGameTimer() < endTime do
        TrySimulateDuck()
        Wait(0)
    end
end

local function TryIsScreenFadedOut()
    local result = SafeCall(IsScreenFadedOut)
    return result == true or result == 1
end

-- Like WaitSimulatingDuck, but after the requested duration also polls IsScreenFadedOut and keeps
-- waiting (up to a small safety cap) until the screen is actually confirmed fully black, instead
-- of just assuming the fade finished exactly on time. A tiny sliver of the stand-up was still
-- visible with a fixed-duration wait alone, suggesting the native fade can finish a few ms later
-- than requested; this closes that gap without guessing a longer fixed number.
local function WaitForFadeOutSimulatingDuck(ms)
    WaitSimulatingDuck(ms)
    local safetyDeadline = GetGameTimer() + 500
    while not TryIsScreenFadedOut() and GetGameTimer() < safetyDeadline do
        TrySimulateDuck()
        Wait(0)
    end
end

-- NOTE: a camera-FOV-based scope-engage detector was tried here (narrow FOV = scope zoomed in),
-- but made no observable difference - RDR2's scope zoom apparently doesn't move the gameplay cam
-- FOV the way this technique relies on, or the native isn't behaving as expected on this build.
-- Reverted to the plain fixed-duration wait; see Config.Crawl.HiddenHoldAimMs to tune it.

-- Detects whether the currently equipped weapon is a scope-class weapon (e.g. sniper/scoped
-- rifles), so the fade mask only applies to those, not plain pistols/non-scoped longarms.
-- LIMITATION: this only catches weapon types that inherently have a scope (via IsWeaponSniper);
-- it can't detect an optional scope *component* manually attached to an otherwise unscoped
-- weapon, since that needs a full list of scope component hashes this hasn't been verified against.
local function IsCurrentWeaponScoped(ped)
    local weaponHash = SafeCall(GetSelectedPedWeapon, ped)
    if not weaponHash then return false end
    return SafeCall(IsWeaponSniper, weaponHash) == true
end

local function IsAiming()
    return IsControlPressed(0, CONTROL_AIM)
end

local function IsMissionDisablingInputs()
    return Config.DisableInputsIfMissionDisablesThem and IsInputDisabled(0)
end

local function UnlockFiringControls(ped)
    EnableControlAction(0, CONTROL_ATTACK, true)
    EnableControlAction(0, CONTROL_AIM, true)
    EnableControlAction(0, CONTROL_RELOAD, true)
    SetPedConfigFlag(ped, Config.PedConfigFlags.DisableBlindFiringInShotReactions, false)
end

-- Starts the scripted prone/crawl state. The animation is full-body (it's a real
-- lying-on-the-ground clip), so it will visually override aiming/firing while any
-- movement clip is playing - see UpdateCrawlMovement below, which is why firing is
-- only unlocked once the ped settles back into the stationary "idle" prone pose.
local function StartCrawling(ped)
    if crawling then return end

    RequestAnimDict(CRAWL_DICT)
    local tries = 0
    while not HasAnimDictLoaded(CRAWL_DICT) and tries < 200 do
        Wait(0)
        tries = tries + 1
    end
    if not HasAnimDictLoaded(CRAWL_DICT) then return end

    -- crawlAnimTarget stays nil so the very next UpdateCrawlMovement call (run in the same tick,
    -- right after this) picks and plays the idle pose immediately.
    crawling = true
    crawlAnimTarget = nil
end

local function StopCrawling(ped)
    if not crawling then return end
    SetPedPositionFrozen(ped, false)
    ClearPedTasks(ped)
    RemoveAnimDict(CRAWL_DICT)
    crawling = false
    crawlAnimTarget = nil
end

-- Reads WASD each tick to pick the right crawl clip, and returns true when the ped
-- is stationary (prone idle) - the only state in which we let the player fire.
local function UpdateCrawlMovement(ped)
    local desired = 'idle'
    if IsControlPressed(0, CONTROL_MOVE_UP) then
        desired = 'walk'
    elseif IsControlPressed(0, CONTROL_MOVE_DOWN) then
        desired = 'onfront_bwd'
    elseif IsControlPressed(0, CONTROL_MOVE_LEFT) then
        desired = 'walk_turn_l4'
    elseif IsControlPressed(0, CONTROL_MOVE_RIGHT) then
        desired = 'walk_turn_r4'
    end

    -- NOTE: the weapon-specific "lying prone holding rifle/pistol" dive pose
    -- (mech_weapons_core@base@dive@.../prone) was tried here for a nicer idle visual, but it kept
    -- sinking the ped into the ground (that clip carries its own baked root motion - it wasn't
    -- authored to be a standalone rooted idle). Reverted to plain mech_crawl@base 'idle', exactly
    -- like the original reference script, which is properly grounded and doesn't drift.
    if desired ~= crawlAnimTarget or not IsEntityPlayingAnim(ped, CRAWL_DICT, desired, 3) then
        local isTurn = desired == 'walk_turn_l4' or desired == 'walk_turn_r4'
        -- The reference script's original blend speed (1.0) is slow - fine on its own, but too
        -- slow to fully settle within the fade-mask window used when returning from aim, so the
        -- idle pose specifically blends in fast (8.0) instead. Movement clips keep the original
        -- slow blend since those aren't covered by the fade mask anyway.
        local blendSpeed = (desired == 'idle') and 8.0 or 1.0
        TaskPlayAnim(ped, CRAWL_DICT, desired, blendSpeed, blendSpeed, isTurn and 1500 or -1, 1, 0, false, false, false)
        crawlAnimTarget = desired
    end
    SetPedPositionFrozen(ped, desired == 'idle')

    return desired == 'idle'
end

-- Optional recovery pose after a backward dodge. No-ops until you supply a real
-- anim dict/name in config.lua - left as a clearly marked hook rather than a guess.
function TrySwitchToSit(ped)
    if not (Config.Dive.SitAnimDict and Config.Dive.SitAnimName) then
        return
    end

    RequestAnimDict(Config.Dive.SitAnimDict)
    local tries = 0
    while not HasAnimDictLoaded(Config.Dive.SitAnimDict) and tries < 100 do
        Wait(0)
        tries = tries + 1
    end

    if HasAnimDictLoaded(Config.Dive.SitAnimDict) then
        TaskPlayAnim(ped, Config.Dive.SitAnimDict, Config.Dive.SitAnimName, 2.0, -2.0, -1, 1, 0.0, false, false, false)
    end
end

local function DoDive(ped)
    if diveActive then return end
    diveActive = true
    diveEndAt = GetGameTimer() + Config.Dive.RecoveryTimeMs

    local moveX = GetControlNormal(0, CONTROL_MOVE_LR)
    local moveY = GetControlNormal(0, CONTROL_MOVE_UD)
    if moveX == 0.0 and moveY == 0.0 then
        moveY = -1.0 -- no movement input held: default to dodging backward, like the vanilla dive
    end

    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)
    local worldX = (moveX * math.cos(rad)) - (moveY * math.sin(rad))
    local worldY = (moveX * math.sin(rad)) + (moveY * math.cos(rad))

    if Config.Dive.AnimDict and Config.Dive.AnimName then
        RequestAnimDict(Config.Dive.AnimDict)
        local tries = 0
        while not HasAnimDictLoaded(Config.Dive.AnimDict) and tries < 100 do
            Wait(0)
            tries = tries + 1
        end
        if HasAnimDictLoaded(Config.Dive.AnimDict) then
            TaskPlayAnim(ped, Config.Dive.AnimDict, Config.Dive.AnimName, 4.0, -4.0, Config.Dive.RecoveryTimeMs, Config.Dive.AnimFlag, 0.0, false, false, false)
        end
    end

    ApplyForceToEntity(
        ped, 1,
        worldX * Config.Dive.ForceMultiplier,
        worldY * Config.Dive.ForceMultiplier,
        0.15 * Config.Dive.ForceMultiplier,
        0.0, 0.0, 0.0,
        0, false, true, true, false, true
    )

    if moveY < -0.1 and not Config.DivingBackwardToOnBack and Config.DivingBackwardToSit then
        SetTimeout(Config.Dive.RecoveryTimeMs, function()
            TrySwitchToSit(PlayerPedId())
        end)
    end
end


DebugPrint('resource loaded - watching for CrawlToggle=0x' .. string.format('%X', Config.Keys.CrawlToggle) ..
    ', StealthToggle=0x' .. string.format('%X', Config.Keys.StealthToggle) ..
    ', SwitchToSit=0x' .. string.format('%X', Config.Keys.SwitchToSit))

CreateThread(function()
    while true do
        Wait(0)
        local ped = PlayerPedId()

        local crawlKeyDown = IsRawKeyDown(Config.Keys.CrawlToggle)
        if crawlKeyDown and not prevCrawlKeyDown then
            DebugPrint('CrawlToggle key detected pressed')
        end
        local crawlKeyJustPressed = crawlKeyDown and not prevCrawlKeyDown
        prevCrawlKeyDown = crawlKeyDown

        local stealthKeyDown = IsRawKeyDown(Config.Keys.StealthToggle)
        local stealthKeyJustPressed = stealthKeyDown and not prevStealthKeyDown
        prevStealthKeyDown = stealthKeyDown

        local sitKeyDown = IsRawKeyDown(Config.Keys.SwitchToSit)
        local sitKeyJustPressed = sitKeyDown and not prevSitKeyDown
        prevSitKeyDown = sitKeyDown

        -- Note: the previous IsInputDisabled(0)-based mission gate here was found to silently
        -- block everything below (its RDR3 semantics don't match what was assumed), so it has
        -- been removed. Config.DisableInputsIfMissionDisablesThem is currently not enforced.
        if diveActive and GetGameTimer() >= diveEndAt then
            diveActive = false
        end

        if crawlKeyJustPressed then
            if crawling then
                DebugPrint('stopping crawl')
                StopCrawling(ped)
            else
                DebugPrint('starting crawl')
                StartCrawling(ped)
            end
        end

        if crawling then
            local isAimingNow = IsAiming()
            if isAimingNow or IsControlPressed(0, CONTROL_ATTACK) then
                -- Hand control back to the game's own aim/fire task: our TaskPlayAnim pose would
                -- otherwise keep occupying the ped's main task and block aiming entirely, even
                -- with the ENABLE_PLAYER_CONTROL flag (tested - it still blocks aim/fire outright).
                -- Resumes the prone pose once Aim/Attack are released.
                if not aimingWhileCrawling then
                    -- Only mask with the fade when actually aiming with a scoped weapon - a plain
                    -- Attack-only press (blind-firing without aiming) still needs ClearPedTasks to
                    -- let the shot fire at all, but shouldn't black the screen for it, and neither
                    -- should aiming a non-scoped weapon (see IsCurrentWeaponScoped above).
                    aimSessionUsedFade = Config.Crawl.MaskStandUpWithFade and isAimingNow and IsCurrentWeaponScoped(ped)
                    if aimSessionUsedFade then
                        TryFadeOut(Config.Crawl.FadeOutMs)
                        WaitForFadeOutSimulatingDuck(Config.Crawl.FadeOutMs)
                    end
                    SetPedPositionFrozen(ped, false)
                    ClearPedTasks(ped)
                    aimingWhileCrawling = true
                    crawlAnimTarget = nil
                    UnlockFiringControls(ped)
                    TrySimulateDuck()
                    if aimSessionUsedFade then
                        WaitSimulatingDuck(Config.Crawl.HiddenHoldAimMs)
                        TryFadeIn(Config.Crawl.FadeInMs)
                    end
                end
                TrySimulateDuck()
                UnlockFiringControls(ped)
            else
                -- Mirror the aim-in fade on the way back down: mask the pop from standing back
                -- into the prone pose the same way, only on the release edge (not every tick), and
                -- only if the aim session that's ending actually used the fade going in.
                local wasAiming = aimingWhileCrawling
                local wasFaded = aimSessionUsedFade
                aimingWhileCrawling = false

                if wasAiming and wasFaded then
                    TryFadeOut(Config.Crawl.FadeOutMs)
                    Wait(Config.Crawl.FadeOutMs)
                end

                local isStationary = UpdateCrawlMovement(ped)
                if isStationary then
                    UnlockFiringControls(ped)
                else
                    DisableControlAction(0, CONTROL_ATTACK, true)
                    DisableControlAction(0, CONTROL_AIM, true)
                end

                if wasAiming and wasFaded then
                    Wait(Config.Crawl.HiddenHoldMs)
                    TryFadeIn(Config.Crawl.FadeInMs)
                end
            end
        elseif diveActive then
            UnlockFiringControls(ped)
        end

        if Config.OverrideDefaultCombatDive then
            -- Block the vanilla dive, but IsDisabledControl* still lets us read the press underneath it,
            -- so the player's existing "Dive" keybind keeps working - just with our custom behaviour instead.
            DisableControlAction(0, CONTROL_DIVE, true)

            if IsDisabledControlPressed(0, CONTROL_DIVE) then
                diveHeldSince = diveHeldSince or GetGameTimer()
                if (not diveActive) and (GetGameTimer() - diveHeldSince) >= Config.DiveHoldTimeMs then
                    if (not Config.EnableDiveOnlyWhenAiming) or IsAiming() then
                        DoDive(ped)
                    end
                end
            else
                diveHeldSince = nil
            end
        end

        if stealthKeyJustPressed and Config.StealthModeEnabled then
            stealthOn = not stealthOn
            if not stealthOn then
                SetPedStealthMovement(ped, false, 0)
            end
        end

        if sitKeyJustPressed then
            TrySwitchToSit(ped)
        end

        if stealthOn and Config.StealthModeEnabled then
            SetPedStealthMovement(ped, true, 0)
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if crawling then
        StopCrawling(PlayerPedId())
    end
    -- Defensive: make sure the player is never left stuck frozen if this fires in some edge case
    -- StopCrawling above didn't cover (e.g. state desync).
    if pedPositionFrozen then
        FreezeEntityPosition(PlayerPedId(), false)
        pedPositionFrozen = false
    end
end)
