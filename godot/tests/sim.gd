## 自動対戦テスト: godot --headless --path . -s tests/sim.gd
extends SceneTree

var main: Control
var games_done := 0
var results := {}

func _initialize() -> void:
	Engine.time_scale = 30.0
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var g: NagisoGame = main.game
	var non_tokens := []
	for i in g.card_pool.size():
		if not g.card_pool[i]["name"] in NagisoGame.TOKEN_NAMES:
			non_tokens.append(i)
	for n in 60:
		g.reset_to_title()
		g.game_mode = "cpu"
		var t: String = ["agro", "ramp", "combo", "custom"][n % 4]
		if t == "custom":
			var deck := []
			for k in 30:
				deck.append(non_tokens.pick_random())
			g.custom_decks[0] = deck
			g.handle_deck_select("custom", 0)
		else:
			g.handle_deck_select(t)
		var steps := 0
		while not g.is_game_over and steps < 3000:
			steps += 1
			await process_frame
			if g.is_selecting_token:
				g.select_token(["draw", "burn", "heal"].pick_random())
			elif g.is_selecting_discard:
				for c in g.player_hand:
					if c["id"] != g.pending_card_to_play["id"] and not g.pending_discard_ids.has(c["id"]):
						g.handle_hand_card_click(c); break
			elif g.is_player_turn:
				var played := false
				for c in g.player_hand.duplicate():
					if g.can_play(c):
						g.handle_hand_card_click(c); played = true; break
				if not played:
					g.end_player_turn()
		var r: String = "win" if g.cpu_hp <= 0 and g.player_hp > 0 else ("lose" if g.player_hp <= 0 else ("timeout" if not g.is_game_over else "other"))
		results[r] = results.get(r, 0) + 1
	print("SIM RESULTS: ", results)
	# 画面遷移テスト: エディタを開いて閉じる
	main._open_editor(1)
	await process_frame
	for i in 30: main._add_to_deck(i % 40)
	main._save_editor()
	await process_frame
	print("EDITOR SAVED: ", g.custom_decks[1] != null, " len=", (g.custom_decks[1] as Array).size())
	quit()
