extends Node

const GS := preload("res://autoload/game_state.gd")

var rec: GS.PetRecord = null

func _ready() -> void:
	rec = GS.PetRecord.new()
	rec.growth = 1.0
	print("PROBE_OK stage=", rec.stage())
	get_tree().quit(0)
