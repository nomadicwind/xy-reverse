extends Node
## Boot: title menu, then the game. Command-line options (after `--`) help
## automated testing:
##   --data=<dir>          extracted data folder
##   --newgame             skip the title and start a new game
##   --entry=<n>           start at entry point n (decimal or 0x..)
##   --autoplay=<file>     run an input script (see scripts/autoplay.gd)

var game: Game


func _ready() -> void:
	if not Assets.available():
		var l := Label.new()
		l.text = "找不到游戏数据。\n请先运行 scripts/extract.sh。\nNo extracted data found."
		add_child(l)
		return
	var args := OS.get_cmdline_user_args()
	var entry := -1
	var newgame := false
	var auto := ""
	for a in args:
		if a.begins_with("--entry="):
			var v := a.substr(8)
			entry = v.hex_to_int() if v.begins_with("0x") else int(v)
		elif a == "--newgame":
			newgame = true
		elif a.begins_with("--autoplay="):
			auto = a.substr(11)
	if auto != "":
		var ap := Autoplay.new()
		add_child(ap)
		ap.run_file(auto)
	if entry >= 0:
		_start_game()
		game.field.load_entry(entry)
		game._sync_palette()
		game.set_brightness(1.0)
	elif newgame:
		_start_game()
		game.start_new_game()
	else:
		_title()


func _start_game() -> void:
	if game:
		game.queue_free()
	for c in get_children():
		if c is Title:
			c.queue_free()
	game = Game.new()
	game.name = "Game"
	add_child(game)
	game.finished.connect(_title)


func _title() -> void:
	if game:
		game.queue_free()
		game = null
	var t := Title.new()
	add_child(t)
	var choice: int = await t.choose()
	t.queue_free()
	match choice:
		0:
			_start_game()
			game.start_new_game()
		1:
			var d := SaveFiles.load_slot(1)
			_start_game()
			if d.is_empty():
				game.start_new_game()
			else:
				game.load_saved(d)
		_:
			get_tree().quit()
