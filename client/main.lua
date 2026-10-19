-- client/main.lua — Cyclone
-- The server owns where every cyclone is and who fell. The client builds the
-- deck as LOCAL objects (every client derives the same full grid), draws the
-- funnels, and applies the lift/spin/throw to the one car it owns — physics on
-- a networked car runs on its owner, so that is where the force has to go.

local EV       = "spz-cyclone:"
local HUD      = exports["spz-minigames"]
local CY       = Config.Cyclone

local active   = false
local alive    = false
local spectating = false
local state    = { phase = "build", alive = 0, total = 0, time = 0, funnels = 0 }
local tiles    = {}       -- object handles
local myVeh    = 0
local myBack, myBackH = nil, nil

-- Cyclones: `target` is the latest server position, `shown` is interpolated
-- toward it every frame so the funnel glides instead of stepping at 10 Hz.
local cyclones = {}       -- [i] = { tx, ty, x, y, r, base (obj), fx = {}, debris = {} }

RegisterNetEvent(EV .. "notify", function(msg, t)
    lib.notify({ description = msg, type = t or "info" })
end)

-- After a match everyone spawns at the hub's shared return point (DK garage).
local function returnPoint(ped)
    if GetResourceState("spz-minigames") == "started" then
        local ok, p = pcall(function() return exports["spz-minigames"]:ReturnPoint() end)
        if ok and p then return vector3(p.x, p.y, p.z), p.w end
    end
    return GetEntityCoords(ped), GetEntityHeading(ped)
end

local function loadModel(name)
    local hash = type(name) == "number" and name or GetHashKey(name)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local dl = GetGameTimer() + 10000
    while not HasModelLoaded(hash) and GetGameTimer() < dl do Wait(20) end
    return HasModelLoaded(hash) and hash or nil
end

-- ── Deck ────────────────────────────────────────────────────────────────────

local function placeObj(hash, x, y, z)
    local obj = CreateObjectNoOffset(hash, x, y, z, false, false, false)
    if obj == 0 then return nil end
    SetEntityCoordsNoOffset(obj, x, y, z, false, false, false)
    SetEntityRotation(obj, 0.0, 0.0, 0.0, 2, true)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    SetEntityDynamic(obj, false)
    SetEntityLodDist(obj, 1000)
    return obj
end

local function clearDeck()
    for _, obj in ipairs(tiles) do
        if DoesEntityExist(obj) then DeleteEntity(obj) end
    end
    tiles = {}
end

-- One section = one Color Rush tile (all the same colour). If that model is not
-- streamed (spz-colorrush stopped), a vanilla block is tiled n x n instead.
local function buildDeck()
    clearDeck()
    local hash = Config.TileModel and loadModel(Config.TileModel)
    if hash then
        local _, mx = GetModelDimensions(hash)
        local z = Config.Center.z - mx.z
        for iy = 0, Config.Grid - 1 do
            for ix = 0, Config.Grid - 1 do
                local x, y = Grid.tileCenter(ix, iy)
                local obj = placeObj(hash, x, y, z)
                if obj then tiles[#tiles + 1] = obj end
            end
        end
        return true
    end

    for _, name in ipairs(Config.TileProps or {}) do
        hash = loadModel(name)
        if hash then
            local mn, mx = GetModelDimensions(hash)
            local cap = Config.MaxPropsPerSide or 6
            local nx = math.min(cap, math.max(1, math.ceil(Config.TileSize / math.max(0.5, mx.x - mn.x))))
            local ny = math.min(cap, math.max(1, math.ceil(Config.TileSize / math.max(0.5, mx.y - mn.y))))
            local sx, sy, half = Config.TileSize / nx, Config.TileSize / ny, Config.TileSize * 0.5
            for iy = 0, Config.Grid - 1 do
                for ix = 0, Config.Grid - 1 do
                    local cx, cy = Grid.tileCenter(ix, iy)
                    for a = 0, nx - 1 do
                        for b = 0, ny - 1 do
                            local z = Config.Center.z - mx.z - (((a + b) % 2 == 0) and 0.0 or 0.03)
                            local obj = placeObj(hash, cx - half + (a + 0.5) * sx, cy - half + (b + 0.5) * sy, z)
                            if obj then tiles[#tiles + 1] = obj end
                        end
                    end
                end
                Wait(0)
            end
            return true
        end
    end
    lib.notify({ title = "CYCLONE", description = "The deck could not be built (no tile model loaded).", type = "error" })
    return false
end

-- ── Car ─────────────────────────────────────────────────────────────────────

local function claimCar(netId)
    if not netId then return 0 end
    local dl = GetGameTimer() + 8000
    while not NetworkDoesEntityExistWithNetworkId(netId) and GetGameTimer() < dl do Wait(50) end
    if not NetworkDoesEntityExistWithNetworkId(netId) then
        lib.notify({ title = "CYCLONE", description = "Your car failed to arrive", type = "error" })
        return 0
    end
    local veh = NetToVeh(netId)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    TaskWarpPedIntoVehicle(ped, veh, -1)
    dl = GetGameTimer() + 3000
    while GetPedInVehicleSeat(veh, -1) ~= ped and GetGameTimer() < dl do Wait(20) end
    dl = GetGameTimer() + 3000
    while not NetworkHasControlOfEntity(veh) and GetGameTimer() < dl do
        NetworkRequestControlOfEntity(veh); Wait(20)
    end
    FreezeEntityPosition(veh, false)
    SetVehicleOnGroundProperly(veh)
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleNumberPlateText(veh, ("CY%03d"):format(math.random(0, 999)))
    if Config.CarInvincible then
        SetEntityInvincible(veh, true)
        SetVehicleCanBeVisiblyDamaged(veh, false)
        SetVehicleTyresCanBurst(veh, false)
        SetVehicleWheelsCanBreak(veh, false)
    end
    return veh
end

local function deleteCar()
    if myVeh ~= 0 and DoesEntityExist(myVeh) then
        SetEntityAsMissionEntity(myVeh, true, true)
        DeleteEntity(myVeh)
    end
    myVeh = 0
end

local function despawnFreeroamCar()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end
    local dl = GetGameTimer() + 1000
    while not NetworkHasControlOfEntity(veh) and GetGameTimer() < dl do
        NetworkRequestControlOfEntity(veh); Wait(0)
    end
    SetEntityAsMissionEntity(veh, true, true)
    DeleteVehicle(veh)
    if DoesEntityExist(veh) then DeleteEntity(veh) end
end

-- ── Funnel visuals ──────────────────────────────────────────────────────────
-- A funnel is: an invisible anchor prop at the base carrying looped smoke at
-- several heights, a spiral of ground/air rings drawn every frame, and a few
-- bits of local debris orbiting it. All local, nothing networked.

local DEBRIS = { "prop_rub_tyre_03", "prop_cardbordbox_02a", "prop_rub_carpart_02", "prop_bin_04a", "prop_rub_boxpile_04",
                 "prop_rub_carpart_04", "prop_rub_wheel_01", "prop_rub_carpart_05", "prop_cs_cardbox_01" }
local SMOKE  = { asset = "core", name = "exp_grd_bzgas_smoke" }
local DUST   = { asset = "core", name = "exp_grd_grenade_smoke" }   -- churned-up ground dust
local ROCKS  = { asset = "core", name = "ent_dst_rocks" }           -- debris kicked off the deck
local STEAM  = { asset = "core", name = "ent_sht_steam" }           -- vortex wisps (spinning rings)
local SPARKS = { asset = "core", name = "ent_amb_sparking_wires" }  -- electric sparks in the funnel

local function spawnFunnel(c)
    local anchorHash = loadModel("prop_golf_ball")
    if anchorHash then
        c.base = CreateObjectNoOffset(anchorHash, c.x, c.y, Config.Center.z, false, false, false)
        SetEntityVisible(c.base, false, false)
        SetEntityCollision(c.base, false, false)
        FreezeEntityPosition(c.base, true)
        RequestNamedPtfxAsset(SMOKE.asset)
        local dl = GetGameTimer() + 3000
        while not HasNamedPtfxAssetLoaded(SMOKE.asset) and GetGameTimer() < dl do Wait(0) end
        c.fx = {}
        for i = 0, 9 do   -- deck to ~45 m
            UseParticleFxAssetNextCall(SMOKE.asset)
            local fx = StartParticleFxLoopedOnEntity(SMOKE.name, c.base, 0.0, 0.0, i * 4.5, 0.0, 0.0, 0.0,
                1.2 + i * 0.5, false, false, false)
            if fx and fx ~= 0 then
                SetParticleFxLoopedColour(fx, 0.45, 0.45, 0.5, false)
                c.fx[#c.fx + 1] = fx
            end
        end
        -- a ring of dust churning around where the funnel touches the deck
        for i = 0, 5 do
            local a = i / 6 * math.pi * 2
            UseParticleFxAssetNextCall(DUST.asset)
            local fx = StartParticleFxLoopedOnEntity(DUST.name, c.base, math.cos(a) * 3.5, math.sin(a) * 3.5, 0.3,
                0.0, 0.0, 0.0, 2.2, false, false, false)
            if fx and fx ~= 0 then
                SetParticleFxLoopedColour(fx, 0.55, 0.5, 0.45, false)
                c.fx[#c.fx + 1] = fx
            end
        end
    end
    -- Vortex: wisps at three heights on a second anchor that the draw loop
    -- spins every frame, so they visibly swirl around the funnel.
    if anchorHash then
        c.spin = CreateObjectNoOffset(anchorHash, c.x, c.y, Config.Center.z, false, false, false)
        SetEntityVisible(c.spin, false, false)
        SetEntityCollision(c.spin, false, false)
        FreezeEntityPosition(c.spin, true)
        RequestNamedPtfxAsset(STEAM.asset)
        local dl = GetGameTimer() + 3000
        while not HasNamedPtfxAssetLoaded(STEAM.asset) and GetGameTimer() < dl do Wait(0) end
        local r = CY.Radius * 0.6
        for ring, hgt in ipairs({ 3.0, 11.0, 20.0 }) do
            for j = 0, 3 do
                local a = (j / 4 + ring * 0.13) * math.pi * 2
                local rr = r * (0.8 + ring * 0.25)
                UseParticleFxAssetNextCall(STEAM.asset)
                local fx = StartParticleFxLoopedOnEntity(STEAM.name, c.spin, math.cos(a) * rr, math.sin(a) * rr, hgt,
                    0.0, 0.0, 0.0, 2.5 + ring * 0.6, false, false, false)
                if fx and fx ~= 0 then
                    SetParticleFxLoopedColour(fx, 0.6, 0.62, 0.68, false)
                    c.fx[#c.fx + 1] = fx
                end
            end
        end
    end

    c.debris = {}
    for i = 1, 20 do
        local h = loadModel(DEBRIS[(i % #DEBRIS) + 1])
        if h then
            local o = CreateObjectNoOffset(h, c.x, c.y, Config.Center.z + 2.0, false, false, false)
            SetEntityCollision(o, false, false)
            FreezeEntityPosition(o, true)
            c.debris[#c.debris + 1] = { obj = o, a = i * 0.63, h = 1.0 + (i * 2.7) % 24.0, sp = 2.0 + (i % 3) }
        end
    end
end

local function removeFunnel(c)
    for _, fx in ipairs(c.fx or {}) do StopParticleFxLooped(fx, false) end
    for _, d in ipairs(c.debris or {}) do if DoesEntityExist(d.obj) then DeleteEntity(d.obj) end end
    if c.base and DoesEntityExist(c.base) then DeleteEntity(c.base) end
    if c.spin and DoesEntityExist(c.spin) then DeleteEntity(c.spin) end
end

local function clearFunnels()
    for _, c in ipairs(cyclones) do removeFunnel(c) end
    cyclones = {}
end

RegisterNetEvent(EV .. "cyclones", function(list)
    if not active then return end
    for i, s in ipairs(list) do
        local c = cyclones[i]
        if not c then
            c = { x = s.x, y = s.y }
            cyclones[i] = c
            CreateThread(function() spawnFunnel(c) end)
        end
        c.tx, c.ty, c.r = s.x, s.y, s.r
    end
end)

-- ── Storm FX ────────────────────────────────────────────────────────────────

-- Lightning strikes every few seconds for the whole match.
CreateThread(function()
    while true do
        if active then
            Wait(math.random(3000, 8000))
            if active then
                ForceLightningFlash()
                ShakeGameplayCam("SMALL_EXPLOSION_SHAKE", 0.08)
            end
        else
            Wait(500)
        end
    end
end)

-- Rocks and debris bursting off the deck where each funnel touches down.
CreateThread(function()
    while true do
        if active and #cyclones > 0 then
            RequestNamedPtfxAsset(ROCKS.asset)
            RequestNamedPtfxAsset(SPARKS.asset)
            for _, c in ipairs(cyclones) do
                local r = c.r or CY.Radius
                if HasNamedPtfxAssetLoaded(ROCKS.asset) then
                    -- one off the deck, one thrown out of the funnel higher up
                    for _, h in ipairs({ 0.2, 4.0 + math.random() * 16.0 }) do
                        local a, d = math.random() * math.pi * 2, r * (0.4 + math.random() * 0.7)
                        UseParticleFxAssetNextCall(ROCKS.asset)
                        StartParticleFxNonLoopedAtCoord(ROCKS.name, c.x + math.cos(a) * d, c.y + math.sin(a) * d,
                            Config.Center.z + h, 0.0, 0.0, 0.0, h > 1.0 and 2.6 or 2.0, false, false, false)
                    end
                end
                -- electric sparks crackling inside the funnel
                if HasNamedPtfxAssetLoaded(SPARKS.asset) and math.random() < 0.55 then
                    local a = math.random() * math.pi * 2
                    UseParticleFxAssetNextCall(SPARKS.asset)
                    StartParticleFxNonLoopedAtCoord(SPARKS.name, c.x + math.cos(a) * r * 0.3, c.y + math.sin(a) * r * 0.3,
                        Config.Center.z + 2.0 + math.random() * 20.0, 0.0, 0.0, 0.0, 2.2, false, false, false)
                end
            end
            Wait(250)
        else
            Wait(500)
        end
    end
end)

-- Rumble: the camera shakes harder the closer the nearest funnel is.
local rumbling = false
CreateThread(function()
    while true do
        if active and #cyclones > 0 then
            local me = GetEntityCoords(PlayerPedId())
            local best = math.huge
            local r = CY.Radius
            for _, c in ipairs(cyclones) do
                local d = #(vector2(me.x, me.y) - vector2(c.x, c.y))
                if d < best then best, r = d, c.r or CY.Radius end
            end
            local reach = r * 4.0
            if best < reach then
                if not rumbling then ShakeGameplayCam("ROAD_VIBRATION_SHAKE", 0.1); rumbling = true end
                SetGameplayCamShakeAmplitude(0.15 + 1.6 * (1.0 - best / reach))
            elseif rumbling then
                StopGameplayCamShaking(false); rumbling = false
            end
            Wait(100)
        else
            if rumbling then StopGameplayCamShaking(false); rumbling = false end
            Wait(500)
        end
    end
end)

-- Draw + glide every frame.
CreateThread(function()
    while true do
        if active and #cyclones > 0 then
            local t = GetGameTimer() / 1000.0
            local z0 = Config.Center.z
            for _, c in ipairs(cyclones) do
                if c.tx then
                    c.x = c.x + (c.tx - c.x) * 0.08
                    c.y = c.y + (c.ty - c.y) * 0.08
                end
                local r = c.r or CY.Radius
                if c.base and DoesEntityExist(c.base) then SetEntityCoordsNoOffset(c.base, c.x, c.y, z0, false, false, false) end
                if c.spin and DoesEntityExist(c.spin) then
                    SetEntityCoordsNoOffset(c.spin, c.x, c.y, z0, false, false, false)
                    SetEntityHeading(c.spin, (t * 220.0) % 360.0)
                end

                -- Spiral funnel: rings widen with height and twist over time.
                for k = 0, 11 do
                    local hgt = k * 3.0
                    local rr = r * (0.35 + k * 0.12)
                    local off = math.sin(t * 2.0 + k * 0.6) * (k * 0.25)
                    DrawMarker(25, c.x + off, c.y + math.cos(t * 2.0 + k * 0.6) * (k * 0.25), z0 + 0.15 + hgt,
                        0.0, 0.0, 0.0, 0.0, 0.0, t * 120.0 + k * 25.0, rr * 2.0, rr * 2.0, 1.0,
                        150, 150, 165, k == 0 and 160 or 70, false, false, 2, false, nil, nil, false)
                end
                -- Danger circle on the deck.
                DrawMarker(1, c.x, c.y, z0 - 0.4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r * 2.0, r * 2.0, 0.8,
                    220, 60, 60, 60, false, false, 2, false, nil, nil, false)

                for _, d in ipairs(c.debris or {}) do
                    d.a = d.a + d.sp * GetFrameTime()
                    local rr = r * (0.4 + d.h / 30.0)
                    if DoesEntityExist(d.obj) then
                        SetEntityCoordsNoOffset(d.obj, c.x + math.cos(d.a) * rr, c.y + math.sin(d.a) * rr,
                            z0 + d.h + math.sin(t + d.a) * 1.5, false, false, false)
                        SetEntityRotation(d.obj, t * 90.0, t * 60.0, t * 140.0, 2, true)
                    end
                end
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- ── Physics on my own car ───────────────────────────────────────────────────
-- Outside PullRange: nothing. Inside it: dragged toward the funnel. Inside the
-- funnel radius: caught — spun round and lifted until LiftHeight or MaxHoldSec,
-- then flung outward. A thrown car is immune for a moment so it actually flies.

local caughtAt, immuneUntil, nearest = nil, 0, nil

local function closestCyclone(p)
    local best, bd = nil, math.huge
    for _, c in ipairs(cyclones) do
        local d = #(vector2(p.x, p.y) - vector2(c.x, c.y))
        if d < bd then best, bd = c, d end
    end
    return best, bd
end

CreateThread(function()
    while true do
        if active and alive and not spectating and state.phase == "live" and myVeh ~= 0 and DoesEntityExist(myVeh) then
            local now = GetGameTimer()
            local p = GetEntityCoords(myVeh)
            local c, d = closestCyclone(p)
            nearest = c and d or nil
            if c and now >= immuneUntil then
                local r = c.r or CY.Radius
                local dx, dy = p.x - c.x, p.y - c.y
                local len = math.max(0.01, math.sqrt(dx * dx + dy * dy))
                local nx, ny = dx / len, dy / len              -- outward
                local tx, ty = -ny, nx                          -- tangent (counter-clockwise)
                local v = GetEntityVelocity(myVeh)

                if d < r or caughtAt then
                    caughtAt = caughtAt or now
                    local held = (now - caughtAt) / 1000
                    local high = p.z - Config.Center.z
                    if high >= CY.LiftHeight or held >= CY.MaxHoldSec then
                        -- Throw.
                        SetEntityVelocity(myVeh,
                            nx * CY.ThrowSpeed + tx * CY.SpinSpeed * 0.5,
                            ny * CY.ThrowSpeed + ty * CY.SpinSpeed * 0.5,
                            CY.ThrowUp)
                        caughtAt = nil
                        immuneUntil = now + math.floor(CY.Immunity * 1000)
                        PlaySoundFrontend(-1, "Hit_In", "PLAYER_SWITCH_CUSTOM_SOUNDSET", true)
                    else
                        -- Spin + lift, with a little pull in so it stays in the funnel.
                        local want = vector3(tx * CY.SpinSpeed - nx * 3.0, ty * CY.SpinSpeed - ny * 3.0, CY.LiftSpeed)
                        SetEntityVelocity(myVeh, v.x + (want.x - v.x) * 0.25, v.y + (want.y - v.y) * 0.25, v.z + (want.z - v.z) * 0.25)
                        SetEntityAngularVelocity(myVeh, 0.0, 0.0, 4.0)
                        ShakeGameplayCam("SMALL_EXPLOSION_SHAKE", 0.06)
                    end
                elseif d < r * CY.PullRange then
                    local k = 1.0 - (d - r) / (r * (CY.PullRange - 1.0))   -- 0 at edge, 1 at funnel
                    local pull = CY.PullForce * k * GetFrameTime() * 2.0
                    SetEntityVelocity(myVeh, v.x - nx * pull + tx * pull * 0.6, v.y - ny * pull + ty * pull * 0.6, v.z)
                end
            end
            Wait(0)
        else
            caughtAt, nearest = nil, nil
            Wait(200)
        end
    end
end)

-- ── Spectate / cleanup ──────────────────────────────────────────────────────

local function enterSpectate()
    if spectating then return end
    spectating = true
    deleteCar()
    local ped = PlayerPedId()
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    SetEntityCoords(ped, Config.Center.x, Config.Center.y - 30.0, Config.Center.z + 50.0, false, false, false, false)
    FreezeEntityPosition(ped, true)
end

-- ── Thunderstorm for the match ──────────────────────────────────────────────
-- spz-core owns the weather (its scene override keeps re-asserting it). We tell
-- it AND apply the storm ourselves, and keep re-applying it while the match
-- runs, so the storm shows even with an older spz-core that doesn't know the
-- scene event. On the way out the synced weather is put back explicitly.
local storm = false
local function applyWeatherNow(w)
    SetWeatherTypeOvertimePersist(w, 2.0)
    SetWeatherTypePersist(w)
    SetWeatherTypeNowPersist(w)
    SetWeatherTypeNow(w)
    SetOverrideWeather(w)
end

local function stormOn()
    storm = true
    TriggerEvent("spz:sceneWeather", "THUNDER")
    applyWeatherNow("THUNDER")
    SetRainLevel(0.9)
    SetWindSpeed(12.0)
    SetWind(1.0)
end

local function stormOff()
    if not storm then return end
    storm = false
    TriggerEvent("spz:sceneWeather", nil)
    SetRainLevel(-1.0)                         -- back to the weather's own rain
    SetWindSpeed(-1.0)
    ClearOverrideWeather()
    ClearWeatherTypePersist()
    applyWeatherNow(GlobalState.envWeather or "EXTRASUNNY")
end

-- Keep the storm for the whole match: other scripts (spz-core's sync, a weather
-- sync resource on the server) may set the weather back, so every second the
-- current AND upcoming weather are checked and the storm is put back, and the
-- rain/wind are re-applied (they are reset by weather changes too).
local THUNDER = GetHashKey("THUNDER")
CreateThread(function()
    while true do
        Wait(1000)
        if storm then
            if GetPrevWeatherTypeHashName() ~= THUNDER or GetNextWeatherTypeHashName() ~= THUNDER then
                applyWeatherNow("THUNDER")
            end
            SetRainLevel(0.9)
            SetWindSpeed(12.0)
            SetWind(1.0)
        end
    end
end)

local function cleanup()
    stormOff()                               -- weather back to normal
    active, alive, spectating = false, false, false
    caughtAt, immuneUntil = nil, 0
    HUD:Hud(nil)
    TriggerServerEvent("spz:setPlayerFlag", "inMinigame", false)
    TriggerEvent("spz:minigameChanged")
    clearFunnels()
    clearDeck()
    deleteCar()

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetEntityInvincible(ped, false)
    if myBack then
        SetEntityCoords(ped, myBack.x, myBack.y, myBack.z, false, false, false, false)
        if myBackH then SetEntityHeading(ped, myBackH) end
        myBack = nil
    end
end

local function playClip(name)
    if GetResourceState("spz-raceUI") == "started" then
        local ok = pcall(function() exports["spz-raceUI"]:PlaySound(name, 1.0) end)
        if ok then return end
    end
    PlaySoundFrontend(-1, name == "go" and "GO" or "3_2_1", "HUD_MINI_GAME_SOUNDSET", true)
end

-- ── Round events ────────────────────────────────────────────────────────────

RegisterNetEvent(EV .. "start", function(d)
    -- thunderstorm for the whole match (spz-core scene weather; cleared in cleanup)
    stormOn()
    DoScreenFadeOut(300)
    Wait(300)

    active, alive, spectating = true, true, false
    state = { phase = "build", alive = 0, total = 0, time = 0, funnels = 0 }
    TriggerServerEvent("spz:setPlayerFlag", "inMinigame", "Cyclone")
    TriggerEvent("spz:minigameChanged")

    local ped = PlayerPedId()
    myBack, myBackH = returnPoint(ped)
    despawnFreeroamCar()
    ped = PlayerPedId()

    SetEntityCoords(ped, d.spawn.x, d.spawn.y, d.spawn.z + 2.0, false, false, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    ClearPedTasksImmediately(ped)
    SetEntityCollision(ped, true, true)
    ResetEntityAlpha(ped)

    if not buildDeck() then DoScreenFadeIn(300); return end
    Wait(250)
    TriggerServerEvent(EV .. "ready")

    lib.notify({ title = "CYCLONE", description = "Stay on the deck. If the cyclone catches you, it throws you off.",
                 type = "inform", duration = 6000 })
    DoScreenFadeIn(500)
end)

RegisterNetEvent(EV .. "car", function(d)
    if not active then return end
    myVeh = claimCar(d.netId)
    if myVeh == 0 then FreezeEntityPosition(PlayerPedId(), false) end
end)

RegisterNetEvent(EV .. "countdown", function(n)
    if not active then return end
    HUD:Flash(tostring(n), nil, 900)
    playClip("countdown")
end)

RegisterNetEvent(EV .. "go", function()
    if not active then return end
    state.phase = "live"
    HUD:Flash("GO", "ok", 900)
    playClip("go")
end)

RegisterNetEvent(EV .. "eliminated", function(d)
    if not active then return end
    alive = false
    lib.notify({ title = "THROWN OFF", description = d.why or "out", type = "error", duration = 5000 })
end)

RegisterNetEvent(EV .. "spectate", function()
    if active and not alive then enterSpectate() end
end)

RegisterNetEvent(EV .. "feed", function(d)
    lib.notify({ description = ("%s — %s"):format(d.name or "A player", d.why or "out"), type = "inform", duration = 2500 })
end)

RegisterNetEvent(EV .. "state", function(s)
    state = s
    if s.me ~= nil then alive = s.me end
end)

-- ── Rounds ──────────────────────────────────────────────────────────────────

RegisterNetEvent(EV .. "roundOver", function(d)
    if not active then return end
    local you = d.winner and d.winner == GetPlayerName(PlayerId())
    local lines = {}
    for i, st in ipairs(d.standings or {}) do
        if i > 4 then break end
        lines[#lines + 1] = ("%s %d"):format(st.name, st.wins)
    end
    HUD:Shard(("Round %d / %d"):format(d.round or 0, d.rounds or 0),
        (d.winner and (d.winner .. " takes it") or "Nobody left standing") .. (#lines > 0 and ("  ·  " .. table.concat(lines, "  ·  ")) or ""),
        you and "ok" or "accent", 4500)
end)

RegisterNetEvent(EV .. "clearCyclones", function()
    if active then clearFunnels() end
end)

-- next round: out of spectate, back onto the deck; the server makes the car
RegisterNetEvent(EV .. "respawn", function(d)
    if not active then return end
    DoScreenFadeOut(300)
    Wait(300)
    deleteCar()
    spectating, alive = false, true
    caughtAt, immuneUntil = nil, 0
    state.phase = "build"
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetEntityCoords(ped, d.spawn.x, d.spawn.y, d.spawn.z + 2.0, false, false, false, false)
    FreezeEntityPosition(ped, true)
    Wait(250)
    TriggerServerEvent(EV .. "ready")
    DoScreenFadeIn(500)
end)

RegisterNetEvent(EV .. "over", function(r)
    local secs = r.survived or 0
    local msg = ("%d of %d rounds won · %d:%02d on the deck"):format(r.roundWins or 0, r.rounds or 1, math.floor(secs / 60), secs % 60)
    if (r.payout or 0) > 0 then msg = msg .. (" · +%d credits"):format(r.payout) end
    DoScreenFadeOut(400)
    Wait(400)
    cleanup()
    HUD:Shard(r.won and "Match won" or "Match over", msg, r.won and "ok" or "accent", 7000)
    DoScreenFadeIn(600)
end)

-- ── HUD ─────────────────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if active then
            local t = state.time or 0
            local hud = { chips = {
                { text = ("Round %d / %d"):format(state.round or 1, state.rounds or 1), hot = true },
                ("%d / %d on deck"):format(state.alive or 0, state.total or 0),
                ("%d:%02d"):format(math.floor(t / 60), t % 60),
                { text = ("%d funnel%s"):format(state.funnels or 0, (state.funnels or 0) == 1 and "" or "s"),
                  hot = (state.funnels or 0) > 1 },
            } }
            if state.phase ~= "live" then
                hud.status = { label = "Get ready", value = "Cyclone", color = "dim" }
            end
            if alive and caughtAt then
                hud.alert = "CAUGHT — HOLD ON!"
            elseif alive and nearest and cyclones[1] and nearest < (CY.Radius * CY.PullRange * 1.3) then
                hud.alert = "CYCLONE CLOSE — DRIVE AWAY"
            end
            hud.board = state.board
            if not alive then hud.foot = { text = "Spectating", color = "bad" } end
            -- key bar (live bindings, resolved by spz-minigames)
            hud.keys = hud.keys or {}
            hud.keys[#hud.keys + 1] = { control = 200, default = "ESC", pad = "START_INDEX", label = "Menu · leave" }
            HUD:Hud(hud)
            Wait(100)
        else
            Wait(500)
        end
    end
end)

-- ── Queue menu (the hub is the main way in) ─────────────────────────────────

local function openLobbyMenu()
    local st = lib.callback.await(EV .. "lobbyState", false)
    if not st then return end
    if st.roundLive then
        lib.notify({ description = "Your room is mid-match.", type = "warning" })
        return
    end
    local options = {
        {
            title = st.inLobby and "Leave Room" or "Quick Join",
            icon = st.inLobby and "right-from-bracket" or "right-to-bracket",
            iconColor = st.inLobby and "#ff4d5e" or "#22c55e",
            onSelect = function()
                lib.callback.await(EV .. "joinToggle", false)
                openLobbyMenu()
            end,
        },
    }
    if st.inLobby and st.isHost then
        options[#options + 1] = {
            title = "Start match", icon = "play", disabled = st.count < st.min,
            description = st.count < st.min and ("Need %d players"):format(st.min) or nil,
            onSelect = function() lib.callback.await(EV .. "startRoom", false) end,
        }
    end
    options[#options + 1] = { title = ("── %s %d/%d ──"):format(st.room and st.room.name or "Room", st.count, st.max), disabled = true }
    for _, r in ipairs(st.roster or {}) do
        options[#options + 1] = { title = (r.host and "👑 " or "") .. (r.isMe and "★ " or "") .. r.name, disabled = true }
    end
    lib.registerContext({ id = "spz_cyclone_lobby", title = "🌪️ Cyclone", options = options })
    lib.showContext("spz_cyclone_lobby")
end

RegisterCommand(Config.MenuCommand, function() openLobbyMenu() end, false)
RegisterKeyMapping(Config.MenuCommand, "Cyclone queue menu", "keyboard", "")

RegisterNetEvent(EV .. "invited", function(d)
    -- Racing / queued / in another minigame: a dialog would grab mouse focus
    -- and lock the car mid-race. Just tell them; the invite is kept, so the
    -- room shows as invited in the hub once they are free.
    do
        local st = LocalPlayer.state
        if st.inRace or st.inQueue or st.inMinigame or st.inTimeTrial then
            lib.notify({ title = "Cyclone invite",
                description = ("%s invited you to %s — open the minigames hub when you're free."):format(d.fromName or "Someone", d.roomName or "their room"),
                type = "inform", duration = 7000 })
            return
        end
    end
    local resp = lib.alertDialog({
        header = "Cyclone Invite",
        content = ("**%s** invited you to **%s** (Cyclone)."):format(d.fromName or "Someone", d.roomName or "their room"),
        centered = true, cancel = true,
        labels = { cancel = "Dismiss", confirm = "Join" },
    })
    if resp == "confirm" then TriggerServerEvent(EV .. "acceptInvite", d.room) end
end)

AddEventHandler("spz:leaveMinigame", function()
    if active then TriggerServerEvent(EV .. "leave") end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() and active then cleanup() end
end)
