//go:build !unix

package core

import "os"

func duplicateFD(int) (int, error) { return -1, os.ErrInvalid }

// CloseOwnedFD closes an owned descriptor; mobile TUN is Apple-only.
func CloseOwnedFD(fd int) {
	if fd >= 0 {
		if file := os.NewFile(uintptr(fd), "wgc-ne"); file != nil {
			_ = file.Close()
		}
	}
}
