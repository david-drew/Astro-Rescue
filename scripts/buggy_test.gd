extends Node2D

@export var buggy_path: NodePath

var _buggy: VehicleBuggy = null


func _ready() -> void:
	if buggy_path != NodePath(""):
		_buggy = get_node_or_null(buggy_path) as VehicleBuggy
	else:
		_buggy = $VehicleBuggy if has_node("VehicleBuggy") else null

	if _buggy == null:
		push_warning("BuggyTestScene: VehicleBuggy not found.")
		return

	_buggy.set_active(true)

	# Optional: default facing, starting position tweaks, etc.
	# _buggy.global_position = Vector2(200, 400)


func _physics_process(delta: float) -> void:
	if _buggy == null:
		return

	_buggy.apply_controls(delta)
