extends Node

## Global signal hub.
##
## Petalia's subsystems (input, brain, audio, VFX, UI, save) all want to react
## to the same handful of moments. Routing those through one bus keeps the
## creature from having to know that a particle system or an achievement
## tracker exists.

# --- Interaction -------------------------------------------------------------

## The player touched a creature. `region` is a body-part id such as &"head",
## &"belly", &"tail"; `local` is the hit point in rig space.
signal pet_touched(pet_id: StringName, region: StringName, local: Vector2)
## A sustained stroke, emitted continuously while the cursor drags across fur.
signal pet_stroked(pet_id: StringName, region: StringName, speed: float)
signal pet_grabbed(pet_id: StringName)
signal pet_released(pet_id: StringName, velocity: Vector2)
signal pet_fed(pet_id: StringName, food_id: StringName)
signal pet_played_with(pet_id: StringName, toy_id: StringName)

# --- Creature state ----------------------------------------------------------

signal affection_changed(pet_id: StringName, value: float, delta: float)
signal mood_changed(pet_id: StringName, mood: StringName)
signal need_critical(pet_id: StringName, need: StringName)
## Fired once when a pet crosses into a new life stage.
signal stage_advanced(pet_id: StringName, stage: int)
signal milestone_unlocked(pet_id: StringName, milestone_id: StringName)
signal pet_vocalised(pet_id: StringName, call_id: StringName, intensity: float)

# --- World / desktop ---------------------------------------------------------

## The desktop layout changed: icons moved, a window opened, resolution changed.
signal desktop_topology_changed()
signal pet_reached_ledge(pet_id: StringName, ledge_id: int)

# --- Meta --------------------------------------------------------------------

signal game_loaded()
signal game_saved()
signal settings_changed(key: StringName)
## Raised by the capture harness so scenes can freeze animation deterministically.
signal capture_requested(shot_id: StringName)
