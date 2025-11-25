extends MeshInstance3D

@export	var MATERIAL: Material
@export var RESOLUTION: int = 50
@export var ISO_LEVEL: float = 0.0
@export var NOISE: FastNoiseLite
@export var FLAT_SHADED: bool = false
@export var TERRAIN_TERRACE: int = 1

func generate():
	var voxel_grid = VoxelGrid.new(RESOLUTION, ISO_LEVEL)
	
	#generate terrain
	for x in range(voxel_grid.resolution):
		for y in range(voxel_grid.resolution):
			for z in range(voxel_grid.resolution):
				var value = NOISE.get_noise_3d(x, y, z)
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
	
	if FLAT_SHADED:
		surface_tool.set_smooth_group(-1)
	
	for vert in vertices:
		surface_tool.add_vertex(vert)
	
	surface_tool.generate_normals()
	surface_tool.index()
	surface_tool.set_material(MATERIAL)
	mesh = surface_tool.commit()
