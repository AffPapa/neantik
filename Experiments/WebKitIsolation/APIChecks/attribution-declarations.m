// Declaration/typecheck fixture only. Never linked or executed.
// It does not create an ES client, read a live token or request any permission.
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#include <EndpointSecurity/EndpointSecurity.h>

void neantik_attribution_declarations(NEFilterFlow *flow, const es_message_t *message)
{
    NSData *application = flow.sourceAppAuditToken;
    NSData *creator = flow.sourceProcessAuditToken;
    (void)application;
    (void)creator;

    // The field exists in the struct but is valid only for message version>=4.
    if (message && message->version >= 4 && message->process) {
        audit_token_t responsible = message->process->responsible_audit_token;
        (void)responsible;
    }

    // A macOS14-compatible source must not unconditionally use the27 API.
    if (__builtin_available(macOS 27.0, *)) {
        es_new_client_result_t (*descendant_client)(es_client_t **, es_handler_block_t) = &es_new_descendants_client;
        (void)descendant_client;
    }
}
