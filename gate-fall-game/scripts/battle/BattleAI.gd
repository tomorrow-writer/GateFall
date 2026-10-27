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
##   back once nobody is fighting it (BattleSim._attacker_of).
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
}

var side_id: String
var tuning: Dictionary
var do_cast := true
var do_dodge := false
var do_gcharge := false
## Why the last cast happened ("value", "full_mp", "danger"), for debugging/tools.
var last_reason := ""

var _wait := 0.0
var _rng := RandomNumberGenerator.new()
var _seen := {}  # enemy side id -> casts already noticed
var _react := {}  # enemy side id -> sim time to react at
var _restore_order := ""  # order to go back to after a full-field special
var _restore_watch := ""  # enemy side whose special we are waiting out


## opts: {"cast": bool, "dodge": bool, "gcharge": bool, "seed": int}
func _init(side: String, ai_cfg: Dictionary = {}, opts: Dictionary = {}) -> void:
	side_id = side
	tuning = merged(ai_cfg)
	do_cast = bool(opts.get("cast", true))
	do_dodge = bool(opts.get("dodge", false))
	do_gcharge = bool(opts.get("gcharge", false))
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
	if do_cast:
		_think_cast(sim, s)


# --- casting -------------------------------------------------------------------

func _think_cast(sim, s) -> void:
	if not sim.special_ready(side_id):
		return
	if sim.time <= float(s.special.get("auto_cast_after", 0)):
		return
	var guard = _general_in_danger(sim, s)
	var plan := best_lane(sim, s, tuning, guard)
	if plan.value <= 0.0:
		return
	var share: float = plan.value / maxf(plan.total, 0.001)
	if guard != null:
		last_reason = "danger"
	elif share >= float(tuning.min_share):
		last_reason = "value"
	elif s.mp >= s.mp_max - 0.001 and share >= float(tuning.full_mp_min_share):
		last_reason = "full_mp"
	else:
		return
	sim.cast(side_id, plan.lane)


## Where a side's special would do the most good right now.
## Returns {"lane": lane index (-1 = whole field), "value": value of that lane,
## "total": value of hitting every enemy}. guard: own general to protect
## (enemies near it count extra), or null.
static func best_lane(sim, s, t: Dictionary = DEFAULTS, guard = null) -> Dictionary:
	var sp: Dictionary = s.special
	var gw := float(t.get("general_weight", DEFAULTS.general_weight))
	var kb := float(t.get("kill_bonus", DEFAULTS.kill_bonus))
	var dw := float(t.get("danger_weight", DEFAULTS.danger_weight))
	var dr := float(t.get("danger_range", DEFAULTS.danger_range))
	var width := float(sim.cfg.field.width)
	var x0: float = sim.launch_x(s)
	var band := float(sp.get("width", 0))
	var reach := float(sp.get("range", 0))
	if reach <= 0.0:
		reach = float(sp.get("end_x", width)) - x0

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
		var dmg: float = sim.special_damage(s, u, maxf(0.0, lx - x0))
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
	if _restore_order != "":
		var w = sim.get_side(_restore_watch)
		if w == null or (w.pending.is_empty() and w.wave.is_empty()):
			sim.set_order(side_id, _restore_order)
			_restore_order = ""


func _react_to(sim, s, e) -> void:
	var info: Dictionary = e.pending if not e.pending.is_empty() else e.wave
	if info.is_empty():
		return
	if _rng.randf() > float(tuning.dodge_skill):
		return
	var lane := int(info.get("lane", -1))
	if lane >= 0:
		var y0 := float(info.y0)
		var y1 := float(info.y1)
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
