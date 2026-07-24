extends RefCounted
## Bridge input source. Reads the freshness-gated inbound values the Bridge
## autoload polls from sloppyCAN and reports them as raw intents — like local_source.gd, every
## interpretation (gear-owns-direction, key gating) happens in InputRouter.
##
## Fields are the contract "in" names; the driving-relevant subset is normalized to VehicleInput
## ranges here (percent → unit). Lamp/warning bits (turnL/turnR/brakeLamp/checkEngine/battery)
## pass through as bools for LampSet + the dashboard tell-tales (mirrored verbatim).


func poll() -> Dictionary:
	var v := Bridge.get_input_values()
	if v.is_empty():
		return {"active": false}
	var out := {
		"active": true,
		"accel": clampf(float(v.get("accel", 0.0)) / 100.0, 0.0, 1.0),
		"brake": clampf(float(v.get("brake", 0.0)) / 100.0, 0.0, 1.0),
		"steer": clampf(float(v.get("steer", 0.0)) / 100.0, -1.0, 1.0),
		"handbrake": clampf(float(v.get("handbrake", 0.0)), 0.0, 1.0),
		"gear": int(v.get("gear", 0)),
		"key": int(v.get("key", 1)),
		"lights": int(v.get("lights", 1)),
		"horn": bool(v.get("horn", 0)),
		"turnL": bool(v.get("turnL", 0)),
		"turnR": bool(v.get("turnR", 0)),
		"brakeLamp": bool(v.get("brakeLamp", 0)),
		"checkEngine": bool(v.get("checkEngine", 0)),
		"battery": bool(v.get("battery", 0)),
		# ISOBUS implement inputs (tractor). Kept in contract units here (percent, flag);
		# arbitrate_bridge normalizes hitch_pos %→unit. Absent → raised/off (§6 default).
		"hitch_pos": clampf(float(v.get("hitch_pos", 100.0)), 0.0, 100.0),
		"pto": bool(v.get("pto", false)),
		# Flight controls (plane/drone). elevator/climb are i8 %; normalize %→unit like
		# steer. arm is a bool. Absent → neutral/disarmed (arbitrate_bridge defaults them).
		"elevator": clampf(float(v.get("elevator", 0.0)) / 100.0, -1.0, 1.0),
		"climb": clampf(float(v.get("climb", 0.0)) / 100.0, -1.0, 1.0),
		"arm": bool(v.get("arm", false)),
		"flaps": clampf(float(v.get("flaps", 0.0)) / 100.0, 0.0, 1.0),
		# Train controls (train). Bools; absent → lowered/shut (arbitrate_bridge defaults them).
		"pantograph": bool(v.get("pantograph", false)),
		"doors": bool(v.get("doors", false)),
	}
	# Boat rudder: included ONLY when sloppyCAN sends it —
	# presence is what makes it override 'steer' in arbitrate_bridge. Normalized %→unit
	# like steer.
	if v.has("rudder"):
		out["rudder"] = clampf(float(v.get("rudder", 0.0)) / 100.0, -1.0, 1.0)
	return out
