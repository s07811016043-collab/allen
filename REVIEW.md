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

## Blocking — ranked by an independent reviewer, most damaging first

1. **The read collapses at ship size.** Coat detail is scale-locked: hair
   strokes vanish, tabby bars turn into plank grain, legs become uniform-width
   noodles with no paw shape. Drive stroke frequency and marking edge softness
   off on-screen pixels-per-unit rather than rig units, and add a broad
   low-frequency value break — a dark saddle over the shoulders, a pale chest
   bib — that carries the read at 200 px when no fine detail survives.
2. **The cat reads as a dachshund.** The torso is far too long for its shoulder
   height and the foreleg attaches near mid-torso, leaving a long unsupported
   neck-and-chest cantilever. This is an over-correction of the earlier
   too-short body. Shorten the lumbar run, move the scapula forward to about
   22% of body length, and give the shoulder an actual mass so the front leg
   stops being a stick pinned to a barrel.
3. **Far-side limbs are flat dark shapes.** They have no coat strokes, no rim
   and no fringe, so they read as painted shadow rather than as limbs. Run the
   same fur shading on the BEHIND layer at reduced contrast instead of replacing
   it with a flat tint; add a thin cool rim and slight desaturation so it
   recedes atmospherically.
4. **Everything above the legs is a rigid plank.** The probe reports body pitch
   of exactly +0.00 on every frame of a walk cycle, head travel of 0.015 units
   and tail travel of 0.03. The idle is functionally frozen: two frames two
   seconds apart are pose-identical. Drive pitch and shoulder/hip counter-roll
   off gait phase, let the tail lag the hips by ~120 ms so it sways and
   overshoots, and give idle a real loop.
5. **Tabby bands are hard-edged rectangles.** Constant width and value over the
   spine and down the flank, with square clipped ends, so the body reads as a
   painted barrel. Taper each band and fade it toward both ends, and modulate by
   surface normal so bands narrow as they wrap away from the light.
6. **The coat is uniformly matte.** No anisotropic sheen anywhere, so a
   3D-shaded form is lit like felt. Add a fur sheen lobe biased along the stroke
   direction, strongest across the back and the top of the tail.
7. **Eyes: the iris is the best asset in the build, and the rest of the eye
   undoes it.** The specular is a hard-edged white rounded rectangle pasted at
   an identical position on both eyes; no eyelid ever overlaps the top of the
   iris, so both eyes are perfect circles and the cat looks permanently
   startled. Make the highlight an elliptical soft reflection positioned from
   the light vector and the eyeball normal, cut the top ~15% of each iris with a
   lid arc and a contact shadow, add a tear-duct wedge — and add whiskers, which
   do not exist at all.
8. **Grounding is mathematically perfect and visually absent.** The probe reports
   slip and sink of exactly 0.0000 on every stance foot, but the shadow is a
   single body-wide ellipse, so a correctly planted paw still reads as
   levitating. Composite one tight, high-opacity contact patch per stance paw on
   top of the broad ambient ellipse.
9. **A cross-hatched etch artifact over the brow** where the SDF blend gradient
   is steep. Clamp the stroke displacement by the blend-field gradient
   magnitude.

## Core bugs found while authoring the bird

Found by dumping *posed* geometry instead of trusting the bind pose. All three
are in files another agent owned at the time, so they were reported rather than
patched. They affect every species, not just the bird.

10. **`marking_strength` is never set.** It is a shader uniform and
    `CreatureRenderer` has zero occurrences of it, so the mammal tabby code runs
    at full strength on birds and reptiles. On the bird this lightened the navy
    wing into four hard blocks that looked exactly like a wing geometry bug and
    were actually a palette-luminance bug.
11. **The FEATHER path was gated off at ship scale.** `pet_feather` gates relief,
    occlusion and iridescence on a term where *raising* density closes the gate —
    the comment had the inequality backwards. At the shipped density the gate
    evaluated to exactly 0.00, so the bird had no vanes and no thin-film at all.
12. **`Slot.WING` parts are fitted twice** in `RigSkeleton.build`; the `fore`
    loop is only skipped for `Slot.LIMB`. Duplicate bone names mean parts bind
    against the wrong rest transform, which collapsed the wing. Worked around in
    the bird spec by naming the parts so they classify as `SPINE`; the rig bug
    itself is still there.
13. **Captures shade at roughly twice ship scale.** The harness fits the pose to
    the frame, so a 560 px shot runs at an effective 294 px per rig unit against
    a nominal 158. Any density tuned by eye in a capture is tuned at the wrong
    scale — another face of the ship-size problem.

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
