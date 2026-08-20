import Foundation

nonisolated extension DarwinStatsCollector {
    static var statsBatchCommand: String {
        RemoteTerminalBootstrap.wrapPOSIXShellCommand("""
        export LC_ALL=C LANG=C
        sysctl -n vm.loadavg 2>/dev/null || uptime | sed 's/.*load average[s]*: //'; echo '---SEP---'
        sysctl -n kern.boottime; echo '---SEP---'
        sysctl -n hw.memsize; echo '---SEP---'
        vm_stat; echo '---SEP---'
        netstat -ibn; echo '---SEP---'
        sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
        """)
    }

    static var topCommand: String {
        RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            "export LC_ALL=C LANG=C; top -l 1 -n 0 -s 0 2>/dev/null | grep 'CPU usage' || echo 'CPU usage: 0% user, 0% sys, 100% idle'"
        )
    }

    static var dfCommand: String {
        RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            "export LC_ALL=C LANG=C; df -m 2>/dev/null | grep -E '^/dev'"
        )
    }

    static var diskutilListCommand: String {
        RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            "export LC_ALL=C LANG=C; /usr/sbin/diskutil list -plist 2>/dev/null"
        )
    }

    private static var processorLoadScript: String {
        """
        if [ -x /usr/bin/ruby ]; then
            /usr/bin/ruby <<'RUBY' && exit 0
        require 'fiddle'

        lib = Fiddle.dlopen('/usr/lib/libSystem.B.dylib')
        host_self = Fiddle::Function.new(lib['mach_host_self'], [], Fiddle::TYPE_INT)
        host_processor_info = Fiddle::Function.new(
          lib['host_processor_info'],
          [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_INT
        )
        mach_task_self = Fiddle::Function.new(lib['mach_task_self'], [], Fiddle::TYPE_INT)
        vm_deallocate = Fiddle::Function.new(
          lib['vm_deallocate'],
          [Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG],
          Fiddle::TYPE_INT
        )

        count_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        info_ptr_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
        info_count_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        result = host_processor_info.call(host_self.call, 2, count_ptr, info_ptr_ptr, info_count_ptr)
        exit 1 unless result == 0

        processor_count = count_ptr[0, Fiddle::SIZEOF_INT].unpack1('I!')
        info_count = info_count_ptr[0, Fiddle::SIZEOF_INT].unpack1('I!')
        info_addr = info_ptr_ptr[0, Fiddle::SIZEOF_VOIDP].unpack1('J')
        info = Fiddle::Pointer.new(info_addr)
        values = info[0, info_count * Fiddle::SIZEOF_INT].unpack('i!*')

        (0...processor_count).each do |cpu|
          base = cpu * 4
          puts "#{cpu} #{values[base]} #{values[base + 1]} #{values[base + 2]} #{values[base + 3]}"
        end

        vm_deallocate.call(mach_task_self.call, info_addr, info_count * Fiddle::SIZEOF_INT)
        RUBY
        fi

        xcode-select -p >/dev/null 2>&1 || exit 1
        command -v cc >/dev/null 2>&1 || exit 1
        HELPER="${TMPDIR:-/tmp}/vvterm-cpu-load-v1"
        if [ ! -x "$HELPER" ]; then
            SRC="${HELPER}.$$.c"
            cat > "$SRC" <<'C'
        #include <mach/mach.h>
        #include <stdio.h>

        int main(void) {
            mach_port_t host = mach_host_self();
            natural_t processor_count = 0;
            processor_info_array_t processor_info = 0;
            mach_msg_type_number_t processor_info_count = 0;
            kern_return_t result = host_processor_info(
                host,
                PROCESSOR_CPU_LOAD_INFO,
                &processor_count,
                &processor_info,
                &processor_info_count
            );

            if (result != KERN_SUCCESS || processor_info == 0) {
                return 1;
            }

            for (natural_t cpu = 0; cpu < processor_count; cpu++) {
                integer_t *base = processor_info + (cpu * CPU_STATE_MAX);
                printf(
                    "%u %d %d %d %d\\n",
                    cpu,
                    base[CPU_STATE_USER],
                    base[CPU_STATE_SYSTEM],
                    base[CPU_STATE_IDLE],
                    base[CPU_STATE_NICE]
                );
            }

            vm_deallocate(
                mach_task_self(),
                (vm_address_t)processor_info,
                (vm_size_t)processor_info_count * sizeof(integer_t)
            );
            return 0;
        }
        C
            cc "$SRC" -o "$HELPER" >/dev/null 2>&1 || {
                rm -f "$SRC" "$HELPER"
                exit 1
            }
            rm -f "$SRC"
        fi
        "$HELPER"
        """
    }

    static var processorLoadCommand: String {
        RemoteTerminalBootstrap.wrapPOSIXShellCommand(processorLoadScript)
    }
}
