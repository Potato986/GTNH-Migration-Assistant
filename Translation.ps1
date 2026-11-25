function Initialize-TranslationTransfer {
    if ('GtnhDownload' -as [type]) { return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $definition = @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class GtnhDownload : IDisposable {
    public readonly CancellationTokenSource Cancel = new CancellationTokenSource();
    public long Bytes;
    public long Total;
    public long LastActivity = DateTime.UtcNow.Ticks;
    public Task Work;
    public void Start(string url, string path) { Work = Download(url, path); }
    private async Task Download(string url, string path) {
        using (var client = new HttpClient()) {
            client.Timeout = Timeout.InfiniteTimeSpan;
            client.DefaultRequestHeaders.UserAgent.ParseAdd("GTNH-Migration-Assistant/0.2");
            using (var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, Cancel.Token).ConfigureAwait(false)) {
                response.EnsureSuccessStatusCode();
                Total = response.Content.Headers.ContentLength ?? 0;
                using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true)) {
                    var buffer = new byte[81920];
                    int count;
                    while ((count = await input.ReadAsync(buffer, 0, buffer.Length, Cancel.Token).ConfigureAwait(false)) > 0) {
                        Bytes += count;
                        if (Bytes > 268435456) throw new IOException("Download exceeds 256 MiB.");
                        await output.WriteAsync(buffer, 0, count, Cancel.Token).ConfigureAwait(false);
                        LastActivity = DateTime.UtcNow.Ticks;
                    }
                }
            }
        }
    }
    public void Dispose() { Cancel.Dispose(); }
    public void CancelAndCleanup(string path) {
        Cancel.Cancel();
        Work.ContinueWith(task => {
            var error = task.Exception;
            try { File.Delete(path); } catch (IOException) {} catch (UnauthorizedAccessException) {}
            Dispose();
        }, TaskScheduler.Default);
    }
}
'@
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -ReferencedAssemblies 'System.Net.Http.dll' -TypeDefinition $definition
    } else {
        Add-Type -TypeDefinition $definition
    }
}

function Receive-TranslationFile($url, $path, $owner, $title, [int]$seconds = 60) {
    Initialize-TranslationTransfer
    $transfer = [GtnhDownload]::new()
    $dialog = [Windows.Forms.Form]::new()
    $dialog.Text = $title
    $dialog.ClientSize = [Drawing.Size]::new(460,110)
    $dialog.StartPosition = 'CenterParent'
    $dialog.ControlBox = $false
    $status = [Windows.Forms.Label]::new()
    $status.Dock = 'Fill'
    $status.Padding = [Windows.Forms.Padding]::new(12)
    $status.Text = '正在连接 GitHub…'
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.Dock = 'Bottom'
    $cancel.DialogResult = 'Cancel'
    $dialog.CancelButton = $cancel
    $dialog.Controls.Add($status)
    $dialog.Controls.Add($cancel)
    $state = @{ Reason = ''; Completed = $false }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 100
    $timer.Add_Tick({
        $status.Text = '已接收 {0:N1} KB，可随时取消。' -f ($transfer.Bytes / 1024)
        $idle = ([DateTime]::UtcNow.Ticks - $transfer.LastActivity) / [TimeSpan]::TicksPerSecond
        if ($clock.Elapsed.TotalSeconds -ge $seconds -or $idle -ge 12) {
            $state.Reason = '网络连接超时，已跳过汉化。'
            $dialog.Close()
        } elseif ($transfer.Work.IsCompleted) {
            $state.Completed = $true
            $dialog.Close()
        }
    })
    try {
        $transfer.Start($url,$path)
        $timer.Start()
        [void]$dialog.ShowDialog($owner)
        if (!$state.Completed) {
            $transfer.Cancel.Cancel()
            if (!$state.Reason) { $state.Reason = '已取消汉化下载。' }
            throw $state.Reason
        }
        [void]$transfer.Work.GetAwaiter().GetResult()
    } finally {
        $timer.Stop()
        $timer.Dispose()
        if ($state.Completed -and $transfer.Work.Status -eq 'RanToCompletion') { $transfer.Dispose() }
        else { $transfer.CancelAndCleanup($path) }
        $dialog.Dispose()
    }
}

function Get-TranslationAssets($releases) {
    foreach ($release in $releases) {
        if ($release.draft) { continue }
        foreach ($asset in $release.assets) {
            if ($asset.name -notmatch '\.(7z|zip)$') { continue }
            if ($asset.browser_download_url -notlike 'https://github.com/Kiwi233/Translation-of-GTNH/releases/download/*') { continue }
            [pscustomobject]@{
                Label = "$($release.tag_name) — $($asset.name)"
                Tag = [string]$release.tag_name
                Name = [string]$asset.name
                Url = [string]$asset.browser_download_url
                Page = [string]$release.html_url
                Size = [long]$asset.size
                Digest = [string]$asset.digest
            }
        }
    }
}

function Show-TranslationFailure($owner,$message,$url) {
    $notice = [Windows.Forms.Form]::new()
    $notice.Text = '汉化暂未安装'
    $notice.ClientSize = [Drawing.Size]::new(540,175)
    $notice.StartPosition = 'CenterParent'
    $label = [Windows.Forms.Label]::new()
    $label.Dock = 'Fill'
    $label.Padding = [Windows.Forms.Padding]::new(12)
    $label.Text = $message + "`r`n可从下方页面手动下载，随后继续其他迁移操作。"
    $link = [Windows.Forms.LinkLabel]::new()
    $link.Dock = 'Bottom'
    $link.Height = 40
    $link.Text = $url
    $link.Add_LinkClicked({ Start-Process $url })
    $ok = [Windows.Forms.Button]::new()
    $ok.Text = '继续'
    $ok.Dock = 'Bottom'
    $ok.DialogResult = 'OK'
    $notice.AcceptButton = $ok
    $notice.CancelButton = $ok
    $notice.Controls.Add($label)
    $notice.Controls.Add($link)
    $notice.Controls.Add($ok)
    try { [void]$notice.ShowDialog($owner) } finally { $notice.Dispose() }
}

function Select-TranslationAsset($owner) {
    $picker = [Windows.Forms.Form]::new()
    $picker.Text = '选择汉化版本和文件（确认迁移时下载）'
    $picker.ClientSize = [Drawing.Size]::new(780,390)
    $picker.StartPosition = 'CenterParent'
    $help = [Windows.Forms.Label]::new()
    $help.Dock = 'Top'
    $help.Height = 46
    $help.Padding = [Windows.Forms.Padding]::new(8)
    $help.Text = '选择与目标整合包相符的版本。每日构建显示日期，完整包（complete）还会覆盖 scripts。'
    $options = [Windows.Forms.ListBox]::new()
    $options.Dock = 'Fill'
    $options.DisplayMember = 'Label'
    $options.HorizontalScrollbar = $true
    $bar = [Windows.Forms.FlowLayoutPanel]::new()
    $bar.Dock = 'Bottom'
    $bar.Height = 40
    $load = [Windows.Forms.Button]::new()
    $load.Text = '获取版本列表'
    $load.AutoSize = $true
    $choose = [Windows.Forms.Button]::new()
    $choose.Text = '使用此版本'
    $choose.AutoSize = $true
    $choose.Enabled = $false
    $bar.Controls.Add($load)
    $bar.Controls.Add($choose)
    $picker.Controls.Add($options)
    $picker.Controls.Add($help)
    $picker.Controls.Add($bar)
    $state = @{ Page = 1 }
    $options.Add_SelectedIndexChanged({ $choose.Enabled = $options.SelectedIndex -ge 0 })
    $choose.Add_Click({ $picker.Tag = $options.SelectedItem; $picker.DialogResult = 'OK' })
    $load.Add_Click({
        $cache = Join-Path ([IO.Path]::GetTempPath()) ('gtnh-releases-' + [guid]::NewGuid() + '.json')
        $load.Enabled = $false
        try {
            $api = 'https://api.github.com/repos/Kiwi233/Translation-of-GTNH/releases?per_page=100&page=' + $state.Page
            Receive-TranslationFile $api $cache $picker '读取汉化版本列表' 20
            $releases = @([IO.File]::ReadAllText($cache) | ConvertFrom-Json)
            foreach ($asset in Get-TranslationAssets $releases) { [void]$options.Items.Add($asset) }
            $state.Page++
            $load.Text = if ($releases.Count -lt 100) { '已加载所有版本' } else { '加载更多版本' }
            $load.Enabled = $releases.Count -ge 100
        } catch {
            Show-TranslationFailure $picker $_.Exception.Message 'https://github.com/Kiwi233/Translation-of-GTNH/releases'
            $load.Text = '重试获取版本'
            $load.Enabled = $true
        } finally {
            if ([IO.File]::Exists($cache)) {
                try { [IO.File]::Delete($cache) } catch [IO.IOException] { }
            }
        }
    })
    $picker.AcceptButton = $choose
    $picker.Add_Shown({ $load.PerformClick() })
    try { if ($picker.ShowDialog($owner) -eq 'OK') { return $picker.Tag } }
    finally { $picker.Dispose() }
}

function Invoke-TranslationTar($archive,$destination,$mode) {
    $tar = Get-Command tar.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $tar.Source
    $info.Arguments = switch ($mode) {
        'names' { '-tf "' + $archive + '"' }
        'types' { '-tvf "' + $archive + '"' }
        'extract' { '-xf "' + $archive + '" -C "' + $destination + '"' }
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($info)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) { $process.Kill(); throw '汉化解压超时。' }
        if ($process.ExitCode) { throw ('汉化压缩包无法读取。' + $errorOutput.Result) }
        $output.Result -split '\r?\n' | Where-Object { $_ }
    } finally { $process.Dispose() }
}

function Install-TranslationArchive($archive,$target) {
    Assert-RegularPath $target
    $names = @(Invoke-TranslationTar $archive $null 'names')
    foreach ($name in $names) {
        $parts = $name -split '[/\\]'
        if ($name -match '^[/\\]|:' -or $parts -contains '..' -or $parts -contains '.') { throw "压缩包路径无效：$name" }
    }
    foreach ($line in Invoke-TranslationTar $archive $null 'types') {
        if ($line[0] -notin '-','d') { throw '汉化包含有不支持的链接或文件类型。' }
    }
    $session = Join-Path $target ('.gtnh-translation-backup-' + [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($session)
    $unpack = [IO.Directory]::CreateDirectory((Join-Path $session 'unpacked')).FullName
    $backup = [IO.Directory]::CreateDirectory((Join-Path $session 'original')).FullName
    $changes = [Collections.Generic.List[object]]::new()
    try {
        [void](Invoke-TranslationTar $archive $unpack 'extract')
        foreach ($file in Get-Tree $unpack) {
            if ($file.PSIsContainer) { continue }
            $relative = $file.FullName.Substring($unpack.Length + 1)
            if ($relative -notmatch '^(config|scripts)\\' -and $relative -notmatch '^GregTech[^\\]*\.lang$' -and $relative -notin 'GTNH介绍.txt','看我.md') {
                throw "无法识别此汉化包的安装结构：$relative"
            }
            $out = Join-Path $target $relative
            $ancestor = Split-Path $out -Parent
            while (!(Test-Path -LiteralPath $ancestor)) { $ancestor = Split-Path $ancestor -Parent }
            Assert-RegularPath $ancestor
            if (Test-Path -LiteralPath $out) { Assert-RegularPath $out }
            $exists = [IO.File]::Exists($out)
            $saved = Join-Path $backup $relative
            if ($exists) {
                [void][IO.Directory]::CreateDirectory((Split-Path $saved -Parent))
                [IO.File]::Copy($out,$saved,$false)
                if ((Get-FileHash -LiteralPath $out).Hash -ne (Get-FileHash -LiteralPath $saved).Hash) { throw '汉化备份校验失败。' }
            }
            $changes.Add([pscustomobject]@{ Path=$relative; Existed=$exists; Hash=(Get-FileHash -LiteralPath $file.FullName).Hash })
        }
        if (!$changes.Count) { throw '汉化包中没有文件。' }
        $journal = Join-Path $session 'files.json'
        [IO.File]::WriteAllText($journal, (ConvertTo-Json -InputObject @($changes.ToArray()) -Depth 4), [Text.UTF8Encoding]::new($false))
        $applied = [Collections.Generic.List[object]]::new()
        try {
            foreach ($change in $changes) {
                $out = Join-Path $target $change.Path
                [void][IO.Directory]::CreateDirectory((Split-Path $out -Parent))
                $stage = $out + '.' + [guid]::NewGuid() + '.tmp'
                try {
                    [IO.File]::Copy((Join-Path $unpack $change.Path),$stage,$false)
                    if ((Get-FileHash -LiteralPath $stage).Hash -ne $change.Hash) { throw '汉化暂存校验失败。' }
                    if ($change.Existed) {
                        if ((Get-FileHash -LiteralPath $out).Hash -ne (Get-FileHash -LiteralPath (Join-Path $backup $change.Path)).Hash) {
                            throw "目标文件在备份后发生变化：$($change.Path)"
                        }
                        [IO.File]::Replace($stage,$out,[System.Management.Automation.Language.NullString]::Value)
                    }
                    else { [IO.File]::Move($stage,$out) }
                    $applied.Add($change)
                    if ((Get-FileHash -LiteralPath $out).Hash -ne $change.Hash) { throw '汉化覆盖校验失败。' }
                } finally { if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) } }
            }
        } catch {
            $problem = $_.Exception.Message
            foreach ($change in $applied) {
                $out = Join-Path $target $change.Path
                if ($change.Existed) { [IO.File]::Copy((Join-Path $backup $change.Path),$out,$true) }
                else { [IO.File]::Delete($out) }
            }
            throw "汉化覆盖失败，已恢复本次改动。$problem 备份位于 $backup"
        }
        return "已覆盖并校验 $($changes.Count) 个汉化文件。备份位于 $backup"
    } finally {
        if ([IO.Directory]::Exists($unpack)) { [IO.Directory]::Delete($unpack,$true) }
    }
}

function Install-SelectedTranslation($asset,$target,$owner) {
    $archive = Join-Path ([IO.Path]::GetTempPath()) ('gtnh-translation-' + [guid]::NewGuid() + [IO.Path]::GetExtension($asset.Name))
    try {
        Receive-TranslationFile $asset.Url $archive $owner ('下载汉化 ' + $asset.Tag) 60
        if ((Get-Item -LiteralPath $archive).Length -ne $asset.Size) { throw '汉化文件下载不完整。' }
        if ($asset.Digest -match '^sha256:([0-9a-fA-F]{64})$' -and (Get-FileHash -LiteralPath $archive).Hash -ine $matches[1]) {
            throw '汉化文件 SHA-256 校验失败。'
        }
        Install-TranslationArchive $archive $target
    } finally {
        if ([IO.File]::Exists($archive)) { try { [IO.File]::Delete($archive) } catch [IO.IOException] { } }
    }
}
