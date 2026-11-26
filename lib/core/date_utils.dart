/// Local date key (`YYYY-MM-DD`) helpers with DST-safe calendar arithmetic.
abstract final class LexoraDateUtils {
  static final RegExp _dateKeyRegex = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// Generates `YYYY-MM-DD` strictly from local device wall-clock time.
  static String todayLocalKey([DateTime? now]) {
    final dt = now ?? DateTime.now();
    return formatLocalDate(dt);
  }

  static String formatLocalDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Parses `YYYY-MM-DD` with strict calendar round-trip validation.
  /// Rejects invalid dates such as `2026-02-30` or `2026-13-01`.
  static ({int year, int month, int day})? parseDateKeyStrict(String raw) {
    final match = _dateKeyRegex.firstMatch(raw);
    if (match == null) return null;

    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final day = int.tryParse(match.group(3)!);
    if (year == null || month == null || day == null) return null;
    if (year < 1970 || year > 2200) return null;
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;

    final roundTrip = DateTime.utc(year, month, day);
    if (roundTrip.year != year ||
        roundTrip.month != month ||
        roundTrip.day != day) {
      return null;
    }
    return (year: year, month: month, day: day);
  }

  /// Exact DST-safe day difference: `toKey - fromKey`.
  static int daysBetweenDateKeys(String fromKey, String toKey) {
    final p1 = parseDateKeyStrict(fromKey);
    final p2 = parseDateKeyStrict(toKey);
    if (p1 == null || p2 == null) {
      throw FormatException('Invalid date key(s): "$fromKey", "$toKey"');
    }
    final utc1 = DateTime.utc(p1.year, p1.month, p1.day);
    final utc2 = DateTime.utc(p2.year, p2.month, p2.day);
    return utc2.difference(utc1).inDays;
  }

  /// DST-safe calendar day addition returning `YYYY-MM-DD`.
  static String addDaysToDateKey(String dateKey, int days) {
    final p = parseDateKeyStrict(dateKey);
    if (p == null) {
      throw FormatException('Invalid date key: "$dateKey"');
    }
    final utc = DateTime.utc(p.year, p.month, p.day).add(Duration(days: days));
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
