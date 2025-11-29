extends Control
class_name SurfaceOpsDialog

signal deploy_buggy_confirmed
signal board_lander_confirmed
signal dialog_closed

@onready var _label: Label = $Panel/MarginContainer/VBox/Label
@onready var _eject_button: Button = $Panel/MarginContainer/VBox/EjectButton
@onready var _cancel_button: Button = $Panel/MarginContainer/VBox/CancelButton

var _mode: String = ""  # "deploy_buggy" or "board_lander"

func _ready() -> void:
	visible = false
	_eject_button.pressed.connect(_on_primary_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)


func show_deploy_buggy() -> void:
	_mode = "deploy_buggy"
	if _label != null:
		_label.text = "Deploy buggy and exit the lander?"
	if _eject_button != null:
		_eject_button.text = "Deploy Buggy"
		visible = true
		#get_tree().set_input_as_handled()


func show_board_lander() -> void:
	_mode = "board_lander"
	if _label != null:
		_label.text = "Re-enter the lander?"
	if _eject_button != null:
		_eject_button.text = "Board Lander"
	visible = true
	#get_tree().set_input_as_handled()


func _on_primary_pressed() -> void:
	match _mode:	
		"deploy_buggy":
			emit_signal("deploy_buggy_confirmed")
		"board_lander":
			emit_signal("board_lander_confirmed")

	visible = false
	emit_signal("dialog_closed")


func _on_cancel_pressed() -> void:
	visible = false
	emit_signal("dialog_closed")
