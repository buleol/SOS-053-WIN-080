$TargetIP   = "192.168.56.30"
$Username   = "BenchUser_RUP"
$Domain     = "LAB"
$UserPass   = "BenchPass2026!"
$AdminUser  = "$Domain\Администратор"
$AdminPass  = "P@ssw0rd"
$Iterations = 5

$secPass = ConvertTo-SecureString $AdminPass -AsPlainText -Force
$cred    = New-Object System.Management.Automation.PSCredential ($AdminUser, $secPass)

cmdkey /generic:TERMSRV/$TargetIP /user:"$Domain\$Username" /pass:$UserPass | Out-Null
Set-Item WSMan:\localhost\Client\TrustedHosts -Value $TargetIP -Force -ErrorAction SilentlyContinue

$Session = New-PSSession -ComputerName $TargetIP -Credential $cred
$Report  = @()

for ($k = 1; $k -le $Iterations; $k++) {
    Write-Host "`n=== ЗАПУСК $k из $Iterations (RUP) ===" -ForegroundColor Cyan

    $Before = Invoke-Command -Session $Session -ScriptBlock {
        param($u)
        Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -match $u | ForEach-Object { logoff $_.SessionId }
        $disk = Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
        $smb  = Get-CimInstance Win32_PerfRawData_PerfNet_Server
        [PSCustomObject]@{
            ReadBytes  = [int64]$disk.DiskReadBytesPersec
            WriteBytes = [int64]$disk.DiskWriteBytesPersec
            SmbBytes   = [int64]$smb.BytesTotalPersec
        }
    } -ArgumentList $Username

    Start-Sleep -Seconds 2
    Write-Host " -> Открываем RDP и ждем загрузку профиля с SMB-шары..." -ForegroundColor Gray

    $StartTime  = Get-Date
    $rdp        = Start-Process -FilePath "mstsc" -ArgumentList "/v:$TargetIP" -PassThru
    $LoadedProc = $null

    for ($i = 0; $i -lt 80; $i++) {
        $LoadedProc = Invoke-Command -Session $Session -ScriptBlock {
            param($u)
            Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -match $u | Select-Object -First 1
        } -ArgumentList $Username -ErrorAction SilentlyContinue

        if ($LoadedProc) { break }
        Start-Sleep -Milliseconds 500
    }

    if ($LoadedProc) {
        $TotalSec = [math]::Round(((Get-Date) - $StartTime).TotalSeconds, 2)
        Write-Host " -> Вход выполнен за $TotalSec сек! Снимаем метрики сети и диска..." -ForegroundColor Green

        $Metrics = Invoke-Command -Session $Session -ScriptBlock {
            param($u, $sId, $bRead, $bWrite, $bSmb)

            $disk2 = Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
            $smb2  = Get-CimInstance Win32_PerfRawData_PerfNet_Server

            $dReadKB  = [math]::Max(0, [math]::Round((([int64]$disk2.DiskReadBytesPersec - $bRead) / 1024), 1))
            $dWriteKB = [math]::Max(0, [math]::Round((([int64]$disk2.DiskWriteBytesPersec - $bWrite) / 1024), 1))
            $smbKB    = [math]::Max(0, [math]::Round((([int64]$smb2.BytesTotalPersec - $bSmb) / 1024), 1))

            $ev1 = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-User Profile Service/Operational'; ID=1} -MaxEvents 1 -ErrorAction SilentlyContinue
            $ev2 = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-User Profile Service/Operational'; ID=2} -MaxEvents 1 -ErrorAction SilentlyContinue

            $profMs = if ($ev1 -and $ev2 -and ($ev2.TimeCreated -ge $ev1.TimeCreated)) {
                [math]::Round(($ev2.TimeCreated - $ev1.TimeCreated).TotalMilliseconds, 0)
            } else {
                0
            }

            $profFolder = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $ntMs = 0
            if ($profFolder -and (Test-Path "$($profFolder.FullName)\NTUSER.DAT")) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $s = [System.IO.File]::Open("$($profFolder.FullName)\NTUSER.DAT", 'Open', 'Read', 'ReadWrite')
                    $b = New-Object byte[] 65536
                    [void]$s.Read($b, 0, $b.Length)
                    $s.Close()
                } catch {}
                $sw.Stop()
                $ntMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            }

            logoff $sId

            [PSCustomObject]@{
                ProfSvc_ms   = $profMs
                DiskRead_KB  = $dReadKB
                DiskWrite_KB = $dWriteKB
                SMB_KB       = $smbKB
                NTUSER_ms    = $ntMs
            }
        } -ArgumentList $Username, $LoadedProc.SessionId, $Before.ReadBytes, $Before.WriteBytes, $Before.SmbBytes

        Write-Host "    ProfSvc: $($Metrics.ProfSvc_ms) мс | Диск R/W: $($Metrics.DiskRead_KB) / $($Metrics.DiskWrite_KB) КБ | SMB: $($Metrics.SMB_KB) КБ | NTUSER: $($Metrics.NTUSER_ms) ms" -ForegroundColor Yellow

        $Report += [PSCustomObject]@{
            Iter         = $k
            User         = $Username
            Logon_Sec    = $TotalSec
            ProfSvc_ms   = $Metrics.ProfSvc_ms
            DiskRead_KB  = $Metrics.DiskRead_KB
            DiskWrite_KB = $Metrics.DiskWrite_KB
            SMB_KB       = $Metrics.SMB_KB
            NTUSER_ms    = $Metrics.NTUSER_ms
        }
    } else {
        Write-Host " -> Таймаут ожидания входа." -ForegroundColor Red
    }

    if ($rdp -and !$rdp.HasExited) {
        Stop-Process -Id $rdp.Id -Force -ErrorAction SilentlyContinue
    }

    Write-Host " -> Ожидание освобождения сеанса на сервере..." -ForegroundColor Gray
    for ($w = 0; $w -lt 20; $w++) {
        $stillThere = Invoke-Command -Session $Session -ScriptBlock {
            param($u)
            Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -match $u
        } -ArgumentList $Username -ErrorAction SilentlyContinue

        if (!$stillThere) { break }
        Start-Sleep -Milliseconds 500
    }

    Start-Sleep -Seconds 2
}

Remove-PSSession $Session
cmdkey /delete:TERMSRV/$TargetIP

$Report | Format-Table -AutoSize
$Report | Export-Csv -Path "C:\Benchmark\rup_benchmark.csv" -NoTypeInformation -Encoding UTF8
