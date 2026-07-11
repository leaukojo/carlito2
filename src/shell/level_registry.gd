class_name LevelRegistry
extends Object
## The shell's list of playable levels (plan §4.6). The level-select screen reads this;
## levels are self-contained scenes (plan §2 rule 6), so adding one is a new entry here
## plus its `.tscn`. `name` is a plain-text menu label (LevelInfo.display_name is the
## in-level authority; kept here too so select needn't load every scene to build a list).
##
## `dev: true` entries are test assets, not shipped content: level-select hides them, but
## the bake/check tools and the CARLITO_LEVEL smoke still iterate the full list, so CI
## covers them. kit_fixture is the permanent minimal bake canary (level_kit_plan.md §4 LK1).

const LEVELS: Array[Dictionary] = [
	{ "id": "gym", "name": "Dev Gym", "scene": "res://src/levels/gym/gym.tscn" },
	{ "id": "kit_fixture", "name": "Kit Fixture (dev)", "scene": "res://src/levels/dev/kit_fixture.tscn", "dev": true },
	# Temporary: registered so it also gets CI bake/check coverage; shown in level-select
	# only because dev entries are currently un-hidden (both removed later).
	{ "id": "terrain_demo", "name": "Terrain Demo (dev)", "scene": "res://src/levels/dev/terrain_demo.tscn", "dev": true },
]
