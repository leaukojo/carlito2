class_name TrainTelemetry
extends VehicleTelemetry
## Train telemetry (flavor "train" — rail practice / CiA 421 semantics, not a real train
## CAN standard). Adds the rail "out" fields on top of the shared VehicleTelemetry. Field
## names are EXACTLY the contract names (pantograph_state / doors_state / catenary_volts /
## motor_current / brake_pipe / grade / coupler_force) so the Bridge's name-keyed
## marshaling and the dashboard's t.get(name) reads work unchanged.
##
## grade and coupler_force are real reads out of the consist sim (curve tangent, coupler
## spring); pantograph_state / doors_state are gate reads. catenary_volts, motor_current
## and brake_pipe are modeled honest values (same latitude as the boat's trim / the
## tractor's engine_load) — the train has no simulated electrical or pneumatic circuit.
##
## Phase 2 ships the struct only: every field holds its resting value until Phase 3's
## TrainVehicle drives them. Declaring them now keeps the bridge-coverage test honest the
## moment the contract lists the train "out" signals.
##
## The base to_bridge_dict still carries rpm/fuel/coolant/ground/slip; the train declares
## none of those, so the Bridge (which walks the contract, not this dict) never reads them.

const BRAKE_PIPE_CHARGED := 5.0  ## bar, fully released train brake pipe pressure

var pantograph_state := false  ## contract 'pantograph_state' (raised: request and key Ignition)
var doors_state := false       ## contract 'doors_state' (open: request honored at standstill)
var catenary_volts := 0.0      ## V, contract 'catenary_volts' (modeled: nominal minus sag)
var motor_current := 0.0       ## A, contract 'motor_current' (modeled from traction force)
var brake_pipe := BRAKE_PIPE_CHARGED  ## bar, contract 'brake_pipe' (modeled air brake)
var grade := 0.0               ## %, contract 'grade' (track slope at the loco, + = climbing)
var coupler_force := 0.0       ## kN, contract 'coupler_force' (+ = tension, - = buff)


func to_bridge_dict() -> Dictionary:
	var d := super()
	d["pantograph_state"] = pantograph_state
	d["doors_state"] = doors_state
	d["catenary_volts"] = catenary_volts
	d["motor_current"] = motor_current
	d["brake_pipe"] = brake_pipe
	d["grade"] = grade
	d["coupler_force"] = coupler_force
	return d
