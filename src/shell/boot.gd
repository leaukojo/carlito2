extends Node3D
## Shell: boot -> level select -> load level -> play, with an in-play garage
## menu. Composes independent level/UI scenes — there is no giant
## main.tscn. The persistent HUD (dashboard, debug overlay, touch controls) lives in
## boot.tscn; the level-select and garage screens are transient overlays created here.

@onready var _ui: CanvasLayer = $UI
@onready var _hint: Label = $UI/Label
@onready var _dashboard: Dashboard = $UI/Dashboard
@onready var _touch: TouchControls = $UI/TouchControls
@onready var _debug: DebugOverlay = $UI/DebugOverlay

var _level: Node3D = null
var _select: LevelSelect = null
var _garage: GarageMenu = null


func _ready() -> void:
	var contract_state := "invalid - see errors above"
	if Contract.data != null and Contract.data.is_valid():
		contract_state = "v%d, %d signals" % [Contract.data.version, Contract.data.signals.size()]
	print("carlito2 boot OK (contract: %s, bridge active: %s)" % [contract_state, Bridge.is_active()])

	_touch.menu_pressed.connect(_return_to_menu)
	_touch.garage_pressed.connect(_open_garage)
	_touch.respawn_pressed.connect(_respawn)
	_touch.next_vehicle_pressed.connect(_cycle_vehicle)
	_touch.camera_pressed.connect(_cycle_camera)
	# The headless CI smoke can't click the menu, so boot straight into the first level
	# there — this keeps the smoke exercising the full load -> spawn -> play path.
	# CARLITO_LEVEL picks a different registry id, so CI can also smoke a baked level
	# without reordering the registry.
	if DisplayServer.get_name() == "headless":
		var wanted := OS.get_environment("CARLITO_LEVEL")
		var scene := String(LevelRegistry.LEVELS[0]["scene"])
		for entry in LevelRegistry.LEVELS:
			if String(entry["id"]) == wanted:
				scene = String(entry["scene"])
		_load_level(scene)
	else:
		_show_level_select()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("to_menu"):
		_return_to_menu()
	elif event.is_action_pressed("garage"):
		_open_garage()
	elif event.is_action_pressed("next_vehicle"):
		_cycle_vehicle()


## Swap to the next variant in the current family (V key / touch button). Reuses the
## level's spawn/respawn path; a family with one variant is a no-op.
func _cycle_vehicle() -> void:
	if _level == null or _level.vehicle == null:
		return
	_level.set_vehicle(VehicleCatalog.next_in_family(GameState.current_variant))


# --- level select ------------------------------------------------------------

## Tear down the active level and return to the level-select screen (Esc / MENU button).
func _return_to_menu() -> void:
	if _select != null:
		return  # already at the menu
	_close_garage()
	if _level != null:
		_level.queue_free()
		_level = null
	Bridge.bind(null)
	_show_level_select()



func _show_level_select() -> void:
	_set_hud_visible(false)
	_select = LevelSelect.new()
	_select.level_chosen.connect(_on_level_chosen)
	_ui.add_child(_select)


func _on_level_chosen(scene_path: String) -> void:
	if _select != null:
		_select.queue_free()
		_select = null
	_load_level(scene_path)


func _load_level(scene_path: String) -> void:
	if _level != null:
		_level.queue_free()
	_level = (load(scene_path) as PackedScene).instantiate()
	add_child(_level)  # level._ready() spawns the vehicle synchronously here
	_level.vehicle_changed.connect(_on_vehicle_changed)
	_bind_hud()
	_set_hud_visible(true)


## (Re)bind the HUD + bridge to the active level/vehicle. Called at load and whenever the
## garage swaps the vehicle (its type drives which dashboard cluster is built).
func _bind_hud() -> void:
	_dashboard.bind(_level)
	_debug.set_level(_level)  # F3 overlay reads the active vehicle's per-wheel surface grip
	Bridge.bind(_level)  # telemetry source for the ~20 Hz outbound publish (web only)


func _on_vehicle_changed(_type: String) -> void:
	_bind_hud()


# --- garage ------------------------------------------------------------------

func _open_garage() -> void:
	if _level == null or _garage != null:
		return
	_garage = GarageMenu.new()
	_garage.setup(_level.info.allowed_vehicles)
	_garage.vehicle_chosen.connect(_on_garage_choice)
	_garage.closed.connect(_close_garage)
	_ui.add_child(_garage)


func _on_garage_choice(type: String) -> void:
	_close_garage()
	# The garage chooses a FAMILY; spawn that family's first (legacy) variant.
	_level.set_vehicle(VehicleCatalog.first_in_family(type))


func _close_garage() -> void:
	if _garage != null:
		_garage.queue_free()
		_garage = null


func _cycle_camera() -> void:
	if _level != null:
		_level.cycle_camera()


func _respawn() -> void:
	if _level != null and _level.vehicle != null:
		_level.vehicle.respawn()


# --- helpers -----------------------------------------------------------------

func _set_hud_visible(v: bool) -> void:
	_hint.visible = v
	_dashboard.visible = v
	_touch.set_active(v)
