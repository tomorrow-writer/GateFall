## World map logic, real time like DF: generals walk the roads between castles
## while the days tick by. Pure logic, no nodes (same idea as BattleSim): the
## map scene (WorldMap.gd) and tools/run_world.gd both drive it.
##
## Time is in days. step(days) moves everyone and returns events. When two
## enemy generals meet (on a road, or one walks into a castle the other holds)
## a battle is queued in `battles` and the map stops until the caller settles
## it with resolve_battle() (fought in Battle.tscn or auto-resolved by
## AutoBattle.gd).
##
## Rules (values in data/world_map.json, balance comes later):
##   - walk into an empty enemy / unowned castle = it is yours (and the march
##     goes on if it was only passing through)
##   - walk into a castle with enemy generals = battle with each in turn
##   - enemy generals meeting on a road = battle there, the winner walks on
##   - the loser walks back to its nearest own castle (through own castles
##     only); no way home = captured
##   - a general resting in its own castle gets troops back over time
##   - take the enemy capital (or capture all its generals) = win the war
##   - every council.every_days the map stops for a council (like DF): each
##     side's reserve gets troops per castle it owns, and generals standing in
##     their own castles take troops from it (or hand them back). AI sides
##     settle theirs at once; a human side keeps the map stopped until
##     end_council() (`council` lists the sides still deciding).
##   - council actions (like DF): each general standing in its own castle may do
##     ONE thing per council: levy (troops into the reserve) or persuade a
##     prisoner to join. Handing out troops from the reserve is free.
##   - walls (like a siege in DF): each castle has a wall level 0..siege.wall_max.
##     A general in its own castle may spend its council action to raise it
##     by 1 (once per castle per council). Troops defending a castle they own
##     take siege.wall_take_per_level less damage per level (not the general,
##     not the duel). Taking a castle knocks siege.wall_lost_on_capture off.
##     Road battles have no walls.
##   - siege engine: a council action too. The general drags it along
##     (siege.engine_speed x march speed); attacking a walled castle it cancels
##     siege.engine_cancels wall levels for that battle, then it is spent (won
##     or lost; a castle with no wall leaves it for the next). Useless on a
##     road, and lost if the general loses a road battle or is taken.
##   - prisoners: a beaten general whose general fell in battle (not one that
##     pulled out) is taken with chance prisoners.capture_if_fell; no way home =
##     always taken. The captor keeps it (`held_by`) and may persuade it at each
##     council; the chance grows each council it stays captive and falls with
##     its loyalty. Kings never join. A general who joins keeps its own look
##     (`origin`) but fights for its new side, starting with no troops.
extends RefCounted


class General:
	var id: String
	var name: String
	var side: String
	var king := false
	var troops := 0.0
	var castle := ""  # castle it stands in ("" while walking)
	var pos := Vector2.ZERO
	var from := ""  # last castle passed: the road walked is from -> path[0]
	var path: Array = []  # castles still to reach, the next one first
	var state := "idle"  # idle | moving | battle | captured
	var retreating := false  # walking home after a lost battle (nobody stops it)
	var origin := ""  # side it started on (its troop look on the map stays this)
	var loyalty := 60  # 0-100: how hard it is to persuade once captured
	var held_by := ""  # captured: the side holding it
	var captive_councils := 0  # councils held since it was captured
	var engine := false  # drags a siege engine (slow; cuts a castle's walls once)

	func target() -> String:
		return str(path[-1]) if not path.is_empty() else castle


var data: Dictionary
var rules: Dictionary
var castles := {}  # id -> {id, name, pos: Vector2, owner, capital, wall}
var adj := {}  # castle id -> [castle ids]
var generals: Array[General] = []
var day := 0.0
var ai_sides: Array = []
var winner := ""  # "" while the war goes on, then a side id
var battles: Array = []  # queued: {id, a, d, castle} (a, d = general ids, castle "" = on a road)
var council_cfg: Dictionary
var reserve := {"S": 0, "K": 0}  # troops waiting to be handed out, per side
var council: Array = []  # human sides still in the council (the map waits for them)
var councils_held := 0
var next_council := INF
var prisoner_cfg: Dictionary
var siege_cfg: Dictionary
var fortified := {}  # castle id -> true once its wall was raised this council
var acted := {}  # general id -> what it did this council ("levy", "persuade_ok", "persuade_fail", "joined")
var tried := {}  # prisoner id -> true once someone tried to persuade it this council
var rng := RandomNumberGenerator.new()
var _council_open := false  # actions only count while a council is on

var _next_battle := 1
var _events: Array = []
var _ai_acc := 0.0


static func load_map(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("WorldSim: cannot open %s" % path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _init(map_data: Dictionary, ai: Array = [], seed_value: int = 0) -> void:
	if seed_value != 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	data = map_data
	prisoner_cfg = data.get("prisoners", {})
	siege_cfg = data.get("siege", {})
	rules = data.rules
	ai_sides = ai
	for c in data.castles:
		castles[c.id] = {"id": c.id, "name": c.name, "pos": Vector2(c.pos[0], c.pos[1]),
				"owner": str(c.get("owner", "")), "capital": bool(c.get("capital", false)),
				"wall": clampi(int(c.get("wall", 0)), 0, wall_max())}
		adj[c.id] = []
	for r in data.roads:
		adj[r[0]].append(r[1])
		adj[r[1]].append(r[0])
	for gd in data.generals:
		var g := General.new()
		g.id = gd.id
		g.name = gd.name
		g.side = gd.side
		g.king = bool(gd.get("king", false))
		g.origin = g.side
		g.loyalty = int(gd.get("loyalty", 100 if g.king else int(prisoner_cfg.get("default_loyalty", 60))))
		g.troops = float(gd.get("troops", rules.max_troops))
		g.castle = gd.castle
		g.from = gd.castle
		g.pos = castles[gd.castle].pos
		generals.append(g)
	council_cfg = data.get("council", {})
	if not council_cfg.is_empty():
		next_council = float(council_cfg.get("every_days", 30))
		for side in reserve:
			reserve[side] = int(council_cfg.get("start", 0))


# --- queries --------------------------------------------------------------------

func get_general(id: String) -> General:
	for g in generals:
		if g.id == id:
			return g
	return null


## Generals standing in a castle (not walking, not fighting).
func generals_at(cid: String, side: String = "") -> Array[General]:
	var out: Array[General] = []
	for g in generals:
		if g.state == "idle" and g.castle == cid and (side == "" or g.side == side):
			out.append(g)
	return out


func generals_of(side: String) -> Array[General]:
	var out: Array[General] = []
	for g in generals:
		if g.side == side and g.state != "captured":
			out.append(g)
	return out


func castles_of(side: String) -> Array:
	var out := []
	for c in castles.values():
		if c.owner == side:
			out.append(c.id)
	return out


func troops_of(side: String) -> int:
	var n := 0.0
	for g in generals_of(side):
		n += floorf(g.troops)
	return int(n)


func get_battle(id: int) -> Dictionary:
	for b in battles:
		if int(b.id) == id:
			return b
	return {}


static func other_side(side: String) -> String:
	return "K" if side == "S" else "S"


## Shortest road path a -> b as castle ids (both ends included), [] if none.
## through: if set, every castle in between must belong to that side.
func shortest(a: String, b: String, through: String = "") -> Array:
	if a == b:
		return [a]
	var dist := {a: 0.0}
	var prev := {}
	var open := [a]
	while not open.is_empty():
		var cur: String = open[0]
		for o in open:
			if dist[o] < dist[cur]:
				cur = o
		open.erase(cur)
		if cur == b:
			break
		if cur != a and through != "" and castles[cur].owner != through:
			continue  # may end here but not pass through
		for n in adj[cur]:
			var nd: float = dist[cur] + castles[cur].pos.distance_to(castles[n].pos)
			if not dist.has(n) or nd < dist[n]:
				dist[n] = nd
				prev[n] = cur
				if not open.has(n):
					open.append(n)
	if not prev.has(b):
		return []
	var out := [b]
	while out[0] != a:
		out.push_front(prev[out[0]])
	return out


func path_length(from_pos: Vector2, path: Array) -> float:
	var total := 0.0
	var p := from_pos
	for cid in path:
		total += p.distance_to(castles[cid].pos)
		p = castles[cid].pos
	return total


# --- orders ---------------------------------------------------------------------

## Send a general to a castle. Works while standing in a castle or walking (it
## turns back if that is shorter). Returns false if it cannot go.
func order_move(g: General, target: String) -> bool:
	if g == null or not castles.has(target) or g.retreating:
		return false
	if g.state == "idle":
		if g.castle == target:
			return false
		var p := shortest(g.castle, target)
		if p.size() < 2:
			return false
		g.from = g.castle
		g.castle = ""
		g.path = p.slice(1)
		g.state = "moving"
		_events.append({"type": "depart", "general": g.id, "to": target})
		return true
	if g.state == "moving":
		var ahead: String = g.path[0]
		var back: String = g.from
		var pa := shortest(ahead, target)
		var pb := shortest(back, target)
		if pa.is_empty() and pb.is_empty():
			return false
		var ca := INF if pa.is_empty() else path_length(g.pos, pa)
		var cb := INF if pb.is_empty() else path_length(g.pos, pb)
		if cb < ca:
			g.from = ahead
			g.path = pb
		else:
			g.path = pa
		_events.append({"type": "depart", "general": g.id, "to": target})
		return true
	return false


# --- time -----------------------------------------------------------------------

## Advance the world by `days`. Does nothing while a battle waits to be settled.
func step(days: float) -> Array:
	if winner != "" or not battles.is_empty() or not council.is_empty():
		return _take_events()
	if day + days >= next_council:
		day = next_council
		_start_council()
		return _take_events()
	day += days
	var speed := float(rules.move_speed)
	var before := _road_snapshot()
	for g in generals:
		if g.state == "moving":
			_walk(g, days * speed * (engine_speed() if g.engine else 1.0))
			if not battles.is_empty() or winner != "":
				break
	if battles.is_empty():
		_check_meetings(before)
	_regen(days)
	if not ai_sides.is_empty():
		_ai_acc += days
		if _ai_acc >= float(rules.ai_think_days):
			_ai_acc = 0.0
			for side in ai_sides:
				_ai_think(side)
	return _take_events()


func _take_events() -> Array:
	var out := _events
	_events = []
	return out


func _walk(g: General, dist: float) -> void:
	while dist > 0.0 and g.state == "moving" and not g.path.is_empty():
		var to: Vector2 = castles[g.path[0]].pos
		var d := g.pos.distance_to(to)
		if d <= dist:
			g.pos = to
			dist -= d
			var cid: String = g.path.pop_front()
			g.from = cid
			_arrive(g, cid)
		else:
			g.pos += (to - g.pos) / d * dist
			dist = 0.0


func _arrive(g: General, cid: String) -> void:
	var c: Dictionary = castles[cid]
	if g.retreating and not g.path.is_empty():
		return  # walking home: passes by without stopping
	if c.owner == g.side:
		if g.path.is_empty():
			g.state = "idle"
			g.castle = cid
			g.retreating = false
			_events.append({"type": "arrive", "general": g.id, "castle": cid})
		return
	# Enemy or unowned castle: defenders = stop and fight; empty = take it and
	# walk on if the march goes further.
	var defs := generals_at(cid, other_side(g.side))
	if not defs.is_empty():
		g.path.clear()
		_start_battle(g, defs[0], cid)
	else:
		_capture(cid, g, not g.path.is_empty())


func _capture(cid: String, g: General, passing := false) -> void:
	var c: Dictionary = castles[cid]
	var was: String = c.owner
	c.owner = g.side
	if was != g.side:
		c.wall = maxi(0, int(c.wall) - int(siege_cfg.get("wall_lost_on_capture", 1)))
	if not passing:
		g.state = "idle"
		g.castle = cid
		g.path.clear()
		g.retreating = false
	_events.append({"type": "capture", "general": g.id, "castle": cid, "from": was})
	if c.capital and was != "":
		_end_war(g.side)


func _start_battle(a: General, d: General, cid: String) -> void:
	a.state = "battle"
	d.state = "battle"
	# A general caught on its way home fights like anyone else: after the
	# battle it is either sent home again (lost) or free to take orders (won).
	a.retreating = false
	d.retreating = false
	# engine: the attacker brought one to a walled castle (it is spent after;
	# a castle with no wall leaves it for the next one).
	var walled: bool = cid != "" and castles[cid].owner == d.side and int(castles[cid].wall) > 0
	var b := {"id": _next_battle, "a": a.id, "d": d.id, "castle": cid, "engine": walled and a.engine}
	_next_battle += 1
	battles.append(b)
	_events.append({"type": "battle", "battle": b.id})


## Enemy generals walking the same road (either way) close enough = battle.
## Also a battle when they passed each other inside this step (a big step, or
## fast speed, can carry two marches straight through each other without ever
## being within meet_distance at the end of the step). `before` comes from
## _road_snapshot() taken before anyone walked.
func _check_meetings(before: Dictionary = {}) -> void:
	var walkers: Array[General] = []
	for g in generals:
		if g.state == "moving" and not g.retreating and not g.path.is_empty():
			walkers.append(g)
	var meet := float(rules.meet_distance)
	for i in walkers.size():
		for j in range(i + 1, walkers.size()):
			var a := walkers[i]
			var b := walkers[j]
			if a.side == b.side or a.state != "moving" or b.state != "moving":
				continue
			var same_road: bool = (a.from == b.from and a.path[0] == b.path[0]) \
					or (a.from == b.path[0] and a.path[0] == b.from)
			if not same_road:
				continue
			if a.pos.distance_to(b.pos) <= meet or _crossed(a, b, before):
				_start_battle(a, b, "")
				return


## Where every walker stood, and on which road, before this step's walk.
func _road_snapshot() -> Dictionary:
	var out := {}
	for g in generals:
		if g.state == "moving" and not g.path.is_empty():
			out[g.id] = {"pos": g.pos, "road": _road_key(g.from, str(g.path[0]))}
	return out


## Same key for a road whichever way it is walked.
func _road_key(x: String, y: String) -> String:
	return x + "|" + y if x < y else y + "|" + x


## True if a and b (on the same road now) were on that same road before the
## step too and their order along it flipped: they walked through each other.
## They are put back at the point where they met, so the fight shows there.
func _crossed(a: General, b: General, before: Dictionary) -> bool:
	if not before.has(a.id) or not before.has(b.id):
		return false
	var road := _road_key(a.from, str(a.path[0]))
	if str(before[a.id].road) != road or str(before[b.id].road) != road:
		return false  # one of them only came onto this road during the step
	var ends := road.split("|")
	var p0: Vector2 = castles[ends[0]].pos
	var dir: Vector2 = castles[ends[1]].pos - p0
	var len2 := dir.length_squared()
	if len2 <= 0.0:
		return false
	var pa: Vector2 = before[a.id].pos
	var pb: Vector2 = before[b.id].pos
	var a0: float = (pa - p0).dot(dir) / len2
	var b0: float = (pb - p0).dot(dir) / len2
	var a1: float = (a.pos - p0).dot(dir) / len2
	var b1: float = (b.pos - p0).dot(dir) / len2
	if signf(a0 - b0) == signf(a1 - b1) or a0 == b0:
		return false
	# Meeting point: where the gap a-b was zero, assuming both walked straight.
	var gap0: float = a0 - b0
	var gap1: float = a1 - b1
	var f: float = gap0 / (gap0 - gap1)
	var at: Vector2 = p0 + dir * (a0 + (a1 - a0) * f)
	a.pos = at
	b.pos = at
	return true


func _regen(days: float) -> void:
	var cap := float(rules.max_troops)
	var per := float(rules.regen_per_day)
	for g in generals:
		if g.state == "idle" and castles[g.castle].owner == g.side and g.troops < cap:
			g.troops = minf(cap, g.troops + per * days)


# --- battles --------------------------------------------------------------------

## Settle a queued battle. winner = side id or "draw"; left = troops left per
## side id ({"S": 12, "K": 0}); fell = side id -> true if that side's general
## fell (on the field or in the duel) rather than pulling out. A loser whose
## general fell may be taken prisoner (prisoners.capture_if_fell).
func resolve_battle(id: int, winner_side: String, left: Dictionary, fell: Dictionary = {}) -> void:
	var b := get_battle(id)
	if b.is_empty():
		return
	battles.erase(b)
	var a := get_general(b.a)
	var d := get_general(b.d)
	for g in [a, d]:
		g.troops = minf(g.troops, float(left.get(g.side, g.troops)))
	var won: General = d  # draw: the attacker turns back, the defender holds
	var lost: General = a
	if winner_side == a.side:
		won = a
		lost = d
	_events.append({"type": "battle_end", "battle": id, "winner": winner_side, "won": won.id, "lost": lost.id,
			"castle": b.castle})
	if b.castle != "" and a.engine and bool(b.get("engine", false)):
		a.engine = false  # spent on this castle's walls, won or lost
		_events.append({"type": "engine_spent", "general": a.id, "castle": b.castle})
	elif b.castle == "" and lost.engine:
		lost.engine = false  # beaten on the road: the winner burns it
		_events.append({"type": "engine_lost", "general": lost.id})
	if winner_side != "draw" and bool(fell.get(lost.side, false)) \
			and rng.randf() < float(prisoner_cfg.get("capture_if_fell", 0.0)):
		_take_prisoner(lost, won.side)
	else:
		_send_home(lost, b.castle)
	if b.castle != "":
		if won == a:
			var more := generals_at(b.castle, other_side(a.side))
			if not more.is_empty():
				_start_battle(a, more[0], b.castle)
			else:
				_capture(b.castle, a)
		else:
			won.state = "idle"
	else:
		won.state = "moving" if not won.path.is_empty() else "idle"
	_check_wipeout()


## A beaten general walks back to its nearest own castle; no way home = captured.
func _send_home(g: General, avoid: String = "") -> void:
	var starts := [g.from] if g.castle == "" else [g.castle]
	if g.castle == "" and not g.path.is_empty():
		starts.append(g.path[0])
	var best := []
	var best_len := INF
	for s in starts:
		for cid in castles_of(g.side):
			if cid == avoid:
				continue
			var p := shortest(s, cid, g.side)
			if p.is_empty():
				continue
			var l := path_length(g.pos, p)
			if l < best_len:
				best_len = l
				best = p
	g.castle = ""
	if best.is_empty():
		_take_prisoner(g, other_side(g.side))
		return
	g.from = best[0]
	g.path = best.slice(1) if g.pos.distance_to(castles[best[0]].pos) < 0.5 else best
	_events.append({"type": "retreat", "general": g.id, "to": best[-1]})
	if g.path.is_empty():
		# Already standing at home (beaten right outside its own castle): it is
		# in. Left "moving" with no road ahead it would never arrive.
		g.pos = castles[best[0]].pos
		g.castle = best[0]
		g.state = "idle"
		g.retreating = false
		_events.append({"type": "arrive", "general": g.id, "castle": best[0]})
		return
	g.state = "moving"
	g.retreating = true


func _take_prisoner(g: General, by: String) -> void:
	g.state = "captured"
	g.held_by = by
	g.captive_councils = 0
	g.castle = ""
	g.troops = 0.0  # its army is gone
	g.engine = false
	g.path.clear()
	g.retreating = false
	_events.append({"type": "captured", "general": g.id, "by": by})


func _check_wipeout() -> void:
	for side in ["S", "K"]:
		if winner == "" and generals_of(side).is_empty():
			_end_war(other_side(side))


func _end_war(side: String) -> void:
	if winner != "":
		return
	winner = side
	_events.append({"type": "over", "winner": side})


# --- council ----------------------------------------------------------------------

## Troops a side's reserve gets at each council: per castle owned, + capital.
func income_of(side: String) -> int:
	var n := 0
	for cid in castles_of(side):
		n += int(council_cfg.get("income_per_castle", 0))
		if castles[cid].capital:
			n += int(council_cfg.get("capital_bonus", 0))
	return n


## Only a general standing in one of its own castles can take or hand back troops.
func can_draft(g: General) -> bool:
	return g != null and g.state == "idle" and g.castle != "" and castles[g.castle].owner == g.side


## Move up to n troops from the side's reserve to g (n < 0 = back to the
## reserve). Returns how many actually moved (same sign as n).
func draft(g: General, n: int) -> int:
	if not can_draft(g) or n == 0:
		return 0
	var have := int(floorf(g.troops))
	var moved := 0
	if n > 0:
		moved = mini(n, mini(int(reserve[g.side]), int(rules.max_troops) - have))
	else:
		moved = -mini(-n, have)
	if moved == 0:
		return 0
	g.troops = float(have + moved)
	reserve[g.side] = int(reserve[g.side]) - moved
	return moved


func _start_council() -> void:
	councils_held += 1
	_council_open = true
	acted.clear()
	tried.clear()
	fortified.clear()
	for g in generals:
		if g.state == "captured":
			g.captive_councils += 1
	var income := {}
	for side in ["S", "K"]:
		if generals_of(side).is_empty():
			continue
		income[side] = income_of(side)
		reserve[side] = int(reserve[side]) + income[side]
	_events.append({"type": "council", "number": councils_held, "income": income})
	for side in income:
		if side in ai_sides:
			auto_council(side)
		else:
			council.append(side)
	if council.is_empty():
		_next_council()


## A human side is done with the council. The map goes on once nobody is left.
func end_council(side: String) -> void:
	if not council.has(side):
		return
	council.erase(side)
	if council.is_empty():
		_next_council()


func _next_council() -> void:
	_council_open = false
	next_council = day + float(council_cfg.get("every_days", 30))
	_events.append({"type": "council_end", "number": councils_held})


## AI council: one action per general (persuade prisoners, the rest levy),
## then hand out the reserve.
func auto_council(side: String) -> void:
	auto_actions(side)
	auto_draft(side)


## Hand out the reserve: fill up the weakest generals standing at home first.
func auto_draft(side: String) -> void:
	var home: Array[General] = []
	for g in generals_of(side):
		if can_draft(g):
			home.append(g)
	home.sort_custom(func(a, b): return a.troops < b.troops)
	for g in home:
		if int(reserve[side]) <= 0:
			break
		draft(g, int(rules.max_troops))


# --- council actions (one per general per council) --------------------------------

## A general can act if it stands in its own castle, the council is on and it
## has not acted yet this council.
func can_act(g: General) -> bool:
	return _council_open and can_draft(g) and not acted.has(g.id)


func prisoners_of(side: String) -> Array[General]:
	var out: Array[General] = []
	for g in generals:
		if g.state == "captured" and g.held_by == side:
			out.append(g)
	return out


## Troops one levy adds to the side's reserve.
func levy_amount() -> int:
	return int(council_cfg.get("levy", 0))


## Action: raise troops from the castle's people into the side's reserve.
func levy(g: General) -> int:
	if not can_act(g) or levy_amount() <= 0:
		return 0
	var n := levy_amount()
	reserve[g.side] = int(reserve[g.side]) + n
	acted[g.id] = "levy"
	_events.append({"type": "levy", "general": g.id, "amount": n})
	return n


## Chance (0-1) that `by` talks prisoner `p` into joining this council. 0 = it
## will not (a king, not ours to ask, or already asked this council).
func recruit_chance(p: General, by: General) -> float:
	if p == null or by == null or p.state != "captured" or p.held_by != by.side or p.king \
			or tried.has(p.id):
		return 0.0
	var c := float(prisoner_cfg.get("base", 0.2)) \
			+ float(prisoner_cfg.get("per_council", 0.15)) * p.captive_councils \
			- (p.loyalty - 50) * float(prisoner_cfg.get("loyalty_weight", 0.01))
	if by.king:
		c += float(prisoner_cfg.get("king_bonus", 0.0))
	return clampf(c, float(prisoner_cfg.get("min", 0.05)), float(prisoner_cfg.get("max", 0.9)))


## Action: `by` tries to talk prisoner `p` into joining. One try per prisoner
## per council. Returns true if it joins (it stands in by's castle, no troops).
func persuade(by: General, p: General) -> bool:
	if not can_act(by):
		return false
	var chance := recruit_chance(p, by)
	if chance <= 0.0:
		return false
	tried[p.id] = true
	if rng.randf() >= chance:
		acted[by.id] = "persuade_fail"
		_events.append({"type": "refused", "general": p.id, "by": by.id})
		return false
	acted[by.id] = "persuade_ok"
	p.side = by.side
	p.held_by = ""
	p.captive_councils = 0
	p.state = "idle"
	p.castle = by.castle
	p.from = by.castle
	p.pos = castles[by.castle].pos
	p.troops = 0.0
	p.loyalty = int(prisoner_cfg.get("joined_loyalty", 50))
	acted[p.id] = "joined"  # just arrived: no action this council (it can still take troops)
	_events.append({"type": "recruited", "general": p.id, "by": by.id, "side": by.side})
	return true


## AI actions: the best persuader (highest chance) tries each prisoner; the
## rest build an engine (walled enemy castle next door), raise the wall of a
## border castle, or levy.
func auto_actions(side: String) -> void:
	for p in prisoners_of(side):
		var best: General = null
		var best_c := 0.0
		for g in generals_of(side):
			if not can_act(g):
				continue
			var c := recruit_chance(p, g)
			if c > best_c:
				best_c = c
				best = g
		if best != null:
			persuade(best, p)
	for g in generals_of(side):
		if not can_act(g):
			continue
		if _ai_wants_engine(g):
			build_engine(g)
		elif _ai_wants_wall(g) and (g.king or castles[g.castle].capital or rng.randf() < 0.5):
			fortify(g)
		else:
			levy(g)


# --- walls and siege engines --------------------------------------------------------

func wall_max() -> int:
	return int(siege_cfg.get("wall_max", 3))


func engine_speed() -> float:
	return float(siege_cfg.get("engine_speed", 0.7))


## Damage-taken multiplier for troops behind a wall of this level (1 = none).
func wall_take(level: int) -> float:
	return clampf(1.0 - float(siege_cfg.get("wall_take_per_level", 0.1)) * level, 0.05, 1.0)


## Wall level that would count if `attacker` hit castle `cid` held by `def_side`
## (an engine cancels some). Walls only help the side that owns the castle.
func wall_against(cid: String, def_side: String, attacker: General) -> int:
	if cid == "" or not castles.has(cid) or castles[cid].owner != def_side:
		return 0
	var lv := int(castles[cid].wall)
	if attacker != null and attacker.engine:
		lv -= int(siege_cfg.get("engine_cancels", 2))
	return maxi(0, lv)


## What the walls do in a queued battle: {castle: bool, wall: castle's level,
## used: level that counts, engine: attacker brought one, side: defender side,
## take: defender troops' damage-taken x}.
func siege_info(b: Dictionary) -> Dictionary:
	var d := get_general(str(b.d))
	var cid := str(b.get("castle", ""))
	var info := {"castle": cid != "", "wall": 0, "used": 0, "engine": bool(b.get("engine", false)),
			"side": d.side if d != null else "", "take": 1.0}
	if cid == "" or d == null:
		return info
	var wall: int = int(castles[cid].wall) if castles[cid].owner == d.side else 0
	info.wall = wall
	var lv := wall
	if bool(info.engine):
		lv = maxi(0, lv - int(siege_cfg.get("engine_cancels", 2)))
	info.used = lv
	info.take = wall_take(lv)
	return info


## BattleSim overrides the walls add to a battle: {side: {"wall_take": x}}.
func battle_mods(b: Dictionary) -> Dictionary:
	var info := siege_info(b)
	if float(info.take) >= 1.0:
		return {}
	return {str(info.side): {"wall_take": float(info.take)}}


## Council action: raise the wall of the castle g stands in by one level
## (once per castle per council).
func can_fortify(g: General) -> bool:
	return can_act(g) and not fortified.has(g.castle) and int(castles[g.castle].wall) < wall_max()


func fortify(g: General) -> bool:
	if not can_fortify(g):
		return false
	var c: Dictionary = castles[g.castle]
	c.wall = int(c.wall) + 1
	fortified[g.castle] = true
	acted[g.id] = "fortify"
	_events.append({"type": "fortify", "general": g.id, "castle": g.castle, "wall": c.wall})
	return true


## Council action: build a siege engine for g to take on its next march.
func can_build_engine(g: General) -> bool:
	return can_act(g) and not g.engine and bool(siege_cfg.get("engines", true))


func build_engine(g: General) -> bool:
	if not can_build_engine(g):
		return false
	g.engine = true
	acted[g.id] = "engine"
	_events.append({"type": "engine", "general": g.id})
	return true


## AI: should g spend its action on an engine? Yes when an enemy castle next
## to where it stands has walls worth cutting (and g is not the king).
func _ai_wants_engine(g: General) -> bool:
	if g.king or g.engine or not can_build_engine(g):
		return false
	for n in adj[g.castle]:
		var c: Dictionary = castles[n]
		if c.owner != g.side and c.owner != "" and int(c.wall) >= int(siege_cfg.get("ai_engine_wall", 2)):
			return true
	return false


## AI: raise this castle's wall? When it borders an enemy castle and is not maxed.
func _ai_wants_wall(g: General) -> bool:
	if not can_fortify(g):
		return false
	for n in adj[g.castle]:
		if castles[n].owner == other_side(g.side):
			return true
	return false


# --- AI -------------------------------------------------------------------------

## Basic AI: every general but the king, once rested, marches on the nearest
## castle it can take (weak or no defenders). Good enough to test the map.
func _ai_think(side: String) -> void:
	var min_troops := float(rules.ai_min_troops)
	var odds := float(rules.ai_odds)
	var claimed := {}
	for g in generals:
		if g.side == side and g.state == "moving":
			claimed[g.target()] = true
	for g in generals:
		if g.side != side or g.state != "idle" or g.king or g.troops < min_troops:
			continue
		var best := ""
		var best_score := INF
		for c in castles.values():
			if c.owner == side:
				continue
			var p := shortest(g.castle, c.id, side)
			if p.is_empty():
				continue
			var defence := 0.0
			for e in generals_at(c.id, other_side(side)):
				defence += e.troops + 5.0
			# Walls make the defenders count for more (less if g brings an engine).
			defence /= wall_take(wall_against(c.id, other_side(side), g))
			if defence > g.troops * odds:
				continue
			var score := path_length(g.pos, p) + defence * 2.0
			if claimed.has(c.id):
				score += 80.0
			if score < best_score:
				best_score = score
				best = c.id
		if best != "" and order_move(g, best):
			claimed[best] = true
