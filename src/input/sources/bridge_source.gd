extends RefCounted
## Bridge input source (plan §4.3, M3). Reads the freshness-gated inbound values the Bridge
## autoload polls from sloppyCAN and reports them as raw intents — like local_source.gd, every
## interpretation (gear-owns-direction, key gating) happens in InputRouter (plan §2 rule 5).
##
## Fields are the contract "in" names; the driving-relevant subset is normalized to VehicleInput
## ranges here (percent → unit). Lamp tell-tale bits (turnL/turnR/checkEngine/battery/brakeLamp)
## also arrive on the Bridge but are consumed at M4, not routed through VehicleInput.


func poll() -> Dictionary:
	var v := Bridge.get_input_values()
	if v.is_empty():
		return {"active": false}
	return {
		"active": true,
		"accel": clampf(float(v.get("accel", 0.0)) / 100.0, 0.0, 1.0),
		"brake": clampf(float(v.get("brake", 0.0)) / 100.0, 0.0, 1.0),
		"steer": clampf(float(v.get("steer", 0.0)) / 100.0, -1.0, 1.0),
		"handbrake": clampf(float(v.get("handbrake", 0.0)), 0.0, 1.0),
		"gear": int(v.get("gear", 0)),
		"key": int(v.get("key", 1)),
		"lights": int(v.get("lights", 1)),
		"horn": bool(v.get("horn", 0)),
	}
