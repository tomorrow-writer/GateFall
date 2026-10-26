## Decides when an AI-controlled side fires its general's special, and where.
##
## Pure logic like BattleSim: reads the sim, never changes it, and never draws
## from the sim rng (so configs without AI keep the prototype's rng sequence).
## Nothing here is tied to a race: the same brain runs the knight general's
## cavalry charge or the slime general's wave, whichever side the AI plays
## (CLAUDE.md section 6).
##
## How it thinks (every think_interval seconds, not every step):
##   1. Special ready? (MP, not already running, past auto_cast_after)
##   2. Value of a hit on each enemy = share of its max HP the special takes
##      off, + kill_bonus if it dies (a big slime splitting is not a kill; the
##      small ones it splits into are). The enemy general counts general_weight x.
##   3. Find the best lane (lane_height 0 = the whole field is one lane) and
##      compare its value with hitting every enemy on the field:
##        cast if share >= min_share
##        MP full (waiting wastes regen): share >= full_mp_min_share
##        own general hurt with enemies on it: any hit, and enemies near the
##        general count danger_weight x (the charge rides in to clear them).
##   So the cavalry charge waits for a crowded lane or a lane of small slimes
##   it can finish off; the slime wave (always hits everyone) fires when ready.
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
	"lane_step": 6.0,
}

var side_id: String
var tuning: Dictionary
var _wait := 0.0
## Why the last cast happened ("value", "full_mp", "danger"), for debugging/tools.
var last_reason := ""


func _init(side: String, ai_cfg: Dictionary = {}) -> void:
	side_id = side
	tuning = merged(ai_cfg)


## DEFAULTS overlaid with a config "ai" section (keys starting with _ ignored).
static func merged(ai_cfg: Dictionary) -> Dictionary:
	var t := DEFAULTS.duplicate()
	for k in ai_cfg:
		if not str(k).begins_with("_"):
			t[k] = ai_cfg[k]
	return t


## Called by BattleSim.step() for its side each step. Returns the lane y to
## cast at, or null to hold the special.
func think(sim, dt: float) -> Variant:
	_wait -= dt
	if _wait > 0.0:
		return null
	_wait = float(tuning.think_interval)
	var s = sim.get_side(side_id)
	if s == null or not sim.special_ready(side_id):
		return null
	if sim.time <= float(s.special.get("auto_cast_after", 0)):
		return null

	var guard = _general_in_danger(sim, s)
	var plan := best_lane(sim, s, tuning, guard)
	if plan.value <= 0.0:
		return null
	var share: float = plan.value / maxf(plan.total, 0.001)
	if guard != null:
		last_reason = "danger"
	elif share >= float(tuning.min_share):
		last_reason = "value"
	elif s.mp >= s.mp_max - 0.001 and share >= float(tuning.full_mp_min_share):
		last_reason = "full_mp"
	else:
		return null
	return plan.y


## Where a side's special would do the most good right now.
## Returns {"y": lane centre, "value": value of that lane, "total": value of
## hitting every enemy}. guard: own general to protect (enemies near it count
## extra), or null.
static func best_lane(sim, s, t: Dictionary = DEFAULTS, guard = null) -> Dictionary:
	var sp: Dictionary = s.special
	var dmg := float(sp.get("damage", 0))
	var lane_h := float(sp.get("lane_height", 0))
	var y_min := float(sim.cfg.field.y_min)
	var y_max := float(sim.cfg.field.y_max)
	var mid := (y_min + y_max) / 2.0
	var gw := float(t.get("general_weight", DEFAULTS.general_weight))
	var kb := float(t.get("kill_bonus", DEFAULTS.kill_bonus))
	var dw := float(t.get("danger_weight", DEFAULTS.danger_weight))
	var dr := float(t.get("danger_range", DEFAULTS.danger_range))

	# Positions now; a charge crosses the field in ~1.5 s, so the lane is only
	# a little stale when it arrives.
	var targets: Array = []
	var total := 0.0
	for u in sim.units:
		if not u.alive or u.side == s:
			continue
		var v: float = minf(dmg, u.hp) / u.max_hp
		if dmg >= u.hp:
			v += kb
		if u.is_general:
			v *= gw
		if guard != null and BattleMath.hypot(u.x - guard.x, u.y - guard.y) <= dr:
			v *= dw
		targets.append([u.y, v])
		total += v

	if lane_h <= 0.0:
		return {"y": mid, "value": total, "total": total}

	var half := lane_h / 2.0
	var step := maxf(1.0, float(t.get("lane_step", DEFAULTS.lane_step)))
	var best_y := mid
	var best_v := -1.0
	var y := y_min
	while y <= y_max + 0.001:
		var v := 0.0
		for tg in targets:
			if absf(tg[0] - y) <= half:
				v += tg[1]
		# Ties go to the lane nearer the middle.
		if v > best_v or (v == best_v and absf(y - mid) < absf(best_y - mid)):
			best_v = v
			best_y = y
		y += step
	return {"y": best_y, "value": maxf(0.0, best_v), "total": total}


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
