$ErrorActionPreference = 'Stop'
$main = Join-Path $PSScriptRoot 'GTNH-Migrate.ps1'
$translation = Join-Path $PSScriptRoot 'Translation.ps1'
$dist = [IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'dist')).FullName
$source = Join-Path $dist 'GTNH-Migrate-bundled.ps1'
[IO.File]::WriteAllText($source, ([IO.File]::ReadAllText($translation) + "`r`n" + [IO.File]::ReadAllText($main)), [Text.UTF8Encoding]::new($true))
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
$exe = Join-Path $dist 'GTNH-Migration-Assistant-v0.2-Windows.exe'
$launcher = @"
using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;

class Launcher {
    [STAThread]
    static int Main() {
        string dir = Path.Combine(Path.GetTempPath(), "GTNH-" + Guid.NewGuid().ToString("N"));
        try {
            Directory.CreateDirectory(dir);
            string script = Path.Combine(dir, "GTNH-Migrate.ps1");
            using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("MigrationScript"))
            using (Stream output = File.Create(script)) {
                if (input == null) throw new IOException("Embedded migration script is missing.");
                input.CopyTo(output);
            }
            string shell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var info = new ProcessStartInfo(shell, "-NoProfile -STA -ExecutionPolicy RemoteSigned -File \"" + script + "\"");
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            using (Process child = Process.Start(info)) {
                child.WaitForExit();
                if (child.ExitCode != 0)
                    MessageBox.Show("PowerShell exit code: " + child.ExitCode, "GTNH Migration Assistant");
                return child.ExitCode;
            }
        } catch (Exception ex) {
            MessageBox.Show(ex.Message, "GTNH Migration Assistant");
            return 1;
        } finally {
            // Remove only the script created by this launcher.
            try { File.Delete(Path.Combine(dir, "GTNH-Migrate.ps1")); Directory.Delete(dir); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
"@
$options = [CodeDom.Compiler.CompilerParameters]::new()
$options.GenerateExecutable = $true
$options.OutputAssembly = $exe
$options.CompilerOptions = '/target:winexe /optimize+ /resource:"' + $source + '",MigrationScript'
[void]$options.ReferencedAssemblies.Add('System.dll')
[void]$options.ReferencedAssemblies.Add('System.Windows.Forms.dll')
# GTNH-ICON: executable-v1
$appIcon = Join-Path $PSScriptRoot 'assets\gtnh-app.ico'
if (![IO.File]::Exists($appIcon)) { throw "Missing application icon: $appIcon" }
$options.CompilerOptions += ' /win32icon:"' + $appIcon + '"'
$compiler = [Microsoft.CSharp.CSharpCodeProvider]::new()
try {
    $result = $compiler.CompileAssemblyFromSource($options, $launcher)
    if ($result.Errors.HasErrors) { throw ($result.Errors -join "`n") }
} finally { $compiler.Dispose() }

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
$embedded = $assembly.GetManifestResourceStream('MigrationScript')
if ($null -eq $embedded) { throw 'EXE 缺少内置脚本。' }
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $actual = [BitConverter]::ToString($sha.ComputeHash($embedded)).Replace('-', '')
} finally { $sha.Dispose(); $embedded.Dispose() }
if ($actual -ne (Get-FileHash -LiteralPath $source).Hash) { throw '内置脚本与源码不一致。' }
$hash = (Get-FileHash -LiteralPath $exe).Hash
[IO.File]::WriteAllText("$exe.sha256", "$hash  $([IO.Path]::GetFileName($exe))`n")
"BUILD PASS: $exe"
