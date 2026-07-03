extends Node
## GameState autoload — current level/vehicle bookkeeping (stub until the shell lands).
##
## Plan §4.6: the shell composes independent level/vehicle/UI scenes at runtime;
## this autoload only tracks what is currently active.

var current_level := ""    ## res:// path of the loaded level scene ("" = none)
var current_vehicle := ""  ## vehicle type id, e.g. "car" (matches contract 'vehicles' tags)
