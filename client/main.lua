-- client/main.lua — Traffic Hide & Seek
-- Server drives everything (roles, catches, timer). Client just: TPs into the
-- arena, spawns a blend-in car, shows the HUD, and (for hiders) blips seekers so
-- they can evade. Catches are decided server-side by proximity.

local active   = false
local role     = nil     -- "hider" | "seeker"
local caught   = false
local phase    = "hide"
local state    = { remain = 0, hideRemain = 0, aliveHiders = 0 }
local myBack   = nil
local myVeh    = 0
local seekerBlips = {}   -- [serverId] = blip (hiders only)
local seekers  = {}      -- serverIds

RegisterNetEvent("spz-hideseek:notify", function(msg, t)
    lib.notify({ description = msg, type = t or "info" })
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

    -- Scatter around the arena.
    local ang = math.random() * math.pi * 2
    local dist = math.random() * (d.spread or 60.0)
    local x = d.arena.x + math.cos(ang) * dist
    local y = d.arena.y + math.sin(ang) * dist
    SetEntityCoords(ped, x, y, d.arena.z + 1.0, false, false, false, false)
    SetEntityInvincible(ped, true)

    spawnCar(d.models or { "blista" })

    -- Seekers are frozen during the hide phase; hiders scatter freely.
    if role == "seeker" then
        FreezeEntityPosition(PlayerPedId(), true)
        lib.notify({ title = "SEEKER", description = "Wait… hiders are scattering. Then hunt them in traffic.", type = "warning", duration = 6000 })
    else
        lib.notify({ title = "HIDER", description = "Blend into traffic. Don't get spotted!", type = "success", duration = 6000 })
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

-- ── HUD ────────────────────────────────────────────────────────────────────────
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
            AddTextComponentSubstringPlayerName(("HIDE & SEEK  ·  %s  ·  %s  ·  %d hiders left"):format(label, timer, state.aliveHiders or 0))
            EndTextCommandDisplayText(0.5, 0.03)
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
