#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

//output buffer for voxel data
layout(set = 0, binding = 0, std430) restrict buffer VoxelData {
    float data[];
} voxel_data;

//push_constant parameters is a way to pass small amounts of data to the shader efficiently WITHOUT USING BUFFERS
//you need to supply the compute shader with 64 bytes when using constants
layout(push_constant, std430) uniform Params {
    vec3 world_offset;
    float iso_level;
    int chunk_size;

    // FastNoiseLite parameters
    float frequency;
    int noise_type;
    int fractal_type;
    int fractal_octaves;
    float fractal_lacunarity;
    float fractal_gain;
    float fractal_weighted_strength;
    float fractal_ping_pong_strength;
    int seed;
} params;



//hash function for pseudo-random number generation
float hash(vec3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

//simplified Perlin-style noise
float noise3D(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    // Cubic interpolation
    f = f * f * (3.0 - 2.0 * f);
    
    // Hash corners
    float n000 = hash(i + vec3(0.0, 0.0, 0.0));
    float n100 = hash(i + vec3(1.0, 0.0, 0.0));
    float n010 = hash(i + vec3(0.0, 1.0, 0.0));
    float n110 = hash(i + vec3(1.0, 1.0, 0.0));
    float n001 = hash(i + vec3(0.0, 0.0, 1.0));
    float n101 = hash(i + vec3(1.0, 0.0, 1.0));
    float n011 = hash(i + vec3(0.0, 1.0, 1.0));
    float n111 = hash(i + vec3(1.0, 1.0, 1.0));
    
    // Trilinear interpolation
    float x00 = mix(n000, n100, f.x);
    float x10 = mix(n010, n110, f.x);
    float x01 = mix(n001, n101, f.x);
    float x11 = mix(n011, n111, f.x);
    
    float y0 = mix(x00, x10, f.y);
    float y1 = mix(x01, x11, f.y);
    
    return mix(y0, y1, f.z) * 2.0 - 1.0;
}

// FBM (Fractal Brownian Motion) for fractal noise
float fbm(vec3 p) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = params.frequency;
    
    for (int i = 0; i < params.fractal_octaves; i++) {
        value += amplitude * noise3D(p * frequency);
        frequency *= params.fractal_lacunarity;
        amplitude *= params.fractal_gain;
    }
    
    return value;
}

void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    int resolution = params.chunk_size + 1;
    
    // Check bounds
    if (pos.x >= resolution || pos.y >= resolution || pos.z >= resolution) {
        return;
    }
    
    vec3 world_pos = params.world_offset + vec3(pos);
    
    world_pos += vec3(float(params.seed) * 1337.0);
    
    float value = fbm(world_pos);
    
    // Calculate 1D index from 3D coordinates
    int index = pos.x + pos.y * resolution + pos.z * resolution * resolution;
    
    voxel_data.data[index] = value;
}