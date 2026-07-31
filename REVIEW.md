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

## Blocking — round 5 blind review at 260 px, most damaging first

The reviewer identified the build as *"a small four-legged mammal — probably a
cat, possibly a whippet or a young deer."* The head is now convincingly feline;
the body is not. Everything below is body.

1. **The legs are collinear, so the silhouette has two columns, not four.** In
   the standing pose the near and far leg of each pair sit on the same x, so
   there is no negative space inside a pair — and negative space is what tells
   the eye it is looking at a quadruped. Stagger the stance in the spec.
2. **There is no chest.** Below the neck the front of the body drops as a flat
   vertical wall to the foreleg, because no capsule fills the brisket between
   the forelimbs. A cat's chest is the deepest part of its body.
3. **The hind limb is an L with no hock zigzag.** The double-bend of a feline
   hind leg is the single most recognisable cue in the animal and it is absent.
4. **Groom runs lengthwise along the whole torso regardless of surface flow**, so
   the strokes cross the form instead of wrapping it — and at 260 px that is
   *precisely* what aliases into wood grain. This is the root cause the previous
   two coat passes were treating symptomatically.
5. **The belly is a blown-out pale slab** with a hard straight bottom edge, at
   essentially the same value as the lit back. No occlusion where the limbs
   enter the body, no ground-bounce gradient on the underside.
6. **No per-paw contact shadow in the standing shot.** `contact_shadow.gd` grew
   the capability but the standing capture still shows one body-wide ellipse, so
   nothing disambiguates the fused leg pair.
7. **Animation regressed to 3/10.** Body pitch, tail lag and a live idle were
   the brief last round and the reviewer still reads the torso as carried
   furniture. Re-measure with `--probe` rather than assuming the fix landed.

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
