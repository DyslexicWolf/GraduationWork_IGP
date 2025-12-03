extends MeshInstance3D
class_name TerrainGeneration_GPU

var rd = RenderingServer.create_local_rendering_device()
var marching_cubes_pipeline: RID
var marching_cubes_shader: RID
var global_buffers: Array
var global_uniform_set: RID

@export var terrain_material: Material
@export var chunk_size: int
@export var chunks_to_load_per_frame: int
@export var iso_level: float
@export var noise: FastNoiseLite
@export var flat_shaded: bool
@export var terrain_terrace: int
@export var render_distance: int
@export var render_distance_height: int

var loaded_chunks: Dictionary = {}
var player: CharacterBody3D
var chunk_load_queue: Array = []

func _ready():
	player = $"../Player"
	
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.01
	noise.cellular_jitter = 0
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	noise.domain_warp_fractal_octaves = 1
	
	init_compute()
	setup_global_bindings()

func init_compute():
	#create shader and pipeline for marching cubes and noise generation
	var marching_cubes_shader_file = load("res://Shaders/ComputeShaders/MarchingCubes.glsl")
	var marching_cubes_shader_spirv = marching_cubes_shader_file.get_spirv()
	marching_cubes_shader = rd.shader_create_from_spirv(marching_cubes_shader_spirv)
	marching_cubes_pipeline = rd.compute_pipeline_create(marching_cubes_shader)

func setup_global_bindings():
	#create the globalparams buffer
	var input = get_global_params()
	var input_bytes = input.to_byte_array()
	global_buffers.push_back(rd.storage_buffer_create(input_bytes.size(), input_bytes))
	
	var input_params_uniform := RDUniform.new()
	input_params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_params_uniform.binding = 0
	input_params_uniform.add_id(global_buffers[0])
	
	#create the lookuptable buffer
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
	print("fps = " + str(Engine.get_frames_per_second()))
	var player_chunk_x := int(player.position.x / chunk_size)
	var player_chunk_y := int(player.position.y / chunk_size)
	var player_chunk_z := int(player.position.z / chunk_size)
	chunk_load_queue.clear()
	
	for x in range(player_chunk_x - render_distance, player_chunk_x + render_distance + 1):
		for y in range(player_chunk_y - render_distance_height, player_chunk_y + render_distance_height + 1):
			for z in range(player_chunk_z - render_distance, player_chunk_z + render_distance + 1):
				var chunk_key := str(x) + "," + str(y) + "," + str(z)
				if not loaded_chunks.has(chunk_key):
					var chunk_pos := Vector3(x, y, z)
					var player_chunk_pos := Vector3(player_chunk_x, player_chunk_y, player_chunk_z)
					var distance := chunk_pos.distance_to(player_chunk_pos)
					chunk_load_queue.append({"key": chunk_key, "distance": distance, "pos": chunk_pos})
	
	chunk_load_queue.sort_custom(func(a, b): return a["distance"] < b["distance"])
	
	#prepare all the chunks to load this frame
	var chunks_this_frame = []
	for i in range(min(chunks_to_load_per_frame, chunk_load_queue.size())):
		var chunk_data = chunk_load_queue[i]
		var x = int(chunk_data["pos"].x)
		var y = int(chunk_data["pos"].y)
		var z = int(chunk_data["pos"].z)
		var chunk_key := str(x) + "," + str(y) + "," + str(z)
		
		var chunk_coords := Vector3(x, y, z)
		var data_buffer_rid := create_data_buffer(chunk_coords)
		var counter_buffer_rid := create_counter_buffer()
		var vertices_buffer_rid := create_vertices_buffer()
		var per_chunk_uniform_set := create_per_chunk_uniform_set(data_buffer_rid, counter_buffer_rid, vertices_buffer_rid)
		
		loaded_chunks[chunk_key] = null
		chunks_this_frame.append({
			"key": chunk_key,
			"x": x, "y": y, "z": z,
			"data_buffer": data_buffer_rid,
			"counter_buffer": counter_buffer_rid,
			"vertices_buffer": vertices_buffer_rid,
			"uniform_set": per_chunk_uniform_set
		})
	
	#process all chunks to be loaded in one batch
	if chunks_this_frame.size() > 0:
		await process_chunk_batch(chunks_this_frame)
	
	#unload chunks when needed
	for key in loaded_chunks.keys().duplicate():
		var coords = key.split(",")
		var chunk_x := int(coords[0])
		var chunk_y := int(coords[1])
		var chunk_z := int(coords[2])
		if abs(chunk_x - player_chunk_x) > render_distance or abs(chunk_y - player_chunk_y) > render_distance_height or abs(chunk_z - player_chunk_z) > render_distance:
			unload_chunk(chunk_x, chunk_y, chunk_z)

func process_chunk_batch(chunks: Array):
	#reset all counter buffers
	var zero_counter := PackedInt32Array([0])
	var counter_bytes := zero_counter.to_byte_array()
	for chunk in chunks:
		rd.buffer_update(chunk["counter_buffer"], 0, counter_bytes.size(), counter_bytes)
	
	#submit all compute operations in one compute list, dispatch per chunk
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, marching_cubes_pipeline)
	for chunk in chunks:
		rd.compute_list_bind_uniform_set(compute_list, global_uniform_set, 0)
		rd.compute_list_bind_uniform_set(compute_list, chunk["uniform_set"], 1)
		rd.compute_list_dispatch(compute_list, chunk_size / 8, chunk_size / 8, chunk_size / 8)
	rd.compute_list_end()
	
	#submit and wait a frame before syncing CPU with GPU
	rd.submit()
	await get_tree().process_frame
	rd.sync ()
	
	#process results for each chunk
	for chunk in chunks:
		var total_triangles := rd.buffer_get_data(chunk["counter_buffer"]).to_int32_array()[0]
		
		if total_triangles == 0:
			safe_free_rid(chunk["data_buffer"])
			safe_free_rid(chunk["counter_buffer"])
			safe_free_rid(chunk["vertices_buffer"])
			print("Didn't load chunk: " + chunk["key"] + " because it is empty")
			continue
		
		var output_array := rd.buffer_get_data(chunk["vertices_buffer"]).to_float32_array()
		var chunk_mesh := build_mesh_from_compute_data(total_triangles, output_array)
		
		print("Loaded chunk: " + chunk["key"])
		var chunk_instance := MeshInstance3D.new()
		chunk_instance.mesh = chunk_mesh
		chunk_instance.position = Vector3(chunk["x"], chunk["y"], chunk["z"]) * chunk_size
		
		if chunk_mesh.get_surface_count() > 0:
			chunk_instance.create_trimesh_collision()
		add_child(chunk_instance)
		
		loaded_chunks[chunk["key"]] = {
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
	
	#parse triangle data: each triangle is 16 floats (3 vec4 for vertices + 1 vec4 for normal)
	for i in range(0, total_triangles * 16, 16):
		#extract the 3 vertices (each vertex is a vec4, so we read x, y, z and skip w)
		output["vertices"].push_back(Vector3(output_array[i + 0], output_array[i + 1], output_array[i + 2]))
		output["vertices"].push_back(Vector3(output_array[i + 4], output_array[i + 5], output_array[i + 6]))
		output["vertices"].push_back(Vector3(output_array[i + 8], output_array[i + 9], output_array[i + 10]))
		
		#extract the normal (indices 12, 13, 14 are x, y, z; skip index 15 which is w)
		var normal := Vector3(output_array[i + 12], output_array[i + 13], output_array[i + 14])
		for j in range(3):
			output["normals"].push_back(normal)
	
	#create mesh using ArrayMesh, this is more optimal than using the surfacetool
	var mesh_data := []
	mesh_data.resize(Mesh.ARRAY_MAX)
	mesh_data[Mesh.ARRAY_VERTEX] = output["vertices"]
	mesh_data[Mesh.ARRAY_NORMAL] = output["normals"]
	
	var array_mesh := ArrayMesh.new()
	array_mesh.clear_surfaces()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_data)
	array_mesh.surface_set_material(0, terrain_material)
	
	assert(array_mesh != null, "Arraymesh should never be null")
	return array_mesh

func create_data_buffer(chunk_coords: Vector3) -> RID:
	var data = get_per_chunk_params(chunk_coords)
	var data_bytes = data.to_byte_array()
	var buffer_rid := rd.storage_buffer_create(data_bytes.size(), data_bytes)
	
	assert(buffer_rid != null, "Data_buffer_rid should never be null")
	return buffer_rid

func create_counter_buffer() -> RID:
	var counter_bytes := PackedFloat32Array([0]).to_byte_array()
	var buffer_rid := rd.storage_buffer_create(counter_bytes.size(), counter_bytes)
	
	assert(buffer_rid != null, "Counter_buffer_rid should never be null")
	return buffer_rid

func create_vertices_buffer() -> RID:
	var total_cells := chunk_size * chunk_size * chunk_size
	var vertices := PackedColorArray()
	vertices.resize(total_cells * 5 * (3 + 1)) # 5 triangles max per cell, 3 vertices and 1 normal per triangle
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
	
	var per_chunk_uniform_set := rd.uniform_set_create([data_uniform, counter_uniform, vertices_uniform], marching_cubes_shader, 1)
	assert(per_chunk_uniform_set != null, "Per_chunk_uniform_set should never be null")
	return per_chunk_uniform_set

func unload_chunk(x: int, y: int, z: int):
	var chunk_key := str(x) + "," + str(y) + "," + str(z)
	if loaded_chunks.has(chunk_key):
		if loaded_chunks[chunk_key] == null:
			loaded_chunks.erase(chunk_key)
			return
		
		var chunk_data = loaded_chunks[chunk_key]
		
		#free the GPU buffers, otherwise you will have memory leaks leading to crashes
		##free the uniform set BEFORE the buffers!!!
		safe_free_rid(chunk_data["per_chunk_uniform_set"])
		safe_free_rid(chunk_data["data_buffer"])
		safe_free_rid(chunk_data["counter_buffer"])
		safe_free_rid(chunk_data["vertices_buffer"])
		
		chunk_data["mesh_node"].queue_free()
		
		loaded_chunks.erase(chunk_key)
		print("Unloaded chunk: " + chunk_key)

#this function returns the global paramaters 
func get_global_params():
	var params := PackedFloat32Array()
	params.append_array([chunk_size + 1, chunk_size + 1, chunk_size + 1])
	params.append(iso_level)
	params.append(int(flat_shaded))
	
	assert(params != null, "Global_params should never be null")
	return params

func get_per_chunk_params(chunk_coords: Vector3):
	var voxel_grid := VoxelGrid.new(chunk_size + 1, iso_level)
	var world_offset: Vector3 = chunk_coords * chunk_size
	
	for x in range(chunk_size + 1):
		for y in range(chunk_size + 1):
			for z in range(chunk_size + 1):
				var world_x := world_offset.x + x
				var world_y := world_offset.y + y
				var world_z := world_offset.z + z
				#var value := noise.get_noise_3d(world_x, world_y, world_z)+(y+y%terrain_terrace)/float(voxel_grid.resolution)-0.5
				var value := noise.get_noise_3d(world_x, world_y, world_z)
				voxel_grid.write(x, y, z, value)
	
	var params := PackedFloat32Array()
	params.append_array(voxel_grid.data)
	assert(params != null, "Per_chunk_params should never be null")
	return params

#safely free a RID without errors if it's invalid
func safe_free_rid(rid: RID):
	if rid.is_valid():
		rd.free_rid(rid)

func _notification(type):
	#this goes through if this object (the object where the script is attached to) would get deleted
	if type == NOTIFICATION_PREDELETE:
		release()

#freeing all rd related things, in the correct order
func release():
	for buffers in global_buffers:
		safe_free_rid(buffers)
	global_buffers.clear()
	
	safe_free_rid(global_uniform_set)
	safe_free_rid(marching_cubes_pipeline)
	safe_free_rid(marching_cubes_shader)
	
	#only free it if you created a rendering device yourself
	rd.free()
