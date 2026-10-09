class_name Title
extends Node2D
## Minimal title menu until the original title screen is ported.

const ITEMS := ["開始遊戲", "讀取進度", "離開遊戲"]
var sel := 0


func _draw() -> void:
	draw_rect(Rect2(0, 0, 320, 200), Color.BLACK)
	var font := Assets.font_texture
	_text("軒轅劍外傳　楓之舞", Vector2(88, 48), Color(0.95, 0.8, 0.5))
	for i in ITEMS.size():
		_text(ITEMS[i], Vector2(128, 100 + i * 22), Color.WHITE if i == sel else Color(0.5, 0.5, 0.5))


func _text(s: String, at: Vector2, c: Color) -> void:
	var x := at.x
	for ch in s:
		var r := Assets.glyph_rect(ch)
		if r.size != Vector2.ZERO:
			draw_texture_rect_region(Assets.font_texture, Rect2(Vector2(x, at.y), r.size), r, c)
		x += 16


func choose() -> int:
	queue_redraw()
	while true:
		await get_tree().process_frame
		if Keys.just("ui_down"):
			sel = (sel + 1) % ITEMS.size()
			queue_redraw()
		elif Keys.just("ui_up"):
			sel = (sel - 1 + ITEMS.size()) % ITEMS.size()
			queue_redraw()
		elif Keys.just("ui_accept"):
			return sel
	return -1
