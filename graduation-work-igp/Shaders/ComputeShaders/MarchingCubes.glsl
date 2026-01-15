#[compute]
#version 450

layout(set = 0, binding = 0, std430) restrict readonly buffer GlobalParams {
    vec3 grid_size;
    float iso_level;
    float flat_shaded;
    float noise_frequency;
    float fractal_octaves;
    float terrain_terrace;
    int noise_type;  // 0=Perlin, 1=Simplex, 2=Cellular
    float noise_gain;
    float noise_lacunarity;
    float cellular_jitter;
} global_params;

layout(set = 0, binding = 1, std430) restrict readonly buffer LookupTable {
    int data[];
} lookup_table;

layout(set = 1, binding = 0, std430) restrict readonly buffer ChunkData {
    vec3 chunk_coords;
    float chunk_size;
} chunk_data;

layout(set = 1, binding = 1, std430) restrict buffer Counter {
    int triangle_count;
} counter;

layout(set = 1, binding = 2, std430) restrict buffer Vertices {
    vec4 data[];
} vertices;

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;


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

int hash(int x) {
    return PERM[x & 255];
}

vec3 hash3(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx);
}

float fade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

vec3 grad3_perlin(int hash_val) {
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

float perlin_noise(vec3 p) {
    ivec3 pi = ivec3(floor(p)) & 255;
    vec3 pf = fract(p);
    vec3 u = vec3(fade(pf.x), fade(pf.y), fade(pf.z));
    
    int aaa = hash(hash(hash(pi.x    ) + pi.y    ) + pi.z    );
    int aba = hash(hash(hash(pi.x    ) + pi.y + 1) + pi.z    );
    int aab = hash(hash(hash(pi.x    ) + pi.y    ) + pi.z + 1);
    int abb = hash(hash(hash(pi.x    ) + pi.y + 1) + pi.z + 1);
    int baa = hash(hash(hash(pi.x + 1) + pi.y    ) + pi.z    );
    int bba = hash(hash(hash(pi.x + 1) + pi.y + 1) + pi.z    );
    int bab = hash(hash(hash(pi.x + 1) + pi.y    ) + pi.z + 1);
    int bbb = hash(hash(hash(pi.x + 1) + pi.y + 1) + pi.z + 1);
    
    float g000 = dot(grad3_perlin(aaa), pf - vec3(0.0, 0.0, 0.0));
    float g100 = dot(grad3_perlin(baa), pf - vec3(1.0, 0.0, 0.0));
    float g010 = dot(grad3_perlin(aba), pf - vec3(0.0, 1.0, 0.0));
    float g110 = dot(grad3_perlin(bba), pf - vec3(1.0, 1.0, 0.0));
    float g001 = dot(grad3_perlin(aab), pf - vec3(0.0, 0.0, 1.0));
    float g101 = dot(grad3_perlin(bab), pf - vec3(1.0, 0.0, 1.0));
    float g011 = dot(grad3_perlin(abb), pf - vec3(0.0, 1.0, 1.0));
    float g111 = dot(grad3_perlin(bbb), pf - vec3(1.0, 1.0, 1.0));
    
    float x00 = mix(g000, g100, u.x);
    float x10 = mix(g010, g110, u.x);
    float x01 = mix(g001, g101, u.x);
    float x11 = mix(g011, g111, u.x);
    
    float y0 = mix(x00, x10, u.y);
    float y1 = mix(x01, x11, u.y);
    
    return mix(y0, y1, u.z);
}

vec3 mod289_vec3(vec3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec4 mod289_vec4(vec4 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec4 permute(vec4 x) {
    return mod289_vec4(((x * 34.0) + 1.0) * x);
}

vec4 taylorInvSqrt(vec4 r) {
    return 1.79284291400159 - 0.85373472095314 * r;
}

float simplex_noise(vec3 v) {
    const vec2 C = vec2(1.0/6.0, 1.0/3.0);
    const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
    
    vec3 i  = floor(v + dot(v, C.yyy));
    vec3 x0 = v - i + dot(i, C.xxx);
    
    vec3 g = step(x0.yzx, x0.xyz);
    vec3 l = 1.0 - g;
    vec3 i1 = min(g.xyz, l.zxy);
    vec3 i2 = max(g.xyz, l.zxy);
    
    vec3 x1 = x0 - i1 + C.xxx;
    vec3 x2 = x0 - i2 + C.yyy;
    vec3 x3 = x0 - D.yyy;
    
    i = mod289_vec3(i);
    vec4 p = permute(permute(permute(
             i.z + vec4(0.0, i1.z, i2.z, 1.0))
           + i.y + vec4(0.0, i1.y, i2.y, 1.0))
           + i.x + vec4(0.0, i1.x, i2.x, 1.0));
    
    float n_ = 0.142857142857;
    vec3 ns = n_ * D.wyz - D.xzx;
    
    vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
    
    vec4 x_ = floor(j * ns.z);
    vec4 y_ = floor(j - 7.0 * x_);
    
    vec4 x = x_ * ns.x + ns.yyyy;
    vec4 y = y_ * ns.x + ns.yyyy;
    vec4 h = 1.0 - abs(x) - abs(y);
    
    vec4 b0 = vec4(x.xy, y.xy);
    vec4 b1 = vec4(x.zw, y.zw);
    
    vec4 s0 = floor(b0) * 2.0 + 1.0;
    vec4 s1 = floor(b1) * 2.0 + 1.0;
    vec4 sh = -step(h, vec4(0.0));
    
    vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    
    vec3 p0 = vec3(a0.xy, h.x);
    vec3 p1 = vec3(a0.zw, h.y);
    vec3 p2 = vec3(a1.xy, h.z);
    vec3 p3 = vec3(a1.zw, h.w);
    
    vec4 norm = taylorInvSqrt(vec4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
    p0 *= norm.x;
    p1 *= norm.y;
    p2 *= norm.z;
    p3 *= norm.w;
    
    vec4 m = max(0.6 - vec4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m*m, vec4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
}

float cellular_noise(vec3 p) {
    vec3 pi = floor(p);
    vec3 pf = fract(p);
    
    float min_dist = 10.0;
    float second_min_dist = 10.0;
    
    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec3 neighbor = vec3(float(x), float(y), float(z));
                vec3 cell = pi + neighbor;
                
                vec3 point = hash3(cell);
                
                point = neighbor + mix(vec3(0.5), point, global_params.cellular_jitter);
                
                vec3 diff = point - pf;
                float dist = length(diff);
                
                if (dist < min_dist) {
                    second_min_dist = min_dist;
                    min_dist = dist;
                } else if (dist < second_min_dist) {
                    second_min_dist = dist;
                }
            }
        }
    }
    
    return (min_dist * 2.0) - 1.0;
}


float fbm(vec3 p, int octaves, int noise_type) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    float max_value = 0.0;
    
    for (int i = 0; i < octaves; i++) {
        float noise_val;
        
        if (noise_type == 0) {
            noise_val = perlin_noise(p * frequency);
        } else if (noise_type == 1) {
            noise_val = simplex_noise(p * frequency);
        } else {
            noise_val = cellular_noise(p * frequency);
        }
        
        value += amplitude * noise_val;
        max_value += amplitude;
        
        frequency *= global_params.noise_lacunarity;
        amplitude *= global_params.noise_gain;
    }
    
    return value / max_value;
}

float get_noise_value(vec3 world_pos) {
    vec3 scaled_pos = world_pos * global_params.noise_frequency;
    return fbm(scaled_pos, int(global_params.fractal_octaves), global_params.noise_type);
}

float get_voxel_value(ivec3 local_pos) {
    vec3 world_offset = chunk_data.chunk_coords * chunk_data.chunk_size;
    vec3 world_pos = world_offset + vec3(local_pos);
    
    float noise_val = get_noise_value(world_pos);
    
    return noise_val;
}

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

vec3 calculate_normal(vec3 p, float delta_multiplier) {
    float delta = 1.0 * delta_multiplier;
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

void main() {
    ivec3 grid_pos = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 grid_size_int = ivec3(global_params.grid_size);
    
    if (grid_pos.x >= grid_size_int.x - 1 || 
        grid_pos.y >= grid_size_int.y - 1 || 
        grid_pos.z >= grid_size_int.z - 1) {
        return;
    }
    
    float cube_values[8];
    cube_values[0] = get_voxel_value(grid_pos + ivec3(0, 0, 0));
    cube_values[1] = get_voxel_value(grid_pos + ivec3(1, 0, 0));
    cube_values[2] = get_voxel_value(grid_pos + ivec3(1, 1, 0));
    cube_values[3] = get_voxel_value(grid_pos + ivec3(0, 1, 0));
    cube_values[4] = get_voxel_value(grid_pos + ivec3(0, 0, 1));
    cube_values[5] = get_voxel_value(grid_pos + ivec3(1, 0, 1));
    cube_values[6] = get_voxel_value(grid_pos + ivec3(1, 1, 1));
    cube_values[7] = get_voxel_value(grid_pos + ivec3(0, 1, 1));
    
    int cube_index = 0;
    if (cube_values[0] < global_params.iso_level) cube_index |= 1;
    if (cube_values[1] < global_params.iso_level) cube_index |= 2;
    if (cube_values[2] < global_params.iso_level) cube_index |= 4;
    if (cube_values[3] < global_params.iso_level) cube_index |= 8;
    if (cube_values[4] < global_params.iso_level) cube_index |= 16;
    if (cube_values[5] < global_params.iso_level) cube_index |= 32;
    if (cube_values[6] < global_params.iso_level) cube_index |= 64;
    if (cube_values[7] < global_params.iso_level) cube_index |= 128;
    
    if (cube_index == 0 || cube_index == 255) {
        return;
    }
    
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
    
    int lut_offset = cube_index * 16;
    
    vec3 cached_normals[12];
    bool normal_computed[12] = bool[12](false, false, false, false, false, false, false, false, false, false, false, false);
    
    for (int i = 0; i < 5; i++) {
        int edge0 = lookup_table.data[lut_offset + i * 3 + 0];
        int edge1 = lookup_table.data[lut_offset + i * 3 + 1];
        int edge2 = lookup_table.data[lut_offset + i * 3 + 2];
        
        if (edge0 == -1) break;
        
        vec3 v0 = edge_vertices[edge0];
        vec3 v1 = edge_vertices[edge1];
        vec3 v2 = edge_vertices[edge2];
        
        vec3 normal;
        if (global_params.flat_shaded > 0.5) {
            normal = normalize(cross(v1 - v0, v2 - v0));
        } else {
            if (!normal_computed[edge0]) {
                cached_normals[edge0] = calculate_normal(v0, 0.5);
                normal_computed[edge0] = true;
            }
            if (!normal_computed[edge1]) {
                cached_normals[edge1] = calculate_normal(v1, 0.5);
                normal_computed[edge1] = true;
            }
            if (!normal_computed[edge2]) {
                cached_normals[edge2] = calculate_normal(v2, 0.5);
                normal_computed[edge2] = true;
            }
            normal = normalize(cached_normals[edge0] + cached_normals[edge1] + cached_normals[edge2]);
        }
        
        int tri_index = atomicAdd(counter.triangle_count, 1);
        int base_index = tri_index * 4;
        
        vertices.data[base_index + 0] = vec4(v0, 0.0);
        vertices.data[base_index + 1] = vec4(v1, 0.0);
        vertices.data[base_index + 2] = vec4(v2, 0.0);
        vertices.data[base_index + 3] = vec4(normal, 0.0);
    }
}