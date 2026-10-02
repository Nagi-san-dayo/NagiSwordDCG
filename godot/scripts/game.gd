## ナギソDCG のゲーム状態とルール。
## 元の index.html (Vue) の data / methods / watch をほぼそのまま移植している。
## 状態が変わったら mark_dirty() を呼び、次フレームで changed を 1 回だけ発火する（Vue の再描画相当）。
class_name NagisoGame
extends Node

signal changed
signal notice(user: String, card: Dictionary)
signal alert(message: String)

const SERVER_URL := "https://nagisworddcg-0.onrender.com/"
const SAVE_PATH := "user://nagiso_save.json"
const TOKEN_NAMES := ["アナライズナギソ", "レディアントナギソ", "エンシェントナギソ"]

var card_pool: Array = []
var ability_dictionary: Array = []
## プリセットデッキ（agro / ramp / combo）と CPU のカードプール（cpu）。どれも cardPool の番号
var deck_presets: Dictionary = {}
var socket: SocketIOClient

# --- プロフィール / 保存データ ---
var user_name := "一般ナギソ"
var custom_decks: Array = []       # 10 スロット: null または プール番号の配列
var custom_deck_names: Array = []

# --- モード ---
var game_mode := "cpu"   # cpu / online_random / online_room / spectate
var room_name := ""
var is_game_started := false
var is_game_over := false
var is_player_turn := true
var is_matching := false
var is_spectator := false
var selected_deck_type := ""
var selected_slot_index := -1
var is_first_turn := true

# --- 盤面 ---
var player_hp := 30
var cpu_hp := 30
var player_barrier := 0
var cpu_barrier := 0
var player_max_mana := 1
var player_current_mana := 1
var cpu_max_mana := 1
var cpu_current_mana := 1
var player_flesh_counter := 0
var cpu_flesh_counter := 0
var p1_flesh_counter := 0
var p2_flesh_counter := 0
var player_played_count_this_turn := 0
var cpu_played_count_this_turn := 0
var log_messages: Array[String] = ["モードとデッキを選んでゲームを始めてね！"]
var player_deck: Array = []
var cpu_deck: Array = []
var player_hand: Array = []
var cpu_hand: Array = []
var cpu_hand_length := 0
var cpu_deck_length := 30
var player_hand_length := 0
var player_deck_length := 30
var max_hand_size := 10
var total_max_mana_limit := 10
var p1_name := "プレイヤー1"
var p2_name := "プレイヤー2"

var is_selecting_discard := false
var pending_card_to_play: Variant = null
var pending_discard_ids: Array = []
var is_selecting_token := false
var token_selection_count := 0
var player_resonance_effects: Array = []
var cpu_resonance_effects: Array = []

var _dirty := false
var _session := 0   # タイトルに戻ったら古いタイマーを無効化するための世代番号
var _prev_player_deck_len := 0
var _prev_cpu_deck_len := 0


# =========================================================
# 初期化
# =========================================================
func _ready() -> void:
	card_pool = _load_json("res://data/cards.json")
	ability_dictionary = _load_json("res://data/abilities.json")
	deck_presets = _load_json("res://data/decks.json")
	custom_decks.resize(10)
	custom_deck_names.resize(10)
	custom_deck_names.fill("")
	_load_save()

	socket = SocketIOClient.new()
	add_child(socket)
	socket.event_received.connect(_on_socket_event)
	# 開発用: godot -- --server=http://localhost:3000 で接続先を差し替えられる
	var url := SERVER_URL
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--server="):
			url = arg.substr(9)
	socket.connect_to(url)
	mark_dirty()


func _load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return normalize(parsed)


## JSON の数値は float になるので、整数値は int に戻す（再帰）
static func normalize(v: Variant) -> Variant:
	if v is float and v == floor(v):
		return int(v)
	if v is Array:
		var out := []
		for x in v:
			out.append(normalize(x))
		return out
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = normalize(v[k])
		return d
	return v


func _load_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if not data is Dictionary:
		return
	data = normalize(data)
	if data.get("user_name") is String:
		user_name = data["user_name"]
	if data.get("custom_decks") is Array and data["custom_decks"].size() == 10:
		custom_decks = data["custom_decks"]
	if data.get("custom_deck_names") is Array and data["custom_deck_names"].size() == 10:
		custom_deck_names = data["custom_deck_names"]


func save_data() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"user_name": user_name,
		"custom_decks": custom_decks,
		"custom_deck_names": custom_deck_names,
	}))
	f.close()


# =========================================================
# 再描画 & watch（山札の偶奇 -> 共鳴）
# =========================================================
func mark_dirty() -> void:
	if _dirty:
		return
	_dirty = true
	_flush.call_deferred()


func _flush() -> void:
	_dirty = false
	var p_len := player_deck_length_c()
	var c_len := cpu_deck_length_c()
	var p_old := _prev_player_deck_len
	var c_old := _prev_cpu_deck_len
	_prev_player_deck_len = p_len
	_prev_cpu_deck_len = c_len
	if is_game_started and not is_spectator:
		if p_len % 2 == 0 and p_old % 2 != 0:
			trigger_resonance(true)
		if c_len % 2 == 0 and c_old % 2 != 0:
			trigger_resonance(false)
	changed.emit()


# =========================================================
# computed
# =========================================================
func is_cpu_mode() -> bool:
	return game_mode == "cpu"

func mode_description() -> String:
	match game_mode:
		"cpu": return "VS CPU"
		"online_random": return "ランダムマッチ"
		"online_room": return "ルームマッチ"
		"spectate": return "観戦モード"
	return ""

func enemy_display_name() -> String:
	if is_spectator:
		return p2_name
	return "CPU" if is_cpu_mode() else "対戦相手"

func player_display_name() -> String:
	return p1_name if is_spectator else user_name

func cpu_hand_length_c() -> int:
	return cpu_hand.size() if is_cpu_mode() else cpu_hand_length

func cpu_deck_length_c() -> int:
	return cpu_deck.size() if is_cpu_mode() else cpu_deck_length

func player_hand_length_c() -> int:
	return player_hand_length if is_spectator else player_hand.size()

func player_deck_length_c() -> int:
	return player_deck_length if is_spectator else player_deck.size()

func get_deck_name(index: int) -> String:
	var n: Variant = custom_deck_names[index]
	return n if n is String and n != "" else "デッキ %d" % (index + 1)


# =========================================================
# ユーティリティ
# =========================================================
static func generate_id() -> String:
	const CHARS := "abcdefghijklmnopqrstuvwxyz0123456789"
	var s := ""
	for i in 11:
		s += CHARS[randi() % CHARS.length()]
	return s


func create_card_instance(base: Dictionary) -> Dictionary:
	var c: Dictionary = base.duplicate(true)
	c["baseCost"] = base["cost"]
	c["id"] = generate_id()
	if not c.has("abilityText"):
		c["abilityText"] = ""
	return c


static func shuffled(arr: Array) -> Array:
	var c := arr.duplicate()
	c.shuffle()
	return c


static func find_ability(card: Dictionary, type: String) -> Variant:
	for ab in card.get("abilities", []):
		if ab.get("type") == type:
			return ab
	return null


static func has_ability(card: Dictionary, type: String) -> bool:
	return find_ability(card, type) != null


func find_pool_card(card_name: String) -> Variant:
	for c in card_pool:
		if c["name"] == card_name:
			return c
	return null


static func _index_by_id(arr: Array, id: String) -> int:
	for i in arr.size():
		if arr[i]["id"] == id:
			return i
	return -1


func add_log(msg: String) -> void:
	log_messages.append(msg)
	mark_dirty()
	if is_game_started and not is_spectator and not is_cpu_mode():
		if not msg.contains("召喚！") and not msg.contains("└【"):
			sync_state_to_server(msg)


func _push_log_only(msg: String) -> void:
	log_messages.append(msg)
	mark_dirty()


func _after(seconds: float, fn: Callable) -> void:
	var session := _session
	get_tree().create_timer(seconds).timeout.connect(func():
		if session == _session:
			fn.call()
	)


# =========================================================
# 灯火
# =========================================================
static func is_tomoshibi_ready(card: Dictionary) -> bool:
	var t: Variant = find_ability(card, "tomoshibi")
	return not (t != null and t["value"] > 0)


func reduce_tomoshibi(is_player: bool) -> bool:
	if not is_player and not is_cpu_mode():
		return false
	var hand := player_hand if is_player else cpu_hand
	var reduced := false
	var re := RegEx.create_from_string("【灯火(\\d+)】")
	for c in hand:
		var t: Variant = find_ability(c, "tomoshibi")
		if t != null and t["value"] > 0:
			t["value"] -= 1
			reduced = true
			if c.get("abilityText", "") != "":
				var m := re.search(c["abilityText"])
				if m:
					var txt: String = c["abilityText"]
					c["abilityText"] = txt.substr(0, m.get_start()) + "【灯火%d】" % t["value"] + txt.substr(m.get_end())
	if reduced and is_player and not is_cpu_mode() and not is_spectator:
		sync_state_to_server()
	mark_dirty()
	return reduced


# =========================================================
# 進行
# =========================================================
func reset_to_title() -> void:
	_session += 1
	is_game_started = false
	is_game_over = false
	is_spectator = false
	is_selecting_discard = false
	pending_card_to_play = null
	pending_discard_ids = []
	is_selecting_token = false
	token_selection_count = 0
	player_resonance_effects = []
	cpu_resonance_effects = []
	log_messages = ["モードとデッキを選んでゲームを始めてね！"]
	mark_dirty()


func handle_deck_select(type: String, slot_index: int = -1) -> void:
	selected_deck_type = type
	selected_slot_index = slot_index
	if game_mode == "online_random":
		is_matching = true
		socket.emit_event("join_matchmaking", {"name": user_name})
	elif game_mode == "online_room":
		if room_name.strip_edges() == "":
			alert.emit("ルーム名を入力してください。")
			return
		is_matching = true
		socket.emit_event("join_room_match", {"roomName": room_name, "name": user_name})
	else:
		_session += 1
		is_spectator = false
		is_player_turn = true
		is_first_turn = true
		setup_game_field(type)
		is_game_started = true
		add_log("🤖 CPU対戦を開始しました！")
	mark_dirty()


func start_spectating() -> void:
	if room_name.strip_edges() == "":
		alert.emit("観戦するルーム名を入力してください。")
		return
	is_matching = true
	is_spectator = true
	socket.emit_event("join_spectate", {"roomName": room_name, "userName": user_name})
	mark_dirty()


func cancel_matching() -> void:
	is_matching = false
	if is_spectator and not is_game_started:
		is_spectator = false
	socket.emit_event("cancel_matchmaking")
	add_log("❌ キャンセルしました。")


func setup_game_field(type: String) -> void:
	player_hp = 30; cpu_hp = 30
	player_barrier = 0; cpu_barrier = 0
	player_max_mana = 1; player_current_mana = 1
	cpu_max_mana = 1; cpu_current_mana = 1
	player_flesh_counter = 0; cpu_flesh_counter = 0
	player_hand = []; cpu_hand = []
	player_played_count_this_turn = 0; cpu_played_count_this_turn = 0
	is_selecting_discard = false; pending_card_to_play = null
	pending_discard_ids = []
	is_selecting_token = false
	token_selection_count = 0
	player_resonance_effects = []
	cpu_resonance_effects = []

	var indices: Array = []
	match type:
		"agro", "ramp", "combo": indices = deck_presets[type]
		"custom": indices = custom_decks[selected_slot_index]
	var deck := []
	for i in indices:
		deck.append(create_card_instance(card_pool[i]))
	player_deck = shuffled(deck)
	for i in 3:
		draw_card(true)

	if is_cpu_mode():
		var cpu_cards := []
		for i in 30:
			cpu_cards.append(create_card_instance(card_pool[deck_presets["cpu"].pick_random()]))
		cpu_deck = shuffled(cpu_cards)
		for i in 3:
			draw_card(false)
	else:
		cpu_hand_length = 3
		cpu_deck_length = 27
	mark_dirty()


func get_card_cost(card: Dictionary, is_player: bool) -> int:
	var cost: int = card["cost"]
	var p_len := player_hand.size()
	var c_len := cpu_hand.size() if is_cpu_mode() else cpu_hand_length
	var ab: Variant = find_ability(card, "lesshandcostdown")
	if ab != null:
		if is_player and p_len < c_len:
			cost -= ab["value"]
		elif not is_player and c_len < p_len:
			cost -= ab["value"]
	return maxi(0, cost)


func has_enough_flesh(card: Dictionary, is_player: bool) -> bool:
	var nie: Variant = find_ability(card, "nie")
	if nie != null and nie["value"] < 0:
		var current := player_flesh_counter if is_player else cpu_flesh_counter
		return current >= absi(nie["value"])
	return true


func can_play(card: Dictionary) -> bool:
	return not is_spectator and is_player_turn and not is_game_over and not is_selecting_discard \
		and player_current_mana >= get_card_cost(card, true) and has_enough_flesh(card, true) \
		and is_tomoshibi_ready(card) and not is_selecting_token


func apply_damage(is_player_target: bool, amount: int) -> void:
	if amount <= 0 or is_game_over:
		return
	if is_player_target:
		if player_barrier > 0:
			player_barrier -= 1
			add_log("🛡️ プレイヤーの【聖域】が作動し、ダメージを無効化した！(残り防壁: %d回)" % player_barrier)
		else:
			player_hp -= amount
	else:
		if cpu_barrier > 0:
			cpu_barrier -= 1
			add_log("🛡️ 相手の【聖域】が作動し、ダメージを無効化した！(残り防壁: %d回)" % cpu_barrier)
		else:
			cpu_hp -= amount
	mark_dirty()


func draw_card(is_player: bool) -> void:
	if is_game_over:
		return
	if is_player:
		if player_deck.is_empty():
			add_log("💀 【LO】山札が0枚のため敗北しました。")
			player_hp = 0
			check_win_lose()
			if not is_cpu_mode():
				sync_state_to_server("💀 【LO】山札が0枚のため敗北しました。")
			return
		var drawn: Dictionary = player_deck.pop_front()
		if player_hand.size() < max_hand_size:
			player_hand.append(drawn)
		else:
			add_log("🔥 手札が上限(10枚)を超えているため、【%s】は燃破した！" % drawn["name"])
	else:
		if is_cpu_mode():
			if cpu_deck.is_empty():
				add_log("💀 【LO】相手の山札が0枚のため勝利しました。")
				cpu_hp = 0
				check_win_lose()
				return
			var drawn: Dictionary = cpu_deck.pop_front()
			if cpu_hand.size() < max_hand_size:
				cpu_hand.append(drawn)
			else:
				add_log("🔥 相手の手札が上限(10枚)を超えているため、カードが1枚燃破した！")
		else:
			if cpu_hand_length < max_hand_size:
				cpu_hand_length += 1
			else:
				add_log("🔥 相手の手札が上限(10枚)を超えているため、カードが1枚燃破した！")
			cpu_deck_length -= 1
	if is_player and is_game_started and not is_cpu_mode() and not is_spectator:
		sync_state_to_server()
	mark_dirty()


func handle_hand_card_click(card: Dictionary) -> void:
	if is_spectator or is_selecting_token:
		return
	if is_selecting_discard:
		if card["id"] == pending_card_to_play["id"]:
			add_log("⚠️ プレイしようとしているカード自体は捨てられません！")
			return
		if pending_discard_ids.has(card["id"]):
			pending_discard_ids.erase(card["id"])
			mark_dirty()
			return
		var ab: Variant = find_ability(pending_card_to_play, "self_discard_select")
		var required: int = ab["value"] if ab != null else 1
		var max_selectable := mini(required, player_hand.size() - 1)
		pending_discard_ids.append(card["id"])
		if pending_discard_ids.size() >= max_selectable:
			is_selecting_discard = false
			var sync := {"discardTargetIds": pending_discard_ids.duplicate(), "chosenCardIndices": [], "chosenZenjiIndices": [], "chosenOnmyoIndices": [], "discardIndex": -1}
			var to_play: Dictionary = pending_card_to_play
			pending_card_to_play = null
			pending_discard_ids = []
			play_card(to_play, true, sync)
		mark_dirty()
		return

	if not is_player_turn or is_game_over or player_current_mana < get_card_cost(card, true) \
			or not has_enough_flesh(card, true) or not is_tomoshibi_ready(card):
		return

	var needs: Variant = find_ability(card, "self_discard_select")
	if needs != null and player_hand.size() > 1:
		pending_card_to_play = card
		is_selecting_discard = true
		pending_discard_ids = []
		var target := mini(needs["value"], player_hand.size() - 1)
		add_log("🔄 【%s】を発動。捨てる手札を %d 枚選んでクリックしてください..." % [card["name"], target])
	else:
		play_card(card, true)


func cancel_discard_select() -> void:
	is_selecting_discard = false
	pending_card_to_play = null
	pending_discard_ids = []
	add_log("❌ カードの使用をキャンセルしました。")


func play_card(card: Dictionary, is_player: bool, sync_data: Variant = null) -> void:
	if is_game_over:
		return
	if is_player:
		if _index_by_id(player_hand, card["id"]) == -1:
			return
	elif is_cpu_mode():
		var found := false
		for c in cpu_hand:
			if c["id"] == card["id"] or c["name"] == card["name"]:
				found = true
				break
		if not found:
			return

	var computed_cost := get_card_cost(card, is_player)
	if is_player and (not is_player_turn or player_current_mana < computed_cost \
			or not has_enough_flesh(card, true) or not is_tomoshibi_ready(card)):
		return

	var local_sync: Dictionary = sync_data if sync_data is Dictionary else {}
	for key in ["chosenCardIndices", "chosenZenjiIndices", "chosenOnmyoIndices"]:
		if not local_sync.get(key) is Array:
			local_sync[key] = []
	if not local_sync.has("discardIndex"):
		local_sync["discardIndex"] = -1
	if not local_sync.has("barrier_pierced"):
		local_sync["barrier_pierced"] = false

	var active_name := user_name if is_player else ("🤖 CPU" if is_cpu_mode() else "👤 相手")
	notice.emit(active_name, card)

	if is_player and not is_cpu_mode():
		for ab in card["abilities"]:
			match ab.get("type"):
				"kenko":
					for i in ab["value"]:
						local_sync["chosenCardIndices"].append(randi() % 30)
				"onmyo_in":
					var yo := _pool_indices_with("onmyo_yo")
					if not yo.is_empty():
						local_sync["chosenOnmyoIndices"].append(yo.pick_random())
				"onmyo_yo":
					var yin := _pool_indices_with("onmyo_in")
					if not yin.is_empty():
						local_sync["chosenOnmyoIndices"].append(yin.pick_random())
		for ab in card["abilities"]:
			if ab.get("type") == "keisin" and card["power"] >= ab["value"]:
				local_sync["barrier_pierced"] = true
	# 相手に送るのは能力処理で消費される前のコピー
	var sync_to_send: Dictionary = local_sync.duplicate(true)

	var pierce := false
	for ab in card["abilities"]:
		if ab.get("type") == "keisin" and card["power"] >= ab["value"]:
			pierce = true

	if is_player:
		player_current_mana -= computed_cost
		if pierce:
			cpu_hp -= card["power"]
			add_log("🗡️ 【逕侵穿突】聖域を貫通して%dダメージ！" % card["power"])
		else:
			apply_damage(false, card["power"])
		player_played_count_this_turn += 1
		var idx := _index_by_id(player_hand, card["id"])
		if idx != -1:
			player_hand.remove_at(idx)
		_push_log_only("👤 %sが【%s】を召喚！" % [user_name, card["name"]])
	else:
		cpu_current_mana -= computed_cost
		if pierce:
			player_hp -= card["power"]
			add_log("🗡️ 相手の【逕侵穿突】聖域を貫通して%dダメージ！" % card["power"])
		else:
			apply_damage(true, card["power"])
		cpu_played_count_this_turn += 1
		if is_cpu_mode():
			for i in cpu_hand.size():
				if cpu_hand[i]["id"] == card["id"] or cpu_hand[i]["name"] == card["name"]:
					cpu_hand.remove_at(i)
					break
		else:
			cpu_hand_length = maxi(0, cpu_hand_length - 1)
		_push_log_only("👤 相手が【%s】を召喚！" % card["name"])

	for ab in card["abilities"]:
		trigger_ability(ab, is_player, local_sync if is_player else sync_data)

	reduce_cost(is_player, card["id"])
	check_win_lose()

	if is_player and not is_cpu_mode():
		socket.emit_event("play_card", {"card": card, "currentMana": player_current_mana, "maxMana": player_max_mana, "syncData": sync_to_send})
		sync_state_to_server("👤 %sが【%s】を召喚！" % [user_name, card["name"]])
	mark_dirty()


func _pool_indices_with(type: String) -> Array:
	var out := []
	for i in card_pool.size():
		if has_ability(card_pool[i], type):
			out.append(i)
	return out


func boost_zenji_cards(cards: Array, amount: int) -> void:
	var re := RegEx.create_from_string("([^0-9]+)(\\d+)")
	for c in cards:
		if not has_ability(c, "zenjikouon"):
			continue
		for ab in c["abilities"]:
			if ab.get("type") != "zenjikouon" and ab.has("value"):
				ab["value"] += amount
		var txt: String = c.get("abilityText", "")
		if txt != "":
			var out := ""
			var last := 0
			for m in re.search_all(txt):
				out += txt.substr(last, m.get_start() - last)
				if m.get_string(1).contains("漸次昂音"):
					out += m.get_string()
				else:
					out += m.get_string(1) + str(int(m.get_string(2)) + amount)
				last = m.get_end()
			out += txt.substr(last)
			c["abilityText"] = out


func reduce_cost(is_player: bool, played_card_id: String = "") -> void:
	if not is_player and not is_cpu_mode():
		return
	var hand := player_hand if is_player else cpu_hand
	for c in hand:
		if played_card_id != "" and c["id"] == played_card_id:
			continue
		var r: Variant = find_ability(c, "costheru")
		if r != null:
			c["cost"] = maxi(0, c["cost"] - r["value"])


func select_token(token_type: String) -> void:
	var token_name := ""
	match token_type:
		"draw": token_name = "アナライズナギソ"
		"burn": token_name = "レディアントナギソ"
		"heal": token_name = "エンシェントナギソ"
	var base: Variant = find_pool_card(token_name)
	if base == null:
		push_error("%s が cardPool 内に見つかりません。" % token_name)
		return
	for i in token_selection_count:
		player_deck.append(create_card_instance(base))
	player_deck = shuffled(player_deck)
	add_log("  └【機巧増幅】「%s」を %d 枚山札に加えてシャッフルした！" % [token_name, token_selection_count])
	is_selecting_token = false
	token_selection_count = 0
	sync_state_to_server()
	mark_dirty()


func trigger_resonance(is_player: bool) -> void:
	var effects := player_resonance_effects if is_player else cpu_resonance_effects
	if effects.is_empty():
		return
	add_log("✨ 自身のデッキが偶数になり【共鳴】が発動した！" if is_player else "✨ 相手のデッキが偶数になり【共鳴】が発動した！")
	for eff in effects.duplicate():
		trigger_ability(eff, is_player, null)
	check_win_lose()
	if is_player:
		sync_state_to_server()


func _make_bread(ab: Dictionary) -> Dictionary:
	var bread := create_card_instance(find_pool_card("ナギソブレッド"))
	if ab.get("grants") is Array:
		for g in ab["grants"]:
			if g is Dictionary and g.has("type"):
				bread["abilities"].append({"type": g["type"], "value": g.get("value", 0)})
				bread["abilityText"] += " " + str(g.get("text", ""))
	return bread


func trigger_ability(ab: Dictionary, is_p: bool, sync_data: Variant) -> void:
	var type: String = str(ab.get("type", ""))
	var value: int = int(ab.get("value", 0))
	var current_count := player_played_count_this_turn if is_p else cpu_played_count_this_turn
	mark_dirty()

	match type:
		"draw":
			for i in value:
				draw_card(is_p)
			add_log("  └【流水%d】カードを %d 枚ドローした！" % [value, value] if is_p else "  └【流水%d】相手がカードを %d 枚ドローした！" % [value, value])

		"kikouzouhuku":
			if is_p:
				is_selecting_token = true
				token_selection_count = value
				add_log("⚙️ 【機巧増幅%d】山札へ埋め込む機巧を選択してください..." % value)
			else:
				if is_cpu_mode():
					var base: Dictionary = find_pool_card(TOKEN_NAMES.pick_random())
					for i in value:
						cpu_deck.append(create_card_instance(base))
					cpu_deck = shuffled(cpu_deck)
				add_log("  └【機巧増幅%d】相手はトークンを %d 枚山札に混ぜてシャッフルした！" % [value, value])

		"kyoumei":
			var effs: Array = []
			if ab.get("effects") is Array:
				effs = ab["effects"].duplicate(true)
			elif ab.get("effect") is Dictionary:
				effs = [ab["effect"].duplicate(true)]
			var label: String = str(ab.get("label", "")) if ab.has("label") else "共鳴"
			if is_p:
				player_resonance_effects.append_array(effs)
				add_log("  └【共鳴：%s】を獲得！以後、デッキが偶数枚になる度に能力が誘発する！" % label)
			else:
				cpu_resonance_effects.append_array(effs)
				add_log("  └【共鳴：%s】相手が共鳴永続バフを獲得！" % label)

		"nie":
			if is_p:
				if value > 0:
					player_flesh_counter += value
					add_log("  └【贄%d】骨カウンターを %d 付与した！(現在: %d)" % [value, value, player_flesh_counter])
				else:
					player_flesh_counter -= absi(value)
					add_log("  └【贄%d】骨カウンターを %d 消費した！(現在: %d)" % [value, absi(value), player_flesh_counter])
			else:
				if value > 0:
					cpu_flesh_counter += value
					add_log("  └【贄%d】相手が骨カウンターを %d 付与した！(現在: %d)" % [value, value, cpu_flesh_counter])
				else:
					cpu_flesh_counter -= absi(value)
					add_log("  └【贄%d】相手が骨カウンターを %d 消費した！(現在: %d)" % [value, absi(value), cpu_flesh_counter])

		"self_discard_select":
			add_log("  └【流炎%d】手札からカードを %d 枚選択して捨てた！" % [value, value] if is_p else "  └【流炎%d】相手が手札を %d 枚選択して捨てた！" % [value, value])
			if is_p:
				if sync_data is Dictionary and sync_data.get("discardTargetIds") is Array and not sync_data["discardTargetIds"].is_empty():
					for id in sync_data["discardTargetIds"]:
						var idx := _index_by_id(player_hand, id)
						if idx != -1:
							player_hand.remove_at(idx)
				else:
					for i in value:
						if not player_hand.is_empty():
							player_hand.remove_at(randi() % player_hand.size())
			else:
				for i in value:
					if is_cpu_mode():
						if not cpu_hand.is_empty():
							cpu_hand.remove_at(randi() % cpu_hand.size())
					else:
						cpu_hand_length = maxi(0, cpu_hand_length - 1)

		"zenjikouon":
			add_log("  └【漸次昂音%d】手札の漸次昂音カードを強化！" % value if is_p else "  └【漸次昂音%d】相手が手札の漸次昂音カードを強化！" % value)
			if is_p:
				boost_zenji_cards(player_hand, value)
			elif is_cpu_mode():
				boost_zenji_cards(cpu_hand, value)

		"burn":
			apply_damage(not is_p, value)
			add_log("  └【雄叫び%d】相手プレイヤーに %d ダメージ！" % [value, value] if is_p else "  └【雄叫び%d】あなたに %d ダメージ！" % [value, value])

		"manahueru":
			if is_p:
				player_current_mana = mini(player_max_mana, player_current_mana + value)
				add_log("  └【還元%d】マナが %d 回復！" % [value, value])
				if reduce_tomoshibi(true):
					add_log("  └✨ 還元発動により、手札の【灯火】が減少した！")
			else:
				cpu_current_mana = mini(cpu_max_mana, cpu_current_mana + value)
				add_log("  └【還元%d】相手のマナが %d 回復！" % [value, value])
				if is_cpu_mode() and reduce_tomoshibi(false):
					add_log("  └✨ 還元発動により、相手の手札の【灯火】が減少した！")

		"saidaimanahueru":
			if is_p:
				player_max_mana = mini(total_max_mana_limit, player_max_mana + value)
				add_log("  └【恵沢%d】最大マナが %d 増加！" % [value, value])
			else:
				cpu_max_mana = mini(total_max_mana_limit, cpu_max_mana + value)
				add_log("  └【恵沢%d】相手の最大マナが %d 増加！" % [value, value])

		"jishoburn":
			apply_damage(is_p, value)
			add_log("  └【反動%d】反動で自分に %d ダメージ！" % [value, value] if is_p else "  └【反動%d】反動で相手に %d ダメージ！" % [value, value])

		"heal":
			if is_p:
				player_hp = mini(30, player_hp + value)
				add_log("  └【神秘%d】HPが %d 回復した！" % [value, value])
			else:
				cpu_hp = mini(30, cpu_hp + value)
				add_log("  └【神秘%d】相手のHPが %d 回復した！" % [value, value])

		"karyokuhueru":
			var dmg := current_count * value
			apply_damage(not is_p, dmg)
			if is_p:
				add_log("  └【連撃%d】このターンに使用した枚数(%d枚×%d＝%d)相手に追加ダメージ！" % [value, current_count, value, dmg])
			else:
				add_log("  └【連撃%d】このターンに相手が使用した枚数(%d枚×%d=%d)あなたに追加ダメージ！" % [value, current_count, value, dmg])

		"kenko":
			add_log("  └【剣呼%d】手札にランダムなカードを %d 枚生成した！" % [value, value] if is_p else "  └【剣呼%d】相手の手札にランダムなカードが %d 枚生成された！" % [value, value])
			if is_cpu_mode() or not is_p:
				for i in value:
					if is_p:
						if player_hand.size() < max_hand_size:
							player_hand.append(create_card_instance(card_pool[randi() % 30]))
						else:
							add_log("🔥 手札満杯のため生成カードが燃破した！")
					elif is_cpu_mode():
						if cpu_hand.size() < max_hand_size:
							cpu_hand.append(create_card_instance(card_pool[randi() % 30]))
					else:
						if cpu_hand_length < max_hand_size:
							cpu_hand_length += 1
						else:
							add_log("🔥 相手の手札が上限(10枚)を超えているため、カードが1枚燃破した！")
			elif sync_data is Dictionary and sync_data.get("chosenCardIndices") is Array:
				for idx in sync_data["chosenCardIndices"]:
					if player_hand.size() < max_hand_size:
						player_hand.append(create_card_instance(card_pool[int(idx)]))
					else:
						add_log("🔥 手札満杯のため生成カードが燃破した！")

		"discard":
			add_log("  └【罪%d】相手の手札をランダムに %d 枚捨てさせた！" % [value, value] if is_p else "  └【罪%d】自分の手札がランダムに %d 枚捨てられた！" % [value, value])
			for i in value:
				if is_p:
					if is_cpu_mode() and not cpu_hand.is_empty():
						cpu_hand.remove_at(randi() % cpu_hand.size())
					elif not is_cpu_mode():
						cpu_hand_length = maxi(0, cpu_hand_length - 1)
				elif not player_hand.is_empty():
					player_hand.remove_at(randi() % player_hand.size())

		"manadestroy":
			if is_p:
				cpu_max_mana = maxi(1, cpu_max_mana - value)
				add_log("  └【崩壊%d】相手の最大マナを %d 破壊した！" % [value, value])
			else:
				player_max_mana = maxi(1, player_max_mana - value)
				add_log("  └【崩壊%d】自分の最大マナが %d 破壊された！" % [value, value])

		"costup":
			add_log("  └【威圧%d】相手の手札のカード全てのコストを +%d した！" % [value, value] if is_p else "  └【威圧%d】自分の手札のカード全てのコストが +%d された！" % [value, value])
			if not is_p:
				for c in player_hand:
					c["cost"] += value
			elif is_cpu_mode():
				for c in cpu_hand:
					c["cost"] += value

		"deckdestroy":
			add_log("  └【罰%d】相手のデッキを %d 枚破壊した！" % [value, value] if is_p else "  └【罰%d】自分のデッキが %d 枚破壊された！" % [value, value])
			for i in value:
				if is_p:
					if is_cpu_mode():
						if not cpu_deck.is_empty():
							cpu_deck.pop_front()
					else:
						cpu_deck_length = maxi(0, cpu_deck_length - 1)
				elif not player_deck.is_empty():
					player_deck.pop_front()

		"revengeburn":
			var my_hp := player_hp if is_p else cpu_hp
			var enemy_hp := cpu_hp if is_p else player_hp
			if my_hp < enemy_hp:
				apply_damage(not is_p, value)
				add_log("  └【逆境%d】逆境のため相手に追加で %d ダメージ！" % [value, value] if is_p else "  └【逆境%d】優勢だったため追加で %d ダメージを受けた！" % [value, value])

		"costdown_all":
			if is_p or is_cpu_mode():
				for c in (player_hand if is_p else cpu_hand):
					c["cost"] = maxi(0, c["cost"] - value)
			add_log("  └【奇跡%d】自分の手札の全てのカードのコストが -%d された！" % [value, value] if is_p else "  └【奇跡%d】相手の手札の全てのカードのコストが -%d された！" % [value, value])

		"barrier":
			if is_p:
				player_barrier += value
				add_log("  └【聖域%d】自分に %d 回のダメージ無効バリアを展開した！" % [value, value])
			else:
				cpu_barrier += value
				add_log("  └【聖域%d】相手が %d 回のダメージ無効バリアを展開した！" % [value, value])

		"contract":
			add_log("  └【契約%d】相手にカードを %d 枚ドローさせる！" % [value, value] if is_p else "  └【契約%d】自分はカードを %d 枚ドローする！" % [value, value])
			for i in value:
				draw_card(not is_p)

		"madoutanzou":
			add_log("  └【魔導鍛造%d】特別な効果を持つナギソブレッドを %d 枚生成した！" % [value, value] if is_p else "  └【魔導鍛造%d】相手が特別な効果を持つナギソブレッドを %d 枚生成した！" % [value, value])
			for i in value:
				if is_p:
					if player_hand.size() < max_hand_size:
						player_hand.append(_make_bread(ab))
					else:
						add_log("🔥 手札満杯のため生成されたナギソブレッドが燃破した！")
				elif is_cpu_mode():
					if cpu_hand.size() < max_hand_size:
						cpu_hand.append(_make_bread(ab))
				elif cpu_hand_length < max_hand_size:
					cpu_hand_length += 1

		"sennjin":
			var hand: Array = player_hand if is_p else (cpu_hand if is_cpu_mode() else [])
			for c in hand:
				c["power"] += value
			add_log("  └【千刃%d】手札の全カードの攻撃力が %d 上がった！" % [value, value] if is_p else "  └【千刃%d】相手の手札の全カードの攻撃力が %d 上がった！" % [value, value])

		"onmyo_in", "onmyo_yo":
			var is_yin := type == "onmyo_in"
			var target_type := "onmyo_yo" if is_yin else "onmyo_in"
			var type_name := "陰陽・陰" if is_yin else "陰陽・陽"
			var target_name := "陰陽・陽" if is_yin else "陰陽・陰"
			add_log("  └【%s%d】%sのカードを生成！" % [type_name, value, target_name] if is_p else "  └【%s%d】相手が%sのカードを生成！" % [type_name, value, target_name])
			var target_index := -1
			if is_cpu_mode():
				var valid := _pool_indices_with(target_type)
				if not valid.is_empty():
					target_index = valid.pick_random()
			elif sync_data is Dictionary and sync_data.get("chosenOnmyoIndices") is Array and not sync_data["chosenOnmyoIndices"].is_empty():
				target_index = int(sync_data["chosenOnmyoIndices"].pop_front())
			if target_index != -1:
				var nc := create_card_instance(card_pool[target_index])
				if is_yin:
					for a in nc["abilities"]:
						if a.has("value"):
							a["value"] += value
					if nc["abilityText"] != "":
						var re := RegEx.create_from_string("\\d+")
						var txt: String = nc["abilityText"]
						var out := ""
						var last := 0
						for m in re.search_all(txt):
							out += txt.substr(last, m.get_start() - last) + str(int(m.get_string()) + value)
							last = m.get_end()
						nc["abilityText"] = out + txt.substr(last)
				else:
					nc["power"] += value
				if is_p:
					if player_hand.size() < max_hand_size:
						player_hand.append(nc)
					else:
						add_log("🔥 手札満杯のため生成カードが燃破した！")
				elif not is_cpu_mode():
					if cpu_hand_length < max_hand_size:
						cpu_hand_length += 1
					else:
						add_log("🔥 相手の手札が上限(10枚)を超えているため、カードが1枚燃破した！")
				elif cpu_hand.size() < max_hand_size:
					cpu_hand.append(nc)
			else:
				add_log("⚠️ 生成可能な%sのカードがプールに存在しませんでした。" % target_name)

		"fuwa":
			if is_p or is_cpu_mode():
				var deck: Array = player_deck if is_p else cpu_deck
				var discarded := 0
				var i := deck.size() - 1
				while i >= 0 and discarded < value:
					if has_ability(deck[i], "fuwa"):
						deck.remove_at(i)
						discarded += 1
					i -= 1
				if is_p:
					add_log("  └【不和%d】デッキから不和を持つカードを %d 枚捨てた！" % [value, discarded])
				else:
					add_log("  └【不和%d】相手がデッキから不和を持つカードを %d 枚捨てた！" % [value, discarded])
			else:
				cpu_deck_length = maxi(0, cpu_deck_length - mini(cpu_deck_length, value))
				add_log("  └【不和%d】相手がデッキから不和を持つカードを捨てた！" % value)


func end_player_turn() -> void:
	if not is_game_started or is_game_over or is_selecting_token or not is_player_turn:
		return
	is_player_turn = false
	is_first_turn = false
	player_played_count_this_turn = 0
	is_selecting_discard = false
	pending_card_to_play = null
	pending_discard_ids = []
	if is_cpu_mode():
		add_log("=== CPUのターン ===")
		cpu_max_mana = mini(total_max_mana_limit, cpu_max_mana + 1)
		cpu_current_mana = cpu_max_mana
		draw_card(false)
		_after(1.2, cpu_action)
	else:
		add_log("=== 相手のターン ===")
		cpu_max_mana = mini(total_max_mana_limit, cpu_max_mana + 1)
		cpu_current_mana = cpu_max_mana
		draw_card(false)
		sync_state_to_server("ターン終了")
		socket.emit_event("end_turn", {"roomName": room_name})
	mark_dirty()


func cpu_action() -> void:
	if is_game_over:
		return
	for c in cpu_hand:
		if get_card_cost(c, false) <= cpu_current_mana and has_enough_flesh(c, false):
			play_card(c, false)
			_after(1.4, cpu_action)
			return
	end_cpu_turn()


func end_cpu_turn() -> void:
	if not is_game_started or is_game_over:
		return
	is_player_turn = true
	if reduce_tomoshibi(true):
		add_log("✨ ターン開始により、手札の【灯火】が減少した！")
	if is_cpu_mode() and reduce_tomoshibi(false):
		add_log("✨ ターン開始により、相手の手札の【灯火】が減少した！")
	cpu_played_count_this_turn = 0
	add_log("=== あなたのターン ===")
	player_max_mana = mini(total_max_mana_limit, player_max_mana + 1)
	player_current_mana = player_max_mana
	if is_first_turn:
		add_log("※先攻1ターン目のためドローはありません。")
		is_first_turn = false
	else:
		draw_card(true)
	mark_dirty()


func check_win_lose() -> void:
	if is_game_over:
		if cpu_hp <= 0 and player_hp > 0 and not log_messages.has("🎉 勝利しました！"):
			add_log("🎉 勝利しました！")
		return
	if cpu_hp <= 0 and player_hp > 0:
		add_log("🎉 勝利しました！")
		is_game_over = true
	elif player_hp <= 0 and cpu_hp > 0:
		add_log("💀 敗北しました。")
		is_game_over = true
	elif player_hp <= 0 and cpu_hp <= 0:
		add_log("🤝 同時撃破により引き分けです。")
		is_game_over = true
	mark_dirty()


func sync_state_to_server(latest_log: String = "") -> void:
	if is_cpu_mode() or is_spectator:
		return
	socket.emit_event("update_room_state", {
		"hp": player_hp, "maxMana": player_max_mana, "currentMana": player_current_mana,
		"handLength": player_hand.size(), "deckLength": player_deck.size(),
		"name": user_name, "latestLog": latest_log, "isP1Turn": is_player_turn,
		"barrier": player_barrier, "fleshCounter": player_flesh_counter,
	})


# =========================================================
# サーバーイベント
# =========================================================
func _on_socket_event(event_name: String, raw: Variant) -> void:
	var data: Variant = normalize(raw)
	match event_name:
		"game_start":
			if is_spectator:
				return
			_session += 1
			is_matching = false
			is_spectator = false
			add_log("🤝 オンライン対戦相手が見つかりました！")
			is_player_turn = bool(data.get("isFirst", false))
			is_first_turn = is_player_turn
			setup_game_field(selected_deck_type)
			is_game_started = true
			sync_state_to_server("ゲーム開始！")

		"opponent_play_card":
			if not data is Dictionary or not data.get("card") is Dictionary:
				return
			if is_spectator:
				# 観戦者は盤面を spectator_update で受け取るので、演出とログだけ出す
				var who := p1_name if data.get("isPlayer1", false) else p2_name
				notice.emit(who, data["card"])
				_push_log_only("👤 %sが【%s】を召喚！" % [who, data["card"].get("name", "?")])
				return
			var card: Dictionary = data["card"]
			if not card.get("abilities") is Array:
				card["abilities"] = []
			play_card(card, false, data.get("syncData"))
			if data.has("currentMana"):
				cpu_current_mana = int(data["currentMana"])
			if data.has("maxMana"):
				cpu_max_mana = int(data["maxMana"])
			mark_dirty()

		"opponent_end_turn":
			if is_spectator:
				return
			end_cpu_turn()

		"room_state_updated":
			if is_cpu_mode() or is_spectator or not data is Dictionary:
				return
			cpu_hp = data.get("hp", cpu_hp)
			cpu_max_mana = data.get("maxMana", cpu_max_mana)
			cpu_current_mana = data.get("currentMana", cpu_current_mana)
			cpu_hand_length = data.get("handLength", cpu_hand_length)
			cpu_deck_length = data.get("deckLength", cpu_deck_length)
			cpu_barrier = data.get("barrier", 0)
			cpu_flesh_counter = data.get("fleshCounter", cpu_flesh_counter)
			_append_remote_log(data.get("latestLog", ""))

		"spectator_game_start":
			if not is_spectator or not data is Dictionary:
				return
			is_matching = false
			is_game_started = true
			p1_name = str(data.get("player1", p1_name))
			p2_name = str(data.get("player2", p2_name))
			_push_log_only("👁️ 観戦を開始しました: %s vs %s" % [p1_name, p2_name])

		"spectator_update":
			if not is_spectator or not data is Dictionary:
				return
			is_matching = false
			is_game_started = true
			var p1: Dictionary = data.get("p1", {})
			var p2: Dictionary = data.get("p2", {})
			player_hp = p1.get("hp", 30); cpu_hp = p2.get("hp", 30)
			player_barrier = p1.get("barrier", 0); cpu_barrier = p2.get("barrier", 0)
			player_current_mana = p1.get("currentMana", 1); player_max_mana = p1.get("maxMana", 1)
			cpu_current_mana = p2.get("currentMana", 1); cpu_max_mana = p2.get("maxMana", 1)
			player_hand_length = p1.get("handLength", 0); player_deck_length = p1.get("deckLength", 30)
			cpu_hand_length = p2.get("handLength", 0); cpu_deck_length = p2.get("deckLength", 30)
			p1_flesh_counter = p1.get("fleshCounter", 0); p2_flesh_counter = p2.get("fleshCounter", 0)
			p1_name = str(p1.get("name", p1_name)); p2_name = str(p2.get("name", p2_name))
			is_player_turn = bool(data.get("isP1Turn", true))
			_append_remote_log(data.get("latestLog", ""))

		"opponent_disconnected":
			if is_game_over:
				return
			if is_spectator:
				add_log("⚠️ 選手の接続が切れました。ルームは解散されました。")
				is_game_over = true
			elif is_game_started:
				add_log("⚠️ 対戦相手の接続が切れました。あなたの勝利です！")
				cpu_hp = 0
				is_game_over = true
				check_win_lose()
	mark_dirty()


func _append_remote_log(msg: Variant) -> void:
	if msg is String and msg != "" and (log_messages.is_empty() or log_messages[-1] != msg):
		log_messages.append(msg)
