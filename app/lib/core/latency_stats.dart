/// Rolling window of latency samples (ms) with percentiles.
class LatencyStats {
  LatencyStats({this.capacity = 200});

  final int capacity;
  final List<int> _values = [];

  int get count => _values.length;
  int? get last => _values.isEmpty ? null : _values.last;

  void add(int ms) {
    _values.add(ms);
    if (_values.length > capacity) _values.removeAt(0);
  }

  void clear() => _values.clear();

  /// Nearest-rank percentile, [p] in 0..100. Null when empty.
  int? percentile(double p) {
    if (_values.isEmpty) return null;
    final sorted = [..._values]..sort();
    final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }
}
