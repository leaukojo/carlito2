extends Node
## Bridge autoload — CAN bridge to sloppyCAN (stub until P3 / plan M3).
##
## Plan §4.2: web-only postMessage transport (values stashed on a JS global read via
## JavaScriptBridge), freshness-gated ~300 ms, poll in ~60 Hz / publish out ~20 Hz.
## All field names come from the Contract autoload — never hand-written lists.
## On desktop the bridge stays inactive and the game runs on local input.


## Whether fresh bridge data is currently arriving. Drives UI decisions
## (e.g. hiding the manual lights button while sloppyCAN owns the lamps).
func is_active() -> bool:
	return false
