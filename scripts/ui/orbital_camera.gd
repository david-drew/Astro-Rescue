## res://scripts/modes/mode1/orbital_camera.gd
extends Camera2D
class_name OrbitalCamera

##
# OrbitalCamera - Handles camera transition from orbital view to landing view
#
# Features:
# - Smooth zoom from orbital distance to landing altitude
# - Coordinates with planet "flattening" effect
# - Configurable easing and duration
##

signal transition_started
signal transition_midpoint  # Emitted at 50% - useful for switching visuals
signal transition_completed

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

@export_category("Transition Settings")
@export var zoom_duration: float = 2.5  # Seconds
@export var zoom_easing: Tween.EaseType = Tween.EASE_IN_OUT
@export var zoom_trans: Tween.TransitionType = Tween.TRANS_CUBIC

@export_category("Zoom Levels")
@export var orbital_zoom: Vector2 = Vector2(1.0, 1.0)  # Zoomed out to see whole planet
@export var landing_zoom: Vector2 = Vector2(0.5, 0.5)  # Zoomed in for landing

@export_category("Planet Flattening")
@export var flatten_start_altitude: float = 8000.0  # Start flattening planet visual
@export var flatten_end_altitude: float = 2000.0    # Finish flattening

@export_category("Debug")
@export var debug_logging: bool = true

# -------------------------------------------------------------------
# Internal State
# -------------------------------------------------------------------

var _is_transitioning: bool = false
var _transition_progress: float = 0.0
var _midpoint_emitted: bool = false

var _start_position: Vector2 = Vector2.ZERO
var _target_position: Vector2 = Vector2.ZERO

var _tween: Tween = null

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	zoom = orbital_zoom
	enabled = false
	
	if debug_logging:
		print("[OrbitalCamera] Ready. Orbital zoom: ", orbital_zoom)

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func activate_orbital_camera() -> void:
	##
	# Enable this camera for orbital view
	##
	enabled = true
	make_current()
	zoom = orbital_zoom


	
	if debug_logging:
		print("[OrbitalCamera] Activated for orbital view")

func deactivate_orbital_camera() -> void:
	##
	# Disable this camera (switch to landing camera)
	##
	enabled = false
	
	if debug_logging:
		print("[OrbitalCamera] Deactivated")

func begin_zoom_transition(target_world_pos: Vector2) -> void:
	##
	# Begin animated zoom transition from orbital view to landing position
	# target_world_pos: The world position to zoom towards (landing zone center)
	##
	if _is_transitioning:
		push_warning("[OrbitalCamera] Transition already in progress!")
		return
	
	_is_transitioning = true
	_transition_progress = 0.0
	_midpoint_emitted = false
	
	_start_position = global_position
	_target_position = target_world_pos
	
	transition_started.emit()
	
	if debug_logging:
		print("[OrbitalCamera] Beginning zoom transition:")
		print("  From: ", _start_position)
		print("  To: ", _target_position)
		print("  Duration: ", zoom_duration, "s")
	
	_animate_transition()

func set_transition_config(duration: float, easing: Tween.EaseType = Tween.EASE_IN_OUT) -> void:
	##
	# Update transition configuration from mission JSON
	##
	zoom_duration = duration
	zoom_easing = easing
	
	if debug_logging:
		print("[OrbitalCamera] Transition config updated: duration=", duration)

# -------------------------------------------------------------------
# Animation
# -------------------------------------------------------------------

func _animate_transition() -> void:
	# Kill existing tween if any
	if _tween != null:
		_tween.kill()
	
	_tween = create_tween()
	_tween.set_parallel(false)
	_tween.set_ease(zoom_easing)
	_tween.set_trans(zoom_trans)
	
	# Animate position
	_tween.tween_property(self, "global_position", _target_position, zoom_duration)
	
	# Animate zoom (happens simultaneously with position)
	_tween.parallel().tween_property(self, "zoom", landing_zoom, zoom_duration)
	
	# Track progress for midpoint event
	_tween.tween_callback(_on_midpoint).set_delay(zoom_duration * 0.5)
	
	# Complete callback
	_tween.finished.connect(_on_transition_finished)
	
	if debug_logging:
		print("[OrbitalCamera] Tween animation started")

func _on_midpoint() -> void:
	if not _midpoint_emitted:
		_midpoint_emitted = true
		transition_midpoint.emit()
		
		if debug_logging:
			print("[OrbitalCamera] Transition midpoint reached")

func _on_transition_finished() -> void:
	_is_transitioning = false
	transition_completed.emit()
	
	if debug_logging:
		print("[OrbitalCamera] Transition completed")
	
	# Optionally deactivate this camera and switch to landing camera
	# This would be handled by MissionController

func get_transition_progress() -> float:
	##
	# Returns 0.0 to 1.0 indicating transition progress
	# Useful for coordinating planet flattening visual effect
	##
	if not _is_transitioning:
		return 1.0 if enabled else 0.0
	
	var dist_total := _start_position.distance_to(_target_position)
	if dist_total <= 0.0:
		return 1.0
	
	var dist_remaining := global_position.distance_to(_target_position)
	return 1.0 - (dist_remaining / dist_total)

func get_altitude_estimate() -> float:
	##
	# Estimate current altitude during transition
	# Used for coordinating planet flattening effect
	##
	if not _is_transitioning:
		return 10000.0  # Arbitrary high value when not transitioning
	
	var progress := get_transition_progress()
	# Interpolate from high altitude to landing altitude
	var start_altitude := 10000.0
	var end_altitude := 1000.0
	return lerp(start_altitude, end_altitude, progress)

func is_transitioning() -> bool:
	return _is_transitioning

# -------------------------------------------------------------------
# Planet Flattening Coordination
# -------------------------------------------------------------------

func get_planet_flatten_ratio() -> float:
	##
	# Returns 0.0 (fully round) to 1.0 (fully flat)
	# Based on current altitude during transition
	##
	var altitude := get_altitude_estimate()
	
	if altitude >= flatten_start_altitude:
		return 0.0  # Still round
	elif altitude <= flatten_end_altitude:
		return 1.0  # Fully flat
	else:
		# Interpolate between start and end
		var range_size := flatten_start_altitude - flatten_end_altitude
		var dist_from_start := flatten_start_altitude - altitude
		return dist_from_start / range_size
