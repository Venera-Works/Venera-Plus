package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	openlistcore "github.com/OpenListTeam/OpenList/v4/native/openlist_core"
)

//export OpenListAllocate
func OpenListAllocate(length C.int) unsafe.Pointer {
	if length <= 0 {
		return nil
	}
	return C.malloc(C.size_t(length))
}

//export OpenListFree
func OpenListFree(pointer unsafe.Pointer) {
	if pointer != nil {
		C.free(pointer)
	}
}

//export OpenListInvoke
func OpenListInvoke(request *C.char) *C.char {
	if request == nil {
		return C.CString(`{"error":{"code":"invalid_request","message":"request is required"}}`)
	}
	return C.CString(openlistcore.Invoke(C.GoString(request)))
}

func main() {}
