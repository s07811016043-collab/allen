class_name NavSegment
extends RefCounted

## One playable move in a path.
##
## The planner deliberately does not emit a polyline. A list of points tells the
## rig nothing about whether to walk, leap or haul itself over a lip, and the
## difference between those is the whole animation. A segment is instead a
## *typed* instruction the traversal executor can turn into motion and the rig
## can turn into a pose.

enum Move {
	WALK,        ## Along a surface, feet down the whole way.
	JUMP,        ## Ballistic arc with a takeoff crouch and a landing absorb.
	CLIMB_UP,    ## Up a vertical face, ending in an edge grab and pull-up.
	CLIMB_DOWN,  ## Over a lip and down a face, feet-first.
	DROP,        ## Step off and fall. No upward impulse.
	FLY,         ## Powered/gliding arc between two perches.
}

## One of `Move`. Held as a plain int so planners can pass values around
## without the parser demanding an explicit enum cast at every hop.
var move: int = Move.WALK
var from: Vector2 = Vector2.ZERO
var to: Vector2 = Vector2.ZERO
## Ledge ids at each end. -1 when the endpoint is a free point in space (the
## pet was dropped by the player and is falling to the nearest surface).
var from_ledge: int = -1
var to_ledge: int = -1
## Rescan-stable identity of the destination, so a re-plan can tell "the ledge I
## was heading for moved" from "the ledge I was heading for is gone".
var to_key: String = ""
## Planned wall-clock seconds, including the fixed crouch/land/grab beats. The
## executor reproduces this closely; the planner needs it to compare routes.
var duration: float = 0.0
## Screen-space y of the top of the arc, for JUMP / DROP / FLY.
var apex: float = 0.0
## Solved launch velocity: `vx` in screen pixels/s, `vy` positive *upward*.
var vx: float = 0.0
var vy: float = 0.0
## +1 facing right, -1 facing left. Zero-length moves inherit the previous one.
var facing: float = 1.0


func length() -> float:
	return from.distance_to(to)


## True while the pet is off the ground and cannot change its mind. The
## navigator refuses to re-plan during these, because rewriting a ballistic arc
## mid-flight is exactly the teleport we are trying to avoid.
func is_committed() -> bool:
	return move == Move.JUMP or move == Move.DROP or move == Move.FLY


static func move_name(m: int) -> String:
	match m:
		Move.WALK: return "walk"
		Move.JUMP: return "jump"
		Move.CLIMB_UP: return "climb_up"
		Move.CLIMB_DOWN: return "climb_down"
		Move.DROP: return "drop"
		Move.FLY: return "fly"
	return "?"


static func make(m: int, a: Vector2, b: Vector2) -> NavSegment:
	var s := NavSegment.new()
	s.move = m
	s.from = a
	s.to = b
	s.facing = 1.0 if b.x >= a.x else -1.0
	return s


func _to_string() -> String:
	return "<%s %s->%s %.2fs>" % [move_name(move), from, to, duration]
