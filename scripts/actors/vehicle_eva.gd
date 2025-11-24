extends CharacterBody2D
class_name VehicleEVA

signal interacted(target_id: String)

@export var walk_speed: float = 120.0
@export var debug_logging: bool = false

var _active: bool = false


func set_active(active: bool) -> void:
	_active = active
	visible = active
	set_physics_process(active)
	process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED


# Called by Player
func apply_controls(delta: float) -> void:
	if not _active:
		return

	if Input.is_action_just_pressed("eva_interact"):
		var target_id := _get_interactable_target_id()
		if target_id != "":
			try_interact(target_id)

	var x: float = Input.get_action_strength("eva_right") - Input.get_action_strength("eva_left")
	var y: float = Input.get_action_strength("eva_down") - Input.get_action_strength("eva_up")

	var dir := Vector2(x, y)
	if dir.length() > 1.0:
		dir = dir.normalized()

	velocity = dir * walk_speed
	move_and_slide()


func try_interact(target_id: String) -> void:
	emit_signal("interacted", target_id)
	EventBus.emit_signal("eva_interacted", target_id)

func _get_interactable_target_id() -> String:
	# TODO: replace with overlap query / nearest interactable
	# For now, if you already track something, return it here.
	return ""
