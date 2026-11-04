//go:build !unix

package core

import "os"

func duplicateFD(int) (int, error) { return -1, os.ErrInvalid }
func nonblockingFD(int) error      { return os.ErrInvalid }

// CloseOwnedFD closes an owned descriptor; the mobile TUN requires Unix.
func CloseOwnedFD(fd int) {
	if fd >= 0 {
		if file := os.NewFile(uintptr(fd), "wgc-ne"); file != nil {
			_ = file.Close()
		}
	}
}
