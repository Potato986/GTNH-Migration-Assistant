param([Parameter(Mandatory)][string]$ExePath,[switch]$Capture)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Resolve-Path $ExePath).Path))
$reader=[IO.StreamReader]::new($assembly.GetManifestResourceStream('MigrationScript'))
try {$code=$reader.ReadToEnd()} finally {$reader.Dispose()}
$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$null,[ref]$null)
$assetCode=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:GtnhBundledAssets'},$true)
. ([scriptblock]::Create($assetCode.Extent.Text))
foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
    . ([scriptblock]::Create($node.Extent.Text))
}

# A denied API must fall back to the release page and merge new tags with cached assets.
$originalReceiver=(Get-Command Receive-TranslationFile).ScriptBlock
$calls=[Collections.Generic.List[string]]::new()
function Receive-TranslationFile($url,$path,$owner,$title,$seconds) {
    $calls.Add($url)
    if ($url -like 'https://api.github.com/*') {throw 'GitHub 请求受限（403/429）。'}
    [IO.File]::WriteAllText($path,'<include-fragment src="https://github.com/Kiwi233/Translation-of-GTNH/releases/expanded_assets/v9.9.9"></include-fragment>')
}
$catalog=Read-TranslationCatalog
function Save-TranslationCatalog($catalog) {} # Keep deterministic fixture data out of the user cache.
$updated=Update-TranslationCatalog $catalog $null 1
if($calls.Count -ne 2 -or $updated.source -ne 'GitHub 发行页' -or !@($updated.releases|Where-Object tag_name -eq 'v9.9.9').Count) {throw '403 fallback lost the version list.'}
if(@(Get-TranslationAssets $updated.releases).Count -lt @(Get-TranslationAssets $catalog.releases).Count) {throw 'Fallback lost cached packages.'}
$release=[pscustomobject]@{tag_name='v9.9.9';html_url='https://github.com/Kiwi233/Translation-of-GTNH/releases/tag/v9.9.9'}
$parsed=@(Get-TranslationPageAssets '<a href="/Kiwi233/Translation-of-GTNH/releases/download/v9.9.9/v9.9.9.7z">Download</a><a href="https://example.org/releases/download/wrong/x.zip">ignore</a>' $release)
if($parsed.Count -ne 1 -or $parsed[0].size -ne 0) {throw 'Release HTML asset parsing failed.'}
Set-Item Function:\Receive-TranslationFile $originalReceiver

$captureDir=Join-Path (Split-Path (Resolve-Path $ExePath).Path -Parent) 'ui-check'
if($Capture){[void][IO.Directory]::CreateDirectory($captureDir)}
function Save-TestWindow($window,$name){
    if(!$Capture){return}
    $bitmap=[Drawing.Bitmap]::new($window.Width,$window.Height)
    try {
        $window.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$window.Width,$window.Height))
        $bitmap.Save((Join-Path $captureDir $name))
    }
    finally {$bitmap.Dispose()}
}
$root=Join-Path $env:TEMP ('gtnh-ui03-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$known=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$known.Add($root)
$script:uiFlowState=@{Stage=0;Failure='';Details=$false}
$driver=[Windows.Forms.Timer]::new()
$driver.Interval=250
$driver.Add_Tick({
    try {
        $windows=@([Windows.Forms.Application]::OpenForms)
        foreach($window in $windows){
            if(!$window.Visible -or !$window.BackgroundImage){continue}
            if($window.Text -eq '实例选择测试' -and $script:uiFlowState.Stage -eq 0){
                Save-TestWindow $window 'instances.png'
                $view=@($window.Controls|Where-Object {$_ -is [Windows.Forms.ListView]})[0]
                if($view.Items.Count -ne 1 -or !$window.BackgroundImage){throw 'Themed instance picker missing rows or background.'}
                $view.Items[0].Selected=$true
                $bar=@($window.Controls|Where-Object {$_ -is [Windows.Forms.FlowLayoutPanel]})[0]
                $script:uiFlowState.Stage=1
                $bar.Controls[0].PerformClick()
            } elseif($window.Text -eq '汉化版本列表' -and $script:uiFlowState.Stage -eq 1){
                Save-TestWindow $window 'translations.png'
                $view=$window.Controls['TranslationVersions']
                if($view.Items.Count -lt 50 -or !$view.BackgroundImage){throw 'Offline translation catalog not visible on first open.'}
                $window.Controls['TranslationSearch'].Text='v2.9.0.7z'
                if($view.Items.Count -ne 1){throw 'Translation version search failed.'}
                $view.Items[0].Selected=$true
                $bar=@($window.Controls|Where-Object {$_ -is [Windows.Forms.FlowLayoutPanel]})[0]
                $script:uiFlowState.Stage=2
                $bar.Controls[1].PerformClick()
            } elseif($window.Text -eq '汉化下载和安装' -and $script:uiFlowState.Stage -eq 2){
                Save-TestWindow $window 'details.png'
                if(!$window.BackgroundImage){throw 'Translation details background missing.'}
                $script:uiFlowState.Details=$true
                $script:uiFlowState.Stage=3
                $bar=@($window.Controls|Where-Object {$_ -is [Windows.Forms.FlowLayoutPanel]})[0]
                $bar.Controls[1].PerformClick()
            }
        }
    } catch {
        $script:uiFlowState.Failure=$_.Exception.Message
        foreach($window in @([Windows.Forms.Application]::OpenForms)){$window.Close()}
    }
})
try {
    $driver.Start()
    $chosen=Select-GtnhDirectory '实例选择测试' $known $null
    if($script:uiFlowState.Failure){throw $script:uiFlowState.Failure}
    if($chosen -ne $root){throw 'Instance selection did not return the selected path.'}
    $selected=Select-TranslationAsset $null $root
    if($script:uiFlowState.Failure){throw $script:uiFlowState.Failure}
    if(!$script:uiFlowState.Details -or $selected.Name -ne 'v2.9.0.7z'){throw 'List-to-details-to-queue flow failed.'}
    $driver.Stop()
    $package=[IO.Directory]::CreateDirectory((Join-Path $root 'package/config/test')).FullName
    [IO.File]::WriteAllText((Join-Path $package 'zh_CN.lang'),'ui-installed')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=Join-Path $root 'fixture.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $root 'package'),$zip)
    function Receive-TranslationFile($url,$path,$owner,$title,$seconds) {[IO.File]::Copy($zip,$path,$false)}
    $detailCode=(Get-Command Show-TranslationDetails).ScriptBlock.ToString()
    $rx=[regex]::new('(?s)\[Windows.Forms.MessageBox\]::Show\(\$details,.*?''确认安装汉化'',''OKCancel''\)')
    if($rx.Matches($detailCode).Count -ne 1){throw 'Cannot locate install confirmation.'}
    Set-Item Function:\Show-TranslationDetails ([scriptblock]::Create($rx.Replace($detailCode,"'OK'")))
    $fixture=[pscustomobject]@{Label='UI test';Tag='test';Name='fixture.zip';Url='https://example.invalid/test';Page='https://github.com/Kiwi233/Translation-of-GTNH/releases';Size=(Get-Item $zip).Length;Digest=''}
    $installState=@{Clicked=$false}
    $installer=[Windows.Forms.Timer]::new()
    $installer.Interval=200
    $installer.Add_Tick({
        foreach($window in @([Windows.Forms.Application]::OpenForms)){
            if($window.Text -eq '汉化下载和安装' -and $window.Visible){
                $installer.Stop()
                $bar=@($window.Controls|Where-Object {$_ -is [Windows.Forms.FlowLayoutPanel]})[0]
                $bar.Controls[0].PerformClick()
                $installState.Clicked=$true
                $window.Close()
            }
        }
    })
    try {$installer.Start();[void](Show-TranslationDetails $fixture $root $null)} finally {$installer.Dispose()}
    if(!$installState.Clicked -or [IO.File]::ReadAllText((Join-Path $root 'config/test/zh_CN.lang')) -cne 'ui-installed'){throw 'Direct install button failed.'}
    'TRANSLATION UI PASS: 403 release-page fallback, retained catalog, themed instance picker, offline list, filtering, details, queue selection'
} finally {
    $driver.Stop();$driver.Dispose()
    if([IO.Directory]::Exists($root) -and $root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){[IO.Directory]::Delete($root,$true)}
}
