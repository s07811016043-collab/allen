# Open visual defects

Live worklist for the iteration loop. Each entry is something visible in a
capture, ranked by how much it costs the AAA read. Delete an entry only after a
capture proves it fixed — not after the code changes.

Reproduce the current state with:

```bash
tools/capture.sh --species=cat --growth=3 --out=_captures/adult.png --size=640x640
tools/capture.sh --species=cat --growth=0 --out=_captures/baby.png  --size=640x640
tools/capture.sh --species=cat --growth=3 --out=_captures/head.png  --size=640x640 --zoom=3.4 --focus=head
```

## Blocking

1. **The tail still clips the frame edge.** `_body_span()` measures the bind
   pose, but the tail spring settles wider than the pose it measured. Measure
   the posed extent after the rig has run, or pad by the tail chain's reach.
2. **Far-side limbs are invisible.** The `BEHIND` layer exists and the parts are
   there, but they read as part of the torso rather than as legs on the other
   side of the animal. Depth separation needs to be much stronger: occlusion
   from the near body, desaturation, and a real value gap. Right now the cat
   looks like it has two legs.
3. **The coat reads as smooth clay, not fur.** At body scale the strand field
   smears into soft blotches; the animal looks wet or shaved. This is the single
   biggest thing between the current frame and a premium one.

### Closed

- ~~The cat floats above its shadow.~~ It never did. `tests/_ground_probe.gd`
  measures the *posed* creature — after gait, IK, springs and idle have run —
  and the lowest point sits at `y = 0.0000` at idle and within 0.007 during a
  walk. The gap was the capture harness drawing the shadow ellipse below the
  ground line: the shader centres it at UV y = 0.62, and the rect was not
  offset by that fraction of its own height. Worth remembering as a method
  note — the visible symptom pointed at the rig and the cause was in the tool
  looking at it.

## Material and form

4. **Fur reads as brushstrokes, not hair.** The strand field is directional but
   the strokes are too long, too uniform in width, and too high in contrast at
   body scale. Real coats are dense and fine, with clumping at a much larger
   scale than the individual strands.
5. **The torso is a smooth tube.** No scapula, no ribcage, no hip point, no
   spine. A cat's back has landmarks and the light should find them.
6. **Tabby markings are absent.** The palette carries a stripe colour that the
   body never uses, so the coat is one flat brown.
7. **No whiskers.** The part budget is nearly full (26 of 28), so whiskers have
   to be a shader feature keyed off the muzzle, not new capsules.
8. **No mouth.** The muzzle is an undifferentiated white mass; a cat's mouth
   line and the split of the upper lip are cheap and very legible.

## Growth

9. **The kitten is not convincingly a kitten.** Proportions are now compact
   rather than loaf-shaped, but the read still depends almost entirely on head
   size. Kittens also have a domed forehead, a much shorter muzzle, softer
   paws, and a tail carried differently.

## Not yet reviewable

- Animation: `--anim`, `--t` and `--strip` exist in the harness. Nobody has
  rendered a contact sheet and checked foot planting, diagonal couplets, tail
  lag, or bob phase against the footfalls.
- UI and VFX have preview scenes but no rendered, inspected frames.
- Dog, bird and reptile do not exist yet.
- Audio has no synthesiser; `AudioDirector` logs that it is silent.
