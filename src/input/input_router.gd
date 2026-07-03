extends Node
## InputRouter autoload — merges input sources into one normalized struct (stub until P1a).
##
## Plan §4.3: three InputSources (keyboard/gamepad, touch, bridge) merge into a single
## VehicleInput. ALL arbitration lives here and nowhere else (plan §2 rule 5):
## bridge-active + in-gear => the gear owns direction; brake > accel > handbrake feel
## hierarchy; key must be in Ignition for throttle (plan §6). Vehicles never know
## which source is active.


## The normalized per-tick input every vehicle consumes.
class VehicleInput:
	var throttle := 0.0    ## -1..1, signed by direction (never from the brake)
	var brake := 0.0       ## 0..1 foot brake
	var steer := 0.0       ## -1..1, negative = left
	var handbrake := 0.0   ## 0..1
	var gear_request := 0  ## RAMN gear byte: 0=N, 1..6=D1-D6, 255=R
	var key := 1           ## 1=Lock, 2=On, 3=Ignition
	var horn := false
	var lights := 1        ## 1=OFF, 2=CLEARANCE, 3=LOW, 4=HIGH


## Current merged input. Stub: neutral until the sources land in P1a (local) and P3 (bridge).
## Returns a fresh instance — callers own (and may mutate) what they get.
func get_vehicle_input() -> VehicleInput:
	return VehicleInput.new()
