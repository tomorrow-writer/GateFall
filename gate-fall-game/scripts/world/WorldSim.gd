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

	func target() -> String:
		return str(path[-1]) if not path.is_empty() else castle


var data: Dictionary
var rules: Dictionary
var castles := {}  # id -> {id, name, pos: Vector2, owner, capital}
var adj := {}  # castle id -> [castle ids]
var generals: Array[General] = []
var day := 0.0
var ai_sides: Array = []
var winner := ""  # "" while the war goes on, then a side id
var battles: Array = []  # queued: {id, a, d, castle} (a, d = general ids, castle "" = on a road)

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


func _init(map_data: Dictionary, ai: Array = []) -> void:
	data = map_data
	rules = data.rules
	ai_sides = ai
	for c in data.castles:
		castles[c.id] = {"id": c.id, "name": c.name, "pos": Vector2(c.pos[0], c.pos[1]),
				"owner": str(c.get("owner", "")), "capital": bool(c.get("capital", false))}
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
		g.troops = float(gd.get("troops", rules.max_troops))
		g.castle = gd.castle
		g.from = gd.castle
		g.pos = castles[gd.castle].pos
		generals.append(g)


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
	if winner != "" or not battles.is_empty():
		return _take_events()
	day += days
	var speed := float(rules.move_speed)
	for g in generals:
		if g.state == "moving":
			_walk(g, days * speed)
			if not battles.is_empty() or winner != "":
				break
	if battles.is_empty():
		_check_meetings()
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
	if not passing:
		g.state = "idle"
		g.castle = cid
		g.path.clear()
	_events.append({"type": "capture", "general": g.id, "castle": cid, "from": was})
	if c.capital and was != "":
		_end_war(g.side)


func _start_battle(a: General, d: General, cid: String) -> void:
	a.state = "battle"
	d.state = "battle"
	var b := {"id": _next_battle, "a": a.id, "d": d.id, "castle": cid}
	_next_battle += 1
	battles.append(b)
	_events.append({"type": "battle", "battle": b.id})


## Enemy generals walking the same road (either way) close enough = battle.
func _check_meetings() -> void:
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
			if same_road and a.pos.distance_to(b.pos) <= meet:
				_start_battle(a, b, "")
				return


func _regen(days: float) -> void:
	var cap := float(rules.max_troops)
	var per := float(rules.regen_per_day)
	for g in generals:
		if g.state == "idle" and castles[g.castle].owner == g.side and g.troops < cap:
			g.troops = minf(cap, g.troops + per * days)


# --- battles --------------------------------------------------------------------

## Settle a queued battle. winner = side id or "draw"; left = troops left per
## side id ({"S": 12, "K": 0}).
func resolve_battle(id: int, winner_side: String, left: Dictionary) -> void:
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
		g.state = "captured"
		g.path.clear()
		_events.append({"type": "captured", "general": g.id})
		return
	g.from = best[0]
	g.path = best.slice(1) if g.pos.distance_to(castles[best[0]].pos) < 0.5 else best
	g.state = "moving"
	g.retreating = true
	_events.append({"type": "retreat", "general": g.id, "to": best[-1]})


func _check_wipeout() -> void:
	for side in ["S", "K"]:
		if winner == "" and generals_of(side).is_empty():
			_end_war(other_side(side))


func _end_war(side: String) -> void:
	if winner != "":
		return
	winner = side
	_events.append({"type": "over", "winner": side})


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
