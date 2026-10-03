param([Parameter(Mandatory = $true)][string]$Action)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, UIAutomationClientsideProviders, System.Windows.Forms, System.Drawing
if (-not ('PcKitNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PcKitNative {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
}
[PcKitNative]::SetProcessDPIAware() | Out-Null
# Without this, classic Win32 controls (Edit, menus, status bars) show up as bare Panes; RootElement must be touched first.
[System.Windows.Automation.AutomationElement]::RootElement | Out-Null
try { [System.Windows.Automation.ClientSettings]::RegisterClientSideProviderAssembly([UIAutomationClientsideProviders.UIAutomationClientSideProviders].Assembly.GetName()) } catch {}

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$AnyCond = [System.Windows.Automation.Condition]::TrueCondition

$a = if ($env:PCKIT_ARGS) { $env:PCKIT_ARGS | ConvertFrom-Json } else { [pscustomobject]@{} }

function Send-Result($obj) { $obj | ConvertTo-Json -Depth 6 -Compress; exit 0 }
function Fail([string]$msg) { @{ error = $msg } | ConvertTo-Json -Compress; exit 1 }

function Get-TypeName($el) { $el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '' }

function Get-TopWindows {
    @($AE::RootElement.FindAll($Scope::Children, $AnyCond)) | Where-Object { $_.Current.Name }
}

function Describe-Window($w) {
    $c = $w.Current
    $proc = try { (Get-Process -Id $c.ProcessId -ErrorAction Stop).ProcessName } catch { '' }
    $r = $c.BoundingRectangle
    [ordered]@{
        handle  = $c.NativeWindowHandle
        title   = $c.Name
        process = $proc
        pid     = $c.ProcessId
        rect    = if ($r.IsEmpty) { $null } else { @([int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height) }
    }
}

function Find-Window([string]$sel) {
    if (-not $sel) { Fail 'Informe a janela (parte do título ou handle de ui_windows).' }
    if ($sel -match '^\d+$') {
        try { return $AE::FromHandle([IntPtr][long]$sel) } catch { Fail "Nenhuma janela com handle $sel." }
    }
    $all = Get-TopWindows
    $exact = $all | Where-Object { $_.Current.Name -eq $sel } | Select-Object -First 1
    if ($exact) { return $exact }
    $hit = $all | Where-Object { $_.Current.Name.IndexOf($sel, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
    if ($hit) { return $hit }
    $titles = ($all | ForEach-Object { $_.Current.Name }) -join ' | '
    Fail "Nenhuma janela contém '$sel'. Abertas: $titles"
}

function Activate-Window($w) {
    $h = [IntPtr]$w.Current.NativeWindowHandle
    if ($h -eq [IntPtr]::Zero) { return }
    if ([PcKitNative]::IsIconic($h)) { [PcKitNative]::ShowWindow($h, 9) | Out-Null }
    # Tapping Alt lets this background process take the foreground.
    [PcKitNative]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [PcKitNative]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [PcKitNative]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 200
}

function Find-Element($win) {
    $conds = @()
    if ($a.automationId) {
        $conds += New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, [string]$a.automationId)
    }
    if ($a.controlType) {
        $ct = [System.Windows.Automation.ControlType]::($a.controlType)
        if (-not $ct) { Fail "controlType inválido: $($a.controlType). Use nomes como Button, Edit, MenuItem, CheckBox, ListItem, TabItem, Hyperlink." }
        $conds += New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $ct)
    }
    $cond = switch ($conds.Count) {
        0 { $AnyCond }
        1 { $conds[0] }
        default { New-Object System.Windows.Automation.AndCondition(, [System.Windows.Automation.Condition[]]$conds) }
    }
    $found = @($win.FindAll($Scope::Descendants, $cond))
    if ($a.name) {
        $n = [string]$a.name
        $exact = @($found | Where-Object { $_.Current.Name -eq $n })
        $found = if ($exact.Count) { $exact } else { @($found | Where-Object { $_.Current.Name.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
    }
    if (-not $a.name -and -not $a.automationId -and -not $a.controlType) { Fail 'Informe name, automationId ou controlType do elemento.' }
    if (-not $found.Count) { Fail 'Elemento não encontrado. Rode ui_tree nessa janela para ver os nomes disponíveis.' }
    $i = if ($null -ne $a.index) { [int]$a.index } else { 0 }
    if ($i -ge $found.Count) { Fail "Só existem $($found.Count) elementos com esse filtro (index começa em 0)." }
    $found[$i]
}

function Describe-Element($el) {
    $c = $el.Current
    $s = (Get-TypeName $el)
    if ($c.Name) { $s += " `"$($c.Name)`"" }
    if ($c.AutomationId) { $s += " id=$($c.AutomationId)" }
    if (-not $c.IsEnabled) { $s += ' (desativado)' }
    if ($c.IsOffscreen) { $s += ' (fora da tela)' }
    $p = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) {
        $v = $p.Current.Value
        if ($v) { if ($v.Length -gt 80) { $v = $v.Substring(0, 80) + '…' }; $s += " valor=`"$v`"" }
    }
    $s
}

function Mouse-Click([int]$x, [int]$y, [string]$button, [bool]$double) {
    [PcKitNative]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 50
    $down, $up = if ($button -eq 'right') { 0x08, 0x10 } else { 0x02, 0x04 }
    $times = if ($double) { 2 } else { 1 }
    for ($k = 0; $k -lt $times; $k++) {
        [PcKitNative]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
        [PcKitNative]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 60
    }
}

function Escape-SendKeys([string]$text) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $text.Replace("`r`n", "`n").ToCharArray()) {
        if ($ch -eq "`n") { [void]$sb.Append('{ENTER}') }
        elseif ('+^%~(){}[]'.Contains([string]$ch)) { [void]$sb.Append('{').Append($ch).Append('}') }
        else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}

try {
    switch ($Action) {
        'windows' {
            Send-Result @{ windows = @(Get-TopWindows | ForEach-Object { Describe-Window $_ }) }
        }
        'tree' {
            $win = Find-Window $a.window
            $maxDepth = if ($a.depth) { [int]$a.depth } else { 6 }
            $maxNodes = if ($a.maxNodes) { [int]$a.maxNodes } else { 400 }
            $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
            $lines = New-Object System.Collections.Generic.List[string]
            $stack = New-Object System.Collections.Stack
            $stack.Push(@($win, 0))
            while ($stack.Count -and $lines.Count -lt $maxNodes) {
                $el, $d = $stack.Pop()
                $lines.Add(('  ' * $d) + (Describe-Element $el))
                if ($d -ge $maxDepth) { continue }
                $kids = New-Object System.Collections.Generic.List[object]
                $child = $walker.GetFirstChild($el)
                while ($child) { $kids.Add($child); $child = $walker.GetNextSibling($child) }
                for ($k = $kids.Count - 1; $k -ge 0; $k--) { $stack.Push(@($kids[$k], ($d + 1))) }
            }
            $truncated = $stack.Count -gt 0
            Send-Result @{ window = (Describe-Window $win); tree = ($lines -join "`n"); truncated = $truncated }
        }
        'focus' {
            $win = Find-Window $a.window
            Activate-Window $win
            Send-Result @{ ok = $true; window = (Describe-Window $win) }
        }
        'click' {
            if ($null -ne $a.x -and $null -ne $a.y) {
                if ($a.window) { Activate-Window (Find-Window $a.window) }
                Mouse-Click ([int]$a.x) ([int]$a.y) ([string]$a.button) ([bool]$a.double)
                Send-Result @{ ok = $true; method = 'mouse'; at = @([int]$a.x, [int]$a.y) }
            }
            $win = Find-Window $a.window
            $el = Find-Element $win
            $desc = Describe-Element $el
            $plain = -not $a.mouse -and -not $a.double -and $a.button -ne 'right'
            if ($plain) {
                $p = $null
                if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); Send-Result @{ ok = $true; method = 'invoke'; element = $desc } }
                if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle(); Send-Result @{ ok = $true; method = 'toggle'; element = $desc } }
                if ($el.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); Send-Result @{ ok = $true; method = 'select'; element = $desc } }
                if ($el.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) {
                    if ($p.Current.ExpandCollapseState -eq 'Collapsed') { $p.Expand() } else { $p.Collapse() }
                    Send-Result @{ ok = $true; method = 'expand'; element = $desc }
                }
            }
            Activate-Window $win
            $pt = $null
            if (-not $el.TryGetClickablePoint([ref]$pt)) {
                $r = $el.Current.BoundingRectangle
                if ($r.IsEmpty) { Fail "O elemento não tem posição na tela: $desc" }
                $pt = New-Object System.Windows.Point(($r.X + $r.Width / 2), ($r.Y + $r.Height / 2))
            }
            Mouse-Click ([int]$pt.X) ([int]$pt.Y) ([string]$a.button) ([bool]$a.double)
            Send-Result @{ ok = $true; method = 'mouse'; element = $desc; at = @([int]$pt.X, [int]$pt.Y) }
        }
        'set_value' {
            $win = Find-Window $a.window
            $el = Find-Element $win
            $p = $null
            if (-not $el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) {
                if (-not $el.Current.IsKeyboardFocusable) { Fail "Esse elemento não aceita texto: $(Describe-Element $el)" }
                Activate-Window $win
                $el.SetFocus()
                Start-Sleep -Milliseconds 100
                [System.Windows.Forms.SendKeys]::SendWait('^a' + (Escape-SendKeys ([string]$a.value)))
                Send-Result @{ ok = $true; method = 'keyboard'; element = (Describe-Element $el) }
            }
            if ($p.Current.IsReadOnly) { Fail "Campo somente leitura: $(Describe-Element $el)" }
            $p.SetValue([string]$a.value)
            Send-Result @{ ok = $true; method = 'value'; element = (Describe-Element $el) }
        }
        'type' {
            if ($a.window) {
                $win = Find-Window $a.window
                Activate-Window $win
                if ($a.name -or $a.automationId -or $a.controlType) { (Find-Element $win).SetFocus(); Start-Sleep -Milliseconds 100 }
            }
            $seq = ''
            if ($a.text) { $seq += Escape-SendKeys ([string]$a.text) }
            if ($a.keys) { $seq += [string]$a.keys }
            if (-not $seq) { Fail 'Informe text e/ou keys.' }
            [System.Windows.Forms.SendKeys]::SendWait($seq)
            Send-Result @{ ok = $true; sent = $seq.Length }
        }
        'screenshot' {
            if ($a.window) {
                $win = Find-Window $a.window
                Activate-Window $win
                Start-Sleep -Milliseconds 150
                $r = $win.Current.BoundingRectangle
                if ($r.IsEmpty) { Fail 'A janela não está visível na tela.' }
                $bounds = New-Object System.Drawing.Rectangle([int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
            } else {
                $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
            }
            $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
            $g.Dispose()
            $maxW = if ($a.maxWidth) { [int]$a.maxWidth } else { 1600 }
            $scale = [Math]::Min(1.0, $maxW / $bounds.Width)
            if ($scale -lt 1.0) {
                $small = New-Object System.Drawing.Bitmap([int]($bounds.Width * $scale), [int]($bounds.Height * $scale))
                $g = [System.Drawing.Graphics]::FromImage($small)
                $g.InterpolationMode = 'HighQualityBicubic'
                $g.DrawImage($bmp, 0, 0, $small.Width, $small.Height)
                $g.Dispose(); $bmp.Dispose(); $bmp = $small
            }
            $dir = Join-Path $env:TEMP 'pi-pc-kit'
            New-Item -ItemType Directory -Force $dir | Out-Null
            $file = Join-Path $dir ("tela-{0:yyyyMMdd-HHmmss-fff}.jpg" -f (Get-Date))
            $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
            $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
            $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]80)
            $bmp.Save($file, $codec, $ep)
            $w, $h = $bmp.Width, $bmp.Height
            $bmp.Dispose()
            Send-Result @{ path = $file; left = $bounds.X; top = $bounds.Y; width = $w; height = $h; scale = $scale }
        }
        default { Fail "Ação desconhecida: $Action" }
    }
} catch {
    Fail $_.Exception.Message
}
