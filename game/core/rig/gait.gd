class_name Gait
extends RefCounted

## Procedural footfall timing, foot trajectories and body weight shift.
##
## Everything here is derived from one number — how fast the creature is
## actually moving — so the gait can never skate. Step frequency comes out of
## speed and stride length; a foot in stance is pinned to the ground it landed
## on and swept backwards by exactly the distance the body travelled.
##
## Timing is expressed as a phase offset per foot within a normalised cycle,
## plus a duty factor (fraction of the cycle a foot spends on the ground).
## That pair is the whole vocabulary of quadruped gait analysis and it is enough
## to describe every pattern we ship:
##
##   walk   4-beat lateral sequence, diagonal couplets. Footfall order is
##          hind-near, fore-near, hind-far, fore-far — each forefoot follows the
##          hindfoot on its own side, which is what "lateral sequence" means.
##          The couplets are the other half of it: a foot and its *diagonal*
##          partner land about an eighth of a cycle apart (fore-near at 0.38,
##          hind-far at 0.50). Duty 0.62, so at least two feet are always down.
##   trot   2-beat. True diagonal pairs, exactly in antiphase. Duty 0.45, which
##          buys two short suspensions.
##   run    rotary gallop, which is what a cat actually uses. The hind pair lands
##          in quick succession, then the fore pair, and the fore lead is the
##          mirror of the hind lead rather than a repeat of it. Duty 0.32, with a
##          long gathered suspension.
##   hop    both legs together, the ground gait of a perching bird.
##
## Body vertical motion is *not* a sine wave laid on top. It falls out of the
## legs: each supporting foot constrains the hip above it to sit at
## sqrt(reach² − dx²), so the body rises over a vertical leg and sinks at
## footfall. Bob is therefore in phase with the footfalls by construction, and
## stays in phase when the gait, speed or leg proportions change.

const RigBones := preload("res://core/rig/bone_map.gd")

enum Kind { IDLE, WALK, TROT, RUN, HOP }

## Foot slots, matching the order `LegIK.gather` returns.
const FORE_NEAR := 0
const FORE_FAR := 1
const HIND_NEAR := 2
const HIND_FAR := 3
const FOOT_COUNT := 4

## Footfall phase per slot, then duty factor, then two amplitudes: `lift` is how
## high the *feet* swing, `rise` is how far the *body* travels vertically, both as
## a multiple of what a walk does.
## Phase order: fore-near, fore-far, hind-near, hind-far.
##
## These were one number for four rounds, and that is why the walk had no body.
## A walking cat lifts its paws barely at all — it is the least athletic thing it
## does with its feet — and still drops its chest at every footfall and pushes it
## back up, because the vertical budget of a walk is spent in the *legs flexing*,
## not in the feet leaving the ground. Tied together, the only way to give the
## trunk a stride was to make the animal prance, so the trunk never got one: the
## walk's body budget sat at 1.00 by definition and delivered 11 px of trunk
## height at ship size against the gallop's 30, and the legs, which only bend as
## much as the body above them moves, stayed the four straight sticks a reviewer
## named. Split, the walk can have a real vertical without its feet leaving the
## floor. `rise` for the faster patterns is trimmed a little below the `lift` it
## used to share, because the spring below hands them back what the old follower
## was shearing off every landing.
const PATTERNS := {
	Kind.WALK: {"phase": [0.62, 0.12, 0.00, 0.50], "duty": 0.62, "lift": 1.00, "rise": 1.60},
	Kind.TROT: {"phase": [0.50, 0.00, 0.00, 0.50], "duty": 0.45, "lift": 1.35, "rise": 1.18},
	Kind.RUN: {"phase": [0.40, 0.49, 0.09, 0.00], "duty": 0.32, "lift": 1.75, "rise": 1.55},
	Kind.HOP: {"phase": [0.00, 0.00, 0.00, 0.00], "duty": 0.42, "lift": 2.10, "rise": 1.85},
}
## A biped walks its two legs in antiphase; the fore slots stay unused.
const BIPED_WALK := {"phase": [0.0, 0.0, 0.00, 0.50], "duty": 0.60, "lift": 1.15,
	"rise": 1.60}


class Foot:
	var slot := 0
	var present := false
	var phase := 0.0
	var stance := true
	## Rig-space IK target for the ankle.
	var target := Vector2.ZERO
	var pitch := 0.0
	## Height above the ground this leg permits its own limb root to ride at.
	var support := 0.0
	## The same height in the bind pose. Pitch and roll are differentials against
	## it, because a cat's hind legs are simply longer than its forelegs and the
	## raw difference would tilt the animal permanently nose-down.
	var support_ref := 0.0
	## Where in *ground* space the **contact patch** is pinned. Ground space is rig
	## space plus distance travelled, so a pinned foot is exactly stationary.
	var plant_ground := 0.0
	var lift_ground := 0.0
	var bind := Vector2.ZERO
	## Bind-pose offset from the ankle out to the contact patch, and where that
	## patch sits along the floor at rest. Stance solves the contact first and
	## derives the ankle from it, so rolling the foot cannot drag the paw.
	var contact_arm := Vector2.ZERO
	var contact_bind := Vector2.ZERO
	var root_bind := Vector2.ZERO
	var reach := 0.0
	## Height this limb's root would ride at with `bob` zeroed, measured off the
	## posed skeleton by the rig each step rather than derived from the bind pose.
	##
	## The reach constraint below is the only thing keeping a stance foot on the
	## floor, and it was solving against a hip that does not exist. Everything the
	## trunk does between the bind pose and the picture — pitch about the middle of
	## the back, lumbar flexion, the scapula riding up the ribcage, impact squash,
	## the idle layer's weight rock — moves the real hip and none of it was visible
	## here. Measured on the cat's gallop: a forefoot in stance hovering 0.21 units
	## short of its own target, which is a stance foot 34 px off the ground.
	var root_h0 := 0.0
	## True on the frame the foot touched down — drives impact squash and audio.
	var just_landed := false
	var landing_force := 0.0


var kind: int = Kind.IDLE
var speed := 0.0
## Distance covered, rig units. Feet are pinned against this, never against time.
var travel := 0.0
var cycle := 0.0
var frequency := 0.0
var duty := 0.62
var feet: Array[Foot] = []

## Body outputs, read by the rig once per frame. All three attitude channels are
## in radians of picture-plane rotation, so the rig applies them directly.
var bob := 0.0
var pitch := 0.0
var roll := 0.0
## Counter-rotation between the pectoral and pelvic girdles: the *total* twist
## across the trunk, which the rig splits half backwards into the croup and half
## forwards into the withers. Positive lifts the withers.
var girdle_twist := 0.0
## Sagittal curvature of the back: total radians of bend shared across the lumbar
## run, positive rounding the topline *up*. Distinct from `pitch`, which rotates
## the trunk rigidly — this is the only channel that changes the trunk's shape,
## and until it existed the torso could only ever translate and tilt, which is
## precisely what a blind reviewer called "furniture being carried".
var flex := 0.0
## Vertical slide of the pectoral girdle over the ribcage, rig units, positive up.
##
## A cat has no clavicle: the shoulder blade is slung in muscle and rides up the
## side of the ribcage every time the limb takes load. From the side that is the
## most conspicuous thing a walking cat's topline does, and it runs at twice the
## stride rate, so it is also the only body channel that is not in lockstep with
## the bob — which is what stops the whole animal reading as one oscillator.
var withers := 0.0
## Trunk pitch from the animal's own fore-aft acceleration, radians, positive
## nose-down. Separate from `pitch` and deliberately **not** gated on the gait
## running, because the whole event it exists for happens after the gait has
## stopped: a cat braking out of a trot rocks onto its forehand, hangs there, and
## rides back. Measured before this existed, post-brake pitch was exactly 0.0000
## — the animal halted like a parked vehicle, which is the last thing a body with
## mass does.
var brake := 0.0
var surge := 0.0
## Lateral body wave for sprawling locomotion, sampled per spine bone.
var undulation := 0.0
var turn := 0.0
## 0 at rest → 1 at full sprint. Drives breathing, coat fluff and audio.
var exertion := 0.0

## Fraction of full leg extension the body rides at when standing. Species author
## bind poses with straight legs because that is how a reference drawing looks,
## but a real animal always stands with the joints slightly flexed — and without
## that reserve the body has nowhere to bob up into, so the feet lift off the
## ground the moment the gait raises it. 5% of leg length is enough.
const STANCE_COMPRESSION := 0.95

## Trunk attitude gains, radians per unit of load asymmetry.
##
## Static geometry cannot produce these and it was a mistake to ask it to. A
## cat's legs are long next to its stride, so the fore and hind support heights
## differ by a couple of hundredths over a whole cycle; the trunk pitch that
## fell out of them measured 0.005 rad peak-to-peak, which is a fifth of a pixel
## at the size this pet actually ships at. An independent reviewer, shown the
## build cold, called the body "furniture being carried along", and that number
## is why.
##
## What pitches a trunk is the *load* handing over between the girdles, and load
## is a phase quantity: already normalised to [0, 1], identical for a kitten and
## an adult, and correct for every pattern in the table without a per-species
## calibration. It also self-checks — at a trot the diagonal pairs make the two
## girdles' loads identical, the imbalance is exactly zero, and a trotting animal
## really does hold its trunk still. That is the gait a rider posts to precisely
## because it does not pitch.
const PITCH_GAIN := 0.72
## Ceiling on trunk pitch. A gallop is often on a single leg and the raw
## imbalance goes past 0.4; 0.13 rad is about 7°, which is a hard-running cat.
const PITCH_MAX := 0.13
## Radians of counter-rotation between the girdles at full asymmetry. Small in
## absolute terms — it is the *opposition* that reads, not the amount.
##
## Sized against the picture rather than against the number. The rig splits the
## twist half backwards into the croup and all of it forwards along the lumbar,
## so the two ends of the trunk end up 1.5x this apart; at 0.064 that measured
## 0.10 rad of opposition, which over the cat's 0.45-unit half-trunk is 2.6 px at
## ship size — right at the floor of what a 260 px frame can show. The channel
## was doing its job and arriving as almost nothing.
const TWIST_GAIN := 0.090
## Whole-body lean from the near/far load split. A strict side view can barely
## show a roll at all, so this stays a hint rather than a statement.
const ROLL_GAIN := 0.022
## Radians of lumbar bend per unit of girdle gather, where one unit is the two
## girdles' feet closing by a whole trunk length.
##
## Driven off the actual gap between the fore and hind contact patches rather
## than off a phase table, which makes it self-scaling in the way that matters:
## at a walk the two feet of a pair are half a cycle apart so the gap barely
## moves and the back stays nearly rigid, while a gallop gathers both pairs under
## the body at once and the back rounds hard. That is the real difference between
## the two gaits and no per-gait constant has to encode it.
const FLEX_GAIN := 1.75
## Ceiling on that bend. A galloping cat's spine really does work through 30°+,
## but the trunk here is three capsules and pushing past this folds them into
## each other instead of arching.
const FLEX_MAX := 0.42
## Scapula travel at full load swing, as a fraction of leg reach.
##
## The most valuable body channel there is at ship size, and the reason is the
## frequency rather than the amplitude: it runs at twice the stride rate, so it
## is the only thing on the trunk that is not in lockstep with the bob, and a
## body whose every channel shares one phase is a body being carried. Measured on
## the cat at 0.30 it delivered 5.0 px of scapula travel against 7.6 px of bob;
## at 0.52 it delivers 8.6 px, which is a shoulder that visibly rides up the
## ribcage twice a stride instead of a topline that only translates.
const WITHERS_GAIN := 0.52
## Extra scapula travel per unit of bob deviation.
##
## The other half of what a shoulder blade does, and the half that only exists
## because a cat has no clavicle: the ribcage is slung between the blades, so when
## the trunk sinks the blades stay with the humerus and appear to *rise* out of
## the back. Load and sink are different phases of the same stride — the load term
## above peaks at mid-stance, this peaks at the bottom of the bob — and having
## both is what stops the withers being a rectified copy of one signal.
const WITHERS_BOB := 0.55
## Ceiling on total scapula travel, as a fraction of leg reach.
const WITHERS_MAX := 0.20
## Radians of topline rounding per unit of bob deviation.
##
## The back is what carries the body's weight between the girdles, so when the
## trunk drops the topline flattens and when it lifts the loin rounds under it.
## Small next to `FLEX_GAIN`, deliberately: the gather term owns the gallop and
## this one exists so a *walk*, which barely gathers at all, still has a topline
## that changes shape instead of a plank that translates.
const FLEX_BOB := 1.30
## Share of the trunk's vertical that comes from the *support force* rather than
## from leg geometry, measured as a fraction of the geometric term's own swing
## over the reference cycle.
##
## This is the term the walk was missing, and it is worth spelling out why,
## because the diagnosis took longer than the fix. Bob was derived purely from
## kinematics: average the height each stance leg permits its girdle to sit at,
## and follow it. At a gallop one leg is down at a time, so that average *is* one
## leg's pendulum and the curve has the shape of a stride. At a walk two or three
## legs are down at every instant and the average is dominated by *which* legs are
## currently in it — measured on the cat, the mean stepped as the count went
## 3-2-3-2 and came out as a single slow hump per stride, 0.027 units of it, with
## no footfall visible anywhere in the curve. One rock per stride is a boat, not a
## walk, and it is exactly what a reviewer means by a crate on four sticks.
##
## The signal that was thrown away is the one the body actually rides on: the
## total vertical support, which `load` already computes for the attitude channels
## and which the height solver never looked at. Its frequency content is correct
## for every pattern in the table without a single per-gait constant, because it
## falls out of the phase offsets: the walk's four feet sit at offsets 0.00, 0.12,
## 0.50 and 0.62, which is two antiphase pairs, and a pair in antiphase has no odd
## harmonics — so the walk and the trot both bounce **twice** per stride, and the
## gallop, whose offsets are all clustered, bounces once. That is the real
## difference between the gaits, and no table encodes it.
##
## Normalised against the geometric term's own swing rather than given an
## absolute size, so it means the same thing on a lizard and a whippet and so the
## authored `spec.bob` still decides the amplitude.
const BOUNCE_SHARE := 1.25
## Trunk vertical spring: natural frequency in rad/s and damping ratio.
##
## Bob was the last channel in this file still driven by a one-pole follower, and
## a one-pole cannot overshoot — it can only arrive late. At a gallop that did not
## show, because `_fly` supplies the overshoot for free: the body is a projectile
## and comes down with real momentum. At a walk nothing leaves the ground, so the
## trunk sat exactly on the height its legs implied, filtered, at every instant of
## every stride. A body with no mass is furniture by definition.
##
## Fast and only lightly underdamped, for the reason the trunk-shape spring next
## door already documents: the drive is at twice the stride rate wherever the
## couplets are in antiphase — 4 Hz at the cat's walk, 8 Hz at the dog's trot —
## and a spring slow enough to wallow prettily is a spring that arrives after the
## footfall that caused it. At 80 rad/s the lag against a walk's bounce is 26°
## where the follower it replaces sat at 17°, and the step overshoot is 8%: a
## landing that dips past its mark and comes back, which is the whole of what mass
## looks like from outside.
##
## `_bob_vel` is shared with the suspension, so a body that leaves the ground and
## lands arrives in stance still carrying its downward momentum instead of being
## snapped to rest by the first frame of support.
const BOB_OMEGA := 80.0
const BOB_ZETA := 0.62
## Radians of nose-down trunk rock per rig unit/s of speed the animal sheds, and
## the spring that carries it back.
##
## Fed as an **impulse** rather than as an acceleration, which is the only
## formulation that survives how speed actually arrives here. A scripted stop is
## a step — the brain writes 1.79 one frame and 0.0 the next — and the derivative
## of a step is one frame of a very large number, which any filter downstream
## turns into a shrug. Accumulating the *change* instead means the rock is sized
## by how much speed was lost and not by how many frames it took to lose it, so
## the same brake reads the same whether the pet eased to a halt or was told to
## stop dead.
##
## Slow and lightly damped, unlike everything else in this file: it is not
## tracking a footfall, it is one event with a long tail. 9.5 rad/s is a rock that
## takes about two thirds of a second to come back, and at ζ 0.34 it comes back
## past level and settles on the second swing — which is what a cat stopping
## actually does, and what "post-brake pitch is exactly 0.00" was the absence of.
const BRAKE_PITCH := 1.15
const BRAKE_OMEGA := 9.5
const BRAKE_ZETA := 0.34
## Ceiling on the rock, radians. Soft, like every other attitude limit here.
const BRAKE_MAX := 0.26
## What a sprawling animal keeps of a declared body rise.
##
## A lizard is a lateral undulator: the belly stays low and close to level and
## everything the trunk does is a wave in plan view, which `undulation` already
## carries. `pitch` and `flex` are already scaled down for the family here for
## the same reason; the height channel was the one that was not, and on a body
## that walks with its belly a fifth of a unit off the floor the extra sink goes
## straight through the ground plane.
const SPRAWL_RISE := 0.72
## Trunk-shape spring: natural frequency in rad/s and damping ratio.
##
## These were one-pole followers, and a one-pole cannot overshoot — it can only
## arrive late. A back and a shoulder are muscle and bone with mass on the end of
## them: they load, they pass the target, and they settle back. Q here is 1/(2ζ)
## = 0.77, below 1, so there is no resonant peak to find at any cadence we ship;
## what the spring buys is the small overshoot after each footfall, which is the
## difference between a shape that is *driven* and a shape that *responds*.
## Chosen against the *phase*, not the amplitude. A one-pole at the 22/s these
## used to run at is 45° late against a 3.6 Hz gallop, and a spring slow enough to
## overshoot prettily is later still — the head stabiliser next door was measured
## losing two thirds of its effect to exactly that. At 42 rad/s the spring is 41°
## late at a gallop and 22° at a walk, which is *less* lag than the follower it
## replaces while still passing the mark and settling back.
const TRUNK_OMEGA := 42.0
const TRUNK_ZETA := 0.62
## Downward acceleration of a trunk with no foot under it, rig units/s².
##
## A quadruped in flight is a projectile and nothing else. This used to hold the
## last support-derived height for the whole suspension, which measured as a flat
## line — the hopping bird's bob sat at exactly −0.047 for four consecutive frames
## of an eight-frame sheet, 58% of its cycle, and the cat's gallop held +0.006
## across the whole of its. A body that translates up, holds, and translates down
## is furniture being carried; a parabola is a body being thrown.
##
## 1.0 rig unit is adult shoulder height and this pet is drawn at roughly a
## quarter of a metre of it, so 9.81 m/s² lands near 38 rig units/s². One number
## for every species because the conversion is a property of the *scale the pet is
## drawn at*, not of the animal standing at it.
const GRAVITY := 38.0

var _spec: CreatureSpec
var _family: int = CreatureSpec.Locomotion.QUADRUPED
## Body height of *this* creature, not of the adult of its species. Every bob
## number in the spec is authored as a fraction of body height, and the rig it is
## applied to has already been scaled by growth — so reading `adult_height`
## straight gave a kitten the adult's absolute bob on a body 0.42 the size, which
## drove a walking kitten nearly four hundredths of a unit into the floor.
var _body_height := 1.0
var _stride_ref := 0.4
var _bob_gain := 1.0
## Rig units of trunk lift per unit of normalised support-force deviation, sized
## against the geometric term over the reference cycle so `BOUNCE_SHARE` reads as
## a ratio rather than as a magic length.
var _bounce_gain := 0.0
## Limbs this species actually authored. The support-force reference is a sum
## over them, and reading a missing forehand as a permanently unloaded pair would
## make a biped walk permanently light on its feet.
var _feet_present := 0
var _body_len := 0.5
## Mean support height over the reference cycle; bob oscillates around it.
var _support_ref := 0.5
## Mean leg reach. Sets the flexion reserve the body bobs into.
var _reach_ref := 0.5
## Constant downward offset that buys the legs their flexion reserve.
var _crouch := 0.0
## Gap between the fore and hind feet in the bind pose. `flex` is a differential
## against it, the same way `pitch` is a differential against `support_ref`: a
## species whose girdles sit unusually close together must not walk permanently
## hunched.
var _span_ref := 0.5
## Slow-followed mean of the fore girdle's load. Subtracting it makes `withers` a
## deviation by construction, so a gait whose duty factor gives the pair a high
## average load does not park the shoulder permanently raised.
var _fore_load_mean := 0.0
## The same trick for the bob, so the channels that ride it are deviations too and
## a crouched walk does not park the shoulder and the topline somewhere new.
var _bob_mean := 0.0
## Extra flexion carried once the animal is actually moving, faded in with speed.
var _move_crouch := 0.0
## Trunk vertical velocity while airborne, rig units/s, positive downward, plus
## the height the body left the ground at so the arc has something to close onto.
var _bob_vel := 0.0
var _airborne := false
var _liftoff_bob := 0.0
## Fraction of the current pattern's cycle with no foot on the ground. Sampled
## from the phase table rather than declared, so it stays right if the table
## changes and it is automatically zero for a species missing a limb pair.
var _air_frac := 0.0
## Spring velocities for the two trunk-shape channels.
var _flex_vel := 0.0
var _withers_vel := 0.0
## Brake-rock spring state, the unlimited angle it integrates, and the speed it
## is differenced against.
var _brake_vel := 0.0
var _brake_rock := 0.0
var _prev_speed := 0.0


func setup(spec: CreatureSpec, chains: Array, body_scale: float = 1.0) -> void:
	_spec = spec
	_family = spec.locomotion
	_body_height = maxf(spec.adult_height * body_scale, 1e-3)
	feet.clear()
	for i in FOOT_COUNT:
		var f := Foot.new()
		f.slot = i
		if i < chains.size():
			var c: LegIK.Chain = chains[i]
			f.present = c.valid
			f.bind = c.ankle_bind
			f.contact_arm = c.contact_arm
			f.contact_bind = c.contact_bind
			f.root_bind = c.root_bind
			f.reach = maxf(c.reach, 1e-3)
		f.target = f.bind
		f.root_h0 = -f.root_bind.y
		var bind_dx: float = f.bind.x - f.root_bind.x
		f.support_ref = -f.bind.y \
			+ sqrt(maxf(f.reach * f.reach - bind_dx * bind_dx, 0.0))
		feet.append(f)

	# A biped has only the hind pair; a quadruped that authored no forelimbs is
	# treated the same way rather than falling over.
	if _family == CreatureSpec.Locomotion.BIPED_HOP:
		feet[FORE_NEAR].present = false
		feet[FORE_FAR].present = false

	var reach_sum := 0.0
	var support_n := 0
	var min_x := INF
	var max_x := -INF
	for f in feet:
		if not f.present:
			continue
		reach_sum += f.reach
		support_n += 1
		min_x = minf(min_x, f.root_bind.x)
		max_x = maxf(max_x, f.root_bind.x)
	_feet_present = support_n
	_reach_ref = reach_sum / float(maxi(support_n, 1))
	_crouch = _reach_ref * (1.0 - STANCE_COMPRESSION)
	_body_len = maxf(max_x - min_x, 0.2) if support_n > 1 else 0.5
	_span_ref = maxf(_girdle_span(), 0.05)

	# `spec.stride` is the ground distance covered by one full cycle at the
	# comfortable walking speed — the reference point the frequency law below
	# scales from. A foot's stance sweep is that times the duty factor.
	#
	# Scaled by growth, like every other length in this file. Authored at adult
	# size and read literally, a kitten reached an adult's step on legs 0.42 as
	# long: the sweep came to nearly a whole leg length fore and aft, which the
	# body could only pay for by crouching a third of its leg length, and it still
	# drove the paws through the floor.
	_stride_ref = maxf(spec.stride * body_scale, 0.02)
	_bob_gain = 1.0
	_bob_gain = _calibrate_bob(spec)
	_air_frac = _suspension_fraction()
	settle()


## Find the gain that makes the bob match the authored `spec.bob`, and the gain
## that sizes the support-force term against the geometric one.
##
## The raw inverted-pendulum drop is always an overestimate — legs flex under
## load — and averaging four out-of-phase legs damps it much further, by an
## amount that depends entirely on the gait pattern and the animal's
## proportions. Rather than guess a constant, sample one reference walk cycle
## and measure the peak-to-peak directly. Cheap (it runs once per rebuild) and
## it means a long-legged dog and a squat lizard both land on their authored bob.
##
## Two channels now, sampled in the same sweep: the leg geometry, and the total
## support force the feet are putting into the ground. The second is sized off
## the first (see `BOUNCE_SHARE`) and then the sum is scaled to the authored
## amplitude, so adding it changes the *shape* of the walk and not its budget —
## which is the point, because the shape was what was wrong.
func _calibrate_bob(spec: CreatureSpec) -> float:
	const SAMPLES := 96
	var pat: Dictionary = BIPED_WALK if _family == CreatureSpec.Locomotion.BIPED_HOP \
		else PATTERNS[Kind.WALK]
	var d := float(pat["duty"])
	var sweep: float = _stride_ref * d
	var geo := PackedFloat32Array()
	var bounce := PackedFloat32Array()
	var lo := INF
	var hi := -INF
	## Deepest the reach constraint will ever push the body during this cycle.
	var ceil_max := -INF
	for s in SAMPLES:
		var c := float(s) / float(SAMPLES)
		var w_sum := 0.0
		var h_sum := 0.0
		var load_sum := 0.0
		for i in FOOT_COUNT:
			var f: Foot = feet[i]
			if not f.present:
				continue
			var ph: float = fposmod(c + float(pat["phase"][i]), 1.0)
			var stance: bool = ph < d
			# Must mirror `_solve_body` exactly, or the gain ends up calibrated
			# against a curve the runtime never produces: stance feet only, the
			# same rolled ankle, and the gathered height whenever the reference
			# cycle has none down.
			if not stance:
				continue
			w_sum += 1.0
			var st: float = ph / d
			load_sum += sin(PI * st)
			# Stance sweeps the contact back linearly under the body; the ankle is
			# then read off it through the roll, exactly as `_ankle_for` does.
			var contact := Vector2(f.contact_bind.x + sweep * (0.5 - st), 0.0)
			var ankle: Vector2 = contact - f.contact_arm.rotated(_stance_pitch(st))
			var dx: float = ankle.x - f.root_bind.x
			var support: float = -ankle.y + sqrt(maxf(f.reach * f.reach - dx * dx, 0.0))
			# The *differential*, exactly as `_solve_body` now averages it. Raw
			# heights make the bob a report on which girdle happens to be carrying
			# rather than on how the body is moving; see the note there.
			h_sum += support - f.support_ref
			ceil_max = maxf(ceil_max, -f.root_bind.y - support)
		var mean: float = (h_sum / w_sum) if w_sum > 0.0 else 0.0
		geo.append(mean)
		bounce.append(_bounce_of(load_sum, d))
		lo = minf(lo, mean)
		hi = maxf(hi, mean)
	var geo_span: float = hi - lo
	if not is_finite(geo_span) or geo_span < 1e-5:
		return 1.0
	_support_ref = (lo + hi) * 0.5
	# A foot planted ahead of the hip needs more leg than one straight under it.
	# If the body does not lower to pay for that, the reach constraint in
	# `_solve_body` shears the top off every bob and the authored amplitude never
	# appears — the animal walks with a nearly rigid trunk. So buy exactly the
	# headroom this cycle asks for, plus room for the authored swing, and fade it
	# in with speed: a cat stands tall and walks low, which is the same thing.
	# Headroom for this cycle's own `rise`, not for one unit of it. The walk's body
	# budget is no longer pinned at 1.00 (see `PATTERNS`), and buying a single
	# unit's worth would leave the reach limit shearing the top off three quarters
	# of the new amplitude before it reached the picture.
	var walk_rise: float = float(pat["rise"])
	if _family == CreatureSpec.Locomotion.SPRAWLING:
		walk_rise *= SPRAWL_RISE
	_move_crouch = maxf(ceil_max - _crouch, 0.0) + spec.bob * _body_height * walk_rise

	var b_lo := INF
	var b_hi := -INF
	for v in bounce:
		b_lo = minf(b_lo, v)
		b_hi = maxf(b_hi, v)
	var b_span: float = b_hi - b_lo
	_bounce_gain = (BOUNCE_SHARE * geo_span / b_span) if b_span > 1e-5 else 0.0

	# Peak-to-peak of what the runtime will actually target, not of one of its two
	# halves. The two terms are close to a quarter cycle apart, so calibrating on
	# the geometry alone would have overshot the authored amplitude by the whole of
	# the new term.
	var t_lo := INF
	var t_hi := -INF
	for s in SAMPLES:
		var v: float = (_support_ref - geo[s]) + _bounce_gain * bounce[s]
		t_lo = minf(t_lo, v)
		t_hi = maxf(t_hi, v)
	var span: float = t_hi - t_lo
	if not is_finite(span) or span < 1e-5:
		return 1.0
	return clampf((spec.bob * _body_height * 2.0) / span, 0.1, 12.0)


## Deviation of the total vertical support from its own cycle mean, normalised.
##
## The mean is exact rather than followed: one foot's half-sine of load averages
## `2/PI` of its peak over the fraction of the cycle it is down, so a whole animal
## averages `feet x duty x 2/PI` and the reference needs no filter to settle. A
## follower here would lag the very transient this term exists to deliver.
func _bounce_of(load_sum: float, d: float) -> float:
	var ref: float = float(_feet_present) * d * 2.0 / PI
	if ref < 1e-4:
		return 0.0
	return load_sum / ref - 1.0


## Snap every foot back to its bind position and zero the cycle.
func settle() -> void:
	cycle = 0.0
	travel = 0.0
	bob = 0.0
	pitch = 0.0
	roll = 0.0
	girdle_twist = 0.0
	flex = 0.0
	withers = 0.0
	brake = 0.0
	_brake_vel = 0.0
	_brake_rock = 0.0
	_prev_speed = speed
	_fore_load_mean = 0.0
	_bob_mean = 0.0
	_bob_vel = 0.0
	_airborne = false
	_liftoff_bob = 0.0
	_flex_vel = 0.0
	_withers_vel = 0.0
	surge = 0.0
	undulation = 0.0
	for f in feet:
		f.phase = 0.0
		f.stance = true
		f.target = f.bind
		f.pitch = 0.0
		f.support = -f.root_bind.y
		f.plant_ground = f.contact_bind.x
		f.lift_ground = f.contact_bind.x
		f.just_landed = false


## Pick a gait. Passing `Kind.IDLE` parks the feet; the caller normally lets
## `Creature` choose from speed instead.
func set_kind(k: int) -> void:
	if k == kind:
		return
	kind = k
	duty = float(_pattern()["duty"])
	_air_frac = _suspension_fraction()


## Fraction of one cycle this pattern spends with nothing on the ground.
##
## Sampled off the phase table rather than declared next to it, for the same
## reason `_calibrate_bob` samples instead of assuming: the number has to stay
## true when the table is edited, when a species is missing a limb pair, and when
## a biped borrows the quadruped walk. A walk comes out at 0, a trot at 0.05, the
## rotary gallop at 0.19 and the bird's hop at 0.58 — which is why the hop is
## where a held height reads worst.
func _suspension_fraction() -> float:
	const SAMPLES := 192
	var pat := _pattern()
	var d := float(pat["duty"])
	var air := 0
	for s in SAMPLES:
		var c := float(s) / float(SAMPLES)
		var down := false
		for i in FOOT_COUNT:
			if not feet[i].present:
				continue
			if fposmod(c + float(pat["phase"][i]), 1.0) < d:
				down = true
				break
		if not down:
			air += 1
	return float(air) / float(SAMPLES)


func pattern_name() -> StringName:
	match kind:
		Kind.WALK: return &"walk"
		Kind.TROT: return &"trot"
		Kind.RUN: return &"run"
		Kind.HOP: return &"hop"
	return &"idle"


func _pattern() -> Dictionary:
	if _family == CreatureSpec.Locomotion.BIPED_HOP and kind == Kind.WALK:
		return BIPED_WALK
	return PATTERNS.get(kind, PATTERNS[Kind.WALK])


## Stride length grows sublinearly with speed — animals lengthen the step *and*
## step faster, roughly as v^0.55 / v^0.45. Anchored at the walk so a species
## only has to author one stride number.
func _stride_length(v: float) -> float:
	var ratio: float = clampf(v / maxf(_spec.walk_speed, 1e-3), 0.05, 6.0)
	return _stride_ref * pow(ratio, 0.55)


## Step frequency at a given speed, without advancing anything. The capture
## harness needs the cycle length before the first frame so it can space a
## contact sheet evenly across exactly one stride.
func frequency_for(v: float) -> float:
	if _spec == null or v < 0.02:
		return 0.0
	return clampf(v / maxf(_stride_length(v), 1e-3), 0.25, 6.0)


func advance(dt: float) -> void:
	if _spec == null or dt <= 0.0:
		return
	var v: float = maxf(speed, 0.0)
	exertion = clampf(v / maxf(_spec.run_speed, 1e-3), 0.0, 1.0)
	_advance_brake(dt, v)

	if kind == Kind.IDLE or v < 0.02:
		_idle_step(dt)
		return

	var stride: float = _stride_length(v)
	frequency = frequency_for(v)
	var pat := _pattern()
	duty = float(pat["duty"])
	travel += v * dt
	cycle = fposmod(cycle + frequency * dt, 1.0)

	var sweep: float = stride * duty
	var step_h: float = 0.0
	for i in FOOT_COUNT:
		var f: Foot = feet[i]
		f.just_landed = false
		if not f.present:
			continue
		var was_stance := f.stance
		f.phase = fposmod(cycle + float(pat["phase"][i]), 1.0)
		f.stance = f.phase < duty
		step_h = f.reach * (0.09 + 0.16 * exertion) * float(pat["lift"])

		if f.stance:
			if not was_stance:
				# Touchdown. Pin the contact patch in ground space, ahead of where
				# it rests by half a sweep, and never move it again.
				f.plant_ground = travel + f.contact_bind.x + sweep * 0.5
				f.just_landed = true
				f.landing_force = clampf(0.35 + exertion, 0.0, 1.6)
			f.pitch = _stance_pitch(f.phase / maxf(duty, 1e-3))
			f.target = _ankle_for(f, Vector2(f.plant_ground - travel, 0.0))
			f.lift_ground = f.plant_ground
		else:
			var u: float = (f.phase - duty) / maxf(1.0 - duty, 1e-3)
			# Where this foot will land, in ground space: the body will have
			# moved on by the time the swing finishes.
			var swing_left: float = (1.0 - f.phase) / frequency
			var next_plant: float = travel + swing_left * v + f.contact_bind.x + sweep * 0.5
			var from_x: float = f.lift_ground - travel
			var to_x: float = next_plant - travel
			# Ease out hard at the end: a real foot is nearly stationary relative
			# to the ground when it touches down, and any residual velocity here
			# is exactly what reads as a skate.
			var e: float = _swing_ease(u)
			f.pitch = lerpf(0.42, -0.14, smoothstep(0.0, 0.55, u))
			f.target = _ankle_for(f, Vector2(lerpf(from_x, to_x, e),
				-step_h * _lift_curve(u)))
		f.support = _support_height(f)

	_solve_body(dt)


## The trunk rocking on its own momentum. Runs before the gait branches, so it is
## alive through the standstill that follows a stop rather than only while the
## feet are still cycling. See `BRAKE_PITCH`.
func _advance_brake(dt: float, v: float) -> void:
	# The impulse is the speed lost this step, not the acceleration it implies.
	_brake_vel += (_prev_speed - v) * BRAKE_PITCH
	_prev_speed = v
	var h: float = clampf(dt, 0.0, 0.02)
	_brake_vel += (-_brake_rock * BRAKE_OMEGA * BRAKE_OMEGA
		- _brake_vel * 2.0 * BRAKE_ZETA * BRAKE_OMEGA) * h
	_brake_rock += _brake_vel * h
	# The limiter sits between the spring and the picture, never inside the loop.
	# Fed back into the state it is not a limit at all, it is a per-frame haircut:
	# `_soft_clip` takes 15% off a 0.02 rad rock, and applied every step at 120 Hz
	# that is an extra 18/s of damping nothing in the constants accounts for. It
	# held the first version of this to 1.5° and killed it inside 0.3 s, which is
	# indistinguishable from the handbrake it was written to fix.
	brake = _soft_clip(_brake_rock, BRAKE_MAX)


func _idle_step(dt: float) -> void:
	frequency = 0.0
	for f in feet:
		f.just_landed = false
		if not f.present:
			continue
		f.stance = true
		f.target = f.target.lerp(f.bind, clampf(dt * 9.0, 0.0, 1.0))
		f.pitch = lerpf(f.pitch, 0.0, clampf(dt * 9.0, 0.0, 1.0))
		f.support = _support_height(f)
	_solve_body(dt)


## Foot roll through stance, `st` running 0 → 1 from touchdown to lift-off: flat
## early, up onto the toe as the leg trails behind. This is what stops the paw
## looking welded on — and it is a named function rather than three inline lines
## because `_calibrate_bob` has to reproduce the same pose, and a roll that the
## calibration cannot see is a roll the bob gain is wrong about.
static func _stance_pitch(st: float) -> float:
	var a: float = clampf(st, 0.0, 1.0)
	return -0.10 * smoothstep(0.0, 0.22, a) + 0.42 * smoothstep(0.62, 1.0, a)


## Swing timing. Recovery is quick, placement is slow — the classic asymmetric
## step. A symmetric curve here is the single most common cause of "floaty".
static func _swing_ease(u: float) -> float:
	var a: float = clampf(u, 0.0, 1.0)
	return 1.0 - pow(1.0 - a, 2.4)


## Foot lift over the swing, peaking early so the leg is already reaching by the
## time it comes down.
static func _lift_curve(u: float) -> float:
	var a: float = clampf(u, 0.0, 1.0)
	return sin(PI * pow(a, 0.78))


## Ankle position that puts this foot's contact patch at `contact`, given the
## roll already chosen for this frame.
##
## The foot is rigid and rotates about the ankle, so a stance that pins the
## ankle necessarily sweeps the paw across the floor by the arm length times the
## roll — around a tenth of a unit for a cat's hind leg, which is a full ruler
## tick of skate on a contact sheet. Solving the contact first and reading the
## ankle back off it makes the pinned foot genuinely pinned, and the ankle rises
## and carries forward over the toe for free, which is what heel-off looks like.
func _ankle_for(f: Foot, contact: Vector2) -> Vector2:
	return contact - f.contact_arm.rotated(f.pitch)


## How high this leg permits the limb root to ride **above the ground**.
##
## For a foot on the ground that is the inverted pendulum: the ankle can be at
## most sqrt(reach² − dx²) below the hip, so the hip clears the floor by that
## much plus however high the ankle itself is. A foot in the *air* constrains
## nothing at all — it can be folded and set down anywhere — so the height it
## permits is its whole reach. Running the swing foot through the stance formula
## instead is what made the body sink through a gallop's suspension: mid-swing
## the target is projected almost a full stride ahead of the hip, which the
## pendulum reads as a leg with no height left in it.
##
## The ankle term is not a detail. The foot rolls onto the toe through the back
## half of stance, which lifts the ankle and carries it forward over the contact
## patch — that rise *is* the push-off, and dropping it (measuring the hip from
## the ankle alone) both loses the lift and makes the pendulum think the leg has
## height in reserve exactly when the body should be sinking. Between them those
## two errors sheared more than half of the authored bob away.
func _support_height(f: Foot) -> float:
	if not f.stance:
		# Gathered under the body: dx is zero because a folded leg can be set down
		# anywhere, so the whole reach is available from wherever the ankle is.
		return -f.target.y + f.reach
	var dx: float = f.target.x - f.root_bind.x
	return -f.target.y + sqrt(maxf(f.reach * f.reach - dx * dx, 0.0))


## Turn the per-foot support heights into body bob, pitch and roll.
##
## Bob comes from the feet that are actually carrying weight, and from nothing
## else: a leg in the air holds up no part of the animal. When *no* foot is down
## the body is not being held up at all and the solver hands over to `_fly`, which
## integrates it as the projectile it is. Pitch and roll do still hear the swing
## legs, quietly, because they are about where the mass is leaning rather than
## about what is holding it up.
##
## Everything the stance branch averages is a *differential* against the bind
## pose — how much higher than its resting height each leg is currently letting
## its girdle sit — because a quadruped's fore and hind legs are different lengths
## and the raw heights report that difference as vertical body motion. Which
## girdle happens to be carrying is a fact about the gait pattern, not about how
## the body is moving, and `pitch` already owns it.
func _solve_body(dt: float) -> void:
	var w_sum := 0.0
	var stance_w := 0.0
	var stance_h := 0.0
	## Highest the body may ride before a supporting leg would have to stretch
	## past full extension. Without this, any bob amplitude the species asks for
	## that the legs cannot absorb comes out as feet hovering above the ground —
	## which no amount of tuning elsewhere can hide.
	var ceiling := -INF
	var fore_h := 0.0
	var fore_w := 0.0
	var hind_h := 0.0
	var hind_w := 0.0
	var near_h := 0.0
	var near_w := 0.0
	var far_h := 0.0
	var far_w := 0.0
	## Vertical load per foot: 0 at touchdown and at lift-off, 1 at mid-stance.
	## Deliberately normalised — the attitude channels are about *when* weight
	## hands over, not about how tall the animal is.
	var load := [0.0, 0.0, 0.0, 0.0]
	## Sum of the same, which is the total force holding the animal up. The
	## attitude channels below want the *difference* between girdles; the height
	## solver wants the sum, and until this round it never asked for it.
	var load_sum := 0.0
	for i in FOOT_COUNT:
		var f: Foot = feet[i]
		if not f.present:
			continue
		if f.stance:
			load[i] = sin(PI * clampf(f.phase / maxf(duty, 1e-3), 0.0, 1.0))
			load_sum += float(load[i])
		var w: float = 1.0 if f.stance else 0.16
		w_sum += w
		# Attitude is a differential: how much higher than its *resting* height this
		# leg is currently letting its girdle sit. Feeding in the raw heights makes
		# an animal with unequal fore and hind legs — which is every quadruped we
		# ship — walk permanently nose-down.
		var lift_h: float = f.support - f.support_ref
		if f.stance:
			stance_w += 1.0
			# The differential, not the raw height, and it is the same lesson the
			# attitude channels learned. A cat's forelegs are shorter than its hind
			# ones, so the raw mean drops the moment the forehand takes the weight on
			# its own — and the bob gain, calibrated on a walk where two or three
			# mixed legs are always down, multiplies that leg-length difference into
			# the largest single term in the whole channel. Measured on the gallop:
			# bob sat at −0.03 through hind stance and slammed to +0.16 the instant
			# the forefeet landed, a 25 px plunge at ship size that is nothing but the
			# cat's own proportions being reported twice — once here and once,
			# correctly, as pitch.
			stance_h += lift_h
			# The hip rides `root_h0 − bob` above the floor and may not out-climb what
			# this leg permits, so bob has a hard lower bound.
			ceiling = maxf(ceiling, f.root_h0 - f.support)
		if i == FORE_NEAR or i == FORE_FAR:
			fore_h += lift_h * w
			fore_w += w
		else:
			hind_h += lift_h * w
			hind_w += w
		if i == FORE_NEAR or i == HIND_NEAR:
			near_h += lift_h * w
			near_w += w
		else:
			far_h += lift_h * w
			far_w += w
	if w_sum <= 0.0:
		return

	# `rise` finally does what the pattern table says it does. The pendulum's
	# geometry is nearly the same at every speed — a cat's legs are long next to
	# its stride, so the support height only ever varies by a couple of
	# hundredths — but a galloping animal's trunk travels far more than a walking
	# one's, because most of that travel is ballistic and no static geometry can
	# see it. `spec.bob` is the species' reference amplitude and every pattern,
	# the walk included, declares its own multiple of it.
	var ride: float = _crouch + _move_crouch \
		* clampf(speed / maxf(_spec.walk_speed, 1e-3), 0.0, 1.0)
	var rise: float = float(_pattern()["rise"])
	if _family == CreatureSpec.Locomotion.SPRAWLING:
		rise *= SPRAWL_RISE
	var budget: float = _spec.bob * _body_height * rise
	if stance_w <= 0.0:
		_fly(dt, budget)
	else:
		_airborne = false
		var mean: float = stance_h / stance_w
		# Geometry says how high the legs *permit* the body to ride; the support
		# force says how hard they are pushing it there. The walk needs both — see
		# `BOUNCE_SHARE` — and the gallop is almost all geometry and flight anyway,
		# because at a duty of 0.32 there is rarely more than one foot down and the
		# sum and the single leg's own pendulum are the same curve.
		var drive: float = (_support_ref - mean) + _bounce_gain * _bounce_of(load_sum, duty)
		var target_bob: float = ride + drive * _bob_gain * rise
		# `rise` is a budget as well as a gain. At a gallop the animal is often on a
		# single leg, and one pendulum swings far wider than the average of four
		# does, so the raw geometry overshot the declared amplitude by well over
		# double — a quarter of the cat's own height of vertical travel per stride.
		#
		# Compressed rather than clipped, and only above budget. A hard clip engaged
		# for two thirds of a gallop cycle and turned the curve into two flat
		# plateaux, which reads more mechanical than the overshoot it was fixing;
		# this leaves an ordinary stride untouched and only reins in the outliers.
		var excess: float = target_bob - ride
		var over: float = absf(excess) / maxf(budget, 1e-5)
		if over > 1.0:
			target_bob = ride + signf(excess) * budget * (2.0 - 1.0 / over)
		# A spring, not a follower. The trunk has mass: it passes the height its
		# legs are asking for and settles back, and it arrives in stance still
		# carrying whatever momentum the suspension gave it, because `_bob_vel` is
		# the same variable `_fly` integrates. See `BOB_OMEGA`.
		var h0: float = clampf(dt, 0.0, 0.02)
		_bob_vel += (-(bob - target_bob) * BOB_OMEGA * BOB_OMEGA
			- _bob_vel * 2.0 * BOB_ZETA * BOB_OMEGA) * h0
		bob += _bob_vel * h0
		# The reach limit is a fact about bone length, so it binds the *state*, not
		# just the target: a spring is allowed to overshoot downward, which is a leg
		# compressing under load, and is not allowed to overshoot upward, which is a
		# foot leaving the ground in the middle of a stance phase. Only the offending
		# half of the velocity is removed, so a body pressed against the limit still
		# falls away from it the moment the geometry lets go.
		if is_finite(ceiling) and bob < ceiling:
			bob = ceiling
			_bob_vel = maxf(_bob_vel, 0.0)
	# Slow-followed centre of the bob, so the channels that ride it below are
	# deviations rather than copies of the crouch the animal happens to be at.
	_bob_mean = lerpf(_bob_mean, bob, clampf(dt * 1.6, 0.0, 1.0))
	var bob_dev: float = bob - _bob_mean

	# Phase-driven trunk attitude, gated on the animal actually walking. At rest
	# the foot phases are frozen wherever the gait stopped, and reading them then
	# would park the trunk at a permanent tilt; the idle layer owns the resting
	# attitude instead, and these decay to zero through the followers below.
	var pitch_to := 0.0
	var roll_to := 0.0
	var twist_to := 0.0
	if frequency > 0.0:
		var has_fore: bool = feet[FORE_NEAR].present and feet[FORE_FAR].present
		var has_hind: bool = feet[HIND_NEAR].present and feet[HIND_FAR].present
		var roll_fore: float = load[FORE_NEAR] - load[FORE_FAR] if has_fore else 0.0
		var roll_hind: float = load[HIND_NEAR] - load[HIND_FAR] if has_hind else 0.0
		if (feet[FORE_NEAR].present or feet[FORE_FAR].present) \
				and (feet[HIND_NEAR].present or feet[HIND_FAR].present):
			# The hind girdle carrying more than the fore means the croup is being
			# driven up while the forehand falls away underneath it: nose down.
			pitch_to = _soft_clip((_pair_load(load, HIND_NEAR, HIND_FAR)
				- _pair_load(load, FORE_NEAR, FORE_FAR)) * PITCH_GAIN, PITCH_MAX)
		# Each girdle's own near/far split, kept apart rather than averaged. The
		# two are close to antiphase in every pattern we ship — at a trot they are
		# exact negatives — and that opposition *is* the counter-rotation.
		# Averaging the four feet together, which is what this used to do, cancels
		# it to nothing, and cancelling it is most of why the trunk read as one
		# rigid plank.
		#
		# Both girdles have to be complete for a twist between them to mean
		# anything. A biped has no forehand at all, and reading the absent pair as
		# a permanently unloaded one twisted its trunk against a girdle that does
		# not exist — which, because the legs hang off the pelvis this rotates,
		# walked the bird's feet a tenth of a unit off the spots they were pinned
		# to. Measured: slip 0.1071 with the phantom girdle, 0.0000 without it.
		if has_fore and has_hind:
			twist_to = (roll_fore - roll_hind) * 0.5 * TWIST_GAIN
		roll_to = (roll_fore + roll_hind) * 0.5 * ROLL_GAIN
		# A sprawling animal's trunk motion is lateral, not sagittal — the spine
		# writhes side to side and `undulation` already carries all of it. Pitching
		# a lizard's long trunk on top of that only drives the far end of a metre
		# of tail through the floor, which is exactly what it measured.
		if _family == CreatureSpec.Locomotion.SPRAWLING:
			pitch_to *= 0.35
			twist_to *= 0.35
	# The geometric differentials stay in the sum. They are a rounding error on a
	# level floor, but they are the only term that hears a species whose hind legs
	# are longer than its fore ones, or a foot that landed somewhere unexpected.
	if fore_w > 0.0 and hind_w > 0.0:
		pitch_to += atan2((hind_h / hind_w) - (fore_h / fore_w), _body_len) * 0.55
	if near_w > 0.0 and far_w > 0.0:
		roll_to += clampf(((near_h / near_w) - (far_h / far_w)) * 1.4, -0.5, 0.5) * 0.22
	pitch = lerpf(pitch, pitch_to, clampf(dt * 18.0, 0.0, 1.0))
	roll = lerpf(roll, roll_to, clampf(dt * 16.0, 0.0, 1.0))
	girdle_twist = lerpf(girdle_twist, twist_to, clampf(dt * 20.0, 0.0, 1.0))

	# Trunk *shape*, as opposed to trunk attitude. Both channels are differentials
	# against a rest value and both are gated on the animal actually moving, for
	# the same reason the attitude channels are: at a standstill the phases are
	# frozen wherever the gait stopped, and a frozen phase read as a pose is a
	# permanent deformity.
	var flex_to := 0.0
	var withers_to := 0.0
	if frequency > 0.0:
		# The two girdles' feet closing toward each other is the animal gathering,
		# and a gathering quadruped rounds its back — that coupling is the whole of
		# a bound and most of a gallop. Normalised by the trunk so it means the same
		# thing on a lizard and a whippet.
		flex_to = _soft_clip((_span_ref - _girdle_span()) / maxf(_body_len, 1e-3)
			* FLEX_GAIN, FLEX_MAX)
		# A sprawling animal's trunk already carries all its motion laterally
		# through `undulation`; adding a sagittal arch on top only lifts the middle
		# of a lizard off the floor.
		# The topline answers the bob as well as the gather. At the bottom of the
		# stride the trunk hangs between loaded limbs and the back is at its
		# flattest; at the top it is gathered and the loin rounds under it. The
		# gather term owns the gallop, where the girdles genuinely close on each
		# other, and this owns the walk, where they barely move at all and without
		# it the topline is a plank that only translates.
		flex_to -= bob_dev * FLEX_BOB
		# A sprawling animal's trunk already carries all its motion laterally
		# through `undulation`; adding a sagittal arch on top only lifts the middle
		# of a lizard off the floor — and drives the far end of a metre of tail
		# through it, which is what it measured. Applied to the whole channel, the
		# bob term included: it was added after this scale for one round and put
		# 8 px of reptile tail under the ground plane.
		if _family == CreatureSpec.Locomotion.SPRAWLING:
			flex_to *= 0.25
		var fore_load: float = _pair_load(load, FORE_NEAR, FORE_FAR)
		_fore_load_mean = lerpf(_fore_load_mean, fore_load, clampf(dt * 1.4, 0.0, 1.0))
		withers_to = (fore_load - _fore_load_mean) * WITHERS_GAIN * _reach_ref
		# The ribcage is slung between the shoulder blades, so when the trunk sinks
		# the blades stay with the humerus and ride up out of the back. Same channel,
		# a different phase of the same stride: the load term above peaks at
		# mid-stance and this at the bottom of the bob, and having both is what keeps
		# the withers from being a rectified copy of one signal.
		withers_to += bob_dev * WITHERS_BOB
		# A scapula slides on the ribcage; it does not come off it. Measured on the
		# cat's gallop the two terms summed to 48.7 px of travel at ship size,
		# against about 24 for a real galloping cat, and every pixel of it is
		# subtracted from what the foreleg below has left to reach the ground with.
		# Soft, not clipped, for the same reason as everywhere else in this file.
		withers_to = _soft_clip(withers_to, WITHERS_MAX * _reach_ref)
	else:
		_fore_load_mean = lerpf(_fore_load_mean, 0.0, clampf(dt * 1.4, 0.0, 1.0))
	# Springs, not followers. Both of these are shape changes driven by a limb
	# taking load, and a limb takes load in about a tenth of a second — but a one-
	# pole can only ever arrive late, never past, and a back and a shoulder are
	# muscle with mass on the end of them. The overshoot after each footfall is the
	# whole difference between a shape that is driven and a shape that responds.
	var h: float = clampf(dt, 0.0, 0.02)
	var k_t: float = TRUNK_OMEGA * TRUNK_OMEGA
	var c_t: float = 2.0 * TRUNK_ZETA * TRUNK_OMEGA
	_flex_vel += (-(flex - flex_to) * k_t - _flex_vel * c_t) * h
	flex += _flex_vel * h
	_withers_vel += (-(withers - withers_to) * k_t - _withers_vel * c_t) * h
	withers += _withers_vel * h

	# Fore-aft surge: the body decelerates against each braking forelimb and is
	# pushed on by each hind. Small, but its absence is why naive walk cycles
	# look like a puppet sliding along a rail.
	var s := 0.0
	for i in FOOT_COUNT:
		var f: Foot = feet[i]
		if not f.present or not f.stance:
			continue
		var st: float = f.phase / maxf(duty, 1e-3)
		var push: float = sin(PI * st)
		s += push * (-1.0 if (i == FORE_NEAR or i == FORE_FAR) else 1.0)
	surge = lerpf(surge, s * _stride_ref * 0.035 * exertion, clampf(dt * 20.0, 0.0, 1.0))

	# Sprawling locomotion: a travelling lateral wave along the trunk. In a side
	# view its most visible component is the trunk shortening and swinging as the
	# animal writhes, so the rig maps it onto the spine as an in-plane S-bend.
	if _family == CreatureSpec.Locomotion.SPRAWLING:
		undulation = sin(TAU * cycle) * (0.10 + 0.16 * exertion)
	else:
		undulation = 0.0


## The suspension: no foot on the ground, so nothing is holding the body up.
##
## Everywhere else in this file the trunk height is *solved* — read off whichever
## legs are carrying weight. In flight there are none, and the honest answer is
## that the body is a projectile. It used to hold the last support-derived height
## instead, which on the bird's hop meant 58% of every cycle spent at exactly the
## same altitude: four consecutive frames of an eight-frame contact sheet with the
## bird translated bodily upward and not otherwise changed. That is the literal
## definition of furniture being carried.
##
## The push-off is derived rather than measured. A projectile that leaves the
## ground at v and returns to the same height after T seconds needs v = gT/2, and
## a real animal's push-off satisfies exactly that condition or it would land
## early and stumble — so taking it as given is not a shortcut, it is the
## constraint. It also makes the arc close by construction: the body arrives back
## at the height it left at, on the frame the next foot touches down, moving
## downward at the speed it left at. Nothing to clamp, nothing to plateau, and the
## landing compression starts from real downward momentum instead of from rest.
##
## The amplitude follows from the flight time and needs no tuning: gT²/8 is 0.2 px
## for a trot's flicker of a suspension, 2 px for the cat's gallop and 17 px for
## the bird's hop, which is the correct ordering and the correct spread.
func _fly(dt: float, budget: float) -> void:
	if not _airborne:
		_airborne = true
		_liftoff_bob = bob
		_bob_vel = -GRAVITY * (_air_frac / maxf(frequency, 0.25)) * 0.5
	_bob_vel += GRAVITY * dt
	bob += _bob_vel * dt
	# A guard rail, not a shaper: the arc above closes on its own, and this only
	# catches a pattern table edited into a suspension long enough for free fall to
	# bury the animal. If it ever engages, the table is wrong.
	if bob > _liftoff_bob + budget:
		bob = _liftoff_bob + budget
		_bob_vel = 0.0


## Fore-aft gap between the two girdles' feet, right now. Measured off the live
## targets rather than off the cycle phase, so it stays honest through a
## suspension, a turn, or a foot placed somewhere the pattern did not predict.
func _girdle_span() -> float:
	var fore := 0.0
	var fore_n := 0
	var hind := 0.0
	var hind_n := 0
	for i in FOOT_COUNT:
		var f: Foot = feet[i]
		if not f.present:
			continue
		if i == FORE_NEAR or i == FORE_FAR:
			fore += f.target.x
			fore_n += 1
		else:
			hind += f.target.x
			hind_n += 1
	if fore_n == 0 or hind_n == 0:
		return _span_ref
	return fore / float(fore_n) - hind / float(hind_n)


## Mean vertical load across one girdle's pair, ignoring limbs the species never
## authored — a biped must not read a missing forehand as a permanently
## unloaded one and walk around nose-up.
func _pair_load(load: Array, near: int, far: int) -> float:
	var sum := 0.0
	var n := 0
	if feet[near].present:
		sum += float(load[near])
		n += 1
	if feet[far].present:
		sum += float(load[far])
		n += 1
	return sum / float(maxi(n, 1))


## Soft saturation: linear near zero, asymptotic at `cap`. A hard clamp on an
## attitude channel flattens the top of every stride into a plateau, which reads
## more mechanical than the overshoot it was fixing — the same lesson the bob
## budget above already learned the expensive way.
static func _soft_clip(v: float, cap: float) -> float:
	return v / (1.0 + absf(v) / maxf(cap, 1e-4))


## The single strongest foot impact this frame, for squash and audio. Zero when
## nothing landed.
func landing_impulse() -> float:
	var best := 0.0
	for f in feet:
		if f.just_landed:
			best = maxf(best, f.landing_force)
	return best


## Gait a given speed should be using. Kept here so the brain can ask without
## reimplementing the thresholds.
func kind_for_speed(v: float) -> int:
	if _spec == null:
		return Kind.IDLE
	if v < 0.02:
		return Kind.IDLE
	if _family == CreatureSpec.Locomotion.BIPED_HOP:
		return Kind.WALK if v < _spec.walk_speed * 1.25 else Kind.HOP
	if v < _spec.walk_speed * 1.35:
		return Kind.WALK
	if v < _spec.run_speed * 0.72:
		return Kind.TROT
	return Kind.RUN
