extends Control

var fps_label: RichTextLabel
var chunks_rendered_label: RichTextLabel
var chunks_loaded_per_frame_label: RichTextLabel
var render_distance_label: RichTextLabel
var render_distance_height_label: RichTextLabel
var chunk_size_label: RichTextLabel

func _ready() -> void:
	fps_label = $FPS_Text
	chunks_rendered_label = $ChunksRendered_Text
	chunks_loaded_per_frame_label = $ChunksLoadedPerFrame_Text
	render_distance_label = $RenderDistance_Text
	render_distance_height_label = $RenderDistanceHeight_Text
	chunk_size_label = $ChunkSize_Text

func _process(_delta: float) -> void:
	fps_label.text = "[color=lightgreen]" + str(Engine.get_frames_per_second()) + "[/color] FPS"

func set_initial_statistics_text(chunks_rendered: int, chunks_loaded_per_frame: int, render_distance: int, render_distance_height: int, chunk_size: int):
	chunks_rendered_label.text = "[color=lightgreen]" + str(chunks_rendered) + "[/color] amount of chunks rendered"
	chunks_loaded_per_frame_label.text = "[color=lightgreen]" + str(chunks_loaded_per_frame) + "[/color] amount of chunks loaded per frame"
	render_distance_label.text = "[color=lightgreen]" + str(render_distance) + "[/color] render distance (on x-axis and z-axis)"
	render_distance_height_label.text = "[color=lightgreen]" + str(render_distance_height) + "[/color] render distance (on y-axis)"
	chunk_size_label.text = "[color=lightgreen]" + str(chunk_size) + "[/color] m = chunksize"

func set_chunks_rendered(chunks_rendered: int):
	chunks_rendered_label.text = "[color=lightgreen]" + str(chunks_rendered) + "[/color] amount of chunks rendered"
