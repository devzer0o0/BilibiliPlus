/// Host policy for plaintext HTTP endpoints on a trusted LAN.
///
/// Public hosts are deliberately excluded even when the caller opts in.
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1';
}

/// RFC1918/CGNAT/link-local IPv4, IPv6 ULA/link-local, ".local" names, and
/// single-label intranet names.
bool isPrivateNetworkHost(String host) {
  final h = host.toLowerCase();
  if (isLoopbackHost(h)) return true;
  if (h.endsWith('.local') || !h.contains('.')) return true;
  if (h.contains(':')) {
    return h.startsWith('fc') || h.startsWith('fd') || h.startsWith('fe80:');
  }
  final parts = h.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }
  if (octets[0] == 10) return true;
  if (octets[0] == 127) return true;
  if (octets[0] == 192 && octets[1] == 168) return true;
  if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  if (octets[0] == 169 && octets[1] == 254) return true;
  if (octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127) return true;
  return false;
}
