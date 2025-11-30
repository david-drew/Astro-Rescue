extends CharacterBody2D
class_name VehicleBuggy

signal arrived_at_poi(poi_id: String)
signal arrived_at_zone(zone_id: String)

@export var debug: bool = true

# Default agile buggy values
var _profile: Dictionary = {}
var _active: bool = false

var _vehicle_type: String = "dune_buggy"
var _trailer_segments: int = 0

# Movement tuning
var _max_speed: float = 400.0
var _accel: float = 800.0
var _brake: float = 500.0
var _brake_hold_time: float = 1.5
var _accel_hold_time: float = 1.0
var accel_ramp_duration: float = 1.5
var brake_ramp_duration: float = 1.0
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

# Jump tuning (speed-influenced)
@export var jump_base_strength: float = 50.0         # Base upward impulse
@export var jump_speed_bonus: float = 80.0           # Extra based on horizontal speed
@export var max_jump_speed_scale: float = 1.2         # How much of _max_speed affects jump
@export var jump_cooldown: float = 0.15               # Small cooldown to avoid input spam
@export var coast_deceleration: float = 80.0


var _jump_timer: float = 0.0

# Optional cached nodes
@onready var _trailers_root: Node2D = get_node_or_null("TrailerMounts") as Node2D


func _ready() -> void:
	# Enable CharacterBody2D built-in floor snapping.
	floor_snap_length = ground_snap_distance
	floor_max_angle = deg_to_rad(ground_max_angle_deg)
	add_to_group("buggy")
	
	if debug:
		print("[VehicleBuggy] ready: max_speed=", _max_speed,
			" accel=", _accel, " brake=", _brake)


func _physics_process(delta: float) -> void:
	# Movement is driven by Player.apply_controls(); we just tick jump cooldown here.
	if _jump_timer > 0.0:
		_jump_timer -= delta
		if _jump_timer < 0.0:
			_jump_timer = 0.0


func set_active(active: bool) -> void:
	_active = active
	visible = active
	set_physics_process(active)

	if active:
		process_mode = Node.PROCESS_MODE_INHERIT
	else:
		process_mode = Node.PROCESS_MODE_DISABLED


func apply_vehicle_phase(phase: Dictionary) -> void:
	# phase["vehicle"] is expected (schema-driven)
	var veh: Dictionary = phase.get("vehicle", {})
	_vehicle_type = str(veh.get("type", "dune_buggy"))
	_trailer_segments = int(veh.get("trailer_segments", 0))

	var profile_id: String = str(veh.get("profile_id", ""))
	if profile_id != "":
		# TODO: pull from DataManager later
		_profile = {}
	else:
		_profile = veh

	_apply_profile(_vehicle_type, _trailer_segments, _profile)
func _apply_profile(vehicle_type: String, trailers: int, profile: Dictionary) -> void:
	# If no profile data is provided, keep existing tuning values.
	if profile.is_empty():
		_update_trailers(trailers)
		return

	if vehicle_type == "atv_hauler":
		if profile.has("seats"):
			seats = int(profile.get("seats"))
		if profile.has("cargo_slots"):
			cargo_slots = int(profile.get("cargo_slots"))
		if profile.has("tow_hooks"):
			tow_hooks = int(profile.get("tow_hooks"))

		if profile.has("max_speed"):
			_max_speed = float(profile.get("max_speed"))
		if profile.has("accel"):
			_accel = float(profile.get("accel"))
		if profile.has("brake"):
			_brake = float(profile.get("brake"))
		if profile.has("turn_speed"):
			_turn_speed = float(profile.get("turn_speed"))
		if profile.has("max_reverse_speed"):
			_max_reverse_speed = float(profile.get("max_reverse_speed"))
	else:
		# dune_buggy (default)
		if profile.has("seats"):
			seats = int(profile.get("seats"))
		if profile.has("cargo_slots"):
			cargo_slots = int(profile.get("cargo_slots"))
		if profile.has("tow_hooks"):
			tow_hooks = int(profile.get("tow_hooks"))

		if profile.has("max_speed"):
			_max_speed = float(profile.get("max_speed"))
		if profile.has("accel"):
			_accel = float(profile.get("accel"))
		if profile.has("brake"):
			_brake = float(profile.get("brake"))
		if profile.has("turn_speed"):
			_turn_speed = float(profile.get("turn_speed"))
		if profile.has("max_reverse_speed"):
			_max_reverse_speed = float(profile.get("max_reverse_speed"))

	_update_trailers(trailers)

	if debug:
		print("[VehicleBuggy] Applied profile type=", vehicle_type,
			" trailers=", trailers,
			" _max_speed=", _max_speed,
			" _accel=", _accel,
			" _brake=", _brake)


func _update_trailers(trailers: int) -> void:
	if _trailers_root == null:
		return

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

	# Cooldown timer for jump
	if _jump_timer > 0.0:
		_jump_timer -= delta
		if _jump_timer < 0.0:
			_jump_timer = 0.0

	# Side-scroller: horizontal only (right/left)
	var move_right: float = Input.get_action_strength("buggy_right")
	var move_left: float = Input.get_action_strength("buggy_left")
	var axis: float = move_right - move_left

	var jump_pressed: bool = Input.is_action_just_pressed("buggy_jump")
	var brake_pressed: bool = Input.is_action_pressed("buggy_brake")

	# --- Ramp timers ---
	if brake_pressed:
		_brake_hold_time += delta
		if brake_ramp_duration > 0.0 and _brake_hold_time > brake_ramp_duration:
			_brake_hold_time = brake_ramp_duration
		_accel_hold_time = 0.0
	else:
		_brake_hold_time = 0.0

	if axis != 0.0 and not brake_pressed:
		_accel_hold_time += delta
		if accel_ramp_duration > 0.0 and _accel_hold_time > accel_ramp_duration:
			_accel_hold_time = accel_ramp_duration
	else:
		if not brake_pressed:
			_accel_hold_time = 0.0

	var accel_factor: float = 1.0
	if accel_ramp_duration > 0.0:
		accel_factor = clamp(_accel_hold_time / accel_ramp_duration, 0.25, 1.0)

	var brake_factor: float = 1.0
	if brake_ramp_duration > 0.0:
		brake_factor = clamp(_brake_hold_time / brake_ramp_duration, 0.25, 1.0)

	# --- Braking (strong, but ramped) ---
	if brake_pressed:
		velocity.x = move_toward(
			velocity.x,
			0.0,
			_brake * brake_factor * 2.5 * delta
		)
	else:
		# --- Throttle / coasting ---
		if axis != 0.0:
			var target_speed: float = _max_speed * axis
			velocity.x = move_toward(
				velocity.x,
				target_speed,
				_accel * accel_factor * delta
			)
		else:
			# No input: coast down slowly instead of hard braking
			var sign:float = signf(velocity.x)
			var abs_v:Variant = abs(velocity.x)
			abs_v = max(abs_v - coast_deceleration * delta, 0.0)
			velocity.x = abs_v * sign

	# --- Jump (speed-influenced, mostly in travel direction) ---
	if jump_pressed:
		_try_jump(axis)

	# Gravity when airborne
	if not is_on_floor():
		velocity.y += gravity_strength * delta

	_update_trailer_follow(delta)
	move_and_slide()

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y += gravity_strength * delta

func _try_jump(direction_axis: float) -> void:
	# Cooldown so you can't spam
	if _jump_timer > 0.0:
		return

	if not is_on_floor():
		return

	# Use current horizontal speed for jump bias
	var horizontal_speed: float = velocity.x

	# If nearly stopped but player is holding a direction, give a small
	# horizontal boost so jumps aren't perfectly vertical from standstill.
	var min_run_speed_for_jump: float = _max_speed * 0.35
	if abs(horizontal_speed) < min_run_speed_for_jump and direction_axis != 0.0:
		horizontal_speed = direction_axis * min_run_speed_for_jump
		velocity.x = horizontal_speed

	# Scale jump based on horizontal speed
	var speed_scale: float = 0.0
	if _max_speed > 0.0:
		speed_scale = clamp(abs(horizontal_speed) / _max_speed, 0.0, max_jump_speed_scale)

	# Mostly "forward" in motion sense: we keep horizontal velocity
	# and add upward impulse scaled by speed.
	var jump_vy: float = -jump_base_strength - jump_speed_bonus * speed_scale
	velocity.y = jump_vy

	_jump_timer = jump_cooldown

	if debug:
		print("[VehicleBuggy] Jump: vx=%.2f scale=%.2f vy=%.2f"
			% [horizontal_speed, speed_scale, jump_vy])


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
