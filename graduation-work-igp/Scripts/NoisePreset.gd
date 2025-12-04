extends Resource
class_name NoisePreset

@export var preset_name: String = "Default"
@export var noise_type: FastNoiseLite.NoiseType = FastNoiseLite.TYPE_PERLIN
@export var fractal_type: FastNoiseLite.FractalType = FastNoiseLite.FRACTAL_FBM
@export var fractal_octaves: int = 3
@export var fractal_lacunarity: float = 2.0
@export var fractal_gain: float = 0.5
@export var frequency: float = 0.01

func apply_to_noise(noise: FastNoiseLite, custom_seed: int):
	noise.noise_type = noise_type
	noise.fractal_type = fractal_type
	noise.fractal_octaves = fractal_octaves
	noise.fractal_lacunarity = fractal_lacunarity
	noise.fractal_gain = fractal_gain
	noise.frequency = frequency
	noise.seed = custom_seed
