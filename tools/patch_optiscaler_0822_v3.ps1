param(
    [Parameter(Mandatory=$true)]
    [string]$OptiRoot
)

$ErrorActionPreference = 'Stop'

function Normalize-LF([string]$s) {
    if ($null -eq $s) { return $s }
    return $s.Replace("`r`n", "`n")
}

# Start with the proven v2 swapchain/rectangle/runtime patch.
$v2Patch = Join-Path $PSScriptRoot 'patch_optiscaler_0822.ps1'
if (-not (Test-Path $v2Patch)) { throw "v2 base patch not found: $v2Patch" }
& $v2Patch -OptiRoot $OptiRoot

# -----------------------------------------------------------------------------
# v3 root-cause fix #1:
# In exact 0822 NVNGX_DX12, UpscaleEnd runs BEFORE feature->Evaluate(). That means
# any HUDless capture performed there sees the previous/uninitialized upscaler
# output instead of the current frame. Move UpscaleEnd after Evaluate so a direct
# HUDless copy is recorded after the current upscaler dispatch on the SAME cmdlist.
# -----------------------------------------------------------------------------
$ngxPath = Join-Path $OptiRoot 'OptiScaler\inputs\NVNGX_DLSS_Dx12.cpp'
if (-not (Test-Path $ngxPath)) { throw "Source file not found: $ngxPath" }
$ngxText = Normalize-LF ([IO.File]::ReadAllText($ngxPath))

$evalOld = Normalize-LF @'
    // Evaluate the feature
    bool evalSuccess = false;
    {
        // Resource tracking
        UpscalerInputsDx12::UpscaleEnd(InCmdList, InParameters, feature);

        ScopedSkipHeapCapture skip {};
        evalSuccess = feature->Evaluate(InCmdList, InParameters);
    }

    // Cleanup on success
'@

$evalNew = Normalize-LF @'
    // Evaluate the feature
    bool evalSuccess = false;
    {
        ScopedSkipHeapCapture skip {};
        evalSuccess = feature->Evaluate(InCmdList, InParameters);
    }

    // GenshinFGCompat v3:
    // 0822 called UpscaleEnd before Evaluate. For Genshin's DX12 OptiScaler path
    // this made HUDless point at stale/unfinished output and produced alternating
    // stretched/black generated frames. Calling it here records the HUDless copy
    // after the current-frame upscaler dispatch on the same command list.
    UpscalerInputsDx12::UpscaleEnd(InCmdList, InParameters, feature);

    // Cleanup on success
'@

if (-not $ngxText.Contains($evalOld)) { throw 'Expected 0822 NVNGX DX12 Evaluate/UpscaleEnd order was not found' }
$ngxText = $ngxText.Replace($evalOld, $evalNew)
[IO.File]::WriteAllText($ngxPath, $ngxText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

# -----------------------------------------------------------------------------
# v3 root-cause fix #2:
# The active path in the user's log is Upscaler_Inputs_Dx12, not Dx11wDx12.
# HUDFix heuristic is therefore intentionally OFF. Feed the just-written NGX
# output directly to FSR-FG as HudlessColor. ValidNow makes FSRFG_Dx12 create an
# ordered copy on InCmdList, so the copy occurs after feature->Evaluate().
# -----------------------------------------------------------------------------
$inputPath = Join-Path $OptiRoot 'OptiScaler\inputs\FG\Upscaler_Inputs_Dx12.cpp'
if (-not (Test-Path $inputPath)) { throw "Source file not found: $inputPath" }
$inputText = Normalize-LF ([IO.File]::ReadAllText($inputPath))

$diagNeedle = Normalize-LF @'
    fg->SetReset(reset);
    fg->SetInterpolationRect(feature->DisplayWidth(), feature->DisplayHeight());

    Hudfix_Dx12::UpscaleStart();
'@
$diagInsert = Normalize-LF @'
    fg->SetReset(reset);
    fg->SetInterpolationRect(feature->DisplayWidth(), feature->DisplayHeight());

    static bool genshinV3InputsLogged = false;
    if (!genshinV3InputsLogged)
    {
        LOG_INFO("GenshinFGCompat v3 D3D12 inputs: render={}x{}, display={}x{}, mvScale=({},{}), jitter=({},{}), lowResMV={}, invertedDepth={}, jitteredMV={}, ResourceFlip={}",
                 feature->RenderWidth(), feature->RenderHeight(), feature->DisplayWidth(), feature->DisplayHeight(),
                 mvScaleX, mvScaleY, jitterX, jitterY, feature->LowResMV(), feature->DepthInverted(),
                 feature->JitteredMV(), Config::Instance()->FGResourceFlip.value_or_default());
        genshinV3InputsLogged = true;
    }

    Hudfix_Dx12::UpscaleStart();
'@
if (-not $inputText.Contains($diagNeedle)) { throw 'Expected UpscalerInputsDx12 input diagnostic insertion point was not found' }
$inputText = $inputText.Replace($diagNeedle, $diagInsert)

$endOld = Normalize-LF @'
void UpscalerInputsDx12::UpscaleEnd(ID3D12GraphicsCommandList* InCmdList, NVSDK_NGX_Parameter* InParameters,
                                    IFeature_Dx12* feature)
{
    Hudfix_Dx12::SetSkipStatus(false);

    auto fg = State::Instance().currentFG;

    if (fg == nullptr || State::Instance().activeFgInput != FGInput::Upscaler || _device == nullptr)
        return;

    // FG Dispatch
    if (fg->IsActive() && Config::Instance()->FGEnabled.value_or_default() &&
        State::Instance().currentSwapchain != nullptr)
    {
        if (Config::Instance()->FGHUDFix.value_or_default())
        {
            // For signal after mv & depth copies
            Hudfix_Dx12::UpscaleEnd(feature->FrameCount(), State::Instance().lastFGFrameTime);

            ID3D12Resource* output = nullptr;
            if (InParameters->Get(NVSDK_NGX_Parameter_Output, &output) != NVSDK_NGX_Result_Success)
                InParameters->Get(NVSDK_NGX_Parameter_Output, (void**) &output);

            ResourceInfo info {};
            auto desc = output->GetDesc();
            info.buffer = output;
            info.width = desc.Width;
            info.height = desc.Height;
            info.format = desc.Format;
            info.flags = desc.Flags;
            info.type = UAV;
            info.captureInfo = CaptureInfo::Upscaler;

            Hudfix_Dx12::CheckForHudless(InCmdList, &info,
                                         (D3D12_RESOURCE_STATES) Config::Instance()->OutputResourceBarrier.value_or(
                                             D3D12_RESOURCE_STATE_UNORDERED_ACCESS),
                                         true);
        }
        else
        {
            LOG_DEBUG("(FG) running, frame: {0}", feature->FrameCount());
        }
    }
}
'@

$endNew = Normalize-LF @'
void UpscalerInputsDx12::UpscaleEnd(ID3D12GraphicsCommandList* InCmdList, NVSDK_NGX_Parameter* InParameters,
                                    IFeature_Dx12* feature)
{
    Hudfix_Dx12::SetSkipStatus(false);

    auto fg = State::Instance().currentFG;

    if (fg == nullptr || State::Instance().activeFgInput != FGInput::Upscaler || _device == nullptr)
        return;

    if (fg->IsActive() && Config::Instance()->FGEnabled.value_or_default() &&
        State::Instance().currentSwapchain != nullptr)
    {
        ID3D12Resource* output = nullptr;
        if (InParameters->Get(NVSDK_NGX_Parameter_Output, &output) != NVSDK_NGX_Result_Success)
            InParameters->Get(NVSDK_NGX_Parameter_Output, (void**) &output);

        if (output != nullptr && InCmdList != nullptr)
        {
            const auto desc = output->GetDesc();

            Dx12Resource hudless {};
            hudless.type = FG_ResourceType::HudlessColor;
            hudless.cmdList = InCmdList;
            hudless.resource = output;
            hudless.left = 0;
            hudless.top = 0;
            hudless.width = desc.Width;
            hudless.height = desc.Height;
            hudless.state = (D3D12_RESOURCE_STATES) Config::Instance()->OutputResourceBarrier.value_or(
                D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            hudless.validity = FG_ResourceValidity::ValidNow;

            const bool accepted = fg->SetResource(&hudless);
            static bool directHudlessLogged = false;
            if (!directHudlessLogged)
            {
                LOG_INFO("GenshinFGCompat v3 current-frame HUDless: accepted={}, {}x{}, format={}, frame={}",
                         accepted, desc.Width, desc.Height, (UINT) desc.Format, feature->FrameCount());
                directHudlessLogged = true;
            }
        }
        else
        {
            static bool missingHudlessLogged = false;
            if (!missingHudlessLogged)
            {
                LOG_WARN("GenshinFGCompat v3 current-frame HUDless unavailable: output={}, cmdList={}",
                         (size_t) output, (size_t) InCmdList);
                missingHudlessLogged = true;
            }
        }

        LOG_DEBUG("(FG) running, frame: {0}", feature->FrameCount());
    }
}
'@

if (-not $inputText.Contains($endOld)) { throw 'Expected exact 0822 UpscalerInputsDx12::UpscaleEnd block was not found' }
$inputText = $inputText.Replace($endOld, $endNew)
[IO.File]::WriteAllText($inputPath, $inputText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

# -----------------------------------------------------------------------------
# v3 preset correction:
# The bridge already performs Genshin-specific motion/jitter conversion. The log
# also reports Game Engine=Other, so forcing OptiScaler's Unity texture flip is an
# unjustified second transform. Keep it OFF. Heuristic HUDFix stays OFF because
# v3 supplies deterministic current-frame HudlessColor directly.
# -----------------------------------------------------------------------------
$iniPath = Join-Path $OptiRoot 'OptiScaler.ini'
if (-not (Test-Path $iniPath)) { throw "INI not found: $iniPath" }
$iniText = Normalize-LF ([IO.File]::ReadAllText($iniPath))

$flipMatches = [regex]::Matches($iniText, '(?m)^ResourceFlip\s*=.*$')
if ($flipMatches.Count -ne 1) { throw "Expected one ResourceFlip key, found $($flipMatches.Count)" }
$iniText = [regex]::Replace($iniText, '(?m)^ResourceFlip\s*=.*$', 'ResourceFlip=false')

$hudMatches = [regex]::Matches($iniText, '(?m)^HUDFix\s*=.*$')
if ($hudMatches.Count -ne 1) { throw "Expected one HUDFix key, found $($hudMatches.Count)" }
$iniText = [regex]::Replace($iniText, '(?m)^HUDFix\s*=.*$', 'HUDFix=false')

$depthMatches = [regex]::Matches($iniText, '(?m)^EnableDepthScale\s*=.*$')
if ($depthMatches.Count -ne 1) { throw "Expected one EnableDepthScale key, found $($depthMatches.Count)" }
$iniText = [regex]::Replace($iniText, '(?m)^EnableDepthScale\s*=.*$', 'EnableDepthScale=false')

[IO.File]::WriteAllText($iniPath, $iniText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))

Write-Host 'Genshin FSR FG v3 current-frame HUDless patch applied successfully.'
