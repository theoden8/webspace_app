/// [raw] as a time when it is a count of milliseconds since the epoch that a
/// [DateTime] can hold, else null. A stored value read back is untrusted, and
/// [DateTime.fromMillisecondsSinceEpoch] throws a [RangeError] past
/// ±8.64e15, an Error no reader catches.
DateTime? timeAtEpochMillis(Object? raw, {bool isUtc = false}) =>
    raw is int && raw.abs() <= _maxEpochMillis
        ? DateTime.fromMillisecondsSinceEpoch(raw, isUtc: isUtc)
        : null;

const _maxEpochMillis = 8640000000000000;
