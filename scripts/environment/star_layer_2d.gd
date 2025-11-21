# res://scripts/space/StarLayer2D.gd
extends Node2D
##
## StarLayer2D: draws a tile of tiny stars that the ParallaxLayer mirrors infinitely.
## Godot 4.5 fixes:
##  - use queue_redraw() instead of update()
##  - dictionary access with ["key"] and explicit typing/casts

@export var tile_size: Vector2 = Vector2(3440, 1440)
@export var star_count: int = 400
@export var min_radius: float = 0.6
@export var max_radius: float = 1.6
@export var base_color: Color = Color(1, 1, 1, 1)
@export var color_jitter: float = 0.08
@export var seed: int = 0
@export var allow_twinkle: bool = false
@export var twinkle_speed: float = 1.2
@export var twinkle_strength: float = 0.25 # 0..1

# Typed array of typed dictionaries
var _stars: Array[Dictionary] = []

@export var role: String = "Mid"

func _ready() -> void:
	var layer := get_parent()
	if layer is ParallaxLayer:
		match role:
			"Far":
				(layer as ParallaxLayer).motion_scale = Vector2(0.15, 0.15)
				star_count = 600
			"Mid":
				(layer as ParallaxLayer).motion_scale = Vector2(0.35, 0.35)
				star_count = 400
			"Near":
				(layer as ParallaxLayer).motion_scale = Vector2(0.60, 0.60)
				star_count = 200
		(layer as ParallaxLayer).motion_mirroring = tile_size

	_generate_stars()
	queue_redraw()
	get_viewport().size_changed.connect(_on_viewport_resized)

func _process(delta: float) -> void:
	if not allow_twinkle:
		return
	var any_changed := false
	for i in _stars.size():
		var tw: float = _stars[i]["tw"]
		tw += delta * twinkle_speed
		_stars[i]["tw"] = tw
		# redraw occasionally; cheap + avoids per-frame redraw
		if randi() % 60 == 0:
			any_changed = true
	if any_changed:
		queue_redraw()

func _draw() -> void:
	for s in _stars:
		var a_mod: float = 1.0
		if allow_twinkle:
			var tw: float = s["tw"]
			a_mod = clampf(1.0 + sin(tw) * twinkle_strength, 0.0, 1.0)

		var c: Color = Color(s["col"])   # explicit cast to Color
		c.a *= a_mod

		var pos: Vector2 = s["pos"]
		var r: float = s["r"]
		draw_circle(pos, r, c)

func _generate_stars() -> void:
	_stars.clear()

	var rng := RandomNumberGenerator.new()
	if seed == 0:
		rng.randomize()
	else:
		rng.seed = seed

	for i in star_count:
		var pos := Vector2(rng.randf_range(0.0, tile_size.x),
						   rng.randf_range(0.0, tile_size.y))
		var r := rng.randf_range(min_radius, max_radius)

		var jitter := rng.randf_range(-color_jitter, color_jitter)
		var col := base_color
		col.r = clampf(col.r + (-jitter * 0.5), 0.0, 1.0)
		col.b = clampf(col.b + ( jitter * 0.5), 0.0, 1.0)

		_stars.append({
			"pos": pos,         # Vector2
			"r": r,             # float
			"col": col,         # Color
			"tw": rng.randf() * TAU, # float (phase)
		})

func _on_viewport_resized() -> void:
	# If you later decide to tie tile_size to the viewport, recompute here,
	# then reassign mirroring and regenerate.
	# Example:
	# tile_size = get_viewport_rect().size * 2.0
	# var layer := get_parent()
	# if layer is ParallaxLayer:
	#     (layer as ParallaxLayer).motion_mirroring = tile_size
	# _generate_stars()
	# queue_redraw()
	pass
