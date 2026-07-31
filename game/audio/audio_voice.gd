class_name AudioVoice
extends RefCounted

## Everything the mixer is allowed to know about a sound.
##
## `VoiceSynth` schedules, caps, ducks and limits; it never asks what a voice
## *is*. That separation is why a vocalisation, a footfall and the ambience bed
## can share one output stream and one policy: they are all just something that
## can add samples into a stereo pair and eventually say it is done.
##
## Voices render into two `PackedFloat32Array`s rather than a `PackedVector2Array`
## because the mixer sums several of them before it builds the interleaved buffer
## the engine wants, and per-element `Vector2` traffic through the binding is the
## single most expensive thing in the render path.

## Priority decides who survives a pile-up. A voice with a higher number is
## kept; ties go to the older voice, which is already audible.
enum Priority { AMBIENCE = 0, FOLEY = 1, VOICE = 2, CRITICAL = 3 }

var priority: int = Priority.VOICE
## Linear output gain, applied by the voice itself so a fade-out is smooth.
var gain: float = 1.0
## -1 left … +1 right. A desktop pet is a point on screen; a little width keeps
## two animals from stacking in the same spot in the mix.
var pan: float = 0.0
## Seconds of audio this voice has actually rendered. The mixer uses it to age
## out anything that outlives its plausible duration, which is what stops a
## stalled audio device from silently filling every slot.
var elapsed: float = 0.0
## Set by the mixer when it wants the voice gone without a click.
var fading_out: bool = false
## How much synthesis this voice may spend, set by the mixer before `setup`.
## 1.0 is the full model; below `0.75` a voice drops the parts of itself that
## cost the most and carry the least — the third formant and the sub-oscillator.
## Nobody can hear the third formant of the fourth simultaneous animal, and the
## alternative under load is a dropped buffer, which everybody can hear.
var fidelity: float = 1.0

var _sr: float = 22050.0
var _gl: float = 0.707
var _gr: float = 0.707


func setup(sample_rate: float) -> void:
	_sr = sample_rate
	var g := AudioDSP.pan_gains(pan)
	_gl = g.x
	_gr = g.y


## Add `count` frames into the mix. Implementations must never resize the
## buffers and must never write past `count`.
func render_add(_left: PackedFloat32Array, _right: PackedFloat32Array, count: int) -> void:
	elapsed += float(count) / _sr


func is_finished() -> bool:
	return true


## Longest this voice may plausibly run. The mixer force-retires anything past
## it; a voice that is wrong about its own length is a leak, not a sound.
func max_seconds() -> float:
	return 4.0
