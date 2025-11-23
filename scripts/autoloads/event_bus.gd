## res://scripts/core/event_bus.gd
extends Node
#class_name EventBus

##
# EventBus
#
# Centralized signal hub for Astro Rescue.
#
# Design goals:
# - Decouple systems (UI, GameState, MissionGenerator, MissionController, etc.)
# - Avoid direct node-to-node references
# - Keep it dumb: define signals, emit, and connect from elsewhere
#
# Typical usage:
#   EventBus.emit_signal("mission_started", mission_id)
#   EventBus.connect("mission_started", Callable(self, "_on_mission_started"))
#
# This file should stay lightweight and stable.
##

# -------------------------------------------------------------------
# Debug
# -------------------------------------------------------------------

## If true, EventBus will print when certain key signals are emitted.
var debug_logging: bool = false


func _ready() -> void:
	# Nothing special required on startup for now.
	# You can toggle debug_logging via a debug menu or console later.
	pass

# -------------------------------------------------------------------
# UI
# -------------------------------------------------------------------
signal new_game_requested
signal crew_recruit_requested(candidate_id: String)
signal crew_recruit_succeeded(candidate_id: String)
signal crew_recruit_failed(candidate_id: String, reason: String)
signal store_purchase_requested(item_id: String, quantity: int)
signal store_purchase_succeeded(item_id: String, quantity: int)
signal store_purchase_failed(item_id: String, reason: String)


# -------------------------------------------------------------------
# Profile / Career signals
# -------------------------------------------------------------------

signal profile_reset(profile: Dictionary)				# profile reset to default (new career)
signal profile_loaded(profile: Dictionary)				# profile loaded from save.
signal reputation_changed(new_value: int, delta: int)	# reputation changed.
signal funds_changed(new_value: int, delta: int)		# funds changed.

## career status changes (e.g., "active", "terminated", "retired").
signal career_status_changed(new_status: String, reason: String)

## career terminated (e.g., rep too low or player death).
signal career_terminated(reason: String)


# -------------------------------------------------------------------
# Unlocks & Progression
# -------------------------------------------------------------------
signal lander_unlocked(lander_id: String)	# new lander unlocked.
signal crew_unlocked(crew_id: String)		# new crew member unlocked.
signal mission_tag_unlocked(tag: String)	# new mission tag is unlocked (gates archetypes/arcs).

signal terrain_generated(terrain_generator:TerrainGenerator)

# -------------------------------------------------------------------
# Mission lifecycle (config, runtime, results)
# -------------------------------------------------------------------

## Emitted when a new MissionConfig is set into GameState.
signal mission_config_set(mission_id: String, mission_config: Dictionary)

## Emitted when the current mission is cleared from GameState.
signal mission_cleared()

## Emitted when a mission is about to start (e.g., when loading a mode scene).
signal mission_started(mission_id: String)
signal start_mission_requested(mission_id: String, mission_config: Dictionary)		# TODO: DUPE

## Emitted when MissionController considers the mission complete (success/partial/fail).
signal mission_completed(mission_id: String, result: Dictionary)

## Emitted when MissionController marks a mission as failed for a specific reason.
signal mission_failed(mission_id: String, reason: String, result: Dictionary)

## Emitted after GameState has applied mission results to the profile (rewards, penalties, etc.).
signal mission_result_applied(mission_id: String, success_state: String, result: Dictionary)

## Emitted when Debrief UI is closed and the player is ready to return to HQ or
## start the next mission. Debrief should have already called
## GameState.apply_mission_result(current_mission_result) before emitting this.
signal debrief_finished(mission_id: String, result: Dictionary)
signal briefing_launch_requested
signal debrief_return_requested

signal time_tick(channel_id: String, dt_game: float, dt_real: float)

# signal world_state_changed(world_state: Dictionary)			# If we want real-time HUD

# -------------------------------------------------------------------
# In-mission events (lander, player, environment)
# -------------------------------------------------------------------
signal lander_entered_landing_zone(zone_id: String, zone_info: Dictionary)
signal lander_exited_landing_zone(zone_id: String, zone_info: Dictionary)

## Emitted on touchdown attempt; success indicates a safe landing according to current thresholds.
signal touchdown(success: bool, impact_data: Dictionary)

## Emitted when the lander is destroyed (hard crash, tip-over beyond recovery, etc.).
signal lander_destroyed(cause: String, context: Dictionary)

## Emitted whenever fuel changes significantly (optional throttle; up to the lander controller).
signal fuel_changed(current_ratio: float)

## Emitted when player death is detected (e.g., catastrophic impact, hazard).
signal player_died(cause: String, context: Dictionary)

## Emitted when a global mission timer or phase timer reaches zero.
signal mission_timer_expired(timer_id: String)

# -------------------------------------------------------------------
# Weather Effects
# -------------------------------------------------------------------
signal wind_profile_changed(profile_id: String)
signal visibility_changed(visibility_state: Dictionary)
signal wind_vector_changed(wind_vector: Vector2)
signal wind_gust_warning(direction_deg: float, strength_factor: float)
signal meteor_shower_started(params: Dictionary)
signal meteor_shower_ended()
signal gravity_changed(gravity_vector: Vector2)

# -------------------------------------------------------------------
# Save / Load
# -------------------------------------------------------------------

## Emitted when a profile is successfully saved.
signal profile_saved(profile: Dictionary)

## Emitted when a save failed (IO error, etc.).
signal profile_save_failed(error_message: String)

# -------------------------------------------------------------------
# UI
# -------------------------------------------------------------------

signal lander_altitude_changed(altitude_meters: float)
signal lander_stats_updated(stats: Dictionary)

# -------------------------------------------------------------------
# Optional debug helper
# -------------------------------------------------------------------

func emit_debug(signal_name: String, args: Array = []) -> void:
	##
	# Convenience wrapper if you ever want to centralize debug prints for signals.
	# Most of the time you will just use emit_signal() directly.
	##
	if debug_logging:
		print("[EventBus] Emitting: %s, args=%s" % [signal_name, str(args)])
	emit_signal(signal_name, args)
