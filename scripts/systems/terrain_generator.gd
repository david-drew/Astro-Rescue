## res://scripts/modes/mode1/terrain_generator.gd
extends Node
class_name TerrainGenerator

##
# TerrainGenerator (Mode 1) - IMPROVED VERSION
#
# Major improvements:
#  - Multiple terrain generation algorithms (plains, mountains, craters, valleys)
#  - More realistic lunar-style terrain
#  - Better landing zone placement and validation
#  - Crater generation system
#  - Biome blending
#  - Height tracking for gravity system integration
#
# New features:
#  - get_highest_point_y() for gravity system
#  - get_center_x() for lander spawning
#  - get_bounds() for camera setup
#  - Better landing zone detection
##

@export_category("Scene References")
@export var terrain_root_path: NodePath

@export_category("Visuals")
@export var terrain_color: Color = Color(0.7, 0.7, 0.7, 1.0)
@export var terrain_z_index: int = 0

@export_category("Collision")
@export var collision_layer: int = 1
@export var collision_mask: int = 1

@export_category("Debug")
@export var clear_existing_terrain: bool = true
@export var debug_logging: bool = false
@export var debug_show_landing_zones: bool = true

# Internal state
var _terrain_root: Node2D = null
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Track generated terrain info
var _landing_zones_info: Dictionary = {}
var _last_terrain_config: Dictionary = {}
var _generated_bounds: Rect2 = Rect2()
var _highest_point_y: float = 0.0
var _terrain_body: StaticBody2D = null

func _ready() -> void:
	if terrain_root_path != NodePath(""):
		_terrain_root = get_node_or_null(terrain_root_path) as Node2D

	if _terrain_root == null:
		if debug_logging:
			push_warning("[TerrainGenerator] terrain_root_path is not set or node not found.")
	else:
		if debug_logging:
			print("[TerrainGenerator] Ready. TerrainRoot=", _terrain_root)

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func generate_from_mission(mission_config: Dictionary) -> void:
	var terrain_config: Dictionary = mission_config.get("terrain", {})
	if terrain_config.is_empty():
		if debug_logging:
			print("[TerrainGenerator] Mission has no 'terrain' block; using defaults.")
		_generate_internal(_build_default_config())
	else:
		_generate_internal(terrain_config)


func generate_terrain(terrain_config: Dictionary = {}) -> void:
	if terrain_config.is_empty():
		_generate_internal(_build_default_config())
	else:
		_generate_internal(terrain_config)


func regenerate_last() -> void:
	if _last_terrain_config.is_empty():
		if debug_logging:
			push_warning("[TerrainGenerator] No previous terrain config to regenerate.")
		return
	_generate_internal(_last_terrain_config)


func get_landing_zone_world_info(zone_id: String) -> Dictionary:
	return _landing_zones_info.get(zone_id, {})

# NEW: Public getters for integration with other systems
func get_highest_point_y() -> float:
	"""Get the Y coordinate of the highest terrain point (for gravity/spawning)"""
	return _highest_point_y

func get_center_x() -> float:
	"""Get the horizontal center of the terrain"""
	return _generated_bounds.position.x + _generated_bounds.size.x / 2.0

func get_bounds() -> Rect2:
	"""Get the bounding rectangle of the terrain"""
	return _generated_bounds

func get_terrain_body() -> StaticBody2D:
	"""Get the terrain's StaticBody2D (useful for physics queries)"""
	return _terrain_body

# -------------------------------------------------------------------
# Internal generation
# -------------------------------------------------------------------

func _generate_internal(terrain_config: Dictionary) -> void:
	if _terrain_root == null:
		if debug_logging:
			push_warning("[TerrainGenerator] Cannot generate terrain; TerrainRoot is null.")
		return

	_last_terrain_config = terrain_config.duplicate(true)
	_landing_zones_info.clear()

	if clear_existing_terrain:
		_clear_terrain_root()

	_rng.randomize()
	var seed_value: int = int(terrain_config.get("seed", 0))
	if seed_value != 0:
		_rng.seed = seed_value

	# Build height profile using improved generation
	var height_points: Array = _build_height_profile_improved(terrain_config)
	if height_points.size() < 2:
		if debug_logging:
			push_warning("[TerrainGenerator] Too few height points; aborting terrain generation.")
		return

	# Apply landing zones (with better validation)
	_apply_landing_zones_improved(height_points, terrain_config)

	# Build the closed polygon
	var polygon_points: PackedVector2Array = _build_closed_polygon(height_points)

	# Calculate bounds and highest point
	_calculate_terrain_metrics(height_points)

	# Create the terrain nodes
	_create_terrain_nodes(polygon_points)

	# Create landing zone markers (if debug enabled)
	if debug_show_landing_zones:
		_create_landing_zone_markers()

	if debug_logging:
		print("[TerrainGenerator] Generated terrain with ", height_points.size(),
			" segments. Bounds=", _generated_bounds, " Highest Y=", _highest_point_y)

# -------------------------------------------------------------------
# Helpers: default config
# -------------------------------------------------------------------

func _build_default_config() -> Dictionary:
	return {
		"seed": 0,
		"length": 8000.0,
		"segment_length": 32.0,
		"baseline_y": 600.0,
		"height_variation": 150.0,
		"roughness": 0.5,
		"terrain_type": "lunar_mixed",  # NEW: terrain generation style
		"crater_count": 3,              # NEW: number of craters
		"landing_zones": [
			{
				"id": "primary",
				"center_x": 4000.0,
				"width": 300.0,
				"difficulty": "easy"
			}
		]
	}

# -------------------------------------------------------------------
# IMPROVED: Height profile generation with multiple algorithms
# -------------------------------------------------------------------

func _build_height_profile_improved(terrain_config: Dictionary) -> Array:
	var terrain_type: String = terrain_config.get("terrain_type", "lunar_mixed")
	
	# Choose generation method based on terrain type
	match terrain_type:
		"flat":
			return _generate_flat_terrain(terrain_config)
		"lunar_plains":
			return _generate_lunar_plains(terrain_config)
		"lunar_mountains":
			return _generate_lunar_mountains(terrain_config)
		"lunar_mixed":
			return _generate_lunar_mixed(terrain_config)
		"crater_field":
			return _generate_crater_field(terrain_config)
		"valleys":
			return _generate_valleys(terrain_config)
		_:
			# Fallback to original simple generation
			return _build_height_profile(terrain_config)

# -------------------------------------------------------------------
# Terrain Type Generators
# -------------------------------------------------------------------

func _generate_flat_terrain(config: Dictionary) -> Array:
	"""Generate perfectly flat terrain (for testing/easy mode)"""
	var length: float = float(config.get("length", 2000.0))
	var segment_length: float = float(config.get("segment_length", 32.0))
	var baseline_y: float = float(config.get("baseline_y", 600.0))
	
	var num_segments: int = int(length / segment_length)
	var points: Array = []
	var x: float = 0.0
	
	for i in range(num_segments + 1):
		points.append(Vector2(x, baseline_y))
		x += segment_length
	
	return points

func _generate_lunar_plains(config: Dictionary) -> Array:
	"""Generate gently rolling plains with occasional small features"""
	var length: float = float(config.get("length", 2000.0))
	var segment_length: float = float(config.get("segment_length", 32.0))
	var baseline_y: float = float(config.get("baseline_y", 600.0))
	var height_variation: float = float(config.get("height_variation", 80.0))
	
	var num_segments: int = int(length / segment_length)
	var points: Array = []
	var x: float = 0.0
	
	# Use multiple octaves of noise for smooth rolling hills
	for i in range(num_segments + 1):
		var t: float = float(i) / float(num_segments)
		
		# Large smooth waves
		var wave1 = sin(t * PI * 2.0) * height_variation * 0.3
		
		# Medium features
		var wave2 = sin(t * PI * 6.0 + 1.5) * height_variation * 0.15
		
		# Small bumps
		var noise = _rng.randf_range(-1.0, 1.0) * height_variation * 0.1
		
		var y = baseline_y + wave1 + wave2 + noise
		points.append(Vector2(x, y))
		x += segment_length
	
	return points

func _generate_lunar_mountains(config: Dictionary) -> Array:
	"""Generate mountainous terrain with peaks and valleys"""
	var length: float = float(config.get("length", 2000.0))
	var segment_length: float = float(config.get("segment_length", 32.0))
	var baseline_y: float = float(config.get("baseline_y", 600.0))
	var height_variation: float = float(config.get("height_variation", 200.0))
	var roughness: float = float(config.get("roughness", 0.7))
	
	var num_segments: int = int(length / segment_length)
	var points: Array = []
	var x: float = 0.0
	var current_y: float = baseline_y
	
	# More aggressive height changes for mountains
	for i in range(num_segments + 1):
		points.append(Vector2(x, current_y))
		x += segment_length
		
		if i < num_segments:
			# Larger steps, more variation
			var step_scale: float = roughness * height_variation * 0.4
			var delta_y: float = _rng.randf_range(-step_scale, step_scale)
			
			# Bias toward creating peaks
			if _rng.randf() < 0.3:  # 30% chance of big jump
				delta_y *= 2.0
			
			current_y += delta_y
			current_y = clamp(current_y, baseline_y - height_variation, baseline_y + height_variation)
	
	return points

func _generate_lunar_mixed(config: Dictionary) -> Array:
	"""Generate mixed terrain with plains, hills, and some craters"""
	# Start with plains
	var points: Array = _generate_lunar_plains(config)
	
	# Add some craters
	var crater_count: int = int(config.get("crater_count", 2))
	if crater_count > 0:
		_add_craters_to_terrain(points, crater_count, config)
	
	# Add some random hills
	_add_random_hills(points, config)
	
	return points

func _generate_crater_field(config: Dictionary) -> Array:
	"""Generate terrain heavily modified by craters"""
	var points: Array = _generate_lunar_plains(config)
	var crater_count: int = int(config.get("crater_count", 5))
	_add_craters_to_terrain(points, crater_count, config)
	return points

func _generate_valleys(config: Dictionary) -> Array:
	"""Generate terrain with deep valleys and ridges"""
	var length: float = float(config.get("length", 2000.0))
	var segment_length: float = float(config.get("segment_length", 32.0))
	var baseline_y: float = float(config.get("baseline_y", 600.0))
	var height_variation: float = float(config.get("height_variation", 150.0))
	
	var num_segments: int = int(length / segment_length)
	var points: Array = []
	var x: float = 0.0
	
	# Create alternating high and low sections
	for i in range(num_segments + 1):
		var t: float = float(i) / float(num_segments)
		
		# Create valley pattern
		var valley = sin(t * PI * 3.0) * height_variation * 0.8
		
		# Add roughness
		var noise = _rng.randf_range(-1.0, 1.0) * height_variation * 0.2
		
		var y = baseline_y + valley + noise
		points.append(Vector2(x, y))
		x += segment_length
	
	return points

# -------------------------------------------------------------------
# Crater Generation
# -------------------------------------------------------------------

func _add_craters_to_terrain(points: Array, crater_count: int, config: Dictionary) -> void:
	"""Add craters to existing terrain points"""
	if points.size() < 10:
		return
	
	var length: float = float(config.get("length", 2000.0))
	
	for c in range(crater_count):
		# Random crater position
		var crater_center_x: float = _rng.randf_range(length * 0.1, length * 0.9)
		var crater_radius: float = _rng.randf_range(100.0, 300.0)
		var crater_depth: float = _rng.randf_range(50.0, 120.0)
		
		# Modify points within crater radius
		for i in range(points.size()):
			var p: Vector2 = points[i]
			var dist: float = abs(p.x - crater_center_x)
			
			if dist < crater_radius:
				# Create crater bowl shape
				var t: float = dist / crater_radius
				var crater_curve: float = 1.0 - (t * t)  # Parabolic crater
				var depth_at_point: float = crater_curve * crater_depth
				
				# Add rim uplift
				if t > 0.85:
					var rim_factor: float = (t - 0.85) / 0.15
					depth_at_point -= rim_factor * crater_depth * 0.3
				
				points[i] = Vector2(p.x, p.y + depth_at_point)

func _add_random_hills(points: Array, config: Dictionary) -> void:
	"""Add some random hill features to terrain"""
	if points.size() < 10:
		return
	
	var length: float = float(config.get("length", 2000.0))
	var hill_count: int = _rng.randi_range(2, 4)
	
	for h in range(hill_count):
		var hill_center_x: float = _rng.randf_range(length * 0.1, length * 0.9)
		var hill_width: float = _rng.randf_range(200.0, 400.0)
		var hill_height: float = _rng.randf_range(-80.0, -40.0)  # Negative = upward
		
		for i in range(points.size()):
			var p: Vector2 = points[i]
			var dist: float = abs(p.x - hill_center_x)
			
			if dist < hill_width:
				var t: float = dist / hill_width
				var hill_curve: float = cos(t * PI * 0.5)  # Smooth hill
				points[i] = Vector2(p.x, p.y + hill_curve * hill_height)

# -------------------------------------------------------------------
# IMPROVED: Landing zone application with better validation
# -------------------------------------------------------------------

func _apply_landing_zones_improved(points: Array, terrain_config: Dictionary) -> void:
	var landing_zones: Array = terrain_config.get("landing_zones", [])
	if landing_zones.is_empty():
		# Auto-generate one landing zone if none specified
		landing_zones = _auto_generate_landing_zones(points, terrain_config)
	
	for index in range(landing_zones.size()):
		var zone_cfg = landing_zones[index]
		if typeof(zone_cfg) != TYPE_DICTIONARY:
			continue

		var zone_id: String = String(zone_cfg.get("id", ""))
		if zone_id == "":
			zone_id = "zone_%d" % index

		var center_x: float = float(zone_cfg.get("center_x", 0.0))
		var width: float = float(zone_cfg.get("width", 200.0))
		if width <= 0.0:
			continue

		# Flatten the landing zone
		var half_width: float = width * 0.5
		var x_min: float = center_x - half_width
		var x_max: float = center_x + half_width

		var indices_in_zone: Array = []
		var sum_y: float = 0.0

		for i in range(points.size()):
			var p: Vector2 = points[i]
			if p.x >= x_min and p.x <= x_max:
				indices_in_zone.append(i)
				sum_y += p.y

		if indices_in_zone.size() == 0:
			continue

		var avg_y: float = sum_y / float(indices_in_zone.size())

		# Flatten the zone
		for idx in indices_in_zone:
			var old: Vector2 = points[idx]
			points[idx] = Vector2(old.x, avg_y)

		# Calculate actual difficulty based on surroundings
		var actual_difficulty: String = _calculate_landing_zone_difficulty(points, indices_in_zone, avg_y)

		_landing_zones_info[zone_id] = {
			"center_x": center_x,
			"width": width,
			"surface_y": avg_y,
			"difficulty": actual_difficulty,
			"indices": indices_in_zone
		}

func _auto_generate_landing_zones(points: Array, config: Dictionary) -> Array:
	"""Automatically find good spots for landing zones"""
	if points.size() < 20:
		return []
	
	var length: float = float(config.get("length", 2000.0))
	
	# Find flattest areas
	var flat_areas: Array = _find_flat_areas(points)
	
	# Pick the best one for landing
	if flat_areas.size() > 0:
		var best_area = flat_areas[0]
		return [
			{
				"id": "auto_primary",
				"center_x": best_area.center_x,
				"width": 250.0,
				"difficulty": "auto"
			}
		]
	
	# Fallback: put one in the middle
	return [
		{
			"id": "auto_fallback",
			"center_x": length * 0.5,
			"width": 300.0,
			"difficulty": "auto"
		}
	]

func _find_flat_areas(points: Array) -> Array:
	"""Find the flattest sections of terrain"""
	var flat_areas: Array = []
	var window_size: int = 10
	
	for i in range(points.size() - window_size):
		var height_variance: float = 0.0
		var avg_y: float = 0.0
		
		# Check window of points
		for j in range(window_size):
			avg_y += points[i + j].y
		avg_y /= window_size
		
		for j in range(window_size):
			height_variance += abs(points[i + j].y - avg_y)
		height_variance /= window_size
		
		# If variance is low, it's flat
		if height_variance < 5.0:  # Adjust threshold as needed
			var center_idx = i + window_size / 2
			flat_areas.append({
				"center_x": points[center_idx].x,
				"variance": height_variance,
				"avg_y": avg_y
			})
	
	# Sort by flatness (lowest variance first)
	flat_areas.sort_custom(func(a, b): return a.variance < b.variance)
	
	return flat_areas

func _calculate_landing_zone_difficulty(points: Array, zone_indices: Array, zone_y: float) -> String:
	"""Calculate difficulty based on terrain around the landing zone"""
	if zone_indices.size() == 0:
		return "unknown"
	
	var first_idx: int = zone_indices[0]
	var last_idx: int = zone_indices[zone_indices.size() - 1]
	
	# Check terrain before and after
	var max_height_diff: float = 0.0
	var check_range: int = 5
	
	for i in range(max(0, first_idx - check_range), min(points.size(), last_idx + check_range + 1)):
		if i < first_idx or i > last_idx:
			var diff: float = abs(points[i].y - zone_y)
			if diff > max_height_diff:
				max_height_diff = diff
	
	# Categorize difficulty
	if max_height_diff < 50.0:
		return "easy"
	elif max_height_diff < 100.0:
		return "medium"
	else:
		return "hard"

# -------------------------------------------------------------------
# Helpers: metrics calculation
# -------------------------------------------------------------------

func _calculate_terrain_metrics(points: Array) -> void:
	"""Calculate bounds and highest point from terrain points"""
	if points.size() == 0:
		_generated_bounds = Rect2()
		_highest_point_y = 0.0
		return
	
	var min_x: float = points[0].x
	var max_x: float = points[0].x
	var min_y: float = points[0].y
	var max_y: float = points[0].y
	
	for p in points:
		if p.x < min_x:
			min_x = p.x
		if p.x > max_x:
			max_x = p.x
		if p.y < min_y:
			min_y = p.y
		if p.y > max_y:
			max_y = p.y
	
	_generated_bounds = Rect2(min_x, min_y, max_x - min_x, max_y - min_y)
	_highest_point_y = min_y  # In Godot, lower Y = higher on screen

# -------------------------------------------------------------------
# Original helper methods (kept for compatibility)
# -------------------------------------------------------------------

func _build_height_profile(terrain_config: Dictionary) -> Array:
	"""Original simple terrain generation (kept as fallback)"""
	var length: float = float(terrain_config.get("length", 2000.0))
	var segment_length: float = float(terrain_config.get("segment_length", 32.0))
	if segment_length <= 0.0:
		segment_length = 32.0

	var num_segments: int = int(length / segment_length)
	if num_segments < 2:
		num_segments = 2

	var baseline_y: float = float(terrain_config.get("baseline_y", 600.0))
	var height_variation: float = float(terrain_config.get("height_variation", 120.0))
	if height_variation <= 0.0:
		height_variation = 60.0

	var roughness: float = float(terrain_config.get("roughness", 0.5))
	roughness = clamp(roughness, 0.0, 1.0)

	var min_y: float = baseline_y - height_variation
	var max_y: float = baseline_y + height_variation

	var points: Array = []
	points.resize(num_segments + 1)

	var x: float = 0.0
	var current_y: float = baseline_y

	for i in range(num_segments + 1):
		points[i] = Vector2(x, current_y)
		x += segment_length

		if i < num_segments:
			var step_scale: float = roughness * height_variation * 0.25
			if step_scale <= 0.0:
				step_scale = height_variation * 0.05

			var delta_y: float = _rng.randf_range(-step_scale, step_scale)
			current_y += delta_y
			current_y = clamp(current_y, min_y, max_y)

	return points

func _apply_landing_zones(points: Array, terrain_config: Dictionary) -> void:
	"""Original landing zone application (kept for compatibility)"""
	_apply_landing_zones_improved(points, terrain_config)

func _build_closed_polygon(height_points: Array) -> PackedVector2Array:
	var poly: PackedVector2Array = PackedVector2Array()
	if height_points.size() == 0:
		return poly

	for p in height_points:
		poly.append(p)

	var last_point: Vector2 = height_points[height_points.size() - 1]
	var first_point: Vector2 = height_points[0]

	var max_y: float = first_point.y
	for p in height_points:
		if p.y > max_y:
			max_y = p.y

	var bottom_y: float = max_y + 400.0

	poly.append(Vector2(last_point.x, bottom_y))
	poly.append(Vector2(first_point.x, bottom_y))

	return poly

# -------------------------------------------------------------------
# Node creation / cleanup
# -------------------------------------------------------------------

func _clear_terrain_root() -> void:
	if _terrain_root == null:
		return

	for child in _terrain_root.get_children():
		_terrain_root.remove_child(child)
		child.queue_free()


func _create_terrain_nodes(polygon: PackedVector2Array) -> void:
	if _terrain_root == null:
		return

	var static_body := StaticBody2D.new()
	static_body.name = "TerrainBody"
	static_body.collision_layer = collision_layer
	static_body.collision_mask = collision_mask
	static_body.add_to_group("terrain")

	var collision_polygon := CollisionPolygon2D.new()
	collision_polygon.polygon = polygon
	static_body.add_child(collision_polygon)

	_terrain_root.add_child(static_body)
	_terrain_body = static_body

	var visual := Polygon2D.new()
	visual.name = "TerrainVisual"
	visual.polygon = polygon
	visual.color = terrain_color
	visual.z_index = terrain_z_index

	_terrain_root.add_child(visual)

func _create_landing_zone_markers() -> void:
	"""Create visual markers for landing zones (debug/helpful)"""
	if _terrain_root == null:
		return
	
	for zone_id in _landing_zones_info.keys():
		var zone_info: Dictionary = _landing_zones_info[zone_id]
		var center_x: float = zone_info.get("center_x", 0.0)
		var width: float = zone_info.get("width", 0.0)
		var surface_y: float = zone_info.get("surface_y", 0.0)
		
		# Create a simple colored rectangle to show landing zone
		var marker := Polygon2D.new()
		marker.name = "LandingZoneMarker_" + zone_id
		
		var half_width := width * 0.5
		var marker_height := 10.0
		
		marker.polygon = PackedVector2Array([
			Vector2(center_x - half_width, surface_y - marker_height),
			Vector2(center_x + half_width, surface_y - marker_height),
			Vector2(center_x + half_width, surface_y),
			Vector2(center_x - half_width, surface_y)
		])
		
		# Color by difficulty
		var difficulty: String = zone_info.get("difficulty", "unknown")
		match difficulty:
			"easy":
				marker.color = Color(0.0, 1.0, 0.0, 0.5)  # Green
			"medium":
				marker.color = Color(1.0, 1.0, 0.0, 0.5)  # Yellow
			"hard":
				marker.color = Color(1.0, 0.0, 0.0, 0.5)  # Red
			_:
				marker.color = Color(0.5, 0.5, 1.0, 0.5)  # Blue
		
		marker.z_index = terrain_z_index + 1
		_terrain_root.add_child(marker)
