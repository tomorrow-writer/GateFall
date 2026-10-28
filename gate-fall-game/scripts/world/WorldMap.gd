## World map scene (real time, like DF): castles joined by roads, generals walk
## them while the days tick by. Draws the map and HUD itself (same panel style
## as the battle HUD) and drives WorldSim, which lives in the Campaign autoload
## so the war carries on after a battle.
##
## Mouse:
##   click a general's banner (or a castle with your generals) = select
##   with a general selected, click any castle = march there (path is shown
##     while hovering) · click its own castle again = next general there
##   right-click = deselect
## Keys:
##   Space = pause / go on · 1 / 2 / 3 = speed ×1 / ×2 / ×4
##   Tab = next of your generals · Esc = deselect
##   when a battle starts: Enter = fight it yourself · A = auto-resolve
extends Node2D

const WorldSim = preload("res://scripts/world/WorldSim.gd")
const AutoBattle = preload("res://scripts/world/AutoBattle.gd")
const BattleSim = preload("res://scripts/battle/BattleSim.gd")

const SCREEN := Vector2(320, 180)
const SEA := Color("1d3a4a")
const SEA_LINE := Color("2c5566")
const LAND := Color("6d8a4c")
const LAND_EDGE := Color("e2d6a0")
const ROAD := Color("c8a86a")
const ROAD_EDGE := Color("4a3a24")
const PANEL := Color(0.05, 0.06, 0.11, 0.86)
const TRIM := Color("b08a4a")
const TRIM_HI := Color("e8c27a")
const TEXT := Color(0.96, 0.94, 0.88)
const DIM := Color(0.75, 0.73, 0.68)
const ALERT := Color("ff7a5a")
const TOP_BAR := Rect2(0, 0, 320, 12)
const BOTTOM_BAR := Rect2(0, 154, 320, 26)

var world: WorldSim = null
var data: Dictionary
var side_cfg: Dictionary
var selected := ""  # general id
var hover_castle := ""
var paused := false
var speed_i := 0
var log_lines: Array[String] = []

var _clock := 0.0
var _decor: Array = []  # [pos, kind] map texture (trees / hills), made once
var _battle_cfg: Dictionary
var _ui: CanvasLayer
var _popup: PanelContainer = null
var _popup_battle := -1


func _ready() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 5
	add_child(_ui)
	_battle_cfg = BattleSim.load_config("res://data/battle_config.json")
	if Campaign.world == null:
		data = WorldSim.load_map(Campaign.MAP_DATA)
		side_cfg = data.sides
		_make_decor()
		_show_title()
		return
	selected = Campaign.map_selected
	speed_i = Campaign.map_speed
	_bind(Campaign.world)
	if world.get_general(selected) == null or world.get_general(selected).state == "captured":
		selected = ""
	paused = true  # back from a battle: look first, Space to go on
	_log("กลับจากสนามรบ · Space เดินเวลาต่อ")
	for e in world._take_events():
		_on_event(e)
	_check_battles()


func _bind(w: WorldSim) -> void:
	world = w
	data = w.data
	side_cfg = data.sides
	_make_decor()
	var mine := world.generals_of(Campaign.player_side)
	if selected == "" and not mine.is_empty():
		selected = mine[0].id


func _process(delta: float) -> void:
	_clock += delta
	if world != null and not paused and _popup == null and world.winner == "":
		var speeds: Array = data.time.speeds
		var days := delta / float(data.time.day_seconds) * float(speeds[speed_i])
		for e in world.step(days):
			_on_event(e)
		_check_battles()
	hover_castle = _castle_at(get_local_mouse_position())
	queue_redraw()


# --- input ----------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if world == null:
		return
	if event is InputEventMouseButton and event.pressed:
		if _popup != null:
			return
		var p := get_local_mouse_position()
		if event.button_index == MOUSE_BUTTON_RIGHT:
			selected = ""
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_click(p)
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if _popup != null:
		if _popup_battle >= 0:
			match event.keycode:
				KEY_ENTER, KEY_KP_ENTER:
					_fight(_popup_battle)
				KEY_A:
					_auto(_popup_battle)
		elif world.winner != "" and event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
			_restart()
		return
	match event.keycode:
		KEY_SPACE:
			paused = not paused
		KEY_1:
			speed_i = 0
		KEY_2:
			speed_i = mini(1, data.time.speeds.size() - 1)
		KEY_3:
			speed_i = data.time.speeds.size() - 1
		KEY_TAB:
			_select_next()
		KEY_ESCAPE:
			selected = ""


func _click(p: Vector2) -> void:
	# Banners first: picking a general directly.
	for t in _tokens():
		if t.rect.grow(1.0).has_point(p):
			var tg := world.get_general(t.id)
			if tg.side == Campaign.player_side:
				selected = tg.id
				return
	var cid := _castle_at(p)
	if cid == "":
		return
	var g := world.get_general(selected)
	if g != null and g.state in ["idle", "moving"]:
		if g.state == "idle" and g.castle == cid:
			_select_next(cid)
			return
		if world.order_move(g, cid):
			_log("%s เดินทัพไป %s" % [g.name, world.castles[cid].name])
		return
	var here := world.generals_at(cid, Campaign.player_side)
	if not here.is_empty():
		selected = here[0].id


## Next of the player's generals (only those standing in `in_castle` if given).
func _select_next(in_castle: String = "") -> void:
	var mine: Array = []
	for g in world.generals_of(Campaign.player_side):
		if in_castle == "" or (g.state == "idle" and g.castle == in_castle):
			mine.append(g)
	if mine.is_empty():
		return
	var i := -1
	for k in mine.size():
		if mine[k].id == selected:
			i = k
	selected = mine[(i + 1) % mine.size()].id


func _castle_at(p: Vector2) -> String:
	if world == null:
		return ""
	var best := ""
	var best_d := 9.0
	for c in world.castles.values():
		var d: float = c.pos.distance_to(p)
		if d < best_d:
			best_d = d
			best = c.id
	return best


# --- events / battles -------------------------------------------------------------

func _on_event(e: Dictionary) -> void:
	var g := world.get_general(str(e.get("general", "")))
	var who: String = g.name if g != null else ""
	var mine: bool = g != null and g.side == Campaign.player_side
	match e.type:
		"capture":
			_log("%s ยึด %s" % [who, world.castles[e.castle].name], not mine)
		"retreat":
			_log("%s ถอยไป %s" % [who, world.castles[e.to].name], mine)
		"captured":
			_log("%s ถูกจับ!" % who, mine)
			if selected == g.id:
				selected = ""
		"arrive":
			if mine:
				_log("%s ถึง %s" % [who, world.castles[e.castle].name])
		"over":
			_show_end(e.winner)


func _check_battles() -> void:
	if _popup != null or world.battles.is_empty() or world.winner != "":
		return
	var b: Dictionary = world.battles[0]
	var a := world.get_general(b.a)
	var d := world.get_general(b.d)
	if a.side != Campaign.player_side and d.side != Campaign.player_side:
		_auto(int(b.id))
		return
	var mine := a if a.side == Campaign.player_side else d
	var theirs := d if mine == a else a
	var where: String = ("ที่ " + world.castles[b.castle].name) if b.castle != "" else "กลางทาง"
	var who_attacks := "เราบุก" if mine == a else "ศัตรูบุก"
	_popup_battle = int(b.id)
	_popup = _make_popup("ศึก! (%s)" % who_attacks,
			"%s  ทหาร %d\nvs\n%s  ทหาร %d\n%s" % [mine.name, int(mine.troops), theirs.name, int(theirs.troops), where],
			[["สู้เอง [Enter]", _fight.bind(int(b.id))], ["ให้คำนวณผล [A]", _auto.bind(int(b.id))]])


func _battle_troops(b: Dictionary) -> Dictionary:
	var a := world.get_general(b.a)
	var d := world.get_general(b.d)
	return {a.side: int(a.troops), d.side: int(d.troops)}


func _fight(id: int) -> void:
	var b := world.get_battle(id)
	if b.is_empty():
		return
	var a := world.get_general(b.a)
	var d := world.get_general(b.d)
	var names := {a.side: a.name, d.side: d.name}
	_close_popup()
	Campaign.map_selected = selected
	Campaign.map_speed = speed_i
	Campaign.fight({"id": id, "player_side": Campaign.player_side, "troops": _battle_troops(b),
			"names": names, "where": world.castles[b.castle].name if b.castle != "" else "กลางทาง"})


func _auto(id: int) -> void:
	var b := world.get_battle(id)
	if b.is_empty():
		return
	_close_popup()
	var res := AutoBattle.resolve(_battle_cfg, _battle_troops(b), randi_range(1, 2147483646))
	var a := world.get_general(b.a)
	var d := world.get_general(b.d)
	world.resolve_battle(id, res.winner, res.left)
	var won := a if res.winner == a.side else d
	var txt := "เสมอ" if res.winner == "draw" else "%s ชนะ" % won.name
	_log("ศึก %s vs %s: %s (เหลือ %d / %d)" % [a.name, d.name, txt, res.left.get(a.side, 0), res.left.get(d.side, 0)],
			res.winner != Campaign.player_side)
	for e in world._take_events():
		_on_event(e)
	_check_battles()


# --- popups -----------------------------------------------------------------------

func _make_popup(title: String, body: String, buttons: Array) -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.11, 0.94)
	sb.border_color = TRIM_HI
	sb.set_border_width_all(1)
	sb.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)
	var t := Label.new()
	t.text = title
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 10)
	t.add_theme_color_override("font_color", TRIM_HI)
	box.add_child(t)
	if body != "":
		var l := Label.new()
		l.text = body
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 8)
		box.add_child(l)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	for bt in buttons:
		var b := Button.new()
		b.text = bt[0]
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 8)
		b.pressed.connect(bt[1])
		row.add_child(b)
	_ui.add_child(panel)
	panel.reset_size()
	panel.position = ((SCREEN - panel.size) / 2.0).round()
	return panel


func _close_popup() -> void:
	if _popup != null:
		_popup.queue_free()
	_popup = null
	_popup_battle = -1


func _show_title() -> void:
	_close_popup()
	_popup = _make_popup("Gatefall · เลือกฝั่ง",
			"ประตูต่างมิติเปิดขึ้นทั่วโลก\nยึดปราสาทหลวงของฝ่ายตรงข้ามเพื่อชนะสงคราม",
			[["สไลม์ (ผู้รุกราน)", _start.bind("S")], ["มนุษย์ (ผู้ปกป้อง)", _start.bind("K")],
			["ทดสอบฉากรบ", Campaign.test_battle]])


func _start(side: String) -> void:
	_close_popup()
	Campaign.new_game(side)
	selected = ""
	log_lines.clear()
	_bind(Campaign.world)
	paused = false
	_log("เริ่มสงคราม: คลิกแม่ทัพ แล้วคลิกปราสาทที่จะไป")


func _show_end(winner: String) -> void:
	_close_popup()
	var won: bool = winner == Campaign.player_side
	_popup = _make_popup("ชนะสงคราม!" if won else "แพ้สงคราม",
			"วันที่ %d" % int(world.day) + ("\nยึดปราสาทหลวงได้แล้ว" if won else ""),
			[["เริ่มใหม่ [Enter]", _restart]])


func _restart() -> void:
	Campaign.quit_war()
	world = null
	selected = ""
	_show_title()


func _log(t: String, alert := false) -> void:
	log_lines.append(("! " if alert else "") + t)
	while log_lines.size() > 4:
		log_lines.pop_front()


# --- drawing --------------------------------------------------------------------

func _make_decor() -> void:
	_decor.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var land := _land_poly()
	var placed := 0
	while placed < 140:
		var p := Vector2(rng.randf_range(10, 310), rng.randf_range(18, 150))
		if not Geometry2D.is_point_in_polygon(p, land):
			continue
		var near := false
		for c in data.castles:
			if p.distance_to(Vector2(c.pos[0], c.pos[1])) < 14:
				near = true
		if near:
			continue
		_decor.append([p.round(), "tree" if rng.randf() < 0.7 else "hill"])
		placed += 1


func _land_poly() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in data.land:
		out.append(Vector2(p[0], p[1]))
	return out


func _side_col(side: String, dark := false) -> Color:
	var s: Dictionary = side_cfg.get(side, side_cfg[""])
	return Color(s.dark if dark else s.color)


func _draw() -> void:
	if data.is_empty():
		return
	var font := ThemeDB.fallback_font
	_draw_ground()
	if world == null:
		_draw_castles_static(font)
		return
	_draw_roads()
	_draw_paths()
	_draw_castles(font)
	_draw_generals(font)
	_draw_top(font)
	_draw_bottom(font)


func _draw_ground() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), SEA)
	for y in range(16, 176, 9):
		var off := sin(y * 0.7 + _clock * 0.6) * 3.0
		draw_line(Vector2(4 + off, y), Vector2(14 + off, y), SEA_LINE, 1.0)
		draw_line(Vector2(300 - off, y + 4), Vector2(312 - off, y + 4), SEA_LINE, 1.0)
	var land := _land_poly()
	var edge := land.duplicate()
	edge.append(land[0])
	draw_colored_polygon(land, LAND)
	draw_polyline(edge, LAND_EDGE, 1.5)
	for d in _decor:
		var p: Vector2 = d[0]
		if d[1] == "tree":
			draw_colored_polygon(PackedVector2Array([p + Vector2(0, -3), p + Vector2(2, 1), p + Vector2(-2, 1)]),
					Color("4a6a36"))
		else:
			draw_colored_polygon(PackedVector2Array([p + Vector2(0, -3), p + Vector2(4, 1), p + Vector2(-4, 1)]),
					Color("8a8f5a"))


func _draw_roads() -> void:
	for r in data.roads:
		var a: Vector2 = world.castles[r[0]].pos
		var b: Vector2 = world.castles[r[1]].pos
		draw_line(a, b, ROAD_EDGE, 3.0)
	for r in data.roads:
		draw_line(world.castles[r[0]].pos, world.castles[r[1]].pos, ROAD, 1.5)


## Where your generals are going (solid), and where the selected one would go.
func _draw_paths() -> void:
	for g in world.generals:
		if g.state != "moving" or g.side != Campaign.player_side:
			continue
		var col := _side_col(g.side)
		col.a = 0.9 if g.id == selected else 0.45
		_dashed(g.pos, g.path, col)
	var sel := world.get_general(selected)
	if sel != null and hover_castle != "" and sel.state in ["idle", "moving"] \
			and not (sel.state == "idle" and sel.castle == hover_castle):
		var start: String = sel.castle if sel.state == "idle" else sel.path[0]
		var p := world.shortest(start, hover_castle)
		if p.size() >= 1:
			_dashed(sel.pos, p, Color(1, 1, 1, 0.8 if fmod(_clock, 0.6) < 0.4 else 0.4))


func _dashed(from: Vector2, path: Array, col: Color) -> void:
	var p := from
	for cid in path:
		var q: Vector2 = world.castles[cid].pos
		var n := maxi(1, int(p.distance_to(q) / 4.0))
		for i in n:
			if i % 2 == 0:
				draw_line(p.lerp(q, float(i) / n), p.lerp(q, float(i + 1) / n), col, 1.0)
		p = q
	draw_circle(p, 2.0, col)


func _draw_castles_static(font: Font) -> void:
	for c in data.castles:
		_draw_castle(font, Vector2(c.pos[0], c.pos[1]), str(c.get("owner", "")), bool(c.get("capital", false)),
				c.name, false, false)


func _draw_castles(font: Font) -> void:
	var fighting := {}
	for b in world.battles:
		if b.castle != "":
			fighting[b.castle] = true
	for c in world.castles.values():
		_draw_castle(font, c.pos, c.owner, c.capital, c.name, c.id == hover_castle, fighting.has(c.id))


func _draw_castle(font: Font, p: Vector2, owner: String, capital: bool, name: String, hover: bool,
		fighting: bool) -> void:
	var col := _side_col(owner)
	var dark := _side_col(owner, true)
	var w := 11.0 if capital else 8.0
	var h := 7.0 if capital else 5.0
	var base := Rect2(p.x - w / 2.0, p.y - h + 2.0, w, h)
	draw_rect(base.grow(1.0), Color(0, 0, 0, 0.6))
	draw_rect(base, col)
	draw_rect(Rect2(base.position.x, base.end.y - 1, w, 1), dark)
	# towers
	for x in [base.position.x, base.end.x - 2.0]:
		draw_rect(Rect2(x - 0.5, base.position.y - 2.0, 3, 3), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(x, base.position.y - 1.5, 2, 2), col)
	draw_rect(Rect2(p.x - 1, base.end.y - 3, 2, 3), dark)  # gate
	if capital:
		draw_rect(Rect2(p.x - 1, base.position.y - 4, 2, 3), TRIM_HI)
	if hover:
		draw_arc(p + Vector2(0, -1), 9.0, 0, TAU, 20, Color(1, 1, 1, 0.8), 1.0)
	if fighting and fmod(_clock, 0.5) < 0.3:
		draw_arc(p + Vector2(0, -1), 10.0, 0, TAU, 20, ALERT, 1.5)
	_text(font, name, p + Vector2(0, 9), 6, TEXT if hover else Color(1, 1, 1, 0.85), true)


## Clickable banners: generals standing in a castle line up above it; walking
## ones are a marker on the road.
func _tokens() -> Array:
	var out := []
	var at := {}
	for g in world.generals:
		if g.state == "idle":
			if not at.has(g.castle):
				at[g.castle] = []
			at[g.castle].append(g)
		elif g.state in ["moving", "battle"]:
			out.append({"id": g.id, "rect": Rect2(g.pos - Vector2(3, 7), Vector2(6, 6)), "moving": true})
	for cid in at:
		var list: Array = at[cid]
		var p: Vector2 = world.castles[cid].pos
		var x0 := p.x - (list.size() * 6 - 1) / 2.0
		for i in list.size():
			out.append({"id": list[i].id, "rect": Rect2(x0 + i * 6, p.y - 16, 5, 6), "moving": false})
	return out


func _draw_generals(font: Font) -> void:
	for t in _tokens():
		var g := world.get_general(t.id)
		var r: Rect2 = t.rect
		var col := _side_col(g.side)
		var sel: bool = g.id == selected
		if t.moving:
			var c := r.get_center()
			var dia := PackedVector2Array([c + Vector2(0, -4), c + Vector2(4, 0), c + Vector2(0, 4), c + Vector2(-4, 0)])
			draw_colored_polygon(dia, Color(0, 0, 0, 0.6))
			var inner := PackedVector2Array([c + Vector2(0, -3), c + Vector2(3, 0), c + Vector2(0, 3), c + Vector2(-3, 0)])
			draw_colored_polygon(inner, col)
			draw_line(c + Vector2(0, 3), g.pos, Color(0, 0, 0, 0.5), 1.0)
			if g.state == "battle":
				var a := ALERT if fmod(_clock, 0.4) < 0.25 else TEXT
				draw_line(c + Vector2(-4, -4), c + Vector2(4, 4), a, 1.0)
				draw_line(c + Vector2(4, -4), c + Vector2(-4, 4), a, 1.0)
			if g.retreating:
				_text(font, "ถอย", c + Vector2(0, -6), 6, DIM, true)
		else:
			# flag on a pole
			draw_line(Vector2(r.position.x, r.position.y), Vector2(r.position.x, r.end.y + 3), Color(0.2, 0.15, 0.1), 1.0)
			draw_rect(r.grow(0.5), Color(0, 0, 0, 0.6))
			draw_rect(r, col)
			if g.king:
				draw_rect(Rect2(r.position.x + 1, r.position.y + 1, 3, 1), TRIM_HI)
		if sel and fmod(_clock, 0.8) < 0.55:
			draw_rect(r.grow(1.5), Color.WHITE, false, 1.0)
		if g.troops < 0.5:
			draw_line(r.position, r.end, ALERT, 1.0)


func _draw_top(font: Font) -> void:
	draw_rect(TOP_BAR, PANEL)
	draw_line(Vector2(0, TOP_BAR.end.y), Vector2(SCREEN.x, TOP_BAR.end.y), TRIM, 1.0)
	var speeds: Array = data.time.speeds
	var clock := "วันที่ %d" % (int(world.day) + 1)
	_text(font, clock, Vector2(160, 9), 8, TRIM_HI, true)
	var state := "หยุด [Space]" if paused else "×%d" % int(speeds[speed_i])
	_text(font, state, Vector2(200, 9), 6, ALERT if paused else DIM, false)
	var x := 3.0
	for side in ["S", "K"]:
		var mine: bool = side == Campaign.player_side
		var t := "%s%s ปราสาท %d · ทหาร %d" % [side_cfg[side].label, " (เรา)" if mine else "",
				world.castles_of(side).size(), world.troops_of(side)]
		if side == "S":
			_text(font, t, Vector2(x, 9), 6, _side_col(side), false)
		else:
			_text(font, t, Vector2(SCREEN.x - 3 - _w(font, t, 6), 9), 6, _side_col(side), false)


func _draw_bottom(font: Font) -> void:
	draw_rect(BOTTOM_BAR, PANEL)
	draw_line(Vector2(0, BOTTOM_BAR.position.y), Vector2(SCREEN.x, BOTTOM_BAR.position.y), TRIM, 1.0)
	var g := world.get_general(selected)
	var y := BOTTOM_BAR.position.y + 8
	if g != null:
		var where := ""
		match g.state:
			"idle":
				where = "อยู่ที่ " + world.castles[g.castle].name
			"moving":
				where = ("ถอยไป " if g.retreating else "กำลังไป ") + world.castles[g.target()].name
			"battle":
				where = "กำลังรบ"
		var t := "%s%s · ทหาร %d/%d · %s" % ["★" if g.king else "", g.name, int(g.troops), int(world.rules.max_troops), where]
		_text(font, t, Vector2(3, y), 8, _side_col(g.side), false)
		if hover_castle != "":
			_text(font, "→ คลิกเพื่อเดินทัพไป %s" % world.castles[hover_castle].name, Vector2(3, y + 9), 6, DIM, false)
		else:
			_text(font, "คลิกปราสาทปลายทาง · Tab แม่ทัพถัดไป · คลิกขวายกเลิก", Vector2(3, y + 9), 6, DIM, false)
	else:
		_text(font, "คลิกธงแม่ทัพของเรา หรือกด Tab", Vector2(3, y), 8, DIM, false)
		_text(font, "Space หยุดเวลา · 1/2/3 ความเร็ว", Vector2(3, y + 9), 6, DIM, false)
	# castle info on hover (right half)
	if hover_castle != "":
		var c: Dictionary = world.castles[hover_castle]
		var lines := ["%s (%s)" % [c.name, side_cfg[c.owner].label]]
		for e in world.generals_at(hover_castle):
			lines.append("%s ทหาร %d" % [e.name, int(e.troops)])
		for i in mini(lines.size(), 3):
			_text(font, lines[i], Vector2(SCREEN.x - 3 - _w(font, lines[i], 6), BOTTOM_BAR.position.y + 7 + i * 7), 6,
					_side_col(c.owner) if i == 0 else TEXT, false)
	elif not log_lines.is_empty():
		var l: String = log_lines[-1]
		_text(font, l, Vector2(SCREEN.x - 3 - _w(font, l, 6), BOTTOM_BAR.position.y + 21), 6,
				ALERT if l.begins_with("!") else TEXT, false)


func _w(font: Font, t: String, size: int) -> float:
	return font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Text with a 1 px shadow; centred on pos.x if centre.
func _text(font: Font, t: String, pos: Vector2, size: int, col: Color, centre: bool) -> void:
	var x := pos.x - _w(font, t, size) / 2.0 if centre else pos.x
	draw_string(font, Vector2(x + 0.5, pos.y + 0.5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.85))
	draw_string(font, Vector2(x, pos.y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
