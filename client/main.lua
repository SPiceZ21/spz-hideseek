-- client/main.lua — RC Hide & Seek
-- Server drives everything (roles, catches, timer). Client just: TPs into the
-- zone, spawns a tiny RC car (hiding the oversized ped so only the toy car
-- shows), shows the HUD, keeps everyone penned inside the zone, and (for
-- hiders) blips seekers so they can evade. Catches are decided server-side.

local active   = false
local role     = nil     -- "hider" | "seeker"
local caught   = false
local phase    = "hide"
local state    = { remain = 0, hideRemain = 0, aliveHiders = 0 }
local myBack   = nil
local myVeh    = 0
local seekerBlips = {}   -- [serverId] = blip (hiders only)
local seekers  = {}      -- serverIds
local zoneCenter = nil
local zoneRadius = 24.0
local lastBoundaryWarnAt = 0

RegisterNetEvent("spz-hideseek:notify", function(msg, t)
    lib.notify({ description = msg, type = t or "info" })
end)

-- ── Queue / invite / car-select menu (ox_lib context) ─────────────────────────
-- Roles are shuffled at round start, so the car picked here just carries
-- through to whichever role you land in — matches how spawnCar always ran
-- regardless of role.

local function prettyModelLabel(model)
    local hash = GetHashKey(model)
    local nameGxt = GetDisplayNameFromVehicleModel(hash)
    local nameText = (nameGxt and nameGxt ~= "") and GetLabelText(nameGxt) or ""
    if nameText == "NULL" or nameText == "" then nameText = model end
    return nameText
end

local function openLobbyMenu()
    local st = lib.callback.await("spz-hideseek:lobbyState", false)
    if not st then return end

    if st.roundLive then
        lib.notify({ description = "A round is already in progress.", type = "warning" })
        return
    end

    -- Car submenu
    local carOptions = {}
    for _, m in ipairs(st.models) do
        local isPicked = st.carPref == m
        carOptions[#carOptions + 1] = {
            title = prettyModelLabel(m),
            description = isPicked and "Selected" or "Tap to select",
            icon = isPicked and "check" or "car",
            onSelect = function()
                lib.callback.await("spz-hideseek:setCar", false, m)
                openLobbyMenu()
            end,
        }
    end
    lib.registerContext({ id = "spz_hideseek_car", title = "Your Car", menu = "spz_hideseek_lobby", options = carOptions })

    -- Invite submenu
    local online = lib.callback.await("spz-hideseek:online", false) or {}
    local inviteOptions = {}
    if #online == 0 then
        inviteOptions[1] = { title = "No one else online", disabled = true }
    else
        for _, p in ipairs(online) do
            inviteOptions[#inviteOptions + 1] = {
                title = p.name,
                icon = "user-plus",
                onSelect = function()
                    TriggerServerEvent("spz-hideseek:invite", p.source)
                end,
            }
        end
    end
    lib.registerContext({ id = "spz_hideseek_invite", title = "Invite Player", menu = "spz_hideseek_lobby", search = #online > 6, options = inviteOptions })

    local mainOptions = {
        {
            title = st.inLobby and "Leave Queue" or "Join Queue",
            description = st.inLobby and "You're queued — tap to leave" or "Free to join",
            icon = st.inLobby and "right-from-bracket" or "right-to-bracket",
            iconColor = st.inLobby and "#ff4d5e" or "#22c55e",
            onSelect = function()
                lib.callback.await("spz-hideseek:joinToggle", false)
                openLobbyMenu()
            end,
        },
        {
            title = "Your Car",
            description = (st.carPref and prettyModelLabel(st.carPref)) or ("Random RC car"),
            icon = "car",
            arrow = true,
            menu = "spz_hideseek_car",
        },
        {
            title = "Invite Player",
            description = #online .. " online",
            icon = "user-plus",
            arrow = true,
            menu = "spz_hideseek_invite",
        },
        {
            title = ("── Queue %d/%d%s ──"):format(st.count, st.max, st.armed and (" · starts in " .. (st.armedRemain or 0) .. "s") or ""),
            disabled = true,
        },
    }

    if #st.roster == 0 then
        mainOptions[#mainOptions + 1] = { title = "Queue is empty", disabled = true }
    else
        for _, r in ipairs(st.roster) do
            mainOptions[#mainOptions + 1] = { title = (r.isMe and "★ " or "") .. r.name, disabled = true }
        end
    end

    lib.registerContext({ id = "spz_hideseek_lobby", title = "🕵️ Hide & Seek", options = mainOptions })
    lib.showContext("spz_hideseek_lobby")
end

RegisterCommand("hideseekmenu", function() openLobbyMenu() end, false)
RegisterKeyMapping("hideseekmenu", "Hide & Seek queue menu", "keyboard", "")

RegisterNetEvent("spz-hideseek:invited", function(d)
    local resp = lib.alertDialog({
        header = "Hide & Seek Invite",
        content = ("**%s** invited you to join Hide & Seek."):format(d.fromName or "Someone"),
        centered = true,
        cancel = true,
        labels = { cancel = "Dismiss", confirm = "Join" },
    })
    if resp == "confirm" then
        TriggerServerEvent("spz-hideseek:acceptInvite")
    end
end)

local function fmt(s) return ("%d:%02d"):format(math.floor(s / 60), s % 60) end

local function clearBlips()
    for _, b in pairs(seekerBlips) do if DoesBlipExist(b) then RemoveBlip(b) end end
    seekerBlips = {}
end

local function spawnCar(models)
    local ped = PlayerPedId()
    local m = models[math.random(#models)]
    local hash = GetHashKey(m)
    RequestModel(hash)
    local dl = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < dl do Wait(20) end
    if not HasModelLoaded(hash) then return end
    local c = GetEntityCoords(ped)
    local v = CreateVehicle(hash, c.x, c.y, c.z, GetEntityHeading(ped), true, false)
    SetModelAsNoLongerNeeded(hash)
    SetPedIntoVehicle(ped, v, -1)
    SetVehicleOnGroundProperly(v)
    SetVehicleNumberPlateText(v, ("%s%d"):format(string.char(math.random(65,90), math.random(65,90)), math.random(100,999)))
    -- The ped is comically oversized next to an RC car — hide it so only the
    -- toy car shows. Restored in cleanup().
    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    myVeh = v
end

local function cleanup()
    active = false
    caught = false
    role = nil
    clearBlips()
    if myVeh ~= 0 and DoesEntityExist(myVeh) then DeleteEntity(myVeh) end
    myVeh = 0
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetEntityInvincible(ped, false)
    if myBack then
        SetEntityCoords(ped, myBack.x, myBack.y, myBack.z, false, false, false, false)
        myBack = nil
    end
end

RegisterNetEvent("spz-hideseek:start", function(d)
    active = true
    caught = false
    role   = d.role
    phase  = "hide"
    seekers = {}
    for _, r in ipairs(d.roles or {}) do
        if r.role == "seeker" then seekers[#seekers + 1] = r.src end
    end

    local ped = PlayerPedId()
    myBack = GetEntityCoords(ped)
    zoneCenter = d.arena
    zoneRadius = d.zoneRadius or 24.0

    -- Scatter around the zone.
    local ang = math.random() * math.pi * 2
    local dist = math.random() * (d.spread or 18.0)
    local x = d.arena.x + math.cos(ang) * dist
    local y = d.arena.y + math.sin(ang) * dist
    SetEntityCoords(ped, x, y, d.arena.z + 1.0, false, false, false, false)
    SetEntityInvincible(ped, true)

    spawnCar(d.models or { "rcbandito" })

    -- Seekers are frozen during the hide phase; hiders scatter freely.
    if role == "seeker" then
        FreezeEntityPosition(PlayerPedId(), true)
        lib.notify({ title = "SEEKER", description = "Wait… hiders are tucking in. Then hunt them down in the zone.", type = "warning", duration = 6000 })
    else
        lib.notify({ title = "HIDER", description = "Find a hiding spot inside the zone. Don't get spotted!", type = "success", duration = 6000 })
    end

    DoScreenFadeIn(400)
end)

RegisterNetEvent("spz-hideseek:release", function()
    phase = "seek"
    if role == "seeker" then
        FreezeEntityPosition(PlayerPedId(), false)
        lib.notify({ title = "GO", description = "Find the hiders!", type = "info" })
    end
end)

RegisterNetEvent("spz-hideseek:caught", function(mine)
    if mine then
        caught = true
        lib.notify({ title = "CAUGHT", description = "You've been found! Out of the round.", type = "error", duration = 6000 })
    else
        lib.notify({ description = "You caught a hider!", type = "success" })
    end
end)

RegisterNetEvent("spz-hideseek:catchFeed", function(name)
    lib.notify({ description = ("%s was found"):format(name or "A hider"), type = "inform", duration = 3000 })
end)

RegisterNetEvent("spz-hideseek:state", function(s)
    phase = s.phase or phase
    state = s
end)

RegisterNetEvent("spz-hideseek:over", function(r)
    local msg = (r.winner == "seeker") and "Seekers win!" or "Hiders win!"
    if r.won then msg = msg .. (" +%d credits"):format(r.payout or 0) end
    DoScreenFadeOut(400)
    Wait(400)
    cleanup()
    lib.notify({ title = "HIDE & SEEK", description = msg, type = r.won and "success" or "info", duration = 8000 })
    DoScreenFadeIn(600)
end)

-- ── HUD + zone containment ───────────────────────────────────────────────────
-- Everyone is confined to Config.ZoneRadius around Config.Arena — this is a
-- contained RC-car pen, not open-world traffic. Enforced client-side (cheap,
-- instant) since it's not competitive-integrity like the catch itself.
CreateThread(function()
    while true do
        if active then
            local label, timer
            if phase == "hide" then
                label = (role == "seeker") and "HOLD — HIDERS SCATTERING" or "HIDE NOW"
                timer = fmt(state.hideRemain or 0)
            else
                label = caught and "CAUGHT — SPECTATING" or (role == "seeker" and "SEEK" or "STAY HIDDEN")
                timer = fmt(state.remain or 0)
            end

            SetTextFont(4); SetTextScale(0.0, 0.5); SetTextCentre(true)
            SetTextColour(255, 255, 255, 220); SetTextOutline()
            BeginTextCommandDisplayText("STRING")
            AddTextComponentSubstringPlayerName(("RC HIDE & SEEK  ·  %s  ·  %s  ·  %d hiders left"):format(label, timer, state.aliveHiders or 0))
            EndTextCommandDisplayText(0.5, 0.03)

            if zoneCenter and myVeh ~= 0 and DoesEntityExist(myVeh) then
                local c = GetEntityCoords(myVeh)
                local dx, dy = c.x - zoneCenter.x, c.y - zoneCenter.y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist > zoneRadius then
                    local ratio = zoneRadius / dist
                    SetEntityCoords(myVeh, zoneCenter.x + dx * ratio, zoneCenter.y + dy * ratio, c.z, false, false, false, false)
                    SetEntityVelocity(myVeh, 0.0, 0.0, 0.0)

                    local now = GetGameTimer()
                    if now - lastBoundaryWarnAt > 2000 then
                        lastBoundaryWarnAt = now
                        lib.notify({ description = "Stay inside the zone!", type = "error", duration = 1800 })
                    end
                end
            end

            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- ── Hider blips on seekers (evasion aid) ──────────────────────────────────────
CreateThread(function()
    while true do
        if active and role == "hider" and not caught then
            for _, sid in ipairs(seekers) do
                local lp = GetPlayerFromServerId(sid)
                local ped = (lp ~= -1) and GetPlayerPed(lp) or 0
                if ped ~= 0 and DoesEntityExist(ped) then
                    if not (seekerBlips[sid] and DoesBlipExist(seekerBlips[sid])) then
                        local b = AddBlipForEntity(ped)
                        SetBlipSprite(b, 1); SetBlipColour(b, 1); SetBlipScale(b, 0.85)
                        BeginTextCommandSetBlipName("STRING"); AddTextComponentSubstringPlayerName("Seeker"); EndTextCommandSetBlipName(b)
                        seekerBlips[sid] = b
                    end
                end
            end
            Wait(1000)
        else
            if next(seekerBlips) then clearBlips() end
            Wait(600)
        end
    end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() and active then cleanup() end
end)
