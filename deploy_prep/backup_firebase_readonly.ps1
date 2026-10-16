# READ-ONLY backup of the production Realtime Database nodes that Priority 1 touches.
# Uses only HTTPS GET requests (the same unauthenticated access the apps use).
# It never writes. Output goes OUTSIDE the repository because it contains GPS data
# and user records. Run before every production-changing stage.
param(
  [string]$DatabaseUrl = 'https://garbagesis-78d39-default-rtdb.asia-southeast1.firebasedatabase.app',
  [string]$OutDir = ("C:\Projects\gt-backups\" + (Get-Date -Format 'yyyy-MM-dd_HHmm'))
)

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$nodes = 'truck_locations','driver_routes','driver_sessions','users','residents','trucks','puroks',
         'weekly_collection_progress','load_history','trip_history','notifications','complaints',
         'collection_logs','collection_progress','truck_issues','driver_settings','admin_settings'
foreach ($n in $nodes) {
  $target = Join-Path $OutDir "$n.json"
  Invoke-WebRequest -Uri "$DatabaseUrl/$n.json" -OutFile $target -UseBasicParsing -TimeoutSec 300
  '{0,-30} {1,12:N0} bytes' -f $n, (Get-Item $target).Length
}
Write-Host "Backup written to $OutDir"
Write-Host "NOTE: Firebase security RULES cannot be read over this public API. Export them from"
Write-Host "      Firebase console > Realtime Database > Rules (copy to rules.backup.json) BEFORE any change."
