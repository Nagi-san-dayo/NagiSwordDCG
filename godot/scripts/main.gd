## 画面 (タイトル / デッキ編集 / 対戦) とオーバーレイをコードで組み立てる。
## 状態は NagisoGame が持ち、changed シグナルで再描画する。
extends Control

const C_BG := Color("#1e1e24")
const C_APP := Color("#2c2c35")
const C_PANEL := Color("#3e3e4a")
const C_PANEL_HOVER := Color("#4a4a5a")
const C_BORDER := Color("#555555")
const C_TEXT := Color("#f5f5f5")
const C_SUB := Color("#aaaaaa")
const C_GOLD := Color("#ffd700")
const C_YELLOW := Color("#ffc107")
const C_BLUE := Color("#007bff")
const C_RED := Color("#dc3545")
const C_GREEN := Color("#28a745")
const C_PURPLE := Color("#6f42c1")
const C_GRAY := Color("#6c757d")
const C_CYAN := Color("#17a2b8")

## 絵文字は Web 版の同梱フォントに無いので、記号に置き換える
const EMOJI_MAP := {
	"🎉": "★", "💀": "×", "🤝": "◇", "🛡️": "◆", "🛡": "◆", "🗡️": "†", "🗡": "†",
	"🔥": "▲", "✨": "☆", "⚙️": "◎", "⚙": "◎", "👤": "●", "🤖": "■", "⚠️": "※", "⚠": "※",
	"❌": "×", "🔄": "→", "🌐": "◎", "👁️": "◉", "👁": "◉", "🧬": "", "🦴": "",
}

## 縦長の画面（スマホ縦持ち）では本家の @media (max-width: 768px) と同じく 1 カラムに並べる
const LANDSCAPE_SIZE := Vector2i(1280, 720)
const PORTRAIT_SIZE := Vector2i(540, 960)

var game: NagisoGame
var portrait := false
var _ui_built := false
var font: FontFile
var font_bold: FontVariation
var _textures := {}

# 画面
var title_screen: Control
var edit_screen: Control
var game_screen: Control
var overlay_layer: Control

# タイトル
var name_edit: LineEdit
var mode_buttons := {}
var room_box: Control
var room_edit: LineEdit
var spectate_btn: Button
var mode_label: Label
var deck_section: Control
var slot_buttons: Array[Button] = []

# デッキ編集
var editing_deck: Array = []   # プール番号の配列
var current_deck_slot := 0
var deck_name_edit: LineEdit
var search_edit: LineEdit
var pool_grid: GridContainer
var pool_cards := {}           # プール番号 -> {panel, count_label}
var edit_title: Label
var edit_count_label: Label
var save_btn: Button
var stacked_list: VBoxContainer

# 対戦
var spectator_banner: Control
var enemy_title: Label
var enemy_sub: RichTextLabel
var enemy_res: Label
var player_title: Label
var player_sub: RichTextLabel
var player_res: Label
var discard_banner: Control
var hand_box: HBoxContainer
var log_label: RichTextLabel
var _log_count := 0
var back_btn: Button
var end_btn: Button

# オーバーレイ
var dictionary_overlay: Control
var matching_overlay: Control
var matching_title: Label
var matching_room: Label
var token_overlay: Control
var token_desc: Label
var notice_root: Control
var toast: PanelContainer
var toast_label: Label
var _toast_tween: Tween


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	font = load("res://fonts/NotoSansJP-Regular.otf")
	font_bold = FontVariation.new()
	font_bold.base_font = font
	font_bold.variation_embolden = 0.8
	theme = _build_theme()

	var bg := ColorRect.new()
	bg.color = C_APP
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	game = NagisoGame.new()
	add_child(game)
	game.changed.connect(_refresh)
	game.notice.connect(_show_card_notice)
	game.alert.connect(_show_toast)

	get_tree().root.size_changed.connect(_apply_orientation)
	_apply_orientation()


## ウィンドウの縦横が変わったら基準解像度を切り替えて UI を作り直す
func _apply_orientation() -> void:
	var win := get_tree().root.size
	var p := win.y > win.x
	if _ui_built and p == portrait:
		return
	portrait = p
	get_tree().root.content_scale_size = PORTRAIT_SIZE if p else LANDSCAPE_SIZE
	_build_ui()


func _build_ui() -> void:
	# デッキ編集中なら入力中の内容を引き継ぐ
	var was_editing := _ui_built and edit_screen.visible
	var deck_name_text := deck_name_edit.text if was_editing else ""
	var search_text := search_edit.text if was_editing else ""
	for n in [title_screen, edit_screen, game_screen, overlay_layer]:
		if n:
			n.queue_free()
	mode_buttons = {}
	slot_buttons = []
	pool_cards = {}
	_log_count = 0

	title_screen = _build_title()
	edit_screen = _build_editor()
	game_screen = _build_game()
	for sc in [title_screen, edit_screen, game_screen]:
		add_child(sc)
	edit_screen.visible = false

	overlay_layer = Control.new()
	overlay_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay_layer)
	_build_overlays()

	name_edit.text = game.user_name
	room_edit.text = game.room_name
	_ui_built = true
	if was_editing:
		_show_editor()
		deck_name_edit.text = deck_name_text
		search_edit.text = search_text
		_refresh_editor()
	game.mark_dirty()


# =========================================================
# 共通ヘルパー
# =========================================================
func _t(s: String) -> String:
	for k in EMOJI_MAP:
		s = s.replace(k, EMOJI_MAP[k])
	var out := ""
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0x1F000 or c == 0xFE0F or c == 0x200D:
			continue
		if c >= 0x2600 and c <= 0x27BF and not "★☆♪♦♠♣♥✓".contains(s[i]):
			continue
		out += s[i]
	return out


func _build_theme() -> Theme:
	var th := Theme.new()
	th.default_font = font
	th.default_font_size = 16
	th.set_color("font_color", "Label", C_TEXT)
	th.set_stylebox("normal", "LineEdit", _sb(Color("#151518"), C_BORDER, 5, 1, 8))
	th.set_stylebox("focus", "LineEdit", _sb(Color(0, 0, 0, 0), C_YELLOW, 5, 1, 8))
	th.set_color("font_placeholder_color", "LineEdit", Color("#777777"))
	var grab := _sb(Color("#555555"), Color("#555555"), 4, 0, 0)
	th.set_stylebox("grabber", "VScrollBar", grab)
	th.set_stylebox("grabber_highlight", "VScrollBar", grab)
	th.set_stylebox("grabber_pressed", "VScrollBar", grab)
	th.set_stylebox("scroll", "VScrollBar", _sb(Color(0, 0, 0, 0.15), Color(0, 0, 0, 0), 4, 0, 0))
	th.set_stylebox("grabber", "HScrollBar", grab)
	th.set_stylebox("grabber_highlight", "HScrollBar", grab)
	th.set_stylebox("grabber_pressed", "HScrollBar", grab)
	th.set_stylebox("scroll", "HScrollBar", _sb(Color(0, 0, 0, 0.15), Color(0, 0, 0, 0), 4, 0, 0))
	return th


func _sb(bg: Color, border: Color, radius := 8, border_w := 1, pad := 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(pad)
	return s


func _label(text: String, size := 16, color := C_TEXT, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_font_override("font", font_bold)
	return l


func _button(text: String, cb: Callable, bg := C_PANEL, fg := Color.WHITE, size := 16, border := C_BORDER) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", font_bold)
	b.add_theme_font_size_override("font_size", size)
	_style_button(b, bg, fg, border)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_PASS  # スマホでボタンの上からもスクロールできるように
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(cb)
	return b


func _style_button(b: Button, bg: Color, fg := Color.WHITE, border := C_BORDER, pad := 10) -> void:
	b.add_theme_stylebox_override("normal", _sb(bg, border, 8, 2, pad))
	b.add_theme_stylebox_override("hover", _sb(bg.lightened(0.12), C_YELLOW if border == C_BORDER else border.lightened(0.2), 8, 2, pad))
	b.add_theme_stylebox_override("pressed", _sb(bg.darkened(0.15), border, 8, 2, pad))
	b.add_theme_stylebox_override("disabled", _sb(Color("#444444"), Color("#666666"), 8, 2, pad))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(k, fg)
	b.add_theme_color_override("font_disabled_color", C_SUB)


func _panel(bg: Color, border: Color, pad := 10, radius := 8) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _sb(bg, border, radius, 1, pad))
	return p


func _vbox(sep := 8) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


func _hbox(sep := 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


## 縦横を切り替えられる Box（HBox/VBoxContainer は向きを変更できない）
func _box(vertical: bool, sep := 8) -> BoxContainer:
	var b := BoxContainer.new()
	b.vertical = vertical
	b.add_theme_constant_override("separation", sep)
	return b


func _margin(child: Control, m := 16) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		mc.add_theme_constant_override("margin_" + side, m)
	mc.add_child(child)
	return mc


func _texture(path: String) -> Texture2D:
	if not _textures.has(path):
		var res_path := "res://" + path
		_textures[path] = load(res_path) if ResourceLoader.exists(res_path) else load("res://images/mate.png")
	return _textures[path]


func _clear(node: Node) -> void:
	for c in node.get_children():
		c.queue_free()


## カード 1 枚の見た目。state: normal / playable / discard_target / discard_selected / dim
func _make_card(card: Dictionary, cost: int, w := 150.0, h := 240.0, state := "normal", bottom := "") -> PanelContainer:
	var border := C_BORDER
	var bg := C_PANEL
	var glow := Color(0, 0, 0, 0)
	match state:
		"playable":
			border = C_BLUE; glow = Color(0, 0.48, 1, 0.7)
		"discard_target":
			border = C_RED; glow = Color(0.86, 0.2, 0.27, 0.7)
		"discard_selected":
			border = C_YELLOW; glow = Color(1, 0.76, 0.03, 0.8); bg = Color("#4a3e2b")
	var sb := _sb(bg, border, 12, 2, 8)
	sb.shadow_color = glow if glow.a > 0 else Color(0, 0, 0, 0.4)
	sb.shadow_size = 10 if glow.a > 0 else 5
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(w, h)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.clip_contents = true
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if state == "dim":
		p.modulate = Color(1, 1, 1, 0.5)

	var v := _vbox(3)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	var img := TextureRect.new()
	img.texture = _texture(str(card.get("image", "images/mate.png")))
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.custom_minimum_size = Vector2(0, h * 0.3)
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(img)

	var name_l := _label(str(card.get("name", "")), 14, Color.WHITE, true)
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.clip_text = true
	v.add_child(name_l)
	var sep := ColorRect.new()
	sep.color = Color(1, 1, 1, 0.2)
	sep.custom_minimum_size = Vector2(0, 2)
	v.add_child(sep)
	var stat := _label("コ:%d / 攻:%d" % [cost, int(card.get("power", 0))], 13)
	stat.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(stat)
	var txt := str(card.get("abilityText", ""))
	if txt != "":
		var ab := _label(_format_ability(txt), 12, C_GOLD, true)
		ab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ab.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		v.add_child(ab)
	if bottom != "":
		var spacer := Control.new()
		spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		v.add_child(spacer)
		var bl := _label(bottom, 12, Color.WHITE, true)
		bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(bl)
	for c in v.get_children():
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _format_ability(text: String) -> String:
	var re := RegEx.create_from_string("[\\s　]+")
	return re.sub(text.strip_edges(), "\n", true)


func _on_click(ctrl: Control, cb: Callable) -> void:
	ctrl.mouse_filter = Control.MOUSE_FILTER_PASS
	var press_pos := [null]
	ctrl.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			if ev.pressed:
				press_pos[0] = ev.global_position
			elif press_pos[0] != null:
				var moved: float = (ev.global_position - press_pos[0]).length()
				press_pos[0] = null
				if moved < 12.0:
					cb.call()
	)


# =========================================================
# タイトル画面
# =========================================================
func _build_title() -> Control:
	var root := _hbox(24)
	var left := _vbox(10)
	left.custom_minimum_size = Vector2(0 if portrait else 540, 0)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL if portrait else Control.SIZE_FILL
	root.add_child(left)

	var title := _label("† ナギソDCG †", 44, C_TEXT, true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(title)
	var sub := _label("30枚のデッキを構築して戦うデジタルカードゲーム", 15, Color.GRAY)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(sub)

	var prof := _panel(Color("#232730"), Color("#444444"))
	var pv := _vbox(4)
	prof.add_child(pv)
	pv.add_child(_label("● ユーザーネーム", 13, Color("#a9b0b7"), true))
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "一般ナギソ"
	name_edit.max_length = 20
	name_edit.text_changed.connect(func(t: String):
		game.user_name = t if t.strip_edges() != "" else "一般ナギソ"
		game.save_data()
	)
	pv.add_child(name_edit)
	left.add_child(prof)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	left.add_child(grid)
	for m in [["cpu", "■ CPU対戦"], ["online_random", "◎ ランダムマッチ"]]:
		var b := _button(m[1], _set_mode.bind(m[0]))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 50)
		grid.add_child(b)
		mode_buttons[m[0]] = b
	for m in [["online_room", "◇ ルームマッチ (合言葉)"], ["spectate", "◉ ルームを観戦する"]]:
		var b := _button(m[1], _set_mode.bind(m[0]))
		b.custom_minimum_size = Vector2(0, 50)
		left.add_child(b)
		mode_buttons[m[0]] = b

	room_box = _vbox(6)
	room_edit = LineEdit.new()
	room_edit.placeholder_text = "ルーム名（例: nagiso123）"
	room_edit.text_changed.connect(func(t: String): game.room_name = t)
	room_box.add_child(room_edit)
	spectate_btn = _button("◉ 観戦画面へ入る", game.start_spectating, C_YELLOW, Color.BLACK, 16, C_YELLOW)
	spectate_btn.custom_minimum_size = Vector2(0, 48)
	room_box.add_child(spectate_btn)
	left.add_child(room_box)

	mode_label = _label("", 13, C_SUB)
	mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(mode_label)

	# デッキ選択: 横画面は右カラム、縦画面は本家と同じく下に続けてページ全体をスクロール
	deck_section = _vbox(8)
	deck_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if portrait:
		var hr := ColorRect.new()
		hr.color = Color("#444444")
		hr.custom_minimum_size = Vector2(0, 1)
		deck_section.add_child(hr)
		left.add_child(deck_section)
	else:
		var scroll := ScrollContainer.new()
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		root.add_child(scroll)
		scroll.add_child(deck_section)

	deck_section.add_child(_label("☆ カスタムデッキ (最大10種類)", 17, C_YELLOW, true))
	var slots := _panel(Color("#3a3528"), C_YELLOW, 8, 10)
	var sv := _vbox(5)
	slots.add_child(sv)
	for i in 10:
		var row := _hbox(6)
		var sel := _button("", game.handle_deck_select.bind("custom", i), Color("#2c2519"), Color.WHITE, 14, C_YELLOW)
		sel.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_style_button(sel, Color("#2c2519"), Color.WHITE, C_YELLOW, 5)
		sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(sel)
		slot_buttons.append(sel)
		var ed := _button("編集", _open_editor.bind(i), C_GRAY, Color.WHITE, 14, C_GRAY)
		_style_button(ed, C_GRAY, Color.WHITE, C_GRAY, 5)
		row.add_child(ed)
		sv.add_child(row)
	deck_section.add_child(slots)

	for d in [["agro", "● ナギソアグロ（速攻）", "低コストのカードで序盤から一気に敵のHPを削りきる攻撃的デッキ！", Color("#ff6b6b")],
			["ramp", "● ナギソランプ（マナ加速）", "マナを高速で増やし、最強の「魔剣ナギソ」で勝利するデッキ！", Color("#51cf66")],
			["combo", "● ナギソコンボ（連撃）", "手札を回しつつ、連撃でワンターンキルを狙うデッキ！", Color("#4dabf7")]]:
		var b := _button("", game.handle_deck_select.bind(d[0]))
		b.custom_minimum_size = Vector2(0, 62)
		var bv := _vbox(2)
		bv.set_anchors_preset(Control.PRESET_FULL_RECT)
		bv.alignment = BoxContainer.ALIGNMENT_CENTER
		bv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var h := _label(d[1], 17, d[3], true)
		var p := _label(d[2], 12 if portrait else 13, Color("#cccccc"))
		for l in [h, p]:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			bv.add_child(l)
		b.add_child(bv)
		deck_section.add_child(b)

	if portrait:
		var page := ScrollContainer.new()
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		var m := _margin(root, 16)
		m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.add_child(m)
		return page
	return _margin(root, 24)


func _set_mode(mode: String) -> void:
	game.game_mode = mode
	game.mark_dirty()


func _refresh_title() -> void:
	for m in mode_buttons:
		var active: bool = game.game_mode == m
		var b: Button = mode_buttons[m]
		_style_button(b, Color(0.157, 0.655, 0.271, 0.25) if active else C_PANEL, Color.WHITE, C_GREEN if active else C_BORDER)
	room_box.visible = game.game_mode in ["online_room", "spectate"]
	spectate_btn.visible = game.game_mode == "spectate"
	mode_label.text = "現在のモード: " + game.mode_description()
	deck_section.visible = game.game_mode != "spectate"
	for i in 10:
		var has: bool = game.custom_decks[i] != null
		slot_buttons[i].text = "%s %s" % [game.get_deck_name(i), "(30枚)" if has else "(未作成)"]
		slot_buttons[i].disabled = not has


# =========================================================
# デッキ編集画面
# =========================================================
func _build_editor() -> Control:
	var root := _box(portrait, 16)
	var left := _vbox(8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.7 if portrait else 2.0
	root.add_child(left)

	edit_title = _label("", 20 if portrait else 24, C_TEXT, true)
	left.add_child(edit_title)
	var nr := _hbox(8)
	nr.add_child(_label("デッキ名:", 14, C_TEXT, true))
	deck_name_edit = LineEdit.new()
	deck_name_edit.placeholder_text = "デッキ名を入力してください"
	deck_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nr.add_child(deck_name_edit)
	left.add_child(nr)
	left.add_child(_label("カードプール (クリックで追加)", 17, C_TEXT, true))
	search_edit = LineEdit.new()
	search_edit.placeholder_text = "カード名や能力（例: 流水, 反動）で検索..."
	search_edit.text_changed.connect(func(_t): _refresh_editor())
	left.add_child(search_edit)

	var pool_panel := _panel(Color(0, 0, 0, 0.2), Color("#444444"), 10)
	pool_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pool_panel.add_child(scroll)
	pool_grid = GridContainer.new()
	pool_grid.columns = 3 if portrait else 5
	pool_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER | Control.SIZE_EXPAND
	pool_grid.add_theme_constant_override("h_separation", 12)
	pool_grid.add_theme_constant_override("v_separation", 12)
	scroll.add_child(pool_grid)
	left.add_child(pool_panel)

	var right := _vbox(8 if portrait else 10)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(right)
	edit_count_label = _label("", 16 if portrait else 17, C_TEXT, true)
	edit_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(edit_count_label)
	# 縦画面ではボタンを横に並べて編成リストの高さを確保する
	var btns := _box(not portrait, 8)
	right.add_child(btns)
	save_btn = _button("", _save_editor, C_GREEN, Color.WHITE, 14 if portrait else 16, C_GREEN)
	save_btn.custom_minimum_size = Vector2(0, 44 if portrait else 50)
	var cancel := _button("× 破棄して戻る" if portrait else "× 変更を破棄して戻る", _close_editor, C_GRAY, Color.WHITE, 14 if portrait else 16, C_GRAY)
	cancel.custom_minimum_size = Vector2(0, 44)
	var dict_btn := _button("能力一覧" if portrait else "能力一覧を開く", _show_dictionary, C_PANEL, Color.WHITE, 14)
	for b in [save_btn, cancel, dict_btn]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btns.add_child(b)
	if portrait:
		save_btn.size_flags_stretch_ratio = 1.6
	right.add_child(_label("現在の編成 (クリックで1枚減らす)", 15 if portrait else 17, C_TEXT, true))
	var ls := ScrollContainer.new()
	ls.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ls.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	stacked_list = _vbox(6)
	stacked_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ls.add_child(stacked_list)
	right.add_child(ls)

	return _margin(root, 16)


func _populate_pool() -> void:
	if not pool_cards.is_empty():
		return
	for i in game.card_pool.size():
		var card: Dictionary = game.card_pool[i]
		if card["name"] in NagisoGame.TOKEN_NAMES:
			continue
		var holder := Control.new()
		holder.custom_minimum_size = _pool_card_size()
		pool_grid.add_child(holder)
		pool_cards[i] = holder


func _pool_card_size() -> Vector2:
	return Vector2(150, 245) if portrait else Vector2(150, 250)


func _open_editor(slot: int) -> void:
	current_deck_slot = slot
	var saved: Variant = game.custom_decks[slot]
	editing_deck = (saved as Array).duplicate() if saved != null else []
	_show_editor()
	deck_name_edit.text = game.get_deck_name(slot)
	search_edit.text = ""
	_refresh_editor()


func _show_editor() -> void:
	_populate_pool()
	edit_title.text = "デッキ編集 [スロット %d]" % (current_deck_slot + 1)
	title_screen.visible = false
	game_screen.visible = false
	edit_screen.visible = true


func _close_editor() -> void:
	edit_screen.visible = false
	game.mark_dirty()


func _save_editor() -> void:
	if editing_deck.size() != 30:
		return
	game.custom_decks[current_deck_slot] = editing_deck.duplicate()
	game.custom_deck_names[current_deck_slot] = deck_name_edit.text.strip_edges()
	game.save_data()
	_close_editor()


func _count_in_deck(pool_index: int) -> int:
	return editing_deck.count(pool_index)


func _add_to_deck(pool_index: int) -> void:
	if editing_deck.size() >= 30:
		_show_toast("× デッキは最大30枚です。")
		return
	if _count_in_deck(pool_index) >= 3:
		_show_toast("×「%s」は3枚までしか入れられません。" % game.card_pool[pool_index]["name"])
		return
	editing_deck.append(pool_index)
	_refresh_editor()


func _remove_from_deck(pool_index: int) -> void:
	var idx := editing_deck.rfind(pool_index)
	if idx != -1:
		editing_deck.remove_at(idx)
	_refresh_editor()


func _refresh_editor() -> void:
	var q := search_edit.text.strip_edges().to_lower()
	for i in pool_cards:
		var holder: Control = pool_cards[i]
		var card: Dictionary = game.card_pool[i]
		var match_q: bool = q == "" or str(card["name"]).to_lower().contains(q) or str(card.get("abilityText", "")).to_lower().contains(q)
		holder.visible = match_q
		if not match_q:
			continue
		_clear(holder)
		var cnt := _count_in_deck(i)
		var sz := _pool_card_size()
		var view := _make_card(card, card["cost"], sz.x, sz.y, "playable" if cnt < 3 else "dim", "枚数: %d / 3" % cnt)
		_on_click(view, _add_to_deck.bind(i))
		holder.add_child(view)

	edit_count_label.text = "現在の合計枚数: (%d / 30 枚)" % editing_deck.size()
	var ok := editing_deck.size() == 30
	save_btn.disabled = not ok
	save_btn.text = "デッキを保存してタイトルへ" if ok else "30枚に調整してください"

	_clear(stacked_list)
	if editing_deck.is_empty():
		var l := _label("カードが未選択です", 14, Color("#888888"))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stacked_list.add_child(l)
		return
	var uniq := []
	for i in editing_deck:
		if not uniq.has(i):
			uniq.append(i)
	uniq.sort_custom(func(a, b): return game.card_pool[a]["cost"] < game.card_pool[b]["cost"])
	for i in uniq:
		var card: Dictionary = game.card_pool[i]
		var row := _panel(C_PANEL, C_BORDER, 8, 6)
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var h := _hbox(10)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(h)
		var cost := _panel(C_BLUE, C_BLUE, 2, 12)
		cost.custom_minimum_size = Vector2(26, 26)
		var cl := _label(str(card["cost"]), 12, Color.WHITE, true)
		cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost.add_child(cl)
		h.add_child(cost)
		var nl := _label(card["name"], 15, Color.WHITE, true)
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nl.clip_text = true
		h.add_child(nl)
		h.add_child(_label("(攻:%d)" % card["power"], 12, C_SUB))
		var cnt := _panel(C_YELLOW, C_YELLOW, 4, 4)
		cnt.add_child(_label("%d 枚" % _count_in_deck(i), 13, Color.BLACK, true))
		h.add_child(cnt)
		for c in h.get_children():
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			for cc in c.get_children():
				cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_on_click(row, _remove_from_deck.bind(i))
		stacked_list.add_child(row)


# =========================================================
# 対戦画面
# =========================================================
func _build_game() -> Control:
	# 縦画面は本家と同じ順: ステータス → 手札 → ログ → ボタン
	var root := _box(portrait, 16)
	var left := _vbox(8 if portrait else 12)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 縦画面: 手札は固定の高さ（本家の 40vh 相当）にして、残りをログに回す
	left.size_flags_vertical = Control.SIZE_FILL if portrait else Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 2.0
	root.add_child(left)

	spectator_banner = _panel(C_CYAN, C_CYAN, 8)
	var sl := _label("◉ 現在リアルタイム観戦中モード (操作不可)", 14 if portrait else 16, Color.WHITE, true)
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spectator_banner.add_child(sl)
	left.add_child(spectator_banner)

	var e := _status_box()
	enemy_title = e[1]; enemy_sub = e[2]; enemy_res = e[3]
	enemy_res.add_theme_color_override("font_color", Color("#9d7bf0"))
	left.add_child(e[0])
	var p := _status_box()
	player_title = p[1]; player_sub = p[2]; player_res = p[3]
	player_res.add_theme_color_override("font_color", C_YELLOW)
	left.add_child(p[0])

	discard_banner = _panel(Color(0.86, 0.2, 0.27, 0.85), Color("#ff4d4d"), 8)
	var dh := _hbox(12)
	dh.alignment = BoxContainer.ALIGNMENT_CENTER
	dh.add_child(_label("※ 捨てる手札を選んでください" if portrait else "※ 捨てる手札を選んでクリックしてください", 15 if portrait else 16, Color.WHITE, true))
	dh.add_child(_button("× やめる", game.cancel_discard_select, Color("#333333"), Color.WHITE, 14, Color("#333333")))
	discard_banner.add_child(dh)
	left.add_child(discard_banner)
	var tw := discard_banner.create_tween().set_loops()
	tw.tween_property(discard_banner, "modulate:a", 0.75, 0.6)
	tw.tween_property(discard_banner, "modulate:a", 1.0, 0.6)

	var hand_panel := _panel(Color(0, 0, 0, 0.3), Color(0, 0, 0, 0), 8 if portrait else 12)
	hand_panel.size_flags_vertical = Control.SIZE_FILL if portrait else Control.SIZE_EXPAND_FILL
	if portrait:
		hand_panel.custom_minimum_size = Vector2(0, 310)
	var hs := ScrollContainer.new()
	hs.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hand_panel.add_child(hs)
	hand_box = _hbox(12)
	hand_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hand_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	hs.add_child(hand_box)
	left.add_child(hand_panel)

	var right := _vbox(8 if portrait else 12)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(right)
	var log_panel := _panel(Color(0, 0, 0, 0.5), Color("#444444"), 10)
	log_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_label = RichTextLabel.new()
	log_label.scroll_following = true
	log_label.selection_enabled = false
	log_label.add_theme_font_size_override("normal_font_size", 12 if portrait else 13)
	log_label.add_theme_color_override("default_color", Color("#dddddd"))
	log_label.add_theme_constant_override("line_separation", 4)
	log_panel.add_child(log_label)
	right.add_child(log_panel)
	# 縦画面ではボタンを 1 行に並べ、親指で押しやすい一番下に置く
	var btns := _box(not portrait, 8)
	right.add_child(btns)
	var dict_btn := _button("能力一覧" if portrait else "能力一覧を開く", _show_dictionary, C_PANEL, Color.WHITE, 14)
	back_btn = _button("← タイトルへ" if portrait else "← タイトルに戻る", game.reset_to_title, C_PURPLE, Color.WHITE, 16, C_PURPLE)
	back_btn.custom_minimum_size = Vector2(0, 48)
	end_btn = _button("ターン終了", game.end_player_turn, C_GREEN, Color.WHITE, 16, C_GREEN)
	end_btn.custom_minimum_size = Vector2(0, 54)
	for b in [dict_btn, back_btn, end_btn]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btns.add_child(b)
	if portrait:
		end_btn.size_flags_stretch_ratio = 2.0
		back_btn.size_flags_stretch_ratio = 1.5
	return _margin(root, 10 if portrait else 16)


func _status_box() -> Array:
	var p := _panel(Color(0, 0, 0, 0.4), C_BORDER, 8 if portrait else 12)
	var v := _vbox(2 if portrait else 4)
	p.add_child(v)
	var title := _label("", 16 if portrait else 18, Color.WHITE, true)
	title.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	v.add_child(title)
	var sub := RichTextLabel.new()
	sub.bbcode_enabled = true
	sub.fit_content = true
	sub.scroll_active = false
	sub.add_theme_font_size_override("normal_font_size", 13 if portrait else 14)
	sub.add_theme_font_size_override("bold_font_size", 13 if portrait else 14)
	sub.add_theme_font_override("bold_font", font_bold)
	sub.add_theme_color_override("default_color", C_SUB)
	v.add_child(sub)
	var res := _label("", 12)
	v.add_child(res)
	return [p, title, sub, res]


func _status_text(name: String, hp: int, barrier: int, cur: int, mx: int) -> String:
	var s := "● %s  HP: %d" % [name, hp]
	if barrier > 0:
		s += "  ◆[聖域:%d]" % barrier
	return s + "  (マナ: %d/%d)" % [cur, mx]


func _deck_line(deck: int, hand: int, bone: int, bold_hand: bool) -> String:
	var res := "[color=#4d9fff](共鳴中)[/color]" if deck % 2 == 0 else "[color=#ffffff](非共鳴)[/color]"
	var hand_s := "手札: %d 枚" % hand
	if bold_hand:
		hand_s = "[b][color=#ffffff]%s[/color][/b]" % hand_s
	return "山札: %d 枚 %s / %s / 骨: %d" % [deck, res, hand_s, bone]


func _refresh_game() -> void:
	var g := game
	spectator_banner.visible = g.is_spectator
	enemy_title.text = _t(_status_text(g.enemy_display_name(), g.cpu_hp, g.cpu_barrier, g.cpu_current_mana, g.cpu_max_mana))
	enemy_sub.text = _deck_line(g.cpu_deck_length_c(), g.cpu_hand_length_c(), g.p2_flesh_counter if g.is_spectator else g.cpu_flesh_counter, false)
	enemy_res.visible = not g.cpu_resonance_effects.is_empty()
	enemy_res.text = "★ 敵の共鳴能力数: %d" % g.cpu_resonance_effects.size()
	player_title.text = _t(_status_text(g.player_display_name(), g.player_hp, g.player_barrier, g.player_current_mana, g.player_max_mana))
	player_sub.text = _deck_line(g.player_deck_length_c(), g.player_hand_length_c(), g.p1_flesh_counter if g.is_spectator else g.player_flesh_counter, true)
	player_res.visible = not g.player_resonance_effects.is_empty()
	player_res.text = "★ あなたの獲得共鳴能力数: %d" % g.player_resonance_effects.size()
	discard_banner.visible = g.is_selecting_discard

	_clear(hand_box)
	for card in g.player_hand:
		var state := "normal"
		if g.pending_discard_ids.has(card["id"]):
			state = "discard_selected"
		elif g.is_selecting_discard and g.pending_card_to_play != null and card["id"] != g.pending_card_to_play["id"]:
			state = "discard_target"
		elif g.can_play(card):
			state = "playable"
		var view := _make_card(card, g.get_card_cost(card, true), 165 if portrait else 160, 280 if portrait else 260, state)
		_on_click(view, g.handle_hand_card_click.bind(card))
		hand_box.add_child(view)

	if g.log_messages.size() < _log_count:
		log_label.clear()
		_log_count = 0
	for i in range(_log_count, g.log_messages.size()):
		log_label.add_text(_t(g.log_messages[i]) + "\n")
	_log_count = g.log_messages.size()

	back_btn.visible = g.is_game_over
	end_btn.visible = not g.is_spectator
	var can_end := g.is_player_turn and not g.is_game_over and not g.is_selecting_token
	end_btn.disabled = not can_end
	end_btn.text = "ターン終了" if g.is_player_turn else "相手のターン中"


# =========================================================
# オーバーレイ
# =========================================================
func _overlay(alpha := 0.85) -> ColorRect:
	var o := ColorRect.new()
	o.color = Color(0, 0, 0, alpha)
	o.set_anchors_preset(Control.PRESET_FULL_RECT)
	o.mouse_filter = Control.MOUSE_FILTER_STOP
	o.visible = false
	overlay_layer.add_child(o)
	return o


func _centered(parent: Control, child: Control) -> void:
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cc.add_child(child)
	parent.add_child(cc)


func _build_overlays() -> void:
	# --- 機巧増幅トークン選択 ---
	token_overlay = _overlay(0.95)
	var tv := _vbox(14)
	tv.alignment = BoxContainer.ALIGNMENT_CENTER
	var th := _label("◎ 機巧増幅 ◎", 32, C_BLUE, true)
	th.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(th)
	token_desc = _label("", 15 if portrait else 17)
	token_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if portrait:
		token_desc.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		token_desc.custom_minimum_size = Vector2(500, 0)
	tv.add_child(token_desc)
	var tr := _hbox(10 if portrait else 40)
	tr.alignment = BoxContainer.ALIGNMENT_CENTER
	for t in [["draw", "アナライズナギソ", "コ:1 / 攻:0", "【流水1】\n【還元1】", "カードを1枚引き、マナを1回復する基本機巧。", C_BLUE],
			["burn", "レディアントナギソ", "コ:1 / 攻:1", "【雄叫び2】\n【還元1】", "敵に1ダメージを与え、マナを1回復する攻撃機巧。", C_RED],
			["heal", "エンシェントナギソ", "コ:1 / 攻:0", "【神秘4】\n【還元1】", "自身の生命力を4ポイント修復し、マナを1回復する防衛機巧。", C_GREEN]]:
		var sb := _sb(C_PANEL, t[5], 12, 2, 16)
		sb.shadow_color = Color(t[5], 0.8)
		sb.shadow_size = 14
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", sb)
		p.custom_minimum_size = Vector2(160, 320) if portrait else Vector2(230, 350)
		p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var v := _vbox(8)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(v)
		var img := TextureRect.new()
		img.texture = _texture("images/mate.png")
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		img.custom_minimum_size = Vector2(0, 100)
		v.add_child(img)
		for l in [_label(t[1], 15 if portrait else 18, Color.WHITE, true), _label(t[2], 14), _label(t[3], 15, t[5], true), _label(t[4], 12, C_SUB)]:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
			v.add_child(l)
		for c in v.get_children():
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_on_click(p, game.select_token.bind(t[0]))
		tr.add_child(p)
	tv.add_child(tr)
	_centered(token_overlay, tv)

	# --- マッチング待ち ---
	matching_overlay = _overlay(0.85)
	var mv := _vbox(14)
	var spinner := Spinner.new()
	spinner.custom_minimum_size = Vector2(56, 56)
	spinner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mv.add_child(spinner)
	matching_title = _label("", 26, Color.WHITE, true)
	matching_room = _label("", 16, C_YELLOW, true)
	var mw := _label("サーバーからの応答を待っています。\n（サーバーが休止中の場合、起動まで1分ほどかかることがあります）", 13 if portrait else 15, Color("#bbbbbb"))
	for l in [matching_title, matching_room, mw]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mv.add_child(l)
	var cb := _button("キャンセル", game.cancel_matching, C_RED, Color.WHITE, 16, C_RED)
	cb.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mv.add_child(cb)
	_centered(matching_overlay, mv)

	# --- 能力用語一覧 ---
	dictionary_overlay = _overlay(0.92)
	var dv := _vbox(16)
	var dh := _label("能力用語一覧", 26, C_YELLOW, true)
	dh.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dv.add_child(dh)
	var dp := _panel(Color("#232730"), C_BORDER, 16, 10)
	dp.custom_minimum_size = Vector2(510, 760) if portrait else Vector2(900, 520)
	var ds := ScrollContainer.new()
	ds.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	dp.add_child(ds)
	var dg := GridContainer.new()
	dg.columns = 1 if portrait else 2  # 本家も 768px 未満は 1 列
	dg.add_theme_constant_override("h_separation", 12)
	dg.add_theme_constant_override("v_separation", 12)
	dg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ds.add_child(dg)
	for ab in game.ability_dictionary:
		var sb := _sb(Color("#151518"), C_BLUE, 6, 0, 12)
		sb.border_width_left = 4
		var item := PanelContainer.new()
		item.add_theme_stylebox_override("panel", sb)
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var iv := _vbox(4)
		item.add_child(iv)
		iv.add_child(_label("【%s】" % ab["name"], 15, Color.WHITE, true))
		var desc := _label(ab["desc"], 13, Color("#cccccc"))
		desc.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		desc.custom_minimum_size = Vector2(440 if portrait else 400, 0)
		iv.add_child(desc)
		dg.add_child(item)
	dv.add_child(dp)
	var close := _button("閉じる", func(): dictionary_overlay.visible = false, C_GRAY, Color.WHITE, 16, C_GRAY)
	close.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	dv.add_child(close)
	_centered(dictionary_overlay, dv)

	# --- カード使用演出 ---
	notice_root = Control.new()
	notice_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	notice_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_layer.add_child(notice_root)

	# --- トースト ---
	toast = _panel(Color(0.86, 0.2, 0.27, 0.95), Color(0, 0, 0, 0), 12, 24)
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_label = _label("", 15, Color.WHITE, true)
	toast.add_child(toast_label)
	toast.modulate.a = 0
	overlay_layer.add_child(toast)


func _show_dictionary() -> void:
	dictionary_overlay.visible = true


func _show_toast(msg: String) -> void:
	toast_label.text = _t(msg)
	toast.reset_size()
	var vp := get_viewport_rect().size
	toast.position = Vector2((vp.x - toast.size.x) / 2.0, vp.y * 0.1 - 20)
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.set_parallel(true)
	_toast_tween.tween_property(toast, "modulate:a", 1.0, 0.3)
	_toast_tween.tween_property(toast, "position:y", vp.y * 0.1, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_toast_tween.chain().tween_interval(2.2)
	_toast_tween.chain().tween_property(toast, "modulate:a", 0.0, 0.3)


func _show_card_notice(user: String, card: Dictionary) -> void:
	_clear(notice_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	notice_root.add_child(dim)

	var v := _vbox(14)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ul := _label(_t(user), 20, Color.WHITE, true)
	ul.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ul.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	v.add_child(ul)

	var sb := _sb(C_BLUE, Color.WHITE, 15, 3, 14)
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 20
	var cardp := PanelContainer.new()
	cardp.add_theme_stylebox_override("panel", sb)
	cardp.custom_minimum_size = Vector2(200, 300)
	cardp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cv := _vbox(6)
	cardp.add_child(cv)
	var img := TextureRect.new()
	img.texture = _texture(str(card.get("image", "images/mate.png")))
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.custom_minimum_size = Vector2(0, 100)
	cv.add_child(img)
	var nl := _label(str(card.get("name", "")), 17, Color.WHITE, true)
	nl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	cv.add_child(nl)
	cv.add_child(_label("コスト: %d / 攻撃: %d" % [game.get_card_cost(card, user == game.user_name), int(card.get("power", 0))], 13))
	if str(card.get("abilityText", "")) != "":
		var al := _label(_format_ability(card["abilityText"]), 12, Color.YELLOW, true)
		al.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		cv.add_child(al)
	for l in cv.get_children():
		if l is Label:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(cardp)

	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cc.add_child(v)
	notice_root.add_child(cc)

	# CSS の popUp / fadeInOut と同じ 1.2 秒の演出
	await get_tree().process_frame
	if not is_instance_valid(cc) or cc.is_queued_for_deletion():
		return
	cardp.pivot_offset = cardp.size / 2.0
	cardp.scale = Vector2(0.5, 0.5)
	v.modulate.a = 0.0
	# 演出ノードに紐づけて、次の演出で消されたらトゥイーンも止まるようにする
	var tw := cc.create_tween()
	tw.set_parallel(true)
	tw.tween_property(dim, "color:a", 0.4, 0.18)
	tw.tween_property(v, "modulate:a", 1.0, 0.18)
	tw.tween_property(cardp, "scale", Vector2(1.1, 1.1), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_property(cardp, "scale", Vector2.ONE, 0.12)
	tw.chain().tween_interval(0.66)
	tw.chain().set_parallel(true)
	tw.tween_property(cardp, "scale", Vector2(0.8, 0.8), 0.24)
	tw.tween_property(v, "modulate:a", 0.0, 0.24)
	tw.tween_property(dim, "color:a", 0.0, 0.24)
	tw.chain().tween_callback(_clear.bind(notice_root))


# =========================================================
# 全体の再描画
# =========================================================
func _refresh() -> void:
	var editing := edit_screen.visible
	title_screen.visible = not game.is_game_started and not editing
	game_screen.visible = game.is_game_started and not editing
	if title_screen.visible:
		_refresh_title()
	if game_screen.visible or game.is_game_started:
		_refresh_game()
	if not game.is_game_started and game.log_messages.size() <= 1:
		log_label.clear()
		_log_count = 0

	matching_overlay.visible = game.is_matching
	matching_title.text = "ルームに接続中..." if game.game_mode == "spectate" else "対戦相手を検索中..."
	matching_room.visible = game.game_mode in ["online_room", "spectate"]
	matching_room.text = "ルーム名: " + game.room_name
	token_overlay.visible = game.is_selecting_token
	token_desc.text = "山札に加えるナギソトークンを1種選択してください（%d枚追加してシャッフル）" % game.token_selection_count


## マッチング待ちのくるくる
class Spinner extends Control:
	var angle := 0.0

	func _process(delta: float) -> void:
		if is_visible_in_tree():
			angle += delta * TAU
			queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var r := minf(size.x, size.y) / 2.0 - 3.0
		draw_arc(c, r, 0, TAU, 48, Color(1, 1, 1, 0.3), 5.0, true)
		draw_arc(c, r, angle, angle + PI / 2.0, 24, Color("#6f42c1"), 5.0, true)
