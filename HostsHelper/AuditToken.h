#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>

NS_ASSUME_NONNULL_BEGIN

/// Copy the audit token of the peer on `connection` into `token`.
///
/// `NSXPCConnection.auditToken` is SPI, so it is redeclared privately in the
/// implementation. Reading the audit token (rather than the racy
/// `processIdentifier`) is what lets the helper pin the caller's code signature
/// with `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit:)`.
///
/// Returns YES on success.
BOOL WPCGetAuditToken(NSXPCConnection *connection, audit_token_t *token);

NS_ASSUME_NONNULL_END
