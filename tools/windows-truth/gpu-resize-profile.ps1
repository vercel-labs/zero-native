# Per-resize-step cost of the Direct2D canvas path.
#
# Launches an app under NATIVE_SDK_GPU_PROFILE (see gpu_surface_renderer.cpp),
# drives a synthetic resize sweep, and reduces the log into the four numbers
# the flip-model migration turns on: target rebuild, image re-upload,
# display-list render, and window blit.
#
# The default vehicle is tools/gpu-image-fixture, which holds the runtime's
# entire registered-image ceiling (16 x 512x512 = 16 MiB). Point -AppDir at
# an example to measure that app instead; a zero-texture app is the control.
#
# Unlike perf-input.ps1 this needs no scheduled-task hop for the sweep:
# SetWindowPos is not desktop input. -Drag additionally performs a real
# border drag through SendInput, which DOES require the console desktop.
param(
    [string]$AppDir = "tools/gpu-image-fixture",
    [string]$ProcessName = "gpu-image-fixture",
    [string]$Label = "",
    [string]$OutputDir = "$env:TEMP\native-truth-out\gpu-resize",
    [int]$Steps = 160,
    [int]$MinWidth = 900,
    [int]$MaxWidth = 1800,
    [int]$MinHeight = 700,
    [int]$MaxHeight = 1150,
    [int]$StepIntervalMs = 8,
    [int]$OriginX = 40,
    [int]$OriginY = 40,
    # Fixture knobs (ignored by any other -AppDir): texture count and edge.
    [int]$Images = 0,
    [int]$Extent = 0,
    # Arguments for the app under test. A real app that stops on a startup
    # dialog measures the dialog, not the app — alchemist-native wants
    # -AppArgs '--restore-session' so the same project comes back on every
    # launch of a before/after pair with nothing to click.
    [string[]]$AppArgs = @(),
    # After the sweep, hold the window still and jiggle the pointer inside
    # it for this long. Resize steps are all full-surface repaints, so they
    # say nothing about partial-update cost; this phase is what exercises
    # the damage-accumulated copy and dirty-rect Present1. Needs the
    # console desktop, like -Drag.
    [int]$HoldMs = 0,
    # How long to let the app settle before the sweep. The default covers
    # boot plus a first present. A real app that restores a project on
    # launch needs much longer -- sweep too early and you measure an empty
    # window, with no registered textures and nothing to flush, which is
    # indistinguishable in the log from an app that has none.
    [int]$SettleMs = 1500,
    # Pin every paint to the full-surface copy + plain Present, so the
    # partial path can be A/B'd against itself on one build.
    [switch]$FullPresent,
    [switch]$Drag,
    # Run -Drag alone. The sweep/drag boundary is a single global sequence
    # number, and sequence numbers are PER SURFACE — fine for a one-surface
    # fixture, meaningless for an app with twenty. Skipping the sweep makes
    # the whole logged population the modal drag, so no boundary is needed.
    [switch]$SkipSweep,
    [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"
if (-not $Label) { $Label = $ProcessName }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeSdkResizeProfile {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint Type; public INPUTUNION Data; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT Mouse; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int Dx; public int Dy; public uint MouseData; public uint Flags; public uint Time; public UIntPtr ExtraInfo;
    }

    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] static extern int GetDeviceCaps(IntPtr dc, int index);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint period);

    public static int DisplayRefreshHz(IntPtr hwnd) {
        IntPtr dc = GetDC(hwnd);
        if (dc == IntPtr.Zero) return 0;
        try { return GetDeviceCaps(dc, 116); } finally { ReleaseDC(hwnd, dc); }
    }

    // SetForegroundWindow is refused for a process that does not own the
    // foreground. Borrowing the foreground thread's input queue is the
    // standard way to make an automated activation actually take.
    public static void ForceForeground(IntPtr hwnd) {
        uint fore = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        uint self = GetCurrentThreadId();
        AttachThreadInput(fore, self, true);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        AttachThreadInput(fore, self, false);
    }

    public static bool MouseTo(int x, int y) { return SetCursorPos(x, y); }

    // Win11's sizing border mostly lives OUTSIDE the rect GetWindowRect
    // reports (DWM draws a visible frame inset from the real one), so a
    // fixed offset either misses the border or lands in the client area.
    // Ask the window itself where its right edge is.
    public static int FindRightBorderX(IntPtr hwnd, int y) {
        RECT rect;
        if (!GetWindowRect(hwnd, out rect)) return 0;
        for (int x = rect.Right - 4; x <= rect.Right + 10; x++) {
            IntPtr hit = SendMessageW(hwnd, 0x0084, IntPtr.Zero, (IntPtr)((y << 16) | (x & 0xFFFF))); // WM_NCHITTEST
            int code = hit.ToInt32();
            if (code == 11 || code == 17 || code == 14) return x; // HTRIGHT / HTBOTTOMRIGHT / HTTOPRIGHT
        }
        return 0;
    }

    public static bool MouseButton(bool down) {
        INPUT input = new INPUT();
        input.Type = 0;
        input.Data.Mouse.Flags = down ? 0x0002u : 0x0004u; // LEFTDOWN / LEFTUP
        return SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT))) == 1;
    }
}
'@

function Wait-Window([string]$name, [int]$timeoutMs = 20000) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $timeoutMs) {
        $process = Get-Process -Name $name -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if ($process) { return $process }
        [Threading.Thread]::Sleep(100)
    }
    throw "no visible window for $name within ${timeoutMs}ms"
}

function Stop-App([string]$name) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.MainWindowHandle -ne [IntPtr]::Zero) {
            # WM_CLOSE, not Kill: the profile log is buffered and only the
            # clean shutdown path flushes and closes it.
            [NativeSdkResizeProfile]::PostMessageW($_.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt 8000) {
        if (-not (Get-Process -Name $name -ErrorAction SilentlyContinue)) { return $true }
        [Threading.Thread]::Sleep(100)
    }
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
    return $false
}

function Percentile([double[]]$values, [double]$fraction) {
    if ($values.Count -eq 0) { return 0 }
    $sorted = $values | Sort-Object
    $index = [int][Math]::Floor($fraction * ($sorted.Count - 1))
    return [double]$sorted[$index]
}

function Summarize([object[]]$rows, [string]$field) {
    $values = @($rows | ForEach-Object { [double]$_.$field })
    if ($values.Count -eq 0) { return [pscustomobject]@{ P50 = 0; P90 = 0; Max = 0; Mean = 0 } }
    $sum = 0.0
    foreach ($value in $values) { $sum += $value }
    return [pscustomobject]@{
        P50  = [Math]::Round((Percentile $values 0.50) / 1000.0, 3)
        P90  = [Math]::Round((Percentile $values 0.90) / 1000.0, 3)
        Max  = [Math]::Round((Percentile $values 1.00) / 1000.0, 3)
        Mean = [Math]::Round(($sum / $values.Count) / 1000.0, 3)
    }
}

function Read-ProfileLines([string]$path) {
    # Shared read: the app still holds the log open for writing whenever
    # this is called before shutdown.
    $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object IO.StreamReader($stream)
        try { return $reader.ReadToEnd() -split "`r?`n" } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Parse-Profile([string]$path) {
    $present = @()
    $paint = @()
    foreach ($line in (Read-ProfileLines $path)) {
        if ($line.StartsWith("#")) { continue }
        $fields = @{}
        foreach ($token in ($line -split ' ')) {
            $pair = $token -split '=', 2
            if ($pair.Count -eq 2) { $fields[$pair[0]] = $pair[1] }
        }
        if ($line.StartsWith("present ")) {
            $present += [pscustomobject]@{
                Surface = if ($fields.ContainsKey("surface")) { [int]$fields["surface"] } else { 0 }
                Seq = [uint64]$fields["seq"]; Outcome = [int]$fields["outcome"]
                Pw = [int]$fields["pw"]; Ph = [int]$fields["ph"]
                Rebuild = [int]$fields["rebuild"]; Flushed = [int]$fields["flushed"]
                TargetsUs = [double]$fields["targets_us"]; ImagesUs = [double]$fields["images_us"]
                ImagesN = [int]$fields["images_n"]; ImageKib = [double]$fields["image_kib"]
                RenderUs = [double]$fields["render_us"]; DecodeUs = [double]$fields["decode_us"]
                TotalUs = [double]$fields["total_us"]
                Megapixels = [Math]::Round(([double]$fields["pw"] * [double]$fields["ph"]) / 1000000.0, 2)
            }
        } elseif ($line.StartsWith("paint ")) {
            $paint += [pscustomobject]@{
                Surface = if ($fields.ContainsKey("surface")) { [int]$fields["surface"] } else { 0 }
                Seq = [uint64]$fields["seq"]; Ok = [int]$fields["ok"]
                Pw = [int]$fields["pw"]; Ph = [int]$fields["ph"]
                Rects = [int]$fields["rects"]; BlitUs = [double]$fields["blit_us"]
                # Present's share of blit_us (flip model only; 0 before it).
                PresentUs = if ($fields.ContainsKey("present_us")) { [double]$fields["present_us"] } else { 0 }
                # 1 = whole surface copied and plain Present; 0 = damage
                # rects copied and Present1. Absent before the flip model.
                Full = if ($fields.ContainsKey("full")) { [int]$fields["full"] } else { 1 }
                Dirty = if ($fields.ContainsKey("dirty")) { [int]$fields["dirty"] } else { 0 }
                DamagePx = if ($fields.ContainsKey("dmg_px")) { [double]$fields["dmg_px"] } else { 0 }
                SurfacePx = if ($fields.ContainsKey("sw")) { [double]$fields["sw"] * [double]$fields["sh"] } else { 0 }
                # Absent in logs captured before the field existed; treat
                # those as real blits rather than silently dropping them.
                Content = if ($fields.ContainsKey("content")) { [int]$fields["content"] } else { 1 }
            }
        }
    }
    return [pscustomobject]@{ Present = $present; Paint = $paint }
}

# --------------------------------------------------------------------- run

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$logPath = Join-Path $OutputDir "$Label.log"
$jsonPath = Join-Path $OutputDir "$Label.json"
$exePath = Join-Path (Join-Path $AppDir "zig-out\bin") "$ProcessName.exe"
if (-not (Test-Path $exePath)) { throw "build $AppDir first: no $exePath" }
Remove-Item $logPath -ErrorAction SilentlyContinue

Stop-App $ProcessName | Out-Null
$env:NATIVE_SDK_GPU_PROFILE = $logPath
if ($Images -gt 0) { $env:NATIVE_SDK_FIXTURE_IMAGES = "$Images" }
if ($Extent -gt 0) { $env:NATIVE_SDK_FIXTURE_EXTENT = "$Extent" }
if ($FullPresent) { $env:NATIVE_SDK_GPU_FULL_PRESENT = "1" }
$startArgs = @{ FilePath = (Resolve-Path $exePath); WorkingDirectory = (Resolve-Path $AppDir); PassThru = $true }
if ($AppArgs.Count -gt 0) { $startArgs.ArgumentList = $AppArgs }
$launched = Start-Process @startArgs
Remove-Item Env:\NATIVE_SDK_GPU_PROFILE
Remove-Item Env:\NATIVE_SDK_FIXTURE_IMAGES -ErrorAction SilentlyContinue
Remove-Item Env:\NATIVE_SDK_FIXTURE_EXTENT -ErrorAction SilentlyContinue
Remove-Item Env:\NATIVE_SDK_GPU_FULL_PRESENT -ErrorAction SilentlyContinue

$result = [ordered]@{
    Label = $Label; App = $AppDir; Error = $null
    DisplayRefreshHz = 0; Steps = $Steps; StepIntervalMs = $StepIntervalMs
    Sweep = $null; Hold = $null; Drag = $null; Log = $logPath
}

try {
    $process = Wait-Window $ProcessName
    $hwnd = $process.MainWindowHandle
    [NativeSdkResizeProfile]::ForceForeground($hwnd)
    $result.DisplayRefreshHz = [NativeSdkResizeProfile]::DisplayRefreshHz($hwnd)
    [NativeSdkResizeProfile]::timeBeginPeriod(1) | Out-Null
    # Let boot-time registration, the first present, and the first paint
    # settle so device creation never lands in the measured population.
    [Threading.Thread]::Sleep($SettleMs)

    # SWPs: NOZORDER | NOACTIVATE | NOCOPYBITS. NOCOPYBITS keeps Windows
    # from blitting stale client pixels forward, so every step invalidates
    # the whole client area the way a real drag's growth edge does.
    $swpFlags = 0x0004 -bor 0x0010 -bor 0x0100

    for ($step = 0; ($step -lt $Steps) -and (-not $SkipSweep); $step++) {
        # Triangle sweep: grow to the ceiling, shrink back. Both directions
        # matter — growth reallocates upward, shrink still rebuilds.
        $phase = [double]$step / [double]$Steps
        $t = if ($phase -le 0.5) { $phase * 2.0 } else { (1.0 - $phase) * 2.0 }
        $width = [int]($MinWidth + ($MaxWidth - $MinWidth) * $t)
        $height = [int]($MinHeight + ($MaxHeight - $MinHeight) * $t)
        [NativeSdkResizeProfile]::SetWindowPos($hwnd, [IntPtr]::Zero, $OriginX, $OriginY, $width, $height, $swpFlags) | Out-Null
        [Threading.Thread]::Sleep($StepIntervalMs)
    }
    [Threading.Thread]::Sleep(400)

    if ($HoldMs -gt 0) {
        $seen = @(Parse-Profile $logPath).Present
        $holdFrom = if ($seen.Count -gt 0) { ($seen | Select-Object -Last 1).Seq + 1 } else { 1 }
        $result.Hold = [pscustomobject]@{ Ran = $false; FirstSeq = $holdFrom; Ms = $HoldMs }
        $rect = New-Object NativeSdkResizeProfile+RECT
        [NativeSdkResizeProfile]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
        $cx = [int](($rect.Left + $rect.Right) / 2)
        $cy = [int](($rect.Top + $rect.Bottom) / 2)
        $radius = [Math]::Min(120, [int](($rect.Right - $rect.Left) / 4))
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $step = 0
        while ($watch.ElapsedMilliseconds -lt $HoldMs) {
            # A small circular sweep: hover state changes repaint a widget
            # at a time, which is the localized-damage case.
            $angle = $step * 0.35
            [NativeSdkResizeProfile]::MouseTo(
                $cx + [int]($radius * [Math]::Cos($angle)),
                $cy + [int]($radius * [Math]::Sin($angle))) | Out-Null
            [Threading.Thread]::Sleep(16)
            $step++
        }
        [Threading.Thread]::Sleep(300)
        $result.Hold.Ran = $true
    }

    if ($Drag) {
        # A real modal resize drag: grab the right border and walk it. This
        # runs the WM_ENTERSIZEMOVE loop, which SetWindowPos never enters.
        $rect = New-Object NativeSdkResizeProfile+RECT
        [NativeSdkResizeProfile]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
        $edgeY = [int](($rect.Top + $rect.Bottom) / 2)
        $edgeX = [NativeSdkResizeProfile]::FindRightBorderX($hwnd, $edgeY)
        if ($edgeX -eq 0) { throw "no HTRIGHT sizing border found near x=$($rect.Right)" }
        # Everything logged from here on belongs to the modal drag, not the
        # SetWindowPos sweep, so the two populations stay separable.
        $seen = @(Parse-Profile $logPath).Present
        $boundary = if ($seen.Count -gt 0) { ($seen | Select-Object -Last 1).Seq + 1 } else { 1 }
        $result.Drag = [pscustomobject]@{ Ran = $false; BorderX = $edgeX; RectRight = $rect.Right; FirstSeq = $boundary }
        [NativeSdkResizeProfile]::MouseTo($edgeX, $edgeY) | Out-Null
        [Threading.Thread]::Sleep(120)
        [NativeSdkResizeProfile]::MouseButton($true) | Out-Null
        for ($step = 0; $step -lt $Steps; $step++) {
            $phase = [double]$step / [double]$Steps
            $t = if ($phase -le 0.5) { $phase * 2.0 } else { (1.0 - $phase) * 2.0 }
            $x = $edgeX + [int](($MaxWidth - $MinWidth) * $t)
            [NativeSdkResizeProfile]::MouseTo($x, $edgeY) | Out-Null
            [Threading.Thread]::Sleep($StepIntervalMs)
        }
        [NativeSdkResizeProfile]::MouseButton($false) | Out-Null
        [Threading.Thread]::Sleep(400)
        $result.Drag.Ran = $true
    }

    [NativeSdkResizeProfile]::timeEndPeriod(1) | Out-Null
    $result.Sweep = [pscustomobject]@{ Ran = $true }
} catch {
    $result.Error = $_.Exception.Message
}

if (-not $KeepRunning) { Stop-App $ProcessName | Out-Null }
[Threading.Thread]::Sleep(300)

# ----------------------------------------------------------------- reduce

if (Test-Path $logPath) {
    $parsed = Parse-Profile $logPath
    # Drop seq 1: the installing frame carries Direct2D factory, hardware
    # render target, and backing target creation, none of which a resize
    # step pays. Keeping it would put a ~100 ms outlier in every maximum.
    $accepted = @($parsed.Present | Where-Object { $_.Outcome -eq 1 -and $_.Seq -gt 1 })
    $dragFrom = if ($result.Drag -and $result.Drag.Ran) { [uint64]$result.Drag.FirstSeq } else { [uint64]::MaxValue }
    $dragRows = @($accepted | Where-Object { $_.Seq -ge $dragFrom -and $_.Rebuild -eq 1 })
    $accepted = @($accepted | Where-Object { $_.Seq -lt $dragFrom })
    $rebuilds = @($accepted | Where-Object { $_.Rebuild -eq 1 })
    $steady = @($accepted | Where-Object { $_.Rebuild -eq 0 })
    # A paint with no retained content, or with an empty update region, does
    # no drawing at all and returns in nanoseconds. Counting those as blits
    # drags the median toward zero and understates the copy this migration
    # is trying to remove.
    $realPaint = { $_.Ok -eq 1 -and $_.Content -eq 1 -and $_.Rects -gt 0 }
    $paints = @($parsed.Paint | Where-Object { (& $realPaint) -and $_.Seq -lt $dragFrom })
    $dragPaints = @($parsed.Paint | Where-Object { (& $realPaint) -and $_.Seq -ge $dragFrom })
    $skippedPaints = @($parsed.Paint | Where-Object { -not (& $realPaint) }).Count

    $result.Totals = [pscustomobject]@{
        PresentLines = $parsed.Present.Count
        Accepted = $accepted.Count
        Refused = @($parsed.Present | Where-Object { $_.Outcome -ne 1 }).Count
        RebuildSteps = $rebuilds.Count
        SteadySteps = $steady.Count
        PaintLines = $paints.Count
        PaintNoOps = $skippedPaints
        PaintsPerPresent = if ($accepted.Count -gt 0) { [Math]::Round($paints.Count / $accepted.Count, 2) } else { 0 }
        TexturesFlushedTotal = ($rebuilds | Measure-Object -Property Flushed -Sum).Sum
        TexturesUploadedTotal = ($accepted | Measure-Object -Property ImagesN -Sum).Sum
    }

    # Keyed by SURFACE and seq: `seq` counts presents per surface, so a
    # multi-surface app (the video editor has a dozen gpu_surfaces) collides
    # sequence numbers across them and seq alone cross-attributes paints.
    $rebuildSeqs = @{}
    foreach ($row in $rebuilds) { $rebuildSeqs["$($row.Surface):$($row.Seq)"] = $true }
    $rebuildPaints = @($paints | Where-Object { $rebuildSeqs.ContainsKey("$($_.Surface):$($_.Seq)") })
    $rebuildBlitPerStep = if ($rebuilds.Count -gt 0) {
        [Math]::Round((($rebuildPaints | Measure-Object -Property BlitUs -Sum).Sum) / $rebuilds.Count / 1000.0, 3)
    } else { 0 }
    $rebuildPresentPerStep = if ($rebuilds.Count -gt 0) {
        [Math]::Round((($rebuildPaints | Measure-Object -Property PresentUs -Sum).Sum) / $rebuilds.Count / 1000.0, 3)
    } else { 0 }

    # The Phase 0 deliverable: cost of ONE resize step, split by stage.
    $result.ResizeStepMs = [pscustomobject]@{
        Samples     = $rebuilds.Count
        TargetSetup = Summarize $rebuilds "TargetsUs"
        ImageUpload = Summarize $rebuilds "ImagesUs"
        Render      = Summarize $rebuilds "RenderUs"
        Decode      = Summarize $rebuilds "DecodeUs"
        PresentTotal= Summarize $rebuilds "TotalUs"
        Blit        = Summarize $paints "BlitUs"
        # The number that actually holds still. WM_PAINT coalescing trades
        # paint COUNT against paint SIZE run to run -- the same workload
        # shows 0.8 or 2.4 paints per present depending on how Windows
        # merged the update regions -- but total blit microseconds per
        # resize step stays put. Quote this, never `Blit.P50 x ratio`.
        #
        # Attributed by seq to the RESIZE presents only: an app that also
        # animates (gpu-dashboard) has steady-state presents in the
        # accepted set, and dividing by those would understate the cost a
        # resize step actually pays.
        BlitPerStep = $rebuildBlitPerStep
        # How much of BlitPerStep is Present itself rather than the copy.
        SwapPresentPerStep = $rebuildPresentPerStep
        TexturesPerStep = if ($rebuilds.Count -gt 0) { [Math]::Round((($rebuilds | Measure-Object -Property ImagesN -Sum).Sum) / $rebuilds.Count, 2) } else { 0 }
        KibPerStep      = if ($rebuilds.Count -gt 0) { [Math]::Round((($rebuilds | Measure-Object -Property ImageKib -Sum).Sum) / $rebuilds.Count, 1) } else { 0 }
    }
    # The partial-update population: paints while the window sat still.
    # This is where the damage-accumulated copy and dirty-rect Present1
    # show up at all -- a resize step is always a full-surface repaint.
    if ($result.Hold -and $result.Hold.Ran) {
        $holdFrom = [uint64]$result.Hold.FirstSeq
        $holdPaints = @($parsed.Paint | Where-Object { $_.Ok -eq 1 -and $_.Content -eq 1 -and $_.Rects -gt 0 -and $_.Seq -ge $holdFrom })
        $holdFull = @($holdPaints | Where-Object { $_.Full -eq 1 })
        $holdPartial = @($holdPaints | Where-Object { $_.Full -eq 0 })
        $result.PartialUpdateMs = [pscustomobject]@{
            Paints = $holdPaints.Count
            FullCopies = $holdFull.Count
            PartialCopies = $holdPartial.Count
            # Copy = blit minus Present, i.e. the surface work this phase
            # is trying to remove, as opposed to the flip itself.
            FullCopyMs = if ($holdFull.Count -gt 0) { [Math]::Round((($holdFull | ForEach-Object { $_.BlitUs - $_.PresentUs } | Measure-Object -Average).Average) / 1000.0, 3) } else { 0 }
            PartialCopyMs = if ($holdPartial.Count -gt 0) { [Math]::Round((($holdPartial | ForEach-Object { $_.BlitUs - $_.PresentUs } | Measure-Object -Average).Average) / 1000.0, 3) } else { 0 }
            FullPresentMs = if ($holdFull.Count -gt 0) { [Math]::Round((($holdFull | Measure-Object -Property PresentUs -Average).Average) / 1000.0, 3) } else { 0 }
            PartialPresentMs = if ($holdPartial.Count -gt 0) { [Math]::Round((($holdPartial | Measure-Object -Property PresentUs -Average).Average) / 1000.0, 3) } else { 0 }
            # The number that predicts whether this app can benefit at
            # all. Copied pixels as a percentage of the surface: at 100%
            # the app invalidates everything every frame and dirty rects
            # have nothing to save, however correct the mechanism is.
            DamageCoveragePct = if ($holdPartial.Count -gt 0) {
                $cov = @($holdPartial | Where-Object { $_.SurfacePx -gt 0 } | ForEach-Object { 100.0 * $_.DamagePx / $_.SurfacePx })
                if ($cov.Count -gt 0) { [Math]::Round(($cov | Measure-Object -Average).Average, 1) } else { 0 }
            } else { 0 }
        }
    }

    # The same split for the real WM_ENTERSIZEMOVE drag, which is the check
    # that the SetWindowPos sweep is an honest proxy for it.
    if ($dragRows.Count -gt 0) {
        $result.DragStepMs = [pscustomobject]@{
            Samples     = $dragRows.Count
            TargetSetup = Summarize $dragRows "TargetsUs"
            ImageUpload = Summarize $dragRows "ImagesUs"
            Render      = Summarize $dragRows "RenderUs"
            PresentTotal= Summarize $dragRows "TotalUs"
            Blit        = Summarize $dragPaints "BlitUs"
        }
    }
    if ($steady.Count -gt 0) {
        $result.SteadyStepMs = [pscustomobject]@{
            Samples = $steady.Count
            ImageUpload = Summarize $steady "ImagesUs"
            Render = Summarize $steady "RenderUs"
            PresentTotal = Summarize $steady "TotalUs"
        }
    }

    # Size-bucketed, so the report can be read against the migration plan's
    # existing megapixel table instead of one blended number.
    $buckets = @()
    foreach ($edge in @(1.0, 2.0, 3.0, 99.0)) {
        $low = if ($edge -eq 1.0) { 0.0 } elseif ($edge -eq 2.0) { 1.0 } elseif ($edge -eq 3.0) { 2.0 } else { 3.0 }
        $inBucket = @($rebuilds | Where-Object { $_.Megapixels -gt $low -and $_.Megapixels -le $edge })
        if ($inBucket.Count -eq 0) { continue }
        $paintSeqs = @{}
        foreach ($row in $inBucket) { $paintSeqs["$($row.Surface):$($row.Seq)"] = $true }
        $bucketPaints = @($paints | Where-Object { $paintSeqs.ContainsKey("$($_.Surface):$($_.Seq)") })
        $buckets += [pscustomobject]@{
            MegapixelRange = "$low-$edge"
            Samples = $inBucket.Count
            MedianPixels = "$([int](Percentile @($inBucket | ForEach-Object { [double]$_.Pw }) 0.5))x$([int](Percentile @($inBucket | ForEach-Object { [double]$_.Ph }) 0.5))"
            TargetSetupMs = (Summarize $inBucket "TargetsUs").P50
            ImageUploadMs = (Summarize $inBucket "ImagesUs").P50
            RenderMs = (Summarize $inBucket "RenderUs").P50
            BlitMs = if ($bucketPaints.Count -gt 0) { (Summarize $bucketPaints "BlitUs").P50 } else { 0 }
            PresentTotalMs = (Summarize $inBucket "TotalUs").P50
        }
    }
    $result.ByMegapixel = $buckets
}

$json = [pscustomobject]$result | ConvertTo-Json -Depth 8
Set-Content -Path $jsonPath -Value $json -Encoding UTF8
Write-Output $json
Write-Output ""
Write-Output "log:  $logPath"
Write-Output "json: $jsonPath"
