-- server/main.lua — Traffic Hide & Seek
-- Lobby with credit escrow → roles (hiders/seekers) → isolated traffic bucket →
-- server-authoritative proximity catches → pot split to the winning side.
-- Catches are distance-based on purpose: the global no-collision means cars pass
-- through each other, so "ram to catch" can't work — seekers catch by closing in.

local Log = SPZ and SPZ.Logger and SPZ.Logger("spz-hideseek") or nil
local function log(m) if Log then Log.info(m) else print("[hideseek] " .. m) end end

local lobby = {}    -- [src] = { pid, name, stake }
local lobbyArmed = false
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

local function escrow(src, amt)
    local ok, prof = pcall(function() return exports["spz-identity"]:GetProfile(src) end)
    if not ok or not prof then return false end
    if (prof.credits or 0) < amt then return false end
    exports["spz-identity"]:UpdateProfile(src, { credits = (prof.credits or 0) - amt })
    return true
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

local function refundLobby(reason)
    for src, e in pairs(lobby) do
        payPid(e.pid, e.stake, "Hide & Seek refund")
        notify(src, ("Lobby cancelled (%s) — %d refunded"):format(reason, e.stake), "warning")
    end
    lobby = {}
    lobbyArmed = false
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

    local rake = Config.HouseRake or 0.0
    local pool = math.floor(r.pot * (1 - rake))
    local share = (#winners > 0) and math.floor(pool / #winners) or 0

    for _, p in ipairs(winners) do
        payPid(p.pid, share, "Hide & Seek won")
    end

    -- Tell everyone + send them home.
    for src, p in pairs(r.players) do
        local won = (p.role == winnerRole and (winnerRole == "seeker" or p.alive))
        TriggerClientEvent("spz-hideseek:over", src, {
            winner = winnerRole, reason = reason, won = won, payout = won and share or 0,
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
            ("%s won (%s). Pot %d split %d ways."):format(winnerRole, reason, pool, #winners), "success")
    end)
    log(("round over: %s (%s)"):format(winnerRole, reason))
end

local function startRound()
    lobbyArmed = false
    local n = lobbyCount()
    if n < Config.MinPlayers then
        refundLobby("not enough players")
        return
    end

    -- Roster + roles
    local roster = {}
    for src, e in pairs(lobby) do roster[#roster + 1] = { src = src, pid = e.pid, name = e.name, stake = e.stake } end
    shuffle(roster)
    local seekerN = math.max(1, math.min(#roster - 1, math.floor(#roster * (Config.SeekerRatio or 0.34))))

    -- Bucket with NPC traffic enabled (so hiders have cars to blend with).
    local bucketId = 0
    if GetResourceState("spz-core") == "started" then
        bucketId = exports["spz-core"]:CreateBucket("hideseek")
        SetRoutingBucketPopulationEnabled(bucketId, true)
    end

    round = {
        bucketId = bucketId, players = {}, pot = 0,
        phase = "hide",
        hideEndsAt = GetGameTimer() + (Config.HideTimeSec * 1000),
        endsAt = GetGameTimer() + ((Config.HideTimeSec + Config.RoundTimeSec) * 1000),
        seekers = {},
    }

    for i, m in ipairs(roster) do
        local role = (i <= seekerN) and "seeker" or "hider"
        round.players[m.src] = { pid = m.pid, name = m.name, stake = m.stake, role = role, alive = true }
        round.pot = round.pot + m.stake
        if role == "seeker" then round.seekers[#round.seekers + 1] = m.src end
        if bucketId ~= 0 then exports["spz-core"]:AssignPlayerToBucket(m.src, bucketId) end
    end
    lobby = {}

    -- Build a roster the clients can use (seeker list for hider blips).
    local roles = {}
    for src, p in pairs(round.players) do roles[#roles + 1] = { src = src, role = p.role } end

    for src, p in pairs(round.players) do
        TriggerClientEvent("spz-hideseek:start", src, {
            role      = p.role,
            arena     = Config.Arena,
            spread    = Config.SpawnSpread,
            hideTime  = Config.HideTimeSec,
            roundTime = Config.RoundTimeSec,
            models    = Config.HiderModels,
            roles     = roles,
        })
    end

    log(("round start: %d players (%d seekers), pot %d"):format(#roster, seekerN, round.pot))
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

-- ── Commands ──────────────────────────────────────────────────────────────────

RegisterCommand(Config.Command, function(source)
    local src = source
    if round and round.players[src] then notify(src, "You're in a round.", "error"); return end
    if round then notify(src, "A round is in progress — wait for the next.", "warning"); return end

    if lobby[src] then
        payPid(lobby[src].pid, lobby[src].stake, "Hide & Seek refund")
        lobby[src] = nil
        notify(src, "Left the lobby — stake refunded.", "info")
        return
    end

    if lobbyCount() >= Config.MaxPlayers then notify(src, "Lobby full.", "error"); return end

    local pid, prof = pidOf(src)
    if not pid then notify(src, "Profile not ready.", "error"); return end
    if (prof.credits or 0) < Config.Stake then notify(src, "Not enough credits.", "error"); return end
    if not escrow(src, Config.Stake) then notify(src, "Couldn't stake.", "error"); return end

    lobby[src] = { pid = pid, name = prof.username or GetPlayerName(src), stake = Config.Stake }
    notify(src, ("Joined Hide & Seek (staked %d)."):format(Config.Stake), "success")
    broadcastLobby()

    if not lobbyArmed then
        lobbyArmed = true
        SetTimeout((Config.LobbyWaitSec or 30) * 1000, function()
            if not round and lobbyArmed then startRound() end
        end)
    end
end, false)

RegisterCommand(Config.StartCommand, function(source)
    local src = source
    if round then return end
    if not lobby[src] then notify(src, "Join first with /" .. Config.Command, "error"); return end
    if lobbyCount() < Config.MinPlayers then notify(src, ("Need %d players."):format(Config.MinPlayers), "error"); return end
    startRound()
end, false)

-- ── Disconnect ────────────────────────────────────────────────────────────────

AddEventHandler("playerDropped", function()
    local src = source
    if lobby[src] then
        payPid(lobby[src].pid, lobby[src].stake, "Hide & Seek refund")
        lobby[src] = nil
        return
    end
    if round and round.players[src] then
        -- Forfeit: a hider who leaves counts as caught; seeker just leaves.
        round.players[src].alive = false
        round.players[src].role = "left"
    end
end)
