/// Local placeholders must never be sent to a comic source or the network.
const missingDownloadPagePrefix = 'missing-download://';

class MissingDownloadPage implements Exception {
  const MissingDownloadPage(this.message);
  final String message;
  @override
  String toString() => message;
}
