## Pure battle simulation: no Nodes, no drawing. Port of prototype/battle_core.js.
##
## Usage:
##   var cfg := BattleSim.load_config("res://data/battle_config.json")
##   var sim := BattleSim.new(cfg, {"S": {"formation": "wedge", "order": "hold"}})
##   while sim.over == "":
##       for e in sim.step(1.0 / 15.0):
##           ...  # BattleView plays animations for e.type (see "Events" below)
##   sim.cast("S", -1, 2)      # player casts special slot 2 (large)
##   sim.split("S", 1)         # open the middle lane
##   sim.set_order("S", "retreat")
##   sim.set_general_charge("S", true)
##
## Lanes (cfg.lanes.count, 3 = top/middle/bottom) split the field height into
## equal bands. Lane specials hit one lane; the other side dodges by opening it.
##
## Specials (cfg.specials) move across the field and hit each enemy they pass
## once. "lanes" 0 = full height (slime wave); 1 = one aimed lane (cavalry
## charge). Casting has a warning time ("telegraph"): MP is paid and the target
## lane is shown, the general stands still channelling, then the special
## launches from the general's position (start_x if the side has no general).
## "range" = px it travels before fading out; damage drops to min_damage_pct
## along the way, so pulling back (retreat) takes less of it.
##
## Three specials per general (units.<general>.specials = [small, medium,
## large], slots 0..2): bigger = more MP, longer warning, more power. Each has
## a focus: "troops" (a wave/charge down lanes), "general" (targets: general,
## a bolt aimed at the enemy general's lane: it passes troops but each troop
## it goes through soaks block_pct of its power, so troops in front shield the
## general) or "defense" (type guard: after the warning the whole side takes
## take_mult x damage, specials included, for duration s). A side without a
## general's list uses sides[].special as its only slot.
##
## Commands during the fight (either side, player or AI, same code):
##   set_order   charge / hold / retreat. Changing order costs switch_delay s
##               where the troops stand frozen (opening a lane does not).
##   split       open a lane for split.duration s: troops in it step out to the
##               neighbouring lane(s) and none walk into it; everyone fights a
##               little worse while crowded (split.crowd_atk). The general does
##               not move: it stands at its post (DF style), so a special aimed
##               at its lane still hits it.
##   set_guard_out  squad formations (guard_share > 0) split the troops into a
##               main group and a guard group. Guards keep their spot round
##               the general (and follow it when it goes in), fight only
##               enemies within guard_radius of it and ignore the order
##               (retreat, hold). Released (on) they fight like the main group;
##               recalled (off) they walk back. No freeze either way.
##   set_general_charge  the general fights at the front like a soldier: gains
##               MP per hit (general_charge.mp_on_hit), specials launch from
##               the front, but takes front_take x damage out there (and
##               channel_take x more while channelling),
##               and walks back slower when recalled.
##
## Events: hit, die, spawn, cast (warning starts), launch, wavehit, cancel,
## guard, guard_end, split, split_end, order, gcharge, over.
##
## AI: a side with a BattleAI brain (overrides "ai", "dodge", "gcharge") gets
## its casts, dodges and general charges decided by the same code either side.
##
## Nothing here is tied to a race: sides, units, orders and formations all come
## from the config, so either side can be the player (CLAUDE.md section 6).
##
## Ported to match the prototype exactly, quirks included (marked PROTOTYPE).
## With data/battle_config_prototype.json (no generals, no lanes, no warning
## time) the same seed gives the same battle as the JS version; keep it that
## way so the core stays testable:
##   godot --headless --script res://tools/run_sims.gd -- --config=res://data/battle_config_prototype.json --per-battle --dodge=off --enemy-dodge=off
##
## Generals (CLAUDE.md section 5): a side with "general" in the config fields a
## general that stands at its post behind the army (DF style) and only hits
## enemies that reach it, until set_general_charge sends it in. A general at
## its post never steps off it: enemies that reach it spread out around it
## (front, back, above, below: _surround_slots) and it cuts them down one at a
## time (_foe_in_reach), whatever the order or a recall says; crowding can't
## shove it either (_anchored). A general whose troops are all gone walks to
## the nearest enemy soldier and fights on its own (and two such generals
## duel). The side loses when its general falls.
class_name BattleSim
extends RefCounted

const BattleMath = preload("res://scripts/battle/BattleMath.gd")
const BattleRng = preload("res://scripts/battle/BattleRng.gd")
const BattleAI = preload("res://scripts/battle/BattleAI.gd")


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
	# Squads (formations with guard_share): troops split into the main group
	# (follows the order) and a guard group that stays round the general.
	var squads: bool = false
	var guard_radius: float = 0.0  # guards fight enemies within this of their general
	var guard_out: bool = false  # guards released: they fight like the main group
	var guard_atk: float = 1.0  # guards on duty: atk x / damage taken x (dug in)
	var guard_take: float = 1.0
	var order_name: String
	var order_atk: float
	var order_take: float
	var order_spd: float = 1.0
	var retreating: bool = false  # order "retreat": walk back, no attacks
	var mp_regen: float
	var hold_range: float  # <= 0 means the order never stops to wait
	var special: Dictionary  # the special warming up / running (last cast); empty = none
	var specials: Array = []  # slots: [small, medium, large] (fewer for simple configs)
	var slot_casts: Array = []  # casts per slot this battle
	var auto_slot: int = -1  # slot auto_cast fires (-1 = the largest)
	var guard: Dictionary = {}  # defence special running {take, left, total, special}; empty = none
	var auto_cast: bool
	var mp: float
	var mp_max: float
	var pending: Dictionary  # special in its warning time {t, total, lane, y0, y1}; empty = none
	var wave: Dictionary  # active special {x, x0, y0, y1, hit}; empty = none
	var brain: RefCounted = null  # BattleAI when the AI commands (part of) this side
	var casts: int = 0  # specials started this battle
	var stagger: float = 0.0  # troops frozen after a command change
	var split_lane: int = -1  # lane kept open, -1 = none
	var split_left: float = 0.0
	var splits: int = 0  # times this side opened a lane
	var gen_charge: bool = false  # general fights at the front
	var gen_returning: bool = false  # recalled, walking back slowly
	var home_x: float  # where the general stands when not sent in
	var home_y: float
	# Index of the general in `units`, -1 = none (side loses when all units are gone).
	# An index, not a Unit reference: Unit.side points back here, and a
	# reference cycle would leak.
	var general_idx: int = -1
	var troops: int  # alive non-general units at the start of the step
	var troop_cx: float  # their centre
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
	var front_take: float = 0.0  # general: own damage-taken x at the front (0 = general_charge.front_take)
	var flank_sign: int = 1  # -1 = upper half of the formation, +1 = lower (envelop side)
	var group: int = 0  # 0 = main group, 1 = guard group (squad formations)
	var gox: float = 0.0  # guard: own spot relative to its general
	var goy: float = 0.0
	## Ranged troops (units.<id>.ranged): {speed, close_range, close_mult,
	## melee_take, aim_y, arc}. Empty = melee. A ranged unit stands and shoots
	## from its reach (long, DF style) at the enemy straight ahead (aim_y x the
	## usual y weight when picking targets, so it keeps to its own row); the
	## shot lands after distance / speed s. An enemy closer than close_range
	## gets a weak point-blank hit (close_mult x) instead, and a ranged unit
	## caught in melee takes melee_take x damage (shots and specials don't).
	var ranged: Dictionary = {}


var cfg: Dictionary
var rng: BattleRng
var units: Array[Unit] = []
var sides: Array[Army] = []
var time: float = 0.0
var over: String = ""  # "" while running, then a side id or "draw"
## "field" = the army battle; "offer" = troops gone on both sides, each side
## chooses duel or retreat; "duel" = the generals' one-on-one (watch only).
var phase: String = "field"
## Duel state: {"order": [side ids in attack order], "turn": index into order,
## "hits_left", "wait": s to the next blow, "choices": side id -> "duel"/"retreat"}
var duel: Dictionary = {}
var retreated: String = ""  # side id that pulled its general out ("" = none)
var record_events: bool = true
## Shots in flight from ranged troops: {by, tgt (unit ids, units[id] is the
## unit), x0, y0, tx, ty, t, dur, dmg, arc}. BattleView draws them.
var shots: Array = []

var _events: Array = []
var _next_id: int = 0
var _field: Dictionary
var _combat: Dictionary
var _time_limit: float
var _lanes: int = 0
var _split_cfg: Dictionary
var _gcharge_cfg: Dictionary
var _switch_delay: float = 0.0
var _special_take: bool = false


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


## overrides: per side id, any of {"formation", "order", "auto_cast",
## "auto_slot", "ai", "dodge", "gcharge"}.
##   auto_cast: fire special auto_slot (default: the largest) as soon as it is
##              ready (best lane).
##   ai: BattleAI decides when and where to cast (enemy side in play and in run_sims).
##   dodge: BattleAI opens lanes / pulls back against enemy specials (default = ai).
##   gcharge: "never" | "always" | "ai" — who sends the general in (default
##            "ai" for an AI side, else "never" = the player decides).
## rng: share one BattleRng across battles to reproduce prototype simulate().
func _init(config: Dictionary, overrides: Dictionary = {}, shared_rng: BattleRng = null) -> void:
	cfg = config
	rng = shared_rng if shared_rng != null else BattleRng.new(int(cfg.sim.seed))
	_field = cfg.field
	_combat = cfg.combat
	_time_limit = float(cfg.sim.time_limit)
	_lanes = int(cfg.get("lanes", {}).get("count", 0))
	_split_cfg = cfg.get("split", {})
	_gcharge_cfg = cfg.get("general_charge", {})
	_switch_delay = float(cfg.get("commands", {}).get("switch_delay", 0))
	_special_take = bool(_combat.get("special_take_mult", false))
	var brain_seed := rng.state

	for i in cfg.sides.size():
		var sd: Dictionary = cfg.sides[i]
		var ov: Dictionary = overrides.get(sd.id, {})
		var s := Army.new()
		s.id = sd.id
		s.index = i
		s.facing = int(sd.facing)
		_apply_formation(s, ov.get("formation", sd.formation))
		_apply_order(s, ov.get("order", sd.order))
		s.specials = _specials_for(sd)
		s.special = s.specials[0] if not s.specials.is_empty() else {}
		s.slot_casts.resize(s.specials.size())
		s.slot_casts.fill(0)
		s.auto_slot = int(ov.get("auto_slot", s.specials.size() - 1))
		s.auto_cast = bool(ov.get("auto_cast", false))
		s.mp = float(sd.mp_start)
		s.mp_max = float(sd.mp_max)
		s.wave = {}
		s.pending = {}
		var ai_cast := bool(ov.get("ai", sd.get("ai", false)))
		var dodge := bool(ov.get("dodge", ai_cast))
		var gcharge := str(ov.get("gcharge", "ai" if ai_cast else "never"))
		if gcharge == "always":
			s.gen_charge = true
		if ai_cast or dodge or gcharge == "ai":
			# Own rng (never the sim's), so configs without AI keep the
			# prototype's rng sequence.
			s.brain = BattleAI.new(s.id, cfg.get("ai", {}),
					{"cast": ai_cast, "dodge": dodge, "gcharge": gcharge == "ai", "seed": brain_seed + i * 7919})
		sides.append(s)

	# PROTOTYPE: units spawn interleaved (S0, K0, S1, K1, ...) and each takes
	# 4 rng draws in this exact order: x, y, attack timer, anim.
	# Troop types per spot: sides[].unit x count, or an override "units" =
	# [[type, count], ...] (dev mode: swap or mix troop types). Spots run
	# front to back, so the first entries stand in front (melee first, then
	# ranged behind them).
	var plans: Array = []
	var spots: Array = []
	var mid_y: Array = []
	var n_main: Array = []
	var max_count := 0
	for i in sides.size():
		var sd: Dictionary = cfg.sides[i]
		var plan := unit_plan(sd, overrides.get(sd.id, {}))
		plans.append(plan)
		var formation: Dictionary = cfg.formations[_formation_name(sd, overrides)]
		var sp: Array = _layout_spots(formation, plan.size(), sides[i].facing)
		spots.append(sp)
		n_main.append(plan.size() - _guard_count_for(formation, plan.size()))
		var sum_y := 0.0
		for p in sp:
			sum_y += p[1]
		mid_y.append(sum_y / maxf(1.0, sp.size()))
		max_count = maxi(max_count, plan.size())
	for n in max_count:
		for i in sides.size():
			var sd: Dictionary = cfg.sides[i]
			if n >= plans[i].size():
				continue
			var s := sides[i]
			var spot: Array = spots[i][n]
			var jx := float(sd.spawn_jitter[0])
			var jy := float(sd.spawn_jitter[1])
			var u := _make_unit(s, plans[i][n])
			u.x = spot[0] + float(s.facing) * rng.next() * jx
			u.y = maxf(float(_field.y_min), minf(float(_field.y_max), spot[1] + rng.next() * jy))
			u.t = rng.next() * float(_combat.start_cd_jitter)
			u.anim = rng.next() * float(_combat.anim_jitter)
			u.flank_sign = -1 if spot[1] < mid_y[i] else 1
			if n >= n_main[i]:
				u.group = 1
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
		s.home_x = g.x
		s.home_y = g.y
		g.t = rng.next() * float(_combat.start_cd_jitter)
		g.anim = rng.next() * float(_combat.anim_jitter)
		s.general_idx = units.size()
		units.append(g)
		for u in units:
			if u.side == s and u.group == 1:
				u.gox = u.x - g.x
				u.goy = u.y - g.y


## Advance the battle by dt seconds. Returns the events since the last step
## (including events from commands called between steps).
func step(dt: float) -> Array:
	if over != "":
		return _take_events()
	time += dt
	if phase != "field":
		_step_duel(dt)
		return _take_events()
	var live: Array[Unit] = []
	for u in units:
		if u.alive:
			live.append(u)

	for s in sides:
		s.mp = minf(s.mp_max, s.mp + dt * s.mp_regen)
		s.stagger = maxf(0.0, s.stagger - dt)
		if not s.guard.is_empty():
			s.guard.left -= dt
			if s.guard.left <= 0.0:
				s.guard = {}
				if record_events:
					_events.append({"type": "guard_end", "side": s.id})
		if s.split_lane >= 0:
			s.split_left -= dt
			if s.split_left <= 0.0:
				var lane := s.split_lane
				s.split_lane = -1
				if record_events:
					_events.append({"type": "split_end", "side": s.id, "lane": lane})
	for s in sides:
		if s.brain != null:
			s.brain.think(self, dt)
		if s.auto_cast and (s.brain == null or not s.brain.do_cast) and special_ready(s.id, s.auto_slot) \
				and time > float(s.specials[s.auto_slot].get("auto_cast_after", 0)):
			cast(s.id, -1, s.auto_slot)
	for s in sides:
		if not s.pending.is_empty():
			_step_pending(s, dt)
	for s in sides:
		if not s.wave.is_empty():
			_step_wave(s, dt, live)

	var engaged := {}
	for u in live:
		if u.tg != null and u.tg.alive:
			engaged[u.tg.id] = engaged.get(u.tg.id, 0) + 1
	_update_troop_centres(live)
	var slots := _surround_slots(live)

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
	var crowd_atk := float(_split_cfg.get("crowd_atk", 1))
	var mp_on_hit := float(_gcharge_cfg.get("mp_on_hit", 0))
	var channel_take := float(_gcharge_cfg.get("channel_take", 1))
	var front_take := float(_gcharge_cfg.get("front_take", 1))

	# PROTOTYPE: loops over the snapshot without re-checking `alive`, so a unit
	# killed earlier in this step still moves and can still attack this step.
	for u in live:
		u.anim += dt
		u.fx = maxf(0.0, u.fx - dt)
		u.t -= dt
		u.re -= dt
		var us := u.side
		# Commands that override fighting: frozen after a change, channelling,
		# stepping out of an opened lane, retreating.
		if us.stagger > 0.0 and not u.is_general:
			u.walking = false
			continue
		if u.is_general and not us.pending.is_empty():
			u.walking = false
			continue
		if us.split_lane >= 0 and not u.is_general and _in_lane(us.split_lane, u.y):
			_step_out_of_lane(u, dt)
			continue
		var gmode := _guarding(u)
		# Retreat moves troops only: a general never turns its back on a fight.
		# Guards stay with their general.
		if us.retreating and not u.is_general and not gmode:
			_retreat(u, dt, move_y)
			continue
		# A general fights whoever is within its reach, one at a time, before
		# anything else (never stepping out to answer longer reaches).
		var foe: Unit = _foe_in_reach(u, live) if u.is_general else null
		if foe != null:
			u.tg = foe
		elif gmode:
			if not _guard_pick(u, live):
				_to_guard_spot(u, dt, move_y)
				continue
		elif u.tg == null or not u.tg.alive or u.re <= 0.0:
			var best: Unit = null
			var bd := 1e9
			var uy_w := y_w * float(u.ranged.get("aim_y", 1)) if not u.ranged.is_empty() else y_w
			for v in live:
				if v.side != us and v.alive:
					var ex := v.x - u.x
					var ey := (v.y - u.y) * uy_w
					var dd := ex * ex + ey * ey
					if v.is_general and not u.is_general:
						dd *= us.general_pull
					# A general left without troops goes for the nearest enemy
					# soldier (the enemy general only once its troops are gone).
					elif v.is_general and u.is_general and us.troops == 0 and v.side.troops > 0:
						dd *= 1e6
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
		# A general not sent in holds its post: it hits whoever reaches it but
		# never chases (walks back to the post after a recall, but only once
		# nobody is fighting it). With no troops left it fights on its own.
		if u.is_general and foe == null and not us.gen_charge and us.troops > 0 and d > u.reach:
			_hold_post(u, dt, move_y)
			continue
		# Mobbing a general: take a spot around it rather than piling up in front.
		var slot = slots.get(u.id) if v.is_general and not u.is_general and u.ranged.is_empty() else null
		if slot != null and (d > u.reach or u.t > 0.0):
			if us.hold_range > 0.0 and d > us.hold_range and not gmode:
				u.walking = false
			else:
				_to_slot(u, v, float(slot), dt, move_y)
			if d > u.reach:
				continue
		if d > u.reach:
			# hold_range keeps troops in place; generals follow their own rules above.
			if us.hold_range > 0.0 and d > us.hold_range and not u.is_general and not gmode:
				u.walking = false
				continue
			var sp := u.spd * us.form_spd
			var my := dy * move_y
			# Envelop: swing out above/below the enemy general instead of straight at it.
			if us.envelop > 0.0 and v.is_general and not u.is_general and d > u.reach * 2.0:
				my = (dy + float(u.flank_sign) * us.envelop) * move_y
			var dm := BattleMath.hypot(dx, my)
			if dm == 0.0:
				dm = 1.0
			var nx := u.x + dx / dm * sp * dt
			var ny := u.y + my / dm * sp * dt
			if us.split_lane >= 0 and not u.is_general:
				ny = _keep_out_of_lane(us.split_lane, u.y, ny)
			if _leashed(u, nx, ny):
				u.walking = false
			else:
				u.x = nx
				u.y = ny
				u.walking = true
		else:
			if slot == null:
				u.walking = false
			if u.t <= 0.0:
				u.t = u.cd * (cd_min + rng.next() * cd_jit)
				u.swing = swing_time
				# Multiplier order matters for bit-exact results; keep it.
				var dmg := u.atk * (dmg_min + rng.next() * dmg_jit)
				dmg *= us.order_atk
				dmg *= v.side.order_take
				dmg *= us.form_atk
				if us.flank != 1.0 and engaged.get(v.id, 0) >= us.flank_min:
					dmg *= us.flank
				dmg *= v.side.form_take
				if not v.side.guard.is_empty():
					dmg *= float(v.side.guard.take)
				if us.split_lane >= 0:
					dmg *= crowd_atk
				if gmode and us.guard_atk != 1.0:
					dmg *= us.guard_atk
				if v.side.guard_take != 1.0 and _guarding(v):
					dmg *= v.side.guard_take
				# Out at the front (sent in, or recalled but not back yet).
				if v.is_general and (v.side.gen_charge or v.side.gen_returning):
					dmg *= v.front_take if v.front_take > 0.0 else front_take
					if not v.side.pending.is_empty():
						dmg *= channel_take
				if not u.ranged.is_empty() and d > float(u.ranged.get("close_range", 0)):
					_fire(u, v, dmg, d)
				else:
					if not u.ranged.is_empty():
						dmg *= float(u.ranged.get("close_mult", 1))
					if not v.ranged.is_empty():
						dmg *= float(v.ranged.get("melee_take", 1))
					_apply_hit(u, v, dmg, hit_flash, mp_on_hit)
		if u.swing > 0.0:
			u.swing = maxf(0.0, u.swing - dt)

	_step_shots(dt, float(_combat.hit_flash), mp_on_hit)
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
	elif _both_armies_gone():
		_offer_duel()
	if over != "":
		_clear_targets()
		if record_events:
			_events.append({"type": "over", "winner": over})
	return _take_events()


func _take_events() -> Array:
	var out := _events
	_events = []
	return out


## Change a side's order mid-battle (charge / hold / retreat). A real change
## freezes the troops for switch_delay seconds.
func set_order(side_id: String, order_name: String) -> void:
	var s := get_side(side_id)
	if s == null or phase != "field" or not cfg.orders.has(order_name) or s.order_name == order_name:
		return
	_apply_order(s, order_name)
	if over == "" and time > 0.0:
		s.stagger = maxf(s.stagger, _switch_delay)
	if record_events:
		_events.append({"type": "order", "side": s.id, "order": order_name})


## Open a lane (0 = top .. lanes-1 = bottom) for split.duration seconds.
## The same lane again closes it early. Returns false without lanes.
func split(side_id: String, lane: int) -> bool:
	var s := get_side(side_id)
	if s == null or over != "" or phase != "field" or lane < 0 or lane >= _lanes:
		return false
	if s.split_lane == lane:
		s.split_lane = -1
		if record_events:
			_events.append({"type": "split_end", "side": s.id, "lane": lane})
		return true
	s.split_lane = lane
	s.split_left = float(_split_cfg.get("duration", 3))
	s.splits += 1
	if record_events:
		var b := lane_bounds(lane)
		_events.append({"type": "split", "side": s.id, "lane": lane, "y0": b.x, "y1": b.y})
	return true


## Send the general to fight at the front (on) or call it back (off).
func set_general_charge(side_id: String, on: bool) -> void:
	var s := get_side(side_id)
	var g := general_of(side_id)
	if s == null or g == null or not g.alive or over != "" or phase != "field" or s.gen_charge == on:
		return
	s.gen_charge = on
	s.gen_returning = not on
	if record_events:
		_events.append({"type": "gcharge", "side": s.id, "on": on})


## Squad formations: release the guard group to fight like the main group (on)
## or call it back to the general (off). Returns false if the side has no squads.
func set_guard_out(side_id: String, on: bool) -> bool:
	var s := get_side(side_id)
	if s == null or not s.squads or over != "" or phase != "field":
		return false
	if s.guard_out == on:
		return true
	s.guard_out = on
	if record_events:
		_events.append({"type": "guard_out", "side": s.id, "on": on})
	return true


## Alive troops of a side by group: Vector2i(main, guard).
func group_counts(side_id: String) -> Vector2i:
	var out := Vector2i.ZERO
	for u in units:
		if u.alive and not u.is_general and u.side.id == side_id:
			if u.group == 1:
				out.y += 1
			else:
				out.x += 1
	return out


## Call if a battle is abandoned before it ends (e.g. player quits).
## Units target each other, and those reference cycles would otherwise leak.
func dispose() -> void:
	_clear_targets()


func _clear_targets() -> void:
	for u in units:
		u.tg = null
	shots.clear()


## Damage lands on v: HP, flash, MP for a general at the front, hit event, death.
func _apply_hit(u: Unit, v: Unit, dmg: float, hit_flash: float, mp_on_hit: float) -> void:
	var us := u.side
	v.hp -= dmg
	v.fx = hit_flash
	if u.is_general and us.gen_charge and mp_on_hit > 0.0:
		us.mp = minf(us.mp_max, us.mp + mp_on_hit)
	if record_events:
		_events.append({"type": "hit", "id": v.id, "by": u.id, "x": v.x, "y": v.y,
				"side": v.side.id, "dmg": dmg})
	if v.hp <= 0.0:
		_kill(v)


## A ranged unit looses a shot at v; the damage (worked out now) lands when it
## arrives, if v is still alive (a shot at a fallen target is wasted).
func _fire(u: Unit, v: Unit, dmg: float, d: float) -> void:
	var speed := maxf(1.0, float(u.ranged.get("speed", 160)))
	shots.append({"by": u.id, "tgt": v.id, "x0": u.x, "y0": u.y, "tx": v.x, "ty": v.y,
			"t": 0.0, "dur": d / speed, "dmg": dmg, "arc": float(u.ranged.get("arc", 10))})
	if record_events:
		_events.append({"type": "shoot", "id": u.id, "tgt": v.id, "x": u.x, "y": u.y, "side": u.side.id})


func _step_shots(dt: float, hit_flash: float, mp_on_hit: float) -> void:
	if shots.is_empty():
		return
	var keep: Array = []
	for sh in shots:
		var v: Unit = units[sh.tgt]
		if v.alive:
			sh.tx = v.x
			sh.ty = v.y
		sh.t += dt
		if sh.t < sh.dur:
			keep.append(sh)
		elif v.alive:
			_apply_hit(units[sh.by], v, float(sh.dmg), hit_flash, mp_on_hit)
	shots = keep


## Troop type per spot for side config sd: override "units" = [[type, count],
## ...] if given, else sd.unit x sd.count.
static func unit_plan(sd: Dictionary, ov: Dictionary = {}) -> Array:
	var out: Array = []
	var mix: Array = ov.get("units", [])
	if mix.is_empty():
		mix = [[sd.unit, int(sd.count)]]
	for part in mix:
		for k in int(part[1]):
			out.append(str(part[0]))
	return out


## Start one of a side's specials. Returns false if not ready.
## slot: 0 small, 1 medium, 2 large; -1 = the largest one ready now.
## lane: for a lane special, the lane to hit; -1 = best lane now
## (BattleAI.best_lane), so the player's one button aims sensibly. A special
## aimed at the general (targets: general) always runs down the enemy
## general's lane; a guard covers the caster's own side.
## MP is paid now; the special takes effect after its "telegraph" warning time.
func cast(side_id: String, lane: int = -1, slot: int = -1) -> bool:
	var s := get_side(side_id)
	if s == null:
		return false
	if slot < 0:
		slot = largest_ready(side_id)
	if slot < 0 or not special_ready(side_id, slot):
		return false
	var sp: Dictionary = s.specials[slot]
	s.special = sp
	var span := int(sp.get("lanes", 0))
	var y0 := float(_field.y_min) - 20.0
	var y1 := float(_field.y_max) + 20.0
	if is_guard(sp):
		lane = -1
	elif str(sp.get("targets", "all")) == "general" and _lanes > 0:
		var eg := _enemy_general(s)
		lane = lane_of(eg.y) if eg != null else 1
		span = 1
		y0 = lane_bounds(lane).x
		y1 = lane_bounds(lane).y
	elif span > 0 and _lanes > 0:
		span = mini(span, _lanes)
		if lane < 0:
			lane = BattleAI.best_lane(self, s, BattleAI.merged(cfg.get("ai", {})), null, sp).lane
		lane = clampi(lane, 0, _lanes - span)
		y0 = lane_bounds(lane).x
		y1 = lane_bounds(lane + span - 1).y
	else:
		lane = -1
	s.mp -= float(sp.mp_cost)
	s.casts += 1
	s.slot_casts[slot] += 1
	var tele := float(sp.get("telegraph", 0))
	s.pending = {"t": tele, "total": tele, "lane": lane, "y0": y0, "y1": y1, "slot": slot}
	if record_events:
		_events.append({"type": "cast", "side": s.id, "special": sp, "lane": lane, "y0": y0, "y1": y1,
				"telegraph": tele, "slot": slot})
	if tele <= 0.0:
		_launch(s)
	return true


## True if the side can start a special now: slot -1 = any of them.
## Not while one is warming up or running; a guard not while a guard is up.
func special_ready(side_id: String, slot: int = -1) -> bool:
	var s := get_side(side_id)
	if over != "" or phase != "field" or s == null or s.specials.is_empty() \
			or not s.wave.is_empty() or not s.pending.is_empty():
		return false
	if slot < 0:
		return largest_ready(side_id) >= 0
	if slot >= s.specials.size():
		return false
	var sp: Dictionary = s.specials[slot]
	if is_guard(sp) and not s.guard.is_empty():
		return false
	return s.mp >= float(sp.mp_cost)


## Highest slot whose special can start now, -1 = none.
func largest_ready(side_id: String) -> int:
	var s := get_side(side_id)
	if s == null:
		return -1
	for i in range(s.specials.size() - 1, -1, -1):
		var sp: Dictionary = s.specials[i]
		if s.mp >= float(sp.mp_cost) and not (is_guard(sp) and not s.guard.is_empty()):
			return i if special_ready(side_id, i) else -1
	return -1


## A defence special (raises the caster's own guard instead of hitting anyone).
static func is_guard(sp: Dictionary) -> bool:
	return str(sp.get("type", "")) == "guard"


## Where a side's special would start, in the special's own coordinates
## (px from the caster's edge): in front of its general, or start_x.
## sp: the special (default: the side's current one).
func launch_x(s: Army, sp: Dictionary = {}) -> float:
	if sp.is_empty():
		sp = s.special
	var g := general_of(s.id)
	if g != null and g.alive and sp.has("launch_offset"):
		var lx := g.x if s.facing == 1 else float(_field.width) - g.x
		return lx + float(sp.launch_offset)
	return float(sp.get("start_x", 0))


## Damage a special does to u when its front has travelled `travelled` px.
## Generals take damage_general when set (troops are many and small, generals
## are one big unit, so the two are tuned apart), else damage. A guard on u's
## side cuts it like a normal hit. sp: the special (default: the side's current one).
func special_damage(s: Army, u: Unit, travelled: float, sp: Dictionary = {}) -> float:
	if sp.is_empty():
		sp = s.special
	var dmg := float(sp.get("damage", 0))
	if u.is_general and sp.has("damage_general"):
		dmg = float(sp.damage_general)
	var rng_px := float(sp.get("range", 0))
	if rng_px > 0.0:
		var k := clampf(travelled / rng_px, 0.0, 1.0)
		dmg *= lerpf(1.0, float(sp.get("min_damage_pct", 100)) / 100.0, k)
	if _special_take:
		dmg *= u.side.order_take * u.side.form_take
		if u.side.guard_take != 1.0 and _guarding(u):
			dmg *= u.side.guard_take
	if not u.side.guard.is_empty():
		dmg *= float(u.side.guard.take)
	return dmg


## Number of lanes (0 = no lanes, the prototype field).
func lane_count() -> int:
	return _lanes


## Lane i's top and bottom y as Vector2(y0, y1).
func lane_bounds(i: int) -> Vector2:
	var y_min := float(_field.y_min)
	var h := (float(_field.y_max) - y_min) / maxf(1.0, _lanes)
	return Vector2(y_min + i * h, y_min + (i + 1) * h)


## Lane at height y (clamped to the field).
func lane_of(y: float) -> int:
	if _lanes <= 0:
		return -1
	var y_min := float(_field.y_min)
	var h := (float(_field.y_max) - y_min) / _lanes
	return clampi(int(floor((y - y_min) / h)), 0, _lanes - 1)


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


## Why a side lost: "retreat" (pulled out before the duel), "duel" (its
## general fell in the duel), "general" (fell on the field) or "wiped".
func defeat_reason(side_id: String) -> String:
	if retreated == side_id:
		return "retreat"
	var g := general_of(side_id)
	if g != null and not g.alive and not duel.is_empty() and duel.has("order"):
		return "duel"
	if g != null and not g.alive:
		return "general"
	return "wiped"


## A side's general, or null if it has none.
func general_of(side_id: String) -> Unit:
	var s := get_side(side_id)
	if s == null or s.general_idx < 0:
		return null
	return units[s.general_idx]


## The general of the side facing s, or null.
func _enemy_general(s: Army) -> Unit:
	for o in sides:
		if o != s:
			var g := general_of(o.id)
			if g != null and g.alive:
				return g
	return null


## A side's special slots: its general's "specials" list (small, medium,
## large), else the side's single "special".
func _specials_for(sd: Dictionary) -> Array:
	var out: Array = []
	var gdef: Dictionary = cfg.units.get(sd.get("general", ""), {})
	for id in gdef.get("specials", []):
		assert(cfg.specials.has(id), "BattleSim: unknown special '%s'" % id)
		out.append(cfg.specials[id])
	if out.is_empty() and cfg.specials.has(sd.get("special", "")):
		out.append(cfg.specials[sd.special])
	return out


func get_side(side_id: String) -> Army:
	for s in sides:
		if s.id == side_id:
			return s
	return null


# --- duel ----------------------------------------------------------------------
# When both armies are gone (generals still standing), the battle cuts to a
# one-on-one duel like DF. First each side chooses: duel, or retreat (the
# general survives but the battle is lost). Then the generals trade blows in
# turns, the faster one first. Each general's "duel" style in the config:
#   hits: blows per turn · power: damage per blow · jitter: +- share of power
#   accuracy: chance each blow lands
# so one general can strike twice lightly and another once and hard. The
# player only watches; no specials. Timing (duel_rules): offer_time = how long
# an undecided side has before the duel starts anyway (headless sims: AI picks
# at once), turn_gap / hit_gap = s between turns / blows.

## Choose for a side during the offer: "duel" or "retreat".
func duel_choice(side_id: String, choice: String) -> void:
	if phase != "offer" or not duel.choices.has(side_id) or duel.choices[side_id] != "":
		return
	duel.choices[side_id] = "retreat" if choice == "retreat" else "duel"
	if record_events:
		_events.append({"type": "duel_choice", "side": side_id, "choice": duel.choices[side_id]})


## A general's duel style with defaults filled in.
func duel_style(g: Unit) -> Dictionary:
	var st: Dictionary = {"hits": 1, "power": g.atk * 2.0, "jitter": 0.2, "accuracy": 1.0}
	var d: Dictionary = cfg.units.get(g.type_id, {}).get("duel", {})
	for k in d:
		st[k] = d[k]
	return st


## Expected damage per turn of a general in the duel.
func duel_turn_damage(g: Unit) -> float:
	var st := duel_style(g)
	return float(st.hits) * float(st.power) * float(st.accuracy)


func _both_armies_gone() -> bool:
	for s in sides:
		var g := general_of(s.id)
		if g == null or not g.alive or s.troops > 0 or troop_count(s.id) > 0:
			return false
	return true


func _rules() -> Dictionary:
	var r := {"offer_time": 8.0, "turn_gap": 0.9, "hit_gap": 0.3, "start_gap": 1.2}
	var c: Dictionary = cfg.get("duel_rules", {})
	for k in c:
		if not str(k).begins_with("_"):
			r[k] = c[k]
	return r


func _offer_duel() -> void:
	phase = "offer"
	var choices := {}
	for s in sides:
		choices[s.id] = ""
		s.pending = {}
		s.wave = {}
		s.guard = {}
		s.split_lane = -1
		s.gen_charge = false
		s.gen_returning = false
	duel = {"choices": choices, "offer_left": float(_rules().offer_time)}
	_clear_targets()
	for u in units:
		u.walking = false
	if record_events:
		_events.append({"type": "duel_offer"})


func _step_duel(dt: float) -> void:
	for u in units:
		u.anim += dt
		u.fx = maxf(0.0, u.fx - dt)
		u.swing = maxf(0.0, u.swing - dt)
	if phase == "offer":
		for s in sides:
			if s.brain != null and duel.choices[s.id] == "":
				s.brain.think(self, dt)
		duel.offer_left -= dt
		var undecided := false
		for k in duel.choices:
			if duel.choices[k] == "":
				undecided = true
		if undecided and duel.offer_left > 0.0:
			return
		_resolve_offer()
		return
	duel.wait -= dt
	if duel.wait > 0.0:
		return
	var r := _rules()
	var atk_side: String = duel.order[duel.turn]
	var def_side: String = duel.order[1 - duel.turn]
	var a := general_of(atk_side)
	var v := general_of(def_side)
	var st := duel_style(a)
	var hit := rng.next() < float(st.accuracy)
	var dmg := 0.0
	if hit:
		dmg = float(st.power) * (1.0 + (rng.next() * 2.0 - 1.0) * float(st.jitter))
		v.hp -= dmg
		v.fx = float(_combat.hit_flash)
	a.swing = float(_combat.swing_time)
	duel.hits_left -= 1
	if record_events:
		_events.append({"type": "duel_hit", "side": atk_side, "by": a.id, "id": v.id, "dmg": dmg,
				"miss": not hit, "x": v.x, "y": v.y})
	if v.hp <= 0.0:
		_kill(v)
		over = atk_side
		if record_events:
			_events.append({"type": "over", "winner": over})
		return
	if duel.hits_left > 0:
		duel.wait = float(r.hit_gap)
	else:
		duel.turn = 1 - duel.turn
		duel.hits_left = int(duel_style(general_of(duel.order[duel.turn])).hits)
		duel.wait = float(r.turn_gap)


func _resolve_offer() -> void:
	var out: Array = []
	for k in duel.choices:
		if duel.choices[k] == "retreat":
			out.append(k)
	if out.size() > 0:
		if out.size() == 1:
			retreated = out[0]
			over = sides[1].id if sides[0].id == retreated else sides[0].id
		else:
			over = "draw"
			retreated = out[0]
		if record_events:
			_events.append({"type": "duel_retreat", "sides": out})
			_events.append({"type": "over", "winner": over})
		return
	# Duel: generals face each other, faster one strikes first.
	phase = "duel"
	var ga := general_of(sides[0].id)
	var gb := general_of(sides[1].id)
	var first := 0 if ga.spd >= gb.spd else 1
	var order := [sides[first].id, sides[1 - first].id]
	duel.order = order
	duel.turn = 0
	duel.hits_left = int(duel_style(general_of(order[0])).hits)
	duel.wait = float(_rules().start_gap)
	if record_events:
		_events.append({"type": "duel_start", "first": order[0]})


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


const GUARD_LEASH_EXTRA := 20.0  # guards chase this far past guard_radius
const GUARD_KEEP_EXTRA := 10.0  # a guard keeps a target this far past guard_radius


## A guard-group soldier on guard duty (not released, general still up).
func _guarding(u: Unit) -> bool:
	if u.group != 1 or u.is_general or u.side.guard_out or u.side.general_idx < 0:
		return false
	return units[u.side.general_idx].alive


## Guard duty: keep the current target while it stays near the general, else
## the nearest enemy within guard_radius of it. False (and no target) if none.
func _guard_pick(u: Unit, live: Array[Unit]) -> bool:
	var g: Unit = units[u.side.general_idx]
	var r := u.side.guard_radius
	var t := u.tg
	if t != null and t.alive and t.side != u.side \
			and BattleMath.hypot(t.x - g.x, t.y - g.y) <= r + GUARD_KEEP_EXTRA:
		return true
	var best: Unit = null
	var bd := 1e9
	for v in live:
		if not v.alive or v.side == u.side:
			continue
		if BattleMath.hypot(v.x - g.x, v.y - g.y) > r:
			continue
		var d := BattleMath.hypot(v.x - u.x, v.y - u.y)
		if d < bd:
			bd = d
			best = v
	u.tg = best
	return best != null


## Guard with nothing to fight: back to its spot round the general.
func _to_guard_spot(u: Unit, dt: float, move_y: float) -> void:
	var g: Unit = units[u.side.general_idx]
	var tx := clampf(g.x + u.gox, float(_field.x_min), float(_field.x_max))
	var ty := clampf(g.y + u.goy, float(_field.y_min), float(_field.y_max))
	var dx := tx - u.x
	var dy := ty - u.y
	var dist := BattleMath.hypot(dx, dy)
	if dist < 1.5:
		u.walking = false
		return
	var sp := minf(u.spd * u.side.form_spd, dist / dt)
	var my := dy * move_y
	var dm := BattleMath.hypot(dx, my)
	if dm == 0.0:
		dm = 1.0
	u.x += dx / dm * sp * dt
	var ny := u.y + my / dm * sp * dt
	if u.side.split_lane >= 0:
		ny = _keep_out_of_lane(u.side.split_lane, u.y, ny)
	u.y = ny
	u.walking = true


## Guard formations: a soldier won't step farther from its general than `leash`
## (moving back toward it is always allowed).
func _leashed(u: Unit, nx: float, ny: float) -> bool:
	var lim := u.side.leash
	if _guarding(u):
		var gl := u.side.guard_radius + GUARD_LEASH_EXTRA
		lim = gl if lim <= 0.0 else minf(lim, gl)
	if lim <= 0.0 or u.is_general or u.side.general_idx < 0:
		return false
	var g: Unit = units[u.side.general_idx]
	if not g.alive:
		return false
	var dn := BattleMath.hypot(nx - g.x, ny - g.y)
	if dn <= lim:
		return false
	return dn > BattleMath.hypot(u.x - g.x, u.y - g.y)


## The enemy a general fights right now, or null: its current target while
## that is still alive and within reach (finish one before the next), else the
## nearest enemy within its reach.
func _foe_in_reach(g: Unit, live: Array[Unit]) -> Unit:
	var t := g.tg
	if t != null and t.alive and t.side != g.side and BattleMath.hypot(t.x - g.x, t.y - g.y) <= g.reach:
		return t
	var best: Unit = null
	var bd := 1e9
	for v in live:
		if not v.alive or v.side == g.side:
			continue
		var d := BattleMath.hypot(v.x - g.x, v.y - g.y)
		if d <= g.reach and d < bd:
			bd = d
			best = v
	return best


## A general standing (at its post, or fighting): crowding never moves it.
func _anchored(u: Unit) -> bool:
	return u.is_general and not u.walking


## Spots around each general for the enemy troops going at it: unit id ->
## angle (radians) around the general. The attackers keep their order around
## it (sorted by the angle they come from) and are spread evenly over the full
## circle, so a mob ends up in front of, behind, above and below it.
func _surround_slots(live: Array[Unit]) -> Dictionary:
	var by_gen := {}
	for u in live:
		if u.alive and not u.is_general and u.tg != null and u.tg.alive and u.tg.is_general \
				and u.tg.side != u.side:
			if not by_gen.has(u.tg.id):
				by_gen[u.tg.id] = []
			by_gen[u.tg.id].append(u)
	var out := {}
	for gid in by_gen:
		var mob: Array = by_gen[gid]
		var g: Unit = mob[0].tg
		var ang := []
		for u in mob:
			ang.append([atan2(u.y - g.y, u.x - g.x), u.id, u])
		ang.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
		var n := ang.size()
		var base: float = ang[0][0]
		for k in n:
			out[ang[k][2].id] = base + TAU * k / n
	return out


## Walk toward a spot around general g (angle a), going round it rather than
## through it.
func _to_slot(u: Unit, g: Unit, a: float, dt: float, move_y: float) -> void:
	var r := minf(u.reach - 1.0, u.radius + g.radius)
	var cur := atan2(u.y - g.y, u.x - g.x)
	var diff := wrapf(a - cur, -PI, PI)
	var aim := a
	var rr := r
	if absf(diff) > 0.6:
		aim = cur + signf(diff) * 0.6
		rr = r + 6.0
	var tx := g.x + cos(aim) * rr
	var ty := g.y + sin(aim) * rr
	var dx := tx - u.x
	var dy := ty - u.y
	var dist := BattleMath.hypot(dx, dy)
	if dist < 1.5:
		u.walking = false
		return
	var sp := minf(u.spd * u.side.form_spd, dist / dt)
	var my := dy * move_y
	var dm := BattleMath.hypot(dx, my)
	if dm == 0.0:
		dm = 1.0
	var nx := u.x + dx / dm * sp * dt
	var ny := u.y + my / dm * sp * dt
	if _leashed(u, nx, ny):
		u.walking = false
		return
	u.x = nx
	u.y = ny
	u.walking = true


## General not sent in: stands at its post (where it started); after a
## recall it walks back there
## at return_spd_mult x speed.
func _hold_post(u: Unit, dt: float, move_y: float) -> void:
	var s := u.side
	var dx := s.home_x - u.x
	var dy := s.home_y - u.y
	var d := BattleMath.hypot(dx, dy)
	if d < 2.0:
		u.walking = false
		s.gen_returning = false
		return
	var spd := u.spd * s.form_spd
	if s.gen_returning:
		spd *= float(_gcharge_cfg.get("return_spd_mult", 1))
	var sp := minf(spd, d / dt)
	var my := dy * move_y
	var dm := BattleMath.hypot(dx, my)
	if dm == 0.0:
		dm = 1.0
	u.x += dx / dm * sp * dt
	var ny := u.y + my / dm * sp * dt
	u.y = ny
	u.walking = true


func _in_lane(lane: int, y: float) -> bool:
	var b := lane_bounds(lane)
	var m := float(_split_cfg.get("margin", 0))
	return y > b.x - m and y < b.y + m


## y after a move from y_old to y_new, stopped at the edge of an open lane.
func _keep_out_of_lane(lane: int, y_old: float, y_new: float) -> float:
	if not _in_lane(lane, y_new):
		return y_new
	return y_old if not _in_lane(lane, y_old) else y_new


## A unit inside an opened lane steps out to the nearer neighbouring lane
## (top and bottom lanes can only empty toward the middle).
func _step_out_of_lane(u: Unit, dt: float) -> void:
	var s := u.side
	var b := lane_bounds(s.split_lane)
	var m := float(_split_cfg.get("margin", 0)) + 1.0
	var up := b.x - m
	var down := b.y + m
	var ty: float
	if s.split_lane == 0:
		ty = down
	elif s.split_lane == _lanes - 1:
		ty = up
	else:
		ty = up if u.y - up < down - u.y else down
	var sp := u.spd * s.form_spd * float(_split_cfg.get("speed_mult", 1))
	var step_y := sp * dt
	u.y = ty if absf(ty - u.y) <= step_y else u.y + signf(ty - u.y) * step_y
	u.walking = true


## Order "retreat": walk back toward the own edge, no attacks.
func _retreat(u: Unit, dt: float, _move_y: float) -> void:
	var s := u.side
	var edge := float(_field.x_min) + 6.0 if s.facing == 1 else float(_field.x_max) - 6.0
	var dx := edge - u.x
	if absf(dx) < 1.0:
		u.walking = false
		return
	var sp := u.spd * s.form_spd * s.order_spd
	u.x += signf(dx) * minf(absf(dx), sp * dt)
	u.walking = true


func _step_pending(s: Army, dt: float) -> void:
	var g := general_of(s.id)
	if g != null and not g.alive:
		s.pending = {}
		if record_events:
			_events.append({"type": "cancel", "side": s.id})
		return
	s.pending.t -= dt
	if s.pending.t <= 0.0:
		_launch(s)


func _launch(s: Army) -> void:
	var p := s.pending
	var sp := s.special
	s.pending = {}
	if is_guard(sp):
		var dur := float(sp.get("duration", 5))
		s.guard = {"take": float(sp.get("take_mult", 1)), "left": dur, "total": dur, "special": sp}
		if record_events:
			_events.append({"type": "guard", "side": s.id, "special": sp})
		return
	var x0 := launch_x(s)
	s.wave = {"x": x0, "x0": x0, "y0": float(p.y0), "y1": float(p.y1), "lane": p.lane, "hit": {}, "power": 1.0}
	if record_events:
		_events.append({"type": "launch", "side": s.id, "x0": x0, "lane": p.lane})


func _step_wave(s: Army, dt: float, live: Array[Unit]) -> void:
	var sp := s.special
	var w := s.wave
	w.x += float(sp.speed) * dt
	var width := float(_field.width)
	var band := float(sp.width)
	var kb := float(sp.get("knockback", 0))
	var y0 := float(w.y0)
	var y1 := float(w.y1)
	# A bolt at the general loses block_pct of its power per troop it passes.
	var block := float(sp.get("block_pct", 0)) / 100.0
	for u in live:
		if u.side != s and u.alive and not w.hit.has(u.id):
			if u.y < y0 or u.y > y1:
				continue
			# Wave coordinates run from the caster's edge of the field.
			var lx := u.x if s.facing == 1 else width - u.x
			if lx < w.x and lx > w.x - band:
				w.hit[u.id] = true
				var dmg := special_damage(s, u, lx - float(w.x0)) * float(w.power)
				if block > 0.0 and not u.is_general:
					w.power = float(w.power) * (1.0 - block)
				if dmg <= 0.0:
					continue
				u.hp -= dmg
				u.fx = float(sp.hit_flash)
				if record_events:
					_events.append({"type": "wavehit", "id": u.id, "x": u.x, "y": u.y,
							"side": u.side.id, "by": s.id, "dmg": dmg})
				if u.hp <= 0.0:
					_kill(u)
				elif kb > 0.0:
					u.x = clampf(u.x + float(s.facing) * kb, float(_field.x_min), float(_field.x_max))
	var rng_px := float(sp.get("range", 0))
	if w.x > float(sp.end_x) or (rng_px > 0.0 and w.x - float(w.x0) > rng_px):
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
		m.group = v.group
		m.gox = v.gox
		m.goy = v.goy
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
			# A soldier fighting an enemy general may stand within its reach
			# (small units would otherwise be held off out of reach).
			if a.side != b.side and a.is_general != b.is_general:
				var s_reach := b.reach if a.is_general else a.reach
				mn = minf(mn, s_reach - 1.0)
			var dx := b.x - a.x
			var dy := b.y - a.y
			var d2 := dx * dx + dy * dy
			if d2 < mn * mn and d2 > min_d2:
				var d := sqrt(d2)
				var p := (mn - d) / 2.0
				# A general at its post doesn't budge: the other one takes the whole push.
				var wa := 0.0 if _anchored(a) else (2.0 if _anchored(b) else 1.0)
				var wb := 0.0 if _anchored(b) else (2.0 if _anchored(a) else 1.0)
				a.x -= dx / d * p * wa
				a.y -= dy / d * p * wa
				b.x += dx / d * p * wb
				b.y += dy / d * p * wb
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
	u.ranged = def.get("ranged", {})
	u.is_general = def.get("role", "") == "general"
	u.front_take = float(def.get("front_take", 0))
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
	s.squads = float(f.get("guard_share", 0)) > 0.0
	s.guard_radius = float(f.get("guard_radius", 90))
	s.guard_atk = float(f.get("guard_atk", 1))
	s.guard_take = float(f.get("guard_take", 1))
	s.guard_out = false


func _apply_order(s: Army, name: String) -> void:
	assert(cfg.orders.has(name), "BattleSim: unknown order '%s'" % name)
	var o: Dictionary = cfg.orders[name]
	s.order_name = name
	s.order_atk = float(o.atk_mult)
	s.order_take = float(o.take_mult)
	s.order_spd = float(o.get("spd_mult", 1))
	s.retreating = bool(o.get("retreat", false))
	s.mp_regen = float(o.mp_regen)
	s.hold_range = float(o.get("hold_range", 0))


## Guard group size for n troops in formation f (0 = no squads).
static func _guard_count_for(f: Dictionary, n: int) -> int:
	var share := float(f.get("guard_share", 0))
	if share <= 0.0:
		return 0
	return clampi(int(round(n * share)), 0, mini(n, f.layout.get("guard_spots", []).size()))


## Spawn spots for n troops: the main group's spots (layout.spots / arc), then
## for squad formations the guard group's (layout.guard_spots).
func _layout_spots(f: Dictionary, n: int, facing: int) -> Array:
	var layout: Dictionary = f.layout
	var ng := _guard_count_for(f, n)
	var out := _layout_main(layout, n - ng)
	var gs: Array = layout.get("guard_spots", [])
	for i in ng:
		out.append([float(gs[i][0]), float(gs[i][1])])
	if facing == -1:
		for p in out:
			p[0] = float(_field.width) - p[0]
	return out


func _layout_main(layout: Dictionary, n: int) -> Array:
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
	return out
