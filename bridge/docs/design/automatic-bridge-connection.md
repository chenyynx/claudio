# Automatic Bridge connection selection

## Goal

Machine registration should not require users to know whether their Bridge is
served as `ws://` or `wss://`. A normally started local Bridge should connect
without changing a security toggle, while users who require TLS must be able to
prevent a plaintext fallback.

## Connection modes

- **Automatic (default):** probe HTTPS first and then HTTP `/health` only when
  needed, without credentials. Use the first successful transport.
- **Secure only:** probe and connect with HTTPS/WSS only. Never downgrade.
- **Standard only:** use HTTP/WS only. This is intended for local networks or an
  encrypted overlay such as Tailscale.

The resolved transport remains in `Machine.useSsl`; the user's policy is stored
separately in `Machine.connectionMode`. Once resolved, routine health checks use
the known transport. A known WS endpoint may try WSS as a safe upgrade after WS
fails, but a known WSS endpoint never tries WS automatically.

An endpoint that has successfully used WSS is pinned to WSS. Automatic mode
does not downgrade that endpoint to WS after a TLS failure; the user must
explicitly choose Standard. A known WS endpoint may still upgrade to WSS.

When an SSH jump host is enabled, Automatic uses WS inside the SSH tunnel. The
outer SSH connection provides encryption, and WSS is not offered because the
current tunnel implementation does not support TLS to the Bridge endpoint.

## Security properties

- Endpoint probes never include the Bridge API key or SSH credentials.
- Automatic selection prefers TLS.
- A previously successful TLS endpoint cannot be automatically downgraded.
- An explicit secure-only policy never falls back to plaintext.
- When a new Automatic connection resolves to WS and has an API key, the app
  asks for confirmation before sending the key without transport encryption.
- The UI explains that standard WS should be used only on a trusted network or
  through a VPN.

## Compatibility

Previously saved `useSsl: true` machines migrate to secure-only so an existing
security choice is preserved. Previously saved standard machines migrate to
automatic, allowing a future TLS endpoint to be preferred automatically.
