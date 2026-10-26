## Battle scene controller: setup (pick formation) -> fight -> result.
## Owns the BattleSim, steps it at the fixed rate from the config (same dt as
## tools/run_sims.gd, so play and balance numbers agree), forwards events to
## BattleView and wires the HUD.
##
## Keys: 1 = charge, 2 = hold, Space = special, Enter = start / again.
extends Node2D

const BattleSim = preload("res://scripts/battle/BattleSim.gd")
const BattleRng = preload("res://scripts/battle/BattleRng.gd")

## Which side the player commands. The other side is AI.
@export var player_side := "S"
@export_file("*.json") var config_path := "res://data/battle_config.json"
## Seed for reproducing a battle exactly; 0 = new random battle each time.
@export var fixed_seed := 0

@onready var view = $View
@onready var mp_label: Label = %MpLabel
@onready var mp_bar: ProgressBar = %MpBar
@onready var count_label: Label = %CountLabel
@onready var time_label: Label = %TimeLabel
@onready var charge_btn: Button = %ChargeButton
@onready var hold_btn: Button = %HoldButton
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
var _freeze := 0.0  # special cutscene: sim time stops
var _seed := 1
var _enemy_side := ""
var _formation_buttons := {}


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
	charge_btn.button_group = order_group
	hold_btn.button_group = order_group
	charge_btn.text = "%s [1]" % cfg.orders.charge.get("label", "charge")
	hold_btn.text = "%s [2]" % cfg.orders.hold.get("label", "hold")
	charge_btn.pressed.connect(_set_order.bind("charge"))
	hold_btn.pressed.connect(_set_order.bind("hold"))
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

	_back_to_setup()


func _process(delta: float) -> void:
	if sim == null:
		return
	if phase == "fight":
		if _freeze > 0.0:
			_freeze -= delta
		else:
			_acc += delta
			while _acc >= _dt and phase == "fight":
				_acc -= _dt
				view.capture_prev()
				var events := sim.step(_dt)
				view.handle_events(events)
				for e in events:
					if e.type == "cast" and e.side != player_side:
						_begin_cutscene(sim.get_side(e.side))
					elif e.type == "over":
						_show_result(e.winner)
				if _freeze > 0.0:
					break
		view.alpha = clampf(_acc / _dt, 0.0, 1.0) if _freeze <= 0.0 else 1.0
	else:
		view.alpha = 1.0
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_1:
			_set_order("charge")
		KEY_2:
			_set_order("hold")
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
	var overrides := {player_side: {"formation": formation, "order": order, "auto_cast": false}}
	sim = BattleSim.new(cfg, overrides, BattleRng.new(_seed))
	view.bind(sim)


func _start_fight() -> void:
	if phase != "setup":
		return
	phase = "fight"
	setup_panel.hide()
	_acc = 0.0
	_freeze = 0.0


func _show_result(winner: String) -> void:
	phase = "over"
	var c := sim.count()
	if winner == player_side:
		result_label.text = "ชนะ!"
		result_detail.text = "เหลือทหาร %d · %.0f วินาที" % [c[player_side], sim.time]
	elif winner == "draw":
		result_label.text = "เสมอ (หมดเวลา)"
		result_detail.text = "เหลือ %d ต่อ %d" % [c[player_side], c[_enemy_side]]
	else:
		result_label.text = "แพ้"
		result_detail.text = "ศัตรูเหลือ %d · %.0f วินาที" % [c[_enemy_side], sim.time]
	result_detail.text += "\nseed %d" % _seed
	result_panel.show()


# --- commands ----------------------------------------------------------------

func _set_order(name: String) -> void:
	if phase == "over":
		return
	order = name
	(charge_btn if name == "charge" else hold_btn).button_pressed = true
	if sim != null:
		sim.set_order(player_side, name)


func _cast_special() -> void:
	if phase != "fight" or _freeze > 0.0 or sim == null:
		return
	var s := sim.get_side(player_side)
	if sim.cast(player_side):
		_begin_cutscene(s)


func _begin_cutscene(s) -> void:
	_freeze = float(s.special.get("cutscene_time", 0.0))
	view.start_cutscene(_freeze, s.special.get("label", ""))


# --- HUD ---------------------------------------------------------------------

func _update_hud() -> void:
	if sim == null:
		return
	var s := sim.get_side(player_side)
	var c := sim.count()
	var has_special := not s.special.is_empty()
	mp_bar.max_value = s.mp_max
	mp_bar.value = s.mp
	mp_label.text = "พลังเวท %d" % int(s.mp)
	mp_bar.visible = has_special
	mp_label.visible = has_special
	count_label.text = "%s %d   %s %d" % [_side_label(player_side), c[player_side], _side_label(_enemy_side), c[_enemy_side]]
	time_label.text = "%d วิ" % int(sim.time)
	special_btn.visible = has_special
	if has_special:
		var cost := float(s.special.mp_cost)
		special_btn.text = "%s (%d) [Space]" % [s.special.get("label", "special"), int(cost)]
		special_btn.disabled = phase != "fight" or _freeze > 0.0 or s.mp < cost or not s.wave.is_empty()


func _side_label(id: String) -> String:
	for sd in cfg.sides:
		if sd.id == id:
			return sd.get("label", id)
	return id


func _formation_text(f: Dictionary) -> String:
	var t := "ตี ×%s   รับดาเมจ ×%s   ความเร็ว ×%s" % [_num(f.atk), _num(f.take), _num(f.spd)]
	if f.has("flank"):
		t += "   ·   รุม %d ตัวขึ้นไป ตี ×%s" % [int(f.get("flank_min", 2)), _num(f.flank)]
	return t


func _num(v) -> String:
	return str(snappedf(float(v), 0.01))
