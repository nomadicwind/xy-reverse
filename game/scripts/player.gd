extends Node2D
## Placeholder walker until the field sprites are decoded.

@export var speed := 60.0
var bounds := Rect2(0, 0, 320, 200)


func _process(delta: float) -> void:
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	position += dir * speed * delta
	position = position.clamp(bounds.position, bounds.end)


func _draw() -> void:
	draw_rect(Rect2(-4, -12, 8, 12), Color(0.9, 0.2, 0.2))
	draw_rect(Rect2(-4, -12, 8, 12), Color.WHITE, false)
