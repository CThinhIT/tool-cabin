import 'package:equatable/equatable.dart';

/// An app that plays audio (Discord, Zalo, a browser...), i.e. a candidate
/// source for the incoming direction.
class CallApp extends Equatable {
  const CallApp({
    required this.exe,
    required this.rootPid,
    this.isPlaying = false,
    this.volume,
  });

  /// "Discord.exe".
  final String exe;

  /// Root of its process tree; process loopback captures the whole tree.
  final int rootPid;

  /// At least one of its audio sessions is active right now.
  final bool isPlaying;

  /// Its session volume in the Windows mixer (0..1), if it has a session.
  final double? volume;

  @override
  List<Object?> get props => [exe, rootPid, isPlaying, volume];
}
