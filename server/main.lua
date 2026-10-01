-- server/main.lua — RC Hide & Seek
-- Free-to-join lobby → roles (hiders/seekers) → everyone spawns as a tiny RC
-- car inside one contained zone (Config.Arena/ZoneRadius) → server-authoritative
-- proximity catches → flat WinReward to the winning side. Catches are
-- distance-based on purpose: the global no-collision means cars pass through
-- each other, so "ram to catch" can't work — seekers catch by closing in.

local Log = SPZ and SPZ.Logger and SPZ.Logger("spz-hideseek") or nil
local function log(m) if Log then Log.info(m) else print("[hideseek] " .. m) end end

local lobby = {}    -- [src] = { pid, name, stake, carPref }
local lobbyArmed = false
local lobbyArmedAt = nil
local round = nil   -- see startRound

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function notify(src, msg, t)
    TriggerClientEvent("spz-hideseek:notify", src, msg, t or "info")
end

local function pidOf(src)
    local ok, p = pcall(function() return exports["spz-identity"]:GetProfile(src) end)
    return ok and p and p.id or nil, ok and p or nil
end

local function srcFromPid(pid)
    for _, s in ipairs(GetPlayers()) do
        local id = pidOf(tonumber(s))
        if id == pid then return tonumber(s) end
    end
    return nil
end


local function payPid(pid, amt, reason)
    if amt <= 0 then return end
    local s = srcFromPid(pid)
    if s then
        exports["spz-progression"]:GrantBonus(s, { credits = amt, reason = reason })
    else
        MySQL.update.await("UPDATE players SET credits = credits + ? WHERE id = ?", { amt, pid })
    end
end

local function shuffle(t)
    for i = #t, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end
end

local function inList(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

-- ── Lobby ───────────────────────────────────────────────────────────────────

local function lobbyCount()
    local n = 0; for _ in pairs(lobby) do n = n + 1 end; return n
end

local function broadcastLobby()
    local n = lobbyCount()
    for src in pairs(lobby) do
        notify(src, ("Hide & Seek lobby: %d/%d — /%s to start"):format(n, Config.MaxPlayers, Config.StartCommand), "info")
    end
end

local function cancelLobby(reason)
    for src in pairs(lobby) do
        notify(src, ("Lobby cancelled — %s"):format(reason), "warning")
    end
    lobby = {}
    lobbyArmed = false
    lobbyArmedAt = nil
end

-- Snapshot the lobby/round for a given viewer — feeds the queue menu.
local function lobbyStateFor(src)
    local roster = {}
    for s, e in pairs(lobby) do roster[#roster + 1] = { name = e.name, isMe = (s == src) } end
    table.sort(roster, function(a, b) return a.name < b.name end)

    return {
        inRound = round ~= nil and round.players[src] ~= nil,
        roundLive = round ~= nil,
        inLobby = lobby[src] ~= nil,
        count = lobbyCount(),
        min = Config.MinPlayers,
        max = Config.MaxPlayers,
        armed = lobbyArmed,
        armedRemain = lobbyArmed and math.max(0, (Config.LobbyWaitSec or 30) - math.floor((GetGameTimer() - lobbyArmedAt) / 1000)) or nil,
        roster = roster,
        carPref = lobby[src] and lobby[src].carPref or nil,
        models = Config.HiderModels or { "blista" },
    }
end

-- ── Round ─────────────────────────────────────────────────────────────────────

local function endRound(winnerRole, reason)
    if not round then return end
    local r = round
    round = nil

    -- Winners: seekers → all seekers; hiders → SURVIVING hiders.
    local winners = {}
    for src, p in pairs(r.players) do
        if p.role == winnerRole and (winnerRole == "seeker" or p.alive) then
            winners[#winners + 1] = p
        end
    end

    local reward = Config.WinReward or 0
    for _, p in ipairs(winners) do
        if reward > 0 then payPid(p.pid, reward, "Hide & Seek won") end
    end

    -- Tell everyone + send them home.
    for src, p in pairs(r.players) do
        local won = (p.role == winnerRole and (winnerRole == "seeker" or p.alive))
        TriggerClientEvent("spz-hideseek:over", src, {
            winner = winnerRole, reason = reason, won = won, payout = won and reward or 0,
        })
    end

    -- Cleanup the bucket after clients TP out.
    SetTimeout(1500, function()
        if r.bucketId and r.bucketId ~= 0 and GetResourceState("spz-core") == "started" then
            exports["spz-core"]:DeleteBucket(r.bucketId)
        end
    end)

    pcall(function()
        exports["spz-log"]:Log("minigame", "Hide & Seek",
            ("%s won (%s). %d winner(s) @ %d each."):format(winnerRole, reason, #winners, reward), "success")
    end)
    log(("round over: %s (%s)"):format(winnerRole, reason))
end

local function startRound()
    lobbyArmed = false
    lobbyArmedAt = nil
    local n = lobbyCount()
    if n < Config.MinPlayers then
        cancelLobby("not enough players")
        return
    end

    -- Roster + roles
    local roster = {}
    for src, e in pairs(lobby) do roster[#roster + 1] = { src = src, pid = e.pid, name = e.name, stake = e.stake, carPref = e.carPref } end
    shuffle(roster)
    local seekerN = math.max(1, math.min(#roster - 1, math.floor(#roster * (Config.SeekerRatio or 0.34))))

    -- Isolated bucket, traffic off — it's a contained RC-car zone, not a
    -- blend-into-traffic street.
    local bucketId = 0
    if GetResourceState("spz-core") == "started" then
        bucketId = exports["spz-core"]:CreateBucket("hideseek")
        SetRoutingBucketPopulationEnabled(bucketId, false)
    end

    round = {
        bucketId = bucketId, players = {},
        phase = "hide",
        hideEndsAt = GetGameTimer() + (Config.HideTimeSec * 1000),
        endsAt = GetGameTimer() + ((Config.HideTimeSec + Config.RoundTimeSec) * 1000),
        seekers = {},
    }

    local pool = Config.HiderModels or { "blista" }

    for i, m in ipairs(roster) do
        local role = (i <= seekerN) and "seeker" or "hider"
        local model = (m.carPref and inList(pool, m.carPref)) and m.carPref or pool[1]
        round.players[m.src] = { pid = m.pid, name = m.name, role = role, alive = true, model = model }
        if role == "seeker" then round.seekers[#round.seekers + 1] = m.src end
        -- Same as joining a race: the freeroam car goes (spz-vehicles).
        pcall(function()
            if GetResourceState("spz-vehicles") == "started" then exports["spz-vehicles"]:DespawnVehicle(m.src) end
        end)
        if bucketId ~= 0 then exports["spz-core"]:AssignPlayerToBucket(m.src, bucketId) end
    end
    lobby = {}

    -- Build a roster the clients can use (seeker list for hider blips).
    local roles = {}
    for src, p in pairs(round.players) do roles[#roles + 1] = { src = src, role = p.role } end

    for src, p in pairs(round.players) do
        TriggerClientEvent("spz-hideseek:start", src, {
            role       = p.role,
            arena      = Config.Arena,
            spread     = Config.SpawnSpread,
            zoneRadius = Config.ZoneRadius,
            hideTime   = Config.HideTimeSec,
            roundTime  = Config.RoundTimeSec,
            models     = { p.model },
            roles      = roles,
        })
    end

    log(("round start: %d players (%d seekers, free)"):format(#roster, seekerN))
end

-- ── Server tick: phase + proximity catches + win check ────────────────────────

CreateThread(function()
    while true do
        Wait(500)
        if round then
            local now = GetGameTimer()

            if round.phase == "hide" and now >= round.hideEndsAt then
                round.phase = "seek"
                for src in pairs(round.players) do
                    TriggerClientEvent("spz-hideseek:release", src)
                end
            end

            if round.phase == "seek" then
                -- Catches: any seeker within CatchDist of an alive hider.
                for _, sk in ipairs(round.seekers) do
                    local sped = GetPlayerPed(sk)
                    if sped ~= 0 then
                        local sp = GetEntityCoords(sped)
                        for hsrc, hp in pairs(round.players) do
                            if hp.role == "hider" and hp.alive then
                                local hped = GetPlayerPed(hsrc)
                                if hped ~= 0 and #(sp - GetEntityCoords(hped)) < (Config.CatchDist or 4.5) then
                                    hp.alive = false
                                    TriggerClientEvent("spz-hideseek:caught", hsrc, true)   -- you got caught
                                    TriggerClientEvent("spz-hideseek:caught", sk, false)     -- you caught someone
                                    for s in pairs(round.players) do
                                        TriggerClientEvent("spz-hideseek:catchFeed", s, hp.name)
                                    end
                                end
                            end
                        end
                    end
                end

                -- Win checks
                local aliveHiders = 0
                for _, hp in pairs(round.players) do
                    if hp.role == "hider" and hp.alive then aliveHiders = aliveHiders + 1 end
                end
                if aliveHiders == 0 then
                    endRound("seeker", "all hiders found")
                elseif now >= round.endsAt then
                    endRound("hider", "time up")
                end
            end

            -- Broadcast HUD state
            if round then
                local aliveHiders = 0
                for _, hp in pairs(round.players) do if hp.role == "hider" and hp.alive then aliveHiders = aliveHiders + 1 end end
                local remain = math.max(0, math.floor((round.endsAt - GetGameTimer()) / 1000))
                local hideRemain = math.max(0, math.floor((round.hideEndsAt - GetGameTimer()) / 1000))
                for src in pairs(round.players) do
                    TriggerClientEvent("spz-hideseek:state", src, {
                        phase = round.phase, remain = remain, hideRemain = hideRemain, aliveHiders = aliveHiders,
                    })
                end
            end
        end
    end
end)

-- ── Join / leave ──────────────────────────────────────────────────────────────
-- Shared by the /hideseek command and the queue menu's Join/Leave button.
local function toggleJoin(src)
    if round and round.players[src] then notify(src, "You're in a round.", "error"); return end
    if round then notify(src, "A round is in progress — wait for the next.", "warning"); return end

    if lobby[src] then
        lobby[src] = nil
        notify(src, "Left the lobby.", "info")
        return
    end

    if lobbyCount() >= Config.MaxPlayers then notify(src, "Lobby full.", "error"); return end

    local pid, prof = pidOf(src)
    if not pid then notify(src, "Profile not ready.", "error"); return end

    lobby[src] = { pid = pid, name = prof.username or GetPlayerName(src) }
    notify(src, "Joined Hide & Seek (free to play).", "success")
    broadcastLobby()

    if not lobbyArmed then
        lobbyArmed = true
        lobbyArmedAt = GetGameTimer()
        SetTimeout((Config.LobbyWaitSec or 30) * 1000, function()
            if not round and lobbyArmed then startRound() end
        end)
    end
end

-- ── Commands ──────────────────────────────────────────────────────────────────

RegisterCommand(Config.Command, function(source) toggleJoin(source) end, false)

RegisterCommand(Config.StartCommand, function(source)
    local src = source
    if round then return end
    if not lobby[src] then notify(src, "Join first with /" .. Config.Command, "error"); return end
    if lobbyCount() < Config.MinPlayers then notify(src, ("Need %d players."):format(Config.MinPlayers), "error"); return end
    startRound()
end, false)

-- ── Queue menu callbacks ────────────────────────────────────────────────────

lib.callback.register("spz-hideseek:lobbyState", function(src)
    return lobbyStateFor(src)
end)

lib.callback.register("spz-hideseek:joinToggle", function(src)
    toggleJoin(src)
    return lobbyStateFor(src)
end)

lib.callback.register("spz-hideseek:setCar", function(src, model)
    local e = lobby[src]
    if not e then return { ok = false, error = "Join the lobby first." } end
    if not inList(Config.HiderModels or {}, model) then return { ok = false, error = "Not an available car." } end
    e.carPref = model
    return { ok = true }
end)

-- Online players eligible to invite: not already queued, not in a live round.
lib.callback.register("spz-hideseek:online", function(src)
    local list = {}
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid ~= src and not lobby[sid] and not (round and round.players[sid]) then
            local ok, profile = pcall(function() return exports["spz-identity"]:GetProfile(sid) end)
            local name = (ok and profile and profile.username) or GetPlayerName(sid) or ("Racer" .. sid)
            list[#list + 1] = { source = sid, name = name }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end)

-- ── Invites ───────────────────────────────────────────────────────────────────

RegisterNetEvent("spz-hideseek:invite", function(targetSrc)
    local src = source
    targetSrc = tonumber(targetSrc)
    if not lobby[src] then notify(src, "Join the lobby before inviting.", "error"); return end
    if not targetSrc or not GetPlayerName(targetSrc) then notify(src, "That player isn't online.", "error"); return end
    if lobby[targetSrc] then notify(src, "They're already queued.", "info"); return end
    if round and round.players[targetSrc] then notify(src, "They're in a round.", "error"); return end
    if lobbyCount() >= Config.MaxPlayers then notify(src, "Lobby full.", "error"); return end

    local fromName = lobby[src].name
    TriggerClientEvent("spz-hideseek:invited", targetSrc, { fromSrc = src, fromName = fromName })
    notify(src, ("Invite sent to %s."):format(GetPlayerName(targetSrc) or "player"), "success")
end)

RegisterNetEvent("spz-hideseek:acceptInvite", function()
    local src = source
    if not lobby[src] then toggleJoin(src) end
end)

-- ── Disconnect ────────────────────────────────────────────────────────────────

-- "Leave minigame" from the Esc / radial menu: forfeit and go home.
RegisterNetEvent("spz-hideseek:leave", function()
    local src = source
    if lobby[src] then lobby[src] = nil; return end
    local p = round and round.players[src]
    if not p then return end
    round.players[src] = nil
    TriggerClientEvent("spz-hideseek:over", src, { left = true, won = false, payout = 0 })
    SetTimeout(600, function()
        if GetPlayerName(src) and GetResourceState("spz-core") == "started" then
            exports["spz-core"]:RemovePlayerFromBucket(src)
        end
    end)
end)

AddEventHandler("playerDropped", function()
    local src = source
    if lobby[src] then
        lobby[src] = nil
        return
    end
    if round and round.players[src] then
        -- Forfeit: a hider who leaves counts as caught; seeker just leaves.
        round.players[src].alive = false
        round.players[src].role = "left"
    end
end)
