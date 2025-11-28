#[compute]
#version 450

struct Triangle{
    vec4 v[3]; // 3 vertices, each a vec4 = 3 * 16 bytes
    vec4 normal; // 1 normal vec4 = 16 bytes
};

//This is a SSBO (Shader Storage Buffer Object), this allows shaders to read and write data efficiently
//The 'layout' configures the buffer's location and memory layout
//'set' and 'binding' specify where the buffer is bound, essentially a memory address that the GPU can find
// 'std430' indicates a specific memory layout (you have other options like std140, ...)
//'restrict' and 'coherent' are keywords that provide additional information about how the buffer will be used
// 'restrict' tells the compiler that this buffer won't be aliased (i.e., no other pointers will reference the same memory)
// 'coherent' ensures that memory operations are visible across different shader invocations immediately
layout(set = 0, binding = 0, std430) restrict buffer GlobalParamsBuffer {
    float size_x;
    float size_y;
    float size_z;
    float iso_level;
    float flat_shaded; //this should be bool but std430 doesn't support it
} global_params;

layout(set = 0, binding = 1, std430) restrict buffer LookUpTableBuffer {
    int table[256][16];
} look_up_table;

layout(set = 1, binding = 0, std430) restrict buffer PerChunkDataBuffer {
	float data[];
} per_chunk_data;

layout(set = 1, binding = 1, std430) coherent buffer CounterBuffer {
    uint counter;
};

layout(set = 1, binding = 2, std430) restrict buffer OutputBuffer {
    Triangle data[];
} output_buffer;



const vec3 points[8] =
{
	{ 0, 0, 0 },
	{ 0, 0, 1 },
	{ 1, 0, 1 },
	{ 1, 0, 0 },
	{ 0, 1, 0 },
	{ 0, 1, 1 },
	{ 1, 1, 1 },
	{ 1, 1, 0 }
};

const ivec2 edges[12] =
{
	{ 0, 1 },
	{ 1, 2 },
	{ 2, 3 },
	{ 3, 0 },
	{ 4, 5 },
	{ 5, 6 },
	{ 6, 7 },
	{ 7, 4 },
	{ 0, 4 },
	{ 1, 5 },
	{ 2, 6 },
	{ 3, 7 }
};

//Helper function to get the scalar value at a given voxel position
float voxel_value(vec3 position) {
	return per_chunk_data.data[int(position.x + global_params.size_x * (position.y + global_params.size_y * position.z))];
}

//Helper function to interpolate between two voxel positions based on their scalar values
vec3 calculate_interpolation(vec3 v1, vec3 v2)
{
	if (global_params.flat_shaded == 1.0) {
		return (v1 + v2) * 0.5;
	} else {
		float val1 = voxel_value(v1);
		float val2 = voxel_value(v2);
		return mix(v1, v2, (global_params.iso_level - val1) / (val2 - val1));
	}
}

//the layout(local_size_x, local_size_y, local_size_z) in; directive specifies the number of work items (threads) in each workgroup along the x, y, and z dimensions.
//In this case, each workgroup contains 8x8x8 = 512 threads
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() {
	vec3 grid_position = gl_GlobalInvocationID;

    //same as get_triangulation function in CPU version (see helper functions)
	int triangulation = 0;
	for (int i = 0; i < 8; ++i) {
		triangulation |= int(voxel_value(grid_position + points[i]) > global_params.iso_level) << i;
	}

	for (int i = 0; i < 16; i += 3) {
		if (look_up_table.table[triangulation][i] < 0) {
			break;
		}
		
		// you can't just add vertices to your output array like in CPU
		// or you'll get vertex spaghetti
		Triangle t;
		for (int j = 0; j < 3; ++j) {
			ivec2 edge = edges[look_up_table.table[triangulation][i + j]];
			vec3 p0 = points[edge.x];
			vec3 p1 = points[edge.y];
			vec3 p = calculate_interpolation(grid_position + p0, grid_position + p1);
			t.v[j] = vec4(p, 0.0);
		}
		
		// calculate normals
		vec3 ab = t.v[1].xyz - t.v[0].xyz;
		vec3 ac = t.v[2].xyz - t.v[0].xyz;
		t.normal = -vec4(normalize(cross(ab,ac)), 0.0);
		
        //atomicAdd is used to safely increment the counter variable in a multi-threaded environment
		output_buffer.data[atomicAdd(counter, 1u)] = t;
	}
}