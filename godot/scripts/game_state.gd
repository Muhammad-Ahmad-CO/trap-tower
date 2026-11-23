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

# Lane U4 (M8 chapter-complete): the chapter (1/2/3) whose final
# door was just won AND whose whole chapter is now complete; 0 =
# none. Set by game.gd in the normal win branch (never for
# daily/bonus/nightmare runs); consumed (then cleared to 0) by
# map.gd, which opens the M8 chapter-complete overlay instead of the
# door picker. The return_door for that win is consumed with it.
static var chapter_complete := 0

# Lane U4 (M8 -> M7 order, N4): set by the map when the Chapter 3
# M8 overlay closes, so Lane U5's end-credits screen opens AFTER
# the chapter-complete screen. Consumed (then cleared) by U5's
# open_credits; the map itself never opens credits.
static var pending_credits := false

# Lane U5 (M4 speedrun): 0 = normal play; 1/2/3 = a timed run of
# that chapter's doors in order. Set by the map before changing to
# the game scene (run loop applied with the M4 stub after U4's
# chapter API landed — see M4-SPEEDRUN-STUB.md). This is only the
# cross-scene carrier, like bonus/daily/nightmare above; it invents
# no chapter mapping (the chapter->door table is U4's).
static var speedrun_chapter := 0
