/*
    Oilify - Painterly Strokes v26 (Adaptive Depth)

    Optimization goals:
      - Keep the supplied original Oilify/Kuwahara math intact.
      - Remove the extra full-screen Capture pass.
      - Replace the v9 5x5 x 2 stroke searches with one 3x3 search.
      - Sample Anisotropy once per brush pixel instead of once per candidate stroke.
      - Remove per-candidate sin/cos and use cheap hash/polynomial shape functions.
      - Use one coherent stroke-color sample per pixel.
      - Keep Paint Drag axial and optional.
      - Add larger-scale bristle grooves, paint-load variation, stroke scatter,
        controllable direction jitter, edge wear, dry-brush breakup and paint relief.
      - Give each stroke an independent temporal phase, speed, direction wobble, and breathing rate.
      - Use smoothed triangle waves for more organic continuous motion.
      - Protect strong silhouettes using derivative-based edge detection (no extra texture fetches).
      - Add subtle per-stroke pigment variation and one-sided paint pooling with math only.
      - Add shape-adaptive stroke sizing: broad calm regions use longer strokes while complex structure uses shorter, more controlled strokes.
      - Add stroke clumping: nearby strokes can share a gentle directional family and partially shared temporal motion.
      - Add contour flow: optional tendency for strokes to follow strong local silhouette flow without extra texture fetches.
      - Add shape-adaptive motion: calm regions drift farther while detailed edges remain steadier, without synchronizing strokes globally.
      - Keep the new controls math-only so these features do not add texture fetches.
      - Optimize stroke search with one seed hash per candidate and a cheap coarse cull.
      - Precompute per-pixel form/motion factors outside the 3x3 candidate loop.
      - Compute contour-following tangent once per pixel and reuse it for all candidates.
      - Skip the final paint color fetch entirely when the pixel is outside all stroke coverage.
      - Add a mutually exclusive depth-adaptive final mode with smooth camera-distance weighting.
      - Capture the pre-Oilify source in the existing anisotropy pass via MRT, avoiding an extra copy pass.

    The expensive original part is intentionally preserved so Sharpness / Scale /
    Tuning retain the behavior of the supplied Oilify.fx.
*/

#ifndef OILIFY_SIZE
    #define OILIFY_SIZE 7
#endif
#ifndef OILIFY_ITERATIONS
    #define OILIFY_ITERATIONS 1
#endif

// Fixed compile-time stroke search radius. 1 = 3x3 candidates.
#ifndef STROKE_SEARCH_RADIUS
    #define STROKE_SEARCH_RADIUS 1
#endif

// Larger cells let a 3x3 neighborhood cover long strokes without a 5x5 search.
#ifndef STROKE_CELL_FACTOR
    #define STROKE_CELL_FACTOR 0.82
#endif

#define OILIFY_PASS \
        pass \
        { \
            VertexShader = PostProcessVS;\
            PixelShader = KuwaharaPS;\
        }\

#define OILIFY_FINAL_PASS \
        pass \
        { \
            VertexShader = PostProcessVS;\
            PixelShader = KuwaharaPS;\
            RenderTarget0 = OilifyResult;\
        }\

static const float PI = 3.1415926536;
static const float TWO_PI = 6.2831853072;
static const float GAUSSIAN_WEIGHTS[5] = {0.095766, 0.303053, 0.20236, 0.303053, 0.095766};
static const float GAUSSIAN_OFFSETS[5] = {-3.2979345488, -1.40919905099, 0, 1.40919905099, 3.2979345488};

namespace Oilify
{
    texture BackBuffer : COLOR;

    // Captures the pre-Oilify image during the existing anisotropy pass.
    // This is the same image that the Kuwahara stage receives, so adaptive
    // compositing does not need a separate source-copy pass.
    texture OriginalInput < pooled = true; >
    {
        Width = BUFFER_WIDTH;
        Height = BUFFER_HEIGHT;
        Format = RGBA16f;
    };

    // ReShade's special DEPTH semantic provides the application's depth buffer.
    texture2D DepthBufferTex : DEPTH;

    texture Anisotropy {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16f;};
    texture OilifyResult
    {
        Width = BUFFER_WIDTH;
        Height = BUFFER_HEIGHT;
        Format = RGBA16f;
    };

    sampler sBackBuffer{Texture = BackBuffer;};
    sampler sOriginalInput{Texture = OriginalInput; MagFilter = LINEAR; MinFilter = LINEAR; MipFilter = LINEAR;};
    sampler sDepthBuffer{Texture = DepthBufferTex; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT;};
    sampler sAnisotropy{Texture = Anisotropy;};
    sampler sOilifyResult{Texture = OilifyResult;};

    uniform bool HasDepth < source = "bufready_depth"; hidden = true; >;

    // ---------------------------------------------------------------------
    // Simple settings
    // ---------------------------------------------------------------------

    // 0 = original full-image application, 1 = depth-adaptive application.
    // The branch is resolved in the final pixel shader so depth is never sampled
    // in the default full-image mode.
    uniform int FilterMode<
        ui_type = "combo";
        ui_category = "Simple Settings";
        ui_label = "Filter Mode";
        ui_items = "Full Image\0Adaptive Depth\0";
        ui_min = 0; ui_max = 1;
        ui_tooltip = "Full Image applies the complete filter uniformly. Adaptive Depth uses the depth buffer to vary filter strength smoothly with camera distance.";
    > = 0;

    // This control is used only by Full Image mode. Adaptive Depth mode ignores
    // it completely and uses the three controls in Adaptive Depth Settings.
    // ReShade FX does not provide a dynamic per-uniform disabled/greyed state,
    // so the slider remains visible but becomes a no-op in Adaptive Depth mode.
    uniform float FilterStrength<
        ui_category = "Simple Settings";
        ui_type = "slider";
        ui_label = "Filter Strength";
        ui_tooltip = "Overall amount of the complete Oilify + painterly result in Full Image mode. This control is ignored in Adaptive Depth mode.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 1.0;

    uniform int SimplePreset<
        ui_type = "combo";
        ui_category = "Simple Settings";
        ui_label = "Style Preset";
        ui_items = "Original Oilify\0Soft Wash\0Classic Oil\0Long Strokes\0Dry Brush\0Impasto\0Living Paint\0";
        ui_min = 0; ui_max = 6;
        ui_tooltip = "Choose a prepared painterly style. Turn on Advanced Settings when you want individual brush control.";
    > = 2;

    uniform float Sharpness<
        ui_category = "Simple Settings";
        ui_type = "slider";
        ui_label = "Sharpness";
        ui_tooltip = "Higher settings result in a sharper image, while lower values give the\n"
                     "image a more simplified look.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 1;

    uniform float Tuning<
        ui_category = "Simple Settings";
        ui_type = "slider";
        ui_label = "Anistropy Tuning";
        ui_tooltip = "Adjusts how elliptical the sampling can become with anisotropy\n"
                     "Smaller numbers mean more elliptical. (Use this if the shader looks stretched)";
        ui_min = 0; ui_max = 4;
    > = 2;

    uniform float Scale<
        ui_category = "Simple Settings";
        ui_type = "slider";
        ui_label = "Scale";
        ui_tooltip = "Similar to size it raises the range the effect is applied over, \n"
                     "however, the number of samples remains unchanged resulting in a less, \n"
                     "detailed image.";
        ui_min = 1; ui_max = 4;
    > = 1;

    // ---------------------------------------------------------------------
    // Pre-Oilify image treatment
    // These controls are deliberately outside the Advanced Settings preset
    // system. They are applied before the complete original Oilify pipeline.
    // ---------------------------------------------------------------------

    uniform float PosterizationColors<
        ui_category = "Simple Settings";
        ui_type = "slider";
        ui_label = "Posterization - Colors";
        ui_tooltip = "Reduces the input image to a selectable number of color levels per channel before Oilify. Higher values retain more colors.";
        ui_min = 2; ui_max = 256;
        ui_step = 1;
    > = 32;

    uniform float CanvasSize<
        ui_category = "Simple Settings";
        ui_type = "slider";
        ui_label = "Canvas - Size";
        ui_tooltip = "Controls the physical scale of the procedural canvas weave and broad fold pattern in screen pixels. This effect uses no external texture file.";
        ui_min = 2; ui_max = 96;
        ui_step = 1;
    > = 24;

    uniform float CanvasFoldVisibility<
        ui_category = "Simple Settings";
        ui_type = "slider";
        ui_label = "Canvas - Fold Visibility";
        ui_tooltip = "Controls how visible the procedural canvas weave and broad fold relief are. Zero disables the canvas modulation.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.42;

    uniform float AdaptiveForegroundStrength<
        ui_category = "Adaptive Depth Settings";
        ui_category_closed = true;
        ui_type = "slider";
        ui_label = "Foreground Filter Strength";
        ui_tooltip = "Filter strength for geometry close to the camera. Used only in Adaptive Depth mode.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.35;

    uniform float AdaptiveBackgroundStrength<
        ui_category = "Adaptive Depth Settings";
        ui_type = "slider";
        ui_label = "Background Filter Strength";
        ui_tooltip = "Filter strength for distant geometry. Used only in Adaptive Depth mode.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.90;

    uniform float AdaptiveDepthBoundary<
        ui_category = "Adaptive Depth Settings";
        ui_type = "slider";
        ui_label = "Foreground / Background Boundary";
        ui_tooltip = "Approximate camera distance in meters at the center of the transition. The transition is deliberately soft, spanning about 50 meters. Actual linearization follows ReShade's configured far plane.";
        ui_min = 1; ui_max = 1000;
        ui_step = 1;
    > = 40;

    // ---------------------------------------------------------------------
    // Advanced painterly controls
    // ---------------------------------------------------------------------

    // This boolean doubles as the category toggle. ReShade keeps the toggle
    // available while the rest of the category is hidden/collapsed.
    uniform bool AdvancedSettings<
        ui_category = "Advanced Settings";
        ui_category_closed = true;
        ui_category_toggle = true;
        ui_label = "Enable Advanced Settings";
        ui_tooltip = "Enable the complete painterly toolkit. When disabled, the selected Style Preset controls the brush layer.";
    > = false;

    uniform float BrushStrength<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Brush Strength";
        ui_tooltip = "Amount of coherent brush reconstruction mixed into the original Oilify result.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.34;

    uniform float StrokeLength<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Length";
        ui_tooltip = "Average length of each long continuous brush stroke in screen pixels.";
        ui_min = 32; ui_max = 320;
        ui_step = 1;
    > = 150;

    uniform float StrokeSpacing<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Spacing";
        ui_tooltip = "Spacing between logical stroke centers. Larger values reduce brush-pass work and create more open paint.";
        ui_min = 16; ui_max = 160;
        ui_step = 1;
    > = 58;

    uniform float StrokeWidth<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Width";
        ui_tooltip = "Stroke thickness relative to spacing.";
        ui_min = 0.20; ui_max = 1.25;
        ui_step = 0.01;
    > = 0.72;

    uniform float StrokeTaper<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Taper";
        ui_tooltip = "How strongly a stroke narrows toward its ends.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.38;

    uniform float StrokeIrregularity<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Irregularity";
        ui_tooltip = "Broad variation of stroke center, width and silhouette. It does not add pixel grain.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.45;

    uniform float StrokeBend<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Bend";
        ui_tooltip = "Broadly curves the centerline of long strokes.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.30;

    uniform float StrokeTexture<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Texture";
        ui_tooltip = "Broad paint-load variation inside a stroke. Uses low-frequency triangular bands, not fine noise.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.22;

    uniform float StrokeBristle<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Bristle Streaks";
        ui_tooltip = "Adds a few broad, coherent brush-fiber streaks inside each stroke. No pixel grain is generated.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.28;

    uniform float PaintLoad<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Paint Load";
        ui_tooltip = "Varies paint density from the center of a stroke toward its tips and edges.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.35;

    uniform float StrokeScatter<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Scatter";
        ui_tooltip = "Breaks up the regular spacing of stroke centers without changing the underlying image detail.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.28;

    uniform float StrokeCoherence<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Color Coherence";
        ui_tooltip = "How strongly the color inside a stroke follows its centerline. Higher values create more continuous paint shapes.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.38;

    uniform float PaintDrag<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Paint Drag";
        ui_tooltip = "Shifts the single axial paint sample along the stroke. It does not average both sides of an edge.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0;

    uniform float AnisotropyInfluence<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Direction Influence";
        ui_tooltip = "How strongly strokes follow the local anisotropic Kuwahara direction.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.90;

    uniform float DirectionJitter<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Direction Jitter";
        ui_tooltip = "Allows neighboring strokes to deviate from the local flow direction while still following the image structure.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.18;

    uniform float TemporalInstability<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Temporal Instability";
        ui_tooltip = "Makes complete brush strokes drift with different phases and speeds. Higher values make the motion visibly stronger; zero keeps paint static.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.08;

    uniform float InstabilitySpeed<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Instability Speed";
        ui_tooltip = "Global speed multiplier for the stroke motion; each stroke also gets its own speed variation and phase.";
        ui_min = 0; ui_max = 1.5;
        ui_step = 0.01;
    > = 0.18;

    uniform float TemporalEdgeSwim<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Temporal Edge Swim";
        ui_tooltip = "Separately animates the broad contour of a stroke. Zero leaves stroke edges static while the rest of the instability can still move.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.10;

    uniform float EdgeWear<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Edge Wear";
        ui_tooltip = "Makes stroke sides more imperfect and brush-like using only broad deterministic shape changes.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.25;

    uniform float BristleBreakup<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Bristle Breakup";
        ui_tooltip = "Breaks a stroke into a few broad paint gaps, especially useful for dry-brush styles. It never creates fine pixel grain.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.18;

    uniform float PaintRelief<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Paint Relief";
        ui_tooltip = "Adds a broad center ridge to the stroke so thick paint reads as layered rather than perfectly flat.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.20;

    uniform float EdgeRespect<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Edge Respect";
        ui_tooltip = "Reduces brush coverage across strong image edges so important silhouettes remain crisp instead of being painted over.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.55;

    uniform float PigmentVariation<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Pigment Variation";
        ui_tooltip = "Gives individual strokes a very subtle color bias so the paint layer is not perfectly uniform.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.28;

    uniform float PaintPooling<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Paint Pooling";
        ui_tooltip = "Adds a subtle uneven paint build-up toward one end of each stroke without creating outlines.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.22;

    uniform float StrokeClumping<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Clumping";
        ui_tooltip = "Lets neighboring strokes share a broad directional and motion family, reducing the isolated procedural look without synchronizing the whole image.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.34;

    uniform float ContourFlow<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Contour Flow";
        ui_tooltip = "Blends stroke direction toward the local contour tangent near strong edges. Useful for painterly form-following without adding texture samples.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.28;

    uniform float FormResponse<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Form Response";
        ui_tooltip = "Adapts stroke length and width to image complexity: calmer areas keep broader strokes while structured areas use shorter, more controlled strokes.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.50;

    uniform float FormMotion<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Form Motion Response";
        ui_tooltip = "Makes motion behave differently across the image: broad quiet areas drift farther, while detailed edges stay comparatively stable.";
        ui_min = 0; ui_max = 1;
        ui_step = 0.001;
    > = 0.50;

    uniform float StrokeEdge<
        ui_category = "Advanced Settings";
        ui_type = "slider";
        ui_label = "Stroke Edge";
        ui_tooltip = "Softness of the ribbon boundary in screen pixels.";
        ui_min = 0.25; ui_max = 8;
        ui_step = 0.1;
    > = 1.0;

    uniform bool ShowStrokeMask<
        ui_category = "Advanced Settings";
        ui_label = "Debug: Show Stroke Mask";
        ui_tooltip = "Shows the generated coherent brush ribbons instead of color.";
    > = false;

    uniform float TimerMs<source = "timer"; hidden = true;>;

    // ---------------------------------------------------------------------
    // Full-screen triangle
    // ---------------------------------------------------------------------

    void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
    {
        texcoord.x = (id == 2) ? 2.0 : 0.0;
        texcoord.y = (id == 1) ? 2.0 : 0.0;
        position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    }

    // ---------------------------------------------------------------------
    // PRE-OILIFY POSTERIZATION + PROCEDURAL CANVAS
    // ---------------------------------------------------------------------

    float3 ApplyPosterization(float3 color)
    {
        // Use a rounded level count so the UI remains a normal one-step slider.
        // The calculation intentionally avoids saturating HDR values above 1.0.
        float levels = max(floor(PosterizationColors + 0.5), 2.0);
        float scale = levels - 1.0;
        color = max(color, 0.0);
        return floor(color * scale + 0.5) / scale;
    }

    // Continuous hash used by the analytical canvas noise. This is intentionally
    // independent from the brush-stroke hash above so the canvas keeps its own
    // stable material pattern and does not inherit the stroke layout.
    float CanvasHash21(float2 p)
    {
        p = frac(p * float2(0.1031, 0.1030));
        p += dot(p, p.yx + 33.33);
        return frac((p.x + p.y) * p.x * p.y);
    }

    float CanvasValueNoise(float2 p)
    {
        float2 i = floor(p);
        float2 f = frac(p);
        f = f * f * (3.0 - 2.0 * f);

        float a = CanvasHash21(i);
        float b = CanvasHash21(i + float2(1.0, 0.0));
        float c = CanvasHash21(i + float2(0.0, 1.0));
        float d = CanvasHash21(i + float2(1.0, 1.0));

        return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
    }

    // Two-octave FBM is sufficient for the canvas material and cuts the
    // procedural-noise cost substantially compared with the previous three-
    // octave implementation. The weights sum to 1, so no final saturate is
    // required here.
    float CanvasFBM2(float2 p)
    {
        float n = CanvasValueNoise(p) * 0.67;
        p = p * 2.03 + float2(17.4, -9.2);
        n += CanvasValueNoise(p) * 0.33;
        return n;
    }

    float3 ApplyProceduralCanvas(float3 color, float2 texcoord)
    {
        float visibility = saturate(CanvasFoldVisibility);
        if (visibility <= 0.0001)
            return color;

        // Everything is generated analytically. No texture asset is required.
        // CanvasSize controls the nominal thread spacing in screen pixels.
        float sizePx = max(CanvasSize, 2.0);
        float2 pixel = texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT);
        float2 q = pixel / sizePx;

        // -----------------------------------------------------------------
        // Irregular domain warp
        // -----------------------------------------------------------------
        // Keep the large warp two-octave: it supplies the broad non-periodic
        // deformation that prevents the fibers from becoming a visible grid.
        float2 warpSpace = q * 0.24;
        float warpA = CanvasFBM2(warpSpace + float2(3.7, 11.2)) - 0.5;
        float warpB = CanvasFBM2(warpSpace * 1.37 + float2(-8.1, 5.4)) - 0.5;
        float2 warpedQ = q + float2(warpA, warpB) * 0.42;

        // -----------------------------------------------------------------
        // Long irregular canvas fibers
        // -----------------------------------------------------------------
        // These auxiliary bends only need one octave. Their purpose is to
        // perturb the fiber axes, not to add visible noise by themselves.
        float fiberWarpX = CanvasValueNoise(warpedQ * float2(0.55, 1.55) + float2(12.3, -4.6)) - 0.5;
        float fiberWarpY = CanvasValueNoise(warpedQ * float2(1.55, 0.55) + float2(-6.8, 14.7)) - 0.5;

        float2 fiberXCoord = warpedQ * float2(0.72, 5.35);
        fiberXCoord.y += fiberWarpY * 0.82;
        fiberXCoord.x += CanvasValueNoise(warpedQ * 0.90 + float2(23.1, 4.2)) * 0.65;

        float2 fiberYCoord = warpedQ * float2(5.35, 0.72);
        fiberYCoord.x += fiberWarpX * 0.82;
        fiberYCoord.y += CanvasValueNoise(warpedQ * 0.86 + float2(-17.5, 8.9)) * 0.65;

        // The main fiber fields keep two octaves because this is where the
        // material's recognizable yarn structure is formed.
        float fiberXNoise = CanvasFBM2(fiberXCoord);
        float fiberYNoise = CanvasFBM2(fiberYCoord);

        float fiberX = smoothstep(0.30, 0.74, fiberXNoise);
        float fiberY = smoothstep(0.30, 0.74, fiberYNoise);
        float fiberXRidge = fiberX * fiberX * (0.72 + 0.28 * fiberX);
        float fiberYRidge = fiberY * fiberY * (0.72 + 0.28 * fiberY);
        float fiberXValley = fiberX * (2.0 - fiberX);
        float fiberYValley = fiberY * (2.0 - fiberY);
        fiberXValley = 1.0 - fiberXValley;
        fiberYValley = 1.0 - fiberYValley;

        // Directional thread relief. Positive values are raised yarn catches;
        // negative values are the darker troughs between neighboring threads.
        float warpRelief = fiberXRidge * 0.92 - fiberXValley * 0.56;
        float weftRelief = fiberYRidge * 0.92 - fiberYValley * 0.56;
        float fiberRelief = warpRelief * 0.48 + weftRelief * 0.48;

        // -----------------------------------------------------------------
        // Frayed micro-structure and large soft cloth irregularities
        // -----------------------------------------------------------------
        // Keep one detailed two-octave field and two cheap single-octave fields.
        // Together they retain the broken/fuzzy character at a fraction of the
        // previous FBM cost.
        float grainA = CanvasFBM2(warpedQ * 3.35 + float2(41.2, -12.8)) - 0.5;
        float grainB = CanvasValueNoise(warpedQ * float2(8.8, 2.65) + float2(-28.4, 19.6)) - 0.5;
        float grainC = CanvasValueNoise(warpedQ * float2(2.2, 8.6) + float2(17.7, -34.5)) - 0.5;
        float fineFiber = grainA * 0.38 + grainB * 0.22 + grainC * 0.16;

        // Convert the finer noise into broken little ridges instead of smooth
        // cloudy noise. This reads more like short stray fibers and rough yarn.
        float roughFiber = smoothstep(0.20, 0.78, fineFiber + 0.5) - 0.42;
        float roughValley = smoothstep(0.18, 0.66, 0.5 - fineFiber) - 0.40;
        float frayRelief = roughFiber * 0.16 - roughValley * 0.10;

        // Broad cloth bunching does not need three noise octaves. One two-
        // octave field plus one single-octave directional field is enough.
        float clothBunch = CanvasFBM2(warpedQ * 0.17 + float2(-2.4, 37.1)) - 0.5;
        float clothTilt = CanvasValueNoise(warpedQ * float2(0.31, 0.13) + float2(8.8, -26.4)) - 0.5;

        // Broad fold field plus cross-fiber interaction. The latter makes the
        // intersections of warp/weft slightly darker or brighter without
        // reconstructing a square checkerboard.
        float crossing = fiberXRidge * fiberYRidge * 0.14
                       - fiberXValley * fiberYValley * 0.08;
        float bunchRelief = clothBunch * 0.072 + clothTilt * 0.034;

        // Strong material relief. Asymmetric highlight/shadow amplitudes make
        // the surface read as three-dimensional canvas rather than a flat decal.
        float weaveRelief = fiberRelief * 0.072;
        weaveRelief += crossing;
        weaveRelief += frayRelief * 0.030;
        weaveRelief += bunchRelief;

        float trough = (fiberXValley + fiberYValley - 0.65) * 0.026;
        weaveRelief -= trough;

        float relief = weaveRelief * visibility;
        float3 canvasColor = color * (1.0 + relief);
        return max(canvasColor, 0.0);
    }

    void PreOilifyPS(
        float4 vpos : SV_POSITION,
        float2 texcoord : TEXCOORD,
        out float4 outputColor : SV_TARGET0,
        out float4 originalOutput : SV_TARGET1)
    {
        float3 original = tex2D(sBackBuffer, texcoord).rgb;
        float3 color = original;

        // The pre-Oilify reference is captured in the existing anisotropy pass.
        originalOutput = float4(original, 1.0);

        // Required order: posterization first, canvas treatment second.
        color = ApplyPosterization(color);
        color = ApplyProceduralCanvas(color, texcoord);

        outputColor = float4(color, 1.0);
    }

    // ---------------------------------------------------------------------
    // ORIGINAL ANISOTROPY CODE
    // ---------------------------------------------------------------------

    void AnisotropyPS(
        float4 vpos : SV_POSITION,
        float2 texcoord : TEXCOORD,
        out float4 anisotropyData : SV_TARGET0,
        out float4 originalOutput : SV_TARGET1)
    {
        float3 inputColor = tex2D(sBackBuffer, texcoord).rgb;
        originalOutput = float4(inputColor, 1.0);

        float3 center = inputColor * 255;
        float3 dx = center * GAUSSIAN_WEIGHTS[2];
        float3 dy = dx;
        
        [unroll]
        for(int i = 0; i < 5; i++)
        {
            if (i == 2) i++;
            float3 offsets = float3(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT, 0) * GAUSSIAN_OFFSETS[i];
            dx += tex2D(sBackBuffer, texcoord + offsets.xz).rgb * GAUSSIAN_WEIGHTS[i] * 255;
            dy += tex2D(sBackBuffer, texcoord + offsets.zy).rgb * GAUSSIAN_WEIGHTS[i] * 255;
        }
        dx = ddx(dx);
        dy = ddy(dy);
        
        float e = dot(dx, dx);
        float f = dot(dx, dy);
        float g = dot(dy, dy);
        float root = sqrt((e-g) * (e-g) + 4 * f * f);
        float2 eigenvalues = float2(e + g + root, e + g - root) / 2;
        
        float2 t;
        [flatten]
        if(any(abs(float2(eigenvalues.x - e, -f)) > 1e-15))
        {
            t = (normalize((float2(eigenvalues.x - e, -f))));
        }
        else
            t = float2(1, 0);
            
        float anisotropy = abs((eigenvalues.y - eigenvalues.x) / (eigenvalues.x + eigenvalues.y));
        anisotropy *= anisotropy;
        anisotropy = saturate(anisotropy);
        anisotropy = max(anisotropy, 1e-15);
        anisotropyData.xyz = float3(t, anisotropy);
        anisotropyData.w = 1;
    }

    // ---------------------------------------------------------------------
    // ORIGINAL KUWAHARA CODE
    // ---------------------------------------------------------------------

    void KuwaharaPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float3 kuwahara : SV_TARGET0)
    {
        // x^4 is expanded explicitly to avoid a general-purpose pow() call.
        float sharpnessBase = (2 * Sharpness / 3) + 0.333333;
        float sharpnessSquared = sharpnessBase * sharpnessBase;
        float sharpnessMultiplier = max(1023 * sharpnessSquared * sharpnessSquared, 1e-10);
        float3 sum[6];
        float3 squaredSum[6];
        float gaussianSum[6];
        float sampleCount[6];

        // Compare squared distances so the per-sample radius test needs no sqrt().
        float2 radiusVector = float2((float(OILIFY_SIZE) / 2), (float(OILIFY_SIZE) / 4));
        float radiusSquared = dot(radiusVector, radiusVector);
        
        float3 anistropyData = tex2D(sAnisotropy, texcoord).xyz;
        float2 t = anistropyData.xy;
        float anisotropy = anistropyData.z;
        float tuning = exp2(Tuning - 1);
        float2x2 tuningMatrix = float2x2(tuning / (anisotropy + tuning), 0,
                                0, (tuning + anisotropy) / tuning);
        float2x2 rotationMatrix = float2x2(t.x, -t.y, t.y, t.x);
        float2x2 offsetMatrix = mul(rotationMatrix, tuningMatrix);
        [unroll]
        for(int i = -(OILIFY_SIZE / 2); i < ((OILIFY_SIZE + 1) / 2); i++)
        {
            [unroll]
            for(int j = -(OILIFY_SIZE / 2); j < ((OILIFY_SIZE + 1) / 2); j++)
            {
                float2 offset = float2(i, j);
                if(abs(j) % 2 != 0)
                {
                    offset.y -= 0.5;
                }
                
                if(all(int2(i, j) == 0))
                {
                    // The center sample is identical for all six sectors, so
                    // fetch it once instead of issuing six equivalent texture reads.
                    float3 centerColor = tex2D(sBackBuffer, texcoord).rgb * sharpnessMultiplier;
                    float3 centerSquared = centerColor * centerColor;
                    [unroll]
                    for(int k = 0; k < 6; k++)
                    {
                        sum[k] += centerColor;
                        squaredSum[k] += centerSquared;
                        sampleCount[k]++;
                    }
                }
                else if(dot(offset, offset) <= radiusSquared)
                {
                    float angle = atan2(offset.x, offset.y) + PI;
                    if(angle > 5.75958653158)
                    {
                        angle -= 2 * PI;
                    }
                    float sectorOffset = (float((angle * 6) / PI) + 1) / 2;
                    int sector = floor(sectorOffset);
                    sectorOffset -= float(sector);
                    offset *= float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT) * Scale;
                    offset = mul(offset, offsetMatrix);
                    float3 color = tex2D(sBackBuffer, texcoord + offset).rgb * sharpnessMultiplier;
                    sum[sector] += color;
                    squaredSum[sector] += color * color;
                    sampleCount[sector]++;
                }
            }
        }
        
        float3 weightedSum = 0;
        float3 weightSum = 0;
        [unroll]
        for(int i = 0; i < 6; i++)
        {
            float3 sumSquared = sum[i] * sum[i];
            float3 mean = sum[i] / sampleCount[i];
            float3 variance = (squaredSum[i] - ((sumSquared) / sampleCount[i]));
            variance /= sampleCount[0];

            // Original expression: 1 / (1 + pow(sqrt(x), 8)) == 1 / (1 + x^4)
            // for x >= 0. Expanding the powers removes both pow() and sqrt().
            float varianceLuma = max(dot(variance, float3(0.299, 0.587, 0.114)), 1e-5);
            float varianceSquared = varianceLuma * varianceLuma;
            float varianceFourth = varianceSquared * varianceSquared;
            float weight = 1.0 / (1.0 + varianceFourth);
            weightedSum += mean * weight;
            weightSum += weight;
        }
        kuwahara = ((weightedSum) / weightSum) / sharpnessMultiplier;
    }

    // ---------------------------------------------------------------------
    // Cheap coherent stroke helpers
    // ---------------------------------------------------------------------

    // Fast deterministic hashes. One Hash22 call is enough to seed a complete stroke.
    // This avoids the repeated trigonometric hash work used by earlier versions.
    float2 Hash22(float2 p)
    {
        float3 q = frac(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
        q += dot(q, q.yzx + 33.33);
        return frac((q.xx + q.yz) * q.zy);
    }

    float TriangleWave(float x)
    {
        return 1.0 - abs(frac(x) * 2.0 - 1.0);
    }

    // Smooth the corner of the triangle wave for temporal motion only.
    // Position remains periodic/continuous, but velocity changes are softer,
    // making the paint feel less like a mechanical back-and-forth loop.
    float SmoothTriangleWave(float x)
    {
        float t = TriangleWave(x);
        return t * t * (3.0 - 2.0 * t);
    }

    float StrokeCellSize(float lengthPx, float spacingPx)
    {
        return max(lengthPx * STROKE_CELL_FACTOR, spacingPx * 1.30);
    }


    float EvaluateRibbonCached(
        float2 pixel,
        float2 cell,
        float2 rnd,
        float seed,
        float2 baseTangent,
        float baseAnisotropy,
        float lengthPx,
        float spacingPx,
        float widthRatio,
        float taper,
        float irregularity,
        float bend,
        float scatter,
        float directionJitter,
        float edgeWear,
        float temporalEdgeSwim,
        float temporalAmount,
        float adaptiveLengthScale,
        float adaptiveWidthScale,
        float tangentMotionScale,
        float normalMotionScale,
        float speedFormScale,
        float angleMotionScale,
        float strokeClumping,
        float timeSeconds,
        out float2 centerOut,
        out float2 tangentOut,
        out float2 normalOut,
        out float localXOut,
        out float localYOut,
        out float seedOut,
        out float widthOut,
        out float lengthOut,
        out float curveOut)
    {
        float cellSize = StrokeCellSize(lengthPx, spacingPx);

        // Nearby cells can share a subtle directional family. The cluster grid is
        // deliberately coarser than the stroke grid so the grouping is broad,
        // not a repeating micro-pattern.
        float2 clusterCell = floor(cell * 0.5);
        float2 clusterRnd = Hash22(clusterCell + float2(71.31, 19.73));
        float clusterAngle = (clusterRnd.x - 0.5) * 0.72 * saturate(strokeClumping);
        float clusterMotionBoost = lerp(0.82, 1.18, clusterRnd.y);

        float2 clusterTangent = baseTangent + float2(-baseTangent.y, baseTangent.x) * clusterAngle;
        clusterTangent *= rsqrt(max(dot(clusterTangent, clusterTangent), 1e-4));

        float2 center = (cell + 0.5) * cellSize;
        center += (rnd - 0.5) * cellSize * (0.20 + scatter * 0.34 + irregularity * 0.06);

        // Continuous whole-stroke motion. Each stroke now receives its own
        // temporal phase AND its own speed multiplier, so neighboring strokes
        // do not drift in lockstep. Motion follows the stroke's local tangent
        // and normal axes, keeping the animated paint coherent with the image.
        float motionSpeedT = lerp(0.58, 1.58, rnd.x) * lerp(1.0, clusterMotionBoost, 0.48 * saturate(strokeClumping));
        float motionSpeedN = lerp(0.46, 1.38, rnd.y) * lerp(1.0, clusterMotionBoost, 0.40 * saturate(strokeClumping));
        float clusterPhaseT = clusterRnd.x * 6.2831853 * 0.65;
        float clusterPhaseN = clusterRnd.y * 6.2831853 * 0.55;
        float motionPhaseT = timeSeconds * (0.23 * motionSpeedT) + seed * 7.37 + rnd.y * 2.41
                           + clusterPhaseT * saturate(strokeClumping);
        float motionPhaseN = timeSeconds * (0.17 * motionSpeedN) + seed * 9.11 + rnd.x * 3.17
                           + clusterPhaseN * saturate(strokeClumping);
        float motionT = SmoothTriangleWave(motionPhaseT) - 0.5;
        float motionN = SmoothTriangleWave(motionPhaseN) - 0.5;

        // Form-aware motion scales are precomputed once per pixel.
        motionT *= tangentMotionScale;
        motionN *= normalMotionScale;

        // One random direction per stroke; local Kuwahara direction remains the
        // main flow guide, while Direction Jitter introduces controlled variation.
        float2 randomDir = rnd * 2.0 - 1.0;
        float randomLen2 = max(dot(randomDir, randomDir), 1e-4);
        randomDir *= rsqrt(randomLen2);

        // Clumping gives neighboring strokes a shared family direction while
        // keeping individual jitter and local image flow visible.
        randomDir = lerp(randomDir, clusterTangent, 0.42 * saturate(strokeClumping));
        randomDir *= rsqrt(max(dot(randomDir, randomDir), 1e-4));

        float follow = smoothstep(0.01, 0.22, baseAnisotropy) * saturate(AnisotropyInfluence);
        float2 tangent = lerp(randomDir, baseTangent, follow);
        tangent *= rsqrt(max(dot(tangent, tangent), 1e-4));

        float2 jitterDir = float2(rnd.y * 2.0 - 1.0, 1.0 - rnd.x * 2.0);
        jitterDir *= rsqrt(max(dot(jitterDir, jitterDir), 1e-4));
        tangent = lerp(tangent, jitterDir, 0.23 * directionJitter * (0.35 + 0.65 * irregularity));
        tangent *= rsqrt(max(dot(tangent, tangent), 1e-4));

        float2 normal = float2(-tangent.y, tangent.x);

        // Increase the motion range enough to be clearly visible while keeping
        // it below roughly one third of a cell, which limits candidate popping.
        float motionCells = (0.06 + 0.27 * temporalAmount) * speedFormScale;
        center += tangent * (motionT * motionCells * cellSize);
        center += normal  * (motionN * motionCells * 0.76 * cellSize);

        // Give each stroke a different wobble speed and phase as well. This
        // changes the direction of a stroke very slowly instead of rotating all
        // strokes together. The amplitude remains deliberately small.
        float wobbleSpeed = lerp(0.62, 1.44, rnd.x);
        float wobblePhase = timeSeconds * (0.13 * wobbleSpeed)
                          + seed * 4.11 + rnd.y * 2.73;
        float angleWobble = (SmoothTriangleWave(wobblePhase) - 0.5)
                          * 0.14 * temporalAmount
                          * angleMotionScale;
        tangent += normal * angleWobble;
        tangent *= rsqrt(max(dot(tangent, tangent), 1e-4));
        normal = float2(-tangent.y, tangent.x);

        float2 d = pixel - center;
        float localX = dot(d, tangent);
        float localY = dot(d, normal);

        // Broad slow size variation adds life without per-pixel randomness.
        // Its phase and rate also vary per stroke so the canvas does not breathe
        // as a single synchronized layer.
        float sizeSpeed = lerp(0.52, 1.32, rnd.y);
        float sizePhase = timeSeconds * (0.061 * sizeSpeed) + seed * 6.23 + rnd.x * 1.93;
        float sizeBreath = SmoothTriangleWave(sizePhase) - 0.5;
        float lengthValue = max(lengthPx * lerp(0.82, 1.20, rnd.x)
                              * adaptiveLengthScale
                              * (1.0 + sizeBreath * 0.10 * temporalAmount), 12.0);
        float widthValue = max(spacingPx * widthRatio * lerp(0.72, 1.20, rnd.y)
                             * adaptiveWidthScale
                             * (1.0 + sizeBreath * 0.08 * temporalAmount), 2.0);

        float halfLength = max(lengthValue * 0.5, 2.0);
        float halfWidth = max(widthValue * 0.5, 1.0);
        float xNorm = localX / halfLength;

        float curveRandom = seed * 2.0 - 1.0;
        float curveShape = xNorm * max(0.0, 1.0 - xNorm * xNorm);
        float curve = curveShape * halfWidth * bend * (0.55 + 0.35 * irregularity) * curveRandom;

        float edgeSpeedA = lerp(0.62, 1.48, rnd.x);
        float edgeSpeedB = lerp(0.54, 1.36, rnd.y);
        float edgeSwimA = SmoothTriangleWave(timeSeconds * (0.17 * edgeSpeedA) + seed * 7.1 + rnd.y * 1.7) - 0.5;
        float edgeSwimB = SmoothTriangleWave(timeSeconds * (0.11 * edgeSpeedB) + rnd.y * 6.7 + seed * 1.9) - 0.5;
        curve += (edgeSwimA * 0.65 + edgeSwimB * 0.35) * halfWidth * 0.10 * temporalEdgeSwim * temporalAmount;
        localY -= curve;

        float end01 = saturate((abs(xNorm) - 0.40) / 0.60);
        float tipProfile = 1.0 - taper * end01 * end01;

        // Broad edge breakup, animated only at very low frequency.
        float swimPhase = timeSeconds * 0.32 * temporalEdgeSwim;
        float edgeWaveA = TriangleWave(xNorm * 0.72 + seed * 1.7 + swimPhase * (0.8 + seed)) - 0.5;
        float edgeWaveB = TriangleWave(xNorm * 0.33 - seed * 2.3 - swimPhase * (0.45 + seed * 0.6)) - 0.5;
        float edgeWaveC = TriangleWave(xNorm * 1.55 + seed * 3.2 + swimPhase * 0.35) - 0.5;
        float edgeAmplitude = (0.45 + 1.35 * edgeWear) * irregularity;
        float edgeWave = (edgeWaveA * 0.075 + edgeWaveB * 0.040 + edgeWaveC * 0.028) * edgeAmplitude;

        float localHalfWidth = max(halfWidth * max(0.18, tipProfile) * (1.0 + edgeWave), 0.75);
        float side = abs(localY) / localHalfWidth;
        float endDistance = abs(xNorm);
        float softness = max(StrokeEdge, 0.25) / max(widthValue, 1.0);

        float sideMask = 1.0 - smoothstep(0.78, 1.0 + softness * 1.35, side);
        float endMask = 1.0 - smoothstep(0.96, 1.065, endDistance);
        float mask = sideMask * endMask;

        centerOut = center;
        tangentOut = tangent;
        normalOut = normal;
        localXOut = localX;
        localYOut = localY;
        seedOut = seed;
        widthOut = widthValue;
        lengthOut = lengthValue;
        curveOut = curve;

        return saturate(mask);
    }

    void FindStrokeFast(
        float2 pixel,
        float2 baseTangent,
        float baseAnisotropy,
        float lengthPx,
        float spacingPx,
        float widthRatio,
        float taper,
        float irregularity,
        float bend,
        float scatter,
        float directionJitter,
        float edgeWear,
        float temporalEdgeSwim,
        float temporalAmount,
        float adaptiveLengthScale,
        float adaptiveWidthScale,
        float tangentMotionScale,
        float normalMotionScale,
        float speedFormScale,
        float angleMotionScale,
        float strokeClumping,
        float timeSeconds,
        out float bestMask,
        out float2 bestCenter,
        out float2 bestTangent,
        out float2 bestNormal,
        out float bestLocalX,
        out float bestLocalY,
        out float bestSeed,
        out float bestWidth,
        out float bestLength,
        out float bestCurve)
    {
        float cellSize = StrokeCellSize(lengthPx, spacingPx);
        float2 baseCell = floor(pixel / cellSize);

        bestMask = 0.0;
        bestCenter = pixel;
        bestTangent = baseTangent;
        bestNormal = float2(-baseTangent.y, baseTangent.x);
        bestLocalX = 0.0;
        bestLocalY = 0.0;
        bestSeed = 0.0;
        bestWidth = max(spacingPx * widthRatio, 2.0);
        bestLength = max(lengthPx, 8.0);
        bestCurve = 0.0;

        float2 baseNormal = float2(-baseTangent.y, baseTangent.x);

        [unroll]
        for (int oy = -STROKE_SEARCH_RADIUS; oy <= STROKE_SEARCH_RADIUS; oy++)
        {
            [unroll]
            for (int ox = -STROKE_SEARCH_RADIUS; ox <= STROKE_SEARCH_RADIUS; ox++)
            {
                float2 cell = baseCell + float2(ox, oy);
                float2 rnd = Hash22(cell + float2(13.17, 29.31));
                float seed = frac(rnd.x * 0.75487766 + rnd.y * 0.56984029);

                float2 center = (cell + 0.5) * cellSize;
                center += (rnd - 0.5) * cellSize * (0.20 + scatter * 0.34 + irregularity * 0.06);

                float2 d0 = pixel - center;
                float approxLength = lengthPx * lerp(0.80, 1.22, rnd.x);
                float approxWidth = spacingPx * widthRatio * lerp(0.70, 1.24, rnd.y);
                float ax = abs(dot(d0, baseTangent));
                float ay = abs(dot(d0, baseNormal));

                // Most pixels are far from 6-8 of the 9 candidates. Avoid doing
                // the expensive ribbon math for those candidates.
                float coarseX = approxLength * 0.62 + spacingPx * 0.20;
                float coarseY = max(approxWidth * 1.55, 3.0);
                if (ax <= coarseX && ay <= coarseY)
                {
                    float2 centerEval;
                    float2 tangentEval;
                    float2 normalEval;
                    float localXEval;
                    float localYEval;
                    float seedEval;
                    float widthEval;
                    float lengthEval;
                    float curveEval;

                    float mask = EvaluateRibbonCached(
                        pixel,
                        cell,
                        rnd,
                        seed,
                        baseTangent,
                        baseAnisotropy,
                        lengthPx,
                        spacingPx,
                        widthRatio,
                        taper,
                        irregularity,
                        bend,
                        scatter,
                        directionJitter,
                        edgeWear,
                        temporalEdgeSwim,
                        temporalAmount,
                        adaptiveLengthScale,
                        adaptiveWidthScale,
                        tangentMotionScale,
                        normalMotionScale,
                        speedFormScale,
                        angleMotionScale,
                        strokeClumping,
                        timeSeconds,
                        centerEval,
                        tangentEval,
                        normalEval,
                        localXEval,
                        localYEval,
                        seedEval,
                        widthEval,
                        lengthEval,
                        curveEval);

                    if (mask > bestMask)
                    {
                        bestMask = mask;
                        bestCenter = centerEval;
                        bestTangent = tangentEval;
                        bestNormal = normalEval;
                        bestLocalX = localXEval;
                        bestLocalY = localYEval;
                        bestSeed = seedEval;
                        bestWidth = widthEval;
                        bestLength = lengthEval;
                        bestCurve = curveEval;
                    }
                }
            }
        }
    }

    float3 ApplyBroadPaintTexture(
        float3 color,
        float localX,
        float localY,
        float widthValue,
        float lengthValue,
        float seed,
        float strokeTexture,
        float bristle,
        float paintLoad,
        float bristleBreakup,
        float paintRelief,
        float pigmentVariation,
        float paintPooling,
        out float paintCoverage)
    {
        float halfWidth = max(widthValue * 0.5, 1.0);
        float halfLength = max(lengthValue * 0.5, 2.0);
        float y = localY / halfWidth;
        float x = localX / halfLength;

        float bandA = TriangleWave(x * 0.72 + seed * 1.61);
        float bandB = TriangleWave(y * 0.58 - seed * 2.17);
        float broadLoad = (bandA - 0.5) * 0.055 + (bandB - 0.5) * 0.022;
        broadLoad *= saturate(strokeTexture);

        float laneA = TriangleWave(y * 1.55 + seed * 1.37 + x * 0.10);
        float laneB = TriangleWave(y * 2.70 - seed * 2.23 - x * 0.05);
        float laneC = TriangleWave(y * 4.10 + seed * 0.73 + x * 0.035);
        float bristleShape = 0.52 * laneA + 0.30 * laneB + 0.18 * laneC;
        bristleShape = smoothstep(0.18, 0.82, bristleShape);
        float bristleDelta = (bristleShape - 0.5) * 0.12 * saturate(bristle);

        float body = 1.0 - smoothstep(0.15, 0.95, abs(y));
        float tip = 1.0 - smoothstep(0.42, 1.0, abs(x));
        float load = saturate(body * 0.62 + tip * 0.38);
        float loadDelta = (load - 0.5) * 0.11 * saturate(paintLoad);

        float edge = saturate(abs(y));
        float edgeLoad = 1.0 - 0.025 * smoothstep(0.55, 1.0, edge);

        // Broad dry-brush gaps. These remain large and coherent rather than becoming grain.
        float gapField = 0.58 * laneA + 0.27 * laneB + 0.15 * bandA;
        float gapMask = smoothstep(0.26, 0.72, gapField);
        paintCoverage = lerp(1.0, lerp(0.34, 1.0, gapMask), saturate(bristleBreakup * bristle));

        // A broad center ridge gives loaded paint a little relief and layering.
        float ridge = 1.0 - smoothstep(0.0, 0.82, abs(y + 0.10));
        float relief = (ridge - 0.5) * 0.085 * saturate(paintRelief);

        // Subtle one-sided paint pooling. The heavier end varies per stroke,
        // so no two strokes build pigment in precisely the same place.
        float poolDir = (seed > 0.5) ? 1.0 : -1.0;
        float poolCoord = x * poolDir;
        float pool = smoothstep(0.48, 0.96, poolCoord);
        float poolVariation = (pool - 0.5) * 0.10 * saturate(paintPooling);

        float value = max(0.82, edgeLoad + broadLoad + bristleDelta + loadDelta + relief + poolVariation);

        // Tiny per-stroke pigment bias. It is intentionally chromatic and very
        // small, just enough to stop the paint layer from looking mathematically uniform.
        float pigment = (seed - 0.5) * 0.085 * saturate(pigmentVariation);
        float3 pigmentTint = 1.0 + float3(pigment, pigment * 0.35, -pigment * 0.55);

        return saturate(color * value * pigmentTint);
    }

    // ---------------------------------------------------------------------
    // Adaptive depth compositing
    // ---------------------------------------------------------------------

    #ifndef RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN
        #define RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN 0
    #endif
    #ifndef RESHADE_DEPTH_INPUT_IS_REVERSED
        #define RESHADE_DEPTH_INPUT_IS_REVERSED 1
    #endif
    #ifndef RESHADE_DEPTH_INPUT_IS_MIRRORED
        #define RESHADE_DEPTH_INPUT_IS_MIRRORED 0
    #endif
    #ifndef RESHADE_DEPTH_INPUT_IS_LOGARITHMIC
        #define RESHADE_DEPTH_INPUT_IS_LOGARITHMIC 0
    #endif
    #ifndef RESHADE_DEPTH_MULTIPLIER
        #define RESHADE_DEPTH_MULTIPLIER 1
    #endif
    #ifndef RESHADE_DEPTH_LINEARIZATION_FAR_PLANE
        #define RESHADE_DEPTH_LINEARIZATION_FAR_PLANE 1000.0
    #endif
    #ifndef RESHADE_DEPTH_INPUT_Y_SCALE
        #define RESHADE_DEPTH_INPUT_Y_SCALE 1
    #endif
    #ifndef RESHADE_DEPTH_INPUT_X_SCALE
        #define RESHADE_DEPTH_INPUT_X_SCALE 1
    #endif
    #ifndef RESHADE_DEPTH_INPUT_Y_OFFSET
        #define RESHADE_DEPTH_INPUT_Y_OFFSET 0
    #endif
    #ifndef RESHADE_DEPTH_INPUT_Y_PIXEL_OFFSET
        #define RESHADE_DEPTH_INPUT_Y_PIXEL_OFFSET 0
    #endif
    #ifndef RESHADE_DEPTH_INPUT_X_OFFSET
        #define RESHADE_DEPTH_INPUT_X_OFFSET 0
    #endif
    #ifndef RESHADE_DEPTH_INPUT_X_PIXEL_OFFSET
        #define RESHADE_DEPTH_INPUT_X_PIXEL_OFFSET 0
    #endif

    // ReShade's linearization produces a normalized camera-space depth in [0,1].
    // Multiplying by the configured far plane turns it into the approximate scene
    // distance used by the meter-based boundary slider.
    float GetAdaptiveDepthMeters(float2 texcoord)
    {
    #if RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN
        texcoord.y = 1.0 - texcoord.y;
    #endif
    #if RESHADE_DEPTH_INPUT_IS_MIRRORED
        texcoord.x = 1.0 - texcoord.x;
    #endif

        texcoord.x /= RESHADE_DEPTH_INPUT_X_SCALE;
        texcoord.y /= RESHADE_DEPTH_INPUT_Y_SCALE;

    #if RESHADE_DEPTH_INPUT_X_PIXEL_OFFSET
        texcoord.x -= RESHADE_DEPTH_INPUT_X_PIXEL_OFFSET * BUFFER_RCP_WIDTH;
    #else
        texcoord.x -= RESHADE_DEPTH_INPUT_X_OFFSET / 2.000000001;
    #endif

    #if RESHADE_DEPTH_INPUT_Y_PIXEL_OFFSET
        texcoord.y += RESHADE_DEPTH_INPUT_Y_PIXEL_OFFSET * BUFFER_RCP_HEIGHT;
    #else
        texcoord.y += RESHADE_DEPTH_INPUT_Y_OFFSET / 2.000000001;
    #endif

        float depth = tex2Dlod(sDepthBuffer, float4(texcoord, 0, 0)).x * RESHADE_DEPTH_MULTIPLIER;

    #if RESHADE_DEPTH_INPUT_IS_LOGARITHMIC
        const float C = 0.01;
        depth = (exp(depth * log(C + 1.0)) - 1.0) / C;
    #endif

    #if RESHADE_DEPTH_INPUT_IS_REVERSED
        depth = 1.0 - depth;
    #endif

        const float N = 1.0;
        const float farPlane = max(float(RESHADE_DEPTH_LINEARIZATION_FAR_PLANE), N + 1e-3);
        depth /= farPlane - depth * (farPlane - N);
        depth = saturate(depth);
        return depth * farPlane;
    }

    // Separate mode paths: in full-image mode no depth read occurs at all.
    float3 CompositeFullImage(float3 filtered, float2 texcoord)
    {
        float strength = saturate(FilterStrength);
        if (strength >= 0.999)
            return filtered;

        float3 original = tex2D(sOriginalInput, texcoord).rgb;
        return lerp(original, filtered, strength);
    }

    float3 CompositeAdaptiveDepth(float3 filtered, float2 texcoord)
    {
        float foreground = saturate(AdaptiveForegroundStrength);
        float background = saturate(AdaptiveBackgroundStrength);

        // Uniform endpoints are cheap fast paths and need no source/depth sample.
        if (foreground >= 0.999 && background >= 0.999)
            return filtered;

        // If the game does not expose a usable depth buffer, keep the full filtered
        // result rather than inventing a distance split.
        if (!HasDepth)
            return filtered;

        // Equal strengths make the adaptive mode spatially uniform, so depth is unnecessary.
        if (abs(background - foreground) <= 0.001)
        {
            float3 uniformOriginal = tex2D(sOriginalInput, texcoord).rgb;
            return lerp(uniformOriginal, filtered, foreground);
        }

        // This texture contains the image immediately before Kuwahara, not a
        // potentially invalid backbuffer copy, so zero-strength areas retain
        // their real source color.
        float3 original = tex2D(sOriginalInput, texcoord).rgb;

        if (foreground <= 0.001 && background <= 0.001)
            return original;

        float depthMeters = GetAdaptiveDepthMeters(texcoord);

        // A fixed 50 m-wide transition (25 m on either side of the boundary)
        // avoids an artificial hard wall between foreground and background.
        const float transitionHalfWidthMeters = 25.0;
        float transition = smoothstep(
            max(0.0, AdaptiveDepthBoundary - transitionHalfWidthMeters),
            AdaptiveDepthBoundary + transitionHalfWidthMeters,
            depthMeters);

        float strength = lerp(foreground, background, transition);
        return lerp(original, filtered, strength);
    }

    void BrushPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 outputColor : SV_TARGET0)
    {
        float3 base = tex2D(sOilifyResult, texcoord).rgb;

        // Resolve either the user-facing preset or the full advanced controls.
        // Presets only affect the painterly layer; the original Oilify controls
        // (Sharpness / Tuning / Scale) always remain independent.
        float brushStrength = BrushStrength;
        float strokeLength = StrokeLength;
        float strokeSpacing = StrokeSpacing;
        float strokeWidth = StrokeWidth;
        float strokeTaper = StrokeTaper;
        float strokeIrregularity = StrokeIrregularity;
        float strokeBend = StrokeBend;
        float strokeTexture = StrokeTexture;
        float strokeBristle = StrokeBristle;
        float paintLoad = PaintLoad;
        float strokeScatter = StrokeScatter;
        float strokeCoherence = StrokeCoherence;
        float paintDrag = PaintDrag;
        float anisotropyInfluence = AnisotropyInfluence;
        float directionJitter = DirectionJitter;
        float temporalInstability = TemporalInstability;
        float instabilitySpeed = InstabilitySpeed;
        float temporalEdgeSwim = TemporalEdgeSwim;
        float strokeEdge = StrokeEdge;
        float edgeWear = EdgeWear;
        float bristleBreakup = BristleBreakup;
        float paintRelief = PaintRelief;
        float edgeRespect = EdgeRespect;
        float pigmentVariation = PigmentVariation;
        float paintPooling = PaintPooling;
        float formResponse = FormResponse;
        float formMotion = FormMotion;
        float strokeClumping = StrokeClumping;
        float contourFlow = ContourFlow;

        if (!AdvancedSettings)
        {
            // Presets intentionally occupy different parts of the parameter space:
            // Soft Wash = broad/quiet, Classic Oil = balanced, Dry Brush = broken/airy.
            if (SimplePreset == 0)
            {
                brushStrength = 0.0;
                formResponse = 0.0;
                formMotion = 0.0;
                strokeClumping = 0.0;
                contourFlow = 0.0;
            }
            else if (SimplePreset == 1)
            {
                // Soft Wash: broad, low-frequency strokes with smooth coverage and almost no bristles.
                brushStrength = 0.12; strokeLength = 270.0; strokeSpacing = 128.0; strokeWidth = 0.94;
                strokeTaper = 0.18; strokeIrregularity = 0.08; strokeBend = 0.05; strokeTexture = 0.015;
                strokeBristle = 0.00; paintLoad = 0.06; strokeScatter = 0.04; strokeCoherence = 0.94;
                paintDrag = 0.0; anisotropyInfluence = 0.98; directionJitter = 0.02;
                temporalInstability = 0.0; instabilitySpeed = 0.10; temporalEdgeSwim = 0.0; strokeEdge = 2.4; edgeWear = 0.03;
                bristleBreakup = 0.0; paintRelief = 0.00;
                edgeRespect = 0.92; pigmentVariation = 0.04; paintPooling = 0.02;
                formResponse = 0.12; formMotion = 0.70; strokeClumping = 0.10; contourFlow = 0.04;
            }
            else if (SimplePreset == 2)
            {
                // Classic Oil: medium, dense strokes with clearly loaded paint and moderate bristle structure.
                brushStrength = 0.40; strokeLength = 145.0; strokeSpacing = 56.0; strokeWidth = 0.76;
                strokeTaper = 0.42; strokeIrregularity = 0.46; strokeBend = 0.28; strokeTexture = 0.32;
                strokeBristle = 0.42; paintLoad = 0.58; strokeScatter = 0.34; strokeCoherence = 0.64;
                paintDrag = 0.0; anisotropyInfluence = 0.92; directionJitter = 0.16;
                temporalInstability = 0.02; instabilitySpeed = 0.16; temporalEdgeSwim = 0.04; strokeEdge = 0.85; edgeWear = 0.34;
                bristleBreakup = 0.20; paintRelief = 0.34;
                edgeRespect = 0.64; pigmentVariation = 0.26; paintPooling = 0.24;
                formResponse = 0.52; formMotion = 0.48; strokeClumping = 0.46; contourFlow = 0.34;
            }
            else if (SimplePreset == 3)
            {
                // Long Strokes: sparse sweeping ribbons that follow the image flow.
                brushStrength = 0.47; strokeLength = 330.0; strokeSpacing = 116.0; strokeWidth = 0.60;
                strokeTaper = 0.64; strokeIrregularity = 0.20; strokeBend = 0.50; strokeTexture = 0.10;
                strokeBristle = 0.08; paintLoad = 0.50; strokeScatter = 0.16; strokeCoherence = 0.84;
                paintDrag = 0.0; anisotropyInfluence = 1.00; directionJitter = 0.08;
                temporalInstability = 0.02; instabilitySpeed = 0.11; temporalEdgeSwim = 0.03; strokeEdge = 1.7; edgeWear = 0.10;
                bristleBreakup = 0.05; paintRelief = 0.12;
                edgeRespect = 0.72; pigmentVariation = 0.16; paintPooling = 0.16;
                formResponse = 0.62; formMotion = 0.78; strokeClumping = 0.58; contourFlow = 0.22;
            }
            else if (SimplePreset == 4)
            {
                // Dry Brush: short, broken, narrow strokes with strong bristle gaps and scatter.
                brushStrength = 0.60; strokeLength = 108.0; strokeSpacing = 66.0; strokeWidth = 0.42;
                strokeTaper = 0.94; strokeIrregularity = 0.90; strokeBend = 0.50; strokeTexture = 0.52;
                strokeBristle = 1.00; paintLoad = 0.10; strokeScatter = 0.82; strokeCoherence = 0.26;
                paintDrag = 0.0; anisotropyInfluence = 0.76; directionJitter = 0.54;
                temporalInstability = 0.03; instabilitySpeed = 0.15; temporalEdgeSwim = 0.08; strokeEdge = 0.30; edgeWear = 1.00;
                bristleBreakup = 1.00; paintRelief = 0.04;
                edgeRespect = 0.24; pigmentVariation = 0.46; paintPooling = 0.04;
                formResponse = 0.88; formMotion = 0.30; strokeClumping = 0.18; contourFlow = 0.72;
            }
            else if (SimplePreset == 5)
            {
                // Impasto: short, thick, loaded marks with pronounced relief and pooling.
                brushStrength = 0.64; strokeLength = 108.0; strokeSpacing = 46.0; strokeWidth = 1.02;
                strokeTaper = 0.34; strokeIrregularity = 0.50; strokeBend = 0.16; strokeTexture = 0.44;
                strokeBristle = 0.52; paintLoad = 1.00; strokeScatter = 0.28; strokeCoherence = 0.72;
                paintDrag = 0.0; anisotropyInfluence = 0.74; directionJitter = 0.22;
                temporalInstability = 0.01; instabilitySpeed = 0.10; temporalEdgeSwim = 0.02; strokeEdge = 0.65; edgeWear = 0.30;
                bristleBreakup = 0.24; paintRelief = 1.00;
                edgeRespect = 0.76; pigmentVariation = 0.34; paintPooling = 0.42;
                formResponse = 0.46; formMotion = 0.18; strokeClumping = 0.60; contourFlow = 0.16;
            }
            else
            {
                // Living Paint: desynchronized medium strokes with strong, form-aware motion.
                brushStrength = 0.44; strokeLength = 164.0; strokeSpacing = 62.0; strokeWidth = 0.68;
                strokeTaper = 0.50; strokeIrregularity = 0.56; strokeBend = 0.36; strokeTexture = 0.26;
                strokeBristle = 0.36; paintLoad = 0.50; strokeScatter = 0.40; strokeCoherence = 0.54;
                paintDrag = 0.0; anisotropyInfluence = 0.90; directionJitter = 0.24;
                temporalInstability = 1.00; instabilitySpeed = 0.72; temporalEdgeSwim = 0.88; strokeEdge = 0.85; edgeWear = 0.46;
                bristleBreakup = 0.28; paintRelief = 0.30;
                edgeRespect = 0.54; pigmentVariation = 0.32; paintPooling = 0.28;
                formResponse = 0.58; formMotion = 0.92; strokeClumping = 0.42; contourFlow = 0.30;
            }
        }

        // Keep the base Oilify result when the painterly layer is disabled, but
        // continue to the mode-specific final blend so Filter Strength still works.
        float3 result = base;

        if (brushStrength > 0.001)
        {
        float2 pixel = texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT);
        float timeSeconds = TimerMs * 0.001 * max(instabilitySpeed, 0.0);
        float temporalAmount = saturate(temporalInstability);

        // One anisotropy fetch for the complete 3x3 stroke search.
        float3 anisotropyData = tex2D(sAnisotropy, texcoord).xyz;
        float2 baseTangent = anisotropyData.xy;
        float tangentLength = length(baseTangent);
        baseTangent = (tangentLength > 1e-4) ? (baseTangent / tangentLength) : float2(1.0, 0.0);
        float baseAnisotropy = saturate(anisotropyData.z);

        // Local visual complexity from the finished Oilify image. No extra fetches.
        float lumaDx = dot(ddx(base), float3(0.299, 0.587, 0.114));
        float lumaDy = dot(ddy(base), float3(0.299, 0.587, 0.114));
        float lumaGradient = abs(lumaDx) + abs(lumaDy);
        float edgeStrength = smoothstep(0.006, 0.055, lumaGradient * 2.25);
        float shapeComplexity = saturate(baseAnisotropy * 0.65 + edgeStrength * 0.35);

        // Optional contour-following flow. The gradient itself is already available
        // from ddx/ddy of the Oilify result, so this adds no texture fetches.
        float2 gradient = float2(lumaDx, lumaDy);
        float gradLen2 = max(dot(gradient, gradient), 1e-8);
        float2 edgeTangent = float2(-gradient.y, gradient.x) * rsqrt(gradLen2);
        if (dot(edgeTangent, baseTangent) < 0.0) edgeTangent = -edgeTangent;
        float contourBlend = saturate(contourFlow * edgeStrength);
        float2 flowTangent = lerp(baseTangent, edgeTangent, contourBlend);
        flowTangent *= rsqrt(max(dot(flowTangent, flowTangent), 1e-4));

        // These values are constant for all candidate strokes at this pixel.
        // Compute them once instead of repeating the work inside the 3x3 search.
        float formAmount = saturate(shapeComplexity * formResponse);
        float motionForm = saturate(shapeComplexity * formMotion);
        float adaptiveLengthScale = lerp(1.24, 0.58, formAmount);
        float adaptiveWidthScale = lerp(1.12, 0.74, formAmount);
        float tangentMotionScale = lerp(1.06, 0.68, motionForm);
        float normalMotionScale = lerp(0.92, 0.38, motionForm);
        float speedFormScale = lerp(1.00, 0.72, motionForm);
        float angleMotionScale = lerp(1.00, 0.44, motionForm);

        float strokeMask;
        float2 strokeCenter;
        float2 strokeTangent;
        float2 strokeNormal;
        float strokeLocalX;
        float strokeLocalY;
        float strokeSeed;
        float foundWidth;
        float foundLength;
        float strokeCurve;

        FindStrokeFast(
            pixel,
            flowTangent,
            baseAnisotropy,
            max(strokeLength, 20.0),
            max(strokeSpacing, 10.0),
            strokeWidth,
            strokeTaper,
            strokeIrregularity,
            strokeBend,
            strokeScatter,
            directionJitter,
            edgeWear,
            temporalEdgeSwim,
            temporalAmount,
            adaptiveLengthScale,
            adaptiveWidthScale,
            tangentMotionScale,
            normalMotionScale,
            speedFormScale,
            angleMotionScale,
            strokeClumping,
            timeSeconds,
            strokeMask,
            strokeCenter,
            strokeTangent,
            strokeNormal,
            strokeLocalX,
            strokeLocalY,
            strokeSeed,
            foundWidth,
            foundLength,
            strokeCurve);

        float directionFactor = lerp(
            0.80,
            1.0,
            smoothstep(0.01, 0.25, baseAnisotropy * anisotropyInfluence));
        strokeMask *= directionFactor;

        // Reuse the structure estimate for silhouette protection.
        float edgeProtection = lerp(1.0, 0.34, edgeStrength * saturate(edgeRespect));
        strokeMask *= edgeProtection;

        if (ShowStrokeMask)
        {
            outputColor = float4(saturate(pow(strokeMask.xxx, 0.72)), 1.0);
            return;
        }

        // Sparse brush layouts have many pixels outside a stroke. Avoid the
        // additional color fetch and paint math for those pixels, while still
        // allowing the mode-specific filter-strength composite below to run.
        if (strokeMask > 0.001)
        {
            // One coherent axial color sample. Paint Drag shifts this source along
            // the same axis instead of sampling both sides of the image edge.
            float2 axisPoint = strokeCenter
                             + strokeTangent * strokeLocalX
                             + strokeNormal * strokeCurve;
            axisPoint += strokeTangent * (paintDrag * strokeLength * 0.10);

            float2 axisUV = saturate(axisPoint * float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT));
            float3 axisColor = tex2D(sOilifyResult, axisUV).rgb;
            float3 strokeColor = lerp(base, axisColor, saturate(strokeCoherence));

            float paintCoverage;
            strokeColor = ApplyBroadPaintTexture(
                strokeColor,
                strokeLocalX,
                strokeLocalY,
                foundWidth,
                foundLength,
                strokeSeed,
                strokeTexture,
                strokeBristle,
                paintLoad,
                bristleBreakup,
                paintRelief,
                pigmentVariation,
                paintPooling,
                paintCoverage);

            float blend = saturate(strokeMask * brushStrength * paintCoverage);
            float edgeGuard = smoothstep(0.025, 0.12, strokeMask);
            blend *= edgeGuard;

            result = lerp(base, strokeColor, blend);
        }
        }

        // Mode selection is a single coherent uniform branch. The two compositing
        // paths are kept separate so Adaptive Depth never executes in Full Image
        // mode, and Full Image never samples the depth buffer.
        float3 finalColor;
        if (FilterMode == 0)
            finalColor = CompositeFullImage(result, texcoord);
        else
            finalColor = CompositeAdaptiveDepth(result, texcoord);

        outputColor = float4(finalColor, 1.0);
    }

    technique Oilify<
        ui_tooltip = "Anisotropic Kuwahara Oilify with a simple preset layer with strong style presets, grouped brush flow, visible temporal motion, and an optional detailed painterly toolkit."
    ;>
    {
        // Prepass: Posterization -> procedural canvas.
        // RT0 is the normal backbuffer. The pre-Oilify reference used for
        // strength blending is captured later during the existing anisotropy pass.
        pass
        {
            VertexShader = PostProcessVS;
            PixelShader = PreOilifyPS;
        }

        // Original anisotropy pass.
        pass
        {
            VertexShader = PostProcessVS;
            PixelShader = AnisotropyPS;
            RenderTarget0 = Anisotropy;
            RenderTarget1 = OriginalInput;
        }

        // Intermediate Kuwahara iterations write to the normal backbuffer.
#if OILIFY_ITERATIONS > 1
        OILIFY_PASS
#endif
#if OILIFY_ITERATIONS > 2
        OILIFY_PASS
#endif
#if OILIFY_ITERATIONS > 3
        OILIFY_PASS
#endif
#if OILIFY_ITERATIONS > 4
        OILIFY_PASS
#endif
#if OILIFY_ITERATIONS > 5
        OILIFY_PASS
#endif
#if OILIFY_ITERATIONS > 6
        OILIFY_PASS
#endif
#if OILIFY_ITERATIONS > 7
        OILIFY_PASS
#endif

        // Final Kuwahara iteration is written directly to OilifyResult.
        // This removes the full-screen Capture pass used by v8/v9.
        OILIFY_FINAL_PASS

        // Lightweight final painterly layer.
        pass
        {
            VertexShader = PostProcessVS;
            PixelShader = BrushPS;
        }
    }
}
