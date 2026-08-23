-- config.lua — Traffic Hide & Seek
Config = {}

Config.Command      = "hideseek"   -- join/leave the lobby
Config.StartCommand = "hsstart"    -- force-start the lobby early

-- ── Reward (FREE to join — no entry fee) ────────────────────────────────────
Config.WinReward = 500     -- flat credits paid to each winner (0 = no reward)

-- ── Lobby ───────────────────────────────────────────────────────────────────
Config.MinPlayers   = 3
Config.MaxPlayers   = 16
Config.LobbyWaitSec = 30    -- countdown armed by the first joiner

-- ── Round ───────────────────────────────────────────────────────────────────
Config.SeekerRatio = 0.34   -- ~1/3 seekers (min 1 seeker, 1 hider)
Config.HideTimeSec = 45     -- head start: seekers frozen while hiders scatter
Config.RoundTimeSec = 300   -- hiders survive this long to win
Config.CatchDist   = 2.5    -- metres: seeker this close to a hider = caught (RC scale)

-- ── RC car mode ─────────────────────────────────────────────────────────────
-- Everyone — hiders and seekers — spawns as a tiny RC car and plays inside a
-- single contained zone instead of full-size cars scattered across downtown
-- traffic. Tune Arena to wherever you want the hiding spot to be (a yard,
-- warehouse, garage — somewhere with clutter to hide a toy car behind).
Config.Arena       = vector3(732.0, -1088.0, 22.0)   -- Cypress Flats yard
Config.ZoneRadius  = 24.0    -- players are confined to this radius of Arena
Config.SpawnSpread = 18.0    -- scatter radius at spawn — keep below ZoneRadius

-- RC vehicles to choose from in the car-select menu.
Config.HiderModels = { "rcbandito", "rctank" }
