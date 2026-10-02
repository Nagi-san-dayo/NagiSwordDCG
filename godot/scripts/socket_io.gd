## 最小限の Socket.IO v4 (Engine.IO v4) クライアント。
## 既存の Node.js サーバー (socket.io) とそのまま通信するために WebSocket 上でプロトコルを手実装している。
class_name SocketIOClient
extends Node

signal connected
signal disconnected
signal event_received(event_name: String, data: Variant)

const RECONNECT_DELAY := 3.0

var url: String = ""
var _ws := WebSocketPeer.new()
var _is_open := false   # Socket.IO 名前空間に接続済みか
var _last_state := WebSocketPeer.STATE_CLOSED
var _reconnect_timer := 0.0
var _queue: Array[String] = []  # 接続前に emit されたパケット


func connect_to(server_url: String) -> void:
	var base := server_url.strip_edges().trim_suffix("/")
	if base.begins_with("https://"):
		base = "wss://" + base.substr(8)
	elif base.begins_with("http://"):
		base = "ws://" + base.substr(7)
	url = base + "/socket.io/?EIO=4&transport=websocket"
	_open()


func is_connected_to_server() -> bool:
	return _is_open


func emit_event(event_name: String, data: Variant = null) -> void:
	var payload: Array = [event_name]
	if data != null:
		payload.append(data)
	var packet := "42" + JSON.stringify(payload)
	if _is_open:
		_ws.send_text(packet)
	else:
		_queue.append(packet)


func _open() -> void:
	_ws = WebSocketPeer.new()
	_is_open = false
	var err := _ws.connect_to_url(url)
	if err != OK:
		push_warning("Socket.IO: 接続開始に失敗しました (%d)" % err)
		_reconnect_timer = RECONNECT_DELAY


func _process(delta: float) -> void:
	if url.is_empty():
		return
	if _reconnect_timer > 0.0:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0:
			_open()
		return

	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		while _ws.get_available_packet_count() > 0:
			_handle_packet(_ws.get_packet().get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSED and _last_state != WebSocketPeer.STATE_CLOSED:
		var was_open := _is_open
		_is_open = false
		if was_open:
			disconnected.emit()
		_reconnect_timer = RECONNECT_DELAY
	_last_state = state


func _handle_packet(text: String) -> void:
	if text.is_empty():
		return
	match text[0]:
		"0":  # Engine.IO open -> Socket.IO 名前空間 "/" に接続
			_ws.send_text("40")
		"2":  # ping -> pong
			_ws.send_text("3")
		"1":  # close
			_ws.close()
		"4":
			_handle_socketio(text.substr(1))


func _handle_socketio(text: String) -> void:
	if text.is_empty():
		return
	match text[0]:
		"0":  # CONNECT ack
			_is_open = true
			for p in _queue:
				_ws.send_text(p)
			_queue.clear()
			connected.emit()
		"1":  # DISCONNECT
			_is_open = false
			disconnected.emit()
		"2":  # EVENT
			var body := text.substr(1)
			# ack id が付いている場合は数字を読み飛ばす
			var i := 0
			while i < body.length() and body[i] >= "0" and body[i] <= "9":
				i += 1
			var parsed: Variant = JSON.parse_string(body.substr(i))
			if parsed is Array and parsed.size() > 0:
				event_received.emit(str(parsed[0]), parsed[1] if parsed.size() > 1 else null)
		"4":  # CONNECT_ERROR
			push_warning("Socket.IO: 接続エラー " + text)
