class_name Keys
extends RefCounted
## Key-press edges for menu loops that poll once per frame. Unlike
## Input.is_action_just_pressed this cannot miss a press that lands between
## two polls (synthetic presses from Autoplay often do).

static var _down := {}


static func just(action: String) -> bool:
	var d := Input.is_action_pressed(action)
	var was: bool = _down.get(action, false)
	_down[action] = d
	return d and not was


## Forget held keys, so a key still down from the previous menu does not count.
static func reset() -> void:
	for a in ["ui_accept", "ui_cancel", "ui_up", "ui_down", "ui_left", "ui_right"]:
		_down[a] = Input.is_action_pressed(a)
