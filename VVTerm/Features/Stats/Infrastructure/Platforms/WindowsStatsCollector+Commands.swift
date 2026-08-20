import Foundation

nonisolated extension WindowsStatsCollector {
    func powerShellProcessScript(limit: Int?) -> String {
        let limitClause = limit.map { " | Select-Object -First \($0)" } ?? ""
        return """
        $os = Get-CimInstance Win32_OperatingSystem;
        $totalMemory = [double]$os.TotalVisibleMemorySize * 1024;
        $logicalProcessors = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors;
        if ($logicalProcessors -le 0) { $logicalProcessors = [Environment]::ProcessorCount };
        $logicalProcessors = [math]::Max($logicalProcessors, 1);
        Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
          Where-Object { $_.IDProcess -gt 0 -and $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
          Sort-Object PercentProcessorTime -Descending\(limitClause) |
          ForEach-Object {
            $cpu = [double]$_.PercentProcessorTime / $logicalProcessors;
            $memoryBytes = [double]$_.WorkingSet;
            $memoryPercent = if ($totalMemory -gt 0) { ($memoryBytes / $totalMemory) * 100 } else { 0 };
            $name = ([string]$_.Name).Replace('|', '/');
            Write-Output ('{0}|{1}|{2}|{3}|{4}' -f $_.IDProcess, $name, [math]::Round($cpu,1), [math]::Round($memoryPercent,1), [uint64]$memoryBytes)
          }
        """
    }

    func periodicStatsPowerShellScript() -> String {
        """
        try {
          $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop;
          [uint64]$memoryTotal = [uint64]$os.TotalVisibleMemorySize * 1024;
          [uint64]$memoryFree = [uint64]$os.FreePhysicalMemory * 1024;
          [uint64]$memoryUsed = 0;
          if ($memoryTotal -ge $memoryFree) { $memoryUsed = $memoryTotal - $memoryFree };
          Write-Output ('MEMORY|{0}|{1}|{2}' -f $memoryTotal, $memoryUsed, $memoryFree);
          [long]$uptime = [long]((Get-Date) - $os.LastBootUpTime).TotalSeconds;
          if ($uptime -lt 0) { $uptime = 0 };
          Write-Output ('UPTIME|{0}' -f $uptime);
        } catch {}
        try {
          $processes = @(Get-Process -ErrorAction Stop);
          Write-Output ('PROCESS_COUNT|{0}' -f $processes.Count);
        } catch {}
        try {
          $networkStats = @(Get-NetAdapterStatistics -ErrorAction Stop | Where-Object {$_.Name -notlike '*Loopback*'});
          [uint64]$networkRx = [uint64](($networkStats | Measure-Object -Property ReceivedBytes -Sum).Sum);
          [uint64]$networkTx = [uint64](($networkStats | Measure-Object -Property SentBytes -Sum).Sum);
          Write-Output ('NETWORK|{0}|{1}' -f $networkRx, $networkTx);
        } catch {}
        """
    }

    func nvidiaSMIQueryScript(fields: String) -> String {
        """
        $nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue;
        if ($nvidia) {
          & $nvidia.Source --query-gpu=\(fields) --format=csv,noheader,nounits 2>$null
        }
        """
    }

    func windowsGPUCounterScript() -> String {
        """
        $rows = @{};
        function Ensure-Row([string]$phys) {
          if (-not $rows.ContainsKey($phys)) {
            $rows[$phys] = @{ Util = 0.0; Used = 0.0; Limit = 0.0 };
          }
        }
        $engineCounter = Get-Counter '\\GPU Engine(*)\\Utilization Percentage' -ErrorAction SilentlyContinue;
        if ($engineCounter) {
          foreach ($sample in $engineCounter.CounterSamples) {
            $instance = [string]$sample.InstanceName;
            if ($instance -match '_phys_(\\d+)') {
              $phys = $matches[1];
              Ensure-Row $phys;
              $rows[$phys]['Util'] = [double]$rows[$phys]['Util'] + [double]$sample.CookedValue;
            }
          }
        }
        $memoryUsage = Get-Counter '\\GPU Adapter Memory(*)\\Dedicated Usage' -ErrorAction SilentlyContinue;
        if ($memoryUsage) {
          foreach ($sample in $memoryUsage.CounterSamples) {
            $instance = [string]$sample.InstanceName;
            if ($instance -match '_phys_(\\d+)') {
              $phys = $matches[1];
              Ensure-Row $phys;
              $rows[$phys]['Used'] = [math]::Max([double]$rows[$phys]['Used'], [double]$sample.CookedValue);
            }
          }
        }
        $memoryLimit = Get-Counter '\\GPU Adapter Memory(*)\\Dedicated Limit' -ErrorAction SilentlyContinue;
        if ($memoryLimit) {
          foreach ($sample in $memoryLimit.CounterSamples) {
            $instance = [string]$sample.InstanceName;
            if ($instance -match '_phys_(\\d+)') {
              $phys = $matches[1];
              Ensure-Row $phys;
              $rows[$phys]['Limit'] = [math]::Max([double]$rows[$phys]['Limit'], [double]$sample.CookedValue);
            }
          }
        }
        $rows.Keys | Sort-Object {[int]$_} | ForEach-Object {
          $row = $rows[$_];
          Write-Output ('PERF|windows-phys-{0}|{1}|{2}|{3}' -f $_, [math]::Round([double]$row['Util'], 1), [uint64][math]::Max([double]$row['Used'], 0), [uint64][math]::Max([double]$row['Limit'], 0));
        }
        """
    }

    func powerShellCommand(using client: SSHClient, script: String) async throws -> String {
        let environment = await client.remoteEnvironment()
        if environment.shellProfile.family == .powershell {
            return script
        }

        guard let executable = environment.powerShellExecutable else {
            throw SSHError.unknown("Windows stats require a working PowerShell runtime on the remote host")
        }
        let wrapped = RemoteTerminalBootstrap.wrapPowerShellCommand(script, executableName: executable)
        if environment.shellProfile.family == .cmd {
            return RemoteTerminalBootstrap.wrapCmdExecCommand(wrapped)
        }
        return wrapped
    }
}
