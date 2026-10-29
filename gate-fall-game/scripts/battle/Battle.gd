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
##   4 / 5 / 6 = the general's small / medium / large special,
##   Space = the largest special ready now, Enter = start / again
##   F2 = HD light on/off (bloom, grading, vignette: shaders/hd_post.gdshader)
##   ` (backquote, left of 1) or the DEV button = dev mode (setup screen):
##     pick each side's troops from dev.troop_options in the config (e.g.
##     ranged slime mages). 7 / 8 cycle the player's / enemy's troops (or
##     click the two buttons). Not F-keys: macOS takes F3-F5 for itself.
##   Tab / right-click / click the order box = command menu: the battle pauses
##     while it is open (like DF's command window) and it closes on any command
## HUD (BattleHud.gd) in the DF layout: general HP at the top corners, clock in
## the middle, both sides' MP along the bottom, current order between them.
## When both armies are gone the battle stops and asks: duel (Enter) or pull
## the general out (3, the battle is lost but the general survives). The duel
## itself plays out on its own; the player watches.
## Specials have a warning time instead of a freeze: the target lane lights up
## and the battle keeps running, so there is time to open that lane (or pull
## back from a full-field wave). A lane special fired by the player runs down
## the lane with the most enemies (BattleSim.cast picks it); a bolt at the
## general always goes down the enemy general's lane.
extends Node2D

const BattleSim = preload("res://scripts/battle/BattleSim.gd")
const BattleRng = preload("res://scripts/battle/BattleRng.gd")
const FormationPicker = preload("res://scripts/battle/FormationPicker.gd")
const AutoBattle = preload("res://scripts/world/AutoBattle.gd")
## Army colour on the setup screen's formation diagrams, by side name.
const ARMY_COLOURS := {"slime": Color("8fe07a"), "human": Color("7fb2ff")}

## Which side the player commands. The other side is AI.
@export var player_side := "S"
@export_file("*.json") var config_path := "res://data/battle_config.json"
## Seed for reproducing a battle exactly; 0 = new random battle each time.
@export var fixed_seed := 0

const ORDER_KEYS := {"charge": "1", "hold": "2", "retreat": "3"}
const LANE_KEYS := ["Q", "A", "Z"]
const SPECIAL_KEYS := ["4", "5", "6"]
const TIER_LABELS := {"small": "เล็ก", "medium": "กลาง", "large": "ใหญ่"}
const FOCUS_LABELS := {"troops": "ตีทหาร", "general": "ตีแม่ทัพ", "defense": "ป้องกัน"}

@onready var view = $View
@onready var hud = %DfHud
@onready var command_menu: Control = %CommandMenu
@onready var charge_btn: Button = %ChargeButton
@onready var hold_btn: Button = %HoldButton
@onready var retreat_btn: Button = %RetreatButton
@onready var lane_box: Container = %LaneBox
@onready var general_btn: Button = %GeneralButton
@onready var special_row: Container = %SpecialRow
@onready var setup_panel: Control = %SetupPanel
@onready var formation_list: Container = %FormationList
@onready var formation_info: Label = %FormationInfo
@onready var start_btn: Button = %StartButton
@onready var duel_panel: Control = %DuelPanel
@onready var duel_title: Label = %DuelTitle
@onready var duel_info: Label = %DuelInfo
@onready var duel_btn: Button = %DuelButton
@onready var duel_retreat_btn: Button = %DuelRetreatButton
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
var _special_buttons: Array[Button] = []
var _guard_btn: Button = null  # squad formations: release / recall the guard group [R]
var _form_btn: Button = null  # the formation's own command [E] (disperse / raid / divrush)
var _picker: Control = null  # setup screen: formation cards (FormationPicker.gd)
## Command menu open: the sim does not step (DF's pausing command window).
var menu_open := false
## Campaign autoload while fighting a world-map battle (troop counts and the
## player's side come from the map, the result goes back to it); null when the
## battle scene runs on its own.
var _campaign: Node = null
## Dev mode: troop picks per side (index into cfg.dev.troop_options, -1 = config default).
@export var dev_mode := false
var _dev_troops := {}
var _dev_row: HBoxContainer = null
var _dev_buttons := {}  # side id -> Button


func _ready() -> void:
	cfg = BattleSim.load_config(config_path)
	if cfg.is_empty():
		return
	_campaign = get_node_or_null("/root/Campaign")
	if _campaign != null and _campaign.in_battle():
		player_side = str(_campaign.battle.player_side)
	else:
		_campaign = null
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
		b.text = cfg.orders[name].get("label", name)
		b.tooltip_text = "[%s]" % ORDER_KEYS[name]
		b.pressed.connect(_set_order.bind(name))

	# Lane buttons: one per lane, top to bottom
	var lanes := int(cfg.get("lanes", {}).get("count", 0))
	var labels: Array = cfg.get("lanes", {}).get("labels", [])
	for i in lanes:
		var b := Button.new()
		var key: String = LANE_KEYS[i] if i < LANE_KEYS.size() else ""
		b.text = labels[i] if i < labels.size() else str(i + 1)
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 8)
		b.tooltip_text = "แยกเลน [%s]: เปิดเลน%s ให้ท่าพิเศษผ่าน" % [key, labels[i] if i < labels.size() else ""]
		b.pressed.connect(_split.bind(i))
		lane_box.add_child(b)
		_lane_buttons.append(b)
	lane_box.visible = lanes > 0

	general_btn.toggle_mode = true
	general_btn.pressed.connect(_toggle_general)
	_guard_btn = Button.new()
	_guard_btn.toggle_mode = true
	_guard_btn.focus_mode = Control.FOCUS_NONE
	_guard_btn.add_theme_font_size_override("font_size", 8)
	_guard_btn.tooltip_text = "[R] ส่งกองคุ้มกันออกบุก / เรียกกลับมาคุ้มกันแม่ทัพ"
	_guard_btn.pressed.connect(_toggle_guard)
	general_btn.get_parent().add_child(_guard_btn)
	_form_btn = Button.new()
	_form_btn.toggle_mode = true
	_form_btn.focus_mode = Control.FOCUS_NONE
	_form_btn.add_theme_font_size_override("font_size", 8)
	_form_btn.pressed.connect(_formation_command)
	general_btn.get_parent().add_child(_form_btn)
	for i in special_row.get_child_count():
		var b: Button = special_row.get_child(i)
		b.pressed.connect(_cast_special.bind(i))
		_special_buttons.append(b)
	start_btn.pressed.connect(_start_fight)
	again_btn.pressed.connect(_back_to_setup)
	duel_btn.pressed.connect(_duel_choice.bind("duel"))
	duel_retreat_btn.pressed.connect(_duel_choice.bind("retreat"))

	var form_group := ButtonGroup.new()
	for key in cfg.formations.keys():
		var b := Button.new()
		b.text = cfg.formations[key].get("label", key)
		b.toggle_mode = true
		b.button_group = form_group
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 8)
		b.pressed.connect(_pick_formation.bind(key))
		formation_list.add_child(b)
		_formation_buttons[key] = b

	# Setup screen: the formation picker replaces the old row of buttons; the
	# old panel stays (bottom left) for the DEV row only.
	_picker = FormationPicker.new()
	var colour := Color("8fe07a")
	for sd in cfg.sides:
		if sd.id == player_side:
			colour = ARMY_COLOURS.get(str(sd.get("name", "")), colour)
	_picker.setup(cfg, colour)
	_picker.picked.connect(_pick_formation)
	_picker.start_pressed.connect(_start_fight)
	hud.get_parent().add_child(_picker)
	formation_list.get_parent().hide()
	formation_info.hide()
	setup_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	setup_panel.position = Vector2(232, 161)
	setup_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	setup_panel.size = Vector2.ZERO

	_build_dev_row()
	view.player_side = player_side
	hud.view = view
	hud.player_side = player_side
	if _campaign != null:
		hud.names = _campaign.battle.get("names", {})
	_back_to_setup()


func _process(delta: float) -> void:
	if sim == null:
		return
	if phase == "fight" and not menu_open:
		_acc += delta
		while _acc >= _dt and phase == "fight":
			_acc -= _dt
			view.capture_prev()
			var events := sim.step(_dt)
			view.handle_events(events)
			for e in events:
				if e.type == "over":
					_close_menu()
					duel_panel.hide()
					_show_result(e.winner)
				elif e.type == "duel_offer":
					_close_menu()
					_show_duel_offer()
				elif e.type == "duel_start":
					duel_panel.hide()
		view.alpha = clampf(_acc / _dt, 0.0, 1.0)
	elif phase != "fight":
		view.alpha = 1.0
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_toggle_menu()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# The order box at the bottom of the HUD opens the command menu.
		if hud.ORDER_BOX.has_point(hud.get_local_mouse_position()):
			_toggle_menu()
			get_viewport().set_input_as_handled()
			return
		if menu_open:
			return
		# Click a lane on the field to open it.
		if phase == "fight" and sim != null and sim.lane_count() > 0:
			var p: Vector2 = view.get_local_mouse_position()  # field coords (camera applied)
			var f: Dictionary = cfg.field
			if p.y >= float(f.y_min) - 20.0 and p.y <= float(f.y_max) + 4.0:
				_split(sim.lane_of(p.y))
				get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Physical key position, so the number / letter keys work with a Thai (or
	# any) keyboard layout too.
	var k: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if phase == "fight" and sim != null and sim.phase == "offer":
		match k:
			KEY_ENTER, KEY_KP_ENTER:
				_duel_choice("duel")
			KEY_3, KEY_ESCAPE:
				_duel_choice("retreat")
		return
	if k == KEY_F2:
		%PostFx.visible = not %PostFx.visible
		return
	if phase == "setup" and (k == KEY_QUOTELEFT):
		_toggle_dev()
		return
	if phase == "setup" and dev_mode and k == KEY_7:
		_cycle_troops(player_side)
		return
	if phase == "setup" and dev_mode and k == KEY_8:
		_cycle_troops(_enemy_side)
		return
	if phase == "setup" and not menu_open and _picker != null:
		var step := {KEY_LEFT: -1, KEY_RIGHT: 1, KEY_UP: -FormationPicker.COLS, KEY_DOWN: FormationPicker.COLS}
		if step.has(k):
			_picker.move(step[k])
			return
	if k == KEY_TAB:
		_toggle_menu()
		return
	if k == KEY_ESCAPE and menu_open:
		_close_menu()
		return
	match k:
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
		KEY_R:
			_toggle_guard()
		KEY_E:
			_formation_command()
		KEY_4:
			_cast_special(0)
		KEY_5:
			_cast_special(1)
		KEY_6:
			_cast_special(2)
		KEY_SPACE:
			_cast_special(-1)
		KEY_ENTER, KEY_KP_ENTER:
			if phase == "setup":
				_start_fight()
			elif phase == "over":
				_back_to_setup()


# --- phases ------------------------------------------------------------------

func _back_to_setup() -> void:
	if _campaign != null and phase == "over":
		var left := {}
		for sd in cfg.sides:
			left[sd.id] = sim.troop_count(sd.id)
		_campaign.finish_battle(sim.over, left, AutoBattle.fell_of(cfg, sim))
		return
	phase = "setup"
	result_panel.hide()
	duel_panel.hide()
	setup_panel.show()
	_pick_formation(formation)
	_set_order(order)


func _pick_formation(key: String) -> void:
	if phase != "setup":
		return
	formation = key
	_formation_buttons[key].button_pressed = true
	_new_sim()
	formation_info.text = _formation_text(cfg.formations[key]) + "\n" + _specials_text()
	_picker.selected = key
	_picker.specials_lines = _specials_text().split("\n")


## Builds the battle now so the setup screen shows the real starting positions.
func _new_sim() -> void:
	if sim != null:
		sim.dispose()
	_seed = fixed_seed if fixed_seed > 0 else randi_range(1, 2147483646)
	# The other side is the AI: BattleAI casts, dodges and sends its general in.
	var overrides := {player_side: {"formation": formation, "order": order, "auto_cast": false},
			_enemy_side: {"ai": true}}
	if dev_mode:
		for id in _dev_troops:
			var opt := _troop_option(int(_dev_troops[id]))
			if not opt.is_empty():
				overrides[id]["units"] = opt.units
	if _campaign != null:
		var troops: Dictionary = _campaign.battle.troops
		for sd in cfg.sides:
			overrides[sd.id]["units"] = [[sd.unit, int(troops.get(sd.id, sd.count))]]
	sim = BattleSim.new(cfg, overrides, BattleRng.new(_seed))
	view.bind(sim)
	hud.sim = sim


# --- dev mode: swap troop types ---------------------------------------------------

func _troop_option(i: int) -> Dictionary:
	var opts: Array = cfg.get("dev", {}).get("troop_options", [])
	return opts[i] if i >= 0 and i < opts.size() else {}


## A row under the formation info: [DEV] player troops / enemy troops.
func _build_dev_row() -> void:
	if cfg.get("dev", {}).get("troop_options", []).is_empty():
		return
	_dev_row = HBoxContainer.new()
	_dev_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_dev_row.add_theme_constant_override("separation", 3)
	var tag := Button.new()
	tag.text = "DEV [`]"
	tag.toggle_mode = true
	tag.focus_mode = Control.FOCUS_NONE
	tag.add_theme_font_size_override("font_size", 7)
	tag.add_theme_color_override("font_color", Color("ff9a3c"))
	tag.add_theme_color_override("font_pressed_color", Color("ff9a3c"))
	tag.pressed.connect(_toggle_dev)
	_dev_row.add_child(tag)
	_dev_buttons["_tag"] = tag
	for id in [player_side, _enemy_side]:
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 7)
		b.pressed.connect(_cycle_troops.bind(id))
		_dev_row.add_child(b)
		_dev_buttons[id] = b
	formation_info.get_parent().add_child(_dev_row)
	_update_dev_row()


func _toggle_dev() -> void:
	if phase != "setup":
		return
	dev_mode = not dev_mode
	_update_dev_row()
	_pick_formation(formation)


## Next troop option for a side (wraps back to the config default).
func _cycle_troops(id: String) -> void:
	if phase != "setup":
		return
	var n: int = cfg.get("dev", {}).get("troop_options", []).size()
	var i := int(_dev_troops.get(id, -1)) + 1
	_dev_troops[id] = i if i < n else -1
	_update_dev_row()
	_pick_formation(formation)


func _update_dev_row() -> void:
	if _dev_row == null:
		return
	_dev_row.visible = true  # the DEV button always shows; the troop buttons only in dev mode
	for id in _dev_buttons:
		if id == "_tag":
			_dev_buttons[id].set_pressed_no_signal(dev_mode)
			continue
		_dev_buttons[id].visible = dev_mode
		var opt := _troop_option(int(_dev_troops.get(id, -1)))
		var who := "เรา" if id == player_side else "ศัตรู"
		var key := "7" if id == player_side else "8"
		_dev_buttons[id].text = "%s: %s [%s]" % [who, opt.get("label", "ตามค่าเริ่มต้น"), key]


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
	if winner == "draw" and sim.retreated != "":
		result_label.text = "ต่างฝ่ายต่างถอย"
		result_detail.text = "แม่ทัพทั้งสองฝั่งถอยทัพ · %.0f วินาที" % sim.time
	elif winner == player_side:
		result_label.text = "ชนะ!"
		result_detail.text = _defeat_text(_enemy_side) + "\nเหลือทหาร %d · %.0f วินาที" % [mine, sim.time]
	elif winner == "draw":
		result_label.text = "เสมอ (หมดเวลา)"
		result_detail.text = "ทหารเหลือ %d ต่อ %d" % [mine, theirs]
	else:
		result_label.text = "แพ้"
		result_detail.text = _defeat_text(player_side) + "\nศัตรูเหลือ %d · %.0f วินาที" % [theirs, sim.time]
	result_detail.text += "\nseed %d" % _seed
	if _campaign != null:
		again_btn.text = "กลับแผนที่"
	result_panel.show()


func _defeat_text(loser: String) -> String:
	match sim.defeat_reason(loser):
		"retreat":
			return "แม่ทัพ%sถอยทัพ (รอดกลับไป)" % _side_label(loser)
		"duel":
			return "แม่ทัพ%sแพ้การดวล" % _side_label(loser)
	if sim.defeat_reason(loser) == "general":
		return "แม่ทัพ%sล้ม" % _side_label(loser)
	return "ทัพ%sถูกกวาดล้าง" % _side_label(loser)


# --- duel ------------------------------------------------------------------------

func _show_duel_offer() -> void:
	var mine := sim.general_of(player_side)
	var theirs := sim.general_of(_enemy_side)
	duel_title.text = "ทหารหมดทั้งสองฝั่ง: ดวลแม่ทัพ?"
	duel_info.text = "แม่ทัพ%s %d/%d  vs  แม่ทัพ%s %d/%d\nถอยทัพ = แพ้ศึกนี้ แต่แม่ทัพรอด" % [
			_side_label(player_side), ceili(mine.hp), int(mine.max_hp),
			_side_label(_enemy_side), ceili(theirs.hp), int(theirs.max_hp)]
	duel_btn.disabled = false
	duel_retreat_btn.disabled = false
	duel_panel.show()


func _duel_choice(choice: String) -> void:
	if sim == null or sim.phase != "offer":
		return
	sim.duel_choice(player_side, choice)
	duel_btn.disabled = true
	duel_retreat_btn.disabled = true
	duel_title.text = "รอฝ่ายตรงข้าม..."


# --- commands ----------------------------------------------------------------

func _set_order(name: String) -> void:
	if phase == "over" or not cfg.orders.has(name):
		return
	order = name
	if _order_buttons.has(name):
		_order_buttons[name].button_pressed = true
	if sim != null:
		sim.set_order(player_side, name)
	_close_menu()


func _split(lane: int) -> void:
	if phase != "fight" or sim == null or lane < 0:
		return
	sim.split(player_side, lane)
	_close_menu()


func _toggle_general() -> void:
	if phase != "fight" or sim == null:
		return
	var s := sim.get_side(player_side)
	sim.set_general_charge(player_side, not s.gen_charge)
	_close_menu()


## Squad formations: release the guard group or call it back.
func _toggle_guard() -> void:
	if phase != "fight" or sim == null:
		return
	var s := sim.get_side(player_side)
	if s.squads:
		sim.set_guard_out(player_side, not s.guard_out)
	_close_menu()


## The formation's own command (disperse / raid / send the next division).
func _formation_command() -> void:
	if phase != "fight" or sim == null:
		return
	sim.formation_command(player_side)
	_close_menu()


## Button text for the formation command in its current state, "" = none.
static func form_command_label(s, sim_ref) -> String:
	match s.form_command:
		"disperse":
			return "รวมปีก [E]" if s.dispersed else "แตกปีก [E]"
		"raid":
			return "เรียกกองจู่โจมกลับ [E]" if s.raiding else "จู่โจมอ้อม ×%d [E]" % sim_ref.group_count(s.id, 2)
		"divrush":
			var left: int = s.divs - s.divs_sent
			return "ส่งกองถัดไป (เหลือ %d) [E]" % left if left > 0 else "ส่งครบแล้ว"
	return ""


## slot 0 small, 1 medium, 2 large; -1 = the largest one ready.
func _cast_special(slot: int) -> void:
	if phase != "fight" or sim == null:
		return
	sim.cast(player_side, -1, slot)
	_close_menu()


## Command menu: open before the fight (starting order) or while the troops
## fight on the field; not during a duel offer, the duel or the result.
func _toggle_menu() -> void:
	if menu_open:
		_close_menu()
		return
	if sim == null or phase == "over" or sim.phase != "field":
		return
	menu_open = true


func _close_menu() -> void:
	menu_open = false


# --- HUD ---------------------------------------------------------------------

func _update_hud() -> void:
	if sim == null:
		return
	var s := sim.get_side(player_side)
	hud.menu_open = menu_open
	command_menu.visible = menu_open
	if phase == "setup":
		setup_panel.visible = not menu_open
	_picker.visible = phase == "setup" and not menu_open
	special_row.visible = not s.specials.is_empty()
	for i in _special_buttons.size():
		var b := _special_buttons[i]
		b.visible = i < s.specials.size()
		if not b.visible:
			continue
		var sp: Dictionary = s.specials[i]
		b.text = "%s %d" % [sp.get("label", "special"), int(sp.mp_cost)]
		b.tooltip_text = "[%s] %s" % [SPECIAL_KEYS[i], _special_line(sp)]
		b.disabled = phase != "fight" or not sim.special_ready(player_side, i)
	if sim.phase == "offer" and not duel_btn.disabled:
		duel_btn.text = "ดวล [Enter] %d" % ceili(maxf(0.0, float(sim.duel.offer_left)))
	elif duel_btn.text != "ดวล [Enter]":
		duel_btn.text = "ดวล [Enter]"
	var field := phase == "fight" and sim.phase == "field"
	for b in _order_buttons.values():
		b.disabled = not field and phase != "setup"
	for i in _lane_buttons.size():
		_lane_buttons[i].set_pressed_no_signal(s.split_lane == i)
		_lane_buttons[i].disabled = not field
	if _order_buttons.has(s.order_name) and not _order_buttons[s.order_name].button_pressed:
		_order_buttons[s.order_name].set_pressed_no_signal(true)
	var g := sim.general_of(player_side)
	general_btn.visible = g != null
	general_btn.disabled = not field or g == null or not g.alive
	general_btn.set_pressed_no_signal(s.gen_charge)
	var gc: Dictionary = cfg.get("general_charge", {})
	general_btn.text = ("กลับ" if s.gen_charge else str(gc.get("short_label", "ลงสนาม")))
	var fl := form_command_label(s, sim)
	_form_btn.visible = fl != ""
	if fl != "":
		_form_btn.text = fl
		_form_btn.set_pressed_no_signal(s.dispersed or s.raiding)
		_form_btn.disabled = not field or (s.form_command == "divrush" and s.divs_sent >= s.divs)
	_guard_btn.visible = s.squads
	if s.squads:
		var gn := sim.group_counts(player_side).y
		_guard_btn.disabled = not field or gn == 0
		_guard_btn.set_pressed_no_signal(s.guard_out)
		_guard_btn.text = ("คุ้มกันกลับ ×%d [R]" if s.guard_out else "คุ้มกันบุก ×%d [R]") % gn


func _side_label(id: String) -> String:
	for sd in cfg.sides:
		if sd.id == id:
			return sd.get("label", id)
	return id


func _formation_text(f: Dictionary) -> String:
	var t := "ตี ×%s   รับดาเมจ ×%s   ความเร็ว ×%s" % [_num(f.atk), _num(f.take), _num(f.spd)]
	if f.has("role"):
		t = f.role + "\n" + t
	if float(f.get("guard_share", 0)) > 0.0:
		t += "\nกองคุ้มกันอยู่รอบแม่ทัพ ตีศัตรูที่เข้ามาใกล้ (ตี ×%s รับดาเมจ ×%s) · [R] ส่งออกบุก/เรียกกลับ" % [
				_num(f.get("guard_atk", 1)), _num(f.get("guard_take", 1))]
	if f.has("flank"):
		t += "   ·   รุม %d ตัวขึ้นไป ตี ×%s" % [int(f.get("flank_min", 2)), _num(f.flank)]
	return t


## The player general's three specials, for the setup screen (two lines:
## the general's style, then the keys with name and MP).
func _specials_text() -> String:
	if sim == null:
		return ""
	var s := sim.get_side(player_side)
	if s == null or s.specials.is_empty():
		return ""
	var g := sim.general_of(player_side)
	var t := "แม่ทัพ"
	if g != null:
		var label := str(cfg.units.get(g.type_id, {}).get("focus_label", ""))
		if label != "":
			t += " · " + label
	var parts: PackedStringArray = []
	for i in s.specials.size():
		var sp: Dictionary = s.specials[i]
		parts.append("[%s] %s %d" % [SPECIAL_KEYS[i] if i < SPECIAL_KEYS.size() else "", sp.get("label", ""), int(sp.mp_cost)])
	return t + "\n" + "  ".join(parts)


## "เล็ก · ตีแม่ทัพ · กระสุน... MP 20"
func _special_line(sp: Dictionary) -> String:
	return "%s · %s · %s MP %d" % [TIER_LABELS.get(str(sp.get("tier", "")), "-"),
			FOCUS_LABELS.get(str(sp.get("focus", "")), "-"), sp.get("label", ""), int(sp.get("mp_cost", 0))]


func _num(v) -> String:
	return str(snappedf(float(v), 0.01))
