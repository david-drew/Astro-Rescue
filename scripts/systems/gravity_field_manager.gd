## res://scripts/systems/gravity_field_manager.gd
extends Node2D
class_name GravityFieldManager

##
# GravityFieldManager - FIXED VERSION
#
# Provides altitude-based gravity scaling for realistic descent physics.
# Gravity is very light at orbital altitudes and gradually increases
# as the lander descends toward the surface.
#
# Features:
# - Smooth gravity interpolation based on altitude
# - Configurable orbital height and surface gravity
# - Support for different planetary bodies
# - Debug visualization options
##

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

@export_category("Gravity Settings")
@export var base_surface_gravity: float = 30.0  # Gravity at surface (pixels/sec²) - FIXED: was 20.0
@export var orbital_height: float = 10000.0      # Height where gravity becomes minimal (pixels)
@export var min_gravity_ratio: float = 0.05     # Minimum gravity at orbital height (5% of surface)
@export var gravity_curve_power: float = 2.0    # How quickly gravity increases (1.0=linear, 2.0=quadratic)

@export_category("Reference Points")
@export var surface_y_position: float = 0.0     # Y coordinate of the surface (can be updated dynamically)
@export var auto_update_surface: bool = true    # Automatically find surface from terrain

@export_category("Debug")
@export var debug_logging: bool = false
@export var debug_draw_gradient: bool = false   # Visual debug of gravity zones

# -------------------------------------------------------------------
# Internal state
# -------------------------------------------------------------------

var _global_gravity_base: Vector2 = Vector2.ZERO  # Base gravity vector from environment
var _cached_terrain_surface_y: float = 0.0
var _surface_found: bool = false

# -------------------------------------------------------------------
# Gravity Model Constants (production safe)
# -------------------------------------------------------------------
const GRAVITY_SOFTENING: float = 3000.0   # tune later
const GRAVITY_STRENGTH_MULT: float = 1.0  # multiplier for surface gravity

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	# Initialize with default downward gravity
	#_global_gravity_base = Vector2.DOWN * base_surface_gravity
	_global_gravity_base = Vector2.DOWN * 300.0
	
	# Listen for environment gravity changes
	if EventBus.has_signal("gravity_changed"):
		if not EventBus.is_connected("gravity_changed", Callable(self, "_on_environment_gravity_changed")):
			EventBus.connect("gravity_changed", Callable(self, "_on_environment_gravity_changed"))

	if EventBus.has_signal("terrain_generated"):
		EventBus.terrain_generated.connect(_on_terrain_generated)

	# FIXED: Removed the early return that was preventing initialization
	# Try to find terrain surface if auto-update is enabled
	if auto_update_surface:
		call_deferred("_find_terrain_surface")
	
	if debug_logging:
		print("[GravityFieldManager] Ready. Surface gravity: ", base_surface_gravity,
			" Orbital height: ", orbital_height,
			" Min gravity ratio: ", min_gravity_ratio)
	
	_global_gravity_base = Vector2.DOWN * base_surface_gravity
	print("[GFM] _ready() set _global_gravity_base to: ", _global_gravity_base)
	print("[GFM] base_surface_gravity is: ", base_surface_gravity)

func _process(_delta: float) -> void:
	if debug_draw_gradient:
		queue_redraw()

func _draw() -> void:
	if not debug_draw_gradient:
		return
	
	# Draw visual representation of gravity zones
	var screen_height = get_viewport_rect().size.y
	var step_count = 10
	
	for i in range(step_count):
		var altitude = (float(i) / step_count) * orbital_height
		var test_pos = Vector2(0, surface_y_position - altitude)
		var gravity = get_gravity_at_position(test_pos)
		var strength_ratio = gravity.length() / base_surface_gravity
		
		# Draw colored lines representing gravity strength
		var color = Color(1.0 - strength_ratio, strength_ratio, 0.0, 0.3)
		var y_screen = test_pos.y
		draw_line(Vector2(-1000, y_screen), Vector2(1000, y_screen), color, 2.0)

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func set_global_gravity(gravity: Vector2) -> void:
	"""Set the base gravity vector (from environment/planet config)"""
	_global_gravity_base = gravity
	if debug_logging:
		print("[GravityFieldManager] Base gravity set to: ", gravity)
		
	"""Set the base gravity vector (from environment/planet config)"""
	print("[GFM] set_global_gravity() called! Old: ", _global_gravity_base, " New: ", gravity)
	print("    Call stack:")
	print_stack()  # This will show WHO is calling it
	_global_gravity_base = gravity
	if debug_logging:
		print("[GravityFieldManager] Base gravity set to: ", gravity)

func get_gravity_at_position(global_position: Vector2) -> Vector2:
	# Compute altitude above surface
	var altitude := surface_y_position - global_position.y
	if altitude < 0.0:
		altitude = 0.0

	# Combine exported surface gravity with constant tuning multiplier
	var surface_g := base_surface_gravity * GRAVITY_STRENGTH_MULT

	# Softened inverse-square gravity model
	var effective_dist := altitude + GRAVITY_SOFTENING
	var strength := surface_g * (GRAVITY_SOFTENING * GRAVITY_SOFTENING) / (effective_dist * effective_dist)

	# Downward gravity vector
	var scaled_gravity := Vector2.DOWN * strength

	# Optional debug logging
	if debug_logging and Engine.get_physics_frames() % 60 == 0:
		print("[GFM] pos=", global_position,
			" alt=", altitude,
			" strength=", strength,
			" grav=", scaled_gravity)

	return scaled_gravity



func set_surface_position(y_position: float) -> void:
	"""Manually set the surface Y coordinate"""
	surface_y_position = y_position
	_surface_found = true
	if debug_logging:
		print("[GravityFieldManager] Surface position set to: ", y_position)

func update_from_terrain(terrain_node: Node) -> bool:
	"""
	Update surface position from a terrain node.
	Returns true if successful.
	"""
	if terrain_node == null:
		return false
	
	# Try different methods to get terrain bounds
	if terrain_node.has_method("get_highest_point_y"):
		surface_y_position = terrain_node.call("get_highest_point_y")
		_surface_found = true
		if debug_logging:
			print("[GravityFieldManager] Got surface from get_highest_point_y: ", surface_y_position)
		return true
	elif terrain_node.has_method("get_surface_y"):
		surface_y_position = terrain_node.call("get_surface_y")
		_surface_found = true
		if debug_logging:
			print("[GravityFieldManager] Got surface from get_surface_y: ", surface_y_position)
		return true
	elif terrain_node is TileMapLayer or terrain_node is TileMap:
		# For tilemaps, find the topmost used cell
		var used_cells = terrain_node.get_used_cells()
		if used_cells.size() > 0:
			var min_y = used_cells[0].y
			for cell in used_cells:
				if cell.y < min_y:
					min_y = cell.y
			# Convert tile coordinates to world position
			surface_y_position = terrain_node.map_to_local(Vector2i(0, min_y)).y
			_surface_found = true
			if debug_logging:
				print("[GravityFieldManager] Got surface from TileMap: ", surface_y_position)
			return true
	
	return false

# -------------------------------------------------------------------
# Internal Methods
# -------------------------------------------------------------------

func _calculate_gravity_ratio(altitude: float) -> float:
	"""
	Calculate gravity strength ratio based on altitude.
	
	At surface (altitude = 0): returns 1.0 (100% gravity)
	At orbital height: returns min_gravity_ratio (e.g., 5% gravity)
	In between: smooth interpolation based on gravity_curve_power
	"""
	if altitude <= 0.0:
		return 1.0
	
	if altitude >= orbital_height:
		return min_gravity_ratio
	
	# Normalize altitude to 0-1 range
	var t: float = altitude / orbital_height
	
	# Apply curve power for non-linear scaling
	# Higher power = gravity increases more sharply near surface
	var curve_t: float = pow(t, gravity_curve_power)
	
	# Interpolate between full gravity (1.0) and minimum gravity
	var ratio: float = lerp(1.0, min_gravity_ratio, curve_t)
	
	return ratio

func _on_terrain_generated(tg: TerrainGenerator) -> void:
	update_from_terrain(tg)
	if debug_logging:
		print("[GravityFieldManager] Updated from terrain generator, surface at: ", surface_y_position)

func _on_environment_gravity_changed(gravity_vector: Vector2) -> void:
	print("\t\t....................ENV CHANGED GRAVITY: ", gravity_vector)
	"""Handle gravity updates from EnvironmentController"""
	set_global_gravity(gravity_vector)

func _find_terrain_surface() -> void:
	"""Attempt to automatically find terrain surface Y position"""
	if _surface_found:
		return
	
	# Look for common terrain node names/groups
	var terrain_candidates = [
		"Terrain",
		"TerrainGenerator", 
		"Ground",
		"LandscapeGenerator",
		"ProceduralTerrain"
	]
	
	for candidate_name in terrain_candidates:
		var terrain = get_node_or_null("/root/" + candidate_name)
		if terrain == null:
			terrain = get_tree().get_first_node_in_group(candidate_name.to_lower())
		
		if terrain != null:
			if update_from_terrain(terrain):
				if debug_logging:
					print("[GravityFieldManager] Found terrain surface at: ", surface_y_position)
				return
	
	# If we still haven't found terrain, try to find any StaticBody2D or TileMap in the scene
	var root = get_tree().root
	var terrain = _find_terrain_recursive(root)
	if terrain != null:
		update_from_terrain(terrain)
	
	if not _surface_found:
		# Set a reasonable default if no terrain found
		surface_y_position = 600.0  # Assuming terrain is typically near bottom of screen
		if debug_logging:
			push_warning("[GravityFieldManager] Could not find terrain surface automatically. " +
				"Using default surface_y_position: " + str(surface_y_position) + 
				". Set surface_y_position manually or call update_from_terrain().")

func _find_terrain_recursive(node: Node) -> Node:
	"""Recursively search for terrain-like nodes"""
	if node is TileMap or node is TileMapLayer:
		return node
	
	if node.is_in_group("terrain") or node.is_in_group("ground"):
		return node
	
	for child in node.get_children():
		var result = _find_terrain_recursive(child)
		if result != null:
			return result
	
	return null

# -------------------------------------------------------------------
# Utility / Debug
# -------------------------------------------------------------------

func get_debug_info() -> Dictionary:
	"""Return debug information about current gravity state"""
	return {
		"base_gravity": _global_gravity_base,
		"surface_y": surface_y_position,
		"orbital_height": orbital_height,
		"min_gravity_ratio": min_gravity_ratio,
		"surface_found": _surface_found
	}

func get_altitude_from_position(global_position: Vector2) -> float:
	"""Helper to get altitude of a position"""
	return max(0.0, surface_y_position - global_position.y)

func get_gravity_ratio_at_position(global_position: Vector2) -> float:
	"""Get the gravity strength ratio (0.0 to 1.0) at a position"""
	var altitude = get_altitude_from_position(global_position)
	return _calculate_gravity_ratio(altitude)
