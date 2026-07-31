class_name IdleRig
extends RefCounted

## The layer that makes a stationary creature read as alive rather than as a
## paused animation.
##
## A resting animal is never still. It breathes, it blinks — usually twice, in a
## quick pair — its eyes flick between things in short ballistic jumps, its ears
## rotate toward whatever it just heard, and its weight drifts from one side to
## the other every few seconds. Remove any one of those and the creature reads as
## a prop; remove all of them and it reads as dead.
##
## Everything is driven from a seeded RNG advanced at fixed steps, so the same
## creature advanced to the same `t` produces the same pose every run. The
## capture harness depends on that.

## Blink shape, seconds. Closing is roughly half the time of opening — lids fall
## and are lifted, and getting that asymmetry wrong is instantly readable.
const BLINK_CLOSE := 0.055
const BLINK_HOLD := 0.022
const BLINK_OPEN := 0.105
## Probability that a blink is immediately followed by a second one. Animals
## blink in pairs far more often than chance would suggest.
const DOUBLE_BLINK_CHANCE := 0.42
const DOUBLE_BLINK_GAP := 0.09

## Saccade ballistics: eyes reach a new target in well under a tenth of a second
## and then hold. Smooth eye interpolation is one of the great uncanny tells.
const SACCADE_TIME := 0.045

## How far the whole body sinks between a full inhale and a full exhale, rig
## units. Small on purpose — see `_advance_weight`, which owns the budget.
const BREATH_SINK := 0.016
## Peak rotation of an idle ear flick, radians. A real ear twitch is 10–15° and
## over inside a fifth of a second; the 3° this used to be was a pixel of travel
## at the size the pet ships at, which is the same as no flick at all.
const EAR_FLICK := 0.22


## Breathing.
var breath := 0.0          ## −1 exhaled → +1 inhaled
var breath_rate := 0.26    ## cycles per second at rest
var exertion := 0.0

## Eyes.
var blink := 0.0           ## 0 open → 1 shut
var gaze := Vector2.ZERO   ## in [-1, 1] of the eyeball's travel
var pupil_scale := 1.0
## Where the brain wants the creature looking, in gaze units. Saccades wander
## around this rather than replacing it.
var gaze_anchor := Vector2.ZERO
var alertness := 0.0       ## 0 drowsy → 1 wired; widens pupils, quickens blinks
var arousal := 0.0         ## fear/excitement; widens pupils further

## Ears, radians. Positive rotates forward.
var ear_near := 0.0
var ear_far := 0.0

## Slow postural drift, rig units and radians.
var weight_shift := Vector2.ZERO
var weight_roll := 0.0
## Fore-aft rock of a standing animal, radians, positive nose-down.
##
## A resting quadruped does not just slide sideways over its feet — it rocks its
## weight between the girdles, and that rock is the one postural signal a strict
## side view can show at full strength. Without it the only thing separating two
## idle frames was a lateral drift of two pixels, which is how a twelve-second
## sheet came back pose-identical.
var weight_pitch := 0.0

## Self-motion of a resting tail, in radians of extra curl at the base.
##
## Nothing else drives it when the animal is standing: the tail chain is a spring
## hanging off the pelvis, and a pelvis that is not moving exerts no force at all.
## A twelve-second idle sheet caught the tail frozen to the pixel in all six
## frames while the head and eyes were plainly alive — which reads worse than no
## animation, because the contrast points straight at the seam.
var tail_sway := 0.0

var _rng := RandomNumberGenerator.new()
var _spec: CreatureSpec
var _t := 0.0
var _blink_timer := 0.0
var _blink_at := -1.0
var _blink_queued := false
var _blink_queue_at := 0.0
var _sac_timer := 0.0
var _sac_from := Vector2.ZERO
var _sac_to := Vector2.ZERO
var _sac_at := -1.0
var _ear_target_near := 0.0
var _ear_target_far := 0.0
var _ear_hold := 0.0
var _shift_timer := 0.0
var _shift := Vector2.ZERO
var _shift_roll := 0.0
var _shift_pitch := 0.0
var _shift_target := Vector2.ZERO
var _shift_roll_target := 0.0
var _shift_pitch_target := 0.0


func setup(spec: CreatureSpec, seed_value: int) -> void:
	_spec = spec
	_rng.seed = seed_value
	# Personality reaches straight into the idle layer: a curious, high-energy
	# animal breathes faster, saccades more and holds an ear pricked longer.
	breath_rate = lerpf(0.22, 0.46, spec.energy)
	_blink_timer = _next_blink_gap()
	_sac_timer = _next_saccade_gap()
	_shift_timer = _rng.randf_range(2.0, 5.0)


func advance(dt: float) -> void:
	if _spec == null or dt <= 0.0:
		return
	_t += dt
	_advance_breath(dt)
	_advance_blink(dt)
	_advance_gaze(dt)
	_advance_ears(dt)
	_advance_weight(dt)
	_advance_tail()


# --- breathing --------------------------------------------------------------

func _advance_breath(dt: float) -> void:
	# Rate and depth both climb with exertion, and the ratio between them
	# changes: a panting animal breathes fast *and* shallow at the top end.
	var rate: float = breath_rate * (1.0 + exertion * 2.6)
	var phase: float = _t * rate
	# Asymmetric: inhale is quicker than the passive exhale.
	var s := sin(TAU * phase)
	breath = s * (1.0 - 0.18 * signf(s))


## Breathing amplitude as a body-scale multiplier, applied to the ribcage.
##
## Deliberately larger than life. A resting cat's flank moves a couple of
## millimetres, which at desktop-pet scale is a third of a pixel — a contact
## sheet of one whole breath cycle differenced against itself showed literally
## no change in the silhouette. Breathing you cannot see is breathing that isn't
## there, and a still pet reads as a prop, so the amplitude is pushed to where
## the torso visibly rises and the shoulders carry the head with them.
##
## Measured against the ribcage's own silhouette rather than tuned by eye: the
## top line of the trunk now travels 0.063 rig units over a breath, against
## 0.020 with this term switched off. That is eight pixels at ship size, where
## the previous 0.035 was inside the noise of the postural drift around it.
func breath_swell() -> float:
	return breath * (0.062 + 0.050 * exertion)


# --- blinking ---------------------------------------------------------------

func _next_blink_gap() -> float:
	var base: float = maxf(_spec.blink_interval, 0.6)
	# Alert animals blink less; drowsy ones blink slowly and hold longer.
	return base * _rng.randf_range(0.55, 1.65) * lerpf(1.25, 0.75, alertness)


func _advance_blink(dt: float) -> void:
	if _blink_at < 0.0:
		_blink_timer -= dt
		if _blink_queued and _t >= _blink_queue_at:
			_blink_queued = false
			_blink_at = _t
		elif _blink_timer <= 0.0:
			_blink_at = _t
			_blink_timer = _next_blink_gap()
			if _rng.randf() < DOUBLE_BLINK_CHANCE:
				_blink_queued = true
				_blink_queue_at = _t + BLINK_CLOSE + BLINK_HOLD + BLINK_OPEN + DOUBLE_BLINK_GAP
		blink = maxf(blink - dt * 12.0, 0.0)
		return

	var u: float = _t - _blink_at
	if u < BLINK_CLOSE:
		blink = smoothstep(0.0, BLINK_CLOSE, u)
	elif u < BLINK_CLOSE + BLINK_HOLD:
		blink = 1.0
	elif u < BLINK_CLOSE + BLINK_HOLD + BLINK_OPEN:
		blink = 1.0 - smoothstep(0.0, BLINK_OPEN, u - BLINK_CLOSE - BLINK_HOLD)
	else:
		blink = 0.0
		_blink_at = -1.0


## Force a blink now — used by reactions, and by the brain when the pet is
## startled or dazzled.
func trigger_blink(double_it: bool = false) -> void:
	_blink_at = _t
	_blink_queued = double_it
	_blink_queue_at = _t + BLINK_CLOSE + BLINK_HOLD + BLINK_OPEN + DOUBLE_BLINK_GAP


# --- gaze -------------------------------------------------------------------

func _next_saccade_gap() -> float:
	# Curiosity buys shorter fixations. Range matches real inter-saccade
	# intervals for a relaxed mammal, roughly a third of a second to two seconds.
	return _rng.randf_range(0.30, 2.1) * lerpf(1.5, 0.6, _spec.curiosity)


func _advance_gaze(dt: float) -> void:
	if _sac_at < 0.0:
		_sac_timer -= dt
		if _sac_timer <= 0.0:
			_sac_timer = _next_saccade_gap()
			_sac_at = _t
			_sac_from = gaze
			# Fixations cluster near whatever the brain is attending to; only
			# occasionally does the eye break away to scan.
			var spread: float = 0.22 if _rng.randf() > 0.28 else 0.75
			_sac_to = (gaze_anchor + Vector2(
				_rng.randfn(0.0, spread), _rng.randfn(0.0, spread * 0.55))
				).limit_length(1.0)
	else:
		var u: float = (_t - _sac_at) / SACCADE_TIME
		if u >= 1.0:
			gaze = _sac_to
			_sac_at = -1.0
		else:
			gaze = _sac_from.lerp(_sac_to, smoothstep(0.0, 1.0, u))

	# Fixational drift and microtremor: the eye is never perfectly still even
	# mid-fixation, and a perfectly locked pupil is uncanny at close zoom.
	var drift := Vector2(sin(_t * 1.7) * 0.012, cos(_t * 1.31) * 0.009)
	gaze = (gaze + drift).limit_length(1.0)

	# Pupil: arousal and darkness dilate, alertness and glare constrict. The slow
	# ripple is hippus, the involuntary oscillation every real iris has.
	var hippus := sin(_t * 0.83) * 0.035 + sin(_t * 1.97) * 0.018
	pupil_scale = clampf(1.0 + arousal * 0.85 - alertness * 0.28 + hippus, 0.35, 2.2)


# --- ears -------------------------------------------------------------------

## Point the ears at a sound. `lateral` is the source direction in rig space;
## its x sign decides whether the ears rotate forward or swing back.
func hear(lateral: Vector2, strength: float = 1.0) -> void:
	var forward: float = clampf(lateral.normalized().x, -1.0, 1.0)
	var amount: float = clampf(strength, 0.0, 1.0) * 0.55
	# Ears rotate independently: the far ear leads on a sound from behind, which
	# is most of what makes the swivel read as directional rather than decorative.
	_ear_target_near = -forward * amount
	_ear_target_far = -forward * amount * 1.35
	_ear_hold = 0.9 + 1.4 * clampf(strength, 0.0, 1.0)


func _advance_ears(dt: float) -> void:
	if _ear_hold > 0.0:
		_ear_hold -= dt
	else:
		_ear_target_near = 0.0
		_ear_target_far = 0.0
	# Independent flicks. Ears twitch at rest even with nothing to hear, and the
	# two sides are never in sync. The follower below used to run at 9 Hz, which
	# smeared a hundred-millisecond flick down to a third of its amplitude before
	# the ear spring ever saw it — the impulse has to survive to the chain or it
	# is not a flick, it is a drift.
	# Same rate correction as the tail and the postural creep: an ear that sways on
	# a nine-second period is an ear that does not sway.
	var idle_near := sin(_t * 1.60 + 1.1) * 0.034 + _tick(_t, 0.37) * EAR_FLICK
	var idle_far := sin(_t * 1.27 + 2.7) * 0.028 + _tick(_t + 3.1, 0.29) * EAR_FLICK * 0.8
	var k: float = clampf(dt * 20.0, 0.0, 1.0)
	ear_near = lerpf(ear_near, _ear_target_near + idle_near + alertness * 0.16, k)
	ear_far = lerpf(ear_far, _ear_target_far + idle_far + alertness * 0.16, k)


## Sparse impulse train: mostly zero, with a short decaying spike now and then.
## Cheaper and more animal than layered sine noise, which always reads as a wave.
static func _tick(t: float, rate: float) -> float:
	var u := fposmod(t * rate, 1.0)
	return exp(-u * 26.0) * (1.0 if fmod(floor(t * rate), 3.0) < 1.5 else 0.0)


# --- postural drift ---------------------------------------------------------

func _advance_weight(dt: float) -> void:
	_shift_timer -= dt
	if _shift_timer <= 0.0:
		# Shorter gaps than a literal reading of "every few seconds" would suggest.
		# The follower below has a three-quarter-second time constant, so a gap of
		# five seconds means four of them are spent parked on the target, and a
		# review frame is far more likely to land in the parked stretch than in the
		# move — which is exactly how a twelve-second sheet came back with six
		# identical bodies.
		_shift_timer = _rng.randf_range(1.8, 4.5) * lerpf(1.4, 0.6, _spec.energy)
		# The vertical drift is biased downward on purpose. A standing animal settles
		# onto its legs; it does not push itself up off them. And mechanically it
		# cannot: the only headroom the body has is the flexion reserve the gait
		# holds back, so a rise larger than that runs the legs out of reach and the
		# forepaws lift a couple of pixels clear of the floor.
		_shift_target = Vector2(_rng.randf_range(-0.034, 0.034), _rng.randf_range(-0.005, 0.014))
		_shift_roll_target = _rng.randf_range(-0.055, 0.055)
		# Rocking fore-aft is the load actually moving between the girdles, so it
		# is correlated with the lateral drift rather than independent of it: the
		# animal leans back as it settles onto its hocks and forward as it comes
		# up onto its toes. Correlated, not locked — the noise term keeps two
		# consecutive shifts from looking like the same move replayed.
		_shift_pitch_target = _shift_target.x * -0.62 + _rng.randf_range(-0.014, 0.014)
	var k: float = clampf(dt * 1.3, 0.0, 1.0)
	_shift = _shift.lerp(_shift_target, k)
	_shift_roll = lerpf(_shift_roll, _shift_roll_target, k)
	_shift_pitch = lerpf(_shift_pitch, _shift_pitch_target, k)
	# A creep rides on top of the destination, at three frequencies that never
	# line up. A discrete shift alone leaves the body perfectly still between
	# moves; the creep means there is no instant at which the animal is not
	# moving at all, which is the whole point of the idle layer.
	#
	# Breathing is folded into the same vertical budget rather than added on top
	# of it. The only headroom the body has is the flexion reserve the gait holds
	# back, so the term is written to *sink* on the exhale instead of rising past
	# what the legs can pay for — and the ribcage is what carries the visible half
	# of the breath anyway, through `breath_swell`.
	#
	# The rates were the same bug the tail had. Written at 0.23–0.41 rad/s these
	# had periods of **fifteen to twenty-seven seconds** and amplitudes under a
	# pixel at ship size, so between two discrete shifts the creep contributed
	# nothing a viewer could see and the animal was, for seconds at a time,
	# perfectly still — the exact thing the term exists to prevent. Six to eleven
	# seconds is slow enough to read as postural rather than as a wobble.
	var breath_sink: float = (1.0 - breath) * 0.5 * BREATH_SINK
	weight_shift = _shift + Vector2(sin(_t * 1.05) * 0.009,
		sin(_t * 0.78 + 2.0) * 0.003 + breath_sink)
	weight_roll = _shift_roll + sin(_t * 0.85 + 1.4) * 0.016
	weight_pitch = _shift_pitch + sin(_t * 0.95 + 0.6) * 0.014 \
		+ sin(_t * 0.58 + 2.4) * 0.008


# --- resting tail -----------------------------------------------------------

func _advance_tail() -> void:
	# Two swings well apart in frequency, so the tail wanders instead of
	# metronoming, plus the same sparse impulse train the ears use — a resting
	# cat's tail spends most of its time drifting and then flicks once.
	#
	# The rates are the load-bearing part and they were the bug. Authored at 0.44
	# and 0.19 rad/s, the resting tail's two components had periods of **fourteen
	# and thirty-three seconds**: a viewer watching for three seconds — which is
	# all a desktop pet ever gets — saw the tip move about four pixels, and a blind
	# reviewer called it "a rigid stick that never moves". Measured on the eight-
	# second idle sheet the tip travelled 16 px *in total*, i.e. 2 px/s, which is
	# below the rate at which motion registers as motion at all. A real resting
	# cat's tail sweeps on a three-to-four second beat.
	var drift: float = sin(_t * 1.55) * 0.090 + sin(_t * 0.62 + 0.9) * 0.060
	# The flick is a *base* angle handed to a soft, under-damped chain that delays
	# it joint by joint, so it leaves the root and runs out to the tip and the tip
	# travels several times this. Under-driven it read as the tail breathing.
	var flick: float = _tick(_t + 1.7, 0.34) * lerpf(0.16, 0.34, _spec.energy)
	# Exertion fades it out: a moving animal's tail is driven by its hips and does
	# not need — or want — an idle wander fighting the spring.
	tail_sway = (drift + flick) * (1.0 - clampf(exertion * 1.6, 0.0, 1.0))


## Write the live eye state the renderer reads. Kept here rather than in the rig
## so the whole `EyeSpec.Live` contract has exactly one author.
func write_eyes(live_eyes: Array, bind_eyes: Array) -> void:
	for i in mini(live_eyes.size(), bind_eyes.size()):
		var e: EyeSpec.Live = live_eyes[i]
		var b: EyeSpec.Live = bind_eyes[i]
		e.gaze = gaze
		e.blink = blink
		e.pupil_scale = pupil_scale
		e.pupil_ratio = b.pupil_ratio
		# Alert animals open the lids wider; drowsy ones let them settle.
		e.lid_open = clampf(b.lid_open * lerpf(0.86, 1.06, alertness), 0.0, 1.0)
