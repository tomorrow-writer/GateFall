## Battle HUD in the Dragon Force layout, drawn in our own style (dark panels,
## bronze trim): the two generals at the top corners (portrait, name, HP bar,
## troops left) with the clock between them, each side's MP gauge along the
## bottom with the current order in the middle. The order box opens the command
## menu (Battle.gd); keys work without it.
## Draw-only: reads the sim every frame, never changes it.
extends Control

const SCREEN := Vector2(320, 180)
const PANEL := Color(0.05, 0.06, 0.11, 0.86)
const TRIM := Color("b08a4a")
const TRIM_HI := Color("e8c27a")
const TEXT := Color(0.96, 0.94, 0.88)
const DIM := Color(0.75, 0.73, 0.68)
const HP_COL := Color("e8d25a")
const HP_LOW := Color("e05a4a")
const MP_COL := Color("5fd0ff")
const MP_READY := Color("8cff9a")
## Bottom bars are slim (13 px) so the bottom flank track shows above them.
const ORDER_BOX := Rect2(124, 165, 72, 13)

var sim = null
var view = null  # BattleView: sprite strips for the portraits
var player_side := ""
## General names per side id (world-map battles); empty = "แม่ทัพ<side>".
var names := {}
## Castle battle: one line under the clock about the walls ("" = road / field).
var siege_text := ""
var menu_open := false
var _clock := 0.0


func _process(delta: float) -> void:
	_clock += delta
	queue_redraw()


func _draw() -> void:
	if sim == null or sim.phase == "duel":
		return
	var font := ThemeDB.fallback_font
	for i in sim.sides.size():
		_draw_general_panel(font, i)
	_draw_clock(font)
	if siege_text != "":
		_text(font, siege_text, Vector2(0, 37), 6, TRIM_HI, false, SCREEN.x, true)
	if sim.time > 0.0:
		for i in sim.sides.size():
			_draw_mp(font, i)
	_draw_order_box(font)
	if menu_open:
		draw_rect(Rect2(Vector2(0, 30), Vector2(SCREEN.x, 128)), Color(0, 0, 0, 0.35))


func _side_label(id: String) -> String:
	for sd in sim.cfg.sides:
		if sd.id == id:
			return sd.get("label", id)
	return id


func _frame(r: Rect2, hi := false) -> void:
	draw_rect(r, PANEL)
	draw_rect(r.grow(-0.5), TRIM_HI if hi else TRIM, false, 1.0)


## Top corner panel: portrait, "แม่ทัพ<side>", HP bar, troops left.
## First side on the left, second mirrored on the right.
func _draw_general_panel(font: Font, i: int) -> void:
	var s = sim.sides[i]
	var g = sim.general_of(s.id)
	var left := i == 0
	var w := 128.0
	var r := Rect2(2 if left else SCREEN.x - 2 - w, 2, w, 26)
	_frame(r)
	var pr := Rect2(r.position.x + 3 if left else r.end.x - 3 - 20, r.position.y + 3, 20, 20)
	draw_rect(pr, Color(0.12, 0.13, 0.2))
	if g != null:
		_draw_portrait(g, pr, left)
	draw_rect(pr.grow(-0.5), TRIM, false, 1.0)
	var mine: bool = s.id == player_side
	var name: String = names.get(s.id, "แม่ทัพ" + _side_label(s.id))
	var tx0 := pr.end.x + 4 if left else r.position.x + 4
	var tx1 := r.end.x - 4 if left else pr.position.x - 4
	var bw := tx1 - tx0
	_text(font, name, Vector2(tx0, r.position.y + 10), 8, TEXT if mine else DIM, left, bw)
	var hp := 0.0 if g == null else clampf(g.hp / g.max_hp, 0.0, 1.0)
	var bar := Rect2(tx0, r.position.y + 12, bw, 4)
	draw_rect(bar.grow(1), Color(0, 0, 0, 0.8))
	var col := HP_LOW if hp < 0.3 else HP_COL
	var fill := Rect2(bar.position.x if left else bar.end.x - bw * hp, bar.position.y, bw * hp, bar.size.y)
	draw_rect(fill, col)
	if hp > 0.0 and hp < 0.3 and fmod(_clock, 0.6) < 0.3:
		draw_rect(fill, Color(1, 1, 1, 0.35))
	var troops := "ทหาร ×%d" % sim.troop_count(s.id)
	var hp_txt := "%d" % (0 if g == null else maxi(0, ceili(g.hp)))
	_text(font, troops, Vector2(tx0, r.position.y + 24), 7, DIM, left, bw)
	_text(font, hp_txt, Vector2(tx0, r.position.y + 24), 7, DIM, not left, bw)


## Head-and-shoulders crop of the general's idle frame (or the "portrait"
## rect [x, y, w, h] in its sprite config). Mirrored so both face the middle.
func _draw_portrait(g, pr: Rect2, left: bool) -> void:
	if view == null or not view._sprites.has(g.type_id):
		return
	var sp: Dictionary = view._sprites[g.type_id]
	var tex: Texture2D = sp.anims.idle.tex
	var defs: Dictionary = sim.cfg.get("sprites", {}).get(g.type_id, {})
	var src: Rect2
	if defs.has("portrait"):
		var p: Array = defs.portrait
		src = Rect2(p[0], p[1], p[2], p[3])
	else:
		var foot: Vector2 = sp.foot
		var top := foot.y - float(sp.height)
		src = Rect2(foot.x - 10.0, maxf(0.0, top - 1.0), 20, 20)
	var flip := 1.0 if left else -1.0
	draw_set_transform(pr.get_center(), 0.0, Vector2(flip, 1))
	draw_texture_rect_region(tex, Rect2(-pr.size / 2.0, pr.size), src)
	draw_set_transform(Vector2.ZERO)


## Clock between the panels: time left, red in the last 30 s.
func _draw_clock(font: Font) -> void:
	var r := Rect2(SCREEN.x / 2.0 - 25, 2, 50, 26)
	_frame(r)
	var limit := float(sim.cfg.sim.time_limit)
	var left := maxf(0.0, limit - sim.time)
	_text(font, "เวลา", Vector2(r.position.x, r.position.y + 9), 7, DIM, true, r.size.x, true)
	var col := HP_LOW if left <= 30.0 and sim.time > 0.0 else TRIM_HI
	_text(font, "%d" % ceili(left), Vector2(r.position.x, r.position.y + 23), 14, col, true, r.size.x, true)


## Bottom gauges: each side's MP on its own half, a tick at each special's
## cost (small / medium / large: taller tick for the bigger one, lit once
## affordable), the bar glowing when any can be cast. The enemy's is shown
## too, as in DF, so the player can see a special coming. A guard running
## shows as a shield bar under the gauge.
func _draw_mp(font: Font, i: int) -> void:
	var s = sim.sides[i]
	if s.specials.is_empty():
		return
	var left := i == 0
	var w := 116.0
	var r := Rect2(2 if left else SCREEN.x - 2 - w, 165, w, 13)
	_frame(r)
	var k := clampf(s.mp / maxf(1.0, s.mp_max), 0.0, 1.0)
	var ready: bool = sim.special_ready(s.id)
	var label := "MP %d" % int(s.mp)
	_text(font, label, Vector2(r.position.x + 4, r.position.y + 9.5), 7, TEXT, left, r.size.x - 8)
	var bx := r.position.x + 40 if left else r.position.x + 4
	var bar := Rect2(bx, r.position.y + 4, w - 44, 4)
	draw_rect(bar.grow(1), Color(0, 0, 0, 0.8))
	var col := MP_READY if ready else MP_COL
	if ready and fmod(_clock, 0.8) < 0.4:
		col = col.lightened(0.35)
	if left:
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * k, bar.size.y)), col)
	else:
		draw_rect(Rect2(bar.end.x - bar.size.x * k, bar.position.y, bar.size.x * k, bar.size.y), col)
	for j in s.specials.size():
		var cost := float(s.specials[j].mp_cost)
		var ck := clampf(cost / maxf(1.0, s.mp_max), 0.0, 1.0)
		var tx := roundf(bar.position.x + bar.size.x * ck if left else bar.end.x - bar.size.x * ck)
		var tick := TRIM_HI if s.mp >= cost else Color(TRIM, 0.7)
		draw_line(Vector2(tx, bar.position.y - 1 - j), Vector2(tx, bar.end.y + 1), tick, 1.0)
	if not s.guard.is_empty():
		var gk := clampf(float(s.guard.left) / maxf(0.001, float(s.guard.total)), 0.0, 1.0)
		var gcol := Color(str(s.guard.special.get("color", "8cc8ff")))
		var gw := bar.size.x * gk
		var gx := bar.position.x if left else bar.end.x - gw
		draw_rect(Rect2(gx, bar.end.y + 1.5, gw, 1.5), gcol)


## Middle of the bottom: the player's current order; click (or Tab) for the menu.
func _draw_order_box(font: Font) -> void:
	var s = sim.get_side(player_side)
	var hover := get_local_mouse_position()
	_frame(ORDER_BOX, menu_open or ORDER_BOX.has_point(hover))
	var label := str(sim.cfg.orders.get(s.order_name, {}).get("label", s.order_name))
	if s.gen_charge:
		label += " · แม่ทัพบุก"
	if s.squads and s.guard_out:
		label += " · คุ้มกันบุก"
	if s.dispersed:
		label += " · แตกปีก"
	if s.raiding:
		label += " · จู่โจมอ้อม"
	if s.form_command == "divrush":
		label += " · กอง %d/%d" % [s.divs_sent, s.divs]
	_text(font, label, Vector2(ORDER_BOX.position.x, ORDER_BOX.position.y + 9.5), 8, TRIM_HI, true, ORDER_BOX.size.x - 14, true)
	# key hint tucked in the right edge of the box
	_text(font, "Tab", Vector2(ORDER_BOX.position.x, ORDER_BOX.position.y + 9), 6, DIM, false, ORDER_BOX.size.x - 3)


## Text helper: left- or right-aligned (or centred) inside a width, 1 px shadow.
func _text(font: Font, t: String, pos: Vector2, size: int, col: Color, left: bool, width: float,
		centre := false) -> void:
	var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var x := pos.x
	if centre:
		x = pos.x + (width - tw) / 2.0
	elif not left:
		x = pos.x + width - tw
	draw_string(font, Vector2(x + 1, pos.y + 1), t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.8))
	draw_string(font, Vector2(x, pos.y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
