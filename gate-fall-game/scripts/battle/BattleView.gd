## Draws a BattleSim with placeholder shapes and plays effects from its events.
## Read-only: never changes the sim, so what you see is what run_sims measures.
## Swap the _draw_* functions for sprites later without touching BattleSim.
##
## Reads the sim's command state every frame: a special's warning time lights
## up its target lane (red when it is coming at the player), an opened lane is
## striped in the player's colour, a general sent in gets a red ring.
## Sprites: units listed in the config "sprites" section are drawn from
## sprite strips (see _load_sprites); anything without one falls back to the
## placeholder shapes below, so art can be added one unit at a time.
## When the sim reaches its duel phase the view cuts to a close-up of the two
## generals trading blows (_draw_duel), with damage numbers from duel_hit.
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
const DANGER := Color("ff4a3a")
const OPEN_LANE := Color("6ad0ff")
const CHARGE_RING := Color("ff6a4a")

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
## Side the player commands: enemy warnings are drawn red, own ones in the special's colour.
var player_side := ""
var _sprites := {}  # unit type id -> {"anims": {name: {tex, frames, fps, loop}}, "foot": Vector2, "height"}
var _fx_sprites := {}  # effect id -> {tex, w, h, frames, fps, loop, foot}
var _duel_t0 := -1.0  # view clock when the duel started
var _duel_nums: Array = []  # {side (target), text, t0, col}
var _bg: Texture2D = null  # field.background from the config (null = drawn placeholder)
var _bg_path := ""
var _facing := {}  # unit id -> -1/+1, which way it is drawn facing (see _update_facing)
var _duel_bg: Texture2D = null  # field.duel_background (null = drawn placeholder)
var _duel_bg_path := ""

# --- camera (DF style) -----------------------------------------------------------
# The screen (320x180) is smaller than the field (480 wide, ground y 104-240), so
# the view is a window onto the field, like Dragon Force: close enough that the
# troops read big, the ground fills the screen, and the camera follows the clash.
# The camera only moves this node (whole pixels, no scaling), so sprites stay
# crisp and the sim never knows. Things drawn in screen space (HP bars, banners,
# radar, flashes) go through _screen_begin()/_screen_end().
const SCREEN := Vector2(320, 180)
## World y at the top of the screen: horizon (y 104) sits under the top HUD,
## the dark strip under the field (y 240+) under the bottom HUD.
const CAM_Y := 76.0
## How fast the camera catches up (1/s); higher = snappier.
const CAM_FOLLOW := 2.5
## Radar: small map of the whole field, bottom-left above the command bar.
const RADAR := Rect2(4, 128, 72, 20)
## World position of the screen's top-left corner.
var cam := Vector2(0, CAM_Y)
var _cam_ready := false  # false = jump straight to the goal (new battle)


func bind(s: BattleSim) -> void:
	sim = s
	_load_sprites()
	_load_fx_sprites()
	_prev.clear()
	_facing.clear()
	_died_at.clear()
	_born_at.clear()
	_fx.clear()
	_duel_t0 = -1.0
	_duel_nums.clear()
	_cam_ready = false
	capture_prev()
	_update_camera(0.0)
	queue_redraw()


## Call right before each sim.step().
func capture_prev() -> void:
	if sim == null:
		return
	for u in sim.units:
		_update_facing(u)
		_prev[u.id] = Vector2(u.x, u.y)


## Units turn to face what they fight: a target within reach (so a mob behind
## a general hits its back and the general turns round to cut them down),
## else the way they walked last step, else their target. Small moves don't
## flip them, so nobody jitters.
func _update_facing(u) -> void:
	var f: float = _facing.get(u.id, float(u.side.facing))
	if u.alive and sim.phase == "field":
		var t = u.tg
		var tdx: float = t.x - u.x if t != null and t.alive else 0.0
		var near: bool = t != null and t.alive and Vector2(tdx, t.y - u.y).length() <= u.reach + 4.0
		var mdx: float = u.x - _prev[u.id].x if _prev.has(u.id) else 0.0
		if near and absf(tdx) > 2.0:
			f = signf(tdx)
		elif u.walking and absf(mdx) > 0.5:
			f = signf(mdx)
		elif not u.walking and absf(tdx) > 2.0:
			f = signf(tdx)
	_facing[u.id] = f


## Which way to draw a unit: per unit on the field, the side's way in the duel.
func _face(u) -> float:
	if sim.phase != "field":
		return float(u.side.facing)
	return _facing.get(u.id, float(u.side.facing))


func handle_events(events: Array) -> void:
	for e in events:
		match e.type:
			"hit":
				_fx.append({"kind": "spark", "pos": Vector2(e.x, e.y - 8), "t0": _clock, "dur": 0.2})
			"wavehit":
				var by = sim.get_side(e.get("by", ""))
				var hit_id := _special_fx(by, "hit")
				if hit_id != "":
					_add_fx_sprite(hit_id, Vector2(e.x, e.y - 6), float(by.facing))
				else:
					_fx.append({"kind": "burst", "pos": Vector2(e.x, e.y - 8), "t0": _clock, "dur": 0.4,
							"col": _special_color(by)})
			"die":
				_died_at[e.id] = _clock
				_fx.append({"kind": "poof", "pos": Vector2(e.x, e.y - 6), "t0": _clock, "dur": 0.35})
			"spawn":
				_born_at[e.id] = _clock
			"cast":
				_flash = 0.12
				_flash_col = _special_color(sim.get_side(e.side))
			"launch":
				var ls = sim.get_side(e.side)
				_flash = 0.2
				_flash_col = _special_color(ls)
				var launch_id := _special_fx(ls, "launch")
				var g = sim.general_of(e.side)
				if launch_id != "" and g != null:
					# x0 is in the caster's coordinates (measured from its own edge)
					var lx := float(e.x0) if ls.facing == 1 else float(sim.cfg.field.width) - float(e.x0)
					_add_fx_sprite(launch_id, Vector2(lx, g.y), float(ls.facing))
			"duel_offer":
				_flash = 0.3
				_flash_col = Color(1, 1, 1)
			"duel_start":
				_duel_t0 = _clock
				_flash = 0.35
				_flash_col = Color(1, 0.9, 0.6)
			"duel_hit":
				var target := _other_side(e.side)
				if e.miss:
					_duel_nums.append({"side": target, "text": "พลาด", "t0": _clock, "col": Color(0.8, 0.8, 0.85)})
				else:
					var big: bool = e.dmg >= 30.0
					_duel_nums.append({"side": target, "text": "-%d" % roundi(e.dmg), "t0": _clock,
							"col": Color("ffdd55") if big else Color(1, 1, 1), "big": big})
					if big:
						_flash = 0.12
						_flash_col = Color(1, 1, 1)


## Special's "color" from the config, light green if unset.
func _special_color(s) -> Color:
	if s == null or s.special.is_empty():
		return WAVE
	return Color(str(s.special.get("color", "73ff8c")))


func _process(delta: float) -> void:
	_clock += delta
	_flash = maxf(0.0, _flash - delta)
	var keep: Array = []
	for f in _fx:
		if _clock - f.t0 < f.dur:
			keep.append(f)
	_fx = keep
	_update_camera(delta)
	queue_redraw()


## Where the camera wants to be: the middle of the clash (mean x of all troops
## still standing), or of the player's army before the battle starts; generals
## only when no troops are left. Clamped so the screen never leaves the field.
func _camera_goal() -> float:
	var sum := 0.0
	var n := 0
	var setup: bool = sim.time <= 0.0
	for pass_generals in [false, true]:
		for u in sim.units:
			if not u.alive or u.is_general != pass_generals:
				continue
			if setup and u.side.id != player_side:
				continue
			sum += _pos(u).x
			n += 1
		if n > 0:
			break
	var cx := sum / float(n) if n > 0 else float(sim.cfg.field.width) / 2.0
	return clampf(cx - SCREEN.x / 2.0, 0.0, float(sim.cfg.field.width) - SCREEN.x)


func _update_camera(delta: float) -> void:
	if sim == null:
		return
	if sim.phase == "duel":
		position = Vector2.ZERO  # the duel close-up is drawn in screen space
		return
	var goal := _camera_goal()
	if not _cam_ready:
		cam.x = goal
		_cam_ready = true
	else:
		cam.x = lerpf(cam.x, goal, 1.0 - exp(-CAM_FOLLOW * delta))
	cam.y = CAM_Y
	position = -cam.round()


## Draw in screen pixels (0..SCREEN) while the node is offset by the camera.
func _screen_begin() -> void:
	draw_set_transform(cam.round())


func _screen_end() -> void:
	draw_set_transform(Vector2.ZERO)


func _draw() -> void:
	if sim != null and sim.phase == "duel":
		_draw_duel()
		if _flash > 0.0:
			draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(_flash_col, _flash * 1.5))
		return
	_draw_field()
	if sim == null:
		return
	_draw_lanes()
	for s in sim.sides:
		if not s.pending.is_empty():
			_draw_warning(s)
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
	_screen_begin()
	_draw_lane_timer()
	_draw_general_bars()
	_draw_banners()
	_draw_radar()
	if sim.phase == "offer":
		draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0, 0.45))
	if _flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(_flash_col.lerp(Color.WHITE, 0.4), _flash * 1.2))
	_screen_end()


## Radar (screen space): the whole field shrunk into a small box, a dot per
## unit in its side's colour (generals bigger), and a frame for what the screen
## shows. Lets the player keep track of generals that are off screen.
func _draw_radar() -> void:
	if sim.time <= 0.0:
		return
	var f: Dictionary = sim.cfg.field
	var w := float(f.width)
	var y0 := float(f.y_min)
	var y1 := float(f.y_max)
	draw_rect(RADAR.grow(1), Color(0.85, 0.7, 0.35, 0.9), false, 1.0)
	draw_rect(RADAR, Color(0.02, 0.03, 0.08, 0.75))
	var to_radar := func(p: Vector2) -> Vector2:
		return RADAR.position + Vector2(p.x / w * RADAR.size.x,
				clampf((p.y - y0) / maxf(1.0, y1 - y0), 0.0, 1.0) * (RADAR.size.y - 1.0))
	for u in sim.units:
		if not u.alive:
			continue
		var mine: bool = u.side.id == player_side
		var col := Color("6ad0ff") if mine else Color("ff5a4a")
		var p: Vector2 = to_radar.call(_pos(u))
		if u.is_general:
			draw_rect(Rect2(p - Vector2(1, 1), Vector2(3, 3)), col.lightened(0.4))
		else:
			draw_rect(Rect2(p, Vector2(1, 1)), col)
	var vx := RADAR.position.x + cam.x / w * RADAR.size.x
	draw_rect(Rect2(vx, RADAR.position.y, SCREEN.x / w * RADAR.size.x, RADAR.size.y), Color(1, 1, 1, 0.55), false, 1.0)


func _pos(u) -> Vector2:
	var cur := Vector2(u.x, u.y)
	var p: Vector2 = _prev.get(u.id, cur)
	return p.lerp(cur, alpha)


func _draw_field() -> void:
	# Painted background (480x270: horizon at y 104, ground to y 240, HUD strip below).
	var path := ""
	if sim != null:
		path = str(sim.cfg.field.get("background", ""))
	if path != _bg_path:
		_bg_path = path
		_bg = load(path) as Texture2D if path != "" and ResourceLoader.exists(path) else null
	if _bg != null:
		draw_texture_rect(_bg, Rect2(0, 0, 480, 270), false)
		return
	# Placeholder: sky (top band, behind the HUD)
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
	# fades as it runs out of range (weaker damage)
	var fade := 1.0
	if float(sp.get("range", 0)) > 0.0:
		var k := clampf((float(w.x) - float(w.x0)) / float(sp.range), 0.0, 1.0)
		fade = lerpf(1.0, maxf(0.25, float(sp.get("min_damage_pct", 100)) / 100.0), k)
	var top := maxf(112.0, float(w.y0))
	var bot := minf(238.0, float(w.y1))
	var wave_id := _special_fx(s, "wave")
	if wave_id != "":
		_draw_wave_sprites(s, wave_id, x0, x1, top, bot, fade, col)
		return
	draw_rect(Rect2(x0, top, x1 - x0, bot - top), Color(col, 0.35 * fade))
	var n := int((bot - top) / 18.0)
	for i in n:
		var cy := top + 8.0 + i * 18.0
		draw_circle(Vector2(lerpf(x0, x1, 0.7) + sin(_clock * 20.0 + i) * 3.0, cy), 7.0, Color(col, 0.7 * fade))


## Wave drawn from its sprite: one crest per lane it covers, the crest's front
## (the sprite's foot) on the wave front and its base on the lane's bottom edge,
## lanes a few px out of step (position and frame) so the wall looks alive.
## Fades with range like the placeholder band.
const WAVE_STAGGER := [0.0, 6.0, 3.0]

func _draw_wave_sprites(s, id: String, x0: float, x1: float, top: float, bot: float, fade: float, col: Color) -> void:
	var f := float(s.facing)
	var front := x1 if f > 0.0 else x0
	# fade in over the first 30 px so it rises out of the launch splash instead
	# of popping up on top of the general
	fade *= clampf((float(s.wave.x) - float(s.wave.x0)) / 30.0, 0.0, 1.0)
	draw_rect(Rect2(x0, top, x1 - x0, bot - top), Color(col, 0.10 * fade))
	for i in sim.lane_count():
		var b: Vector2 = sim.lane_bounds(i)
		if b.y <= top or b.x >= bot:
			continue  # lane outside the wave (single-lane specials)
		var px := front - f * float(WAVE_STAGGER[i % WAVE_STAGGER.size()])
		_draw_fx_sprite(id, _clock + i * 0.11, Vector2(px, b.y), f, Color(1, 1, 1, 0.92 * fade))


## Cavalry charge: a row of placeholder horsemen galloping down the lane,
## dust behind them, the lane itself faintly marked.
func _draw_charge(s, x0: float, x1: float, col: Color) -> void:
	var w: Dictionary = s.wave
	var f := float(s.facing)
	var half := (float(w.y1) - float(w.y0)) / 2.0
	var ly := (float(w.y0) + float(w.y1)) / 2.0
	var front := x1 if f > 0.0 else x0
	var back := -40.0 if f > 0.0 else 520.0
	# lane marker + dust trail
	draw_rect(Rect2(0, ly - half, 480, half * 2.0), Color(col, 0.10))
	draw_line(Vector2(0, ly - half), Vector2(480, ly - half), Color(col, 0.45), 1.0)
	draw_line(Vector2(0, ly + half), Vector2(480, ly + half), Color(col, 0.45), 1.0)
	var tx0 := minf(front, back)
	draw_rect(Rect2(tx0, ly - half, absf(front - back), half * 2.0), Color(0.75, 0.62, 0.45, 0.18))
	var rider_id := _special_fx(s, "rider")
	if rider_id != "":
		_draw_charge_sprites(s, rider_id, _special_fx(s, "trail"), front, ly, half)
		return
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


## Cavalry charge from sprites: two ranks of riders (front rank on the charge
## front, second rank CHARGE_RANK_GAP px behind), two riders per rank staggered
## across the lane, dust clouds rolling behind each rank. The rider sprite's foot
## is its lance tip on the ground line, so the lances lead the hit band.
const CHARGE_RANK_GAP := 34.0

func _draw_charge_sprites(s, rider_id: String, trail_id: String, front: float, ly: float, half: float) -> void:
	var f := float(s.facing)
	var rows := 2
	var ranks := 2
	# back to front so nearer riders overlap the ones behind them
	for r in range(ranks - 1, -1, -1):
		for i in rows:
			var y := ly - half + (i + 0.5) * (half * 2.0 / rows) + 6.0
			var x := front - f * (8.0 + (i % 2) * 7.0 + r * CHARGE_RANK_GAP)
			var t := _clock + i * 0.17 + r * 0.29  # out of step, like real riders
			if trail_id != "":
				_draw_fx_sprite(trail_id, t, Vector2(x - f * 52.0, y), f, Color(1, 1, 1, 0.85))
			_draw_fx_sprite(rider_id, t, Vector2(x, y), f, Color(1, 1, 1, 1))


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
	if u.is_general:
		_draw_general_marks(u, p)
	if not _draw_sprite(u, p, fade, flash, 1.0):
		match u.kind:
			"big", "mini":
				_draw_slime(u, p, fade, flash)
			"general":
				_draw_general(u, p, fade, flash)
			_:
				_draw_knight(u, p, fade, flash)
	if u.alive and u.hp < u.max_hp and not u.is_general:
		var w := 14.0 if u.kind != "mini" else 9.0
		var bar_y := -26.0 if u.kind == "knight" else (-20.0 if u.kind == "big" else -14.0)
		if _sprites.has(u.type_id):
			bar_y = -float(_sprites[u.type_id].height) - 2.0
		var top := p + Vector2(-w / 2.0, bar_y)
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
	var f: float = _face(u)
	draw_rect(Rect2(c + Vector2(f * r * 0.25 - 1, -2), Vector2(1.5, 2)), Color(0, 0, 0, fade))
	draw_rect(Rect2(c + Vector2(f * r * 0.6 - 1, -2), Vector2(1.5, 2)), Color(0, 0, 0, fade))
	# spear
	if big and u.alive:
		var thrust := 5.0 if u.swing > 0.0 else 0.0
		draw_line(c + Vector2(f * 3, 2), c + Vector2(f * (14 + thrust), -1), Color("c9a46a"), 1.0)


func _draw_knight(u, p: Vector2, fade: float, flash: bool) -> void:
	var f: float = _face(u)
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
## Aura ring so the general is easy to find; red when sent into the fight,
## pulsing glow while channelling a special. Drawn under sprite or placeholder.
func _draw_general_marks(u, b: Vector2) -> void:
	if not u.alive:
		return
	var s = u.side
	if not s.pending.is_empty():
		var col := _special_color(s)
		draw_circle(b + Vector2(0, -20), 16.0 + sin(_clock * 16.0) * 3.0, Color(col, 0.25))
		draw_arc(b + Vector2(0, -1), 15.0, 0, TAU * (1.0 - float(s.pending.t) / maxf(0.001, float(s.pending.total))),
				24, Color(col, 0.9), 2.0)
	if s.gen_charge:
		draw_arc(b + Vector2(0, -1), 13.0, 0, TAU, 20, Color(CHARGE_RING, 0.85), 1.5)
	else:
		draw_arc(b + Vector2(0, -1), 13.0, 0, TAU, 20, Color(Color("d8b440"), 0.5), 1.0)


func _draw_general(u, p: Vector2, fade: float, flash: bool) -> void:
	var f: float = _face(u)
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
		var w := 120.0
		var x := 6.0 if i == 0 else SCREEN.x - 6.0 - w
		var y := 18.0
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
		"sprite":
			_draw_fx_sprite(f.id, _clock - f.t0, f.pos, f.facing, Color(1, 1, 1, 1))


## Faint lane guides while fighting; an opened lane is striped in the player's
## colour (enemy's opened lane faintly) with the time it stays open.
func _draw_lanes() -> void:
	var n: int = sim.lane_count()
	if n <= 0 or sim.time <= 0.0:
		return
	for i in range(1, n):
		var y: float = sim.lane_bounds(i).x
		var x := 0.0
		while x < 480.0:
			draw_line(Vector2(x, y), Vector2(x + 6.0, y), Color(1, 1, 1, 0.10), 1.0)
			x += 12.0
	for s in sim.sides:
		if s.split_lane < 0:
			continue
		var b: Vector2 = sim.lane_bounds(s.split_lane)
		var mine: bool = s.id == player_side
		var col := OPEN_LANE if mine else Color(0.8, 0.8, 0.8)
		var a := 0.16 if mine else 0.07
		draw_rect(Rect2(0, b.x, 480, b.y - b.x), Color(col, a))
		# chevrons pointing out of the lane, on this side's half
		var f := float(s.facing)
		var x0 := 20.0 if f > 0.0 else 300.0
		for k in 4:
			var cx := x0 + k * 40.0
			draw_line(Vector2(cx - 4, b.x + 6), Vector2(cx, b.x + 2), Color(col, a * 4.0), 1.0)
			draw_line(Vector2(cx + 4, b.x + 6), Vector2(cx, b.x + 2), Color(col, a * 4.0), 1.0)
			draw_line(Vector2(cx - 4, b.y - 6), Vector2(cx, b.y - 2), Color(col, a * 4.0), 1.0)
			draw_line(Vector2(cx + 4, b.y - 6), Vector2(cx, b.y - 2), Color(col, a * 4.0), 1.0)


## Time left on the player's opened lane, at the screen edge on the player's
## side (screen space, so it stays visible wherever the camera is).
func _draw_lane_timer() -> void:
	var s = sim.get_side(player_side)
	if s == null or s.split_lane < 0 or sim.time <= 0.0:
		return
	var b: Vector2 = sim.lane_bounds(s.split_lane)
	var font := ThemeDB.fallback_font
	var text := "เปิด %.1f" % maxf(0.0, s.split_left)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
	var x := 4.0 if s.facing > 0 else SCREEN.x - 4.0 - tw
	draw_string(font, Vector2(x, b.x + (b.y - b.x) / 2.0 + 3.0 - cam.round().y), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(OPEN_LANE, 0.9))


## A special in its warning time: the lane it will run down blinks, with an
## arrow showing which way it comes and a bar for the time left.
func _draw_warning(s) -> void:
	var p: Dictionary = s.pending
	var enemy: bool = s.id != player_side
	var col := DANGER if enemy else _special_color(s)
	var top := maxf(108.0, float(p.y0))
	var bot := minf(240.0, float(p.y1))
	var k := 1.0 - float(p.t) / maxf(0.001, float(p.total))  # 0 -> 1
	var blink := 0.5 + 0.5 * sin(_clock * (10.0 + k * 14.0))
	draw_rect(Rect2(0, top, 480, bot - top), Color(col, 0.16 + 0.16 * blink))
	draw_line(Vector2(0, top), Vector2(480, top), Color(col, 0.7), 1.0)
	draw_line(Vector2(0, bot), Vector2(480, bot), Color(col, 0.7), 1.0)
	# arrows in the direction of travel
	var f := float(s.facing)
	var mid := (top + bot) / 2.0
	for i in 5:
		var ax := fposmod(i * 100.0 + _clock * 60.0 * f, 500.0) - 10.0
		draw_line(Vector2(ax, mid - 6), Vector2(ax + f * 8, mid), Color(col, 0.6), 2.0)
		draw_line(Vector2(ax, mid + 6), Vector2(ax + f * 8, mid), Color(col, 0.6), 2.0)
	# time left: bar shrinking along the lane edge
	draw_rect(Rect2(0, top, 480.0 * (1.0 - k), 2), Color(col, 0.9))


## Top banners: special name and countdown while it warms up.
func _draw_banners() -> void:
	var font := ThemeDB.fallback_font
	var row := 0
	for s in sim.sides:
		if s.pending.is_empty():
			continue
		var enemy: bool = s.id != player_side
		var col := DANGER if enemy else _special_color(s)
		var lane_name := ""
		var lane := int(s.pending.lane)
		var labels: Array = sim.cfg.get("lanes", {}).get("labels", [])
		if lane >= 0 and lane < labels.size():
			lane_name = " · เลน" + str(labels[lane])
		elif lane < 0:
			lane_name = " · ทั้งสนาม"
		var text := "%s%s%s  %.1f" % ["! " if enemy else "", s.special.get("label", ""), lane_name,
				maxf(0.0, float(s.pending.t))]
		var size := 10
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var y := 46.0 + row * 14.0
		var cx := SCREEN.x / 2.0
		draw_rect(Rect2(cx - tw / 2.0 - 5.0, y - 10.0, tw + 10.0, 13.0), Color(0, 0, 0, 0.6))
		draw_string(font, Vector2(cx - tw / 2.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
		row += 1


func _other_side(id: String) -> String:
	for s in sim.sides:
		if s.id != id:
			return s.id
	return id


# --- duel close-up -------------------------------------------------------------

const DUEL_X := [110.0, 210.0]  # first side (facing right) on the left (screen px)
const DUEL_Y := 124.0  # feet line on screen: centre of the spotlight
## The duel background is painted at 480x270 with the spotlight at y 214; the
## screen shows this 320x180 window of it, spotlight on DUEL_Y.
const DUEL_BG_CROP := Rect2(80, 90, 320, 180)
const DUEL_SCALE := 2.6  # placeholder generals
const DUEL_SPRITE_SCALE := 2.0  # sprites: integer scale keeps the pixels square


## The duel: dark backdrop, the two generals big and facing each other, the
## attacker lunges on each blow, damage numbers float up, HP bars on top.
func _draw_duel() -> void:
	var k := 1.0 if _duel_t0 < 0.0 else clampf((_clock - _duel_t0) / 0.4, 0.0, 1.0)
	var path := str(sim.cfg.field.get("duel_background", ""))
	if path != _duel_bg_path:
		_duel_bg_path = path
		_duel_bg = load(path) as Texture2D if path != "" and ResourceLoader.exists(path) else null
	if _duel_bg != null:
		# Painted duel scene (480x270, spotlight centred on DUEL_Y), fading in over the field.
		draw_texture_rect_region(_duel_bg, Rect2(Vector2.ZERO, SCREEN), DUEL_BG_CROP, Color(1, 1, 1, k))
	else:
		draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0.05, 0.05, 0.09, 0.85 * k + 0.1))
		# spotlight and ground
		draw_circle(Vector2(160, 210), 140.0, Color(0.95, 0.75, 0.45, 0.10))
		draw_rect(Rect2(0, DUEL_Y, SCREEN.x, SCREEN.y - DUEL_Y), Color(0.16, 0.13, 0.12))
		draw_line(Vector2(0, DUEL_Y), Vector2(SCREEN.x, DUEL_Y), Color(0.95, 0.75, 0.45, 0.4), 1.0)
	var font := ThemeDB.fallback_font
	for i in sim.sides.size():
		var s = sim.sides[i]
		var g = sim.general_of(s.id)
		if g == null:
			continue
		var fade := 1.0
		if not g.alive:
			fade = clampf(1.0 - (_clock - _died_at.get(g.id, _clock)) / 0.8, 0.0, 1.0)
		# lunge toward the opponent while swinging
		var lunge: float = (g.swing / 0.25) * 16.0 * float(s.facing) if g.swing > 0.0 else 0.0
		var shake := sin(_clock * 60.0) * 2.0 if g.fx > 0.0 else 0.0
		var pos := Vector2(DUEL_X[i] + lunge + shake, DUEL_Y)
		draw_ellipse_shadow(pos, fade)
		if not _draw_sprite(g, pos, fade, g.fx > 0.0, DUEL_SPRITE_SCALE):
			draw_set_transform(pos, 0.0, Vector2(DUEL_SCALE, DUEL_SCALE))
			_draw_general(g, Vector2.ZERO, fade, g.fx > 0.0)
			draw_set_transform(Vector2.ZERO)
		# HP bar and name, big, on this general's side
		var w := 110.0
		var x := 8.0 if i == 0 else SCREEN.x - 8.0 - w
		var y := 10.0
		var hp := clampf(g.hp / g.max_hp, 0.0, 1.0)
		draw_rect(Rect2(x - 1, y - 1, w + 2, 9), Color(0, 0, 0, 0.8))
		var col := Color("e05a4a") if hp < 0.3 else HP_FG
		if i == 0:
			draw_rect(Rect2(x, y, w * hp, 7), col)
		else:
			draw_rect(Rect2(x + w * (1.0 - hp), y, w * hp, 7), col)
		var label := "แม่ทัพ%s  %d" % [_side_label(s.id), maxi(0, ceili(g.hp))]
		var st: Dictionary = sim.duel_style(g)
		var style := "ตี %d ครั้ง/ตา" % int(st.hits)
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		var sw := font.get_string_size(style, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
		draw_string(font, Vector2(x if i == 0 else x + w - tw, y + 18), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
				Color(1, 1, 1, 0.95))
		draw_string(font, Vector2(x if i == 0 else x + w - sw, y + 28), style, HORIZONTAL_ALIGNMENT_LEFT, -1, 8,
				Color(1, 1, 1, 0.6))
	# whose turn: small marker over the attacker
	if sim.over == "" and sim.duel.has("order"):
		var atk: String = sim.duel.order[sim.duel.turn]
		var idx := 0 if sim.sides[0].id == atk else 1
		var mx: float = DUEL_X[idx]
		draw_colored_polygon(PackedVector2Array([Vector2(mx - 4, 20), Vector2(mx + 4, 20), Vector2(mx, 26)]),
				Color(1, 0.85, 0.4, 0.8 + 0.2 * sin(_clock * 8.0)))
	# damage numbers
	for n in _duel_nums:
		var age: float = _clock - n.t0
		if age > 1.0:
			continue
		var idx := 0 if sim.sides[0].id == n.side else 1
		var size := 16 if n.get("big", false) else 12
		var p := Vector2(DUEL_X[idx] - 10.0, 62.0 - age * 24.0)
		draw_string(font, p + Vector2(1, 1), n.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 1.0 - age))
		draw_string(font, p, n.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(n.col, 1.0 - age))
	# title
	if _duel_t0 >= 0.0 and _clock - _duel_t0 < 1.6:
		var a := clampf(1.6 - (_clock - _duel_t0), 0.0, 1.0)
		var title := "ดวล!"
		var ttw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		draw_string(font, Vector2(SCREEN.x / 2.0 - ttw / 2.0, 96), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 0.85, 0.4, a))


func draw_ellipse_shadow(pos: Vector2, fade: float) -> void:
	draw_set_transform(pos + Vector2(0, 2), 0.0, Vector2(1.0, 0.25))
	draw_circle(Vector2.ZERO, 30.0, Color(0, 0, 0, 0.45 * fade))
	draw_set_transform(Vector2.ZERO)


# --- sprites ---------------------------------------------------------------------
# Config "sprites": { "<unit type id>": {
#     "dir": "res://assets/units/<id>",  folder with one strip per animation
#     "frame": [w, h],                   size of one frame (all strips)
#     "foot": [x, y],                    pixel in the frame that stands on the ground
#     "anims": { "idle": {"frames": 4, "fps": 6}, "walk": ..., "attack": ...,
#                "cast": ..., "die": {"frames": 3, "fps": 8, "loop": false} } } }
# Strips are <dir>/<anim>.png, frames left to right, character facing RIGHT
# (flipped for the side facing left). Missing anims fall back to idle; a unit
# with no idle strip uses the placeholder shapes.

func _load_sprites() -> void:
	_sprites.clear()
	var defs: Dictionary = sim.cfg.get("sprites", {})
	for id in defs:
		if str(id).begins_with("_"):
			continue
		var d: Dictionary = defs[id]
		var fw := int(d.frame[0])
		var fh := int(d.frame[1])
		var anims := {}
		for a in d.get("anims", {}):
			var ad: Dictionary = d.anims[a]
			var path := "%s/%s.png" % [d.dir, a]
			if not ResourceLoader.exists(path):
				continue
			var tex: Texture2D = load(path)
			var n := int(ad.get("frames", maxi(1, tex.get_width() / fw)))
			anims[a] = {"tex": tex, "frames": n, "fps": float(ad.get("fps", 6)), "loop": bool(ad.get("loop", true))}
		if not anims.has("idle"):
			continue
		var foot: Array = d.get("foot", [fw / 2, fh - 1])
		_sprites[id] = {"anims": anims, "w": fw, "h": fh, "foot": Vector2(foot[0], foot[1]),
				"height": float(d.get("height", fh))}


# Config "fx_sprites": { "<effect id>": {
#     "file": "res://assets/fx/<id>.png",  one strip, frames left to right, moving RIGHT
#     "frame": [w, h], "foot": [x, y],      foot = frame pixel placed on the effect's point
#     "frames": n, "fps": f, "loop": bool } }
# A special picks its effects with "fx": {"wave": id, "hit": id, "launch": id};
# any role without a loaded sprite falls back to the placeholder drawing.

func _load_fx_sprites() -> void:
	_fx_sprites.clear()
	var defs: Dictionary = sim.cfg.get("fx_sprites", {})
	for id in defs:
		if str(id).begins_with("_"):
			continue
		var d: Dictionary = defs[id]
		var path := str(d.get("file", ""))
		if not ResourceLoader.exists(path):
			continue
		var tex: Texture2D = load(path)
		var fw := int(d.frame[0])
		var fh := int(d.frame[1])
		var foot: Array = d.get("foot", [fw / 2, fh - 1])
		_fx_sprites[id] = {"tex": tex, "w": fw, "h": fh, "foot": Vector2(foot[0], foot[1]),
				"frames": int(d.get("frames", maxi(1, tex.get_width() / fw))),
				"fps": float(d.get("fps", 12)), "loop": bool(d.get("loop", false))}


## The effect sprite a side's special uses for role ("wave", "hit", "launch"); "" = none.
func _special_fx(s, role: String) -> String:
	if s == null or s.special.is_empty():
		return ""
	var id := str(s.special.get("fx", {}).get(role, ""))
	return id if _fx_sprites.has(id) else ""


## One-shot effect: plays its frames once at pos, then is dropped with the other fx.
func _add_fx_sprite(id: String, pos: Vector2, facing: float) -> void:
	var d: Dictionary = _fx_sprites[id]
	_fx.append({"kind": "sprite", "id": id, "pos": pos, "facing": facing, "t0": _clock,
			"dur": float(d.frames) / maxf(0.001, float(d.fps))})


func _draw_fx_sprite(id: String, t: float, pos: Vector2, facing: float, col: Color) -> void:
	var d: Dictionary = _fx_sprites[id]
	var i := int(t * float(d.fps))
	i = i % int(d.frames) if d.loop else mini(i, int(d.frames) - 1)
	var w: float = d.w
	var h: float = d.h
	var foot: Vector2 = d.foot
	draw_set_transform(pos, 0.0, Vector2(facing, 1.0))
	draw_texture_rect_region(d.tex, Rect2(-foot.x, -foot.y, w, h), Rect2(i * w, 0, w, h), col)
	draw_set_transform(Vector2.ZERO)


## Which animation a unit is in right now.
func _anim_of(u) -> String:
	if not u.alive:
		return "die"
	if u.is_general and not u.side.pending.is_empty():
		return "cast"
	if u.swing > 0.0:
		return "attack"
	if u.walking:
		return "walk"
	return "idle"


## Draws u from its sprite strip with its feet at p. False = no sprite.
func _draw_sprite(u, p: Vector2, fade: float, flash: bool, scale: float) -> bool:
	if not _sprites.has(u.type_id):
		return false
	var sp: Dictionary = _sprites[u.type_id]
	var name := _anim_of(u)
	if not sp.anims.has(name):
		if name == "die":
			return true  # no death strip: just vanish (the poof fx plays)
		name = "idle"
	var a: Dictionary = sp.anims[name]
	var t: float = u.anim
	if name == "die":
		t = _clock - _died_at.get(u.id, _clock)
	elif name == "attack":
		t = 0.25 - u.swing  # swing counts down from swing_time
	var i := int(t * a.fps)
	i = i % int(a.frames) if a.loop else mini(i, int(a.frames) - 1)
	var w: float = sp.w
	var h: float = sp.h
	var f := _face(u)
	var foot: Vector2 = sp.foot
	# born pop-in for split slimes
	var born: float = _clock - _born_at.get(u.id, -10.0)
	var pop := clampf(born / 0.25, 0.3, 1.0) if born < 0.25 else 1.0
	var s := scale * pop
	# drawn in a frame mirrored around the feet for the side facing left
	draw_set_transform(p, 0.0, Vector2(s * f, s))
	var dst := Rect2(-foot.x, -foot.y, w, h)
	var src := Rect2(i * w, 0, w, h)
	draw_texture_rect_region(a.tex, dst, src, Color(1, 1, 1, fade))
	if flash:
		# white flash: draw again over-bright
		draw_texture_rect_region(a.tex, dst, src, Color(3, 3, 3, 0.6 * fade))
	draw_set_transform(Vector2.ZERO)
	return true
