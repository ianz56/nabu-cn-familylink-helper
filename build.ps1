# Build script for Nabu CN System & Family Link Helper Magisk Module
# Run this in PowerShell from the project directory

$ModuleName = "nabu-global-helper"
$Version = "v2.0.0"
$ZipName = "$ModuleName-$Version.zip"
$ZipPath = Join-Path $PWD $ZipName

# Remove old zip if it exists
if (Test-Path $ZipPath) {
    Remove-Item $ZipPath
    Write-Host "Removed old $ZipName" -ForegroundColor Yellow
}

Write-Host "Building $ZipName ..." -ForegroundColor Cyan

# Use .NET ZipFile to preserve directory structure
Add-Type -AssemblyName System.IO.Compression.FileSystem

$filesToInclude = @(
    "module.prop",
    "service.sh",
    "action.sh",
    "auto_switch.sh",
    "customize.sh",
    "system.prop",
    "META-INF\com\google\android\update-binary",
    "META-INF\com\google\android\updater-script"
)

# Recursively add all files in 'system' folder
if (Test-Path "system") {
    $systemFiles = Get-ChildItem -Path "system" -Recurse -File | ForEach-Object {
        # Make the path relative to the module directory
        $_.FullName.Substring($PWD.Path.Length + 1)
    }
    $filesToInclude += $systemFiles
}

$zip = [System.IO.Compression.ZipFile]::Open($ZipPath, 'Create')

# Shell scripts that need Unix (LF) line endings for Android
$shellScripts = @("service.sh", "action.sh", "auto_switch.sh", "customize.sh")

foreach ($file in $filesToInclude) {
    $fullPath = Join-Path $PWD $file
    $entryName = $file.Replace([System.IO.Path]::DirectorySeparatorChar, [char]0x2F)

    # Convert CRLF to LF for shell scripts (Android requires Unix line endings)
    if ($shellScripts -contains (Split-Path $file -Leaf)) {
        $content = [System.IO.File]::ReadAllText($fullPath) -replace "`r`n", "`n"
        $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $stream = $entry.Open()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        Write-Host "  + $entryName (LF converted)" -ForegroundColor DarkCyan
    } else {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $fullPath, $entryName, [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
        Write-Host "  + $entryName" -ForegroundColor DarkGray
    }
}

$zip.Dispose()

if (Test-Path $ZipPath) {
    $size = (Get-Item $ZipPath).Length
    Write-Host ""
    Write-Host "Build successful!" -ForegroundColor Green
    Write-Host "Output: $ZipName ($size bytes)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Transfer the ZIP to your device and flash via Magisk Manager." -ForegroundColor White
} else {
    Write-Host "Build failed!" -ForegroundColor Red
    exit 1
}
