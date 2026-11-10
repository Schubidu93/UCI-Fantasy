# Nutzt unter Windows bei Bedarf den verschlüsselten lokalen PostgreSQL-Zugang.
$ErrorActionPreference = 'Stop'
$previousPassword = $env:PGPASSWORD
try {
  $credentialFile = Join-Path $env:LOCALAPPDATA 'PostgreSQL\17\postgres.credential.xml'
  if (-not $env:PGPASSWORD -and -not $env:PGPASSFILE -and (Test-Path -LiteralPath $credentialFile)) {
    $credential = Import-Clixml -LiteralPath $credentialFile
    $env:PGPASSWORD = $credential.GetNetworkCredential().Password
  }
  & node (Join-Path $PSScriptRoot 'test-db.mjs')
  $result = $LASTEXITCODE
} finally {
  if ($null -eq $previousPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
  else { $env:PGPASSWORD = $previousPassword }
}
exit $result
