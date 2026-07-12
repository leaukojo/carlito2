class_name TractorTelemetry
extends VehicleTelemetry
## Tractor telemetry (ISOBUS flavor). Adds the four ISOBUS "out" fields on
## top of the ground-vehicle VehicleTelemetry. Field names are EXACTLY the contract names
## (hitch_pos_actual/pto_state/pto_rpm/engine_load) so the Bridge's name-keyed marshaling
## and the dashboard's t.get(name) reads work unchanged.
##
## hitch_pos_actual / pto_state / pto_rpm are read straight out of the tractor sim
## (real values read from the sim); engine_load is a modeled honest value (same latitude
## as fuel/coolant/battery), computed by the pure engine_load_pct below and unit-tested.

const PTO_RPM_MAX := 1200          ## contract 'pto_rpm' range max

var hitch_pos_actual := 100        ## %, contract 'hitch_pos_actual'
var pto_state := false             ## contract 'pto_state'
var pto_rpm := 0                   ## rev/min, contract 'pto_rpm'
var engine_load := 0               ## %, contract 'engine_load'


## Modeled engine load (honest-model latitude, like fuel/coolant): throttle
## demand, plus a parasitic term while the PTO is engaged. Pure -> unit-tested.
static func engine_load_pct(throttle: float, pto_on: bool, pto_load: float) -> float:
	var load := clampf(absf(throttle), 0.0, 1.0)
	if pto_on:
		load = clampf(load + pto_load, 0.0, 1.0)
	return load * 100.0


func to_bridge_dict() -> Dictionary:
	var d := super()
	d["hitch_pos_actual"] = hitch_pos_actual
	d["pto_state"] = pto_state
	d["pto_rpm"] = pto_rpm
	d["engine_load"] = engine_load
	return d
