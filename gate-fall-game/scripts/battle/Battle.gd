## Battle scene controller: setup (pick formation) -> fight -> result.
## Owns the BattleSim, steps it at the fixed rate from the config (same dt as
## tools/run_sims.gd, so play and balance numbers agree), forwards events to
## BattleView and wires the HUD.
##
## Keys:
##   1 = charge, 2 = hold, 3 = retreat
##   Q / A / Z (or Up / Left / Down) = open the top / middle / bottom lane
##     (same key again closes it); clicking a lane on the field does the same
##   G = send the general in / call it back
##   Space = special, Enter = start / again
## Specials have a warning time instead of a freeze: the target lane lights up
## and the battle keeps running, so there is time to open that lane (or pull
## back from a full-field wave). A lane special fired by the player runs down
## the lane with the most enemies (BattleSim.cast picks it).
extends Node2D

const BattleSim = preload("res://scripts/battle/BattleSim.gd")
const BattleRng = preload("res://scripts/battle/BattleRng.gd")

## Which side the player commands. The other side is AI.
@export var player_side := "S"
@export_file("*.json") var config_path := "res://data/battle_config.json"
## Seed for reproducing a battle exactly; 0 = new random battle each time.
@export var fixed_seed := 0

const ORDER_KEYS := {"charge": "1", "hold": "2", "retreat": "3"}
const LANE_KEYS := ["Q", "A", "Z"]

@onready var view = $View
@onready var mp_label: Label = %MpLabel
@onready var mp_bar: ProgressBar = %MpBar
@onready var count_label: Label = %CountLabel
@onready var time_label: Label = %TimeLabel
@onready var charge_btn: Button = %ChargeButton
@onready var hold_btn: Button = %HoldButton
@onready var retreat_btn: Button = %RetreatButton
@onready var lane_box: Container = %LaneBox
@onready var general_btn: Button = %GeneralButton
@onready var special_btn: Button = %SpecialButton
@onready var setup_panel: Control = %SetupPanel
@onready var formation_list: Container = %FormationList
@onready var formation_info: Label = %FormationInfo
@onready var start_btn: Button = %StartButton
@onready var result_panel: Control = %ResultPanel
@onready var result_label: Label = %ResultLabel
@onready var result_detail: Label = %ResultDetail
@onready var again_btn: Button = %AgainButton

var cfg: Dictionary
var sim: BattleSim
var phase := "setup"  # setup | fight | over
var formation := ""
var order := "charge"

var _dt := 1.0 / 15.0
var _acc := 0.0
var _seed := 1
var _enemy_side := ""
var _formation_buttons := {}
var _order_buttons := {}
var _lane_buttons: Array[Button] = []


func _ready() -> void:
	cfg = BattleSim.load_config(config_path)
	if cfg.is_empty():
		return
	_dt = 1.0 / float(cfg.sim.steps_per_second)
	for sd in cfg.sides:
		if sd.id == player_side:
			formation = sd.formation
			order = sd.order if cfg.orders.has(sd.order) else "charge"
		else:
			_enemy_side = sd.id

	var order_group := ButtonGroup.new()
	_order_buttons = {"charge": charge_btn, "hold": hold_btn, "retreat": retreat_btn}
	for name in _order_buttons:
		var b: Button = _order_buttons[name]
		if not cfg.orders.has(name):
			b.hide()
			continue
		b.button_group = order_group
		b.text = "%s [%s]" % [cfg.orders[name].get("label", name), ORDER_KEYS[name]]
		b.pressed.connect(_set_order.bind(name))

	# Lane buttons: one per lane, top to bottom
	var lanes := int(cfg.get("lanes", {}).get("count", 0))
	var labels: Array = cfg.get("lanes", {}).get("labels", [])
	for i in lanes:
		var b := Button.new()
		var key: String = LANE_KEYS[i] if i < LANE_KEYS.size() else ""
		b.text = "%s[%s]" % [labels[i] if i < labels.size() else str(i + 1), key]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 9)
		b.tooltip_text = "แยกเลน: เปิดเลน%s ให้ท่าพิเศษผ่าน" % (labels[i] if i < labels.size() else "")
		b.pressed.connect(_split.bind(i))
		lane_box.add_child(b)
		_lane_buttons.append(b)
	lane_box.visible = lanes > 0

	general_btn.toggle_mode = true
	general_btn.pressed.connect(_toggle_general)
	special_btn.pressed.connect(_cast_special)
	start_btn.pressed.connect(_start_fight)
	again_btn.pressed.connect(_back_to_setup)

	var form_group := ButtonGroup.new()
	for key in cfg.formations.keys():
		var b := Button.new()
		b.text = cfg.formations[key].get("label", key)
		b.toggle_mode = true
		b.button_group = form_group
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_pick_formation.bind(key))
		formation_list.add_child(b)
		_formation_buttons[key] = b

	view.player_side = player_side
	_back_to_setup()


func _process(delta: float) -> void:
	if sim == null:
		return
	if phase == "fight":
		_acc += delta
		while _acc >= _dt and phase == "fight":
			_acc -= _dt
			view.capture_prev()
			var events := sim.step(_dt)
			view.handle_events(events)
			for e in events:
				if e.type == "over":
					_show_result(e.winner)
		view.alpha = clampf(_acc / _dt, 0.0, 1.0)
	else:
		view.alpha = 1.0
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Click a lane on the field to open it.
		if phase == "fight" and sim != null and sim.lane_count() > 0:
			var p := get_global_mouse_position()
			var f: Dictionary = cfg.field
			if p.y >= float(f.y_min) - 20.0 and p.y <= float(f.y_max) + 4.0:
				_split(sim.lane_of(p.y))
				get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_1:
			_set_order("charge")
		KEY_2:
			_set_order("hold")
		KEY_3:
			_set_order("retreat")
		KEY_Q, KEY_UP:
			_split(0)
		KEY_A, KEY_LEFT:
			_split(1)
		KEY_Z, KEY_DOWN:
			_split(2)
		KEY_G:
			_toggle_general()
		KEY_SPACE:
			_cast_special()
		KEY_ENTER, KEY_KP_ENTER:
			if phase == "setup":
				_start_fight()
			elif phase == "over":
				_back_to_setup()


# --- phases ------------------------------------------------------------------

func _back_to_setup() -> void:
	phase = "setup"
	result_panel.hide()
	setup_panel.show()
	_pick_formation(formation)
	_set_order(order)


func _pick_formation(key: String) -> void:
	if phase != "setup":
		return
	formation = key
	_formation_buttons[key].button_pressed = true
	formation_info.text = _formation_text(cfg.formations[key])
	_new_sim()


## Builds the battle now so the setup screen shows the real starting positions.
func _new_sim() -> void:
	if sim != null:
		sim.dispose()
	_seed = fixed_seed if fixed_seed > 0 else randi_range(1, 2147483646)
	# The other side is the AI: BattleAI casts, dodges and sends its general in.
	var overrides := {player_side: {"formation": formation, "order": order, "auto_cast": false},
			_enemy_side: {"ai": true}}
	sim = BattleSim.new(cfg, overrides, BattleRng.new(_seed))
	view.bind(sim)


func _start_fight() -> void:
	if phase != "setup":
		return
	phase = "fight"
	setup_panel.hide()
	_acc = 0.0


func _show_result(winner: String) -> void:
	phase = "over"
	var mine := sim.troop_count(player_side)
	var theirs := sim.troop_count(_enemy_side)
	if winner == player_side:
		result_label.text = "ชนะ!"
		result_detail.text = _defeat_text(_enemy_side) + "\nเหลือทหาร %d · %.0f วินาที" % [mine, sim.time]
	elif winner == "draw":
		result_label.text = "เสมอ (หมดเวลา)"
		result_detail.text = "ทหารเหลือ %d ต่อ %d" % [mine, theirs]
	else:
		result_label.text = "แพ้"
		result_detail.text = _defeat_text(player_side) + "\nศัตรูเหลือ %d · %.0f วินาที" % [theirs, sim.time]
	result_detail.text += "\nseed %d" % _seed
	result_panel.show()


func _defeat_text(loser: String) -> String:
	if sim.defeat_reason(loser) == "general":
		return "แม่ทัพ%sล้ม" % _side_label(loser)
	return "ทัพ%sถูกกวาดล้าง" % _side_label(loser)


# --- commands ----------------------------------------------------------------

func _set_order(name: String) -> void:
	if phase == "over" or not cfg.orders.has(name):
		return
	order = name
	if _order_buttons.has(name):
		_order_buttons[name].button_pressed = true
	if sim != null:
		sim.set_order(player_side, name)


func _split(lane: int) -> void:
	if phase != "fight" or sim == null or lane < 0:
		return
	sim.split(player_side, lane)


func _toggle_general() -> void:
	if phase != "fight" or sim == null:
		return
	var s := sim.get_side(player_side)
	sim.set_general_charge(player_side, not s.gen_charge)


func _cast_special() -> void:
	if phase != "fight" or sim == null:
		return
	sim.cast(player_side)


# --- HUD ---------------------------------------------------------------------

func _update_hud() -> void:
	if sim == null:
		return
	var s := sim.get_side(player_side)
	var has_special := not s.special.is_empty()
	mp_bar.max_value = s.mp_max
	mp_bar.value = s.mp
	mp_label.text = "พลังเวท %d" % int(s.mp)
	mp_bar.visible = has_special
	mp_label.visible = has_special
	count_label.text = "%s %d   %s %d" % [_side_label(player_side), sim.troop_count(player_side),
			_side_label(_enemy_side), sim.troop_count(_enemy_side)]
	time_label.text = "%d วิ" % int(sim.time)
	special_btn.visible = has_special
	if has_special:
		var cost := float(s.special.mp_cost)
		special_btn.text = "%s (%d) [Space]" % [s.special.get("label", "special"), int(cost)]
		special_btn.disabled = phase != "fight" or not sim.special_ready(player_side)
	for i in _lane_buttons.size():
		_lane_buttons[i].set_pressed_no_signal(s.split_lane == i)
		_lane_buttons[i].disabled = phase != "fight"
	if _order_buttons.has(s.order_name) and not _order_buttons[s.order_name].button_pressed:
		_order_buttons[s.order_name].set_pressed_no_signal(true)
	var g := sim.general_of(player_side)
	general_btn.visible = g != null
	general_btn.disabled = phase != "fight" or g == null or not g.alive
	general_btn.set_pressed_no_signal(s.gen_charge)
	var gc: Dictionary = cfg.get("general_charge", {})
	general_btn.text = ("กลับหลังแนว [G]" if s.gen_charge else "%s [G]" % gc.get("label", "แม่ทัพลงสนาม"))


func _side_label(id: String) -> String:
	for sd in cfg.sides:
		if sd.id == id:
			return sd.get("label", id)
	return id


func _formation_text(f: Dictionary) -> String:
	var t := "ตี ×%s   รับดาเมจ ×%s   ความเร็ว ×%s" % [_num(f.atk), _num(f.take), _num(f.spd)]
	if f.has("role"):
		t = f.role + "\n" + t
	if f.has("flank"):
		t += "   ·   รุม %d ตัวขึ้นไป ตี ×%s" % [int(f.get("flank_min", 2)), _num(f.flank)]
	return t


func _num(v) -> String:
	return str(snappedf(float(v), 0.01))
