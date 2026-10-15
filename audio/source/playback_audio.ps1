param([switch]$FullLoops)

# Play local audio through Windows SoundPlayer and record completed playback.
$ErrorActionPreference = 'Stop'
$audioRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $audioRoot '..'))
$recordPath = Join-Path $PSScriptRoot 'playback-check.txt'
Add-Type -AssemblyName System

if ($FullLoops) {
    $playbackFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot '.godot\phase6-audio-pass') -Filter '*-three-loops.wav')
    if ($playbackFiles.Count -ne 2) { throw 'Run check_audio.py --full-loop-preview first.' }
} else {
    $playbackFiles = @(Get-ChildItem -LiteralPath (Join-Path $audioRoot 'sfx') -Filter '*.wav')
    $playbackFiles += @(Get-ChildItem -LiteralPath (Join-Path $audioRoot 'preview') -Filter '*.wav')
}

foreach ($playbackFile in $playbackFiles) {
    $beginTime = [DateTime]::UtcNow
    Write-Output ('PLAYING ' + $playbackFile.Name)
    $player = [System.Media.SoundPlayer]::new($playbackFile.FullName)
    try {
        $player.Load()
        $player.PlaySync()
    } finally {
        $player.Dispose()
    }
    $elapsedSeconds = ([DateTime]::UtcNow - $beginTime).TotalSeconds
    $record = ('PLAYED {0} elapsed={1:F3}s completed_utc={2:o}' -f $playbackFile.Name, $elapsedSeconds, [DateTime]::UtcNow)
    Add-Content -LiteralPath $recordPath -Value $record -Encoding utf8
    Write-Output $record
}
