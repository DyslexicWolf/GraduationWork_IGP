extends Node
class_name HelperFunctions

static func march_cube(x:int, y:int, z:int, voxel_grid:VoxelGrid, vertices:PackedVector3Array):
	var tri = get_triangulation(x, y, z, voxel_grid)
	for edge_index in tri:
		if edge_index < 0: break
		var point_indices = GlobalConstants.EDGES[edge_index]
		
		var p0 = GlobalConstants.POINTS[point_indices.x]
		var p1 = GlobalConstants.POINTS[point_indices.y]
		
		var pos_a = Vector3(x+p0.x, y+p0.y, z+p0.z)
		var pos_b = Vector3(x+p1.x, y+p1.y, z+p1.z)
		
		var position = calculate_interpolation(pos_a, pos_b, voxel_grid)
		
		vertices.append(position)

#idx is a byte, we check for each vertex whether it is in the surface or not
#if it is in the surface, we assign a 1 to the idx, otherwise a 0
#<<0, <<1, ... is to move over in the byte, so it assigns on the right bit
static func get_triangulation(x:int, y:int, z:int, voxel_grid:VoxelGrid):
	var idx = 0b00000000
	idx |= int(voxel_grid.read(x, y, z) < voxel_grid.iso_level)<<0
	idx |= int(voxel_grid.read(x, y, z+1) < voxel_grid.iso_level)<<1
	idx |= int(voxel_grid.read(x+1, y, z+1) < voxel_grid.iso_level)<<2
	idx |= int(voxel_grid.read(x+1, y, z) < voxel_grid.iso_level)<<3
	idx |= int(voxel_grid.read(x, y+1, z) < voxel_grid.iso_level)<<4
	idx |= int(voxel_grid.read(x, y+1, z+1) < voxel_grid.iso_level)<<5
	idx |= int(voxel_grid.read(x+1, y+1, z+1) < voxel_grid.iso_level)<<6
	idx |= int(voxel_grid.read(x+1, y+1, z) < voxel_grid.iso_level)<<7
	return GlobalConstants.LOOKUPTABLE[idx]

#interpolate between the two vertices to place our new vertex in between
static func calculate_interpolation(a:Vector3, b:Vector3, voxel_grid:VoxelGrid):
	var val_a = voxel_grid.read(a.x, a.y, a.z)
	var val_b = voxel_grid.read(b.x, b.y, b.z)
	var t = (voxel_grid.iso_level - val_a)/(val_b-val_a)
	return a+t*(b-a)

static func parse_time(time: int) -> String:
	var MILLISECOND: int = 1000
	var SECOND: int = 1000 * MILLISECOND
	var MINUTE: int = 60 * SECOND
	var HOUR: int = 60 * MINUTE
	
	if time < MILLISECOND:
		return "%s μs" % time
	elif time < SECOND:
		return "%s ms" % (time / MILLISECOND)
	elif time < MINUTE:
		return "%s s" % (time / SECOND)
	elif time < HOUR:
		return "%s min" % (time / MINUTE)
	else:
		return "%s h" % (time / HOUR)
