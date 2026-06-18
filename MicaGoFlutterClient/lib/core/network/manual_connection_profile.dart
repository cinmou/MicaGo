import '../models/connection_profile.dart';
import 'endpoint_utils.dart';

/// Builds a v3-style profile from advanced manual origins. Normal setup should
/// use QR or pasted connection JSON; this is only the fallback editor.
ConnectionProfile advancedManualProfile({
  required String publicBaseUrl,
  required String lanBaseUrl,
  required String token,
}) {
  final pub = normalizeBaseUrl(publicBaseUrl);
  final lan = normalizeBaseUrl(lanBaseUrl);
  final hasLan = lan.isNotEmpty;
  final hasPublic = pub.isNotEmpty;
  final primary = hasLan ? lan : pub;
  final mode = hasLan
      ? ConnectionMode.lanFirst
      : hasPublic
      ? ConnectionMode.publicOnly
      : ConnectionMode.auto;
  return ConnectionProfile(
    baseUrl: primary,
    token: token.trim(),
    lanBaseUrl: hasLan ? lan : null,
    lanWsUrl: hasLan ? deriveWebSocketUrl(lan) : null,
    publicBaseUrl: hasPublic ? pub : null,
    publicWsUrl: hasPublic ? deriveWebSocketUrl(pub) : null,
    mode: mode,
  );
}
