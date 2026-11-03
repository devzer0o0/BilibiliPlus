/// A video someone shared with the account over B站 private messages.
///
/// Only视频 shares are collected; text, images and live cards are ignored. The
/// home feed shows these until the user opens one, at which point the bvid is
/// remembered and the entry stops appearing.
class SharedVideo {
  const SharedVideo({
    required this.bvid,
    required this.title,
    required this.senderName,
    required this.senderId,
    required this.cover,
    this.timestamp = 0,
  });

  final String bvid;
  final String title;

  /// Display name of the person who sent it - `StepGo` in the original request.
  final String senderName;
  final int senderId;
  final String cover;
  final int timestamp;

  @override
  bool operator ==(Object other) =>
      other is SharedVideo && other.bvid == bvid && other.senderId == senderId;

  @override
  int get hashCode => Object.hash(bvid, senderId);
}
