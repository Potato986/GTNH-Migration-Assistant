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
    public int StatusCode;
    public long LastActivity = DateTime.UtcNow.Ticks;
    public Task Work;
    public void Start(string url, string path) { Work = Download(url, path); }
    private async Task Download(string url, string path) {
        using (var client = new HttpClient()) {
            client.Timeout = Timeout.InfiniteTimeSpan;
            client.DefaultRequestHeaders.UserAgent.ParseAdd("GTNH-Migration-Assistant/0.3");
            using (var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, Cancel.Token).ConfigureAwait(false)) {
                StatusCode = (int)response.StatusCode;
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
    $dialog.ClientSize = [Drawing.Size]::new(660,265)
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
    [void](Add-GtnhDialogHeader $dialog '下载汉化文件' $title)
    Set-GtnhWindowTheme $dialog 'translation-scene.png'
    $state = @{ Reason = ''; Completed = $false }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 100
    $timer.Add_Tick({
        $status.Text = if ($transfer.Total -gt 0) {
            '已接收 {0:N1} / {1:N1} KB。可点击取消或按 Esc。' -f ($transfer.Bytes / 1024),($transfer.Total / 1024)
        } else { '已接收 {0:N1} KB，可点击取消或按 Esc。' -f ($transfer.Bytes / 1024) }
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
        try { [void]$transfer.Work.GetAwaiter().GetResult() }
        catch {
            if ($transfer.StatusCode -in 403,429) { throw 'GitHub 请求受限（403/429）。可使用已有版本列表，或打开下载页稍后重试。' }
            if ($transfer.StatusCode -eq 404) { throw '此版本文件已被上游移除，请刷新列表或打开下载页。' }
            throw '无法连接 GitHub 或下载被中断，请检查网络后重试。'
        }
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
    $notice.ClientSize = [Drawing.Size]::new(740,290)
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
    [void](Add-GtnhDialogHeader $notice '汉化下载暂未完成' '可返回选择其他版本或手动下载')
    Set-GtnhWindowTheme $notice 'translation-scene.png'
    try { [void]$notice.ShowDialog($owner) } finally { $notice.Dispose() }
}

function Read-TranslationCatalog {
    $bundled = [Text.Encoding]::UTF8.GetString((Get-GtnhAssetBytes 'translation-catalog.json')) | ConvertFrom-Json
    $cache = Join-Path $env:LOCALAPPDATA 'GTNH-Migration-Assistant/translation-catalog.json'
    if ([IO.File]::Exists($cache)) {
        try {
            $stored = [IO.File]::ReadAllText($cache) | ConvertFrom-Json
            if ([DateTime]$stored.fetchedAt -gt [DateTime]$bundled.fetchedAt -and $stored.releases) { return $stored }
        } catch { }
    }
    return $bundled
}

function Save-TranslationCatalog($catalog) {
    $dir = [IO.Directory]::CreateDirectory((Join-Path $env:LOCALAPPDATA 'GTNH-Migration-Assistant')).FullName
    $path = Join-Path $dir 'translation-catalog.json'
    $stage = $path + '.' + [guid]::NewGuid() + '.tmp'
    try {
        [IO.File]::WriteAllText($stage,($catalog | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($stage,$path,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($stage,$path) }
    } finally { if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) } }
}

function Get-TranslationPageReleases([string]$html) {
    $prefix = 'https://github.com/Kiwi233/Translation-of-GTNH/releases/expanded_assets/'
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hit in [regex]::Matches($html,'(?i)src="([^"\s]*releases/expanded_assets/[^"\s]+)"')) {
        $url = [Net.WebUtility]::HtmlDecode($hit.Groups[1].Value)
        if ($url.StartsWith('/')) { $url = 'https://github.com' + $url }
        if (!$url.StartsWith($prefix,[StringComparison]::Ordinal) -or !$seen.Add($url)) { continue }
        $tag = [Uri]::UnescapeDataString($url.Substring($prefix.Length))
        [pscustomobject]@{tag_name=$tag;html_url=('https://github.com/Kiwi233/Translation-of-GTNH/releases/tag/' + [Uri]::EscapeDataString($tag));draft=$false;assets=@()}
    }
}

function Get-TranslationPageAssets([string]$html,$release) {
    $prefix = '/Kiwi233/Translation-of-GTNH/releases/download/'
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hit in [regex]::Matches($html,'(?i)href="([^"\s]+/releases/download/[^"\s]+)"')) {
        $link = [Net.WebUtility]::HtmlDecode($hit.Groups[1].Value)
        if (!$link.StartsWith($prefix,[StringComparison]::Ordinal)) { continue }
        $name = [Uri]::UnescapeDataString(($link -split '/')[-1])
        if ($name -notmatch '\.(7z|zip)$' -or !$seen.Add($link)) { continue }
        [pscustomobject]@{name=$name;browser_download_url=('https://github.com'+$link);size=0;digest=''}
    }
}

function Update-TranslationCatalog($catalog,$owner,[int]$page) {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('gtnh-list-'+[guid]::NewGuid()+'.json')
    try {
        try {
            Receive-TranslationFile ('https://api.github.com/repos/Kiwi233/Translation-of-GTNH/releases?per_page=100&page='+$page) $temp $owner '刷新汉化版本' 8
            $incoming = @([IO.File]::ReadAllText($temp) | ConvertFrom-Json)
            $sourceName = 'GitHub API'
        } catch {
            if ($_.Exception.Message -match '取消') { throw }
            # Use an independent temp file because a canceled request may still release its handle.
            $temp = Join-Path ([IO.Path]::GetTempPath()) ('gtnh-list-'+[guid]::NewGuid()+'.html')
            Receive-TranslationFile ('https://github.com/Kiwi233/Translation-of-GTNH/releases?page='+$page) $temp $owner '从发行页读取版本' 8
            $incoming = @(Get-TranslationPageReleases ([IO.File]::ReadAllText($temp)))
            $sourceName = 'GitHub 发行页'
        }
        if (!$incoming.Count) { throw '此页未找到更多版本，可以继续使用现有列表。' }
        $map = @{}
        foreach ($release in $catalog.releases) { $map[$release.tag_name] = $release }
        foreach ($release in $incoming) {
            if (!$release.assets.Count -and $map.ContainsKey($release.tag_name)) { continue }
            $map[$release.tag_name] = $release
        }
        $ordered = [Collections.Generic.List[object]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($release in @($incoming)+@($catalog.releases)) {
            if ($seen.Add([string]$release.tag_name)) { $ordered.Add($map[$release.tag_name]) }
        }
        $updated = [pscustomobject]@{ fetchedAt=[DateTime]::UtcNow.ToString('o');releases=@($ordered.ToArray());source=$sourceName }
        try { Save-TranslationCatalog $updated } catch { }
        return $updated
    } finally { if ([IO.File]::Exists($temp)) { try {[IO.File]::Delete($temp)} catch [IO.IOException] {} } }
}

function Show-TranslationDetails($asset,$target,$owner) {
    $details = [Windows.Forms.Form]::new()
    $details.Text = '汉化下载和安装'
    $details.ClientSize = [Drawing.Size]::new(820,360)
    $details.StartPosition = 'CenterParent'
    $description = [Windows.Forms.Label]::new()
    $description.Dock = 'Fill'
    $description.Padding = [Windows.Forms.Padding]::new(16)
    $description.Text = "$($asset.Label)`r`n`r`n目标目录`r`n$target`r`n`r`n覆盖前备份原文件。完整包（complete）还会覆盖 scripts。"
    $bar = [Windows.Forms.FlowLayoutPanel]::new()
    $bar.Dock = 'Bottom'
    $install = [Windows.Forms.Button]::new()
    $install.Text = '下载并安装'
    $install.AutoSize = $true
    $queue = [Windows.Forms.Button]::new()
    $queue.Text = '加入迁移清单'
    $queue.AutoSize = $true
    $link = [Windows.Forms.LinkLabel]::new()
    $link.Text = '打开下载页'
    $link.AutoSize = $true
    $link.Margin = [Windows.Forms.Padding]::new(8,12,0,0)
    $link.Add_LinkClicked({ Start-Process $asset.Page })
    $back = [Windows.Forms.Button]::new()
    $back.Text = '返回列表'
    $back.DialogResult = 'Cancel'
    $queue.Add_Click({ $details.Tag=$asset; $details.DialogResult='OK' })
    $install.Add_Click({
        if ([Windows.Forms.MessageBox]::Show($details,"安装 $($asset.Label)`r`n覆盖到 $target`r`n覆盖前自动备份。",'确认安装汉化','OKCancel') -ne 'OK') {return}
        $install.Enabled=$false; $queue.Enabled=$false
        try {
            $result = Install-SelectedTranslation $asset $target $details
            $description.Text = "$result`r`n`r`n已安装 $($asset.Label)"
        } catch { Show-TranslationFailure $details $_.Exception.Message $asset.Page }
        finally { $install.Enabled=$true; $queue.Enabled=$true }
    })
    $bar.Controls.AddRange(@($install,$queue,$back,$link))
    $details.Controls.Add($description)
    $details.Controls.Add($bar)
    [void](Add-GtnhDialogHeader $details '汉化下载和安装' $asset.Tag)
    Set-GtnhWindowTheme $details 'translation-scene.png'
    $details.CancelButton=$back
    $details.AcceptButton=$install
    try { if ($details.ShowDialog($owner) -eq 'OK') {return $details.Tag} }
    finally {$details.Dispose()}
}

function Select-TranslationAsset($owner,$target) {
    $picker = [Windows.Forms.Form]::new()
    $picker.Text = '汉化版本列表'
    $picker.ClientSize = [Drawing.Size]::new(940,560)
    $picker.StartPosition = 'CenterParent'
    $help = [Windows.Forms.Label]::new()
    $help.Dock = 'Top'
    $help.Height = 46
    $help.Padding = [Windows.Forms.Padding]::new(8)
    $help.Text = '选择与目标整合包相符的版本。每日构建显示日期，完整包（complete）还会覆盖 scripts。'
    $options = [Windows.Forms.ListView]::new()
    $options.Name = 'TranslationVersions'
    $options.View = 'Details'
    $options.MultiSelect = $false
    [void]$options.Columns.Add('汉化版本',250)
    [void]$options.Columns.Add('可下载文件',440)
    [void]$options.Columns.Add('类型',170)
    $options.Dock = 'Fill'
    $filter = [Windows.Forms.TextBox]::new()
    $filter.Name = 'TranslationSearch'
    $filter.Dock = 'Top'
    $filter.AccessibleName = '搜索汉化版本或文件名'
    $bar = [Windows.Forms.FlowLayoutPanel]::new()
    $bar.Dock = 'Bottom'
    $bar.Height = 40
    $load = [Windows.Forms.Button]::new()
    $load.Text = '刷新版本'
    $load.AutoSize = $true
    $choose = [Windows.Forms.Button]::new()
    $choose.Text = '查看并安装'
    $choose.AutoSize = $true
    $choose.Enabled = $false
    $bar.Controls.Add($load)
    $bar.Controls.Add($choose)
    $more = [Windows.Forms.Button]::new()
    $more.Text = '加载更多版本'
    $more.AutoSize = $true
    $bar.Controls.Add($more)
    $close = [Windows.Forms.Button]::new()
    $close.Text = '返回迁移'
    $close.DialogResult = 'Cancel'
    $bar.Controls.Add($close)
    $picker.Controls.Add($options)
    $picker.Controls.Add($help)
    $picker.Controls.Add($filter)
    $picker.Controls.Add($bar)
    $state = @{ Page=1; Catalog=Read-TranslationCatalog }
    $render = {
        $options.BeginUpdate()
        try {
            $options.Items.Clear()
            $search=$filter.Text.Trim()
            foreach ($release in $state.Catalog.releases) {
                if ($release.draft) { continue }
                $assets=@(Get-TranslationAssets @($release))
                if (!$assets.Count -and !$release.assets.Count) { $assets=@([pscustomobject]@{Tag=$release.tag_name;Name='查看此版本的下载文件';Url='';Page=$release.html_url;Release=$release}) }
                foreach ($asset in $assets) {
                    if ($search -and ($asset.Tag+' '+$asset.Name).IndexOf($search,[StringComparison]::OrdinalIgnoreCase) -lt 0) {continue}
                    $row=[Windows.Forms.ListViewItem]::new([string]$asset.Tag)
                    [void]$row.SubItems.Add($asset.Name)
                    $kind=if($asset.Tag -like '*nightly*'){'每日构建'}elseif($asset.Name -like '*complete*'){'完整包（含脚本）'}else{'版本汉化'}
                    [void]$row.SubItems.Add($kind)
                    $row.Tag=$asset
                    [void]$options.Items.Add($row)
                }
            }
            $date=([DateTime]$state.Catalog.fetchedAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            $help.Text="搜索版本号或文件名。目录更新于 $date，共 $($options.Items.Count) 个文件。选中后查看并安装。"
            $choose.Enabled=$false
        } finally {$options.EndUpdate()}
    }
    $filter.Add_TextChanged($render)
    $options.Add_SelectedIndexChanged({$choose.Enabled=$options.SelectedItems.Count -eq 1})
    $choose.Add_Click({
        if (!$options.SelectedItems.Count) {return}
        $asset=$options.SelectedItems[0].Tag
        if (!$asset.Url) {
            $temp=Join-Path ([IO.Path]::GetTempPath()) ('gtnh-assets-'+[guid]::NewGuid()+'.html')
            try {
                $url='https://github.com/Kiwi233/Translation-of-GTNH/releases/expanded_assets/'+[Uri]::EscapeDataString($asset.Tag)
                Receive-TranslationFile $url $temp $picker '读取版本下载文件' 12
                $asset.Release.assets=@(Get-TranslationPageAssets ([IO.File]::ReadAllText($temp)) $asset.Release)
                try {Save-TranslationCatalog $state.Catalog} catch {}
                & $render
            } catch {Show-TranslationFailure $picker $_.Exception.Message $asset.Page}
            finally {if([IO.File]::Exists($temp)){try{[IO.File]::Delete($temp)} catch [IO.IOException] {}}}
            return
        }
        $chosen=Show-TranslationDetails $asset $target $picker
        if ($chosen) {$picker.Tag=$chosen; $picker.DialogResult='OK'}
    })
    $options.Add_DoubleClick({$choose.PerformClick()})
    $refresh = {
        $load.Enabled=$false; $more.Enabled=$false
        try {
            $state.Catalog=Update-TranslationCatalog $state.Catalog $picker $state.Page
            & $render
        } catch {
            $help.Text=$_.Exception.Message+' 已保留当前版本列表。'
        } finally {$load.Enabled=$true; $more.Enabled=$true}
    }
    $load.Add_Click({$state.Page=1; & $refresh})
    $more.Add_Click({$state.Page++; & $refresh})
    & $render
    [void](Add-GtnhDialogHeader $picker '选择汉化版本' '搜索 → 查看文件 → 下载并安装，或加入本次迁移清单')
    Set-GtnhWindowTheme $picker 'translation-scene.png'
    $picker.AcceptButton = $choose
    $picker.CancelButton = $close
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
        if ($asset.Size -gt 0 -and (Get-Item -LiteralPath $archive).Length -ne $asset.Size) { throw '汉化文件下载不完整。' }
        if ($asset.Digest -match '^sha256:([0-9a-fA-F]{64})$' -and (Get-FileHash -LiteralPath $archive).Hash -ine $matches[1]) {
            throw '汉化文件 SHA-256 校验失败。'
        }
        Install-TranslationArchive $archive $target
    } finally {
        if ([IO.File]::Exists($archive)) { try { [IO.File]::Delete($archive) } catch [IO.IOException] { } }
    }
}
