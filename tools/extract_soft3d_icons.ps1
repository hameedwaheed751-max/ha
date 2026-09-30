Add-Type -AssemblyName System.Drawing

$sourcePath = Join-Path $PSScriptRoot '..\assets\reference\soft3d-icons.png'
$outputPath = Join-Path $PSScriptRoot '..\assets\images\icons\3d'
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

$source = [System.Drawing.Bitmap]::FromFile((Resolve-Path $sourcePath))
$regions = @{
  check_3d = @(220, 0, 260, 205)
  wifi_3d = @(500, 0, 260, 205)
  money_3d = @(785, 0, 260, 205)
  wallet_3d = @(1065, 0, 260, 205)
  gift_3d = @(220, 215, 260, 205)
  users_3d = @(500, 215, 260, 205)
  user_check_3d = @(785, 215, 260, 205)
  hourglass_3d = @(1065, 215, 260, 205)
  chat_3d = @(75, 425, 260, 205)
  tasks_3d = @(355, 425, 260, 205)
  user_add_3d = @(635, 425, 260, 205)
  calculator_3d = @(1190, 425, 260, 205)
  users_group_3d = @(215, 635, 260, 205)
  router_3d = @(500, 635, 260, 205)
  speedometer_3d = @(785, 635, 260, 205)
  debt_3d = @(1070, 635, 260, 205)
}

foreach ($entry in $regions.GetEnumerator()) {
  $r = New-Object System.Drawing.Rectangle -ArgumentList @($entry.Value[0], $entry.Value[1], $entry.Value[2], $entry.Value[3])
  $crop = $source.Clone($r, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $crop.Save((Join-Path $outputPath ($entry.Key + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
  $crop.Dispose()
}
$source.Dispose()
Write-Output "Extracted $($regions.Count) transparent Soft 3D assets from the supplied reference."
