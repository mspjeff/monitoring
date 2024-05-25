#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
    .SYNOPSIS
        Downloads and starts the Windows Exporter
    .DESCRIPTION
        This script downloads the Windows Exporter that surfaces Prometheus
        metrics at http://<hostname>:9182/metrics. A scheduled task is created
        that starts the exporter at system startup. The task is automatically
        started at the end of this script. The collector list is dynamically
        created at script runtime based on the Windows services that exist and
        are running at the time the script is run.
    .EXAMPLE
        PS C:\> Install-WindowsExporter.ps1
    .EXAMPLE
        PS C:\> irm https://raw.githubusercontent.com/mspjeff/monitoring/main/Install-WindowsExporter.ps1 | iex
    .LINK
        https://prometheus.io
    .LINK
        https://github.com/prometheus-community/windows_exporter
  #>

[CmdletBinding()]
param(
)


function Get-CollectorList
{
    #
    # list of collectors that we enable by default
    #
    $collectors = @(
        'cpu',
        'cs',
        'logical_disk',
        'memory',
        'net',
        'os',
        'scheduled_task',
        'service',
        'system',
        'time'
    )

    #
    # list of collectors that we optionally enable depeneding on whether the
    # specified Windows service is installed; for example, if the ntds service
    # is installed and running then we enable the active directory collector
    #
    $serviceToCollectorHash = @{
        ntds = 'ad'
        dfsr = 'dfsr'
        dhcpserver = 'dhcp'
        dns = 'dns'
        vmms = 'hyperv'
        w3svc = 'iis'
        mssqlserver = 'mssql'
        termservice = 'terminal_services'
    }

    foreach ($key in $serviceToCollectorHash.Keys)
    {
        if ((Get-Service $key -ErrorAction SilentlyContinue).Status -eq 'Running')
        {
            $collectors += $serviceToCollectorHash[$key]
        }
    }

    #
    # returns a comma-delimited list of collectors e.g. cpu,cs,net,os
    #
    $collectors -join ','
}

function Get-Installer
{
    #
    # use github api to determine the latest stable release for windows exporter
    # and get the appropriate download url and filename
    #
    $downloadUrl = Invoke-RestMethod `
        https://api.github.com/repos/prometheus-community/windows_exporter/releases/latest `
    | Select-Object -ExpandProperty assets `
    | Where-Object { $_.name.EndsWith("-amd64.msi")} `
    | Select-Object -ExpandProperty browser_download_url

    $filename = Split-Path $downloadUrl -Leaf

    $pathAndFilename = (Join-Path $env:TEMP $filename)

    if (-not (Test-Path $pathAndFilename))
    {
        Write-Output "[+] Downloading latest windows exporter installer"
        Start-BitsTransfer -Source $downloadUrl -Destination $pathAndFilename
    }

    $pathAndFilename
}

$installer = Get-Installer
Write-Output "[*] Downloaded installer to $installer"

$collectors = Get-CollectorList
Write-Output "[*] Collectors to enable are $collectors"


$flags = @()
$flags += "--collector.scheduled_task.exclude=""""/Microsoft/.+"""""
$flags += "--collector.service.services-where=""""StartMode='auto'"""""
$flags = $flags -join ' '
Write-Output "[*] Extra flags are $flags"

$cmdline = @()
$cmdline += "/i"
$cmdline += "$installer"
$cmdline += "ENABLED_COLLECTORS=""$collectors"""
$cmdline += "EXTRA_FLAGS=""$flags"""
$cmdline = $cmdline -join ' '

Write-Output "[+] Installing service using $cmdline"
Start-Process -FilePath "msiexec.exe" -ArgumentList $cmdline -Wait

#
# if everything worked as expected then the exporter should be running
# and providing health information at http://localhost:9182/health
#
if (-not ((Invoke-RestMethod http://localhost:9182/health).status -eq 'ok'))
{
    Write-Warning "Windows Exporter does not appear to be providing health info"
    return
}

Write-Output "[*] Listening at http://localhost:9182/metrics"
