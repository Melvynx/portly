package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// processMemoryCountersEx mirrors PROCESS_MEMORY_COUNTERS_EX.
type processMemoryCountersEx struct {
	CB                         uint32
	PageFaultCount             uint32
	PeakWorkingSetSize         uintptr
	WorkingSetSize             uintptr
	QuotaPeakPagedPoolUsage    uintptr
	QuotaPagedPoolUsage        uintptr
	QuotaPeakNonPagedPoolUsage uintptr
	QuotaNonPagedPoolUsage     uintptr
	PagefileUsage              uintptr
	PeakPagefileUsage          uintptr
	PrivateUsage               uintptr
}

var procGetProcessMemoryInfo = windows.NewLazySystemDLL("kernel32.dll").NewProc("K32GetProcessMemoryInfo")

// listProcesses reports private bytes as footprint and the working set as RSS.
// CPU is measured as a delta between samples, like the Linux path.
func listProcesses() []procRecord {
	var recs []procRecord
	eachProcess(func(e *windows.ProcessEntry32) {
		rec := procRecord{
			PID:       int(e.ProcessID),
			ParentPID: int(e.ParentProcessID),
			Command:   windows.UTF16ToString(e.ExeFile[:]),
		}
		if h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, e.ProcessID); err == nil {
			var mem processMemoryCountersEx
			mem.CB = uint32(unsafe.Sizeof(mem))
			if ok, _, _ := procGetProcessMemoryInfo.Call(uintptr(h), uintptr(unsafe.Pointer(&mem)), uintptr(mem.CB)); ok != 0 {
				rec.RSSBytes = uint64(mem.WorkingSetSize)
				rec.Footprint = uint64(mem.PrivateUsage)
			}
			var created, exited, kernel, user windows.Filetime
			if windows.GetProcessTimes(h, &created, &exited, &kernel, &user) == nil {
				// FILETIME is in 100ns units; the shared CPU math expects 1/100 s ticks.
				ticks := uint64(kernel.HighDateTime)<<32 | uint64(kernel.LowDateTime)
				ticks += uint64(user.HighDateTime)<<32 | uint64(user.LowDateTime)
				rec.CPUPercent = linuxCPUPercent(rec.PID, ticks/100_000)
			}
			windows.CloseHandle(h)
		}
		recs = append(recs, rec)
	})
	pruneCPUSnapshots(recs)
	return recs
}
