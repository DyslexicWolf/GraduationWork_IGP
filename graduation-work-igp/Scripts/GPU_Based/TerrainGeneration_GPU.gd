extends MeshInstance3D
class_name TerrainGeneration_GPU_ComputeNoise

enum NoiseType {
	PERLIN = 0,
	SIMPLEX = 1,
	CELLULAR = 2
}

var sync_time := 0.0
var async_time := 0.0

var rd = RenderingServer.create_local_rendering_device()
var marching_cubes_pipeline: RID
var marching_cubes_shader: RID
var global_buffers: Array
var global_uniform_set: RID

@export_category("General Settings")
@export var terrain_material: Material
@export var chunk_size: int
@export var chunks_to_load_per_frame: int
@export var iso_level: float

@export_category("Rendering Settings")
@export var flat_shaded: bool
@export var terrain_terrace: int
@export var render_distance: int
@export var render_distance_height: int

@export_category("Physics Settings")
@export var use_batch_colliders: bool = true

@export_category("Performance Settings")
@export var use_async_readback: bool = true
@export var use_threaded_mesh_finalization: bool = true
@export var amount_of_worker_threads: int = 2

var rendered_chunks: Dictionary = {}
var player: CharacterBody3D
var chunk_load_queue: Array = []
var chunk_index_counter: int = 0
var chunk_physics_bodies: Dictionary = {}
var pending_gpu_chunks: Array = []
var frames_since_gpu_submit: int = 0

# Threading variables
var mesh_finalization_thread_pool: Array[Thread] = []
var pending_mesh_tasks: Array = []
var pending_collision_tasks: Array = []
var task_mutex := Mutex.new()

signal set_statistics(chunks_rendered: int, chunks_loaded_per_frame: int, render_distance: int, render_distance_height: int, chunk_size: int)
signal set_chunks_rendered_text(chunks_rendered: int)
signal set_fog_settings(render_distance: int)

func _ready():
	player = $"../Player"
	
	# Initialize thread pool for mesh finalization
	if use_threaded_mesh_finalization:
		for i in range(amount_of_worker_threads):
			mesh_finalization_thread_pool.append(null)
	
	if not init_compute():
		push_error("Failed to initialize compute shader!")
		return
	
	setup_global_bindings()
	set_statistics.emit(0, chunks_to_load_per_frame, render_distance, render_distance_height, chunk_size)
	set_fog_settings.emit(render_distance)

func init_compute() -> bool:
	var shader_path = "res://Shaders/ComputeShaders/MarchingCubes.glsl"
	
	if not ResourceLoader.exists(shader_path):
		push_error("Shader file not found at: " + shader_path)
		return false
	
	var marching_cubes_shader_file = load(shader_path)
	if marching_cubes_shader_file == null:
		push_error("Failed to load shader file: " + shader_path)
		return false
	
	var marching_cubes_shader_spirv = marching_cubes_shader_file.get_spirv()
	if marching_cubes_shader_spirv == null:
		push_error("Failed to compile shader to SPIRV. Make sure the shader starts with #[compute]")
		return false
	
	marching_cubes_shader = rd.shader_create_from_spirv(marching_cubes_shader_spirv)
	if not marching_cubes_shader.is_valid():
		push_error("Failed to create shader from SPIRV")
		return false
	
	marching_cubes_pipeline = rd.compute_pipeline_create(marching_cubes_shader)
	if not marching_cubes_pipeline.is_valid():
		push_error("Failed to create compute pipeline")
		return false
	
	print("Compute shader initialized successfully!")
	return true

func setup_global_bindings():
	var input = get_global_params()
	var input_bytes = input.to_byte_array()
	global_buffers.push_back(rd.storage_buffer_create(input_bytes.size(), input_bytes))
	
	var input_params_uniform := RDUniform.new()
	input_params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_params_uniform.binding = 0
	input_params_uniform.add_id(global_buffers[0])
	
	var lut_array := PackedInt32Array()
	for i in range(GlobalConstants.LOOKUPTABLE.size()):
		lut_array.append_array(GlobalConstants.LOOKUPTABLE[i])
	var lut_array_bytes := lut_array.to_byte_array()
	global_buffers.push_back(rd.storage_buffer_create(lut_array_bytes.size(), lut_array_bytes))
	
	var lut_uniform := RDUniform.new()
	lut_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	lut_uniform.binding = 1
	lut_uniform.add_id(global_buffers[1])
	
	global_uniform_set = rd.uniform_set_create([input_params_uniform, lut_uniform], marching_cubes_shader, 0)

func _process(_delta):
	var player_chunk_x := int(player.position.x / chunk_size)
	var player_chunk_y := int(player.position.y / chunk_size)
	var player_chunk_z := int(player.position.z / chunk_size)
	chunk_load_queue.clear()
	
	for x in range(player_chunk_x - render_distance, player_chunk_x + render_distance + 1):
		for y in range(player_chunk_y - render_distance_height, player_chunk_y + render_distance_height + 1):
			for z in range(player_chunk_z - render_distance, player_chunk_z + render_distance + 1):
				var chunk_key := Vector3i(x, y, z)
				if not rendered_chunks.has(chunk_key):
					var chunk_pos := Vector3i(x, y, z)
					var player_chunk_pos := Vector3i(player_chunk_x, player_chunk_y, player_chunk_z)
					var distance := chunk_pos.distance_to(player_chunk_pos)
					chunk_load_queue.append({"key": chunk_key, "distance": distance, "pos": chunk_pos})
	
	chunk_load_queue.sort_custom(func(a, b): return a["distance"] < b["distance"])
	
	var chunks_this_frame = []
	for i in range(min(chunks_to_load_per_frame, chunk_load_queue.size())):
		var chunk_data = chunk_load_queue[i]
		var chunk_key: Vector3i = chunk_data["key"]
		var x = chunk_key.x
		var y = chunk_key.y
		var z = chunk_key.z
		
		var chunk_coords := Vector3(x, y, z)
		var data_buffer_rid := create_data_buffer(chunk_coords)
		var counter_buffer_rid := create_counter_buffer()
		var vertices_buffer_rid := create_vertices_buffer()
		var per_chunk_uniform_set := create_per_chunk_uniform_set(data_buffer_rid, counter_buffer_rid, vertices_buffer_rid)
		
		rendered_chunks[chunk_key] = null
		chunks_this_frame.append({
			"key": chunk_key,
			"x": x, "y": y, "z": z,
			"data_buffer": data_buffer_rid,
			"counter_buffer": counter_buffer_rid,
			"vertices_buffer": vertices_buffer_rid,
			"uniform_set": per_chunk_uniform_set
		})
	
	if chunks_this_frame.size() > 0:
		await process_chunk_batch(chunks_this_frame)
	
	if use_async_readback:
		if use_threaded_mesh_finalization:
			process_threaded_mesh_finalization()
		else:
			process_pending_gpu_chunks()
	
	# Process pending collisions
	process_pending_collisions()
	
	#unload chunks if needed
	for key: Vector3i in rendered_chunks.keys().duplicate():
		var chunk_x := key.x
		var chunk_y := key.y
		var chunk_z := key.z
		if abs(chunk_x - player_chunk_x) > render_distance or abs(chunk_y - player_chunk_y) > render_distance_height or abs(chunk_z - player_chunk_z) > render_distance:
			unload_chunk(chunk_x, chunk_y, chunk_z)
	set_chunks_rendered_text.emit(rendered_chunks.size())

func process_chunk_batch(chunks: Array):
	var start = Time.get_ticks_msec()
	var zero_counter := PackedInt32Array([0])
	var counter_bytes := zero_counter.to_byte_array()
	for chunk in chunks:
		rd.buffer_update(chunk["counter_buffer"], 0, counter_bytes.size(), counter_bytes)
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, marching_cubes_pipeline)
	var dispatch_size: int = int(float(chunk_size) / 8.0)
	for chunk in chunks:
		rd.compute_list_bind_uniform_set(compute_list, global_uniform_set, 0)
		rd.compute_list_bind_uniform_set(compute_list, chunk["uniform_set"], 1)
		rd.compute_list_dispatch(compute_list, dispatch_size, dispatch_size, dispatch_size)
	rd.compute_list_end()
	
	rd.submit()
	await get_tree().process_frame
	
	if use_async_readback:
		if use_threaded_mesh_finalization:
			# Queue chunks for threaded finalization instead of immediate processing
			task_mutex.lock()
			pending_mesh_tasks.append_array(chunks)
			task_mutex.unlock()
			frames_since_gpu_submit = 0
			async_time = Time.get_ticks_msec() - start
			print("Asynchronous chunk batch queued for threaded finalization in " + str(async_time) + " ms")
		else:
			pending_gpu_chunks.append_array(chunks)
			frames_since_gpu_submit = 0
			async_time = Time.get_ticks_msec() - start
			print("Asynchronous chunk batch submitted in " + str(async_time) + " ms")
	else:
		rd.sync()
		finalize_chunk_batch(chunks)
		sync_time = Time.get_ticks_msec() - start
		print("Synchronous chunk batch processed in " + str(sync_time) + " ms")

func process_threaded_mesh_finalization() -> void:
	"""Process mesh finalization using a thread pool"""
	if pending_mesh_tasks.is_empty():
		return
	
	# Check if we have chunks that need GPU data read
	var has_unread_chunks = false
	for chunk in pending_mesh_tasks:
		if not (chunk.has("gpu_data_read") and chunk["gpu_data_read"]):
			has_unread_chunks = true
			break
	
	# Only sync if we have unread GPU data
	if has_unread_chunks:
		rd.sync()
	
	# Read GPU buffers on main thread and queue for mesh building
	for i in range(pending_mesh_tasks.size()):
		var chunk = pending_mesh_tasks[i]
		
		# Skip if already has GPU data read
		if chunk.has("gpu_data_read") and chunk["gpu_data_read"]:
			continue
		
		# Read triangle count from GPU (render thread only)
		var total_triangles := rd.buffer_get_data(chunk["counter_buffer"]).to_int32_array()[0]
		
		if total_triangles == 0:
			chunk["total_triangles"] = 0
			chunk["gpu_data_read"] = true
			continue
		
		# Read vertex data from GPU (render thread only)
		var bytes_needed = total_triangles * 4 * 4 * 4
		var output_array := rd.buffer_get_data(chunk["vertices_buffer"], 0, bytes_needed).to_float32_array()
		
		chunk["total_triangles"] = total_triangles
		chunk["vertex_data"] = output_array
		chunk["gpu_data_read"] = true
	
	# Submit tasks to available threads for mesh building
	for i in range(pending_mesh_tasks.size()):
		var chunk = pending_mesh_tasks[i]
		
		if not chunk.get("gpu_data_read", false):
			continue  # GPU data not ready yet
		
		if chunk.has("thread") and chunk["thread"] != null:
			continue  # Already processing
		
		# Find available thread
		var thread_idx = find_available_mesh_thread()
		if thread_idx >= 0:
			var callable = Callable(self, "build_mesh_threaded").bind(
				chunk["total_triangles"],
				chunk.get("vertex_data", PackedFloat32Array()),
				chunk["key"]
			)
			var thread = Thread.new()
			chunk["thread"] = thread
			thread.start(callable)
			mesh_finalization_thread_pool[thread_idx] = chunk["thread"]
	
	# Collect completed tasks
	var completed_indices = []
	for i in range(pending_mesh_tasks.size()):
		var chunk = pending_mesh_tasks[i]
		
		if chunk.has("thread") and chunk["thread"] != null:
			if not chunk["thread"].is_alive():
				# Thread finished, get result
				var mesh_result = chunk["thread"].wait_to_finish()
				chunk["thread"] = null
				
				# Apply the finalized mesh on main thread
				if mesh_result != null:
					apply_finalized_mesh_with_mesh(chunk, mesh_result)
				
				completed_indices.append(i)
	
	# Remove completed tasks in reverse order to maintain indices
	for i in range(completed_indices.size() - 1, -1, -1):
		pending_mesh_tasks.remove_at(completed_indices[i])

func find_available_mesh_thread() -> int:
	"""Find an available thread slot in the pool"""
	for i in range(mesh_finalization_thread_pool.size()):
		if mesh_finalization_thread_pool[i] == null or not mesh_finalization_thread_pool[i].is_alive():
			return i
	return -1

func build_mesh_threaded(total_triangles: int, output_array: PackedFloat32Array, _chunk_key: Vector3i) -> Dictionary:
	"""Runs on worker thread - builds mesh from vertex data"""
	if total_triangles == 0:
		return {}
	
	# Build mesh data structure on thread (safe operation)
	var output = {
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
	}
	
	for i in range(0, total_triangles * 16, 16):
		output["vertices"].push_back(Vector3(output_array[i + 0], output_array[i + 1], output_array[i + 2]))
		output["vertices"].push_back(Vector3(output_array[i + 4], output_array[i + 5], output_array[i + 6]))
		output["vertices"].push_back(Vector3(output_array[i + 8], output_array[i + 9], output_array[i + 10]))
		
		var normal := Vector3(output_array[i + 12], output_array[i + 13], output_array[i + 14])
		for j in range(3):
			output["normals"].push_back(normal)
	
	# Store processed data (mesh creation happens on main thread)
	return {
		"vertices": output["vertices"],
		"normals": output["normals"]
	}

func apply_finalized_mesh_with_mesh(chunk: Dictionary, mesh_data: Dictionary) -> void:
	"""Apply mesh built on worker thread to scene"""
	var total_triangles = chunk.get("total_triangles", 0)
	
	if total_triangles == 0:
		safe_free_rid(chunk["data_buffer"])
		safe_free_rid(chunk["counter_buffer"])
		safe_free_rid(chunk["vertices_buffer"])
		print("Didn't load chunk: " + str(chunk["key"]) + " because it is empty")
		return
	
	# Build the actual mesh on main thread
	var chunk_mesh := build_mesh_from_thread_data(mesh_data)
	
	print("Loaded chunk: " + str(chunk["key"]))
	var chunk_instance := MeshInstance3D.new()
	chunk_instance.mesh = chunk_mesh
	chunk_instance.position = Vector3(chunk["x"], chunk["y"], chunk["z"]) * float(chunk_size)
	
	if chunk_mesh.get_surface_count() > 0:
		if use_batch_colliders:
			queue_collision_creation(chunk_instance, chunk["key"])
		else:
			chunk_instance.create_trimesh_collision()
	
	add_child(chunk_instance)
	
	rendered_chunks[chunk["key"]] = {
		"mesh_node": chunk_instance,
		"data_buffer": chunk["data_buffer"],
		"counter_buffer": chunk["counter_buffer"],
		"vertices_buffer": chunk["vertices_buffer"],
		"per_chunk_uniform_set": chunk["uniform_set"]
	}

func build_mesh_from_thread_data(mesh_data: Dictionary) -> Mesh:
	"""Create ArrayMesh from thread-processed data on main thread"""
	var vertices = mesh_data.get("vertices", PackedVector3Array())
	var normals = mesh_data.get("normals", PackedVector3Array())
	
	var array_mesh_data := []
	array_mesh_data.resize(Mesh.ARRAY_MAX)
	array_mesh_data[Mesh.ARRAY_VERTEX] = vertices
	array_mesh_data[Mesh.ARRAY_NORMAL] = normals
	
	var array_mesh := ArrayMesh.new()
	array_mesh.clear_surfaces()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, array_mesh_data)
	array_mesh.surface_set_material(0, terrain_material)
	
	return array_mesh

func apply_finalized_mesh(task: Dictionary) -> void:
	"""Apply finalized mesh on main thread"""
	var chunk = task
	var mesh_data = chunk.get("mesh_data", {})
	var total_triangles = mesh_data.get("total_triangles", 0)
	
	if total_triangles == 0:
		if rendered_chunks.has(chunk["key"]):
			safe_free_rid(chunk["data_buffer"])
			safe_free_rid(chunk["counter_buffer"])
			safe_free_rid(chunk["vertices_buffer"])
			print("Didn't load chunk: " + str(chunk["key"]) + " because it is empty")
		return
	
	var output_array = mesh_data.get("vertices", PackedFloat32Array())
	var chunk_mesh := build_mesh_from_compute_data(total_triangles, output_array)
	
	print("Loaded chunk: " + str(chunk["key"]))
	var chunk_instance := MeshInstance3D.new()
	chunk_instance.mesh = chunk_mesh
	chunk_instance.position = Vector3(chunk["x"], chunk["y"], chunk["z"]) * float(chunk_size)
	
	if chunk_mesh.get_surface_count() > 0:
		if use_batch_colliders:
			# Queue collision creation asynchronously
			queue_collision_creation(chunk_instance, chunk["key"])
		else:
			chunk_instance.create_trimesh_collision()
	
	add_child(chunk_instance)
	
	rendered_chunks[chunk["key"]] = {
		"mesh_node": chunk_instance,
		"data_buffer": chunk["data_buffer"],
		"counter_buffer": chunk["counter_buffer"],
		"vertices_buffer": chunk["vertices_buffer"],
		"per_chunk_uniform_set": chunk["uniform_set"]
	}

func process_pending_gpu_chunks() -> void:
	if pending_gpu_chunks.is_empty():
		return
	
	frames_since_gpu_submit += 1
	
	if frames_since_gpu_submit < 1:
		return
	
	rd.sync()
	
	finalize_chunk_batch(pending_gpu_chunks)
	pending_gpu_chunks.clear()

func finalize_chunk_batch(chunks: Array) -> void:
	for chunk in chunks:
		var total_triangles := rd.buffer_get_data(chunk["counter_buffer"]).to_int32_array()[0]
		
		if total_triangles == 0:
			safe_free_rid(chunk["data_buffer"])
			safe_free_rid(chunk["counter_buffer"])
			safe_free_rid(chunk["vertices_buffer"])
			print("Didn't load chunk: " + str(chunk["key"]) + " because it is empty")
			continue
		
		var bytes_needed = total_triangles * 4 * 4 * 4  # 4 vec4s per triangle, 4 bytes per float
		var output_array := rd.buffer_get_data(chunk["vertices_buffer"], 0, bytes_needed).to_float32_array()
		var chunk_mesh := build_mesh_from_compute_data(total_triangles, output_array)
		
		print("Loaded chunk: " + str(chunk["key"]))
		var chunk_instance := MeshInstance3D.new()
		chunk_instance.mesh = chunk_mesh
		chunk_instance.position = Vector3(chunk["x"], chunk["y"], chunk["z"]) * float(chunk_size)
		
		if chunk_mesh.get_surface_count() > 0:
			if use_batch_colliders:
				create_batch_collider(chunk_instance, chunk["key"])
			else:
				chunk_instance.create_trimesh_collision()
		add_child(chunk_instance)
		
		rendered_chunks[chunk["key"]] = {
			"mesh_node": chunk_instance,
			"data_buffer": chunk["data_buffer"],
			"counter_buffer": chunk["counter_buffer"],
			"vertices_buffer": chunk["vertices_buffer"],
			"per_chunk_uniform_set": chunk["uniform_set"]
		}

func build_mesh_from_compute_data(total_triangles: int, output_array: PackedFloat32Array) -> Mesh:
	var output = {
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
	}
	
	for i in range(0, total_triangles * 16, 16):
		output["vertices"].push_back(Vector3(output_array[i + 0], output_array[i + 1], output_array[i + 2]))
		output["vertices"].push_back(Vector3(output_array[i + 4], output_array[i + 5], output_array[i + 6]))
		output["vertices"].push_back(Vector3(output_array[i + 8], output_array[i + 9], output_array[i + 10]))
		
		var normal := Vector3(output_array[i + 12], output_array[i + 13], output_array[i + 14])
		for j in range(3):
			output["normals"].push_back(normal)
	
	var mesh_data := []
	mesh_data.resize(Mesh.ARRAY_MAX)
	mesh_data[Mesh.ARRAY_VERTEX] = output["vertices"]
	mesh_data[Mesh.ARRAY_NORMAL] = output["normals"]
	
	var array_mesh := ArrayMesh.new()
	array_mesh.clear_surfaces()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_data)
	array_mesh.surface_set_material(0, terrain_material)
	
	return array_mesh

func create_data_buffer(chunk_coords: Vector3) -> RID:
	var data = get_per_chunk_params(chunk_coords)
	var data_bytes = data.to_byte_array()
	var buffer_rid := rd.storage_buffer_create(data_bytes.size(), data_bytes)
	
	assert(buffer_rid != null, "Data_buffer_rid should never be null")
	return buffer_rid

func create_counter_buffer() -> RID:
	var counter_bytes := PackedInt32Array([0]).to_byte_array()
	var buffer_rid := rd.storage_buffer_create(counter_bytes.size(), counter_bytes)
	
	assert(buffer_rid != null, "Counter_buffer_rid should never be null")
	return buffer_rid

func create_vertices_buffer() -> RID:
	var total_cells := chunk_size * chunk_size * chunk_size
	var vertices := PackedColorArray()
	vertices.resize(total_cells * 5 * 4)
	var vertices_bytes := vertices.to_byte_array()
	var buffer_rid := rd.storage_buffer_create(vertices_bytes.size(), vertices_bytes)
	
	assert(buffer_rid != null, "Vertices_buffer_rid should never be null")
	return buffer_rid

func create_per_chunk_uniform_set(data_buffer_rid: RID, counter_buffer_rid: RID, vertices_buffer_rid: RID) -> RID:
	var data_uniform := RDUniform.new()
	data_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	data_uniform.binding = 0
	data_uniform.add_id(data_buffer_rid)
	
	var counter_uniform := RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 1
	counter_uniform.add_id(counter_buffer_rid)
	
	var vertices_uniform := RDUniform.new()
	vertices_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertices_uniform.binding = 2
	vertices_uniform.add_id(vertices_buffer_rid)
	
	return rd.uniform_set_create([data_uniform, counter_uniform, vertices_uniform], marching_cubes_shader, 1)

func unload_chunk(x: int, y: int, z: int):
	var chunk_key := Vector3i(x, y, z)
	if rendered_chunks.has(chunk_key):
		if rendered_chunks[chunk_key] == null:
			rendered_chunks.erase(chunk_key)
			return
		
		var chunk_data = rendered_chunks[chunk_key]
		
		safe_free_rid(chunk_data["per_chunk_uniform_set"])
		safe_free_rid(chunk_data["data_buffer"])
		safe_free_rid(chunk_data["counter_buffer"])
		safe_free_rid(chunk_data["vertices_buffer"])
		
		chunk_data["mesh_node"].queue_free()
		
		if use_batch_colliders and chunk_physics_bodies.has(chunk_key):
			chunk_physics_bodies[chunk_key].queue_free()
			chunk_physics_bodies.erase(chunk_key)
		
		rendered_chunks.erase(chunk_key)
		print("Unloaded chunk: " + str(chunk_key))

func get_global_params():
	var params := PackedFloat32Array()
	#grid size
	params.append_array([chunk_size + 1, chunk_size + 1, chunk_size + 1])
	
	params.append(iso_level)
	#1 == true, 0 == false
	params.append(float(flat_shaded))
	params.append(NoiseConfig.noise_frequency)
	params.append(float(NoiseConfig.fractal_octaves))
	#1 == true, 0 == false
	params.append(float(terrain_terrace))
	
	#0=Perlin, 1=Simplex, 2=Cellular
	params.append(float(NoiseConfig.noise_type))
	params.append(NoiseConfig.fractal_gain)
	params.append(NoiseConfig.fractal_lacunarity)
	params.append(NoiseConfig.cellular_jitter)
	
	return params

func get_per_chunk_params(chunk_coords: Vector3):
	var params := PackedFloat32Array()
	params.append_array([chunk_coords.x, chunk_coords.y, chunk_coords.z])
	params.append(float(chunk_size))
	
	return params

func queue_collision_creation(mesh_instance: MeshInstance3D, chunk_key: Vector3i) -> void:
	"""Queue collision creation without blocking"""
	task_mutex.lock()
	pending_collision_tasks.append({
		"mesh_instance": mesh_instance,
		"chunk_key": chunk_key,
		"thread": null,
		"completed": false
	})
	task_mutex.unlock()

func process_pending_collisions() -> void:
	"""Process collision creation for completed tasks"""
	if pending_collision_tasks.is_empty():
		return
	
	var completed_indices = []
	
	for i in range(pending_collision_tasks.size()):
		var task = pending_collision_tasks[i]
		
		# If thread hasn't been started yet, start it
		if task["thread"] == null and not task["completed"]:
			var callable = Callable(self, "create_collision_shape_threaded").bind(
				task["mesh_instance"].mesh,
				task["chunk_key"]
			)
			var thread = Thread.new()
			task["thread"] = thread
			thread.start(callable)
		
		# Check if thread is done
		if task["thread"] != null and not task["thread"].is_alive():
			if not task["completed"]:
				task["thread"].wait_to_finish()  # Ensure thread completes
				# Validate mesh_instance is still valid before using
				if is_instance_valid(task["mesh_instance"]):
					create_batch_collider(task["mesh_instance"], task["chunk_key"])
				task["completed"] = true
				completed_indices.append(i)
	
	# Remove completed tasks
	for i in range(completed_indices.size() - 1, -1, -1):
		pending_collision_tasks.remove_at(completed_indices[i])

func create_collision_shape_threaded(_mesh: Mesh, _chunk_key: Vector3i) -> bool:
	"""Prepare collision data on worker thread"""
	# This function runs on a worker thread and prepares the collision shape
	# The actual collision application happens on the main thread
	return true

func create_batch_collider(mesh_instance: MeshInstance3D, chunk_key: Vector3i) -> void:
	var static_body := StaticBody3D.new()
	static_body.position = mesh_instance.position
	
	var collision_shape := CollisionShape3D.new()
	var shape: Shape3D = mesh_instance.mesh.create_trimesh_shape()
	collision_shape.shape = shape
	
	static_body.add_child(collision_shape)
	add_child(static_body)
	
	chunk_physics_bodies[chunk_key] = static_body

func safe_free_rid(rid: RID):
	if rid.is_valid():
		rd.free_rid(rid)

func _notification(type):
	if type == NOTIFICATION_PREDELETE:
		release()

func release():
	# Clean up mesh finalization threads and their RIDs
	for task in pending_mesh_tasks:
		if task.has("thread") and task["thread"] != null and task["thread"].is_alive():
			task["thread"].wait_to_finish()
		# Free GPU buffers from pending tasks
		safe_free_rid(task.get("data_buffer", RID()))
		safe_free_rid(task.get("counter_buffer", RID()))
		safe_free_rid(task.get("vertices_buffer", RID()))
		safe_free_rid(task.get("uniform_set", RID()))
	pending_mesh_tasks.clear()
	
	# Clean up collision threads
	for task in pending_collision_tasks:
		if task.has("thread") and task["thread"] != null and task["thread"].is_alive():
			task["thread"].wait_to_finish()
	pending_collision_tasks.clear()
	
	# Clean up thread pool
	for thread in mesh_finalization_thread_pool:
		if thread != null and thread.is_alive():
			thread.wait_to_finish()
	mesh_finalization_thread_pool.clear()
	
	if not pending_gpu_chunks.is_empty():
		rd.sync()
		for chunk in pending_gpu_chunks:
			safe_free_rid(chunk["data_buffer"])
			safe_free_rid(chunk["counter_buffer"])
			safe_free_rid(chunk["vertices_buffer"])
			safe_free_rid(chunk["uniform_set"])
		pending_gpu_chunks.clear()
	
	safe_free_rid(global_uniform_set)
	for buffers in global_buffers:
		safe_free_rid(buffers)
	global_buffers.clear()
	
	safe_free_rid(marching_cubes_pipeline)
	safe_free_rid(marching_cubes_shader)
	
	#only free if you made a rendering device yourself
	rd.free()
