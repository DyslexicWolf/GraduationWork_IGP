extends Control

var fps_label: RichTextLabel
var time_label: RichTextLabel
var chunks_rendered_label: RichTextLabel
var chunks_loaded_per_frame_label: RichTextLabel
var render_distance_label: RichTextLabel
var render_distance_height_label: RichTextLabel
var chunk_size_label: RichTextLabel
var worker_threads_label: RichTextLabel

func _ready() -> void:
	fps_label = $VBoxContainer/FPS_Text
	time_label = $VBoxContainer/Time_Text
	chunks_rendered_label = $VBoxContainer/ChunksRendered_Text
	chunks_loaded_per_frame_label = $VBoxContainer/ChunksLoadedPerFrame_Text
	render_distance_label = $VBoxContainer/RenderDistance_Text
	render_distance_height_label = $VBoxContainer/RenderDistanceHeight_Text
	chunk_size_label = $VBoxContainer/ChunkSize_Text
	worker_threads_label = $VBoxContainer/WorkerThreads_Text

func _process(_delta: float) -> void:
	fps_label.text = "[color=lightgreen]" + str(Engine.get_frames_per_second()) + "[/color] FPS"
	time_label.text = "[color=lightgreen]" + str(Time.get_ticks_msec() / 1000) + "[/color] seconds passed"

func set_initial_statistics_text(chunks_rendered: int, chunks_loaded_per_frame: int, render_distance: int, render_distance_height: int, chunk_size: int, amount_of_worker_threads: int):
	chunks_rendered_label.text = "[color=lightgreen]" + str(chunks_rendered) + "[/color] chunks rendered"
	chunks_loaded_per_frame_label.text = "[color=lightgreen]" + str(chunks_loaded_per_frame) + "[/color] chunks loaded per frame"
	render_distance_label.text = "[color=lightgreen]" + str(render_distance) + "[/color] chunks render distance (x-axis and z-axis)"
	render_distance_height_label.text = "[color=lightgreen]" + str(render_distance_height) + "[/color] chunks render distance (y-axis)"
	chunk_size_label.text = "[color=lightgreen]" + str(chunk_size) + "[/color]m chunksize"
	worker_threads_label.text = "[color=lightgreen]" + str(amount_of_worker_threads) + "[/color] WorkerThreads"

func set_chunks_rendered(chunks_rendered: int):
	chunks_rendered_label.text = "[color=lightgreen]" + str(chunks_rendered) + "[/color] chunks rendered"
