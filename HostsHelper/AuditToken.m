#import "AuditToken.h"

// Private redeclaration of the SPI property. Reading it is the standard,
// widely-used technique for obtaining an XPC peer's audit token from
// NSXPCConnection (there is no public accessor).
@interface NSXPCConnection (WPCPrivateAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

BOOL WPCGetAuditToken(NSXPCConnection *connection, audit_token_t *token) {
    if (token == NULL) { return NO; }
    if (![connection respondsToSelector:@selector(auditToken)]) { return NO; }
    *token = connection.auditToken;
    return YES;
}
