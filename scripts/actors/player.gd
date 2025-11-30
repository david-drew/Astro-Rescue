extends Node2D
class_name Player

signal mode_changed(old_mode: String, new_mode: String)
signal stats_changed(money: int, reputation: int)

enum PlayerMode {
	HQ,
	LANDER,
	BUGGY,
	ATV,
	EVA
}

@export var lander_path: NodePath = NodePath("VehicleLander")
@export var buggy_path: NodePath = NodePath("VehicleBuggy")
@export var eva_path: NodePath = NodePath("VehicleEVA")
@export var mission_cam_path: NodePath = NodePath("MissionCam")
@export var boarding_zone_path: NodePath
@export var surface_ops_dialog_path: NodePath


var _mission_cam: Node = null
var _surface_ops_dialog: Node = null
var _boarding_zone: LanderBoardingZone = null
var _can_board_from_surface: bool = false

var money: int = 0
var reputation: int = 0

var _mode: PlayerMode = PlayerMode.HQ

var _lander: VehicleLander = null
var _buggy: VehicleBuggy = null
var _eva: VehicleEVA = null


func _ready() -> void:
	var eb = EventBus
	_lander = get_node_or_null(lander_path) as VehicleLander
	_buggy = get_node_or_null(buggy_path) as VehicleBuggy
	_eva = get_node_or_null(eva_path) as VehicleEVA
	_mission_cam = get_node_or_null(mission_cam_path)

	if surface_ops_dialog_path != NodePath(""):
		_surface_ops_dialog = get_node_or_null(surface_ops_dialog_path)
		
	if _surface_ops_dialog is SurfaceOpsDialog:
		var sod := _surface_ops_dialog as SurfaceOpsDialog
		if not sod.is_connected("deploy_buggy_confirmed", Callable(self, "_on_deploy_buggy_confirmed")):
			sod.deploy_buggy_confirmed.connect(_on_deploy_buggy_confirmed)
		if not sod.is_connected("board_lander_confirmed", Callable(self, "_on_board_lander_confirmed")):
			sod.board_lander_confirmed.connect(_on_board_lander_confirmed)


	# Start in HQ and explicitly deactivate all vehicles.
	_set_mode(PlayerMode.HQ, true)

	if boarding_zone_path != NodePath(""):
		_boarding_zone = get_node_or_null(boarding_zone_path) as LanderBoardingZone
		if _boarding_zone != null:
			_boarding_zone.surface_vehicle_entered.connect(_on_surface_vehicle_entered_board_zone)
			_boarding_zone.surface_vehicle_exited.connect(_on_surface_vehicle_exited_board_zone)

	if not eb.is_connected("set_vehicle_mode", Callable(self, "_on_set_vehicle_mode")):
		eb.connect("set_vehicle_mode", Callable(self, "_on_set_vehicle_mode"))

func _physics_process(delta: float) -> void:
	# Delegate controls only to active mode controller.
	# Each vehicle handles its own movement/forces internally.
	if _mode == PlayerMode.LANDER:
		if _lander != null:
			_lander.apply_controls(delta)
		# Check for exit / deploy buggy
		_handle_vehicle_interact()
		return

	if _mode == PlayerMode.BUGGY or _mode == PlayerMode.ATV:
		if _buggy != null:
			_buggy.apply_controls(delta)
		_handle_vehicle_interact()
		return

	if _mode == PlayerMode.EVA:
		if _eva != null:
			_eva.apply_controls(delta)
		_handle_vehicle_interact()
		return



# -------------------------------------------------------------------
# Public Mode API (MissionPhaseRunner / MissionController will call)
# -------------------------------------------------------------------

func enter_hq() -> void:
	_set_mode(PlayerMode.HQ)

func enter_lander() -> void:
	_set_mode(PlayerMode.LANDER)

func enter_buggy(phase: Dictionary = {}) -> void:
	_set_mode(PlayerMode.BUGGY)
	if _buggy != null:
		_buggy.apply_vehicle_phase(phase)

func enter_atv(phase: Dictionary = {}) -> void:
	_set_mode(PlayerMode.ATV)
	if _buggy != null:
		_buggy.apply_vehicle_phase(phase)

func enter_eva() -> void:
	_set_mode(PlayerMode.EVA)

func get_mode_string() -> String:
	return _mode_to_string(_mode)

func get_lander() -> VehicleLander:
	return _lander

func get_buggy() -> VehicleBuggy:
	return _buggy

func get_eva() -> VehicleEVA:
	return _eva

func get_active_vehicle() -> Node:
	if _mode == PlayerMode.LANDER:
		return _lander
	if _mode == PlayerMode.BUGGY or _mode == PlayerMode.ATV:
		return _buggy
	if _mode == PlayerMode.EVA:
		return _eva
	return null


# -------------------------------------------------------------------
# Stats API
# -------------------------------------------------------------------

func add_money(delta: int) -> void:
	money += delta
	_emit_stats_changed()

func add_reputation(delta: int) -> void:
	reputation += delta
	_emit_stats_changed()

func set_money(value: int) -> void:
	money = max(0, value)
	_emit_stats_changed()

func set_reputation(value: int) -> void:
	reputation = max(0, value)
	_emit_stats_changed()

func _emit_stats_changed() -> void:
	emit_signal("stats_changed", money, reputation)

	# Safe optional mirroring to GameState for save/load later
	if typeof(GameState) != TYPE_NIL and GameState != null:
		GameState.money = money
		GameState.reputation = reputation


# -------------------------------------------------------------------
# Internal mode machine
# -------------------------------------------------------------------

func _set_mode(new_mode: PlayerMode, force: bool = false) -> void:
	if new_mode == _mode and not force:
		return

	var old_name: String = _mode_to_string(_mode)
	var new_name: String = _mode_to_string(new_mode)
	_mode = new_mode

	# Activate exactly one controller
	_set_controller_active(_lander, new_mode == PlayerMode.LANDER)
	_set_controller_active(_buggy, new_mode == PlayerMode.BUGGY or new_mode == PlayerMode.ATV)
	_set_controller_active(_eva, new_mode == PlayerMode.EVA)
	
	_update_mission_cam_target()

	emit_signal("mode_changed", old_name, new_name)


func _set_controller_active(node: Node, active: bool) -> void:
	if node == null:
		return

	# Let vehicle scripts manage their own activation if they support it.
	if node.has_method("set_active"):
		node.set_active(active)

	# Fallback visibility for safety
	if node is CanvasItem:
		node.visible = active
		if active:
			node.show()
		else:
			node.hide()

	# Ensure processing is aligned with active state
	if active:
		node.process_mode = Node.PROCESS_MODE_INHERIT
		node.set_physics_process(true)
	else:
		node.process_mode = Node.PROCESS_MODE_DISABLED
		node.set_physics_process(false)


func _mode_to_string(m: PlayerMode) -> String:
	if m == PlayerMode.HQ:
		return "HQ"
	if m == PlayerMode.LANDER:
		return "LANDER"
	if m == PlayerMode.BUGGY:
		return "BUGGY"
	if m == PlayerMode.ATV:
		return "ATV"
	if m == PlayerMode.EVA:
		return "EVA"
	return "UNKNOWN"


func _on_set_vehicle_mode(vehicle: String) -> void:
	var v := vehicle.to_lower()
	if v == "lander" or v == "vehicle_lander":
		enter_lander()
		return
	if v == "buggy" or v == "atv":
		enter_buggy({})
		return
	if v == "eva":
		enter_eva()
		return

	# Fallback: treat anything else as HQ/none to keep vehicles disabled
	enter_hq()

func _update_mission_cam_target() -> void:
	if _mission_cam == null:
		return

	if _mode == PlayerMode.LANDER:
		if _lander != null and _mission_cam.has_method("set_target"):
			_mission_cam.set_target(_lander, "lander")
		else:
			if _mission_cam.has_method("clear_target"):
				_mission_cam.clear_target()
		return

	if _mode == PlayerMode.BUGGY or _mode == PlayerMode.ATV:
		if _buggy != null and _mission_cam.has_method("set_target"):
			_mission_cam.set_target(_buggy, "buggy")
		else:
			if _mission_cam.has_method("clear_target"):
				_mission_cam.clear_target()
		return

	if _mode == PlayerMode.EVA:
		if _eva != null and _mission_cam.has_method("set_target"):
			_mission_cam.set_target(_eva, "eva")
		else:
			if _mission_cam.has_method("clear_target"):
				_mission_cam.clear_target()
		return

	# Any other mode (HQ, unknown) → no mission camera target.
	if _mission_cam.has_method("clear_target"):
		_mission_cam.clear_target()


func _handle_vehicle_interact() -> void:
	# Single button for enter/exit behavior.
	if not Input.is_action_just_pressed("vehicle_interact"):
		return

	if _mode == PlayerMode.LANDER:
		# Attempt to exit lander into surface ops (buggy for now).
		if _lander != null and _lander.has_method("can_exit_to_surface"):
			if _lander.can_exit_to_surface():
				_request_surface_ops_from_lander()
		return

	if _mode == PlayerMode.BUGGY or _mode == PlayerMode.ATV:
		# Attempt to re-enter lander (only allowed near a boarding zone).
		_request_board_lander_from_surface()
		return

	if _mode == PlayerMode.EVA:
		# EVA → lander boarding will follow same boarding zone rules
		_request_board_lander_from_surface()
		return

func _request_surface_ops_from_lander() -> void:
	# Player is in LANDER mode, lander is stable enough to exit.
	# Prefer to go through a dialog; fall back to direct mode change.
	if _surface_ops_dialog != null and _surface_ops_dialog.has_method("show_deploy_buggy"):
		_surface_ops_dialog.show_deploy_buggy()
	else:
		# Fallback: directly activate buggy
		enter_buggy({})


func _request_board_lander_from_surface() -> void:
	# Player is in BUGGY / ATV / EVA and near the lander (boarding zone check
	# will be wired in via a flag in a moment).
	if not _can_board_from_surface:
		return
	
	if _surface_ops_dialog != null and _surface_ops_dialog.has_method("show_board_lander"):
		_surface_ops_dialog.show_board_lander()
	else:
		enter_lander()

func _on_surface_vehicle_entered_board_zone(vehicle: Node) -> void:
	# We only care when in BUGGY / ATV / EVA modes.
	if _mode == PlayerMode.BUGGY or _mode == PlayerMode.ATV or _mode == PlayerMode.EVA:
		_can_board_from_surface = true


func _on_surface_vehicle_exited_board_zone(vehicle: Node) -> void:
	if _mode == PlayerMode.BUGGY or _mode == PlayerMode.ATV or _mode == PlayerMode.EVA:
		_can_board_from_surface = false

func _on_deploy_buggy_confirmed() -> void:
	if _buggy == null:
		push_error("[Player] Cannot deploy buggy: _buggy is null. Check buggy_path and scene.")
		return

	# Spawn buggy at (or near) lander position so it’s visible
	if _lander != null:
		_buggy.global_position = _lander.global_position + Vector2(32.0, 0.0)

	enter_buggy({})

	# Optional: notify any listeners (camera, HUD) that we’re now in buggy mode
	if EventBus.has_signal("set_vehicle_mode"):
		EventBus.emit_signal("set_vehicle_mode", "buggy")


func _on_board_lander_confirmed() -> void:
	if _lander == null:
		push_error("[Player] Cannot board lander: _lander is null.")
		return

	# Optional: snap lander to buggy/EVA position if you want them to coincide
	if _buggy != null and (_mode == PlayerMode.BUGGY or _mode == PlayerMode.ATV):
		_lander.global_position = _buggy.global_position

	enter_lander()

	if EventBus.has_signal("set_vehicle_mode"):
		EventBus.emit_signal("set_vehicle_mode", "lander")
