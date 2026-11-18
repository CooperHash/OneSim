// Xcode 27 dtuhidd transport. Wire keys and service names follow the MIT-licensed
// FBSimulatorControl DTUHIDModels and SimulatorDTUHIDConnection in meta/idb.
// Copyright (c) 2026 SimLab contributors. Licensed under the MIT license.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <math.h>
#import <mach/mach.h>
#import <stdlib.h>
#import <unistd.h>
#import <xpc/xpc.h>
#import "SimKitHIDBridge.h"

@interface NSObject (SimKitDeviceLookup)
- (mach_port_t)lookup:(NSString *)service error:(NSError **)error;
@end

struct SimKitHIDClient {
    xpc_connection_t connection;
    dispatch_queue_t queue;
    uint64_t touchTarget;
};

static const char *serviceName = "com.apple.coredevice.feature.remote.hid.digitizer";

static xpc_object_t envelope(const char *type, xpc_object_t payload, bool barrier) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "messageType", type);
    xpc_dictionary_set_bool(message, "isBarrier", barrier);
    xpc_dictionary_set_string(message, "featureIdentifier", serviceName);
    xpc_dictionary_set_value(message, "payload", payload);
    return message;
}

static xpc_object_t keyboardMessage(uint64_t usage, bool down, bool barrier) {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usageCode", usage);
    xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
    return envelope("IndigoKeyboardButtonEvent", payload, barrier);
}

static bool live(xpc_connection_t connection, dispatch_queue_t queue) {
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block bool answered = false;
    xpc_connection_send_message_with_reply(connection, keyboardMessage(0, false, true), queue,
                                           ^(xpc_object_t reply) {
        answered = xpc_get_type(reply) == XPC_TYPE_DICTIONARY;
        dispatch_semaphore_signal(finished);
    });
    return dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) == 0 && answered;
}

SimKitHIDClient *SimKitHIDCreate(void *devicePointer) {
    if (!devicePointer) return NULL;
    id device = (__bridge id)devicePointer;
    if (![device respondsToSelector:@selector(lookup:error:)]) return NULL;
    typedef xpc_object_t (*EndpointFromPort)(mach_port_t, uint64_t, uint64_t);
    typedef xpc_connection_t (*ConnectionFromEndpoint)(xpc_object_t);
    typedef void (*EnableSimToHost)(xpc_connection_t);
    EndpointFromPort endpointFromPort = (EndpointFromPort)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    ConnectionFromEndpoint fromEndpoint = (ConnectionFromEndpoint)dlsym(RTLD_DEFAULT, "xpc_connection_create_from_endpoint");
    EnableSimToHost enableSimToHost = (EnableSimToHost)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!endpointFromPort || !fromEndpoint || !enableSimToHost) return NULL;

    NSError *error = nil;
    mach_port_t port = [device lookup:@"com.apple.coredevice.feature.remote.hid.digitizer" error:&error];
    if (port == MACH_PORT_NULL) return NULL;
    xpc_object_t endpoint = endpointFromPort(port, 0, 0);
    xpc_connection_t connection = endpoint ? fromEndpoint(endpoint) : NULL;
    if (!connection) return NULL;

    dispatch_queue_t queue = dispatch_queue_create("org.simlab.dtuhid", DISPATCH_QUEUE_SERIAL);
    enableSimToHost(connection);
    xpc_connection_set_target_queue(connection, queue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);
    if (!live(connection, queue)) {
        xpc_connection_cancel(connection);
        return NULL;
    }
    // The daemon answers before its guest device has fully opened.
    usleep(200000);
    SimKitHIDClient *client = calloc(1, sizeof(SimKitHIDClient));
    client->connection = connection;
    client->queue = queue;
    return client;
}

void SimKitHIDDestroy(SimKitHIDClient *client) {
    if (!client) return;
    xpc_connection_cancel(client->connection);
    free(client);
}

void SimKitHIDSetTouchTarget(SimKitHIDClient *client, uint64_t target) {
    if (client) client->touchTarget = target;
}

static xpc_object_t point(double x, double y) {
    xpc_object_t value = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_double(value, "x", fmin(1, fmax(0, x)));
    xpc_dictionary_set_double(value, "y", fmin(1, fmax(0, y)));
    return value;
}

bool SimKitHIDTouch(SimKitHIDClient *client, uint64_t phase, double x, double y, uint64_t edge) {
    if (!client || phase > 2 || !isfinite(x) || !isfinite(y)) return false;
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "pointOne", point(x, y));
    xpc_dictionary_set_uint64(payload, "eventType", phase);
    xpc_dictionary_set_uint64(payload, "edge", edge);
    xpc_dictionary_set_uint64(payload, "target", client->touchTarget);
    xpc_connection_send_message(client->connection, envelope("IndigoDigitizerEvent", payload, false));
    return true;
}

bool SimKitHIDTouchTwo(SimKitHIDClient *client, uint64_t phase, double x1, double y1, double x2, double y2) {
    if (!client || phase > 2) return false;
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "pointOne", point(x1, y1));
    xpc_dictionary_set_value(payload, "pointTwo", point(x2, y2));
    xpc_dictionary_set_uint64(payload, "eventType", phase);
    xpc_dictionary_set_uint64(payload, "edge", 0);
    xpc_dictionary_set_uint64(payload, "target", client->touchTarget);
    xpc_connection_send_message(client->connection, envelope("IndigoDigitizerEvent", payload, false));
    return true;
}

bool SimKitHIDButton(SimKitHIDClient *client, uint64_t page, uint64_t usage, bool down) {
    if (!client) return false;
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usagePage", page);
    xpc_dictionary_set_uint64(payload, "usageCode", usage);
    xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
    xpc_connection_send_message(client->connection, envelope("IndigoButtonEvent", payload, false));
    return true;
}

bool SimKitHIDKey(SimKitHIDClient *client, uint64_t usage, bool down) {
    if (!client) return false;
    xpc_connection_send_message(client->connection, keyboardMessage(usage, down, false));
    return true;
}
