#ifndef UNITOON_2020_1_FORWARD_LIT_PASS_INCLUDED
#define UNITOON_2020_1_FORWARD_LIT_PASS_INCLUDED

#include "./Lighting.hlsl"
#include "../UniToonFunctions.hlsl"

struct Attributes
{
    float4 positionOS   : POSITION;
    float3 normalOS     : NORMAL;
    float4 tangentOS    : TANGENT;
    float2 texcoord     : TEXCOORD0;
    float2 lightmapUV   : TEXCOORD1;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct Varyings
{
    float2 uv                       : TEXCOORD0;
    DECLARE_LIGHTMAP_OR_SH(lightmapUV, vertexSH, 1);

#if defined(REQUIRES_WORLD_SPACE_POS_INTERPOLATOR)
    float3 positionWS               : TEXCOORD2;
#endif

    float3 normalWS                 : TEXCOORD3;
#ifdef _NORMALMAP
    float4 tangentWS                : TEXCOORD4;    // xyz: tangent, w: sign
#endif
    float3 viewDirWS                : TEXCOORD5;

    half4 fogFactorAndVertexLight   : TEXCOORD6; // x: fogFactor, yzw: vertex light

#if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    float4 shadowCoord              : TEXCOORD7;
#endif

    float4 screenPos                : TEXCOORD8;
    float3 normalCorrectWS          : TEXCOORD9;
    float3 shadowCorrectWS          : TEXCOORD10;

    float4 positionCS               : SV_POSITION;
    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

void InitializeInputData(Varyings input, half3 normalTS, out InputData inputData)
{
    inputData = (InputData)0;

#if defined(REQUIRES_WORLD_SPACE_POS_INTERPOLATOR)
    inputData.positionWS = input.positionWS;
#endif

    half3 viewDirWS = SafeNormalize(input.viewDirWS);
#ifdef _NORMALMAP 
    float sgn = input.tangentWS.w;      // should be either +1 or -1
    float3 bitangent = sgn * cross(input.normalWS.xyz, input.tangentWS.xyz);
    inputData.normalWS = TransformTangentToWorld(normalTS, half3x3(input.tangentWS.xyz, bitangent.xyz, input.normalWS.xyz));
#else
    inputData.normalWS = input.normalWS;
#endif

    inputData.normalWS = NormalizeNormalPerPixel(inputData.normalWS);
    inputData.viewDirectionWS = viewDirWS;

#if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    inputData.shadowCoord = input.shadowCoord;
#elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)
    inputData.shadowCoord = TransformWorldToShadowCoord(input.shadowCorrectWS);
#else
    inputData.shadowCoord = float4(0, 0, 0, 0);
#endif

    inputData.fogCoord = input.fogFactorAndVertexLight.x;
    inputData.vertexLighting = input.fogFactorAndVertexLight.yzw;
    inputData.bakedGI = SAMPLE_GI(input.lightmapUV, input.vertexSH, inputData.normalWS);
}

///////////////////////////////////////////////////////////////////////////////
//                  Vertex and Fragment functions                            //
///////////////////////////////////////////////////////////////////////////////

// Used in Standard (Physically Based) shader
Varyings LitPassVertex(Attributes input)
{
    Varyings output = (Varyings)0;

    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_TRANSFER_INSTANCE_ID(input, output);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

    VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
    
    // normalWS and tangentWS already normalize.
    // this is required to avoid skewing the direction during interpolation
    // also required for per-vertex lighting and SH evaluation
    VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);
    float3 viewDirWS = GetCameraPositionWS() - vertexInput.positionWS;
    half3 vertexLight = VertexLighting(vertexInput.positionWS, normalInput.normalWS);
    half fogFactor = ComputeFogFactor(vertexInput.positionCS.z);

    output.uv = TRANSFORM_TEX(input.texcoord, _BaseMap);

    // already normalized from normal transform to WS.
    output.normalWS = normalInput.normalWS;
    output.viewDirWS = viewDirWS;
#ifdef _NORMALMAP
    real sign = input.tangentOS.w * GetOddNegativeScale();
    output.tangentWS = half4(normalInput.tangentWS.xyz, sign);
#endif

    OUTPUT_LIGHTMAP_UV(input.lightmapUV, unity_LightmapST, output.lightmapUV);
    OUTPUT_SH(output.normalWS.xyz, output.vertexSH);

    output.fogFactorAndVertexLight = half4(fogFactor, vertexLight);

#if defined(REQUIRES_WORLD_SPACE_POS_INTERPOLATOR)
    output.positionWS = vertexInput.positionWS;
#endif

#if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)

    float3 shadowCorrectDir = (input.positionOS.xyz - _ShadowCorrectOrigin);
    shadowCorrectDir = SafeNormalize(shadowCorrectDir);
    float3 shadowCorrectOS = _ShadowCorrectOrigin + shadowCorrectDir * _ShadowCorrectRadius;
    VertexPositionInputs shadowVertexInput = GetVertexPositionInputs(lerp(input.positionOS.xyz, shadowCorrectOS, _ShadowCorrect));
    output.shadowCoord = GetShadowCoord(shadowVertexInput);

#elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)

    float3 shadowCorrectDir = (input.positionOS.xyz - _ShadowCorrectOrigin);
    shadowCorrectDir = SafeNormalize(shadowCorrectDir);
    float3 shadowCorrectOS = _ShadowCorrectOrigin + shadowCorrectDir * _ShadowCorrectRadius;
    output.shadowCorrectWS = TransformObjectToWorld(lerp(input.positionOS.xyz, shadowCorrectOS, _ShadowCorrect));

#endif

    output.positionCS = vertexInput.positionCS;
    output.screenPos = output.positionCS;

    float3 normalCorrectOS = (input.positionOS.xyz - _NormalCorrectOrigin);
    float3 normalCorrectDir = normalCorrectOS;
    normalCorrectDir.y = 0.0;
    normalCorrectDir = SafeNormalize(normalCorrectDir);
    output.normalCorrectWS = TransformObjectToWorldNormal(normalCorrectDir);

    return output;
}

// Used in Standard (Physically Based) shader
half4 LitPassFragment(Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

    SurfaceData surfaceData;
    InitializeStandardLitSurfaceData(input.uv, surfaceData);

    InputData inputData;
    InitializeInputData(input, surfaceData.normalTS, inputData);

    half3 shadeColor = SAMPLE_TEXTURE2D(_ShadeMap, sampler_ShadeMap, input.uv).rgb;
    shadeColor = shift(shadeColor, half3(_ShadeHue, _ShadeSaturation, _ShadeBrightness)) * _ShadeColor.rgb;
    half ramp;

    // normal correct
    inputData.normalWS = normalize(lerp(inputData.normalWS, input.normalCorrectWS, _NormalCorrect));

    half4 color = UniToonFragmentPBR(inputData, surfaceData.albedo, surfaceData.metallic, surfaceData.specular, surfaceData.smoothness, surfaceData.occlusion, surfaceData.emission, surfaceData.alpha, shadeColor, _ToonyFactor, ramp);
    
    // Outline
#if !(defined(_ALPHAPREMULTIPLY_ON) || defined(_ALPHABLEND_ON))
    if (_OutlineWidth > 0.0 && _OutlineStrength > 0.0)
    {
        float2 screenPos = ComputeScreenPos(input.screenPos / input.screenPos.w).xy;
        half width = lerp(_OutlineWidth, _OutlineWidth * 0.5, ramp * _OutlineLightAffects);
        width *= SAMPLE_TEXTURE2D(_OutlineMask, sampler_OutlineMask, input.uv).r;
        half outlineFactor = SoftOutline(screenPos, width, _OutlineStrength, _OutlineSmoothness);
        color.rgb = lerp(color.rgb, shift(color.rgb, half3(0.0, _OutlineSaturation, lerp(_OutlineBrightness, saturate(_OutlineBrightness * 2.0), ramp * _OutlineLightAffects))), outlineFactor);
    }
#endif

    color.rgb = MixFog(color.rgb, inputData.fogCoord);

    return color;
}

#endif
