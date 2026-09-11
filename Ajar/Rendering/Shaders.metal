#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 field;    // progress, boundary offset, curvature, softness
    float4 effect;   // max sigma in source pixels, perspective, scale, crossfade width
    float4 look;     // reverse, debug mask, luminance, contrast
    float4 geometry;// viewport aspect, source aspect, unused, unused
    float4 motion;  // motion mode, blur strength, signed direction, gradient mode
    float4 canvas;  // padding left, right and top, in picture-height units
};
struct VertexOut { float4 position [[position]]; float2 uv; };
vertex VertexOut fullscreen(uint id [[vertex_id]]) {
    float2 point = float2((id << 1) & 2, id & 2);
    VertexOut out;
    out.position = float4(point * float2(2,-2) + float2(-1,1),0,1);
    out.uv = point;
    return out;
}
float fieldMask(float2 uv, constant Uniforms& u) {
    float p = u.field.x, offset = u.field.y, curvature = u.field.z, softness = u.field.w;
    float margin = 0.02 + abs(curvature)*0.25 + softness + abs(offset);
    float boundary = mix(-margin,1+margin,p) + offset + curvature*pow(uv.y-0.5,2.0);
    float x = u.look.x > 0.5 ? 1-uv.x : uv.x;
    return 1-smoothstep(-softness,softness,x-boundary);
}
float2 surfaceUV(float2 uv, float depth, constant Uniforms& u) {
    float2 q = uv-0.5;
    // Aspect-fill the pre-rendered surface; apply a small projective transform.
    float ratio = u.geometry.x/u.geometry.y;
    if (ratio > 1) q.y /= ratio; else q.x *= ratio;
    q /= 1 + u.effect.z*depth;
    q /= max(0.75,1 + u.effect.y*depth*q.x*2);
    q.x -= depth*0.015;
    return q+0.5;
}

// Whole-screen depth field for the motion/settle interaction. The amount comes
// from how far the image lag has drifted from the lid, never from absolute
// angle, so no lid position is special.
float motionField(float2 q, constant Uniforms& u) {
    float amount = u.motion.y;
    // Distance from the hinge, in picture units: 0 at the hinge line, 1 at the
    // free edge, clamped inside the picture so the padding reads as "beyond the
    // free edge" and gets the heaviest blur.
    float fromHinge = clamp((1.0-q.y)*(1.0+u.canvas.z),0.0,1.0);
    float distance = u.look.x > 0.5 ? 1-fromHinge : fromHinge;
    if (u.motion.w > 0.5) return amount*(0.15+0.85*distance);
    float softness = u.field.w;
    float front = mix(-softness,1+softness,amount);
    float curve = u.field.z*pow(q.x-0.5,2.0);
    float region = 1-smoothstep(front-softness,front+softness,distance+curve);
    return amount*(0.15+0.85*region);
}

// The picture is a plane of height `k` hinged along its bottom edge, seen from
// a camera `D` picture-heights in front of the hinge. Rotating it about that
// axis foreshortens the plane and swings the free edge: the hinge line stays
// where it is, the top edge does not.
//
// It counter-rotates against the lid: tilting the screen forward tips the
// picture backward, as if the picture were fixed in space and the screen were a
// window swinging around it. `geometry.z` flips that for comparison.
//
// At rest the picture spans the whole frame: its bottom edge sits on the hinge
// at the bottom of the screen and its top edge at the top, so no padding shows.
// Rotating about the hinge swings the free edge down and reveals the padding
// that sits off-screen above, left and right of the picture.
float2 motionSample(float2 uv, constant Uniforms& u) {
    float ratio  = u.motion.z;   // -1...1 signed travel, never reaching the ends
    float direction = u.geometry.z > 0.5 ? -1.0 : 1.0;
    float theta = -ratio*u.effect.y*0.0174532925*direction;
    float cost = cos(theta), sint = sin(theta);
    float D = max(1.02,u.geometry.w);     // perpendicular distance to the screen, in picture heights
    float yCam = u.field.x;               // camera offset up the screen from the hinge line
    float A = max(0.5,u.geometry.x);      // frame aspect
    float pL = u.canvas.x, pR = u.canvas.y, pT = u.canvas.z;

    float Y = 1.0-uv.y;                   // height above the hinge line
    float X = (uv.x-0.5)*A;               // centred, in frame heights

    // Invert the projection: which point of the picture lands on this pixel?
    //
    // The camera sits on the plane through the screen's vertical midline, at
    // `yCam` up from the hinge and D in front of the screen. Rays leave it
    // towards the screen, and the picture is the plane hinged along the bottom
    // edge, tipped back by θ. Inverting that gives
    //
    //     s = Y*D / (D*cosθ - sinθ*(Y - yCam))
    //
    // which is the camera-at-hinge-height case with the height folded in. The
    // denominator reaches zero at Y = yCam + D/tanθ: above that line the ray
    // passes over the picture's free edge and never meets the plane in front of
    // the hinge at all, so it is background. Clamping the denominator rather
    // than letting it go negative is what makes that distinction — a negative
    // denominator would place the sample behind the hinge.
    float denom = max(cost*D - sint*(Y - yCam),1e-4);
    float s = Y*D/denom;
    float scaleAt = D/(D+s*sint);
    float a = X/(A*max(1e-4,scaleAt));

    // Picture coordinates to texture coordinates. The padding is part of the
    // texture, so the blur softens the picture into it rather than cutting.
    float pictureX = (a+0.5)*A;
    float canvasWidth = A+pL+pR;
    float canvasHeight = 1.0+pT;
    return float2((pictureX+pL)/canvasWidth,1.0-s/canvasHeight);
}
float4 blurred(array<texture2d<float>,6> levels, float2 uv, float sigma) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    const float radii[6] = {0,2,5,12,24,48};
    uint lo = 0;
    for (uint i=1; i<5; ++i) if (sigma >= radii[i]) lo = i;
    float t = saturate((sigma-radii[lo])/(radii[lo+1]-radii[lo]));
    return mix(levels[lo].sample(s,uv),levels[lo+1].sample(s,uv),t);
}

// Live path: copy the captured display into the padded canvas. `picture` is
// (x, y, width, height) of the picture's rect inside the canvas, in canvas uv.
// Everything outside stays black, which is what the padded border is made of.
fragment float4 canvasFill(VertexOut in [[stage_in]],
                           constant float4& picture [[buffer(0)]],
                           texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv = in.uv;
    if (uv.x < picture.x || uv.y < picture.y || uv.x > picture.x+picture.z || uv.y > picture.y+picture.w) {
        return float4(0,0,0,1);
    }
    return float4(source.sample(s,(uv-picture.xy)/picture.zw).rgb,1);
}

// Exact 2x2 box reduce. Four linear taps half a source texel off centre average
// the four texels that the destination pixel covers.
fragment float4 downscale(VertexOut in [[stage_in]],
                          constant float2& texel [[buffer(0)]],
                          texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 o = texel;
    float4 sum = source.sample(s,in.uv+float2(-o.x,-o.y))
               + source.sample(s,in.uv+float2( o.x,-o.y))
               + source.sample(s,in.uv+float2(-o.x, o.y))
               + source.sample(s,in.uv+float2( o.x, o.y));
    return sum*0.25;
}

fragment float4 focusComposite(VertexOut in [[stage_in]],
                              constant Uniforms& u [[buffer(0)]],
                              array<texture2d<float>,6> outgoing [[texture(0)]],
                              array<texture2d<float>,6> incoming [[texture(6)]]) {
    if (u.motion.x > 0.5) {
        float2 sample = motionSample(in.uv,u);
        float mask = motionField(sample,u);
        if (u.look.y > 0.5) return float4(float3(mask),1);
        // Overlay mode (canvas.w): the window sits on top of the live screen, so
        // it stays fully transparent until there is enough blur to hide the
        // one-frame-old copy, then becomes opaque. Premultiplied output.
        float alpha = 1.0;
        if (u.canvas.w > 0.5) alpha = smoothstep(u.effect.z,max(u.effect.z+0.01,u.effect.w),mask);
        // The padding is black and part of the texture, so blurring the whole
        // thing softens the picture's border into it.
        float3 color = blurred(outgoing,sample,mask*u.effect.x).rgb;
        color = (color-0.5)*(1-u.look.w*mask)+0.5;
        color *= 1-u.look.z*mask;
        return float4(color*alpha,alpha);
    }
    float mask = fieldMask(in.uv,u);
    if (u.look.y > 0.5) return float4(float3(mask),1);
    float outgoingSigma = u.effect.x*smoothstep(0.0,0.5,mask);
    float incomingSigma = u.effect.x*(1-smoothstep(0.5,1.0,mask));
    float reveal = smoothstep(0.5-u.effect.w/2,0.5+u.effect.w/2,mask);
    float4 a = blurred(outgoing,surfaceUV(in.uv,-u.field.x,u),outgoingSigma);
    float4 b = blurred(incoming,surfaceUV(in.uv,1-u.field.x,u),incomingSigma);
    float3 color = mix(a.rgb,b.rgb,reveal);
    float middle = 4*mask*(1-mask);
    color = (color-0.5)*(1-u.look.w*middle)+0.5;
    color *= 1-u.look.z*middle;
    return float4(color,1);
}
