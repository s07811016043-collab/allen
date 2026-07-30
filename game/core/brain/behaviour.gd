class_name PetBehaviour
extends RefCounted

## One thing a pet can be doing.
##
## Every behaviour answers the same three questions: how much do I want to run
## right now (`score`), what do I do while I am running (`update`), and how
## rudely may I be interrupted (`urgency`). The brain does the rest.
##
## The interrupt model is deliberately not a plain "highest score wins", because
## that produces a pet that twitches. Two mechanisms damp it:
##
##  * **Urgency tiers.** A candidate whose urgency is *below* the running
##    behaviour's cannot cut in at all until the runner finishes or gives up.
##    That is the whole reason a nap (AMBIENT) can never interrupt a greeting
##    (URGENT), while a startle (REFLEX) can cut anything short.
##  * **Commitment.** Within a tier, the running behaviour's score is inflated
##    by a bonus that decays over `commitment` seconds, and a challenger must
##    beat it by a margin. So the pet finishes what it started unless something
##    genuinely better turns up.

## Interrupt tiers. Ordering is load-bearing: a strictly lower tier can never
## interrupt a strictly higher one.
enum Urgency {
	AMBIENT,  ## Filler: idle, wander, nap, groom. Anything may cut in.
	NORMAL,   ## Wants doing: play, investigate, follow, mischief.
	URGENT,   ## Should not be missed: begging when starving, greeting.
	REFLEX,   ## Involuntary: startle. Cuts everything, including itself.
}

## Stable id, used for the intent, EventBus and debugging.
var id: StringName = &"behaviour"
var urgency: Urgency = Urgency.AMBIENT
## Once entered, run at least this long before any same-tier challenger wins.
var min_duration: float = 1.0
## Give up after this long even if the score stays high, so nothing can wedge.
var max_duration: float = 20.0
## Seconds this behaviour is ineligible after it finishes. Keeps a pet from
## grooming, stopping, and immediately grooming again.
var cooldown: float = 0.0
## Seconds over which the commitment bonus decays to nothing.
var commitment: float = 6.0
## Strength of the commitment bonus at the moment of entry.
var commit_bonus: float = 0.5

## Runtime.
var elapsed: float = 0.0
var ready_at: float = 0.0


## Utility in roughly [0, 2]. Anything at or below zero is "not now".
func score(_ctx: BrainContext) -> float:
	return 0.0


func on_enter(_ctx: BrainContext) -> void:
	pass


## Drive the body. Return false when the behaviour has finished of its own
## accord; the brain will re-select immediately.
func update(_ctx: BrainContext, _delta: float) -> bool:
	return true


func on_exit(_ctx: BrainContext) -> void:
	pass


## Eligible to be considered at all? Reflexes ignore their own cooldown when
## the charge behind them is large enough; everything else waits its turn.
func available(ctx: BrainContext) -> bool:
	return ctx.now >= ready_at


func begin(ctx: BrainContext) -> void:
	elapsed = 0.0
	on_enter(ctx)


func finish(ctx: BrainContext) -> void:
	on_exit(ctx)
	ready_at = ctx.now + cooldown


## How much the brain inflates this behaviour's score while it is running.
func commitment_multiplier() -> float:
	if commitment <= 0.0:
		return 1.0
	var t: float = clampf(elapsed / commitment, 0.0, 1.0)
	return 1.0 + commit_bonus * (1.0 - t)
