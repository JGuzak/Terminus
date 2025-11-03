param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$OutputDir,
    [Parameter(Mandatory=$false, Position=2)]
    [switch]$NoLog,
    [Parameter(Mandatory=$false, Position=3)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$SrcDir = Join-Path (Get-Location) "src"
if (-not (Test-Path $SrcDir)) { Write-Host "Error: Source directory '$SrcDir' not found." -ForegroundColor Red; exit 1 }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not $NoLog) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $LogFile = Join-Path $OutputDir ("extract_log_$timestamp.log")
}



function Log {
    param([string]$Message, [ConsoleColor]$Color="Gray")
    $t = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$t] $Message"
    Write-Host $line -ForegroundColor $Color
    if (-not $NoLog) { $line | Out-File -FilePath $LogFile -Append -Encoding utf8 }
}
function LogError {
    param([string]$Message)
    Log $Message "Red"
}

Log "Scanning for leaf project folders under: $SrcDir" "Cyan"

# Find leaf project folders
$projectDirs = Get-ChildItem -Path $SrcDir -Directory -Recurse | Where-Object { (Get-ChildItem -Path $_.FullName -Directory -Force | Measure-Object).Count -eq 0 }

if (-not $projectDirs) { Log "No project folders found." "Yellow"; exit 0 }

$total = $projectDirs.Count
$processed = 0
$activeProjects = New-Object System.Collections.Generic.Queue[string]
$IsPS7 = $PSVersionTable.PSVersion.Major -ge 7

function Process-Project {
    param($project)

    $relativePath = $project.FullName.Substring($SrcDir.Length).TrimStart('\','/')
    $activeProjects.Enqueue($relativePath)
    if ($activeProjects.Count -gt 5) { $null = $activeProjects.Dequeue() }

    # Detect files
    $hasModels = @(Get-ChildItem -Path $project.FullName -Recurse -Include *.stl, *.3mf -File -ErrorAction SilentlyContinue)
    $hasGcode  = @(Get-ChildItem -Path $project.FullName -Recurse -Include *.gcode, *.bgcode -File -ErrorAction SilentlyContinue)
    $hasMd     = @(Get-ChildItem -Path $project.FullName -Recurse -Include *.md -File -ErrorAction SilentlyContinue)
    $hasPdf    = @(Get-ChildItem -Path $project.FullName -Recurse -Include *.pdf -File -ErrorAction SilentlyContinue)

    # Skip projects with no exportable files
    if ($hasModels.Count -eq 0 -and $hasGcode.Count -eq 0 -and $hasMd.Count -eq 0 -and $hasPdf.Count -eq 0) {
        Log "Skipping project (no exportable files): $relativePath" "DarkGray"
        return
    }

    $projectOutDir = Join-Path $OutputDir $relativePath
    New-Item -ItemType Directory -Force -Path $projectOutDir | Out-Null
    Log "`nProcessing project: $relativePath" "White"

    # Copy models
    foreach ($file in $hasModels) {
        try {
            $dest = Join-Path $projectOutDir $file.Name
            if ($Force -or -not (Test-Path $dest)) {
                Log "  Copying model: $($file.Name)"
                Copy-Item $file.FullName -Destination $dest -Force
            }
        } catch { LogError "  ERROR copying model $($file.Name): $($_.Exception.Message)" }
    }

    # Copy gcode/bgcode if present
    if ($hasGcode.Count -gt 0) {
        $gcodeOutDir = Join-Path $projectOutDir "gcode"
        New-Item -ItemType Directory -Force -Path $gcodeOutDir | Out-Null
        foreach ($gfile in $hasGcode) {
            try {
                $dest = Join-Path $gcodeOutDir $gfile.Name
                if ($Force -or -not (Test-Path $dest)) {
                    Log "  Copying gcode/bgcode: $($gfile.Name)"
                    Copy-Item $gfile.FullName -Destination $dest -Force
                }
            } catch { LogError "  ERROR copying gcode/bgcode $($gfile.Name): $($_.Exception.Message)" }
        }
    }

    # Handle PDFs for .md files
    foreach ($md in $hasMd) {
        try {
            $pdfOut = Join-Path $projectOutDir ($md.BaseName + ".pdf")
            $existingPdf = Join-Path $project.FullName ($md.BaseName + ".pdf")

            if (Test-Path $existingPdf) {
                if ($Force -or -not (Test-Path $pdfOut)) {
                    Log "  Copying existing PDF: $($existingPdf | Split-Path -Leaf)"
                    Copy-Item $existingPdf -Destination $pdfOut -Force
                }
            } else {
                if ($Force -or -not (Test-Path $pdfOut)) {
                    Log "  Generating PDF: $($md.Name) → $(Split-Path $pdfOut -Leaf)"
                    & pandoc -s $md.FullName -o $pdfOut
                }
            }
        } catch { LogError "  ERROR handling PDF for $($md.Name): $($_.Exception.Message)" }
    }

    # Copy any other PDFs in the project (not associated with MD files)
    foreach ($pdf in $hasPdf) {
        # Skip PDFs that match MD base names (already handled above)
        if ($hasMd | Where-Object { $_.BaseName -eq $pdf.BaseName }) { continue }
        try {
            $pdfDest = Join-Path $projectOutDir $pdf.Name
            if ($Force -or -not (Test-Path $pdfDest)) {
                Log "  Copying PDF: $($pdf.Name)"
                Copy-Item $pdf.FullName -Destination $pdfDest -Force
            }
        } catch { LogError "  ERROR copying PDF $($pdf.Name): $($_.Exception.Message)" }
    }

    # Update progress
    $script:processed++
    $pct = [Math]::Round(($script:processed / $script:total) * 100, 1)
    Write-Progress -Activity "Processing Projects" -Status "Done $script:processed/$script:total | Active: $($activeProjects -join ', ')" -PercentComplete $pct
}

# Run processing
if ($IsPS7) {
    $projectDirs | ForEach-Object -Parallel { Process-Project $_ } -ThrottleLimit 6
} else {
    foreach ($project in $projectDirs) { Process-Project $project }
}

# Root README.md → PDF or copy
$rootReadme = Join-Path (Split-Path $SrcDir -Parent) "README.md"
if (Test-Path $rootReadme) {
    $readmePdf = Join-Path $OutputDir "README.pdf"
    try {
        $existingRootPdf = Join-Path (Split-Path $SrcDir -Parent) "README.pdf"
        if (Test-Path $existingRootPdf) {
            Copy-Item $existingRootPdf -Destination $readmePdf -Force
            Log "Copied root README.pdf" "White"
        } else {
            if ($Force -or -not (Test-Path $readmePdf)) {
                Log "`nGenerating root README.pdf → $readmePdf" "White"
                & pandoc -s $rootReadme -o $readmePdf
            }
        }
    } catch { LogError "ERROR handling root README: $($_.Exception.Message)" }
} else { Log "`nNo root README.md found." "Yellow" }

Log "`n✅ Extraction and PDF handling complete. Files placed in: $OutputDir" "Green"
if (-not $NoLog) { Log "Log saved at: $LogFile" "DarkGray" }

