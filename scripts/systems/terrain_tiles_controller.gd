## res://scripts/modes/mode1/terrain_tiles_controller.gd
extends Node
class_name TerrainTilesController

##
# TerrainTilesController (Mode 1 - Lander)
#
# Responsibilities:
#  - Use TerrainGenerator's bounds + landing zone info to build tile-based visuals.
#  - Drive one or more TileMapLayer nodes under World/TerrainRoot.
#  - Be driven by MissionController with the mission_config Dictionary.
#
# It does NOT generate collision; that is TerrainGenerator's job.
##

@export_category("Scene References")
@export var terrain_generator_path: NodePath
@export var bg_tiles_layer_path: NodePath
@export var surface_tiles_layer_path: NodePath
@export var landing_deco_layer_path: NodePath

@export_category("Tile IDs / Atlas Coords")
# Background (sky/ground) tiles
@export var bg_source_id: int = 0
@export var bg_atlas_coords: Vector2i = Vector2i(0, 0)

# Surface detail (rocks, cracks, debris) tiles
@export var surface_source_id: int = 0
@export var surface_atlas_coords: Vector2i = Vector2i(0, 0)

# Landing zone decoration tiles (pads + lights)
@export var landing_pad_source_id: int = 0
@export var landing_pad_atlas_coords: Vector2i = Vector2i(0, 0)
@export var landing_light_source_id: int = 0
@export var landing_light_atlas_coords: Vector2i = Vector2i(0, 0)

@export_category("Generation Settings")
@export var background_height_above_terrain: float = 400.0
@export var background_height_below_terrain: float = 200.0
@export var surface_detail_density: float = 0.25        # 0..1 probability per sample
@export var landing_light_spacing: float = 96.0         # world units between lights
@export var debug_logging: bool = false

# Internal references
var _terrain_generator: TerrainGenerator = null
var _bg_layer: TileMapLayer = null
var _surface_layer: TileMapLayer = null
var _landing_layer: TileMapLayer = null

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	_resolve_references()


func _resolve_references() -> void:
	if _terrain_generator == null and terrain_generator_path != NodePath(""):
		_terrain_generator = get_node_or_null(terrain_generator_path) as TerrainGenerator

	if _bg_layer == null and bg_tiles_layer_path != NodePath(""):
		_bg_layer = get_node_or_null(bg_tiles_layer_path) as TileMapLayer

	if _surface_layer == null and surface_tiles_layer_path != NodePath(""):
		_surface_layer = get_node_or_null(surface_tiles_layer_path) as TileMapLayer

	if _landing_layer == null and landing_deco_layer_path != NodePath(""):
		_landing_layer = get_node_or_null(landing_deco_layer_path) as TileMapLayer

	# Lazy seed; we reseed per mission
	if _rng == null:
		_rng = RandomNumberGenerator.new()

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

##
# Build all tile layers for the given mission.
#
# Expected mission_config structure (terrain block):
#   mission_config["terrain"] = {
#       "seed": int,
#       "length": float,
#       "segment_length": float,
#       "baseline_y": float,
#       "height_variation": float,
#       "roughness": float,
#       "landing_zones": [
#           { "id": "training_zone_01", "center_x": 1500.0, "width": 360.0 },
#           ...
#       ]
#   }
#
func build_tiles_from_mission(mission_config: Dictionary) -> void:
	_resolve_references()

	if _terrain_generator == null:
		if debug_logging:
			push_warning("[TerrainTilesController] TerrainGenerator is not set; skipping tile build.")
		return

	var terrain_cfg: Dictionary = mission_config.get("terrain", {})
	if terrain_cfg.is_empty():
		if debug_logging:
			push_warning("[TerrainTilesController] mission_config has no 'terrain' block; skipping tile build.")
		return

	# Seed RNG so visuals are deterministic per mission.
	_rng.randomize()
	var seed_value: int = int(terrain_cfg.get("seed", 0))
	if seed_value != 0:
		_rng.seed = seed_value

	_clear_all_layers()

	var bounds: Rect2 = _terrain_generator.get_bounds()
	if bounds.size.x <= 0.0:
		if debug_logging:
			push_warning("[TerrainTilesController] Terrain bounds are empty; nothing to draw.")
		return

	if debug_logging:
		print("[TerrainTilesController] Building tiles. Bounds=", bounds)

	_fill_background(bounds, terrain_cfg)
	_scatter_surface_detail(bounds, terrain_cfg)
	_decorate_landing_zones(terrain_cfg)

	# Force TileMapLayer to update immediately (not strictly required, but nice)
	if _bg_layer:
		_bg_layer.update_internals()
	if _surface_layer:
		_surface_layer.update_internals()
	if _landing_layer:
		_landing_layer.update_internals()

# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _clear_all_layers() -> void:
	if _bg_layer:
		_bg_layer.clear()
	if _surface_layer:
		_surface_layer.clear()
	if _landing_layer:
		_landing_layer.clear()

# --- Background ----------------------------------------------------

func _fill_background(bounds: Rect2, terrain_cfg: Dictionary) -> void:
	if _bg_layer == null:
		return
	if bg_source_id < 0:
		return

	# Compute a world-space rectangle slightly larger than the terrain.
	var world_top: Vector2 = bounds.position
	world_top.y -= background_height_above_terrain

	var world_bottom: Vector2 = bounds.position + bounds.size
	world_bottom.y += background_height_below_terrain

	var top_cell: Vector2i = _world_to_cell(_bg_layer, world_top)
	var bottom_cell: Vector2i = _world_to_cell(_bg_layer, world_bottom)

	var min_x: int = min(top_cell.x, bottom_cell.x)
	var max_x: int = max(top_cell.x, bottom_cell.x)
	var min_y: int = min(top_cell.y, bottom_cell.y)
	var max_y: int = max(top_cell.y, bottom_cell.y)

	if debug_logging:
		print("[TerrainTilesController] Background cell rect: (",
			min_x, ",", min_y, ") → (", max_x, ",", max_y, ")")

	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			_set_tile(_bg_layer, Vector2i(x, y), bg_source_id, bg_atlas_coords)

# --- Surface detail ------------------------------------------------

func _scatter_surface_detail(bounds: Rect2, terrain_cfg: Dictionary) -> void:
	if _surface_layer == null:
		return
	if surface_source_id < 0:
		return
	if surface_detail_density <= 0.0:
		return

	var tile_size: Vector2 = _get_cell_world_size(_surface_layer)
	var step_x: float = tile_size.x
	if step_x <= 0.0:
		step_x = terrain_cfg.get("segment_length", 32.0)

	# Approximate a surface height band around the baseline.
	var baseline_y: float = float(terrain_cfg.get("baseline_y", bounds.position.y + bounds.size.y))
	var variation: float = float(terrain_cfg.get("height_variation", 0.0))
	var approx_surface_y: float = baseline_y - variation * 0.5

	var x: float = bounds.position.x
	var x_end: float = bounds.position.x + bounds.size.x

	while x <= x_end:
		if _rng.randf() < surface_detail_density:
			var world_pos := Vector2(x, approx_surface_y)
			var cell: Vector2i = _world_to_cell(_surface_layer, world_pos)
			_set_tile(_surface_layer, cell, surface_source_id, surface_atlas_coords)
		x += step_x

# --- Landing zones -------------------------------------------------

func _decorate_landing_zones(terrain_cfg: Dictionary) -> void:
	if _landing_layer == null:
		return

	var landing_zones: Array = terrain_cfg.get("landing_zones", [])
	if landing_zones.is_empty():
		return

	for zone_def in landing_zones:
		if typeof(zone_def) != TYPE_DICTIONARY:
			continue

		var zone_id: String = str(zone_def.get("id", ""))
		if zone_id.is_empty():
			continue

		var zone_info: Dictionary = _terrain_generator.get_landing_zone_world_info(zone_id)
		if zone_info.is_empty():
			if debug_logging:
				push_warning("[TerrainTilesController] No landing zone info for id=" + zone_id)
			continue

		_stamp_landing_pad(zone_info)
		_stamp_landing_lights(zone_info)

func _stamp_landing_pad(zone_info: Dictionary) -> void:
	if _landing_layer == null:
		return
	if landing_pad_source_id < 0:
		return

	var center_x: float = float(zone_info.get("center_x", 0.0))
	var width: float = float(zone_info.get("width", 0.0))
	var surface_y: float = float(zone_info.get("surface_y", 0.0))

	var half_width: float = width * 0.5
	var left_x: float = center_x - half_width
	var right_x: float = center_x + half_width

	var tile_size: Vector2 = _get_cell_world_size(_landing_layer)
	var step_x: float = tile_size.x
	if step_x <= 0.0:
		step_x = 32.0

	var x: float = left_x
	while x <= right_x:
		var world_pos := Vector2(x, surface_y)
		var cell: Vector2i = _world_to_cell(_landing_layer, world_pos)
		_set_tile(_landing_layer, cell, landing_pad_source_id, landing_pad_atlas_coords)
		x += step_x

func _stamp_landing_lights(zone_info: Dictionary) -> void:
	if _landing_layer == null:
		return
	if landing_light_source_id < 0:
		return

	var center_x: float = float(zone_info.get("center_x", 0.0))
	var width: float = float(zone_info.get("width", 0.0))
	var surface_y: float = float(zone_info.get("surface_y", 0.0))

	var half_width: float = width * 0.5
	var left_x: float = center_x - half_width
	var right_x: float = center_x + half_width

	var tile_size: Vector2 = _get_cell_world_size(_landing_layer)
	var light_y: float = surface_y - tile_size.y    # one tile above surface

	var spacing: float = landing_light_spacing
	if spacing <= 0.0:
		spacing = tile_size.x * 2.0

	var x: float = left_x
	while x <= right_x:
		var world_pos := Vector2(x, light_y)
		var cell: Vector2i = _world_to_cell(_landing_layer, world_pos)
		_set_tile(_landing_layer, cell, landing_light_source_id, landing_light_atlas_coords)
		x += spacing

# -------------------------------------------------------------------
# Utility
# -------------------------------------------------------------------

func _world_to_cell(layer: TileMapLayer, world_pos: Vector2) -> Vector2i:
	# TerrainGenerator and TileMapLayers should share TerrainRoot as a parent.
	# Use the layer's local space to remain robust if TerrainRoot moves.
	var local_pos: Vector2 = layer.to_local(world_pos)
	return layer.local_to_map(local_pos)

func _get_cell_world_size(layer: TileMapLayer) -> Vector2:
	if layer == null:
		return Vector2(32.0, 32.0)

	var tileset := layer.tile_set
	if tileset != null:
		var size: Vector2i = tileset.tile_size
		return Vector2(float(size.x), float(size.y))

	return Vector2(32.0, 32.0)

func _set_tile(layer: TileMapLayer, cell: Vector2i, source_id: int, atlas_coords: Vector2i, alternative_tile: int = 0) -> void:
	if layer == null:
		return
	if source_id < 0:
		return
	layer.set_cell(cell, source_id, atlas_coords, alternative_tile)
