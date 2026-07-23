extends RefCounted
## Keyboard/gamepad input source. Reads the project [input] actions and
## reports raw intents only — every interpretation (reverse engagement, key gating,
## source priority, the headlight cycle) happens in InputRouter, nowhere else. Headlights report a per-frame `lights_cycle` EDGE, not a level: InputRouter
## owns the OFF->CLEARANCE->LOW->HIGH state so keyboard and touch share one owner.


func poll(_delta: float) -> Dictionary:
	# R/F drive one vertical axis shared by both aircraft (plane elevator / drone climb);
	# the families are mutually exclusive so each reads only its own field. + = up.
	var vert := Input.get_action_strength("aircraft_up") - Input.get_action_strength("aircraft_down")
	return {
		"accel": Input.get_action_strength("accel"),
		"brake_reverse": Input.get_action_strength("brake_reverse"),
		"steer": Input.get_action_strength("steer_right") - Input.get_action_strength("steer_left"),
		"handbrake": Input.get_action_strength("handbrake"),
		"horn": Input.is_action_pressed("horn"),
		"lights_cycle": Input.is_action_just_pressed("headlights"),
		"hitch_toggle": Input.is_action_just_pressed("hitch"),
		"pto_toggle": Input.is_action_just_pressed("pto"),
		"elevator": vert,
		"climb": vert,
		"arm_toggle": Input.is_action_just_pressed("arm"),
	}
