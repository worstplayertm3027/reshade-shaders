/*
 * Ganossa Motion Focus - Modern Edition
 *
 * Original concept:
 *   Ganossa (mediehawk@gmail.com)
 * Original port credit:
 *   IDDQD
 *
 * Modern additions:
 *   - Resolution-independent motion analysis (fixed 32x18 grid)
 *   - Frame-time-aware temporal persistence
 *   - Independent motion fisheye
 *   - Independent motion chromatic aberration
 *   - Independent edge Gaussian blur
 *   - Separate deadzone + persistence for every motion-driven effect
 *   - Each optional effect has its own checkbox + collapsible UI category
   - Idle figure-eight head sway integrated into Motion Focus/Zoom framing
 *
 * Target: current ReShade FX / ReShade 6.x+
 * Head Sway V3: continuous speed reduction instead of hard idle stop
 * Fisheye V4: accumulated attack + persistence release, with a more sensitive
 *             instantaneous motion readout for localized camera movement
 */

#include "ReShade.fxh"

// ============================================================================
// Preset / manual configuration
// ============================================================================

uniform int mfPreset
<
    ui_type = "combo";
    ui_category = "Effect Preset";
    ui_label = "Effect preset";
    ui_items = "Original / Recommended\0Cinematic\0Dynamic\0Subtle\0Focus Only\0";
    ui_tooltip = "Select a complete effect preset. Manual settings override the selected preset independently for each effect.";
> = 0;

// ============================================================================
// Motion Focus controls
// ============================================================================

uniform bool mfManualMotionFocus
<
    ui_type = "checkbox";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_category_closed = true;
    ui_category_toggle = true;
    ui_label = "Manual Motion Focus";
    ui_tooltip = "Show and use Motion Focus parameters instead of the selected preset.";
> = false;

uniform bool mfDebug
<
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_label = "Debug overlay";
    ui_tooltip = "Show the detected motion center and current motion activity.";
> = false;

uniform bool mfResetHistory
<
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_type = "button";
    ui_label = "Reset motion history";
    ui_tooltip = "Clear all temporal histories. Useful after scene cuts or when enabling the effect mid-game.";
> = false;

uniform float mfFocusStrength
<
    ui_type = "slider";
    ui_label = "Focus strength";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "How strongly the image follows the detected motion center.";
> = 1.0;

uniform float mfZoomStrength
<
    ui_type = "slider";
    ui_label = "Zoom strength";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "How strongly the image zooms toward the detected motion.";
> = 0.60;

uniform float mfMotionSensitivity
<
    ui_type = "slider";
    ui_label = "Motion sensitivity";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_min = 0.25;
    ui_max = 4.0;
    ui_step = 0.05;
    ui_tooltip = "Amplifies frame-to-frame image changes before converting them into motion intensity.";
> = 1.50;

uniform float mfMotionThreshold
<
    ui_type = "slider";
    ui_label = "Motion threshold";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_min = 0.0;
    ui_max = 0.10;
    ui_step = 0.001;
    ui_tooltip = "Suppresses tiny frame-to-frame changes such as dithering and post-process noise.";
> = 0.10;

uniform float mfPersistence
<
    ui_type = "slider";
    ui_label = "Motion persistence";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_min = 0.0;
    ui_max = 0.999;
    ui_step = 0.001;
    ui_tooltip = "How long detected motion remains in the Motion Focus history.";
> = 0.960;

uniform float mfFocusSmoothing
<
    ui_type = "slider";
    ui_label = "Focus smoothing";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_min = 0.01;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Response speed of the tracked focus point. Higher values react faster.";
> = 0.25;

uniform float mfDeadzone
<
    ui_type = "slider";
    ui_label = "Focus deadzone";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_min = 0.0;
    ui_max = 0.25;
    ui_step = 0.005;
    ui_tooltip = "Ignore small focus offsets around the screen center.";
> = 0.25;

uniform float mfMaxZoom
<
    ui_type = "slider";
    ui_label = "Maximum zoom";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_min = 0.0;
    ui_max = 0.50;
    ui_step = 0.01;
    ui_tooltip = "Maximum zoom-in amount. 0.20 means up to 20 percent.";
> = 0.30;

uniform float mfMaxShift
<
    ui_type = "slider";
    ui_label = "Maximum focus shift";
    ui_category = "Advanced - Motion Focus (Manual Settings)";
    ui_min = 0.0;
    ui_max = 0.50;
    ui_step = 0.01;
    ui_tooltip = "Maximum camera translation caused by motion tracking.";
> = 0.30;

// ============================================================================
// Head Sway controls (subsystem of Motion Focus)
// ============================================================================

uniform bool mfManualHeadSway
<
    ui_type = "checkbox";
    ui_category = "Advanced - Head Sway";
    ui_category_closed = true;
    ui_category_toggle = true;
    ui_label = "Manual Head Sway";
    ui_tooltip = "Show and use Head Sway parameters instead of the selected preset.";
> = false;

uniform bool mfHeadSwayEnable
<
    ui_type = "checkbox";
    ui_category = "Advanced - Head Sway";
    ui_category_closed = true;
    ui_label = "Enable head sway";
    ui_tooltip = "Adds a subtle figure-eight head movement while strong on-screen motion is absent. Implemented inside the Motion Focus framing pass so the sampled image stays inside the rendered frame.";
> = false;

uniform float mfHeadSwayStrength
<
    ui_type = "slider";
    ui_category = "Advanced - Head Sway";
    ui_label = "Head sway strength";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Overall amplitude of the idle figure-eight camera sway.";
> = 0.22;

uniform float mfHeadSwaySpeed
<
    ui_type = "slider";
    ui_category = "Advanced - Head Sway";
    ui_label = "Head sway speed";
    ui_min = 0.05;
    ui_max = 1.00;
    ui_step = 0.01;
    ui_units = "Hz";
    ui_tooltip = "Speed of the figure-eight head movement in cycles per second.";
> = 0.18;

uniform float mfHeadSwayMotionThreshold
<
    ui_type = "slider";
    ui_category = "Advanced - Head Sway";
    ui_label = "Motion slowdown threshold";
    ui_min = 0.0;
    ui_max = 0.50;
    ui_step = 0.005;
    ui_tooltip = "On-screen motion below this level does not slow the head sway. Above it, the sway gradually becomes slower.";
> = 0.0;

uniform float mfHeadSwayMinSpeed
<
    ui_type = "slider";
    ui_category = "Advanced - Head Sway";
    ui_label = "Minimum sway speed";
    ui_min = 0.01;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Lowest fraction of the configured head-sway speed. Strong motion can slow the sway down to this value, but never to zero.";
> = 0.01;

uniform float mfHeadSwayMotionResponse
<
    ui_type = "slider";
    ui_category = "Advanced - Head Sway";
    ui_label = "Motion slowdown curve";
    ui_min = 0.25;
    ui_max = 4.0;
    ui_step = 0.05;
    ui_tooltip = "Controls how gradually screen motion reduces sway speed. Lower values begin slowing earlier; higher values keep the original speed longer and slow it mainly during stronger motion.";
> = 0.25;

uniform float mfHeadSwayHorizontal
<
    ui_type = "slider";
    ui_category = "Advanced - Head Sway";
    ui_label = "Horizontal sway";
    ui_min = 0.0;
    ui_max = 0.05;
    ui_step = 0.001;
    ui_tooltip = "Maximum horizontal image shift used by the figure-eight motion, in normalized screen space.";
> = 0.012;

uniform float mfHeadSwayVerticalRatio
<
    ui_type = "slider";
    ui_category = "Advanced - Head Sway";
    ui_label = "Vertical sway ratio";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Vertical amplitude relative to horizontal amplitude. Lower values make the head motion flatter.";
> = 0.55;

uniform float mfHeadSwayFramingZoom
<
    ui_type = "slider";
    ui_category = "Advanced - Head Sway";
    ui_label = "Sway framing zoom";
    ui_min = 0.0;
    ui_max = 0.15;
    ui_step = 0.005;
    ui_tooltip = "Small internal zoom reserved for head sway when Motion Focus itself is not zooming, so the image can move without exposing pixels outside the rendered frame.";
> = 0.0;

// ============================================================================
// Motion Fisheye controls
// ============================================================================

uniform bool mfManualFisheye
<
    ui_type = "checkbox";
    ui_category = "Advanced - Motion Fisheye";
    ui_category_closed = true;
    ui_category_toggle = true;
    ui_label = "Manual Fisheye";
    ui_tooltip = "Show and use Motion Fisheye parameters instead of the selected preset.";
> = false;

uniform bool mfFisheyeEnable
<
    ui_type = "checkbox";
    ui_category = "Advanced - Motion Fisheye";
    ui_category_closed = true;
    ui_label = "Enable motion fisheye";
    ui_tooltip = "Enable motion-driven radial distortion that is concentrated toward the screen edges.";
> = false;

uniform float mfFisheyeStrength
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Fisheye";
    ui_label = "Fisheye strength";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Maximum fisheye distortion strength.";
> = 0.55;

uniform float mfFisheyeSpeedCurve
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Fisheye";
    ui_label = "Fisheye speed response";
    ui_min = 0.50;
    ui_max = 3.0;
    ui_step = 0.05;
    ui_tooltip = "Shapes how rapidly fisheye reacts to motion. 1.0 is linear.";
> = 1.00;

uniform float mfFisheyeMotionGain
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Fisheye";
    ui_label = "Motion-to-fisheye gain";
    ui_min = 1.0;
    ui_max = 50.0;
    ui_step = 0.5;
    ui_tooltip = "Amplifies the motion signal before converting it into fisheye strength.";
> = 1.0;

uniform float mfFisheyeAccumulation
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Fisheye";
    ui_label = "Fisheye accumulation speed";
    ui_min = 0.01;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "How quickly fisheye builds toward the current motion target. Lower values make the effect accumulate more gradually.";
> = 0.08;

uniform float mfFisheyePersistence
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Fisheye";
    ui_label = "Fisheye persistence";
    ui_min = 0.0;
    ui_max = 0.999;
    ui_step = 0.001;
    ui_tooltip = "How gradually the fisheye fades after motion stops.";
> = 0.940;

uniform float mfFisheyeDeadzone
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Fisheye";
    ui_label = "Fisheye deadzone";
    ui_min = 0.0;
    ui_max = 0.50;
    ui_step = 0.005;
    ui_tooltip = "Ignore weak motion below this level for fisheye.";
> = 0.020;

uniform float mfFisheyeEdgeStart
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Fisheye";
    ui_label = "Fisheye edge start";
    ui_min = 0.0;
    ui_max = 0.85;
    ui_step = 0.01;
    ui_tooltip = "Normalized radius where fisheye begins. Higher values keep it closer to the edges.";
> = 0.25;

uniform float mfFisheyeAspect
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Fisheye";
    ui_label = "Fisheye aspect correction";
    ui_min = 0.50;
    ui_max = 1.50;
    ui_step = 0.01;
    ui_tooltip = "Fine-tune aspect correction. 1.0 is the normal setting.";
> = 1.0;

// ============================================================================
// Motion Chromatic Aberration controls
// ============================================================================

uniform bool mfManualCA
<
    ui_type = "checkbox";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_category_closed = true;
    ui_category_toggle = true;
    ui_label = "Manual Chromatic Aberration";
    ui_tooltip = "Show and use chromatic aberration parameters instead of the selected preset.";
> = false;

uniform bool mfCAEnable
<
    ui_type = "checkbox";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_category_closed = true;
    ui_label = "Enable motion chromatic aberration";
    ui_tooltip = "Add motion-driven RGB separation that is concentrated toward the screen edges. Independent from fisheye and blur.";
> = false;

uniform float mfCAStrength
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_label = "Chromatic aberration strength";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Maximum RGB separation strength.";
> = 0.55;

uniform float mfCAMaxSeparation
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_label = "Maximum color separation";
    ui_min = 0.0;
    ui_max = 16.0;
    ui_step = 0.25;
    ui_units = "px";
    ui_tooltip = "Maximum red/blue channel separation at full effect strength.";
> = 3.0;

uniform float mfCASpeedCurve
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_label = "Aberration speed response";
    ui_min = 0.50;
    ui_max = 3.0;
    ui_step = 0.05;
    ui_tooltip = "Shapes how rapidly chromatic aberration reacts to motion.";
> = 3.00;

uniform float mfCAMotionGain
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_label = "Motion-to-aberration gain";
    ui_min = 1.0;
    ui_max = 50.0;
    ui_step = 0.5;
    ui_tooltip = "Amplifies the motion signal before converting it into chromatic aberration.";
> = 50.0;

uniform float mfCAPersistence
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_label = "Aberration persistence";
    ui_min = 0.0;
    ui_max = 0.999;
    ui_step = 0.001;
    ui_tooltip = "How gradually chromatic aberration fades after motion stops.";
> = 0.940;

uniform float mfCADeadzone
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_label = "Aberration deadzone";
    ui_min = 0.0;
    ui_max = 0.50;
    ui_step = 0.005;
    ui_tooltip = "Ignore weak motion below this level for chromatic aberration.";
> = 0.020;

uniform float mfCAEdgeStart
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_label = "Aberration edge start";
    ui_min = 0.0;
    ui_max = 0.85;
    ui_step = 0.01;
    ui_tooltip = "Normalized radius where RGB separation begins.";
> = 0.35;

uniform float mfCAAspect
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Chromatic Aberration";
    ui_label = "Aberration aspect correction";
    ui_min = 0.50;
    ui_max = 1.50;
    ui_step = 0.01;
    ui_tooltip = "Fine-tune radial direction on ultrawide or unusual aspect ratios. 1.0 is the normal setting.";
> = 1.0;

// ============================================================================
// Motion Edge Gaussian Blur controls
// ============================================================================

uniform bool mfManualBlur
<
    ui_type = "checkbox";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_category_closed = true;
    ui_category_toggle = true;
    ui_label = "Manual Edge Gaussian Blur";
    ui_tooltip = "Show and use edge blur parameters instead of the selected preset.";
> = false;

uniform bool mfBlurEnable
<
    ui_type = "checkbox";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_category_closed = true;
    ui_label = "Enable motion edge blur";
    ui_tooltip = "Add a motion-driven Gaussian-like blur toward the screen edges. Independent from fisheye and chromatic aberration.";
> = false;

uniform float mfBlurStrength
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_label = "Edge blur strength";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Maximum blend amount of the edge blur.";
> = 0.75;

uniform float mfBlurRadius
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_label = "Blur radius";
    ui_min = 0.0;
    ui_max = 16.0;
    ui_step = 0.25;
    ui_units = "px";
    ui_tooltip = "Maximum blur radius at full effect strength.";
> = 5.0;

uniform float mfBlurSpeedCurve
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_label = "Blur speed response";
    ui_min = 0.50;
    ui_max = 3.0;
    ui_step = 0.05;
    ui_tooltip = "Shapes how rapidly edge blur reacts to motion.";
> = 1.00;

uniform float mfBlurMotionGain
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_label = "Motion-to-blur gain";
    ui_min = 1.0;
    ui_max = 50.0;
    ui_step = 0.5;
    ui_tooltip = "Amplifies the motion signal before converting it into blur strength.";
> = 50.0;

uniform float mfBlurPersistence
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_label = "Blur persistence";
    ui_min = 0.0;
    ui_max = 0.999;
    ui_step = 0.001;
    ui_tooltip = "How gradually edge blur fades after motion stops.";
> = 0.940;

uniform float mfBlurDeadzone
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_label = "Blur deadzone";
    ui_min = 0.0;
    ui_max = 0.50;
    ui_step = 0.005;
    ui_tooltip = "Ignore weak motion below this level for edge blur.";
> = 0.020;

uniform float mfBlurEdgeStart
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_label = "Blur edge start";
    ui_min = 0.0;
    ui_max = 0.85;
    ui_step = 0.01;
    ui_tooltip = "Normalized radius where edge blur begins.";
> = 0.40;

uniform float mfBlurAspect
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Edge Gaussian Blur";
    ui_label = "Blur aspect correction";
    ui_min = 0.50;
    ui_max = 1.50;
    ui_step = 0.01;
    ui_tooltip = "Fine-tune the radial edge mask. 1.0 is the normal setting.";
> = 1.0;

// ============================================================================
// Motion Camera Gaussian Blur controls
// ============================================================================

uniform bool mfManualCameraBlur
<
    ui_type = "checkbox";
    ui_category = "Advanced - Motion Camera Gaussian Blur";
    ui_category_closed = true;
    ui_category_toggle = true;
    ui_label = "Manual Camera Gaussian Blur";
    ui_tooltip = "Show and use camera Gaussian blur parameters instead of the selected preset.";
> = false;

uniform bool mfCameraBlurEnable
<
    ui_type = "checkbox";
    ui_category = "Advanced - Motion Camera Gaussian Blur";
    ui_category_closed = true;
    ui_label = "Enable camera Gaussian blur";
    ui_tooltip = "Adds a full-screen Gaussian blur that responds primarily to coherent camera movement rather than isolated object motion.";
> = false;

uniform float mfCameraBlurStrength
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Camera Gaussian Blur";
    ui_label = "Camera blur strength";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Maximum blend strength of the camera-motion Gaussian blur.";
> = 0.80;

uniform float mfCameraBlurRadius
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Camera Gaussian Blur";
    ui_label = "Camera blur radius";
    ui_min = 0.0;
    ui_max = 20.0;
    ui_step = 0.25;
    ui_units = "px";
    ui_tooltip = "Maximum Gaussian blur radius at full camera-motion strength.";
> = 20.0;

uniform float mfCameraBlurResponse
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Camera Gaussian Blur";
    ui_label = "Camera blur response";
    ui_min = 0.05;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "How quickly the blur builds when coherent camera motion begins.";
> = 0.35;

uniform float mfCameraBlurMotionGain
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Camera Gaussian Blur";
    ui_label = "Motion-to-blur gain";
    ui_min = 1.0;
    ui_max = 80.0;
    ui_step = 0.5;
    ui_tooltip = "Amplifies coherent scene motion before converting it into camera blur strength.";
> = 80.0;

uniform float mfCameraBlurPersistence
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Camera Gaussian Blur";
    ui_label = "Camera blur persistence";
    ui_min = 0.0;
    ui_max = 0.999;
    ui_step = 0.001;
    ui_tooltip = "How gradually camera blur fades after the camera stops moving.";
> = 0.940;

uniform float mfCameraBlurDeadzone
<
    ui_type = "slider";
    ui_category = "Advanced - Motion Camera Gaussian Blur";
    ui_label = "Camera blur deadzone";
    ui_min = 0.0;
    ui_max = 0.50;
    ui_step = 0.005;
    ui_tooltip = "Ignore very small coherent camera motion below this level.";
> = 0.015;

// ============================================================================
// Preset evaluation helpers
// ============================================================================
//
// The original version repeated the same preset-selection chain in every helper.
// These compact selectors preserve the exact preset-0..3 / preset-4-fallback
// behavior while reducing source size and redundant control flow.
//
// mfPreset:
//   0 = Original / Recommended
//   1 = Cinematic
//   2 = Dynamic
//   3 = Subtle
//   4 = Focus Only (falls back to the Original / Recommended values here)

float MF_Preset4(float p0, float p1, float p2, float p3)
{
    if (mfPreset == 1) return p1;
    if (mfPreset == 2) return p2;
    if (mfPreset == 3) return p3;
    return p0;
}

bool MF_Preset4Bool(bool p0, bool p1, bool p2, bool p3)
{
    if (mfPreset == 1) return p1;
    if (mfPreset == 2) return p2;
    if (mfPreset == 3) return p3;
    return p0;
}

float MF_Eff_mfFocusStrength()
{
    if (mfManualMotionFocus)
        return mfFocusStrength;
    return 1.0;
}

float MF_Eff_mfZoomStrength()
{
    if (mfManualMotionFocus)
        return mfZoomStrength;
    return 0.60;
}

float MF_Eff_mfMotionSensitivity()
{
    if (mfManualMotionFocus)
        return mfMotionSensitivity;
    return 1.50;
}

float MF_Eff_mfMotionThreshold()
{
    if (mfManualMotionFocus)
        return mfMotionThreshold;
    return 0.10;
}

float MF_Eff_mfPersistence()
{
    if (mfManualMotionFocus)
        return mfPersistence;
    return 0.960;
}

float MF_Eff_mfFocusSmoothing()
{
    if (mfManualMotionFocus)
        return mfFocusSmoothing;
    return 0.25;
}

float MF_Eff_mfDeadzone()
{
    if (mfManualMotionFocus)
        return mfDeadzone;
    return 0.25;
}

float MF_Eff_mfMaxZoom()
{
    if (mfManualMotionFocus)
        return mfMaxZoom;
    return 0.30;
}

float MF_Eff_mfMaxShift()
{
    if (mfManualMotionFocus)
        return mfMaxShift;
    return 0.30;
}

bool MF_Eff_mfHeadSwayEnable()
{
    if (mfManualHeadSway)
        return mfHeadSwayEnable;
    return true;
}

float MF_Eff_mfHeadSwayStrength()
{
    if (mfManualHeadSway)
        return mfHeadSwayStrength;
    return MF_Preset4(0.22, 0.16, 0.18, 0.12);
}

float MF_Eff_mfHeadSwaySpeed()
{
    if (mfManualHeadSway)
        return mfHeadSwaySpeed;
    return MF_Preset4(0.18, 0.16, 0.20, 0.14);
}

float MF_Eff_mfHeadSwayMotionThreshold()
{
    if (mfManualHeadSway)
        return mfHeadSwayMotionThreshold;
    return 0.0;
}

float MF_Eff_mfHeadSwayMinSpeed()
{
    if (mfManualHeadSway)
        return mfHeadSwayMinSpeed;
    return MF_Preset4(0.01, 0.05, 0.01, 0.01);
}

float MF_Eff_mfHeadSwayMotionResponse()
{
    if (mfManualHeadSway)
        return mfHeadSwayMotionResponse;
    return 0.25;
}

float MF_Eff_mfHeadSwayHorizontal()
{
    if (mfManualHeadSway)
        return mfHeadSwayHorizontal;
    return 0.012;
}

float MF_Eff_mfHeadSwayVerticalRatio()
{
    if (mfManualHeadSway)
        return mfHeadSwayVerticalRatio;
    return 0.55;
}

float MF_Eff_mfHeadSwayFramingZoom()
{
    if (mfManualHeadSway)
        return mfHeadSwayFramingZoom;
    return 0.0;
}

bool MF_Eff_mfFisheyeEnable()
{
    if (mfManualFisheye)
        return mfFisheyeEnable;
    return true;
}

float MF_Eff_mfFisheyeStrength()
{
    if (mfManualFisheye)
        return mfFisheyeStrength;
    return MF_Preset4(0.55, 0.35, 0.75, 0.25);
}

float MF_Eff_mfFisheyeSpeedCurve()
{
    if (mfManualFisheye)
        return mfFisheyeSpeedCurve;
    return MF_Preset4(1.00, 1.20, 1.00, 1.00);
}

float MF_Eff_mfFisheyeMotionGain()
{
    if (mfManualFisheye)
        return mfFisheyeMotionGain;
    return MF_Preset4(1.0, 2.0, 3.0, 2.0);
}

float MF_Eff_mfFisheyeAccumulation()
{
    if (mfManualFisheye)
        return mfFisheyeAccumulation;
    return MF_Preset4(0.08, 0.08, 0.12, 0.08);
}

float MF_Eff_mfFisheyePersistence()
{
    if (mfManualFisheye)
        return mfFisheyePersistence;
    return 0.940;
}

float MF_Eff_mfFisheyeDeadzone()
{
    if (mfManualFisheye)
        return mfFisheyeDeadzone;
    return 0.020;
}

float MF_Eff_mfFisheyeEdgeStart()
{
    if (mfManualFisheye)
        return mfFisheyeEdgeStart;
    return 0.25;
}

float MF_Eff_mfFisheyeAspect()
{
    if (mfManualFisheye)
        return mfFisheyeAspect;
    return 1.0;
}

bool MF_Eff_mfCAEnable()
{
    if (mfManualCA)
        return mfCAEnable;
    return true;
}

float MF_Eff_mfCAStrength()
{
    if (mfManualCA)
        return mfCAStrength;
    return MF_Preset4(0.55, 0.28, 0.65, 0.18);
}

float MF_Eff_mfCAMaxSeparation()
{
    if (mfManualCA)
        return mfCAMaxSeparation;
    return MF_Preset4(3.0, 2.25, 4.0, 1.50);
}

float MF_Eff_mfCASpeedCurve()
{
    if (mfManualCA)
        return mfCASpeedCurve;
    return 3.00;
}

float MF_Eff_mfCAMotionGain()
{
    if (mfManualCA)
        return mfCAMotionGain;
    return MF_Preset4(50.0, 35.0, 50.0, 50.0);
}

float MF_Eff_mfCAPersistence()
{
    if (mfManualCA)
        return mfCAPersistence;
    return 0.940;
}

float MF_Eff_mfCADeadzone()
{
    if (mfManualCA)
        return mfCADeadzone;
    return 0.020;
}

float MF_Eff_mfCAEdgeStart()
{
    if (mfManualCA)
        return mfCAEdgeStart;
    return 0.35;
}

float MF_Eff_mfCAAspect()
{
    if (mfManualCA)
        return mfCAAspect;
    return 1.0;
}

bool MF_Eff_mfBlurEnable()
{
    if (mfManualBlur)
        return mfBlurEnable;
    return true;
}

float MF_Eff_mfBlurStrength()
{
    if (mfManualBlur)
        return mfBlurStrength;
    return MF_Preset4(0.75, 0.45, 0.90, 0.30);
}

float MF_Eff_mfBlurRadius()
{
    if (mfManualBlur)
        return mfBlurRadius;
    return MF_Preset4(5.0, 4.0, 7.0, 3.0);
}

float MF_Eff_mfBlurSpeedCurve()
{
    if (mfManualBlur)
        return mfBlurSpeedCurve;
    return 1.00;
}

float MF_Eff_mfBlurMotionGain()
{
    if (mfManualBlur)
        return mfBlurMotionGain;
    return MF_Preset4(50.0, 40.0, 50.0, 35.0);
}

float MF_Eff_mfBlurPersistence()
{
    if (mfManualBlur)
        return mfBlurPersistence;
    return 0.940;
}

float MF_Eff_mfBlurDeadzone()
{
    if (mfManualBlur)
        return mfBlurDeadzone;
    return 0.020;
}

float MF_Eff_mfBlurEdgeStart()
{
    if (mfManualBlur)
        return mfBlurEdgeStart;
    return 0.40;
}

float MF_Eff_mfBlurAspect()
{
    if (mfManualBlur)
        return mfBlurAspect;
    return 1.0;
}

bool MF_Eff_mfCameraBlurEnable()
{
    if (mfManualCameraBlur)
        return mfCameraBlurEnable;
    return true;
}

float MF_Eff_mfCameraBlurStrength()
{
    if (mfManualCameraBlur)
        return mfCameraBlurStrength;
    return MF_Preset4(0.80, 0.80, 0.95, 0.50);
}

float MF_Eff_mfCameraBlurRadius()
{
    if (mfManualCameraBlur)
        return mfCameraBlurRadius;
    return MF_Preset4(20.0, 14.0, 20.0, 6.0);
}

float MF_Eff_mfCameraBlurResponse()
{
    if (mfManualCameraBlur)
        return mfCameraBlurResponse;
    return MF_Preset4(0.35, 0.30, 0.45, 0.25);
}

float MF_Eff_mfCameraBlurMotionGain()
{
    if (mfManualCameraBlur)
        return mfCameraBlurMotionGain;
    return MF_Preset4(80.0, 75.0, 80.0, 45.0);
}

float MF_Eff_mfCameraBlurPersistence()
{
    if (mfManualCameraBlur)
        return mfCameraBlurPersistence;
    return 0.940;
}

float MF_Eff_mfCameraBlurDeadzone()
{
    if (mfManualCameraBlur)
        return mfCameraBlurDeadzone;
    return 0.015;
}

// ============================================================================
// Runtime values
// ============================================================================

uniform int mfFrameCount
<
    source = "framecount";
    hidden = true;
>;

uniform float mfFrameTime
<
    source = "frametime";
    hidden = true;
>;

uniform float mfTimer
<
    source = "timer";
    hidden = true;
>;

// ============================================================================
// Internal resolution / texture definitions
// ============================================================================

#define MF_HALF_WIDTH      (BUFFER_WIDTH / 2)
#define MF_HALF_HEIGHT     (BUFFER_HEIGHT / 2)
#define MF_ANALYSIS_X      32
#define MF_ANALYSIS_Y      18
#define MF_QUAD_X          (MF_ANALYSIS_X / 2)
#define MF_QUAD_Y          (MF_ANALYSIS_Y / 2)
#define MF_QUAD_SAMPLES    (MF_QUAD_X * MF_QUAD_Y)
#define MF_TOTAL_SAMPLES   (MF_ANALYSIS_X * MF_ANALYSIS_Y)

texture2D Ganossa_MF_CurrentTex
{
    Width = MF_HALF_WIDTH;
    Height = MF_HALF_HEIGHT;
    Format = RG16F;
    MipLevels = 1;
};

texture2D Ganossa_MF_PreviousTex
{
    Width = MF_HALF_WIDTH;
    Height = MF_HALF_HEIGHT;
    Format = RG16F;
    MipLevels = 1;
};

texture2D Ganossa_MF_MotionTex
{
    Width = MF_HALF_WIDTH;
    Height = MF_HALF_HEIGHT;
    Format = RG16F;
    MipLevels = 1;
};

texture2D Ganossa_MF_PreviousMotionTex
{
    Width = MF_HALF_WIDTH;
    Height = MF_HALF_HEIGHT;
    Format = RG16F;
    MipLevels = 1;
};

// 1x1 State: xy = focus offset, z = persistent focus activity, w = quadrant contrast.
texture2D Ganossa_MF_StateTex
{
    Width = 1;
    Height = 1;
    Format = RGBA16F;
    MipLevels = 1;
};

texture2D Ganossa_MF_PreviousStateTex
{
    Width = 1;
    Height = 1;
    Format = RGBA16F;
    MipLevels = 1;
};

// 1x1 Effects speed state:
//   R = Fisheye accumulated motion drive
//   G = Chromatic aberration persistent speed
//   B = Edge blur persistent speed
//   A = instantaneous motion activity for Head Sway speed control
texture2D Ganossa_MF_EffectsSpeedTex
{
    Width = 1;
    Height = 1;
    Format = RGBA16F;
    MipLevels = 1;
};

texture2D Ganossa_MF_PreviousEffectsSpeedTex
{
    Width = 1;
    Height = 1;
    Format = RGBA16F;
    MipLevels = 1;
};


// Independent 1x1 camera-motion blur state:
//   R = temporal camera Gaussian blur drive.
texture2D Ganossa_MF_CameraBlurSpeedTex
{
    Width = 1;
    Height = 1;
    Format = R16F;
    MipLevels = 1;
};

texture2D Ganossa_MF_PreviousCameraBlurSpeedTex
{
    Width = 1;
    Height = 1;
    Format = R16F;
    MipLevels = 1;
};

// 1x1 accumulated phase for the Head Sway oscillator. Keeping phase in history
// allows its angular speed to change smoothly from frame to frame.
texture2D Ganossa_MF_HeadSwayPhaseTex
{
    Width = 1;
    Height = 1;
    Format = R16F;
    MipLevels = 1;
};

texture2D Ganossa_MF_PreviousHeadSwayPhaseTex
{
    Width = 1;
    Height = 1;
    Format = R16F;
    MipLevels = 1;
};

// Full-resolution ping-pong textures for independent post effects.
// Using separate passes keeps each optional effect truly independent.
texture2D Ganossa_MF_BaseTex
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
    MipLevels = 1;
};

texture2D Ganossa_MF_CAOutputTex
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
    MipLevels = 1;
};


texture2D Ganossa_MF_EdgeBlurOutputTex
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
    MipLevels = 1;
};

sampler2D Ganossa_MF_CurrentColor
{
    Texture = Ganossa_MF_CurrentTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_PreviousColor
{
    Texture = Ganossa_MF_PreviousTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_MotionColor
{
    Texture = Ganossa_MF_MotionTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_PreviousMotionColor
{
    Texture = Ganossa_MF_PreviousMotionTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_StateColor
{
    Texture = Ganossa_MF_StateTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = POINT;
    MinFilter = POINT;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_PreviousStateColor
{
    Texture = Ganossa_MF_PreviousStateTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = POINT;
    MinFilter = POINT;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_EffectsSpeedColor
{
    Texture = Ganossa_MF_EffectsSpeedTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = POINT;
    MinFilter = POINT;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_PreviousEffectsSpeedColor
{
    Texture = Ganossa_MF_PreviousEffectsSpeedTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = POINT;
    MinFilter = POINT;
    MipFilter = POINT;
};


sampler2D Ganossa_MF_CameraBlurSpeedColor
{
    Texture = Ganossa_MF_CameraBlurSpeedTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = POINT;
    MinFilter = POINT;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_PreviousCameraBlurSpeedColor
{
    Texture = Ganossa_MF_PreviousCameraBlurSpeedTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = POINT;
    MinFilter = POINT;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_HeadSwayPhaseColor
{
    Texture = Ganossa_MF_HeadSwayPhaseTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = POINT;
    MinFilter = POINT;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_PreviousHeadSwayPhaseColor
{
    Texture = Ganossa_MF_PreviousHeadSwayPhaseTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = POINT;
    MinFilter = POINT;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_BaseColor
{
    Texture = Ganossa_MF_BaseTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};

sampler2D Ganossa_MF_CAOutputColor
{
    Texture = Ganossa_MF_CAOutputTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};


sampler2D Ganossa_MF_EdgeBlurOutputColor
{
    Texture = Ganossa_MF_EdgeBlurOutputTex;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};

// ============================================================================
// Helpers
// ============================================================================

float2 MF_GetColorFeatures(float3 color)
{
    float luma = dot(color, float3(0.2126f, 0.7152f, 0.0722f));
    float chroma = max(color.r, max(color.g, color.b)) -
                   min(color.r, min(color.g, color.b));
    return float2(luma, chroma);
}

float MF_FrameScale60()
{
    // Approximate a 60 Hz reference frame. Clamp to avoid extreme jumps on stalls.
    float frameScale = 16.6667f / max(0.25f, mfFrameTime);
    return clamp(frameScale, 0.25f, 4.0f);
}

float MF_PersistenceFactor(float persistence)
{
    // Convert a 0..0.999 per-frame coefficient into a frame-time-aware coefficient.
    float dt60 = clamp(mfFrameTime * 0.060f, 0.25f, 4.0f);
    return pow(saturate(persistence), dt60);
}

float MF_EdgeMask(float2 uv, float edgeStart, float aspectCorrection)
{
    float screenAspect = (float)BUFFER_WIDTH / max(1.0f, (float)BUFFER_HEIGHT);
    float aspectScale = (screenAspect / 1.7777778f) * aspectCorrection;

    float2 p = uv - 0.5f;
    p.x *= aspectScale;

    float radius = length(p);
    float maxRadius = length(float2(0.5f * aspectScale, 0.5f));
    float radiusNorm = saturate(radius / max(0.0001f, maxRadius));

    float edge = smoothstep(edgeStart, 1.0f, radiusNorm);
    return edge * edge;
}

float MF_MotionCurve(float speed, float gain, float curve)
{
    float speedSignal = 1.0f - exp(-speed * gain);
    return pow(saturate(speedSignal), max(0.01f, curve));
}

// ============================================================================
// Pass 1: capture current frame at half resolution
// ============================================================================

float4 PS_MotionFocusCapture(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float2 features = MF_GetColorFeatures(color);
    return float4(features, 0.0f, 0.0f);
}

// ============================================================================
// Pass 2: build motion map
// ============================================================================

float4 PS_MotionFocusMotion(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 currentFeatures = tex2D(Ganossa_MF_CurrentColor, texcoord).rg;
    float2 previousFeatures = tex2D(Ganossa_MF_PreviousColor, texcoord).rg;

    float2 featureDelta = abs(currentFeatures - previousFeatures);
    float weightedDelta = (featureDelta.x + featureDelta.y * 0.25f) * MF_FrameScale60();
    float motion = 1.0f - exp(-weightedDelta * MF_Eff_mfMotionSensitivity());

    motion = saturate((motion - MF_Eff_mfMotionThreshold()) /
                      max(0.0001f, 1.0f - MF_Eff_mfMotionThreshold()));

    float previousMotion = tex2D(Ganossa_MF_PreviousMotionColor, texcoord).r;
    float framePersistence = MF_PersistenceFactor(MF_Eff_mfPersistence());

    float persistentMotion = max(motion, previousMotion * framePersistence);

    if (mfFrameCount <= 1 || mfResetHistory)
        persistentMotion = 0.0f;

    // R = Motion Focus persistent map.
    // G = instantaneous motion for the independent effect drivers.
    return float4(persistentMotion, motion, 0.0f, 0.0f);
}

// ============================================================================
// Pass 3: reduce 32x18 map to 1x1 state and three independent histories
// ============================================================================

void PS_MotionFocusAnalyze(
    float4 vpos : SV_Position,
    float2 texcoord : TEXCOORD,
    out float4 stateR : SV_Target0,
    out float4 effectsSpeedR : SV_Target1,
    out float phaseR : SV_Target2,
    out float cameraBlurSpeedR : SV_Target3)
{
    float4 quadrants = 0.0f;
    float4 instantQuadrants = 0.0f;
    float totalMotion = 0.0f;
    float totalInstantMotion = 0.0f;
    float instantMotionSquare = 0.0f;
    float instantMotionPeak = 0.0f;
    float2 weightedCenter = 0.0f;

    [loop]
    for (int y = 0; y < MF_ANALYSIS_Y; ++y)
    {
        [loop]
        for (int x = 0; x < MF_ANALYSIS_X; ++x)
        {
            float2 analysisUV =
                (float2(x, y) + 0.5f) /
                float2((float)MF_ANALYSIS_X, (float)MF_ANALYSIS_Y);

            float2 motionData = tex2D(Ganossa_MF_MotionColor, analysisUV).rg;
            float motion = motionData.x;

            totalMotion += motion;
            totalInstantMotion += motionData.y;
            instantMotionSquare += motionData.y * motionData.y;
            instantMotionPeak = max(instantMotionPeak, motionData.y);
            weightedCenter += analysisUV * motion;

            if (x < MF_QUAD_X && y < MF_QUAD_Y)
            {
                quadrants.x += motion;
                instantQuadrants.x += motionData.y;
            }
            else if (x >= MF_QUAD_X && y < MF_QUAD_Y)
            {
                quadrants.y += motion;
                instantQuadrants.y += motionData.y;
            }
            else if (x < MF_QUAD_X && y >= MF_QUAD_Y)
            {
                quadrants.z += motion;
                instantQuadrants.z += motionData.y;
            }
            else
            {
                quadrants.w += motion;
                instantQuadrants.w += motionData.y;
            }
        }
    }

    quadrants /= (float)MF_QUAD_SAMPLES;
    instantQuadrants /= (float)MF_QUAD_SAMPLES;

    float activity = saturate(totalMotion / (float)MF_TOTAL_SAMPLES);

    float2 focusOffset = 0.0f;
    if (totalMotion > 0.00001f)
        focusOffset = weightedCenter / totalMotion - 0.5f;

    float usableRange = max(0.0001f, 0.5f - MF_Eff_mfDeadzone());
    float2 focusSign = sign(focusOffset);
    float2 focusMagnitude = max(abs(focusOffset) - MF_Eff_mfDeadzone(), 0.0f);
    focusOffset = focusSign * saturate(focusMagnitude / usableRange) * 0.5f;

    float strongestQuadrant = max(quadrants.x,
                                  max(quadrants.y, max(quadrants.z, quadrants.w)));

    float otherAverage =
        (quadrants.x + quadrants.y + quadrants.z + quadrants.w - strongestQuadrant) / 3.0f;

    float contrast = saturate(
        (strongestQuadrant - otherAverage) /
        max(0.0001f, strongestQuadrant));

    float4 rawState = float4(focusOffset, activity, contrast);
    float4 previousState = tex2D(Ganossa_MF_PreviousStateColor, float2(0.5f, 0.5f));

    float dt60 = clamp(mfFrameTime * 0.060f, 0.25f, 4.0f);
    float response = 1.0f - pow(1.0f - saturate(MF_Eff_mfFocusSmoothing()), dt60);

    float4 state = rawState;
    if (mfFrameCount > 1 && !mfResetHistory)
        state = lerp(previousState, rawState, response);

    stateR = state;

    // All optional post effects share the same instantaneous motion measurement,
    // but each gets an independent deadzone + temporal history. Fisheye uses a
    // second, more motion-sensitive readout so localized/high-contrast motion
    // can contribute without requiring the whole screen to change.
    float instantActivity = saturate(totalInstantMotion / (float)MF_TOTAL_SAMPLES);
    float instantRMS = sqrt(saturate(instantMotionSquare / (float)MF_TOTAL_SAMPLES));
    float strongestInstantQuadrant = max(instantQuadrants.x,
        max(instantQuadrants.y, max(instantQuadrants.z, instantQuadrants.w)));

    // RMS + peak/mean hybrid: for full-screen camera motion it remains close to
    // the global average, while a smaller but strong moving region is less diluted.
    float fisheyeMotionActivity = max(
        instantActivity,
        sqrt(max(0.0f, instantActivity * max(instantRMS, instantMotionPeak * 0.5f))));

    // Head sway should yield to localized motion too.
    float headSwayBlockActivity = max(instantActivity, strongestInstantQuadrant);

    float fisheyeInput = saturate((fisheyeMotionActivity - MF_Eff_mfFisheyeDeadzone()) /
                                  max(0.0001f, 1.0f - MF_Eff_mfFisheyeDeadzone()));
    float caInput = saturate((instantActivity - MF_Eff_mfCADeadzone()) /
                             max(0.0001f, 1.0f - MF_Eff_mfCADeadzone()));
    float blurInput = saturate((instantActivity - MF_Eff_mfBlurDeadzone()) /
                               max(0.0001f, 1.0f - MF_Eff_mfBlurDeadzone()));

    float4 previousEffects =
        tex2D(Ganossa_MF_PreviousEffectsSpeedColor, float2(0.5f, 0.5f));

    // Fisheye is intentionally NOT a max(current, previous) envelope anymore.
    // It now has separate attack and release behavior: motion must accumulate
    // over multiple frames to build the effect, while persistence controls the
    // slower falloff after motion decreases. This avoids the old 'full strength
    // after only a few frames' behavior.
    float fisheyeTarget = MF_MotionCurve(
        fisheyeInput, MF_Eff_mfFisheyeMotionGain(), MF_Eff_mfFisheyeSpeedCurve());

    float fisheyePrevious = previousEffects.r;
    float fisheyeAttack = 1.0f - pow(
        1.0f - saturate(MF_Eff_mfFisheyeAccumulation()), dt60);
    float fisheyeRelease = 1.0f - MF_PersistenceFactor(MF_Eff_mfFisheyePersistence());

    float fisheyePersist;
    if (fisheyeTarget >= fisheyePrevious)
        fisheyePersist = lerp(fisheyePrevious, fisheyeTarget, fisheyeAttack);
    else
        fisheyePersist = lerp(fisheyePrevious, fisheyeTarget, fisheyeRelease);

    float caPersist = max(
        caInput,
        previousEffects.g * MF_PersistenceFactor(MF_Eff_mfCAPersistence()));

    float blurPersist = max(
        blurInput,
        previousEffects.b * MF_PersistenceFactor(MF_Eff_mfBlurPersistence()));

    if (mfFrameCount <= 1 || mfResetHistory)
    {
        fisheyePersist = 0.0f;
        caPersist = 0.0f;
        blurPersist = 0.0f;
    }

    // A stores the dedicated instantaneous head-sway motion signal.
    // It deliberately does not use Motion Focus persistence or focus smoothing.
    effectsSpeedR = float4(fisheyePersist, caPersist, blurPersist, headSwayBlockActivity);

    // Camera-motion coherence:
    // A camera pan tends to affect all quadrants at once, whereas isolated object
    // motion usually occupies only one or two regions. Use the weakest quadrant
    // relative to the strongest as a coherence gate, while retaining average
    // scene motion so low-frequency camera movement remains detectable.
    float instantQMax = max(
        instantQuadrants.x,
        max(
            instantQuadrants.y,
            max(instantQuadrants.z, instantQuadrants.w)));

    float instantQMin = min(
        instantQuadrants.x,
        min(
            instantQuadrants.y,
            min(instantQuadrants.z, instantQuadrants.w)));

    float quadrantCoherence =
        instantQMax > 0.0001f
            ? saturate(instantQMin / instantQMax)
            : 0.0f;

    float cameraMotionInput =
        saturate(
            instantActivity *
            (0.45f + 0.55f * quadrantCoherence));

    float cameraInput =
        saturate(
            (cameraMotionInput - MF_Eff_mfCameraBlurDeadzone()) /
            max(
                0.0001f,
                1.0f - MF_Eff_mfCameraBlurDeadzone()));

    float cameraTarget =
        MF_MotionCurve(
            cameraInput,
            MF_Eff_mfCameraBlurMotionGain(),
            1.0f);

    float previousCamera =
        tex2D(
            Ganossa_MF_PreviousCameraBlurSpeedColor,
            float2(0.5f, 0.5f)).r;

    float cameraAttack =
        1.0f -
        pow(
            1.0f -
            saturate(MF_Eff_mfCameraBlurResponse()),
            dt60);

    float cameraRelease =
        1.0f -
        MF_PersistenceFactor(
            MF_Eff_mfCameraBlurPersistence());

    float cameraState;

    if (cameraTarget >= previousCamera)
    {
        cameraState =
            lerp(
                previousCamera,
                cameraTarget,
                cameraAttack);
    }
    else
    {
        cameraState =
            lerp(
                previousCamera,
                cameraTarget,
                cameraRelease);
    }

    if (mfFrameCount <= 1 || mfResetHistory)
        cameraState = 0.0f;

    cameraBlurSpeedR = cameraState;

    // ------------------------------------------------------------------------
    // Head Sway: continuously slow oscillator speed as on-screen motion grows.
    // This replaces the old hard on/off gate. The speed never reaches zero.
    // ------------------------------------------------------------------------
    const float TWO_PI = 6.28318530718f;
    float previousPhase = tex2D(Ganossa_MF_PreviousHeadSwayPhaseColor, float2(0.5f, 0.5f)).r;
    previousPhase = saturate(previousPhase);

    float motionThreshold = saturate(MF_Eff_mfHeadSwayMotionThreshold());
    float motionRange = saturate(
        (headSwayBlockActivity - motionThreshold) /
        max(0.0001f, 1.0f - motionThreshold));

    float slowdown = pow(
        motionRange,
        max(0.05f, MF_Eff_mfHeadSwayMotionResponse()));

    float minimumSpeed = clamp(MF_Eff_mfHeadSwayMinSpeed(), 0.01f, 1.0f);
    float speedFactor = lerp(1.0f, minimumSpeed, slowdown);

    if (!MF_Eff_mfHeadSwayEnable() || MF_Eff_mfHeadSwaySpeed() <= 0.0f || MF_Eff_mfHeadSwayStrength() <= 0.0f)
        speedFactor = 0.0f;

    // Keep phase in turns (0..1) rather than radians to keep the history stable.
    float deltaSeconds = max(0.00001f, mfFrameTime * 0.001f);
    float phaseAdvance = MF_Eff_mfHeadSwaySpeed() * speedFactor * deltaSeconds;
    float phase = previousPhase + phaseAdvance;
    phase = frac(phase);

    if (mfFrameCount <= 1 || mfResetHistory)
        phase = 0.0f;

    phaseR = float4(phase, 0.0f, 0.0f, 0.0f);
}

// ============================================================================
// Motion Fisheye
// ============================================================================

float2 MF_ApplyMotionFisheye(
    float2 uv,
    float motionSpeed,
    bool enabled,
    float strength,
    float motionGain,
    float speedCurve,
    float edgeStart,
    float aspectCorrection)
{
    if (!enabled || strength <= 0.0f)
        return uv;

    float speed = MF_MotionCurve(motionSpeed, motionGain, speedCurve);
    if (speed <= 0.00001f)
        return uv;

    float screenAspect = (float)BUFFER_WIDTH / max(1.0f, (float)BUFFER_HEIGHT);
    float aspectScale = (screenAspect / 1.7777778f) * aspectCorrection;

    float2 p = uv - 0.5f;
    p.x *= aspectScale;

    float radius = length(p);
    if (radius <= 0.000001f)
        return uv;

    float maxRadius = length(float2(0.5f * aspectScale, 0.5f));
    float radiusNorm = saturate(radius / max(0.0001f, maxRadius));
    float edge = smoothstep(edgeStart, 1.0f, radiusNorm);
    edge *= edge;

    float amount = saturate(strength * speed * edge);
    float radial = radiusNorm * radiusNorm;
    float warp = 1.0f - amount * (0.85f + 0.15f * radial) * radial;

    float2 warped = p * warp;
    warped.x /= max(0.0001f, aspectScale);

    return saturate(warped + 0.5f);
}

float2 MF_GetHeadSwayOffset(
    float phaseTurns,
    bool enabled,
    float strength,
    float horizontal,
    float verticalRatio,
    float speed)
{
    if (!enabled || strength <= 0.0f || horizontal <= 0.0f || speed <= 0.0f)
        return 0.0f;

    const float TWO_PI = 6.28318530718f;
    float t = phaseTurns * TWO_PI;

    float2 figureEight = float2(sin(t), sin(2.0f * t));
    figureEight.y *= verticalRatio;

    return figureEight * horizontal * strength;
}


// ============================================================================
// Pass 4: Motion Focus + optional head sway + optional fisheye -> base image
// ============================================================================

float4 PS_MotionFocusDisplay(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float4 state = tex2D(Ganossa_MF_StateColor, float2(0.5f, 0.5f));
    float2 focusOffset = state.xy;
    float activity = saturate(state.z);
    float contrast = saturate(state.w);
    float headSwayPhase = tex2D(Ganossa_MF_HeadSwayPhaseColor, float2(0.5f, 0.5f)).r;

    // Cache all effective parameters used by this full-screen pass.
    float focusStrength = MF_Eff_mfFocusStrength();
    float zoomStrength = MF_Eff_mfZoomStrength();
    float maxZoom = MF_Eff_mfMaxZoom();
    float maxShift = MF_Eff_mfMaxShift();

    bool headSwayEnabled = MF_Eff_mfHeadSwayEnable();
    float headSwayStrength = MF_Eff_mfHeadSwayStrength();
    float headSwayHorizontal = MF_Eff_mfHeadSwayHorizontal();
    float headSwayVerticalRatio = MF_Eff_mfHeadSwayVerticalRatio();
    float headSwaySpeed = MF_Eff_mfHeadSwaySpeed();
    float headSwayFramingZoom = MF_Eff_mfHeadSwayFramingZoom();

    float fisheyeStrength = MF_Eff_mfFisheyeStrength();
    bool fisheyeEnabled = MF_Eff_mfFisheyeEnable();

    float focusAmount = activity * pow(contrast, 1.5f) * focusStrength;
    float motionZoomAmount = activity * (0.35f + 0.65f * contrast) * zoomStrength;
    motionZoomAmount = min(motionZoomAmount, maxZoom);

    float2 focusShift = focusOffset * (2.0f * maxShift) * focusAmount;

    float headSwayAmount = headSwayEnabled ? headSwayStrength : 0.0f;
    float2 headSwayOffset = MF_GetHeadSwayOffset(
        headSwayPhase,
        headSwayEnabled,
        headSwayStrength,
        headSwayHorizontal,
        headSwayVerticalRatio,
        headSwaySpeed);

    float swayMaxX = headSwayHorizontal * headSwayAmount;
    float swayMaxY = headSwayHorizontal * headSwayVerticalRatio * headSwayAmount;
    float swayRequiredZoom =
        2.0f * max(swayMaxX, swayMaxY) +
        headSwayFramingZoom * headSwayAmount;

    float zoomAmount = min(max(motionZoomAmount, swayRequiredZoom), maxZoom);

    // Clamp Focus translation to the safe inner frame. The maximum head-sway
    // excursion is accounted for before the clamp, so the final sample UV
    // remains inside [0,1] throughout the complete figure-eight cycle.
    float swayRoomX = swayMaxX;
    float swayRoomY = swayMaxY;
    float safeMinX = 0.5f * zoomAmount + swayRoomX;
    float safeMaxX = 1.0f - safeMinX;
    float safeMinY = 0.5f * zoomAmount + swayRoomY;
    float safeMaxY = 1.0f - safeMinY;

    if (safeMinX > 0.5f || safeMinY > 0.5f)
    {
        headSwayOffset = 0.0f;
        headSwayAmount = 0.0f;
        swayRequiredZoom = 0.0f;
        zoomAmount = motionZoomAmount;
        safeMinX = 0.5f * zoomAmount;
        safeMaxX = 1.0f - safeMinX;
        safeMinY = 0.5f * zoomAmount;
        safeMaxY = 1.0f - safeMinY;
    }

    float2 sampleCoord =
        (texcoord - 0.5f) * (1.0f - zoomAmount) +
        0.5f + focusShift;

    sampleCoord.x = clamp(sampleCoord.x, safeMinX, safeMaxX);
    sampleCoord.y = clamp(sampleCoord.y, safeMinY, safeMaxY);
    sampleCoord += headSwayOffset;
    sampleCoord = saturate(sampleCoord);

    if (mfDebug)
    {
        float2 center = float2(0.5f, 0.5f);
        float2 target = saturate(0.5f + focusOffset);

        if ((abs(texcoord.x - center.x) < 0.0015f &&
             abs(texcoord.y - center.y) < 0.012f) ||
            (abs(texcoord.y - center.y) < 0.0015f &&
             abs(texcoord.x - center.x) < 0.012f))
            return float4(0.0f, 1.0f, 0.0f, 1.0f);

        if ((abs(texcoord.x - target.x) < 0.0020f &&
             abs(texcoord.y - target.y) < 0.015f) ||
            (abs(texcoord.y - target.y) < 0.0020f &&
             abs(texcoord.x - target.x) < 0.015f))
            return float4(1.0f, 0.0f, 0.0f, 1.0f);

        if (texcoord.y > 0.01f && texcoord.y < 0.02f &&
            texcoord.x < activity * 0.25f)
            return float4(1.0f, 1.0f, 0.0f, 1.0f);
    }

    float fisheyeSpeed = tex2D(
        Ganossa_MF_EffectsSpeedColor,
        float2(0.5f, 0.5f)).r;

    sampleCoord = MF_ApplyMotionFisheye(
        sampleCoord,
        fisheyeSpeed,
        fisheyeEnabled,
        fisheyeStrength,
        MF_Eff_mfFisheyeMotionGain(),
        MF_Eff_mfFisheyeSpeedCurve(),
        MF_Eff_mfFisheyeEdgeStart(),
        MF_Eff_mfFisheyeAspect());

    return tex2D(ReShade::BackBuffer, sampleCoord);
}

// ============================================================================
// Pass 5: independent motion chromatic aberration
// ============================================================================

float4 PS_MotionChromaticAberration(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float4 base = tex2D(Ganossa_MF_BaseColor, texcoord);

    bool enabled = MF_Eff_mfCAEnable();
    float strength = MF_Eff_mfCAStrength();
    float maxSeparation = MF_Eff_mfCAMaxSeparation();

    if (!enabled || strength <= 0.0f || maxSeparation <= 0.0f)
        return base;

    float speed = tex2D(Ganossa_MF_EffectsSpeedColor, float2(0.5f, 0.5f)).g;
    float motionGain = MF_Eff_mfCAMotionGain();
    float speedCurve = MF_Eff_mfCASpeedCurve();
    float edgeStart = MF_Eff_mfCAEdgeStart();
    float aspectCorrection = MF_Eff_mfCAAspect();

    float speedAmount = MF_MotionCurve(speed, motionGain, speedCurve);
    float edge = MF_EdgeMask(texcoord, edgeStart, aspectCorrection);
    float amount = saturate(strength * speedAmount * edge);

    if (amount <= 0.00001f)
        return base;

    float screenAspect = (float)BUFFER_WIDTH / max(1.0f, (float)BUFFER_HEIGHT);
    float aspectScale = (screenAspect / 1.7777778f) * aspectCorrection;
    float2 p = texcoord - 0.5f;
    p.x *= aspectScale;

    float radius = length(p);
    float2 direction = (radius > 0.000001f) ? p / radius : float2(0.0f, 0.0f);
    direction.x /= max(0.0001f, aspectScale);

    float separationPixels = maxSeparation * amount;
    float2 separationUV = direction * separationPixels * float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

    float red = tex2D(Ganossa_MF_BaseColor, texcoord + separationUV).r;
    float green = base.g;
    float blue = tex2D(Ganossa_MF_BaseColor, texcoord - separationUV).b;

    return float4(red, green, blue, base.a);
}

// ============================================================================
// Pass 6: independent motion edge Gaussian-like blur
// ============================================================================

float4 PS_MotionEdgeBlur(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float4 base = tex2D(Ganossa_MF_CAOutputColor, texcoord);

    bool enabled = MF_Eff_mfBlurEnable();
    float strength = MF_Eff_mfBlurStrength();
    float baseRadius = MF_Eff_mfBlurRadius();

    if (!enabled || strength <= 0.0f || baseRadius <= 0.0f)
        return base;

    float speed = tex2D(Ganossa_MF_EffectsSpeedColor, float2(0.5f, 0.5f)).b;
    float speedAmount = MF_MotionCurve(
        speed,
        MF_Eff_mfBlurMotionGain(),
        MF_Eff_mfBlurSpeedCurve());

    float edge = MF_EdgeMask(
        texcoord,
        MF_Eff_mfBlurEdgeStart(),
        MF_Eff_mfBlurAspect());

    float amount = saturate(strength * speedAmount * edge);

    if (amount <= 0.00001f)
        return base;

    float radius = baseRadius * amount;
    float2 px = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

    // 3x3 Gaussian approximation:
    // center = 4/16, axial = 2/16, diagonal = 1/16.
    float4 sum = base * 0.25f;

    float2 o1 = px * radius;
    float2 o2 = o1 * 0.70710678f;

    sum += tex2D(Ganossa_MF_CAOutputColor, texcoord + float2(o1.x, 0.0f)) * 0.125f;
    sum += tex2D(Ganossa_MF_CAOutputColor, texcoord - float2(o1.x, 0.0f)) * 0.125f;
    sum += tex2D(Ganossa_MF_CAOutputColor, texcoord + float2(0.0f, o1.y)) * 0.125f;
    sum += tex2D(Ganossa_MF_CAOutputColor, texcoord - float2(0.0f, o1.y)) * 0.125f;

    sum += tex2D(Ganossa_MF_CAOutputColor, texcoord + float2(o2.x, o2.y)) * 0.0625f;
    sum += tex2D(Ganossa_MF_CAOutputColor, texcoord + float2(-o2.x, o2.y)) * 0.0625f;
    sum += tex2D(Ganossa_MF_CAOutputColor, texcoord + float2(o2.x, -o2.y)) * 0.0625f;
    sum += tex2D(Ganossa_MF_CAOutputColor, texcoord - float2(o2.x, o2.y)) * 0.0625f;

    return lerp(base, sum, amount);
}

// ============================================================================
// Pass 7: independent full-screen camera-motion Gaussian blur
// ============================================================================

float4 PS_MotionCameraGaussianBlur(
    float4 vpos : SV_Position,
    float2 texcoord : TEXCOORD) : SV_Target
{
    float4 base = tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord);

    bool enabled = MF_Eff_mfCameraBlurEnable();
    float strength = MF_Eff_mfCameraBlurStrength();
    float baseRadius = MF_Eff_mfCameraBlurRadius();

    if (!enabled || strength <= 0.0f || baseRadius <= 0.0f)
        return base;

    float cameraSpeed = tex2D(
        Ganossa_MF_CameraBlurSpeedColor,
        float2(0.5f, 0.5f)).r;

    if (cameraSpeed <= 0.00001f)
        return base;

    float cameraAmount = saturate(strength * cameraSpeed);

    if (cameraAmount <= 0.00001f)
        return base;

    float radius = baseRadius * cameraAmount;
    float2 px = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

    // Compact 13-tap Gaussian-like kernel:
    // center 6/16
    // cardinal near 1/16 each
    // cardinal far 1/32 each
    // diagonal near 1/32 each
    float4 sum = base * 0.375f;

    float2 o1 = px * radius * 0.50f;
    float2 o2 = px * radius * 0.90f;
    float2 d = px * radius * 0.70710678f;

    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord + float2(o1.x, 0.0f)) * 0.0625f;
    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord - float2(o1.x, 0.0f)) * 0.0625f;
    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord + float2(0.0f, o1.y)) * 0.0625f;
    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord - float2(0.0f, o1.y)) * 0.0625f;

    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord + float2(o2.x, 0.0f)) * 0.03125f;
    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord - float2(o2.x, 0.0f)) * 0.03125f;
    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord + float2(0.0f, o2.y)) * 0.03125f;
    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord - float2(0.0f, o2.y)) * 0.03125f;

    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord + float2(d.x, d.y)) * 0.03125f;
    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord + float2(-d.x, d.y)) * 0.03125f;
    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord + float2(d.x, -d.y)) * 0.03125f;
    sum += tex2D(Ganossa_MF_EdgeBlurOutputColor, texcoord - float2(d.x, d.y)) * 0.03125f;

    float4 blurred = sum * (1.0f / 0.875f);

    return lerp(base, blurred, cameraAmount);
}

// ============================================================================
// Pass 7: store frame + motion histories
// ============================================================================

void PS_MotionFocusStoreHistory(
    float4 vpos : SV_Position,
    float2 texcoord : TEXCOORD,
    out float4 previousFrame : SV_Target0,
    out float4 previousMotion : SV_Target1)
{
    previousFrame = tex2D(Ganossa_MF_CurrentColor, texcoord);
    previousMotion = tex2D(Ganossa_MF_MotionColor, texcoord);
}

// ============================================================================
// Pass 8: store 1x1 state + all three independent effect histories
// ============================================================================

void PS_MotionFocusStoreState(
    float4 vpos : SV_Position,
    float2 texcoord : TEXCOORD,
    out float4 previousState : SV_Target0,
    out float4 previousEffectsSpeed : SV_Target1,
    out float4 previousHeadSwayPhase : SV_Target2,
    out float previousCameraBlurSpeed : SV_Target3)
{
    previousState = tex2D(Ganossa_MF_StateColor, float2(0.5f, 0.5f));
    previousEffectsSpeed = tex2D(Ganossa_MF_EffectsSpeedColor, float2(0.5f, 0.5f));
    previousHeadSwayPhase = tex2D(Ganossa_MF_HeadSwayPhaseColor, float2(0.5f, 0.5f));
    previousCameraBlurSpeed = tex2D(Ganossa_MF_CameraBlurSpeedColor, float2(0.5f, 0.5f)).r;
}

// ============================================================================
// Technique
// ============================================================================

technique GanossaMotionFocusModernPresetDrivenCameraGaussianBlur
<
    ui_label = "Ganossa Motion Focus (Modern + Head Sway + Fisheye + CA + Edge Blur + Camera Gaussian Blur)";
    ui_tooltip = "Resolution-independent Motion Focus with idle head sway, independent motion fisheye, chromatic aberration, edge blur and coherent camera-motion Gaussian blur.";
>
{
    pass MotionFocusCapturePass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MotionFocusCapture;
        RenderTarget = Ganossa_MF_CurrentTex;
        ClearRenderTargets = false;
    }

    pass MotionFocusMotionPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MotionFocusMotion;
        RenderTarget = Ganossa_MF_MotionTex;
        ClearRenderTargets = false;
    }

    pass MotionFocusAnalyzePass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MotionFocusAnalyze;
        RenderTarget0 = Ganossa_MF_StateTex;
        RenderTarget1 = Ganossa_MF_EffectsSpeedTex;
        RenderTarget2 = Ganossa_MF_HeadSwayPhaseTex;
        RenderTarget3 = Ganossa_MF_CameraBlurSpeedTex;
        ClearRenderTargets = true;
    }

    pass MotionFocusBasePass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MotionFocusDisplay;
        RenderTarget = Ganossa_MF_BaseTex;
        ClearRenderTargets = false;
    }

    pass MotionChromaticAberrationPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MotionChromaticAberration;
        RenderTarget = Ganossa_MF_CAOutputTex;
        ClearRenderTargets = false;
    }

    pass MotionEdgeBlurPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MotionEdgeBlur;
        RenderTarget = Ganossa_MF_EdgeBlurOutputTex;
        ClearRenderTargets = false;
    }

    pass MotionCameraGaussianBlurPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MotionCameraGaussianBlur;
    }

    pass MotionFocusStoreHistoryPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MotionFocusStoreHistory;
        RenderTarget0 = Ganossa_MF_PreviousTex;
        RenderTarget1 = Ganossa_MF_PreviousMotionTex;
        ClearRenderTargets = false;
    }

    pass MotionFocusStoreStatePass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MotionFocusStoreState;
        RenderTarget0 = Ganossa_MF_PreviousStateTex;
        RenderTarget1 = Ganossa_MF_PreviousEffectsSpeedTex;
        RenderTarget2 = Ganossa_MF_PreviousHeadSwayPhaseTex;
        RenderTarget3 = Ganossa_MF_PreviousCameraBlurSpeedTex;
        ClearRenderTargets = false;
    }
}
