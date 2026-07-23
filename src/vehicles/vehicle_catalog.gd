class_name VehicleCatalog
extends RefCounted
## Static registry of vehicle VARIANTS. A *variant* is one concrete body scene; a
## *family* is the contract type id (car / truck / tractor / boat / bike) that drives the
## bridge marshaling, dashboard cluster and spawn filter. Many variants share one family —
## the garage still chooses a family, and V cycles the variants within it.
##
## The hand-built vehicles are variants of their own family (listed first, so a family
## resolves to its legacy body). The rest are the Kenney car kit and Watercraft pack (CC0),
## each generated with its own feel (tools/gen_kenney_vehicles, tools/gen_boat_variants).
## Pure static data + helpers, unit-tested in tests/test_vehicle_catalog.gd. The contract file is NOT touched:
## every variant maps to one of the four existing families.

const KENNEY := "res://src/vehicles/kenney/"
const WATERCRAFT := "res://src/vehicles/watercraft/"

## variant id -> { scene: String, family: String }. Insertion order is the cycle order.
const VARIANTS := {
	# -- hand-built (variant == family; first in each family = the legacy body) --
	"car": {"scene": "res://src/vehicles/car/car.tscn", "family": "car"},
	"truck": {"scene": "res://src/vehicles/truck/truck.tscn", "family": "truck"},
	"tractor": {"scene": "res://src/vehicles/tractor/tractor.tscn", "family": "tractor"},
	"boat": {"scene": "res://src/vehicles/boat/boat.tscn", "family": "boat"},
	"bike": {"scene": "res://src/vehicles/bike/bike.tscn", "family": "bike"},
	# -- bike family: recolors of the one hand-built body (variant == body colour) --
	"bike-motocross": {"scene": "res://src/vehicles/bike/bike-motocross.tscn", "family": "bike"},
	"bike-scooter": {"scene": "res://src/vehicles/bike/bike-scooter.tscn", "family": "bike"},
	# -- Watercraft pack: boat family --
	"boat-speed-a": {"scene": WATERCRAFT + "boat-speed-a.tscn", "family": "boat"},
	"boat-speed-j": {"scene": WATERCRAFT + "boat-speed-j.tscn", "family": "boat"},
	"boat-sail-a": {"scene": WATERCRAFT + "boat-sail-a.tscn", "family": "boat"},
	# -- Kenney car kit: car family --
	"sedan": {"scene": KENNEY + "sedan.tscn", "family": "car"},
	"sedan-sports": {"scene": KENNEY + "sedan-sports.tscn", "family": "car"},
	"hatchback-sports": {"scene": KENNEY + "hatchback-sports.tscn", "family": "car"},
	"suv": {"scene": KENNEY + "suv.tscn", "family": "car"},
	"suv-luxury": {"scene": KENNEY + "suv-luxury.tscn", "family": "car"},
	"taxi": {"scene": KENNEY + "taxi.tscn", "family": "car"},
	"police": {"scene": KENNEY + "police.tscn", "family": "car"},
	"race": {"scene": KENNEY + "race.tscn", "family": "car"},
	"race-future": {"scene": KENNEY + "race-future.tscn", "family": "car"},
	"van": {"scene": KENNEY + "van.tscn", "family": "car"},
	"pickup": {"scene": KENNEY + "pickup.tscn", "family": "car"},
	"pickup-flat": {"scene": KENNEY + "pickup-flat.tscn", "family": "car"},
	# -- Kenney car kit: truck family (J1939) --
	"delivery": {"scene": KENNEY + "delivery.tscn", "family": "truck"},
	"delivery-flat": {"scene": KENNEY + "delivery-flat.tscn", "family": "truck"},
	"firetruck": {"scene": KENNEY + "firetruck.tscn", "family": "truck"},
	"garbage-truck": {"scene": KENNEY + "garbage-truck.tscn", "family": "truck"},
	"ambulance": {"scene": KENNEY + "ambulance.tscn", "family": "truck"},
	# -- Kenney car kit: tractor family (ISOBUS) --
	"tractor-kenney": {"scene": KENNEY + "tractor-kenney.tscn", "family": "tractor"},
	"tractor-police": {"scene": KENNEY + "tractor-police.tscn", "family": "tractor"},
	"tractor-shovel": {"scene": KENNEY + "tractor-shovel.tscn", "family": "tractor"},
}


## The contract family a variant belongs to; "" if the variant is unknown.
static func family_of(variant: String) -> String:
	return String(VARIANTS[variant]["family"]) if VARIANTS.has(variant) else ""


## Scene path for a variant; "" if unknown.
static func scene_of(variant: String) -> String:
	return String(VARIANTS[variant]["scene"]) if VARIANTS.has(variant) else ""


## Variants in `family`, in cycle (insertion) order.
static func variants_in_family(family: String) -> PackedStringArray:
	var out := PackedStringArray()
	for v in VARIANTS:
		if String(VARIANTS[v]["family"]) == family:
			out.append(v)
	return out


## The family's legacy/first variant (what the garage spawns for that family); "" if none.
static func first_in_family(family: String) -> String:
	var vs := variants_in_family(family)
	return vs[0] if not vs.is_empty() else ""


## Next variant within the same family, wrapping around. Returns `variant` unchanged when
## it is unknown or the only one in its family.
static func next_in_family(variant: String) -> String:
	var vs := variants_in_family(family_of(variant))
	if vs.size() < 2:
		return variant
	var i := vs.find(variant)
	return vs[(i + 1) % vs.size()] if i >= 0 else vs[0]
