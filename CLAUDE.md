# Petalia — AAA desktop pet

A Godot 4.5 desktop companion: cats, dogs, birds and reptiles that live on the
user's desktop, roam between icons, react to touch, build affection, and grow
from baby to adult over real days.

The bar is a AAA-quality game, not a hobby toy. Every visual decision should be
defensible next to a shipped premium title.

## Running things

Godot lives at `.tools/Godot_v4.5-stable_linux.x86_64` (not in git). There is no
GPU and no display in this container; everything runs through llvmpipe under
Xvfb, which the scripts handle.

```bash
# Render one deterministic frame. THIS IS THE PRIMARY FEEDBACK LOOP — use it.
tools/capture.sh --species=cat --growth=3 --out=_captures/cat_adult.png --size=560x560

# Flags: --species=cat|dog|bird|reptile  --growth=0..3  --size=WxH
#        --bg=checker|alpha|RRGGBB  --zoom=<f>  --contact=0|1  --pose=<name>
#        --frames=<n>  (frames to settle before the shot)

# Compile-check the whole project without rendering (fast, catches parse errors).
tools/check.sh
```

Then **look at the PNG with the Read tool**. Do not claim a visual result you
have not seen. A capture that prints `CAPTURE_OK` but that you never opened is
not evidence of anything.

Captures cost ~3 s each at 560x560 (software rasteriser). Larger frames scale
roughly with pixel count; 900x900 is about 8 s. Budget accordingly, but never
skip looking.

## Architecture

```
game/
  autoload/        singletons: Log, Settings, EventBus, Clock, SaveSystem,
                   DesktopBridge, AudioDirector, GameState
  core/
    creature/      SDFPart, CreatureSpec, Growth, Creature
    rig/           skeleton, spring chains, IK, gait
    render/        CreatureRenderer — packs parts into shader uniforms
    brain/         utility AI and behaviours
    nav/           ledge graph, pathfinding, platform providers
  shaders/         creature body/eye/post shaders (+ .gdshaderinc helpers)
  species/         one directory per species, each exposing `static func build()`
  ui/ vfx/ audio/  presentation layers
  scenes/          boot, world
  tools/capture/   the screenshot harness scene
```

### The one big idea: implicit bodies

Creatures are **not sprites**. Each animal is a list of tapered capsules
(`SDFPart`) that the body shader smooth-unions into a signed distance field,
lifts into a height field, and shades with analytic normals. Consequences worth
internalising:

- Silhouettes are resolution independent and always smooth.
- Normals are exact; there are no normal maps to author.
- Creases between parts self-occlude for free (the smooth-union blend amount
  *is* the ambient occlusion term).
- Growth is a continuous reinterpretation of the same numbers, not new art.
- Anything you want lit must be expressed as parts or as a shader term. There
  is nowhere to "paint" a detail.

Rig space convention, identical for every species:

- `+x` is forward; the creature faces right at rotation 0.
- `+y` is **down**, matching Godot 2D.
- The origin sits between the paws, on the ground plane.
- `1.0` unit ≈ adult shoulder height.

Parts sort into three depth layers (`BEHIND`, `BODY`, `FRONT`) which the shader
composites back to front, so a far leg reads as being behind the torso.

### Uniform budget

`CreatureRenderer.MAX_PARTS` is 28, three `vec4` each. GLES3 only guarantees 224
fragment uniform vectors, so 28 parts + a 12-entry palette + the lighting block
is already close to the floor. Do not raise it without measuring on
`gl_compatibility`.

## Conventions

- GDScript, tabs for indentation, static types on declarations where the type is
  not obvious from the right-hand side.
- Species are **code**, not `.tres`: `species/<id>/<id>_spec.gd` with a
  `static func build() -> CreatureSpec`. A species should read as a document.
- Colours go through the palette indirection, never hardcoded in a part.
- Comments explain *why*, at the density of the surrounding file. The existing
  files are the style reference — match them, do not exceed them.
- Never name a GDScript enum after a native class (`Material`, `Node`, `Timer`);
  the parser rejects it.

## Working rules for agents

- **Stay inside the files you were assigned.** Multiple agents work this repo in
  parallel; editing a file you do not own will be overwritten or will break
  someone else's build.
- **Do not run `git commit`, `git push`, `git checkout`, or `git stash`.** The
  orchestrator commits.
- Before you finish: run `tools/check.sh`, then render at least one capture and
  read it. Report honestly if it still looks wrong.
- If a contract in `core/` genuinely blocks you, say so in your result rather
  than editing it behind another agent's back.
