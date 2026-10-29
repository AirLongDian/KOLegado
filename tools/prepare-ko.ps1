param(
    [string]$Runtime = "$PSScriptRoot/../work/koreader-runtime",
    [string]$Donor = "$PSScriptRoot/../work/koreader-donor",
    [string]$Ndk = "$PSScriptRoot/../work/toolchain/android-ndk-r23c"
)
$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path "$PSScriptRoot/..").Path
$taskRuntime = (Resolve-Path $Runtime).Path
$taskDonor = (Resolve-Path $Donor).Path
$taskAssets = "$taskRoot/app/src/main/assets"
$taskLib = "$taskRoot/app/src/main/jniLibs/armeabi-v7a"
New-Item -ItemType Directory -Force -Path $taskAssets, $taskLib | Out-Null

# Keep upstream script dependencies and KOReader plugins intact. Exclude quickstart and unused translations.
# This is an installation archive of code/fonts, never a chapter export.
Add-Type -AssemblyName System.IO.Compression
$taskZipPath = "$taskAssets/ko-runtime.zip"
$taskStream = [IO.File]::Open($taskZipPath, [IO.FileMode]::Create)
$taskArchive = [IO.Compression.ZipArchive]::new($taskStream, [IO.Compression.ZipArchiveMode]::Create)
function Add-KoFile([string]$Path, [string]$Name) {
    $entry = $taskArchive.CreateEntry($Name, [IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = [DateTimeOffset]::new(2022, 6, 1, 0, 0, 0, [TimeSpan]::Zero)
    $inputStream = [IO.File]::OpenRead($Path)
    $outputStream = $entry.Open()
    try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
}
try {
    Get-ChildItem -LiteralPath $taskRuntime -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($taskRuntime.Length + 1).Replace('\', '/')
        if ($relative -match '^(resources/quickstart/|l10n/(?!zh_CN/))') { return }
        if ($relative -in @('reader.lua', 'llapp_main.lua', 'afterupdate.marker', 'datastorage.lua')) { return }
        Add-KoFile $_.FullName $relative
    }
    Get-ChildItem -LiteralPath "$taskDonor/assets/libs" -File | Sort-Object Name | ForEach-Object {
        Add-KoFile $_.FullName ('libs/' + $_.Name)
    }
    Add-KoFile "$taskRoot/ko/legado.lua" 'legado.lua'
    Add-KoFile "$taskRoot/ko/COPYING.koreader" 'COPYING'
    Add-KoFile "$taskRoot/ko/LICENSE.launcher" 'LICENSE.launcher'
} finally { $taskArchive.Dispose(); $taskStream.Dispose() }
$taskHash = (Get-FileHash -LiteralPath $taskZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$taskAssets/ko-runtime.version", $taskHash, [Text.Encoding]::ASCII)
Copy-Item -LiteralPath "$taskDonor/lib/armeabi-v7a/libluajit.so" -Destination $taskLib
Push-Location $taskRoot
try {
    & "$Ndk/toolchains/llvm/prebuilt/windows-x86_64/bin/armv7a-linux-androideabi19-clang.cmd" `
        -shared -fPIC -O2 '-Wl,-soname,libluajit-launcher.so' '-Wl,--no-undefined' `
        -Iapp/src/main/cpp/glue app/src/main/cpp/main.c app/src/main/cpp/glue/android_native_app_glue.c `
        -o app/src/main/jniLibs/armeabi-v7a/libluajit-launcher.so -landroid -llog -ldl
    if ($LASTEXITCODE -ne 0) { throw 'Native launcher compilation failed' }
    & "$Ndk/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe" --strip-unneeded `
        app/src/main/jniLibs/armeabi-v7a/libluajit-launcher.so
    if ($LASTEXITCODE -ne 0) { throw 'Native launcher stripping failed' }
} finally { Pop-Location }
Get-Item -LiteralPath $taskZipPath | Select-Object Name, Length
