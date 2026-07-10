class_name LevelRegistry
extends Object
## The shell's list of playable levels (plan §4.6). The level-select screen reads this;
## levels are self-contained scenes (plan §2 rule 6), so adding one is a new entry here
## plus its `.tscn`. `name` is a plain-text menu label (LevelInfo.display_name is the
## in-level authority; kept here too so select needn't load every scene to build a list).

const LEVELS: Array[Dictionary] = [
	{ "id": "gym", "name": "Dev Gym", "scene": "res://src/levels/gym/gym.tscn" },
]
