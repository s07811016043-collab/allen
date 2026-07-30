@tool
class_name CreatureSpec
extends Resource

## Everything that makes one species one species.
##
## A spec is pure data: the implicit body parts, the palette, how the body
## reproportions as it grows, how it walks, how it sounds, and how it behaves.
## Two specs sharing the same code produce a cat and a bearded dragon.

## The four life stages. Growth is continuous — `GameState` keeps a float in
## [0,3] and the renderer interpolates — but stages give designers named anchors
## and give the player milestones worth caring about.
enum Stage { BABY, CHILD, TEEN, ADULT }

## Broad locomotion family. Drives which gait solver and which idle set is used.
enum Locomotion {
	QUADRUPED,   ## Cats, dogs, most reptiles: diagonal-couplet gaits.
	BIPED_HOP,   ## Perching birds on the ground: hop or alternating walk.
	SPRAWLING,   ## Lizards: laterally splayed limbs, body undulation.
}

@export_group("Identity")
@export var species_id: StringName = &""
@export var display_name: String = ""
## Shown in the adoption screen and the journal.
@export_multiline var blurb: String = ""

@export_group("Body")
## Bind-pose implicit parts. Order is irrelevant; `SDFPart.layer` decides depth.
@export var parts: Array[SDFPart] = []
## Up to 12 colours referenced by `SDFPart.palette_index`.
@export var palette: PackedColorArray = PackedColorArray()
## Height of the adult creature in rig units, used to normalise scale.
@export_range(0.1, 4.0, 0.01) var adult_height: float = 1.0
## Screen pixels per rig unit at 100% UI scale, adult stage.
@export_range(16.0, 512.0, 1.0) var pixels_per_unit: float = 180.0

@export_group("Coat")
@export var coat_surface: SDFPart.Surface = SDFPart.Surface.FUR
## Base strand/barb/plate length in rig units.
@export_range(0.0, 0.2, 0.001) var coat_length: float = 0.02
## Strand density multiplier. Higher reads as plusher and finer.
@export_range(0.1, 8.0, 0.01) var coat_density: float = 1.0
## How much the coat scatters light through thin areas (ears, wings, webbing).
@export_range(0.0, 1.0, 0.01) var translucency: float = 0.35
## Specular roughness of the coat.
@export_range(0.02, 1.0, 0.01) var roughness: float = 0.55

@export_group("Face")
## Up to `CreatureRenderer.MAX_EYES` eyes. Two for everything so far, but the
## contract does not assume it.
@export var eyes: Array[EyeSpec] = []
## Resting blink interval in seconds; the rig jitters around this.
@export_range(0.5, 20.0, 0.1) var blink_interval: float = 4.5

@export_group("Growth")
## Real-world hours to advance one full stage at default pacing.
@export_range(0.5, 400.0, 0.5) var hours_per_stage: float = 24.0
## Overall body scale at each stage, adult == 1.0.
@export var stage_scale := PackedFloat32Array([0.42, 0.62, 0.83, 1.0])
## Head-to-body ratio bonus per stage. Babies are top-heavy; this is most of
## why a baby reads as a baby rather than as a shrunken adult.
@export var stage_head_bias := PackedFloat32Array([1.45, 1.24, 1.09, 1.0])
## Eye-size multiplier per stage — the other half of the neoteny cue.
@export var stage_eye_bias := PackedFloat32Array([1.5, 1.28, 1.1, 1.0])

@export_group("Motion")
@export var locomotion: Locomotion = Locomotion.QUADRUPED
## Comfortable walking speed, rig units per second, at adult scale.
@export_range(0.05, 8.0, 0.01) var walk_speed: float = 0.9
@export_range(0.1, 16.0, 0.01) var run_speed: float = 2.6
## Stride length in rig units. Together with speed this sets step frequency.
@export_range(0.05, 2.0, 0.01) var stride: float = 0.45
## Vertical bob amplitude as a fraction of body height.
@export_range(0.0, 0.4, 0.005) var bob: float = 0.04
## How high the creature can jump, in rig units — gates the ledge graph.
@export_range(0.1, 8.0, 0.05) var jump_height: float = 1.4
## Can it stick to and climb vertical surfaces (window edges, icon stacks)?
@export var can_climb: bool = false
## Can it fly between ledges instead of pathing along them?
@export var can_fly: bool = false

@export_group("Personality")
## 0 = placid, 1 = manic. Scales idle frequency and reaction sharpness.
@export_range(0.0, 1.0, 0.01) var energy: float = 0.5
## 0 = aloof, 1 = clingy. Drives how far it strays from the cursor.
@export_range(0.0, 1.0, 0.01) var affection_drive: float = 0.5
## 0 = incurious, 1 = investigates every new icon and window.
@export_range(0.0, 1.0, 0.01) var curiosity: float = 0.5
## 0 = fearless, 1 = startles at fast cursor movement and loud typing.
@export_range(0.0, 1.0, 0.01) var skittishness: float = 0.4

@export_group("Voice")
## Base pitch in Hz for the procedural voice synthesiser at adult stage.
@export_range(60.0, 2000.0, 1.0) var voice_hz: float = 320.0
## Babies speak higher. Multiplier applied at the baby stage.
@export_range(1.0, 4.0, 0.01) var baby_voice_scale: float = 1.9
## Formant character: 0 = breathy/airy, 1 = nasal/buzzy.
@export_range(0.0, 1.0, 0.01) var voice_timbre: float = 0.5


## Per-stage lookup with graceful fallback for short arrays.
static func _sample(arr: PackedFloat32Array, growth: float, fallback: float) -> float:
	if arr.is_empty():
		return fallback
	var g: float = clampf(growth, 0.0, float(arr.size() - 1))
	var i: int = int(floor(g))
	var j: int = mini(i + 1, arr.size() - 1)
	return lerpf(arr[i], arr[j], g - float(i))


## Body scale at a continuous growth value in [0, 3].
func scale_at(growth: float) -> float:
	return _sample(stage_scale, growth, 1.0)


## Head enlargement factor at a continuous growth value.
func head_bias_at(growth: float) -> float:
	return _sample(stage_head_bias, growth, 1.0)


## Eye enlargement factor at a continuous growth value.
func eye_bias_at(growth: float) -> float:
	return _sample(stage_eye_bias, growth, 1.0)


## How much of the "baby proportions" morph is still applied, 1 → 0 over the
## first two stages. Kept separate from scale so limbs can lengthen on their
## own schedule.
func babyness_at(growth: float) -> float:
	return clampf(1.0 - growth / 2.0, 0.0, 1.0)


func find_part(part_id: StringName) -> SDFPart:
	for p in parts:
		if p != null and p.id == part_id:
			return p
	return null


func palette_color(index: int) -> Color:
	if palette.is_empty():
		return Color(0.8, 0.7, 0.6)
	return palette[clampi(index, 0, palette.size() - 1)]
