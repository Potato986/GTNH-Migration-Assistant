param([Parameter(Mandatory)][string]$ExePath)
$ErrorActionPreference = 'Stop'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Resolve-Path $ExePath).Path))
$stream = $assembly.GetManifestResourceStream('MigrationScript')
if (!$stream) { throw 'EXE 缺少内置脚本。' }
$reader = [IO.StreamReader]::new($stream)
try { $code = $reader.ReadToEnd() } finally { $reader.Dispose() }
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in 'Assert-RegularPath','Get-Tree','Copy-Verified','Read-Config','Write-Config') {
    $nodes = @($ast.FindAll({
        param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true))
    if ($nodes.Count -ne 1) { throw "内置脚本缺少唯一的函数：$name" }
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('gtnh-test-' + [guid]::NewGuid())
$src = Join-Path $root 'source'
$dst = Join-Path $root 'target'
$bytes = [Text.Encoding]::GetEncoding(28591)
try {
    foreach ($dir in $src,$dst) { [void][IO.Directory]::CreateDirectory($dir) }
    $relative = 'sample.bin'
    $original = Join-Path $src $relative
    $copy = Join-Path $dst $relative
    [IO.File]::WriteAllBytes($original, [byte[]](0,127,128,255))
    Copy-Verified $relative
    if ((Get-FileHash $original).Hash -ne (Get-FileHash $copy).Hash) { throw '文件复制校验失败。' }

    $options = Join-Path $dst 'options.txt'
    $before = "gamma:0`r`nfov:90`r`n"
    $after = "gamma:1`r`nfov:90`r`n"
    [IO.File]::WriteAllBytes($options, $bytes.GetBytes($before))
    $initial = (Get-FileHash $options).Hash
    Write-Config $options $before $after
    if ((Read-Config $options) -cne $after) { throw '配置写入结果不符。' }
    $backups = @(Get-ChildItem -LiteralPath $dst -File -Filter 'options.txt.*.bak')
    if ($backups.Count -ne 1) { throw '未找到唯一的配置备份。' }
    [IO.File]::Copy($backups[0].FullName, $options, $true)
    if ((Get-FileHash $options).Hash -ne $initial) { throw '备份恢复校验失败。' }
    'TEST PASS: embedded file copy, config write, backup restore'
} finally {
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
