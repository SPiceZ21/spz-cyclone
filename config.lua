-- config.lua — Cyclone
-- Everyone drives onto one big single-colour deck in the sky. A cyclone roams
-- the deck, lifts any car it catches, spins it up and throws it away. One
-- round, no waves: it lasts until a single car is left on the deck.

Config = {}

Config.Command      = "cyclone"        -- join/leave the lobby
Config.StartCommand = "cystart"        -- host starts the match
Config.MenuCommand  = "cyclonemenu"    -- queue menu

-- ── Rewards (FREE to join) ──────────────────────────────────────────────────
Config.WinReward      = 1500   -- most round wins after Config.Rounds (split on a tie)
Config.Rounds         = 5      -- rounds per match; each ends when one car is left
Config.SurvivalPerMin = 100    -- per full minute on the deck, paid to everyone

-- ── Lobby ───────────────────────────────────────────────────────────────────
Config.MinPlayers = 2
Config.MaxPlayers = 24
Config.MaxRooms   = 6
Config.LobbyWaitSec = 45       -- unused: only the host starts (kept for shared room code)

-- ── Arena ───────────────────────────────────────────────────────────────────
-- Centre of the TOP surface of the deck. High in the air over open water, so a
-- thrown car falls into nothing. Each room plays in its own routing bucket, so
-- rooms never see each other's deck.
Config.Center   = vector3(-2400.0, -1400.0, 260.0)
Config.Grid     = 8        -- sections per side
Config.TileSize = 13.0     -- metres per section: 8 x 13 = 104 m deck

-- The deck reuses Color Rush's streamed tiles — all one colour. spz-colorrush
-- must be started for these to exist. Falls back to a vanilla stunt block.
Config.TileModel = "spz_cr_tile_purple"
Config.TileProps = { "stt_prop_stunt_bblock_mdm3", "stt_prop_stunt_bblock_lrg3", "prop_container_05a" }
Config.MaxPropsPerSide = 6

-- ── The cyclone ─────────────────────────────────────────────────────────────
Config.Cyclone = {
    -- movement (server)
    Speed       = 6.0,     -- m/s at the start
    SpeedStep   = 1.0,     -- added every RampEverySec
    MaxSpeed    = 14.0,
    Radius      = 9.0,     -- metres: inside this a car is lifted
    RadiusStep  = 1.5,
    MaxRadius   = 18.0,
    RampEverySec = 30,     -- intensity step
    SecondAtSec  = 90,     -- a second funnel touches down after this long
    ChaseChance  = 0.45,   -- chance its next target is a random living car

    -- physics (client, on your own car)
    PullRange   = 2.2,     -- x Radius: inside this the car is dragged in
    PullForce   = 7.0,     -- m/s of drag toward the funnel at the edge of PullRange
    LiftSpeed   = 11.0,    -- m/s up while caught
    SpinSpeed   = 16.0,    -- m/s around the funnel while caught
    LiftHeight  = 22.0,    -- metres above the deck where it lets go
    MaxHoldSec  = 2.2,     -- or after this long, whichever comes first
    ThrowSpeed  = 34.0,    -- m/s outward when thrown
    ThrowUp     = 6.0,     -- m/s up on release
    Immunity    = 2.5,     -- seconds a thrown car can't be caught again
}

-- ── Cars ────────────────────────────────────────────────────────────────────
Config.Cars = {
    "blista", "futo", "prairie", "rhapsody", "dilettante",
    "panto", "issi2", "brioso", "kuruma", "sultan",
    "bison", "sadler", "sandking", "rebel2", "dubsta3",
    "firetruk", "mule", "benson", "taco", "caddy2",
}
Config.CarInvincible = true

-- ── Grid maths (shared by client and server) ────────────────────────────────
Grid = {}

function Grid.span()    return Config.Grid * Config.TileSize end
function Grid.originX() return Config.Center.x - (Grid.span() * 0.5) end
function Grid.originY() return Config.Center.y - (Grid.span() * 0.5) end

function Grid.tileCenter(ix, iy)
    return Grid.originX() + ((ix + 0.5) * Config.TileSize),
           Grid.originY() + ((iy + 0.5) * Config.TileSize)
end

function Grid.total() return Config.Grid * Config.Grid end
