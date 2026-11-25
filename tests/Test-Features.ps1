param([Parameter(Mandatory)][string]$ExePath, [string]$TranslationSample, [switch]$UiTest)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Resolve-Path $ExePath).Path))
$reader = [IO.StreamReader]::new($assembly.GetManifestResourceStream('MigrationScript'))
try { $code = $reader.ReadToEnd() } finally { $reader.Dispose() }
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($code,[ref]$null,[ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
$assetAssignment = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:GtnhBundledAssets'},$true)
if ($assetAssignment) { . ([scriptblock]::Create($assetAssignment.Extent.Text)) }
foreach ($function in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] },$true)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('gtnh-v02-test-' + [guid]::NewGuid())
$src = [IO.Directory]::CreateDirectory((Join-Path $root 'old')).FullName
$dst = [IO.Directory]::CreateDirectory((Join-Path $root 'new')).FullName
$bytes = [Text.Encoding]::GetEncoding(28591)
try {
    # A target that has never generated options.txt must expose settings immediately.
    [IO.File]::WriteAllText((Join-Path $src 'options.txt'),"gamma:1`nkey_example:23`nresourcePacks:[]`n")
    $snapshots = @{}
    $captured = [Collections.Generic.List[object]]::new()
    function Add-Choice($label,$value) { $captured.Add($value) }
    Add-Settings 'options.txt' '(?m)^(?<key>[^:\r\n]+):(?<value>[^\r\n]*)' '^(gamma|key_.*)$'
    if ($captured.Count -ne 2) { throw 'First-run settings are missing.' }
    $entry = $captured | Where-Object AppendKey -eq 'key_example'
    Write-Config (Join-Path $dst 'options.txt') $snapshots['options.txt'] ($entry.AppendKey + ':' + $entry.Value + "`r`n")
    if ((Read-Config (Join-Path $dst 'options.txt')) -cne "key_example:23`r`n") { throw 'Unselected settings were written.' }
    $sentinel = Join-Path $src 'mods'
    [void][IO.Directory]::CreateDirectory($sentinel)
    [IO.File]::WriteAllText((Join-Path $sentinel 'GTNewHorizonsCoreMod-test.jar'),'')
    if (!(Test-GtnhDirectory $src) -or (Test-GtnhDirectory $dst)) { throw 'GTNH identification failed.' }

    $fixtures = @([pscustomobject]@{
        tag_name='2.3.4'; html_url='https://github.com/Kiwi233/Translation-of-GTNH/releases/tag/2.3.4'; draft=$false
        assets=@(foreach ($name in '2.3.4_normal.7z','2.3.4_complete.7z','helper.jar') {
            [pscustomobject]@{name=$name; browser_download_url="https://github.com/Kiwi233/Translation-of-GTNH/releases/download/2.3.4/$name";size=1;digest=''}
        })
    })
    $assets = @(Get-TranslationAssets $fixtures)
    if ($assets.Count -ne 2 -or $assets[0].Tag -ne '2.3.4') { throw 'Per-version archive selection failed.' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $content = [IO.Directory]::CreateDirectory((Join-Path $root 'package/config/test')).FullName
    [IO.File]::WriteAllText((Join-Path $content 'zh_CN.lang'),'translated')
    $zip = Join-Path $root 'translation.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $root 'package'),$zip)
    $out = Join-Path $dst 'config/test/zh_CN.lang'
    [void][IO.Directory]::CreateDirectory((Split-Path $out -Parent))
    [IO.File]::WriteAllText($out,'original')
    $message = Install-TranslationArchive $zip $dst
    if ([IO.File]::ReadAllText($out) -cne 'translated') { throw 'Translation not installed.' }
    $backup = @(Get-ChildItem -LiteralPath $dst -Directory -Filter '.gtnh-translation-backup-*')
    if ($backup.Count -ne 1 -or [IO.File]::ReadAllText((Join-Path $backup[0].FullName 'original/config/test/zh_CN.lang')) -cne 'original') {
        throw 'Translation backup mismatch.'
    }
    # A malformed archive must fail before it can touch the destination.
    $bad = Join-Path $root 'bad.zip'
    $z = [IO.Compression.ZipFile]::Open($bad,'Create')
    try { [void]$z.CreateEntry('../outside.txt') } finally { $z.Dispose() }
    $rejected = $false
    try { [void](Install-TranslationArchive $bad $dst) } catch { $rejected = $true }
    if (!$rejected -or [IO.File]::Exists((Join-Path $root 'outside.txt'))) { throw 'Traversal archive accepted.' }

    # Fail after a replacement has occurred, then verify the original is restored.
    $rollbackTarget = [IO.Directory]::CreateDirectory((Join-Path $root 'rollback-target')).FullName
    $rollbackFile = Join-Path $rollbackTarget 'config/test/zh_CN.lang'
    [void][IO.Directory]::CreateDirectory((Split-Path $rollbackFile -Parent))
    [IO.File]::WriteAllText($rollbackFile,'original')
    function Get-FileHash($LiteralPath) {
        if ($LiteralPath -eq $rollbackFile -and [IO.File]::ReadAllText($LiteralPath) -eq 'translated') {
            throw 'Injected verification failure.'
        }
        Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath
    }
    $rolledBack = $false
    try { [void](Install-TranslationArchive $zip $rollbackTarget) }
    catch { $rolledBack = $_.Exception.Message -match '已恢复' }
    finally { Remove-Item Function:\Get-FileHash }
    if (!$rolledBack -or [IO.File]::ReadAllText($rollbackFile) -cne 'original') { throw 'Rollback after replacement failed.' }

    if ($TranslationSample) {
        $sampleTarget = [IO.Directory]::CreateDirectory((Join-Path $root 'sample-target')).FullName
        $result = Install-TranslationArchive (Resolve-Path $TranslationSample).Path $sampleTarget
        if (!(Test-Path -LiteralPath (Join-Path $sampleTarget 'GregTech_zh_CN.lang'))) { throw '7z sample not installed.' }
        Write-Output $result
    }
    # A local slow endpoint verifies cancellation and timeout without GitHub access.
    Initialize-TranslationTransfer
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;
public sealed class GtnhSlowServer : IDisposable {
    private TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
    private TcpClient connection;
    public int Port;
    public GtnhSlowServer() {
        listener.Start(); Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        Task.Run(async () => { try { connection = await listener.AcceptTcpClientAsync(); } catch {} });
    }
    public void Dispose() { listener.Stop(); if (connection != null) connection.Close(); }
}
'@
    $server = [GtnhSlowServer]::new()
    $owner = [Windows.Forms.Form]::new()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try {
        if ($UiTest) {
            Receive-TranslationFile "http://127.0.0.1:$($server.Port)/slow" (Join-Path $root 'slow') $owner '超时测试' 1
        } else {
            $transfer = [GtnhDownload]::new()
            $transfer.Start("http://127.0.0.1:$($server.Port)/slow",(Join-Path $root 'slow'))
            $transfer.Cancel.CancelAfter(1000)
            try { [void]$transfer.Work.Wait(4000) } catch { }
            $timedOut = $transfer.Work.IsCompleted -and $transfer.Work.Status -eq 'Canceled'
            $transfer.CancelAndCleanup((Join-Path $root 'slow'))
        }
    } catch { $timedOut = $_.Exception.Message -match '超时' }
    finally { $server.Dispose(); $owner.Dispose() }
    if (!$timedOut -or $watch.Elapsed.TotalSeconds -gt 5) { throw 'Network timeout failed to release UI.' }
    if ($UiTest) {
        $server = [GtnhSlowServer]::new()
        $owner = [Windows.Forms.Form]::new()
        $cancelTimer = [Windows.Forms.Timer]::new()
        $cancelTimer.Interval = 200
        $cancelTimer.Add_Tick({
            foreach ($window in [Windows.Forms.Application]::OpenForms) {
                if ($window.Text -eq '取消测试') {
                    $cancelTimer.Stop()
                    $window.CancelButton.PerformClick()
                    break
                }
            }
        })
        $canceled = $false
        $watch.Restart()
        try {
            $cancelTimer.Start()
            Receive-TranslationFile "http://127.0.0.1:$($server.Port)/slow" (Join-Path $root 'cancel') $owner '取消测试' 20
        } catch { $canceled = $_.Exception.Message -match '取消' }
        finally { $cancelTimer.Dispose(); $server.Dispose(); $owner.Dispose() }
        if (!$canceled -or $watch.Elapsed.TotalSeconds -gt 5) { throw 'Cancel button failed to release the download window.' }
    }
    'FEATURE PASS: first-run settings, GTNH detection, release assets, translation install/backup/rollback, traversal rejection, bounded network timeout'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if (!$resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test directory.' }
    [IO.Directory]::Delete($resolved,$true)
}
