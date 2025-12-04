extends Control

# Define presets directly in code
var current_preset_index: int = 0

@export var presets: Array[NoisePreset] = []
@onready var preset_name_label: Label = $VBoxContainer/PresetName
@onready var seed_entry_field: SpinBox = $VBoxContainer/SeedContainer/SeedEntryField
@onready var frequency_slider: HSlider = $VBoxContainer/FrequencyContainer/FrequencySlider
@onready var frequency_label: Label = $VBoxContainer/FrequencyContainer/FrequencyValue

func _ready() -> void:
	if presets.is_empty():
		push_error("No presets assigned!!!")
		return
	
	NoiseSettings.custom_frequency = presets[0].frequency
	_update_ui()

func _update_ui() -> void:
	var preset = presets[current_preset_index]
	preset_name_label.text = preset.preset_name
	seed_entry_field.value = NoiseSettings.custom_seed
	
	if frequency_slider.value == 0:
		NoiseSettings.custom_frequency = preset.frequency
	
	frequency_slider.value = preset.frequency * 1000.0  #scale for slider
	frequency_label.text = str(preset.frequency)

func _on_prev_button_pressed() -> void:
	current_preset_index = (current_preset_index - 1 + presets.size()) % presets.size()
	NoiseSettings.custom_frequency = presets[current_preset_index].frequency
	_update_ui()

func _on_next_button_pressed() -> void:
	current_preset_index = (current_preset_index + 1) % presets.size()
	NoiseSettings.custom_frequency = presets[current_preset_index].frequency
	_update_ui()

func _on_seed_changed(value: float) -> void:
	NoiseSettings.custom_seed = int(value)

func _on_frequency_changed(value: float) -> void:
	NoiseSettings.custom_frequency = value / 1000.0
	frequency_label.text = "%.3f" % NoiseSettings.custom_frequency

func _on_random_seed_pressed() -> void:
	seed_entry_field.value = randi() % 100000

func _on_start_game_pressed() -> void:
	NoiseSettings.selected_preset = presets[current_preset_index]
	get_tree().change_scene_to_file("res://Scenes/MarchingCubes_GPU.tscn")
