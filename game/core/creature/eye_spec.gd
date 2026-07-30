@tool
class_name EyeSpec
extends Resource

## One eye.
##
## Eyes get their own contract rather than being ordinary `SDFPart`s because
## they are the single highest-leverage thing on the creature. Everything a
## player reads as "alive" — where it is looking, whether it trusts you, whether
## it just heard something behind it — arrives through two small discs. They
## need a cornea that refracts, a pupil that dilates with mood and light, a
## limbal ring, wet catchlights that track the key light, and lids that blink
## and squint. None of that is expressible as a capsule.
##
## Authored in rig space, same convention as `SDFPart`.

@export_group("Placement")
@export var id: StringName = &"eye"
## Bone that carries this eye. The rig writes the live centre each frame.
@export var bone: StringName = &"head"
@export var center: Vector2 = Vector2(0.42, -0.76)
## Eyeball radius in rig units.
@export_range(0.002, 0.3, 0.001) var radius: float = 0.032
## Rotation of the lid aperture, radians. Slanting the lids is most of the
## difference between a friendly and a haughty face.
@export_range(-1.5, 1.5, 0.01) var tilt: float = 0.0
## How deep the eye sits in its socket. Higher values darken the socket rim and
## push the catchlight further under the brow.
@export_range(0.0, 1.0, 0.01) var socket_depth: float = 0.35

@export_group("Iris")
@export_range(0.1, 1.0, 0.01) var iris_ratio: float = 0.62
@export_range(0.05, 1.0, 0.01) var pupil_ratio: float = 0.45
## 0 = round pupil (dogs, most birds), 1 = fully vertical slit (cats, geckos).
@export_range(0.0, 1.0, 0.01) var pupil_slit: float = 0.0
@export var iris_color: Color = Color(0.42, 0.62, 0.25)
## Outer limbal ring, usually a much darker version of the iris. Its presence is
## a large part of why an eye reads as wet and deep rather than as a sticker.
@export var limbal_color: Color = Color(0.06, 0.09, 0.05)
@export var sclera_color: Color = Color(0.93, 0.92, 0.90)

@export_group("Lids")
## Bind-pose openness, 0 = shut, 1 = wide.
@export_range(0.0, 1.0, 0.01) var lid_open: float = 1.0
## Palette index used for the eyelid, so lids match the surrounding coat.
@export_range(0, 15, 1) var lid_palette_index: int = 0

@export_group("Growth")
## Eye radius multiplier at the baby stage. Neoteny lives here: oversized eyes
## are the strongest single "this is a baby" signal we have.
@export_range(0.5, 3.0, 0.01) var baby_radius_scale: float = 1.55
## Babies' pupils sit wider open too.
@export_range(0.5, 2.0, 0.01) var baby_pupil_scale: float = 1.3


## Live per-frame state, owned by the rig and read by the renderer. Kept as a
## separate object so the authored spec stays immutable.
class Live:
	var center := Vector2.ZERO
	var radius := 0.03
	var tilt := 0.0
	var iris_ratio := 0.62
	var pupil_ratio := 0.45
	var pupil_slit := 0.0
	var iris_color := Color(0.42, 0.62, 0.25)
	var limbal_color := Color(0.06, 0.09, 0.05)
	var sclera_color := Color(0.93, 0.92, 0.90)
	## Where the eye is looking, in [-1, 1] of the eyeball's travel.
	var gaze := Vector2.ZERO
	## 0 = open, 1 = fully shut. Driven by the blink and squint systems.
	var blink := 0.0
	## Multiplier on pupil size: fear and darkness widen, contentment and glare
	## narrow. Range roughly [0.4, 2.2].
	var pupil_scale := 1.0
	var lid_open := 1.0
	var socket_depth := 0.35
	var lid_palette_index := 0

	func copy_from(s: EyeSpec) -> void:
		center = s.center
		radius = s.radius
		tilt = s.tilt
		iris_ratio = s.iris_ratio
		pupil_ratio = s.pupil_ratio
		pupil_slit = s.pupil_slit
		iris_color = s.iris_color
		limbal_color = s.limbal_color
		sclera_color = s.sclera_color
		lid_open = s.lid_open
		socket_depth = s.socket_depth
		lid_palette_index = s.lid_palette_index
