extends MeshInstance3D
class_name TerrainGeneration

@export	var terrain_material: Material
@export var resolution: int = 50
@export var iso_level: float = 0.0
@export var noise: FastNoiseLite
@export var flat_shaded: bool = false
@export var terrain_terrace: int = 1
@export var chunk_size: int = 8
@export var render_distance: int = 1

var player_position: Vector3 = Vector3()
var loaded_chunks: Dictionary = {}
var player: CharacterBody3D

func _ready():
	player = $"../Player"

func _process(_delta):
	player_position = player.position
	
	# Calculate player chunk position
	var player_chunk_x = int(player_position.x / chunk_size)
	var player_chunk_y = int(player_position.y / chunk_size)
	var player_chunk_z = int(player_position.z / chunk_size)
	
	# Load and unload chunks based on player position
	for x in range(player_chunk_x - render_distance, player_chunk_x + render_distance + 1):
		for y in range(player_chunk_y - render_distance, player_chunk_y + render_distance + 1):
			for z in range(player_chunk_z - render_distance, player_chunk_z + render_distance + 1):
				var chunk_key = str(x) + "," + str(y) + "," + str(z)
				if not loaded_chunks.has(chunk_key):
					print("x: "+str(x)+" y: "+str(y)+" z: "+str(z))
					load_chunk(x, y, z)
				else:
					# Update chunk position if it's already loaded
					loaded_chunks[chunk_key].position.x = x * chunk_size
					loaded_chunks[chunk_key].position.y = y * chunk_size
					loaded_chunks[chunk_key].position.z = z * chunk_size
	
	# Unload chunks that are out of render distance
	for key in loaded_chunks.keys():
		var coords = key.split(",")
		var chunk_x = int(coords[0])
		var chunk_y = int(coords[1])
		var chunk_z = int(coords[2])
		if abs(chunk_x - player_chunk_x) > render_distance or abs(chunk_y - player_chunk_y) > render_distance or abs(chunk_z - player_chunk_z) > render_distance:
			unload_chunk(chunk_x, chunk_y, chunk_z)

func load_chunk(x, y, z):
	var chunk_mesh = generate_chunk_mesh(x, y, z)
	var chunk_instance = MeshInstance3D.new()
	chunk_instance.mesh = chunk_mesh
	chunk_instance.position.x = x * chunk_size
	chunk_instance.position.y = y * chunk_size
	chunk_instance.position.z = z * chunk_size
	add_child(chunk_instance)
	loaded_chunks[str(x) + "," + str(y) + "," + str(z)] = chunk_instance

func unload_chunk(x, y, z):
	var chunk_key = str(x) + "," + str(y) + "," + str(z)
	if loaded_chunks.has(chunk_key):
		var chunk_instance = loaded_chunks[chunk_key]
		chunk_instance.queue_free()
		loaded_chunks.erase(chunk_key)
		print('UNLOAD CHNK')

func generate_chunk_mesh(x, y, z):
	var generated_mesh = generate(Vector3(x, y, z) * chunk_size)
	return generated_mesh

func generate(chunk_pos: Vector3):
	var voxel_grid = VoxelGrid.new(resolution, iso_level)
	
	#generate terrain
	for x in range(voxel_grid.resolution):
		for y in range(voxel_grid.resolution):
			for z in range(voxel_grid.resolution):
				var value = noise.get_noise_3d(x + chunk_pos.x, y + chunk_pos.y, z + chunk_pos.z)
				#code to check out 
				##var value = noise.get_noise_3d(x + chunk_pos.x, y + chunk_pos.y, z + chunk_pos.z)+(y+y%TERRAIN_TERRACE)/float(voxel_grid.resolution)-0.5
				voxel_grid.write(x, y, z, value)
	
	 #march the cubes
	var vertices = PackedVector3Array()
	for x in voxel_grid.resolution-1:
		for y in voxel_grid.resolution-1:
			for z in voxel_grid.resolution-1:
				HelperFunctions.march_cube(x, y, z, voxel_grid, vertices)
	
	# Create mesh surface and draw
	var surface_tool = SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	if flat_shaded:
		surface_tool.set_smooth_group(-1)
	
	for vert in vertices:
		surface_tool.add_vertex(vert)
	
	surface_tool.generate_normals()
	surface_tool.index()
	surface_tool.set_material(terrain_material)
	mesh = surface_tool.commit()
