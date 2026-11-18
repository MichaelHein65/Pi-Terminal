# Local changes to Citadel 0.12.1

Based on upstream commit ae8562f895de06ccb86fdb1cbb65fd99c8976e12, MIT license retained.

- Install the supplied channelHandlers after the SSH handlers so authentication banners reach the app. Upstream stored these handlers without installing them. Forward authentication events through the handshake handler.
- Preserve custom authentication delegates for subsequent challenges so SSH `none` can fall back to a signed public-key request.
- Allow 120 seconds for SSH authentication so a user can complete a Tailscale check in the browser.
- Fail the handshake on channel closure; close the transport on authentication failure or cancellation to avoid leaving a pending session behind.

All other upstream source is unchanged. SSH host-key validation remains mandatory in the application.
