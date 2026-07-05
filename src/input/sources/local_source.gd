extends RefCounted
## Keyboard/gamepad input source (plan §4.3). Reads the project [input] actions and
## reports raw intents only — every interpretation (reverse engagement, key gating,
## source priority, the headlight cycle) happens in InputRouter, nowhere else (plan §2
## rule 5). Headlights report a per-frame `lights_cycle` EDGE, not a level: InputRouter
## owns the OFF->CLEARANCE->LOW->HIGH state so keyboard and touch share one owner.


func poll(_delta: float) -> Dictionary:
	return {
		"accel": Input.get_action_strength("accel"),
		"brake_reverse": Input.get_action_strength("brake_reverse"),
		"steer": Input.get_action_strength("steer_right") - Input.get_action_strength("steer_left"),
		"handbrake": Input.get_action_strength("handbrake"),
		"horn": Input.is_action_pressed("horn"),
		"lights_cycle": Input.is_action_just_pressed("headlights"),
	}
