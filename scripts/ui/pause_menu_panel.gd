extends Control

signal load_requested
signal save_requested
signal main_menu_requested
signal quit_requested

@onready var _load_button: Button = $Panel/VBox/LoadButton
@onready var _save_button: Button = $Panel/VBox/SaveButton
@onready var _main_menu_button: Button = $Panel/VBox/MainMenuButton
@onready var _quit_button: Button = $Panel/VBox/QuitButton

func _ready() -> void:
	visible = false

	if _load_button:
		_load_button.pressed.connect(_on_load_pressed)
	if _save_button:
		_save_button.pressed.connect(_on_save_pressed)
	if _main_menu_button:
		_main_menu_button.pressed.connect(_on_main_menu_pressed)
	if _quit_button:
		_quit_button.pressed.connect(_on_quit_pressed)

func show_menu() -> void:
	visible = true
	grab_focus()

func hide_menu() -> void:
	visible = false

func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()

func _on_load_pressed() -> void:
	emit_signal("load_requested")

func _on_save_pressed() -> void:
	emit_signal("save_requested")

func _on_main_menu_pressed() -> void:
	emit_signal("main_menu_requested")

func _on_quit_pressed() -> void:
	emit_signal("quit_requested")
