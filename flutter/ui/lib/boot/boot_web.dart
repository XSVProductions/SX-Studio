import 'package:sx_api/sx_api.dart';

/// The page was served by the laptop's engine, so the API is at the same
/// address. The key comes from the link the laptop showed (`?k=...`).
Future<SxClient> boot() async {
  final here = Uri.base;
  return SxClient(
    Uri(scheme: here.scheme, host: here.host, port: here.port),
    token: here.queryParameters['k'] ?? '',
  );
}
