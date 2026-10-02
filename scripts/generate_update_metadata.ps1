param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]] $Artifact
)

$ErrorActionPreference = 'Stop'

foreach ($artifactPath in $Artifact) {
    $file = Get-Item -LiteralPath $artifactPath -ErrorAction Stop
    if (-not $file.PSIsContainer -and
        (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
        if ($file.Name -notmatch '^[A-Za-z0-9._-]+\.(apk|exe|dmg)$') {
            throw "安装包文件名不符合发布契约：$($file.Name)"
        }
    } else {
        throw "安装包必须是普通文件，不能是目录或符号链接：$artifactPath"
    }

    # 用 .NET 直接算摘要，不依赖 Get-FileHash（它来自 Microsoft.PowerShell.Utility 模块，
    # 在 PSModulePath 被改写的终端里可能加载不到）
    $stream = [IO.File]::OpenRead($file.FullName)
    try {
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $algorithm.ComputeHash($stream)
        } finally {
            $algorithm.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    $digest = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    if ($digest -notmatch '^[a-f0-9]{64}$') {
        throw "无法生成有效的 SHA-256：$($file.FullName)"
    }

    $metadataPath = "$($file.FullName).sha256"
    $content = "$digest  $($file.Name)" + [Environment]::NewLine
    [IO.File]::WriteAllText($metadataPath, $content, [Text.Encoding]::ASCII)
    [Console]::WriteLine("已生成 SHA-256：$metadataPath")
}
