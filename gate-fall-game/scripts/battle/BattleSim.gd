## Pure battle simulation: no Nodes, no drawing. Port of prototype/battle_core.js.
##
## Usage:
##   var cfg := BattleSim.load_config("res://data/battle_config.json")
##   var sim := BattleSim.new(cfg, {"S": {"formation": "wedge", "order": "hold"}})
##   while sim.over == "":
##       for e in sim.step(1.0 / 15.0):
##           ...  # BattleView plays animations for e.type: hit, die, spawn, cast, wavehit, over
##   sim.cast("S")  # player presses the special button
##
## Nothing here is tied to a race: sides, units, orders and formations all come
## from the config, so either side can be the player (CLAUDE.md section 6).
##
## Ported to match the prototype exactly, quirks included (marked PROTOTYPE).
## Same seed -> same battle as the JS version. Don't "fix" these until the
## Godot numbers have been checked against the prototype and committed.
class_name BattleSim
extends RefCounted

const BattleMath = preload("res://scripts/battle/BattleMath.gd")
const BattleRng = preload("res://scripts/battle/BattleRng.gd")


class Army:
	var id: String
	var index: int
	var facing: int
	var form_atk: float
	var form_take: float
	var form_spd: float
	var flank: float
	var flank_min: int
	var order_name: String
	var order_atk: float
	var order_take: float
	var mp_regen: float
	var hold_range: float  # <= 0 means the order never stops to wait
	var special: Dictionary  # empty = no special
	var auto_cast: bool
	var mp: float
	var mp_max: float
	var wave: Dictionary  # active wave {x, hit}; empty = none


class Unit:
	var id: int
	var side: Army
	var type_id: String
	var kind: String
	var x: float
	var y: float
	var hp: float
	var max_hp: float
	var atk: float
	var cd: float
	var spd: float
	var reach: float
	var radius: float
	var split: Dictionary
	var t: float = 0.0  # time until next attack
	var tg: Unit = null  # current target
	var re: float = 0.0  # time until next retarget
	var fx: float = 0.0  # hit flash timer (view only)
	var anim: float = 0.0  # animation clock (view only)
	var alive: bool = true
	var walking: bool = false
	var swing: float = 0.0  # attack swing timer (view only)
	var born: float = 0.0  # spawn-in timer for split pieces (view only)
	var bx: float = 0.0  # where a split piece came from (view only)
	var by: float = 0.0


var cfg: Dictionary
var rng: BattleRng
var units: Array[Unit] = []
var sides: Array[Army] = []
var time: float = 0.0
var over: String = ""  # "" while running, then a side id or "draw"
var record_events: bool = true

var _events: Array = []
var _next_id: int = 0
var _field: Dictionary
var _combat: Dictionary
var _time_limit: float


static func load_config(path: String = "res://data/battle_config.json") -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		push_error("BattleSim: cannot read %s" % path)
		return {}
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("BattleSim: %s is not a JSON object" % path)
		return {}
	return data


## overrides: per side id, any of {"formation", "order", "auto_cast"}.
## rng: share one BattleRng across battles to reproduce prototype simulate().
func _init(config: Dictionary, overrides: Dictionary = {}, shared_rng: BattleRng = null) -> void:
	cfg = config
	rng = shared_rng if shared_rng != null else BattleRng.new(int(cfg.sim.seed))
	_field = cfg.field
	_combat = cfg.combat
	_time_limit = float(cfg.sim.time_limit)

	for i in cfg.sides.size():
		var sd: Dictionary = cfg.sides[i]
		var ov: Dictionary = overrides.get(sd.id, {})
		var s := Army.new()
		s.id = sd.id
		s.index = i
		s.facing = int(sd.facing)
		_apply_formation(s, ov.get("formation", sd.formation))
		_apply_order(s, ov.get("order", sd.order))
		s.special = cfg.specials.get(sd.get("special", ""), {})
		s.auto_cast = bool(ov.get("auto_cast", false))
		s.mp = float(sd.mp_start)
		s.mp_max = float(sd.mp_max)
		s.wave = {}
		sides.append(s)

	# PROTOTYPE: units spawn interleaved (S0, K0, S1, K1, ...) and each takes
	# 4 rng draws in this exact order: x, y, attack timer, anim.
	var spots: Array = []
	var max_count := 0
	for i in sides.size():
		var sd: Dictionary = cfg.sides[i]
		var formation: Dictionary = cfg.formations[_formation_name(sd, overrides)]
		spots.append(_layout_spots(formation.layout, int(sd.count), sides[i].facing))
		max_count = maxi(max_count, int(sd.count))
	for n in max_count:
		for i in sides.size():
			var sd: Dictionary = cfg.sides[i]
			if n >= int(sd.count):
				continue
			var s := sides[i]
			var spot: Array = spots[i][n]
			var jx := float(sd.spawn_jitter[0])
			var jy := float(sd.spawn_jitter[1])
			var u := _make_unit(s, sd.unit)
			u.x = spot[0] + float(s.facing) * rng.next() * jx
			u.y = maxf(float(_field.y_min), minf(float(_field.y_max), spot[1] + rng.next() * jy))
			u.t = rng.next() * float(_combat.start_cd_jitter)
			u.anim = rng.next() * float(_combat.anim_jitter)
			units.append(u)


## Advance the battle by dt seconds. Returns this step's events.
func step(dt: float) -> Array:
	_events = []
	if over != "":
		return _events
	time += dt
	var live: Array[Unit] = []
	for u in units:
		if u.alive:
			live.append(u)

	for s in sides:
		s.mp = minf(s.mp_max, s.mp + dt * s.mp_regen)
	for s in sides:
		if s.auto_cast and not s.special.is_empty() and s.mp >= float(s.special.mp_cost) \
				and time > float(s.special.auto_cast_after) and s.wave.is_empty():
			cast(s.id)
	for s in sides:
		if not s.wave.is_empty():
			_step_wave(s, dt, live)

	var engaged := {}
	for u in live:
		if u.tg != null and u.tg.alive:
			engaged[u.tg.id] = engaged.get(u.tg.id, 0) + 1

	var y_w := float(_combat.target_y_weight)
	var move_y := float(_combat.move_y_factor)
	var re_base := float(_combat.retarget_base)
	var re_jit := float(_combat.retarget_jitter)
	var cd_min := float(_combat.attack_cd_min)
	var cd_jit := float(_combat.attack_cd_jitter)
	var dmg_min := float(_combat.damage_min)
	var dmg_jit := float(_combat.damage_jitter)
	var swing_time := float(_combat.swing_time)
	var hit_flash := float(_combat.hit_flash)

	# PROTOTYPE: loops over the snapshot without re-checking `alive`, so a unit
	# killed earlier in this step still moves and can still attack this step.
	for u in live:
		u.anim += dt
		u.fx = maxf(0.0, u.fx - dt)
		u.t -= dt
		u.re -= dt
		if u.tg == null or not u.tg.alive or u.re <= 0.0:
			var best: Unit = null
			var bd := 1e9
			for v in live:
				if v.side != u.side and v.alive:
					var ex := v.x - u.x
					var ey := (v.y - u.y) * y_w
					var dd := ex * ex + ey * ey
					if dd < bd:
						bd = dd
						best = v
			u.tg = best
			u.re = re_base + rng.next() * re_jit
		var v := u.tg
		if v == null:
			continue
		var dx := v.x - u.x
		var dy := v.y - u.y
		var d := BattleMath.hypot(dx, dy)
		if d == 0.0:
			d = 1.0
		if d > u.reach:
			if u.side.hold_range > 0.0 and d > u.side.hold_range:
				u.walking = false
				continue
			var sp := u.spd * u.side.form_spd
			var my := dy * move_y
			var dm := BattleMath.hypot(dx, my)
			if dm == 0.0:
				dm = 1.0
			u.x += dx / dm * sp * dt
			u.y += my / dm * sp * dt
			u.walking = true
		else:
			u.walking = false
			if u.t <= 0.0:
				u.t = u.cd * (cd_min + rng.next() * cd_jit)
				u.swing = swing_time
				# Multiplier order matters for bit-exact results; keep it.
				var dmg := u.atk * (dmg_min + rng.next() * dmg_jit)
				dmg *= u.side.order_atk
				dmg *= v.side.order_take
				dmg *= u.side.form_atk
				if u.side.flank != 1.0 and engaged.get(v.id, 0) >= u.side.flank_min:
					dmg *= u.side.flank
				dmg *= v.side.form_take
				v.hp -= dmg
				v.fx = hit_flash
				if record_events:
					_events.append({"type": "hit", "id": v.id, "by": u.id, "x": v.x, "y": v.y,
							"side": v.side.id, "dmg": dmg})
				if v.hp <= 0.0:
					_kill(v)
		if u.swing > 0.0:
			u.swing = maxf(0.0, u.swing - dt)

	_separate(live)

	var c := count()
	var a_id := sides[0].id
	var b_id := sides[1].id
	# PROTOTYPE: if both armies are wiped on the same step, the first side wins.
	if c[b_id] == 0:
		over = a_id
	elif c[a_id] == 0:
		over = b_id
	elif time > _time_limit:
		over = "draw"
	if over != "":
		_clear_targets()
		if record_events:
			_events.append({"type": "over", "winner": over})
	return _events


## Call if a battle is abandoned before it ends (e.g. player quits).
## Units target each other, and those reference cycles would otherwise leak.
func dispose() -> void:
	_clear_targets()


func _clear_targets() -> void:
	for u in units:
		u.tg = null


## Fire a side's special. Returns false if not ready.
func cast(side_id: String) -> bool:
	var s := get_side(side_id)
	if over != "" or s == null or s.special.is_empty() or not s.wave.is_empty() \
			or s.mp < float(s.special.mp_cost):
		return false
	s.mp -= float(s.special.mp_cost)
	s.wave = {"x": float(s.special.start_x), "hit": {}}
	if record_events:
		_events.append({"type": "cast", "side": s.id, "special": s.special})
	return true


## Alive units per side id, plus per unit kind ("big", "mini", "knight").
func count() -> Dictionary:
	var c := {}
	for s in sides:
		c[s.id] = 0
	for u in units:
		if u.alive:
			c[u.side.id] += 1
			c[u.kind] = c.get(u.kind, 0) + 1
	return c


func get_side(side_id: String) -> Army:
	for s in sides:
		if s.id == side_id:
			return s
	return null


# --- internals ----------------------------------------------------------------

func _step_wave(s: Army, dt: float, live: Array[Unit]) -> void:
	var sp := s.special
	var w := s.wave
	w.x += float(sp.speed) * dt
	var width := float(_field.width)
	var band := float(sp.width)
	for u in live:
		if u.side != s and u.alive and not w.hit.has(u.id):
			# Wave coordinates run from the caster's edge of the field.
			var lx := u.x if s.facing == 1 else width - u.x
			if lx < w.x and lx > w.x - band:
				w.hit[u.id] = true
				u.hp -= float(sp.damage)
				u.fx = float(sp.hit_flash)
				if record_events:
					_events.append({"type": "wavehit", "id": u.id, "x": u.x, "y": u.y,
							"side": u.side.id, "dmg": float(sp.damage)})
				if u.hp <= 0.0:
					_kill(u)
	if w.x > float(sp.end_x):
		s.wave = {}


func _kill(v: Unit) -> void:
	v.alive = false
	if record_events:
		_events.append({"type": "die", "id": v.id, "x": v.x, "y": v.y, "side": v.side.id, "kind": v.kind})
	if v.split.is_empty():
		return
	var sp: Dictionary = v.split
	var n := int(sp.count)
	for i in n:
		var a := float(i) / float(n) * PI * 2.0 + rng.next()
		var m := _make_unit(v.side, sp.into)
		m.x = v.x + BattleMath.dcos(a) * float(sp.offset_x)
		m.y = v.y + BattleMath.dsin(a) * float(sp.offset_y)
		m.t = float(sp.first_attack_min) + rng.next() * float(sp.first_attack_jitter)
		m.anim = rng.next() * float(_combat.anim_jitter)
		m.born = float(sp.born_time)
		m.bx = v.x
		m.by = v.y
		units.append(m)
		if record_events:
			_events.append({"type": "spawn", "id": m.id, "from": v.id, "x": m.x, "y": m.y,
					"side": m.side.id, "kind": m.kind})


func _separate(live: Array[Unit]) -> void:
	var x_min := float(_field.x_min)
	var x_max := float(_field.x_max)
	var y_min := float(_field.y_min)
	var y_max := float(_field.y_max)
	var min_d2 := float(_combat.separation_min_d2)
	var n := live.size()
	for i in n:
		var a := live[i]
		if not a.alive:
			continue
		for j in range(i + 1, n):
			var b := live[j]
			if not b.alive:
				continue
			var mn := a.radius + b.radius
			var dx := b.x - a.x
			var dy := b.y - a.y
			var d2 := dx * dx + dy * dy
			if d2 < mn * mn and d2 > min_d2:
				var d := sqrt(d2)
				var p := (mn - d) / 2.0
				a.x -= dx / d * p
				a.y -= dy / d * p
				b.x += dx / d * p
				b.y += dy / d * p
		a.y = maxf(y_min, minf(y_max, a.y))
		a.x = maxf(x_min, minf(x_max, a.x))


func _make_unit(s: Army, type_id: String) -> Unit:
	var def: Dictionary = cfg.units[type_id]
	var u := Unit.new()
	u.id = _next_id
	_next_id += 1
	u.side = s
	u.type_id = type_id
	u.kind = def.kind
	u.reach = float(def.reach)
	u.radius = float(def.radius)
	u.split = def.get("split", {})
	if def.has("scale_from"):
		var base: Dictionary = cfg.units[def.scale_from]
		var p := float(def.strength_pct) / 100.0
		u.hp = float(base.hp) * p
		u.atk = float(base.atk) * p
		u.cd = float(base.cd) * float(def.cd_mult)
		u.spd = float(base.spd) * float(def.spd_mult)
	else:
		u.hp = float(def.hp)
		u.atk = float(def.atk)
		u.cd = float(def.cd)
		u.spd = float(def.spd)
	u.max_hp = u.hp
	return u


func _formation_name(sd: Dictionary, overrides: Dictionary) -> String:
	return overrides.get(sd.id, {}).get("formation", sd.formation)


func _apply_formation(s: Army, name: String) -> void:
	assert(cfg.formations.has(name), "BattleSim: unknown formation '%s'" % name)
	var f: Dictionary = cfg.formations[name]
	s.form_atk = float(f.atk)
	s.form_take = float(f.take)
	s.form_spd = float(f.spd)
	s.flank = float(f.get("flank", 1))
	s.flank_min = int(f.get("flank_min", 2))


func _apply_order(s: Army, name: String) -> void:
	assert(cfg.orders.has(name), "BattleSim: unknown order '%s'" % name)
	var o: Dictionary = cfg.orders[name]
	s.order_name = name
	s.order_atk = float(o.atk_mult)
	s.order_take = float(o.take_mult)
	s.mp_regen = float(o.mp_regen)
	s.hold_range = float(o.get("hold_range", 0))


func _layout_spots(layout: Dictionary, n: int, facing: int) -> Array:
	# Spots are [x, y] float pairs, not Vector2: Vector2 is 32-bit and would
	# round the arc positions.
	var out: Array = []
	if layout.type == "arc":
		var step_a := float(layout.angle_span) / float(n - 1)
		for i in n:
			var a := float(layout.angle_start) + float(i) * step_a
			var sa := BattleMath.dsin(a)
			out.append([float(layout.x) + absf(sa) * float(layout.rx), float(layout.y) + sa * float(layout.ry)])
	else:
		for i in mini(n, layout.spots.size()):
			out.append([float(layout.spots[i][0]), float(layout.spots[i][1])])
	if facing == -1:
		for p in out:
			p[0] = float(_field.width) - p[0]
	return out
