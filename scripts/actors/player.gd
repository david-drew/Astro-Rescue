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

    # Start in HQ and explicitly deactivate all vehicles.
    _set_mode(PlayerMode.HQ, true)

    if not eb.is_connected("set_vehicle_mode", Callable(self, "_on_set_vehicle_mode")):
        eb.connect("set_vehicle_mode", Callable(self, "_on_set_vehicle_mode"))


func _physics_process(delta: float) -> void:
    # Delegate controls only to active mode controller.
    # Each vehicle handles its own movement/forces internally.
    if _mode == PlayerMode.LANDER:
        if _lander != null:
            _lander.apply_controls(delta)
        return

    if _mode == PlayerMode.BUGGY or _mode == PlayerMode.ATV:
        if _buggy != null:
            _buggy.apply_controls(delta)
        return

    if _mode == PlayerMode.EVA:
        if _eva != null:
            _eva.apply_controls(delta)
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
