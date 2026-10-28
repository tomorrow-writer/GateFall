## Setup screen: pick a formation. A 3-column grid of cards, each with a small
## diagram of the formation's real starting spots (BattleSim.formation_spots)
## coloured by group, and a detail panel for the selected one: role, stat bars,
## how the troops are split, its commands and the general's specials, plus the
## start button. Drawn in the HUD's own style (dark panels, bronze trim) at the
## 320x180 game resolution like BattleHud.
## Mouse: click a card to pick it, click the selected card again or the start
## button to fight. Keys (Battle.gd): arrows move, Enter starts.
extends Control

signal picked(key: String)
signal start_pressed

const BattleSim = preload("res://scripts/battle/BattleSim.gd")

const PANEL := Color(0.05, 0.06, 0.11, 0.94)
const CARD := Color(0.09, 0.10, 0.17, 1.0)
const CARD_SEL := Color(0.16, 0.14, 0.12, 1.0)
const FIELD := Color(0.20, 0.17, 0.12, 1.0)
const FIELD_LANE := Color(1, 1, 1, 0.07)
const TRIM := Color("b08a4a")
const TRIM_HI := Color("e8c27a")
const TEXT := Color(0.96, 0.94, 0.88)
const DIM := Color(0.72, 0.70, 0.65)
const GOOD := Color("8cff9a")
const BAD := Color("ff8a7a")
const GUARD_COL := Color("ffd25a")
const RAID_COL := Color("ff9a3c")
const GEN_COL := Color("ff5a5a")

const BOX := Rect2(4, 31, 312, 127)
const COLS := 3
const CARD_SIZE := Vector2(54, 33)
const CARD_GAP := 3.0
const GRID_POS := Vector2(9, 45)
const INFO := Rect2(180, 43, 132, 112)
const START_BTN := Rect2(184, 139, 124, 13)
## Diagram: field area shown (world px) -> card diagram rect
const WORLD_X := Vector2(22, 168)
const WORLD_Y := Vector2(114, 236)

var cfg: Dictionary = {}
var keys: Array = []
var selected := ""
var troop_col := Color("8fe07a")  # the player's army colour (main group)
var specials_lines: PackedStringArray = []  # the general's style + specials (Battle.gd)
var _hover := -1
var _hover_start := false
var _clock := 0.0


func setup(config: Dictionary, troop_colour: Color) -> void:
	cfg = config
	keys = cfg.formations.keys()
	troop_col = troop_colour
	mouse_filter = Control.MOUSE_FILTER_STOP
	position = Vector2.ZERO
	size = Vector2(320, 180)
	queue_redraw()


func _process(delta: float) -> void:
	if visible:
		_clock += delta
		queue_redraw()


## Move the selection by d cards (keys: left/right 1, up/down COLS).
func move(d: int) -> void:
	if keys.is_empty():
		return
	var i := keys.find(selected)
	i = clampi(i + d, 0, keys.size() - 1)
	picked.emit(keys[i])


func _card_rect(i: int) -> Rect2:
	var c := i % COLS
	var r := i / COLS
	return Rect2(GRID_POS + Vector2(c * (CARD_SIZE.x + CARD_GAP), r * (CARD_SIZE.y + CARD_GAP)), CARD_SIZE)


func _has_point(point: Vector2) -> bool:
	return visible and BOX.has_point(point)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = -1
		for i in keys.size():
			if _card_rect(i).has_point(event.position):
				_hover = i
		_hover_start = START_BTN.has_point(event.position)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if START_BTN.has_point(event.position):
			start_pressed.emit()
			accept_event()
			return
		for i in keys.size():
			if _card_rect(i).has_point(event.position):
				if keys[i] == selected and event.double_click:
					start_pressed.emit()
				else:
					picked.emit(keys[i])
				accept_event()
				return
		accept_event()


func _draw() -> void:
	if cfg.is_empty():
		return
	var font := ThemeDB.fallback_font
	# panel
	draw_rect(BOX, PANEL)
	draw_rect(BOX.grow(-0.5), TRIM, false, 1.0)
	draw_line(Vector2(BOX.position.x + 3, 41.5), Vector2(BOX.end.x - 3, 41.5), Color(TRIM, 0.6), 0.5)
	_text(font, "เลือกรูปขบวน", Vector2(BOX.position.x + 6, 39), 8, TRIM_HI)
	_text(font, "ลูกศร เลือก · คลิก/Enter เริ่มรบ", Vector2(BOX.end.x - 6, 39), 5.5, DIM, false)
	for i in keys.size():
		_draw_card(font, i)
	_draw_info(font)


func _draw_card(font: Font, i: int) -> void:
	var key: String = keys[i]
	var f: Dictionary = cfg.formations[key]
	var r := _card_rect(i)
	var sel := key == selected
	if sel:
		var glow := 0.35 + 0.2 * sin(_clock * 4.0)
		draw_rect(r.grow(1.5), Color(TRIM_HI, glow * 0.5))
	draw_rect(r, CARD_SEL if sel else CARD)
	var border := TRIM_HI if sel else (Color(TRIM, 1.0) if i == _hover else Color(TRIM, 0.45))
	draw_rect(r.grow(-0.5), border, false, 1.0)
	var dr := Rect2(r.position + Vector2(2, 2), Vector2(r.size.x - 4, 20))
	_draw_diagram(f, dr, sel)
	_text(font, str(f.get("label", key)), Vector2(r.position.x, r.end.y - 3), 7, TEXT if sel else DIM, true, r.size.x, true)


## World spot -> point in the diagram rect.
func _to_diag(dr: Rect2, x: float, y: float) -> Vector2:
	var tx := (x - WORLD_X.x) / (WORLD_X.y - WORLD_X.x)
	var ty := (y - WORLD_Y.x) / (WORLD_Y.y - WORLD_Y.x)
	return dr.position + Vector2(clampf(tx, 0, 1) * dr.size.x, clampf(ty, 0, 1) * dr.size.y)


func _group_colour(gid: int) -> Color:
	match gid:
		BattleSim.GROUP_GUARD:
			return GUARD_COL
		BattleSim.GROUP_RAID:
			return RAID_COL
	if gid >= BattleSim.GROUP_DIV:
		# divisions: front one brightest
		var k := gid - BattleSim.GROUP_DIV
		return troop_col.lerp(Color(0.25, 0.3, 0.25), 0.18 * k)
	return troop_col


func _draw_diagram(f: Dictionary, dr: Rect2, sel: bool) -> void:
	draw_rect(dr, FIELD)
	# lane lines (3 lanes, like the field)
	var lanes := int(cfg.get("lanes", {}).get("count", 0))
	var fy0 := float(cfg.field.y_min)
	var fy1 := float(cfg.field.y_max)
	for k in range(1, lanes):
		var ly := fy0 + (fy1 - fy0) * k / lanes
		var p := _to_diag(dr, WORLD_X.x, ly)
		draw_line(Vector2(dr.position.x, p.y), Vector2(dr.end.x, p.y), FIELD_LANE, 0.5)
	# general
	var gs: Array = cfg.sides[0].get("general_spot", [40, 176])
	var gp := _to_diag(dr, float(gs[0]), float(gs[1]))
	# troops
	var a := 1.0 if sel else 0.8
	for s in BattleSim.formation_spots(f, 30):
		var c := _group_colour(int(s[0]))
		draw_circle(_to_diag(dr, float(s[1]), float(s[2])), 0.95, Color(c, a))
	draw_colored_polygon(PackedVector2Array([gp + Vector2(0, -2.2), gp + Vector2(1.6, 0), gp + Vector2(0, 2.2),
			gp + Vector2(-1.6, 0)]), GEN_COL)
	_draw_hint_arrows(f, dr)


## Little arrows for formations that move in their own way.
func _draw_hint_arrows(f: Dictionary, dr: Rect2) -> void:
	var col := Color(TEXT, 0.75)
	match str(f.get("command", "")):
		"disperse":
			var c := dr.position + Vector2(dr.size.x * 0.93, dr.size.y * 0.5)
			_arrow(c + Vector2(0, -1.5), c + Vector2(0, -7.5), col)
			_arrow(c + Vector2(0, 1.5), c + Vector2(0, 7.5), col)
		"raid":
			var y := dr.position.y + 1.5
			_arrow(Vector2(dr.position.x + dr.size.x * 0.62, y + 2.5), Vector2(dr.end.x - 2, y), Color(RAID_COL, 0.9))
			var y2 := dr.end.y - 1.5
			_arrow(Vector2(dr.position.x + dr.size.x * 0.62, y2 - 2.5), Vector2(dr.end.x - 2, y2), Color(RAID_COL, 0.9))
		"divrush":
			var c2 := dr.position + Vector2(dr.size.x * 0.86, dr.size.y * 0.5)
			_arrow(c2, c2 + Vector2(6, 0), col)
	if float(f.get("general_pull", 1)) < 0.5:  # wedge: straight at the general
		var c3 := dr.position + Vector2(dr.size.x * 0.9, dr.size.y * 0.5)
		_arrow(c3, c3 + Vector2(4.5, 0), col)


func _arrow(a: Vector2, b: Vector2, col: Color) -> void:
	draw_line(a, b, col, 0.75)
	var d := (b - a).normalized()
	var n := Vector2(-d.y, d.x)
	draw_colored_polygon(PackedVector2Array([b + d * 1.2, b - d * 1.3 + n * 1.3, b - d * 1.3 - n * 1.3]), col)


func _draw_info(font: Font) -> void:
	if selected == "" or not cfg.formations.has(selected):
		return
	var f: Dictionary = cfg.formations[selected]
	var x := INFO.position.x + 4
	var w := INFO.size.x - 8
	draw_rect(INFO, Color(0, 0, 0, 0.25))
	draw_rect(INFO.grow(-0.5), Color(TRIM, 0.5), false, 0.5)
	var y := INFO.position.y + 11
	_text(font, str(f.get("label", selected)), Vector2(x, y), 10, TRIM_HI)
	y += 8
	var role := str(f.get("role", ""))
	# the role without its key hints ("... · [E] ..."): the commands get their own lines
	var role_main := role.split("[")[0].strip_edges().trim_suffix("·").strip_edges()
	draw_multiline_string(font, Vector2(x, y), role_main, HORIZONTAL_ALIGNMENT_LEFT, w, 6, 2, DIM)
	y += 9 if font.get_string_size(role_main, HORIZONTAL_ALIGNMENT_LEFT, -1, 6).x <= w else 16
	# stat bars
	y = _stat_bar(font, "ตี", float(f.atk), true, x, y, w)
	y = _stat_bar(font, "รับดาเมจ", float(f.take), false, x, y, w)
	y = _stat_bar(font, "ความเร็ว", float(f.spd), true, x, y, w)
	y += 2
	# groups
	y = _groups_line(font, f, x, y, w)
	# commands
	for line in _command_lines(f):
		_text(font, line, Vector2(x, y + 5), 6, TEXT)
		y += 8
	# general
	# the general: style, then the specials wrapped to the panel width
	var lines: PackedStringArray = []
	if not specials_lines.is_empty():
		lines.append_array(_wrap(font, specials_lines[0], w, 5))
	y = maxf(y, START_BTN.position.y - 3 - 6.5 * lines.size())
	for line in lines:
		_text(font, line, Vector2(x, y + 5), 5, DIM)
		y += 6.5
	# start button
	var pulse := 0.5 + 0.5 * sin(_clock * 3.0)
	draw_rect(START_BTN, Color(0.22, 0.17, 0.08, 1.0) if _hover_start else Color(0.14, 0.11, 0.06, 1.0))
	draw_rect(START_BTN.grow(-0.5), TRIM_HI.lerp(Color.WHITE, 0.25 * pulse), false, 1.0)
	_text(font, "เริ่มรบ  [Enter]", Vector2(START_BTN.position.x, START_BTN.end.y - 3.5), 8, TEXT, true,
			START_BTN.size.x, true)


## "ตี  [====|==]  ×1.08": bar centred on ×1, green when better, red when worse.
func _stat_bar(font: Font, label: String, v: float, higher_good: bool, x: float, y: float, w: float) -> float:
	_text(font, label, Vector2(x, y + 5), 6, DIM)
	var bx := x + 34.0
	var bw := w - 34.0 - 24.0
	var bar := Rect2(bx, y + 1.5, bw, 4)
	draw_rect(bar, Color(1, 1, 1, 0.08))
	var mid := bx + bw * 0.5
	var k := clampf((v - 1.0) / 0.3, -1.0, 1.0)  # ±30% fills half the bar
	var better := (v > 1.0) == higher_good
	var col := DIM if is_equal_approx(v, 1.0) else (GOOD if better else BAD)
	if is_equal_approx(v, 1.0):
		draw_rect(Rect2(mid - 0.5, bar.position.y, 1, bar.size.y), DIM)
	else:
		var x0 := mid
		var x1 := mid + k * bw * 0.5
		draw_rect(Rect2(minf(x0, x1), bar.position.y, absf(x1 - x0), bar.size.y), col)
	draw_line(Vector2(mid, bar.position.y - 1), Vector2(mid, bar.end.y + 1), Color(1, 1, 1, 0.35), 0.5)
	_text(font, "×%s" % _num(v), Vector2(x, y + 5), 6, col if not is_equal_approx(v, 1.0) else TEXT, false, w)
	return y + 7.0


## Coloured chips: how the 30 troops are split between the groups.
func _groups_line(font: Font, f: Dictionary, x: float, y: float, w: float) -> float:
	var counts := {}
	var order: Array = []
	for s in BattleSim.formation_spots(f, 30):
		var gid := int(s[0])
		var key := "div" if gid >= BattleSim.GROUP_DIV else str(gid)
		if not counts.has(key):
			counts[key] = 0
			order.append([key, gid])
		counts[key] += 1
	if order.size() <= 1:
		_text(font, "ทั้งทัพเป็นกองเดียว", Vector2(x, y + 5), 6, DIM)
		return y + 8.0
	var cx := x
	for o in order:
		var key: String = o[0]
		var gid: int = o[1]
		var name := ""
		match key:
			"0":
				name = "บุก"
			"1":
				name = "คุ้มกัน"
			"2":
				name = "จู่โจม"
			"div":
				name = "กองรบ %d×%d" % [_div_count(f), counts[key] / maxi(1, _div_count(f))]
		var t := "%s %d" % [name, counts[key]] if key != "div" else name
		draw_rect(Rect2(cx, y + 1.5, 4, 4), _group_colour(gid))
		_text(font, t, Vector2(cx + 6, y + 5), 6, TEXT)
		cx += 6 + font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 6).x + 6
	return y + 9.0


## Greedy wrap on double spaces (Battle.gd joins the specials with two
## spaces, so each special stays whole); shown joined with " · ".
func _wrap(font: Font, t: String, w: float, size: int) -> PackedStringArray:
	var out: PackedStringArray = []
	var cur := ""
	for word in t.split("  "):
		var cand := word if cur == "" else cur + " · " + word
		if cur != "" and font.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > w:
			out.append(cur)
			cur = word
		else:
			cur = cand
	if cur != "":
		out.append(cur)
	return out


func _div_count(f: Dictionary) -> int:
	var n := 0
	for g in f.layout.get("groups", []):
		if str(g.role) == "div":
			n += 1
	return n


func _command_lines(f: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	match str(f.get("command", "")):
		"disperse":
			out.append("[E] แตกปีกขึ้นบน-ล่าง / รวมกลับ")
		"raid":
			out.append("[E] กองจู่โจมอ้อมขอบสนามไปตีแม่ทัพ")
		"divrush":
			out.append("[E] ส่งกองรบเข้าทีละกอง")
	var guard := float(f.get("guard_share", 0)) > 0.0
	for g in f.layout.get("groups", []):
		if str(g.role) == "guard":
			guard = true
	if guard:
		out.append("[R] กองคุ้มกันออกบุก / กลับ")
	if f.has("flank"):
		out.append("รุมเป้าเดียว %d ตัวขึ้นไป ตี ×%s" % [int(f.get("flank_min", 2)), _num(f.flank)])
	if f.has("leash"):
		out.append("ไม่ห่างแม่ทัพเกิน %d" % int(f.leash))
	if float(f.get("general_pull", 1)) < 0.5:
		out.append("พุ่งหาแม่ทัพศัตรู")
	elif f.has("envelop"):
		out.append("อ้อมบน-ล่างไปรุมแม่ทัพ")
	return out


## Text: left/right aligned in width w from x (or centred), 1 px shadow.
func _text(font: Font, t: String, pos: Vector2, size: float, col: Color, left := true, w := 0.0,
		centre := false) -> void:
	var fs := int(round(size))
	var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var x := pos.x
	if centre:
		x = pos.x + (w - tw) / 2.0
	elif not left:
		x = pos.x + w - tw if w > 0.0 else pos.x - tw
	draw_string(font, Vector2(x + 0.5, pos.y + 0.5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.7))
	draw_string(font, Vector2(x, pos.y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _num(v) -> String:
	return str(snappedf(float(v), 0.01))
