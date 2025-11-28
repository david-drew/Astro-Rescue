extends CharacterBody2D
class_name VehicleBuggy

signal arrived_at_poi(poi_id: String)
signal arrived_at_zone(zone_id: String)

@export var debug_logging: bool = false

# Default agile buggy values
var _profile: Dictionary = {}
var _active: bool = false

var _vehicle_type: String = "dune_buggy"
var _trailer_segments: int = 0

# Movement tuning
var _max_speed: float = 40.0
var _accel: float = 180.0
var _brake: float = 220.0
var _turn_speed: float = 3.5
var _max_reverse_speed: float = 18.0

# Trailer fake physics - “follow with lag” so it feels articulated
var _trailer_follow_strength: float = 6.0
var _trailer_spacing: float = 42.0

# Cargo / seats / tow
var seats: int = 4
var cargo_slots: int = 1
var tow_hooks: int = 0

@export var gravity_strength: float = 55.0
@export var ground_snap_distance: float = 6.0
@export var ground_max_angle_deg: float = 45.0


# Optional cached nodes
@onready var _trailers_root: Node2D = get_node_or_null("TrailerMounts") as Node2D
@onready var MC := MissionController.new() as MissionController


func _ready() -> void:
	# Enable CharacterBody2D built-in floor snapping.
	# Uses existing ground_snap_distance (no duplication).
	floor_snap_length = ground_snap_distance
	floor_max_angle = deg_to_rad(ground_max_angle_deg)
	add_to_group("buggy")
	
	var eb = EventBus
	if not eb.is_connected("poi_area_entered", Callable(self, "_on_poi_area_entered")):
		eb.connect("poi_area_entered", Callable(self, "_on_poi_area_entered"))

	if not eb.is_connected("landing_zone_area_entered", Callable(self, "_on_landing_zone_area_entered")):
		eb.connect("landing_zone_area_entered", Callable(self, "_on_landing_zone_area_entered"))

func set_active(active: bool) -> void:
	_active = active
	visible = active
	set_physics_process(active)

	if active:
		process_mode = Node.PROCESS_MODE_INHERIT
	else:
		process_mode = Node.PROCESS_MODE_DISABLED


func apply_vehicle_phase(phase: Dictionary) -> void:
	# phase["vehicle"] is expected (we enforced in schema)
	var veh: Dictionary = phase.get("vehicle", {})
	_vehicle_type = str(veh.get("type", "dune_buggy"))
	_trailer_segments = int(veh.get("trailer_segments", 0))

	# Profile can come from DataManager later; for now allow direct values
	var profile_id: String = str(veh.get("profile_id", ""))
	if profile_id != "":
		# TODO: pull real profile from your data table
		# _profile = DataManager.get_vehicle_profile(profile_id)
		_profile = {}
	else:
		_profile = veh

	_apply_profile(_vehicle_type, _trailer_segments, _profile)


func _apply_profile(vehicle_type: String, trailers: int, profile: Dictionary) -> void:
	if vehicle_type == "atv_hauler":
		seats = int(profile.get("seats", 2))
		cargo_slots = int(profile.get("cargo_slots", 6))
		tow_hooks = int(profile.get("tow_hooks", 2))

		_max_speed = float(profile.get("max_speed", 22.0))
		_accel = float(profile.get("accel", 120.0))
		_brake = float(profile.get("brake", 180.0))
		_turn_speed = float(profile.get("turn_speed", 2.2))
		_max_reverse_speed = float(profile.get("max_reverse_speed", 10.0))
	else:
		# dune_buggy
		seats = int(profile.get("seats", 4))
		cargo_slots = int(profile.get("cargo_slots", 1))
		tow_hooks = int(profile.get("tow_hooks", 0))

		_max_speed = float(profile.get("max_speed", 42.0))
		_accel = float(profile.get("accel", 190.0))
		_brake = float(profile.get("brake", 230.0))
		_turn_speed = float(profile.get("turn_speed", 3.6))
		_max_reverse_speed = float(profile.get("max_reverse_speed", 16.0))

	_update_trailers(trailers)

	if debug_logging:
		print("[VehicleBuggy] Applied profile type=", vehicle_type, " trailers=", trailers, " seats=", seats, " cargo=", cargo_slots)


func _update_trailers(trailers: int) -> void:
	if _trailers_root == null:
		return

	# Expect children named Segment0, Segment1 (optional pool)
	for i in range(_trailers_root.get_child_count()):
		var seg := _trailers_root.get_child(i)
		if seg is Node:
			seg.visible = i < trailers
			if i < trailers:
				seg.process_mode = Node.PROCESS_MODE_INHERIT
			else:
				seg.process_mode = Node.PROCESS_MODE_DISABLED


# Called by Player
func apply_controls(delta: float) -> void:
	if not _active:
		return

	var forward: float = Input.get_action_strength("buggy_forward")
	var back: float = Input.get_action_strength("buggy_back")
	var turn_r: float = Input.get_action_strength("buggy_turn_right")
	var turn_l: float = Input.get_action_strength("buggy_turn_left")

	var throttle: float = forward - back
	var turn: float = turn_r - turn_l

	var brake_pressed: bool = Input.is_action_pressed("buggy_brake")
	if brake_pressed:
		velocity = velocity.move_toward(Vector2.ZERO, _brake * 2.5 * delta)
		move_and_slide()
		return

	# Steering
	if turn != 0.0:
		rotation += turn * _turn_speed * delta

	# Accel / brake along forward vector (works for forward AND reverse)
	if throttle != 0.0:
		var target_speed: float = _max_speed
		if throttle < 0.0:
			target_speed = _max_reverse_speed

		var desired: Vector2 = Vector2.RIGHT.rotated(rotation) * throttle * target_speed
		velocity = velocity.move_toward(desired, _accel * delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, _brake * delta)

	# Simple gravity
	if not is_on_floor():
		velocity.y += gravity_strength * delta

	_update_trailer_follow(delta)
	move_and_slide()

func _update_trailer_follow(delta: float) -> void:
	if _trailers_root == null:
		return

	var prev_pos: Vector2 = global_position
	var prev_rot: float = rotation

	for i in range(_trailers_root.get_child_count()):
		var seg := _trailers_root.get_child(i)
		if seg == null or not seg.visible:
			continue
		if not (seg is Node2D):
			continue

		var seg2d: Node2D = seg

		var target_pos: Vector2 = prev_pos - Vector2.RIGHT.rotated(prev_rot) * _trailer_spacing
		seg2d.global_position = seg2d.global_position.lerp(target_pos, _trailer_follow_strength * delta)

		var dir: Vector2 = (prev_pos - seg2d.global_position)
		if dir.length() > 0.01:
			seg2d.rotation = dir.angle()

		prev_pos = seg2d.global_position
		prev_rot = seg2d.rotation

func _on_landing_zone_area_entered(zone_id: String) -> void:
	MC.on_zone_reached(zone_id)
	MC.mc_goal.on_zone_reached(zone_id)

func _on_poi_area_entered(poi_id: String) -> void:
	MC.on_poi_reached(poi_id)
	MC.mc_goal.on_poi_reached(poi_id)
