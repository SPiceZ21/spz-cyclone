-- server/main.lua — Cyclone
-- Rooms -> one round on a full deck -> a roaming cyclone lifts cars and throws
-- them off. The server owns where the cyclones are and reads every player's
-- real coords to decide who fell, so elimination is never client-trusted. The
-- deck is built client-side as local objects; the lift/throw is applied by
-- each client to the car it owns.
--
-- Room / lobby / invite code is shared with spz-colorrush.

local Log = SPZ and SPZ.Logger and SPZ.Logger("spz-cyclone") or nil
local function log(m) if Log then Log.info(m) else print("[cyclone] " .. m) end end

local EV = "spz-cyclone:"

local Rooms = {}         -- [id] = { id, name, host, private, max, members = { [src] = { pid, name } }, armed, armedAt, round }
local RoomOf = {}        -- [src] = room
local Invites = {}       -- [src] = { [roomId] = true, last = roomId }
local nextRoomId = 1

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function notify(src, msg, t)
    TriggerClientEvent(EV .. "notify", src, msg, t or "info")
end

local function pidOf(src)
    local ok, p = pcall(function() return exports["spz-identity"]:GetProfile(src) end)
    return ok and p and p.id or nil, ok and p or nil
end

local function nameOf(src)
    local _, prof = pidOf(src)
    return (prof and prof.username) or GetPlayerName(src) or ("Racer" .. src)
end

local function srcFromPid(pid)
    for _, s in ipairs(GetPlayers()) do
        if pidOf(tonumber(s)) == pid then return tonumber(s) end
    end
    return nil
end

local function payPid(pid, amt, reason)
    if not pid or amt <= 0 then return end
    local s = srcFromPid(pid)
    if s and GetResourceState("spz-progression") == "started" then
        exports["spz-progression"]:GrantBonus(s, { credits = amt, reason = reason })
    else
        MySQL.update.await("UPDATE players SET credits = credits + ? WHERE id = ?", { amt, pid })
    end
end

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

local function shuffle(t)
    for i = #t, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end
end

local function roundOf(src)
    local room = RoomOf[src]
    local r = room and room.round
    return (r and r.players[src]) and r or nil
end

local function toAll(r, event, payload)
    if not r then return end
    for src in pairs(r.players) do TriggerClientEvent(event, src, payload) end
end

local function aliveList(r)
    local out = {}
    if not r then return out end
    for src, p in pairs(r.players) do
        if p.alive then out[#out + 1] = src end
    end
    return out
end

-- spz-core ghosts every player unless BOTH carry `spz:contact`; round players
-- get it so their cars actually shove each other.
local function setContact(src, on)
    if GetPlayerName(src) then Player(src).state:set("spz:contact", on or nil, true) end
end

-- Cars are created HERE: spz-core buckets run strict entity lockdown and delete
-- networked entities a client creates.
local function spawnCarFor(_, bucketId, x, y, z, heading)
    local pool = Config.Cars or { "blista" }
    local model = pool[math.random(#pool)]
    local veh = CreateVehicleServerSetter(joaat(model), "automobile", x, y, z, heading or 0.0)
    local dl = GetGameTimer() + 3000
    while veh ~= 0 and not DoesEntityExist(veh) and GetGameTimer() < dl do Wait(0) end
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    if bucketId ~= 0 then SetEntityRoutingBucket(veh, bucketId) end
    SetEntityOrphanMode(veh, 2)
    return veh
end

local function deleteCar(p)
    if p and p.veh and DoesEntityExist(p.veh) then DeleteEntity(p.veh) end
    if p then p.veh = nil end
end

local function eliminate(r, src, why)
    local p = r and r.players[src]
    if not p or not p.alive then return end
    p.alive = false
    p.outAt = GetGameTimer()
    TriggerClientEvent(EV .. "eliminated", src, { why = why })
    toAll(r, EV .. "feed", { name = p.name, why = why })
end

-- ── Round ───────────────────────────────────────────────────────────────────
-- One round, no waves: everyone on a full deck, the cyclone(s) roam until one
-- car is left. The server owns where every cyclone is and who fell; the lift
-- and throw are applied by each client to its own car (see client/main.lua).

-- Bank this round's time on the deck for everyone (survival bonus is paid on
-- the total across all rounds).
local function bankRound(r)
    if not r.liveAt then return end
    local now = GetGameTimer()
    for _, p in pairs(r.players) do
        if not p.left then
            p.surviveSec = (p.surviveSec or 0) + math.max(0, math.floor(((p.outAt or now) - r.liveAt) / 1000))
        end
    end
    r.liveAt = nil
end

-- Match over (after Config.Rounds rounds): the most round wins takes
-- WinReward (split on a tie); everyone gets SurvivalPerMin for every full
-- minute they stayed on the deck across all rounds. Then everyone home.
local function endRound(r, why)
    if not r or not r.active then return end
    bankRound(r)
    r.active = false
    r.phase = "over"
    if r.room.round == r then r.room.round = nil end

    local best = 0
    for _, p in pairs(r.players) do if not p.left then best = math.max(best, p.roundWins or 0) end end
    local winners = {}
    for _, p in pairs(r.players) do
        if not p.left and best > 0 and (p.roundWins or 0) == best then winners[#winners + 1] = p end
    end

    for src, p in pairs(r.players) do
        deleteCar(p)
        setContact(src, false)
        p.survived = p.surviveSec or 0
        local won = not p.left and best > 0 and (p.roundWins or 0) == best
        local total = math.floor(p.survived / 60) * (Config.SurvivalPerMin or 0)
        if won then total = total + math.floor((Config.WinReward or 0) / math.max(1, #winners)) end
        if total > 0 then payPid(p.pid, total, "Cyclone") end
        if not p.left then
            TriggerClientEvent(EV .. "over", src, {
                won = won, payout = total, survived = p.survived,
                survivors = #winners, reason = why,
                roundWins = p.roundWins or 0, rounds = r.roundNo or 1,
            })
        end
    end

    SetTimeout(1500, function()
        if r.bucketId and r.bucketId ~= 0 and GetResourceState("spz-core") == "started" then
            exports["spz-core"]:DeleteBucket(r.bucketId)
        end
    end)
    SetTimeout(4000, function()
        if Rooms[r.room.id] ~= r.room then return end
        -- Match over: the room closes and everyone is out of the lobby.
        Rooms[r.room.id] = nil
        for s in pairs(r.room.members) do
            RoomOf[s] = nil
            if GetPlayerName(s) then Player(s).state:set("mgRoom", nil, true) end
            notify(s, "Match over — you left the room. Open the hub to play again.")
        end
    end)

    pcall(function()
        local who = (#winners == 1) and winners[1].name or (#winners .. " winners")
        exports["spz-log"]:Log("minigame", "Cyclone", ("%s — %s (%s)"):format(who, why, r.room.name), "success")
    end)
    log(("room %d match over: %s"):format(r.room.id, why))
end

-- ── Rounds ──────────────────────────────────────────────────────────────────
local restartRound   -- defined with the spawn helpers below
local finishRound

-- One round is over (one car left, or none). Last car standing takes the
-- round; after Config.Rounds rounds the match ends on round wins.
finishRound = function(r, winnerSrc)
    if r.phase ~= "live" then return end
    r.phase = "between"
    bankRound(r)
    local wp = winnerSrc and r.players[winnerSrc]
    if wp then wp.roundWins = (wp.roundWins or 0) + 1 end
    local rounds = Config.Rounds or 1
    log(("room %d round %d/%d: %s"):format(r.room.id, r.roundNo or 1, rounds, wp and wp.name or "nobody"))

    if (r.roundNo or 1) >= rounds then
        endRound(r, wp and (wp.name .. " took the last round") or "everyone was thrown off")
        return
    end

    local standings = {}
    for _, p in pairs(r.players) do
        if not p.left then standings[#standings + 1] = { name = p.name, wins = p.roundWins or 0 } end
    end
    table.sort(standings, function(a, b) return a.wins > b.wins end)
    toAll(r, EV .. "roundOver", { round = r.roundNo or 1, rounds = rounds, winner = wp and wp.name or nil, standings = standings })
    r.cyclones = {}
    toAll(r, EV .. "clearCyclones", {})

    CreateThread(function()
        Wait(5000)
        if r.active then restartRound(r) end
    end)
end

local function eachRound(fn)
    for _, room in pairs(Rooms) do
        if room.round and room.round.active then fn(room.round) end
    end
end

-- ── Fall watcher ────────────────────────────────────────────────────────────
-- The only way out is falling off the deck. Server reads real coords, so
-- nothing about elimination is client-trusted.
local FALL_DROP = 6.0   -- metres below the deck that count as fallen
CreateThread(function()
    while true do
        Wait(200)
        eachRound(function(r)
            if r.phase ~= "live" then return end
            for src, p in pairs(r.players) do
                if not p.spectating and not p.left then
                    local ped = GetPlayerPed(src)
                    local fallen = false
                    if ped ~= 0 then
                        local veh = GetVehiclePedIsIn(ped) or 0
                        local ent = (veh ~= 0 and DoesEntityExist(veh)) and veh or ped
                        fallen = GetEntityCoords(ent).z < (Config.Center.z - FALL_DROP)
                    end
                    if p.alive and fallen then eliminate(r, src, "thrown off the deck") end
                    if not p.alive and (fallen or GetGameTimer() - (p.outAt or 0) > 1500) then
                        p.spectating = true
                        TriggerClientEvent(EV .. "spectate", src)
                    end
                end
            end

            local alive = aliveList(r)
            local present = 0
            for _, p in pairs(r.players) do if not p.left then present = present + 1 end end
            if present < 2 then
                endRound(r, "not enough players left")
            elseif #alive <= 1 then
                finishRound(r, alive[1])
            end
        end)
    end
end)

-- ── Cyclones ────────────────────────────────────────────────────────────────

local function deckRadius() return Grid.span() * 0.5 end

-- A random point on the deck, kept inside so the funnel stays over the tiles.
local function randomPoint()
    local half = deckRadius() * 0.8
    return Config.Center.x + (math.random() * 2 - 1) * half,
           Config.Center.y + (math.random() * 2 - 1) * half
end

-- Sometimes the cyclone hunts: aims at a random living car instead of a random spot.
local function pickTarget(r)
    if math.random() < (Config.Cyclone.ChaseChance or 0.4) then
        local alive = aliveList(r)
        if #alive > 0 then
            local ped = GetPlayerPed(alive[math.random(#alive)])
            if ped ~= 0 then
                local c = GetEntityCoords(ped)
                local half = deckRadius() * 0.9
                return math.max(Config.Center.x - half, math.min(Config.Center.x + half, c.x)),
                       math.max(Config.Center.y - half, math.min(Config.Center.y + half, c.y))
            end
        end
    end
    return randomPoint()
end

local function newCyclone(r)
    local x, y = randomPoint()
    local c = { x = x, y = y }
    c.tx, c.ty = pickTarget(r)
    r.cyclones[#r.cyclones + 1] = c
    return c
end

-- Intensity grows every RampEverySec: faster, wider, and from SecondAtSec a
-- second funnel joins, so a match always ends.
local function intensity(r)
    local cfg = Config.Cyclone
    local t = (GetGameTimer() - (r.liveAt or GetGameTimer())) / 1000
    local steps = math.floor(t / (cfg.RampEverySec or 30))
    return math.min(cfg.MaxSpeed, cfg.Speed + steps * cfg.SpeedStep),
           math.min(cfg.MaxRadius, cfg.Radius + steps * cfg.RadiusStep),
           t
end

local TICK = 100
CreateThread(function()
    while true do
        Wait(TICK)
        eachRound(function(r)
            if r.phase ~= "live" then return end
            local speed, radius, t = intensity(r)
            local want = (t >= (Config.Cyclone.SecondAtSec or 90)) and 2 or 1
            while #r.cyclones < want do
                newCyclone(r)
                toAll(r, EV .. "feed", { name = "Cyclone", why = "a second funnel touched down!" })
            end

            local step = speed * (TICK / 1000)
            local list = {}
            for i, c in ipairs(r.cyclones) do
                local dx, dy = c.tx - c.x, c.ty - c.y
                local d = math.sqrt(dx * dx + dy * dy)
                if d <= step then
                    c.x, c.y = c.tx, c.ty
                    c.tx, c.ty = pickTarget(r)
                else
                    -- a little wobble so it never moves in a dead-straight line
                    local wob = math.sin(GetGameTimer() / 700 + i) * 0.35
                    c.x = c.x + (dx / d) * step - (dy / d) * step * wob
                    c.y = c.y + (dy / d) * step + (dx / d) * step * wob
                end
                list[i] = { x = c.x, y = c.y, r = radius }
            end
            r.radius = radius
            toAll(r, EV .. "cyclones", list)
        end)
    end
end)

-- ── HUD state broadcast ─────────────────────────────────────────────────────

CreateThread(function()
    while true do
        Wait(250)
        eachRound(function(r)
            local alive = #aliveList(r)
            local total = 0
            local rows = {}
            local now = GetGameTimer()
            for src, p in pairs(r.players) do
                if not p.left then
                    total = total + 1
                    local secs = r.liveAt and math.floor(((p.outAt or now) - r.liveAt) / 1000) or 0
                    local w = p.roundWins or 0
                    rows[#rows + 1] = { src = src, name = p.name, out = not p.alive,
                        value = ("%d W"):format(w), valueColor = w > 0 and "ok" or "dim",
                        sub = ("%d:%02d this round"):format(math.floor(secs / 60), secs % 60), _w = w, _s = secs }
                end
            end
            table.sort(rows, function(a, b)
                if a._w ~= b._w then return a._w > b._w end
                if a.out ~= b.out then return not a.out end
                if a._s ~= b._s then return a._s > b._s end
                return a.name < b.name
            end)
            for _, row in ipairs(rows) do row._s, row._w = nil, nil end

            local secs = r.liveAt and math.floor((now - r.liveAt) / 1000) or 0
            for src, p in pairs(r.players) do
                TriggerClientEvent(EV .. "state", src, {
                    phase = r.phase, alive = alive, total = total, time = secs,
                    funnels = #r.cyclones, me = p.alive,
                    round = r.roundNo or 1, rounds = Config.Rounds or 1,
                    board = { title = "Still standing", rows = rows },
                })
            end
        end)
    end
end)

-- ── Rooms ───────────────────────────────────────────────────────────────────

local function roomMax(room) return room.max or Config.MaxPlayers end
local function disarm(room) room.armed, room.armedAt = false, nil end

local function spawnSpots()
    -- Ring of spots around the centre, so nobody starts inside the first funnel.
    local spots = {}
    for iy = 0, Config.Grid - 1 do
        for ix = 0, Config.Grid - 1 do
            local edge = math.min(ix, iy, Config.Grid - 1 - ix, Config.Grid - 1 - iy)
            if edge <= 1 then spots[#spots + 1] = { ix, iy } end
        end
    end
    shuffle(spots)
    return spots
end

restartRound = function(r)
    r.roundNo = (r.roundNo or 1) + 1
    r.cyclones, r.phase = {}, "build"
    local spots = spawnSpots()
    local n = 0
    for src, p in pairs(r.players) do
        if not p.left then
            n = n + 1
            deleteCar(p)
            p.alive, p.spectating, p.outAt = true, false, nil
            local sp = spots[((n - 1) % #spots) + 1]
            local tx, ty = Grid.tileCenter(sp[1], sp[2])
            p.heading = (math.deg(math.atan(Config.Center.y - ty, Config.Center.x - tx)) - 90.0) % 360.0
            p.spawn = vector3(tx, ty, Config.Center.z + 1.0)
            TriggerClientEvent(EV .. "respawn", src, { spawn = p.spawn, heading = p.heading, round = r.roundNo, rounds = Config.Rounds or 1 })
        end
    end
    Wait(3000)
    for c = 3, 1, -1 do
        if not r.active then return end
        toAll(r, EV .. "countdown", c)
        Wait(1000)
    end
    if not r.active then return end
    r.liveAt = GetGameTimer()
    r.phase = "live"
    newCyclone(r)
    toAll(r, EV .. "go", {})
end

local function startRound(room)
    disarm(room)
    if room.round then return end
    if count(room.members) < Config.MinPlayers then
        for s in pairs(room.members) do notify(s, "Not enough players to start.", "warning") end
        return
    end

    local roster = {}
    for src, e in pairs(room.members) do roster[#roster + 1] = { src = src, pid = e.pid, name = e.name } end

    local bucketId = 0
    if GetResourceState("spz-core") == "started" then
        bucketId = exports["spz-core"]:CreateBucket(("cyclone:%d"):format(room.id))
        SetRoutingBucketPopulationEnabled(bucketId, false)
    end

    local r = { room = room, active = true, bucketId = bucketId, players = {}, phase = "build", cyclones = {}, roundNo = 1 }
    room.round = r

    for _, m in ipairs(roster) do
        r.players[m.src] = { pid = m.pid, name = m.name, alive = true }
        pcall(function()
            if GetResourceState("spz-vehicles") == "started" then exports["spz-vehicles"]:DespawnVehicle(m.src) end
        end)
        if bucketId ~= 0 then exports["spz-core"]:AssignPlayerToBucket(m.src, bucketId) end
    end

    local spots = spawnSpots()
    local n = 0
    for src, p in pairs(r.players) do
        n = n + 1
        local s = spots[((n - 1) % #spots) + 1]
        local tx, ty = Grid.tileCenter(s[1], s[2])
        local heading = (math.deg(math.atan(Config.Center.y - ty, Config.Center.x - tx)) - 90.0) % 360.0
        p.spawn, p.heading = vector3(tx, ty, Config.Center.z + 1.0), heading
        setContact(src, true)
        TriggerClientEvent(EV .. "start", src, { spawn = p.spawn, heading = heading })
    end

    log(("room %d round start: %d players"):format(room.id, #roster))

    CreateThread(function()
        Wait(3000)
        for c = 3, 1, -1 do
            if not r.active then return end
            toAll(r, EV .. "countdown", c)
            Wait(1000)
        end
        if not r.active then return end
        r.liveAt = GetGameTimer()
        r.phase = "live"
        newCyclone(r)
        toAll(r, EV .. "go", {})
    end)
end


local function arm(room)
    if room.armed or room.round then return end
    room.armed, room.armedAt = true, GetGameTimer()
    local token = room.armedAt
    SetTimeout((Config.LobbyWaitSec or 45) * 1000, function()
        if Rooms[room.id] == room and room.armed and room.armedAt == token and not room.round then
            CreateThread(function() startRound(room) end)
        end
    end)
end

-- Busy elsewhere → hidden from invite lists. Queued racers still show: joining
-- a room takes them out of the race queue (see leaveRaceQueue).
local function invitable(sid)
    local st = Player(sid).state
    if st.mgRoom or st.inMinigame or st.inRace or st.inTimeTrial or st.inPursuit then return false end
    return true
end

-- Joining a minigame room drops your E-join race queue spot instead of refusing.
local function leaveRaceQueue(src)
    local st = Player(src).state
    if not (st.inQueue or st.pendingRace) or st.inRace then return end
    if GetResourceState("spz-races") ~= "started" then return end
    pcall(function() exports["spz-races"]:LeaveQueue(src) end)
end

local function busy(src)
    if RoomOf[src] then return "already in a room" end
    local st = Player(src).state
    -- One minigame room at a time, across every game.
    if st.mgRoom and st.mgRoom ~= GetCurrentResourceName() then return "already in another minigame room — leave it first" end
    if st.inRace then return "in a race" end
    if st.inTimeTrial then return "in a time trial" end
    return nil
end

local function addMember(room, src)
    local pid, prof = pidOf(src)
    if not pid then return false, "Profile not ready." end
    room.members[src] = { pid = pid, name = (prof and prof.username) or GetPlayerName(src) }
    RoomOf[src] = room
    if Invites[src] then Invites[src][room.id] = nil end
    local n = count(room.members)
    for s in pairs(room.members) do
        if s ~= src then notify(s, ("%s joined %s (%d/%d)"):format(room.members[src].name, room.name, n, roomMax(room)), "success") end
    end
    Player(src).state:set("mgRoom", GetCurrentResourceName(), true)
    leaveRaceQueue(src)
    -- No auto-start: only the room host starts the match.
    return true
end

local function removeMember(src, why)
    local room = RoomOf[src]
    if not room then return end
    local e = room.members[src]
    room.members[src] = nil
    RoomOf[src] = nil
    if GetPlayerName(src) then Player(src).state:set("mgRoom", nil, true) end
    if not next(room.members) then Rooms[room.id] = nil; return end
    if room.host == src then
        room.host = next(room.members)
        notify(room.host, "You are now the room host.", "info")
    end
    if count(room.members) < Config.MinPlayers then disarm(room) end
    for s in pairs(room.members) do
        notify(s, ("%s left the room%s."):format(e and e.name or "Someone", why and (" (" .. why .. ")") or ""), "warning")
    end
end

local function createRoom(src, opts)
    local b = busy(src)
    if b then return false, "You are " .. b .. "." end
    local maxRooms = Config.MaxRooms or 8
    if count(Rooms) >= maxRooms then return false, ("All %d rooms are in use."):format(maxRooms) end
    opts = type(opts) == "table" and opts or {}

    local name = tostring(opts.name or ""):gsub("[^%w%s%-_'!%.]", ""):sub(1, 24)
    if name:match("^%s*$") then name = nameOf(src) .. "'s room" end
    local max = math.floor(tonumber(opts.max) or Config.MaxPlayers)
    max = math.max(Config.MinPlayers, math.min(Config.MaxPlayers, max))

    local room = { id = nextRoomId, name = name, host = src, private = opts.private == true, max = max, members = {} }
    nextRoomId = nextRoomId + 1
    Rooms[room.id] = room
    local ok, err = addMember(room, src)
    if not ok then Rooms[room.id] = nil; return false, err end
    log(("room %d created by %s (%s, max %d%s)"):format(room.id, nameOf(src), name, max, room.private and ", private" or ""))
    return true, ("Created %s."):format(name)
end

local function joinRoom(src, id)
    local room = Rooms[tonumber(id) or -1]
    if not room then return false, "That room is gone." end
    if RoomOf[src] == room then return true end
    local b = busy(src)
    if b then return false, "You are " .. b .. "." end
    if room.round then return false, "That room is mid-round — wait for it to finish." end
    if room.private and not (Invites[src] and Invites[src][room.id]) then return false, "That room is invite-only." end
    if count(room.members) >= roomMax(room) then return false, "That room is full." end
    local ok, err = addMember(room, src)
    if not ok then return false, err end
    return true, ("Joined %s."):format(room.name)
end

-- Public matchmaking: the fullest open public room, else a new one.
local function quickJoin(src)
    local best
    for _, room in pairs(Rooms) do
        if not room.private and not room.round and count(room.members) < roomMax(room)
            and (not best or count(room.members) > count(best.members)) then
            best = room
        end
    end
    if best then return joinRoom(src, best.id) end
    return createRoom(src, {})
end

local function roomView(room, viewer)
    local roster = {}
    for s, e in pairs(room.members) do
        roster[#roster + 1] = { src = s, name = e.name, isMe = (s == viewer), host = (s == room.host) }
    end
    table.sort(roster, function(a, b)
        if a.host ~= b.host then return a.host end
        return a.name < b.name
    end)
    return {
        id = room.id, name = room.name, private = room.private, host = nameOf(room.host),
        count = #roster, max = roomMax(room), live = room.round ~= nil,
        armed = room.armed,
        armedRemain = room.armed and math.max(0, (Config.LobbyWaitSec or 45) - math.floor((GetGameTimer() - room.armedAt) / 1000)) or nil,
        roster = roster,
    }
end

-- Shape kept compatible with the old single-lobby menu (inLobby/count/roster…),
-- plus the room list for the hub.
local function lobbyStateFor(src)
    local room = RoomOf[src]
    local rooms = {}
    for _, rm in pairs(Rooms) do
        local invited = Invites[src] and Invites[src][rm.id] or false
        if not rm.private or invited or rm == room then
            local v = roomView(rm, src)
            v.roster, v.invited, v.mine = nil, invited and true or false, rm == room
            rooms[#rooms + 1] = v
        end
    end
    table.sort(rooms, function(a, b)
        if a.mine ~= b.mine then return a.mine end
        if a.invited ~= b.invited then return a.invited end
        if a.live ~= b.live then return not a.live end
        return a.count > b.count
    end)

    local v = room and roomView(room, src)
    return {
        rooms = rooms, maxRooms = Config.MaxRooms or 8,
        room = v, isHost = room ~= nil and room.host == src,
        inRound = roundOf(src) ~= nil,
        roundLive = v and v.live or false,
        inLobby = room ~= nil,
        count = v and v.count or 0, min = Config.MinPlayers, max = v and v.max or Config.MaxPlayers,
        armed = v and v.armed or false, armedRemain = v and v.armedRemain or nil,
        roster = v and v.roster or {},
    }
end

local function reply(src, ok, msg)
    if msg then notify(src, msg, ok and "success" or "error") end
    return lobbyStateFor(src)
end

local function toggleJoin(src)
    if RoomOf[src] then
        if roundOf(src) then notify(src, "You are in a round.", "error"); return end
        removeMember(src, "left")
        notify(src, "Left the room.")
        return
    end
    local ok, msg = quickJoin(src)
    if msg then notify(src, msg, ok and "success" or "error") end
end

local function startNow(src)
    local room = RoomOf[src]
    if not room then return false, "Join a room first with /" .. Config.Command end
    if room.host ~= src then return false, "Only the room host can start." end
    if room.round then return false, "A round is already running." end
    if count(room.members) < Config.MinPlayers then return false, ("Need %d players."):format(Config.MinPlayers) end
    CreateThread(function() startRound(room) end)
    return true
end

-- ── Commands / callbacks ────────────────────────────────────────────────────

RegisterCommand(Config.Command, function(source) if source > 0 then toggleJoin(source) end end, false)

RegisterCommand(Config.StartCommand, function(source)
    if source <= 0 then return end
    local ok, msg = startNow(source)
    if not ok then notify(source, msg, "error") end
end, false)

lib.callback.register(EV .. "lobbyState", function(src) return lobbyStateFor(src) end)
lib.callback.register(EV .. "joinToggle", function(src) toggleJoin(src); return lobbyStateFor(src) end)
lib.callback.register(EV .. "createRoom", function(src, opts) return reply(src, createRoom(src, opts)) end)
lib.callback.register(EV .. "joinRoom", function(src, id) return reply(src, joinRoom(src, id)) end)
lib.callback.register(EV .. "leaveRoom", function(src)
    if roundOf(src) then return reply(src, false, "You are in a round.") end
    if not RoomOf[src] then return reply(src, false) end
    removeMember(src, "left")
    return reply(src, true, "Left the room.")
end)
lib.callback.register(EV .. "startRoom", function(src) return reply(src, startNow(src)) end)
lib.callback.register(EV .. "kick", function(src, target)
    local room = RoomOf[src]
    target = tonumber(target)
    if not room or room.host ~= src then return reply(src, false, "Only the host can do that.") end
    if room.round then return reply(src, false, "Not during a round.") end
    if not target or target == src or RoomOf[target] ~= room then return reply(src, false) end
    removeMember(target, "removed by host")
    notify(target, ("You were removed from %s."):format(room.name), "warning")
    return reply(src, true)
end)

-- Online players eligible to invite: not already in a room.
lib.callback.register(EV .. "online", function(src)
    local list = {}
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid ~= src and not RoomOf[sid] and invitable(sid) then
            list[#list + 1] = { source = sid, name = nameOf(sid) }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end)

-- ── Invites ─────────────────────────────────────────────────────────────────

RegisterNetEvent(EV .. "invite", function(targetSrc)
    local src = source
    local room = RoomOf[src]
    targetSrc = tonumber(targetSrc)
    if not room then notify(src, "Join a room before inviting.", "error"); return end
    if not targetSrc or not GetPlayerName(targetSrc) then notify(src, "That player is not online.", "error"); return end
    if RoomOf[targetSrc] then notify(src, "They are already in a room.", "info"); return end
    if count(room.members) >= roomMax(room) then notify(src, "Room full.", "error"); return end

    Invites[targetSrc] = Invites[targetSrc] or {}
    Invites[targetSrc][room.id] = true
    Invites[targetSrc].last = room.id
    TriggerClientEvent(EV .. "invited", targetSrc, { fromSrc = src, fromName = room.members[src].name, room = room.id, roomName = room.name })
    notify(src, ("Invite sent to %s."):format(nameOf(targetSrc)), "success")
end)

RegisterNetEvent(EV .. "acceptInvite", function(roomId)
    local src = source
    if RoomOf[src] then return end
    local id = tonumber(roomId) or (Invites[src] and Invites[src].last)
    if not id then return end
    local ok, msg = joinRoom(src, id)
    if msg then notify(src, msg, ok and "success" or "error") end
end)

-- ── Round plumbing ──────────────────────────────────────────────────────────

-- Client is standing at its spawn with the platform built: NOW create its car.
-- Creating it here (player already nearby, in the bucket) means the player gets
-- ownership straight away and can drive it.
RegisterNetEvent(EV .. "ready", function()
    local src = source
    local r = roundOf(src)
    local p = r and r.players[src]
    if not p or p.veh or not p.spawn then return end
    local veh = spawnCarFor(src, r.bucketId or 0, p.spawn.x, p.spawn.y, p.spawn.z, p.heading)
    if not r.active then if veh then DeleteEntity(veh) end return end
    p.veh = veh
    TriggerClientEvent(EV .. "car", src, { netId = veh and NetworkGetNetworkIdFromEntity(veh) or nil })
end)

-- "Leave minigame" from the Esc / radial menu. Counts as eliminated; they are
-- taken out of the round entirely so the end-of-round payout skips them.
RegisterNetEvent(EV .. "leave", function()
    local src = source
    local r = roundOf(src)
    local p = r and r.players[src]
    if p then
        deleteCar(p)
        setContact(src, false)
        r.players[src] = nil
        TriggerClientEvent(EV .. "over", src, { won = false, payout = 0 })
        SetTimeout(600, function()
            if GetPlayerName(src) and GetResourceState("spz-core") == "started" then
                exports["spz-core"]:RemovePlayerFromBucket(src)
            end
        end)
        toAll(r, EV .. "feed", { name = p.name, why = "left" })
    end
    removeMember(src, "left")
end)

AddEventHandler("playerDropped", function()
    local src = source
    local r = roundOf(src)
    if r then
        local p = r.players[src]
        p.alive, p.left = false, true
        deleteCar(p)
    end
    removeMember(src, "disconnected")
    Invites[src] = nil
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, room in pairs(Rooms) do
        if room.round then endRound(room.round, "resource stopped") end
    end
end)
