extends Node
class_name HelperFunctions

static func march_cube(x:int, y:int, z:int, voxel_grid:VoxelGrid, vertices:PackedVector3Array):
  # Get the correct configuration
	var tri = get_triangulation(x, y, z, voxel_grid)
	for edge_index in tri:
		if edge_index < 0: break
		var point_indices = GlobalConstants.EDGES[edge_index]
		
		# Get 2 points connecting this edge
		var p0 = GlobalConstants.POINTS[point_indices.x]
		var p1 = GlobalConstants.POINTS[point_indices.y]
		
		# Global position of these 2 points
		var pos_a = Vector3(x+p0.x, y+p0.y, z+p0.z)
		var pos_b = Vector3(x+p1.x, y+p1.y, z+p1.z)
		
		# Interpolate between these 2 points to get our mesh's vertex position
		var position = calculate_interpolation(pos_a, pos_b, voxel_grid)
		
		# Add our new vertex to our mesh's vertices array
		vertices.append(position)

#idx is a byte, we check for each vertex whether it is in the surface or not
#if it is in the surface, we assign a 1 to the idx, otherwise a 0
#<<0, <<1, ... is to move over in the byte, so it assigns on the right bit
static func get_triangulation(x:int, y:int, z:int, voxel_grid:VoxelGrid):
	var idx = 0b00000000
	idx |= int(voxel_grid.read(x, y, z) < voxel_grid.ISO_LEVEL)<<0
	idx |= int(voxel_grid.read(x, y, z+1) < voxel_grid.ISO_LEVEL)<<1
	idx |= int(voxel_grid.read(x+1, y, z+1) < voxel_grid.ISO_LEVEL)<<2
	idx |= int(voxel_grid.read(x+1, y, z) < voxel_grid.ISO_LEVEL)<<3
	idx |= int(voxel_grid.read(x, y+1, z) < voxel_grid.ISO_LEVEL)<<4
	idx |= int(voxel_grid.read(x, y+1, z+1) < voxel_grid.ISO_LEVEL)<<5
	idx |= int(voxel_grid.read(x+1, y+1, z+1) < voxel_grid.ISO_LEVEL)<<6
	idx |= int(voxel_grid.read(x+1, y+1, z) < voxel_grid.ISO_LEVEL)<<7
	return GlobalConstants.TRIANGULATIONS[idx]

# Interpolate between the two vertices to place our new vertex in between
static func calculate_interpolation(a:Vector3, b:Vector3, voxel_grid:VoxelGrid):
	var val_a = voxel_grid.read(a.x, a.y, a.z)
	var val_b = voxel_grid.read(b.x, b.y, b.z)
	var t = (voxel_grid.ISO_LEVEL - val_a)/(val_b-val_a)
	return a+t*(b-a)
