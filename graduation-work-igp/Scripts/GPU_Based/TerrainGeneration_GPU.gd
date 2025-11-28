extends MeshInstance3D
class_name TerrainGeneration_GPU

var rd = RenderingServer.create_local_rendering_device()
const uniform_set_index: int = 0
var pipeline: RID
var shader: RID
var buffers: Array
var global_uniform_set: RID
var per_chunk_uniform_set: RID
var output

@export	var terrain_material: Material
@export var chunk_size: int
@export var iso_level: float
@export var noise: FastNoiseLite
@export var flat_shaded: bool
@export var terrain_terrace: int
@export var render_distance: int
@export var render_distance_height: int

var loaded_chunks: Dictionary = {}
var player: CharacterBody3D

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
	#create shader and pipeline
	var shader_file = load("res://shaders/marching_cubes.glsl")
	var shader_spirv = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	pipeline = rd.compute_pipeline_create(shader)

func setup_global_bindings():
	#create the triangles buffer
	var total_cells = chunk_size * chunk_size * chunk_size
	var vertices = PackedColorArray()
	vertices.resize(total_cells * 5 * (3 + 1)) # 5 triangles max per cell, 3 vertices and 1 normal per triangle
	var vertices_bytes = vertices.to_byte_array()
	buffers.push_back(rd.storage_buffer_create(vertices_bytes.size(), vertices_bytes))
	
	var vertices_uniform := RDUniform.new()
	vertices_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertices_uniform.binding = 2
	vertices_uniform.add_id(buffers[2])
	
	#create the lookuptable buffer
	var lut_array = PackedInt32Array()
	for i in range(GlobalConstants.LOOKUPTABLE.size()):
		lut_array.append_array(GlobalConstants.LOOKUPTABLE[i])
	var lut_array_bytes = lut_array.to_byte_array()
	buffers.push_back(rd.storage_buffer_create(lut_array_bytes.size(), lut_array_bytes))
	
	var lut_uniform := RDUniform.new()
	lut_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	lut_uniform.binding = 3
	lut_uniform.add_id(buffers[3])
	
	global_uniform_set = rd.uniform_set_create([vertices_uniform, lut_uniform], shader, 0)

func _process(_delta):
	#calculate player chunk position
	var player_chunk_x = int(player.position.x / chunk_size)
	var player_chunk_y = int(player.position.y / chunk_size)
	var player_chunk_z = int(player.position.z / chunk_size)
	
	#load and unload chunks based on player position
	for x in range(player_chunk_x - render_distance, player_chunk_x + render_distance + 1):
		for y in range(player_chunk_y - render_distance_height, player_chunk_y + render_distance_height + 1):
			for z in range(player_chunk_z - render_distance, player_chunk_z + render_distance + 1):
				var chunk_key = str(x) + "," + str(y) + "," + str(z)
				if not loaded_chunks.has(chunk_key):
					load_chunk(x, y, z)
	
	#unload chunks that are out of render distance
	for key in loaded_chunks.keys().duplicate():
		var coords = key.split(",")
		var chunk_x = int(coords[0])
		var chunk_y = int(coords[1])
		var chunk_z = int(coords[2])
		if abs(chunk_x - player_chunk_x) > render_distance or abs(chunk_y - player_chunk_y) > render_distance_height or abs(chunk_z - player_chunk_z) > render_distance:
			unload_chunk(chunk_x, chunk_y, chunk_z)

func load_chunk(x, y, z):
	var chunk_mesh = generate_chunk_mesh(x, y, z)
	var chunk_key = str(x) + "," + str(y) + "," + str(z)
	
	#if there is no mesh, we add the key to the loadedchunks array but the value is null, this way we know it is an empty chunk
	if chunk_mesh.get_surface_count() == 0:
		print("Didn't load chunk: " + chunk_key + " because it is empty")
		loaded_chunks[chunk_key] = null
		return
	
	print("Loaded chunk: "+ chunk_key)
	var chunk_instance = MeshInstance3D.new()
	chunk_instance.mesh = chunk_mesh
	chunk_instance.position = Vector3(x, y, z) * chunk_size
	
	#create a collider from the mesh (only use this on static bodies)
	chunk_instance.create_trimesh_collision()
	add_child(chunk_instance)
	loaded_chunks[chunk_key] = chunk_instance
	

func unload_chunk(x, y, z):
	var chunk_key = str(x) + "," + str(y) + "," + str(z)
	if loaded_chunks.has(chunk_key):
		if loaded_chunks[chunk_key] == null:
			loaded_chunks.erase(chunk_key)
			return
		
		var chunk_instance = loaded_chunks[chunk_key]
		chunk_instance.queue_free()
		loaded_chunks.erase(chunk_key)
		print("Unloaded chunk: " + chunk_key)

func setup_per_chunk_bindings(chunk_coords: Vector3):
	# Create the input params buffer
	var input = get_params(chunk_coords)
	var input_bytes = input.to_byte_array()
	buffers.push_back(rd.storage_buffer_create(input_bytes.size(), input_bytes))
	
	var input_params_uniform := RDUniform.new()
	input_params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_params_uniform.binding = 0
	input_params_uniform.add_id(buffers[0])
	
	# Create counter buffer
	var counter_bytes = PackedFloat32Array([0]).to_byte_array()
	buffers.push_back(rd.storage_buffer_create(counter_bytes.size(), counter_bytes))
	
	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 1
	counter_uniform.add_id(buffers[1])
	
	per_chunk_uniform_set = rd.uniform_set_create([input_params_uniform, counter_uniform], shader, 1)
	

func _notification(type):
	#this goes through if this object (the object where the script is attached to) would get deleted
	if type == NOTIFICATION_PREDELETE:
		release()

#freeing all rd related things, in the correct order
func release():
	for b in buffers:
		rd.free_rid(b)
	buffers.clear()
	
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	
	#only free it if you created a renderingdevice yourself
	rd.free()

#this function returns the paramaters (aka noise values) for the mesh in the specified chunk
func get_params(chunk_coords: Vector3):
	var voxel_grid := VoxelGrid.new(chunk_size, iso_level)
	
	var world_offset: Vector3 = chunk_coords * chunk_size
	for x in range(chunk_size + 1):
		for y in range(chunk_size + 1):
			for z in range(chunk_size + 1):
				var world_x = world_offset.x + x
				var world_y = world_offset.y + y
				var world_z = world_offset.z + z
				
				#var value = noise.get_noise_3d(world_x, world_y, world_z)+(y+y%terrain_terrace)/float(voxel_grid.resolution)-0.5
				var value = noise.get_noise_3d(world_x, world_y, world_z)
				voxel_grid.write(x, y, z, value)
	
	var params = PackedFloat32Array()
	params.append_array([chunk_size, chunk_size, chunk_size])
	params.append(iso_level)
	params.append(int(flat_shaded))
	params.append_array(voxel_grid.data)
	
	return params








func compute():
	# Update input buffers and clear output ones
	# This one is actually not always needed. Comment to see major speed optimization
	var time_send: int = Time.get_ticks_usec()
	var input = get_params()
	var input_bytes = input.to_byte_array()
	rd.buffer_update(buffers[0], 0, input_bytes.size(), input_bytes)

	var total_cells = DATA.get_width() * DATA.get_height() * DATA.get_depth()
	var vertices = PackedColorArray()
	vertices.resize(total_cells * 5 * (3 + 1)) # 5 triangles max per cell, 3 vertices and 1 normal per triangle
	var vertices_bytes = vertices.to_byte_array()

	var counter_bytes = PackedFloat32Array([0]).to_byte_array()
	rd.buffer_update(buffers[1], 0, counter_bytes.size(), counter_bytes)
	print("Time to update buffer: " + HelperFunctions.parse_time(Time.get_ticks_usec() - time_send))

	# Dispatch compute and uniforms
	time_send = Time.get_ticks_usec()
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, uniform_set_index)
	rd.compute_list_dispatch(compute_list, DATA.get_width() / 8, DATA.get_height() / 8, DATA.get_depth() / 8)
	rd.compute_list_end()
	print("Time to dispatch uniforms: " + HelperFunctions.parse_time(Time.get_ticks_usec() - time_send))

	# Submit to GPU and wait for sync
	time_send = Time.get_ticks_usec()
	rd.submit()
	rd.sync()
	print("Time to submit and sync: " + HelperFunctions.parse_time(Time.get_ticks_usec() - time_send))

	# Read back the data from the buffer
	time_send = Time.get_ticks_usec()
	var total_triangles = rd.buffer_get_data(buffers[1]).to_int32_array()[0]
	var output_array := rd.buffer_get_data(buffers[2]).to_float32_array()
	print("Time to read back buffer: " + HelperFunctions.parse_time(Time.get_ticks_usec() - time_send))

	time_send = Time.get_ticks_usec()
	output = {
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
	}

	for i in range(0, total_triangles * 16, 16): # Each triangle spans for 16 floats
		output["vertices"].push_back(Vector3(output_array[i+0], output_array[i+1], output_array[i+2]))
		output["vertices"].push_back(Vector3(output_array[i+4], output_array[i+5], output_array[i+6]))
		output["vertices"].push_back(Vector3(output_array[i+8], output_array[i+9], output_array[i+10]))

		var normal = Vector3(output_array[i+12], output_array[i+13], output_array[i+14])
		# Each vector will point to the same normal
		for j in range(3):
			output["normals"].push_back(normal)

	print("Time iterate vertices: " + HelperFunctions.parse_time(Time.get_ticks_usec() - time_send))
	print("Total vertices ", output["vertices"].size())

	create_mesh()

func create_mesh():
	var time_send: int = Time.get_ticks_usec()
	create_mesh_with_array()
	print("Time to create with array mesh: " + HelperFunctions.parse_time(Time.get_ticks_usec() - time_send))

	time_send = Time.get_ticks_usec()
	create_mesh_with_surface()
	print("Time to create with surface tool: " + HelperFunctions.parse_time(Time.get_ticks_usec() - time_send))

func create_mesh_with_array():
	var mesh_data = []
	mesh_data.resize(Mesh.ARRAY_MAX)
	mesh_data[Mesh.ARRAY_VERTEX] = output["vertices"]
	mesh_data[Mesh.ARRAY_NORMAL] = output["normals"]

	var array_mesh = ArrayMesh.new()
	array_mesh.clear_surfaces()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_data)
	call_deferred("set_mesh", array_mesh)

func create_mesh_with_surface():
	var surface_tool = SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	if flat_shaded:
		surface_tool.set_smooth_group(-1)

	for vert in output["vertices"]:
		surface_tool.add_vertex(vert)

	surface_tool.generate_normals()
	surface_tool.index()
	call_deferred("set_mesh", surface_tool.commit())
