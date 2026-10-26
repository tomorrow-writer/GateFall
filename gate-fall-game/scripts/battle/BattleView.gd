## Draws a BattleSim with placeholder shapes and plays effects from its events.
## Read-only: never changes the sim, so what you see is what run_sims measures.
## Swap the _draw_* functions for sprites later without touching BattleSim.
extends Node2D

const BattleSim = preload("res://scripts/battle/BattleSim.gd")

const SLIME := Color("4fc24f")
const SLIME_DARK := Color("2c7a34")
const MINI := Color("8be08b")
const KNIGHT := Color("aab4c8")
const KNIGHT_DARK := Color("5a6478")
const PLUME := Color("c8443c")
const FLASH := Color(1, 1, 1)
const WAVE := Color(0.45, 1.0, 0.55)
const HP_BG := Color(0, 0, 0, 0.6)
const HP_FG := Color("e0e05a")

var sim: BattleSim
## 0..1 between the previous sim step and the current one (smooth 60 fps on a 15 Hz sim).
var alpha := 1.0

var _prev := {}  # unit id -> Vector2 position at the previous step
var _died_at := {}  # unit id -> view clock when it died
var _born_at := {}  # unit id -> view clock when it split off
var _fx: Array = []  # {kind, pos, t0, dur}
var _clock := 0.0
var _flash := 0.0  # full-screen flash when a special is cast
var _flash_col := WAVE
var _cutscene := 0.0  # remaining cutscene time
var _cutscene_len := 0.0
var _cutscene_side = null  # Army whose general is casting


func bind(s: BattleSim) -> void:
	sim = s
	_prev.clear()
	_died_at.clear()
	_born_at.clear()
	_fx.clear()
	_cutscene = 0.0
	capture_prev()
	queue_redraw()


## Call right before each sim.step().
func capture_prev() -> void:
	if sim == null:
		return
	for u in sim.units:
		_prev[u.id] = Vector2(u.x, u.y)


func handle_events(events: Array) -> void:
	for e in events:
		match e.type:
			"hit":
				_fx.append({"kind": "spark", "pos": Vector2(e.x, e.y - 8), "t0": _clock, "dur": 0.2})
			"wavehit":
				_fx.append({"kind": "burst", "pos": Vector2(e.x, e.y - 8), "t0": _clock, "dur": 0.4,
						"col": _special_color(sim.get_side(e.get("by", "")))})
			"die":
				_died_at[e.id] = _clock
				_fx.append({"kind": "poof", "pos": Vector2(e.x, e.y - 6), "t0": _clock, "dur": 0.35})
			"spawn":
				_born_at[e.id] = _clock
			"cast":
				_flash = 0.25
				_flash_col = _special_color(sim.get_side(e.side))


## s: the casting Army (either side; the AI's casts get a cutscene too).
func start_cutscene(duration: float, s) -> void:
	_cutscene = duration
	_cutscene_len = duration
	_cutscene_side = s


## Special's "color" from the config, light green if unset.
func _special_color(s) -> Color:
	if s == null or s.special.is_empty():
		return WAVE
	return Color(str(s.special.get("color", "73ff8c")))


func _process(delta: float) -> void:
	_clock += delta
	_flash = maxf(0.0, _flash - delta)
	_cutscene = maxf(0.0, _cutscene - delta)
	var keep: Array = []
	for f in _fx:
		if _clock - f.t0 < f.dur:
			keep.append(f)
	_fx = keep
	queue_redraw()


func _draw() -> void:
	_draw_field()
	if sim == null:
		return
	# Wave behind the units (a cavalry charge rides over them, drawn below)
	for s in sim.sides:
		if not s.wave.is_empty() and s.special.get("type", "wave") != "charge":
			_draw_wave(s)
	# Units back to front
	var order: Array = []
	for u in sim.units:
		if u.alive or _clock - _died_at.get(u.id, _clock) < 0.6:
			order.append(u)
	order.sort_custom(func(a, b): return a.y < b.y)
	for u in order:
		_draw_unit(u)
	for s in sim.sides:
		if not s.wave.is_empty() and s.special.get("type", "wave") == "charge":
			_draw_wave(s)
	for f in _fx:
		_draw_fx(f)
	_draw_general_bars()
	if _flash > 0.0:
		draw_rect(Rect2(0, 0, 480, 270), Color(_flash_col.lerp(Color.WHITE, 0.4), _flash * 1.6))
	if _cutscene > 0.0:
		_draw_cutscene()


func _pos(u) -> Vector2:
	var cur := Vector2(u.x, u.y)
	var p: Vector2 = _prev.get(u.id, cur)
	return p.lerp(cur, alpha)


func _draw_field() -> void:
	# Sky (top band, behind the HUD)
	var sky_top := Color("1d2a48")
	var sky_low := Color("d98c5a")
	for i in 8:
		var y0 := i * 13.0
		draw_rect(Rect2(0, y0, 480, 13), sky_top.lerp(sky_low, i / 7.0))
	# Mountains
	draw_colored_polygon(PackedVector2Array([Vector2(0, 104), Vector2(60, 70), Vector2(120, 96),
			Vector2(190, 62), Vector2(260, 100), Vector2(330, 74), Vector2(410, 98), Vector2(480, 78),
			Vector2(480, 104)]), Color("3b3f5c"))
	# Ground
	draw_rect(Rect2(0, 104, 480, 140), Color("4b6b3a"))
	for i in 6:
		draw_rect(Rect2(0, 110 + i * 22, 480, 1), Color("557a42"))
	draw_rect(Rect2(0, 240, 480, 30), Color("2b2a33"))


func _draw_wave(s) -> void:
	var w: Dictionary = s.wave
	var sp: Dictionary = s.special
	var x1 := float(w.x)
	var x0 := x1 - float(sp.width)
	if s.facing == -1:
		var t := 480.0 - x0
		x0 = 480.0 - x1
		x1 = t
	var col := _special_color(s)
	if sp.get("type", "wave") == "charge":
		_draw_charge(s, x0, x1, col)
		return
	draw_rect(Rect2(x0, 112, x1 - x0, 126), Color(col, 0.35))
	for i in 7:
		var cy := 120.0 + i * 18.0
		draw_circle(Vector2(lerpf(x0, x1, 0.7) + sin(_clock * 20.0 + i) * 3.0, cy), 7.0, Color(col, 0.7))


## Cavalry charge: a row of placeholder horsemen galloping down the lane,
## dust behind them, the lane itself faintly marked.
func _draw_charge(s, x0: float, x1: float, col: Color) -> void:
	var w: Dictionary = s.wave
	var f := float(s.facing)
	var half := float(s.special.get("lane_height", 40)) / 2.0
	var ly := float(w.y)
	var front := x1 if f > 0.0 else x0
	var back := -40.0 if f > 0.0 else 520.0
	# lane marker + dust trail
	draw_rect(Rect2(0, ly - half, 480, half * 2.0), Color(col, 0.10))
	draw_line(Vector2(0, ly - half), Vector2(480, ly - half), Color(col, 0.45), 1.0)
	draw_line(Vector2(0, ly + half), Vector2(480, ly + half), Color(col, 0.45), 1.0)
	var tx0 := minf(front, back)
	draw_rect(Rect2(tx0, ly - half, absf(front - back), half * 2.0), Color(0.75, 0.62, 0.45, 0.18))
	for i in 6:
		var dx := front - f * (14.0 + i * 11.0)
		draw_circle(Vector2(dx, ly - half + fmod(i * 17.0, half * 2.0) + 4.0), 5.0 + i, Color(0.8, 0.7, 0.55, 0.3 - i * 0.04))
	# horsemen, rows staggered so the line reads as a charge
	var rows := maxi(2, int(half * 2.0 / 15.0))
	for i in rows:
		var y := ly - half + (i + 0.5) * (half * 2.0 / rows) + 6.0
		var x := front - f * (8.0 + (i % 2) * 7.0)
		var gallop := absf(sin(_clock * 22.0 + i)) * 2.0
		draw_set_transform(Vector2(x, y - gallop), 0.0, Vector2(1.4, 1.4))
		_draw_horseman(Vector2.ZERO, f, col)
		draw_set_transform(Vector2.ZERO)


func _draw_horseman(p: Vector2, f: float, col: Color) -> void:
	var horse := Color("6b4a32")
	draw_rect(Rect2(p + Vector2(-8, -9), Vector2(16, 6)), horse)  # body
	draw_rect(Rect2(p + Vector2(f * 6 - 2, -13), Vector2(5, 6)), horse)  # neck/head
	draw_rect(Rect2(p + Vector2(-7, -3), Vector2(2, 3)), horse.darkened(0.3))  # legs
	draw_rect(Rect2(p + Vector2(5, -3), Vector2(2, 3)), horse.darkened(0.3))
	draw_rect(Rect2(p + Vector2(-3, -17), Vector2(6, 8)), KNIGHT)  # rider
	draw_rect(Rect2(p + Vector2(-1, -19), Vector2(2, 2)), PLUME)
	draw_line(p + Vector2(f * 2, -13), p + Vector2(f * 16, -15), col, 1.0)  # lance


func _draw_unit(u) -> void:
	var p := _pos(u)
	var dead_t: float = _clock - _died_at.get(u.id, _clock)
	var fade := 1.0 if u.alive else clampf(1.0 - dead_t / 0.6, 0.0, 1.0)
	var flash: bool = u.fx > 0.0
	match u.kind:
		"big", "mini":
			_draw_slime(u, p, fade, flash)
		"general":
			_draw_general(u, p, fade, flash)
		_:
			_draw_knight(u, p, fade, flash)
	if u.alive and u.hp < u.max_hp and not u.is_general:
		var w := 14.0 if u.kind != "mini" else 9.0
		var top := p + Vector2(-w / 2.0, -26.0 if u.kind == "knight" else (-20.0 if u.kind == "big" else -14.0))
		draw_rect(Rect2(top, Vector2(w, 2)), HP_BG)
		draw_rect(Rect2(top, Vector2(w * clampf(u.hp / u.max_hp, 0.0, 1.0), 2)), HP_FG)


func _draw_slime(u, p: Vector2, fade: float, flash: bool) -> void:
	var big: bool = u.kind == "big"
	var r := 9.0 if big else 5.5
	var col := SLIME if big else MINI
	if flash:
		col = FLASH
	# Split pieces pop in from their parent
	var born: float = _clock - _born_at.get(u.id, -10.0)
	var pop := clampf(born / 0.25, 0.0, 1.0) if born < 0.25 else 1.0
	var bob := absf(sin(u.anim * 9.0)) * 2.0 if u.walking else 0.0
	var squash := 0.72 + (0.08 if u.walking and bob < 0.5 else 0.0)
	if not u.alive:
		squash *= fade
	var c := p + Vector2(0, -r * squash - bob)
	draw_set_transform(c, 0.0, Vector2(pop, squash * pop))
	draw_circle(Vector2(0, 2), r, Color(SLIME_DARK, fade))
	draw_circle(Vector2.ZERO, r, Color(col, fade))
	draw_set_transform(Vector2.ZERO)
	# eyes face the enemy
	var f: float = float(u.side.facing)
	draw_rect(Rect2(c + Vector2(f * r * 0.25 - 1, -2), Vector2(1.5, 2)), Color(0, 0, 0, fade))
	draw_rect(Rect2(c + Vector2(f * r * 0.6 - 1, -2), Vector2(1.5, 2)), Color(0, 0, 0, fade))
	# spear
	if big and u.alive:
		var thrust := 5.0 if u.swing > 0.0 else 0.0
		draw_line(c + Vector2(f * 3, 2), c + Vector2(f * (14 + thrust), -1), Color("c9a46a"), 1.0)


func _draw_knight(u, p: Vector2, fade: float, flash: bool) -> void:
	var f: float = float(u.side.facing)
	var bob := absf(sin(u.anim * 8.0)) * 1.5 if u.walking else 0.0
	var body := KNIGHT if not flash else FLASH
	var base := p + Vector2(0, -bob)
	if not u.alive:
		# fall over
		draw_rect(Rect2(base + Vector2(-9, -6), Vector2(18, 6)), Color(KNIGHT_DARK, fade))
		return
	draw_rect(Rect2(base + Vector2(-5, -18), Vector2(10, 14)), body)
	draw_rect(Rect2(base + Vector2(-5, -4), Vector2(3, 4)), KNIGHT_DARK)
	draw_rect(Rect2(base + Vector2(2, -4), Vector2(3, 4)), KNIGHT_DARK)
	draw_rect(Rect2(base + Vector2(-4, -24), Vector2(8, 7)), body)
	draw_rect(Rect2(base + Vector2(f * 1 - 1, -22), Vector2(3, 1)), Color(0, 0, 0))
	draw_rect(Rect2(base + Vector2(-1, -27), Vector2(2, 3)), PLUME)
	# sword: raised normally, swung forward when attacking
	var hand := base + Vector2(f * 5, -12)
	var tip := hand + (Vector2(f * 11, 2) if u.swing > 0.0 else Vector2(f * 3, -10))
	draw_line(hand, tip, Color("e8e8f0"), 1.0)


## Placeholder generals: slime general (green armour, red cape, orb staff) and
## knight general (gold-trimmed armour, blue cape). Both clearly bigger than troops.
func _draw_general(u, p: Vector2, fade: float, flash: bool) -> void:
	var f: float = float(u.side.facing)
	var bob := absf(sin(u.anim * 6.0)) * 1.5 if u.walking else 0.0
	var b := p + Vector2(0, -bob)
	var slime: bool = u.type_id.contains("slime")
	var armour := Color("2f8a52") if slime else Color("8f9bb3")
	var cape := Color("a02a2a") if slime else Color("2a4aa0")
	var trim := Color("d8b440")
	if flash:
		armour = FLASH
	if not u.alive:
		draw_rect(Rect2(b + Vector2(-13, -7), Vector2(26, 7)), Color(armour.darkened(0.4), fade))
		return
	# aura ring so the general is easy to find
	draw_arc(b + Vector2(0, -1), 13.0, 0, TAU, 20, Color(trim, 0.5), 1.0)
	draw_colored_polygon(PackedVector2Array([b + Vector2(-f * 3 - 5, -30), b + Vector2(-f * 3 + 5, -30),
			b + Vector2(-f * 3 + 8, -4), b + Vector2(-f * 3 - 9, -4)]), cape)
	draw_rect(Rect2(b + Vector2(-6, -30), Vector2(12, 22)), armour)
	draw_rect(Rect2(b + Vector2(-6, -18), Vector2(12, 2)), trim)
	draw_rect(Rect2(b + Vector2(-6, -8), Vector2(4, 8)), armour.darkened(0.35))
	draw_rect(Rect2(b + Vector2(2, -8), Vector2(4, 8)), armour.darkened(0.35))
	draw_rect(Rect2(b + Vector2(-5, -39), Vector2(10, 9)), Color("e8c8a8") if slime else armour)
	if slime:
		draw_rect(Rect2(b + Vector2(-5, -41), Vector2(10, 3)), Color("7a4fb0"))
	else:
		draw_rect(Rect2(b + Vector2(-5, -41), Vector2(10, 3)), trim)
		draw_rect(Rect2(b + Vector2(-1, -45), Vector2(2, 4)), PLUME)
	draw_rect(Rect2(b + Vector2(f * 2 - 1, -36), Vector2(2, 2)), Color(0, 0, 0))
	var hand := b + Vector2(f * 8, -20)
	if slime:
		var lean := Vector2(f * 6, 0) if u.swing > 0.0 else Vector2.ZERO
		draw_line(hand + Vector2(0, 12), hand + Vector2(0, -24) + lean, Color("c9a46a"), 2.0)
		draw_circle(hand + Vector2(0, -27) + lean, 4.0, WAVE)
	else:
		var tip := hand + (Vector2(f * 18, 3) if u.swing > 0.0 else Vector2(f * 4, -18))
		draw_line(hand, tip, Color("f0f0ff"), 2.0)


## Top-of-field HP bars for both generals (first side on the left).
func _draw_general_bars() -> void:
	if sim.time <= 0.0:
		return  # setup screen: the formation panel sits here
	var font := ThemeDB.fallback_font
	for i in sim.sides.size():
		var g = sim.general_of(sim.sides[i].id)
		if g == null:
			continue
		var w := 150.0
		var x := 6.0 if i == 0 else 480.0 - 6.0 - w
		var y := 20.0
		var k := clampf(g.hp / g.max_hp, 0.0, 1.0)
		draw_rect(Rect2(x - 1, y - 1, w + 2, 6), Color(0, 0, 0, 0.7))
		var col := Color("e05a4a") if k < 0.3 else HP_FG
		if i == 0:
			draw_rect(Rect2(x, y, w * k, 4), col)
		else:
			draw_rect(Rect2(x + w * (1.0 - k), y, w * k, 4), col)
		var label := "แม่ทัพ%s %d" % [_side_label(sim.sides[i].id), maxi(0, ceili(g.hp))]
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
		var tx := x if i == 0 else x + w - tw
		draw_string(font, Vector2(tx, y + 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, 0.9))


func _side_label(id: String) -> String:
	for sd in sim.cfg.sides:
		if sd.id == id:
			return sd.get("label", id)
	return id


func _draw_fx(f: Dictionary) -> void:
	var k: float = (_clock - f.t0) / f.dur
	match f.kind:
		"spark":
			draw_circle(f.pos, 2.0 + k * 2.0, Color(1, 0.95, 0.6, 1.0 - k))
		"burst":
			draw_arc(f.pos, 4.0 + k * 10.0, 0, TAU, 16, Color(f.get("col", WAVE), 1.0 - k), 2.0)
		"poof":
			draw_arc(f.pos, 3.0 + k * 9.0, 0, TAU, 12, Color(1, 1, 1, 0.8 * (1.0 - k)), 1.0)


## Placeholder cutscene: the casting general slides in from its own edge,
## scaled up, with the special's name on the other side.
func _draw_cutscene() -> void:
	var k := 1.0 - _cutscene / maxf(_cutscene_len, 0.001)  # 0 -> 1
	draw_rect(Rect2(0, 0, 480, 270), Color(0, 0, 0, 0.55))
	# letterbox bars slide in
	var bar := 30.0 * minf(k * 4.0, 1.0)
	draw_rect(Rect2(0, 0, 480, bar), Color(0, 0, 0))
	draw_rect(Rect2(0, 270 - bar, 480, bar), Color(0, 0, 0))
	var s = _cutscene_side
	if s == null:
		return
	var col := _special_color(s)
	var f := float(s.facing)
	var slide := minf(k * 3.0, 1.0)
	var gx := lerpf(-40.0, 150.0, slide) if f > 0.0 else lerpf(520.0, 330.0, slide)
	var g := Vector2(gx, 200)
	var glow := 14.0 + sin(_clock * 18.0) * 3.0 + k * 10.0
	draw_circle(g + Vector2(0, -50), glow * 2.0, Color(col, 0.18))
	var gen = sim.general_of(s.id)
	if gen != null:
		draw_set_transform(g, 0.0, Vector2(2.4, 2.4))
		_draw_general(gen, Vector2.ZERO, 1.0, false)
		draw_set_transform(Vector2.ZERO)
	# title on the far side from the general
	var label: String = s.special.get("label", "")
	var font := ThemeDB.fallback_font
	var size := 16
	var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var tx := 470.0 - tw if f > 0.0 else 10.0
	draw_string(font, Vector2(tx, 120), label, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
