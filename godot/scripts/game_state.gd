class_name TTState
extends RefCounted

# Cross-scene state (no autoload): which level the Game scene opens.

static var level_index := 0

# v1.0.5: which door's picker the map re-opens after a win/skip.
# -1 = none (cold start, pause exit, ESC exit -> plain map, no picker).
# Set by game.gd in the win branch and in _on_skip_pressed, before the
# return-to-map delay is set; consumed (then cleared to -1) by map.gd.
static var return_door := -1

# v1.0.5 Part B (Lane F1): true while playing a bonus-door level
# (B001..B005 from bonus_levels.json). Set by the map before changing
# to the game scene; cleared by _start_level for main levels.
static var bonus := false

# v1.0.5 Part B (Lane F2): daily challenge + nightmare mode. Set by
# the map before changing to the game scene; cleared by _start_level
# for main levels. daily_date is "YYYY-MM-DD". nightmare_armed is the
# map's mode toggle (persists across the map scene, so a nightmare
# win returns to the nightmare picker); nightmare is the per-run flag
# for the level currently loading.
static var daily := false
static var daily_date := ""
static var nightmare := false
static var nightmare_armed := false
