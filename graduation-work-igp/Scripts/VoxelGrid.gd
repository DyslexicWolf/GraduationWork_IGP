extends Node
class_name VoxelGrid

var data: PackedFloat32Array
var resolution: int
var iso_level: float

func _init(input_resolution: int, input_iso_level):
	iso_level = input_iso_level
	resolution = input_resolution
	data.resize(input_resolution*input_resolution*input_resolution)
	data.fill(1.0)

#returns the scalar value of the vertex on the position x, y, z
func read(x: int, y: int, z: int):
	return data[x + resolution * (y + resolution * z)]

#writes the scalar value of the vertex on the position x, y, z
func write(x: int, y: int, z: int, value: float):
	data[x + resolution * (y + resolution * z)] = value
