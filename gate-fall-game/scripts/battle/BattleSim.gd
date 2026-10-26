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
## With data/battle_config_prototype.json (no generals) the same seed gives the
## same battle as the JS version; keep it that way so the core stays testable:
##   godot --headless --script res://tools/run_sims.gd -- --config=res://data/battle_config_prototype.json --per-battle
##
## Generals (CLAUDE.md section 5): a side with "general" in the config fields a
## general that hangs back behind its troops, fights when an enemy comes within
## engage_range (or when its troops are gone), and the side loses when it falls.
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
	# Formation roles toward generals (see formations in battle_config.json)
	var general_pull: float  # < 1: enemy general looks closer when picking targets
	var envelop: float  # > 0: troops swing this far above/below an enemy general
	var leash: float  # > 0: troops won't move farther than this from their general
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
	# Index of the general in `units`, -1 = none (side loses when all units are gone).
	# An index, not a Unit reference: Unit.side points back here, and a
	# reference cycle would leak.
	var general_idx: int = -1
	var troops: int  # alive non-general units at the start of the step
	var troop_cx: float  # their centre, where the general follows
	var troop_cy: float


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
	var is_general: bool = false
	var flank_sign: int = 1  # -1 = upper half of the formation, +1 = lower (envelop side)
	var engage_range: float = 0.0  # general: fights enemies closer than this
	var follow_gap: float = 0.0  # general: stays this far behind its troops


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
	var mid_y: Array = []
	var max_count := 0
	for i in sides.size():
		var sd: Dictionary = cfg.sides[i]
		var formation: Dictionary = cfg.formations[_formation_name(sd, overrides)]
		var sp: Array = _layout_spots(formation.layout, int(sd.count), sides[i].facing)
		spots.append(sp)
		var sum_y := 0.0
		for p in sp:
			sum_y += p[1]
		mid_y.append(sum_y / maxf(1.0, sp.size()))
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
			u.flank_sign = -1 if spot[1] < mid_y[i] else 1
			units.append(u)

	# Generals spawn after the troops (so configs without generals keep the
	# prototype's rng sequence) at a fixed spot behind their army.
	for i in sides.size():
		var sd: Dictionary = cfg.sides[i]
		if sd.get("general", "") == "":
			continue
		var s := sides[i]
		var g := _make_unit(s, sd.general)
		var gx := float(sd.general_spot[0])
		g.x = gx if s.facing == 1 else float(_field.width) - gx
		g.y = float(sd.general_spot[1])
		g.t = rng.next() * float(_combat.start_cd_jitter)
		g.anim = rng.next() * float(_combat.anim_jitter)
		s.general_idx = units.size()
		units.append(g)


## Advance the battle by dt seconds. Returns the events since the last step
## (including a "cast" from calling cast() between steps).
func step(dt: float) -> Array:
	if over != "":
		return _take_events()
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
	_update_troop_centres(live)

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
					if v.is_general and not u.is_general:
						dd *= u.side.general_pull
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
		if u.is_general and u.side.troops > 0 and d > u.engage_range:
			_follow_troops(u, dt, move_y)
			continue
		if d > u.reach:
			if u.side.hold_range > 0.0 and d > u.side.hold_range:
				u.walking = false
				continue
			var sp := u.spd * u.side.form_spd
			var my := dy * move_y
			# Envelop: swing out above/below the enemy general instead of straight at it.
			if u.side.envelop > 0.0 and v.is_general and not u.is_general and d > u.reach * 2.0:
				my = (dy + float(u.flank_sign) * u.side.envelop) * move_y
			var dm := BattleMath.hypot(dx, my)
			if dm == 0.0:
				dm = 1.0
			var nx := u.x + dx / dm * sp * dt
			var ny := u.y + my / dm * sp * dt
			if _leashed(u, nx, ny):
				u.walking = false
			else:
				u.x = nx
				u.y = ny
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
	var a := sides[0]
	var b := sides[1]
	# PROTOTYPE: if both sides fall on the same step, the first side wins.
	if _defeated(b, c):
		over = a.id
	elif _defeated(a, c):
		over = b.id
	elif time > _time_limit:
		over = "draw"
	if over != "":
		_clear_targets()
		if record_events:
			_events.append({"type": "over", "winner": over})
	return _take_events()


func _take_events() -> Array:
	var out := _events
	_events = []
	return out


## Change a side's order mid-battle (player presses charge / hold).
func set_order(side_id: String, order_name: String) -> void:
	var s := get_side(side_id)
	if s != null and cfg.orders.has(order_name):
		_apply_order(s, order_name)


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


## Alive units per side id (generals included), plus per unit kind.
func count() -> Dictionary:
	var c := {}
	for s in sides:
		c[s.id] = 0
	for u in units:
		if u.alive:
			c[u.side.id] += 1
			c[u.kind] = c.get(u.kind, 0) + 1
	return c


## Alive units of a side, not counting its general.
func troop_count(side_id: String) -> int:
	var n := 0
	for u in units:
		if u.alive and not u.is_general and u.side.id == side_id:
			n += 1
	return n


## Why a side lost: "general" (its general fell) or "wiped" (no units left).
func defeat_reason(side_id: String) -> String:
	var s := get_side(side_id)
	var g := general_of(side_id)
	if g != null and not g.alive:
		return "general"
	return "wiped"


## A side's general, or null if it has none.
func general_of(side_id: String) -> Unit:
	var s := get_side(side_id)
	if s == null or s.general_idx < 0:
		return null
	return units[s.general_idx]


func get_side(side_id: String) -> Army:
	for s in sides:
		if s.id == side_id:
			return s
	return null


# --- internals ----------------------------------------------------------------

func _defeated(s: Army, c: Dictionary) -> bool:
	if s.general_idx >= 0:
		return not units[s.general_idx].alive
	return c[s.id] == 0


func _update_troop_centres(live: Array[Unit]) -> void:
	for s in sides:
		s.troops = 0
		s.troop_cx = 0.0
		s.troop_cy = 0.0
	for u in live:
		if not u.is_general:
			u.side.troops += 1
			u.side.troop_cx += u.x
			u.side.troop_cy += u.y
	for s in sides:
		if s.troops > 0:
			s.troop_cx /= s.troops
			s.troop_cy /= s.troops


## General walks to a point follow_gap behind the centre of its troops.
## Guard formations: a soldier won't step farther from its general than `leash`
## (moving back toward it is always allowed).
func _leashed(u: Unit, nx: float, ny: float) -> bool:
	if u.side.leash <= 0.0 or u.is_general or u.side.general_idx < 0:
		return false
	var g: Unit = units[u.side.general_idx]
	if not g.alive:
		return false
	var dn := BattleMath.hypot(nx - g.x, ny - g.y)
	if dn <= u.side.leash:
		return false
	return dn > BattleMath.hypot(u.x - g.x, u.y - g.y)


func _follow_troops(u: Unit, dt: float, move_y: float) -> void:
	var px := u.side.troop_cx - float(u.side.facing) * u.follow_gap
	var dx := px - u.x
	var dy := u.side.troop_cy - u.y
	var d := BattleMath.hypot(dx, dy)
	if d < 2.0:
		u.walking = false
		return
	var sp := minf(u.spd * u.side.form_spd, d / dt)
	var my := dy * move_y
	var dm := BattleMath.hypot(dx, my)
	if dm == 0.0:
		dm = 1.0
	u.x += dx / dm * sp * dt
	u.y += my / dm * sp * dt
	u.walking = true


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
		m.flank_sign = v.flank_sign
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
	u.is_general = def.get("role", "") == "general"
	u.engage_range = float(def.get("engage_range", 0))
	u.follow_gap = float(def.get("follow_gap", 0))
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
	s.general_pull = float(f.get("general_pull", 1))
	s.envelop = float(f.get("envelop", 0))
	s.leash = float(f.get("leash", 0))


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
