extends GdUnitTestSuite
## Shell menu overlays (plan §4.6): the level-select reads the registry, the garage reads
## the passed allowed-vehicle list, and both emit their pick. Pure Control scenes, so
## they build and fire headless without a 3D level.

const LevelSelect := preload("res://src/ui/level_select.gd")
const GarageMenu := preload("res://src/ui/garage_menu.gd")


func _buttons(node: Node) -> Array:
	var out := []
	for b in node.find_children("*", "Button", true, false):
		out.append(b)
	return out


func test_level_select_lists_registry_and_emits_scene() -> void:
	var sel: LevelSelect = auto_free(LevelSelect.new())
	add_child(sel)
	var buttons := _buttons(sel)
	assert_int(buttons.size()).is_equal(LevelRegistry.LEVELS.size())

	var chosen := [""]
	sel.level_chosen.connect(func(path: String) -> void: chosen[0] = path)
	buttons[0].pressed.emit()
	assert_str(chosen[0]).is_equal(String(LevelRegistry.LEVELS[0]["scene"]))


func test_garage_lists_allowed_vehicles_and_emits_choice() -> void:
	var garage: GarageMenu = auto_free(GarageMenu.new())
	garage.setup(PackedStringArray(["car", "truck"]))
	add_child(garage)
	# One button per allowed vehicle plus the CLOSE button.
	var labels := []
	for b in _buttons(garage):
		labels.append(b.text)
	assert_array(labels).contains(["CAR", "TRUCK", "CLOSE"])

	var picked := [""]
	garage.vehicle_chosen.connect(func(t: String) -> void: picked[0] = t)
	for b in _buttons(garage):
		if b.text == "TRUCK":
			b.pressed.emit()
	assert_str(picked[0]).is_equal("truck")


func test_garage_close_emits_closed() -> void:
	var garage: GarageMenu = auto_free(GarageMenu.new())
	garage.setup(PackedStringArray(["car"]))
	add_child(garage)
	var closed := [false]
	garage.closed.connect(func() -> void: closed[0] = true)
	for b in _buttons(garage):
		if b.text == "CLOSE":
			b.pressed.emit()
	assert_bool(closed[0]).is_true()
