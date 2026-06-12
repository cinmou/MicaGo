import '../models/connection_profile.dart';
import 'endpoint_utils.dart';

enum ConnectionCandidateKind { lan, public }

class ConnectionCandidate {
  final ConnectionCandidateKind kind;
  final String baseUrl;
  final String wsUrl;

  const ConnectionCandidate({
    required this.kind,
    required this.baseUrl,
    required this.wsUrl,
  });

  String get label => kind == ConnectionCandidateKind.lan ? 'LAN' : 'Public';

  @override
  String toString() => '$label(base=$baseUrl, ws=$wsUrl)';
}

List<ConnectionCandidate> connectionCandidatesForProfile(
  ConnectionProfile profile,
) {
  ConnectionCandidate? lan;
  final lanBase = _nonEmpty(profile.lanBaseUrl);
  if (lanBase != null) {
    lan = ConnectionCandidate(
      kind: ConnectionCandidateKind.lan,
      baseUrl: normalizeBaseUrl(lanBase),
      wsUrl: _nonEmpty(profile.lanWsUrl) ?? deriveWebSocketUrl(lanBase),
    );
  }

  ConnectionCandidate? pub;
  final publicBase = _nonEmpty(profile.publicBaseUrl);
  if (publicBase != null) {
    pub = ConnectionCandidate(
      kind: ConnectionCandidateKind.public,
      baseUrl: normalizeBaseUrl(publicBase),
      wsUrl: _nonEmpty(profile.publicWsUrl) ?? deriveWebSocketUrl(publicBase),
    );
  }

  final fallback = ConnectionCandidate(
    kind: profile.mode == ConnectionMode.publicOnly
        ? ConnectionCandidateKind.public
        : ConnectionCandidateKind.lan,
    baseUrl: normalizeBaseUrl(profile.baseUrl),
    wsUrl:
        _nonEmpty(profile.wsUrlOverride) ?? deriveWebSocketUrl(profile.baseUrl),
  );

  final out = <ConnectionCandidate>[];
  switch (profile.mode) {
    case ConnectionMode.lanOnly:
      if (lan != null) out.add(lan);
      break;
    case ConnectionMode.publicOnly:
      if (pub != null) out.add(pub);
      break;
    case ConnectionMode.lanFirst:
    case ConnectionMode.auto:
      if (lan != null) out.add(lan);
      if (pub != null) out.add(pub);
      break;
  }
  if (out.isEmpty && fallback.baseUrl.isNotEmpty) out.add(fallback);
  return _dedupe(out);
}

String? _nonEmpty(String? value) {
  final v = value?.trim() ?? '';
  return v.isEmpty ? null : v;
}

List<ConnectionCandidate> _dedupe(List<ConnectionCandidate> input) {
  final seen = <String>{};
  final out = <ConnectionCandidate>[];
  for (final c in input) {
    if (seen.add(c.baseUrl)) out.add(c);
  }
  return out;
}
