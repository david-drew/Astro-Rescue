extends Area2D
class_name LanderBoardingZone

@export var debug_logging: bool = false

signal surface_vehicle_entered(vehicle: Node)
signal surface_vehicle_exited(vehicle: Node)

func _ready() -> void:
	monitoring = true
	monitorable = true

func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group("buggy") or body.is_in_group("eva"):
		if debug_logging:
			print("[LanderBoardingZone] vehicle entered: ", body)
		emit_signal("surface_vehicle_entered", body)

func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group("buggy") or body.is_in_group("eva"):
		if debug_logging:
			print("[LanderBoardingZone] vehicle exited: ", body)
		emit_signal("surface_vehicle_exited", body)
