//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"golang.org/x/sys/windows"
	"unsafe"
)

// The handle is private and non-inheritable. Kernel cleanup kills the injector
// if the guardian exits, including forced termination. This does not release
// injected input: guardian death still requires an unresolved-cleanup outcome.
func inputJob() (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	var limits windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	_, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits)))
	if err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	return job, nil
}

func assignInput(job windows.Handle, processID int) error {
	p, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(processID))
	if err != nil {
		return err
	}
	defer windows.CloseHandle(p)
	return windows.AssignProcessToJobObject(job, p)
}
