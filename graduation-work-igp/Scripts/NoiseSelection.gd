extends Control

enum UI_State{
	UNDECIDED,
	PRESET,
	CUSTOM
}

var current_preset_index: int
var current_custom_noise_type_index: int
var amount_of_noise_types: int
var ui_state: UI_State

@onready var undecided_vbox_container: VBoxContainer = $Undecided_VBoxContainer

@export var presets: Array[NoisePreset] = []
@onready var preset_vbox_container: VBoxContainer = $Preset_VBoxContainer
@onready var preset_name_label: Label = $Preset_VBoxContainer/PresetNameText

@onready var custom_vbox_container: VBoxContainer = $Custom_VBoxContainer
@onready var noise_type_label: Label = $Custom_VBoxContainer/NoiseTypeContainer/NoiseTypeText
@onready var seed_entry_field: SpinBox = $Custom_VBoxContainer/SeedContainer/SeedEntryField
@onready var frequency_entry_field: SpinBox = $Custom_VBoxContainer/FrequencyContainer/FrequencyEntryField
@onready var octaves_entry_field: SpinBox = $Custom_VBoxContainer/OctavesContainer/OctavesEntryField
@onready var gain_entry_field: SpinBox = $Custom_VBoxContainer/GainContainer/GainEntryField
@onready var lacunarity_entry_field: SpinBox = $Custom_VBoxContainer/LacunarityContainer/LacunarityEntryField
@onready var cellular_jitter_entry_field: SpinBox = $Custom_VBoxContainer/CellularJitterContainer/CellularJitterEntryField


func _ready() -> void:
	if presets.is_empty():
		push_error("No presets assigned!!!")
		return
	
	current_preset_index = 0
	current_custom_noise_type_index = 0
	amount_of_noise_types = 3
	ui_state = UI_State.UNDECIDED
	
	seed_entry_field.max_value = 10000
	frequency_entry_field.max_value = 1
	octaves_entry_field.max_value = 12
	gain_entry_field.max_value = 1
	lacunarity_entry_field.max_value = 5
	cellular_jitter_entry_field.max_value = 1
	update_ui()

func update_ui() -> void:
	match ui_state:
		UI_State.UNDECIDED:
			undecided_vbox_container.visible = true
			preset_vbox_container.visible = false
			custom_vbox_container.visible = false
		
		UI_State.PRESET:
			undecided_vbox_container.visible = false
			preset_vbox_container.visible = true
			custom_vbox_container.visible = false
			
			var preset = presets[current_preset_index]
			preset_name_label.text = preset.preset_name
		
		UI_State.CUSTOM:
			undecided_vbox_container.visible = false
			preset_vbox_container.visible = false
			custom_vbox_container.visible = true

func on_noise_type_prev_button_pressed() -> void:
	current_custom_noise_type_index = (current_custom_noise_type_index - 1 + amount_of_noise_types) % amount_of_noise_types
	NoiseConfig.noise_type = current_custom_noise_type_index
	var noise_type_name: String
	if current_custom_noise_type_index == 0:
		noise_type_name = "Perlin"
	elif current_custom_noise_type_index == 1:
		noise_type_name = "Simplex"
	else:
		noise_type_name = "Cellular"
	
	noise_type_label.text = "NoiseType: " + noise_type_name

func on_noise_type_next_button_pressed() -> void:
	current_custom_noise_type_index = (current_custom_noise_type_index + 1) % amount_of_noise_types
	NoiseConfig.noise_type = current_custom_noise_type_index
	var noise_type_name: String
	if current_custom_noise_type_index == 0:
		noise_type_name = "Perlin"
	elif current_custom_noise_type_index == 1:
		noise_type_name = "Simplex"
	else:
		noise_type_name = "Cellular"
	
	noise_type_label.text = "NoiseType: " + noise_type_name

func on_seed_changed(value: float) -> void:
	NoiseConfig.noise_seed = int(value)

##still BIG issues with this random seed, doesnt work!!!
func on_random_seed_pressed() -> void:
	seed_entry_field.value = randi() % 10000

func on_frequency_changed(value: float) -> void:
	NoiseConfig.noise_frequency = value

func on_octaves_changed(value: float) -> void:
	NoiseConfig.fractal_octaves = int(value)

func on_gain_changed(value: float) -> void:
	NoiseConfig.fractal_gain = value

func on_lacunarity_changed(value: float) -> void:
	NoiseConfig.fractal_lacunarity = value

func on_cellular_jitter_changed(value: float) -> void:
	NoiseConfig.cellular_jitter = value

func on_preset_prev_button_pressed() -> void:
	current_preset_index = (current_preset_index - 1 + presets.size()) % presets.size()
	NoiseConfig.noise_type = presets[current_preset_index].noise_type
	NoiseConfig.noise_seed = presets[current_preset_index].noise_seed
	NoiseConfig.noise_frequency = presets[current_preset_index].noise_frequency
	NoiseConfig.fractal_octaves = presets[current_preset_index].fractal_octaves
	NoiseConfig.fractal_gain = presets[current_preset_index].fractal_gain
	NoiseConfig.fractal_lacunarity = presets[current_preset_index].fractal_lacunarity
	NoiseConfig.cellular_jitter = presets[current_preset_index].cellular_jitter
	update_ui()

func on_preset_next_button_pressed() -> void:
	current_preset_index = (current_preset_index + 1) % presets.size()
	NoiseConfig.noise_type = presets[current_preset_index].noise_type
	NoiseConfig.noise_seed = presets[current_preset_index].noise_seed
	NoiseConfig.noise_frequency = presets[current_preset_index].noise_frequency
	NoiseConfig.fractal_octaves = presets[current_preset_index].fractal_octaves
	NoiseConfig.fractal_gain = presets[current_preset_index].fractal_gain
	NoiseConfig.fractal_lacunarity = presets[current_preset_index].fractal_lacunarity
	NoiseConfig.cellular_jitter = presets[current_preset_index].cellular_jitter
	update_ui()

func on_preset_button_pressed() -> void:
	ui_state = UI_State.PRESET
	update_ui()

func on_custom_button_pressed() -> void:
	ui_state = UI_State.CUSTOM
	update_ui()

func on_back_button_pressed() -> void:
	ui_state = UI_State.UNDECIDED
	update_ui()

func on_start_game_pressed() -> void:
	#NoiseSettings.selected_preset = presets[current_preset_index]
	get_tree().change_scene_to_file("res://Scenes/MarchingCubes_GPU.tscn")
