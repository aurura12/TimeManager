#requires -Version 5.1
# 无需 Pester；模拟构建和 HTTP，不联网、不发布、不操作真实 Git 仓库。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Net.Http

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptPath = Join-Path $projectRoot 'scripts/publish_windows_release.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# 只加载函数，避免执行真实脚本入口；核心发布编排与 HTTP 实现仍使用原代码。
$definitions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"))

$referenceAssemblies = @('System.Net.Http', 'System', 'System.Core')
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $referenceAssemblies = @('System.Net.Http', 'System.Net.Primitives', 'System.Collections', 'System.Runtime')
}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class RecordedReleaseRequest {
    public string Method;
    public string Url;
    public string Body;
    public string FileName;
    public string Authorization;
}

public sealed class FakeReleaseHandler : HttpMessageHandler {
    public readonly Queue<Tuple<int, string>> Responses = new Queue<Tuple<int, string>>();
    public readonly List<RecordedReleaseRequest> Requests = new List<RecordedReleaseRequest>();
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
        var recorded = new RecordedReleaseRequest();
        recorded.Method = request.Method.Method;
        recorded.Url = request.RequestUri.ToString();
        recorded.Authorization = request.Headers.Authorization == null ? "" : request.Headers.Authorization.ToString();
        recorded.Body = request.Content == null ? "" : await request.Content.ReadAsStringAsync();
        var multipart = request.Content as MultipartFormDataContent;
        if (multipart != null) {
            foreach (var content in multipart) {
                if (content.Headers.ContentDisposition.Name.Trim('"') != "file") throw new Exception("wrong multipart field");
                recorded.FileName = content.Headers.ContentDisposition.FileName.Trim('"');
            }
        }
        Requests.Add(recorded);
        if (Responses.Count == 0) throw new Exception("Unexpected HTTP request: " + recorded.Url);
        var queued = Responses.Dequeue();
        var response = new HttpResponseMessage((HttpStatusCode)queued.Item1);
        response.Content = new StringContent(queued.Item2, System.Text.Encoding.UTF8, "application/json");
        return response;
    }
}
'@ -ReferencedAssemblies $referenceAssemblies

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("time-manager-windows-release-test-" + [Guid]::NewGuid().ToString('N'))
$savedEnvironment = @{}
foreach ($key in @('GITEE_TOKEN', 'GITEE_OWNER', 'GITEE_REPO', 'GITEE_TARGET_COMMITISH', 'ISCC_PATH')) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
}
$testCount = 0

function Assert-Equal($Expected, $Actual, [string] $Message) {
    if ($Expected -cne $Actual) { throw "$Message (expected: $Expected, actual: $Actual)" }
}

function Assert-True([bool] $Value, [string] $Message) {
    if (-not $Value) { throw $Message }
}

function Assert-Fails([scriptblock] $Action, [string] $MessagePattern) {
    $failure = $null
    try { & $Action } catch { $failure = $_.Exception.Message }
    if ($null -eq $failure -or $failure -notmatch $MessagePattern) { throw "Expected failure '$MessagePattern', got '$failure'" }
}

function Read-PubspecBytes { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:pubspecPath)) }

function Reset-Fixture {
    $script:repoRoot = Join-Path $testRoot ("项目 with spaces " + [Guid]::NewGuid().ToString('N'))
    $script:scriptDir = Join-Path $script:repoRoot 'scripts'
    $script:pubspecPath = Join-Path $script:repoRoot 'pubspec.yaml'
    foreach ($directory in @('scripts', 'docs', 'lib/config')) { [void] [IO.Directory]::CreateDirectory((Join-Path $script:repoRoot $directory)) }
    foreach ($file in @('generate_update_metadata.ps1', 'installer.iss')) {
        [IO.File]::Copy((Join-Path $projectRoot "scripts/$file"), (Join-Path $script:scriptDir $file))
    }
    [IO.File]::WriteAllText($script:pubspecPath, "name: time_manager`r`nversion: 1.114.3+32 # 保留注释`r`ndescription: 测试`r`n", [Text.UTF8Encoding]::new($true))
    $script:notes = "本次更新：`r`n`r`n- Windows 发布测试。`r`n"
    [IO.File]::WriteAllText((Join-Path $script:repoRoot 'docs/release-notes.md'), $script:notes, [Text.UTF8Encoding]::new($false))
    $env:GITEE_TOKEN = 'dummy-release-token'
    $env:GITEE_OWNER = 'test-owner'
    $env:GITEE_REPO = 'test-releases'
    $env:GITEE_TARGET_COMMITISH = 'release-branch'
    $env:ISCC_PATH = ''
    $script:handler = [FakeReleaseHandler]::new()
    $script:commands = [Collections.Generic.List[object]]::new()
    $script:logs = [Collections.Generic.List[string]]::new()
    $script:failCommand = ''
    $script:dirtyPubspec = $false
    $script:noUpstream = $false
    $script:pushFails = $false
    $script:apiBase = 'https://gitee.com/api/v5/repos/test-owner/test-releases'
    $script:giteeToken = ''
    $script:client = $null
}

function Add-Response([int] $Status, [string] $Body) { $script:handler.Responses.Enqueue([Tuple]::Create($Status, $Body)) }

function Add-NotesResponse([string] $Body = '不同的旧版说明', [string] $Tag = '1.113.0') {
    Add-Response 200 (ConvertTo-Json -Compress -InputObject @(@{ tag_name = $Tag; created_at = '2026-10-01T12:00:00Z'; body = $Body }))
}

function Add-NewReleaseResponses([string] $Version = '1.115.0') {
    Add-Response 404 '{"message":"Not Found Release"}'
    Add-Response 200 '[]'
    Add-Response 201 '{"id":999}'
    Add-Response 200 '[]'
    Add-Response 201 "{`"name`":`"time_manager_setup_$Version.exe.sha256`"}"
    Add-Response 201 "{`"name`":`"time_manager_setup_$Version.exe`"}"
}

function New-GiteeClient {
    $client = [Net.Http.HttpClient]::new($script:handler)
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('token', $script:giteeToken)
    return $client
}

function Write-ReleaseLog([string] $Message) { $script:logs.Add($Message) }
function Assert-WindowsBuild { }
function Find-InnoCompiler([string] $Path) { return Join-Path $script:repoRoot 'tools/iscc.exe' }
function Initialize-WindowsNuget { }

function Invoke-ReleaseCommand([string] $Command, [string[]] $Arguments) {
    $script:commands.Add([pscustomobject] @{ Command = $Command; Arguments = $Arguments; Version = (Get-AppVersion).Value })
    $key = "$Command $($Arguments[0])"
    if ($key -eq $script:failCommand -or ([IO.Path]::GetFileName($Command) -eq $script:failCommand)) { throw "mock failure: $script:failCommand" }
    if ($Command -eq 'flutter' -and $Arguments[0] -eq 'build') {
        $directory = Join-Path $script:repoRoot 'build/windows/x64/runner/Release'
        [void] [IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText((Join-Path $directory 'time_manager.exe'), 'fake-flutter-release')
    }
    if ([IO.Path]::GetFileName($Command) -eq 'iscc.exe') {
        $outputDir = ($Arguments | Where-Object { $_.StartsWith('/O') }).Substring(2)
        $outputName = ($Arguments | Where-Object { $_.StartsWith('/F') }).Substring(2)
        [IO.File]::WriteAllText((Join-Path $outputDir "$outputName.exe"), 'release-payload')
    }
}

function git {
    $script:commands.Add([pscustomobject] @{ Command = 'git'; Arguments = @($args); Version = (Get-AppVersion).Value })
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'status' { if ($script:dirtyPubspec) { ' M pubspec.yaml' } }
        'rev-parse' { if ($script:noUpstream) { $global:LASTEXITCODE = 1 } else { 'origin/master' } }
        'push' { if ($script:pushFails) { $global:LASTEXITCODE = 1 } }
        default { throw "unexpected git command: $args" }
    }
}

function New-ExistingInstaller([string] $Version = '1.114.3') {
    $directory = Join-Path $script:repoRoot 'existing packages'
    [void] [IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory "time_manager_setup_$Version.exe"
    [IO.File]::WriteAllText($path, 'existing-installer-payload')
    return $path
}

function Assert-Uploads([string] $ExpectedNames) {
    $names = @($script:handler.Requests | Where-Object { $_.FileName } | ForEach-Object { $_.FileName }) -join ','
    Assert-Equal $ExpectedNames $names 'upload order / uploaded files'
    Assert-Equal 0 $script:handler.Responses.Count 'all expected HTTP requests must occur'
    foreach ($request in $script:handler.Requests) { Assert-Equal 'token dummy-release-token' $request.Authorization 'HTTP authentication' }
}

function Pass([string] $Name) { $script:testCount++; [Console]::WriteLine("PASS: $Name") }

try {
    Reset-Fixture
    $before = Read-PubspecBytes
    Invoke-WindowsRelease @('--dry-run')
    Invoke-WindowsRelease @('--dry-run', '--skip-bump', '--dist-dir', 'custom output')
    Assert-Equal $before (Read-PubspecBytes) 'dry-run must preserve the pubspec bytes'
    Assert-Equal 0 $script:commands.Count 'dry-run must not run commands'
    Assert-Equal 0 $script:handler.Requests.Count 'dry-run must not access the network'
    Assert-True (-not [IO.Directory]::Exists((Join-Path $script:repoRoot 'dist'))) 'dry-run must not create output'
    Pass 'dry-run has no side effects'

    Reset-Fixture
    Add-NotesResponse
    Add-NewReleaseResponses
    Invoke-WindowsRelease @('--run-tests')
    Assert-Equal '1.115.0+33' (Get-AppVersion).Value 'version bump'
    $sequence = @($script:commands | ForEach-Object { "$([IO.Path]::GetFileName($_.Command)) $($_.Arguments -join ' ')" }) -join "`n"
    Assert-True ($sequence -match 'flutter pub get\nflutter analyze\nflutter test --reporter compact\nflutter build windows --release --target-platform windows-x64') 'checks must precede the build'
    $compiler = $script:commands | Where-Object { $_.Command.EndsWith('iscc.exe') }
    Assert-True ($compiler.Arguments -contains '/DMyAppVersion=1.115.0') 'installer version must match the app version'
    $commit = $script:commands | Where-Object { $_.Command -eq 'git' -and $_.Arguments[0] -eq 'commit' }
    Assert-Equal 'commit,-m,chore: bump version to 1.115.0+33,--,pubspec.yaml' ($commit.Arguments -join ',') 'commit only pubspec.yaml'
    Assert-True ($sequence -match 'git push') 'push to upstream'
    $create = $script:handler.Requests | Where-Object { $_.Method -eq 'POST' -and $_.Url.EndsWith('/releases') }
    $form = [Uri]::UnescapeDataString($create.Body.Replace('+', ' '))
    Assert-True ($form.Contains('tag_name=1.115.0') -and $form.Contains('name=时间块') -and $form.Contains('target_commitish=release-branch') -and $form.Contains($script:notes)) 'release form must preserve Chinese notes and use the final version'
    Assert-Uploads 'time_manager_setup_1.115.0.exe.sha256,time_manager_setup_1.115.0.exe'
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('release-payload'))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    Assert-Equal "$digest  time_manager_setup_1.115.0.exe" ([IO.File]::ReadAllText((Join-Path $script:repoRoot 'dist/time_manager_setup_1.115.0.exe.sha256')).Trim()) 'checksum matches uploaded installer'
    Pass 'full build, checks, version commit, UTF-8 release notes and upload order'

    Reset-Fixture
    Add-NotesResponse
    Add-NewReleaseResponses
    Invoke-WindowsRelease @('--no-git', '--run-tests', '--skip-tests', '--dist-dir', 'custom output')
    Assert-Equal 0 @($script:commands | Where-Object { $_.Command -eq 'git' -or $_.Arguments[0] -in @('analyze', 'test') }).Count 'no-git and skip-tests'
    Assert-True ([IO.File]::Exists((Join-Path $script:repoRoot 'custom output/time_manager_setup_1.115.0.exe'))) 'custom output path'
    Assert-Uploads 'time_manager_setup_1.115.0.exe.sha256,time_manager_setup_1.115.0.exe'
    Pass 'skip-tests / no-git / output path with spaces'

    Reset-Fixture
    $before = Read-PubspecBytes
    Add-NotesResponse ($script:notes -replace '\s', '')
    Assert-Fails { Invoke-WindowsRelease @() } '完全相同'
    Assert-Equal $before (Read-PubspecBytes) 'stale notes must not change version'
    Assert-Equal 1 $script:commands.Count 'only the read-only git preflight may run'
    Assert-Equal 'status' $script:commands[0].Arguments[0] 'no build or commit before notes guard'
    Assert-Equal 1 $script:handler.Requests.Count 'notes guard must stop before release mutation'
    Pass 'stale notes stop before build and version bump'

    Reset-Fixture
    Add-NotesResponse $script:notes '1.114.3'
    Add-Response 200 '[]'
    Add-Response 200 '[{"id":222,"tag_name":"1.114.3"}]'
    Add-Response 200 '[{"name":"android-release.apk"},{"name":"time_manager_setup_1.114.3.exe.sha256"}]'
    Add-Response 201 '{"name":"time_manager_setup_1.114.3.exe"}'
    Invoke-WindowsRelease @('--skip-bump')
    Assert-Equal '1.114.3+32' (Get-AppVersion).Value 'reuse Android release version'
    Assert-Equal 0 @($script:commands | Where-Object { $_.Command -eq 'git' }).Count 'skip-bump must not commit or push'
    Assert-Equal 0 @($script:handler.Requests | Where-Object { $_.Method -eq 'POST' -and $_.Url.EndsWith('/releases') }).Count 'reuse existing release via list fallback'
    Assert-Uploads 'time_manager_setup_1.114.3.exe'
    Pass 'reuse same release, empty tag response fallback, preserve other platform assets'

    Reset-Fixture
    $artifact = New-ExistingInstaller
    Add-Response 200 '{"data":{"id":222}}'
    Add-Response 200 '[{"name":"time_manager_setup_1.114.3.exe.sha256"},{"name":"time_manager_setup_1.114.3.exe"}]'
    Invoke-WindowsRelease @('--artifact', 'existing packages/time_manager_setup_1.114.3.exe', '--allow-stale-notes')
    Assert-Equal 0 $script:commands.Count 'artifact upload must not build or commit'
    Assert-True ([IO.File]::Exists("$artifact.sha256")) 'metadata for existing installer'
    Assert-Uploads ''
    Pass 'existing artifact, token-safe tag wrapper, duplicate assets skipped'

    foreach ($failure in @('flutter build', 'iscc.exe', 'flutter pub')) {
        Reset-Fixture
        $before = Read-PubspecBytes
        $script:failCommand = $failure
        Add-NotesResponse
        Assert-Fails { Invoke-WindowsRelease @('--no-git') } 'mock failure'
        Assert-Equal $before (Read-PubspecBytes) 'failed build must restore exact BOM, CRLF and comment bytes'
        Assert-Equal 1 $script:handler.Requests.Count 'failed build must not mutate remote release'
        Pass "failure rollback: $failure"
    }

    Reset-Fixture
    Add-NotesResponse
    Add-Response 404 '{}'
    Add-Response 200 '[]'
    Add-Response 201 '{"release_id":999}'
    Add-Response 200 '[]'
    Add-Response 503 '{"message":"upload unavailable"}'
    Assert-Fails { Invoke-WindowsRelease @('--no-git') } 'HTTP 503'
    Assert-Equal '1.115.0+33' (Get-AppVersion).Value 'upload failure must retain built version'
    Assert-True ([IO.File]::Exists((Join-Path $script:repoRoot 'dist/time_manager_setup_1.115.0.exe'))) 'retain installer for retry'
    Assert-Uploads 'time_manager_setup_1.115.0.exe.sha256'
    Pass 'checksum upload failure blocks EXE upload, retains successful build'

    Reset-Fixture
    $artifact = New-ExistingInstaller
    Add-Response 200 '{"id":999}'
    Add-Response 200 '[]'
    Add-Response 201 '{"name":"wrong.exe.sha256"}'
    Assert-Fails { Invoke-WindowsRelease @('--artifact', $artifact, '--allow-stale-notes') } '附件名'
    Assert-Uploads 'time_manager_setup_1.114.3.exe.sha256'
    Pass 'unexpected checksum asset response blocks EXE upload'

    foreach ($response in @(@(401, '{"message":"unauthorized"}', 'HTTP 401'), @(200, 'not json', 'JSON'))) {
        Reset-Fixture
        $before = Read-PubspecBytes
        Add-Response $response[0] $response[1]
        Assert-Fails { Invoke-WindowsRelease @('--no-git') } $response[2]
        Assert-Equal $before (Read-PubspecBytes) 'bad preflight HTTP must not change version'
        Assert-Equal 0 $script:commands.Count 'bad preflight HTTP must not build'
        Pass "preflight error: $($response[2])"
    }

    Reset-Fixture
    $artifact = New-ExistingInstaller '1.113.0'
    Assert-Fails { Invoke-WindowsRelease @('--artifact', $artifact) } '版本一致'
    Assert-Equal 0 $script:handler.Requests.Count 'reject wrong artifact version without network access'
    Pass 'reject installer version mismatch'

    Reset-Fixture
    $script:dirtyPubspec = $true
    Assert-Fails { Invoke-WindowsRelease @() } 'pubspec.yaml 有未提交改动'
    Assert-Equal 0 $script:handler.Requests.Count 'dirty pubspec must stop before network'
    Pass 'prevent unrelated pubspec edits in auto commit'

    foreach ($arguments in @(@('--artifact'), @('--artifact', '--dry-run'), @('--skip-build'), @('--bad-flag'))) {
        Reset-Fixture
        Assert-Fails { Invoke-WindowsRelease $arguments } '需要一个值|指定 EXE|未知选项'
        Assert-Equal 0 $script:handler.Requests.Count 'invalid arguments must not access network'
    }
    Pass 'missing option values and unknown flags'

    Reset-Fixture
    $artifact = New-ExistingInstaller
    $page = @(1..100 | ForEach-Object { @{ id = $_; tag_name = "old-$_" } })
    Add-Response 200 '{}'
    Add-Response 200 (ConvertTo-Json -Compress -InputObject $page)
    Add-Response 200 '[{"id":222,"tag_name":"1.114.3"}]'
    $assets = @(1..100 | ForEach-Object { @{ name = "old-$_.exe" } })
    Add-Response 200 (ConvertTo-Json -Compress -InputObject $assets)
    Add-Response 200 '[{"name":"time_manager_setup_1.114.3.exe.sha256"}]'
    Add-Response 201 '{"name":"time_manager_setup_1.114.3.exe"}'
    Invoke-WindowsRelease @('--artifact', $artifact, '--allow-stale-notes')
    Assert-Uploads 'time_manager_setup_1.114.3.exe'
    Assert-Equal 2 @($script:handler.Requests | Where-Object { $_.Url.Contains('page=2') }).Count 'paginate releases and assets'
    Pass 'release and asset pagination'

    foreach ($warning in @('noUpstream', 'pushFails')) {
        Reset-Fixture
        Set-Variable -Name $warning -Value $true -Scope Script
        Add-NotesResponse
        Add-NewReleaseResponses
        Invoke-WindowsRelease @()
        Assert-True (@($script:logs | Where-Object { $_.Contains('警告：') }).Count -gt 0) 'git push problems must be visible'
        Assert-Uploads 'time_manager_setup_1.115.0.exe.sha256,time_manager_setup_1.115.0.exe'
        Pass "git warning: $warning"
    }

    Reset-Fixture
    $configPath = Join-Path $script:repoRoot 'lib/config/diary_gitee_config.dart'
    [IO.File]::WriteAllText($configPath, "class DiaryGiteeConfig {`n static const String hardcodedToken =`n   'local-test-token';`n}")
    Assert-Equal 'dummy-release-token' (Get-ReleaseToken) 'environment token takes priority'
    $env:GITEE_TOKEN = ''
    Assert-Equal 'local-test-token' (Get-ReleaseToken) 'multiline local token fallback'
    [IO.File]::WriteAllText($configPath, 'static const String hardcodedToken = "double-quoted-token";')
    Assert-Equal 'double-quoted-token' (Get-ReleaseToken) 'double quoted token'
    [IO.File]::WriteAllText($configPath, 'static const String hardcodedToken = "";')
    Assert-Fails { Get-ReleaseToken } '没有可用的 hardcodedToken'
    Pass 'token precedence and local config fallback'

    Reset-Fixture
    & {
        $definition = $definitions | Where-Object { $_.Name -eq 'Invoke-ReleaseCommand' }
        . ([scriptblock]::Create($definition.Extent.Text))
        $executable = (Get-Process -Id $PID).Path
        Assert-Fails { Invoke-ReleaseCommand $executable @('-NoProfile', '-Command', 'exit 7') } '退出码 7'
    }
    Pass 'native command exit code propagates as failure'

    Reset-Fixture
    & {
        $definition = $definitions | Where-Object { $_.Name -eq 'Initialize-WindowsNuget' }
        . ([scriptblock]::Create($definition.Extent.Text))
        $script:downloadFails = $true
        $script:downloadCount = 0
        function Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec, [switch] $UseBasicParsing)
            $script:downloadCount++
            [IO.File]::WriteAllText($OutFile, 'fake-nuget-download')
            if ($script:downloadFails) { throw 'mock download failure' }
        }
        $path = Join-Path $script:repoRoot 'build/windows/x64/_deps/nuget-subbuild/nuget-populate-prefix/src/nuget.exe'
        Assert-Fails { Initialize-WindowsNuget } 'download failure'
        Assert-True (-not [IO.File]::Exists($path) -and -not [IO.File]::Exists("$path.download")) 'partial NuGet download must not survive failure'
        $script:downloadFails = $false
        Initialize-WindowsNuget
        Assert-True ([IO.File]::Exists($path)) 'retry produces nuget.exe'
        Initialize-WindowsNuget
        Assert-Equal 2 $script:downloadCount 'reuse existing nuget.exe'
    }
    Pass 'NuGet download failure cleanup and retry'

    Reset-Fixture
    Assert-Fails { Assert-InnoCompilerVersion ([version] '6.2.0') 'ISCC.exe' } 'Inno Setup'
    Assert-Fails { Assert-InnoCompilerVersion ([version] '5.6.1') 'ISCC.exe' } 'Inno Setup'
    Assert-InnoCompilerVersion ([version] '6.3.0') 'ISCC.exe'
    Assert-InnoCompilerVersion ([version] '7.0.0') 'ISCC.exe'
    # 读不到版本时不能阻塞构建（自编译或非标准 ISCC）
    Assert-InnoCompilerVersion $null 'ISCC.exe'
    Assert-Equal ([version] '6.2') (ConvertTo-InnoCompilerVersion '6.2.2.0') 'parse product version'
    Assert-Equal ([version] '6.3') (ConvertTo-InnoCompilerVersion '6.3.3 (abc)') 'parse version with suffix'
    Assert-Equal $null (ConvertTo-InnoCompilerVersion '') 'empty version'
    Assert-Equal $null (ConvertTo-InnoCompilerVersion 'not-a-version') 'unparsable version'
    Pass 'require Inno Setup 6.3+ but tolerate unknown versions'

    foreach ($file in @('publish_windows_release.ps1', 'generate_update_metadata.ps1')) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $projectRoot "scripts/$file"))
        Assert-Equal 'EF-BB-BF' ([BitConverter]::ToString($bytes[0..2])) 'PowerShell 5.1 Chinese script encoding'
    }
    Pass 'UTF-8 BOM for Windows PowerShell 5.1'

    [Console]::WriteLine("Windows release script tests passed ($testCount cases)")
} finally {
    if ($null -ne $script:client) { $script:client.Dispose() }
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key]) }
}
