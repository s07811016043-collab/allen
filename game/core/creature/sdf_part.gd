@tool
class_name SDFPart
extends Resource

## A single volumetric primitive that contributes to a creature's implicit body.
##
## Petalia builds every creature out of smooth-blended capsules rather than
## bitmap sprites. A capsule is defined by two endpoints and a radius at each
## end; the renderer unions them with a polynomial smooth-minimum, then lifts
## the resulting 2D field into a height field so it can be lit like a solid.
##
## Because the body is implicit, silhouettes stay perfectly smooth at any zoom,
## normals are analytic (no normal maps to author), and growth is just a
## continuous reinterpretation of the same numbers.
##
## Coordinate space
## ----------------
## Endpoints are expressed in *rig space*: unit-less units where 1.0 is roughly
## the adult creature's shoulder height. `bone_a` / `bone_b` name rig bones; at
## runtime the rig overwrites `a` / `b` with the live bone positions, so the
## authored values act as the bind pose.

## Surface families. The body shader branches on these to pick a coat model.
enum Surface {
	FUR,      ## Mammal coat: anisotropic strand shading, soft silhouette fringe.
	FEATHER,  ## Barbed vanes with thin-film iridescence.
	SCALE,    ## Tiled keratin plates with parallax depth and sharp speculars.
	SKIN,     ## Bare hide: paw pads, beaks, noses, bellies.
	CLAW,     ## Hard keratin: claws, talons, horns, beak tips.
	EYE,      ## Handled by the dedicated eye pass; body pass masks it out.
}

## Rendering layer. Parts are composited back-to-front so that, for example, a
## far-side leg reads as being behind the torso even though the field is 2D.
enum Layer {
	BEHIND = 0,  ## Far limbs, far ear, tail when tucked.
	BODY = 1,    ## Torso, head, near limbs.
	FRONT = 2,   ## Near ear, muzzle, chest ruff, wing when raised.
}

@export_group("Identity")
## Stable name, used by rigs and behaviours to look a part up.
@export var id: StringName = &""
## Bone driving `a`. Empty means `a` stays at its authored position.
@export var bone_a: StringName = &""
## Bone driving `b`. Empty means `b` stays at its authored position.
@export var bone_b: StringName = &""

@export_group("Geometry")
## First endpoint of the capsule spine, in rig space.
@export var a: Vector2 = Vector2.ZERO
## Second endpoint of the capsule spine, in rig space.
@export var b: Vector2 = Vector2(0.0, 0.1)
## Radius at endpoint `a`.
@export_range(0.001, 2.0, 0.001) var radius_a: float = 0.1
## Radius at endpoint `b`.
@export_range(0.001, 2.0, 0.001) var radius_b: float = 0.1
## Smooth-union blend radius against neighbouring parts. Larger values melt
## parts together (good for a torso meeting a hip); near-zero keeps a crisp
## join (good for a claw meeting a toe).
@export_range(0.0, 0.5, 0.001) var blend: float = 0.06
## Scales the height the field is lifted to. Below 1.0 flattens the part into a
## slab (ears, wings, webbing); above 1.0 makes it read as rounder than wide.
@export_range(0.05, 3.0, 0.01) var height_scale: float = 1.0

@export_group("Shading")
@export var surface: Surface = Surface.FUR
## Index into the creature's palette. Keeping colour indirect means a whole
## coat can be recoloured (growth, mood, breed variant) without touching parts.
@export_range(0, 15, 1) var palette_index: int = 0
## Direction fur/feathers lie, in radians, in rig space. Ignored by SCALE/SKIN.
@export_range(-PI, PI, 0.01) var groom_angle: float = 0.0
## How strongly this part's coat stands proud of the silhouette (0 = shaved).
@export_range(0.0, 1.0, 0.01) var coat_length: float = 1.0
@export var layer: Layer = Layer.BODY

@export_group("Growth")
## Radius multiplier at the baby stage. Babies are famously all head and paws,
## so per-part growth curves are what sell the silhouette change.
@export_range(0.1, 4.0, 0.01) var baby_radius_scale: float = 1.0
## Rig-space offset applied at the baby stage, blended out as the pet grows.
@export var baby_offset: Vector2 = Vector2.ZERO
## Length multiplier at the baby stage (limbs are stubby before they stretch).
@export_range(0.1, 4.0, 0.01) var baby_length_scale: float = 1.0


## Number of `vec4` slots one part occupies in the shader uniform block.
const FLOATS_PER_PART := 12
const VEC4S_PER_PART := 3


func duplicate_part() -> SDFPart:
	var p := SDFPart.new()
	p.id = id
	p.bone_a = bone_a
	p.bone_b = bone_b
	p.a = a
	p.b = b
	p.radius_a = radius_a
	p.radius_b = radius_b
	p.blend = blend
	p.height_scale = height_scale
	p.surface = surface
	p.palette_index = palette_index
	p.groom_angle = groom_angle
	p.coat_length = coat_length
	p.layer = layer
	p.baby_radius_scale = baby_radius_scale
	p.baby_offset = baby_offset
	p.baby_length_scale = baby_length_scale
	return p
