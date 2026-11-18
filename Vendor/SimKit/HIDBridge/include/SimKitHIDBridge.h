#ifndef SIMKIT_HID_BRIDGE_H
#define SIMKIT_HID_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct SimKitHIDClient SimKitHIDClient;

/// Xcode 27's dtuhidd transport. `device` is an unretained SimDevice NSObject.
SimKitHIDClient *SimKitHIDCreate(void *device);
void SimKitHIDDestroy(SimKitHIDClient *client);
void SimKitHIDSetTouchTarget(SimKitHIDClient *client, uint64_t target);
bool SimKitHIDTouch(SimKitHIDClient *client, uint64_t phase, double x, double y, uint64_t edge);
bool SimKitHIDTouchTwo(SimKitHIDClient *client, uint64_t phase, double x1, double y1, double x2, double y2);
bool SimKitHIDButton(SimKitHIDClient *client, uint64_t page, uint64_t usage, bool down);
bool SimKitHIDKey(SimKitHIDClient *client, uint64_t usage, bool down);

#endif
