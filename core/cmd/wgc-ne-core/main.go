//go:build cgo

package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"github.com/idy/wgc-ne/core"
	"github.com/idy/wgc-ne/core/native"
	"unsafe"
	// wgc-ne:extension-imports
)

var bridge native.Bridge

func input(pointer *C.char, length C.int32_t) []byte {
	if pointer == nil || length <= 0 || length > core.MaxConfigBytes {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(pointer), C.int(length))
}

//export WGCNEABIVersion
func WGCNEABIVersion() C.int32_t { return native.ABIVersion }

//export WGCNEValidate
func WGCNEValidate(config *C.char, length C.int32_t) *C.char {
	return C.CString(native.Validate(input(config, length)))
}

//export WGCNEStart
func WGCNEStart(fd C.int32_t, config *C.char, length C.int32_t) *C.char {
	return C.CString(bridge.Start(int(fd), input(config, length)))
}

//export WGCNEStatus
func WGCNEStatus(handle C.uint64_t) *C.char { return C.CString(bridge.Status(uint64(handle))) }

//export WGCNEStop
func WGCNEStop(handle C.uint64_t) { bridge.Stop(uint64(handle)) }

//export WGCNEFree
func WGCNEFree(value *C.char) { C.free(unsafe.Pointer(value)) }
func main()                   {}
