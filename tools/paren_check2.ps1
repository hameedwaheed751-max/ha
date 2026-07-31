$path='c:\untitled\lib\screens\subscribers_screen.dart'
$text = Get-Content -Raw -Path $path
$len = $text.Length
$inS=$false; $inD=$false; $inLine=$false; $inBlock=$false; $count=0
$firstNegFound=$false
for($i=0;$i -lt $len;$i++){
  $ch = $text[$i]
  $next = if($i+1 -lt $len) {$text[$i+1]} else {''}
  $prev = if($i-1 -ge 0) {$text[$i-1]} else {''}
  if($inLine){ if($ch -eq "`n") { $inLine=$false } ; continue }
  if($inBlock){ if($ch -eq '*' -and $next -eq '/') { $inBlock=$false; $i++; continue } ; continue }
  if(-not $inS -and -not $inD){ if($ch -eq '/' -and $next -eq '/') { $inLine=$true; $i++; continue } if($ch -eq '/' -and $next -eq '*') { $inBlock=$true; $i++; continue } }
  if($inS){ if($ch -eq "'" -and $prev -ne "\\") { $inS=$false } ; continue }
  if($inD){ if($ch -eq '"' -and $prev -ne "\\") { $inD=$false } ; continue }
  if($ch -eq "'") { $inS=$true; continue }
  if($ch -eq '"') { $inD=$true; continue }
  if(-not $inS -and -not $inD -and -not $inLine -and -not $inBlock){ if($ch -eq '(') { $count++ } elseif($ch -eq ')') { $count-- } }
  if(-not $firstNegFound -and $count -lt 0){ $before = $text.Substring(0,$i+1); $lineNum = ($before -split "\r?\n").Length; $col = ($before -split "\r?\n")[-1].Length; Write-Host "Negative at index $i line $lineNum col $col"; $firstNegFound=$true }
}
Write-Host "finalCount:$count"
