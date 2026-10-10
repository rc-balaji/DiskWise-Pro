/// Pure presentation helpers; safe to test without platform channels.
String prettyBytes(int n) {
  if (n < 1024) return '$n B';
  final units = ['KB', 'MB', 'GB', 'TB'];
  var size = n.toDouble();
  var i = -1;
  do {
    size /= 1024;
    i++;
  } while (size >= 1024 && i < units.length - 1);
  return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[i]}';
}

int number(Object? source) => source is num ? source.toInt() : int.tryParse('$source') ?? 0;
String string(Object? source) => source?.toString() ?? '';
Map<String, dynamic> asMap(Object? input) => Map<String, dynamic>.from(input as Map);

