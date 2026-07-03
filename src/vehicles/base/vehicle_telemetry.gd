class_name VehicleTelemetry
extends RefCounted
## Per-tick telemetry published by BaseVehicle (plan §4.4). Minimal M1 set — only
## values the sim actually produces (plan §2 rule 3: no derived fictions). M2
## completes the struct (GPS, odometer, fuel, coolant, status bitfield, ...).

var speed := 0.0        ## signed longitudinal m/s (contract 'speed')
var kmh := 0.0          ## absolute km/h (contract 'kmh')
var rpm := 0.0          ## real engine RPM out of the drivetrain (contract 'rpm')
var gear_byte := 0      ## RAMN byte: 0=N, 1..6=D1-D6, 255=R (contract 'gear')
var throttle := 0.0     ## -1..1 as applied, signed by direction (contract 'throttle')
var steer := 0.0        ## -1..1 as applied (contract 'steer')
var slip_front := 0.0   ## mean |longitudinal slip ratio| per axle (contract 'slip')
var slip_rear := 0.0
var ground := false     ## all wheels in contact (contract 'ground')
