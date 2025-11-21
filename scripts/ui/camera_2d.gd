extends Camera2D

signal screenshot

var _current_alt_band: int = -1
var _current_altitude:float = 0.0

var ZOOM_MAX:float = 2.0
var ZOOM_MIN:float = 0.2

var zoom_scale:float = 0.1
var new_zoom:float   = 0.0

var _zoom_tween: Tween
var tween_duration = 0.6 		# seconds

func _ready() -> void:
	if not EventBus.is_connected("lander_altitude_changed", Callable(self, "_on_altitude_changed")):
		EventBus.connect("lander_altitude_changed", Callable(self, "_on_altitude_changed"))

func _get_altitude_band(altitude_meters: float) -> int:
	# Higher band number = higher altitude
	# Thresholds: 600, 450, 220, 100
	
	if altitude_meters > 600.0:
		return 4
	elif altitude_meters > 500.0:
		return 3
	elif altitude_meters > 220.0:
		return 2
	elif altitude_meters < 110.0:
		return 1
	else:
		return 0


func _on_altitude_changed(altitude_meters: float) -> void:
	_current_altitude = altitude_meters

	var new_band: int = _get_altitude_band(altitude_meters)

	# If we're still in the same band, do nothing.
	if new_band == _current_alt_band:
		return

	_current_alt_band = new_band
	_update_camera_zoom()

	
func _update_camera_zoom() -> void:
	var target_zoom: float

	# As altitude decreases, zoom value increases (closer).
	match _current_alt_band:
		5:  target_zoom = 0.6 	# > 14000 m: very far, zoomed out, rarely used
		4:  target_zoom = 0.8 	# > 10000 m: far, zoomed out
		3:	target_zoom = 1.0	# 5000–10000 m
		2:	target_zoom = 1.2	# 2400–5000 m
		1:	target_zoom = 1.4	# 1100–2400 m
		0:	target_zoom = 1.6	# < 1100 m: very close, zoomed in
		_: 	target_zoom = 1.6	# Fallback

	target_zoom = clamp(target_zoom, ZOOM_MIN, ZOOM_MAX)

	# Exit if it's not a significant change
	if abs(target_zoom - self.zoom.x) < 0.1:
		return

	new_zoom = target_zoom
	#camera_zoom()
	tween_zoom()

func tween_zoom() -> void:
	if _zoom_tween and _zoom_tween.is_running():
		_zoom_tween.kill()

	_zoom_tween = create_tween()
	_zoom_tween.set_trans(Tween.TRANS_SINE)
	_zoom_tween.set_ease(Tween.EASE_IN_OUT)
	_zoom_tween.tween_property(self, "zoom", Vector2(new_zoom, new_zoom), tween_duration)

func _unhandled_input(event):
	new_zoom = 0
	if event.is_action_pressed("zoom_in"):
		new_zoom = self.zoom.x + zoom_scale
		#self.zoom = Vector2( zoom.x + zoom_scale, zoom.y + zoom_scale)
	elif event.is_action_pressed("zoom_out"):
		new_zoom = self.zoom.x - zoom_scale
		#self.zoom = Vector2( zoom.x - zoom_scale, zoom.y - zoom_scale)
	elif event.is_action_pressed("reset_camera"):
		self.zoom = Vector2(1, 1)
	elif event.is_action_pressed("print_screen"):
			print_screen()

	if new_zoom > ZOOM_MIN and new_zoom < ZOOM_MAX:
		#print( str( "New Zoom: ", new_zoom ))
		camera_zoom()


func camera_zoom():
	self.zoom = Vector2(new_zoom, new_zoom)
	#zoom_lbl.text = str(self.zoom)

func print_screen():
	var datime = Time.get_datetime_dict_from_system()
	var img = get_viewport().get_texture().get_image()
	#img.flip_y
	#var tex = ImageTexture.create_from_image(img)

	# user:// is:
	#   Windows:  %APPDATA%\Godot\app_userdata\Project Name
	#   Linux:    $HOME/.godot/app_userdata/Project Name
	var err := img.save_png(
			"user://sl_{year}-{month}-{day}_{hour}.{minute}.{second}.png" \
			.format(datime)
	)

	if err == OK:
		screenshot.emit()
	else:
		print("Error: Couldn't save screenshot.")
