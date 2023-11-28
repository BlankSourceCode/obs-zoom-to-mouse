// file: mouse_helper.c
// build: gcc -o mouse_helper.dylib -shared mouse_helper.m -framework Cocoa -arch x86_64

#include <Cocoa/Cocoa.h>

NSPoint GetMouseLocation() {
    return [NSEvent mouseLocation];
}
