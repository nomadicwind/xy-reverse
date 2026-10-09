class_name Autoplay
extends Node
## Plays an input script, for automated tests and screenshots. One command per line:
##   wait <seconds>
##   press <action>            tap an input action (ui_accept, ui_up ...)
##   hold <action> <seconds>
##   mash <count> <seconds>    tap ui_accept count times, waiting between taps
##   shot <path.png>           save the screen
##   shots <prefix> <count> <seconds>   a screenshot every few seconds
##   trace on|off              print every script op
##   autokey on|off            text never waits for a key
##   speed <factor>            Engine.time_scale (waits scale too)
##   quit


func run_file(path: String) -> void:
	var lines := FileAccess.get_file_as_string(path).split("\n")
	await get_tree().process_frame
	for raw in lines:
		var l := raw.strip_edges()
		if l == "" or l.begins_with("#"):
			continue
		var p := l.split(" ", false)
		match p[0]:
			"wait":
				await get_tree().create_timer(float(p[1])).timeout
			"press":
				await _tap(p[1])
			"hold":
				Input.action_press(p[1])
				await get_tree().create_timer(float(p[2])).timeout
				Input.action_release(p[1])
			"mash":
				for i in int(p[1]):
					await _tap("ui_accept")
					await get_tree().create_timer(float(p[2])).timeout
			"shots":
				for i in int(p[2]):
					await RenderingServer.frame_post_draw
					get_viewport().get_texture().get_image().save_png("%s%03d.png" % [p[1], i])
					await get_tree().create_timer(float(p[3])).timeout
			"shot":
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(p[1])
				print("[autoplay] saved ", p[1])
			"autokey":
				Overlay.auto_continue = p[1] == "on"
			"speed":
				Engine.time_scale = float(p[1])
			"trace":
				var g = get_tree().root.find_child("Game", true, false)
				if g:
					g.vm.trace = p[1] == "on"
			"quit":
				get_tree().quit()


func _tap(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.action_press(action)
	await get_tree().process_frame
	await get_tree().process_frame
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	Input.action_release(action)
	await get_tree().process_frame
