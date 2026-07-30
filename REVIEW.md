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

1. **The cat floats.** Paws sit well above the contact shadow in every full-body
   shot, and the bind pose measurably grounds at `y = 0` (see
   `tests/_ground_probe.gd`), so the lift is introduced by the rig — idle bob,
   leg IK target height, or the root offset. A pet that does not touch the
   surface it is standing on has no weight, and nothing else in the frame can
   compensate for that.
2. **The tail clips the frame edge.** `_body_span()` measures the bind pose, but
   the rig poses the creature afterwards and the tail spring swings wider than
   the pose it measured. Measure the posed extent, or pad the fit by the tail
   chain's reach.
3. **Far-side limbs are invisible.** The `BEHIND` layer is there and the parts
   exist, but they read as part of the torso rather than as legs on the other
   side of the animal. Depth separation needs to be much stronger: occlusion
   from the near body, desaturation, and a value gap.

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
