## World map scene (real time, like DF): castles joined by roads, generals walk
## them while the days tick by. Draws the map and HUD itself (same panel style
## as the battle HUD) and drives WorldSim, which lives in the Campaign autoload
## so the war carries on after a battle.
##
## Mouse (like DF: pick one general, give one order):
##   the roster along the bottom lists all your generals: click a name =
##     select it (click again = deselect); a banner on the map works too
##   with a general selected, click any castle = march there (path shown
##     while hovering); the order deselects it, so the next click picks again
##   click a castle with your generals and nobody selected = select the first
##     there (click again = the next one) · right-click = deselect
## Keys:
##   Space = pause / go on · 1 / 2 / 3 = speed ×1 / ×2 / ×4
##   Tab = next of your generals · Esc = deselect
##   when a battle starts: Enter = fight it yourself · A = auto-resolve
##
## Marching armies are drawn with the battle sprite of their troops (a slime
## army walks as slimes, a human army as knights), with a ring in the side
## colour at the feet and a few troops walking behind when the army is big
## (world_map.json "map_sprites"). Generals standing in a castle are flags.
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
const PAUSE_HIT := Rect2(194, 0, 46, 12)  # "หยุด [Space]" / "×1" on the top bar: click = pause / go on

var world: WorldSim = null
var data: Dictionary
var side_cfg: Dictionary
var selected := ""  # general id
var hover_castle := ""
var hover_chip := ""  # general id under the mouse in the roster
var paused := false
var speed_i := 0
var log_lines: Array[String] = []

var _clock := 0.0
var _decor: Array = []  # [pos, kind] map texture (trees / hills), made once
var _battle_cfg: Dictionary
var _ui: CanvasLayer
var _popup: PanelContainer = null
var _popup_battle := -1
var _map_sprites := {}  # sprite id -> {anims: {name: {tex, frames, fps}}, w, h, foot, height}
var _facing := {}  # general id -> -1 (left) / 1 (right): kept while it stands to fight
var _in_council := false  # the council window is open (the popup is the council)
var _council_target := ""  # prisoner id the "ชวน" buttons in the council aim at


func _ready() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 5
	add_child(_ui)
	_battle_cfg = BattleSim.load_config("res://data/battle_config.json")
	_load_map_sprites()
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
	# Back from a battle: time goes on at once (it used to wait for Space, which
	# looked like the map had frozen). Space / the clock label still pause.
	paused = false
	_log("กลับจากสนามรบ")
	for e in world._take_events():
		_on_event(e)
	_check_battles()


func _bind(w: WorldSim) -> void:
	world = w
	data = w.data
	side_cfg = data.sides
	_make_decor()


func _process(delta: float) -> void:
	_clock += delta
	if world != null and not paused and _popup == null and world.winner == "":
		var speeds: Array = data.time.speeds
		var days := delta / float(data.time.day_seconds) * float(speeds[speed_i])
		for e in world.step(days):
			_on_event(e)
		_check_battles()
	var mp := get_local_mouse_position()
	hover_chip = ""
	if world != null:
		for c in _roster():
			if c.rect.has_point(mp):
				hover_chip = c.id
	hover_castle = "" if mp.y >= BOTTOM_BAR.position.y or mp.y < TOP_BAR.end.y else _castle_at(mp)
	queue_redraw()


# --- input ----------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if world == null:
		return
	if event is InputEventMouseButton and event.pressed:
		if _popup != null:
			return
		var p := get_local_mouse_position()
		if event.button_index == MOUSE_BUTTON_LEFT and PAUSE_HIT.has_point(p):
			paused = not paused
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			selected = ""
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_click(p)
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Physical key position, so 1/2/3/A work with a Thai (or any) layout too.
	var k: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if _popup != null:
		if _popup_battle >= 0:
			match k:
				KEY_ENTER, KEY_KP_ENTER:
					_fight(_popup_battle)
				KEY_A:
					_auto(_popup_battle)
		elif _in_council:
			match k:
				KEY_ENTER, KEY_KP_ENTER:
					_end_council()
				KEY_F:
					_council_auto()
		elif world.winner != "" and k in [KEY_ENTER, KEY_KP_ENTER]:
			_restart()
		return
	match k:
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
	# Roster along the bottom.
	for c in _roster():
		if c.rect.has_point(p):
			selected = "" if selected == c.id else c.id
			return
	if p.y >= BOTTOM_BAR.position.y or p.y < TOP_BAR.end.y:
		return
	var g := world.get_general(selected)
	var cid := _castle_at(p)
	# Banners on the map (only when no castle order is meant).
	if g == null or cid == "":
		for t in _tokens():
			if t.rect.grow(2.0).has_point(p):
				var tg := world.get_general(t.id)
				if tg.side == Campaign.player_side:
					selected = tg.id
					return
	if cid == "":
		return
	if g != null and g.state in ["idle", "moving"] and not (g.state == "idle" and g.castle == cid):
		if world.order_move(g, cid):
			_log("%s เดินทัพไป %s" % [g.name, world.castles[cid].name])
			selected = ""  # one order per pick, like DF
		return
	_select_next(cid)


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
			_log("%s ถูกจับเป็นเชลย!" % who if mine else "จับ %s เป็นเชลยได้" % who, mine)
			if selected == g.id:
				selected = ""
		"recruited":
			# g has already changed side: mine = it joined us.
			var by := world.get_general(str(e.by))
			if mine:
				_log("%s ยอมเข้าร่วมฝ่ายเรา! (%s ชวน)" % [who, by.name if by != null else ""])
			else:
				_log("%s ของเราถูกชวนไปเข้าฝ่ายศัตรู" % who, true)
		"refused":
			if g != null and g.held_by == Campaign.player_side:
				_log("%s ไม่ยอมเข้าร่วม" % who)
		"arrive":
			if mine:
				_log("%s ถึง %s" % [who, world.castles[e.castle].name])
		"council":
			var inc: Dictionary = e.income
			_log("ประชุมทัพครั้งที่ %d · คลังทหาร +%d" % [e.number, int(inc.get(Campaign.player_side, 0))])
		"over":
			_show_end(e.winner)


func _check_battles() -> void:
	if _popup == null and world.winner == "" and world.battles.is_empty() \
			and world.council.has(Campaign.player_side):
		_show_council()
		return
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
	world.resolve_battle(id, res.winner, res.left, res.fell)
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
	_in_council = false


# --- council (every council.every_days, like DF) ------------------------------------
# The map stops; troops come into the reserve and are handed to generals standing
# in our own castles. Others (walking, fighting, in a castle that is not ours)
# cannot take any this time.

func _show_council() -> void:
	_close_popup()
	_in_council = true
	var side := Campaign.player_side
	var prisoners := world.prisoners_of(side)
	# Keep the aimed-at prisoner while it is still ours to ask; else the first
	# one who can still be asked this council.
	var target := world.get_general(_council_target)
	if target == null or target.state != "captured" or target.held_by != side:
		_council_target = ""
		for p in prisoners:
			if not p.king and not world.tried.has(p.id):
				_council_target = p.id
				break
		if _council_target == "" and not prisoners.is_empty():
			_council_target = prisoners[0].id
	target = world.get_general(_council_target)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.11, 0.95)
	sb.border_color = TRIM_HI
	sb.set_border_width_all(1)
	sb.set_content_margin_all(5)
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)
	_council_label(box, "ประชุมทัพ ครั้งที่ %d · วันที่ %d" % [world.councils_held, int(world.day) + 1], 9, TRIM_HI,
			true)
	var n_castles := world.castles_of(side).size()
	_council_label(box, "คลังทหาร %d   (เดือนนี้ได้ +%d จาก %d ปราสาท)" % [int(world.reserve[side]),
			world.income_of(side), n_castles], 8, TEXT, true)
	var grid := GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 2)
	box.add_child(grid)
	var cap := int(world.rules.max_troops)
	var step := int(world.council_cfg.get("step", 5))
	for g in world.generals_of(side):
		var ok := world.can_draft(g)
		_council_label(grid, ("★" if g.king else "") + g.name, 7, TEXT if ok else DIM, false)
		var where: String = world.castles[g.castle].name if ok else ("เดินทาง" if g.state == "moving" else
				("กำลังรบ" if g.state == "battle" else "นอกปราสาท"))
		_council_label(grid, where, 7, DIM, false)
		_council_label(grid, "%d/%d" % [int(g.troops), cap], 7, TEXT if ok else DIM, false)
		_council_button(grid, "−%d" % step, _council_draft.bind(g.id, -step), ok and g.troops >= 1)
		_council_button(grid, "+%d" % step, _council_draft.bind(g.id, step),
				ok and g.troops < cap and int(world.reserve[side]) > 0)
		_council_button(grid, "เต็ม", _council_draft.bind(g.id, cap),
				ok and g.troops < cap and int(world.reserve[side]) > 0)
		_council_action_cell(grid, g, target)
	# Prisoners we hold: click one to aim the "ชวน" buttons at it.
	if not prisoners.is_empty():
		var prow := HBoxContainer.new()
		prow.alignment = BoxContainer.ALIGNMENT_CENTER
		prow.add_theme_constant_override("separation", 3)
		box.add_child(prow)
		_council_label(prow, "เชลย:", 7, TRIM_HI, false)
		for p in prisoners:
			var t := ("▶" if p.id == _council_target else "") + ("★" if p.king else "") + p.name
			if p.king:
				t += " (ไม่ยอม)"
			elif world.tried.has(p.id):
				t += " (ลองแล้ว)"
			_council_button(prow, t, _council_pick.bind(p.id), not p.king)
	var taken := PackedStringArray()
	for p in world.prisoners_of(WorldSim.other_side(side)):
		taken.append(p.name)
	if not taken.is_empty():
		_council_label(box, "แม่ทัพเราที่ถูกจับ: " + ", ".join(taken), 7, ALERT, true)
	_council_label(box, "แม่ทัพในปราสาทเรา: แจกทหารได้ · สั่งงานได้คนละ 1 อย่าง", 7, DIM, true)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	_council_button(row, "แจกอัตโนมัติ [F]", _council_auto, int(world.reserve[side]) > 0)
	_council_button(row, "จบการประชุม [Enter]", _end_council, true)
	_ui.add_child(panel)
	panel.reset_size()
	panel.position = ((SCREEN - panel.size) / 2.0).round()
	_popup = panel


## Last column of a general's row: its one action this council (levy, or
## persuade the aimed-at prisoner), or what it already did.
func _council_action_cell(grid: GridContainer, g, target) -> void:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 2)
	grid.add_child(cell)
	if not world.can_draft(g):
		_council_label(cell, "–", 7, DIM, false)
		return
	if world.acted.has(g.id):
		var what := str(world.acted[g.id])
		var done: String = {"levy": "เกณฑ์แล้ว", "persuade_ok": "ชวนสำเร็จ", "persuade_fail": "ชวนไม่สำเร็จ",
				"joined": "เพิ่งเข้าร่วม"}.get(what, "สั่งแล้ว")
		_council_label(cell, done, 7, TRIM_HI if what == "persuade_ok" else DIM, false)
		return
	_council_button(cell, "เกณฑ์ +%d" % world.levy_amount(), _council_levy.bind(g.id), world.levy_amount() > 0)
	if target != null:
		var c: float = world.recruit_chance(target, g)
		_council_button(cell, "ชวน %d%%" % int(roundf(c * 100.0)), _council_persuade.bind(g.id, target.id), c > 0.0)


func _council_label(parent: Control, t: String, size: int, col: Color, centre: bool) -> void:
	var l := Label.new()
	l.text = t
	if centre:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	parent.add_child(l)


func _council_button(parent: Control, t: String, cb: Callable, enabled: bool) -> void:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_NONE
	b.disabled = not enabled
	b.add_theme_font_size_override("font_size", 7)
	# Compact buttons so 6 generals still fit on the 320x180 screen.
	for st in ["normal", "hover", "pressed", "disabled"]:
		var bs := StyleBoxFlat.new()
		bs.bg_color = {"normal": Color(0.14, 0.15, 0.24), "hover": Color(0.22, 0.24, 0.36),
				"pressed": Color(0.3, 0.26, 0.16), "disabled": Color(0.08, 0.09, 0.13)}[st]
		bs.border_color = TRIM if st != "disabled" else Color(0.25, 0.25, 0.3)
		bs.set_border_width_all(1)
		bs.content_margin_left = 3
		bs.content_margin_right = 3
		bs.content_margin_top = 0
		bs.content_margin_bottom = 0
		b.add_theme_stylebox_override(st, bs)
	b.pressed.connect(cb)
	parent.add_child(b)


func _council_draft(gid: String, n: int) -> void:
	world.draft(world.get_general(gid), n)
	_show_council()


## Action: the general raises troops into the reserve.
func _council_levy(gid: String) -> void:
	var g := world.get_general(gid)
	var n := world.levy(g)
	if n > 0:
		_log("%s เกณฑ์ทหาร +%d เข้าคลัง" % [g.name, n])
	world._take_events()
	_show_council()


func _council_pick(pid: String) -> void:
	_council_target = pid
	_show_council()


## Action: the general tries to talk the aimed-at prisoner into joining.
func _council_persuade(gid: String, pid: String) -> void:
	world.persuade(world.get_general(gid), world.get_general(pid))
	for e in world._take_events():
		_on_event(e)
	_show_council()


## Same as the AI: fill up the weakest generals at home first (troops only;
## the one-per-general actions stay the player's choice).
func _council_auto() -> void:
	world.auto_draft(Campaign.player_side)
	_show_council()


func _end_council() -> void:
	_close_popup()
	world.end_council(Campaign.player_side)
	for e in world._take_events():
		_on_event(e)
	_log("จบการประชุม · คลังเหลือ %d" % int(world.reserve[Campaign.player_side]))
	_check_battles()


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
			var h := _unit_height(g)
			out.append({"id": g.id, "rect": Rect2(g.pos - Vector2(4, h), Vector2(8, h + 1)), "moving": true})
	for cid in at:
		var list: Array = at[cid]
		var p: Vector2 = world.castles[cid].pos
		var x0 := p.x - (list.size() * 6 - 1) / 2.0
		for i in list.size():
			out.append({"id": list[i].id, "rect": Rect2(x0 + i * 6, p.y - 16, 5, 6), "moving": false})
	return out


func _draw_generals(font: Font) -> void:
	var tokens := _tokens()
	tokens.sort_custom(func(x, y): return x.rect.end.y < y.rect.end.y)  # lower on screen = in front
	for t in tokens:
		var g := world.get_general(t.id)
		var r: Rect2 = t.rect
		var col := _side_col(g.side)
		var sel: bool = g.id == selected
		if t.moving:
			_draw_army(g, sel)
			var top := Vector2(g.pos.x, r.position.y)
			if g.king:
				_draw_crown(top + Vector2(0, -1))
			if g.state == "battle":
				var c := top + Vector2(0, -5)
				var a := ALERT if fmod(_clock, 0.4) < 0.25 else TEXT
				draw_line(c + Vector2(-3, -3), c + Vector2(3, 3), a, 1.0)
				draw_line(c + Vector2(3, -3), c + Vector2(-3, 3), a, 1.0)
			if g.retreating:
				_text(font, "ถอย", top + Vector2(0, -3), 6, DIM, true)
			if g.id == hover_chip:
				_draw_foot_ring(g.pos, 6.0, TRIM_HI)
			if g.troops < 0.5:
				draw_line(r.position, r.end, ALERT, 1.0)
			continue
		else:
			# flag on a pole
			draw_line(Vector2(r.position.x, r.position.y), Vector2(r.position.x, r.end.y + 3), Color(0.2, 0.15, 0.1), 1.0)
			draw_rect(r.grow(0.5), Color(0, 0, 0, 0.6))
			draw_rect(r, col)
			if g.king:
				draw_rect(Rect2(r.position.x + 1, r.position.y + 1, 3, 1), TRIM_HI)
		if g.id == hover_chip:
			draw_arc(r.get_center(), 6.0, 0, TAU, 16, TRIM_HI, 1.0)
		if sel and fmod(_clock, 0.8) < 0.55:
			draw_rect(r.grow(1.5), Color.WHITE, false, 1.0)
		if g.troops < 0.5:
			draw_line(r.position, r.end, ALERT, 1.0)


# --- marching armies (sprites) ----------------------------------------------------

## Load the battle sprite strips the map uses (walk + idle only).
func _load_map_sprites() -> void:
	_map_sprites.clear()
	var defs: Dictionary = _battle_cfg.get("sprites", {})
	var map := WorldSim.load_map(Campaign.MAP_DATA)
	var ms: Dictionary = map.get("map_sprites", {})
	var want := {}
	for k in ms:
		if ms[k] is Dictionary and ms[k].has("sprite"):
			want[str(ms[k].sprite)] = true
	for gd in map.get("generals", []):
		if gd.has("unit"):
			want[str(gd.unit)] = true
	for id in want:
		if not defs.has(id):
			continue
		var d: Dictionary = defs[id]
		var fw := int(d.frame[0])
		var fh := int(d.frame[1])
		var anims := {}
		for a in ["walk", "idle"]:
			var path := "%s/%s.png" % [d.dir, a]
			if not ResourceLoader.exists(path):
				continue
			var tex: Texture2D = load(path)
			var ad: Dictionary = d.get("anims", {}).get(a, {})
			anims[a] = {"tex": tex, "frames": int(ad.get("frames", maxi(1, tex.get_width() / fw))),
					"fps": float(ad.get("fps", 6))}
		if anims.is_empty():
			continue
		var foot: Array = d.get("foot", [fw / 2, fh - 1])
		_map_sprites[id] = {"anims": anims, "w": fw, "h": fh, "foot": Vector2(foot[0], foot[1]),
				"height": float(d.get("height", fh))}


## Sprite set + scale a general's army is drawn with ({} = no sprite: diamond).
## The side it started on picks the troop look (a general who changed sides
## keeps its look; the foot ring shows the side); a general may set its own "unit".
func _army_look(g) -> Dictionary:
	var ms: Dictionary = data.get("map_sprites", {})
	var side_look: Dictionary = ms.get(g.origin if g.origin != "" else g.side, {})
	var id := str(side_look.get("sprite", ""))
	for gd in data.generals:
		if gd.id == g.id and gd.has("unit"):
			id = str(gd.unit)
	if not _map_sprites.has(id):
		return {}
	return {"sp": _map_sprites[id], "scale": float(side_look.get("scale", 0.5))}


func _unit_height(g) -> float:
	var look := _army_look(g)
	if look.is_empty():
		return 8.0
	return ceilf(look.sp.height * look.scale)


## Which way a marching army heads: towards the next castle. The facing is kept
## while it stops to fight, so both sides of a road battle face each other.
func _army_dir(g) -> Vector2:
	if g.state == "moving" and not g.path.is_empty():
		var to: Vector2 = world.castles[g.path[0]].pos
		if to.distance_to(g.pos) > 0.1:
			var d: Vector2 = (to - g.pos).normalized()
			if absf(d.x) > 0.05:
				_facing[g.id] = 1 if d.x > 0 else -1
			return d
	return Vector2(_facing.get(g.id, 1), 0)


func _draw_army(g, sel: bool) -> void:
	var look := _army_look(g)
	var col := _side_col(g.side)
	var dir := _army_dir(g)
	var face: int = _facing.get(g.id, 1 if dir.x >= 0 else -1)
	_draw_foot_ring(g.pos, 5.5, col, true)
	if sel and fmod(_clock, 0.8) < 0.55:
		_draw_foot_ring(g.pos, 6.5, Color.WHITE)
	if look.is_empty():
		var c: Vector2 = g.pos + Vector2(0, -4)
		draw_colored_polygon(PackedVector2Array([c + Vector2(0, -4), c + Vector2(4, 0), c + Vector2(0, 4),
				c + Vector2(-4, 0)]), Color(0, 0, 0, 0.6))
		draw_colored_polygon(PackedVector2Array([c + Vector2(0, -3), c + Vector2(3, 0), c + Vector2(0, 3),
				c + Vector2(-3, 0)]), col)
		return
	var anim := "walk" if g.state == "moving" else "idle"
	var t := _clock + float(absi(hash(g.id)) % 97) * 0.13  # out of step with the others
	# Followers: a few troops walking behind the leader (more troops = more).
	var fl: Dictionary = data.get("map_sprites", {}).get("followers", {})
	var n := mini(int(fl.get("max", 0)), int(floorf(g.troops / maxf(1.0, float(fl.get("per", 10))))))
	var back := -dir
	var side_off := Vector2(-back.y, back.x)
	for i in range(n, 0, -1):
		var p: Vector2 = g.pos + back * float(fl.get("gap", 5.0)) * i + side_off * (1.5 if i % 2 == 1 else -1.5)
		_draw_unit(look.sp, anim, t + i * 0.21, p.round(), look.scale * float(fl.get("scale", 0.8)), face,
				Color(0.85, 0.85, 0.85))
	_draw_unit(look.sp, anim, t, g.pos.round(), look.scale, face, Color.WHITE)


## One sprite frame standing on `foot` (scaled; face -1 = flipped to the left).
func _draw_unit(sp: Dictionary, anim: String, t: float, foot: Vector2, scale: float, face: int,
		mod: Color) -> void:
	var a: Dictionary = sp.anims.get(anim, sp.anims.get("idle", sp.anims.values()[0]))
	var frame := int(t * float(a.fps)) % int(a.frames)
	var src := Rect2(frame * sp.w, 0, sp.w, sp.h)
	draw_set_transform(foot, 0.0, Vector2(scale * face, scale))
	draw_texture_rect_region(a.tex, Rect2(-sp.foot, Vector2(sp.w, sp.h)), src, mod)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Flat ellipse on the ground; filled = side-colour patch under an army.
func _draw_foot_ring(p: Vector2, r: float, col: Color, filled := false) -> void:
	draw_set_transform(p, 0.0, Vector2(1.0, 0.45))
	if filled:
		draw_circle(Vector2.ZERO, r + 0.8, Color(0, 0, 0, 0.55))
		var c := col
		c.a = 0.55
		draw_circle(Vector2.ZERO, r, c)
	draw_arc(Vector2.ZERO, r, 0, TAU, 20, col, 1.0 if filled else 1.2)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_crown(p: Vector2) -> void:
	draw_rect(Rect2(p.x - 2.5, p.y - 2.5, 5, 2.5), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(p.x - 2, p.y - 2, 4, 1.5), TRIM_HI)
	for x in [-2.0, -0.5, 1.0]:
		draw_rect(Rect2(p.x + x, p.y - 3, 1, 1), TRIM_HI)


func _draw_top(font: Font) -> void:
	draw_rect(TOP_BAR, PANEL)
	draw_line(Vector2(0, TOP_BAR.end.y), Vector2(SCREEN.x, TOP_BAR.end.y), TRIM, 1.0)
	var speeds: Array = data.time.speeds
	var clock := "วันที่ %d" % (int(world.day) + 1)
	_text(font, clock, Vector2(160, 9), 8, TRIM_HI, true)
	var state := "หยุด [Space]" if paused else "×%d [Space หยุด]" % int(speeds[speed_i])
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


## Chips of the player's generals along the bottom bar, left to right.
func _roster() -> Array:
	var out := []
	if world == null:
		return out
	var font := ThemeDB.fallback_font
	var x := 3.0
	for g in world.generals_of(Campaign.player_side):
		var w := _w(font, _chip_text(g), 6) + 9.0
		out.append({"id": g.id, "rect": Rect2(x, BOTTOM_BAR.position.y + 3, w, 10)})
		x += w + 3.0
	return out


func _chip_text(g) -> String:
	var mark := ""
	match g.state:
		"moving":
			mark = " ถอย" if g.retreating else " เดิน"
		"battle":
			mark = " รบ"
	return "%s%s %d%s" % ["★" if g.king else "", g.name, int(g.troops), mark]


func _draw_bottom(font: Font) -> void:
	draw_rect(BOTTOM_BAR, PANEL)
	draw_line(Vector2(0, BOTTOM_BAR.position.y), Vector2(SCREEN.x, BOTTOM_BAR.position.y), TRIM, 1.0)
	for c in _roster():
		var g := world.get_general(c.id)
		var r: Rect2 = c.rect
		var sel: bool = c.id == selected
		draw_rect(r, Color(0.16, 0.18, 0.28) if sel or c.id == hover_chip else Color(0.09, 0.1, 0.16))
		draw_rect(r.grow(-0.5), TRIM_HI if sel else (TRIM if c.id == hover_chip else Color(0.3, 0.3, 0.35)), false, 1.0)
		draw_rect(Rect2(r.position.x + 2, r.position.y + 3, 4, 4), _side_col(g.side))
		var col := TEXT if g.state == "idle" else DIM
		if g.troops < 0.5:
			col = ALERT
		_text(font, _chip_text(g), Vector2(r.position.x + 7.5, r.position.y + 7.5), 6, col, false)
	# Reserve and days to the next council, right end of the roster row.
	if world.next_council < INF:
		var left := maxi(0, int(ceilf(world.next_council - world.day)))
		var info := "คลัง %d · ประชุมอีก %d วัน" % [int(world.reserve[Campaign.player_side]), left]
		_text(font, info, Vector2(SCREEN.x - 3 - _w(font, info, 6), BOTTOM_BAR.position.y + 10.5), 6,
				TRIM_HI if left <= 5 else DIM, false)
	var g := world.get_general(selected)
	var y := BOTTOM_BAR.position.y + 22
	if g != null:
		var t := ""
		if hover_castle != "" and not (g.state == "idle" and g.castle == hover_castle):
			t = "คลิกเพื่อส่ง %s ไป %s" % [g.name, world.castles[hover_castle].name]
		else:
			match g.state:
				"idle":
					t = "%s อยู่ที่ %s · คลิกปราสาทปลายทาง · คลิกขวายกเลิก" % [g.name, world.castles[g.castle].name]
				"moving":
					t = "%s %s %s · คลิกปราสาทอื่นเพื่อเปลี่ยนทาง" % [g.name, "ถอยไป" if g.retreating else "กำลังไป",
							world.castles[g.target()].name]
				"battle":
					t = "%s กำลังรบ" % g.name
		_text(font, t, Vector2(3, y), 6, TRIM_HI, false)
	elif not log_lines.is_empty():
		var l: String = log_lines[-1]
		_text(font, l, Vector2(3, y), 6, ALERT if l.begins_with("!") else TEXT, false)
	else:
		_text(font, "เลือกแม่ทัพจากแถบนี้ แล้วคลิกปราสาทที่จะไป · Space หยุดเวลา", Vector2(3, y), 6, DIM, false)
	if hover_castle != "":
		_draw_castle_tip(font, hover_castle)


## Small box next to a hovered castle: owner and who stands there.
func _draw_castle_tip(font: Font, cid: String) -> void:
	var c: Dictionary = world.castles[cid]
	var lines := ["%s (%s)" % [c.name, side_cfg[c.owner].label]]
	for e in world.generals_at(cid):
		lines.append("%s ทหาร %d" % [e.name, int(e.troops)])
	var w := 0.0
	for l in lines:
		w = maxf(w, _w(font, l, 6))
	var size := Vector2(w + 6, lines.size() * 7 + 3)
	var pos: Vector2 = c.pos + Vector2(10, -size.y / 2.0)
	if pos.x + size.x > SCREEN.x - 2:
		pos.x = c.pos.x - 10 - size.x
	pos.y = clampf(pos.y, TOP_BAR.end.y + 2, BOTTOM_BAR.position.y - size.y - 2)
	var r := Rect2(pos.round(), size)
	draw_rect(r, PANEL)
	draw_rect(r.grow(-0.5), TRIM, false, 1.0)
	for i in lines.size():
		_text(font, lines[i], r.position + Vector2(3, 7.5 + i * 7), 6, _side_col(c.owner) if i == 0 else TEXT, false)


func _w(font: Font, t: String, size: int) -> float:
	return font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Text with a 1 px shadow; centred on pos.x if centre.
func _text(font: Font, t: String, pos: Vector2, size: int, col: Color, centre: bool) -> void:
	var x := pos.x - _w(font, t, size) / 2.0 if centre else pos.x
	draw_string(font, Vector2(x + 0.5, pos.y + 0.5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.85))
	draw_string(font, Vector2(x, pos.y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
