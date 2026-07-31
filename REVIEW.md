# Open visual defects

Live worklist. Each entry is something visible in a capture, ranked by how much
it costs the AAA read. Delete an entry only after a capture proves it fixed —
not after the code changes.

## Review at ship size, always

The pet lives on a desktop at roughly **150–300 px tall**. Every review until
now was done at 640–720 px, and that is why the coat kept passing: at review
zoom the strokes read as hair, and at ship size they collapse into plank grain.

An independent blind reviewer, shown the build with no context, called it *"a
carved wooden ox or deer figurine"* at 260 px and could not identify the
species. That is the verdict that matters, because that is the size a player
sees.

**A change is not accepted until it holds up at 260 px.** Render the ship size
first, and only then zoom in to diagnose.

```bash
tools/capture.sh --species=cat --growth=3 --out=_captures/ship.png  --size=260x260   # the one that counts
tools/capture.sh --species=cat --growth=3 --out=_captures/adult.png --size=720x720
tools/capture.sh --species=cat --growth=3 --out=_captures/head.png  --size=720x720 --zoom=3.4 --focus=head
```

## Blocking — round 6 blind review at 260 px, all four species

The cat now reads as a cat within a second, carried entirely by the head. The
reviewer checked every species at ship size for the first time, and three of the
four fail outright. A store page shows all four.

1. **THE DOG READS AS TWO-HEADED.** The curled Shiba tail has fused into a solid
   rear mass with a snout-like taper and no daylight under the arc, so at 260 px
   the animal is a pushmi-pullyu. Confirmed by eye — it is unmistakable. Open
   the arc so the tail reads as a tail, or drop the curl.
2. **The cat's body reads as a hairless Sphynx or a clay maquette.** Smooth
   latex with crater dents. The head sells the species and the body contradicts
   it. The coat is not reaching the torso at ship size.
3. **Every species carries the same white-streak-over-black-stipple seam along
   the belly.** One shared artifact, four animals — so it is in the shared
   marking or decal path, not in any species file.
4. **The lizard reads as a brass ornament** and **the bird floats off its own
   shadow.**
5. **Animation scored 2/10**, its lowest yet, and the tail is described as a
   rigid stick that never moves. Secondary motion has now been briefed twice
   without landing. Before writing anything, measure what is actually there with
   `--probe` and report the numbers; if the previous round's work is not
   present, find out why rather than writing it a third time.
6. **Grounding 3/10.** Per-paw contact patches were briefed and the bird still
   floats.

### Method notes worth keeping

- **The coat fringe closes about 3.6 px of any authored gap at ship size.** A
  0.038 rig-unit gap between the shins measured as *zero* rendered pixels. Three
  rounds of leg staggering had been signed off on the geometric number and none
  of it reached the picture. `_measure.gd` now names the constant and subtracts
  it. Measure in rendered pixels, never in rig units.
- **`f.crease` only accumulates within a depth layer.** A limb segment that
  unions with nothing arrives at its cap with zero occlusion and is the
  brightest thing on the animal — which is why the legs looked like doll limbs
  with pale knobs at every joint.
- **A debug view now exists.** `PETALIA_DEBUG_VIEW=<1..12>` renders groom
  direction, lane index, occlusion, marking mask and more straight to the
  framebuffer. Three of the four root causes found this round could not have
  been found by reasoning.

## Closed

- ~~The cat floats above its shadow.~~ It never did. `tests/_ground_probe.gd`
  measures the *posed* creature and the lowest point sits at `y = 0` at idle.
  The gap was the capture harness drawing the shadow ellipse below the ground
  line. A method note worth keeping: the symptom pointed at the rig and the
  cause was in the tool looking at it.
- ~~The tail clips the frame edge.~~ `_posed_extent()` measures the settled
  pose; fifteen contact sheets across every gait showed nothing clipped.
- ~~Feet skate during a walk.~~ Measured, not assumed: the probe reports
  `slip=0.0000` for every stance foot on cat, dog and reptile at every gait and
  growth stage. Walk touchdown order is a correct lateral sequence with
  diagonal partners 0.12 apart; trot is true diagonal pairs in antiphase.
- ~~The coat is smooth clay at review zoom.~~ Fixed at 720 px and confirmed by a
  blind A/B against the previous build — the reviewer chose the new build before
  being shown which was which. It still fails at ship size, which is item 1.

## Not yet reviewable

- UI and VFX have preview scenes but no rendered, inspected frames.
- Bird and reptile are in progress.
- No human has heard the audio; there is no device in this container.
