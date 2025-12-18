#[compute]
#version 450

// Global parameters (set 0, binding 0)
layout(set = 0, binding = 0, std430) restrict readonly buffer GlobalParams {
    vec3 grid_size;
    float iso_level;
    float flat_shaded;
    float noise_frequency;
    float fractal_octaves;
    float terrain_terrace;
} global_params;

// Lookup table (set 0, binding 1)
layout(set = 0, binding = 1, std430) restrict readonly buffer LookupTable {
    int data[];
} lookup_table;

// Per-chunk parameters (set 1, binding 0)
layout(set = 1, binding = 0, std430) restrict readonly buffer ChunkData {
    vec3 chunk_coords;
    float chunk_size;
} chunk_data;

// Counter for triangle output (set 1, binding 1)
layout(set = 1, binding = 1, std430) restrict buffer Counter {
    int triangle_count;
} counter;

// Output vertices (set 1, binding 2)
layout(set = 1, binding = 2, std430) restrict buffer Vertices {
    vec4 data[];
} vertices;

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// ============================================================================
// PERLIN NOISE IMPLEMENTATION
// ============================================================================

// Permutation table for Perlin noise
const int PERM[256] = int[256](
    151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225,
    140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148,
    247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32,
    57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175,
    74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122,
    60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54,
    65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169,
    200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64,
    52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212,
    207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213,
    119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9,
    129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104,
    218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241,
    81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157,
    184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93,
    222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180
);

// Hash function using permutation table
int hash(int x) {
    return PERM[x & 255];
}

// 3D gradient vectors
vec3 grad3(int hash_val) {
    int h = hash_val & 15;
    float u = h < 8 ? 1.0 : -1.0;
    float v = h < 4 ? 1.0 : (h == 12 || h == 14 ? 1.0 : -1.0);
    float w = (h & 1) == 0 ? 1.0 : -1.0;
    
    return vec3(
        (h & 1) == 0 ? u : 0.0,
        (h & 2) == 0 ? v : 0.0,
        (h & 4) == 0 ? w : 0.0
    );
}

// Fade function for smooth interpolation (6t^5 - 15t^4 + 10t^3)
float fade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// 3D Perlin Noise
float perlin_noise(vec3 p) {
    // Find unit cube containing the point
    ivec3 pi = ivec3(floor(p)) & 255;
    
    // Find relative position in cube
    vec3 pf = fract(p);
    
    // Compute fade curves
    vec3 u = vec3(fade(pf.x), fade(pf.y), fade(pf.z));
    
    // Hash coordinates of the 8 cube corners
    int aaa = hash(hash(hash(pi.x    ) + pi.y    ) + pi.z    );
    int aba = hash(hash(hash(pi.x    ) + pi.y + 1) + pi.z    );
    int aab = hash(hash(hash(pi.x    ) + pi.y    ) + pi.z + 1);
    int abb = hash(hash(hash(pi.x    ) + pi.y + 1) + pi.z + 1);
    int baa = hash(hash(hash(pi.x + 1) + pi.y    ) + pi.z    );
    int bba = hash(hash(hash(pi.x + 1) + pi.y + 1) + pi.z    );
    int bab = hash(hash(hash(pi.x + 1) + pi.y    ) + pi.z + 1);
    int bbb = hash(hash(hash(pi.x + 1) + pi.y + 1) + pi.z + 1);
    
    // Calculate gradients and dot products
    float g000 = dot(grad3(aaa), pf - vec3(0.0, 0.0, 0.0));
    float g100 = dot(grad3(baa), pf - vec3(1.0, 0.0, 0.0));
    float g010 = dot(grad3(aba), pf - vec3(0.0, 1.0, 0.0));
    float g110 = dot(grad3(bba), pf - vec3(1.0, 1.0, 0.0));
    float g001 = dot(grad3(aab), pf - vec3(0.0, 0.0, 1.0));
    float g101 = dot(grad3(bab), pf - vec3(1.0, 0.0, 1.0));
    float g011 = dot(grad3(abb), pf - vec3(0.0, 1.0, 1.0));
    float g111 = dot(grad3(bbb), pf - vec3(1.0, 1.0, 1.0));
    
    // Trilinear interpolation
    float x00 = mix(g000, g100, u.x);
    float x10 = mix(g010, g110, u.x);
    float x01 = mix(g001, g101, u.x);
    float x11 = mix(g011, g111, u.x);
    
    float y0 = mix(x00, x10, u.y);
    float y1 = mix(x01, x11, u.y);
    
    return mix(y0, y1, u.z);
}

// Fractal Brownian Motion (FBM) - multiple octaves of noise
float fbm(vec3 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    float max_value = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        value += amplitude * perlin_noise(p * frequency);
        max_value += amplitude;
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    
    return value / max_value; // Normalize
}

// Main noise function with frequency scaling
float get_noise_value(vec3 world_pos) {
    vec3 scaled_pos = world_pos * global_params.noise_frequency;
    return fbm(scaled_pos, int(global_params.fractal_octaves));
}

// ============================================================================
// VOXEL GRID ACCESS (computed on-the-fly)
// ============================================================================

float get_voxel_value(ivec3 local_pos) {
    // Calculate world position
    vec3 world_offset = chunk_data.chunk_coords * chunk_data.chunk_size;
    vec3 world_pos = world_offset + vec3(local_pos);
    
    // Generate noise value on the fly
    float noise_val = get_noise_value(world_pos);
    
    // Optional: Add terrain features
    // Uncomment to add height-based terrain (terracing, caves, etc.)
    // float height_factor = (world_pos.y / chunk_data.chunk_size) - 0.5;
    // noise_val += height_factor;
    
    return noise_val;
}

// ============================================================================
// MARCHING CUBES HELPERS
// ============================================================================

vec3 interpolate_vertex(vec3 p1, vec3 p2, float v1, float v2) {
    if (abs(global_params.iso_level - v1) < 0.00001)
        return p1;
    if (abs(global_params.iso_level - v2) < 0.00001)
        return p2;
    if (abs(v1 - v2) < 0.00001)
        return p1;
    
    float t = (global_params.iso_level - v1) / (v2 - v1);
    return mix(p1, p2, clamp(t, 0.0, 1.0));
}

vec3 calculate_normal(vec3 p) {
    float delta = 0.5;
    vec3 world_offset = chunk_data.chunk_coords * chunk_data.chunk_size;
    vec3 world_pos = world_offset + p;
    
    float dx = get_noise_value(world_pos + vec3(delta, 0, 0)) - 
               get_noise_value(world_pos - vec3(delta, 0, 0));
    float dy = get_noise_value(world_pos + vec3(0, delta, 0)) - 
               get_noise_value(world_pos - vec3(0, delta, 0));
    float dz = get_noise_value(world_pos + vec3(0, 0, delta)) - 
               get_noise_value(world_pos - vec3(0, 0, delta));
    
    vec3 normal = vec3(dx, dy, dz);
    return length(normal) > 0.0 ? normalize(normal) : vec3(0, 1, 0);
}

// ============================================================================
// MARCHING CUBES MAIN ALGORITHM
// ============================================================================

void main() {
    ivec3 grid_pos = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 grid_size_int = ivec3(global_params.grid_size);
    
    // Bounds check
    if (grid_pos.x >= grid_size_int.x - 1 || 
        grid_pos.y >= grid_size_int.y - 1 || 
        grid_pos.z >= grid_size_int.z - 1) {
        return;
    }
    
    // Get the 8 corner values of the cube
    float cube_values[8];
    cube_values[0] = get_voxel_value(grid_pos + ivec3(0, 0, 0));
    cube_values[1] = get_voxel_value(grid_pos + ivec3(1, 0, 0));
    cube_values[2] = get_voxel_value(grid_pos + ivec3(1, 1, 0));
    cube_values[3] = get_voxel_value(grid_pos + ivec3(0, 1, 0));
    cube_values[4] = get_voxel_value(grid_pos + ivec3(0, 0, 1));
    cube_values[5] = get_voxel_value(grid_pos + ivec3(1, 0, 1));
    cube_values[6] = get_voxel_value(grid_pos + ivec3(1, 1, 1));
    cube_values[7] = get_voxel_value(grid_pos + ivec3(0, 1, 1));
    
    // Calculate cube index
    int cube_index = 0;
    if (cube_values[0] < global_params.iso_level) cube_index |= 1;
    if (cube_values[1] < global_params.iso_level) cube_index |= 2;
    if (cube_values[2] < global_params.iso_level) cube_index |= 4;
    if (cube_values[3] < global_params.iso_level) cube_index |= 8;
    if (cube_values[4] < global_params.iso_level) cube_index |= 16;
    if (cube_values[5] < global_params.iso_level) cube_index |= 32;
    if (cube_values[6] < global_params.iso_level) cube_index |= 64;
    if (cube_values[7] < global_params.iso_level) cube_index |= 128;
    
    // If cube is entirely inside or outside surface, skip
    if (cube_index == 0 || cube_index == 255) {
        return;
    }
    
    // Edge vertices positions
    vec3 edge_vertices[12];
    vec3 cube_corners[8] = vec3[8](
        vec3(grid_pos) + vec3(0, 0, 0),
        vec3(grid_pos) + vec3(1, 0, 0),
        vec3(grid_pos) + vec3(1, 1, 0),
        vec3(grid_pos) + vec3(0, 1, 0),
        vec3(grid_pos) + vec3(0, 0, 1),
        vec3(grid_pos) + vec3(1, 0, 1),
        vec3(grid_pos) + vec3(1, 1, 1),
        vec3(grid_pos) + vec3(0, 1, 1)
    );
    
    // Interpolate edge vertices
    edge_vertices[0]  = interpolate_vertex(cube_corners[0], cube_corners[1], cube_values[0], cube_values[1]);
    edge_vertices[1]  = interpolate_vertex(cube_corners[1], cube_corners[2], cube_values[1], cube_values[2]);
    edge_vertices[2]  = interpolate_vertex(cube_corners[2], cube_corners[3], cube_values[2], cube_values[3]);
    edge_vertices[3]  = interpolate_vertex(cube_corners[3], cube_corners[0], cube_values[3], cube_values[0]);
    edge_vertices[4]  = interpolate_vertex(cube_corners[4], cube_corners[5], cube_values[4], cube_values[5]);
    edge_vertices[5]  = interpolate_vertex(cube_corners[5], cube_corners[6], cube_values[5], cube_values[6]);
    edge_vertices[6]  = interpolate_vertex(cube_corners[6], cube_corners[7], cube_values[6], cube_values[7]);
    edge_vertices[7]  = interpolate_vertex(cube_corners[7], cube_corners[4], cube_values[7], cube_values[4]);
    edge_vertices[8]  = interpolate_vertex(cube_corners[0], cube_corners[4], cube_values[0], cube_values[4]);
    edge_vertices[9]  = interpolate_vertex(cube_corners[1], cube_corners[5], cube_values[1], cube_values[5]);
    edge_vertices[10] = interpolate_vertex(cube_corners[2], cube_corners[6], cube_values[2], cube_values[6]);
    edge_vertices[11] = interpolate_vertex(cube_corners[3], cube_corners[7], cube_values[3], cube_values[7]);
    
    // Generate triangles based on lookup table
    int lut_offset = cube_index * 16;
    
    for (int i = 0; i < 5; i++) {
        int edge0 = lookup_table.data[lut_offset + i * 3 + 0];
        int edge1 = lookup_table.data[lut_offset + i * 3 + 1];
        int edge2 = lookup_table.data[lut_offset + i * 3 + 2];
        
        if (edge0 == -1) break;
        
        vec3 v0 = edge_vertices[edge0];
        vec3 v1 = edge_vertices[edge1];
        vec3 v2 = edge_vertices[edge2];
        
        // Calculate normal
        vec3 normal;
        if (global_params.flat_shaded > 0.5) {
            // Flat shading: face normal
            normal = normalize(cross(v1 - v0, v2 - v0));
        } else {
            // Smooth shading: averaged vertex normals
            vec3 n0 = calculate_normal(v0);
            vec3 n1 = calculate_normal(v1);
            vec3 n2 = calculate_normal(v2);
            normal = normalize(n0 + n1 + n2);
        }
        
        // Atomically increment triangle counter
        int tri_index = atomicAdd(counter.triangle_count, 1);
        
        // Write triangle data (3 vertices + 1 normal = 4 vec4s per triangle)
        int base_index = tri_index * 4;
        
        vertices.data[base_index + 0] = vec4(v0, 0.0);
        vertices.data[base_index + 1] = vec4(v1, 0.0);
        vertices.data[base_index + 2] = vec4(v2, 0.0);
        vertices.data[base_index + 3] = vec4(normal, 0.0);
    }
}
