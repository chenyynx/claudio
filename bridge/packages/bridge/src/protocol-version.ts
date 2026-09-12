export const BRIDGE_PROTOCOL_MIN_VERSION = 1;
export const BRIDGE_PROTOCOL_MAX_VERSION = 1;
export const LEGACY_PROTOCOL_VERSION = 1;

/**
 * Additive behaviour flags advertised by the Bridge in `session_list`.
 *
 * These are NOT protocol versions: the wire format stays backwards compatible,
 * and each flag gates a behaviour change that only activates for clients that
 * echo the flag back in `client_capabilities`.  See docs/protocol-versioning.md.
 */
export const CAPABILITY_PROJECT_REQUEST_CORRELATION_V1 =
  "project_request_correlation_v1";
export const CAPABILITY_SESSION_CONTEXT_V1 = "session_context_v1";
/**
 * [stable history ids] Bridge assigns every history entry a stable
 * `messageUuid` (reused from the CLI transcript) and can serve a full-history
 * snapshot (archive + window) instead of a window-only one.  Clients that
 * advertise this capability receive stable ids and complete snapshots; clients
 * that do not get byte-identical legacy responses.
 */
export const CAPABILITY_STABLE_HISTORY_IDS = "stable_history_ids";

/** All capabilities this Bridge build advertises. */
export const BRIDGE_PROTOCOL_CAPABILITIES = [
  CAPABILITY_PROJECT_REQUEST_CORRELATION_V1,
  CAPABILITY_SESSION_CONTEXT_V1,
  CAPABILITY_STABLE_HISTORY_IDS,
] as const;

export interface ProtocolRange {
  min: number;
  max: number;
}

export interface ClientProtocolDeclaration {
  protocolVersion?: number;
  minimumProtocolVersion?: number;
}

/**
 * Resolve the range advertised by a client.
 *
 * Clients released before range negotiation either sent a singular
 * `protocolVersion` or omitted protocol metadata entirely. Both forms are
 * treated as supporting exactly one protocol version.
 */
export function clientProtocolRange(
  declaration: ClientProtocolDeclaration,
): ProtocolRange {
  const max = declaration.protocolVersion ?? LEGACY_PROTOCOL_VERSION;
  const min = declaration.minimumProtocolVersion ?? max;
  return { min, max };
}

/** Select the highest protocol version supported by both peers. */
export function negotiateProtocolVersion(
  client: ProtocolRange,
  server: ProtocolRange = {
    min: BRIDGE_PROTOCOL_MIN_VERSION,
    max: BRIDGE_PROTOCOL_MAX_VERSION,
  },
): number | null {
  const lowerBound = Math.max(client.min, server.min);
  const upperBound = Math.min(client.max, server.max);
  return lowerBound <= upperBound ? upperBound : null;
}
