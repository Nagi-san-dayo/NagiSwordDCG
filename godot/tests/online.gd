## オンライン対戦テスト: godot --headless --path . -s tests/online.gd -- --server=http://localhost:3000
extends SceneTree

var main: Control

func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()

func _run() -> void:
	var g: NagisoGame = main.game
	var t0 := Time.get_ticks_msec()
	while not g.socket.is_connected_to_server():
		await process_frame
		if Time.get_ticks_msec() - t0 > 10000:
			print("ONLINE: connect timeout"); quit(1); return
	print("ONLINE: connected")
	g.user_name = "ゴドー"
	g.game_mode = "online_room"
	g.room_name = "testroom"
	g.handle_deck_select("agro")
	while not g.is_game_started:
		await process_frame
	print("ONLINE: game started, my turn=", g.is_player_turn)
	var turns := 0
	t0 = Time.get_ticks_msec()
	while turns < 3 and not g.is_game_over and Time.get_ticks_msec() - t0 < 30000:
		await process_frame
		if g.is_player_turn and not g.is_selecting_token and not g.is_selecting_discard:
			for c in g.player_hand.duplicate():
				if g.can_play(c):
					print("ONLINE: playing ", c["name"])
					g.handle_hand_card_click(c)
					break
			await create_timer(0.3).timeout
			g.end_player_turn()
			turns += 1
			print("ONLINE: ended turn ", turns)
	await create_timer(1.0).timeout
	print("ONLINE: final my HP=", g.player_hp, " enemy HP=", g.cpu_hp, " enemyHand=", g.cpu_hand_length, " enemyDeck=", g.cpu_deck_length)
	print("ONLINE LOG:\n  ", "\n  ".join(g.log_messages.slice(-25)))
	quit()
