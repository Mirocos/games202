#ifdef GL_ES
precision mediump float;
#endif

// Phong related variables
uniform sampler2D uSampler;
uniform vec3 uKd;
uniform vec3 uKs;
uniform vec3 uLightPos;
uniform vec3 uCameraPos;
uniform vec3 uLightIntensity;

varying highp vec2 vTextureCoord;
varying highp vec3 vFragPos;
varying highp vec3 vNormal;

// Shadow map related variables
#define NUM_SAMPLES 64
#define BLOCKER_SEARCH_NUM_SAMPLES NUM_SAMPLES
#define PCF_NUM_SAMPLES NUM_SAMPLES
#define NUM_RINGS 5
#define FILTER_SIZE (1.0/2048.0)
#define LIGHT_SIZE  6.0


#define EPS 1e-3
#define PI 3.141592653589793
#define PI2 6.283185307179586

uniform sampler2D uShadowMap;

varying vec4 vPositionFromLight;

float filter_size = 0.0;

highp float dynamicBias(){
    vec3 light_direction = normalize(uLightPos);
    vec3 frag_normal = normalize(vNormal);
    float  bias = 0.005 * tan(acos(min(dot(light_direction, frag_normal) + EPS, 1.0)));
    
    return min(max(0.0, bias), 0.01);
    // return dot(light_direction, frag_normal) * 0.0008  + 0.0008;
    
}



highp float rand_1to1(highp float x ) { 
  // -1 -1
  return fract(sin(x)*10000.0);
}

highp float rand_2to1(vec2 uv ) { 
  // 0 - 1
	const highp float a = 12.9898, b = 78.233, c = 43758.5453;
	highp float dt = dot( uv.xy, vec2( a,b ) ), sn = mod( dt, PI );
	return fract(sin(sn) * c);
}

float unpack(vec4 rgbaDepth) {
    const vec4 bitShift = vec4(1.0, 1.0/255.0, 1.0/(255.0*255.0), 1.0/(255.0*255.0*255.0));
    return dot(rgbaDepth, bitShift);
}

vec2 poissonDisk[NUM_SAMPLES];

void poissonDiskSamples( const in vec2 randomSeed ) {

  float ANGLE_STEP = PI2 * float( NUM_RINGS ) / float( NUM_SAMPLES );
  float INV_NUM_SAMPLES = 1.0 / float( NUM_SAMPLES );

  float angle = rand_2to1( randomSeed ) * PI2;
  float radius = INV_NUM_SAMPLES;
  float radiusStep = radius;

  for( int i = 0; i < NUM_SAMPLES; i ++ ) {
    poissonDisk[i] = vec2( cos( angle ), sin( angle ) ) * pow( radius, 0.75 );
    radius += radiusStep;
    angle += ANGLE_STEP;
  }
}

void uniformDiskSamples( const in vec2 randomSeed ) {

  float randNum = rand_2to1(randomSeed);
  float sampleX = rand_1to1( randNum ) ;
  float sampleY = rand_1to1( sampleX ) ;

  float angle = sampleX * PI2;
  float radius = sqrt(sampleY);

  for( int i = 0; i < NUM_SAMPLES; i ++ ) {
    poissonDisk[i] = vec2( radius * cos(angle) , radius * sin(angle)  );

    sampleX = rand_1to1( sampleY ) ;
    sampleY = rand_1to1( sampleX ) ;

    angle = sampleX * PI2;
    radius = sqrt(sampleY);
  }
}


float findBlocker( sampler2D shadowMap,  vec2 uv, float zReceiver ) {
  int block_num = 0;
  float block_depth = 0.0;
  for(int i = 0 ; i < NUM_SAMPLES; i++){
    vec4 region_sample_rgba = texture2D(shadowMap, FILTER_SIZE * poissonDisk[i] * 8.0+ uv);
    float region_sample_depth = unpack(region_sample_rgba);
    if(zReceiver > region_sample_depth + dynamicBias())
    {
      block_depth += region_sample_depth;
      block_num += 1;
    }
  }

  if(block_num == 0)
    return -1.0;
  
  if(block_num == NUM_SAMPLES)
    return 2.0;

	return block_depth / float(block_num);
}

float PCF(sampler2D shadowMap, vec4 coords) {
  vec3 coords_xyz = coords.xyz * 0.5 + vec3(0.5);
  vec2 randomSeed = coords_xyz.xy;
  float shadow_depth = coords_xyz.z;
  poissonDiskSamples(randomSeed);
  float kernel_sum = 0.0;
  for(int i = 0; i < NUM_SAMPLES; i++)
  {
    vec4 sample_rgba = texture2D(shadowMap, poissonDisk[i] * FILTER_SIZE * 2.0+ coords_xyz.xy);
    float sample_depth = unpack(sample_rgba);
    
    if(shadow_depth < sample_depth + dynamicBias())
      kernel_sum += 1.0;
  }

  float visibility = float(NUM_SAMPLES);
  visibility = kernel_sum /  visibility;
 
  return visibility;
}

float PCSS(sampler2D shadowMap, vec4 coords){

  vec3 coords_xyz = coords.xyz * 0.5 + vec3(0.5);
  poissonDiskSamples(coords_xyz.xy);

  // STEP 1: avgblocker depth
  float z_Blocker = findBlocker(shadowMap, coords_xyz.xy, coords_xyz.z);
  if(z_Blocker < 0.0)
    return 1.0;
  
  if(z_Blocker > 1.0 + EPS)
    return 0.0;
  
  // STEP 2: penumbra size

  float penumbra = (coords_xyz.z - z_Blocker) * LIGHT_SIZE / z_Blocker;

  // return filter_size;
  float kernel_sum = 0.0;
  for(int i = 0; i < NUM_SAMPLES; i++){
    vec4 sample_rgba = texture2D(shadowMap, poissonDisk[i] * penumbra  / 2048.0 + coords_xyz.xy);
    float sample_depth = unpack(sample_rgba);
    if(coords_xyz.z < sample_depth + dynamicBias()){
      kernel_sum += 1.0;
    }
  }
  float visibility = kernel_sum / float(NUM_SAMPLES);
  visibility = max(visibility, 0.0);
  return visibility;

}


float useShadowMap(sampler2D shadowMap, vec4 shadowCoord){

  vec3 shadowCoord_xyz = shadowCoord.xyz * 0.5 + vec3(0.5);
  vec4 rgbaDepth = texture2D(shadowMap, shadowCoord_xyz.xy);
  float shadowDepth = unpack(rgbaDepth);
  float bias = 0.0018;
  if(shadowCoord_xyz.z   <  shadowDepth +dynamicBias())
    return 1.0;
  else 
    return 0.0;
  return shadowDepth;
}

vec3 blinnPhong() {
  vec3 color = texture2D(uSampler, vTextureCoord).rgb;
  color = pow(color, vec3(2.2));

  // vec3 ambient = 0.05 * color;

  vec3 lightDir = normalize(uLightPos);
  vec3 normal = normalize(vNormal);
  float diff = max(dot(lightDir, normal), 0.0);
  vec3 light_atten_coff =
      uLightIntensity / pow(length(uLightPos - vFragPos), 2.0);
  vec3 diffuse = diff * light_atten_coff * color;

  vec3 viewDir = normalize(uCameraPos - vFragPos);
  vec3 halfDir = normalize((lightDir + viewDir));
  float spec = pow(max(dot(halfDir, normal), 0.0), 32.0);
  vec3 specular = uKs * light_atten_coff * spec;

  vec3 radiance = (diffuse + specular);
  vec3 phongColor = pow(radiance, vec3(1.0 / 2.2));
  return phongColor;
}

void main(void) {

  float visibility = 1.0;
  vec3 shadowCoord = vPositionFromLight.xyz / vPositionFromLight.w;
  // visibility = useShadowMap(uShadowMap, vec4(shadowCoord, 1.0));
  // visibility = PCF(uShadowMap, vec4(shadowCoord, 1.0));
  visibility = PCSS(uShadowMap, vec4(shadowCoord, 1.0));

  vec3 phongColor = blinnPhong();
  vec3 color = texture2D(uSampler, vTextureCoord).rgb;
  color = pow(color, vec3(2.2));

  vec3 ambient = 0.05 * color;

  gl_FragColor = vec4(phongColor * visibility + ambient, 1.0);
  // gl_FragColor = vec4(visibility, 0.0, 0.0 , 1.0);
}