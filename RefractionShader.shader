Shader "Rayzar/RefractionShader"
{
    Properties {
        _Refractive_index ("Refractive Index", Range(1.0, 2.0)) = 1.5
        _Thickness ("Glass Thickness", Range(0.0, 5.0)) = 0.1
        _Dispersion_amt ("Dispersion Amount", Range(0.0, 1.0)) = 0.0
        _Color ("Color", COLOR) = (1,1,1,1)
        _NormalMapStrength ("Normal Map Strength", Range(0.0, 3.0)) = 1.0
        [NoScaleOffset]_NormalMap("NormalMap", 2D) = "bump" {}
    }   

    SubShader {
        Tags {"Queue"="Transparent+4" "RenderType"="Opaque"}
        ZWrite On
        Cull Off
        Lighting On
        LOD 100

        GrabPass {
            "_BackgroundTexture"
        }
        
        Pass {
            name "Refraction Pass"
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma exclude_renderers d3d11_9x
            #pragma exclude_renderers d3d9
            #pragma target 5.0
            #pragma multi_compile _ALPHAPREMULTIPLY_ON

            #include "UnityCG.cginc"
            #include "UnityStandardUtils.cginc"

            float _Refractive_index;
            float _Thickness;
            float _Dispersion_amt;
            float _NormalMapStrength;
            float4 _Color;
            
            sampler2D _CameraDepthTexture;
            sampler2D _BackgroundTexture;
            sampler2D _NormalMap;

            float4 _BackgroundTexture_TexelSize;

            struct v2f {
                float4 texcoord : TEXCOORD0;
                float3 worldDirection : TEXCOORD1;
                float4 vertex : SV_POSITION;

                float3 T : TEXCOORD2;
				float3 B : TEXCOORD3;
				float3 N : TEXCOORD4;
                float2 uv : TEXCOORD5;
                UNITY_VERTEX_INPUT_INSTANCE_ID
				UNITY_VERTEX_OUTPUT_STEREO
            }; 

            v2f vert (appdata_full v) {
                v2f o;
                UNITY_SETUP_INSTANCE_ID( v );
				UNITY_INITIALIZE_OUTPUT( v2f, o );
				UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO( o );
				UNITY_TRANSFER_INSTANCE_ID( v, o );

                float3 cameraPos = _WorldSpaceCameraPos;

                o.worldDirection = mul(unity_ObjectToWorld, v.vertex).xyz - cameraPos;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.texcoord = ComputeGrabScreenPos(o.vertex);
                
                o.N = UnityObjectToWorldNormal(v.normal);
                o.T = UnityObjectToWorldDir(v.tangent.xyz);

                float tangentSign = v.tangent.w * unity_WorldTransformParams.w;

                o.B = cross(o.N, o.T) * tangentSign;

                o.uv = v.texcoord.xy;

                return o;
            }

            struct fragOutput {
                float4 color : COLOR;
            };

            float2 worldToUv(float3 pos) {
                float4 clipPosition = mul(UNITY_MATRIX_VP, pos);
                float2 ndc = clipPosition.xy / clipPosition.w;
                float2 screenUV = (ndc + 1.0) * 0.5;
                screenUV.y = 1.0 - screenUV.y;

                return screenUV;
            }

            float worldToDepth(float3 pos) {
                float4 clipPosition = mul(UNITY_MATRIX_VP, pos);

                return clipPosition.w;
            }

            float intersectPlane(float3 ro, float3 rd, float3 n, float d) {
                float NoV = -dot(rd, n);

                return d / NoV;
            }

            float calculateRelativeDepth(float2 uv, float3 rd, float3 forward) {
                float linCorrect = 1.0 / dot(rd, forward);

                float depth = UNITY_SAMPLE_DEPTH(tex2D(_CameraDepthTexture, uv));
                float eyeDepth = LinearEyeDepth(depth);

                return eyeDepth * linCorrect;
            }

            float2 rayTraceRefraction(float3 origin, float3 maxStep, float3 direction) {
                const int steps = 50;

                float3 increment = direction * 20.0 / float(steps);
                float3 pos = origin;
                float2 uv = float2(0.0, 0.0);

                for (int i = 0; i < steps; i++) {
                    uv = worldToUv(pos); 

                    float posZ = worldToDepth(pos);
                    float depthZ = LinearEyeDepth(UNITY_SAMPLE_DEPTH(tex2D(_CameraDepthTexture, uv)));

                    if (posZ > depthZ) {
                        return uv;
                    }

                    pos += increment;
                }

                return worldToUv(pos + direction * distance(pos, maxStep));
            }

            float2 calculateRefractiveUv(float3 worldVector, float2 texcoord, float3 normal, float3 flatNormal, float3 frontPosition, float3 backPosition, float ri, float thickness) {
                float3 refractVectorIn = refract(worldVector, normal, 1.0 / ri);
                float backPlane = intersectPlane(frontPosition, refractVectorIn, normal, thickness);
                float3 posIn = frontPosition + refractVectorIn * min(backPlane, distance(frontPosition, backPosition));
                
                float3 refractVectorOut = refract(refractVectorIn, normal, ri);

                if (length(refractVectorOut) < 0.01) {
                    refractVectorOut = reflect(refractVectorIn, normal);
                }

                float distantPlane = distance(posIn, backPosition);
                float3 posOut = posIn + refractVectorOut;

                float2 newUv = worldToUv(posOut);
                float newDepth = LinearEyeDepth(UNITY_SAMPLE_DEPTH(tex2D(_CameraDepthTexture, newUv)));

                if (worldToDepth(frontPosition) > newDepth) {
                    return texcoord;
                }

                return newUv;
                //return rayTraceRefraction(posIn, backPosition, refractVectorOut);
            }

            float getDispIndex(float index, float d) {
                return index + (index - 1.0) * _Dispersion_amt * d;
            }

            fragOutput frag (v2f i) {
                UNITY_SETUP_INSTANCE_ID(i);

                fragOutput o;
                float3x3 TBN = float3x3(normalize(i.T), normalize(i.B), normalize(i.N));

                float2 texcoord = i.texcoord.xy / i.texcoord.w;
                float3 normalMap = UnpackScaleNormal(tex2D(_NormalMap, i.uv), _NormalMapStrength);

                float3 normal = mul(transpose(TBN), normalMap);
                float3 worldVector = normalize(i.worldDirection);
                
                float NoV = dot(TBN[2], worldVector);
                if (NoV > 0.0) {
                    TBN[2] = -TBN[2];
                }

                float3 forward = normalize(mul((float3x3)unity_CameraToWorld, float3(0,0,1)));
                float eyeDepth = calculateRelativeDepth(texcoord, worldVector, forward);
                
                float3 backPosition = worldVector * eyeDepth;
                float3 frontPosition = i.worldDirection;

                float2 screenUV_r = calculateRefractiveUv(worldVector, texcoord, normal, TBN[2], frontPosition, backPosition, getDispIndex(_Refractive_index, 0.0), _Thickness);
                float2 screenUV_g = calculateRefractiveUv(worldVector, texcoord, normal, TBN[2], frontPosition, backPosition, getDispIndex(_Refractive_index, 1.0), _Thickness);
                float2 screenUV_b = calculateRefractiveUv(worldVector, texcoord, normal, TBN[2], frontPosition, backPosition, getDispIndex(_Refractive_index, 2.0), _Thickness);

                float color_r = tex2D(_BackgroundTexture, screenUV_r).r;
                float color_g = tex2D(_BackgroundTexture, screenUV_g).g;
                float color_b = tex2D(_BackgroundTexture, screenUV_b).b;
                const float3 atten = float3(0.3, 0.2, 0.1);

                float3 color = float3(color_r, color_g, color_b);

                o.color = float4(color * _Color.rgb, 1.0); // multiply by _Color

                return o;
            }

            ENDCG
        }
    }
}
