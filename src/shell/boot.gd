extends Node3D
## Boot: prints autoload status, then loads the current playable scene.
## Proto-shell — becomes boot -> level select -> play as M1+ progresses (plan §4.6).

const PLAY_SCENE := preload("res://src/levels/dev/flat.tscn")


func _ready() -> void:
	var contract_state := "invalid - see errors above"
	if Contract.data != null and Contract.data.is_valid():
		contract_state = "v%d, %d signals" % [Contract.data.version, Contract.data.signals.size()]
	print("carlito2 boot OK (contract: %s, bridge active: %s)" % [contract_state, Bridge.is_active()])
	add_child(PLAY_SCENE.instantiate())
