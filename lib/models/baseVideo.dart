import 'package:json_annotation/json_annotation.dart';

import 'db/server.dart';
import 'db/videoFilter.dart';
import 'imageObject.dart';
import 'interfaces/sharelink.dart';

abstract class BaseVideo implements ShareLinks {
  String title;
  String videoId;
  int lengthSeconds;
  String? author;
  String? authorId;
  String? authorUrl;
  List<ImageObject> videoThumbnails;

  @JsonKey(includeFromJson: false, includeToJson: false)
  bool filtered = false;
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<VideoFilter> matchedFilters = [];

  BaseVideo(this.title, this.videoId, this.lengthSeconds, this.author, this.authorId, this.authorUrl, this.videoThumbnails);

  @override
  String getInvidiousLink(Server server, int? timestamp) {
    String link = '${server.url}/watch?v=$videoId';

    if (timestamp != null) link += '&t=$timestamp';

    return link;
  }

  @override
  String getRedirectLink(int? timestamp) {
    String link = 'https://redirect.invidious.io/watch?v=$videoId';

    if (timestamp != null) link += '&t=$timestamp';

    return link;
  }

  @override
  String getYoutubeLink(int? timestamp) {
    String link = 'https://youtu.be/$videoId';

    if (timestamp != null) link += '?t=$timestamp';

    return link;
  }
}
