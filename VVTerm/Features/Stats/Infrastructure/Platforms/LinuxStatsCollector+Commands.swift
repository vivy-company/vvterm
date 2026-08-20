import Foundation

nonisolated extension LinuxStatsCollector {
    static var systemInfoCommand: String {
        "uname -srm; echo '---SEP---'; hostname; echo '---SEP---'; nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1"
    }

    static var profileCommand: String {
        let script = """
            LC_ALL=C LANG=C; \
            hostname 2>/dev/null; echo '---SEP---'; \
            uname -srm 2>/dev/null; echo '---SEP---'; \
            uname -m 2>/dev/null; echo '---SEP---'; \
            uname -r 2>/dev/null; echo '---SEP---'; \
            (lscpu 2>/dev/null || cat /proc/cpuinfo 2>/dev/null); echo '---SEP---'; \
            grep -m1 '^MemTotal:' /proc/meminfo 2>/dev/null; echo '---SEP---'; \
            (nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader,nounits 2>/dev/null || true); echo '---SEP---'; \
            (lspci -mm 2>/dev/null | grep -Ei 'VGA|3D|Display' || true)
            """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static var statsBatchCommand: String {
        """
        grep '^cpu' /proc/stat; echo '---SEP---'; \
        cat /proc/meminfo; echo '---SEP---'; \
        cat /proc/net/dev; echo '---SEP---'; \
        cat /proc/loadavg; echo '---SEP---'; \
        cat /proc/uptime; echo '---SEP---'; \
        ls -d /proc/[0-9]* 2>/dev/null | wc -l
        """
    }

    static var fallbackStatsCommand: String {
        let script = """
            export LC_ALL=C LANG=C; \
            top -bn1 2>/dev/null | head -20; echo '---SEP---'; \
            free -b 2>/dev/null; echo '---SEP---'; \
            uptime 2>/dev/null; echo '---SEP---'; \
            for i in /sys/class/net/*; do \
              n=$(basename "$i"); \
              [ "$n" = "lo" ] && continue; \
              rx=$(cat "$i/statistics/rx_bytes" 2>/dev/null); \
              tx=$(cat "$i/statistics/tx_bytes" 2>/dev/null); \
              [ -n "$rx" ] && [ -n "$tx" ] && echo "$n $rx $tx"; \
            done; echo '---SEP---'; \
            (ip -s link 2>/dev/null || ifconfig -a 2>/dev/null); echo '---SEP---'; \
            (ps -e 2>/dev/null | wc -l)
            """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static var volumesCommand: String {
        RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            "LC_ALL=C LANG=C; volume_df=$(df -BM -P -T -x tmpfs -x devtmpfs -x squashfs 2>/dev/null); "
                + "if [ -n \"$volume_df\" ]; then printf '%s\\n' \"$volume_df\"; "
                + "else df -BM -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null; fi"
        )
    }

    static var processCountCommand: String { "ps -e 2>/dev/null | wc -l" }
    static var memoryInfoCommand: String { "cat /proc/meminfo 2>/dev/null" }

    static var gpuSamplesCommand: String {
        "nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null || true"
    }

    static var volumeMetadataCommand: String {
        RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            "LC_ALL=C LANG=C lsblk -J -p -o NAME,UUID,FSTYPE 2>/dev/null"
        )
    }
}
