-- config.lua — Traffic Hide & Seek
Config = {}

Config.Command      = "hideseek"   -- join/leave the lobby
Config.StartCommand = "hsstart"    -- force-start the lobby early

-- ── Wager ───────────────────────────────────────────────────────────────────
Config.Stake     = 250     -- credits staked to enter (winners split the pot)
Config.HouseRake = 0.0     -- 0 = pure pot split

-- ── Lobby ───────────────────────────────────────────────────────────────────
Config.MinPlayers   = 3
Config.MaxPlayers   = 16
Config.LobbyWaitSec = 30    -- countdown armed by the first joiner

-- ── Round ───────────────────────────────────────────────────────────────────
Config.SeekerRatio = 0.34   -- ~1/3 seekers (min 1 seeker, 1 hider)
Config.HideTimeSec = 45     -- head start: seekers frozen while hiders scatter
Config.RoundTimeSec = 300   -- hiders survive this long to win
Config.CatchDist   = 4.5    -- metres: seeker this close to a hider = caught

-- Dense-traffic arena the round is played in (hiders blend into NPC cars).
Config.Arena = vector3(-260.0, -970.0, 31.2)   -- downtown Los Santos
Config.SpawnSpread = 80.0                        -- players scatter within this radius

-- Common "traffic-look" cars hiders spawn in so they blend with NPCs.
Config.HiderModels = {
  "blista", "asea", "premier", "washington", "asterope", "intruder",
  "ingot", "stratum", "tailgater", "stanier", "primo", "regina",
}
