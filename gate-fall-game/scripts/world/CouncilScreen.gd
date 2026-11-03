## Council screen (ประชุมทัพ), every council.every_days like DF: a full-screen
## throne room. Layout as agreed with Art (2026-10-30, Design artifact
## "Gatefall ฉากบัลลังก์ประชุมทัพ", 1280x720 = this 320x180 screen x4):
##   top bar     crest · "ประชุมทัพ" · council / day · castle · reserve, castles
##   centre      the throne room: throne + king, pillars, side banners, carpet
##   left        realm report · prison (click a prisoner = aim "ชวน") · auto [F] · end [Enter]
##   bottom      "แม่ทัพเข้าเฝ้า": one card per general (click = select; the
##               selected one is lifted with a gold frame; away = dimmed)
##   right       the selected general: portrait, level, rank, race, loyalty ·
##               troop types of ITS race (locked ones show the rank needed;
##               switching = its one order) · troops −5 / +5 / เต็ม · orders
## All placeholders (portraits, the king on the throne) are drawn shapes until
## real art exists; swap them without moving the layout.
##
## Pure view: every button calls back into WorldMap (host), which changes the
## WorldSim and rebuilds this screen through _show_council().
extends Control

const PANEL_BG := Color("182240")
const PANEL_DARK := Color("0f1528")
const BAR_BG := Color("0a0f1e")
const COPPER := Color("b8743e")
const GOLD := Color("e8b25c")
const GOLD_HI := Color("f5d08a")
const TEXT := Color("ede4cf")
const DIM := Color("a9b3d3")
const FAINT := Color("8c95b4")
const LINE := Color("3a4a78")
const LINE_DIM := Color("26304f")
const WARN := Color("f2a0a0")
const OK := Color("8fd49b")
const WALL := Color("131a31")
const FLOOR := Color("0f1528")
const WINDOW := Color("22305a")
const PILLAR := Color("1b2445")
const PILLAR_EDGE := Color("232e55")
const CARPET := Color("5a1a26")
const THRONE := Color("4a301c")
const STEP_A := Color("2a2238")
const STEP_B := Color("241d30")
const SHAFT := Color(0.91, 0.70, 0.36, 0.07)

const TOP := Rect2(0, 0, 320, 16)
const LEFT_X := 4.0
const LEFT_W := 70.0
const RIGHT := Rect2(222, 20, 94, 157)
const CARDS := Rect2(4, 127, 214, 48)
const CARD_W := 40.0
const CARD_GAP := 3.0
const VOWELS := "เแโใไ★"

var host  # WorldMap: callbacks + side colours
var world  # WorldSim
var side := ""
var sel_id := ""  # selected general
var target_id := ""  # prisoner the "ชวน" order aims at
var warn := ""  # one-off line in the orders header ("ต้องเลื่อนเป็น…")

var _boxes: Array = []  # [rect, fill, border (alpha 0 = none), border width]
var _pips: Array = []  # [pos, filled]
var _faces: Array = []  # [rect, colour, initial, dashed colour]


func setup(h, w, s: String, sel: String, target: String, note: String) -> void:
	host = h
	world = w
	side = s
	sel_id = sel
	target_id = target
	warn = note
	position = Vector2.ZERO
	size = Vector2(320, 180)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


# --- building ------------------------------------------------------------------------

func _build() -> void:
	for c in get_children():
		c.queue_free()
	_boxes.clear()
	_pips.clear()
	_faces.clear()
	var gens: Array = world.generals_of(side)
	if world.get_general(sel_id) == null or world.get_general(sel_id).side != side:
		sel_id = ""
		for g in gens:  # first one that can take orders, else the first
			if world.can_draft(g):
				sel_id = g.id
				break
		if sel_id == "" and not gens.is_empty():
			sel_id = gens[0].id
	_build_top()
	_build_left()
	_build_cards(gens)
	var g = world.get_general(sel_id)
	if g != null:
		_build_right(g)
	queue_redraw()


func _build_top() -> void:
	var cap = _capital()
	_label("ประชุมทัพ", Rect2(16, 1, 60, 9), 6, GOLD_HI)
	_label("ครั้งที่ %d · วันที่ %d" % [world.councils_held, int(world.day) + 1], Rect2(16, 9, 70, 6), 3, DIM)
	_label("ท้องพระโรง · " + (str(cap.name) if cap != null else "ปราสาทหลวง"), Rect2(90, 4, 120, 8), 4, TEXT,
			HORIZONTAL_ALIGNMENT_CENTER)
	_chip("คลังทหาร", str(int(world.reserve[side])), Rect2(232, 3, 44, 10))
	_chip("ปราสาท", str(world.castles_of(side).size()), Rect2(279, 3, 37, 10))


func _chip(title: String, value: String, r: Rect2) -> void:
	_box(r, PANEL_BG, LINE)
	_label(title, Rect2(r.position + Vector2(2, 2), Vector2(r.size.x * 0.6, 6)), 3, DIM)
	_label(value, Rect2(r.position + Vector2(0, 1), Vector2(r.size.x - 2, 8)), 5, GOLD_HI,
			HORIZONTAL_ALIGNMENT_RIGHT)


func _build_left() -> void:
	# Realm report
	var r := Rect2(LEFT_X, 20, LEFT_W, 30)
	_box(r, PANEL_BG, COPPER)
	_label("รายงานแผ่นดิน", Rect2(r.position + Vector2(3, 1), Vector2(64, 7)), 4, GOLD_HI)
	var present := 0
	var free := 0
	for g in world.generals_of(side):
		if world.can_draft(g):
			present += 1
			if not world.acted.has(g.id):
				free += 1
	_row("ทหารเข้าคลังรอบนี้", "+%d" % world.income_of(side), r.position.y + 9, OK)
	_row("ศัตรูถูกจับในคุก", str(world.prisoners_of(side).size()), r.position.y + 15, TEXT)
	_row("แม่ทัพที่สั่งได้", "%d / %d" % [free, present], r.position.y + 21, TEXT)
	# Prison
	var pr := Rect2(LEFT_X, 53, LEFT_W, 30)
	_box(pr, PANEL_BG, COPPER)
	var prisoners: Array = world.prisoners_of(side)
	_label("คุกหลวง · เชลย %d" % prisoners.size(), Rect2(pr.position + Vector2(3, 1), Vector2(64, 7)), 4, GOLD_HI)
	if prisoners.is_empty():
		_label("ไม่มีเชลย", Rect2(pr.position + Vector2(3, 11), Vector2(64, 6)), 3, FAINT)
	var y := pr.position.y + 9
	for i in mini(prisoners.size(), 2):
		var p = prisoners[i]
		var rr := Rect2(LEFT_X + 2, y, LEFT_W - 4, 10)
		if p.id == target_id:
			_box(rr, Color("2a3a6a"), GOLD)
		_face(Rect2(rr.position + Vector2(1, 1), Vector2(8, 8)), p)
		_label(("▶" if p.id == target_id else "") + p.name + " Lv%d" % p.level,
				Rect2(rr.position + Vector2(11, 0), Vector2(55, 5)), 3, TEXT)
		var note := "ไม่ยอมเข้าร่วม" if p.king else ("ลองแล้วรอบนี้" if world.tried.has(p.id) else
				"ขัง %d การประชุม" % p.captive_councils)
		_label(note, Rect2(rr.position + Vector2(11, 5), Vector2(55, 5)), 3, FAINT if p.king else OK)
		_hit(rr, host._council_pick.bind(p.id), not p.king)
		y += 11
	if prisoners.size() > 2:
		_label("+%d คน" % (prisoners.size() - 2), Rect2(LEFT_X + 3, 76, 60, 5), 3, FAINT)
	# Our generals the enemy holds
	var taken := PackedStringArray()
	for p in world.prisoners_of("K" if side == "S" else "S"):
		taken.append(p.name)
	if not taken.is_empty():
		_label("ถูกจับ: " + ", ".join(taken), Rect2(LEFT_X, 84, LEFT_W, 5), 3, WARN)
	_button("แจกอัตโนมัติ [F]", Rect2(LEFT_X, 90, LEFT_W, 10), host._council_auto,
			int(world.reserve[side]) > 0, false)
	_button("จบการประชุม [Enter]", Rect2(LEFT_X, 102, LEFT_W, 12), host._end_council, true, true)


func _row(title: String, value: String, y: float, col: Color) -> void:
	_label(title, Rect2(LEFT_X + 3, y, 46, 6), 3, DIM)
	_label(value, Rect2(LEFT_X + 46, y, LEFT_W - 49, 6), 3, col, HORIZONTAL_ALIGNMENT_RIGHT)


func _build_cards(gens: Array) -> void:
	_label("แม่ทัพเข้าเฝ้า", Rect2(CARDS.position.x, 117, 80, 7), 4, GOLD_HI)
	_label("คลิกการ์ดเพื่อสั่งงาน · คนละ 1 คำสั่ง", Rect2(110, 118, 108, 6), 3, DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	var n := gens.size()
	var w := minf(CARD_W, (CARDS.size.x - CARD_GAP * (n - 1)) / maxf(1.0, n))
	for i in n:
		var g = gens[i]
		var selected: bool = g.id == sel_id
		var home: bool = world.can_draft(g)
		var r := Rect2(CARDS.position.x + i * (w + CARD_GAP), CARDS.position.y - (3.0 if selected else 0.0), w,
				CARDS.size.y)
		var race_col: Color = host._side_col(g.origin if g.origin != "" else g.side)
		_box(r, PANEL_BG if home else PANEL_DARK, GOLD_HI if selected else LINE, 1.0)
		_box(Rect2(r.position, Vector2(w, 1)), race_col, Color(0, 0, 0, 0))
		_face(Rect2(r.position + Vector2(2, 3), Vector2(16, 16)), g)
		var race: String = _race_label(g) + (" ·ชวนมา" if g.origin != "" and g.origin != g.side else "")
		_label(race, Rect2(r.position + Vector2(19, 3), Vector2(w - 20, 5)), 3, race_col)
		_label("Lv%d" % g.level, Rect2(r.position + Vector2(19, 8), Vector2(w - 20, 5)), 3, DIM)
		_label(world.rank_name(g), Rect2(r.position + Vector2(19, 13), Vector2(w - 20, 5)), 3, DIM)
		_label(("★" if g.king else "") + g.name, Rect2(r.position + Vector2(2, 20), Vector2(w - 4, 7)), 4,
				TEXT if home else FAINT)
		var cap: int = world.max_troops_of(g)
		_label(world.troop_label(g), Rect2(r.position + Vector2(2, 27), Vector2(w - 16, 5)), 3,
				TEXT if home else FAINT)
		_label("%d/%d" % [int(g.troops), cap], Rect2(r.position + Vector2(w - 16, 27), Vector2(14, 5)), 3, GOLD_HI,
				HORIZONTAL_ALIGNMENT_RIGHT)
		_bar(Rect2(r.position + Vector2(2, 33), Vector2(w - 4, 2)), float(g.troops) / maxf(1.0, cap), race_col)
		var stamp := "ยังไม่ได้สั่ง"
		var stamp_col := DIM
		var stamp_bg := PANEL_DARK
		if not home:
			stamp = _where(g)
			stamp_col = FAINT
		elif world.acted.has(g.id):
			stamp = _done_text(g)
			stamp_col = Color("1b1206")
			stamp_bg = COPPER
		var sr := Rect2(r.position + Vector2(2, 38), Vector2(w - 4, 7))
		_box(sr, stamp_bg, LINE if stamp_bg == PANEL_DARK else GOLD_HI)
		_label(stamp, sr, 3, stamp_col, HORIZONTAL_ALIGNMENT_CENTER)
		_hit(r, host._council_select.bind(g.id), true)


func _build_right(g) -> void:
	var r := RIGHT
	_box(r, PANEL_BG, COPPER)
	var x := r.position.x + 4
	var home: bool = world.can_draft(g)
	var race_col: Color = host._side_col(g.origin if g.origin != "" else g.side)
	# Who
	_face(Rect2(x, r.position.y + 4, 32, 32), g)
	_label(("★" if g.king else "") + g.name, Rect2(x + 35, r.position.y + 3, 52, 9), 6, GOLD_HI)
	_label("Lv%d · %s" % [g.level, world.rank_name(g)], Rect2(x + 35, r.position.y + 12, 52, 6), 3, TEXT)
	var tag: String = _race_label(g) + (" · ชวนมาจากฝ่ายศัตรู" if g.origin != "" and g.origin != g.side else "")
	_box(Rect2(x + 35, r.position.y + 19, 52, 6), race_col, Color(0, 0, 0, 0))
	_label(tag, Rect2(x + 36, r.position.y + 19, 50, 6), 3, Color.WHITE)
	_label("ความภักดี", Rect2(x + 35, r.position.y + 26, 30, 5), 3, DIM)
	_label(str(g.loyalty), Rect2(x + 65, r.position.y + 26, 22, 5), 3, DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	_bar(Rect2(x + 35, r.position.y + 32, 52, 2), g.loyalty / 100.0, GOLD)
	# Troop types (its race only)
	var ty := r.position.y + 39
	_label("ชนิดทหาร", Rect2(x, ty, 30, 7), 4, TEXT)
	_label("เลือกได้เฉพาะทหารเผ่า" + _race_label(g), Rect2(x + 28, ty + 1, 58, 5), 3, DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	var choices: Array = world.troop_choices(g)
	var cur: String = world.unit_of(g)
	var tw := 27.0
	for i in choices.size():
		var t: Dictionary = choices[i]
		var tr := Rect2(x + i * (tw + 2), ty + 8, tw, 40)
		var current := str(t.unit) == cur
		var locked := not bool(t.unlocked)
		_box(tr, Color("2a3a6a") if current else (Color("121a30") if locked else PANEL_DARK),
				GOLD_HI if current else (LINE_DIM if locked else LINE))
		var sp := Rect2(tr.position + Vector2((tw - 14) / 2.0, 2), Vector2(14, 14))
		_box(sp, Color("1a2138") if locked else race_col.darkened(0.55), race_col if not locked else LINE)
		_label("ล็อก" if locked else _initial(str(t.get("label", ""))), sp, 3 if locked else 6,
				FAINT if locked else TEXT, HORIZONTAL_ALIGNMENT_CENTER)
		_label(str(t.get("label", t.unit)), Rect2(tr.position + Vector2(1, 16), Vector2(tw - 2, 6)), 3,
				FAINT if locked else TEXT, HORIZONTAL_ALIGNMENT_CENTER)
		var pips: Array = t.get("pips", [])
		var names := ["ตี", "ทน", "ระยะ", "เร็ว"]
		for k in mini(pips.size(), 4):
			var py := tr.position.y + 22 + k * 3
			_label(names[k], Rect2(tr.position.x + 1, py - 1, 9, 4), 3, DIM)
			for j in 5:
				_pips.append([Vector2(tr.position.x + 11 + j * 3, py), j < int(pips[k])])
		var foot := "ใช้อยู่" if current else ("ยศ" + _rank_name(int(t.get("rank", 0))) if locked else "เปลี่ยน")
		_label(foot, Rect2(tr.position + Vector2(1, 34), Vector2(tw - 2, 5)), 3,
				GOLD_HI if current else (FAINT if locked else DIM), HORIZONTAL_ALIGNMENT_CENTER)
		if locked:
			_hit(tr, host._council_note.bind("ต้องเลื่อนเป็น%sก่อน" % _rank_name(int(t.get("rank", 0)))), true)
		elif not current:
			_hit(tr, host._council_troops.bind(g.id, str(t.unit)), true)
	if choices.is_empty():
		_label("เผ่านี้ยังไม่มีชุดทหาร", Rect2(x, ty + 20, 86, 6), 3, FAINT)
	var desc := ""
	for t in choices:
		if str(t.unit) == cur:
			desc = str(t.get("label", "")) + " · " + str(t.get("desc", ""))
	_label(desc, Rect2(x, ty + 49, 86, 6), 3, TEXT)
	# Troops
	var cap: int = world.max_troops_of(g)
	var my := r.position.y + 96
	_label("จำนวนทหาร", Rect2(x, my, 40, 7), 4, TEXT)
	_label("%d / %d" % [int(g.troops), cap], Rect2(x + 46, my + 1, 40, 6), 4, GOLD_HI, HORIZONTAL_ALIGNMENT_RIGHT)
	var step := int(world.council_cfg.get("step", 5))
	var res := int(world.reserve[side])
	_button("−%d" % step, Rect2(x, my + 8, 15, 10), host._council_draft.bind(g.id, -step), home and g.troops >= 1,
			false)
	_box(Rect2(x + 17, my + 11, 37, 4), BAR_BG, LINE)
	_bar(Rect2(x + 17, my + 11, 37, 4), float(g.troops) / maxf(1.0, cap), race_col)
	_button("+%d" % step, Rect2(x + 56, my + 8, 15, 10), host._council_draft.bind(g.id, step),
			home and g.troops < cap and res > 0, false)
	_button("เต็ม", Rect2(x + 73, my + 8, 13, 10), host._council_draft.bind(g.id, cap),
			home and g.troops < cap and res > 0, false)
	# Orders: one per council
	var oy := r.position.y + 117
	_label("คำสั่ง", Rect2(x, oy, 30, 7), 4, TEXT)
	var status := "เหลือ 1 คำสั่ง"
	var scol := OK
	if not home:
		status = _where(g)
		scol = FAINT
	elif world.acted.has(g.id):
		status = _done_text(g)
		scol = GOLD_HI
	if warn != "":
		status = warn
		scol = WARN
	_label(status, Rect2(x + 22, oy + 1, 64, 6), 3, scol, HORIZONTAL_ALIGNMENT_RIGHT)
	var can: bool = world.can_act(g)
	var orders := []
	orders.append(["เกณฑ์ทหาร", "+%d เข้าคลัง" % world.levy_amount(), host._council_levy.bind(g.id),
			can and world.levy_amount() > 0])
	var tgt = world.get_general(target_id)
	if tgt != null and tgt.state == "captured" and tgt.held_by == side:
		var c: float = world.recruit_chance(tgt, g)
		orders.append(["ชวน" + tgt.name, "โอกาส ~%d%%" % int(roundf(c * 100.0)),
				host._council_persuade.bind(g.id, tgt.id), can and c > 0.0])
	else:
		orders.append(["ชวนเชลย", "ไม่มีเชลยให้ชวน", Callable(), false])
	var wall := int(world.castles[g.castle].wall) if g.castle != "" else 0
	orders.append(["สร้างกำแพง", "ก.%d → ก.%d" % [wall, mini(wall + 1, world.wall_max())],
			host._council_fortify.bind(g.id), world.can_fortify(g)])
	if bool(world.siege_cfg.get("engines", true)):
		orders.append(["เครื่องตีกำแพง", "ลากไปตีเมือง", host._council_engine.bind(g.id), world.can_build_engine(g)])
	var need: int = world.next_rank_level(g)
	if not g.king and need > 0:
		orders.append(["เลื่อนยศ → " + _rank_name(g.rank + 1),
				"คำสั่งกษัตริย์" if g.level >= need else "ต้อง Lv%d" % need,
				host._council_promote.bind(g.id), world.can_promote(g)])
	for i in orders.size():
		var o: Array = orders[i]
		var orr := Rect2(x + (i % 2) * 44, oy + 8 + (i / 2) * 11, 42, 10)
		_order(orr, o[0], o[1], o[2], o[3])


# --- small builders ------------------------------------------------------------------

func _label(t: String, r: Rect2, sz: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = t
	l.position = r.position
	l.size = r.size
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	l.add_theme_constant_override("line_spacing", 0)
	add_child(l)
	return l


## Invisible click area over something drawn (a card, a tile, a prisoner).
func _hit(r: Rect2, cb: Callable, enabled: bool) -> void:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.position = r.position
	b.size = r.size
	b.disabled = not enabled
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(st, empty)
	if enabled and cb.is_valid():
		b.pressed.connect(cb)
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	add_child(b)


func _button(t: String, r: Rect2, cb: Callable, enabled: bool, primary: bool) -> void:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_NONE
	b.position = r.position
	b.size = r.size
	b.clip_text = true
	b.disabled = not enabled
	b.add_theme_font_size_override("font_size", 4 if primary else 3)
	var fg := Color("1b1206") if primary else TEXT
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)
	b.add_theme_color_override("font_disabled_color", FAINT)
	for st in ["normal", "hover", "pressed", "disabled"]:
		var bs := StyleBoxFlat.new()
		if primary:
			bs.bg_color = {"normal": COPPER, "hover": COPPER.lightened(0.15), "pressed": COPPER.darkened(0.2),
					"disabled": PANEL_DARK}[st]
			bs.border_color = GOLD_HI
		else:
			bs.bg_color = {"normal": PANEL_DARK, "hover": Color("22305a"), "pressed": Color("2a3a6a"),
					"disabled": Color("121a30")}[st]
			bs.border_color = LINE if st != "disabled" else LINE_DIM
		bs.set_border_width_all(1)
		bs.set_content_margin_all(0)
		b.add_theme_stylebox_override(st, bs)
	if cb.is_valid():
		b.pressed.connect(cb)
	add_child(b)


## An order button: title on top, a small grey line under it.
func _order(r: Rect2, title: String, sub: String, cb: Callable, enabled: bool) -> void:
	_box(r, PANEL_DARK if enabled else Color("121a30"), LINE if enabled else LINE_DIM)
	_label(title, Rect2(r.position + Vector2(2, 0), Vector2(r.size.x - 3, 5)), 3, TEXT if enabled else FAINT)
	_label(sub, Rect2(r.position + Vector2(2, 5), Vector2(r.size.x - 3, 5)), 3, DIM if enabled else FAINT)
	_hit(r, cb, enabled)


func _box(r: Rect2, fill: Color, border: Color, width := 1.0) -> void:
	_boxes.append([r, fill, border, width])


func _bar(r: Rect2, k: float, col: Color) -> void:
	_boxes.append([r, BAR_BG, Color(0, 0, 0, 0), 1.0])
	_boxes.append([Rect2(r.position, Vector2(r.size.x * clampf(k, 0.0, 1.0), r.size.y)), col, Color(0, 0, 0, 0), 1.0])


## Placeholder portrait: race-coloured square, dashed edge, first letter.
func _face(r: Rect2, g) -> void:
	var col: Color = host._side_col(g.origin if g.origin != "" else g.side)
	_faces.append([r, col])
	_label(_initial(g.name), r, int(clampf(r.size.y * 0.55, 4, 18)), TEXT, HORIZONTAL_ALIGNMENT_CENTER)


# --- text helpers ---------------------------------------------------------------------

func _initial(t: String) -> String:
	for i in t.length():
		var ch := t.substr(i, 1)
		if not VOWELS.contains(ch):
			return ch
	return "?"


func _race_label(g) -> String:
	var sides: Dictionary = world.data.get("sides", {})
	return str(sides.get(g.origin if g.origin != "" else g.side, {}).get("label", ""))


func _rank_name(i: int) -> String:
	var names: Array = world.rank_cfg.get("names", [])
	return str(names[i]) if i >= 0 and i < names.size() else "?"


func _where(g) -> String:
	if g.state == "moving":
		return "เดินทางอยู่"
	if g.state == "battle":
		return "กำลังรบ"
	return "นอกปราสาท"


func _done_text(g) -> String:
	var what := str(world.acted.get(g.id, ""))
	if what == "troops":
		return "เปลี่ยนเป็น" + world.troop_label(g)
	return {"levy": "เกณฑ์แล้ว", "persuade_ok": "ชวนสำเร็จ", "persuade_fail": "ชวนไม่สำเร็จ",
			"joined": "เพิ่งเข้าร่วม", "fortify": "สร้างกำแพงแล้ว", "engine": "สร้างเครื่องตีแล้ว",
			"promote": "ปูนบำเหน็จแล้ว"}.get(what, "สั่งแล้ว")


func _capital():
	for cid in world.castles:
		var c: Dictionary = world.castles[cid]
		if c.owner == side and bool(c.capital):
			return c
	var king = world.king_of(side)
	if king != null and king.castle != "":
		return world.castles[king.castle]
	return null


# --- drawing --------------------------------------------------------------------------

func _draw() -> void:
	_draw_hall()
	_draw_top_bar()
	for b in _boxes:
		var r: Rect2 = b[0]
		draw_rect(r, b[1])
		var border: Color = b[2]
		if border.a > 0.0:
			draw_rect(r, border, false, float(b[3]))
	for f in _faces:
		var r: Rect2 = f[0]
		var col: Color = f[1]
		draw_rect(r, col.darkened(0.6))
		_dashed_rect(r, col.lightened(0.3))
	for p in _pips:
		draw_rect(Rect2(p[0], Vector2(2, 2)), GOLD if p[1] else Color("2a3558"))


func _draw_top_bar() -> void:
	draw_rect(TOP, BAR_BG)
	draw_rect(Rect2(0, TOP.size.y - 1, TOP.size.x, 1), COPPER)
	var crest := Rect2(4, 3, 10, 10)
	var side_col: Color = host._side_col(side, true)
	draw_colored_polygon(PackedVector2Array([crest.position, crest.position + Vector2(10, 0),
			crest.position + Vector2(10, 6), crest.position + Vector2(5, 10), crest.position + Vector2(0, 6)]),
			side_col)
	_diamond(crest.position + Vector2(5, 4.5), 2.0, GOLD)


## The throne room behind the panels (centre x 148).
func _draw_hall() -> void:
	draw_rect(Rect2(0, 0, 320, 180), FLOOR)
	draw_rect(Rect2(0, 0, 320, 87), WALL)
	draw_rect(Rect2(0, 86, 320, 1), STEP_A)
	for wx in [85.0, 197.0]:
		draw_rect(Rect2(wx, 24, 14, 50), WINDOW)
		draw_circle(Vector2(wx + 7, 24), 7, WINDOW)
	draw_colored_polygon(PackedVector2Array([Vector2(87, 50), Vector2(96, 50), Vector2(135, 150), Vector2(110, 150)]),
			SHAFT)
	draw_colored_polygon(PackedVector2Array([Vector2(200, 50), Vector2(209, 50), Vector2(186, 150), Vector2(161, 150)]),
			SHAFT)
	for px in [107.0, 180.0]:
		draw_rect(Rect2(px, 16, 9, 71), PILLAR)
		draw_rect(Rect2(px, 16, 1, 71), PILLAR_EDGE)
		draw_rect(Rect2(px - 1, 16, 11, 3), PILLAR_EDGE)
	var banner: Color = host._side_col(side, true)
	for bx in [122.0, 164.0]:
		draw_colored_polygon(PackedVector2Array([Vector2(bx, 16), Vector2(bx + 10, 16), Vector2(bx + 10, 60),
				Vector2(bx + 5, 55), Vector2(bx, 60)]), banner)
		_diamond(Vector2(bx + 5, 32), 2.0, GOLD)
	# carpet with a copper trim, from the dais to the bottom edge
	draw_colored_polygon(PackedVector2Array([Vector2(139, 87), Vector2(157, 87), Vector2(196, 180), Vector2(100, 180)]),
			COPPER)
	draw_colored_polygon(PackedVector2Array([Vector2(141, 87), Vector2(155, 87), Vector2(193, 180), Vector2(103, 180)]),
			CARPET)
	# dais and throne
	draw_rect(Rect2(108, 81, 80, 6), STEP_B)
	draw_rect(Rect2(108, 81, 80, 1), Color("3a2e48"))
	draw_rect(Rect2(118, 75, 60, 6), STEP_A)
	draw_rect(Rect2(118, 75, 60, 1), Color("43355a"))
	draw_rect(Rect2(136, 45, 24, 30), THRONE)
	draw_circle(Vector2(148, 45), 12, THRONE)
	draw_arc(Vector2(148, 45), 12, PI, TAU, 16, COPPER, 1.0)
	draw_rect(Rect2(136, 45, 1, 30), COPPER)
	draw_rect(Rect2(159, 45, 1, 30), COPPER)
	# the king on the throne (placeholder until a sitting portrait exists)
	var king = world.king_of(side)
	var kc: Color = host._side_col(side)
	draw_rect(Rect2(142, 58, 12, 16), kc.darkened(0.35))
	draw_circle(Vector2(148, 54), 4, Color("e8c9a0"))
	draw_colored_polygon(PackedVector2Array([Vector2(144, 50), Vector2(145, 47), Vector2(146.5, 49), Vector2(148, 46),
			Vector2(149.5, 49), Vector2(151, 47), Vector2(152, 50)]), GOLD)
	if king == null or king.castle == "" or world.castles[king.castle].owner != side:
		draw_rect(Rect2(136, 45, 24, 30), Color(0, 0, 0, 0.5))  # the king is away (or captured)


func _diamond(c: Vector2, r: float, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r),
			c + Vector2(-r, 0)]), col)


func _dashed_rect(r: Rect2, col: Color) -> void:
	var pts := [r.position, r.position + Vector2(r.size.x, 0), r.end, r.position + Vector2(0, r.size.y)]
	for i in 4:
		draw_dashed_line(pts[i], pts[(i + 1) % 4], col, 0.5, 2.0)
