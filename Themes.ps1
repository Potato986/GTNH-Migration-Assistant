function Get-GtnhAssetBytes([string]$name) {
    if ($script:GtnhBundledAssets -and $script:GtnhBundledAssets.ContainsKey($name)) {
        return ,([Convert]::FromBase64String($script:GtnhBundledAssets[$name]))
    }
    return ,([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot ('assets/' + $name))))
}

function New-GtnhScene([string]$name) {
    $stream = [IO.MemoryStream]::new((Get-GtnhAssetBytes $name))
    try {
        $image = [Drawing.Image]::FromStream($stream)
        try { return [Drawing.Bitmap]::new($image) } finally { $image.Dispose() }
    } finally { $stream.Dispose() }
}

function Set-GtnhSceneImage($control,$image,[int]$overlay) {
    $w = $control.ClientSize.Width
    $h = $control.ClientSize.Height
    if ($w -lt 1 -or $h -lt 1) { return }
    $canvas = [Drawing.Bitmap]::new($w,$h)
    $g = [Drawing.Graphics]::FromImage($canvas)
    try {
        $scale = [Math]::Max($w/$image.Width,$h/$image.Height)
        $iw = [int][Math]::Ceiling($image.Width*$scale)
        $ih = [int][Math]::Ceiling($image.Height*$scale)
        $g.DrawImage($image,[Drawing.Rectangle]::new([int](($w-$iw)/2),[int](($h-$ih)/2),$iw,$ih))
        $color = if ($control -is [Windows.Forms.Form]) { [Drawing.Color]::FromArgb(135,22,32,35) }
            else { [Drawing.Color]::FromArgb($overlay,255,255,255) }
        $brush = [Drawing.SolidBrush]::new($color)
        try { $g.FillRectangle($brush,0,0,$w,$h) } finally { $brush.Dispose() }
    } finally { $g.Dispose() }
    $old = $control.BackgroundImage
    $control.BackgroundImage = $canvas
    if ($control -is [Windows.Forms.ListView]) {
        $control.BackgroundImageTiled = $true
        if ($control.IsHandleCreated) {
            [void][GtnhDialogFrame]::SendMessage($control.Handle,0x1026,[IntPtr]::Zero,[IntPtr]::new(-1))
            $control.Invalidate()
        }
    }
    if ($old) { $old.Dispose() }
}

function Add-GtnhDialogHeader($window,$title,$subtitle) {
    $header = [Windows.Forms.Panel]::new()
    $header.Dock = 'Top'
    $header.Height = 84
    $header.BackColor = [Drawing.Color]::FromArgb(34,43,44)
    $heading = [Windows.Forms.Label]::new()
    $heading.Text = $title
    $heading.Location = [Drawing.Point]::new(16,10)
    $heading.AutoSize = $true
    $heading.Font = [Drawing.Font]::new('Microsoft YaHei UI',16,[Drawing.FontStyle]::Bold)
    $heading.ForeColor = [Drawing.Color]::White
    $hint = [Windows.Forms.Label]::new()
    $hint.Location = [Drawing.Point]::new(18,46)
    $hint.Text = $subtitle
    $hint.Height = 32
    $hint.Width = $window.ClientSize.Width-60
    $hint.Anchor = 'Top,Left,Right'
    $hint.ForeColor = [Drawing.Color]::FromArgb(218,233,228)
    $header.Controls.Add($heading)
    $header.Controls.Add($hint)
    $window.Controls.Add($header)
    return $header
}

function Set-GtnhControlTheme($control) {
    if ($control -is [Windows.Forms.Button]) {
        $control.FlatStyle = 'Flat'
        $control.FlatAppearance.BorderSize = 0
        $control.BackColor = [Drawing.Color]::FromArgb(28,98,84)
        $control.ForeColor = [Drawing.Color]::White
        $control.MinimumSize = [Drawing.Size]::new(100,32)
        $control.Margin = [Windows.Forms.Padding]::new(5)
    } elseif ($control -is [Windows.Forms.LinkLabel]) {
        $control.LinkColor = [Drawing.Color]::FromArgb(143,230,203)
        $control.ActiveLinkColor = [Drawing.Color]::White
        $control.VisitedLinkColor = $control.LinkColor
        $control.BackColor = [Drawing.Color]::FromArgb(34,43,44)
    } elseif ($control -is [Windows.Forms.FlowLayoutPanel]) {
        $control.BackColor = [Drawing.Color]::FromArgb(34,43,44)
        $control.Height = 48
    } elseif ($control -is [Windows.Forms.ListView]) {
        $control.BorderStyle = 'None'
        $control.FullRowSelect = $true
        $control.HideSelection = $false
        $control.OwnerDraw = $true
        $control.Add_DrawColumnHeader({param($sender,$eventArgs) $eventArgs.DrawDefault=$true})
        $control.Add_DrawItem({param($sender,$eventArgs) if($sender.View -ne 'Details'){$eventArgs.DrawDefault=$true}})
        $control.Add_DrawSubItem({
            param($sender,$eventArgs)
            $bounds=$eventArgs.Bounds
            if($sender.BackgroundImage){
                $eventArgs.Graphics.DrawImage($sender.BackgroundImage,$bounds,$bounds,[Drawing.GraphicsUnit]::Pixel)
            }else{$eventArgs.DrawBackground()}
            $selected=$eventArgs.Item.Selected
            if($selected){
                $brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(220,28,98,84))
                try{$eventArgs.Graphics.FillRectangle($brush,$bounds)}finally{$brush.Dispose()}
            }
            $textColor=if($selected){[Drawing.Color]::White}else{[Drawing.Color]::FromArgb(15,30,32)}
            $bounds.Inflate(-4,0)
            $flags=[Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                [Windows.Forms.TextFormatFlags]::EndEllipsis -bor [Windows.Forms.TextFormatFlags]::NoPrefix
            [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,$eventArgs.SubItem.Text,$sender.Font,$bounds,$textColor,$flags)
            if($selected -and $sender.Focused){[Windows.Forms.ControlPaint]::DrawFocusRectangle($eventArgs.Graphics,$eventArgs.Bounds)}
        })
    } elseif ($control -is [Windows.Forms.Label] -or $control -is [Windows.Forms.CheckBox]) {
        $control.ForeColor = [Drawing.Color]::White
        $control.BackColor = [Drawing.Color]::Transparent
    }
    foreach ($child in $control.Controls) { Set-GtnhControlTheme $child }
}

function Set-GtnhWindowTheme($window,[string]$scene) {
    if (!('GtnhDialogFrame' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GtnhDialogFrame {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
}
'@
    }
    $window.Font = [Drawing.Font]::new('Microsoft YaHei UI',10)
    $window.BackColor = [Drawing.Color]::FromArgb(34,43,44)
    $window.Padding = [Windows.Forms.Padding]::new(10)
    $window.AutoScaleMode = 'Dpi'
    Set-GtnhControlTheme $window
    $data = @{ Image=New-GtnhScene $scene; Window=$window; Views=@($window.Controls | Where-Object { $_ -is [Windows.Forms.ListView] }) }
    $refresh = {
        Set-GtnhSceneImage $data.Window $data.Image 30
        foreach ($view in $data.Views) { Set-GtnhSceneImage $view $data.Image 175 }
    }.GetNewClosure()
    $window.Add_ResizeEnd($refresh)
    $window.Add_Shown($refresh)
    $iconStream = [IO.MemoryStream]::new((Get-GtnhAssetBytes 'gtnh-app.ico'))
    try {
        $icon = [Drawing.Icon]::new($iconStream)
        try { $window.Icon = [Drawing.Icon]$icon.Clone() } finally { $icon.Dispose() }
    } finally { $iconStream.Dispose() }
    $window.Add_Shown({
        param($sender,$eventArgs)
        $dark=1; $round=2
        [void][GtnhDialogFrame]::DwmSetWindowAttribute($sender.Handle,20,[ref]$dark,4)
        [void][GtnhDialogFrame]::DwmSetWindowAttribute($sender.Handle,33,[ref]$round,4)
    })
    $cleanup = {
        $data.Image.Dispose()
        foreach ($control in @($data.Window)+$data.Views) {
            if ($control.BackgroundImage) { $control.BackgroundImage.Dispose() }
        }
    }.GetNewClosure()
    $window.Add_FormClosed($cleanup)
}
