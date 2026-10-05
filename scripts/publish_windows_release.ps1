#requires -Version 5.1
# 保存为 UTF-8 with BOM，确保 Windows 自带的 PowerShell 5.1 正确读取中文。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:scriptDir = $PSScriptRoot
$script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Write-ReleaseLog([string] $Message) {
    [Console]::WriteLine("[时间块] $Message")
}

function Show-ReleaseUsage {
    [Console]::WriteLine(@'
用法：
  .\scripts\publish_windows_release.bat [选项]

默认行为：
  1. 在构建前检查 docs/release-notes.md 是否与线上最新 Release 重复；
  2. 获取依赖，次版本号 +1、patch 归零、构建号 +1；
  3. 构建 Windows x64 release，用 Inno Setup 6 打包到 dist/；
  4. 生成同名 .exe.sha256，只提交 pubspec.yaml 的版本号并推送上游；
  5. 创建或复用 <版本> Gitee Release，先传 SHA-256，再传 EXE。

默认跳过 flutter analyze 和 flutter test；需要检查时使用 --run-tests。
构建需要 Windows、Flutter（含 Visual Studio C++ 桌面开发环境）和 Inno Setup 6.3+。
（installer.iss 使用 6.3 引入的 x64compatible，并用无 BOM 的 UTF-8 保存中文。）
上传使用 PowerShell/.NET，无需安装 Bash、jq 或 curl。

选项：
  --artifact PATH          发布已有 time_manager_setup_<版本>.exe，自动跳过构建
  --skip-build             跳过构建，必须同时指定 --artifact
  --run-tests              构建前运行 flutter analyze 和 flutter test
  --skip-tests             显式跳过分析和测试（默认）
  --skip-bump              按 pubspec.yaml 当前版本构建，可给 Android 同一 Release 补 EXE
  --no-git                 不自动提交、推送版本号
  --dist-dir DIR           安装包输出目录，默认 <项目根>/dist
  --notes-file FILE        Release 说明，默认 docs/release-notes.md
  --allow-stale-notes      跳过说明查重；复用同一版本 Release 本来就不查重
  --iscc PATH              指定 Inno Setup 6.3+ 的 ISCC.exe
  --owner OWNER            覆盖 Gitee 用户名/组织名
  --repo REPO              覆盖发布仓库名
  --dry-run                只显示发布计划，不联网、不构建、不改文件
  -h, --help               显示帮助

环境变量：
  GITEE_TOKEN              未设置时读取 lib/config/diary_gitee_config.dart 的 hardcodedToken
  GITEE_OWNER              默认 zhou-jiaqi10
  GITEE_REPO               默认 time_manager_releases，与 UpdateService 保持一致
  GITEE_TARGET_COMMITISH   创建 Release 的目标分支，默认 master
  ISCC_PATH               可选，指定 ISCC.exe（也会搜索 PATH 和常用安装目录）

相对路径均以项目根目录为基准。构建失败或中断只回滚本次版本号修改；
构建成功后上传失败会保留安装包和版本号，可用 --artifact 重试。
'@)
}

function Resolve-ReleasePath([string] $Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $script:repoRoot $Path }
    return [IO.Path]::GetFullPath($Path)
}

function Get-AppVersion {
    $text = [IO.File]::ReadAllText($script:pubspecPath)
    $matches = [regex]::Matches($text, '(?m)^version:[ \t]*(?<version>(?<major>\d+)\.(?<minor>\d+)\.\d+\+(?<build>\d+))(?=[ \t]*(?:#[^\r\n]*)?\r?$)')
    if ($matches.Count -ne 1) { throw 'pubspec.yaml 必须有一个 major.minor.patch+build 格式的 version 字段' }
    $value = $matches[0].Groups['version'].Value
    $nextName = '{0}.{1}.0' -f $matches[0].Groups['major'].Value, ([long] $matches[0].Groups['minor'].Value + 1)
    return [pscustomobject] @{
        Value = $value
        Name = $value.Split('+')[0]
        Next = "$nextName+$([long] $matches[0].Groups['build'].Value + 1)"
    }
}

function Set-AppVersion([string] $Expected, [string] $NewVersion) {
    # 只替换版本值，保留原来的 BOM、换行、注释和所有其他内容。
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString([IO.File]::ReadAllBytes($script:pubspecPath))
    $pattern = '(?m)^version:[ \t]*(?<version>' + [regex]::Escape($Expected) + ')(?=[ \t]*(?:#[^\r\n]*)?\r?$)'
    $matches = [regex]::Matches($text, $pattern)
    if ($matches.Count -ne 1) { throw "版本号已被其他操作修改，不能将 $Expected 替换为 $NewVersion" }
    $group = $matches[0].Groups['version']
    $text = $text.Remove($group.Index, $group.Length).Insert($group.Index, $NewVersion)
    [IO.File]::WriteAllBytes($script:pubspecPath, $encoding.GetBytes($text))
}

function Get-JsonProperty($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-ReleaseToken {
    if (-not [string]::IsNullOrWhiteSpace($env:GITEE_TOKEN)) { return $env:GITEE_TOKEN.Trim() }
    $configPath = Join-Path $script:repoRoot 'lib/config/diary_gitee_config.dart'
    if (-not [IO.File]::Exists($configPath)) { throw '请设置 GITEE_TOKEN，或配置 lib/config/diary_gitee_config.dart' }
    $match = [regex]::Match([IO.File]::ReadAllText($configPath), 'static\s+const\s+String\s+hardcodedToken\s*=\s*([''"])(?<token>[^''"\r\n]+)\1\s*;')
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups['token'].Value)) {
        throw '本地 Gitee 配置没有可用的 hardcodedToken，请设置 GITEE_TOKEN'
    }
    return $match.Groups['token'].Value.Trim()
}

function New-GiteeClient {
    Add-Type -AssemblyName System.Net.Http
    # Windows PowerShell 5.1 默认协议可能不含 TLS 1.2。
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/json')
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('token', $script:giteeToken)
    return $client
}

function Invoke-GiteeApi([string] $Method, [string] $Endpoint, [hashtable] $Form, [string] $File) {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "$script:apiBase/$Endpoint")
    $response = $null
    $timeoutSeconds = 120
    if ($File) { $timeoutSeconds = 1800 }
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($timeoutSeconds))
    try {
        if ($File) {
            # 流式上传，避免把整个 Windows 安装包读入内存。
            $multipart = [Net.Http.MultipartFormDataContent]::new()
            $request.Content = $multipart
            $content = [Net.Http.StreamContent]::new([IO.File]::OpenRead($File))
            $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
            $multipart.Add($content, 'file', [IO.Path]::GetFileName($File))
        } elseif ($Form) {
            $values = [Collections.Generic.Dictionary[string,string]]::new()
            foreach ($key in $Form.Keys) { $values.Add($key, [string] $Form[$key]) }
            $request.Content = [Net.Http.FormUrlEncodedContent]::new($values)
        }
        $response = $script:client.SendAsync($request, $cancellation.Token).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $data = $null
        if (-not [string]::IsNullOrWhiteSpace($body)) {
            try { $data = ConvertFrom-Json -InputObject $body } catch {
                if ($response.IsSuccessStatusCode) { throw 'Gitee 返回的成功响应不是有效 JSON' }
            }
            if ($body.TrimStart().StartsWith('[')) {
                if ($null -eq $data) { $data = @() } else { $data = @($data) }
            }
        }
        return [pscustomobject] @{ Status = [int] $response.StatusCode; Data = $data; Body = $body }
    } catch {
        throw "Gitee 请求失败（$Method $Endpoint）：$($_.Exception.Message)"
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $cancellation.Dispose()
    }
}

function Assert-GiteeSuccess($Response) {
    if ($Response.Status -ge 200 -and $Response.Status -lt 300) { return }
    $message = Get-JsonProperty $Response.Data 'message'
    if (-not $message) { $message = Get-JsonProperty $Response.Data 'error' }
    if (-not $message) { $message = $Response.Body }
    throw "Gitee API 请求失败（HTTP $($Response.Status)）：$message"
}

function Get-GiteeCollection([string] $Endpoint) {
    $items = [Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le 100; $page++) {
        $response = Invoke-GiteeApi 'GET' "${Endpoint}?per_page=100&page=$page"
        Assert-GiteeSuccess $response
        if ($response.Data -isnot [array]) { throw "Gitee $Endpoint 响应不是列表" }
        foreach ($item in $response.Data) { $items.Add($item) }
        if ($response.Data.Count -lt 100) { return ,$items.ToArray() }
    }
    throw "Gitee $Endpoint 列表超过 100 页，已停止发布"
}

function Assert-FreshReleaseNotes([string] $Tag, [string] $Notes) {
    $releases = Get-GiteeCollection 'releases'
    $latest = $releases | Sort-Object -Property { Get-JsonProperty $_ 'created_at' } | Select-Object -Last 1
    $latestTag = [string] (Get-JsonProperty $latest 'tag_name')
    $latestBody = [string] (Get-JsonProperty $latest 'body')
    if (-not $latestTag -or -not $latestBody -or $latestTag -eq $Tag) { return }
    if (($latestBody -replace '\s', '') -ceq ($Notes -replace '\s', '')) {
        throw "Release 说明与线上最新版本（$latestTag）完全相同。请更新说明，或加 --allow-stale-notes"
    }
    Write-ReleaseLog "Release 说明查重通过（线上最新版本 $latestTag）"
}

function Get-ReleaseId($Data, [string] $Tag) {
    if ($Data -is [array]) {
        $Data = $Data | Where-Object { (Get-JsonProperty $_ 'tag_name') -eq $Tag } | Select-Object -First 1
    }
    $id = Get-JsonProperty $Data 'id'
    if (-not $id) { $id = Get-JsonProperty $Data 'release_id' }
    if (-not $id) { $id = Get-JsonProperty (Get-JsonProperty $Data 'data') 'id' }
    if ([string] $id -match '^[1-9][0-9]*$') { return [string] $id }
    return $null
}

function Get-OrCreateRelease([string] $Tag, [string] $Notes, [string] $Target) {
    Write-ReleaseLog "检查 Gitee Release：$Tag"
    $response = Invoke-GiteeApi 'GET' "releases/tags/$Tag"
    $id = $null
    if ($response.Status -eq 200) { $id = Get-ReleaseId $response.Data $Tag }
    elseif ($response.Status -ne 404) { Assert-GiteeSuccess $response }
    if (-not $id) { $id = Get-ReleaseId (Get-GiteeCollection 'releases') $Tag }
    if ($id) {
        Write-ReleaseLog "复用现有 Release：$Tag"
        return $id
    }
    Write-ReleaseLog "创建 Gitee Release：$Tag"
    $response = Invoke-GiteeApi 'POST' 'releases' -Form @{
        tag_name = $Tag; target_commitish = $Target; name = '时间块'; body = $Notes; prerelease = 'false'
    }
    Assert-GiteeSuccess $response
    $id = Get-ReleaseId $response.Data $Tag
    if (-not $id) { throw 'Gitee 创建 Release 成功，但响应没有有效的 Release ID' }
    return $id
}

function Send-ReleaseAsset([string] $ReleaseId, [string] $Path, [object[]] $Existing) {
    $name = [IO.Path]::GetFileName($Path)
    foreach ($asset in $Existing) {
        if ((Get-JsonProperty $asset 'name') -ceq $name) {
            Write-ReleaseLog "附件已存在，跳过上传：$name"
            return
        }
    }
    Write-ReleaseLog "上传附件：$name"
    $response = Invoke-GiteeApi 'POST' "releases/$ReleaseId/attach_files" -File $Path
    Assert-GiteeSuccess $response
    if ((Get-JsonProperty $response.Data 'name') -cne $name) { throw "Gitee 返回的附件名与 $name 不一致" }
}

function Invoke-ReleaseCommand([string] $Command, [string[]] $Arguments) {
    $PSNativeCommandUseErrorActionPreference = $false
    & $Command @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Command 执行失败（退出码 $LASTEXITCODE）" }
}

function ConvertTo-InnoCompilerVersion([string] $Value) {
    # 只取主次版本号；解析失败返回 $null。
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $match = [regex]::Match($Value, '^(\d+)\.(\d+)')
    if (-not $match.Success) { return $null }
    return [version] ($match.Groups[1].Value + '.' + $match.Groups[2].Value)
}

function Get-InnoCompilerVersion([string] $Path) {
    # 读取 ISCC.exe 的版本；读不到时返回 $null，交由调用方放行。
    $info = $null
    try { $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path) } catch { return $null }
    if ($null -eq $info) { return $null }
    foreach ($candidate in @($info.ProductVersion, $info.FileVersion)) {
        $version = ConvertTo-InnoCompilerVersion $candidate
        if ($null -ne $version) { return $version }
    }
    return $null
}

function Assert-InnoCompilerVersion([version] $Version, [string] $Path) {
    # installer.iss 依赖 6.3 引入的 x64compatible，且以无 BOM 的 UTF-8 保存中文；
    # 更早的版本会直接编译失败（或中文乱码）。
    if ($null -eq $Version) { return }
    $minimum = [version] '6.3'
    if ($Version -ge $minimum) { return }
    throw "Inno Setup $minimum 或更高版本是必需的（installer.iss 使用 x64compatible 与无 BOM 的 UTF-8），当前版本：$Version（$Path）"
}

function Find-InnoCompiler([string] $Path) {
    $resolved = $null
    if ($Path) {
        $resolved = Resolve-ReleasePath $Path
        if (-not [IO.File]::Exists($resolved)) { throw "找不到 Inno Setup 编译器：$resolved" }
    } else {
        $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
        if ($command) { $resolved = $command.Source }
        if (-not $resolved) {
            foreach ($directory in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
                if (-not $directory) { continue }
                foreach ($relative in @('Inno Setup 6/ISCC.exe', 'Programs/Inno Setup 6/ISCC.exe')) {
                    $candidate = Join-Path $directory $relative
                    if ([IO.File]::Exists($candidate)) { $resolved = $candidate; break }
                }
                if ($resolved) { break }
            }
        }
        if (-not $resolved) { throw '找不到 Inno Setup 6.3+，请安装后重试，或使用 --iscc 指定 ISCC.exe' }
    }
    $version = Get-InnoCompilerVersion $resolved
    Assert-InnoCompilerVersion $version $resolved
    return $resolved
}

function Assert-WindowsBuild {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows 构建必须在 Windows 电脑上运行' }
    if (-not (Get-Command 'flutter' -ErrorAction SilentlyContinue)) { throw '找不到 flutter，请将 Flutter SDK 加入 PATH' }
}

function Initialize-WindowsNuget {
    $path = Join-Path $script:repoRoot 'build/windows/x64/_deps/nuget-subbuild/nuget-populate-prefix/src/nuget.exe'
    if ([IO.File]::Exists($path)) { return }
    Write-ReleaseLog '下载 geolocator 构建所需的 nuget.exe'
    [void] [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $temporary = "$path.download"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri 'https://dist.nuget.org/win-x86-commandline/v6.0.0/nuget.exe' -OutFile $temporary -TimeoutSec 120
        if ((Get-Item -LiteralPath $temporary).Length -eq 0) { throw '下载的 nuget.exe 为空' }
        Move-Item -LiteralPath $temporary -Destination $path -Force
    } finally {
        if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Assert-CleanPubspec {
    if (-not (Get-Command 'git' -ErrorAction SilentlyContinue)) { throw '找不到 git；可使用 --no-git 跳过版本号提交' }
    $PSNativeCommandUseErrorActionPreference = $false
    $status = & git status --porcelain -- pubspec.yaml
    if ($LASTEXITCODE -ne 0) { throw '无法读取 Git 状态；可使用 --no-git 跳过版本号提交' }
    if ($status) { throw 'pubspec.yaml 有未提交改动，请先提交，或使用 --no-git，避免把其他修改带入版本提交' }
}

function Complete-VersionCommit([string] $Version) {
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    Write-ReleaseLog "只提交 pubspec.yaml 版本号：$Version"
    Invoke-ReleaseCommand 'git' @('commit', '-m', "chore: bump version to $Version", '--', 'pubspec.yaml')
    & git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-ReleaseLog '警告：当前分支没有上游，版本号已在本地提交，请稍后手动推送'
        return
    }
    & git push | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-ReleaseLog '警告：push 失败，版本号已在本地提交，请稍后手动执行 git push' }
}

function Assert-Installer([string] $Path, [string] $Version) {
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or $file.Length -eq 0) {
        throw "安装包必须是非空普通文件，不能是目录或符号链接：$Path"
    }
    $expectedName = "time_manager_setup_$Version.exe"
    if ($file.Name -cne $expectedName) { throw "安装包文件名必须与 pubspec.yaml 版本一致：$expectedName（实际：$($file.Name)）" }
}

function Invoke-WindowsRelease([string[]] $PublishArgs) {
    $script:pubspecPath = Join-Path $script:repoRoot 'pubspec.yaml'
    $script:client = $null
    $script:giteeToken = ''
    $owner = 'zhou-jiaqi10'
    $repo = 'time_manager_releases'
    $target = 'master'
    if ($env:GITEE_OWNER) { $owner = $env:GITEE_OWNER }
    if ($env:GITEE_REPO) { $repo = $env:GITEE_REPO }
    if ($env:GITEE_TARGET_COMMITISH) { $target = $env:GITEE_TARGET_COMMITISH }
    $dist = 'dist'
    $notesFile = 'docs/release-notes.md'
    $artifact = ''
    $isccPath = $env:ISCC_PATH
    $skipBuild = $false
    $runTests = $false
    $skipBump = $false
    $noGit = $false
    $allowStaleNotes = $false
    $dryRun = $false
    $bumped = $false
    $buildCompleted = $false
    $locationPushed = $false
    $originalProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        for ($i = 0; $i -lt $PublishArgs.Count; $i++) {
            $option = $PublishArgs[$i]
            if ($option -in @('--artifact', '--dist-dir', '--notes-file', '--iscc', '--owner', '--repo')) {
                if ($i + 1 -ge $PublishArgs.Count -or [string]::IsNullOrWhiteSpace($PublishArgs[$i + 1]) -or $PublishArgs[$i + 1].StartsWith('--')) {
                    throw "$option 需要一个值"
                }
                $i++
                $value = $PublishArgs[$i]
                switch ($option) {
                    '--artifact' { $artifact = $value; $skipBuild = $true }
                    '--dist-dir' { $dist = $value }
                    '--notes-file' { $notesFile = $value }
                    '--iscc' { $isccPath = $value }
                    '--owner' { $owner = $value }
                    '--repo' { $repo = $value }
                }
                continue
            }
            switch ($option) {
                '--skip-build' { $skipBuild = $true }
                '--run-tests' { $runTests = $true }
                '--skip-tests' { $runTests = $false }
                '--skip-bump' { $skipBump = $true }
                '--no-git' { $noGit = $true }
                '--allow-stale-notes' { $allowStaleNotes = $true }
                '--dry-run' { $dryRun = $true }
                { $_ -in @('-h', '--help') } { Show-ReleaseUsage; return }
                default { throw "未知选项：$option（使用 --help 查看用法）" }
            }
        }
        if ($owner -notmatch '^[A-Za-z0-9_.-]+$' -or $repo -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Gitee owner/repo 格式无效' }
        if ($skipBuild -and -not $artifact) { throw '--skip-build 必须同时通过 --artifact 指定 EXE' }
        $notesFile = Resolve-ReleasePath $notesFile
        if (-not [IO.File]::Exists($notesFile)) { throw "找不到 Release 说明文件：$notesFile" }
        $notes = [IO.File]::ReadAllText($notesFile)
        if ([string]::IsNullOrWhiteSpace($notes)) { throw "Release 说明不能为空：$notesFile" }
        $original = Get-AppVersion
        $version = $original.Value
        if (-not $skipBuild -and -not $skipBump) { $version = $original.Next }
        $tag = $version.Split('+')[0]
        $dist = Resolve-ReleasePath $dist
        if ($artifact) { $artifact = Resolve-ReleasePath $artifact }
        else { $artifact = Join-Path $dist "time_manager_setup_$tag.exe" }
        $script:apiBase = "https://gitee.com/api/v5/repos/$owner/$repo"
        if ($dryRun) {
            [Console]::WriteLine("当前版本：$($original.Value)`n发布版本：$version（Release tag：$tag）`nEXE：$artifact`n校验文件：$artifact.sha256`nGitee：$owner/$repo")
            return
        }
        if ($skipBuild) { Assert-Installer $artifact $tag }
        else {
            Assert-WindowsBuild
            $iscc = Find-InnoCompiler $isccPath
        }
        Push-Location -LiteralPath $script:repoRoot
        $locationPushed = $true
        if (-not $skipBuild -and -not $skipBump -and -not $noGit) { Assert-CleanPubspec }
        $script:giteeToken = Get-ReleaseToken
        $script:client = New-GiteeClient
        if (-not $allowStaleNotes) { Assert-FreshReleaseNotes $tag $notes }
        if (-not $skipBuild) {
            Initialize-WindowsNuget
            Invoke-ReleaseCommand 'flutter' @('pub', 'get')
            if ($runTests) {
                Invoke-ReleaseCommand 'flutter' @('analyze')
                Invoke-ReleaseCommand 'flutter' @('test', '--reporter', 'compact')
            }
            if (-not $skipBump) {
                Write-ReleaseLog "版本号自增：$($original.Value) → $version"
                Set-AppVersion $original.Value $version
                $bumped = $true
            }
            Invoke-ReleaseCommand 'flutter' @('build', 'windows', '--release', '--target-platform', 'windows-x64')
            if (-not [IO.File]::Exists((Join-Path $script:repoRoot 'build/windows/x64/runner/Release/time_manager.exe'))) {
                throw 'Windows 构建完成，但找不到 build/windows/x64/runner/Release/time_manager.exe'
            }
            [void] [IO.Directory]::CreateDirectory($dist)
            # 只检查本次版本的产物，不能误用 installer_output 中的旧 EXE。
            if ([IO.File]::Exists($artifact)) { Remove-Item -LiteralPath $artifact -Force }
            Invoke-ReleaseCommand $iscc @("/DMyAppVersion=$tag", "/O$dist", "/Ftime_manager_setup_$tag", (Join-Path $script:scriptDir 'installer.iss'))
        }
        Assert-Installer $artifact $tag
        & (Join-Path $script:scriptDir 'generate_update_metadata.ps1') $artifact
        $buildCompleted = $true
        if ($bumped -and -not $noGit) { Complete-VersionCommit $version }
        $id = Get-OrCreateRelease $tag $notes $target
        $assets = Get-GiteeCollection "releases/$id/attach_files"
        Send-ReleaseAsset $id "$artifact.sha256" $assets
        Send-ReleaseAsset $id $artifact $assets
        Write-ReleaseLog 'Windows 发布完成'
        Write-ReleaseLog "Release：https://gitee.com/$owner/$repo/releases/tag/$tag"
        Write-ReleaseLog "版本：$version"
        Write-ReleaseLog "EXE：$artifact"
    } finally {
        try {
            if ($bumped -and -not $buildCompleted) {
                Write-ReleaseLog "构建失败或中断，回滚版本号到 $($original.Value)"
                Set-AppVersion $version $original.Value
            }
        } finally {
            if ($null -ne $script:client) { $script:client.Dispose() }
            [Net.ServicePointManager]::SecurityProtocol = $originalProtocol
            if ($locationPushed) { Pop-Location }
        }
    }
}

try {
    Invoke-WindowsRelease -PublishArgs @($args)
} catch {
    $message = $_.Exception.Message
    # Gitee 的错误正文也不允许把 Token 回显到日志。
    if ($script:giteeToken) { $message = $message.Replace($script:giteeToken, '[REDACTED]') }
    [Console]::Error.WriteLine("[错误] $message")
    exit 1
}
