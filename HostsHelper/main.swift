import Foundation
import Security

// wpc-hosts-helper — the privileged /etc/hosts daemon (PLAN.md §2f-bis).
//
// Launched on demand by launchd when the app/CLI connects to the mach service.
// It installs the custom authorization right on first run, then listens for XPC
// connections whose client code signature it pins to WP Container.

// Install the custom right into the policy database (idempotent). The helper
// runs as root, so this succeeds without prompting. The client installs it too
// (defence in depth); whichever runs first wins.
var authRef: AuthorizationRef?
if AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess, let authRef {
    wpcInstallHostsAuthorizationRight(authRef)
    AuthorizationFree(authRef, [])
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HostsHelperInfo.machServiceName)
listener.delegate = delegate
listener.resume()

// Run forever; launchd manages the process lifecycle.
dispatchMain()
