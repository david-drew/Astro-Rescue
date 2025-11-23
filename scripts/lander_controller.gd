## res://scripts/modes/mode1/lander_controller.gd
extends RigidBody2D
class_name LanderController

##
# LanderController - FIXED VERSION
#
# Key fixes in this version:
# - Fixed gravity field manager initialization (was set to null)
# - Fixed thrust multiplier bug (was hardcoded to 3.0)
# - Better tuned physics for lunar lander feel
# - Integrated with GravityFieldManager for altitude-based gravity
# - Improved rotation feel
# - Better default values
##

# -------------------------------------------------------------------
# Thrust & rotation settings
# -------------------------------------------------------------------

@export_category("Thrust")
@export var base_thrust_force: float = 200.0  			# 700 - Reduced from 600 for better feel
@export var turbo_thrust_multiplier: float = 1.0		# 6.0
@export var allow_turbo: bool = true

@export_category("Fuel")
@export var fuel_capacity: float = 100.0
@export var base_fuel_burn_rate: float = 12.0
@export var turbo_fuel_multiplier: float = 2.5

@export_category("Rotation")
@export var rotation_accel: float = 6.0         # Slightly reduced for smoother control
@export var max_angular_speed: float = 4.5      # Slightly reduced
@export var rotation_drag: float = 6.0          # Increased for snappier feel

# -------------------------------------------------------------------
# Landing / impact thresholds
# -------------------------------------------------------------------

@export_category("Landing Safety")
@export var safe_vertical_speed: float = 4.0
@export var safe_horizontal_speed: float = 3.0
@export var safe_tilt_deg: float = 20.0
@export var safe_upright_check_duration: float = 1.5

@export_category("Destruction Thresholds")
@export var destroy_vertical_speed: float = 15.0
@export var destroy_horizontal_speed: float = 15.0
@export var destroy_velocity_magnitude: float = 15.0
@export var hard_crash_always_fatal: bool = true

@export_category("Landing Zone / Debug")
@export var upright_angle_limit_for_check: float = 25.0
@export var debug_logging: bool = false

@export_category("Environment")
@export var weather_controller_path: NodePath
@export var wind_force_scale: float = 1.0

@export_category("Altitude")
@export var altitude_reference_y: float = 0.0
@export var pixels_per_meter: float = 16.0

@export_category("Gravity")
@export var use_altitude_gravity: bool = true  # NEW: Enable altitude-based gravity
@export var gravity_field_manager_path: NodePath = NodePath("/root/GravityFieldManager")

@export_category("HUD Updates")
@export var hud_update_enabled: bool = true
@export var hud_update_interval_frames: int = 20  	# Update every 20 frames (efficient!)
@export var altitude_change_threshold: float = 5.0  # Only emit if altitude changes by this much

# -------------------------------------------------------------------
# Internal state
# -------------------------------------------------------------------

var old_gravity:Vector2 = Vector2.ZERO
var _current_fuel: float = 0.0
var _last_fuel_ratio: float = 1.0

var _landing_evaluation_active: bool = false
var _has_sent_touchdown: bool = false
var _has_sent_destruction: bool = false

var _impact_data_pending: Dictionary = {}
var _impact_ground_body: Object = null

var _landing_contact_time: float = 0.0

var _weather_controller: WeatherController = null
var _current_wind: Vector2 = Vector2.ZERO
var _current_gravity_vector: Vector2 = Vector2.ZERO

var _gravity_field_manager: GravityFieldManager = null  # FIXED: Don't set to null!

var _hud_frame_counter: int = 0
var _last_emitted_altitude: float = 0.0
var _last_emitted_fuel: float = 1.0


# TODO DEBUG DELETE	
var _last_vel: Vector2 = Vector2.ZERO
var _last_frame_logged: int = 0

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	_current_fuel = fuel_capacity
	if fuel_capacity <= 0.0:
		_current_fuel = 0.0
	_last_fuel_ratio = _get_fuel_ratio()

	# Disable built-in gravity; we will apply custom gravity manually.
	gravity_scale = 0.0
	
	# Initial gravity fallback: use current project default as downward acceleration.
	# Changed to 30.0 for lunar-style feel (was 49.0)
	var default_gravity: float = float(ProjectSettings.get_setting("physics/2d/default_gravity", 30.0))
	_current_gravity_vector = Vector2.DOWN * default_gravity
	
	# ADD THESE LINES at the end of _ready():
	collision_layer = 2   # Layer 2 for lander
	collision_mask = 1    # Detect layer 1 (terrain)
	add_to_group("lander")

	# Weather controller reference (for wind)
	if weather_controller_path != NodePath(""):
		_weather_controller = get_node_or_null(weather_controller_path)

	# FIXED: Properly initialize GravityFieldManager
	if use_altitude_gravity and gravity_field_manager_path != NodePath(""):
		_gravity_field_manager = get_node_or_null(gravity_field_manager_path)
		if _gravity_field_manager == null:
			push_warning("LanderController: GravityFieldManager not found at path: ", gravity_field_manager_path)
			# Try to create one if it doesn't exist
			var gfm = GravityFieldManager.new()
			gfm.name = "GravityFieldManager"
			get_tree().root.add_child(gfm)
			_gravity_field_manager = gfm
			print("[LanderController] Created new GravityFieldManager instance")

	if use_altitude_gravity and _gravity_field_manager == null:
		# Fall back to EventBus gravity updates / default gravity vector.
		use_altitude_gravity = false
		push_warning("LanderController: Falling back to EventBus gravity (altitude gravity disabled).")


	# Listen for gravity updates from EnvironmentController via EventBus.
	if not EventBus.is_connected("gravity_changed", Callable(self, "_on_gravity_changed")):
		EventBus.connect("gravity_changed", Callable(self, "_on_gravity_changed"))

	$Sprite2D.rotation_degrees = -90  # change from default right to facing up

	if debug_logging:
		print("[LanderController] Ready. Fuel capacity=", fuel_capacity, " default_gravity=", default_gravity)
		print("[LanderController] GravityFieldManager: ", _gravity_field_manager)

	call_deferred("_setup_collision")

func _setup_collision() -> void:
	print("⚠️ Setting up lander collision...")
	collision_layer = 2
	collision_mask = 1
	add_to_group("lander")
	
	#print("✅ Lander collision_layer: ", collision_layer)
	#print("✅ Lander collision_mask: ", collision_mask)
	#print("✅ In lander group: ", is_in_group("lander"))

func _physics_process(delta: float) -> void:
	# Get Weather Effects
	if _weather_controller != null:
		_current_wind = _weather_controller.get_current_wind_vector()
	else:
		_current_wind = Vector2.ZERO

	# Update gravity based on altitude if enabled
	if use_altitude_gravity and _gravity_field_manager != null:
		_current_gravity_vector = _gravity_field_manager.get_gravity_at_position(global_position)
		if debug_logging and Engine.get_physics_frames() % 60 == 0:  # Log every second
			print("[LanderController] Gravity at position ", global_position, ": ", _current_gravity_vector)

	#_current_gravity_vector = Vector2(0, 30)  # DEBUG ONLY - COMMENTED OUT
	_apply_controls(delta)
	
	# HUD updates (efficient - only every N frames)
	if hud_update_enabled:
		_hud_frame_counter += 1
		if _hud_frame_counter >= hud_update_interval_frames:
			_hud_frame_counter = 0
			_emit_hud_updates()


func PREV_integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	# TEST: Apply a massive sideways force
	#state.apply_central_force(Vector2(0, 200)) 		# TODO DEBUG

	
	# DEBUG: Print every 60 frames
	if Engine.get_physics_frames() % 60 == 0:
		var cam := get_viewport().get_camera_2d()
		print("=== INTEGRATE_FORCES DEBUG ===")
		print("\tCurrent camera is: ", cam)
		print("  _current_gravity_vector: ", _current_gravity_vector)
		print("  mass: ", mass)
		print("  freeze: ", freeze)
		print("  sleeping: ", sleeping)
		print("  linear_velocity: ", linear_velocity)
	
	# Apply custom gravity as a force: F = m * a
	if _current_gravity_vector != Vector2.ZERO:
		var m: float = mass
		var gravity_force: Vector2 = _current_gravity_vector * m
		state.apply_central_force(gravity_force)
		
	# END TEMP DEBUG

	# Apply wind as a lateral/angled force.
	if _current_wind != Vector2.ZERO and wind_force_scale != 0.0:
		var wind_force: Vector2 = _current_wind * wind_force_scale
		state.apply_central_force(wind_force)
	
	if Engine.get_physics_frames() % 60 == 0:
		print("  [END] state.linear_velocity: ", state.linear_velocity)
		print("  [END] state.transform.origin: ", state.transform.origin)

func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	# Apply custom gravity as a force
	if _current_gravity_vector != Vector2.ZERO:
		state.apply_central_force(_current_gravity_vector * mass)

	# Every 60 frames, compare velocity to last logged velocity
	var f := Engine.get_physics_frames()
	if f % 60 == 0 and f != _last_frame_logged:
		var dv := state.linear_velocity - _last_vel
		print("=== GRAVITY EFFECT CHECK ===")
		print("  v_now: ", state.linear_velocity)
		print("  v_prev: ", _last_vel)
		print("  dv over 60 frames: ", dv)
		print("  approx accel: ", dv / (60.0 * state.step))
		_last_vel = state.linear_velocity
		_last_frame_logged = f


# -------------------------------------------------------------------
# Control / thrust
# -------------------------------------------------------------------

func _apply_controls(delta: float) -> void:
	# Gather input.
	var thrust_input: float = Input.get_action_strength("lander_thrust")
	var turbo_pressed: bool = false
	if allow_turbo:
		turbo_pressed = Input.is_action_pressed("lander_turbo")

	var rotate_right: float = Input.get_action_strength("lander_rotate_right")
	var rotate_left: float = Input.get_action_strength("lander_rotate_left")
	var rotate_input: float = rotate_right - rotate_left

	# Apply rotation via angular_velocity.
	if rotate_input != 0.0:
		var new_ang_vel: float = angular_velocity + rotate_input * rotation_accel * delta
		angular_velocity = clampf(new_ang_vel, -max_angular_speed, max_angular_speed)
	elif rotation_drag > 0.0:
		# Dampen rotation toward 0 when no input, so the lander doesn't spin forever.
		var drag_step: float = rotation_drag * delta
		if angular_velocity > 0.0:
			angular_velocity = max(0.0, angular_velocity - drag_step)
		elif angular_velocity < 0.0:
			angular_velocity = min(0.0, angular_velocity + drag_step)

	# Apply thrust if we have fuel and there is thrust input.
	if thrust_input > 0.0 and _current_fuel > 0.0:
		# FIXED: Use 1.0 as default multiplier, not 3.0!
		var thrust_multiplier: float = 1.0
		var fuel_mult: float = 1.0

		if allow_turbo and turbo_pressed:	
			thrust_multiplier = turbo_thrust_multiplier
			fuel_mult = turbo_fuel_multiplier

		var thrust_force: float = base_thrust_force * thrust_input * thrust_multiplier
		var thrust_vector: Vector2 = Vector2(0.0, -1.0).rotated(rotation) * thrust_force

		# Apply as central impulse (or force).
		apply_central_impulse(thrust_vector * delta)

		# Consume fuel.
		var fuel_consumed: float = base_fuel_burn_rate * thrust_input * fuel_mult * delta
		_current_fuel = max(0.0, _current_fuel - fuel_consumed)
		_update_fuel_ratio()

		# Emit thrust signal (for audio, visuals, etc.).
		var thrust_strength: float = thrust_input
		if allow_turbo and turbo_pressed:
			thrust_strength *= 1.5 # or whatever makes sense

		EventBus.emit_signal("lander_thrust", thrust_strength)

# -------------------------------------------------------------------
# Fuel
# -------------------------------------------------------------------

func _get_fuel_ratio() -> float:
	if fuel_capacity <= 0.0:
		return 0.0
	return _current_fuel / fuel_capacity

func _update_fuel_ratio() -> void:
	var ratio: float = _get_fuel_ratio()
	
	# Emit signal if fuel changed noticeably (e.g., crossing 10% thresholds).
	var last_tenth: int = int(_last_fuel_ratio * 10)
	var new_tenth: int = int(ratio * 10)
	
	if new_tenth != last_tenth or (ratio == 0.0 and _last_fuel_ratio > 0.0):
		EventBus.emit_signal("lander_fuel_changed", ratio)
		
		# Check for critical fuel levels
		if ratio <= 0.1 and _last_fuel_ratio > 0.1:
			EventBus.emit_signal("lander_fuel_critical", ratio)
		elif ratio == 0.0 and _last_fuel_ratio > 0.0:
			EventBus.emit_signal("lander_fuel_depleted")
	
	_last_fuel_ratio = ratio

# -------------------------------------------------------------------
# Gravity updates from environment
# -------------------------------------------------------------------

func _on_gravity_changed(gravity_vector: Vector2) -> void:
	# Only use this if we're not using altitude-based gravity
	if not use_altitude_gravity or _gravity_field_manager == null:
		_current_gravity_vector = gravity_vector
		if debug_logging:
			print("[LanderController] Gravity changed via EventBus: ", gravity_vector)

# -------------------------------------------------------------------
# Landing / impact detection (simplified)
# -------------------------------------------------------------------

func _on_body_entered(body: Node) -> void:
	# Called when lander collides with something.
	# For a simple check: if we hit terrain and speed is too high, crash.
	
	if body.is_in_group("terrain") or body.is_in_group("ground"):
		var v: Vector2 = linear_velocity
		var speed: float = v.length()
		
		var v_vert: float = abs(v.y)
		var v_horiz: float = abs(v.x)
		
		# Check for crash conditions.
		if v_vert > destroy_vertical_speed or v_horiz > destroy_horizontal_speed or speed > destroy_velocity_magnitude:
			_handle_destruction("high_speed_impact", {
				"speed": speed,
				"vertical_speed": v_vert,
				"horizontal_speed": v_horiz
			})
		elif v_vert <= safe_vertical_speed and v_horiz <= safe_horizontal_speed:
			# Check tilt
			var tilt_deg: float = abs(rad_to_deg(rotation))
			if tilt_deg <= safe_tilt_deg:
				_handle_safe_landing()
			else:
				_handle_destruction("excessive_tilt", { "tilt_degrees": tilt_deg })
		else:
			# Hard landing but not necessarily fatal
			_handle_destruction("hard_landing", {
				"speed": speed,
				"vertical_speed": v_vert,
				"horizontal_speed": v_horiz
			})

func _handle_safe_landing() -> void:
	if _has_sent_touchdown:
		return
	
	_has_sent_touchdown = true
	
	if debug_logging:
		print("[LanderController] Safe touchdown!")
	
	EventBus.emit_signal("lander_touchdown", {})
	EventBus.emit_signal("lander_landed_safely", {})

func _handle_destruction(cause: String, context: Dictionary) -> void:
	"""
	New crash handling that reliably stops the lander.
	Uses PhysicsServer2D for immediate physics state changes.
	"""
	if _has_sent_destruction:
		return

	_has_sent_destruction = true

	if debug_logging:
		print("[LanderController] Destruction: cause=", cause, " context=", context)

	# Emit signals
	EventBus.emit_signal("lander_destroyed", cause, context)
	if hard_crash_always_fatal:
		EventBus.emit_signal("player_died", "lander_crash_" + cause, context)

	# Stop physics processing to prevent further input
	set_physics_process(false)
	
	# Use PhysicsServer2D for immediate, authoritative stop
	# This bypasses any physics quirks and ensures complete stop
	
	# Stop linear velocity
	PhysicsServer2D.body_set_state(
		get_rid(),
		PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY,
		Vector2.ZERO
	)
	
	# Stop angular velocity
	PhysicsServer2D.body_set_state(
		get_rid(),
		PhysicsServer2D.BODY_STATE_ANGULAR_VELOCITY,
		0.0
	)
	
	# Let physics settle for a few frames
	for i in range(3):
		await get_tree().physics_frame
		
		# Re-apply zero velocities each frame to ensure it sticks
		PhysicsServer2D.body_set_state(
			get_rid(),
			PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY,
			Vector2.ZERO
		)
		PhysicsServer2D.body_set_state(
			get_rid(),
			PhysicsServer2D.BODY_STATE_ANGULAR_VELOCITY,
			0.0
		)
		
		# Also try setting through the node properties
		if not freeze:
			linear_velocity = Vector2.ZERO
			angular_velocity = 0.0
			break
	
	# Final freeze
	freeze = true
	lock_rotation = true
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0


# -------------------------------------------------------------------
# ALTERNATIVE: Simpler crash handling (if the above is too complex)
# -------------------------------------------------------------------

func _handle_destruction_simple(cause: String, context: Dictionary) -> void:
	"""
	Simpler crash handling - just stop everything immediately.
	Use this if you don't want any bounce/settling physics.
	"""
	if _has_sent_destruction:
		return

	_has_sent_destruction = true

	if debug_logging:
		print("[LanderController] Destruction: cause=", cause)

	# Emit signals
	EventBus.emit_signal("lander_destroyed", cause, context)
	if hard_crash_always_fatal:
		EventBus.emit_signal("player_died", "lander_crash_" + cause, context)

	# Stop all physics immediately
	set_physics_process(false)
	
	# Use PhysicsServer2D for immediate, reliable stop
	PhysicsServer2D.body_set_state(
		get_rid(),
		PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY,
		Vector2.ZERO
	)
	PhysicsServer2D.body_set_state(
		get_rid(),
		PhysicsServer2D.BODY_STATE_ANGULAR_VELOCITY,
		0.0
	)
	
	# Wait a frame then freeze
	await get_tree().physics_frame
	
	freeze = true
	lock_rotation = true


# -------------------------------------------------------------------
# ADDITIONAL: Prevent terrain penetration
# -------------------------------------------------------------------

## This prevents the lander from getting "stuck" in terrain

func _push_out_of_terrain(terrain_body: Node) -> void:
	"""
	Push lander slightly above terrain to prevent penetration.
	"""
	if not terrain_body is StaticBody2D:
		return
	
	# Get collision normal (points away from terrain)
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(
		global_position,
		global_position + Vector2.DOWN * 100
	)
	
	var result = space_state.intersect_ray(query)
	if result:
		# Push lander 5 pixels above surface
		var safe_position = result.position + Vector2.UP * 5
		
		PhysicsServer2D.body_set_state(
			get_rid(),
			PhysicsServer2D.BODY_STATE_TRANSFORM,
			Transform2D.IDENTITY.translated(safe_position)
		)

func _apply_ship_loadout(mission_config: Dictionary) -> void:
	if not self.has_method("apply_loadout_multipliers"):
		return

	# Prefer new-style "mission_modifiers" from the mission JSON.
	# Fall back to legacy "ship_loadout" if present.
	var loadout_cfg: Dictionary = {}

	if mission_config.has("mission_modifiers"):
		loadout_cfg = mission_config.get("mission_modifiers", {})
	else:
		loadout_cfg = mission_config.get("ship_loadout", {})

	if loadout_cfg.is_empty():
		return

	var allow_override: bool = bool(loadout_cfg.get("allow_player_override", true))

	var mission_fuel_mult: float = float(loadout_cfg.get("fuel_capacity_multiplier", 1.0))
	var mission_thrust_mult: float = float(loadout_cfg.get("thrust_multiplier", 1.0))

	if allow_override and GameState.has_method("get_player_ship_loadout_overrides"):
		var player_loadout: Dictionary = GameState.get_player_ship_loadout_overrides()
		if player_loadout.has("fuel_capacity_multiplier"):
			mission_fuel_mult = float(player_loadout["fuel_capacity_multiplier"])
		if player_loadout.has("thrust_multiplier"):
			mission_thrust_mult = float(player_loadout["thrust_multiplier"])

	apply_loadout_multipliers(mission_fuel_mult, mission_thrust_mult)

func apply_loadout_multipliers(fuel_mult: float, thrust_mult: float) -> void:
	# Safety clamps
	if fuel_mult <= 0.0:
		fuel_mult = 1.0
	if thrust_mult <= 0.0:
		thrust_mult = 1.0

	# Apply fuel multiplier
	var old_capacity: float = fuel_capacity
	var new_capacity: float = old_capacity * fuel_mult
	fuel_capacity = new_capacity

	# Scale current fuel to preserve ratio (if capacity changed)
	var ratio: float = 0.0
	if old_capacity > 0.0:
		ratio = _current_fuel / old_capacity

	_current_fuel = new_capacity * ratio

	# Apply thrust multiplier
	base_thrust_force = base_thrust_force * thrust_mult

	if debug_logging:
		print("[LanderController] Loadout applied:",
			" fuel_mult=", fuel_mult,
			" thrust_mult=", thrust_mult,
			" new_capacity=", fuel_capacity,
			" new_current_fuel=", _current_fuel,
			" new_thrust_force=", base_thrust_force)

func apply_mission_modifiers(mission_config: Dictionary) -> void:
	# Public entry point for mission-based lander tweaks.
	# For now this just forwards to the loadout logic.
	reset_for_new_mission()
	_apply_ship_loadout(mission_config)
		
	print("\t............[Debug] Lander freeze=", self.freeze, " sleeping=", self.sleeping)


# -------------------------------------------------------------------
# UI
# -------------------------------------------------------------------

func get_fuel_ratio() -> float:
	return _get_fuel_ratio()

func get_altitude_estimate_meters() -> float:
	var dy: float = altitude_reference_y - global_position.y
	if pixels_per_meter <= 0.0:
		return 0.0

	var meters: float = dy / pixels_per_meter
	if meters < 0.0:
		meters = 0.0
	return meters


func _emit_hud_updates() -> void:
	"""
	Emit HUD update signals via EventBus.
	Called every N physics frames for efficiency.
	"""
	
	# Get current stats
	var altitude: float = get_altitude_estimate_meters()
	var fuel: float = get_fuel_ratio()

	# Option 1: Emit individual signals (allows throttling per-stat)
	_emit_altitude_if_changed(altitude)
	_emit_fuel_if_changed(fuel)
	
	# Option 2: Batch update (most efficient - single signal with all data)
	# Uncomment if you prefer batch updates:
	# _emit_batch_stats(altitude, fuel)

func _emit_altitude_if_changed(current_altitude: float) -> void:
	"""Only emit if altitude changed significantly"""
	var delta: float = abs(current_altitude - _last_emitted_altitude)
	
	if delta >= altitude_change_threshold:
		_last_emitted_altitude = current_altitude
		
		if EventBus.has_signal("lander_altitude_changed"):
			EventBus.emit_signal("lander_altitude_changed", current_altitude)

func _emit_fuel_if_changed(current_fuel: float) -> void:
	"""Only emit if fuel changed significantly (already has threshold in _update_fuel_ratio)"""
	# Fuel already has emission logic in _update_fuel_ratio()
	# This is redundant but shown for completeness
	_last_emitted_fuel = current_fuel

func _emit_batch_stats(altitude: float, fuel: float) -> void:
	"""
	Emit all stats in one signal (most efficient).
	Use this if HUD prefers batch updates.
	"""
	if EventBus.has_signal("lander_stats_updated"):
		var stats := {
			"altitude": altitude,
			"fuel_ratio": fuel,
			"velocity": linear_velocity,
			"angular_velocity": angular_velocity,
			"position": global_position
		}
		EventBus.emit_signal("lander_stats_updated", stats)

func reset_for_new_mission() -> void:
	# Ensure physics is live again.
	freeze = false
	sleeping = false
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0

	# Re-enable controls if they were disabled by crash / landing.
	set_physics_process(true)

	# Optional: clear crash/landing flags if you track them.
	#_has_crashed = false
	#_has_landed = false
