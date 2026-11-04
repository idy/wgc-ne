//go:build android && cgo

// Command wgc-ne-android is the Android API 23+ JNI shared library entrypoint.
package main

/*
#include <stdlib.h>
#include "jni_bridge.h"
*/
import "C"

import (
	"sync"
	"unsafe"

	"github.com/idy/wgc-ne/core"
	"github.com/idy/wgc-ne/core/native"
	"github.com/idy/wgc-ne/core/transport"
	// wgc-ne:extension-imports
)

var bridge native.Bridge

// jniProtector owns one reference to a C allocation containing a JNI global
// reference, never a Go pointer. In-flight callbacks retain their own reference
// so Stop and a Java callback can overlap without deleting the live object.
type jniProtector struct {
	mu    sync.Mutex
	value *C.WGCNEProtector
}

func (p *jniProtector) protect(fd int) error {
	p.mu.Lock()
	value := p.value
	if value != nil {
		C.wgc_ne_protector_retain(value)
	}
	p.mu.Unlock()
	if value == nil {
		return transport.ErrSocketProtection
	}
	defer C.wgc_ne_protector_release(value)
	// Attach/callback/exception clearing/detach are one C call, so JNIEnv never
	// escapes its OS thread even if this goroutine migrates between calls.
	if C.wgc_ne_protector_protect(value, C.int(fd)) == 0 {
		return transport.ErrSocketProtection
	}
	return nil
}

func (p *jniProtector) close() {
	p.mu.Lock()
	value := p.value
	p.value = nil
	p.mu.Unlock()
	if value != nil {
		C.wgc_ne_protector_release(value)
	}
}

func input(pointer *C.char, length C.int) []byte {
	if pointer == nil || length <= 0 || length > core.MaxConfigBytes {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(pointer), length)
}

//export WGCNEAndroidValidate
func WGCNEAndroidValidate(config *C.char, length C.int) *C.char {
	return C.CString(native.Validate(input(config, length)))
}

//export WGCNEAndroidStart
func WGCNEAndroidStart(fd C.int, config *C.char, length C.int, value *C.WGCNEProtector) *C.char {
	var protector transport.SocketProtector
	var release func()
	if value != nil {
		owned := &jniProtector{value: value}
		protector, release = owned.protect, owned.close
	}
	// Bridge consumes both fd and protector on every path, including invalid
	// configuration, a missing/invalid Java protector, timeout, and box failure.
	return C.CString(bridge.StartWithSocketProtector(int(fd), input(config, length), protector, release))
}

//export WGCNEAndroidStatus
func WGCNEAndroidStatus(handle C.longlong) *C.char {
	return C.CString(bridge.Status(uint64(handle)))
}

//export WGCNEAndroidStop
func WGCNEAndroidStop(handle C.longlong) { bridge.Stop(uint64(handle)) }

func main() {}
