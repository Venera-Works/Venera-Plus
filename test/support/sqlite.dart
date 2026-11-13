import 'package:sqlite3/sqlite3.dart';

bool isSqliteAvailable() {
  try {
    final database = sqlite3.openInMemory();
    database.close();
    return true;
  } catch (_) {
    return false;
  }
}
