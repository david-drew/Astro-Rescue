## res://scripts/core/mission_generator.gd
extends Node
class_name MissionGenerator

##
# MissionGenerator
#
# Creates fully-populated MissionConfig dictionaries from:
# - Player profile (via GameState)
# - Mission archetypes (via DataManager)
# - Biomes, landers, objective templates, reward profiles (via DataManager)
#
# Main entrypoint:
#   generate_mission(context: Dictionary) -> Dictionary
#
# Expected context keys:
#   - is_training: bool = false
#   - requested_modes: Array[String] = ["lander"]
#   - difficulty_hint: String = "auto"  # "auto", "easy", "normal", "hard"
#   - special_tags: Array[String]        # e.g. ["training"], ["story_arc_alpha"]
#   - seed_override: int                 # optional fixed seed
#   - forced_archetype_id: String        # optional
#   - forced_biome_id: String            # optional
#
# MissionConfig result structure (high-level):
# {
#   "id": String,
#   "seed": int,
#   "tier": int,
#   "is_training": bool,
#   "archetype_id": String,
#   "biome_id": String,
#   "environment": Dictionary,
#   "terrain": Dictionary,
#   "lander_setup": Dictionary,
#   "crew_setup": Dictionary,
#   "objectives": {
#       "primary": Array[Dictionary],
#       "bonus": Array[Dictionary]
#   },
#   "failure_rules": Dictionary,
#   "rewards": Dictionary,
#   "ui": Dictionary   # name, description, tags, etc.
# }
##

const DEFAULT_GRAVITY_SCALE := 1.0
const DEFAULT_TERRAIN_RESOLUTION := 4.0
const DEFAULT_MISSION_MODE := "lander"

# Simple tier thresholds based on reputation.
const TIER_THRESHOLDS := [
	{"min_rep": -9999, "max_rep": 9, "tier": 0},
	{"min_rep": 10, "max_rep": 25, "tier": 1},
	{"min_rep": 26, "max_rep": 50, "tier": 2},
	{"min_rep": 51, "max_rep": 80, "tier": 3},
	{"min_rep": 81, "max_rep": 120, "tier": 4},
	{"min_rep": 121, "max_rep": 99999, "tier": 5}
]

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var world_sim: Node = null


func _ready() -> void:
	_rng.randomize()
	world_sim = WorldSimManager.new()

func generate_mission(context: Dictionary) -> Dictionary:
	##
	# Main entrypoint.
	# Creates a MissionConfig for either training or career missions.
	##
	var is_training: bool = context.get("is_training", false)
	var requested_modes: Array = context.get("requested_modes", [DEFAULT_MISSION_MODE])
	var difficulty_hint: String = context.get("difficulty_hint", "auto")
	var special_tags: Array = context.get("special_tags", [])
	var forced_archetype_id: String = context.get("forced_archetype_id", "")
	var forced_biome_id: String = context.get("forced_biome_id", "")

	var seed: int = context.get("seed_override", 0)
	if seed == 0:
		seed = int(Time.get_unix_time_from_system())
	_rng.seed = seed

	var player_profile: Dictionary = GameState.player_profile
	var tier: int = 0

	if is_training:
		tier = 0
	else:
		tier = _determine_tier(player_profile, difficulty_hint)

	var archetype: Dictionary = _select_archetype(
		tier,
		requested_modes,
		is_training,
		special_tags,
		forced_archetype_id
	)
	var biome: Dictionary = _select_biome(
		tier,
		archetype,
		forced_biome_id
	)

	var environment: Dictionary = _build_environment(biome, archetype, tier)
	var terrain: Dictionary = _build_terrain(biome, archetype, tier)

	var lander_setup: Dictionary = _build_lander_setup(
		archetype,
		player_profile,
		is_training
	)
	var crew_setup: Dictionary = _build_crew_setup(archetype, player_profile)

	var objectives: Dictionary = _build_objectives(
		archetype,
		tier,
		terrain,
		is_training
	)

	var failure_rules: Dictionary = _build_failure_rules(archetype, is_training)
	var rewards: Dictionary = _build_rewards(archetype, tier)

	var mission_id: String = _build_mission_id(archetype, biome, seed)

	var ui_info: Dictionary = {
		"name": archetype.get("name", "Mission"),
		"description": archetype.get("description", ""),
		"tags": archetype.get("tags", [])
	}

	var mission_config: Dictionary = {
		"id": mission_id,
		"seed": seed,
		"tier": tier,
		"is_training": is_training,
		"archetype_id": archetype.get("id", ""),
		"biome_id": biome.get("id", ""),
		"environment": environment,
		"terrain": terrain,
		"lander_setup": lander_setup,
		"crew_setup": crew_setup,
		"objectives": objectives,
		"failure_rules": failure_rules,
		"rewards": rewards,
		"ui": ui_info
	}

	# TODO: WorldSim is supposed to tweak and decorate missions
	#mission_config = world_sim.decorate_mission_config(mission_config)

	return mission_config

func generate_training_mission() -> Dictionary:
	var cfg:Dictionary = world_sim.choose_training_mission()
	var mid:String = ""
	if not cfg.is_empty():
		mid = String(cfg.get("id", ""))

	return generate_mission({
		"is_training": true,
		"forced_archetype_id": mid
	})

# -------------------------------------------------------------------
# Tier / Difficulty
# -------------------------------------------------------------------

func _determine_tier(player_profile: Dictionary, difficulty_hint: String) -> int:
	var rep: int = int(player_profile.get("reputation", 0))
	var base_tier := 0

	for entry in TIER_THRESHOLDS:
		if rep >= entry["min_rep"] and rep <= entry["max_rep"]:
			base_tier = entry["tier"]
			break

	if difficulty_hint == "easy":
		base_tier = max(base_tier - 1, 0)
	elif difficulty_hint == "hard":
		base_tier += 1
	elif difficulty_hint == "normal":
		base_tier = base_tier
	# "auto" or unknown → use base_tier as-is

	return base_tier


# -------------------------------------------------------------------
# Archetype & Biome Selection
# -------------------------------------------------------------------

func _select_archetype(
		tier: int,
		requested_modes: Array,
		is_training: bool,
		special_tags: Array,
		forced_archetype_id: String
	) -> Dictionary:
	var archetypes: Array = DataManager.get_mission_archetypes()  # Expect: Array[Dictionary]

	# Forced archetype?
	if forced_archetype_id != "":
		for a in archetypes:
			if a.get("id", "") == forced_archetype_id:
				return a

	var candidates: Array = []

	for a in archetypes:
		var tier_range: Array = a.get("tier_range", [0, 5])
		var archetype_tier_min: int = tier_range[0]
		var archetype_tier_max: int = tier_range[1]
		if tier < archetype_tier_min or tier > archetype_tier_max:
			continue

		var modes: Array = a.get("modes", ["lander"])
		if not _modes_compatible(modes, requested_modes):
			continue

		var tags: Array = a.get("tags", [])

		if is_training:
			# Prefer training-tagged archetypes for training missions.
			if not tags.has("training"):
				continue
		elif special_tags.size() > 0:
			var matches_any := false
			for tag in special_tags:
				if tags.has(tag):
					matches_any = true
					break
			if not matches_any:
				continue

		candidates.append(a)

	# Fallback: if no candidates, relax conditions slightly
	if candidates.is_empty():
		for a in archetypes:
			var tier_range2: Array = a.get("tier_range", [0, 5])
			if tier >= tier_range2[0] and tier <= tier_range2[1]:
				candidates.append(a)

	if candidates.is_empty():
		push_warning("MissionGenerator: No mission archetypes matched; using first archetype as fallback.")
		if archetypes.size() > 0:
			return archetypes[0]
		return {}

	var index: int = _rng.randi_range(0, candidates.size() - 1)
	return candidates[index]


func _modes_compatible(archetype_modes: Array, requested_modes: Array) -> bool:
	# For now, we just care that all requested modes are supported by the archetype.
	for mode in requested_modes:
		if not archetype_modes.has(mode):
			return false
	return true


func _select_biome(tier: int, archetype: Dictionary, forced_biome_id: String) -> Dictionary:
	var biomes: Array = DataManager.get_biomes()  # Expect: Array[Dictionary]

	# Forced biome?
	if forced_biome_id != "":
		for b in biomes:
			if b.get("id", "") == forced_biome_id:
				return b

	var allowed_tags: Array = archetype.get("biome_tags_allowed", [])
	var candidates: Array = []

	for b in biomes:
		var tier_min: int = int(b.get("tier_min", 0))
		var tier_max: int = int(b.get("tier_max", 5))
		if tier < tier_min or tier > tier_max:
			continue

		if allowed_tags.size() == 0:
			candidates.append(b)
			continue

		var biome_tags: Array = b.get("tags", [])
		if _arrays_intersect(allowed_tags, biome_tags):
			candidates.append(b)

	if candidates.is_empty():
		# Fallback: any biome matching tier.
		for b in biomes:
			var tier_min2: int = int(b.get("tier_min", 0))
			var tier_max2: int = int(b.get("tier_max", 5))
			if tier >= tier_min2 and tier <= tier_max2:
				candidates.append(b)

	if candidates.is_empty():
		push_warning("MissionGenerator: No biomes matched; using first biome as fallback.")
		if biomes.size() > 0:
			return biomes[0]
		return {}

	var index: int = _rng.randi_range(0, candidates.size() - 1)
	return candidates[index]


func _arrays_intersect(a: Array, b: Array) -> bool:
	for item in a:
		if b.has(item):
			return true
	return false


# -------------------------------------------------------------------
# Environment & Terrain
# -------------------------------------------------------------------

func _build_environment(biome: Dictionary, archetype: Dictionary, tier: int) -> Dictionary:
	var env_defaults: Dictionary = biome.get("environment_defaults", {})

	var gravity_range: Array = env_defaults.get("gravity_scale_range", [DEFAULT_GRAVITY_SCALE, DEFAULT_GRAVITY_SCALE])
	var gravity_scale: float = _rand_range(gravity_range)

	var atmosphere: String = env_defaults.get("atmosphere", "none")

	var wind_profiles: Array = env_defaults.get("wind_profile_ids", ["none"])
	var wind_profile_id: String = "none"
	if wind_profiles.size() > 0:
		var wind_index: int = _rng.randi_range(0, wind_profiles.size() - 1)
		wind_profile_id = wind_profiles[wind_index]

	var physics_profiles: Array = env_defaults.get("physics_profile_ids", ["standard"])
	var physics_profile_id: String = physics_profiles[0]

	var visibility_defaults: Dictionary = env_defaults.get("visibility", {})
	var fog_types: Array = visibility_defaults.get("fog_types", ["none"])
	var fog_type: String = "none"
	if fog_types.size() > 0:
		var fog_index: int = _rng.randi_range(0, fog_types.size() - 1)
		fog_type = fog_types[fog_index]

	var fog_density_range: Array = visibility_defaults.get("fog_density_range", [0.0, 0.0])
	var fog_density: float = _rand_range(fog_density_range)

	var precip_types: Array = visibility_defaults.get("precipitation_types", ["none"])
	var precip_type: String = "none"
	if precip_types.size() > 0:
		var precip_index: int = _rng.randi_range(0, precip_types.size() - 1)
		precip_type = precip_types[precip_index]

	var precip_intensity_range: Array = visibility_defaults.get("precipitation_intensity_range", [0.0, 0.0])
	var precip_intensity: float = _rand_range(precip_intensity_range)

	var allow_reveal_tool: bool = bool(visibility_defaults.get("allow_reveal_tool", false))

	# Difficulty scalars from archetype (optional)
	var diff: Dictionary = archetype.get("difficulty_scalars", {})
	var gravity_mult: float = float(diff.get("gravity_multiplier", 1.0))
	var wind_mult: float = float(diff.get("wind_strength_multiplier", 1.0))

	gravity_scale *= gravity_mult
	precip_intensity *= float(diff.get("visibility_penalty", 1.0))  # optional repurposing

	return {
		"gravity_scale": gravity_scale,
		"atmosphere": atmosphere,
		"wind_profile_id": wind_profile_id,
		"visibility": {
			"fog_type": fog_type,
			"fog_density": fog_density,
			"precipitation_type": precip_type,
			"precipitation_intensity": precip_intensity,
			"allow_reveal_tool": allow_reveal_tool
		},
		"physics_profile_id": physics_profile_id,
		"wind_strength_multiplier": wind_mult
	}


func _build_terrain(biome: Dictionary, archetype: Dictionary, tier: int) -> Dictionary:
	var defaults: Dictionary = biome.get("terrain_defaults", {})

	var generator_id: String = defaults.get("generator_id", "default_lunar")

	var length_range: Array = defaults.get("length_range", [3000.0, 4000.0])
	var length: float = _rand_range(length_range)

	var resolution: float = float(defaults.get("resolution", DEFAULT_TERRAIN_RESOLUTION))

	var lz_width_range: Array = defaults.get("landing_zone_width_range", [100.0, 140.0])
	var lz_width: float = _rand_range(lz_width_range)

	var lz_flatness_range: Array = defaults.get("landing_zone_flatness_range", [0.05, 0.2])
	var lz_flatness: float = _rand_range(lz_flatness_range)

	var hazard_defaults: Dictionary = defaults.get("hazards", {})
	var crater_density_range: Array = hazard_defaults.get("crater_density_range", [0.2, 0.5])
	var rock_density_range: Array = hazard_defaults.get("rock_density_range", [0.2, 0.5])

	var crater_density: float = _rand_range(crater_density_range)
	var rock_density: float = _rand_range(rock_density_range)

	var sharp_rocks_allowed: bool = bool(hazard_defaults.get("sharp_rocks_allowed", true))
	var steep_slopes_allowed: bool = bool(hazard_defaults.get("steep_slopes_allowed", true))

	var diff: Dictionary = archetype.get("difficulty_scalars", {})
	var hazard_mult: float = float(diff.get("hazard_multiplier", 1.0))

	crater_density *= hazard_mult
	rock_density *= hazard_mult

	# For now we generate one main landing zone in the center-ish region.
	var landing_zones: Array = []
	var lz: Dictionary = {
		"id": "LZ_0",
		"center_x": length * 0.5,
		"width": lz_width,
		"flatness": lz_flatness
	}
	landing_zones.append(lz)

	return {
		"generator_id": generator_id,
		"length": length,
		"resolution": resolution,
		"landing_zones": landing_zones,
		"hazards": {
			"crater_density": crater_density,
			"rock_density": rock_density,
			"sharp_rocks_allowed": sharp_rocks_allowed,
			"steep_slopes_allowed": steep_slopes_allowed
		}
	}


# -------------------------------------------------------------------
# Lander & Crew Setup
# -------------------------------------------------------------------

func _build_lander_setup(
		archetype: Dictionary,
		player_profile: Dictionary,
		is_training: bool
	) -> Dictionary:
	var all_landers: Array = DataManager.get_landers()  # Expect: Array[Dictionary]
	var unlocked_ids: Array = player_profile.get("unlocked_lander_ids", [])
	var rep: int = int(player_profile.get("reputation", 0))

	var required_categories: Array = archetype.get("required_lander_categories", [])
	var allowed_ids: Array = []

	# If player has no unlocked landers yet, allow at least the starter one (if present).
	var treat_unlocked_as_all := false
	if unlocked_ids.is_empty():
		treat_unlocked_as_all = true

	for l in all_landers:
		var lander_id: String = l.get("id", "")
		var category: String = l.get("category", "standard")
		var unlock_tier: int = int(l.get("unlock_tier", 0))
		var min_rep: int = int(l.get("min_reputation", 0))

		if not treat_unlocked_as_all:
			if not unlocked_ids.has(lander_id):
				continue

		# Reputation / tier gate:
		if rep < min_rep:
			continue

		# Category requirements:
		if required_categories.size() > 0:
			if not required_categories.has(category):
				continue

		allowed_ids.append(lander_id)

	# Fallback: if nothing matched, allow at least one
	if allowed_ids.is_empty():
		if treat_unlocked_as_all:
			for l in all_landers:
				var lid: String = l.get("id", "")
				if lid != "":
					allowed_ids.append(lid)
					break
		else:
			# pick first unlocked lander if any
			if unlocked_ids.size() > 0:
				allowed_ids.append(unlocked_ids[0])

	var required_lander_id := ""
	if required_categories.size() == 1 and allowed_ids.size() == 1:
		required_lander_id = allowed_ids[0]

	var fuel_cost_mode: String = "career"
	var fuel_cost_multiplier: float = 1.0
	if is_training:
		fuel_cost_mode = "free"
		fuel_cost_multiplier = 0.0

	return {
		"required_lander_id": required_lander_id,
		"allowed_lander_ids": allowed_ids,
		"fuel_cost_mode": fuel_cost_mode,
		"fuel_cost_multiplier": fuel_cost_multiplier
	}


func _build_crew_setup(archetype: Dictionary, player_profile: Dictionary) -> Dictionary:
	# Lightweight for now – define required roles; UI will choose specific crew.
	# Archetypes can later specify this more precisely.
	var required_roles: Array = archetype.get("required_crew_roles", ["pilot"])
	var recommended_roles: Array = archetype.get("recommended_crew_roles", [])

	return {
		"required_roles": required_roles,
		"recommended_roles": recommended_roles
	}


# -------------------------------------------------------------------
# Objectives
# -------------------------------------------------------------------

func _build_objectives(
		archetype: Dictionary,
		tier: int,
		terrain: Dictionary,
		is_training: bool
	) -> Dictionary:
	var objective_templates: Dictionary = archetype.get("objective_templates", {})
	var primary_ids: Array = objective_templates.get("primary", [])
	var bonus_ids: Array = objective_templates.get("bonus", [])

	var primary: Array = []
	var bonus: Array = []

	var landing_zones: Array = terrain.get("landing_zones", [])
	var default_lz_id: String = ""
	if landing_zones.size() > 0:
		default_lz_id = landing_zones[0].get("id", "LZ_0")

	for tid in primary_ids:
		var tmpl: Dictionary = DataManager.get_objective_template(tid)  # You will implement this.
		if tmpl.is_empty():
			continue
		var obj := _instantiate_objective(
			tid,
			tmpl,
			tier,
			default_lz_id,
			true
		)
		primary.append(obj)

	for tid in bonus_ids:
		var tmpl_b: Dictionary = DataManager.get_objective_template(tid)
		if tmpl_b.is_empty():
			continue
		var obj_b := _instantiate_objective(
			tid,
			tmpl_b,
			tier,
			default_lz_id,
			false
		)
		bonus.append(obj_b)

	return {
		"primary": primary,
		"bonus": bonus
	}


func _instantiate_objective(
		template_id: String,
		template_data: Dictionary,
		tier: int,
		default_lz_id: String,
		is_primary: bool
	) -> Dictionary:
	var obj_type: String = template_data.get("type", "")
	var params_def: Dictionary = template_data.get("params", {})
	var tier_scaling: Dictionary = template_data.get("tier_scaling", {})

	var params: Dictionary = {}

	match obj_type:
		"precision_landing":
			params = _build_precision_landing_params(params_def, tier, tier_scaling, default_lz_id)
		"return_to_orbit":
			params = _build_return_to_orbit_params(params_def, tier, tier_scaling)
		"fuel_remaining":
			params = _build_fuel_remaining_params(params_def, tier, tier_scaling)
		"time_under":
			params = _build_time_under_params(params_def, tier, tier_scaling)
		"no_damage":
			params = _build_no_damage_params(params_def)
		"landing_accuracy":
			params = _build_landing_accuracy_params(params_def, tier, tier_scaling)
		_:
			# Unknown type, pass through params_def as-is
			params = params_def.duplicate(true)

	# Ensure we have a unique objective id within mission.
	var uid: String = "%s_%d_%d" % [obj_type, tier, _rng.randi()]

	return {
		"id": uid,
		"template_id": template_id,
		"type": obj_type,
		"params": params,
		"is_primary": is_primary
	}


func _build_precision_landing_params(
		defs: Dictionary,
		tier: int,
		tier_scaling: Dictionary,
		default_lz_id: String
	) -> Dictionary:
	var max_vs: float = _rand_range(defs.get("max_vertical_speed_range", [3.0, 4.0]))
	var max_hs: float = _rand_range(defs.get("max_horizontal_speed_range", [2.0, 3.0]))
	var max_if: float = _rand_range(defs.get("max_impact_force_range", [0.6, 0.8]))
	var max_tilt: float = _rand_range(defs.get("max_tilt_deg_range", [10.0, 20.0]))
	var upright_dur: float = _rand_range(defs.get("upright_duration_range", [1.5, 3.0]))
	var require_in_lz: bool = bool(defs.get("require_in_lz", true))

	# Optional scaling.
	var tmin: int = int(tier_scaling.get("tier_min", 0))
	var tmax: int = int(tier_scaling.get("tier_max", 0))
	if tier >= tmin and tier <= tmax:
		var vs_factor: float = float(tier_scaling.get("vertical_speed_factor_per_tier", 0.0))
		var hs_factor: float = float(tier_scaling.get("horizontal_speed_factor_per_tier", 0.0))
		var tilt_factor: float = float(tier_scaling.get("tilt_factor_per_tier", 0.0))
		var tier_offset: int = tier - tmin

		if vs_factor != 0.0:
			max_vs += max_vs * vs_factor * tier_offset
		if hs_factor != 0.0:
			max_hs += max_hs * hs_factor * tier_offset
		if tilt_factor != 0.0:
			max_tilt += max_tilt * tilt_factor * tier_offset

		if max_vs < 0.5:
			max_vs = 0.5
		if max_hs < 0.5:
			max_hs = 0.5
		if max_tilt < 2.0:
			max_tilt = 2.0

	return {
		"target_lz_id": default_lz_id,
		"max_vertical_speed": max_vs,
		"max_horizontal_speed": max_hs,
		"max_impact_force": max_if,
		"max_tilt_deg": max_tilt,
		"must_remain_upright_seconds": upright_dur,
		"require_in_lz": require_in_lz
	}


func _build_return_to_orbit_params(
		defs: Dictionary,
		tier: int,
		tier_scaling: Dictionary
	) -> Dictionary:
	var min_alt: float = _rand_range(defs.get("min_altitude_range", [1400.0, 1800.0]))
	var max_time: float = _rand_range(defs.get("max_time_seconds_range", [90.0, 150.0]))

	var tmin: int = int(tier_scaling.get("tier_min", 0))
	var tmax: int = int(tier_scaling.get("tier_max", 0))
	if tier >= tmin and tier <= tmax:
		var time_factor: float = float(tier_scaling.get("time_factor_per_tier", 0.0))
		var tier_offset: int = tier - tmin
		if time_factor != 0.0:
			max_time += max_time * time_factor * tier_offset
			if max_time < 30.0:
				max_time = 30.0

	return {
		"min_altitude": min_alt,
		"max_time_seconds": max_time
	}


func _build_fuel_remaining_params(
		defs: Dictionary,
		tier: int,
		tier_scaling: Dictionary
	) -> Dictionary:
	var min_ratio: float = _rand_range(defs.get("min_fuel_ratio_range", [0.25, 0.35]))
	# You can add tier scaling later if needed.
	return {
		"min_fuel_ratio": min_ratio
	}


func _build_time_under_params(
		defs: Dictionary,
		tier: int,
		tier_scaling: Dictionary
	) -> Dictionary:
	var max_time: float = _rand_range(defs.get("max_time_seconds_range", [60.0, 120.0]))
	# Tier scaling optional; can be added as per return_to_orbit logic.
	return {
		"max_time_seconds": max_time
	}


func _build_no_damage_params(defs: Dictionary) -> Dictionary:
	var allow_minor: bool = bool(defs.get("allow_minor_damage", true))
	var max_ratio: float = float(defs.get("max_hull_damage_ratio", 0.1))
	return {
		"allow_minor_damage": allow_minor,
		"max_hull_damage_ratio": max_ratio
	}


func _build_landing_accuracy_params(
		defs: Dictionary,
		tier: int,
		tier_scaling: Dictionary
	) -> Dictionary:
	var max_offset: float = _rand_range(defs.get("max_offset_from_center_range", [12.0, 24.0]))
	return {
		"max_offset_from_center": max_offset
	}


# -------------------------------------------------------------------
# Failure Rules & Rewards
# -------------------------------------------------------------------

func _build_failure_rules(archetype: Dictionary, is_training: bool) -> Dictionary:
	var training_profile_id: String = ""
	if is_training:
		training_profile_id = "training_default"

	var hard_fail_on_player_death: bool = true
	var hard_fail_on_lander_destroyed: bool = true
	var allow_abort: bool = true
	var abort_counts_as_failure: bool = true

	# Archetype could override some of these in the future if needed.
	var time_limit_seconds: float = -1.0  # -1 = no global time limit

	return {
		"hard_fail_on_player_death": hard_fail_on_player_death,
		"hard_fail_on_lander_destroyed": hard_fail_on_lander_destroyed,
		"allow_abort": allow_abort,
		"abort_counts_as_failure": abort_counts_as_failure,
		"time_limit_seconds": time_limit_seconds,
		"training_crash_profile_id": training_profile_id
	}


func _build_rewards(archetype: Dictionary, tier: int) -> Dictionary:
	var reward_profile_id: String = archetype.get("reward_profile_id", "")
	if reward_profile_id == "":
		# Fallback profile
		reward_profile_id = "default_tier_%d" % tier

	var profile: Dictionary = DataManager.get_reward_profile(reward_profile_id)
	if profile.is_empty():
		# Simple default
		var base_rep: int = 2 + tier
		var base_funds: int = 200 * (tier + 1)
		return {
			"reputation": {
				"on_success": base_rep,
				"on_partial": base_rep / 2,
				"on_fail": -1
			},
			"funds": {
				"on_success": base_funds,
				"on_partial": base_funds / 2,
				"on_fail": 0
			},
			"unlock_tags": []
		}

	# Expect reward profile to already have the needed structure.
	return profile.duplicate(true)


# -------------------------------------------------------------------
# Misc Helpers
# -------------------------------------------------------------------

func _rand_range(range_array: Array) -> float:
	if range_array.size() == 0:
		return 0.0
	if range_array.size() == 1:
		return float(range_array[0])
	var lo: float = float(range_array[0])
	var hi: float = float(range_array[1])
	if hi < lo:
		var tmp := lo
		lo = hi
		hi = tmp
	return _rng.randf_range(lo, hi)


func _build_mission_id(archetype: Dictionary, biome: Dictionary, seed: int) -> String:
	var archetype_id: String = archetype.get("id", "arc")
	var biome_id: String = biome.get("id", "bio")
	return "%s_%s_%d" % [archetype_id, biome_id, seed]
