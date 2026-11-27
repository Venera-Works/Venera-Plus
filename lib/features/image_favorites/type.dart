enum ImageFavoriteSortType {
  title("Title"),
  timeAsc("Time Asc"),
  timeDesc("Time Desc"),
  maxFavorites("Favorite Num"), // 单本收藏数最多排序
  favoritesCompareComicPages("Favorite Num Compare Comic Pages"); // 单本收藏数比上总页数

  final String value;

  const ImageFavoriteSortType(this.value);
}

const numFilterList = [0, 1, 2, 5, 10, 20, 50, 100];

class TimeRange {
  /// 自定义范围的结束边界（不含），为空时表示相对范围。
  final DateTime? end;

  /// 区间的实际时长。
  final Duration duration;

  const TimeRange({this.end, required this.duration});

  static const all = TimeRange(end: null, duration: Duration.zero);

  static const lastWeek = TimeRange(end: null, duration: Duration(days: 7));

  static const lastMonth = TimeRange(end: null, duration: Duration(days: 30));

  static const lastHalfYear = TimeRange(
    end: null,
    duration: Duration(days: 180),
  );

  static const lastYear = TimeRange(end: null, duration: Duration(days: 365));

  @override
  String toString() {
    return "${end?.millisecondsSinceEpoch}:${duration.inMilliseconds}";
  }

  /// 解析失败时恢复为全部时间。
  factory TimeRange.fromString(String? str) {
    final parts = str?.split(':');
    if (parts == null || parts.length != 2) return all;

    const maxDateTimeMs = 8_640_000_000_000_000;
    final durationMs = int.tryParse(parts[1]);
    if (durationMs == null || durationMs < 0 || durationMs > maxDateTimeMs) {
      return all;
    }
    final duration = Duration(milliseconds: durationMs);
    if (parts[0] == 'null') return TimeRange(duration: duration);

    final endMs = int.tryParse(parts[0]);
    // 旧版仅保存了毫秒分量，无法恢复结束日期。
    if (endMs == null ||
        endMs < 1000 ||
        endMs > maxDateTimeMs ||
        durationMs == 0) {
      return all;
    }
    return TimeRange(
      end: DateTime.fromMillisecondsSinceEpoch(endMs),
      duration: duration,
    );
  }

  bool contains(DateTime time) {
    final end = this.end;
    if (end != null) {
      return !time.isBefore(end.subtract(duration)) && time.isBefore(end);
    }
    if (duration == Duration.zero) return true;

    final now = DateTime.now();
    return !time.isBefore(now.subtract(duration)) && !time.isAfter(now);
  }

  @override
  bool operator ==(Object other) {
    return other is TimeRange && other.end == end && other.duration == duration;
  }

  @override
  int get hashCode => end.hashCode ^ duration.hashCode;

  static const List<TimeRange> values = [
    all,
    lastWeek,
    lastMonth,
    lastHalfYear,
    lastYear,
  ];
}

enum TimeRangeType {
  all("All"),
  lastWeek("Last Week"),
  lastMonth("Last Month"),
  lastHalfYear("Last Half Year"),
  lastYear("Last Year"),
  custom("Custom");

  final String value;

  const TimeRangeType(this.value);
}
