class ChatMediaAttachment {
  const ChatMediaAttachment({required this.id, required this.mediaType});
  final String id;
  final String mediaType;
  factory ChatMediaAttachment.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final type = json['media_type'];
    if (id is! String || id.isEmpty || (type != 'photo' && type != 'video')) {
      throw const FormatException('Invalid private attachment.');
    }
    return ChatMediaAttachment(id: id, mediaType: type as String);
  }
  Map<String, dynamic> toJson() => {'id': id, 'media_type': mediaType};
}
