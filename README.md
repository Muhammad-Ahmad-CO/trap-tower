# Trap Tower

An ORIGINAL minimalist 2D tricky platformer for Android, built with Godot 4.3.
One screen = one level. Flat 2-colour levels, a tiny runner, hidden traps, and
one small white door. No copied assets, characters, levels, or names from any
other game — everything here is original.

Made by Ahmed.

## How to play

- Move with the left / right arrows, jump with the big up-arrow button.
- Reach the white door. Spikes, saws, falling floors, and dropping pillars
  restart the level instantly. Watch for dotted lines — they warn of traps.
- Complete levels to unlock the next ones. Progress is saved on the device.

## Build (CI)

Pushing to `main` builds the Android APK with GitHub Actions
(`.github/workflows/build-godot-apk.yml`): Godot 4.3-stable, export templates,
Temurin JDK 17, Android SDK 34, no Gradle build. The signed APK is uploaded as
the `trap-tower-apk` artifact.

## Layout

- `godot/` — the Godot project (all art is drawn in code; no binary assets).
  - `godot/data/tuning.json` — frozen physics + palette constants.
  - `godot/data/levels.json` — shipped levels (generated; see below).
- `tools/make_icon.py` — generates the launcher icon (`godot/assets/icon.png`,
  stdlib only, deterministic). The PNG is a build artifact and is not
  committed; CI runs this before the Godot import step.
- `tools/generate_levels.py` — level generator (templates x variations).
- `tools/check_levels.py` — static solvability + distinctness verifier.
- `tools/autopilot/` — headless playthrough verification through real physics.
- `tools/touch_test/` — injected multi-touch input tests.
- `LEVEL_SCHEMA.md` — the frozen level-data contract (v1).

Levels are data-driven: every shipped level must pass the static harness AND a
headless autopilot playthrough. The verified count is reported from the
verification run, never assumed.

## Local development

Requires Godot 4.3-stable. Open `godot/project.godot`, or run headless:

```sh
python3 tools/make_icon.py   # generate launcher icon (not committed)
godot --headless --path godot --import
python3 tools/generate_levels.py
python3 tools/check_levels.py
```
