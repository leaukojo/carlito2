extends Node3D
## M0 boot scene: proves the deployed build loads and the autoloads initialize.
## Replaced by the real shell (boot -> level select -> play) from M1 on.


func _ready() -> void:
	var contract_state := "invalid - see errors above"
	if Contract.data != null and Contract.data.is_valid():
		contract_state = "v%d, %d signals" % [Contract.data.version, Contract.data.signals.size()]
	print("carlito2 boot OK (contract: %s, bridge active: %s)" % [contract_state, Bridge.is_active()])
