import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:bloc/bloc.dart';
import 'package:copy_with_extension/copy_with_extension.dart';
import 'package:easy_debounce/easy_debounce.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:invidious/database.dart';
import 'package:invidious/globals.dart';
import 'package:invidious/models/mediaCommand.dart';
import 'package:invidious/models/mediaEvent.dart';
import 'package:invidious/settings/models/db/settings.dart';
import 'package:invidious/utils/models/image_object.dart';
import 'package:logging/logging.dart';

import '../downloads/models/downloaded_video.dart';
import '../main.dart';
import '../mediaHander.dart';
import '../utils/models/pair.dart';
import '../videos/models/base_video.dart';
import '../videos/models/db/progress.dart' as dbProgress;
import '../videos/models/sponsor_segment.dart';
import '../videos/models/sponsor_segment_types.dart';
import '../videos/models/video.dart';

part 'miniPayerController.g.dart';

const double targetHeight = 69;
const double miniPlayerThreshold = 300;
const double bigPlayerThreshold = 700;

var log = Logger('MiniPlayerController');

enum PlayerRepeat { noRepeat, repeatAll, repeatOne }

class MiniPlayerCubit extends Cubit<MiniPlayerController> {
  MiniPlayerCubit(super.initialState) {
    onReady();
  }

  setEvent(MediaEvent event) {
    var state = this.state.copyWith();
    state.mediaEvent = event;
    emit(state);
    handleMediaEvent(event);
    mapMediaEventToMediaHandler(event);
  }

  mapMediaEventToMediaHandler(MediaEvent event) {
    if (event.type != MediaEventType.progress) {
      log.fine("Event state: ${event.state}, ${event.type}");
      var playbackState = PlaybackState(
        controls: [
          state.hasQueue ? MediaControl.skipToPrevious : MediaControl.rewind,
          if (state.isPlaying) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          state.hasQueue ? MediaControl.skipToNext : MediaControl.fastForward,
        ],
        systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward, MediaAction.setShuffleMode, MediaAction.setRepeatMode},
        androidCompactActionIndices: const [0, 1, 3],
        processingState: const {
              MediaState.idle: AudioProcessingState.idle,
              MediaState.loading: AudioProcessingState.loading,
              MediaState.buffering: AudioProcessingState.buffering,
              MediaState.ready: AudioProcessingState.ready,
              MediaState.completed: AudioProcessingState.completed,
              MediaState.playing: AudioProcessingState.ready,
            }[event.state] ??
            AudioProcessingState.ready,
        playing: event.state == MediaState.idle || event.state == MediaState.completed ? false : state.isPlaying,
        updatePosition: state.position,
        bufferedPosition: state.bufferedPosition,
        speed: state.speed,
        queueIndex: state.currentIndex,
      );

      mediaHandler.playbackState.add(playbackState);
    }
  }

  onReady() async {
    if (!isTv) {
      BackButtonInterceptor.add(handleBackButton, name: 'miniPlayer', zIndex: 2);

      mediaHandler = await AudioService.init(
        builder: () => MediaHandler(this),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.github.lamarios.clipious.channel.audio',
          androidNotificationChannelName: 'Video playback',
          androidNotificationOngoing: true,
        ),
      );
    }
  }

  handleMediaEvent(MediaEvent event) {
    switch (event.state) {
      case MediaState.completed:
        if (state.currentlyPlaying != null) {
          saveProgress(state.currentlyPlaying!.lengthSeconds);
        }
        playNext();
        _setPlaying(false);
        break;
      default:
        break;
    }

    switch (event.type) {
      case MediaEventType.progress:
        onProgress(event.value);
        break;
      case MediaEventType.play:
        _setPlaying(true);
        break;
      case MediaEventType.pause:
        _setPlaying(false);
      default:
        break;
    }
  }

  @override
  close() async {
    BackButtonInterceptor.removeByName('miniPlayer');
    super.close();
  }

  bool handleBackButton(bool stopDefaultButtonEvent, RouteInfo info) {
    if (state.isFullScreen) {
      var state = this.state.copyWith();
      state.isFullScreen = false;
      emit(state);
      globalNavigator.currentState?.pop();
      return true;
    } else if (!state.isMini) {
      // we block the backbutton behavior and we make the player small
      showMiniPlayer();
      return true;
    } else {
      return false;
    }
  }

  toggleShuffle() {
    var state = this.state.copyWith();
    state.shuffle = !state.shuffle;
    db.saveSetting(SettingsValue(PLAYER_SHUFFLE, state.shuffle.toString()));
    emit(state);
  }

  setNextRepeatMode() {
    switch (state.repeat) {
      case PlayerRepeat.noRepeat:
        state.repeat = PlayerRepeat.repeatAll;
        break;
      case PlayerRepeat.repeatAll:
        state.repeat = PlayerRepeat.repeatOne;
        break;
      case PlayerRepeat.repeatOne:
        state.repeat = PlayerRepeat.noRepeat;
        break;
    }

    db.saveSetting(SettingsValue(PLAYER_REPEAT, PlayerRepeat.values.indexOf(state.repeat).toString()));
  }

  setVideos(List<BaseVideo> videos) {
    var state = this.state.copyWith();
    state.videos = videos.where((element) => !element.filtered).toList();
    state.offlineVideos = [];
    emit(state);
  }

  selectTab(int index) {
    var state = this.state.copyWith();
    state.selectedFullScreenIndex = index;
    emit(state);
  }

  setAudio(bool? newValue) {
    var state = this.state.copyWith();
    newValue ??= false;

    state.isAudio = newValue;
    emit(state);
  }

  hide() {
    var state = this.state.copyWith();
    state.isMini = true;
    state.mediaEvent = MediaEvent(state: MediaState.miniDisplayChanged);
    state.top = null;
    state.height = targetHeight;
    state.isHidden = true;
    state.videos = [];
    state.playedVideos = [];
    state.currentlyPlaying = null;
    state.offlineCurrentlyPlaying = null;
    state.offlineVideos = [];
    state.opacity = 0;
    emit(state);
    setEvent(MediaEvent(state: MediaState.idle));
  }

  double get getBottom => state.isHidden ? -targetHeight : 0;

  BaseVideo showVideo() {
    var video = state.videos[state.currentIndex];
    hide();
    return video;
  }

  saveProgress(int timeInSeconds) {
    if (state.currentlyPlaying != null) {
      int currentPosition = timeInSeconds;
      // saving progress
      var progress = dbProgress.Progress.named(progress: currentPosition / state.currentlyPlaying!.lengthSeconds, videoId: state.currentlyPlaying!.videoId);
      db.saveProgress(progress);

      if (progress.progress > 0.5) {
        EasyDebounce.debounce('invidious-progress-sync-${progress.videoId}', const Duration(seconds: 5), () {
          if (service.isLoggedIn()) {
            service.addToUserHistory(progress.videoId);
          }
        });
      }
    }
  }

  queueVideos(List<BaseVideo> videos) {
    var state = this.state.copyWith();
    state.offlineVideos = [];
    if (videos.isNotEmpty) {
      //removing videos that are already in the queue
      state.videos.addAll(videos.where((v) => state.videos.indexWhere((v2) => v2.videoId == v.videoId) == -1).where((element) => !element.filtered));
    } else {
      playVideo(videos);
    }
    log.fine('Videos in queue ${videos.length}');
    emit(state);
  }

  showBigPlayer() {
    var state = this.state.copyWith();
    state.isMini = false;
    state.mediaEvent = MediaEvent(state: MediaState.miniDisplayChanged);
    state.top = 0;
    state.opacity = 1;
    state.isHidden = false;
    emit(state);
  }

  showMiniPlayer() {
    if (state.currentlyPlaying != null || state.offlineCurrentlyPlaying != null) {
      var state = this.state.copyWith();
      state.isMini = true;
      state.mediaEvent = MediaEvent(state: MediaState.miniDisplayChanged);
      state.top = null;
      state.isHidden = false;
      state.opacity = 1;
      emit(state);
    }
  }

  onProgress(Duration? position) {
    EasyThrottle.throttle('media-progress', const Duration(seconds: 1), () {
      var state = this.state.copyWith();
      state.position = position ?? Duration.zero;
      int currentPosition = state.position.inSeconds;
      saveProgress(currentPosition);
      log.fine("video event");

      emit(state);

      if (state.sponsorSegments.isNotEmpty) {
        double positionInMs = currentPosition * 1000;
        Pair<int> nextSegment = state.sponsorSegments.firstWhere((e) => e.first <= positionInMs && positionInMs <= e.last, orElse: () => Pair<int>(-1, -1));
        if (nextSegment.first != -1) {
          seek(Duration(milliseconds: nextSegment.last + 1000));
          final ScaffoldMessengerState? scaffold = scaffoldKey.currentState;

          if (scaffold != null) {
            var locals = AppLocalizations.of(scaffold.context)!;
            scaffold.showSnackBar(SnackBar(
              content: Text(locals.sponsorSkipped),
              duration: const Duration(seconds: 1),
            ));
          }
        }
      }
    });
  }

  playNext() {
    if (state.videos.isNotEmpty || state.offlineVideos.isNotEmpty) {
      var state = this.state.copyWith();
      var listToUpdate = state.videos.isNotEmpty ? state.videos : state.offlineVideos;

      log.fine('Play next: played length: ${state.playedVideos.length} videos: ${state.videos.length} Repeat mode: ${state.repeat}');
      if (state.repeat == PlayerRepeat.repeatOne) {
        if (state.videos.isNotEmpty) {
          switchToVideo(state.currentlyPlaying!);
        } else if (state.offlineVideos.isNotEmpty) {
          switchToOfflineVideo(state.offlineCurrentlyPlaying!);
        }
      } else {
        state = this.state.copyWith();
        if (state.playedVideos.length >= listToUpdate.length) {
          if (state.repeat == PlayerRepeat.repeatAll) {
            state.playedVideos = [];
            state.currentIndex = 0;
          } else {
            return;
          }
        } else {
          if (!state.shuffle) {
            // making sure we play something that can be played
            if (state.currentIndex + 1 < listToUpdate.length) {
              state.currentIndex++;
            } else if (state.repeat == PlayerRepeat.repeatAll) {
              // we might reach here if user changes repeat mode and play with previous/next buttons
              state.currentIndex = 0;
              state.playedVideos = [];
            } else {
              return;
            }
          } else {
            if (state.videos.isNotEmpty) {
              List<BaseVideo> availableVideos = state.videos.where((e) => !state.playedVideos.contains(e.videoId)).toList();
              String nextVideoId = availableVideos[Random().nextInt(availableVideos.length)].videoId;
              state.currentIndex = state.videos.indexWhere((e) => e.videoId == nextVideoId);
            } else {
              List<DownloadedVideo> availableVideos = state.offlineVideos.where((e) => !state.playedVideos.contains(e.videoId)).toList();
              String nextVideoId = availableVideos[Random().nextInt(availableVideos.length)].videoId;
              state.currentIndex = state.offlineVideos.indexWhere((e) => e.videoId == nextVideoId);
            }
          }
        }
        emit(state);
        if (state.videos.isNotEmpty) {
          switchToVideo(state.videos[state.currentIndex]);
        } else if (state.offlineVideos.isNotEmpty) {
          switchToOfflineVideo(state.offlineVideos[state.currentIndex]);
        }
      }
    }
  }

  playPrevious() {
    var listToUpdate = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    if (listToUpdate.length > 1) {
      var state = this.state.copyWith();
      state.currentIndex--;
      if (state.currentIndex < 0) {
        state.currentIndex = state.videos.length - 1;
      }

      if (state.videos.isNotEmpty) {
        switchToVideo(state.videos[state.currentIndex]);
      } else if (state.offlineVideos.isNotEmpty) {
        switchToOfflineVideo(state.offlineVideos[state.currentIndex]);
      }

      emit(state);
    }
  }

  _setPlaying(bool playing) {
    var state = this.state.copyWith();
    state.isPlaying = playing;
    emit(state);
  }

  _playVideos(List<IdedVideo> vids, {Duration? startAt}) async {
    if (vids.isNotEmpty) {
      var state = this.state.copyWith();
      state.startAt = startAt;
      bool isOffline = vids[0] is DownloadedVideo;

      state.mediaEvent = MediaEvent(state: MediaState.loading);

      if (isOffline) {
        state.videos = [];
        state.offlineVideos = List.from(vids, growable: true);
      } else {
        state.offlineVideos = [];
        state.videos = List.from(vids, growable: true);
      }

      state.playedVideos = [];
      state.currentIndex = 0;
      state.selectedFullScreenIndex = 0;
      if (vids.length > 1) {
        state.selectedFullScreenIndex = 3;
      }
      state.opacity = 0;
      state.top = 500;
      emit(state);

      showBigPlayer();
      if (isOffline) {
        await switchToOfflineVideo(state.offlineVideos[0]);
      } else {
        await switchToVideo(state.videos[0], startAt: startAt);
      }
    }
  }

  _switchToVideo(IdedVideo video, {Duration? startAt}) async {
    var state = this.state.copyWith();
    bool isOffline = video is DownloadedVideo;

    state.mediaEvent = MediaEvent(state: MediaState.loading);

    if (isOffline) {
      state.videos = [];
      state.currentlyPlaying = null;
    } else {
      state.offlineVideos = [];
      state.offlineCurrentlyPlaying = null;
    }

    List<IdedVideo> toCheck = isOffline ? state.offlineVideos : state.videos;

    int index = toCheck.indexWhere((element) => element.videoId == video.videoId);
    if (index >= 0 && index < toCheck.length) {
      state.currentIndex = index;
    } else {
      state.currentIndex = 0;
    }

    if (!isOffline) {
      late Video v;
      if (video is Video) {
        v = video;
      } else {
        v = await service.getVideo(video.videoId);
      }
      state.currentlyPlaying = v;
      setSponsorBlock(state);
      state.mediaCommand = MediaCommand(MediaCommandType.switchVideo, value: SwitchVideoValue(video: v, startAt: startAt));
    } else {
      state.isAudio = video.audioOnly;
      state.offlineCurrentlyPlaying = video;
      state.mediaCommand = MediaCommand(MediaCommandType.switchToOfflineVideo, value: video);
    }

    if (!state.playedVideos.contains(video.videoId)) {
      state.playedVideos.add(video.videoId);
    }
    state.position = Duration.zero;

    emit(state);
    // MiniPlayerControlsController.to()?.setVideo(video.videoId);

    mediaHandler.skipToQueueItem(state.currentIndex);
  }

  playOfflineVideos(List<DownloadedVideo> offlineVids) async {
    log.fine('Playing ${offlineVids.length} offline videos');
    await _playVideos(offlineVids);
  }

  playVideo(List<BaseVideo> v, {bool? goBack, bool? audio, Duration? startAt}) async {
    List<BaseVideo> videos = v.where((element) => !element.filtered).toList();
    if (goBack ?? false) navigatorKey.currentState?.pop();
    log.fine('Playing ${videos.length} videos');

    setAudio(audio);

    await _playVideos(videos, startAt: startAt);
  }

  switchToOfflineVideo(DownloadedVideo video) async {
    await _switchToVideo(video);
  }

  switchToVideo(BaseVideo video, {Duration? startAt}) async {
    await _switchToVideo(video, startAt: startAt);
  }

  void togglePlaying() {
    state.isPlaying ? pause() : play();
  }

  play() {
    var state = this.state.copyWith();
    state.mediaCommand = MediaCommand(MediaCommandType.play);
    emit(state);
  }

  pause() {
    var state = this.state.copyWith();
    state.mediaCommand = MediaCommand(MediaCommandType.pause);
    emit(state);
  }

  BaseVideo? get currentVideo => state.videos.isNotEmpty ? state.videos[state.currentIndex] : null;

  removeVideoFromQueue(String videoId) {
    var state = this.state.copyWith();
    var listToUpdate = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    if (listToUpdate.length == 1) {
      hide();
    } else {
      int index = state.videos.isNotEmpty ? state.videos.indexWhere((element) => element.videoId == videoId) : state.offlineVideos.indexWhere((element) => element.videoId == videoId);
      state.playedVideos.remove(videoId);
      if (index >= 0) {
        if (index < state.currentIndex) {
          state.currentIndex--;
        }
        listToUpdate.removeAt(index);
      }
    }
    emit(state);
  }

  void videoDragged(DragUpdateDetails details) {
    var state = this.state.copyWith();
    // log.info('delta: ${details.delta.dy}, local: ${details.localPosition.dy}, global: ${details.globalPosition.dy}');
    state.isDragging = true;
    state.top = details.globalPosition.dy;
    // we  change the display mode if there's a big enough drag movement to avoid jittery behavior when dragging slow
    if (details.delta.dy.abs() > 3) {
      state.isMini = details.delta.dy > 0;
      state.mediaEvent = MediaEvent(state: MediaState.miniDisplayChanged);
    }
    state.dragDistance += details.delta.dy;
    // we're going down, putting threshold high easier to switch to mini player
    emit(state);
  }

  void videoDraggedEnd(DragEndDetails details) {
    bool showMini = state.dragDistance.abs() > 200 ? state.isMini : state.dragStartMini;
    if (showMini) {
      showMiniPlayer();
    } else {
      showBigPlayer();
    }
  }

  void videoDragStarted(DragStartDetails details) {
    state.dragDistance = 0;
    state.dragStartMini = state.isMini;
  }

  bool isVideoInQueue(Video video) {
    return state.videos.indexWhere((element) => element.videoId == video.videoId) >= 0;
  }

  onQueueReorder(int oldItemIndex, int newItemIndex) {
    var state = this.state.copyWith();
    log.fine('Dragged video');
    var listToUpdate = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    var movedItem = listToUpdate.removeAt(oldItemIndex);
    listToUpdate.insert(newItemIndex, movedItem);
    log.fine('Reordered list: $oldItemIndex new index: ${listToUpdate.indexOf(movedItem)}');
    if (oldItemIndex == state.currentIndex) {
      state.currentIndex = newItemIndex;
    } else if (oldItemIndex > state.currentIndex && newItemIndex <= state.currentIndex) {
      state.currentIndex++;
    } else if (oldItemIndex < state.currentIndex && newItemIndex >= state.currentIndex) {
      state.currentIndex--;
    }

    emit(state);
  }

  void playVideoNext(BaseVideo video) {
    if (state.videos.isEmpty) {
      playVideo([video]);
    } else {
      var state = this.state.copyWith();
      int newIndex = state.currentIndex + 1;
      int oldIndex = state.videos.indexWhere((element) => element.videoId == video.videoId);
      if (oldIndex == -1) {
        state.videos.insert(newIndex, video);
        emit(state);
      } else {
        onQueueReorder(oldIndex, newIndex);
      }
    }
  }

  setSponsorBlock(MiniPlayerController state) async {
    if (state.currentlyPlaying != null) {
      List<SponsorSegmentType> types = SponsorSegmentType.values.where((e) => db.getSettings(e.settingsName())?.value == 'true').toList();

      if (types.isNotEmpty) {
        List<SponsorSegment> sponsorSegments = await service.getSponsorSegments(state.currentlyPlaying!.videoId, types);
        List<Pair<int>> segments = List.from(sponsorSegments.map((e) {
          Duration start = Duration(seconds: e.segment[0].floor());
          Duration end = Duration(seconds: e.segment[1].floor());
          Pair<int> segment = Pair(start.inMilliseconds, end.inMilliseconds);
          return segment;
        }));

        state.sponsorSegments = segments;
        log.fine('we found ${segments.length} segments to skip');
      } else {
        state.sponsorSegments = [];
      }
    }
  }

  seek(Duration duration) {
    var state = this.state.copyWith();
    state.position = duration;
    state.mediaCommand = MediaCommand(MediaCommandType.seek, value: duration);
    emit(state);
  }

  void fastForward() {
    Duration newDuration = Duration(seconds: (state.position.inSeconds ?? 0) + 10);
    seek(newDuration);
  }

  void rewind() {
    Duration newDuration = Duration(seconds: (state.position.inSeconds ?? 0) - 10);
    seek(newDuration);
  }

  Future<MediaItem?> getMediaItem(int index) async {
    if (state.videos.isNotEmpty) {
      var e = state.videos[index];
      return MediaItem(
          id: e.videoId, title: e.title, artist: e.author, duration: Duration(seconds: e.lengthSeconds), album: '', artUri: Uri.parse(ImageObject.getBestThumbnail(e.videoThumbnails)?.url ?? ''));
    } else if (state.offlineVideos.isNotEmpty) {
      var e = state.offlineVideos[index];
      var path = await e.thumbnailPath;
      return MediaItem(id: e.videoId, title: e.title, artist: e.author, duration: Duration(seconds: e.lengthSeconds), album: '', artUri: Uri.file(path));
    }
    return null;
  }

  void setSpeed(double d) {
    var state = this.state.copyWith();
    state.mediaCommand = MediaCommand(MediaCommandType.speed, value: d);
    emit(state);
  }

  void togglePlay() {
    if (state.isPlaying) {
      pause();
    } else {
      play();
    }
  }

  Duration get duration => Duration(seconds: (state.currentlyPlaying?.lengthSeconds ?? state.offlineCurrentlyPlaying?.lengthSeconds ?? 1));

  double get progress => state.position.inMilliseconds / duration.inMilliseconds;
}

@CopyWith(constructor: "_")
class MiniPlayerController {
  int currentIndex = 0;
  List<BaseVideo> videos = List.empty(growable: true);
  double height = targetHeight;
  bool isMini = true;
  double? top;
  bool isDragging = false;
  int selectedFullScreenIndex = 0;
  bool isPip = false;
  bool isHidden = true;
  bool isFullScreen = false;
  Video? currentlyPlaying;
  DownloadedVideo? offlineCurrentlyPlaying;
  double opacity = 0;
  double dragDistance = 0;
  bool dragStartMini = true;
  bool isShowingOverflow = false;
  PlayerRepeat repeat = PlayerRepeat.values[int.parse(db.getSettings(PLAYER_REPEAT)?.value ?? '0')];
  bool shuffle = db.getSettings(PLAYER_SHUFFLE)?.value == 'true';
  List<String> playedVideos = [];
  Offset offset = Offset.zero;
  bool isAudio = true;
  Duration? startAt;
  Duration position = Duration.zero;
  Duration bufferedPosition = Duration.zero;

  double speed = 1.0;
  MediaCommand? mediaCommand;

  // sponsor block variables
  List<Pair<int>> sponsorSegments = List.of([]);
  Pair<int> nextSegment = Pair(0, 0);

  // end of sponsor block variables

  List<DownloadedVideo> offlineVideos = [];

  // final eventStream = StreamController<MediaEvent>.broadcast();
  MediaEvent mediaEvent = MediaEvent(state: MediaState.idle);

  bool isPlaying = false;

  bool get hasVideo => currentlyPlaying != null || offlineCurrentlyPlaying != null;

  bool get hasQueue => offlineVideos.length > 1 || videos.length > 1;

  MiniPlayerController();

  MiniPlayerController.withVideos(this.videos);

  MiniPlayerController._(
      this.currentIndex,
      this.videos,
      this.height,
      this.isMini,
      this.top,
      this.isDragging,
      this.selectedFullScreenIndex,
      this.isPip,
      this.isHidden,
      this.speed,
      this.isFullScreen,
      this.currentlyPlaying,
      this.offlineCurrentlyPlaying,
      this.opacity,
      this.dragDistance,
      this.dragStartMini,
      this.isShowingOverflow,
      this.repeat,
      this.shuffle,
      this.bufferedPosition,
      this.playedVideos,
      this.offset,
      this.isAudio,
      this.startAt,
      this.isPlaying,
      this.sponsorSegments,
      this.nextSegment,
      this.offlineVideos,
      this.position,
      this.mediaCommand,
      this.mediaEvent);
}
