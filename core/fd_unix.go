//go:build unix

package core

import "golang.org/x/sys/unix"

func duplicateFD(fd int) (int, error) { return unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 3) }

// CloseOwnedFD closes a descriptor transferred through the native ABI.
func CloseOwnedFD(fd int) {
	if fd >= 0 {
		_ = unix.Close(fd)
	}
}
