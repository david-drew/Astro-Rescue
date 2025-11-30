# res://scripts/modes/mode1/mission_results.gd
extends RefCounted
class_name MissionResults


var mission_id: String
var is_training: bool
var tier: int
var success_state: String
var failure_reason: String
var elapsed_time: float
var time_limit: float

var primary_objectives: Array
var bonus_objectives: Array

var max_hull_damage_ratio: float
var crashes: int
var player_died: bool
var lander_destroyed: bool

var orbit_reached: bool
var orbit_reached_altitude: float
var orbit_reached_time: float

var rewards: Dictionary


func build(
	mission_id: String,
	is_training: bool,
	tier: int,
	success_state: String,
	failure_reason: String,
	elapsed_time: float,
	time_limit: float,
	primary: Array,
	bonus: Array,
	stats: Dictionary,
	rewards: Dictionary
) -> Dictionary:
	self.mission_id = mission_id
	self.is_training = is_training
	self.tier = tier
	self.success_state = success_state
	self.failure_reason = failure_reason
	self.elapsed_time = elapsed_time
	self.time_limit = time_limit
	self.primary_objectives = primary
	self.bonus_objectives = bonus
	self.rewards = rewards

	max_hull_damage_ratio = stats.get("max_hull_damage_ratio", 0.0)
	crashes = stats.get("crashes", 0)
	player_died = stats.get("player_died", false)
	lander_destroyed = stats.get("lander_destroyed", false)

	orbit_reached = stats.get("orbit_reached", false)
	orbit_reached_altitude = stats.get("orbit_reached_altitude", 0.0)
	orbit_reached_time = stats.get("orbit_reached_time", 0.0)

	return _to_dict()


func _to_dict() -> Dictionary:
	return {
		"mission_id": mission_id,
		"is_training": is_training,
		"tier": tier,
		"success_state": success_state,
		"failure_reason": failure_reason,
		"elapsed_time": elapsed_time,
		"time_limit": time_limit,
		"primary_objectives": primary_objectives,
		"bonus_objectives": bonus_objectives,
		"stats": {
			"max_hull_damage_ratio": max_hull_damage_ratio,
			"crashes": crashes,
			"player_died": player_died,
			"lander_destroyed": lander_destroyed,
			"orbit_reached": orbit_reached,
			"orbit_reached_altitude": orbit_reached_altitude,
			"orbit_reached_time": orbit_reached_time
		},
		"rewards": rewards
	}
