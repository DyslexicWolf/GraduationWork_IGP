extends Node

var selected_preset: NoisePreset
var custom_seed: int = 1337
var custom_frequency: float = 0.01

func get_configured_noise() -> FastNoiseLite:
	var noise = FastNoiseLite.new()
	if selected_preset:
		selected_preset.apply_to_noise(noise, custom_seed)
		noise.frequency = custom_frequency
	return noise
