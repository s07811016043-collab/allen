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

## The classified gesture behind a touch: &"tap", &"stroke", &"scratch",
## &"tickle", &"grab". `quality` in [-1, 1] is how much the pet liked it.
## The coarse signals above stay for listeners that only care *that* a touch
## happened; this one is for audio and VFX, which need to tell a chin scratch
## from a tail yank.
signal pet_gesture(pet_id: StringName, gesture: StringName, region: StringName, quality: float)
## The pet's visible answer to a touch: &"purr", &"lean_in", &"roll_over",
## &"knead", &"flinch", &"swipe", &"pull_away", &"freeze", &"wag".
signal pet_reacted(pet_id: StringName, reaction: StringName, intensity: float)
## A dropped pet touched down. `impact` in [0, 1]; `upright` is whether the
## righting reflex finished before the ground did.
signal pet_landed(pet_id: StringName, impact: float, upright: bool)

# --- Creature state ----------------------------------------------------------

signal affection_changed(pet_id: StringName, value: float, delta: float)
## Trust is the *touch* bond, distinct from affection: it gates which body
## regions the pet will let you near. A cat can adore you and still not offer
## its belly.
signal trust_changed(pet_id: StringName, value: float, delta: float)
signal mood_changed(pet_id: StringName, mood: StringName)
signal need_critical(pet_id: StringName, need: StringName)
## Fired once when a pet crosses into a new life stage.
signal stage_advanced(pet_id: StringName, stage: int)
signal milestone_unlocked(pet_id: StringName, milestone_id: StringName)
signal pet_vocalised(pet_id: StringName, call_id: StringName, intensity: float)
## A remembered moment was written down. The journal is what a returning player
## reads; UI listens here so it can surface the entry as it happens.
signal journal_entry(pet_id: StringName, entry_id: StringName, text: String, at: float)
## The pet noticed you came back after being away. `away_seconds` is the *true*
## absence, uncapped, so the greeting can scale from a glance to a fuss.
signal pet_greeted(pet_id: StringName, away_seconds: float)
signal pet_startled(pet_id: StringName, intensity: float)

# --- Behaviour ---------------------------------------------------------------

## The brain switched behaviours. Audio and VFX hang idle loops off this rather
## than polling the brain.
signal behaviour_changed(pet_id: StringName, behaviour_id: StringName, previous: StringName)
## Cat physics applied to a desktop icon.
signal pet_knocked_off(pet_id: StringName, ledge_id: int, label: String)

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
