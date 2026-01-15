extends Node

@export var noise_type: int = 2
@export var noise_seed: int = 1337
@export var noise_frequency: float = 0.02
@export var fractal_octaves: int = 5
@export var fractal_gain: float = 0.4
@export var fractal_lacunarity: float = 2.0
@export_range(0.0, 1.0) var cellular_jitter: float = 1.0
