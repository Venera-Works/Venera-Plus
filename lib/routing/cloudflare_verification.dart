const cloudflareVerificationRetryDelay = Duration(milliseconds: 250);
const cloudflareVerificationMaxRetries = 3;

bool isCloudflareDocumentReady(Object? readyState, Object? head, Object? body) {
  return (readyState == 'interactive' || readyState == 'complete') &&
      head is String &&
      body is String &&
      body.trim().isNotEmpty;
}
