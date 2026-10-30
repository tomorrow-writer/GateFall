## Commands one side of a battle: when and where its general casts, how it
## dodges the other side's specials, and when its general rides into the fight.
##
## Pure logic like BattleSim: reads the sim and only acts through its public
## commands (cast, split, set_order, set_general_charge), never draws from the
## sim rng (it has its own), so configs without AI keep the prototype's rng
## sequence. Nothing here is tied to a race: the same brain runs either side
## (CLAUDE.md section 6), and run_sims can give the player side a brain too
## (e.g. dodging only) to stand in for a player who reacts.
##
## Casting (every think_interval s):
##   Value of a hit on each enemy = share of its max HP the special takes off
##   (with falloff over range and the target's damage-taken multipliers), +
##   kill_bonus if it dies. The enemy general counts general_weight x. Pick the
##   best lane (or the whole field) and cast if it holds min_share of the value
##   of hitting every enemy; full MP lowers that to full_mp_min_share; own
##   general hurt with enemies on it: any hit, those enemies count danger_weight x.
##   With three specials (small / medium / large) every one gets that value;
##   a defence special (guard) is worth the HP it would save: damage our units
##   are taking now (enemies in reach, guard_persist share of its duration)
##   plus enemy specials on their way, x (1 - take_mult); it goes when that is
##   >= guard_min_value. Of the ones worth casting it picks the best value per
##   MP, but saves up (casts nothing) while a dearer one would be worth more
##   than save_ratio x per MP; full MP or a general in danger stop the saving.
##
## Dodging (checked every step): reaction_time s after an enemy cast starts,
##   with chance dodge_skill: a lane special holding dodge_min_units of our
##   troops -> open that lane; a full-field special
##   -> switch to full_response ("hold", "retreat" or "none") until it is over.
##
## General charge (every think_interval s, after charge_after s), by the
##   general's own style (units.<general>.ai_charge): "front" goes in while its
##   HP >= charge_hp alongside troops that are going in; "never" stays; "mopup"
##   (default) is a mop-up
##   charge: send the general in while its HP >= charge_hp, our troops' HP >=
##   charge_adv x theirs and at most charge_max_enemy_troops of theirs are left;
##   call it back when troops fall below return_adv x. A hurt general is never
##   called back (it stands and takes the hits), and a recalled one only walks
##   back once nobody is fighting it (BattleSim._foe_in_reach).
##
## Guard group (squad formations, every think_interval s): release the guards
##   to fight when our troops' HP >= guard_release_adv x theirs (finish them),
##   or when our main group is gone while the enemy holds back (else nobody
##   moves); call them back when ours fall below guard_recall_adv x theirs.
##
## Counter-raid (checked every step with dodging): an enemy raid on the way
##   while we HOLD -> order retreat (troops head home to the general), and back
##   to hold once raiders reach within counter_raid_near px of our general.
##   A charging army keeps fighting (only guards on duty defend the general).
## Formation command (key E for the player, every think_interval s):
##   disperse: used as a dodge (see Dodging): a special down the middle lane
##     only -> split to the top / bottom lanes, regroup once it is over.
##   raid: the raid group fights with the army (follows the order) until
##     launched; the AI raids only while holding (order hold): after
##     raid_after s, with at least raid_min raiders left,
##     never at a general sent into the fight (it is no raid target), when
##     their general stands clear of the fight (none of our others within
##     raid_clear px), their troops' centre is at least raid_gap px from it
##     (their army has left it behind: the way round is open), and our
##     share of troop HP left is at least raid_adv x theirs (not while
##     losing the main fight); no recall. Until then the formation fights like ทัพรุก.
##   divrush: send the first division at once, the next every div_interval s
##     or as soon as fewer than div_min_alive of the ones sent are standing.
## Tuning lives in battle_config.json "ai"; DEFAULTS below fill any gap.
extends RefCounted

const BattleMath = preload("res://scripts/battle/BattleMath.gd")

const DEFAULTS := {
	"think_interval": 0.5,
	"min_share": 0.35,
	"full_mp_min_share": 0.15,
	"kill_bonus": 1.0,
	"general_weight": 10.0,
	"danger_hp": 0.5,
	"danger_range": 70.0,
	"danger_weight": 3.0,
	"reaction_time": 0.6,
	"dodge_skill": 0.85,
	"dodge_min_units": 2.0,
	"full_response": "hold",
	"charge_after": 4.0,
	"charge_hp": 0.7,
	"charge_adv": 1.5,
	"charge_max_enemy_troops": 3,
	"return_adv": 0.7,
	"duel_retreat_ratio": 1.5,
	"save_ratio": 0.8,
	"guard_min_value": 2.0,
	"guard_persist": 0.6,
	"guard_release_adv": 1.5,
	"guard_recall_adv": 0.9,
	"raid_after": 6.0,
	"raid_min": 5,
	"raid_clear": 100.0,
	"raid_gap": 0.0,
	"raid_adv": 0.0,
	"counter_raid_near": 60.0,
	"div_interval": 5.0,
	"div_min_alive": 3,
}

var side_id: String
var tuning: Dictionary
var do_cast := true
var do_dodge := false
var do_gcharge := false
var do_squads := true
## Why the last cast happened ("value", "full_mp", "danger"), for debugging/tools.
var last_reason := ""

var _wait := 0.0
var _rng := RandomNumberGenerator.new()
var _seen := {}  # enemy side id -> casts already noticed
var _react := {}  # enemy side id -> sim time to react at
var _restore_order := ""  # order to go back to after a full-field special
var _restore_watch := ""  # enemy side whose special we are waiting out
var _save_slot := -1  # dearer special we are saving MP for, -1 = none
var _last_div := -1e9  # sim time the last division was sent
var _regroup_watch := ""  # disperse: enemy side whose middle-lane special we split for
var _start_hp := {}  # raid: both sides' troop HP at the first look (own, their)
var _counter_restore := ""  # order to go back to after falling back from a raid ("*" = done)


## opts: {"cast": bool, "dodge": bool, "gcharge": bool, "squads": bool, "seed": int}
func _init(side: String, ai_cfg: Dictionary = {}, opts: Dictionary = {}) -> void:
	side_id = side
	tuning = merged(ai_cfg)
	do_cast = bool(opts.get("cast", true))
	do_dodge = bool(opts.get("dodge", false))
	do_gcharge = bool(opts.get("gcharge", false))
	do_squads = bool(opts.get("squads", true))
	_rng.seed = int(opts.get("seed", 1))


## DEFAULTS overlaid with a config "ai" section (keys starting with _ ignored).
static func merged(ai_cfg: Dictionary) -> Dictionary:
	var t := DEFAULTS.duplicate()
	for k in ai_cfg:
		if not str(k).begins_with("_"):
			t[k] = ai_cfg[k]
	return t


## Called by BattleSim.step() for its side each step.
func think(sim, dt: float) -> void:
	var s = sim.get_side(side_id)
	if s == null:
		return
	if sim.phase == "offer":
		_decide_duel(sim, s)
		return
	if do_dodge:
		_think_dodge(sim, s)
	_wait -= dt
	if _wait > 0.0:
		return
	_wait = float(tuning.think_interval)
	if do_gcharge:
		_think_gcharge(sim, s)
	if do_squads and s.squads:
		_think_guard(sim, s)
	if do_squads and s.form_command != "":
		_think_form_command(sim, s)
	if do_cast:
		_think_cast(sim, s)


# --- casting -------------------------------------------------------------------

func _think_cast(sim, s) -> void:
	if not sim.special_ready(side_id):
		return
	var guard = _general_in_danger(sim, s)
	var full: bool = s.mp >= s.mp_max - 0.001
	var threat := _enemy_special_coming(sim, s)
	var best := {}
	var best_eff := -1.0
	var top_eff := 0.0  # best value per MP among the ones worth casting, affordable or not
	var top_slot := -1
	var save_ok := false  # the special we were saving for is still worth it
	for slot in s.specials.size():
		var sp: Dictionary = s.specials[slot]
		if sim.time <= float(sp.get("auto_cast_after", 0)):
			continue
		var plan := plan_special(sim, s, sp, tuning, guard)
		var reason := _worth(plan, sp, guard != null, full)
		if reason == "":
			continue
		var eff: float = plan.value / maxf(1.0, float(sp.mp_cost))
		if slot == _save_slot:
			save_ok = true
		if eff > top_eff:
			top_eff = eff
			top_slot = slot
		# A guard against an enemy special already on its way never waits.
		if _is_guard(sp) and threat:
			eff *= 100.0
		if sim.special_ready(side_id, slot) and eff > best_eff:
			best_eff = eff
			best = plan
			best.slot = slot
			best.reason = reason
	if not save_ok:
		_save_slot = -1
	if best.is_empty():
		return
	# Save MP for a dearer special that would be worth clearly more per MP;
	# once saving for one, stick to it (positions shift every think) unless
	# MP is full, the general is in danger or a guard is needed now.
	var guard_now: bool = threat and _is_guard(s.specials[best.slot])
	var urgent: bool = guard != null or full or guard_now
	if not urgent:
		if _save_slot >= 0 and best.slot != _save_slot:
			return
		if best_eff < top_eff * float(tuning.save_ratio):
			_save_slot = top_slot
			return
	_save_slot = -1
	last_reason = best.reason
	sim.cast(side_id, best.lane, best.slot)


## True if an enemy special (not a guard) is warming up or running.
func _enemy_special_coming(sim, s) -> bool:
	for o in sim.sides:
		if o != s and (not o.pending.is_empty() or not o.wave.is_empty()) and not _is_guard(o.special):
			return true
	return false


## Why a plan is worth casting ("value", "full_mp", "danger", "guard"), "" = not.
func _worth(plan: Dictionary, sp: Dictionary, danger: bool, full: bool) -> String:
	if plan.value <= 0.0:
		return ""
	if _is_guard(sp):
		return "guard" if plan.value >= float(tuning.guard_min_value) else ""
	if danger:
		return "danger"
	var share: float = plan.value / maxf(plan.total, 0.001)
	if share >= float(tuning.min_share):
		return "value"
	if full and share >= float(tuning.full_mp_min_share):
		return "full_mp"
	return ""


## Value of one special for a side right now: best_lane for attacks,
## guard_value for a defence special. Same keys as best_lane.
static func plan_special(sim, s, sp: Dictionary, t: Dictionary = DEFAULTS, guard = null) -> Dictionary:
	if _is_guard(sp):
		var v := guard_value(sim, s, sp, t)
		return {"lane": -1, "value": v, "total": v}
	return best_lane(sim, s, t, guard, sp)


## HP a guard would save (in hit-value units: share of max HP, general x
## general_weight): what our units in a fight are taking now over guard_persist
## of its duration, plus enemy specials warming up or running, x (1 - take_mult).
static func guard_value(sim, s, sp: Dictionary, t: Dictionary = DEFAULTS) -> float:
	var gw := float(t.get("general_weight", DEFAULTS.general_weight))
	var cut := 1.0 - float(sp.get("take_mult", 1))
	var secs := float(sp.get("duration", 5)) * float(t.get("guard_persist", DEFAULTS.guard_persist))
	var incoming := {}  # unit id -> HP expected to be lost
	for e in sim.units:
		if not e.alive or e.side == s or e.tg == null or not e.tg.alive or e.tg.side != s:
			continue
		if BattleMath.hypot(e.x - e.tg.x, e.y - e.tg.y) > e.reach + 4.0:
			continue
		var dps: float = e.atk / maxf(0.1, e.cd) * e.side.order_atk * e.side.form_atk \
				* s.order_take * s.form_take
		incoming[e.tg.id] = incoming.get(e.tg.id, 0.0) + dps * secs
	var width := float(sim.cfg.field.width)
	for o in sim.sides:
		if o == s or (o.pending.is_empty() and o.wave.is_empty()):
			continue
		var w: Dictionary = o.pending if not o.pending.is_empty() else o.wave
		var x0: float = sim.launch_x(o)
		for u in sim.units:
			if u.alive and u.side == s and u.y >= float(w.y0) and u.y <= float(w.y1):
				var lx: float = u.x if o.facing == 1 else width - u.x
				if str(o.special.get("targets", "all")) == "general" and not u.is_general:
					continue
				incoming[u.id] = incoming.get(u.id, 0.0) + sim.special_damage(o, u, maxf(0.0, lx - x0))
	var v := 0.0
	for u in sim.units:
		if u.alive and u.side == s and incoming.has(u.id):
			var saved: float = minf(float(incoming[u.id]), u.hp) * cut / u.max_hp
			v += saved * (gw if u.is_general else 1.0)
	return v


## Where a side's special would do the most good right now.
## Returns {"lane": lane index (-1 = whole field), "value": value of that lane,
## "total": value of hitting every enemy}. guard: own general to protect
## (enemies near it count extra), or null. sp: the special (default: the
## side's current one). A bolt at the general (targets: general) is worth only
## its hit on the general, after the troops in its lane soak their share.
static func best_lane(sim, s, t: Dictionary = DEFAULTS, guard = null, sp: Dictionary = {}) -> Dictionary:
	if sp.is_empty():
		sp = s.special
	var gw := float(t.get("general_weight", DEFAULTS.general_weight))
	var kb := float(t.get("kill_bonus", DEFAULTS.kill_bonus))
	var dw := float(t.get("danger_weight", DEFAULTS.danger_weight))
	var dr := float(t.get("danger_range", DEFAULTS.danger_range))
	var width := float(sim.cfg.field.width)
	var x0: float = sim.launch_x(s, sp)
	var band := float(sp.get("width", 0))
	var reach := float(sp.get("range", 0))
	if reach <= 0.0:
		reach = float(sp.get("end_x", width)) - x0

	if str(sp.get("targets", "all")) == "general":
		return _bolt_value(sim, s, sp, x0, reach, gw, kb)

	# Positions now; the special arrives a couple of seconds later, so the
	# lane is a little stale by then (and the enemy may dodge).
	var per_lane := {}
	var total := 0.0
	for u in sim.units:
		if not u.alive or u.side == s:
			continue
		var lx: float = u.x if s.facing == 1 else width - u.x
		if lx < x0 - band or lx > x0 + reach:
			continue
		var dmg: float = sim.special_damage(s, u, maxf(0.0, lx - x0), sp)
		var v: float = minf(dmg, u.hp) / u.max_hp
		if dmg >= u.hp:
			v += kb
		if u.is_general:
			v *= gw
		if guard != null and BattleMath.hypot(u.x - guard.x, u.y - guard.y) <= dr:
			v *= dw
		var ln: int = sim.lane_of(u.y)
		per_lane[ln] = per_lane.get(ln, 0.0) + v
		total += v

	var span := int(sp.get("lanes", 0))
	var lanes: int = sim.lane_count()
	if span <= 0 or lanes <= 0:
		return {"lane": -1, "value": total, "total": total}
	span = mini(span, lanes)
	var mid := (lanes - span) / 2.0
	var best := 0
	var best_v := -1.0
	for i in lanes - span + 1:
		var v := 0.0
		for j in span:
			v += per_lane.get(i + j, 0.0)
		# Ties go to the lane nearer the middle.
		if v > best_v or (v == best_v and absf(i - mid) < absf(best - mid)):
			best_v = v
			best = i
	return {"lane": best, "value": maxf(0.0, best_v), "total": total}


## Bolt at the enemy general: down the general's lane, block_pct of its power
## lost per enemy troop between the launch point and the general.
static func _bolt_value(sim, s, sp: Dictionary, x0: float, reach: float, gw: float, kb: float) -> Dictionary:
	var g = null
	for o in sim.sides:
		if o != s:
			g = sim.general_of(o.id)
	if g == null or not g.alive:
		return {"lane": -1, "value": 0.0, "total": 0.0}
	var width := float(sim.cfg.field.width)
	var gx: float = g.x if s.facing == 1 else width - g.x
	if gx < x0 or gx > x0 + reach:
		return {"lane": -1, "value": 0.0, "total": 0.0}
	var lane: int = sim.lane_of(g.y)
	var b: Vector2 = sim.lane_bounds(lane) if lane >= 0 else Vector2(-INF, INF)
	var block := float(sp.get("block_pct", 0)) / 100.0
	var power := 1.0
	for u in sim.units:
		if u.alive and u.side == g.side and not u.is_general and u.y >= b.x and u.y <= b.y:
			var lx: float = u.x if s.facing == 1 else width - u.x
			if lx > x0 and lx < gx:
				power *= 1.0 - block
	var dmg: float = sim.special_damage(s, g, gx - x0, sp) * power
	var v: float = minf(dmg, g.hp) / g.max_hp
	if dmg >= g.hp:
		v += kb
	v *= gw
	return {"lane": lane, "value": v, "total": v}


static func _is_guard(sp: Dictionary) -> bool:
	return str(sp.get("type", "")) == "guard"


## Own general if it is hurt and an enemy is close to it, else null.
func _general_in_danger(sim, s):
	var g = sim.general_of(s.id)
	if g == null or not g.alive or g.hp / g.max_hp > float(tuning.danger_hp):
		return null
	var dr := float(tuning.danger_range)
	for u in sim.units:
		if u.alive and u.side != s and BattleMath.hypot(u.x - g.x, u.y - g.y) <= dr:
			return g
	return null


# --- dodging -------------------------------------------------------------------

func _think_dodge(sim, s) -> void:
	for e in sim.sides:
		if e == s:
			continue
		if e.casts > int(_seen.get(e.id, 0)):
			_seen[e.id] = e.casts
			_react[e.id] = sim.time + float(tuning.reaction_time)
		if _react.has(e.id) and sim.time >= float(_react[e.id]):
			_react.erase(e.id)
			_react_to(sim, s, e)
	_think_counter_raid(sim, s)
	if _regroup_watch != "":
		var rw = sim.get_side(_regroup_watch)
		if rw == null or (rw.pending.is_empty() and rw.wave.is_empty()):
			_regroup_watch = ""
			if s.dispersed:
				sim.formation_command(side_id)
	if _restore_order != "":
		var w = sim.get_side(_restore_watch)
		if w == null or (w.pending.is_empty() and w.wave.is_empty()):
			sim.set_order(side_id, _restore_order)
			_restore_order = ""


## An enemy raid on its way to our general: fall back (order retreat) so our
## troops get home in time, then turn on the raiders once they are at our
## general (back to the old order). Guards on duty make it unnecessary, and
## only a holding army falls back: one that is charging keeps fighting.
func _think_counter_raid(sim, s) -> void:
	var g = sim.general_of(side_id)
	if g == null or not g.alive:
		return
	var raid_on := false
	var near := false
	for e in sim.sides:
		if e != s and e.raiding:
			raid_on = true
	if not raid_on:
		if _counter_restore != "":
			sim.set_order(side_id, _counter_restore)
			_counter_restore = ""
		return
	if s.squads and not s.guard_out:
		return
	if _counter_restore == "" and s.order_name != "hold":
		return  # charging: the troops keep fighting, they don't run home
	for u in sim.units:
		if u.alive and u.side != s and u.group == 2 and not u.running \
				and absf(u.x - g.x) < float(tuning.counter_raid_near) and absf(u.y - g.y) < float(tuning.counter_raid_near):
			near = true
	if _counter_restore == "" and not near and _rng.randf() < float(tuning.dodge_skill) * 0.1:
		if sim.cfg.orders.has("retreat") and s.order_name != "retreat":
			_counter_restore = s.order_name if _restore_order == "" else _restore_order
			sim.set_order(side_id, "retreat")
	elif _counter_restore != "" and near:
		sim.set_order(side_id, _counter_restore)
		_counter_restore = "*"  # done: don't fall back again for this raid


func _react_to(sim, s, e) -> void:
	var info: Dictionary = e.pending if not e.pending.is_empty() else e.wave
	if info.is_empty():
		return
	if _rng.randf() > float(tuning.dodge_skill):
		return
	if _is_guard(e.special):
		return
	var lane := int(info.get("lane", -1))
	if str(e.special.get("targets", "all")) == "general":
		return  # opening the lane would only take the general's shield away
	if lane >= 0:
		var y0 := float(info.y0)
		var y1 := float(info.y1)
		# Disperse formation: a special down the middle lane only -> split the
		# whole army to the top and bottom lanes instead, regroup after it.
		var mid: int = sim.lane_count() / 2
		var mb: Vector2 = sim.lane_bounds(mid)
		if s.form_command == "disperse" and sim.lane_count() >= 3 and y0 >= mb.x - 1.0 and y1 <= mb.y + 1.0:
			if not s.dispersed:
				sim.formation_command(side_id)
				_regroup_watch = e.id
			return
		var exposure := 0.0
		for u in sim.units:
			# troops only: the general does not step out of an opened lane
			if u.alive and u.side == s and not u.is_general and u.y >= y0 and u.y <= y1:
				exposure += 1.0
		if exposure >= float(tuning.dodge_min_units) and s.split_lane != lane:
			sim.split(side_id, lane)
		return
	var resp := str(tuning.full_response)
	if resp == "none" or not sim.cfg.orders.has(resp) or s.order_name == resp:
		return
	if _restore_order == "":
		_restore_order = s.order_name
	_restore_watch = e.id
	sim.set_order(side_id, resp)


# --- general charge ---------------------------------------------------------------

func _think_gcharge(sim, s) -> void:
	var g = sim.general_of(s.id)
	if g == null or not g.alive or sim.time < float(tuning.charge_after):
		return
	var hp: float = g.hp / g.max_hp
	# Each general has its own style (units.<general>.ai_charge):
	#   "front" = fights at the front from the start, "mopup" = goes in to
	#   finish a beaten army, "never" = always stays at its post.
	var style := str(sim.cfg.units.get(g.type_id, {}).get("ai_charge", "mopup"))
	if style == "never":
		return
	if style == "front":
		# only alongside troops that are going in themselves
		var with_troops: bool = not s.retreating and s.hold_range <= 0.0
		if not s.gen_charge and hp >= float(tuning.charge_hp) and with_troops:
			sim.set_general_charge(side_id, true)
		elif s.gen_charge and not with_troops:
			sim.set_general_charge(side_id, false)
		return
	var own := 0.0
	var theirs := 0.0
	var their_n := 0
	for u in sim.units:
		if u.alive and not u.is_general:
			if u.side == s:
				own += u.hp
			else:
				theirs += u.hp
				their_n += 1
	if not s.gen_charge:
		if hp >= float(tuning.charge_hp) and own >= theirs * float(tuning.charge_adv) \
				and their_n <= int(tuning.charge_max_enemy_troops):
			sim.set_general_charge(side_id, true)
	elif own < theirs * float(tuning.return_adv):
		sim.set_general_charge(side_id, false)


# --- guard group ---------------------------------------------------------------

func _think_guard(sim, s) -> void:
	var own := 0.0
	var theirs := 0.0
	var main_n := 0
	var e = null
	for u in sim.units:
		if u.alive and not u.is_general:
			if u.side == s:
				own += u.hp
				if u.group != 1:
					main_n += 1
			else:
				theirs += u.hp
				e = u.side
	if e == null:
		return
	if not s.guard_out:
		var stall: bool = main_n == 0 and (e.hold_range > 0.0 or e.retreating)
		if own >= theirs * float(tuning.guard_release_adv) or stall:
			sim.set_guard_out(side_id, true)
	elif own < theirs * float(tuning.guard_recall_adv) and main_n > 0:
		sim.set_guard_out(side_id, false)


# --- formation command ----------------------------------------------------------

func _think_form_command(sim, s) -> void:
	match s.form_command:
		"disperse":
			# "always" (testing: a player who keeps the wings split all battle)
			if str(tuning.get("disperse_mode", "react")) == "always" and not s.dispersed:
				sim.formation_command(side_id)
		"raid":
			# only from a standing army (order hold): raiding out of a charge
			# leaves the general's side outnumbered (sims: 4-48% vs 33%+)
			if s.hold_range <= 0.0:
				return
			if _start_hp.is_empty():
				_start_hp = {"own": 1.0, "their": 1.0}
				var a := 0.0
				var b := 0.0
				for u in sim.units:
					if u.alive and not u.is_general:
						if u.side == s:
							a += u.hp
						else:
							b += u.hp
				_start_hp = {"own": maxf(1.0, a), "their": maxf(1.0, b)}
			if s.raiding or sim.time < float(tuning.raid_after):
				return
			var eg = null
			for o in sim.sides:
				if o != s:
					eg = sim.general_of(o.id)
			if eg == null or not eg.alive or eg.side.gen_charge:
				return  # a general out in the fight is no raid target
			var raiders := 0
			var ours: Array = []
			var theirs: Array = []
			# "ours" = everyone but the raiders (guards, general): who holds
			# their army while the raiders slip round
			for u in sim.units:
				if not u.alive:
					continue
				if u.side == s:
					if u.group == 2 and not u.is_general:
						raiders += 1
					else:
						ours.append(u)
				elif not u.is_general:
					theirs.append(u)
			if raiders < int(tuning.raid_min):
				return
			# not while losing the main fight: pulling the raiders out then
			# only hands it to them
			var own_hp := 0.0
			var their_hp := 0.0
			for u in sim.units:
				if u.alive and not u.is_general:
					if u.side == s:
						own_hp += u.hp
					else:
						their_hp += u.hp
			# shares of each side's starting troop HP (races differ in HP)
			if own_hp / float(_start_hp.own) < their_hp / float(_start_hp.their) * float(tuning.raid_adv):
				return
			# their general stands clear of the fight...
			var clear := float(tuning.raid_clear)
			for u in ours:
				if absf(u.x - eg.x) + absf(u.y - eg.y) * 0.5 < clear:
					return
			# ...and their army has left it far behind (the way round is open)
			var cx := 0.0
			for v in theirs:
				cx += v.x
			if theirs.is_empty() or absf(cx / theirs.size() - eg.x) >= float(tuning.raid_gap):
				sim.formation_command(side_id)
		"divrush":
			if s.divs_sent >= s.divs:
				return
			var alive := 0
			for u in sim.units:
				if u.alive and u.side == s and u.group >= 10 and u.group - 10 < s.divs_sent:
					alive += 1
			if s.divs_sent == 0 or sim.time - _last_div >= float(tuning.div_interval) \
					or alive < int(tuning.div_min_alive):
				if sim.formation_command(side_id):
					_last_div = sim.time


# --- duel offer --------------------------------------------------------------------

## Duel or retreat when both armies are gone: count the turns each general
## needs to finish the other (expected damage per turn, the faster one strikes
## first). Retreat if ours needs more than duel_retreat_ratio x theirs.
func _decide_duel(sim, s) -> void:
	var g = sim.general_of(s.id)
	var e = null
	for o in sim.sides:
		if o != s:
			e = sim.general_of(o.id)
	if g == null or e == null:
		sim.duel_choice(side_id, "duel")
		return
	var ours: float = ceilf(e.hp / maxf(0.001, sim.duel_turn_damage(g)))
	var theirs: float = ceilf(g.hp / maxf(0.001, sim.duel_turn_damage(e)))
	if g.spd < e.spd:
		ours += 0.5
	elif e.spd < g.spd:
		theirs += 0.5
	var choice := "retreat" if ours > theirs * float(tuning.duel_retreat_ratio) else "duel"
	sim.duel_choice(side_id, choice)
