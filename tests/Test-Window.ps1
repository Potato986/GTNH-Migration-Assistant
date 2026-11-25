param([Parameter(Mandatory)][string]$ExePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root = Join-Path ([IO.Path]::GetTempPath()) ('gtnh-window-test-' + [guid]::NewGuid())
$testSource = [IO.Directory]::CreateDirectory((Join-Path $root 'old')).FullName
$testTarget = [IO.Directory]::CreateDirectory((Join-Path $root 'new')).FullName
foreach ($dir in $testSource,$testTarget) { [void][IO.Directory]::CreateDirectory((Join-Path $dir 'mods')) }
[IO.File]::WriteAllText((Join-Path $testSource 'options.txt'),"gamma:1`r`nresourcePacks:[]`r`n")
$initial = "gamma:0`r`nresourcePacks:[]`r`n"
[IO.File]::WriteAllText((Join-Path $testTarget 'options.txt'),$initial)
$asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Resolve-Path $ExePath).Path))
$reader = [IO.StreamReader]::new($asm.GetManifestResourceStream('MigrationScript'))
try { $code = $reader.ReadToEnd() } finally { $reader.Dispose() }
$code = $code.Replace('$src = Select-GtnhDirectory ''选择旧 GTNH 实例（来源）'' $knownInstances $null', '$src = $testSource')
$code = $code.Replace('$dst = Select-GtnhDirectory ''选择新 GTNH 实例（目标）'' $knownInstances $src', '$dst = $testTarget')
$code = $code.Replace('$PSScriptRoot', '$testScriptRoot')
$testScriptRoot = Split-Path (Resolve-Path $ExePath).Path -Parent
# Exercise the normal preview button event and cancel before file writes.
$pattern = "(?s)\[Windows.Forms.MessageBox\]::Show\(\s*\(\`$preview -join .*?'确认迁移清单', 'OKCancel'\s*\)"
$rx = [regex]::new($pattern)
if ($rx.Matches($code).Count -ne 1) { throw 'Cannot locate preview confirmation.' }
$code = $rx.Replace($code, '$( $script:previewCaptured = @($preview); ''Cancel'' )')
$testBody = @'
$testTimer = [Windows.Forms.Timer]::new()
$testTimer.Interval = 300
$testTimer.Add_Tick({
    $testTimer.Stop()
    try {
        if ($translationCheck.Enabled -or $translationCheck.Checked) { throw 'Translation is unexpectedly selected before a version is chosen.' }
        $translationState.Asset = [pscustomobject]@{ Label='2.9.0 — v2.9.0.7z' }
        $translationCheck.Enabled = $true
        $translationCheck.Checked = $true
        if (!$button.Enabled -or $countLabel.Text -ne '已选 1 项') { throw 'Translation selection does not enable preview.' }
        $button.PerformClick()
        if ($script:previewCaptured.Count -ne 1 -or $script:previewCaptured[0] -notmatch 'v2.9.0.7z') { throw 'Translation missing from preview.' }
        $translationCheck.Checked = $false
        $settingRow = @($list.Items | Where-Object { $_.Tag.Kind -eq 'setting' })[0]
        $settingRow.Checked = $true
        $button.PerformClick()
        if ($script:previewCaptured.Count -ne 1 -or $script:previewCaptured[0] -notmatch 'gamma') { throw 'Game setting missing from preview.' }
        $settingRow.Checked = $false
        if ($button.Enabled -or $countLabel.Text -ne '已选 0 项') { throw 'Deselecting does not clear preview state.' }
        if ([IO.File]::ReadAllText((Join-Path $testTarget 'options.txt')) -cne $initial) { throw 'Canceled preview changed the target.' }
    } catch { $script:windowFailure = $_.Exception.Message }
    finally { $form.Close() }
})
$form.Add_Shown({ $testTimer.Start() })
[void]$form.ShowDialog()
$testTimer.Dispose()
'@
$code = $code.Replace('[void]$form.ShowDialog()',$testBody)
try {
    . ([scriptblock]::Create($code))
    if ($script:windowFailure) { throw $script:windowFailure }
    'WINDOW PASS: translation selection, settings selection, preview cancellation, count and target preservation'
} finally {
    if (![IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid test root.' }
    [IO.Directory]::Delete($root,$true)
}
