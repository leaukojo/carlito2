class_name LevelRegistry
extends Object
## The shell's list of playable levels. The level-select screen reads this;
## levels are self-contained scenes, so adding one is a new entry here
## plus its `.tscn`. `name` is a plain-text menu label (LevelInfo.display_name is the
## in-level authority; kept here too so select needn't load every scene to build a list).
##
## `dev: true` entries are test assets, not shipped content: level-select hides them, but
## the bake/check tools and the CARLITO_LEVEL smoke still iterate the full list, so CI
## covers them.
##
## The five island levels are independent playgrounds: level_1 is dressed; 2-5 ship
## generated terrain + auto-splat and an empty AuthoringRoot, ready to author
## (see tools/gen_islands.gd).

const LEVELS: Array[Dictionary] = [
	{ "id": "garage", "name": "Garage", "scene": "res://src/levels/garage/garage.tscn" },
	{ "id": "level_1", "name": "Level 1 - Island", "scene": "res://src/levels/island/level_1/level_1.tscn" },
	{ "id": "level_2", "name": "Level 2 - Bay Islands", "scene": "res://src/levels/island/level_2/level_2.tscn" },
	{ "id": "level_3", "name": "Level 3 - Highlands", "scene": "res://src/levels/island/level_3/level_3.tscn" },
	{ "id": "level_4", "name": "Level 4 - Archipelago", "scene": "res://src/levels/island/level_4/level_4.tscn" },
	{ "id": "level_5", "name": "Level 5 - Railway", "scene": "res://src/levels/island/level_5/level_5.tscn" },
]
