import 'package:flutter_test/flutter_test.dart';
import 'package:diskwise_mobile/format.dart';

void main() {
  test('byte formatting includes 0-byte and sub-kilobyte files', () {
    expect(prettyBytes(0), '0 B');
    expect(prettyBytes(1), '1 B');
    expect(prettyBytes(1023), '1023 B');
    expect(prettyBytes(1024), '1.0 KB');
    expect(prettyBytes(1024 * 1024), '1.0 MB');
  });

  test('defensive platform value conversion', () {
    expect(number(null), 0);
    expect(number(123), 123);
    expect(number('45'), 45);
    expect(string(null), '');
    expect(asMap(<String, Object>{'a': 1})['a'], 1);
  });
}
