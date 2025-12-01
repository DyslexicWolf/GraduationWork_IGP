extends MeshInstance3D
class_name TerrainGeneration

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

func _process(_delta):
	#calculate player chunk position
	var player_chunk_x := int(player.position.x / chunk_size)
	var player_chunk_y := int(player.position.y / chunk_size)
	var player_chunk_z := int(player.position.z / chunk_size)
	
	#load and unload chunks based on player position
	for x in range(player_chunk_x - render_distance, player_chunk_x + render_distance + 1):
		for y in range(player_chunk_y - render_distance_height, player_chunk_y + render_distance_height + 1):
			for z in range(player_chunk_z - render_distance, player_chunk_z + render_distance + 1):
				var chunk_key := str(x) + "," + str(y) + "," + str(z)
				if not loaded_chunks.has(chunk_key):
					load_chunk(x, y, z)
	
	#unload chunks that are out of render distance
	for key in loaded_chunks.keys().duplicate():
		var coords : Array = key.split(",")
		var chunk_x := int(coords[0])
		var chunk_y := int(coords[1])
		var chunk_z := int(coords[2])
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

func generate_chunk_mesh(chunk_x: int, chunk_y: int, chunk_z: int):
	var generated_mesh : ArrayMesh = generate(Vector3(chunk_x, chunk_y, chunk_z))
	return generated_mesh

#generate scalar values for each voxel
func get_scalar_values(world_offset: Vector3, voxel_grid: VoxelGrid):
	for x in range(chunk_size + 1):
		for y in range(chunk_size + 1):
			for z in range(chunk_size + 1):
				var world_x := world_offset.x + x
				var world_y := world_offset.y + y
				var world_z := world_offset.z + z
				
				#var value = noise.get_noise_3d(world_x, world_y, world_z)+(y+y%terrain_terrace)/float(voxel_grid.resolution)-0.5
				var value := noise.get_noise_3d(world_x, world_y, world_z)
				voxel_grid.write(x, y, z, value)

func generate(chunk_coords: Vector3) -> ArrayMesh:
	var voxel_grid := VoxelGrid.new(chunk_size + 1, iso_level)
	var world_offset: Vector3 = chunk_coords * chunk_size
	get_scalar_values(world_offset, voxel_grid)
	
	#march the cubes
	var vertices := PackedVector3Array()
	for x in range(chunk_size):
		for y in range(chunk_size):
			for z in range(chunk_size):
				HelperFunctions.march_cube(x, y, z, voxel_grid, vertices)
	
	#create mesh surface and draw
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	if flat_shaded:
		surface_tool.set_smooth_group(-1)
	
	for vert in vertices:
		surface_tool.add_vertex(vert)
	
	surface_tool.generate_normals()
	surface_tool.index()
	surface_tool.set_material(terrain_material)
	return surface_tool.commit()
