# GTNH-Migrate.ps1
# Windows PowerShell 5.1 或 PowerShell 7（Windows）
# 使用 Windows PowerShell 5.1 时，脚本文件采用 UTF-8 with BOM。
# 使用前请关闭源实例和目标实例的游戏进程。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function Pick-Instance($title) {
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = $title
    try {
        if ($dialog.ShowDialog() -ne 'OK') { return }
        $root = $dialog.SelectedPath
        foreach ($candidate in @((Join-Path $root '.minecraft'), $root)) {
            if (Test-Path -LiteralPath (Join-Path $candidate 'mods') -PathType Container) {
                return (Get-Item -LiteralPath $candidate).FullName
            }
        }
        throw "没有找到 mods 目录：$root"
    } finally {
        $dialog.Dispose()
    }
}

function Assert-RegularPath($path) {
    $item = Get-Item -LiteralPath $path -Force
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "路径包含目录联接或符号链接：$($item.FullName)"
        }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory }
        else { $item = $item.Parent }
    }
}

function Get-Tree($path) {
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "项目中包含链接：$path"
    }
    $item
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $path -Force) {
            Get-Tree $child.FullName
        }
    }
}

function Copy-Verified($relative, $destinationRelative = $relative) {
    $source = Join-Path $src $relative
    $target = Join-Path $dst $destinationRelative
    Assert-RegularPath $source
    if (Test-Path -LiteralPath $target) { throw "目标已有同名项目：$relative" }

    $parent = Split-Path $target -Parent
    $ancestor = $parent
    while (!(Test-Path -LiteralPath $ancestor)) {
        $ancestor = Split-Path $ancestor -Parent
    }
    Assert-RegularPath $ancestor
    [void][IO.Directory]::CreateDirectory($parent)
    $stage = Join-Path $parent ('.gtnh-stage-' + [guid]::NewGuid())
    try {
        foreach ($item in Get-Tree $source) {
            $out = $stage + $item.FullName.Substring($source.Length)
            if ($item.PSIsContainer) {
                [void][IO.Directory]::CreateDirectory($out)
            } else {
                [IO.File]::Copy($item.FullName, $out, $false)
                if ((Get-FileHash -LiteralPath $item.FullName).Hash -ne
                    (Get-FileHash -LiteralPath $out).Hash) {
                    throw "SHA-256 校验失败：$($item.FullName)"
                }
            }
        }
        if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Move($stage, $target) }
        else { [IO.File]::Move($stage, $target) }
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
}

# 用单字节映射保留原配置的编码、换行和未选中的内容。
$bytes = [Text.Encoding]::GetEncoding(28591)
function Read-Config($path) {
    Assert-RegularPath $path
    $bytes.GetString([IO.File]::ReadAllBytes($path))
}

function Write-Config($path, $before, $after) {
    if ((Read-Config $path) -cne $before) { throw "配置已变化，请重新扫描：$path" }
    if ($before -ceq $after) { return }
    $id = [guid]::NewGuid().ToString('N')
    $stage = "$path.$id.tmp"
    $backup = "$path.$id.bak"
    try {
        [IO.File]::WriteAllBytes($stage, $bytes.GetBytes($after))
        [IO.File]::Replace($stage, $path, $backup)
        if ((Read-Config $path) -cne $after) { throw "配置校验失败，备份：$backup" }
    } finally {
        if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
    }
}

$src = Pick-Instance '选择旧实例或它的 .minecraft'
if (!$src) { return }
$dst = Pick-Instance '选择新实例或它的 .minecraft'
if (!$dst) { return }
Assert-RegularPath $src
Assert-RegularPath $dst
if (($src + '\').StartsWith($dst + '\', 'OrdinalIgnoreCase') -or
    ($dst + '\').StartsWith($src + '\', 'OrdinalIgnoreCase')) {
    throw '请选择两个独立的实例目录。'
}

$form = New-Object Windows.Forms.Form
$form.Text = 'GTNH 迁移助手 · 本地预览版'
$form.Size = New-Object Drawing.Size(920, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI',10)
$form.BackColor = [Drawing.Color]::WhiteSmoke
$form.MinimumSize = [Drawing.Size]::new(760,520)

$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.Padding = [Windows.Forms.Padding]::new(16)
$layout.ColumnCount = 1
$layout.RowCount = 4
foreach ($height in @(54, 0, 44, 44)) {
    $style = New-Object Windows.Forms.RowStyle
    if ($height) { $style.SizeType = 'Absolute'; $style.Height = $height }
    else { $style.SizeType = 'Percent'; $style.Height = 100 }
    [void]$layout.RowStyles.Add($style)
}
$form.Controls.Add($layout)

$heading = New-Object Windows.Forms.Label
$heading.Dock = 'Fill'
$heading.ForeColor = [Drawing.Color]::DarkSlateGray
$heading.Text = "来源：$src`r`n目标：$dst"
$layout.Controls.Add($heading, 0, 0)

$list = New-Object Windows.Forms.ListView
$list.Dock = 'Fill'
$list.View = 'Details'
$list.CheckBoxes = $true
$list.Add_ItemCheck({ param($sender,$eventArgs)
    if ($sender.Items[$eventArgs.Index].Tag -eq 'readonly') {
        $eventArgs.NewValue = [Windows.Forms.CheckState]::Unchecked
    }
})
$list.FullRowSelect = $true
$list.ShowItemToolTips = $true
$list.BorderStyle = 'FixedSingle'
foreach ($col in @('迁移项目','目标当前值','迁移后')) {
    [void]$list.Columns.Add($col,150)
}
$list.Add_SizeChanged({ $list.Columns[0].Width = [Math]::Max(300,$list.ClientSize.Width-325) })
$tabs = [Windows.Forms.TabControl]::new()
$tabs.Dock = 'Fill'
$actionsPage = [Windows.Forms.TabPage]::new('可勾选迁移')
$existingPage = [Windows.Forms.TabPage]::new('目标已有')
$tabs.TabPages.Add($actionsPage)
$tabs.TabPages.Add($existingPage)
$actionsPage.Controls.Add($list)
$existingList = [Windows.Forms.ListView]::new()
$existingList.View = 'Details'
$existingList.Dock = 'Fill'
$existingList.FullRowSelect = $true
$existingList.ShowItemToolTips = $true
foreach ($label in '文件或目录','比较结果','处理方式') {
    [void]$existingList.Columns.Add($label,150)
}
$existingList.Add_SizeChanged({ $existingList.Columns[0].Width = [Math]::Max(300,$existingList.ClientSize.Width-325) })
$existingPage.Controls.Add($existingList)
$layout.Controls.Add($tabs, 0, 1)

$choices = @{}
$snapshots = @{}
function Add-Choice($label, $value) {
    $title = $label
    $current = ''
    $next = ''
    $group = $value.File
    if ($value.Kind -eq 'copy') {
        $group = ($value.File -split '\\')[0]
        $title = Split-Path $value.File -Leaf
        $current = '缺失'
        $next = '复制文件'
    } elseif ($label -match '^\S+   (.+?)   (.*?) → (.*)$') {
        $title = $matches[1]
        $current = $matches[2]
        $next = $matches[3]
    }
    $captions = @{resourcepacks='资源包'; shaderpacks='光影包'; saves='存档和 NEI'; journeymap='旅行地图'; 'options.txt'='游戏设置'; 'config\angelica.cfg'='字体设置'}
    if ($null -eq $list.Groups[$group]) {
        $caption = if ($captions.ContainsKey($group)) {$captions[$group]} else {$group}
        [void]$list.Groups.Add($group,$caption)
    }
    $row = [Windows.Forms.ListViewItem]::new([string]$title)
    $row.Group = $list.Groups[$group]
    $row.ToolTipText = $label
    [void]$row.SubItems.Add([string]$current)
    [void]$row.SubItems.Add([string]$next)
    $row.Tag = $value
    $index = $list.Items.Add($row).Index
    $choices[[int]$index] = $value
}

function Add-Copy($relative) {
    $source = Join-Path $src $relative
    if (!(Test-Path -LiteralPath $source)) { return }
    $target = Join-Path $dst $relative
    if (Test-Path -LiteralPath $target) {
        Assert-RegularPath $source
        Assert-RegularPath $target
        $status = '同名目录（未比较内容）'
        if ([IO.File]::Exists($source) -and [IO.File]::Exists($target)) {
            $same = (Get-Item -LiteralPath $source).Length -eq (Get-Item -LiteralPath $target).Length -and
                (Get-FileHash -LiteralPath $source).Hash -eq (Get-FileHash -LiteralPath $target).Hash
            $status = if ($same) {'文件一致'} else {'同名文件内容不同'}
        } elseif ([IO.Directory]::Exists($source) -ne [IO.Directory]::Exists($target)) {
            $status = '文件与目录类型冲突'
        }
        $group = 'existing'
        $row = [Windows.Forms.ListViewItem]::new($relative)
        $row.Tag = 'readonly'
        if ([IO.Directory]::Exists($source) -and [IO.Directory]::Exists($target)) {
            $row.Name = $relative
            $status = '双击查看差异'
            if ($relative -match '^saves\\[^\\]+$') {
                $suffix = 1
                do { $alternate = "$relative (迁移 $suffix)"; $suffix++ }
                while ((Test-Path -LiteralPath (Join-Path $dst $alternate)) -or (Test-Path -LiteralPath (Join-Path $src $alternate)))
                Add-Choice "另存世界   $relative → $alternate" ([pscustomobject]@{
                    Kind='world'; File=$relative; Destination=$alternate
                })
            }
        }
        $row.ToolTipText = "$relative  $status"
        [void]$row.SubItems.Add($status)
        [void]$row.SubItems.Add('保留目标')
        [void]$existingList.Items.Add($row)
        return
    }
    Add-Choice "复制   $relative" ([pscustomobject]@{
        Kind = 'copy'; File = $relative
    })
}

$existingList.Add_DoubleClick({
    if (!$existingList.SelectedItems.Count) { return }
    $parentRow = $existingList.SelectedItems[0]
    $relative = $parentRow.Name
    if (!$relative) { return }
    $source = Join-Path $src $relative
    $target = Join-Path $dst $relative
    $canMerge = $relative -match '^(screenshots|journeymap|visualprospecting|TCNodeTracker)(\\|$)'
    $detail = [Windows.Forms.Form]::new()
    $detail.Text = $relative
    $detail.Size = [Drawing.Size]::new(800,500)
    $detail.Font = $form.Font
    $files = [Windows.Forms.CheckedListBox]::new()
    $files.Dock = 'Fill'
    $files.CheckOnClick = $true
    $files.HorizontalScrollbar = $true
    $missing = @{}
    $counts = @{'相同'=0;'目标缺失'=0;'仅目标有'=0;'内容不同'=0;'类型冲突'=0}
    $summary = [Windows.Forms.Label]::new()
    $summary.Dock = 'Top'
    $summary.Height = 82
    $summary.Padding = [Windows.Forms.Padding]::new(8)
    $category = switch -Regex ($relative) {
        '^screenshots' {'截图';break}
        '^journeymap' {'旅行地图';break}
        '^visualprospecting' {'矿脉标记';break}
        '^TCNodeTracker' {'神秘节点标记';break}
        '^saves' {'存档';break}
        default {'当前目录'}
    }
    $queue = [Windows.Forms.Button]::new()
    $queue.Text = '加入迁移清单'
    $queue.Dock = 'Bottom'
    try {
        $left = @{}
        $right = @{}
        foreach ($item in Get-Tree $source) {
            if (!$item.PSIsContainer) { $left[$item.FullName.Substring($source.Length+1)] = $item }
        }
        foreach ($item in Get-Tree $target) {
            if (!$item.PSIsContainer) { $right[$item.FullName.Substring($target.Length+1)] = $item }
        }
        foreach ($name in (@($left.Keys)+@($right.Keys) | Sort-Object -Unique)) {
            $state = if (!$left.ContainsKey($name)) {'仅目标有'}
                elseif (!$right.ContainsKey($name)) {
                    $candidate = Join-Path $target $name
                    while (!(Test-Path -LiteralPath $candidate)) { $candidate = Split-Path $candidate -Parent }
                    if ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists((Join-Path $target $name))) {'类型冲突'} else {'目标缺失'}
                } elseif ($left[$name].Length -eq $right[$name].Length -and
                    (Get-FileHash -LiteralPath $left[$name].FullName).Hash -eq (Get-FileHash -LiteralPath $right[$name].FullName).Hash) {'相同'} else {'内容不同'}
            $counts[$state]++
            if ($state -eq '相同') { continue }
            $index = $files.Items.Add("[$state]  $name")
            if ($canMerge -and $state -eq '目标缺失') { $missing[$index] = Join-Path $relative $name }
        }
        $files.Add_ItemCheck({param($sender,$ev)
            if (!$missing.ContainsKey($ev.Index)) { $ev.NewValue = 'Unchecked' }
        })
        $parts = @(foreach ($pair in @(
            @('目标缺失','只在旧实例中'),@('仅目标有','只在新实例中'),
            @('内容不同','同名但内容不同'),@('类型冲突','文件与文件夹重名')
        )) { if ($counts[$pair[0]]) { "$($counts[$pair[0]]) 个$($pair[1])" } })
        $message = if ($parts.Count) { $parts -join '，' } else { '没有发现文件差异' }
        $action = if ($missing.Count) { "可补回 $($missing.Count) 个文件。" }
            elseif ($category -eq '存档' -and $parts.Count) { '要保留两份世界，可在主窗口勾选“另存世界”。' } else { '' }
        $summary.Text = "$category · $message。`r`n$($counts['相同']) 个相同文件已隐藏。$action"
        $queue.Enabled = $missing.Count -gt 0
        $queue.Text = '应用选择'
        $rowsByPath = @{}
        foreach ($id in $choices.Keys) {
            if ($choices[$id].Kind -eq 'copy') { $rowsByPath[$choices[$id].File] = $id }
        }
        foreach ($index in $missing.Keys) {
            $path = $missing[$index]
            if ($rowsByPath.ContainsKey($path)) {
                $files.SetItemChecked($index,$list.Items[$rowsByPath[$path]].Checked)
            }
        }
        $bulk = [Windows.Forms.Button]::new()
        $bulk.Text = '全选 / 取消全部可补回文件'
        $bulk.Dock = 'Top'
        $bulk.Visible = $missing.Count -gt 0
        $bulk.Add_Click({
            $check = $files.CheckedIndices.Count -lt $missing.Count
            $files.BeginUpdate()
            try { foreach ($index in $missing.Keys) { $files.SetItemChecked($index,$check) } }
            finally { $files.EndUpdate() }
        })
        $queue.Add_Click({
            foreach ($index in $missing.Keys) {
                $path = $missing[$index]
                $check = $files.GetItemChecked($index)
                if ($rowsByPath.ContainsKey($path)) { $list.Items[$rowsByPath[$path]].Checked = $check }
                elseif ($check) {
                    $id = $list.Items.Count
                    Add-Copy $path
                    if ($choices.ContainsKey($id)) { $list.Items[$id].Checked = $true }
                }
            }
            $detail.Close()
        })
        $detail.Controls.Add($files)
        $detail.Controls.Add($bulk)
        $detail.Controls.Add($summary)
        $detail.Controls.Add($queue)
        [void]$detail.ShowDialog($form)
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'目录比较失败') }
    finally { $detail.Dispose() }
})
function Get-JarModIds($file) {
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($file.FullName)
        $entry = $archive.GetEntry('mcmod.info')
        if (!$entry -or $entry.Length -gt 1048576) { return }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $metadata = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop }
        finally { $reader.Dispose() }
        if ($metadata.modList) { $metadata = $metadata.modList }
        foreach ($mod in $metadata) {
            if ($mod.modid -is [string] -and $mod.modid.Trim()) { $mod.modid.Trim() }
        }
    } catch { return }
    finally { if ($archive) { $archive.Dispose() } }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$targetIds = @{}
$targetNames = @{}
foreach ($jar in Get-ChildItem -LiteralPath (Join-Path $dst 'mods') -File | Where-Object Name -Match '\.jar(?:\.disabled)?$') {
    $targetNames[($jar.Name -replace '\.disabled$','')] = $true
    foreach ($id in Get-JarModIds $jar) { $targetIds[$id] = $true }
}
foreach ($jar in Get-ChildItem -LiteralPath (Join-Path $src 'mods') -File -Filter '*.jar') {
    if ($targetNames.ContainsKey($jar.Name)) { continue }
    $ids = @(Get-JarModIds $jar)
    if (!$ids.Count -or @($ids | Where-Object { $targetIds.ContainsKey($_) }).Count) { continue }
    $relative = Join-Path 'mods' $jar.Name
    Add-Choice "旧版模组（来源待确认）   $($ids -join ', ')   $relative" ([pscustomobject]@{
        Kind='copy'; File=$relative
    })
}
$scanFolders = @(
    'saves'
    'resourcepacks'
    'shaderpacks'
    'journeymap\data\sp'
    'journeymap\data\mp'
)

foreach ($folder in $scanFolders) {
    $dir = Join-Path $src $folder
    if (!(Test-Path -LiteralPath $dir -PathType Container)) { continue }
    Assert-RegularPath $dir

    foreach ($item in Get-ChildItem -LiteralPath $dir -Force) {
        if ($folder -eq 'saves') {
            # NEI 数据由原有的独立选项处理。
            if (!$item.PSIsContainer -or $item.Name -eq 'NEI') { continue }
        }
        if ($folder -like 'journeymap\*' -and !$item.PSIsContainer) { continue }
        Add-Copy (Join-Path $folder $item.Name)
    }
}
foreach ($relative in 'saves\NEI\global\bookmarks.ini','saves\NEI\global\favorites.ini',
    'visualprospecting','TCNodeTracker','backups','screenshots','schematics',
    'servers.dat','localconfig.cfg','BotaniaVars.dat','optionsnf.txt',
    'config\vendingmachine\favourites') {
    Add-Copy $relative
}

function Index-Settings($text, $regex) {
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($hit in [regex]::Matches($text, $regex)) {
        $key = $hit.Groups['key'].Value
        if ($map.ContainsKey($key)) { $map[$key] = $null }
        else { $map.Add($key, $hit.Groups['value']) }
    }
    return ,$map
}

function Add-Settings($relative, $regex, $allowed) {
    $source = Join-Path $src $relative
    $target = Join-Path $dst $relative
    if (![IO.File]::Exists($source) -or ![IO.File]::Exists($target)) { return }
    $before = Read-Config $target
    $snapshots[$relative] = $before
    $old = Index-Settings (Read-Config $source) $regex
    $new = Index-Settings $before $regex
    foreach ($key in ($old.Keys | Sort-Object)) {
        if ($key -cnotmatch $allowed -or !$new.ContainsKey($key)) { continue }
        $from = $old[$key]
        $to = $new[$key]
        if ($null -eq $from -or $null -eq $to -or $from.Value -ceq $to.Value) { continue }
        Add-Choice "$relative   $key   $($to.Value) → $($from.Value)" ([pscustomobject]@{
            Kind = 'setting'; File = $relative; Offset = $to.Index
            Length = $to.Length; Value = $from.Value
        })
    }
}

# 比较 options.txt 中两边共有、值不同的设置。
# 资源包列表有单独的解析与启用流程。
# lastServer 是连接记录，避免随普通偏好迁移。
Add-Settings 'options.txt' `
    '(?m)^(?<key>[^:\r\n]+):(?<value>[^\r\n]*)' `
    '^(?!(?:resourcePacks|incompatibleResourcePacks|lastServer)$).+$'

# 两边都有 Angelica 时，列出实际不同的字体选项。
# 没有该模组的实例会由 Add-Settings 自动跳过。
Add-Settings 'config\angelica.cfg' `
    '(?m)^[ \t]*(?<key>[BS]:[^=\r\n]+)=(?<value>[^\r\n]*)' `
    '^(?:B:(?:enableCustomFont|enableModernFont)|S:(?:customFont[^=\r\n]*|fontBrightness|fontShadowOffset(?:UC)?))$'

function Read-PackSelection($text) {
    $hits = [regex]::Matches($text, '(?m)^resourcePacks:(?<list>[^\r\n]*)')
    if ($hits.Count -ne 1) { throw '无法唯一定位 resourcePacks。' }
    $value = $hits[0].Groups['list']
    # Read-Config 使用单字节映射；这里恢复 Minecraft 配置中的 UTF-8 名称。
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $json = $utf8.GetString($bytes.GetBytes($value.Value))
    if (!$json.TrimStart().StartsWith('[')) { throw '资源包列表格式异常。' }
    $decoded = ConvertFrom-Json -InputObject $json
    $names = @(foreach ($entry in $decoded) { $entry })
    foreach ($name in $names) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
            $name -in '.', '..' -or
            $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw '资源包列表含无法识别的文件名。'
        }
    }
    [pscustomobject]@{ Names = $names; Offset = $value.Index; Length = $value.Length }
}

$packOrderChoice = $null
try {
    if ($snapshots.ContainsKey('options.txt')) {
        $oldPacks = Read-PackSelection (Read-Config (Join-Path $src 'options.txt'))
        $newPacks = Read-PackSelection $snapshots['options.txt']
        $seen = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        $order = @(
            foreach ($name in (@($oldPacks.Names) + @($newPacks.Names))) {
                if ($seen.Add($name)) { $name }
            }
        )
        $json = ConvertTo-Json -InputObject @($order) -Compress
        $current = ConvertTo-Json -InputObject @($newPacks.Names) -Compress
        if ($json -cne $current) {
            $packOrderChoice = [pscustomobject]@{
                Kind = 'setting'
                File = 'options.txt'
                Offset = $newPacks.Offset
                Length = $newPacks.Length
                Value = $bytes.GetString([Text.Encoding]::UTF8.GetBytes($json))
                Packs = $order
            }
            Add-Choice ("沿用旧实例的资源包顺序   " + ($order -join ' → ')) $packOrderChoice
        }
    }
} catch {
    [void][Windows.Forms.MessageBox]::Show(
        "无法比较资源包启用顺序。仍可逐个复制资源包。`r`n$($_.Exception.Message)",
        '资源包扫描'
    )
}

$shader = New-Object Windows.Forms.ComboBox
$shader.Dock = 'Fill'
$shader.DropDownStyle = 'DropDownList'
[void]$shader.Items.Add('光影：保留新版当前设置')
$names = foreach ($root in @($src, $dst)) {
    $dir = Join-Path $root 'shaderpacks'
    if (!(Test-Path -LiteralPath $dir -PathType Container)) { continue }
    Assert-RegularPath $dir
    foreach ($item in Get-ChildItem -LiteralPath $dir) {
        if ((!$item.PSIsContainer -and $item.Extension -ieq '.zip') -or
            ($item.PSIsContainer -and
             [IO.Directory]::Exists((Join-Path $item.FullName 'shaders')))) {
            $item.Name
        }
    }
}
foreach ($name in ($names | Sort-Object -Unique)) { [void]$shader.Items.Add($name) }
$shader.SelectedIndex = 0
$layout.Controls.Add($shader, 0, 2)

$shaderPath = Join-Path $dst 'config\shaders.properties'
$shaderBefore = if ([IO.File]::Exists($shaderPath)) { Read-Config $shaderPath }
$button = New-Object Windows.Forms.Button
$button.Text = '预览并确认迁移'
$button.Dock = 'Fill'
$button.FlatStyle = 'Flat'
$button.FlatAppearance.BorderSize = 0
$button.BackColor = [Drawing.Color]::FromArgb(22,99,84)
$button.ForeColor = [Drawing.Color]::White
$layout.Controls.Add($button, 0, 3)

$button.Add_Click({
    $checkedRows = @(foreach ($row in $list.Items) { if ($row.Checked) { $row } })
    if (!$checkedRows.Count -and $shader.SelectedIndex -eq 0) {
        [void][Windows.Forms.MessageBox]::Show('请勾选要迁移的项目。','迁移清单为空')
        return
    }
    $failed = [Collections.Generic.List[string]]::new()
    $done = 0
    $selected = @($checkedRows | ForEach-Object { $_.Tag })
    $preview = @($checkedRows | ForEach-Object { $_.ToolTipText })
    try {
        $shaderName = $null
        $restorePacks = $null -ne $packOrderChoice -and $selected -contains $packOrderChoice
        if ($restorePacks) {
            foreach ($name in $packOrderChoice.Packs) {
                $relative = Join-Path 'resourcepacks' $name
                $exists = Test-Path -LiteralPath (Join-Path $dst $relative)
                $queued = @($selected | Where-Object {
                    $_.Kind -eq 'copy' -and $_.File -eq $relative
                }).Count -gt 0
                if (!$exists -and !$queued) {
                    throw "目标里缺少资源包「$name」。请勾选复制该包，或取消恢复加载顺序。"
                }
            }
        }
        if ($shader.SelectedIndex -gt 0) {
            $shaderName = [string]$shader.SelectedItem
            $relative = Join-Path 'shaderpacks' $shaderName
            $copySelected = @($selected | Where-Object {
                $_.Kind -eq 'copy' -and $_.File -eq $relative
            }).Count -gt 0
            if (!(Test-Path -LiteralPath (Join-Path $dst $relative)) -and !$copySelected) {
                throw "请先勾选要复制的光影：$shaderName"
            }
            $rx = [regex]'(?m)^(?<prefix>[ \t]*shaderPack[ \t]*=[ \t]*)[^\r\n]*'
            if ($null -eq $shaderBefore -or $rx.Matches($shaderBefore).Count -ne 1) {
                throw '目标光影配置缺失或无法识别。可选择保留当前光影后继续。'
            }
            $preview += "启用光影   $shaderName"
        }
        if ([Windows.Forms.MessageBox]::Show(
            ($preview -join "`r`n"), '确认迁移清单', 'OKCancel'
        ) -ne 'OK') { return }

        $button.Enabled = $false
        $failedCopies = @{}
        foreach ($entry in $selected | Where-Object { $_.Kind -in 'copy','world' }) {
            try {
                if ($entry.Kind -eq 'world') { Copy-Verified $entry.File $entry.Destination }
                else { Copy-Verified $entry.File }
                $done++
            }
            catch {
                $failedCopies[$entry.File] = $true
                $failed.Add("$($entry.File)：$($_.Exception.Message)")
            }
        }
        foreach ($group in ($selected | Where-Object Kind -eq 'setting' | Group-Object File)) {
            try {
                $before = $snapshots[$group.Name]
                $after = $before
                $applied = 0
                foreach ($edit in ($group.Group | Sort-Object Offset -Descending)) {
                    if ($restorePacks -and $edit -eq $packOrderChoice) {
                        $missing = @(foreach ($name in $packOrderChoice.Packs) {
                            $relative = Join-Path 'resourcepacks' $name
                            if ($failedCopies.ContainsKey($relative) -or
                                !(Test-Path -LiteralPath (Join-Path $dst $relative))) { $name }
                        })
                        if ($missing.Count) {
                            $failed.Add("保留原资源包顺序，以下包未就绪：$($missing -join '、')")
                            continue
                        }
                    }
                    $applied++
                    $after = $after.Remove($edit.Offset, $edit.Length).Insert($edit.Offset, $edit.Value)
                }
                Write-Config (Join-Path $dst $group.Name) $before $after
                $done += $applied
            } catch { $failed.Add("$($group.Name)：$($_.Exception.Message)") }
        }
        if ($shaderName) {
            try {
                $relative = Join-Path 'shaderpacks' $shaderName
                if ($failedCopies.ContainsKey($relative)) { throw '对应光影复制失败。' }
                Assert-RegularPath (Join-Path $dst $relative)
                $encoded = -join $(foreach ($c in $shaderName.ToCharArray()) {
                    if ([int]$c -le 32 -or [int]$c -gt 126) { '\u{0:X4}' -f [int]$c }
                    else { [string]$c }
                })
                $hit = $rx.Match($shaderBefore)
                $line = $hit.Groups['prefix'].Value + $encoded
                $after = $shaderBefore.Remove($hit.Index, $hit.Length).Insert($hit.Index, $line)
                Write-Config $shaderPath $shaderBefore $after
                $done++
            } catch { $failed.Add("启用光影：$($_.Exception.Message)") }
        }
        $report = @("已完成 $done 项，失败 $($failed.Count) 项。") + @($failed)
        [void][Windows.Forms.MessageBox]::Show(($report -join "`r`n"), '迁移结果')
        $form.Close()
    } catch {
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, '迁移提示')
    } finally { $button.Enabled = $true }
})
[void]$form.ShowDialog()
