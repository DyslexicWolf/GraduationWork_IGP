extends MeshInstance3D
class_name TerrainGeneration_GPU

var rd = RenderingServer.create_local_rendering_device()
var marching_cubes_pipeline: RID
var marching_cubes_shader: RID
var noise_generation_pipeline: RID
var noise_generation_shader: RID
var global_buffers: Array
var global_uniform_set: RID

@export	var terrain_material: Material
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
	noise.frequency = 0.02
	noise.cellular_jitter = 0
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	
	init_compute()
	setup_global_bindings()

func init_compute():
	#create shader and pipeline for marching cubes and noise generation
	var marching_cubes_shader_file = load("res://Shaders/ComputeShaders/MarchingCubes.glsl")
	var marching_cubes_shader_spirv = marching_cubes_shader_file.get_spirv()
	marching_cubes_shader = rd.shader_create_from_spirv(marching_cubes_shader_spirv)
	marching_cubes_pipeline = rd.compute_pipeline_create(marching_cubes_shader)
	
	var noise_generation_shader_file = load("res://Shaders/ComputeShaders/NoiseGeneration.glsl")
	var noise_generation_shader_spirv = noise_generation_shader_file.get_spirv()
	noise_generation_shader = rd.shader_create_from_spirv(noise_generation_shader_spirv)
	noise_generation_pipeline = rd.compute_pipeline_create(noise_generation_shader)

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
	#calculate player chunk position
	var player_chunk_x := int(player.position.x / chunk_size)
	var player_chunk_y := int(player.position.y / chunk_size)
	var player_chunk_z := int(player.position.z / chunk_size)
	chunk_load_queue.clear()
	
	#load and unload chunks based on player position
	for x in range(player_chunk_x - render_distance, player_chunk_x + render_distance + 1):
		for y in range(player_chunk_y - render_distance_height, player_chunk_y + render_distance_height + 1):
			for z in range(player_chunk_z - render_distance, player_chunk_z + render_distance + 1):
				var chunk_key := str(x) + "," + str(y) + "," + str(z)
				if not loaded_chunks.has(chunk_key):
					var chunk_pos := Vector3(x, y, z)
					var player_chunk_pos := Vector3(player_chunk_x, player_chunk_y, player_chunk_z)
					var distance := chunk_pos.distance_to(player_chunk_pos)
					chunk_load_queue.append({"key": chunk_key, "distance": distance, "pos": chunk_pos})
	
	#sort by distance (closest first)
	chunk_load_queue.sort_custom(func(a, b): return a["distance"] < b["distance"])
	
	#load only a few chunks per frame to avoid stuttering
	for i in range(min(chunks_to_load_per_frame, chunk_load_queue.size())):
		var chunk_data = chunk_load_queue[i]
		load_chunk(int(chunk_data["pos"].x), int(chunk_data["pos"].y), int(chunk_data["pos"].z))
	
	#unload chunks that are out of render distance
	for key in loaded_chunks.keys().duplicate():
		var coords = key.split(",")
		var chunk_x := int(coords[0])
		var chunk_y := int(coords[1])
		var chunk_z := int(coords[2])
		if abs(chunk_x - player_chunk_x) > render_distance or abs(chunk_y - player_chunk_y) > render_distance_height or abs(chunk_z - player_chunk_z) > render_distance:
			unload_chunk(chunk_x, chunk_y, chunk_z)

func load_chunk(x: int, y: int, z: int):
	var chunk_key := str(x) + "," + str(y) + "," + str(z)
	var chunk_coords := Vector3(x, y, z)
	var data_buffer_rid := await create_data_buffer(chunk_coords)
	var counter_buffer_rid := create_counter_buffer()
	var vertices_buffer_rid := create_vertices_buffer()
	var per_chunk_uniform_set := create_per_chunk_uniform_set(data_buffer_rid, counter_buffer_rid, vertices_buffer_rid)
	
	var compute_result := await run_compute_for_chunk(counter_buffer_rid, vertices_buffer_rid, per_chunk_uniform_set)
	var total_triangles = compute_result["total_triangles"]
	
	#if there are no triangles, it's an empty chunk
	if total_triangles == 0:
		safe_free_rid(data_buffer_rid)
		safe_free_rid(counter_buffer_rid)
		safe_free_rid(vertices_buffer_rid)
		print("Didn't load chunk: " + chunk_key + " because it is empty")
		loaded_chunks[chunk_key] = null
		return
	
	var chunk_mesh := build_mesh_from_compute_data(compute_result)
	
	print("Loaded chunk: "+ chunk_key)
	var chunk_instance := MeshInstance3D.new()
	chunk_instance.mesh = chunk_mesh
	chunk_instance.position = Vector3(x, y, z) * chunk_size
	
	#create a collider from the mesh (only use this on static bodies)
	if chunk_mesh.get_surface_count() > 0:
		chunk_instance.create_trimesh_collision()
	add_child(chunk_instance)
	
	loaded_chunks[chunk_key] = {
		"mesh_node": chunk_instance,
		"data_buffer": data_buffer_rid,
		"counter_buffer": counter_buffer_rid,
		"vertices_buffer": vertices_buffer_rid,
		"per_chunk_uniform_set": per_chunk_uniform_set
		}

func run_compute_for_chunk(counter_buffer_rid: RID, vertices_buffer_rid: RID, per_chunk_uniform_set: RID) -> Dictionary:
	#reset counterbuffer to 0
	var zero_counter := PackedInt32Array([0])
	var counter_bytes := PackedFloat32Array([0]).to_byte_array()
	rd.buffer_update(counter_buffer_rid, 0, counter_bytes.size(),zero_counter.to_byte_array())
	
	#dispatch compute shader for this chunk
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, marching_cubes_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, global_uniform_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, per_chunk_uniform_set, 1) 
	rd.compute_list_dispatch(compute_list, chunk_size / 8, chunk_size / 8, chunk_size / 8)
	rd.compute_list_end()
	
	#submit and wait a frame before syncing
	rd.submit()
	await get_tree().process_frame
	rd.sync()
	
	#read back results
	var total_triangles := rd.buffer_get_data(counter_buffer_rid).to_int32_array()[0]
	var output_array := rd.buffer_get_data(vertices_buffer_rid).to_float32_array()
	
	return {
		"total_triangles": total_triangles,
		"output_array": output_array
	}

func build_mesh_from_compute_data(compute_result: Dictionary) -> Mesh:
	var total_triangles := int(compute_result["total_triangles"])
	var output_array = compute_result["output_array"]
	
	var output = {
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
	}
	
	#parse triangle data: each triangle is 16 floats (3 vec4 for vertices + 1 vec4 for normal)
	for i in range(0, total_triangles * 16, 16):
		# Extract the 3 vertices (each vertex is a vec4, so we read x, y, z and skip w)
		output["vertices"].push_back(Vector3(output_array[i+0], output_array[i+1], output_array[i+2]))
		output["vertices"].push_back(Vector3(output_array[i+4], output_array[i+5], output_array[i+6]))
		output["vertices"].push_back(Vector3(output_array[i+8], output_array[i+9], output_array[i+10]))
		
		#extract the normal (indices 12, 13, 14 are x, y, z; skip index 15 which is w)
		var normal := Vector3(output_array[i+12], output_array[i+13], output_array[i+14])
		for j in range(3):
			output["normals"].push_back(normal)
	
	print("total amount of verts= " + str(output["vertices"].size()))
	
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
	var data = await get_per_chunk_params(chunk_coords)
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
		
		# Free the mesh node from the scene tree
		chunk_data["mesh_node"].queue_free()
		
		loaded_chunks.erase(chunk_key)
		print("Unloaded chunk: " + chunk_key)

#this function returns the paramaters (aka noise values) for the mesh in the specified chunk
func get_global_params():
	var params := PackedFloat32Array()
	params.append_array([chunk_size + 1, chunk_size + 1, chunk_size + 1])
	params.append(iso_level)
	params.append(int(flat_shaded))
	
	assert(params != null, "Global_params should never be null")
	return params

func get_per_chunk_params(chunk_coords: Vector3):
	#var voxel_grid := VoxelGrid.new(chunk_size + 1, iso_level)
	#var world_offset: Vector3 = chunk_coords * chunk_size
	#
	#for x in range(chunk_size + 1):
		#for y in range(chunk_size + 1):
			#for z in range(chunk_size + 1):
				#var world_x := world_offset.x + x
				#var world_y := world_offset.y + y
				#var world_z := world_offset.z + z
				##var value := noise.get_noise_3d(world_x, world_y, world_z)+(y+y%terrain_terrace)/float(voxel_grid.resolution)-0.5
				#var value := noise.get_noise_3d(world_x, world_y, world_z)
				#voxel_grid.write(x, y, z, value)
	#
	#var params := PackedFloat32Array()
	#params.append_array(voxel_grid.data)
	#assert(params != null, "Per_chunk_params should never be null")
	#return params
	var resolution := chunk_size + 1
	var total_voxels := resolution * resolution * resolution
	
	#create output buffer
	var output_bytes := PackedFloat32Array()
	output_bytes.resize(total_voxels)
	var output_buffer := rd.storage_buffer_create(output_bytes.size() * 4, output_bytes.to_byte_array())
	
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(output_buffer)
	
	var noise_generation_uniform_set = rd.uniform_set_create([uniform], noise_generation_shader, 0)
	
	# Prepare push constants
	var world_offset := chunk_coords * chunk_size
	var push_constant := PackedFloat32Array([
		world_offset.x, world_offset.y, world_offset.z,
		iso_level,
		float(chunk_size),
		noise.frequency,
		float(noise.noise_type),
		float(noise.fractal_type),
		float(noise.fractal_octaves),
		noise.fractal_lacunarity,
		noise.fractal_gain,
		noise.fractal_weighted_strength,
		noise.fractal_ping_pong_strength,
		float(noise.seed),
		
		##padding for now, you need to supply the compute shader with 64 bytes when using constants
		0.0,
		0.0
	])
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, noise_generation_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, noise_generation_uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, resolution / 8, resolution / 8, resolution / 8)
	rd.compute_list_end()
	
	#submit and wait a frame before syncing
	rd.submit()
	await get_tree().process_frame
	rd.sync()
	
	var output_data := rd.buffer_get_data(output_buffer)
	var params := output_data.to_float32_array()
	
	safe_free_rid(noise_generation_uniform_set)
	safe_free_rid(output_buffer)
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
	safe_free_rid(noise_generation_pipeline)
	safe_free_rid(noise_generation_shader)
	
	#only free it if you created a rendering device yourself
	rd.free()
