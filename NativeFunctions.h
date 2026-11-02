#pragma once
#include <stddef.h>
#include <stdint.h>

typedef enum { UUZoom, UUOffset, UUWheelBuild, UUWheelTransport, UUNativeFunctionCount } UUNativeFunction;
const void *UUResolveNativeFunction(const uint32_t *text, size_t byteCount, UUNativeFunction function);
