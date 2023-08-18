import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:invidious/controllers/miniPayerController.dart';
import 'package:invidious/views/tv/tvPlayerControls.dart';
import 'package:invidious/views/video/player.dart';

import '../../main.dart';
import '../../videos/models/base_video.dart';

class TvPlayerView extends StatelessWidget {
  final List<BaseVideo> videos;

  const TvPlayerView({Key? key, required this.videos}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    ColorScheme colors = Theme.of(context).colorScheme;
    TextTheme textTheme = Theme.of(context).textTheme;
    var locals = AppLocalizations.of(context)!;
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) => MiniPlayerCubit(MiniPlayerController.withVideos(videos)),
        )
      ],
      child: Theme(
        data: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
        child: Scaffold(
          body: BlocBuilder<MiniPlayerCubit, MiniPlayerController>(
            builder: (context, _) => Stack(
              children: [
                if (_.hasVideo)
                  VideoPlayer(
                    video: _.currentlyPlaying,
                    miniPlayer: false,
                    playNow: true,
                    disableControls: true,
                  ),
                const Positioned(top: 0, left: 0, right: 0, bottom: 0, child: TvPlayerControls())
              ],
            ),
          ),
        ),
      ),
    );
  }
}
